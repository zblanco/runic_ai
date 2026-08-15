defmodule RunicAI.Prompt do
  @moduledoc "An ordered message list with JSON-safe prompt metadata."

  alias RunicAI.JSONValue
  alias RunicAI.Message

  @wire_id "runic.ai/prompt/v1"
  @enforce_keys [:messages]
  defstruct messages: [], metadata: %{}

  @type t :: %__MODULE__{messages: [Message.t()], metadata: map()}

  def new(messages, opts \\ []) when is_list(messages) do
    with {:ok, messages} <- normalize_messages(messages),
         {:ok, metadata} <- JSONValue.normalize(Keyword.get(opts, :metadata, %{})) do
      {:ok, %__MODULE__{messages: messages, metadata: metadata}}
    end
  end

  def new!(messages, opts \\ []) do
    case new(messages, opts) do
      {:ok, prompt} -> prompt
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def append(%__MODULE__{} = prompt, message) do
    with {:ok, message} <- Message.normalize(message),
         do: {:ok, %{prompt | messages: prompt.messages ++ [message]}}
  end

  def append!(prompt, message) do
    case append(prompt, message) do
      {:ok, updated} -> updated
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def encode(%__MODULE__{} = prompt),
    do: %{
      "$contract" => @wire_id,
      "messages" => Enum.map(prompt.messages, &Message.encode/1),
      "metadata" => prompt.metadata
    }

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id do
      new(Map.get(map, "messages", []), metadata: Map.get(map, "metadata", %{}))
    else
      false -> {:error, [%{path: ["$contract"], message: "is not #{@wire_id}"}]}
      {:ok, _other} -> {:error, [%{path: [], message: "prompt must be an object"}]}
      {:error, issues} -> {:error, issues}
    end
  end

  defp normalize_messages(messages) do
    messages
    |> Enum.reduce({:ok, []}, fn message, acc ->
      case {acc, Message.normalize(message)} do
        {{:ok, values}, {:ok, normalized}} -> {:ok, [normalized | values]}
        {{:ok, _values}, {:error, issues}} -> {:error, issues}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
