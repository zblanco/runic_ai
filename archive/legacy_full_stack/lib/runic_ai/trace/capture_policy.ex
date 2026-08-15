defmodule RunicAI.Trace.CapturePolicy do
  @moduledoc """
  Controls how trace payloads are captured and summarized.
  """

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Error
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Message
  alias RunicAI.Prompt
  alias RunicAI.ReviewRequest
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Wait

  @valid_modes [:summary, :full, :replay]

  @enforce_keys [:mode, :metadata]
  defstruct mode: :summary,
            include_raw_payloads: false,
            redactor: nil,
            include_measurements: true,
            include_component_outputs: false,
            max_payload_bytes: 4_096,
            metadata: %{}

  @type mode :: :summary | :full | :replay

  @type t :: %__MODULE__{
          mode: mode(),
          include_raw_payloads: boolean(),
          redactor: nil | function(),
          include_measurements: boolean(),
          include_component_outputs: boolean(),
          max_payload_bytes: pos_integer(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :summary)
    metadata = Keyword.get(opts, :metadata, %{})
    max_payload_bytes = Keyword.get(opts, :max_payload_bytes, 4_096)

    with :ok <- validate_mode(mode),
         :ok <-
           validate_boolean(
             Keyword.get(opts, :include_raw_payloads, false),
             :include_raw_payloads
           ),
         :ok <- validate_redactor(Keyword.get(opts, :redactor)),
         :ok <-
           validate_boolean(Keyword.get(opts, :include_measurements, true), :include_measurements),
         :ok <-
           validate_boolean(
             Keyword.get(opts, :include_component_outputs, false),
             :include_component_outputs
           ),
         :ok <- validate_max_payload_bytes(max_payload_bytes),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         mode: mode,
         include_raw_payloads: Keyword.get(opts, :include_raw_payloads, false),
         redactor: Keyword.get(opts, :redactor),
         include_measurements: Keyword.get(opts, :include_measurements, true),
         include_component_outputs: Keyword.get(opts, :include_component_outputs, false),
         max_payload_bytes: max_payload_bytes,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Trace.CapturePolicy-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      mode: policy.mode,
      include_raw_payloads: policy.include_raw_payloads,
      redactor: policy.redactor,
      include_measurements: policy.include_measurements,
      include_component_outputs: policy.include_component_outputs,
      max_payload_bytes: policy.max_payload_bytes,
      metadata: policy.metadata
    )
  end

  @spec capture(t(), term(), keyword()) :: term()
  def capture(%__MODULE__{} = policy, value, opts \\ []) do
    field = Keyword.get(opts, :field)

    value
    |> maybe_redact(policy, field)
    |> maybe_capture(policy)
  end

  defp maybe_redact(value, %__MODULE__{redactor: nil}, _field), do: value

  defp maybe_redact(value, %__MODULE__{redactor: redactor}, field)
       when is_function(redactor, 2) do
    redactor.(value, field)
  end

  defp maybe_redact(value, %__MODULE__{redactor: redactor}, _field)
       when is_function(redactor, 1) do
    redactor.(value)
  end

  defp maybe_capture(value, %__MODULE__{mode: :replay}), do: value

  defp maybe_capture(value, %__MODULE__{mode: :full} = policy),
    do: truncate(value, policy.max_payload_bytes)

  defp maybe_capture(value, %__MODULE__{mode: :summary} = policy),
    do: summarize(value, policy.max_payload_bytes)

  defp summarize(%Message{} = message, max_bytes) do
    %{
      type: :message,
      role: message.role,
      name: message.name,
      content: truncate(message.content, max_bytes),
      metadata: summarize_map(message.metadata, max_bytes)
    }
  end

  defp summarize(%Prompt{} = prompt, max_bytes) do
    %{
      type: :prompt,
      message_count: length(prompt.messages),
      messages: Enum.map(prompt.messages, &summarize(&1, max_bytes)),
      metadata: summarize_map(prompt.metadata, max_bytes)
    }
  end

  defp summarize(%TurnRequest{} = turn_request, max_bytes) do
    %{
      type: :turn_request,
      model: turn_request.model,
      history_window: turn_request.history_window,
      input_message: summarize(turn_request.input_message, max_bytes),
      pinned_messages: Enum.map(turn_request.pinned_messages, &summarize(&1, max_bytes)),
      observations: Enum.map(turn_request.observations, &summarize(&1, max_bytes)),
      metadata: summarize_map(turn_request.metadata, max_bytes)
    }
  end

  defp summarize(%LLMResult{} = result, max_bytes) do
    %{
      type: :llm_result,
      finish_reason: result.finish_reason,
      usage: result.usage,
      message: summarize(result.message, max_bytes),
      metadata: summarize_map(result.metadata, max_bytes)
    }
  end

  defp summarize(%ExecutionPlan{} = plan, max_bytes) do
    %{
      type: :execution_plan,
      call_count: length(plan.calls),
      calls: Enum.map(plan.calls, &summarize(&1, max_bytes)),
      metadata: summarize_map(plan.metadata, max_bytes)
    }
  end

  defp summarize(%CallRequest{} = call_request, max_bytes) do
    %{
      type: :tool_call,
      id: call_request.id,
      tool_name: call_request.tool_name,
      request_index: call_request.request_index,
      arguments: summarize_map(call_request.arguments, max_bytes),
      metadata: summarize_map(call_request.metadata, max_bytes)
    }
  end

  defp summarize(%CallResult{} = call_result, max_bytes) do
    %{
      type: :tool_result,
      tool_name: call_result.request.tool_name,
      status: call_result.status,
      output: summarize(call_result.output, max_bytes),
      error: summarize(call_result.error, max_bytes),
      metadata: summarize_map(call_result.metadata, max_bytes)
    }
  end

  defp summarize(%BatchResult{} = batch_result, max_bytes) do
    %{
      type: :batch_result,
      result_count: length(batch_result.results),
      results: Enum.map(batch_result.results, &summarize(&1, max_bytes)),
      metadata: summarize_map(batch_result.metadata, max_bytes)
    }
  end

  defp summarize(%TurnResult{} = turn_result, max_bytes) do
    %{
      type: :turn_result,
      kind: turn_result.kind,
      message: summarize(turn_result.message, max_bytes),
      details: summarize_map(turn_result.details, max_bytes),
      metadata: summarize_map(turn_result.metadata, max_bytes)
    }
  end

  defp summarize(%ReviewRequest{} = review_request, max_bytes) do
    %{
      type: :review_request,
      kind: review_request.kind,
      checkpoint: review_request.checkpoint,
      resume_key: review_request.resume_key,
      options: review_request.options,
      details: summarize_map(review_request.details, max_bytes),
      metadata: summarize_map(review_request.metadata, max_bytes)
    }
  end

  defp summarize(%Wait{} = wait, max_bytes) do
    %{
      type: :wait,
      kind: wait.kind,
      reason: wait.reason,
      resume_key: wait.resume_key,
      until: wait.until,
      payload: summarize(wait.payload, max_bytes),
      details: summarize_map(wait.details, max_bytes),
      metadata: summarize_map(wait.metadata, max_bytes)
    }
  end

  defp summarize(%DateTime{} = datetime, _max_bytes), do: datetime
  defp summarize(nil, _max_bytes), do: nil

  defp summarize(value, max_bytes) when is_binary(value) do
    truncate(value, max_bytes)
  end

  defp summarize(value, max_bytes) when is_list(value) do
    Enum.map(value, &summarize(&1, max_bytes))
  end

  defp summarize(value, max_bytes) when is_map(value) and not is_struct(value) do
    summarize_map(value, max_bytes)
  end

  defp summarize(value, max_bytes) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&summarize(&1, max_bytes))
    |> List.to_tuple()
  end

  defp summarize(value, max_bytes) when is_struct(value) do
    %{
      type: value.__struct__,
      summary: truncate(inspect(value), max_bytes)
    }
  end

  defp summarize(value, _max_bytes), do: value

  defp summarize_map(map, max_bytes) do
    Map.new(map, fn {key, value} -> {key, summarize(value, max_bytes)} end)
  end

  defp truncate(value, _max_bytes) when not is_binary(value), do: value

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate(value, max_bytes) do
    binary_part(value, 0, max(0, max_bytes - 3)) <> "..."
  end

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid trace capture mode",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("trace capture policy #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_redactor(nil), do: :ok
  defp validate_redactor(redactor) when is_function(redactor, 1), do: :ok
  defp validate_redactor(redactor) when is_function(redactor, 2), do: :ok

  defp validate_redactor(redactor) do
    {:error,
     Error.validation("trace capture policy redactor must be a 1- or 2-arity function",
       source: __MODULE__,
       details: %{redactor: redactor}
     )}
  end

  defp validate_max_payload_bytes(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_payload_bytes(value) do
    {:error,
     Error.validation("trace capture policy max_payload_bytes must be a positive integer",
       source: __MODULE__,
       details: %{max_payload_bytes: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("trace capture policy metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
