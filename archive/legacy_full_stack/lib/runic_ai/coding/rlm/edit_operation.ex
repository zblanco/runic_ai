defmodule RunicAI.Coding.RLM.EditOperation do
  @moduledoc """
  Generic edit operation proposed by an RLM workflow.

  Operations normalize to the existing structured coding patch contract where
  possible. `:format_files` is represented as an edit intent and executed by
  command adapters, not by this data module.
  """

  alias RunicAI.Error

  @kinds [:apply_unified_patch, :replace_file, :create_file, :delete_file, :format_files]

  @enforce_keys [:kind, :params, :metadata]
  defstruct [:kind, params: %{}, metadata: %{}]

  @type kind :: :apply_unified_patch | :replace_file | :create_file | :delete_file | :format_files

  @type t :: %__MODULE__{
          kind: kind(),
          params: map(),
          metadata: map()
        }

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec new(kind() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(kind, opts \\ []) when is_list(opts) do
    operation = %__MODULE__{
      kind: normalize_kind(kind),
      params: normalize_map(Keyword.get(opts, :params, %{})),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(operation)
  end

  @spec new!(kind() | String.t(), keyword()) :: t()
  def new!(kind, opts \\ []) do
    case new(kind, opts) do
      {:ok, operation} -> operation
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = operation), do: validate(operation)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(get(input, :kind, get(input, :op)),
      params:
        get(input, :params, Map.drop(input, [:kind, "kind", :op, "op", :metadata, "metadata"])),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("edit operation must be a map or EditOperation",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = operation) do
    with :ok <- valid_kind(operation.kind),
         :ok <- map(operation.params, :params),
         :ok <- map(operation.metadata, :metadata),
         :ok <- required_fields(operation) do
      {:ok, operation}
    end
  end

  @spec to_patch_input(t()) :: {:ok, map()} | {:skip, map()} | {:error, Error.t()}
  def to_patch_input(%__MODULE__{kind: :apply_unified_patch} = operation) do
    patch = param(operation, :patch) || param(operation, :text)

    if is_binary(patch) and patch != "" do
      {:ok, %{operations: patch, metadata: operation.metadata}}
    else
      {:error,
       Error.validation("apply_unified_patch requires patch text",
         source: __MODULE__,
         details: %{operation: operation}
       )}
    end
  end

  def to_patch_input(%__MODULE__{kind: :replace_file} = operation) do
    {:ok,
     %{
       operations: [
         %{
           op: :update,
           path: param(operation, :path),
           content: param(operation, :content),
           expected_hash: param(operation, :expected_hash)
         }
         |> drop_nil_values()
       ],
       metadata: operation.metadata
     }}
  end

  def to_patch_input(%__MODULE__{kind: :create_file} = operation) do
    {:ok,
     %{
       operations: [
         %{
           op: :create,
           path: param(operation, :path),
           content: param(operation, :content),
           overwrite: param(operation, :overwrite)
         }
         |> drop_nil_values()
       ],
       metadata: operation.metadata
     }}
  end

  def to_patch_input(%__MODULE__{kind: :delete_file} = operation) do
    {:ok,
     %{
       operations: [
         %{
           op: :delete,
           path: param(operation, :path),
           expected_hash: param(operation, :expected_hash)
         }
         |> drop_nil_values()
       ],
       metadata: operation.metadata
     }}
  end

  def to_patch_input(%__MODULE__{kind: :format_files} = operation) do
    {:skip, %{reason: :format_files_requires_command_adapter, operation: operation}}
  end

  defp required_fields(%__MODULE__{kind: :apply_unified_patch} = operation) do
    if is_binary(param(operation, :patch) || param(operation, :text)) do
      :ok
    else
      invalid("apply_unified_patch requires patch text", operation)
    end
  end

  defp required_fields(%__MODULE__{kind: kind} = operation)
       when kind in [:replace_file, :create_file] do
    with :ok <- require_string(operation, :path),
         :ok <- require_string(operation, :content) do
      :ok
    end
  end

  defp required_fields(%__MODULE__{kind: :delete_file} = operation),
    do: require_string(operation, :path)

  defp required_fields(%__MODULE__{kind: :format_files}), do: :ok

  defp require_string(operation, field) do
    case param(operation, field) do
      value when is_binary(value) and value != "" -> :ok
      _value -> invalid("#{field} must be a non-empty string", operation)
    end
  end

  defp invalid(message, operation) do
    {:error,
     Error.validation(message,
       source: __MODULE__,
       details: %{operation: operation}
     )}
  end

  defp normalize_kind(kind) when kind in @kinds, do: kind
  defp normalize_kind("apply_unified_patch"), do: :apply_unified_patch
  defp normalize_kind("replace_file"), do: :replace_file
  defp normalize_kind("create_file"), do: :create_file
  defp normalize_kind("delete_file"), do: :delete_file
  defp normalize_kind("format_files"), do: :format_files
  defp normalize_kind(kind), do: kind

  defp valid_kind(kind) when kind in @kinds, do: :ok

  defp valid_kind(kind) do
    {:error,
     Error.validation("invalid edit operation kind",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @kinds}
     )}
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("edit operation #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp param(%__MODULE__{} = operation, key),
    do: Map.get(operation.params, key, Map.get(operation.params, Atom.to_string(key)))

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
