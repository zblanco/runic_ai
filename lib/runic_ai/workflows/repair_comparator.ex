defmodule RunicAI.Workflows.RepairComparator do
  @moduledoc """
  End-to-end comparison of whole-object and typed-operation workflow repair.

  Both arms receive the same workflow, instruction, and deterministic
  diagnostics. Candidates pass through canonical IR parsing, runnable
  validation, native compilation, isolated execution, and caller-supplied proof.
  """

  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.OperationProtocol
  alias RunicAI.Workflows.Validator

  @arms [:whole_object, :typed_operations]

  @spec run_case(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_case(
        %{id: id, instruction: instruction, base_ir: base, target_ir: target} = eval_case,
        opts
      )
      when is_binary(id) and is_binary(instruction) and is_list(opts) do
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")

    with {:ok, base} <- IR.from_input(base),
         {:ok, target} <- IR.from_input(target) do
      diagnostics = Validator.report(base, mode: :runnable).diagnostics

      rows =
        Enum.map(@arms, fn arm ->
          run_arm(arm, id, instruction, base, target, diagnostics, model, opts)
        end)

      {:ok,
       %{
         case_id: id,
         task_family: Map.get(eval_case, :task_family),
         base_hash: IR.semantic_hash(base),
         target_hash: IR.semantic_hash(target),
         initial_diagnostics: diagnostics,
         rows: rows,
         all_verified?: Enum.all?(rows, & &1.metrics.verified_success),
         typed_not_worse?: typed_not_worse?(rows)
       }}
    end
  end

  @spec arms() :: [atom()]
  def arms, do: @arms

  defp run_arm(arm, case_id, instruction, base, target, diagnostics, model, opts) do
    prompt = prompt(arm, instruction, base, diagnostics)
    started = System.monotonic_time(:millisecond)

    llm_opts =
      opts
      |> Keyword.take([:author_client, :temperature, :max_completion_tokens, :receive_timeout])
      |> rename_client()
      |> Keyword.put_new(:temperature, 0.0)

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        response = Result.text(result)
        parsed = parse(arm, response, base)

        evaluate_candidate(
          arm,
          case_id,
          prompt,
          response,
          result.usage,
          parsed,
          base,
          target,
          started,
          opts
        )

      outcome ->
        row(arm, case_id, prompt, nil, nil, started,
          status: :error,
          failure_layer: :authoring,
          diagnostics: error_map(outcome)
        )
    end
  end

  defp evaluate_candidate(
         arm,
         case_id,
         prompt,
         response,
         usage,
         {:ok, candidate},
         base,
         target,
         started,
         opts
       ) do
    candidate = %{candidate | revision: target.revision}
    change_metrics = change_metrics(base, target, candidate)
    validation = Validator.report(candidate, mode: :runnable)

    if validation.status == :accepted do
      execute_candidate(
        arm,
        case_id,
        prompt,
        response,
        usage,
        candidate,
        change_metrics,
        validation,
        started,
        opts
      )
    else
      row(arm, case_id, prompt, response, usage, started,
        status: :fail,
        failure_layer: :validation,
        diagnostics: validation,
        change_metrics: change_metrics
      )
    end
  end

  defp evaluate_candidate(
         arm,
         case_id,
         prompt,
         response,
         usage,
         {:error, layer, error},
         _base,
         _target,
         started,
         _opts
       ) do
    row(arm, case_id, prompt, response, usage, started,
      status: :fail,
      failure_layer: layer,
      diagnostics: error_map(error)
    )
  end

  defp execute_candidate(
         arm,
         case_id,
         prompt,
         response,
         usage,
         candidate,
         change_metrics,
         validation,
         started,
         opts
       ) do
    case workspace_for(arm, opts) do
      {:ok, workspace} ->
        compile_and_run(
          arm,
          case_id,
          prompt,
          response,
          usage,
          candidate,
          change_metrics,
          validation,
          workspace,
          started,
          opts
        )

      {:error, error} ->
        failure_row(
          arm,
          case_id,
          prompt,
          response,
          usage,
          started,
          :workspace,
          error,
          change_metrics
        )
    end
  end

  defp compile_and_run(
         arm,
         case_id,
         prompt,
         response,
         usage,
         candidate,
         change_metrics,
         validation,
         workspace,
         started,
         opts
       ) do
    case Compiler.compile(candidate, workspace, compile_opts(opts)) do
      {:ok, compiled} ->
        run_and_verify(
          arm,
          case_id,
          prompt,
          response,
          usage,
          candidate,
          change_metrics,
          validation,
          compiled,
          workspace,
          started,
          opts
        )

      {:error, error} ->
        failure_row(
          arm,
          case_id,
          prompt,
          response,
          usage,
          started,
          :compilation,
          error,
          change_metrics
        )
    end
  end

  defp run_and_verify(
         arm,
         case_id,
         prompt,
         response,
         usage,
         candidate,
         change_metrics,
         validation,
         compiled,
         workspace,
         started,
         opts
       ) do
    case Compiler.run(
           candidate,
           workspace,
           Keyword.get(opts, :execution_input, %{}),
           execution_opts(opts)
         ) do
      {:ok, result} ->
        case verify_result(result, workspace, opts) do
          :ok ->
            row(arm, case_id, prompt, response, usage, started,
              status: :pass,
              failure_layer: nil,
              diagnostics: %{
                validation: validation,
                semantic_hash: IR.semantic_hash(candidate),
                compiled_hash: compiled.compiled_hash
              },
              change_metrics: change_metrics,
              verified_success: true
            )

          {:error, error} ->
            failure_row(
              arm,
              case_id,
              prompt,
              response,
              usage,
              started,
              :proof,
              error,
              change_metrics
            )
        end

      {:error, error} ->
        failure_row(
          arm,
          case_id,
          prompt,
          response,
          usage,
          started,
          :execution,
          error,
          change_metrics
        )
    end
  end

  defp failure_row(
         arm,
         case_id,
         prompt,
         response,
         usage,
         started,
         layer,
         error,
         change_metrics
       ) do
    row(arm, case_id, prompt, response, usage, started,
      status: :fail,
      failure_layer: layer,
      diagnostics: error_map(error),
      change_metrics: change_metrics
    )
  end

  defp prompt(:whole_object, instruction, base, diagnostics) do
    """
    Repair this RunicAI workflow using the validation diagnostics. Return only
    the complete canonical workflow JSON. Preserve every unrelated field and
    contract pin. Every node and edge object must include an "id" exactly equal
    to its enclosing map key. Edge from/to endpoints must remain objects shaped
    {"node":"stable_node_id","port":"exact_port_name"}; never shorten them to
    "node.port" strings. Do not explain the answer.

    Request: #{instruction}
    Diagnostics: #{Jason.encode!(diagnostics)}
    Current workflow: #{Jason.encode!(base)}
    """
  end

  defp prompt(:typed_operations, instruction, base, diagnostics) do
    """
    Repair this RunicAI workflow using the validation diagnostics.
    #{OperationProtocol.grammar()}

    Request: #{instruction}
    Diagnostics: #{Jason.encode!(diagnostics)}
    Base revision: #{base.revision}
    Base semantic hash: #{IR.semantic_hash(base)}
    Current editable manifest: #{Jason.encode!(OperationProtocol.editable_manifest(base))}
    """
  end

  defp parse(:whole_object, response, _base) do
    case response |> unfence() |> Jason.decode() do
      {:ok, decoded} ->
        case IR.from_input(decoded) do
          {:ok, ir} -> {:ok, ir}
          {:error, error} -> {:error, :canonical_ir, error}
        end

      {:error, error} ->
        {:error, :json, error}
    end
  end

  defp parse(:typed_operations, response, base) do
    case response |> unfence() |> Jason.decode() do
      {:ok, decoded} ->
        case operations(decoded) do
          operations when is_list(operations) ->
            case Editor.apply(base, OperationProtocol.batch(base, operations)) do
              {:ok, edit} -> {:ok, edit.ir}
              {:error, error} -> {:error, :operation_application, error}
            end

          error ->
            {:error, :operation_shape, error}
        end

      {:error, error} ->
        {:error, :json, error}
    end
  end

  defp operations(%{"operations" => operations}), do: operations
  defp operations(operations) when is_list(operations), do: operations
  defp operations(_other), do: :invalid_operations

  defp workspace_for(arm, opts) do
    case Keyword.fetch(opts, :workspace_factory) do
      {:ok, factory} when is_function(factory, 1) -> normalize_workspace(factory.(arm))
      {:ok, factory} when is_function(factory, 0) -> normalize_workspace(factory.())
      :error -> {:error, :workspace_factory_required}
    end
  end

  defp normalize_workspace({:ok, workspace}), do: {:ok, workspace}
  defp normalize_workspace(workspace), do: {:ok, workspace}

  defp verify_result(result, workspace, opts) do
    case Keyword.get(opts, :verify_result, fn _result, _workspace -> true end).(result, workspace) do
      true -> :ok
      :ok -> :ok
      false -> {:error, :proof_failed}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_proof_result, other}}
    end
  end

  defp compile_opts(opts), do: Keyword.get(opts, :compile_opts, [])

  defp execution_opts(opts) do
    Keyword.get(opts, :execution_opts, [])
  end

  defp change_metrics(base, target, candidate) do
    expected_paths = changed_paths(base, target)
    candidate_paths = changed_paths(base, candidate)

    %{
      exact_semantic_repair: IR.semantic_hash(candidate) == IR.semantic_hash(target),
      expected_change_count: MapSet.size(expected_paths),
      candidate_change_count: MapSet.size(candidate_paths),
      collateral_change_count: MapSet.size(MapSet.difference(candidate_paths, expected_paths)),
      missing_change_count: MapSet.size(MapSet.difference(expected_paths, candidate_paths)),
      distance_to_expected: MapSet.size(changed_paths(target, candidate))
    }
  end

  defp changed_paths(left, right) do
    left = canonical(left)
    right = canonical(right)
    collect_changed_paths(left, right, [], MapSet.new())
  end

  defp collect_changed_paths(left, right, _path, acc) when left == right, do: acc

  defp collect_changed_paths(left, right, path, acc) when is_map(left) and is_map(right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.reduce(acc, fn key, current ->
      collect_changed_paths(Map.get(left, key), Map.get(right, key), path ++ [key], current)
    end)
  end

  defp collect_changed_paths(left, right, path, acc) when is_list(left) and is_list(right) do
    case max(length(left), length(right)) do
      0 ->
        acc

      count ->
        0..(count - 1)
        |> Enum.reduce(acc, fn index, current ->
          collect_changed_paths(
            Enum.at(left, index),
            Enum.at(right, index),
            path ++ [index],
            current
          )
        end)
    end
  end

  defp collect_changed_paths(_left, _right, path, acc), do: MapSet.put(acc, path)

  defp canonical(value),
    do: value |> Jason.encode!() |> Jason.decode!() |> Map.drop(["presentation"])

  defp row(arm, case_id, prompt, response, usage, started, opts) do
    change_metrics = Keyword.get(opts, :change_metrics, %{})

    %{
      case_id: case_id,
      arm: arm,
      status: Keyword.fetch!(opts, :status),
      metrics:
        Map.merge(
          %{
            verified_success: Keyword.get(opts, :verified_success, false),
            latency_ms: System.monotonic_time(:millisecond) - started,
            prompt_bytes: byte_size(prompt),
            response_bytes: if(is_binary(response), do: byte_size(response), else: 0),
            provider_usage: usage,
            failure_layer: Keyword.get(opts, :failure_layer)
          },
          change_metrics
        ),
      diagnostics: Keyword.get(opts, :diagnostics, %{}),
      artifacts: %{prompt: prompt, response: response}
    }
  end

  defp typed_not_worse?(rows) do
    typed = Enum.find(rows, &(&1.arm == :typed_operations))
    whole = Enum.find(rows, &(&1.arm == :whole_object))

    (Map.get(typed.metrics, :verified_success, false) or
       not Map.get(whole.metrics, :verified_success, false)) and
      Map.get(typed.metrics, :collateral_change_count, 1_000_000) <=
        Map.get(whole.metrics, :collateral_change_count, 1_000_000)
  end

  defp rename_client(opts) do
    case Keyword.pop(opts, :author_client) do
      {nil, opts} -> opts
      {client, opts} -> Keyword.put(opts, :client, client)
    end
  end

  defp unfence(text) do
    text = String.trim(text)

    case Regex.run(~r/\A```(?:json)?\s*\n?(.*?)\n?```\z/su, text) do
      [_, inner] -> String.trim(inner)
      _other -> text
    end
  end

  defp error_map({:error, error}), do: error_map(error)

  defp error_map(%{kind: kind, message: message, details: details}),
    do: %{kind: kind, message: message, details: details}

  defp error_map(error) when is_map(error), do: error
  defp error_map(error), do: %{reason: inspect(error)}
end
