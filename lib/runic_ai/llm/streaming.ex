defmodule RunicAI.LLM.Streaming do
  @moduledoc """
  Stream-aware text generation helper.

  The helper emits normalized stream stages through `:stream_sink` while still
  returning a complete `RunicAI.LLM.Result` after the provider stream is fully
  consumed.
  """

  alias RunicAI.Error
  alias RunicAI.Event
  alias RunicAI.Ids
  alias RunicAI.LLM
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.Message

  @control_keys [
    :stream?,
    :stream_sink,
    :stream_id,
    :message_id,
    :run_id,
    :session_id,
    :agent,
    :message_kind,
    :source_step,
    :workflow_node,
    :runnable_id,
    :presentation_group_id,
    :request_context_id,
    :transient,
    :stream_chunk_size
  ]

  @default_chunk_size 20

  @spec generate_text(Request.t()) ::
          {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()}
  def generate_text(%Request{} = request) do
    {control, llm_opts} = Keyword.split(request.opts, @control_keys)
    request = %{request | opts: llm_opts}

    if stream_enabled?(control) do
      stream_request(request, control, llm_opts)
    else
      LLM.generate_text(request)
    end
  end

  @spec generate_text(LLM.model(), LLM.prompt(), LLM.options()) ::
          {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()}
  def generate_text(model, prompt, opts \\ []) when is_list(opts) do
    {control, llm_opts} = Keyword.split(opts, @control_keys)

    if stream_enabled?(control) do
      with {:ok, request} <- Request.new(model, prompt, opts: llm_opts) do
        stream_request(request, control, llm_opts)
      end
    else
      LLM.generate_text(model, prompt, llm_opts)
    end
  end

  @spec stream_stage(atom(), map(), keyword()) :: Event.t()
  def stream_stage(stage, data, control \\ []) when is_atom(stage) and is_map(data) do
    Event.from_stream_stage(%{
      run_id: Keyword.get(control, :run_id) || data[:run_id] || data["run_id"],
      session_id: Keyword.get(control, :session_id) || data[:session_id] || data["session_id"],
      agent: Keyword.get(control, :agent) || data[:agent] || data["agent"],
      stage: stage,
      status: stream_status(stage),
      data: data
    })
  end

  defp stream_request(%Request{} = request, control, llm_opts) do
    case LLM.stream_text(request.model, request.prompt, llm_opts) do
      {:ok, %ReqLLM.StreamResponse{} = stream_response} ->
        collect_stream(stream_response, request, control)

      {:ok, %Result{} = result} ->
        {:ok, result}

      {:ok, %ReqLLM.Response{} = response} ->
        Result.from_req_llm_response(response)

      {:ok, _non_stream_response} ->
        LLM.generate_text(%{request | opts: llm_opts})

      {:error, %Error{kind: :unsupported}} ->
        LLM.generate_text(%{request | opts: llm_opts})

      {:error, %Error{retryable?: true} = error} ->
        {:retry, error}

      {:error, %Error{} = error} ->
        emit_stream_failure(control, error)
        {:error, error}
    end
  end

  defp collect_stream(stream_response, %Request{} = request, control) do
    identity = stream_identity(control)
    chunk_size = chunk_size(control)

    acc =
      stream_response.stream
      |> Stream.chunk_every(chunk_size)
      |> Enum.reduce(%{sequence: 0, content: []}, fn chunks, acc ->
        chunks
        |> normalize_batch()
        |> Enum.reduce(acc, fn {channel, text, payload}, acc ->
          emit_stream_chunk(control, identity, acc.sequence + 1, channel, text, payload)

          content =
            if channel == "content" do
              [text | acc.content]
            else
              acc.content
            end

          %{acc | sequence: acc.sequence + 1, content: content}
        end)
      end)

    text =
      acc.content
      |> Enum.reverse()
      |> Enum.join("")

    finish_reason = finish_reason(stream_response)
    emit_stream_completed(control, identity, acc.sequence + 1, text, finish_reason)

    Result.new(Message.new!(:assistant, text),
      finish_reason: finish_reason,
      raw: stream_response,
      metadata: %{
        stream_id: identity.stream_id,
        message_id: identity.message_id,
        model: request.model
      }
    )
  rescue
    exception ->
      error =
        Error.from_exception(exception,
          source: __MODULE__,
          message: "LLM stream failed while collecting chunks"
        )

      emit_stream_failure(control, error)
      {:error, error}
  end

  defp normalize_batch(chunks) do
    parts = Enum.map(chunks, &chunk_part/1)

    []
    |> maybe_append_part("content", parts)
    |> maybe_append_part("thinking", parts)
    |> maybe_append_part("tool_calls", parts)
    |> maybe_append_part("meta", parts)
  end

  defp maybe_append_part(acc, channel, parts) do
    selected = Enum.filter(parts, &(&1.channel == channel))

    case selected do
      [] ->
        acc

      parts ->
        text =
          parts
          |> Enum.map(& &1.text)
          |> Enum.join("")

        payload = Enum.map(parts, & &1.payload)
        acc ++ [{channel, text, payload}]
    end
  end

  defp chunk_part(chunk) do
    type = chunk_field(chunk, :type) || :content
    text = chunk_text(chunk)
    %{channel: channel(type), text: text, payload: chunk}
  end

  defp chunk_text(chunk) do
    chunk_field(chunk, :text) ||
      chunk_field(chunk, :delta) ||
      chunk_field(chunk, :content) ||
      chunk
      |> inspect(limit: 20, printable_limit: 1_000)
  end

  defp channel(type) when type in [:content, :text, "content", "text"], do: "content"
  defp channel(type) when type in [:thinking, :reasoning, "thinking", "reasoning"], do: "thinking"

  defp channel(type) when type in [:tool_call, :tool_calls, "tool_call", "tool_calls"],
    do: "tool_calls"

  defp channel(type) when type in [:meta, :metadata, "meta", "metadata"], do: "meta"
  defp channel(_type), do: "meta"

  defp emit_stream_chunk(control, identity, sequence, channel, text, payload) do
    data =
      base_stream_data(control, identity)
      |> Map.merge(%{
        chunk: text,
        content: text,
        channel: channel,
        sequence: sequence,
        stream_complete: false,
        payload: payload
      })

    emit(control, stream_stage(:llm_stream_chunk, data, control))
  end

  defp emit_stream_completed(control, identity, sequence, content, finish_reason) do
    data =
      base_stream_data(control, identity)
      |> Map.merge(%{
        content: content,
        chunk: "",
        channel: "content",
        sequence: sequence,
        finish_reason: finish_reason,
        stream_complete: true
      })

    emit(control, stream_stage(:llm_stream_completed, data, control))
  end

  defp emit_stream_failure(control, %Error{} = error) do
    identity = stream_identity(control)

    data =
      base_stream_data(control, identity)
      |> Map.merge(%{
        content: "",
        chunk: "",
        channel: "content",
        stream_complete: true,
        error: Map.from_struct(error)
      })

    emit(control, stream_stage(:llm_stream_failed, data, control))
  end

  defp emit(control, stage) do
    case Keyword.get(control, :stream_sink) do
      sink when is_function(sink, 1) ->
        sink.(stage)

      _other ->
        :ok
    end
  rescue
    _exception -> :ok
  end

  defp base_stream_data(control, identity) do
    %{
      run_id: Keyword.get(control, :run_id),
      session_id: Keyword.get(control, :session_id),
      agent: Keyword.get(control, :agent),
      stream_id: identity.stream_id,
      message_id: identity.message_id,
      role: "assistant",
      message_kind: Keyword.get(control, :message_kind, "stream"),
      source_step: Keyword.get(control, :source_step),
      workflow_node: Keyword.get(control, :workflow_node),
      runnable_id: Keyword.get(control, :runnable_id),
      transient: Keyword.get(control, :transient, false),
      presentation_group_id:
        Keyword.get(control, :presentation_group_id) || Keyword.get(control, :run_id) ||
          Keyword.get(control, :session_id),
      request_context_id: Keyword.get(control, :request_context_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stream_identity(control) do
    stream_id =
      Keyword.get(control, :stream_id) ||
        Keyword.get(control, :message_id) ||
        Ids.unique("llm-stream")

    message_id = Keyword.get(control, :message_id) || "stream:#{stream_id}"
    %{stream_id: stream_id, message_id: message_id}
  end

  defp stream_enabled?(control) do
    Keyword.get(control, :stream?, true) != false and
      is_function(Keyword.get(control, :stream_sink), 1)
  end

  defp chunk_size(control) do
    case Keyword.get(control, :stream_chunk_size, @default_chunk_size) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_chunk_size
    end
  end

  defp finish_reason(stream_response) do
    if function_exported?(ReqLLM.StreamResponse, :finish_reason, 1) do
      ReqLLM.StreamResponse.finish_reason(stream_response) || :stop
    else
      :stop
    end
  rescue
    _exception -> :stop
  end

  defp stream_status(:llm_stream_chunk), do: :running
  defp stream_status(:llm_stream_failed), do: :error
  defp stream_status(_stage), do: :ok

  defp chunk_field(chunk, key) when is_map(chunk),
    do: Map.get(chunk, key) || Map.get(chunk, to_string(key))

  defp chunk_field(_chunk, _key), do: nil
end
