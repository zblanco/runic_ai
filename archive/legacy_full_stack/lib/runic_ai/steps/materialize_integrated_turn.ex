defmodule RunicAI.Steps.MaterializeIntegratedTurn do
  @moduledoc """
  Project one queued integrated lane into an ordinary `Agent.TurnRequest`.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Error
  alias RunicAI.Integrated.PendingWork
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Integrated.Signal

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :materialize_integrated_turn)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn bundle ->
        materialize!(bundle, options)
      end,
      name: name
    )
  end

  @spec materialize(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def materialize(
        %{agent_id: agent_id, session: %SessionState{} = session, signal: %Signal{} = signal},
        opts
      )
      when is_binary(agent_id) and is_list(opts) do
    with true <-
           Signal.turn_signal?(signal) or
             {:error,
              Error.validation("integrated turn materialization requires a turn signal",
                source: __MODULE__,
                details: %{signal: signal}
              )},
         {^signal, dequeued_session} <- SessionState.dequeue_signal!(session),
         {:ok, turn_request} <- build_turn_request(dequeued_session, signal, opts),
         {:ok, running_session} <- prepare_running_session(dequeued_session, signal) do
      {:ok,
       %{
         agent_id: agent_id,
         session: running_session,
         signal: signal,
         turn_request: turn_request
       }}
    else
      {:error, error} -> {:error, error}
    end
  end

  def materialize(other, _opts) do
    {:error,
     Error.validation("materialize_integrated_turn expects a ready-agent bundle",
       source: __MODULE__,
       details: %{bundle: other}
     )}
  end

  @spec materialize!(map(), keyword()) :: map()
  def materialize!(bundle, opts \\ []) do
    case materialize(bundle, opts) do
      {:ok, materialized} -> materialized
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp build_turn_request(%SessionState{} = session, %Signal{} = signal, opts) do
    defaults =
      session.metadata
      |> Map.get(:turn_defaults, %{})
      |> Map.merge(Enum.into(opts, %{}))

    TurnRequest.new(session.agent_state,
      input_message: payload_input_message(signal.payload),
      history_window: Map.get(defaults, :history_window, :all),
      pinned_messages: Map.get(defaults, :pinned_messages, []),
      observations: Map.get(defaults, :observations, []),
      model: Map.fetch!(defaults, :model),
      llm_opts: Map.get(defaults, :llm_opts, []),
      metadata: Map.get(defaults, :metadata, %{})
    )
  end

  defp prepare_running_session(%SessionState{} = session, %Signal{} = signal) do
    pending_work =
      PendingWork.new!(
        :turn,
        request: signal,
        checkpoint: signal.kind,
        metadata: %{correlation_id: signal.correlation_id}
      )

    {:ok, SessionState.with_pending_work!(session, pending_work, status: :running)}
  end

  defp payload_input_message(nil), do: nil
  defp payload_input_message(%{input_message: input_message}), do: input_message
  defp payload_input_message(%{"input_message" => input_message}), do: input_message
  defp payload_input_message(%{user: input_message}), do: input_message
  defp payload_input_message(%{"user" => input_message}), do: input_message
  defp payload_input_message(payload), do: payload
end
