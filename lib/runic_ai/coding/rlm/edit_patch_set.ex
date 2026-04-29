defmodule RunicAI.Coding.RLM.EditPatchSet do
  @moduledoc """
  Validated set of edit operations for an RLM `:edit` node.

  Patch sets are the late mutation boundary for RLM-generated workflows. They
  carry target paths, expected files, and before/after hash evidence so later
  verification can reject no-op or incomplete edits.
  """

  alias RunicAI.Coding.PatchResult
  alias RunicAI.Coding.RLM.EditOperation
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @enforce_keys [
    :id,
    :objective,
    :target_paths,
    :before_hashes,
    :operations,
    :expected_changed_files,
    :metadata
  ]
  defstruct [
    :id,
    :objective,
    target_paths: [],
    before_hashes: %{},
    operations: [],
    expected_changed_files: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          target_paths: [Path.t()],
          before_hashes: map(),
          operations: [EditOperation.t()],
          expected_changed_files: [Path.t()],
          metadata: map()
        }

  @spec new(String.t(), [EditOperation.t() | map()], keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(objective, operations, opts \\ [])
      when is_binary(objective) and is_list(operations) and is_list(opts) do
    patch_set = %__MODULE__{
      id: Keyword.get(opts, :id) || "edit-patch-set:#{System.unique_integer([:positive])}",
      objective: objective,
      target_paths: Keyword.get(opts, :target_paths, []),
      before_hashes: normalize_map(Keyword.get(opts, :before_hashes, %{})),
      operations: operations,
      expected_changed_files: Keyword.get(opts, :expected_changed_files, []),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(patch_set)
  end

  @spec new!(String.t(), [EditOperation.t() | map()], keyword()) :: t()
  def new!(objective, operations, opts \\ []) do
    case new(objective, operations, opts) do
      {:ok, patch_set} -> patch_set
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = patch_set), do: validate(patch_set)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(
      get(input, :objective, "apply RLM edit patch set"),
      List.wrap(get(input, :operations, [])),
      id: get(input, :id),
      target_paths: List.wrap(get(input, :target_paths, [])),
      before_hashes: get(input, :before_hashes, %{}),
      expected_changed_files: List.wrap(get(input, :expected_changed_files, [])),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("edit patch set must be a map or EditPatchSet",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = patch_set) do
    with :ok <- non_empty_string(patch_set.id, :id),
         :ok <- non_empty_string(patch_set.objective, :objective),
         :ok <- string_list(patch_set.target_paths, :target_paths),
         :ok <- map(patch_set.before_hashes, :before_hashes),
         {:ok, operations} <- normalize_operations(patch_set.operations),
         :ok <- string_list(patch_set.expected_changed_files, :expected_changed_files),
         :ok <- map(patch_set.metadata, :metadata) do
      {:ok, %{patch_set | operations: operations}}
    end
  end

  @spec apply(Workspace.t(), t() | map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def apply(%Workspace{} = workspace, patch_set_input, opts \\ []) when is_list(opts) do
    with {:ok, patch_set} <- from_input(patch_set_input) do
      {patch_results, skipped} =
        patch_set.operations
        |> Enum.map(&EditOperation.to_patch_input/1)
        |> Enum.reduce({[], []}, fn
          {:ok, patch_input}, {results, skipped} ->
            {:ok, result} =
              Tools.apply_patch(
                workspace,
                patch_input
                |> Map.update!(:metadata, &Map.merge(patch_set.metadata, &1))
                |> Map.put(:dry_run, Keyword.get(opts, :dry_run?, false))
              )

            {[result | results], skipped}

          {:skip, reason}, {results, skipped} ->
            {results, [reason | skipped]}

          {:error, error}, {results, skipped} ->
            result =
              PatchResult.new!(:error,
                diagnostics: [
                  %{kind: :invalid_edit_operation, message: error.message, details: error.details}
                ]
              )

            {[result | results], skipped}
        end)

      patch_results = Enum.reverse(patch_results)
      skipped = Enum.reverse(skipped)
      changed_paths = patch_results |> Enum.flat_map(& &1.changed_paths) |> Enum.uniq()
      missing_expected = patch_set.expected_changed_files -- changed_paths
      diagnostics = Enum.flat_map(patch_results, & &1.diagnostics)

      status =
        cond do
          diagnostics != [] -> :error
          changed_paths == [] -> :error
          missing_expected != [] -> :error
          Keyword.get(opts, :dry_run?, false) -> :dry_run
          true -> :ok
        end

      {:ok,
       %{
         id: patch_set.id,
         status: status,
         changed_paths: changed_paths,
         expected_changed_files: patch_set.expected_changed_files,
         missing_expected_files: missing_expected,
         skipped_operations: skipped,
         operation_results: patch_results,
         before_hashes: merge_hashes(patch_results, :before_hashes),
         after_hashes: merge_hashes(patch_results, :after_hashes),
         diagnostics:
           diagnostics ++
             no_op_diagnostics(changed_paths) ++ missing_diagnostics(missing_expected),
         metadata: patch_set.metadata
       }}
    end
  end

  defp normalize_operations(operations) when is_list(operations) do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      case EditOperation.from_input(operation) do
        {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp normalize_operations(operations) do
    {:error,
     Error.validation("edit patch set operations must be a list",
       source: __MODULE__,
       details: %{operations: operations}
     )}
  end

  defp merge_hashes(results, key) do
    Enum.reduce(results, %{}, fn result, acc ->
      Map.merge(acc, Map.fetch!(result, key))
    end)
  end

  defp no_op_diagnostics([]),
    do: [%{kind: :no_changed_paths, message: "edit patch set changed no files"}]

  defp no_op_diagnostics(_changed_paths), do: []

  defp missing_diagnostics([]), do: []

  defp missing_diagnostics(paths) do
    [
      %{
        kind: :missing_expected_changed_files,
        message: "expected changed files were not changed",
        paths: paths
      }
    ]
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("edit patch set #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list(value, field) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      :ok
    else
      {:error,
       Error.validation("edit patch set #{field} must be a list of strings",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
    end
  end

  defp string_list(value, field) do
    {:error,
     Error.validation("edit patch set #{field} must be a list of strings",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("edit patch set #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
