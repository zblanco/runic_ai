defmodule RunicAI.Coding.RLM do
  @moduledoc """
  Facade for the RLM-inspired coding agent.
  """

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Coding.RLM.Evals

  defdelegate prepare(workspace_input, opts \\ []), to: Agent
  defdelegate prepare!(workspace_input, opts \\ []), to: Agent
  defdelegate propose(objective, environment, opts \\ []), to: Agent
  defdelegate compile(proposal, environment, opts \\ []), to: Agent
  defdelegate run(workspace_input, objective, opts \\ []), to: Agent
  defdelegate run!(workspace_input, objective, opts \\ []), to: Agent
  defdelegate validate(proposal, opts \\ []), to: Agent
  defdelegate search_sessions(persistence, query \\ nil), to: Agent
  defdelegate replay_session(snapshot), to: Agent
  defdelegate codex_events_to_artifacts(jsonl), to: Agent

  @spec eval_cases(keyword()) :: [map()]
  def eval_cases(opts \\ []), do: Evals.cases(opts)

  @spec run_evals([map()], keyword()) :: map()
  def run_evals(cases, opts \\ []), do: Evals.run(cases, opts)
end
