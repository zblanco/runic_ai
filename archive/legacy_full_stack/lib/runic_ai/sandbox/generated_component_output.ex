defmodule RunicAI.Sandbox.GeneratedComponentOutput do
  @moduledoc """
  Parses and validates generated component outputs against their interface.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent

  @json_formats [:auto, :json]

  @spec parse(GeneratedComponent.t() | map() | keyword(), term(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def parse(component_input, raw_output, opts \\ []) when is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input),
         {:ok, value} <- parse_value(raw_output, Keyword.get(opts, :format, :auto)),
         :ok <- validate_value(component, value) do
      {:ok,
       %{
         component_id: component.id,
         value: value,
         validation: validation_summary(component, value),
         raw_output: raw_output
       }}
    end
  end

  @spec from_execution(GeneratedComponent.t() | map() | keyword(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def from_execution(component_input, execution, opts \\ []) when is_map(execution) do
    output_field = Keyword.get(opts, :output_field, :stdout)

    raw_output =
      Map.get(execution, output_field, Map.get(execution, Atom.to_string(output_field), ""))

    parse(component_input, raw_output, opts)
  end

  @spec validate_value(GeneratedComponent.t() | map() | keyword(), term()) ::
          :ok | {:error, Error.t()}
  def validate_value(component_input, value) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input) do
      outputs = interface_outputs(component)
      normalized = normalized_output_value(outputs, value)
      missing = missing_outputs(outputs, normalized)
      type_errors = type_errors(outputs, normalized)

      if missing == [] and type_errors == [] do
        :ok
      else
        {:error,
         Error.validation("generated component output did not match interface",
           source: __MODULE__,
           details: %{
             component_id: component.id,
             missing_outputs: missing,
             type_errors: type_errors
           }
         )}
      end
    end
  end

  defp parse_value(value, :text) when is_binary(value), do: {:ok, value}
  defp parse_value(value, :value), do: {:ok, value}

  defp parse_value(value, format) when format in @json_formats and is_binary(value) do
    value = String.trim(value)

    case Jason.decode(value) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, error} when format == :json ->
        {:error,
         Error.validation("generated component output was not valid JSON",
           source: __MODULE__,
           details: %{decode_error: Exception.message(error)}
         )}

      {:error, _error} ->
        {:ok, value}
    end
  end

  defp parse_value(value, format) when format in [:auto, :json, :value], do: {:ok, value}

  defp parse_value(_value, format) do
    {:error,
     Error.validation("invalid generated component output format",
       source: __MODULE__,
       details: %{format: format, valid_formats: [:auto, :json, :text, :value]}
     )}
  end

  defp validation_summary(%GeneratedComponent{} = component, value) do
    outputs = interface_outputs(component)
    normalized = normalized_output_value(outputs, value)

    %{
      status: :accepted,
      output_count: length(outputs),
      required_outputs: outputs |> Enum.filter(&required?/1) |> Enum.map(&output_name/1),
      present_outputs: present_outputs(outputs, normalized)
    }
  end

  defp interface_outputs(%GeneratedComponent{interface: interface}) do
    interface
    |> map_get(:outputs, [])
    |> List.wrap()
    |> Enum.map(&normalize_output_spec/1)
  end

  defp normalize_output_spec(spec) when is_map(spec) do
    %{
      name: map_get(spec, :name, "output") |> to_string(),
      type: map_get(spec, :type, "any") |> to_string(),
      required?: truthy?(map_get(spec, :required, true))
    }
  end

  defp normalize_output_spec(name) when is_atom(name) or is_binary(name) do
    %{name: to_string(name), type: "any", required?: true}
  end

  defp normalize_output_spec(_spec), do: %{name: "output", type: "any", required?: true}

  defp normalized_output_value([%{name: "output"}], value) when not is_map(value) do
    %{"output" => value}
  end

  defp normalized_output_value(_outputs, value) when is_map(value), do: value
  defp normalized_output_value(_outputs, value), do: %{"output" => value}

  defp missing_outputs(outputs, value) do
    outputs
    |> Enum.filter(&required?/1)
    |> Enum.reject(&has_output?(value, output_name(&1)))
    |> Enum.map(&output_name/1)
  end

  defp type_errors(outputs, value) do
    outputs
    |> Enum.filter(&has_output?(value, output_name(&1)))
    |> Enum.reject(fn output ->
      type_matches?(output_value(value, output_name(output)), output.type)
    end)
    |> Enum.map(fn output ->
      %{
        output: output.name,
        expected: output.type,
        actual: actual_type(output_value(value, output.name))
      }
    end)
  end

  defp present_outputs(outputs, value) do
    outputs
    |> Enum.filter(&has_output?(value, output_name(&1)))
    |> Enum.map(&output_name/1)
  end

  defp output_name(output), do: output.name
  defp required?(output), do: output.required?

  defp has_output?(value, name) when is_map(value) do
    Enum.any?(Map.keys(value), &(to_string(&1) == name))
  end

  defp map_get(value, key, default) when is_map(value) do
    Map.get(value, key, Map.get(value, to_string(key), default))
  end

  defp output_value(value, name) when is_map(value) do
    value
    |> Enum.find(fn {key, _value} -> to_string(key) == name end)
    |> case do
      nil -> nil
      {_key, value} -> value
    end
  end

  defp type_matches?(_value, "any"), do: true
  defp type_matches?(value, "string"), do: is_binary(value)
  defp type_matches?(value, "integer"), do: is_integer(value)
  defp type_matches?(value, "number"), do: is_number(value)
  defp type_matches?(value, "boolean"), do: is_boolean(value)
  defp type_matches?(value, "object"), do: is_map(value)
  defp type_matches?(value, "map"), do: is_map(value)
  defp type_matches?(value, "array"), do: is_list(value)
  defp type_matches?(value, "list"), do: is_list(value)
  defp type_matches?(value, "records"), do: is_list(value) and Enum.all?(value, &is_map/1)
  defp type_matches?(_value, _type), do: true

  defp actual_type(value) when is_binary(value), do: "string"
  defp actual_type(value) when is_integer(value), do: "integer"
  defp actual_type(value) when is_float(value), do: "number"
  defp actual_type(value) when is_boolean(value), do: "boolean"
  defp actual_type(value) when is_map(value), do: "object"
  defp actual_type(value) when is_list(value), do: "array"
  defp actual_type(nil), do: "null"
  defp actual_type(_value), do: "term"

  defp truthy?(value), do: value in [true, "true", 1, "1", "yes", "on"]
end
