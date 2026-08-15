defmodule RunicAI.Tool.Spec do
  @moduledoc "Serializable tool specification without an executable binding."

  alias RunicAI.Contract.Value
  alias RunicAI.JSONValue

  @wire_id "runic.ai/tool-spec/v1"
  @effects [
    :pure,
    :workspace_read,
    :workspace_write,
    :network,
    :external_mutation,
    :child_workflow,
    :sandbox
  ]
  @replay [:pure, :idempotent, :unsafe]

  @enforce_keys [:name, :version, :description, :input, :output]
  defstruct name: nil,
            version: nil,
            description: nil,
            input: nil,
            output: nil,
            effects: [],
            replay: :pure,
            idempotency: nil,
            timeout_ms: nil,
            retry: false,
            sensitivity: [],
            policies: [],
            model_visible: true,
            metadata: %{}

  @type t :: %__MODULE__{}

  def new(input) do
    with {:ok, map} when is_map(map) <- JSONValue.normalize(input),
         true <- Map.get(map, "$contract", @wire_id) == @wire_id,
         {:ok, input_contract} <- Value.normalize(Map.get(map, "input")),
         {:ok, output_contract} <- Value.normalize(Map.get(map, "output")),
         {:ok, effects} <- decode_enums(Map.get(map, "effects", []), @effects, ["effects"]),
         {:ok, replay} <- decode_enum(Map.get(map, "replay", "pure"), @replay, ["replay"]),
         {:ok, metadata} when is_map(metadata) <-
           JSONValue.normalize(Map.get(map, "metadata", %{})) do
      validate(%__MODULE__{
        name: Map.get(map, "name"),
        version: Map.get(map, "version", "1"),
        description: Map.get(map, "description"),
        input: input_contract,
        output: output_contract,
        effects: effects,
        replay: replay,
        idempotency: Map.get(map, "idempotency"),
        timeout_ms: Map.get(map, "timeout_ms"),
        retry: Map.get(map, "retry", false),
        sensitivity: Map.get(map, "sensitivity", []),
        policies: Map.get(map, "policies", []),
        model_visible: Map.get(map, "model_visible", true),
        metadata: metadata
      })
    else
      false -> error(["$contract"], "is not #{@wire_id}")
      {:ok, _other} -> error([], "tool spec fields have invalid shapes")
      {:error, issues} -> {:error, issues}
    end
  end

  def new!(input) do
    case new(input) do
      {:ok, spec} -> spec
      {:error, issues} -> raise ArgumentError, inspect(issues)
    end
  end

  def validate(%__MODULE__{} = spec) do
    issues =
      []
      |> check(identifier?(spec.name), ["name"], "must be a stable dotted identifier")
      |> check(
        is_binary(spec.version) and spec.version != "",
        ["version"],
        "must be a non-empty string"
      )
      |> check(
        is_binary(spec.description) and spec.description != "",
        ["description"],
        "must be a non-empty string"
      )
      |> check(
        is_nil(spec.idempotency) or is_binary(spec.idempotency),
        ["idempotency"],
        "must be a string or null"
      )
      |> check(
        is_nil(spec.timeout_ms) or (is_integer(spec.timeout_ms) and spec.timeout_ms > 0),
        ["timeout_ms"],
        "must be a positive integer or null"
      )
      |> check(is_boolean(spec.retry), ["retry"], "must be a boolean")
      |> check(string_list?(spec.sensitivity), ["sensitivity"], "must be a list of strings")
      |> check(string_list?(spec.policies), ["policies"], "must be a list of strings")
      |> check(is_boolean(spec.model_visible), ["model_visible"], "must be a boolean")
      |> require_safe_retry(spec)
      |> Enum.reverse()

    if issues == [], do: {:ok, spec}, else: {:error, issues}
  end

  def encode(%__MODULE__{} = spec) do
    semantics =
      %{
        "$contract" => @wire_id,
        "name" => spec.name,
        "version" => spec.version,
        "description" => spec.description,
        "input" => Value.encode(spec.input),
        "output" => Value.encode(spec.output),
        "effects" => Enum.map(spec.effects, &Atom.to_string/1),
        "replay" => Atom.to_string(spec.replay),
        "retry" => spec.retry,
        "model_visible" => spec.model_visible,
        "metadata" => spec.metadata
      }
      |> put_if("idempotency", spec.idempotency)
      |> put_if("timeout_ms", spec.timeout_ms)
      |> put_if("sensitivity", spec.sensitivity, spec.sensitivity != [])
      |> put_if("policies", spec.policies, spec.policies != [])

    Map.put(semantics, "semantic_hash", JSONValue.semantic_hash!(semantics))
  end

  def decode(input) do
    with {:ok, spec} <- new(input),
         :ok <- verify_hash(input, spec) do
      {:ok, spec}
    end
  end

  def semantic_hash(%__MODULE__{} = spec),
    do: spec |> encode() |> Map.delete("semantic_hash") |> JSONValue.semantic_hash!()

  def to_model_tool(%__MODULE__{} = spec) do
    %{
      "name" => spec.name,
      "description" => spec.description,
      "parameters" => Value.to_json_schema(spec.input)
    }
  end

  defp verify_hash(map, spec) when is_map(map) do
    expected = Map.get(map, "semantic_hash") || Map.get(map, :semantic_hash)

    if is_nil(expected) or expected == semantic_hash(spec),
      do: :ok,
      else: error(["semantic_hash"], "does not match tool semantics")
  end

  defp require_safe_retry(issues, %{retry: true, replay: :unsafe, idempotency: nil}),
    do: [
      %{path: ["retry"], message: "unsafe retries require an explicit idempotency policy"}
      | issues
    ]

  defp require_safe_retry(issues, _spec), do: issues

  defp decode_enums(values, allowed, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce({:ok, []}, fn {value, index}, acc ->
      case {acc, decode_enum(value, allowed, path ++ [index])} do
        {{:ok, decoded}, {:ok, item}} -> {:ok, [item | decoded]}
        {{:ok, _decoded}, {:error, issues}} -> {:error, issues}
        {{:error, issues}, _result} -> {:error, issues}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, decoded |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp decode_enums(_other, _allowed, path), do: error(path, "must be a list")

  defp decode_enum(value, allowed, path) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> error(path, "is not supported")
      item -> {:ok, item}
    end
  end

  defp identifier?(value) when is_binary(value), do: Regex.match?(~r/^[a-z][a-z0-9_.-]*$/, value)
  defp identifier?(_value), do: false
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp check(issues, true, _path, _message), do: issues
  defp check(issues, false, path, message), do: [%{path: path, message: message} | issues]
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
  defp put_if(map, _key, _value, false), do: map
  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp error(path, message), do: {:error, [%{path: path, message: message}]}
end
