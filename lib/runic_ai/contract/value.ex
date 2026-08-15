defmodule RunicAI.Contract.Value do
  @moduledoc """
  Canonical, JSON-safe value contracts shared by workflow boundaries.

  The struct is convenient inside Elixir. `encode/1` is the durable wire form
  and uses the neutral identifier `runic.contract/value/v1`.
  """

  alias RunicAI.JSONValue

  @wire_id "runic.contract/value/v1"
  @types ~w(any null boolean integer number string enum literal object list union ref)
  @annotation_keys ~w(description examples sensitivity content_type)

  @enforce_keys [:type]
  defstruct type: nil,
            nullable: false,
            optional: false,
            description: nil,
            examples: [],
            sensitivity: [],
            content_type: nil,
            enum: nil,
            literal: :unset,
            properties: %{},
            required: [],
            additional_properties: true,
            items: nil,
            min_items: nil,
            max_items: nil,
            one_of: [],
            ref: nil,
            ref_version: nil

  @type type ::
          :any
          | :null
          | :boolean
          | :integer
          | :number
          | :string
          | :enum
          | :literal
          | :object
          | :list
          | :union
          | :ref

  @type t :: %__MODULE__{type: type()}
  @type issue :: JSONValue.issue()

  @spec version() :: pos_integer()
  def version, do: 1

  @spec wire_id() :: String.t()
  def wire_id, do: @wire_id

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [issue()]}
  def new(%__MODULE__{} = contract), do: validate_contract(contract)
  def new(input) when is_list(input), do: input |> Map.new() |> new()
  def new(input), do: normalize(input)

  @spec new!(map() | keyword() | t()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, contract} -> contract
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  @spec normalize(term()) :: {:ok, t()} | {:error, [issue()]}
  def normalize(%__MODULE__{} = contract), do: validate_contract(contract)

  def normalize(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         :ok <- validate_wire_id(map),
         {:ok, type} <- decode_type(Map.get(map, "type")),
         {:ok, contract} <- decode_fields(type, map) do
      validate_contract(contract)
    else
      {:ok, _other} -> error([], "value contract must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  @spec decode(term()) :: {:ok, t()} | {:error, [issue()]}
  def decode(input), do: normalize(input)

  @spec validate_contract(t()) :: {:ok, t()} | {:error, [issue()]}
  def validate_contract(%__MODULE__{} = contract) do
    issues =
      []
      |> validate_common(contract)
      |> validate_shape(contract)
      |> Enum.reverse()

    if issues == [], do: {:ok, contract}, else: {:error, issues}
  end

  def validate_contract(_other), do: error([], "expected a value contract")

  @spec encode(t() | map()) :: map()
  def encode(input) do
    contract = if match?(%__MODULE__{}, input), do: input, else: new!(input)

    %{"$contract" => @wire_id, "type" => Atom.to_string(contract.type)}
    |> put_if("nullable", contract.nullable, contract.nullable)
    |> put_if("optional", contract.optional, contract.optional)
    |> put_annotations(contract)
    |> encode_shape(contract)
  end

  @spec semantic_hash(t() | map()) :: String.t()
  def semantic_hash(contract), do: contract |> encode() |> JSONValue.semantic_hash!()

  @spec validate_value(t() | map(), term()) :: :ok | {:error, [issue()]}
  def validate_value(contract, value) do
    with {:ok, normalized_contract} <- normalize(contract),
         {:ok, normalized_value} <- JSONValue.normalize(value) do
      issues = validate_value_at(normalized_contract, normalized_value, []) |> Enum.reverse()
      if issues == [], do: :ok, else: {:error, issues}
    end
  end

  @spec assignable?(t() | map(), t() | map()) :: boolean()
  def assignable?(source, target), do: assignability(source, target) == :ok

  @spec assignability(t() | map(), t() | map()) :: :ok | {:error, [issue()]}
  def assignability(source, target) do
    with {:ok, source} <- normalize(source),
         {:ok, target} <- normalize(target) do
      issues = assignability_at(source, target, []) |> Enum.reverse()
      if issues == [], do: :ok, else: {:error, issues}
    end
  end

  @spec to_json_schema(t() | map()) :: map()
  def to_json_schema(contract) do
    contract = if match?(%__MODULE__{}, contract), do: contract, else: new!(contract)
    schema = json_schema_shape(contract) |> put_schema_annotations(contract)

    if contract.nullable and contract.type != :null do
      %{"anyOf" => [schema, %{"type" => "null"}]}
    else
      schema
    end
  end

  @spec summary(t() | map()) :: String.t()
  def summary(contract) do
    contract = if match?(%__MODULE__{}, contract), do: contract, else: new!(contract)
    base = summary_shape(contract)
    if contract.nullable, do: base <> " or null", else: base
  end

  defp decode_fields(type, map) do
    base = %__MODULE__{
      type: type,
      nullable: Map.get(map, "nullable", false),
      optional: Map.get(map, "optional", false),
      description: Map.get(map, "description"),
      examples: Map.get(map, "examples", []),
      sensitivity: Map.get(map, "sensitivity", []),
      content_type: Map.get(map, "content_type")
    }

    decode_shape(base, map)
  end

  defp decode_shape(%{type: :enum} = contract, map),
    do: {:ok, %{contract | enum: Map.get(map, "values")}}

  defp decode_shape(%{type: :literal} = contract, map),
    do: {:ok, %{contract | literal: Map.get(map, "value", :unset)}}

  defp decode_shape(%{type: :object} = contract, map) do
    with {:ok, properties} <- decode_properties(Map.get(map, "properties", %{})) do
      {:ok,
       %{
         contract
         | properties: properties,
           required: Map.get(map, "required", []),
           additional_properties: Map.get(map, "additional_properties", true)
       }}
    end
  end

  defp decode_shape(%{type: :list} = contract, map) do
    with {:ok, items} <- normalize(Map.get(map, "items", %{"type" => "any"})) do
      {:ok,
       %{
         contract
         | items: items,
           min_items: Map.get(map, "min_items"),
           max_items: Map.get(map, "max_items")
       }}
    end
  end

  defp decode_shape(%{type: :union} = contract, map) do
    with {:ok, one_of} <- decode_contract_list(Map.get(map, "one_of", []), ["one_of"]) do
      {:ok, %{contract | one_of: one_of}}
    end
  end

  defp decode_shape(%{type: :ref} = contract, map) do
    {:ok, %{contract | ref: Map.get(map, "ref"), ref_version: Map.get(map, "version")}}
  end

  defp decode_shape(contract, _map), do: {:ok, contract}

  defp decode_properties(properties) when is_map(properties) do
    properties
    |> Enum.reduce({:ok, %{}}, fn {name, contract}, acc ->
      case {acc, normalize(contract)} do
        {{:ok, decoded}, {:ok, value_contract}} ->
          {:ok, Map.put(decoded, name, value_contract)}

        {{:ok, _decoded}, {:error, issues}} ->
          {:error, prefix_issues(issues, ["properties", name])}

        {{:error, issues}, _result} ->
          {:error, issues}
      end
    end)
  end

  defp decode_properties(_other), do: error(["properties"], "must be an object")

  defp decode_contract_list(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce({:ok, []}, fn {value, index}, acc ->
      case {acc, normalize(value)} do
        {{:ok, decoded}, {:ok, contract}} -> {:ok, [contract | decoded]}
        {{:ok, _decoded}, {:error, issues}} -> {:error, prefix_issues(issues, path ++ [index])}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_contract_list(_other, path), do: error(path, "must be a list")

  defp decode_type(type) when type in @types,
    do: {:ok, String.to_existing_atom(type)}

  defp decode_type(nil), do: error(["type"], "is required")
  defp decode_type(_type), do: error(["type"], "is not a supported value contract type")

  defp validate_wire_id(%{"$contract" => @wire_id}), do: :ok
  defp validate_wire_id(%{"$contract" => _other}), do: error(["$contract"], "is not #{@wire_id}")
  defp validate_wire_id(_map), do: :ok

  defp validate_common(issues, contract) do
    issues
    |> require_boolean(contract.nullable, ["nullable"])
    |> require_boolean(contract.optional, ["optional"])
    |> require_optional_string(contract.description, ["description"])
    |> require_list(contract.examples, ["examples"])
    |> require_string_list(contract.sensitivity, ["sensitivity"])
    |> require_optional_string(contract.content_type, ["content_type"])
  end

  defp validate_shape(issues, %{type: :enum, enum: values}) do
    if is_list(values) and values != [],
      do: issues,
      else: add_issue(issues, ["values"], "must be a non-empty list")
  end

  defp validate_shape(issues, %{type: :literal, literal: :unset}),
    do: add_issue(issues, ["value"], "is required")

  defp validate_shape(issues, %{type: :object} = contract) do
    issues
    |> require_string_list(contract.required, ["required"])
    |> validate_required_properties(contract)
    |> require_boolean(contract.additional_properties, ["additional_properties"])
  end

  defp validate_shape(issues, %{type: :list} = contract) do
    issues
    |> require_contract(contract.items, ["items"])
    |> require_optional_non_negative_integer(contract.min_items, ["min_items"])
    |> require_optional_non_negative_integer(contract.max_items, ["max_items"])
    |> validate_bounds(contract)
  end

  defp validate_shape(issues, %{type: :union, one_of: one_of}) do
    if is_list(one_of) and length(one_of) >= 2,
      do: issues,
      else: add_issue(issues, ["one_of"], "must contain at least two contracts")
  end

  defp validate_shape(issues, %{type: :ref} = contract) do
    issues
    |> require_non_empty_string(contract.ref, ["ref"])
    |> require_non_empty_string(contract.ref_version, ["version"])
  end

  defp validate_shape(issues, _contract), do: issues

  defp validate_value_at(%{nullable: true}, nil, _path), do: []
  defp validate_value_at(%{type: :any}, _value, _path), do: []
  defp validate_value_at(%{type: :null}, nil, _path), do: []
  defp validate_value_at(%{type: :boolean}, value, _path) when is_boolean(value), do: []
  defp validate_value_at(%{type: :integer}, value, _path) when is_integer(value), do: []
  defp validate_value_at(%{type: :number}, value, _path) when is_number(value), do: []
  defp validate_value_at(%{type: :string}, value, _path) when is_binary(value), do: []

  defp validate_value_at(%{type: :enum, enum: values}, value, path) do
    if value in values, do: [], else: [issue(path, "is not one of the allowed values")]
  end

  defp validate_value_at(%{type: :literal, literal: expected}, value, path) do
    if value == expected, do: [], else: [issue(path, "does not match the literal value")]
  end

  defp validate_value_at(%{type: :object} = contract, value, path) when is_map(value) do
    missing = contract.required -- Map.keys(value)

    unexpected =
      if contract.additional_properties,
        do: [],
        else: Map.keys(value) -- Map.keys(contract.properties)

    property_issues =
      Enum.flat_map(contract.properties, fn {name, property_contract} ->
        case Map.fetch(value, name) do
          {:ok, property_value} ->
            validate_value_at(property_contract, property_value, path ++ [name])

          :error ->
            []
        end
      end)

    Enum.map(missing, &issue(path ++ [&1], "is required")) ++
      Enum.map(unexpected, &issue(path ++ [&1], "is not allowed")) ++ property_issues
  end

  defp validate_value_at(%{type: :list} = contract, value, path) when is_list(value) do
    bound_issues =
      []
      |> maybe_min_items(length(value), contract.min_items, path)
      |> maybe_max_items(length(value), contract.max_items, path)

    item_issues =
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        validate_value_at(contract.items, item, path ++ [index])
      end)

    bound_issues ++ item_issues
  end

  defp validate_value_at(%{type: :union, one_of: alternatives}, value, path) do
    if Enum.any?(alternatives, &(validate_value_at(&1, value, path) == [])),
      do: [],
      else: [issue(path, "does not match any union alternative")]
  end

  defp validate_value_at(%{type: :ref}, _value, path),
    do: [issue(path, "named references require a host registry before value validation")]

  defp validate_value_at(contract, _value, path),
    do: [issue(path, "expected #{summary_shape(contract)}")]

  defp assignability_at(_source, %{type: :any}, _path), do: []
  defp assignability_at(%{type: :integer}, %{type: :number}, _path), do: []

  defp assignability_at(%{nullable: true}, %{nullable: false}, path),
    do: [issue(path, "nullable source is not assignable to a non-nullable target")]

  defp assignability_at(%{type: type} = source, %{type: type} = target, path) do
    assignability_same_type(source, target, path)
  end

  defp assignability_at(source, target, path),
    do: [issue(path, "#{summary_shape(source)} is not assignable to #{summary_shape(target)}")]

  defp assignability_same_type(%{type: :object} = source, target, path) do
    Enum.flat_map(target.required, fn name ->
      case {Map.fetch(source.properties, name), Map.fetch(target.properties, name),
            name in source.required} do
        {{:ok, source_contract}, {:ok, target_contract}, true} ->
          assignability_at(source_contract, target_contract, path ++ [name])

        _other ->
          [issue(path ++ [name], "required target property is not guaranteed by source")]
      end
    end)
  end

  defp assignability_same_type(%{type: :list} = source, target, path),
    do: assignability_at(source.items, target.items, path ++ ["items"])

  defp assignability_same_type(%{type: :enum} = source, target, path) do
    if MapSet.subset?(MapSet.new(source.enum), MapSet.new(target.enum)),
      do: [],
      else: [issue(path, "source enum contains values outside the target enum")]
  end

  defp assignability_same_type(%{type: :literal} = source, target, path) do
    if source.literal == target.literal, do: [], else: [issue(path, "literal values differ")]
  end

  defp assignability_same_type(%{type: :ref} = source, target, path) do
    if {source.ref, source.ref_version} == {target.ref, target.ref_version},
      do: [],
      else: [issue(path, "named references differ")]
  end

  defp assignability_same_type(_source, _target, _path), do: []

  defp encode_shape(map, %{type: :enum, enum: values}), do: Map.put(map, "values", values)
  defp encode_shape(map, %{type: :literal, literal: value}), do: Map.put(map, "value", value)

  defp encode_shape(map, %{type: :object} = contract) do
    map
    |> Map.put(
      "properties",
      Map.new(contract.properties, fn {name, value} -> {name, encode(value)} end)
    )
    |> put_if("required", contract.required, contract.required != [])
    |> put_if("additional_properties", false, not contract.additional_properties)
  end

  defp encode_shape(map, %{type: :list} = contract) do
    map
    |> Map.put("items", encode(contract.items))
    |> put_if("min_items", contract.min_items, not is_nil(contract.min_items))
    |> put_if("max_items", contract.max_items, not is_nil(contract.max_items))
  end

  defp encode_shape(map, %{type: :union, one_of: one_of}),
    do: Map.put(map, "one_of", Enum.map(one_of, &encode/1))

  defp encode_shape(map, %{type: :ref} = contract),
    do: Map.merge(map, %{"ref" => contract.ref, "version" => contract.ref_version})

  defp encode_shape(map, _contract), do: map

  defp put_annotations(map, contract) do
    Enum.reduce(@annotation_keys, map, fn key, acc ->
      value = Map.fetch!(contract, String.to_existing_atom(key))
      put_if(acc, key, value, value not in [nil, []])
    end)
  end

  defp json_schema_shape(%{type: :any}), do: %{}
  defp json_schema_shape(%{type: :null}), do: %{"type" => "null"}

  defp json_schema_shape(%{type: type}) when type in [:boolean, :integer, :number, :string],
    do: %{"type" => Atom.to_string(type)}

  defp json_schema_shape(%{type: :enum, enum: values}), do: %{"enum" => values}
  defp json_schema_shape(%{type: :literal, literal: value}), do: %{"const" => value}

  defp json_schema_shape(%{type: :object} = contract) do
    %{
      "type" => "object",
      "properties" =>
        Map.new(contract.properties, fn {name, value} -> {name, to_json_schema(value)} end),
      "additionalProperties" => contract.additional_properties
    }
    |> put_if("required", contract.required, contract.required != [])
  end

  defp json_schema_shape(%{type: :list} = contract) do
    %{"type" => "array", "items" => to_json_schema(contract.items)}
    |> put_if("minItems", contract.min_items, not is_nil(contract.min_items))
    |> put_if("maxItems", contract.max_items, not is_nil(contract.max_items))
  end

  defp json_schema_shape(%{type: :union, one_of: one_of}),
    do: %{"oneOf" => Enum.map(one_of, &to_json_schema/1)}

  defp json_schema_shape(%{type: :ref} = contract),
    do: %{"$ref" => contract.ref <> "/" <> contract.ref_version}

  defp put_schema_annotations(schema, contract) do
    schema
    |> put_if("description", contract.description, not is_nil(contract.description))
    |> put_if("examples", contract.examples, contract.examples != [])
    |> put_if("contentMediaType", contract.content_type, not is_nil(contract.content_type))
  end

  defp summary_shape(%{type: :object, properties: properties}),
    do: "object{" <> Enum.map_join(Enum.sort(Map.keys(properties)), ", ", & &1) <> "}"

  defp summary_shape(%{type: :list, items: items}), do: "list of " <> summary(items)

  defp summary_shape(%{type: :enum, enum: values}),
    do: "one of " <> Enum.map_join(values, ", ", &inspect/1)

  defp summary_shape(%{type: :literal, literal: value}), do: "literal " <> inspect(value)

  defp summary_shape(%{type: :union, one_of: values}),
    do: Enum.map_join(values, " or ", &summary/1)

  defp summary_shape(%{type: :ref, ref: ref, ref_version: version}), do: "#{ref}@#{version}"
  defp summary_shape(%{type: type}), do: Atom.to_string(type)

  defp validate_required_properties(issues, contract) when is_list(contract.required) do
    Enum.reduce(contract.required, issues, fn name, acc ->
      if is_binary(name) and Map.has_key?(contract.properties, name),
        do: acc,
        else: add_issue(acc, ["required", name], "does not name a declared property")
    end)
  end

  defp validate_required_properties(issues, _contract), do: issues

  defp validate_bounds(issues, %{min_items: min, max_items: max})
       when is_integer(min) and is_integer(max) and min > max,
       do: add_issue(issues, ["max_items"], "must be greater than or equal to min_items")

  defp validate_bounds(issues, _contract), do: issues

  defp require_contract(issues, %__MODULE__{}, _path), do: issues

  defp require_contract(issues, _value, path),
    do: add_issue(issues, path, "must be a value contract")

  defp require_boolean(issues, value, _path) when is_boolean(value), do: issues
  defp require_boolean(issues, _value, path), do: add_issue(issues, path, "must be a boolean")
  defp require_list(issues, value, _path) when is_list(value), do: issues
  defp require_list(issues, _value, path), do: add_issue(issues, path, "must be a list")

  defp require_string_list(issues, value, path) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: issues,
      else: add_issue(issues, path, "must contain only strings")
  end

  defp require_string_list(issues, _value, path),
    do: add_issue(issues, path, "must be a list of strings")

  defp require_optional_string(issues, nil, _path), do: issues
  defp require_optional_string(issues, value, _path) when is_binary(value), do: issues

  defp require_optional_string(issues, _value, path),
    do: add_issue(issues, path, "must be a string or null")

  defp require_non_empty_string(issues, value, _path) when is_binary(value) and value != "",
    do: issues

  defp require_non_empty_string(issues, _value, path),
    do: add_issue(issues, path, "must be a non-empty string")

  defp require_optional_non_negative_integer(issues, nil, _path), do: issues

  defp require_optional_non_negative_integer(issues, value, _path)
       when is_integer(value) and value >= 0, do: issues

  defp require_optional_non_negative_integer(issues, _value, path),
    do: add_issue(issues, path, "must be a non-negative integer or null")

  defp maybe_min_items(issues, _length, nil, _path), do: issues
  defp maybe_min_items(issues, length, min, _path) when length >= min, do: issues

  defp maybe_min_items(issues, _length, min, path),
    do: [issue(path, "must contain at least #{min} items") | issues]

  defp maybe_max_items(issues, _length, nil, _path), do: issues
  defp maybe_max_items(issues, length, max, _path) when length <= max, do: issues

  defp maybe_max_items(issues, _length, max, path),
    do: [issue(path, "must contain at most #{max} items") | issues]

  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp add_issue(issues, path, message), do: [issue(path, message) | issues]
  defp issue(path, message), do: %{path: path, message: message}
  defp error(path, message), do: {:error, [issue(path, message)]}

  defp prefix_issues(issues, prefix),
    do: Enum.map(issues, fn issue -> %{issue | path: prefix ++ issue.path} end)
end
