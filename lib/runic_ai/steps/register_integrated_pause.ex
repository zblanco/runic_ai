defmodule RunicAI.Steps.RegisterIntegratedPause do
  @moduledoc """
  Register a wait or review pause back into an integrated session.
  """

  require Runic

  alias RunicAI.Error
  alias RunicAI.Integrated.Emission
  alias RunicAI.Integrated.PendingWork
  alias RunicAI.Integrated.SessionState
  alias RunicAI.ReviewRequest
  alias RunicAI.Wait

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :register_integrated_pause)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %SessionState{} = session, request ->
        register!(session, request, options)
      end,
      name: name
    )
  end

  @spec register(SessionState.t(), ReviewRequest.t() | Wait.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def register(session, request, opts \\ [])

  def register(%SessionState{} = session, %ReviewRequest{} = review_request, opts) do
    pending_work =
      PendingWork.new!(
        :review,
        request: review_request,
        checkpoint: review_request.checkpoint,
        resume_key: review_request.resume_key,
        metadata: Keyword.get(opts, :metadata, %{})
      )

    {:ok,
     %{
       session: SessionState.with_pending_work!(session, pending_work, status: :review),
       emissions: [Emission.new!(session.agent.id, :review, value: review_request)]
     }}
  end

  def register(%SessionState{} = session, %Wait{} = wait, opts) do
    pending_work =
      PendingWork.new!(
        :wait,
        request: wait,
        checkpoint:
          Map.get(wait.metadata, :checkpoint) ||
            Map.get(wait.metadata, "checkpoint") ||
            Map.get(wait.metadata, :guard_point) ||
            Map.get(wait.metadata, "guard_point"),
        resume_key: wait.resume_key,
        metadata: Keyword.get(opts, :metadata, %{})
      )

    {:ok,
     %{
       session: SessionState.with_pending_work!(session, pending_work, status: :waiting),
       emissions: [Emission.new!(session.agent.id, :wait, value: wait)]
     }}
  end

  def register(%SessionState{} = session, other, _opts) do
    {:error,
     Error.validation("integrated pause registration expects a ReviewRequest or Wait",
       source: __MODULE__,
       details: %{agent_id: session.agent.id, request: other}
     )}
  end

  @spec register!(SessionState.t(), ReviewRequest.t() | Wait.t(), keyword()) :: map()
  def register!(%SessionState{} = session, request, opts \\ []) do
    case register(session, request, opts) do
      {:ok, update} -> update
      {:error, error} -> raise ArgumentError, error.message
    end
  end
end
