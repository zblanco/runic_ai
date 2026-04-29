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
    RuntimeBudget.run(fn -> run_unbounded(workspace_input, objective, opts) end,
      timeout_ms: Keyword.get(opts, :max_runtime_ms),
      stage: :rlm_agent_run,
      objective: objective
    )
  end

  defp run_unbounded(workspace_input, objective, opts) do
    run_id = Checkpoint.run_id(opts)

    opts =
      opts
      |> Keyword.put_new(:run_id, run_id)
      |> put_run_metadata(run_id, objective)

    with {:ok, environment} <- prepare(workspace_input, opts),
         persistence = environment.workspace.persistence,
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
         {:ok, proposal, report} <-
           Checkpoint.result(
             persistence,
             :proposal,
             fn -> Coordinator.propose(objective, environment, opts) end,
             run_id: run_id,
             input: %{objective: objective}
           ),
         {:ok, compiled} <-
           Checkpoint.result(
             persistence,
             :compiled,
             fn -> WorkflowCompiler.compile(proposal, environment, opts) end,
             run_id: run_id,
             proposal_id: proposal.id
           ),
         {:ok, execution} <-
           Checkpoint.result(
             persistence,
             :executed,
             fn ->
               WorkflowCompiler.run(proposal, environment, Keyword.get(opts, :input, %{}), opts)
             end,
             run_id: run_id,
             proposal_id: proposal.id
           ) do
      initial_result =
        Map.merge(execution, %{
          proposal: proposal,
          validation_report: report,
          compiled: compiled,
          codebase_environment: environment
        })
        |> ProgressGate.apply(opts)

      with {:ok, result} <- maybe_repair(initial_result, environment, opts) do
        result =
          if Keyword.get(opts, :persist?, not is_nil(environment.workspace.persistence)) do
            case Persistence.persist(result) do
              {:ok, ref} -> Map.put(result, :persistence_ref, ref)
              {:error, error} -> Map.put(result, :persistence_error, error)
            end
          else
            result
          end

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
end
