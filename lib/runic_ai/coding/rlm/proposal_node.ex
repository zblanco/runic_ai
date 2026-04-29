defmodule RunicAI.Coding.RLM.ProposalNode do
  @moduledoc """
  One inert, model-proposable node in an RLM coding workflow.

  Nodes are data until a validator accepts them and the compiler turns them
  into Runic components. String-keyed and string-valued input is accepted so
  structured LLM output can be normalized without atomizing arbitrary user data.
  """

  alias RunicAI.Error

  @allowed_kinds [
    :llm_leaf,
    :tool,
    :command,
    :script,
    :deterministic_step,
    :agent,
    :edit,
    :verification_gate,
    :reducer,
    :review_gate,
    :workflow_patch
  ]

  @enforce_keys [:id, :kind, :inputs, :outputs, :params, :policy, :provenance, :metadata]
  defstruct [
    :id,
    :kind,
    inputs: [],
    outputs: [],
    params: %{},
    policy: %{},
    provenance: [],
    metadata: %{}
  ]

  @type kind ::
          :llm_leaf
          | :tool
          | :command
          | :script
          | :deterministic_step
          | :agent
          | :edit
          | :verification_gate
          | :reducer
          | :review_gate
          | :workflow_patch

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          inputs: [term()],
          outputs: [term()],
          params: map(),
          policy: map(),
          provenance: [term()],
          metadata: map()
        }

  @spec allowed_kinds() :: [kind()]
  def allowed_kinds, do: @allowed_kinds

  @spec new(String.t() | integer(), kind() | String.t(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(id, kind, opts \\ []) when is_list(opts) do
    node = %__MODULE__{
      id: normalize_id(id),
      kind: normalize_kind(kind),
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      params: Keyword.get(opts, :params, %{}),
      policy: Keyword.get(opts, :policy, %{}),
      provenance: Keyword.get(opts, :provenance, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(node)
  end

  @spec new!(String.t() | integer(), kind() | String.t(), keyword()) :: t()
  def new!(id, kind, opts \\ []) do
    case new(id, kind, opts) do
      {:ok, node} -> node
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = node), do: validate(node)

  def from_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, decoded} ->
        from_input(decoded)

      {:error, _error} ->
        {:error,
         Error.validation("proposal node must be a map or ProposalNode",
           source: __MODULE__,
           details: %{input: input}
         )}
    end
  end

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(get(input, :id), get(input, :kind),
      inputs: List.wrap(get(input, :inputs, [])),
      outputs: List.wrap(get(input, :outputs, [])),
      params: normalize_map(get(input, :params, %{})),
      policy: normalize_map(get(input, :policy, %{})),
      provenance: List.wrap(get(input, :provenance, [])),
      metadata: normalize_map(get(input, :metadata, %{}))
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("proposal node must be a map or ProposalNode",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = node) do
    with :ok <- validate_id(node.id),
         :ok <- validate_kind(node.kind),
         :ok <- validate_list(node.inputs, :inputs),
         :ok <- validate_list(node.outputs, :outputs),
         :ok <- validate_map(node.params, :params),
         :ok <- validate_map(node.policy, :policy),
         :ok <- validate_list(node.provenance, :provenance),
         :ok <- validate_map(node.metadata, :metadata) do
      {:ok, node}
    end
  end

  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(nil), do: nil
  defp normalize_id(id), do: to_string(id)

  defp normalize_kind(kind) when kind in @allowed_kinds, do: kind
  defp normalize_kind(kind) when is_binary(kind), do: lookup_kind(kind)
  defp normalize_kind(kind), do: kind

  defp lookup_kind("llm_leaf"), do: :llm_leaf
  defp lookup_kind("tool"), do: :tool
  defp lookup_kind("command"), do: :command
  defp lookup_kind("script"), do: :script
  defp lookup_kind("deterministic_step"), do: :deterministic_step
  defp lookup_kind("agent"), do: :agent
  defp lookup_kind("edit"), do: :edit
  defp lookup_kind("verification_gate"), do: :verification_gate
  defp lookup_kind("reducer"), do: :reducer
  defp lookup_kind("review_gate"), do: :review_gate
  defp lookup_kind("workflow_patch"), do: :workflow_patch
  defp lookup_kind(kind), do: kind

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("proposal node id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_kind(kind) when kind in @allowed_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid proposal node kind",
       source: __MODULE__,
       details: %{kind: kind, allowed_kinds: @allowed_kinds}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("proposal node #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("proposal node #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(value) when is_binary(value), do: decode_map(value)
  defp normalize_map(_value), do: %{}

  defp decode_map(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} when is_list(decoded) -> Map.new(decoded)
      _other -> %{}
    end
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
