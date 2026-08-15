defmodule RunicAI.Context.State do
  @moduledoc """
  Durable derived context state carried alongside conversation state.
  """

  alias RunicAI.Context.Focus
  alias RunicAI.Context.Graph
  alias RunicAI.Context.Ref
  alias RunicAI.Error

  @enforce_keys [:graph, :root_refs, :active_refs, :tail_refs, :stats, :metadata]
  defstruct [:graph, :last_focus, :root_refs, :active_refs, :tail_refs, :stats, :metadata]

  @type t :: %__MODULE__{
          graph: Graph.t(),
          root_refs: [Ref.t()],
          active_refs: [Ref.t()],
          tail_refs: [Ref.t()],
          last_focus: Focus.t() | nil,
          stats: map(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    graph = Keyword.get(opts, :graph, Graph.new())
    root_refs = Keyword.get(opts, :root_refs, [])
    active_refs = Keyword.get(opts, :active_refs, [])
    tail_refs = Keyword.get(opts, :tail_refs, [])
    last_focus = Keyword.get(opts, :last_focus)
    stats = Keyword.get(opts, :stats, default_stats())
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, graph} <- Graph.validate(graph),
         {:ok, root_refs} <- normalize_refs(root_refs),
         {:ok, active_refs} <- normalize_refs(active_refs),
         {:ok, tail_refs} <- normalize_refs(tail_refs),
         {:ok, last_focus} <- normalize_focus(last_focus),
         :ok <- validate_stats(stats),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         graph: graph,
         root_refs: root_refs,
         active_refs: active_refs,
         tail_refs: tail_refs,
         last_focus: last_focus,
         stats: stats,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, state} -> state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = state) do
    new(
      graph: state.graph,
      root_refs: state.root_refs,
      active_refs: state.active_refs,
      tail_refs: state.tail_refs,
      last_focus: state.last_focus,
      stats: state.stats,
      metadata: state.metadata
    )
  end

  @spec with_graph(t(), Graph.t()) :: {:ok, t()} | {:error, Error.t()}
  def with_graph(%__MODULE__{} = state, %Graph{} = graph) do
    with {:ok, graph} <- Graph.validate(graph) do
      {:ok, %__MODULE__{state | graph: graph}}
    end
  end

  @spec with_graph!(t(), Graph.t()) :: t()
  def with_graph!(%__MODULE__{} = state, %Graph{} = graph) do
    case with_graph(state, graph) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec with_focus(t(), Focus.t() | nil) :: {:ok, t()} | {:error, Error.t()}
  def with_focus(%__MODULE__{} = state, focus) do
    with {:ok, normalized_focus} <- normalize_focus(focus) do
      {:ok, %__MODULE__{state | last_focus: normalized_focus}}
    end
  end

  @spec with_focus!(t(), Focus.t() | nil) :: t()
  def with_focus!(%__MODULE__{} = state, focus) do
    case with_focus(state, focus) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec put_refs(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def put_refs(%__MODULE__{} = state, opts) when is_list(opts) do
    root_refs = Keyword.get(opts, :root_refs, state.root_refs)
    active_refs = Keyword.get(opts, :active_refs, state.active_refs)
    tail_refs = Keyword.get(opts, :tail_refs, state.tail_refs)

    with {:ok, root_refs} <- normalize_refs(root_refs),
         {:ok, active_refs} <- normalize_refs(active_refs),
         {:ok, tail_refs} <- normalize_refs(tail_refs) do
      {:ok,
       %__MODULE__{state | root_refs: root_refs, active_refs: active_refs, tail_refs: tail_refs}}
    end
  end

  @spec put_refs!(t(), keyword()) :: t()
  def put_refs!(%__MODULE__{} = state, opts) when is_list(opts) do
    case put_refs(state, opts) do
      {:ok, updated_state} -> updated_state
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec default_stats() :: map()
  def default_stats do
    %{
      message_count: 0,
      summary_count: 0,
      memory_count: 0,
      retrieval_count: 0,
      handoff_count: 0,
      compacted_count: 0
    }
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
     Error.validation("context refs must be a list of Context.Ref structs",
       source: __MODULE__,
       details: %{refs: refs}
     )}
  end

  defp normalize_focus(nil), do: {:ok, nil}
  defp normalize_focus(%Focus{} = focus), do: Focus.validate(focus)

  defp normalize_focus(focus) do
    {:error,
     Error.validation("context last_focus must be a Context.Focus or nil",
       source: __MODULE__,
       details: %{last_focus: focus}
     )}
  end

  defp validate_stats(stats) when is_map(stats), do: :ok

  defp validate_stats(stats) do
    {:error,
     Error.validation("context stats must be a map",
       source: __MODULE__,
       details: %{stats: stats}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
