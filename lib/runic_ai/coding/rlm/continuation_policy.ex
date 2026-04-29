defmodule RunicAI.Coding.RLM.ContinuationPolicy do
  @moduledoc """
  Continuation decisions for recursive RLM coding episodes.
  """

  alias RunicAI.RLM.Episode
  alias RunicAI.RLM.Plan
  alias RunicAI.RLM.PlanPatch
  alias RunicAI.Coding.RLM.PlanPatchValidator
  alias RunicAI.Coding.RLM.WorkflowValidationReport

  @type decision ::
          {:finish, Episode.t()}
          | {:continue, Episode.t(), PlanPatch.t(), WorkflowValidationReport.t()}
          | {:blocked, Episode.t(), WorkflowValidationReport.t()}
          | {:failed, Episode.t()}

  @spec decide(Episode.t(), Plan.t() | nil, keyword()) :: decision()
  def decide(%Episode{} = episode, plan \\ nil, opts \\ []) when is_list(opts) do
    case episode.status do
      :satisfied ->
        {:finish, episode}

      :failed ->
        {:failed, episode}

      :blocked ->
        {:blocked, episode, WorkflowValidationReport.reject([])}

      status when status in [:partial, :extended] ->
        decide_continuation(episode, plan, opts)
    end
  end

  defp decide_continuation(
         %Episode{continuation: %{next: %PlanPatch{} = patch}} = episode,
         plan,
         opts
       ) do
    report = PlanPatchValidator.validate(patch, plan, opts)

    if WorkflowValidationReport.accepted?(report) do
      {:continue, episode, patch, report}
    else
      {:blocked, episode, report}
    end
  end

  defp decide_continuation(%Episode{continuation: %PlanPatch{} = patch} = episode, plan, opts) do
    report = PlanPatchValidator.validate(patch, plan, opts)

    if WorkflowValidationReport.accepted?(report) do
      {:continue, episode, patch, report}
    else
      {:blocked, episode, report}
    end
  end

  defp decide_continuation(%Episode{} = episode, _plan, _opts) do
    {:blocked, episode, WorkflowValidationReport.reject([])}
  end
end
