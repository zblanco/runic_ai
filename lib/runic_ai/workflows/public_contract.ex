defmodule RunicAI.Workflows.PublicContract do
  @moduledoc """
  Version-pinned public invocation contract for an activated workflow revision.
  """

  alias RunicAI.Error
  alias RunicAI.Workflows.IR

  @enforce_keys [
    :workflow_key,
    :revision_id,
    :revision,
    :definition_hash,
    :contract_hash,
    :inputs,
    :adaptation_inputs,
    :outputs
  ]
  @derive Jason.Encoder
  defstruct [
    :workflow_key,
    :revision_id,
    :revision,
    :definition_hash,
    :contract_hash,
    inputs: %{},
    adaptation_inputs: %{},
    outputs: %{},
    effects: [],
    policies: %{},
    acceptance: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec from_revision(struct(), struct()) :: {:ok, t()} | {:error, Error.t()}
  def from_revision(workflow, revision) do
    with {:ok, ir} <- IR.from_input(revision.ir_json) do
      declared = value(revision.metadata_json || %{}, :public_contract, %{})
      core = core(ir, declared)
      contract_hash = revision.contract_hash || semantic_hash(core)

      {:ok,
       struct!(__MODULE__,
         workflow_key: workflow.workflow_key,
         revision_id: revision.id,
         revision: revision.revision,
         definition_hash: revision.semantic_hash,
         contract_hash: contract_hash,
         inputs: core.inputs,
         adaptation_inputs: core.adaptation_inputs,
         outputs: core.outputs,
         effects: core.effects,
         policies: core.policies,
         acceptance: core.acceptance,
         metadata: value(declared, :metadata, %{})
       )}
    end
  end

  @spec semantic_hash(map()) :: String.t()
  def semantic_hash(contract) when is_map(contract) do
    contract
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec hash_for_ir(IR.t(), map()) :: String.t()
  def hash_for_ir(%IR{} = ir, metadata \\ %{}) do
    declared = value(metadata, :public_contract, %{})
    ir |> core(declared) |> semantic_hash()
  end

  @spec validate_input(t(), term()) :: :ok | {:error, Error.t()}
  def validate_input(%__MODULE__{} = contract, input) do
    validate_value(input, contract.inputs, :input, contract)
  end

  @doc """
  Validates whether an invocation has the structural shape needed to adapt a
  saved workflow safely before execution.

  Exact invocation constants remain enforced by `validate_input/2`. The
  adaptation contract deliberately removes value pins while preserving object,
  collection, required-field, and nested type constraints.
  """
  @spec validate_adaptation_input(t(), term()) :: :ok | {:error, Error.t()}
  def validate_adaptation_input(%__MODULE__{} = contract, input) do
    validate_value(input, contract.adaptation_inputs, :adaptation_input, contract)
  end

  @spec validate_output(t(), term()) :: :ok | {:error, Error.t()}
  def validate_output(%__MODULE__{} = contract, output) do
    validate_value(output, contract.outputs, :output, contract)
  end

  defp core(ir, declared) do
    inputs = value(declared, :inputs, %{})

    %{
      # IR inputs describe bound workflow resources; they are not necessarily
      # a JSON Schema for callers. Reuse requires an explicitly declared
      # public invocation contract rather than treating source descriptors as
      # an unconstrained schema.
      inputs: inputs,
      adaptation_inputs: value(declared, :adaptation_inputs, relax_for_adaptation(inputs)),
      outputs: value(declared, :outputs, value(ir.metadata, :public_outputs, %{})),
      effects:
        value(
          declared,
          :effects,
          ir.nodes |> Map.values() |> Enum.flat_map(& &1.effects) |> Enum.uniq() |> Enum.sort()
        ),
      policies: value(declared, :policies, ir.policies || %{}),
      acceptance: value(declared, :acceptance, ir.acceptance || [])
    }
  end

  defp relax_for_adaptation(schema) when is_map(schema) do
    schema
    |> Enum.reject(fn {key, _value} -> to_string(key) in ["const", "enum"] end)
    |> Map.new(fn {key, value} ->
      cond do
        to_string(key) == "properties" and is_map(value) ->
          {key,
           Map.new(value, fn {child_key, child} ->
             {child_key, relax_for_adaptation(child)}
           end)}

        to_string(key) == "items" ->
          {key, relax_for_adaptation(value)}

        true ->
          {key, value}
      end
    end)
  end

  defp relax_for_adaptation(schema), do: schema

  defp validate_value(_value, schema, _direction, _contract) when schema in [%{}, nil], do: :ok

  defp validate_value(value, schema, direction, contract) when is_map(schema) do
    case matches_schema(value, schema, "$") do
      :ok ->
        :ok

      {:error, path, expected, actual} ->
        {:error,
         Error.validation("saved workflow #{direction} does not match its public contract",
           source: __MODULE__,
           details: %{
             code: :workflow_public_contract_mismatch,
             direction: direction,
             workflow_key: contract.workflow_key,
             revision_id: contract.revision_id,
             path: path,
             expected: expected,
             actual: actual
           }
         )}
    end
  end

  defp validate_value(_value, schema, direction, contract) do
    {:error,
     Error.validation("saved workflow #{direction} contract must be a JSON schema map",
       source: __MODULE__,
       details: %{
         code: :invalid_workflow_public_contract,
         workflow_key: contract.workflow_key,
         schema: schema
       }
     )}
  end

  defp matches_schema(value, schema, path) do
    type = value(schema, :type, nil)

    with :ok <- matches_const(value, value(schema, :const, :not_declared), path),
         :ok <- matches_type(value, type, path),
         :ok <- matches_required(value, schema, path),
         :ok <- matches_properties(value, schema, path),
         :ok <- matches_items(value, schema, path) do
      :ok
    end
  end

  defp matches_const(_value, :not_declared, _path), do: :ok
  defp matches_const(value, value, _path), do: :ok
  defp matches_const(value, expected, path), do: {:error, path, expected, value}

  defp matches_type(_value, nil, _path), do: :ok
  defp matches_type(value, "object", _path) when is_map(value), do: :ok
  defp matches_type(value, "array", _path) when is_list(value), do: :ok
  defp matches_type(value, "string", _path) when is_binary(value), do: :ok
  defp matches_type(value, "integer", _path) when is_integer(value), do: :ok
  defp matches_type(value, "number", _path) when is_number(value), do: :ok
  defp matches_type(value, "boolean", _path) when is_boolean(value), do: :ok
  defp matches_type(nil, "null", _path), do: :ok
  defp matches_type(_value, "any", _path), do: :ok
  defp matches_type(value, type, path), do: {:error, path, type, type_name(value)}

  defp matches_required(value, schema, path) when is_map(value) do
    schema
    |> value(:required, [])
    |> Enum.find(&(not has_key?(value, &1)))
    |> case do
      nil -> :ok
      key -> {:error, "#{path}.#{key}", "required", "missing"}
    end
  end

  defp matches_required(_value, _schema, _path), do: :ok

  defp matches_properties(value, schema, path) when is_map(value) do
    schema
    |> value(:properties, %{})
    |> Enum.reduce_while(:ok, fn {key, child_schema}, :ok ->
      case fetch_key(value, key) do
        :error ->
          {:cont, :ok}

        {:ok, child} ->
          case matches_schema(child, child_schema, "#{path}.#{key}") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp matches_properties(_value, _schema, _path), do: :ok

  defp matches_items(value, schema, path) when is_list(value) do
    case value(schema, :items, nil) do
      nil ->
        :ok

      item_schema ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
          case matches_schema(item, item_schema, "#{path}[#{index}]") do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp matches_items(_value, _schema, _path), do: :ok

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_binary(key) and Map.has_key?(map, existing_atom(key)) ->
        {:ok, Map.fetch!(map, existing_atom(key))}

      true ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp has_key?(map, key), do: match?({:ok, _value}, fetch_key(map, key))
  defp existing_atom(key), do: String.to_existing_atom(key)

  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(nil), do: "null"
  defp type_name(_value), do: "unknown"

  defp canonicalize(value) when is_struct(value), do: value |> Map.from_struct() |> canonicalize()

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, child} -> {to_string(key), canonicalize(child)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value) when is_atom(value), do: Atom.to_string(value)
  defp canonicalize(value), do: value

  defp value(input, key, default) when is_map(input) do
    Map.get(input, key, Map.get(input, Atom.to_string(key), default))
  end
end
