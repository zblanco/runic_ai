defmodule RunicAI.Steps.ApplyReviewDecision do
  @moduledoc """
  Apply an operator review decision back to a pending review request.
  """

  require Runic

  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Error
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :apply_review_decision)

    Runic.step(
      fn %ReviewRequest{} = review_request, %ReviewDecision{} = review_decision ->
        apply_decision!(review_request, review_decision)
      end,
      name: name
    )
  end

  @spec apply_decision(ReviewRequest.t(), ReviewDecision.t()) ::
          {:ok, term()} | {:error, Error.t()}
  def apply_decision(%ReviewRequest{} = review_request, %ReviewDecision{} = review_decision) do
    with {:ok, review_request} <- ReviewRequest.validate(review_request),
         {:ok, review_decision} <- ReviewDecision.validate(review_decision),
         :ok <- validate_resume_key(review_request, review_decision) do
      case review_decision.status do
        :approved ->
          {:ok, review_request.subject}

        :edited ->
          {:ok, review_decision.edited_value}

        :rejected ->
          {:ok,
           ContinueDecision.halt!(:review_rejected,
             metadata: %{
               checkpoint: review_request.checkpoint,
               resume_key: review_request.resume_key
             }
           )}

        :cancelled ->
          {:ok,
           ContinueDecision.stop!(:review_cancelled,
             metadata: %{
               checkpoint: review_request.checkpoint,
               resume_key: review_request.resume_key
             }
           )}
      end
    end
  end

  @spec apply_decision!(ReviewRequest.t(), ReviewDecision.t()) :: term()
  def apply_decision!(%ReviewRequest{} = review_request, %ReviewDecision{} = review_decision) do
    case apply_decision(review_request, review_decision) do
      {:ok, resolved_value} -> resolved_value
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_resume_key(%ReviewRequest{resume_key: resume_key}, %ReviewDecision{
         resume_key: resume_key
       }),
       do: :ok

  defp validate_resume_key(%ReviewRequest{} = review_request, %ReviewDecision{} = review_decision) do
    {:error,
     Error.validation("review decision resume_key did not match the request",
       source: __MODULE__,
       details: %{request: review_request.resume_key, decision: review_decision.resume_key}
     )}
  end
end
