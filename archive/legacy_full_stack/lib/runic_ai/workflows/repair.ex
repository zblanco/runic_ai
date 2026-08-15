defmodule RunicAI.Workflows.Repair do
  @moduledoc """
  Bounded typed-operation repair for canonical workflow IR.

  This boundary runs after any authoring adapter. It never weakens shared
  validation and never asks the model to regenerate the complete workflow.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result
  alias RunicAI.Workflows.Catalog
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.Editor
  alias RunicAI.Workflows.IR
  alias RunicAI.Workflows.OperationProtocol
  alias RunicAI.Workflows.Validator

  @default_model "openai:gpt-5.6-luna"
  @default_attempts 2
  @repair_components ~w[
    source_discovery source_splitter source_materializer llm_map llm_leaf
    lambda_reduce lambda_generate lambda_review report_composer artifact_writer
    objective_scorecard verification
  ]

  @spec to_runnable(IR.t(), Workspace.t(), keyword()) ::
          {:ok, %{ir: IR.t(), compiled: map(), history: [map()]}} | {:error, Error.t()}
  def to_runnable(%IR{} = ir, %Workspace{} = workspace, opts \\ []) when is_list(opts) do
    attempts = Keyword.get(opts, :workflow_repair_attempts, @default_attempts)

    case Compiler.compile(ir, workspace, compile_opts(opts)) do
      {:ok, compiled} -> {:ok, %{ir: ir, compiled: compiled, history: []}}
      {:error, error} -> repair(ir, workspace, opts, attempts, [], error)
    end
  end

  defp repair(_ir, _workspace, _opts, 0, history, error) do
    {:error,
     Error.validation("shared workflow repair attempts were exhausted",
       source: __MODULE__,
       details: %{
         code: :workflow_repair_exhausted,
         last_error: error_details(error),
         history: history
       }
     )}
  end

  defp repair(ir, workspace, opts, attempts_left, history, prior_error) do
    diagnostics = Validator.report(ir, mode: :runnable).diagnostics
    prompt = prompt(ir, diagnostics, prior_error, opts)

    with {:ok, %Result{} = result} <-
           LLM.generate_text(
             Keyword.get(opts, :model, @default_model),
             prompt,
             llm_opts(opts)
           ),
         response = Result.text(result),
         {:ok, operations} <- decode_operations(response),
         {:ok, edit} <- Editor.apply(ir, OperationProtocol.batch(ir, operations)) do
      record = %{
        status: :applied,
        base_revision: edit.base_revision,
        result_revision: edit.result_revision,
        base_hash: edit.base_hash,
        result_hash: edit.result_hash,
        operations: edit.operations,
        affected_nodes: edit.affected_nodes,
        diff: edit.diff,
        diagnostics: edit.diagnostics,
        provider_usage: result.usage,
        prompt: prompt,
        response: response
      }

      case Compiler.compile(edit.ir, workspace, compile_opts(opts)) do
        {:ok, compiled} ->
          {:ok, %{ir: edit.ir, compiled: compiled, history: history ++ [record]}}

        {:error, error} ->
          repair(
            edit.ir,
            workspace,
            opts,
            attempts_left - 1,
            history ++ [Map.put(record, :compile_error, error_details(error))],
            error
          )
      end
    else
      {:error, error} ->
        record = %{
          status: :rejected,
          base_revision: ir.revision,
          base_hash: IR.semantic_hash(ir),
          error: error_details(error),
          prior_error: error_details(prior_error),
          prompt: prompt
        }

        repair(
          ir,
          workspace,
          opts,
          attempts_left - 1,
          history ++ [record],
          error
        )
    end
  end

  defp prompt(ir, diagnostics, prior_error, opts) do
    """
    Repair this canonical RunicAI workflow through a targeted semantic
    operation transaction. The repaired graph must satisfy the objective,
    preserve requested sources and artifact paths, and pass every runnable
    contract diagnostic. Do not weaken acceptance or delete required output.

    Objective: #{Keyword.get(opts, :objective, ir.objective)}
    Runnable diagnostics: #{Jason.encode!(diagnostics)}
    Compiler failure: #{Jason.encode!(error_details(prior_error))}

    Native lowering invariant: when a native map (`llm_map`, `record_map`, or
    `lambda_map`) has downstream work, connect it directly to a typed
    `lambda_reduce`, then proceed to final synthesis or artifact production.
    `lambda_reduce` outputs synthesis and cannot feed `record_group`. If the
    objective only groups fields already present in parsed records, use
    `tabular_parser -> record_group` and remove the map/reduce branch. Never
    connect a native map directly to an ordinary step.

    #{OperationProtocol.grammar()}

    Relevant authoritative component contracts:
    #{Jason.encode!(contract_slice(ir))}

    Base revision: #{ir.revision}
    Base semantic hash: #{IR.semantic_hash(ir)}
    Current editable manifest:
    #{Jason.encode!(OperationProtocol.editable_manifest(ir))}
    """
  end

  defp contract_slice(ir) do
    keys =
      ir.nodes
      |> Map.values()
      |> Enum.map(& &1.component)
      |> Kernel.++(Enum.map(@repair_components, &Catalog.component_key/1))
      |> Enum.uniq()
      |> Enum.sort()

    Map.new(keys, fn key ->
      case Catalog.resolve(key) do
        {:ok, contract} ->
          {key,
           %{
             ref: contract.ref,
             inputs: contract.inputs,
             outputs: contract.outputs,
             effects: contract.effects,
             execution_shape: contract.execution_shape
           }}

        {:error, _error} ->
          {key, %{unavailable: true}}
      end
    end)
  end

  defp decode_operations(response) do
    with {:ok, decoded} <- response |> unfence() |> Jason.decode(),
         operations when is_list(operations) <- value(decoded, :operations) do
      {:ok, operations}
    else
      {:error, error} ->
        {:error,
         Error.validation("workflow repair response was not valid JSON",
           source: __MODULE__,
           details: %{code: :invalid_repair_json, error: Exception.message(error)}
         )}

      _other ->
        {:error,
         Error.validation("workflow repair response must contain an operation list",
           source: __MODULE__,
           details: %{code: :invalid_repair_operations}
         )}
    end
  end

  defp unfence(text) do
    text = String.trim(text)

    case Regex.run(~r/\A```(?:json)?\s*\n?(.*?)\n?```\z/su, text) do
      [_, inner] -> String.trim(inner)
      _other -> text
    end
  end

  defp llm_opts(opts) do
    opts
    |> Keyword.get(:llm_opts, [])
    |> maybe_put(:client, Keyword.get(opts, :client))
    |> maybe_put(:receive_timeout, Keyword.get(opts, :receive_timeout))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp compile_opts(opts), do: Keyword.get(opts, :compile_opts, [])

  defp error_details(%Error{} = error) do
    %{kind: error.kind, message: error.message, details: error.details}
  end

  defp error_details(error), do: %{reason: inspect(error)}

  defp value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_other, _key), do: nil
end
