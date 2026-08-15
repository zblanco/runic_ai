defmodule RunicAI.Message do
  @moduledoc "An owned, serializable conversation message contract."

  alias RunicAI.JSONValue
  alias RunicAI.MessageContent

  @roles [:system, :user, :assistant, :tool]
  @wire_id "runic.ai/message/v1"

  @enforce_keys [:role, :content]
  defstruct role: nil, content: [], name: nil, metadata: %{}

  @type role :: :system | :user | :assistant | :tool
  @type t :: %__MODULE__{
          role: role(),
          content: [MessageContent.t()],
          name: String.t() | nil,
          metadata: map()
        }

  def text(role, text, opts \\ []) when role in @roles and is_binary(text),
    do: new!(role, [MessageContent.text(text)], opts)

  def system(text, opts \\ []), do: text(:system, text, opts)
  def user(text, opts \\ []), do: text(:user, text, opts)
  def assistant(text, opts \\ []), do: text(:assistant, text, opts)

  def new(role, content, opts \\ []) do
    message = %__MODULE__{
      role: role,
      content: content,
      name: Keyword.get(opts, :name),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    normalize(message)
  end

  def new!(role, content, opts \\ []) do
    case new(role, content, opts) do
      {:ok, message} -> message
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def normalize(%__MODULE__{} = message) do
    with true <- message.role in @roles,
         {:ok, content} <- normalize_content(message.content),
         {:ok, metadata} <- JSONValue.normalize(message.metadata),
         true <- is_nil(message.name) or is_binary(message.name) do
      {:ok, %{message | content: content, metadata: metadata}}
    else
      false -> error([], "message role or name is invalid")
      {:error, issues} -> {:error, issues}
    end
  end

  def normalize(%{"role" => role, "content" => content} = map) do
    with {:ok, role} <- decode_role(role) do
      new(role, content, name: Map.get(map, "name"), metadata: Map.get(map, "metadata", %{}))
    end
  end

  def normalize(text) when is_binary(text), do: {:ok, user(text)}

  def normalize(_other),
    do: error([], "message must be a message struct, wire object, or user text")

  def decode(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id do
      normalize(map)
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "message must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  def encode(%__MODULE__{} = message) do
    %{
      "$contract" => @wire_id,
      "role" => Atom.to_string(message.role),
      "content" => Enum.map(message.content, &MessageContent.encode/1),
      "metadata" => message.metadata
    }
    |> put_if("name", message.name)
  end

  def text(%__MODULE__{} = message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp normalize_content(text) when is_binary(text), do: {:ok, [MessageContent.text(text)]}

  defp normalize_content(content) when is_list(content) and content != [] do
    content
    |> Enum.reduce({:ok, []}, fn part, acc ->
      case {acc, MessageContent.decode(part)} do
        {{:ok, parts}, {:ok, normalized}} -> {:ok, [normalized | parts]}
        {{:ok, _parts}, {:error, issues}} -> {:error, issues}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, Enum.reverse(parts)}
      error -> error
    end
  end

  defp normalize_content(_other), do: error(["content"], "must contain at least one content part")

  defp decode_role(value) do
    case Enum.find(@roles, &(Atom.to_string(&1) == value)) do
      nil -> error(["role"], "is not supported")
      role -> {:ok, role}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
