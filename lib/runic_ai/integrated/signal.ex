defmodule RunicAI.Integrated.Signal do
  @moduledoc """
  Normalized envelope for external input and internal runtime events.
  """

  alias RunicAI.Error
  alias RunicAI.Message
  alias RunicAI.ResumeSignal
  alias RunicAI.ReviewDecision

  @valid_kinds [:start, :receive_turn, :continue, :review_decision, :resume, :wake, :spawn, :stop]

  @enforce_keys [:kind, :metadata]
  defstruct [:kind, :agent_id, :payload, :correlation_id, :scheduled_for, metadata: %{}]

  @type kind ::
          :start
          | :receive_turn
          | :continue
          | :review_decision
          | :resume
          | :wake
          | :spawn
          | :stop

  @type t :: %__MODULE__{
          kind: kind(),
          agent_id: String.t() | nil,
          payload: term(),
          correlation_id: String.t() | nil,
          scheduled_for: DateTime.t() | nil,
          metadata: map()
        }

  @spec new(kind() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_kind} <- normalize_kind(kind),
         {:ok, agent_id} <- normalize_agent_id(Keyword.get(opts, :agent_id)),
         :ok <- validate_correlation_id(Keyword.get(opts, :correlation_id)),
         :ok <- validate_scheduled_for(Keyword.get(opts, :scheduled_for)),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         kind: normalized_kind,
         agent_id: agent_id,
         payload: Keyword.get(opts, :payload),
         correlation_id: Keyword.get(opts, :correlation_id),
         scheduled_for: Keyword.get(opts, :scheduled_for),
         metadata: metadata
       }}
    end
  end

  @spec new!(kind() | String.t(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, signal} -> signal
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = signal) do
    new(signal.kind,
      agent_id: signal.agent_id,
      payload: signal.payload,
      correlation_id: signal.correlation_id,
      scheduled_for: signal.scheduled_for,
      metadata: signal.metadata
    )
  end

  @spec from_input(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = signal, _opts), do: validate(signal)

  def from_input(%ReviewDecision{} = review_decision, opts) when is_list(opts) do
    new(:review_decision,
      agent_id: Keyword.get(opts, :agent_id),
      payload: review_decision,
      correlation_id: Keyword.get(opts, :correlation_id),
      scheduled_for: Keyword.get(opts, :scheduled_for),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def from_input(%ResumeSignal{} = resume_signal, opts) when is_list(opts) do
    new(:resume,
      agent_id: Keyword.get(opts, :agent_id),
      payload: resume_signal,
      correlation_id: Keyword.get(opts, :correlation_id),
      scheduled_for: Keyword.get(opts, :scheduled_for),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def from_input(%Message{role: :user} = message, opts) when is_list(opts) do
    new(Keyword.get(opts, :default_kind, :receive_turn),
      agent_id: Keyword.get(opts, :agent_id),
      payload: message,
      correlation_id: Keyword.get(opts, :correlation_id),
      scheduled_for: Keyword.get(opts, :scheduled_for),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def from_input(message, opts) when is_binary(message) and is_list(opts) do
    new(Keyword.get(opts, :default_kind, :receive_turn),
      agent_id: Keyword.get(opts, :agent_id),
      payload: message,
      correlation_id: Keyword.get(opts, :correlation_id),
      scheduled_for: Keyword.get(opts, :scheduled_for),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  def from_input(input, opts) when is_map(input) and is_list(opts) do
    cond do
      Map.has_key?(input, :kind) or Map.has_key?(input, "kind") ->
        build_from_kind_map(input, opts)

      Map.has_key?(input, :review_decision) or Map.has_key?(input, "review_decision") ->
        input
        |> fetch_map_value(:review_decision)
        |> ReviewDecision.from_input()
        |> case do
          {:ok, review_decision} -> from_input(review_decision, map_signal_opts(input, opts))
          {:error, error} -> {:error, error}
        end

      Map.has_key?(input, :resume_signal) or Map.has_key?(input, "resume_signal") ->
        input
        |> fetch_map_value(:resume_signal)
        |> ResumeSignal.from_input()
        |> case do
          {:ok, resume_signal} -> from_input(resume_signal, map_signal_opts(input, opts))
          {:error, error} -> {:error, error}
        end

      Map.has_key?(input, :resume) or Map.has_key?(input, "resume") ->
        input
        |> fetch_map_value(:resume)
        |> ResumeSignal.from_input()
        |> case do
          {:ok, resume_signal} -> from_input(resume_signal, map_signal_opts(input, opts))
          {:error, error} -> {:error, error}
        end

      Map.has_key?(input, :wake) or Map.has_key?(input, "wake") ->
        new(:wake,
          agent_id:
            Map.get(input, :agent_id) || Map.get(input, "agent_id") ||
              Keyword.get(opts, :agent_id),
          payload: fetch_map_value(input, :wake),
          correlation_id:
            Map.get(input, :correlation_id) || Map.get(input, "correlation_id") ||
              Keyword.get(opts, :correlation_id),
          scheduled_for:
            Map.get(input, :scheduled_for) || Map.get(input, "scheduled_for") ||
              Keyword.get(opts, :scheduled_for),
          metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
        )

      turn_payload = turn_payload(input) ->
        new(Keyword.get(opts, :default_kind, :receive_turn),
          agent_id:
            Map.get(input, :agent_id) || Map.get(input, "agent_id") ||
              Keyword.get(opts, :agent_id),
          payload: turn_payload,
          correlation_id:
            Map.get(input, :correlation_id) || Map.get(input, "correlation_id") ||
              Keyword.get(opts, :correlation_id),
          scheduled_for:
            Map.get(input, :scheduled_for) || Map.get(input, "scheduled_for") ||
              Keyword.get(opts, :scheduled_for),
          metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
        )

      true ->
        {:error,
         Error.validation("expected an Integrated.Signal-compatible input",
           source: __MODULE__,
           details: %{input: input}
         )}
    end
  end

  def from_input(other, _opts) do
    {:error,
     Error.validation("expected an Integrated.Signal-compatible input, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(term(), keyword()) :: t()
  def from_input!(input, opts \\ []) do
    case from_input(input, opts) do
      {:ok, signal} -> signal
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec turn_signal?(t()) :: boolean()
  def turn_signal?(%__MODULE__{kind: kind}), do: kind in [:start, :receive_turn, :continue]

  @spec resume_key(t()) :: String.t() | nil
  def resume_key(%__MODULE__{} = signal) do
    cond do
      is_binary(Map.get(signal.metadata, :resume_key)) ->
        Map.get(signal.metadata, :resume_key)

      match?(%ResumeSignal{}, signal.payload) ->
        signal.payload.resume_key

      match?(%ReviewDecision{}, signal.payload) ->
        signal.payload.resume_key

      is_map(signal.payload) ->
        Map.get(signal.payload, :resume_key) || Map.get(signal.payload, "resume_key")

      true ->
        nil
    end
  end

  defp build_from_kind_map(input, opts) do
    new(fetch_map_value(input, :kind),
      agent_id:
        Map.get(input, :agent_id) || Map.get(input, "agent_id") || Keyword.get(opts, :agent_id),
      payload: fetch_map_value(input, :payload),
      correlation_id:
        Map.get(input, :correlation_id) || Map.get(input, "correlation_id") ||
          Keyword.get(opts, :correlation_id),
      scheduled_for:
        Map.get(input, :scheduled_for) || Map.get(input, "scheduled_for") ||
          Keyword.get(opts, :scheduled_for),
      metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
    )
  end

  defp map_signal_opts(input, opts) do
    [
      agent_id:
        Map.get(input, :agent_id) || Map.get(input, "agent_id") || Keyword.get(opts, :agent_id),
      correlation_id:
        Map.get(input, :correlation_id) || Map.get(input, "correlation_id") ||
          Keyword.get(opts, :correlation_id),
      scheduled_for:
        Map.get(input, :scheduled_for) || Map.get(input, "scheduled_for") ||
          Keyword.get(opts, :scheduled_for),
      metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
    ]
  end

  defp fetch_map_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp turn_payload(input) do
    Map.get(input, :input_message) ||
      Map.get(input, "input_message") ||
      Map.get(input, :user) ||
      Map.get(input, "user") ||
      Map.get(input, :message) ||
      Map.get(input, "message")
  end

  defp normalize_kind(kind) when kind in @valid_kinds, do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) do
    case Enum.find(@valid_kinds, &(Atom.to_string(&1) == kind)) do
      nil ->
        {:error,
         Error.validation("invalid integrated signal kind: #{inspect(kind)}",
           source: __MODULE__,
           details: %{kind: kind, valid_kinds: @valid_kinds}
         )}

      normalized_kind ->
        {:ok, normalized_kind}
    end
  end

  defp normalize_kind(kind) do
    {:error,
     Error.validation("invalid integrated signal kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp normalize_agent_id(nil), do: {:ok, nil}

  defp normalize_agent_id(agent_id) when is_binary(agent_id) and agent_id != "",
    do: {:ok, agent_id}

  defp normalize_agent_id(agent_id) when is_atom(agent_id), do: {:ok, Atom.to_string(agent_id)}

  defp normalize_agent_id(agent_id) do
    {:error,
     Error.validation("integrated signal agent_id must be a non-empty string, atom, or nil",
       source: __MODULE__,
       details: %{agent_id: agent_id}
     )}
  end

  defp validate_correlation_id(nil), do: :ok
  defp validate_correlation_id(correlation_id) when is_binary(correlation_id), do: :ok

  defp validate_correlation_id(correlation_id) do
    {:error,
     Error.validation("integrated signal correlation_id must be a string or nil",
       source: __MODULE__,
       details: %{correlation_id: correlation_id}
     )}
  end

  defp validate_scheduled_for(nil), do: :ok
  defp validate_scheduled_for(%DateTime{}), do: :ok

  defp validate_scheduled_for(scheduled_for) do
    {:error,
     Error.validation("integrated signal scheduled_for must be a DateTime or nil",
       source: __MODULE__,
       details: %{scheduled_for: scheduled_for}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("integrated signal metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
