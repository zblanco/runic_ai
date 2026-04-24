defmodule RunicAI.Trace.Event do
  @moduledoc """
  Structured semantic trace event emitted during harness-driven execution.
  """

  alias RunicAI.Error

  @enforce_keys [:kind, :metadata]
  defstruct [
    :id,
    :trace_id,
    :parent_id,
    :sequence,
    :recipe,
    :component,
    :agent_id,
    :conversation_id,
    :kind,
    :status,
    :input,
    :output,
    measurements: %{},
    metadata: %{},
    observed_at: nil
  ]

  @type ref_value :: atom() | String.t() | module() | nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          trace_id: String.t() | nil,
          parent_id: String.t() | nil,
          sequence: pos_integer() | nil,
          recipe: ref_value(),
          component: ref_value(),
          agent_id: String.t() | nil,
          conversation_id: String.t() | nil,
          kind: atom(),
          status: atom() | String.t() | nil,
          input: term(),
          output: term(),
          measurements: map(),
          metadata: map(),
          observed_at: DateTime.t() | nil
        }

  @spec new(atom() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    measurements = Keyword.get(opts, :measurements, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_kind} <- normalize_kind(kind),
         :ok <- validate_ref(Keyword.get(opts, :recipe), :recipe),
         :ok <- validate_ref(Keyword.get(opts, :component), :component),
         :ok <- validate_id(Keyword.get(opts, :id), :id),
         :ok <- validate_id(Keyword.get(opts, :trace_id), :trace_id),
         :ok <- validate_id(Keyword.get(opts, :parent_id), :parent_id),
         :ok <- validate_sequence(Keyword.get(opts, :sequence)),
         :ok <- validate_string(Keyword.get(opts, :agent_id), :agent_id),
         :ok <- validate_string(Keyword.get(opts, :conversation_id), :conversation_id),
         :ok <- validate_status(Keyword.get(opts, :status)),
         :ok <- validate_map(measurements, :measurements),
         :ok <- validate_map(metadata, :metadata),
         :ok <- validate_observed_at(Keyword.get(opts, :observed_at)) do
      {:ok,
       %__MODULE__{
         id: Keyword.get(opts, :id),
         trace_id: Keyword.get(opts, :trace_id),
         parent_id: Keyword.get(opts, :parent_id),
         sequence: Keyword.get(opts, :sequence),
         recipe: Keyword.get(opts, :recipe),
         component: Keyword.get(opts, :component),
         agent_id: Keyword.get(opts, :agent_id),
         conversation_id: Keyword.get(opts, :conversation_id),
         kind: normalized_kind,
         status: Keyword.get(opts, :status),
         input: Keyword.get(opts, :input),
         output: Keyword.get(opts, :output),
         measurements: measurements,
         metadata: metadata,
         observed_at: Keyword.get(opts, :observed_at)
       }}
    end
  end

  @spec new!(atom() | String.t(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, event} -> event
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = event) do
    new(event.kind,
      id: event.id,
      trace_id: event.trace_id,
      parent_id: event.parent_id,
      sequence: event.sequence,
      recipe: event.recipe,
      component: event.component,
      agent_id: event.agent_id,
      conversation_id: event.conversation_id,
      status: event.status,
      input: event.input,
      output: event.output,
      measurements: event.measurements,
      metadata: event.metadata,
      observed_at: event.observed_at
    )
  end

  @spec assign(t(), String.t(), pos_integer(), String.t() | nil) :: t()
  def assign(%__MODULE__{} = event, trace_id, sequence, parent_id \\ nil)
      when is_binary(trace_id) and is_integer(sequence) and sequence > 0 do
    %__MODULE__{
      event
      | id: event.id || default_event_id(trace_id, sequence),
        trace_id: trace_id,
        sequence: sequence,
        parent_id: parent_id || event.parent_id,
        observed_at: event.observed_at || DateTime.utc_now()
    }
  end

  defp normalize_kind(kind) when is_atom(kind), do: {:ok, kind}

  defp normalize_kind(kind) when is_binary(kind) and kind != "" do
    {:ok, String.to_atom(kind)}
  end

  defp normalize_kind(kind) do
    {:error,
     Error.validation("trace event kind must be an atom or non-empty string",
       source: __MODULE__,
       details: %{kind: kind}
     )}
  end

  defp validate_ref(nil, _field), do: :ok
  defp validate_ref(value, _field) when is_atom(value) or is_binary(value), do: :ok

  defp validate_ref(value, _field) when is_atom(value) do
    :ok
  end

  defp validate_ref(value, field) do
    {:error,
     Error.validation("trace event #{field} must be an atom, module, string, or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_id(nil, _field), do: :ok
  defp validate_id(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_id(value, field) do
    {:error,
     Error.validation("trace event #{field} must be a non-empty string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_sequence(nil), do: :ok
  defp validate_sequence(value) when is_integer(value) and value > 0, do: :ok

  defp validate_sequence(value) do
    {:error,
     Error.validation("trace event sequence must be a positive integer or nil",
       source: __MODULE__,
       details: %{sequence: value}
     )}
  end

  defp validate_string(nil, _field), do: :ok
  defp validate_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_string(value, field) do
    {:error,
     Error.validation("trace event #{field} must be a non-empty string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_status(nil), do: :ok
  defp validate_status(status) when is_atom(status) or is_binary(status), do: :ok

  defp validate_status(status) do
    {:error,
     Error.validation("trace event status must be an atom, string, or nil",
       source: __MODULE__,
       details: %{status: status}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("trace event #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_observed_at(nil), do: :ok
  defp validate_observed_at(%DateTime{}), do: :ok

  defp validate_observed_at(value) do
    {:error,
     Error.validation("trace event observed_at must be a DateTime or nil",
       source: __MODULE__,
       details: %{observed_at: value}
     )}
  end

  defp default_event_id(trace_id, sequence), do: "#{trace_id}:#{sequence}"
end
