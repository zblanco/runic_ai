defmodule RunicAI.Message do
  @moduledoc """
  Canonical message contract for RunicAI workflows.
  """

  alias RunicAI.Error

  @valid_roles [:system, :user, :assistant, :tool]

  @enforce_keys [:role, :content]
  defstruct [:role, :content, :name, metadata: %{}]

  @type role :: :system | :user | :assistant | :tool

  @type t :: %__MODULE__{
          role: role(),
          content: String.t(),
          name: String.t() | nil,
          metadata: map()
        }

  @spec new(role(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(role, content, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    name = Keyword.get(opts, :name)

    with :ok <- validate_role(role),
         :ok <- validate_content(content),
         :ok <- validate_name(name),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{role: role, content: content, name: name, metadata: metadata}}
    end
  end

  @spec new!(role(), String.t(), keyword()) :: t()
  def new!(role, content, opts \\ []) do
    case new(role, content, opts) do
      {:ok, message} -> message
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec normalize(t() | ReqLLM.Message.t() | {role(), String.t()} | map()) ::
          {:ok, t()} | {:error, Error.t()}
  def normalize(%__MODULE__{} = message), do: validate(message)
  def normalize(%ReqLLM.Message{} = message), do: from_req_llm(message)
  def normalize({role, content}) when is_atom(role) and is_binary(content), do: new(role, content)

  def normalize(%{role: role, content: content} = message)
      when is_atom(role) and is_binary(content) do
    new(role, content,
      name: Map.get(message, :name),
      metadata: Map.get(message, :metadata, %{})
    )
  end

  def normalize(other) do
    {:error,
     Error.validation("expected a RunicAI message-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec normalize_list([term()]) :: {:ok, [t()]} | {:error, Error.t()}
  def normalize_list(messages) when is_list(messages) do
    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, acc} ->
      case normalize(message) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  def normalize_list(other) do
    {:error,
     Error.validation("expected a message list, got: #{inspect(other)}", source: __MODULE__)}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = message) do
    with :ok <- validate_role(message.role),
         :ok <- validate_content(message.content),
         :ok <- validate_name(message.name),
         :ok <- validate_metadata(message.metadata) do
      {:ok, message}
    end
  end

  @spec from_req_llm(ReqLLM.Message.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_req_llm(%ReqLLM.Message{} = message) do
    new(message.role, extract_text(message.content),
      name: message.name,
      metadata: req_metadata(message)
    )
  end

  @spec from_req_llm!(ReqLLM.Message.t()) :: t()
  def from_req_llm!(%ReqLLM.Message{} = message) do
    case from_req_llm(message) do
      {:ok, normalized} -> normalized
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_req_llm(t()) :: ReqLLM.Message.t()
  def to_req_llm(%__MODULE__{} = message) do
    metadata = message.metadata || %{}

    case message.role do
      :system ->
        ReqLLM.Context.system(message.content, metadata: metadata)

      :user ->
        ReqLLM.Context.user(message.content, metadata: metadata)

      :assistant ->
        assistant_metadata = Map.drop(metadata, [:tool_calls])
        tool_calls = Map.get(metadata, :tool_calls, [])

        ReqLLM.Context.assistant(message.content,
          metadata: assistant_metadata,
          tool_calls: tool_calls
        )

      :tool ->
        tool_call_id = Map.get(metadata, :tool_call_id)
        req_message = ReqLLM.Context.user(message.content, metadata: metadata)

        %ReqLLM.Message{
          req_message
          | role: :tool,
            name: message.name,
            tool_call_id: tool_call_id
        }
    end
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: content}), do: content

  @spec valid_role?(term()) :: boolean()
  def valid_role?(role), do: role in @valid_roles

  defp validate_role(role) do
    if valid_role?(role) do
      :ok
    else
      {:error,
       Error.validation("invalid message role: #{inspect(role)}",
         source: __MODULE__,
         details: %{role: role, valid_roles: @valid_roles}
       )}
    end
  end

  defp validate_content(content) when is_binary(content), do: :ok

  defp validate_content(content) do
    {:error,
     Error.validation("message content must be a string, got: #{inspect(content)}",
       source: __MODULE__
     )}
  end

  defp validate_name(nil), do: :ok
  defp validate_name(name) when is_binary(name), do: :ok

  defp validate_name(name) do
    {:error,
     Error.validation("message name must be a string or nil, got: #{inspect(name)}",
       source: __MODULE__
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("message metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end

  defp extract_text(content_parts) when is_list(content_parts) do
    content_parts
    |> Enum.map_join("", fn
      %{text: text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp req_metadata(message) do
    message.metadata
    |> Map.new()
    |> maybe_put(:tool_calls, message.tool_calls)
    |> maybe_put(:tool_call_id, message.tool_call_id)
    |> maybe_put(:reasoning_details, message.reasoning_details)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
