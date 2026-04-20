defmodule RunicAI.Context.Bundle do
  @moduledoc """
  Canonical assembled active context just before prompt projection.
  """

  alias RunicAI.Context.Focus
  alias RunicAI.Context.Ref
  alias RunicAI.Error
  alias RunicAI.Message
  alias RunicAI.Prompt

  @enforce_keys [:entries, :messages, :refs, :token_estimate, :coverage, :metadata]
  defstruct [:focus, :entries, :messages, :refs, :token_estimate, :coverage, :metadata]

  @type entry :: map()

  @type t :: %__MODULE__{
          entries: [entry()],
          messages: [Message.t()],
          refs: [Ref.t()],
          focus: Focus.t() | nil,
          token_estimate: non_neg_integer(),
          coverage: map(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    entries = Keyword.get(opts, :entries, [])
    messages = Keyword.get(opts, :messages, [])
    refs = Keyword.get(opts, :refs, [])
    focus = Keyword.get(opts, :focus)
    coverage = Keyword.get(opts, :coverage, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_entries(entries),
         {:ok, messages} <- Message.normalize_list(messages),
         {:ok, refs} <- normalize_refs(refs),
         {:ok, focus} <- normalize_focus(focus),
         :ok <- validate_coverage(coverage),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         entries: entries,
         messages: messages,
         refs: refs,
         focus: focus,
         token_estimate: estimate_tokens(messages),
         coverage: coverage,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, bundle} -> bundle
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = bundle) do
    new(
      entries: bundle.entries,
      messages: bundle.messages,
      refs: bundle.refs,
      focus: bundle.focus,
      coverage: bundle.coverage,
      metadata: bundle.metadata
    )
  end

  @spec to_prompt(t()) :: {:ok, Prompt.t()} | {:error, Error.t()}
  def to_prompt(%__MODULE__{} = bundle) do
    Prompt.new(bundle.messages, metadata: bundle.metadata)
  end

  @spec to_prompt!(t()) :: Prompt.t()
  def to_prompt!(%__MODULE__{} = bundle) do
    case to_prompt(bundle) do
      {:ok, prompt} -> prompt
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec estimate_tokens([Message.t()]) :: non_neg_integer()
  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map(&String.length(&1.content))
    |> Enum.sum()
    |> Kernel./(4)
    |> Float.ceil()
    |> trunc()
  end

  defp validate_entries(entries) when is_list(entries), do: :ok

  defp validate_entries(entries) do
    {:error,
     Error.validation("context bundle entries must be a list",
       source: __MODULE__,
       details: %{entries: entries}
     )}
  end

  defp normalize_refs(refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn ref, {:ok, acc} ->
      case Ref.validate(ref) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_refs(refs) do
    {:error,
     Error.validation("context bundle refs must be a list of Context.Ref structs",
       source: __MODULE__,
       details: %{refs: refs}
     )}
  end

  defp normalize_focus(nil), do: {:ok, nil}
  defp normalize_focus(%Focus{} = focus), do: Focus.validate(focus)

  defp normalize_focus(focus) do
    {:error,
     Error.validation("context bundle focus must be a Context.Focus or nil",
       source: __MODULE__,
       details: %{focus: focus}
     )}
  end

  defp validate_coverage(coverage) when is_map(coverage), do: :ok

  defp validate_coverage(coverage) do
    {:error,
     Error.validation("context bundle coverage must be a map",
       source: __MODULE__,
       details: %{coverage: coverage}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context bundle metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
