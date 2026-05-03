defmodule RunicAI.Persistence do
  @moduledoc """
  Facade for optional durable RunicAI persistence.

  Core RunicAI workflows do not require a durable store. Harnesses that want
  restartable runs, queryable traces, or eval data pass an explicit store handle
  to the persistence-aware APIs.
  """

  alias RunicAI.Error

  @type store :: term()

  @spec normalize_result(term(), module()) :: term()
  def normalize_result({:ok, _value} = result, _source), do: result
  def normalize_result(:ok, _source), do: :ok

  def normalize_result({:error, %Error{}} = result, _source), do: result

  def normalize_result({:error, reason}, source) do
    {:error,
     Error.from_reason(reason,
       kind: :persistence,
       message: "persistence operation failed",
       source: source
     )}
  end

  def normalize_result(other, source) do
    {:error,
     Error.from_reason(other,
       kind: :persistence,
       message: "unexpected persistence response",
       source: source
     )}
  end
end
