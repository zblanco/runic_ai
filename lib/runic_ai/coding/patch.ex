defmodule RunicAI.Coding.Patch do
  @moduledoc """
  Structured, patch-first edit contract for workspace changes.

  A patch is a list of explicit operations:

    * `:create` with `:path` and `:content`
    * `:update` with `:path`, `:content`, and optional `:expected_hash`
    * `:delete` with `:path` and optional `:expected_hash`
    * `:move` with `:from`, `:to`, and optional `:expected_hash`

  Hashes are lowercase SHA-256 hex strings of the whole file content.
  """

  alias RunicAI.Coding.PatchResult
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @valid_ops [:create, :update, :delete, :move]

  @enforce_keys [:operations, :metadata]
  defstruct operations: [], metadata: %{}

  @type operation :: %{
          required(:op) => :create | :update | :delete | :move,
          optional(:path) => Path.t(),
          optional(:from) => Path.t(),
          optional(:to) => Path.t(),
          optional(:content) => binary(),
          optional(:expected_hash) => String.t(),
          optional(:overwrite) => boolean()
        }

  @type t :: %__MODULE__{
          operations: [operation()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    operations = Keyword.get(opts, :operations, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, operations} <- normalize_operations(operations),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{operations: operations, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, patch} -> patch
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = patch), do: validate(patch)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      operations: get(input, :operations, []),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.Patch-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = patch) do
    new(operations: patch.operations, metadata: patch.metadata)
  end

  @spec apply_patch(Workspace.t(), t() | keyword() | map(), keyword()) :: PatchResult.t()
  def apply_patch(%Workspace{} = workspace, patch_input, opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run?, false)

    case patch_input |> expand_text_patch(workspace) |> from_input() do
      {:ok, %__MODULE__{operations: operations, metadata: metadata}} ->
        apply_operations(workspace, operations, dry_run?, metadata)

      {:error, error} ->
        PatchResult.new!(:error,
          diagnostics: [diagnostic(:invalid_patch, error.message, error.details)]
        )
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @spec file_sha256(Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def file_sha256(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, sha256(content)}
    else
      {:error, reason} ->
        {:error,
         Error.new(:file_read_failed, "could not hash file",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp apply_operations(workspace, operations, dry_run?, patch_metadata) do
    initial = %{
      changed_paths: [],
      operation_summaries: [],
      diagnostics: [],
      before_hashes: %{},
      after_hashes: %{}
    }

    operations
    |> Enum.reduce_while(initial, fn operation, acc ->
      case apply_operation(workspace, operation, dry_run?) do
        {:ok, operation_result} ->
          {:cont, merge_operation_result(acc, operation_result)}

        {:error, diagnostic} ->
          {:halt, %{acc | diagnostics: acc.diagnostics ++ [diagnostic]}}
      end
    end)
    |> build_result(dry_run?, patch_metadata)
  end

  defp build_result(state, dry_run?, patch_metadata) do
    status =
      cond do
        state.diagnostics != [] -> :error
        dry_run? -> :dry_run
        true -> :ok
      end

    PatchResult.new!(status,
      changed_paths: Enum.uniq(state.changed_paths),
      operation_summaries: state.operation_summaries,
      diagnostics: state.diagnostics,
      before_hashes: state.before_hashes,
      after_hashes: state.after_hashes,
      metadata: patch_metadata
    )
  end

  defp apply_operation(workspace, %{op: :create} = operation, dry_run?) do
    with {:ok, path} <- require_path(operation),
         {:ok, content} <- require_content(operation),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :write),
         :ok <- validate_content(resolved.relative, content),
         :ok <- reject_existing(resolved.path, operation),
         :ok <- maybe_write_file(resolved.path, content, dry_run?) do
      after_hash = sha256(content)

      {:ok,
       %{
         changed_paths: [resolved.relative],
         operation_summaries: [
           %{op: :create, path: resolved.relative, dry_run?: dry_run?, bytes: byte_size(content)}
         ],
         before_hashes: %{resolved.relative => nil},
         after_hashes: %{resolved.relative => after_hash}
       }}
    else
      {:error, error} -> {:error, operation_diagnostic(:create, operation, error)}
    end
  end

  defp apply_operation(workspace, %{op: :update} = operation, dry_run?) do
    with {:ok, path} <- require_path(operation),
         {:ok, content} <- require_content(operation),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :write),
         :ok <- validate_content(resolved.relative, content),
         :ok <- require_file(resolved.path),
         {:ok, before_hash} <- file_sha256(resolved.path),
         :ok <- validate_expected_hash(operation, before_hash),
         :ok <- maybe_write_file(resolved.path, content, dry_run?) do
      after_hash = sha256(content)

      {:ok,
       %{
         changed_paths: [resolved.relative],
         operation_summaries: [
           %{op: :update, path: resolved.relative, dry_run?: dry_run?, bytes: byte_size(content)}
         ],
         before_hashes: %{resolved.relative => before_hash},
         after_hashes: %{resolved.relative => after_hash}
       }}
    else
      {:error, error} -> {:error, operation_diagnostic(:update, operation, error)}
    end
  end

  defp apply_operation(workspace, %{op: :delete} = operation, dry_run?) do
    with {:ok, path} <- require_path(operation),
         {:ok, resolved} <- Workspace.resolve_path(workspace, path, :write),
         :ok <- require_file(resolved.path),
         {:ok, before_hash} <- file_sha256(resolved.path),
         :ok <- validate_expected_hash(operation, before_hash),
         :ok <- maybe_delete_file(resolved.path, dry_run?) do
      {:ok,
       %{
         changed_paths: [resolved.relative],
         operation_summaries: [
           %{op: :delete, path: resolved.relative, dry_run?: dry_run?}
         ],
         before_hashes: %{resolved.relative => before_hash},
         after_hashes: %{resolved.relative => nil}
       }}
    else
      {:error, error} -> {:error, operation_diagnostic(:delete, operation, error)}
    end
  end

  defp apply_operation(workspace, %{op: :move} = operation, dry_run?) do
    with {:ok, from} <- require_field(operation, :from),
         {:ok, to} <- require_field(operation, :to),
         {:ok, from_resolved} <- Workspace.resolve_path(workspace, from, :write),
         {:ok, to_resolved} <- Workspace.resolve_path(workspace, to, :write),
         :ok <- require_file(from_resolved.path),
         :ok <- reject_existing(to_resolved.path, operation),
         {:ok, before_hash} <- file_sha256(from_resolved.path),
         :ok <- validate_expected_hash(operation, before_hash),
         :ok <- maybe_move_file(from_resolved.path, to_resolved.path, dry_run?) do
      {:ok,
       %{
         changed_paths: [from_resolved.relative, to_resolved.relative],
         operation_summaries: [
           %{
             op: :move,
             from: from_resolved.relative,
             to: to_resolved.relative,
             dry_run?: dry_run?
           }
         ],
         before_hashes: %{from_resolved.relative => before_hash, to_resolved.relative => nil},
         after_hashes: %{from_resolved.relative => nil, to_resolved.relative => before_hash}
       }}
    else
      {:error, error} -> {:error, operation_diagnostic(:move, operation, error)}
    end
  end

  defp apply_operation(_workspace, operation, _dry_run?) do
    {:error,
     diagnostic(:invalid_operation, "unsupported patch operation", %{operation: operation})}
  end

  defp maybe_write_file(path, content, true) when is_binary(path) and is_binary(content), do: :ok

  defp maybe_write_file(path, content, false) when is_binary(path) and is_binary(content) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok ->
        case File.write(path, content) do
          :ok ->
            refresh_mtime(path)

          {:error, reason} ->
            {:error,
             Error.new(:file_write_failed, "could not write file",
               source: __MODULE__,
               details: %{path: path, reason: reason}
             )}
        end

      {:error, reason} ->
        {:error,
         Error.new(:file_write_failed, "could not create parent directory",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp refresh_mtime(path) do
    path
    |> File.touch(future_file_time())
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:file_write_failed, "could not refresh file mtime",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp future_file_time do
    DateTime.utc_now()
    |> DateTime.add(2, :second)
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
  end

  defp validate_content(path, content) do
    cond do
      elixir_source?(path) and under_escaped_elixir_default_arg?(content) ->
        {:error,
         Error.validation("Elixir default argument appears to use a single backslash",
           source: __MODULE__,
           details: %{
             path: path,
             guidance:
               "Elixir default arguments require two backslashes in the file. In JSON strings this is escape-sensitive; prefer explicit function clauses or ensure the written file contains `\\\\`, not `\\`."
           }
         )}

      true ->
        :ok
    end
  end

  defp elixir_source?(path), do: Path.extname(path) in [".ex", ".exs"]

  defp under_escaped_elixir_default_arg?(content) do
    Regex.match?(~r/^\s*def(?:p|macro)?\s+.*(?:^|[^\\])\\(?!\\)\s+[%\[\w:&]/m, content)
  end

  defp maybe_delete_file(_path, true), do: :ok

  defp maybe_delete_file(path, false) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:file_delete_failed, "could not delete file",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp maybe_move_file(_from, _to, true), do: :ok

  defp maybe_move_file(from, to, false) do
    to
    |> Path.dirname()
    |> File.mkdir_p()
    |> case do
      :ok ->
        case File.rename(from, to) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:file_move_failed, "could not move file",
               source: __MODULE__,
               details: %{from: from, to: to, reason: reason}
             )}
        end

      {:error, reason} ->
        {:error,
         Error.new(:file_move_failed, "could not create target parent directory",
           source: __MODULE__,
           details: %{from: from, to: to, reason: reason}
         )}
    end
  end

  defp reject_existing(path, operation) do
    cond do
      not File.exists?(path) ->
        :ok

      Map.get(operation, :overwrite, false) ->
        :ok

      true ->
        {:error,
         Error.validation("target path already exists",
           source: __MODULE__,
           details: %{path: path}
         )}
    end
  end

  defp require_file(path) do
    cond do
      not File.exists?(path) ->
        {:error,
         Error.validation("file does not exist",
           source: __MODULE__,
           details: %{path: path}
         )}

      not File.regular?(path) ->
        {:error,
         Error.validation("path must be a regular file",
           source: __MODULE__,
           details: %{path: path}
         )}

      true ->
        :ok
    end
  end

  defp validate_expected_hash(operation, actual_hash) do
    case Map.get(operation, :expected_hash) do
      nil ->
        :ok

      ^actual_hash ->
        :ok

      expected_hash ->
        {:error,
         Error.validation("expected hash does not match current file hash",
           source: __MODULE__,
           details: %{expected_hash: expected_hash, actual_hash: actual_hash}
         )}
    end
  end

  defp require_path(operation), do: require_field(operation, :path)

  defp require_content(operation) do
    case Map.fetch(operation, :content) do
      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:ok, content} ->
        {:error,
         Error.validation("patch operation content must be a binary",
           source: __MODULE__,
           details: %{content: content}
         )}

      :error ->
        {:error,
         Error.validation("patch operation requires content",
           source: __MODULE__,
           details: %{operation: operation}
         )}
    end
  end

  defp require_field(operation, field) do
    case Map.fetch(operation, field) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, value} ->
        {:error,
         Error.validation("patch operation field must be a non-empty string",
           source: __MODULE__,
           details: %{field: field, value: value}
         )}

      :error ->
        {:error,
         Error.validation("patch operation is missing required field",
           source: __MODULE__,
           details: %{field: field, operation: operation}
         )}
    end
  end

  defp merge_operation_result(acc, result) do
    %{
      changed_paths: acc.changed_paths ++ Map.get(result, :changed_paths, []),
      operation_summaries: acc.operation_summaries ++ Map.get(result, :operation_summaries, []),
      diagnostics: acc.diagnostics,
      before_hashes: Map.merge(acc.before_hashes, Map.get(result, :before_hashes, %{})),
      after_hashes: Map.merge(acc.after_hashes, Map.get(result, :after_hashes, %{}))
    }
  end

  defp expand_text_patch(patch_input, %Workspace{} = workspace) do
    operations = patch_operations_value(patch_input)

    if text_patch?(operations) do
      case parse_text_patch(workspace, operations) do
        {:ok, parsed_operations} -> put_patch_operations(patch_input, parsed_operations)
        {:error, _error} -> patch_input
      end
    else
      patch_input
    end
  end

  defp patch_operations_value(%__MODULE__{operations: operations}), do: operations
  defp patch_operations_value(input) when is_list(input), do: Keyword.get(input, :operations)

  defp patch_operations_value(input) when is_map(input),
    do: Map.get(input, :operations, Map.get(input, "operations"))

  defp patch_operations_value(_input), do: nil

  defp put_patch_operations(%__MODULE__{} = patch, operations),
    do: %{patch | operations: operations}

  defp put_patch_operations(input, operations) when is_list(input),
    do: Keyword.put(input, :operations, operations)

  defp put_patch_operations(input, operations) when is_map(input) do
    cond do
      Map.has_key?(input, :operations) -> Map.put(input, :operations, operations)
      Map.has_key?(input, "operations") -> Map.put(input, "operations", operations)
      true -> Map.put(input, :operations, operations)
    end
  end

  defp put_patch_operations(input, operations),
    do: %{operations: operations, metadata: %{raw: input}}

  defp text_patch?(value) when is_binary(value),
    do: String.contains?(value, "*** Begin Patch") and String.contains?(value, "*** End Patch")

  defp text_patch?(_value), do: false

  defp parse_text_patch(%Workspace{} = workspace, text) do
    text
    |> String.split("\n", trim: false)
    |> parse_text_patch_lines(workspace, [], nil)
  end

  defp parse_text_patch_lines([], _workspace, operations, nil),
    do: {:ok, Enum.reverse(operations)}

  defp parse_text_patch_lines([], workspace, operations, current) do
    finish_text_patch_file(workspace, current, operations)
  end

  defp parse_text_patch_lines([line | rest], workspace, operations, nil) do
    case text_patch_file_header(line) do
      {:ok, current} -> parse_text_patch_lines(rest, workspace, operations, current)
      :skip -> parse_text_patch_lines(rest, workspace, operations, nil)
    end
  end

  defp parse_text_patch_lines([line | rest], workspace, operations, current) do
    case text_patch_file_header(line) do
      {:ok, next_current} ->
        case finish_text_patch_file(workspace, current, operations) do
          {:ok, operations} -> parse_text_patch_lines(rest, workspace, operations, next_current)
          {:error, error} -> {:error, error}
        end

      :skip ->
        parse_text_patch_lines(
          rest,
          workspace,
          operations,
          update_in(current.lines, &(&1 ++ [line]))
        )
    end
  end

  defp text_patch_file_header("*** Add File: " <> path),
    do: {:ok, %{op: :create, path: path, lines: []}}

  defp text_patch_file_header("*** Update File: " <> path),
    do: {:ok, %{op: :update, path: path, lines: []}}

  defp text_patch_file_header("*** Delete File: " <> path),
    do: {:ok, %{op: :delete, path: path, lines: []}}

  defp text_patch_file_header(_line), do: :skip

  defp finish_text_patch_file(_workspace, %{op: :delete, path: path}, operations) do
    {:ok, [%{op: :delete, path: path} | operations]}
  end

  defp finish_text_patch_file(_workspace, %{op: :create, path: path, lines: lines}, operations) do
    content =
      lines
      |> Enum.reject(&text_patch_noise?/1)
      |> Enum.filter(&String.starts_with?(&1, "+"))
      |> Enum.map(&String.trim_leading(&1, "+"))
      |> Enum.join("\n")
      |> ensure_trailing_newline()

    {:ok, [%{op: :create, path: path, content: content} | operations]}
  end

  defp finish_text_patch_file(
         %Workspace{} = workspace,
         %{op: :update, path: path, lines: lines},
         operations
       ) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read),
         {:ok, original} <- File.read(resolved.path),
         {:ok, content} <- apply_text_hunks(original, lines) do
      {:ok, [%{op: :update, path: path, content: content} | operations]}
    end
  end

  defp apply_text_hunks(original, lines) do
    hunks =
      lines
      |> Enum.reject(&text_patch_noise?/1)
      |> split_text_hunks()

    original_lines = split_content_lines(original)

    hunks
    |> Enum.reduce_while({:ok, original_lines}, fn hunk, {:ok, acc} ->
      case apply_text_hunk(acc, hunk) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, updated_lines} ->
        {:ok, join_content_lines(updated_lines, String.ends_with?(original, "\n"))}

      error ->
        error
    end
  end

  defp split_text_hunks(lines) do
    lines
    |> Enum.reduce([[]], fn
      "@@" <> _header, [[]] -> [[]]
      "@@" <> _header, acc -> [[] | acc]
      line, [current | rest] -> [[line | current] | rest]
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reject(&(&1 == []))
    |> Enum.reverse()
  end

  defp apply_text_hunk(current_lines, hunk_lines) do
    old_lines = hunk_old_lines(hunk_lines)
    new_lines = hunk_new_lines(hunk_lines)

    case find_subsequence(current_lines, old_lines) do
      nil ->
        {:error,
         Error.validation("text patch hunk did not match current file",
           source: __MODULE__,
           details: %{old_lines: old_lines}
         )}

      index ->
        {prefix, rest} = Enum.split(current_lines, index)
        {_old, suffix} = Enum.split(rest, length(old_lines))
        {:ok, prefix ++ new_lines ++ suffix}
    end
  end

  defp hunk_old_lines(lines) do
    lines
    |> Enum.filter(&(String.starts_with?(&1, " ") or String.starts_with?(&1, "-")))
    |> Enum.map(&String.slice(&1, 1..-1//1))
  end

  defp hunk_new_lines(lines) do
    lines
    |> Enum.filter(&(String.starts_with?(&1, " ") or String.starts_with?(&1, "+")))
    |> Enum.map(&String.slice(&1, 1..-1//1))
  end

  defp find_subsequence(_lines, []), do: 0

  defp find_subsequence(lines, needle) do
    max_start = length(lines) - length(needle)

    if max_start < 0 do
      nil
    else
      Enum.find(0..max_start, fn index ->
        lines |> Enum.slice(index, length(needle)) |> Kernel.==(needle)
      end)
    end
  end

  defp split_content_lines(content) do
    lines = String.split(content, "\n", trim: false)

    if String.ends_with?(content, "\n") do
      Enum.drop(lines, -1)
    else
      lines
    end
  end

  defp join_content_lines(lines, true), do: Enum.join(lines, "\n") <> "\n"
  defp join_content_lines(lines, false), do: Enum.join(lines, "\n")

  defp text_patch_noise?("*** Begin Patch"), do: true
  defp text_patch_noise?("*** End Patch"), do: true
  defp text_patch_noise?(""), do: true
  defp text_patch_noise?(_line), do: false

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(content),
    do: if(String.ends_with?(content, "\n"), do: content, else: content <> "\n")

  defp normalize_operations(operations) when is_list(operations) and operations != [] do
    operations
    |> Enum.reduce_while({:ok, []}, fn operation, {:ok, acc} ->
      case normalize_operation(operation) do
        {:ok, operation} -> {:cont, {:ok, [operation | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      error -> error
    end
  end

  defp normalize_operations(operations) when is_binary(operations) do
    case Jason.decode(operations) do
      {:ok, decoded} ->
        normalize_operations(decoded)

      {:error, reason} ->
        {:error,
         Error.validation("patch operations JSON string could not be decoded",
           source: __MODULE__,
           details: %{operations: operations, reason: Exception.message(reason)}
         )}
    end
  end

  defp normalize_operations(operations) do
    {:error,
     Error.validation("patch operations must be a non-empty list",
       source: __MODULE__,
       details: %{operations: operations}
     )}
  end

  defp normalize_operation(operation) when is_map(operation) do
    op = normalize_op(get(operation, :op, nil))

    with {:ok, op} <- op,
         :ok <- validate_op(op) do
      {:ok,
       %{
         op: op,
         path: get(operation, :path, nil),
         from: get(operation, :from, nil),
         to: get(operation, :to, nil),
         content: get(operation, :content, nil),
         expected_hash: get(operation, :expected_hash, nil),
         overwrite: get(operation, :overwrite, false)
       }
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.new()}
    end
  end

  defp normalize_operation(operation) do
    {:error,
     Error.validation("patch operation must be a map",
       source: __MODULE__,
       details: %{operation: operation}
     )}
  end

  defp normalize_op(op) when is_atom(op), do: {:ok, op}

  defp normalize_op(op) when is_binary(op) do
    case op do
      "create" ->
        {:ok, :create}

      "update" ->
        {:ok, :update}

      "delete" ->
        {:ok, :delete}

      "move" ->
        {:ok, :move}

      other ->
        {:error,
         Error.validation("invalid patch operation", source: __MODULE__, details: %{op: other})}
    end
  end

  defp normalize_op(op) do
    {:error,
     Error.validation("patch operation op must be an atom or string",
       source: __MODULE__,
       details: %{op: op}
     )}
  end

  defp validate_op(op) when op in @valid_ops, do: :ok

  defp validate_op(op) do
    {:error,
     Error.validation("invalid patch operation",
       source: __MODULE__,
       details: %{op: op, valid_ops: @valid_ops}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("patch metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp operation_diagnostic(op, operation, %Error{} = error) do
    diagnostic(op, error.message, Map.put(error.details, :operation, operation))
  end

  defp diagnostic(code, message, details) do
    %{code: code, message: message, details: details}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
