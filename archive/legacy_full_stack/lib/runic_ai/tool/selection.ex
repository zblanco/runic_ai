defmodule RunicAI.Tool.Selection do
  @moduledoc """
  Per-turn selected visible tool set.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.Definition
  alias RunicAI.Tool.Registry

  @enforce_keys [:registry, :visible_tools, :hidden_tools, :metadata]
  defstruct [:registry, :visible_tools, :hidden_tools, :reason, :metadata]

  @type t :: %__MODULE__{
          registry: Registry.t(),
          visible_tools: [Definition.t()],
          hidden_tools: [String.t()],
          reason: atom() | String.t() | nil,
          metadata: map()
        }

  @spec new(Registry.t(), [Definition.t() | String.t()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(%Registry{} = registry, visible_tools \\ [], opts \\ []) when is_list(opts) do
    reason = Keyword.get(opts, :reason)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, registry} <- Registry.validate(registry),
         {:ok, normalized_visible} <- normalize_visible_tools(registry, visible_tools),
         :ok <- validate_metadata(metadata) do
      visible_names = Enum.map(normalized_visible, & &1.name)
      hidden_tools = Registry.names(registry) -- visible_names

      {:ok,
       %__MODULE__{
         registry: registry,
         visible_tools: normalized_visible,
         hidden_tools: hidden_tools,
         reason: reason,
         metadata: metadata
       }}
    end
  end

  @spec new!(Registry.t(), [Definition.t() | String.t()], keyword()) :: t()
  def new!(%Registry{} = registry, visible_tools \\ [], opts \\ []) do
    case new(registry, visible_tools, opts) do
      {:ok, selection} -> selection
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = selection) do
    new(selection.registry, selection.visible_tools,
      reason: selection.reason,
      metadata: selection.metadata
    )
  end

  @spec visible_names(t()) :: [String.t()]
  def visible_names(%__MODULE__{visible_tools: visible_tools}),
    do: Enum.map(visible_tools, & &1.name)

  @spec fetch_visible(t(), String.t()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def fetch_visible(%__MODULE__{visible_tools: visible_tools}, name) do
    case Enum.find(visible_tools, &(&1.name == name)) do
      %Definition{} = definition ->
        {:ok, definition}

      nil ->
        {:error,
         Error.validation("tool is not visible for this turn: #{inspect(name)}",
           source: __MODULE__,
           details: %{tool_name: name, visible_tools: Enum.map(visible_tools, & &1.name)}
         )}
    end
  end

  @spec fetch_visible!(t(), String.t()) :: Definition.t()
  def fetch_visible!(%__MODULE__{} = selection, name) do
    case fetch_visible(selection, name) do
      {:ok, definition} -> definition
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_req_llm_tools(t()) :: {:ok, [ReqLLM.Tool.t()]} | {:error, Error.t()}
  def to_req_llm_tools(%__MODULE__{visible_tools: visible_tools}) do
    visible_tools
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, acc} ->
      case Definition.to_req_llm_tool(definition) do
        {:ok, req_tool} -> {:cont, {:ok, [req_tool | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, req_tools} -> {:ok, Enum.reverse(req_tools)}
      error -> error
    end
  end

  defp normalize_visible_tools(registry, visible_tools) do
    visible_tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case normalize_visible_tool(registry, tool) do
        {:ok, normalized_tool} -> {:cont, {:ok, [normalized_tool | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_tools} -> {:ok, Enum.reverse(normalized_tools)}
      error -> error
    end
  end

  defp normalize_visible_tool(_registry, %Definition{} = definition),
    do: Definition.validate(definition)

  defp normalize_visible_tool(registry, name) when is_binary(name),
    do: Registry.fetch(registry, name)

  defp normalize_visible_tool(_registry, other) do
    {:error,
     Error.validation("visible tools must be tool names or Tool.Definition values",
       source: __MODULE__,
       details: %{visible_tool: other}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool selection metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
