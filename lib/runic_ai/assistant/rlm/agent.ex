defmodule RunicAI.Assistant.RLM.Agent do
  @moduledoc """
  General-purpose dynamic RLM assistant agent.

  The agent proposes a workflow blueprint, validates it, compiles it into a
  Runic graph backed by anonymous functions/components, executes the graph, and
  returns artifacts plus an evidence scorecard.
  """

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.RepairLoop
  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @spec run(Workspace.t() | Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace_input, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    run_id = Keyword.get(opts, :run_id) || "assistant:#{System.unique_integer([:positive])}"
    event_sink = Keyword.get(opts, :event_sink, fn _stage -> :ok end)

    with {:ok, workspace} <- workspace_from_input(workspace_input, opts) do
      emit(event_sink, run_id, :started, :running, %{
        objective: objective,
        workspace: workspace.root,
        inputs: Keyword.get(opts, :input_paths, []),
        output: Keyword.get(opts, :output_path)
      })

      emit(event_sink, run_id, :capability_manifest_prepared, :ok, %{
        capabilities: Coordinator.capability_manifest(opts)
      })

      case propose_validate_execute(workspace, objective, opts, run_id, event_sink) do
        {:ok, result} ->
          emit(event_sink, run_id, :completed, result_status(result.scorecard), %{
            artifact_paths: artifact_paths(result.artifacts),
            scorecard: result.scorecard
          })

          {:ok,
           result
           |> Map.put(:agent, :assistant)
           |> Map.put(:run_id, run_id)
           |> Map.put(:session_id, run_id)
           |> Map.put(:status, result_status(result.scorecard))}

        {:error, %Error{} = error} ->
          emit(event_sink, run_id, :failed, :error, %{error: error})
          {:error, error}
      end
    end
  end

  defp propose_validate_execute(workspace, objective, opts, run_id, event_sink) do
    with {:ok, blueprint} <- Coordinator.propose(workspace, objective, opts) do
      emit(event_sink, run_id, :blueprint_proposed, :ok, %{
        blueprint_id: blueprint.id,
        component_count: length(blueprint.components),
        sources: blueprint.sources
      })

      case BlueprintValidator.validate(blueprint, validation_opts(opts)) do
        {:ok, report} ->
          execute_blueprint(workspace, objective, blueprint, report, opts, run_id, event_sink, [])

        {:error, %Error{} = error} ->
          repair_and_execute(workspace, objective, opts, run_id, event_sink, error)
      end
    end
  end

  defp repair_and_execute(workspace, objective, opts, run_id, event_sink, error) do
    emit(event_sink, run_id, :validation_completed, :error, %{error: error})

    with {:ok, repair} <- RepairLoop.fallback_repair(workspace, objective, error, opts),
         blueprint = repair.blueprint,
         {:ok, report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
      emit(event_sink, run_id, :repair_completed, :ok, %{
        strategy: repair.strategy,
        reason: repair.reason,
        blueprint_id: blueprint.id
      })

      execute_blueprint(workspace, objective, blueprint, report, opts, run_id, event_sink, [
        Map.drop(repair, [:blueprint])
      ])
    end
  end

  defp execute_blueprint(
         workspace,
         objective,
         blueprint,
         report,
         opts,
         run_id,
         event_sink,
         repair_history
       ) do
    emit(event_sink, run_id, :validation_completed, :ok, %{validation_report: report})

    run_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:event_sink, event_sink)
      |> Keyword.put(:objective, objective)

    case WorkflowCompiler.run(blueprint, workspace, %{}, run_opts) do
      {:ok, result} ->
        emit(event_sink, run_id, :execution_completed, :ok, %{
          output: output_summary(result.output),
          artifacts: result.artifacts
        })

        scorecard = result.scorecard || fallback_scorecard(result, opts)

        emit(event_sink, run_id, :scorecard_completed, result_status(scorecard), %{
          scorecard: scorecard
        })

        {:ok,
         result
         |> Map.put(:scorecard, scorecard)
         |> Map.put(:objective_scorecard, scorecard)
         |> Map.put(:repair_history, repair_history)
         |> Map.put(:persistence_ref, nil)}

      {:error, %Error{} = error} ->
        emit(event_sink, run_id, :execution_failed, :error, %{error: error})
        {:error, error}
    end
  end

  defp workspace_from_input(%Workspace{} = workspace, _opts), do: Workspace.validate(workspace)

  defp workspace_from_input(root, opts) when is_binary(root) do
    Workspace.new(
      root: root,
      path_policy: path_policy(Keyword.get(opts, :write_policy, :docs_only), opts)
    )
  end

  defp workspace_from_input(input, _opts), do: Workspace.from_input(input)

  defp path_policy(:docs_only, opts) do
    PathPolicy.new!(
      hidden_policy: :allow,
      allowed_write_roots: [".docs"],
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
    )
  end

  defp path_policy("docs_only", opts), do: path_policy(:docs_only, opts)
  defp path_policy("docs-only", opts), do: path_policy(:docs_only, opts)

  defp path_policy(:workspace_review, opts) do
    PathPolicy.new!(
      hidden_policy: :allow,
      allowed_write_roots: ["."],
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
    )
  end

  defp path_policy("workspace_review", opts), do: path_policy(:workspace_review, opts)
  defp path_policy("workspace-review", opts), do: path_policy(:workspace_review, opts)

  defp path_policy(_policy, opts) do
    PathPolicy.new!(
      hidden_policy: :allow,
      allowed_write_roots: ["."],
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
    )
  end

  defp validation_opts(opts) do
    [
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      max_nodes: Keyword.get(opts, :max_nodes)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fallback_scorecard(result, opts) do
    output_text = output_text(result.output)

    objective_status =
      if String.trim(output_text) != "" or result.artifacts != [] do
        :objective_satisfied
      else
        :objective_incomplete
      end

    %{
      id: "scorecard:fallback",
      objective_status: objective_status,
      artifact_path: Keyword.get(opts, :output_path),
      artifact_status: if(result.artifacts == [], do: :not_required, else: :present),
      residual_risks:
        if(objective_status == :objective_satisfied, do: [], else: ["no output produced"])
    }
  end

  defp result_status(%{objective_status: status})
       when status in [:objective_satisfied, "objective_satisfied"],
       do: :ok

  defp result_status(%{objective_status: status})
       when status in [:objective_incomplete, "objective_incomplete"],
       do: :blocked

  defp result_status(_scorecard), do: :ok

  defp artifact_paths(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, :path) || Map.get(&1, "path")))
    |> Enum.reject(&is_nil/1)
  end

  defp output_summary(%{text: text}) when is_binary(text), do: %{text_preview: preview(text)}
  defp output_summary(value), do: %{preview: preview(value)}

  defp output_text(%{text: text}) when is_binary(text), do: text
  defp output_text(%{"text" => text}) when is_binary(text), do: text
  defp output_text(value) when is_binary(value), do: value
  defp output_text(_value), do: ""

  defp emit(event_sink, run_id, stage, status, data) when is_function(event_sink, 1) do
    try do
      event_sink.(%{run_id: run_id, stage: stage, status: status, data: data})
    rescue
      _exception -> :ok
    end
  end

  defp emit(_event_sink, _run_id, _stage, _status, _data), do: :ok

  defp preview(value) when is_binary(value) do
    if String.length(value) > 220, do: String.slice(value, 0, 220) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 12, printable_limit: 220)
end
