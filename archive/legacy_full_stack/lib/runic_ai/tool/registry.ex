defmodule RunicAI.Tool.Registry do
  @moduledoc """
  Deterministic registry of available tool definitions.
  """

  alias RunicAI.Error
  alias RunicAI.Tool.Definition

  @enforce_keys [:tools, :metadata]
  defstruct [:tools, :metadata]

  @type t :: %__MODULE__{
          tools: [Definition.t()],
          metadata: map()
        }

  @spec new([Definition.t() | keyword()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(tools \\ [], opts \\ []) when is_list(tools) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_tools} <- normalize_tools(tools),
         :ok <- validate_unique_names(normalized_tools),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{tools: normalized_tools, metadata: metadata}}
    end
  end

  @spec new!([Definition.t() | keyword()], keyword()) :: t()
  def new!(tools \\ [], opts \\ []) do
    case new(tools, opts) do
      {:ok, registry} -> registry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | [Definition.t() | keyword()] | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = registry), do: validate(registry)
  def from_input(tools) when is_list(tools), do: new(tools)

  def from_input(other) do
    {:error,
     Error.validation("expected a Tool.Registry-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | [Definition.t() | keyword()] | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, registry} -> registry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = registry) do
    new(registry.tools, metadata: registry.metadata)
  end

  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{tools: tools}), do: Enum.map(tools, & &1.name)

  @spec fetch(t(), String.t()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def fetch(%__MODULE__{tools: tools}, name) when is_binary(name) do
    case Enum.find(tools, &(&1.name == name)) do
      %Definition{} = definition ->
        {:ok, definition}

      nil ->
        {:error,
         Error.validation("unknown tool: #{inspect(name)}",
           source: __MODULE__,
           details: %{
             tool_name: name,
             available_tools: names(%__MODULE__{tools: tools, metadata: %{}})
           }
         )}
    end
  end

  @spec fetch!(t(), String.t()) :: Definition.t()
  def fetch!(%__MODULE__{} = registry, name) do
    case fetch(registry, name) do
      {:ok, definition} -> definition
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_tools(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case normalize_tool(tool) do
        {:ok, normalized_tool} -> {:cont, {:ok, [normalized_tool | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_tools} -> {:ok, Enum.reverse(normalized_tools)}
      error -> error
    end
  end

  defp normalize_tool(%Definition{} = definition), do: Definition.validate(definition)
  defp normalize_tool(opts) when is_list(opts), do: Definition.new(opts)

  defp normalize_tool(other) do
    {:error,
     Error.validation("registry tools must be Tool.Definition values or keyword opts",
       source: __MODULE__,
       details: %{tool: other}
     )}
  end

  defp validate_unique_names(tools) do
    names = Enum.map(tools, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        {:error,
         Error.validation("tool registry names must be unique",
           source: __MODULE__,
           details: %{duplicate_names: duplicates}
         )}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool registry metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
