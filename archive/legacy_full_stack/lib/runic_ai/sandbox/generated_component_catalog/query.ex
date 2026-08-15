defmodule RunicAI.Sandbox.GeneratedComponentCatalog.Query do
  @moduledoc """
  Lookup contract for generated component catalog retrieval.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry

  @enforce_keys [
    :objective,
    :intent_tags,
    :inputs,
    :outputs,
    :component_kind,
    :runtime,
    :policy,
    :top_k,
    :metadata
  ]
  @derive Jason.Encoder
  defstruct [
    :objective,
    :intent_tags,
    :inputs,
    :outputs,
    :component_kind,
    :runtime,
    :policy,
    :top_k,
    :metadata
  ]

  @type t :: %__MODULE__{
          objective: String.t(),
          intent_tags: [atom() | String.t()],
          inputs: [map()],
          outputs: [map()],
          component_kind: Entry.component_kind() | nil,
          runtime: atom() | String.t() | nil,
          policy: map(),
          top_k: pos_integer(),
          metadata: map()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)

    with :ok <- validate_objective(get(input, :objective, "")),
         {:ok, intent_tags} <- normalize_tags(get(input, :intent_tags, [])),
         {:ok, inputs} <- normalize_signature(get(input, :inputs, []), :inputs),
         {:ok, outputs} <- normalize_signature(get(input, :outputs, []), :outputs),
         {:ok, component_kind} <- normalize_optional_kind(get(input, :component_kind)),
         :ok <- validate_optional_runtime(get(input, :runtime)),
         {:ok, policy} <- normalize_map(get(input, :policy, %{}), :policy),
         :ok <- validate_top_k(get(input, :top_k, 5)),
         {:ok, metadata} <- normalize_map(get(input, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         objective: get(input, :objective, ""),
         intent_tags: intent_tags,
         inputs: inputs,
         outputs: outputs,
         component_kind: component_kind,
         runtime: get(input, :runtime),
         policy: policy,
         top_k: get(input, :top_k, 5),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, query} -> query
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = query) do
    new(%{
      objective: query.objective,
      intent_tags: query.intent_tags,
      inputs: query.inputs,
      outputs: query.outputs,
      component_kind: query.component_kind,
      runtime: query.runtime,
      policy: query.policy,
      top_k: query.top_k,
      metadata: query.metadata
    })
  end

  defp validate_objective(objective) when is_binary(objective) and objective != "", do: :ok

  defp validate_objective(objective) do
    {:error,
     Error.validation("generated component catalog query objective must be a non-empty string",
       source: __MODULE__,
       details: %{objective: objective}
     )}
  end

  defp normalize_tags(tags) when is_list(tags) do
    {:ok, Enum.map(tags, &normalize_tag/1)}
  rescue
    ArgumentError ->
      {:error,
       Error.validation("generated component catalog query tags must be atoms or strings",
         source: __MODULE__,
         details: %{intent_tags: tags}
       )}
  end

  defp normalize_tags(tags) do
    {:error,
     Error.validation("generated component catalog query intent_tags must be a list",
       source: __MODULE__,
       details: %{intent_tags: tags}
     )}
  end

  defp normalize_tag(tag) when is_atom(tag), do: tag

  defp normalize_tag(tag) when is_binary(tag) and tag != "" do
    normalized =
      tag |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

    if normalized == "", do: raise(ArgumentError), else: normalized
  end

  defp normalize_tag(_tag), do: raise(ArgumentError)

  defp normalize_signature(value, _field) when is_list(value) do
    if Enum.all?(value, &(is_map(&1) or is_binary(&1))) do
      {:ok,
       Enum.map(value, fn
         port when is_map(port) -> port
         port when is_binary(port) -> %{name: port}
       end)}
    else
      {:error,
       Error.validation("generated component catalog query signatures require maps or names",
         source: __MODULE__,
         details: %{value: value}
       )}
    end
  end

  defp normalize_signature(value, field) do
    {:error,
     Error.validation("generated component catalog query #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_optional_kind(nil), do: {:ok, nil}

  defp normalize_optional_kind(kind) when is_atom(kind) do
    if kind in Entry.component_kinds(), do: {:ok, kind}, else: invalid_kind(kind)
  end

  defp normalize_optional_kind(kind) when is_binary(kind) do
    Entry.component_kinds()
    |> Enum.find(&(Atom.to_string(&1) == String.replace(kind, "-", "_")))
    |> case do
      nil -> invalid_kind(kind)
      kind -> {:ok, kind}
    end
  end

  defp normalize_optional_kind(kind), do: invalid_kind(kind)

  defp invalid_kind(kind) do
    {:error,
     Error.validation("invalid generated component catalog query component_kind",
       source: __MODULE__,
       details: %{component_kind: kind, valid: Entry.component_kinds()}
     )}
  end

  defp validate_optional_runtime(nil), do: :ok
  defp validate_optional_runtime(runtime) when is_atom(runtime), do: :ok
  defp validate_optional_runtime(runtime) when is_binary(runtime) and runtime != "", do: :ok

  defp validate_optional_runtime(runtime) do
    {:error,
     Error.validation("generated component catalog query runtime must be an atom, string, or nil",
       source: __MODULE__,
       details: %{runtime: runtime}
     )}
  end

  defp validate_top_k(top_k) when is_integer(top_k) and top_k > 0, do: :ok

  defp validate_top_k(top_k) do
    {:error,
     Error.validation("generated component catalog query top_k must be a positive integer",
       source: __MODULE__,
       details: %{top_k: top_k}
     )}
  end

  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map(value, field) do
    {:error,
     Error.validation("generated component catalog query #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
