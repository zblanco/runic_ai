defmodule RunicAI.RLM.ContextSliceContract do
  @moduledoc """
  Contract for one bounded context slice in a Lambda-style RLM plan.

  The contract describes what may be read from an external source, how large the
  slice may be, what shape a leaf output should have, and how the result should
  be merged or reviewed. It intentionally references external context through
  `RunicAI.RLM.EnvironmentRef` rather than copying content into the root model
  prompt.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.EnvironmentRef

  @source_kinds [
    :text,
    :document,
    :code,
    :structured,
    :artifact,
    :sandbox_file,
    :trace_range,
    :workspace_selection,
    :database_query,
    :graph_slice
  ]

  @enforce_keys [:id, :source_ref, :source_kind, :provenance, :metadata]
  defstruct [
    :id,
    :source_ref,
    :source_kind,
    :slice_id,
    :token_budget,
    :byte_budget,
    :expected_output_schema,
    :merge_policy,
    :review_policy,
    provenance: [],
    metadata: %{}
  ]

  @type source_kind ::
          :text
          | :document
          | :code
          | :structured
          | :artifact
          | :sandbox_file
          | :trace_range
          | :workspace_selection
          | :database_query
          | :graph_slice

  @type t :: %__MODULE__{
          id: String.t(),
          source_ref: EnvironmentRef.t(),
          source_kind: source_kind(),
          slice_id: String.t() | nil,
          token_budget: pos_integer() | nil,
          byte_budget: pos_integer() | nil,
          expected_output_schema: term(),
          merge_policy: term(),
          review_policy: term(),
          provenance: [term()],
          metadata: map()
        }

  @spec source_kinds() :: [source_kind()]
  def source_kinds, do: @source_kinds

  @spec new(EnvironmentRef.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(%EnvironmentRef{} = source_ref, opts \\ []) when is_list(opts) do
    id = Keyword.get(opts, :id) || default_id(source_ref)
    source_kind = Keyword.get(opts, :source_kind) || source_kind_from_ref(source_ref)
    provenance = Keyword.get(opts, :provenance, [source_ref])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, source_ref} <- EnvironmentRef.validate(source_ref),
         :ok <- validate_id(id),
         {:ok, source_kind} <- normalize_source_kind(source_kind),
         :ok <- validate_optional_string(Keyword.get(opts, :slice_id), :slice_id),
         :ok <- validate_optional_positive_count(Keyword.get(opts, :token_budget), :token_budget),
         :ok <- validate_optional_positive_count(Keyword.get(opts, :byte_budget), :byte_budget),
         :ok <- validate_output_schema(Keyword.get(opts, :expected_output_schema)),
         :ok <- validate_policy(Keyword.get(opts, :merge_policy), :merge_policy),
         :ok <- validate_policy(Keyword.get(opts, :review_policy), :review_policy),
         :ok <- validate_provenance(provenance),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         id: id,
         source_ref: source_ref,
         source_kind: source_kind,
         slice_id: Keyword.get(opts, :slice_id),
         token_budget: Keyword.get(opts, :token_budget),
         byte_budget: Keyword.get(opts, :byte_budget),
         expected_output_schema: Keyword.get(opts, :expected_output_schema),
         merge_policy: Keyword.get(opts, :merge_policy),
         review_policy: Keyword.get(opts, :review_policy),
         provenance: provenance,
         metadata: metadata
       }}
    end
  end

  @spec new!(EnvironmentRef.t(), keyword()) :: t()
  def new!(%EnvironmentRef{} = source_ref, opts \\ []) do
    case new(source_ref, opts) do
      {:ok, contract} -> contract
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = contract) do
    new(contract.source_ref,
      id: contract.id,
      source_kind: contract.source_kind,
      slice_id: contract.slice_id,
      token_budget: contract.token_budget,
      byte_budget: contract.byte_budget,
      expected_output_schema: contract.expected_output_schema,
      merge_policy: contract.merge_policy,
      review_policy: contract.review_policy,
      provenance: contract.provenance,
      metadata: contract.metadata
    )
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = contract), do: validate(contract)

  def from_input(input) when is_map(input) do
    case map_get(input, :source_ref) do
      %EnvironmentRef{} = source_ref ->
        new(source_ref,
          id: map_get(input, :id),
          source_kind: map_get(input, :source_kind),
          slice_id: map_get(input, :slice_id),
          token_budget: map_get(input, :token_budget),
          byte_budget: map_get(input, :byte_budget),
          expected_output_schema: map_get(input, :expected_output_schema),
          merge_policy: map_get(input, :merge_policy),
          review_policy: map_get(input, :review_policy),
          provenance: map_get(input, :provenance) || [source_ref],
          metadata: map_get(input, :metadata) || %{}
        )

      other ->
        {:error,
         Error.validation("context slice contract requires an EnvironmentRef source_ref",
           source: __MODULE__,
           details: %{source_ref: other}
         )}
    end
  end

  def from_input(input) when is_list(input), do: input |> Map.new() |> from_input()

  defp default_id(%EnvironmentRef{} = source_ref), do: "context-slice:#{source_ref.source_id}"

  defp source_kind_from_ref(%EnvironmentRef{} = source_ref) do
    case Map.get(source_ref.metadata, :source_kind) || Map.get(source_ref.metadata, "source_kind") do
      kind when kind in @source_kinds -> kind
      kind when is_binary(kind) -> kind
      _other -> :text
    end
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("context slice contract id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp normalize_source_kind(kind) when kind in @source_kinds, do: {:ok, kind}

  defp normalize_source_kind(kind) when is_binary(kind) do
    Enum.find(@source_kinds, &(Atom.to_string(&1) == kind))
    |> case do
      nil -> invalid_source_kind(kind)
      kind -> {:ok, kind}
    end
  end

  defp normalize_source_kind(kind), do: invalid_source_kind(kind)

  defp invalid_source_kind(kind) do
    {:error,
     Error.validation("invalid context slice source kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{source_kind: kind, valid_source_kinds: @source_kinds}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, _field) when is_binary(value), do: :ok

  defp validate_optional_string(value, field) do
    {:error,
     Error.validation("#{field} must be a string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_positive_count(nil, _field), do: :ok

  defp validate_optional_positive_count(value, _field) when is_integer(value) and value > 0,
    do: :ok

  defp validate_optional_positive_count(value, field) do
    {:error,
     Error.validation("#{field} must be a positive integer or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_output_schema(nil), do: :ok

  defp validate_output_schema(schema)
       when is_atom(schema) or is_binary(schema) or is_map(schema) or is_list(schema),
       do: :ok

  defp validate_output_schema(schema) do
    {:error,
     Error.validation("expected_output_schema must be an atom, string, map, list, or nil",
       source: __MODULE__,
       details: %{expected_output_schema: schema}
     )}
  end

  defp validate_policy(nil, _field), do: :ok

  defp validate_policy(value, _field)
       when is_atom(value) or is_binary(value) or is_map(value) or is_list(value),
       do: :ok

  defp validate_policy(value, field) do
    {:error,
     Error.validation("#{field} must be an atom, string, map, list, or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_provenance([_first | _rest]), do: :ok

  defp validate_provenance(provenance) do
    {:error,
     Error.validation("context slice provenance must be a non-empty list",
       source: __MODULE__,
       details: %{provenance: provenance}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("context slice metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp map_get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
