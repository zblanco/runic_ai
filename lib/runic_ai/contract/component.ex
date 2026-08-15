defmodule RunicAI.Contract.Component do
  @moduledoc """
  An inert component specification.

  Executable functions, clients, processes, and workspace state are bindings
  owned by the host and cannot appear in this contract.
  """

  alias RunicAI.Contract.Port
  alias RunicAI.Contract.Value
  alias RunicAI.JSONValue

  @wire_id "runic.contract/component/v1"
  @shapes [:step, :rule, :map, :reduce, :state, :trigger, :workflow, :adapter]
  @effects [
    :workspace_read,
    :workspace_write,
    :event_append,
    :network,
    :llm,
    :external_mutation,
    :child_workflow,
    :sandbox
  ]
  @replay_classes [:pure, :idempotent, :effectful]
  @implementation_kinds ~w(builtin mfa workspace_tool child_workflow)

  @enforce_keys [:key, :contract_version, :shape, :inputs, :outputs, :implementation]
  defstruct key: nil,
            contract_version: nil,
            shape: nil,
            inputs: [],
            outputs: [],
            config: nil,
            form_spec_ref: nil,
            effects: [],
            replay: :pure,
            idempotency: nil,
            retry: false,
            timeout_ms: nil,
            policies: [],
            sensitivity: [],
            implementation: nil

  @type t :: %__MODULE__{}

  @spec version() :: pos_integer()
  def version, do: 1

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def new(%__MODULE__{} = component), do: validate(component)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         :ok <- validate_wire_id(map),
         {:ok, shape} <- closed_enum(Map.get(map, "shape"), @shapes, ["shape"]),
         {:ok, replay} <- closed_enum(Map.get(map, "replay", "pure"), @replay_classes, ["replay"]),
         {:ok, inputs} <- decode_ports(Map.get(map, "inputs", []), :input, ["inputs"]),
         {:ok, outputs} <- decode_ports(Map.get(map, "outputs", []), :output, ["outputs"]),
         {:ok, config} <- decode_optional_contract(Map.get(map, "config"), ["config"]),
         {:ok, implementation} <- decode_implementation(Map.get(map, "implementation")),
         {:ok, effects} <- decode_effects(Map.get(map, "effects", [])) do
      component = %__MODULE__{
        key: Map.get(map, "key"),
        contract_version: Map.get(map, "contract_version"),
        shape: shape,
        inputs: inputs,
        outputs: outputs,
        config: config,
        form_spec_ref: Map.get(map, "form_spec_ref"),
        effects: effects,
        replay: replay,
        idempotency: Map.get(map, "idempotency"),
        retry: Map.get(map, "retry", false),
        timeout_ms: Map.get(map, "timeout_ms"),
        policies: Map.get(map, "policies", []),
        sensitivity: Map.get(map, "sensitivity", []),
        implementation: implementation
      }

      with {:ok, component} <- validate(component),
           :ok <- verify_declared_hash(map, component) do
        {:ok, component}
      end
    else
      {:ok, _other} -> error([], "component must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  @spec new!(map() | keyword() | t()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, component} -> component
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  @spec decode(term()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def decode(input), do: new(input)

  @spec validate(t()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def validate(%__MODULE__{} = component) do
    issues =
      []
      |> require_identifier(component.key, ["key"])
      |> require_version(component.contract_version)
      |> require_unique_ports(component.inputs, ["inputs"])
      |> require_unique_ports(component.outputs, ["outputs"])
      |> require_disjoint_ports(component)
      |> require_optional_string(component.form_spec_ref, ["form_spec_ref"])
      |> require_optional_string(component.idempotency, ["idempotency"])
      |> require_boolean(component.retry, ["retry"])
      |> require_optional_positive_integer(component.timeout_ms, ["timeout_ms"])
      |> require_string_list(component.policies, ["policies"])
      |> require_string_list(component.sensitivity, ["sensitivity"])
      |> require_replay_policy(component)
      |> Enum.reverse()

    if issues == [], do: {:ok, component}, else: {:error, issues}
  end

  @spec encode(t() | map()) :: map()
  def encode(input) do
    component = if match?(%__MODULE__{}, input), do: input, else: new!(input)
    Map.put(encode_semantics(component), "semantic_hash", semantic_hash(component))
  end

  @spec semantic_hash(t() | map()) :: String.t()
  def semantic_hash(input) do
    component = if match?(%__MODULE__{}, input), do: input, else: new!(input)
    component |> encode_semantics() |> JSONValue.semantic_hash!()
  end

  defp encode_semantics(component) do
    %{
      "$contract" => @wire_id,
      "key" => component.key,
      "contract_version" => component.contract_version,
      "shape" => Atom.to_string(component.shape),
      "inputs" => Enum.map(component.inputs, &Port.encode/1),
      "outputs" => Enum.map(component.outputs, &Port.encode/1),
      "effects" => Enum.map(component.effects, &Atom.to_string/1),
      "replay" => Atom.to_string(component.replay),
      "retry" => component.retry,
      "implementation" => component.implementation
    }
    |> put_if("config", encode_optional(component.config), not is_nil(component.config))
    |> put_if("form_spec_ref", component.form_spec_ref, not is_nil(component.form_spec_ref))
    |> put_if("idempotency", component.idempotency, not is_nil(component.idempotency))
    |> put_if("timeout_ms", component.timeout_ms, not is_nil(component.timeout_ms))
    |> put_if("policies", component.policies, component.policies != [])
    |> put_if("sensitivity", component.sensitivity, component.sensitivity != [])
  end

  defp decode_ports(values, direction, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce({:ok, []}, fn {value, index}, acc ->
      case {acc, Port.new(value)} do
        {{:ok, ports}, {:ok, %{direction: ^direction} = port}} ->
          {:ok, [port | ports]}

        {{:ok, _ports}, {:ok, _port}} ->
          error(path ++ [index, "direction"], "must be #{direction}")

        {{:ok, _ports}, {:error, issues}} ->
          {:error, prefix_issues(issues, path ++ [index])}

        {{:error, issues}, _result} ->
          {:error, issues}
      end
    end)
    |> case do
      {:ok, ports} -> {:ok, Enum.reverse(ports)}
      error -> error
    end
  end

  defp decode_ports(_other, _direction, path), do: error(path, "must be a list")

  defp decode_optional_contract(nil, _path), do: {:ok, nil}

  defp decode_optional_contract(value, path) do
    case Value.new(value) do
      {:ok, contract} -> {:ok, contract}
      {:error, issues} -> {:error, prefix_issues(issues, path)}
    end
  end

  defp decode_implementation(value) when is_map(value) do
    with {:ok, kind} <-
           closed_string_enum(Map.get(value, "kind"), @implementation_kinds, [
             "implementation",
             "kind"
           ]),
         :ok <- require_map_string(value, "id", ["implementation", "id"]),
         :ok <- reject_binding_terms(value) do
      {:ok, Map.put(value, "kind", kind)}
    end
  end

  defp decode_implementation(_other), do: error(["implementation"], "must be an object")

  defp reject_binding_terms(map) do
    forbidden =
      Map.keys(map) |> Enum.filter(&(&1 in ["fun", "function", "pid", "client", "state"]))

    if forbidden == [],
      do: :ok,
      else:
        error(
          ["implementation"],
          "contains runtime binding fields: #{Enum.join(forbidden, ", ")}"
        )
  end

  defp decode_effects(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce({:ok, []}, fn {value, index}, acc ->
      case {acc, closed_enum(value, @effects, ["effects", index])} do
        {{:ok, effects}, {:ok, effect}} -> {:ok, [effect | effects]}
        {{:ok, _effects}, {:error, issues}} -> {:error, issues}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, effects} -> {:ok, effects |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp decode_effects(_other), do: error(["effects"], "must be a list")

  defp verify_declared_hash(%{"semantic_hash" => expected}, component) do
    if expected == semantic_hash(component),
      do: :ok,
      else: error(["semantic_hash"], "does not match the component semantics")
  end

  defp verify_declared_hash(_map, _component), do: :ok

  defp require_replay_policy(issues, %{retry: true, replay: :effectful, idempotency: nil}),
    do: [issue(["retry"], "effectful retries require an idempotency policy") | issues]

  defp require_replay_policy(issues, _component), do: issues

  defp require_unique_ports(issues, ports, path) do
    duplicates =
      ports
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)

    Enum.reduce(duplicates, issues, fn {name, _count}, acc ->
      [issue(path ++ [name], "port name is duplicated") | acc]
    end)
  end

  defp require_disjoint_ports(issues, component) do
    overlaps =
      MapSet.intersection(
        MapSet.new(component.inputs, & &1.name),
        MapSet.new(component.outputs, & &1.name)
      )

    Enum.reduce(overlaps, issues, fn name, acc ->
      [issue(["outputs", name], "port name is also used by an input") | acc]
    end)
  end

  defp require_identifier(issues, value, path) when is_binary(value) and value != "" do
    if Regex.match?(~r/^[a-z][a-z0-9_.-]*$/, value),
      do: issues,
      else: [issue(path, "has invalid identifier syntax") | issues]
  end

  defp require_identifier(issues, _value, path),
    do: [issue(path, "must be a non-empty string") | issues]

  defp require_version(issues, value) when is_binary(value) and value != "", do: issues

  defp require_version(issues, _value),
    do: [issue(["contract_version"], "must be a non-empty string") | issues]

  defp require_boolean(issues, value, _path) when is_boolean(value), do: issues
  defp require_boolean(issues, _value, path), do: [issue(path, "must be a boolean") | issues]
  defp require_optional_string(issues, nil, _path), do: issues
  defp require_optional_string(issues, value, _path) when is_binary(value), do: issues

  defp require_optional_string(issues, _value, path),
    do: [issue(path, "must be a string or null") | issues]

  defp require_optional_positive_integer(issues, nil, _path), do: issues

  defp require_optional_positive_integer(issues, value, _path)
       when is_integer(value) and value > 0, do: issues

  defp require_optional_positive_integer(issues, _value, path),
    do: [issue(path, "must be a positive integer or null") | issues]

  defp require_string_list(issues, value, path) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: issues,
      else: [issue(path, "must contain only strings") | issues]
  end

  defp require_string_list(issues, _value, path),
    do: [issue(path, "must be a list of strings") | issues]

  defp require_map_string(map, key, path) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> :ok
      _other -> error(path, "must be a non-empty string")
    end
  end

  defp closed_enum(value, allowed, path) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error(path, "is not supported")
      known -> {:ok, known}
    end
  end

  defp closed_string_enum(value, allowed, path) do
    if value in allowed, do: {:ok, value}, else: error(path, "is not supported")
  end

  defp validate_wire_id(%{"$contract" => @wire_id}), do: :ok
  defp validate_wire_id(%{"$contract" => _other}), do: error(["$contract"], "is not #{@wire_id}")
  defp validate_wire_id(_map), do: :ok
  defp encode_optional(nil), do: nil
  defp encode_optional(contract), do: Value.encode(contract)
  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp issue(path, message), do: %{path: path, message: message}
  defp error(path, message), do: {:error, [issue(path, message)]}

  defp prefix_issues(issues, prefix),
    do: Enum.map(issues, fn issue -> %{issue | path: prefix ++ issue.path} end)
end
