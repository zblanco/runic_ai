defmodule RunicAI.Coding.RLM.Persistence do
  @moduledoc """
  Snapshot persistence helpers for RLM coding runs.
  """

  alias RunicAI.Coding.Persistence, as: CodingPersistence
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Error

  @spec snapshot(map()) :: map()
  def snapshot(result) when is_map(result) do
    environment = Map.get(result, :codebase_environment)

    %{
      kind: :rlm_coding_run,
      source_index: source_index(environment),
      proposal: Map.get(result, :proposal),
      validation_report: Map.get(result, :validation_report),
      compiled_metadata: get_in(result, [:compiled, :metadata]),
      episodes: Map.get(result, :episodes, []),
      output: Map.get(result, :output),
      trace: Map.get(result, :trace, []),
      scorecards: get_in(result, [:context, :scorecards]) || [],
      objective_contract: get_in(result, [:context, :objective_contract]),
      objective_judgements: get_in(result, [:context, :objective_judgements]) || [],
      objective_evidence_summaries:
        get_in(result, [:context, :objective_evidence_summaries]) || [],
      repair_history: Map.get(result, :repair_history, []),
      checkpoint_refs: get_in(result, [:context, :checkpoint_refs]) || [],
      stored_at: DateTime.utc_now()
    }
  end

  @spec persist(map()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def persist(result) when is_map(result) do
    persistence =
      result
      |> Map.get(:codebase_environment)
      |> workspace_persistence()

    artifact = snapshot(result)

    with {:ok, ref} <- CodingPersistence.put_artifact(persistence, artifact),
         :ok <-
           CodingPersistence.record_event(persistence, %{
             kind: :rlm_coding_run_persisted,
             artifact_ref: ref,
             proposal_id: get_in(result, [:proposal, Access.key(:id)])
           }) do
      {:ok, ref}
    end
  end

  @spec search(nil | {module(), term()} | module(), String.t() | nil) ::
          {:ok, [map()]} | {:error, Error.t()}
  def search(nil, _query), do: {:ok, []}

  def search({RunicAI.Coding.Persistence.InMemory, handle}, query) when is_pid(handle) do
    results =
      handle
      |> RunicAI.Coding.Persistence.InMemory.artifacts()
      |> Enum.filter(&matches_query?(&1, query))

    {:ok, results}
  end

  def search(_persistence, _query) do
    {:error,
     Error.validation("RLM coding session search requires searchable persistence",
       source: __MODULE__
     )}
  end

  @spec replay(map()) :: {:ok, map()} | {:error, Error.t()}
  def replay(%{kind: :rlm_coding_run} = snapshot) do
    trace = Map.get(snapshot, :trace, [])
    episodes = Map.get(snapshot, :episodes, [])

    {:ok,
     %{
       status: :replayed,
       proposal: Map.get(snapshot, :proposal),
       validation_report: Map.get(snapshot, :validation_report),
       output: Map.get(snapshot, :output),
       scorecards: Map.get(snapshot, :scorecards, []),
       objective_contract: Map.get(snapshot, :objective_contract),
       objective_judgements: Map.get(snapshot, :objective_judgements, []),
       objective_evidence_summaries: Map.get(snapshot, :objective_evidence_summaries, []),
       repair_history: Map.get(snapshot, :repair_history, []),
       checkpoint_refs: Map.get(snapshot, :checkpoint_refs, []),
       source_index: Map.get(snapshot, :source_index, []),
       trace: trace,
       episodes: episodes,
       node_ids: Enum.map(trace, &Map.get(&1, :node_id)),
       artifact_count: count_artifacts(episodes)
     }}
  end

  def replay(snapshot) do
    {:error,
     Error.validation("expected an RLM coding run snapshot",
       source: __MODULE__,
       details: %{snapshot: snapshot}
     )}
  end

  defp source_index(%CodebaseEnvironment{} = environment),
    do: CodebaseEnvironment.source_summaries(environment, 10_000)

  defp source_index(_environment), do: []

  defp workspace_persistence(%CodebaseEnvironment{} = environment),
    do: environment.workspace.persistence

  defp workspace_persistence(_environment), do: nil

  defp matches_query?(artifact, nil), do: rlm_run_snapshot?(artifact)
  defp matches_query?(artifact, ""), do: rlm_run_snapshot?(artifact)

  defp matches_query?(artifact, query) when is_binary(query) do
    rlm_run_snapshot?(artifact) and
      artifact
      |> inspect(limit: :infinity, printable_limit: :infinity)
      |> String.contains?(query)
  end

  defp rlm_run_snapshot?(artifact),
    do: Map.get(artifact, :kind, Map.get(artifact, "kind")) == :rlm_coding_run

  defp count_artifacts(episodes) do
    Enum.reduce(episodes, 0, fn
      %{artifacts: artifacts}, count when is_list(artifacts) -> count + length(artifacts)
      %{"artifacts" => artifacts}, count when is_list(artifacts) -> count + length(artifacts)
      _episode, count -> count
    end)
  end
end
