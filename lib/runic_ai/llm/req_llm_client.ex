defmodule RunicAI.LLM.ReqLLMClient do
  @moduledoc "ReqLLM adapter that prevents provider structs from crossing the public boundary."

  @behaviour RunicAI.LLM.Client

  alias RunicAI.Error
  alias RunicAI.LLM.Evidence
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.Usage
  alias RunicAI.Message
  alias RunicAI.Prompt

  @impl true
  def generate(%Request{} = request, opts) do
    with {:ok, context} <- to_req_context(request.prompt),
         {:ok, response} <- dispatch(request, context, opts),
         {:ok, result} <- from_response(response, request) do
      {:ok, result}
    else
      {:retry, %Error{} = error} -> {:retry, error}
      {:error, %Error{} = error} -> outcome_for(error)
      {:error, reason} -> reason |> provider_error(request) |> outcome_for()
    end
  rescue
    exception ->
      {:error,
       Error.from_exception(exception,
         kind: :provider,
         code: "req_llm_exception",
         source: inspect(__MODULE__),
         details: %{"model" => request.model}
       )}
  end

  defp dispatch(request, context, opts) do
    case Keyword.get(opts, :dispatch) do
      fun when is_function(fun, 3) -> fun.(request, context, req_opts(request))
      nil -> default_dispatch(request, context)
    end
  end

  defp default_dispatch(%Request{output: nil} = request, context),
    do: ReqLLM.generate_text(request.model, context, req_opts(request))

  defp default_dispatch(%Request{} = request, context),
    do:
      ReqLLM.generate_object(
        request.model,
        context,
        RunicAI.Contract.Value.to_json_schema(request.output),
        req_opts(request)
      )

  defp req_opts(request) do
    parameter_opts =
      Enum.map(request.parameters, fn
        {"temperature", value} -> {:temperature, value}
        {"top_p", value} -> {:top_p, value}
        {"max_tokens", value} -> {:max_tokens, value}
        {"stop", value} -> {:stop, value}
        {"seed", value} -> {:seed, value}
        {"reasoning_effort", value} -> {:reasoning_effort, value}
      end)

    parameter_opts
    |> put_tools(request.tools)
    |> put_extension(request.extensions, "tool_choice", :tool_choice)
  end

  defp to_req_context(%Prompt{messages: messages}) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case to_req_message(message) do
        {:ok, req_message} -> {:cont, {:ok, [req_message | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> ReqLLM.Context.new()}
      error -> error
    end
  end

  defp to_req_message(%Message{role: :tool} = message) do
    tool_result = Enum.find(message.content, &(&1.type == :tool_result))

    tool_call_id =
      Map.get(message.metadata, "tool_call_id") || (tool_result && tool_result.call_id)

    name = message.name || (tool_result && tool_result.name)
    content = if(tool_result, do: Jason.encode!(tool_result.value), else: Message.text(message))

    if is_binary(tool_call_id) and tool_call_id != "" do
      {:ok, ReqLLM.Context.tool_result(tool_call_id, name, content)}
    else
      {:error,
       Error.validation("tool messages require a tool_call_id",
         code: "invalid_tool_message",
         source: inspect(__MODULE__)
       )}
    end
  end

  defp to_req_message(%Message{} = message) do
    if Enum.all?(message.content, &(&1.type == :text)) do
      text = Message.text(message)

      req_message =
        case message.role do
          :system -> ReqLLM.Context.system(text, metadata: message.metadata)
          :user -> ReqLLM.Context.user(text, metadata: message.metadata)
          :assistant -> ReqLLM.Context.assistant(text, metadata: message.metadata)
        end

      {:ok, req_message}
    else
      {:error,
       Error.validation("ReqLLM adapter does not support this owned content part yet",
         code: "unsupported_message_part",
         source: inspect(__MODULE__)
       )}
    end
  end

  defp from_response(%ReqLLM.Response{} = response, request) do
    text = ReqLLM.Response.text(response) || ""
    object = response.object
    tool_requests = Enum.map(ReqLLM.Response.tool_calls(response), &safe_tool_call/1)

    with :ok <- validate_structured_output(request.output, object),
         {:ok, usage} <- Usage.new(response.usage || %{}),
         {:ok, evidence} <- Evidence.new(evidence_map(response, request)) do
      Result.new(Message.assistant(text),
        reasoning: ReqLLM.Response.thinking(response),
        object: object,
        tool_requests: tool_requests,
        usage: Usage.encode(usage),
        evidence: Evidence.encode(evidence),
        warnings: provider_warnings(response.provider_meta)
      )
    end
  end

  defp from_response(_response, _request),
    do:
      {:error,
       Error.provider("ReqLLM returned an unexpected response",
         code: "malformed_response",
         source: inspect(__MODULE__)
       )}

  defp validate_structured_output(nil, _object), do: :ok

  defp validate_structured_output(_contract, nil),
    do:
      {:error,
       Error.provider("structured response did not include an object",
         code: "missing_structured_output",
         source: inspect(__MODULE__)
       )}

  defp validate_structured_output(contract, object) do
    case RunicAI.Contract.Value.validate_value(contract, object) do
      :ok ->
        :ok

      {:error, issues} ->
        {:error,
         Error.provider("structured response failed its output contract",
           code: "invalid_structured_output",
           source: inspect(__MODULE__),
           details: %{"issues" => issues}
         )}
    end
  end

  defp evidence_map(response, request) do
    %{
      "provider" => provider_from_model(request.model),
      "model" => response.model || request.model,
      "request_id" => response_request_id(response),
      "finish_reason" => if(response.finish_reason, do: Atom.to_string(response.finish_reason))
    }
  end

  defp response_request_id(%ReqLLM.Response{message: %{metadata: metadata}, id: id})
       when is_map(metadata),
       do: Map.get(metadata, :response_id) || Map.get(metadata, "response_id") || id

  defp response_request_id(%ReqLLM.Response{id: id}), do: id

  defp safe_tool_call(call) do
    map = ReqLLM.ToolCall.to_map(call)

    %{
      "id" => map[:id] || map["id"],
      "name" => ReqLLM.ToolCall.name(call),
      "arguments" =>
        safe_arguments(
          map[:arguments] || map["arguments"] || get_in(map, [:function, :arguments]) ||
            get_in(map, ["function", "arguments"])
        )
    }
  end

  defp safe_arguments(value) when is_map(value), do: RunicAI.JSONValue.normalize!(value)

  defp safe_arguments(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"raw" => value}
    end
  end

  defp safe_arguments(_value), do: %{}

  defp put_tools(opts, []), do: opts

  defp put_tools(opts, tools) do
    case Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
           case to_req_tool(tool) do
             {:ok, req_tool} -> {:cont, {:ok, [req_tool | acc]}}
             {:error, error} -> {:halt, {:error, error}}
           end
         end) do
      {:ok, req_tools} -> Keyword.put(opts, :tools, Enum.reverse(req_tools))
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp to_req_tool(%{"name" => name, "description" => description, "parameters" => schema}) do
    ReqLLM.Tool.new(
      name: name,
      description: description,
      parameter_schema: schema,
      callback: fn _arguments -> {:error, :host_executes_tools} end
    )
    |> case do
      {:ok, tool} ->
        {:ok, tool}

      {:error, _reason} ->
        {:error,
         Error.validation("LLM tool specification is invalid",
           code: "invalid_llm_tool",
           source: inspect(__MODULE__),
           details: %{"name" => name}
         )}
    end
  end

  defp to_req_tool(_tool),
    do:
      {:error,
       Error.validation("LLM tool specification is invalid",
         code: "invalid_llm_tool",
         source: inspect(__MODULE__)
       )}

  defp put_extension(opts, extensions, key, option) do
    case Map.get(extensions, key) do
      nil -> opts
      value -> Keyword.put(opts, option, value)
    end
  end

  defp provider_warnings(meta) when is_map(meta),
    do: Map.get(meta, :warnings) || Map.get(meta, "warnings") || []

  defp provider_warnings(_meta), do: []
  defp provider_from_model(model), do: model |> String.split(":", parts: 2) |> hd()

  defp provider_error(%Error{} = error, _request), do: error

  defp provider_error(reason, request) do
    Error.provider("ReqLLM generation failed",
      code: "generation_failed",
      retryable: retryable?(reason),
      source: inspect(__MODULE__),
      details: %{"model" => request.model, "reason" => reason_summary(reason)}
    )
  end

  defp retryable?(%{status: status}) when status in [408, 409, 429, 500, 502, 503, 504], do: true
  defp retryable?(_reason), do: false
  defp reason_summary(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_summary(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp reason_summary(_reason), do: "provider request failed"
  defp outcome_for(%Error{retryable: true} = error), do: {:retry, error}
  defp outcome_for(%Error{} = error), do: {:error, error}
end
