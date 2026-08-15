defmodule RunicAI.LLM.Request do
  @moduledoc "Provider-neutral, serializable LLM generation request."

  alias RunicAI.Contract.Value
  alias RunicAI.JSONValue
  alias RunicAI.Message
  alias RunicAI.Prompt

  @wire_id "runic.ai/llm-request/v1"
  @parameter_keys ~w(temperature top_p max_tokens stop seed reasoning_effort)

  @enforce_keys [:model, :prompt]
  defstruct model: nil,
            prompt: nil,
            parameters: %{},
            output: nil,
            tools: [],
            metadata: %{},
            extensions: %{}

  @type t :: %__MODULE__{}

  def new(model, prompt, opts \\ []) do
    request = %__MODULE__{
      model: model,
      prompt: prompt,
      parameters: Keyword.get(opts, :parameters, %{}),
      output: Keyword.get(opts, :output),
      tools: Keyword.get(opts, :tools, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      extensions: Keyword.get(opts, :extensions, %{})
    }

    normalize(request)
  end

  def new!(model, prompt, opts \\ []) do
    case new(model, prompt, opts) do
      {:ok, request} -> request
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def normalize(%__MODULE__{} = request) do
    with true <- is_binary(request.model) and request.model != "",
         {:ok, prompt} <- normalize_prompt(request.prompt),
         {:ok, parameters} <- normalize_parameters(request.parameters),
         {:ok, output} <- normalize_output(request.output),
         {:ok, tools} when is_list(tools) <- JSONValue.normalize(request.tools),
         {:ok, metadata} when is_map(metadata) <- JSONValue.normalize(request.metadata),
         {:ok, extensions} when is_map(extensions) <- JSONValue.normalize(request.extensions) do
      {:ok,
       %{
         request
         | prompt: prompt,
           parameters: parameters,
           output: output,
           tools: tools,
           metadata: metadata,
           extensions: extensions
       }}
    else
      false -> error(["model"], "must be a non-empty provider:model string")
      {:ok, _other} -> error([], "tools, metadata, and extensions have invalid shapes")
      {:error, issues} -> {:error, issues}
    end
  end

  def normalize(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id do
      request = %__MODULE__{
        model: Map.get(map, "model"),
        prompt: Map.get(map, "prompt"),
        parameters: Map.get(map, "parameters", %{}),
        output: Map.get(map, "output"),
        tools: Map.get(map, "tools", []),
        metadata: Map.get(map, "metadata", %{}),
        extensions: Map.get(map, "extensions", %{})
      }

      normalize(request)
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "request must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def decode(input), do: normalize(input)

  def encode(%__MODULE__{} = request) do
    %{
      "$contract" => @wire_id,
      "model" => request.model,
      "prompt" => Prompt.encode(request.prompt),
      "parameters" => request.parameters,
      "tools" => request.tools,
      "metadata" => request.metadata,
      "extensions" => request.extensions
    }
    |> put_if(
      "output",
      if(request.output, do: Value.encode(request.output)),
      not is_nil(request.output)
    )
  end

  defp normalize_prompt(%Prompt{} = prompt), do: Prompt.decode(Prompt.encode(prompt))
  defp normalize_prompt(%Message{} = message), do: Prompt.new([message])
  defp normalize_prompt(text) when is_binary(text), do: Prompt.new([Message.user(text)])
  defp normalize_prompt(map) when is_map(map), do: Prompt.decode(map)
  defp normalize_prompt(_other), do: error(["prompt"], "must be text, message, or prompt")

  defp normalize_output(nil), do: {:ok, nil}
  defp normalize_output(output), do: Value.normalize(output)

  defp normalize_parameters(parameters) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(parameters),
         [] <- Map.keys(map) -- @parameter_keys,
         :ok <- validate_parameter_values(map) do
      {:ok, map}
    else
      [_ | _] = unknown ->
        error(["parameters"], "contains unsupported keys: #{Enum.join(unknown, ", ")}")

      {:ok, _other} ->
        error(["parameters"], "must be an object")

      {:error, issues} ->
        {:error, issues}
    end
  end

  defp validate_parameter_values(map) do
    cond do
      Map.has_key?(map, "temperature") and not is_number(map["temperature"]) ->
        error(["parameters", "temperature"], "must be a number")

      Map.has_key?(map, "top_p") and not is_number(map["top_p"]) ->
        error(["parameters", "top_p"], "must be a number")

      Map.has_key?(map, "max_tokens") and
          not (is_integer(map["max_tokens"]) and map["max_tokens"] > 0) ->
        error(["parameters", "max_tokens"], "must be a positive integer")

      Map.has_key?(map, "stop") and
          not (is_binary(map["stop"]) or
                   (is_list(map["stop"]) and Enum.all?(map["stop"], &is_binary/1))) ->
        error(["parameters", "stop"], "must be text or a list of text")

      true ->
        :ok
    end
  end

  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
