defmodule RunicAI.Context.Node do
  @moduledoc """
  Context graph node carrying summarized, recalled, or retrieved content.
  """

  alias RunicAI.Context.HandoffArtifact
  alias RunicAI.Context.Ref
  alias RunicAI.Error
  alias RunicAI.Memory.Entry
  alias RunicAI.Message
  alias RunicAI.Retrieval.Document

  @valid_kinds [:message, :summary, :memory, :retrieval, :observation, :handoff, :artifact]

  @enforce_keys [:id, :kind, :content, :token_count, :created_at, :metadata]
  defstruct [:id, :kind, :content, :token_count, :created_at, :metadata]

  @type kind :: Ref.kind()

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          content: term(),
          token_count: non_neg_integer(),
          created_at: DateTime.t(),
          metadata: map()
        }

  @spec new(String.t(), kind(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(id, kind, content, opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())
    token_count = Keyword.get(opts, :token_count, estimate_tokens(content))

    with :ok <- validate_id(id),
         :ok <- validate_kind(kind),
         :ok <- validate_token_count(token_count),
         :ok <- validate_created_at(created_at),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         content: content,
         token_count: token_count,
         created_at: created_at,
         metadata: metadata
       }}
    end
  end

  @spec new!(String.t(), kind(), term(), keyword()) :: t()
  def new!(id, kind, content, opts \\ []) do
    case new(id, kind, content, opts) do
      {:ok, node} -> node
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec new_from_ref(Ref.t(), term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new_from_ref(%Ref{} = ref, content, opts \\ []) when is_list(opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.put_new(:target_id, ref.target_id)
      |> Map.put_new(:ref_label, ref.label)
      |> Map.put_new(:provenance, ref.provenance)
      |> Map.put_new(:ref_metadata, ref.metadata)

    new(Ref.key(ref), ref.kind, content,
      token_count: Keyword.get(opts, :token_count, estimate_tokens(content)),
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      metadata: metadata
    )
  end

  @spec new_from_ref!(Ref.t(), term(), keyword()) :: t()
  def new_from_ref!(%Ref{} = ref, content, opts \\ []) do
    case new_from_ref(ref, content, opts) do
      {:ok, node} -> node
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = node) do
    new(node.id, node.kind, node.content,
      token_count: node.token_count,
      created_at: node.created_at,
      metadata: node.metadata
    )
  end

  @spec ref(t()) :: Ref.t()
  def ref(%__MODULE__{} = node) do
    target_id =
      Map.get(node.metadata, :target_id) ||
        String.replace_prefix(node.id, "#{node.kind}:", "")

    Ref.new!(node.kind, target_id,
      label: Map.get(node.metadata, :ref_label),
      provenance: Map.get(node.metadata, :provenance, []),
      metadata: Map.get(node.metadata, :ref_metadata, %{})
    )
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{content: %Message{} = message}), do: message.content
  def text(%__MODULE__{content: %Entry{} = entry}), do: entry.summary || entry.content
  def text(%__MODULE__{content: %Document{} = document}), do: document.content
  def text(%__MODULE__{content: %HandoffArtifact{} = artifact}), do: artifact.brief
  def text(%__MODULE__{content: content}) when is_binary(content), do: content
  def text(%__MODULE__{content: content}), do: inspect(content)

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @valid_kinds

  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(%Message{} = message), do: estimate_tokens(message.content)
  def estimate_tokens(%Entry{} = entry), do: estimate_tokens(entry.summary || entry.content)
  def estimate_tokens(%Document{} = document), do: estimate_tokens(document.content)
  def estimate_tokens(%HandoffArtifact{} = artifact), do: estimate_tokens(artifact.brief)

  def estimate_tokens(content) when is_binary(content) do
    content
    |> byte_size()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
    |> max(1)
  end

  def estimate_tokens(content), do: estimate_tokens(inspect(content))

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("context node id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid context node kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_token_count(token_count) when is_integer(token_count) and token_count >= 0,
    do: :ok

  defp validate_token_count(token_count) do
    {:error,
     Error.validation("context node token_count must be a non-negative integer",
       source: __MODULE__,
       details: %{token_count: token_count}
     )}
  end

  defp validate_created_at(%DateTime{}), do: :ok

  defp validate_created_at(created_at) do
    {:error,
     Error.validation("context node created_at must be a DateTime",
       source: __MODULE__,
       details: %{created_at: created_at}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context node metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
