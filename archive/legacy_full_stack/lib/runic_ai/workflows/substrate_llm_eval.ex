defmodule RunicAI.Workflows.SubstrateLLMEval do
  @moduledoc "Runs the substrate bake-off against a real model and preserves provider usage."

  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.Workflows.DSL
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.OperationProtocol

  @arms [:normalized_json, :compact_dsl, :typed_operations]

  @spec run_case(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_case(%{id: id, instruction: instruction, base_ir: base, target_ir: target}, opts \\ []) do
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")

    with {:ok, base} <- IR.from_input(base),
         {:ok, target} <- IR.from_input(target),
         {:ok, base_dsl} <- DSL.render(base) do
      target_hash = IR.semantic_hash(target)
      json = Jason.encode!(base, pretty: true)

      rows =
        Enum.map(@arms, fn arm ->
          prompt = prompt(arm, instruction, json, base_dsl, base)
          run_arm(arm, id, model, prompt, base, target, target_hash, opts)
        end)

      {:ok,
       %{
         case_id: id,
         target_hash: target_hash,
         rows: rows,
         all_pass?: Enum.all?(rows, &(&1.status == :pass)),
         provider_usage_complete?: Enum.all?(rows, &is_map(&1.metrics.provider_usage))
       }}
    end
  end

  defp run_arm(arm, case_id, model, prompt, base, target, target_hash, opts) do
    started = System.monotonic_time(:millisecond)

    llm_opts =
      opts
      |> Keyword.take([:client, :temperature, :max_completion_tokens, :receive_timeout])
      |> Keyword.put_new(:temperature, 0.0)

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        text = Result.text(result)
        parsed = parse_arm(arm, text, base)
        {status, diagnostics} = compare(parsed, target, target_hash)

        %{
          case_id: case_id,
          arm: arm,
          status: status,
          metrics: %{
            prompt_bytes: byte_size(prompt),
            response_bytes: byte_size(text),
            latency_ms: System.monotonic_time(:millisecond) - started,
            provider_usage: result.usage
          },
          diagnostics: diagnostics,
          artifacts: %{prompt: prompt, response: text, model: model}
        }

      {:error, error} ->
        %{
          case_id: case_id,
          arm: arm,
          status: :error,
          metrics: %{
            prompt_bytes: byte_size(prompt),
            response_bytes: 0,
            latency_ms: System.monotonic_time(:millisecond) - started,
            provider_usage: nil
          },
          diagnostics: error_map(error),
          artifacts: %{prompt: prompt, model: model}
        }
    end
  end

  defp parse_arm(:normalized_json, text, _base) do
    with {:ok, decoded} <- text |> unfence() |> Jason.decode(),
         {:ok, ir} <- IR.from_input(decoded) do
      {:ok, ir}
    end
  end

  defp parse_arm(:compact_dsl, text, _base), do: text |> unfence() |> DSL.parse()

  defp parse_arm(:typed_operations, text, base) do
    with {:ok, decoded} <- text |> unfence() |> Jason.decode(),
         operations when is_list(operations) <-
           decoded_operations(decoded),
         {:ok, edited} <-
           Editor.apply(base, %{
             base_revision: base.revision,
             base_hash: IR.semantic_hash(base),
             operations: operations
           }) do
      {:ok, edited.ir}
    else
      {:error, error} -> {:error, error}
      other -> {:error, other}
    end
  end

  defp decoded_operations(%{"operations" => operations}), do: operations
  defp decoded_operations(operations) when is_list(operations), do: operations
  defp decoded_operations(_decoded), do: :invalid_operations

  # Definition revisions are assigned by the editor/persistence transaction, not
  # by an authoring projection. Normalize that server-owned field before judging
  # a full-object or DSL response against an operation-based response.
  defp compare({:ok, ir}, target, target_hash) do
    author_revision = ir.revision
    actual = ir |> Map.put(:revision, target.revision) |> IR.semantic_hash()

    if actual == target_hash do
      {:pass,
       %{
         semantic_hash: actual,
         semantic_fidelity: 1.0,
         author_revision: author_revision,
         normalized_revision: target.revision
       }}
    else
      {:fail,
       %{
         code: :semantic_mismatch,
         expected: target_hash,
         actual: actual,
         author_revision: author_revision,
         normalized_revision: target.revision
       }}
    end
  end

  defp compare({:error, error}, _target, _target_hash), do: {:fail, error_map(error)}

  defp prompt(:normalized_json, instruction, json, _dsl, _base) do
    """
    Edit the workflow exactly as requested. Return only the complete canonical JSON object.
    Preserve every unrelated field and catalog contract pin.

    Request: #{instruction}

    Current workflow:
    #{json}
    """
  end

  defp prompt(:compact_dsl, instruction, _json, dsl, _base) do
    """
    Edit the workflow exactly as requested. Return only the complete Runic workflow DSL.
    Preserve tabs, stable ids, unrelated statements, and catalog contract pins.

    Request: #{instruction}

    Current workflow:
    #{dsl}
    """
  end

  defp prompt(:typed_operations, instruction, _json, _dsl, base) do
    """
    #{OperationProtocol.grammar()}

    Request: #{instruction}
    Base revision: #{base.revision}
    Base semantic hash: #{IR.semantic_hash(base)}
    Current editable manifest:
    #{Jason.encode!(OperationProtocol.editable_manifest(base))}
    """
  end

  defp unfence(text) do
    text = String.trim(text)

    case Regex.run(~r/\A```(?:json|text|yaml|dsl)?\s*\n?(.*?)\n?```\z/su, text) do
      [_, inner] -> String.trim(inner)
      _other -> text
    end
  end

  defp error_map(%{kind: kind, message: message, details: details}) do
    %{kind: kind, message: message, details: details}
  end

  defp error_map(error) when is_map(error), do: error
  defp error_map(error), do: %{reason: inspect(error)}
end
