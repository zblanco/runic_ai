defmodule RunicAI.RLM.REPL.PythonRuntime do
  @moduledoc """
  Executes one Python turn for the sandbox-backed RLM REPL.

  This module deliberately talks to `RunicAI.Coding.SandboxSessionRegistry`
  instead of raw `RunicSandbox.Session` handles. The REPL state carries only the
  model-visible session id; the registry owns the signed sandbox authority.
  """

  alias RunicAI.Coding.SandboxSessionRegistry
  alias RunicAI.Error
  alias RunicAI.RLM.REPL.State

  @final_marker "__RUNIC_REPL_FINAL__"
  @default_observation_bytes 4_096

  @type turn_result :: %{
          state: State.t(),
          execution: map(),
          observation: map(),
          final_result: term()
        }

  @spec execute_turn(State.t(), String.t(), GenServer.server(), keyword()) ::
          {:ok, turn_result()} | {:error, Error.t()}
  def execute_turn(state, code, registry, opts \\ [])

  def execute_turn(%State{runtime: :python} = state, code, registry, opts)
      when is_binary(code) and is_list(opts) do
    max_observation_bytes = Keyword.get(opts, :max_observation_bytes, @default_observation_bytes)
    final_schema = Keyword.get(opts, :final_schema)

    request =
      %{
        runtime: :python,
        source: source_for_turn(state, code),
        timeout_ms: Keyword.get(opts, :timeout_ms),
        max_output_bytes: Keyword.get(opts, :max_output_bytes)
      }
      |> reject_nil_values()

    with :ok <- validate_positive_integer(max_observation_bytes, :max_observation_bytes),
         {:ok, execution} <-
           SandboxSessionRegistry.exec(registry, state.sandbox_session_id, request),
         {stdout, final_result} <- extract_final_result(Map.get(execution, :stdout, "")),
         observation <- observation(execution, stdout, max_observation_bytes),
         :ok <- validate_final_result(final_result, final_schema),
         {:ok, state} <- State.add_observation(state, observation),
         {:ok, state} <- maybe_set_final(state, final_result) do
      {:ok,
       %{
         state: state,
         execution: execution,
         observation: observation,
         final_result: final_result
       }}
    end
  end

  def execute_turn(%State{} = state, _code, _registry, _opts) do
    {:error,
     Error.validation("Python REPL runtime requires state runtime :python",
       source: __MODULE__,
       details: %{runtime: state.runtime}
     )}
  end

  @spec final_marker() :: String.t()
  def final_marker, do: @final_marker

  defp source_for_turn(%State{} = state, code) do
    variables_json =
      state.variables
      |> variable_values()
      |> json_safe()
      |> Jason.encode!()
      |> Jason.encode!()

    """
    import json

    variables = json.loads(#{variables_json})
    final_result = None

    def peek(name, default=None):
        return variables.get(name, default)

    def set_final(value):
        global final_result
        final_result = value

    def _context_value(name):
        value = variables.get(name)
        if isinstance(value, dict):
            for key in ("content", "text", "data", "value"):
                if key in value:
                    return value[key]
        return value

    def read_slice(name, range_or_start=0, length=None):
        value = _context_value(name)
        if value is None:
            raise KeyError("unknown REPL variable: " + str(name))

        if isinstance(value, (dict, list)):
            text = json.dumps(value, sort_keys=True)
        else:
            text = str(value)

        if isinstance(range_or_start, dict):
            start = int(range_or_start.get("offset", range_or_start.get("start", 0)))
            if "end" in range_or_start:
                end = int(range_or_start["end"])
            elif "length" in range_or_start:
                end = start + int(range_or_start["length"])
            else:
                end = len(text)
        else:
            start = int(range_or_start or 0)
            end = len(text) if length is None else start + int(length)

        start = max(0, start)
        end = max(start, end)
        return text[start:end]

    def write_artifact(*_args, **_kwargs):
        raise RuntimeError("write_artifact is mediated by RunicAI and is not available in this local turn yet")

    def llm_query(*_args, **_kwargs):
        raise RuntimeError("llm_query is mediated by RunicAI and is not available in this local turn yet")

    def rlm_query(*_args, **_kwargs):
        raise RuntimeError("rlm_query is mediated by RunicAI and is not available in this local turn yet")

    def delegate(*_args, **_kwargs):
        raise RuntimeError("delegate is mediated by RunicAI and is not available in this local turn yet")

    def checkpoint(*_args, **_kwargs):
        raise RuntimeError("checkpoint is mediated by RunicAI and is not available in this local turn yet")

    try:
    #{indent(code, 4)}
    finally:
        if final_result is not None:
            print("#{@final_marker}" + json.dumps(final_result, sort_keys=True))
    """
  end

  defp variable_values(variables) when is_map(variables) do
    Map.new(variables, fn {name, variable} ->
      value =
        case variable do
          %{value: value} -> value
          %{"value" => value} -> value
          value -> value
        end

      {name, value}
    end)
  end

  defp indent(code, spaces) do
    prefix = String.duplicate(" ", spaces)

    code
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp extract_final_result(stdout) when is_binary(stdout) do
    {lines, final_result} =
      stdout
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {lines, final_result} ->
        if String.starts_with?(line, @final_marker) do
          marker_value = String.replace_prefix(line, @final_marker, "")
          {lines, decode_final(marker_value)}
        else
          {[line | lines], final_result}
        end
      end)

    {lines |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing(), final_result}
  end

  defp decode_final(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _error} -> value
    end
  end

  defp observation(execution, stdout, max_observation_bytes) do
    stderr = Map.get(execution, :stderr, "")
    stdout_preview = bounded(stdout, max_observation_bytes)
    stderr_preview = bounded(stderr, max_observation_bytes)

    %{
      kind: :python_turn,
      status: Map.get(execution, :status),
      exit_status: Map.get(execution, :exit_status),
      duration_ms: Map.get(execution, :duration_ms),
      stdout_preview: stdout_preview.content,
      stderr_preview: stderr_preview.content,
      stdout_bytes: byte_size(stdout),
      stderr_bytes: byte_size(stderr),
      truncated?: stdout_preview.truncated? or stderr_preview.truncated?,
      backend: Map.get(execution, :backend),
      isolation_level: Map.get(execution, :isolation_level)
    }
  end

  defp bounded(value, max_bytes) when is_binary(value) do
    bytes = byte_size(value)
    content = binary_part(value, 0, min(bytes, max_bytes))
    %{content: content, truncated?: bytes > byte_size(content)}
  end

  defp maybe_set_final(state, nil), do: {:ok, state}
  defp maybe_set_final(state, final_result), do: State.set_final(state, final_result)

  defp validate_final_result(nil, _schema), do: :ok
  defp validate_final_result(_final_result, nil), do: :ok

  defp validate_final_result(final_result, schema) when is_map(schema) do
    required = Map.get(schema, :required, Map.get(schema, "required", []))

    missing =
      required
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&final_key?(final_result, &1))

    case missing do
      [] ->
        :ok

      missing ->
        {:error,
         Error.validation("REPL final_result does not satisfy schema",
           source: __MODULE__,
           details: %{missing_required: missing, schema: schema}
         )}
    end
  end

  defp validate_final_result(_final_result, schema) do
    {:error,
     Error.validation("REPL final_schema must be a map or nil",
       source: __MODULE__,
       details: %{final_schema: schema}
     )}
  end

  defp final_key?(final_result, key) when is_map(final_result) do
    Enum.any?(Map.keys(final_result), &(to_string(&1) == key))
  end

  defp final_key?(_final_result, _key), do: false

  defp validate_positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer(value, field) do
    {:error,
     Error.validation("#{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp json_safe(%_struct{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
