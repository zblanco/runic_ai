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
    :computing,
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
          | :computing
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
    kind = normalize_kind(kind)
    params = normalize_params(kind, Keyword.get(opts, :params, %{}))
    {kind, params} = normalize_kind_and_params(kind, params)

    node = %__MODULE__{
      id: normalize_id(id),
      kind: kind,
      inputs: Keyword.get(opts, :inputs, []),
      outputs: Keyword.get(opts, :outputs, []),
      params: params,
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
  defp lookup_kind("computing"), do: :computing
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

  defp normalize_params(:agent, params) do
    params = normalize_map(params)

    case get(params, :mode) do
      mode when mode in ["review_repair", :review_repair, "repair", :repair] ->
        put_param(params, :mode, "patch")

      mode when mode in ["write_tests", :write_tests, "test_writer", :test_writer] ->
        put_param(params, :mode, "write_tests")

      mode when mode in ["verify", :verify, "verification", :verification] ->
        put_param(params, :mode, "verify")

      mode when mode in ["patch", :patch, "edit", :edit, "implement", :implement] ->
        put_param(params, :mode, "patch")

      _other ->
        params
    end
  end

  defp normalize_params(:deterministic_step, params) do
    params = normalize_map(params)

    cond do
      present?(get(params, :action)) ->
        params

      present?(get(params, :value)) ->
        put_param(params, :action, "constant")

      contract_like_step?(params) ->
        params
        |> put_param(:action, "constant")
        |> put_param(:value, deterministic_contract_value(params))

      true ->
        params
    end
  end

  defp normalize_params(_kind, params), do: normalize_map(params)

  defp normalize_kind_and_params(:edit, params) do
    operations = List.wrap(get(params, :operations, []))

    if operations != [] and Enum.all?(operations, &abstract_edit_intent?/1) do
      {:review_gate,
       %{
         focus:
           Enum.map(operations, fn operation ->
             operation = normalize_map(operation)

             get(operation, :description) || get(operation, :type) ||
               inspect(operation, limit: 10)
           end)
       }}
    else
      {:edit, params}
    end
  end

  defp normalize_kind_and_params(kind, params), do: {kind, params}

  defp abstract_edit_intent?(operation) do
    operation = normalize_map(operation)

    get(operation, :kind) in [nil, ""] and get(operation, :op) in [nil, ""] and
      get(operation, :type) not in [
        "apply_unified_patch",
        "replace_file",
        "create_file",
        "delete_file",
        "format_files"
      ]
  end

  defp contract_like_step?(params) do
    present?(get(params, :contract)) or present?(get(params, :task)) or
      present?(get(params, :outputs)) or present?(get(params, :purpose)) or
      present?(get(params, :requirements))
  end

  defp deterministic_contract_value(params) do
    %{}
    |> maybe_put(:contract, get(params, :contract))
    |> maybe_put(:task, get(params, :task))
    |> maybe_put(:outputs, get(params, :outputs))
    |> maybe_put(:purpose, get(params, :purpose))
    |> maybe_put(:requirements, get(params, :requirements))
  end

  defp put_param(map, key, value) do
    string_key = Atom.to_string(key)

    map
    |> Map.delete(key)
    |> Map.delete(string_key)
    |> Map.put(key, value)
  end

  defp maybe_put(map, _key, value) when value in [nil, "", []], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(value), do: value not in [nil, "", []]

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
