defmodule RunicAI.Steps.ResolveIntegratedResume do
  @moduledoc """
  Resolve an integrated wait pause from a resume or wake signal.
  """

  require Runic

  alias RunicAI.Error
  alias RunicAI.Integrated.PendingWork
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Integrated.Signal
  alias RunicAI.ResumeSignal
  alias RunicAI.Steps.NormalizeResumeSignal
  alias RunicAI.Wait

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :resolve_integrated_resume)

    Runic.step(
      fn bundle ->
        resolve!(bundle)
      end,
      name: name
    )
  end

  @spec resolve(map()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(%{session: %SessionState{} = session, signal: %Signal{} = signal} = bundle) do
    with %PendingWork{request: %Wait{} = wait} <- session.pending_work,
         {^signal, dequeued_session} <- SessionState.dequeue_signal!(session),
         {:ok, payload} <- resolve_payload(wait, signal) do
      {:ok,
       Map.merge(bundle, %{
         session: SessionState.clear_pending_work!(dequeued_session, status: :idle),
         resolved: payload,
         wait: wait
       })}
    else
      nil ->
        {:error,
         Error.validation("integrated resume resolution requires a pending wait",
           source: __MODULE__,
           details: %{bundle: bundle}
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  def resolve(other) do
    {:error,
     Error.validation("resolve_integrated_resume expects a ready-agent bundle",
       source: __MODULE__,
       details: %{bundle: other}
     )}
  end

  @spec resolve!(map()) :: map()
  def resolve!(bundle) do
    case resolve(bundle) do
      {:ok, resolved_bundle} -> resolved_bundle
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp resolve_payload(%Wait{} = wait, %Signal{kind: :resume, payload: payload}) do
    payload
    |> ResumeSignal.from_input()
    |> case do
      {:ok, resume_signal} -> NormalizeResumeSignal.normalize(wait, resume_signal)
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_payload(%Wait{} = wait, %Signal{kind: :wake}) do
    {:ok, Map.get(wait.payload || %{}, :subject, wait.payload)}
  end

  defp resolve_payload(%Wait{} = _wait, %Signal{} = signal) do
    {:error,
     Error.validation("integrated resume resolution requires a :resume or :wake signal",
       source: __MODULE__,
       details: %{signal: signal}
     )}
  end
end
