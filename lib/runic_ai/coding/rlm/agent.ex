defmodule RunicAI.Coding.RLM.Agent do
  @moduledoc """
  Strategic RLM-inspired coding agent.

  The agent coordinates a higher-level coding objective by:

  1. indexing the codebase as external RLM sources,
  2. asking or selecting a coordinator workflow proposal,
  3. validating the proposal before execution,
  4. compiling accepted data into a Runic workflow, and
  5. executing decomposed workflow nodes into episodes and artifacts.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.RLM.Artifact
  alias RunicAI.Coding.RLM.Checkpoint
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.Coordinator
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.Persistence
  alias RunicAI.Coding.RLM.ProgressGate
  alias RunicAI.Coding.RLM.RepairLoop
  alias RunicAI.Coding.RLM.RuntimeBudget
  alias RunicAI.Coding.RLM.WorkflowCompiler
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Error

  @type run_result :: %{
          required(:proposal) => term(),
          required(:validation_report) => term(),
          required(:compiled) => term(),
          required(:workflow) => Workflow.t(),
          required(:context) => map(),
          required(:output) => term(),
          required(:episodes) => list(),
          required(:trace) => list()
        }

  @spec prepare(Workspace.t() | keyword() | map() | Path.t(), keyword()) ::
          {:ok, CodebaseEnvironment.t()} | {:error, Error.t()}
  def prepare(workspace_input, opts \\ []) when is_list(opts) do
    CodebaseEnvironment.new(workspace_input,
      index?: Keyword.get(opts, :index?, true),
      file_limit: Keyword.get(opts, :file_limit, 500),
      include_hidden: Keyword.get(opts, :include_hidden, false),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  @spec prepare!(Workspace.t() | keyword() | map() | Path.t(), keyword()) ::
          CodebaseEnvironment.t()
  def prepare!(workspace_input, opts \\ []) do
    case prepare(workspace_input, opts) do
      {:ok, environment} -> environment
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec propose(String.t(), CodebaseEnvironment.t(), keyword()) ::
          {:ok, term(), term()} | {:error, Error.t()}
  def propose(objective, %CodebaseEnvironment{} = environment, opts \\ []) do
    Coordinator.propose(objective, environment, opts)
  end

  @spec compile(term(), CodebaseEnvironment.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def compile(proposal, %CodebaseEnvironment{} = environment, opts \\ []) do
    WorkflowCompiler.compile(proposal, environment, opts)
  end

  @spec run(Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) ::
          {:ok, run_result()} | {:error, Error.t()}
  def run(workspace_input, objective, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    run_id = Checkpoint.run_id(opts)
    started_at_ms = System.monotonic_time(:millisecond)
    tracker = start_event_tracker()

    opts =
      opts
      |> Keyword.put_new(:run_id, run_id)
      |> Keyword.put_new(:run_started_at_ms, started_at_ms)
      |> maybe_put_run_deadline(started_at_ms)
      |> wrap_event_tracker(tracker)

    try do
      fn -> run_unbounded(workspace_input, objective, opts) end
      |> RuntimeBudget.run(
        timeout_ms: Keyword.get(opts, :max_runtime_ms),
        stage: :rlm_agent_run,
        objective: objective,
        timeout_handler: fn details ->
          parent_timeout_result(details, tracker, opts, objective)
        end
      )
      |> tap(fn
        {:error, error} -> emit_stage(opts, :failed, :error, %{error: error})
        _other -> :ok
      end)
    after
      stop_event_tracker(tracker)
    end
  end

  defp maybe_put_run_deadline(opts, started_at_ms) do
    case Keyword.get(opts, :max_runtime_ms) do
      max_runtime_ms when is_integer(max_runtime_ms) and max_runtime_ms > 0 ->
        Keyword.put_new(opts, :run_deadline_ms, started_at_ms + max_runtime_ms)

      _other ->
        opts
    end
  end

  defp run_unbounded(workspace_input, objective, opts) do
    run_id = Checkpoint.run_id(opts)

    opts =
      opts
      |> Keyword.put_new(:run_id, run_id)
      |> put_run_metadata(run_id, objective)

    emit_stage(opts, :started, :running, %{objective: objective})

    with {:ok, environment} <- prepare(workspace_input, opts),
         persistence = environment.workspace.persistence,
         :ok <-
           emit_stage(opts, :environment_prepared, :ok, %{
             workspace_root: environment.workspace.root,
             source_count: map_size(environment.source_index.refs_by_id)
           }),
         _prepared_ref <-
           Checkpoint.record_best_effort(
             persistence,
             :prepared,
             %{
               workspace_root: environment.workspace.root,
               source_count: map_size(environment.source_index.refs_by_id),
               objective: objective
             },
             run_id: run_id
           ),
         :ok <-
           emit_stage(opts, :proposal_started, :running, %{
             objective: objective,
             source_count: map_size(environment.source_index.refs_by_id),
             max_runtime_ms: Keyword.get(opts, :max_runtime_ms),
             run_deadline_ms: Keyword.get(opts, :run_deadline_ms),
             objective_contract: early_objective_contract(objective, opts)
           }),
         {:ok, proposal, report} <-
           Checkpoint.result(
             persistence,
             :proposal,
             fn -> propose_with_progress(objective, environment, opts) end,
             run_id: run_id,
             input: %{objective: objective}
           ),
         :ok <-
           emit_stage(opts, :proposal_received, report.status, %{
             proposal: proposal,
             validation_report: report
           }),
         {:ok, compiled} <-
           Checkpoint.result(
             persistence,
             :compiled,
             fn -> WorkflowCompiler.compile(proposal, environment, opts) end,
             run_id: run_id,
             proposal_id: proposal.id
           ),
         :ok <- emit_stage(opts, :compile_completed, :ok, %{compiled: compiled}),
         {:ok, execution} <-
           Checkpoint.result(
             persistence,
             :executed,
             fn ->
               WorkflowCompiler.run(proposal, environment, Keyword.get(opts, :input, %{}), opts)
             end,
             run_id: run_id,
             proposal_id: proposal.id
           ),
         :ok <- emit_stage(opts, :execution_completed, :ok, execution) do
      initial_result =
        Map.merge(execution, %{
          proposal: proposal,
          validation_report: report,
          compiled: compiled,
          codebase_environment: environment
        })
        |> ProgressGate.apply(opts)

      emit_stage(opts, :progress_gate_completed, :ok, %{
        objective_scorecard: Map.get(initial_result, :objective_scorecard),
        repair_needs: get_in(initial_result, [:context, :repair_needs])
      })

      with {:ok, result} <- maybe_repair(initial_result, environment, opts) do
        result =
          if Keyword.get(opts, :persist?, not is_nil(environment.workspace.persistence)) do
            case Persistence.persist(result) do
              {:ok, ref} ->
                emit_stage(opts, :persistence_completed, :ok, %{persistence_ref: ref})
                Map.put(result, :persistence_ref, ref)

              {:error, error} ->
                emit_stage(opts, :persistence_completed, :error, %{error: error})
                Map.put(result, :persistence_error, error)
            end
          else
            result
          end

        emit_stage(opts, :completed, completion_status(result), %{
          objective_scorecard: Map.get(result, :objective_scorecard),
          repair_status: Map.get(result, :repair_status),
          persistence_ref: Map.get(result, :persistence_ref)
        })

        {:ok, result}
      end
    end
  end

  defp put_run_metadata(opts, run_id, objective) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.put_new(:run_id, run_id)
      |> Map.put_new(:original_objective, objective)

    Keyword.put(opts, :metadata, metadata)
  end

  defp propose_with_progress(objective, environment, opts) do
    timeout_ms = proposal_timeout_ms(opts)

    result =
      RuntimeBudget.run(
        fn ->
          opts = put_proposal_llm_timeout(opts, timeout_ms)

          case Coordinator.propose(objective, environment, opts) do
            {:ok, proposal, report} -> {:ok, {proposal, report}}
            {:error, error} -> {:error, error}
          end
        end,
        timeout_ms: timeout_ms,
        tick_ms: Keyword.get(opts, :proposal_progress_tick_ms, 5_000),
        stage: :proposal_generation,
        objective: objective,
        details: %{
          source_count: map_size(environment.source_index.refs_by_id),
          run_deadline_ms: Keyword.get(opts, :run_deadline_ms)
        },
        progress_sink: fn tick ->
          emit_stage(opts, :proposal_progress, :running, tick)
        end
      )

    case result do
      {:ok, {proposal, report}} -> {:ok, proposal, report}
      other -> other
    end
  end

  defp put_proposal_llm_timeout(opts, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 5_000 do
    Keyword.put_new(opts, :proposal_llm_timeout_ms, timeout_ms - 4_000)
  end

  defp put_proposal_llm_timeout(opts, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    Keyword.put_new(opts, :proposal_llm_timeout_ms, timeout_ms)
  end

  defp put_proposal_llm_timeout(opts, _timeout_ms), do: opts

  defp proposal_timeout_ms(opts) do
    explicit = Keyword.get(opts, :proposal_timeout_ms)
    remaining = remaining_runtime_ms(opts)

    cond do
      is_integer(explicit) and explicit > 0 and is_integer(remaining) and remaining > 0 ->
        min(explicit, remaining)

      is_integer(explicit) and explicit > 0 ->
        explicit

      is_integer(remaining) and remaining > 0 ->
        remaining

      true ->
        nil
    end
  end

  defp remaining_runtime_ms(opts) do
    case Keyword.get(opts, :run_deadline_ms) do
      deadline_ms when is_integer(deadline_ms) ->
        max(deadline_ms - System.monotonic_time(:millisecond), 1)

      _other ->
        nil
    end
  end

  @spec run!(Workspace.t() | keyword() | map() | Path.t(), String.t(), keyword()) :: run_result()
  def run!(workspace_input, objective, opts \\ []) do
    case run(workspace_input, objective, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(term(), keyword()) :: term()
  def validate(proposal, opts \\ []), do: WorkflowValidator.validate(proposal, opts)

  @spec search_sessions(nil | {module(), term()} | module(), String.t() | nil) ::
          {:ok, [map()]} | {:error, Error.t()}
  def search_sessions(persistence, query \\ nil), do: Persistence.search(persistence, query)

  @spec replay_session(map()) :: {:ok, map()} | {:error, Error.t()}
  def replay_session(snapshot), do: Persistence.replay(snapshot)

  @spec codex_events_to_artifacts(String.t()) :: {:ok, [Artifact.t()]} | {:error, Error.t()}
  def codex_events_to_artifacts(jsonl) when is_binary(jsonl) do
    with {:ok, normalized} <- EventNormalizer.normalize_jsonl(jsonl) do
      artifacts =
        normalized.raw_events
        |> Enum.with_index()
        |> Enum.map(fn {event, index} ->
          Artifact.new!(:codex_event, event,
            id: "codex-event:#{index}",
            metadata: %{source: :codex, final?: event == normalized.final}
          )
        end)

      {:ok, artifacts}
    end
  end

  defp maybe_repair(result, %CodebaseEnvironment{} = environment, opts) do
    repair_opts = Keyword.get(opts, :repair_opts, [])

    if Keyword.get(opts, :repair?, Keyword.get(repair_opts, :enabled?, false)) do
      RepairLoop.run(result, environment, opts)
    else
      {:ok, result}
    end
  end

  defp early_objective_contract(objective, opts) do
    contract =
      case Keyword.get(opts, :objective_contract) do
        nil -> ObjectiveContract.infer(objective, metadata: %{source: :proposal_started})
        input -> ObjectiveContract.from_input(input)
      end

    case contract do
      {:ok, %ObjectiveContract{} = contract} -> ObjectiveContract.to_map(contract)
      {:error, _error} -> nil
    end
  end

  defp emit_stage(opts, stage, status, data) do
    sink = Keyword.get(opts, :event_sink) || Keyword.get(opts, :stage_sink)

    if is_function(sink, 1) do
      event = %{
        id:
          "rlm-stage:#{Keyword.get(opts, :run_id)}:#{stage}:#{System.unique_integer([:positive])}",
        run_id: Keyword.get(opts, :run_id),
        stage: stage,
        status: status,
        at: DateTime.utc_now(),
        data: data
      }

      try do
        sink.(event)
      rescue
        _exception -> :ok
      end
    end

    :ok
  end

  defp start_event_tracker do
    case Elixir.Agent.start_link(fn -> %{last_event: nil} end) do
      {:ok, pid} -> pid
      {:error, _reason} -> nil
    end
  end

  defp stop_event_tracker(nil), do: :ok

  defp stop_event_tracker(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Elixir.Agent.stop(pid, :normal, 100), else: :ok
  catch
    _kind, _reason -> :ok
  end

  defp wrap_event_tracker(opts, nil), do: opts

  defp wrap_event_tracker(opts, tracker) do
    original_sink = Keyword.get(opts, :event_sink) || Keyword.get(opts, :stage_sink)

    tracked_sink = fn event ->
      Elixir.Agent.update(tracker, &Map.put(&1, :last_event, event))

      if is_function(original_sink, 1) do
        original_sink.(event)
      end
    end

    opts
    |> Keyword.put(:event_sink, tracked_sink)
    |> Keyword.delete(:stage_sink)
  end

  defp last_tracked_event(nil), do: nil

  defp last_tracked_event(tracker) when is_pid(tracker) do
    Elixir.Agent.get(tracker, &Map.get(&1, :last_event), 100)
  catch
    _kind, _reason -> nil
  end

  defp parent_timeout_result(details, tracker, opts, objective) do
    last_event = last_tracked_event(tracker)

    if active_execution_event?(last_event) do
      result = blocked_timeout_result(objective, details, last_event)

      emit_stage(opts, :completed, :blocked, %{
        runtime_timeout: details,
        current_event: last_event
      })

      {:ok, result}
    else
      {:error,
       Error.timeout("RLM runtime budget exhausted",
         source: __MODULE__,
         details: details
       )}
    end
  end

  defp active_execution_event?(%{stage: stage}) do
    stage in [
      :node_started,
      :node_budget_selected,
      :child_budget_selected,
      :child_agent_started,
      :child_agent_progress,
      :child_agent_event,
      :child_noop_repair_started,
      :child_noop_repair_completed,
      :child_patch_repair_started,
      :child_patch_repair_completed,
      :child_agent_completed
    ]
  end

  defp active_execution_event?(_event), do: false

  defp blocked_timeout_result(objective, details, last_event) do
    timeout_message = "RLM runtime budget exhausted during active workflow execution"

    %{
      status: :blocked,
      output: timeout_message,
      trace: [
        %{
          status: :blocked,
          kind: :runtime_budget,
          node_id: get_in(last_event, [:data, :node_id])
        }
      ],
      episodes: [],
      context: %{
        runtime_timeout: details,
        last_event: last_event,
        repair_needs: [
          %{
            id: "runtime-budget-exhausted",
            reason: timeout_message,
            target: get_in(last_event, [:data, :node_id]),
            evidence: details
          }
        ]
      },
      objective: objective,
      objective_scorecard: nil
    }
  end

  defp completion_status(result) do
    cond do
      objective_satisfied?(result) ->
        :ok

      repair_needs?(result) ->
        :blocked

      failed_trace?(result) ->
        :blocked

      true ->
        scorecard_completion_status(result)
    end
  end

  defp objective_satisfied?(result) do
    result
    |> current_scorecard()
    |> case do
      nil ->
        false

      scorecard ->
        scorecard_field(scorecard, :objective_status) in [
          :objective_satisfied,
          "objective_satisfied"
        ]
    end
  end

  defp failed_trace?(result) do
    result
    |> Map.get(:trace, [])
    |> List.wrap()
    |> Enum.any?(fn trace ->
      map_field(trace, :status) in [:failed, "failed", :error, "error"]
    end)
  end

  defp scorecard_completion_status(result) do
    case current_scorecard(result) do
      nil ->
        :ok

      scorecard ->
        if scorecard_field(scorecard, :objective_status) in [
             :objective_satisfied,
             "objective_satisfied"
           ] do
          :ok
        else
          :blocked
        end
    end
  end

  defp current_scorecard(result),
    do: latest_scorecard(result) || Map.get(result, :objective_scorecard)

  defp repair_needs?(result) do
    result
    |> get_in([:context, :repair_needs])
    |> List.wrap()
    |> Enum.any?()
  end

  defp latest_scorecard(result) do
    result
    |> Map.get(:context, %{})
    |> Map.get(:scorecards, [])
    |> List.wrap()
    |> List.last()
  end

  defp scorecard_field(scorecard, key) when is_map(scorecard),
    do: Map.get(scorecard, key) || Map.get(scorecard, Atom.to_string(key))

  defp scorecard_field(_scorecard, _key), do: nil

  defp map_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_field(_map, _key), do: nil
end
