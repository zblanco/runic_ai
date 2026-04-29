defmodule RunicAI.Coding.RLM.Checkpoint do
  @moduledoc """
  Checkpoint helpers for RLM coding runs.

  Checkpoints are persisted through `RunicAI.Coding.Persistence`, so callers can
  choose the development ETS/in-memory stores or the optional SQLite adapter.
  The checkpoint payloads are ordinary artifacts plus searchable events; they
  are intentionally separate from workflow execution so bounded timeouts still
  leave useful partial evidence behind.
  """

  alias RunicAI.Coding.Persistence
  alias RunicAI.Error

  @spec run_id(keyword()) :: String.t()
  def run_id(opts) when is_list(opts) do
    Keyword.get(opts, :run_id) ||
      get_in(Keyword.get(opts, :metadata, %{}), [:run_id]) ||
      "rlm-coding-run:#{System.unique_integer([:positive])}"
  end

  @spec record(term(), atom(), map(), keyword()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def record(persistence, stage, payload, opts \\ [])
      when is_atom(stage) and is_map(payload) and is_list(opts) do
    checkpoint = %{
      kind: :rlm_coding_checkpoint,
      id: Keyword.get(opts, :id) || checkpoint_id(stage),
      run_id: Keyword.get(opts, :run_id),
      stage: stage,
      status: Keyword.get(opts, :status, Map.get(payload, :status, :completed)),
      proposal_id: Keyword.get(opts, :proposal_id) || field(Map.get(payload, :proposal), :id),
      node_id: Keyword.get(opts, :node_id) || Map.get(payload, :node_id),
      content: payload,
      metadata: Keyword.get(opts, :metadata, %{}),
      stored_at: DateTime.utc_now()
    }

    with {:ok, ref} <- Persistence.put_artifact(persistence, checkpoint),
         :ok <- Persistence.record_event(persistence, event(checkpoint, ref)) do
      {:ok, ref}
    end
  end

  @spec record_best_effort(term(), atom(), map(), keyword()) :: String.t() | nil
  def record_best_effort(persistence, stage, payload, opts \\ []) do
    case record(persistence, stage, payload, opts) do
      {:ok, ref} -> ref
      {:error, _error} -> nil
    end
  end

  @spec result(term(), atom(), (-> tuple()), keyword()) :: tuple()
  def result(persistence, stage, fun, opts \\ [])
      when is_atom(stage) and is_function(fun, 0) and is_list(opts) do
    _started_ref =
      record_best_effort(
        persistence,
        stage,
        %{status: :started, input: Keyword.get(opts, :input)},
        Keyword.put(opts, :status, :started)
      )

    case fun.() do
      ok when is_tuple(ok) and tuple_size(ok) >= 1 and elem(ok, 0) == :ok ->
        _completed_ref =
          record_best_effort(
            persistence,
            stage,
            %{status: :completed, result: ok},
            Keyword.put(opts, :status, :completed)
          )

        ok

      {:error, %Error{} = error} = failed ->
        _failed_ref =
          record_best_effort(
            persistence,
            stage,
            %{status: :failed, error: error},
            Keyword.put(opts, :status, :failed)
          )

        failed
    end
  end

  defp event(checkpoint, ref) do
    %{
      kind: :rlm_coding_checkpoint,
      artifact_ref: ref,
      run_id: checkpoint.run_id,
      stage: checkpoint.stage,
      status: checkpoint.status,
      proposal_id: checkpoint.proposal_id,
      node_id: checkpoint.node_id,
      metadata: checkpoint.metadata
    }
  end

  defp checkpoint_id(stage) do
    "rlm-checkpoint:#{stage}:#{System.unique_integer([:positive])}"
  end

  defp field(nil, _key), do: nil
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
