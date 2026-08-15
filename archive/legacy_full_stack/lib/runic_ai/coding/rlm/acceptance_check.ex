defmodule RunicAI.Coding.RLM.AcceptanceCheck do
  @moduledoc """
  One deterministic acceptance check for an RLM coding objective.

  Checks are intentionally data-first. The coordinator can generate them, the
  validator can inspect them, and verification gates can evaluate them without
  treating an LLM assertion as proof of completion.
  """

  alias RunicAI.Error

  @types [
    :file_exists,
    :module_exists,
    :function_exists,
    :source_contains,
    :source_not_contains,
    :command_passes,
    :command_fails_with,
    :test_count_min,
    :changed_file_count_between,
    :warning_count_zero,
    :runtime_smoke,
    :child_status,
    :semantic_requirement,
    :artifact_present
  ]

  @statuses [:pass, :fail, :skipped]

  @enforce_keys [:id, :type, :params, :required?, :metadata]
  defstruct [:id, :type, params: %{}, required?: true, metadata: %{}]

  @type type ::
          :file_exists
          | :module_exists
          | :function_exists
          | :source_contains
          | :source_not_contains
          | :command_passes
          | :command_fails_with
          | :test_count_min
          | :changed_file_count_between
          | :warning_count_zero
          | :runtime_smoke
          | :child_status
          | :semantic_requirement
          | :artifact_present

  @type status :: :pass | :fail | :skipped

  @type result :: %{
          required(:id) => String.t(),
          required(:type) => type(),
          required(:status) => status(),
          required(:required?) => boolean(),
          required(:message) => String.t(),
          required(:metadata) => map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          params: map(),
          required?: boolean(),
          metadata: map()
        }

  @spec types() :: [type()]
  def types, do: @types

  @spec new(type() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(type, opts \\ []) when is_list(opts) do
    check = %__MODULE__{
      id: Keyword.get(opts, :id) || "acceptance:#{System.unique_integer([:positive])}",
      type: normalize_type(type),
      params: normalize_map(Keyword.get(opts, :params, %{})),
      required?: Keyword.get(opts, :required?, true),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(check)
  end

  @spec new!(type() | String.t(), keyword()) :: t()
  def new!(type, opts \\ []) do
    case new(type, opts) do
      {:ok, check} -> check
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = check), do: validate(check)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    input = normalize_generated_check(input)

    new(get(input, :type),
      id: get(input, :id),
      params: get(input, :params, %{}),
      required?: get(input, :required?, get(input, :required, true)),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("acceptance check must be a map or AcceptanceCheck",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = check) do
    with :ok <- non_empty_string(check.id, :id),
         :ok <- valid_type(check.type),
         :ok <- map(check.params, :params),
         :ok <- boolean(check.required?, :required?),
         :ok <- map(check.metadata, :metadata) do
      {:ok, check}
    end
  end

  @spec result(t(), status(), String.t(), map()) :: result()
  def result(%__MODULE__{} = check, status, message, metadata \\ %{})
      when status in @statuses and is_binary(message) and is_map(metadata) do
    %{
      id: check.id,
      type: check.type,
      status: status,
      required?: check.required?,
      message: message,
      metadata: metadata
    }
  end

  @spec passed?(result()) :: boolean()
  def passed?(%{status: :pass}), do: true
  def passed?(_result), do: false

  @spec blocking_failure?(result()) :: boolean()
  def blocking_failure?(%{required?: true, status: status}) when status in [:fail, :skipped],
    do: true

  def blocking_failure?(_result), do: false

  defp normalize_type(type) when type in @types, do: type
  defp normalize_type(type) when is_binary(type), do: lookup_type(type)
  defp normalize_type(type), do: type

  defp lookup_type("file_exists"), do: :file_exists
  defp lookup_type("module_exists"), do: :module_exists
  defp lookup_type("function_exists"), do: :function_exists
  defp lookup_type("source_contains"), do: :source_contains
  defp lookup_type("source_not_contains"), do: :source_not_contains
  defp lookup_type("command_passes"), do: :command_passes
  defp lookup_type("command_fails_with"), do: :command_fails_with
  defp lookup_type("test_count_min"), do: :test_count_min
  defp lookup_type("changed_file_count_between"), do: :changed_file_count_between
  defp lookup_type("changed_file_count"), do: :changed_file_count_between
  defp lookup_type("warning_count_zero"), do: :warning_count_zero
  defp lookup_type("runtime_smoke"), do: :runtime_smoke
  defp lookup_type("child_status"), do: :child_status
  defp lookup_type("semantic_requirement"), do: :semantic_requirement
  defp lookup_type("artifact_present"), do: :artifact_present
  defp lookup_type(type), do: type

  defp valid_type(type) when type in @types, do: :ok

  defp valid_type(type) do
    {:error,
     Error.validation("invalid acceptance check type",
       source: __MODULE__,
       details: %{type: type, valid_types: @types}
     )}
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("acceptance check #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("acceptance check #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp boolean(value, _field) when is_boolean(value), do: :ok

  defp boolean(value, field) do
    {:error,
     Error.validation("acceptance check #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp normalize_generated_check(input) do
    type = get(input, :type)

    if changed_file_count_check?(input) and type in [:test_count_min, "test_count_min"] do
      input
      |> put(:type, :changed_file_count_between)
      |> put(:params, changed_file_count_params(input))
    else
      input
    end
  end

  defp changed_file_count_check?(input) do
    text =
      [
        get(input, :id),
        get(input, :type),
        input |> get(:metadata, %{}) |> inspect(limit: 20),
        input |> get(:params, %{}) |> inspect(limit: 20)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(text, [
      "changed_file_count",
      "changed-file-count",
      "changed file count",
      "changed files"
    ])
  end

  defp changed_file_count_params(input) do
    id = input |> get(:id, "") |> to_string() |> String.downcase()
    params = input |> get(:params, %{}) |> normalize_map()
    value = first_present(params, [:count, :expected, :value, :min, :max])

    cond do
      String.contains?(id, "max") ->
        params |> Map.drop(["min", :min]) |> put(:max, value)

      String.contains?(id, "min") ->
        params |> Map.drop(["max", :max]) |> put(:min, value)

      true ->
        params
    end
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp put(map, key, value) when is_map(map) do
    map
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
