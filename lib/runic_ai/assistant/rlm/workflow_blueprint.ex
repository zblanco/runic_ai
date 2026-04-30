defmodule RunicAI.Assistant.RLM.WorkflowBlueprint do
  @moduledoc """
  Data contract for generated assistant RLM workflows.

  A workflow blueprint describes a Runic graph without generated Elixir modules
  or files. The compiler turns accepted component and function blueprints into
  ordinary Runic components backed by trusted anonymous functions.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Error

  @enforce_keys [:id, :objective]
  @derive Jason.Encoder
  defstruct [
    :id,
    :objective,
    sources: [],
    components: [],
    edges: [],
    stop_conditions: [],
    policies: %{},
    metadata: %{}
  ]

  @type edge :: %{required(:from) => String.t(), required(:to) => String.t()}
  @type source :: %{
          required(:id) => String.t(),
          required(:path) => Path.t(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          sources: [source()],
          components: [ComponentBlueprint.t()],
          edges: [edge()],
          stop_conditions: [String.t()],
          policies: map(),
          metadata: map()
        }

  @spec new(String.t(), [ComponentBlueprint.t() | map()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(objective, components, opts \\ []) when is_list(components) and is_list(opts) do
    id = Keyword.get(opts, :id) || "assistant_blueprint:#{System.unique_integer([:positive])}"

    with :ok <- validate_id(id),
         :ok <- validate_objective(objective),
         {:ok, components} <- normalize_components(components),
         {:ok, sources} <- normalize_sources(Keyword.get(opts, :sources, [])),
         {:ok, edges} <- normalize_edges(Keyword.get(opts, :edges, [])),
         :ok <- validate_list(Keyword.get(opts, :stop_conditions, []), :stop_conditions),
         :ok <- validate_map(Keyword.get(opts, :policies, %{}), :policies),
         :ok <- validate_map(Keyword.get(opts, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         objective: objective,
         sources: sources,
         components: components,
         edges: edges,
         stop_conditions: Keyword.get(opts, :stop_conditions, []),
         policies: Keyword.get(opts, :policies, %{}),
         metadata: Keyword.get(opts, :metadata, %{})
       }}
    end
  end

  @spec new!(String.t(), [ComponentBlueprint.t() | map()], keyword()) :: t()
  def new!(objective, components, opts \\ []) do
    case new(objective, components, opts) do
      {:ok, blueprint} -> blueprint
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = blueprint), do: validate(blueprint)
  def from_input(input) when is_list(input), do: input |> Map.new() |> from_input()

  def from_input(input) when is_map(input) do
    new(get(input, :objective, nil), get(input, :components, get(input, :nodes, [])),
      id: get(input, :id, nil),
      sources: get(input, :sources, []),
      edges: get(input, :edges, []),
      stop_conditions: get(input, :stop_conditions, []),
      policies: get(input, :policies, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("expected an assistant workflow blueprint",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = blueprint) do
    new(blueprint.objective, blueprint.components,
      id: blueprint.id,
      sources: blueprint.sources,
      edges: blueprint.edges,
      stop_conditions: blueprint.stop_conditions,
      policies: blueprint.policies,
      metadata: blueprint.metadata
    )
  end

  @spec component_ids(t()) :: [String.t()]
  def component_ids(%__MODULE__{} = blueprint), do: Enum.map(blueprint.components, & &1.id)

  defp normalize_components(components) do
    components
    |> Enum.reduce_while({:ok, []}, fn component, {:ok, acc} ->
      case ComponentBlueprint.from_input(component) do
        {:ok, component} -> {:cont, {:ok, [component | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_sources(sources) when is_list(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {source, index}, {:ok, acc} ->
      case normalize_source(source, index) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_sources(sources) do
    {:error,
     Error.validation("workflow blueprint sources must be a list",
       source: __MODULE__,
       details: %{sources: sources}
     )}
  end

  defp normalize_source(path, index) when is_binary(path) and path != "" do
    {:ok, %{id: "source_#{index}", path: path}}
  end

  defp normalize_source(source, index) when is_map(source) do
    path = get(source, :path, nil)
    id = get(source, :id, "source_#{index}")

    cond do
      not (is_binary(path) and path != "") ->
        {:error,
         Error.validation("workflow blueprint source path must be a non-empty string",
           source: __MODULE__,
           details: %{source: source}
         )}

      not (is_binary(id) and id != "") ->
        {:error,
         Error.validation("workflow blueprint source id must be a non-empty string",
           source: __MODULE__,
           details: %{source: source}
         )}

      true ->
        {:ok, %{id: id, path: path, metadata: get(source, :metadata, %{})}}
    end
  end

  defp normalize_source(source, _index) do
    {:error,
     Error.validation("workflow blueprint source must be a path or map",
       source: __MODULE__,
       details: %{source: source}
     )}
  end

  defp normalize_edges(edges) when is_list(edges) do
    edges
    |> Enum.reduce_while({:ok, []}, fn edge, {:ok, acc} ->
      case normalize_edge(edge) do
        {:ok, edge} -> {:cont, {:ok, [edge | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_edges(edges) do
    {:error,
     Error.validation("workflow blueprint edges must be a list",
       source: __MODULE__,
       details: %{edges: edges}
     )}
  end

  defp normalize_edge(edge) when is_map(edge) do
    from = get(edge, :from, nil)
    to = get(edge, :to, nil)

    if is_binary(from) and from != "" and is_binary(to) and to != "" do
      {:ok, %{from: from, to: to}}
    else
      {:error,
       Error.validation("workflow blueprint edges require non-empty from and to ids",
         source: __MODULE__,
         details: %{edge: edge}
       )}
    end
  end

  defp normalize_edge(edge) do
    {:error,
     Error.validation("workflow blueprint edge must be a map",
       source: __MODULE__,
       details: %{edge: edge}
     )}
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("workflow blueprint id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_objective(objective) when is_binary(objective) and objective != "", do: :ok

  defp validate_objective(objective) do
    {:error,
     Error.validation("workflow blueprint objective must be a non-empty string",
       source: __MODULE__,
       details: %{objective: objective}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("workflow blueprint #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("workflow blueprint #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
