defmodule RunicAI.Prompt do
  @moduledoc """
  Provider-neutral prompt contract built from normalized messages.
  """

  alias RunicAI.Error
  alias RunicAI.Message

  @enforce_keys [:messages]
  defstruct [:messages, metadata: %{}]

  @type t :: %__MODULE__{
          messages: [Message.t()],
          metadata: map()
        }

  @spec new([Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(messages, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_messages} <- Message.normalize_list(messages),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{messages: normalized_messages, metadata: metadata}}
    end
  end

  @spec new!([Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()], keyword()) ::
          t()
  def new!(messages, opts \\ []) do
    case new(messages, opts) do
      {:ok, prompt} -> prompt
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = prompt) do
    with {:ok, _messages} <- Message.normalize_list(prompt.messages),
         :ok <- validate_metadata(prompt.metadata) do
      {:ok, prompt}
    end
  end

  @spec append(t(), Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()) ::
          {:ok, t()} | {:error, Error.t()}
  def append(%__MODULE__{} = prompt, message) do
    with {:ok, normalized} <- Message.normalize(message) do
      {:ok, %__MODULE__{prompt | messages: prompt.messages ++ [normalized]}}
    end
  end

  @spec append!(t(), Message.t() | ReqLLM.Message.t() | {Message.role(), String.t()} | map()) ::
          t()
  def append!(%__MODULE__{} = prompt, message) do
    case append(prompt, message) do
      {:ok, updated_prompt} -> updated_prompt
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_req_llm(t()) :: ReqLLM.Context.t()
  def to_req_llm(%__MODULE__{} = prompt) do
    prompt.messages
    |> Enum.map(&Message.to_req_llm/1)
    |> ReqLLM.Context.new()
  end

  @spec from_req_llm(ReqLLM.Context.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_req_llm(%ReqLLM.Context{} = context) do
    context
    |> ReqLLM.Context.to_list()
    |> new()
  end

  @spec from_req_llm!(ReqLLM.Context.t()) :: t()
  def from_req_llm!(%ReqLLM.Context{} = context) do
    case from_req_llm(context) do
      {:ok, prompt} -> prompt
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("prompt metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
