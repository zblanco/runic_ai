defmodule RunicAI.Contract.Port do
  @moduledoc "A named, versioned value boundary on a workflow component."

  alias RunicAI.Contract.Value
  alias RunicAI.JSONValue

  @wire_id "runic.contract/port/v1"
  @directions [:input, :output]
  @cardinalities [:one, :many]
  @modes [:single, :batch, :stream]

  @enforce_keys [:name, :direction, :value]
  defstruct name: nil,
            direction: nil,
            value: nil,
            required: true,
            cardinality: :one,
            mode: :single,
            sensitivity: [],
            description: nil

  @type t :: %__MODULE__{
          name: String.t(),
          direction: :input | :output,
          value: Value.t(),
          required: boolean(),
          cardinality: :one | :many,
          mode: :single | :batch | :stream,
          sensitivity: [String.t()],
          description: String.t() | nil
        }

  @spec version() :: pos_integer()
  def version, do: 1

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def new(%__MODULE__{} = port), do: validate(port)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         :ok <- validate_wire_id(map),
         {:ok, direction} <- closed_enum(Map.get(map, "direction"), @directions, ["direction"]),
         {:ok, cardinality} <-
           closed_enum(Map.get(map, "cardinality", "one"), @cardinalities, ["cardinality"]),
         {:ok, mode} <- closed_enum(Map.get(map, "mode", "single"), @modes, ["mode"]),
         {:ok, value} <- Value.normalize(Map.get(map, "value")) do
      validate(%__MODULE__{
        name: Map.get(map, "name"),
        direction: direction,
        value: value,
        required: Map.get(map, "required", true),
        cardinality: cardinality,
        mode: mode,
        sensitivity: Map.get(map, "sensitivity", []),
        description: Map.get(map, "description")
      })
    else
      {:ok, _other} -> error([], "port must be an object")
      {:error, issues} -> {:error, issues}
    end
  end

  @spec new!(map() | keyword() | t()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, port} -> port
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  @spec decode(term()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def decode(input), do: new(input)

  @spec validate(t()) :: {:ok, t()} | {:error, [JSONValue.issue()]}
  def validate(%__MODULE__{} = port) do
    issues =
      []
      |> require_name(port.name)
      |> require_boolean(port.required, ["required"])
      |> require_string_list(port.sensitivity, ["sensitivity"])
      |> require_optional_string(port.description, ["description"])
      |> validate_mode(port)
      |> Enum.reverse()

    if issues == [], do: {:ok, port}, else: {:error, issues}
  end

  @spec encode(t() | map()) :: map()
  def encode(input) do
    port = if match?(%__MODULE__{}, input), do: input, else: new!(input)

    %{
      "$contract" => @wire_id,
      "name" => port.name,
      "direction" => Atom.to_string(port.direction),
      "value" => Value.encode(port.value),
      "required" => port.required,
      "cardinality" => Atom.to_string(port.cardinality),
      "mode" => Atom.to_string(port.mode)
    }
    |> put_if("sensitivity", port.sensitivity, port.sensitivity != [])
    |> put_if("description", port.description, not is_nil(port.description))
  end

  @spec semantic_hash(t() | map()) :: String.t()
  def semantic_hash(port), do: port |> encode() |> JSONValue.semantic_hash!()

  @spec connectable?(t() | map(), t() | map()) :: boolean()
  def connectable?(output, input), do: connectability(output, input) == :ok

  @spec connectability(t() | map(), t() | map()) :: :ok | {:error, [JSONValue.issue()]}
  def connectability(output, input) do
    with {:ok, output} <- new(output),
         {:ok, input} <- new(input),
         :ok <- require_direction(output, :output),
         :ok <- require_direction(input, :input),
         :ok <- require_transport_match(output, input) do
      Value.assignability(output.value, input.value)
    end
  end

  defp validate_mode(issues, %{cardinality: :one, mode: :batch}),
    do: [issue(["mode"], "batch mode requires many cardinality") | issues]

  defp validate_mode(issues, %{cardinality: :one, mode: :stream}),
    do: [issue(["mode"], "stream mode requires many cardinality") | issues]

  defp validate_mode(issues, _port), do: issues

  defp require_direction(%{direction: direction}, direction), do: :ok
  defp require_direction(_port, expected), do: error(["direction"], "must be #{expected}")

  defp require_transport_match(output, input) do
    if {output.cardinality, output.mode} == {input.cardinality, input.mode},
      do: :ok,
      else: error([], "port cardinality and mode do not match")
  end

  defp validate_wire_id(%{"$contract" => @wire_id}), do: :ok
  defp validate_wire_id(%{"$contract" => _other}), do: error(["$contract"], "is not #{@wire_id}")
  defp validate_wire_id(_map), do: :ok

  defp closed_enum(value, allowed, path) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error(path, "is not supported")
      known -> {:ok, known}
    end
  end

  defp require_name(issues, name) when is_binary(name) and name != "" do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name),
      do: issues,
      else: [issue(["name"], "must use snake_case identifier syntax") | issues]
  end

  defp require_name(issues, _name), do: [issue(["name"], "must be a non-empty string") | issues]
  defp require_boolean(issues, value, _path) when is_boolean(value), do: issues
  defp require_boolean(issues, _value, path), do: [issue(path, "must be a boolean") | issues]

  defp require_string_list(issues, value, path) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: issues,
      else: [issue(path, "must contain only strings") | issues]
  end

  defp require_string_list(issues, _value, path),
    do: [issue(path, "must be a list of strings") | issues]

  defp require_optional_string(issues, nil, _path), do: issues
  defp require_optional_string(issues, value, _path) when is_binary(value), do: issues

  defp require_optional_string(issues, _value, path),
    do: [issue(path, "must be a string or null") | issues]

  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp issue(path, message), do: %{path: path, message: message}
  defp error(path, message), do: {:error, [issue(path, message)]}
end
