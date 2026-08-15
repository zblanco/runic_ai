defmodule RunicAI.RLM.Components.SafeCompute do
  @moduledoc """
  Bounded deterministic computing components for assistant/RLM workflows.

  These operations intentionally interpret data descriptors. They do not eval
  Elixir source and they keep file access routed through `Coding.Workspace`.
  """

  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.Components.BlueprintTransform

  @default_limit 100
  @default_max_text_bytes 100_000

  @type family ::
          :collection_compute
          | :string_compute
          | :json_compute
          | :artifact_compute
          | :time_compute
          | :score_compute

  @spec run(family(), term(), map() | keyword(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(family, input, params \\ %{}, opts \\ []) when is_list(opts) do
    params = opts_map(params)
    op = op(params, default_op(family))

    case family do
      :collection_compute -> collection(op, input, params, opts)
      :string_compute -> string(op, input, params)
      :json_compute -> json(op, input, params)
      :artifact_compute -> artifact(op, input, params, opts)
      :time_compute -> time(op, input, params)
      :score_compute -> score(op, input, params)
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp collection("map", input, params, opts) do
    items = records(input)
    selected = Enum.take(items, integer(params, :limit, @default_limit))
    function = get(params, :function, %{tier: :tier0, op: :identity})

    selected
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case BlueprintTransform.apply(function, record_data(item),
             max_tier: Keyword.get(opts, :max_tier, :tier1)
           ) do
        {:ok, mapped} -> {:cont, {:ok, acc ++ [mapped_record(item, mapped)]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, mapped} ->
        {:ok, collection_result("map", items, mapped)}

      error ->
        error
    end
  end

  defp collection("filter", input, params, opts) do
    items = records(input)
    selected = Enum.take(items, integer(params, :limit, @default_limit))
    predicate = get(params, :predicate, get(params, :function, %{tier: :tier0, op: :identity}))

    filtered =
      Enum.filter(selected, fn item ->
        case BlueprintTransform.apply(predicate, record_data(item),
               max_tier: Keyword.get(opts, :max_tier, :tier1)
             ) do
          {:ok, value} -> truthy?(value)
          {:error, _error} -> false
        end
      end)

    {:ok, collection_result("filter", items, filtered)}
  end

  defp collection("group", input, params, _opts) do
    items = records(input)
    path = path(get(params, :group_by, get(params, :path, nil)))

    groups =
      items
      |> Enum.group_by(fn item -> record_data(item) |> get_path(path) |> key_string() end)
      |> Enum.map(fn {key, records} -> %{key: key, count: length(records), records: records} end)
      |> Enum.sort_by(& &1.count, :desc)

    {:ok,
     %{
       operation: :group,
       records: items,
       groups: groups,
       count: length(items),
       group_count: length(groups),
       truncated?: false
     }}
  end

  defp collection("sort", input, params, _opts) do
    items = records(input)
    path = path(get(params, :sort_by, get(params, :path, nil)))
    direction = op_value(get(params, :direction, "asc"))

    sorted = Enum.sort_by(items, &(record_data(&1) |> get_path(path) |> sort_key()))
    sorted = if direction == "desc", do: Enum.reverse(sorted), else: sorted

    {:ok, collection_result("sort", items, sorted)}
  end

  defp collection("dedupe", input, params, _opts) do
    items = records(input)
    paths = path_list(get(params, :dedupe_by, get(params, :keys, [])))

    deduped =
      if paths == [] do
        Enum.uniq(items)
      else
        Enum.uniq_by(items, fn item ->
          data = record_data(item)
          Enum.map(paths, &get_path(data, &1))
        end)
      end

    {:ok, collection_result("dedupe", items, deduped)}
  end

  defp collection("reduce", input, params, _opts) do
    items = records(input)
    reducer = op_value(get(params, :reducer, "count"))
    path = path(get(params, :path, get(params, :field, nil)))
    values = Enum.map(items, &(record_data(&1) |> get_path(path)))

    reduced =
      case reducer do
        "count" ->
          length(items)

        "sum" ->
          values |> Enum.map(&number/1) |> Enum.sum()

        "average" ->
          average(values)

        "avg" ->
          average(values)

        "min" ->
          values |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)

        "max" ->
          values |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

        "join" ->
          values
          |> Enum.map(&stringify/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(get(params, :separator, "\n"))

        "merge_maps" ->
          Enum.reduce(items, %{}, &Map.merge(&2, normalize_map(record_data(&1))))

        "merge_lists" ->
          List.flatten(items)

        _other ->
          length(items)
      end

    {:ok,
     %{
       operation: :reduce,
       reducer: reducer,
       value: reduced,
       count: length(items),
       truncated?: false
     }}
  end

  defp collection("take", input, params, _opts) do
    items = records(input)
    selected = Enum.take(items, integer(params, :limit, @default_limit))
    {:ok, collection_result("take", items, selected)}
  end

  defp collection("window", input, params, _opts) do
    items = records(input)
    size = integer(params, :size, 2)

    chunks =
      items
      |> Enum.chunk_every(max(size, 1))
      |> Enum.take(integer(params, :limit, @default_limit))

    {:ok,
     %{
       operation: :window,
       windows: chunks,
       count: length(chunks),
       input_count: length(items),
       truncated?: length(chunks) < div(length(items) + max(size, 1) - 1, max(size, 1))
     }}
  end

  defp collection(other, _input, _params, _opts), do: unsupported(:collection_compute, other)

  defp string("split", input, params) do
    text = text_value(input, params)
    separator = get(params, :separator, "\n")
    parts = String.split(text, to_string(separator), trim: get(params, :trim?, false))
    limit = integer(params, :limit, @default_limit)

    {:ok,
     %{
       operation: :split,
       text: text,
       parts: Enum.take(parts, limit),
       count: min(length(parts), limit),
       input_count: length(parts),
       truncated?: length(parts) > limit
     }}
  end

  defp string("join", input, params) do
    values =
      case get(params, :values, nil) do
        nil -> records(input)
        values -> List.wrap(values)
      end

    {:ok,
     %{
       operation: :join,
       text: values |> Enum.map(&stringify/1) |> Enum.join(get(params, :separator, "\n")),
       count: length(values)
     }}
  end

  defp string("replace", input, params) do
    text = text_value(input, params)
    pattern = get(params, :pattern, "")
    replacement = get(params, :replacement, "")

    {:ok,
     %{
       operation: :replace,
       text: String.replace(text, to_string(pattern), to_string(replacement))
     }}
  end

  defp string("trim", input, params) do
    {:ok, %{operation: :trim, text: String.trim(text_value(input, params))}}
  end

  defp string("regex_extract", input, params) do
    text = text_value(input, params)

    with {:ok, regex} <- compile_regex(get(params, :pattern, "")) do
      matches =
        regex
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.map(fn
          [] -> nil
          [single] -> single
          values -> values
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(integer(params, :limit, @default_limit))

      {:ok, %{operation: :regex_extract, matches: matches, count: length(matches)}}
    end
  end

  defp string("text_chunk", input, params) do
    text = text_value(input, params)
    by = op_value(get(params, :by, "lines"))
    limit = integer(params, :limit, @default_limit)
    size = integer(params, :size, 40)

    chunks =
      case by do
        "paragraphs" ->
          String.split(text, ~r/\n\s*\n/u, trim: true)

        "bytes" ->
          byte_chunks(text, size)

        _lines ->
          text
          |> String.split("\n", trim: false)
          |> Enum.chunk_every(size)
          |> Enum.map(&Enum.join(&1, "\n"))
      end

    {:ok,
     %{
       operation: :text_chunk,
       chunks: Enum.take(chunks, limit),
       count: min(length(chunks), limit),
       input_count: length(chunks),
       truncated?: length(chunks) > limit
     }}
  end

  defp string("template_render", input, params) do
    template = get(params, :template, text_value(input, params))
    data = get(params, :data, input)

    {:ok, %{operation: :template_render, text: render_template(template, data)}}
  end

  defp string(other, _input, _params), do: unsupported(:string_compute, other)

  defp json("parse", input, params) do
    text = text_value(input, params)

    case op_value(get(params, :format, "json")) do
      "jsonl" ->
        parse_jsonl(text)

      _json ->
        with {:ok, data} <- Jason.decode(text) do
          {:ok,
           %{
             operation: :json_parse,
             data: data,
             records: if(is_list(data), do: data, else: List.wrap(data)),
             count: if(is_list(data), do: length(data), else: 1)
           }}
        else
          {:error, error} ->
            {:error,
             Error.validation("invalid JSON input",
               source: __MODULE__,
               details: %{error: inspect(error)}
             )}
        end
    end
  end

  defp json("encode", input, _params) do
    {:ok, %{operation: :json_encode, text: Jason.encode!(input)}}
  end

  defp json("query", input, params) do
    data = data_value(input)
    path = path(get(params, :path, get(params, :query, [])))
    {:ok, %{operation: :json_query, value: get_path(data, path), path: Enum.join(path, ".")}}
  end

  defp json("map_get", input, params), do: json("query", input, params)

  defp json("map_pick", input, params) do
    data = data_value(input)
    keys = List.wrap(get(params, :keys, [])) |> Enum.map(&to_string/1)
    {:ok, %{operation: :map_pick, data: Map.take(normalize_map(data), keys), keys: keys}}
  end

  defp json("map_drop", input, params) do
    data = data_value(input)
    keys = List.wrap(get(params, :keys, [])) |> Enum.map(&to_string/1)
    {:ok, %{operation: :map_drop, data: Map.drop(normalize_map(data), keys), keys: keys}}
  end

  defp json("map_merge", input, params) do
    data = normalize_map(data_value(input))
    value = normalize_map(get(params, :value, get(params, :data, %{})))
    {:ok, %{operation: :map_merge, data: Map.merge(data, value)}}
  end

  defp json("records_from_jsonl", input, params),
    do: json("parse", input, Map.put(params, :format, "jsonl"))

  defp json("records_to_jsonl", input, _params) do
    lines = records(input) |> Enum.map(&Jason.encode!/1)
    {:ok, %{operation: :records_to_jsonl, text: Enum.join(lines, "\n"), count: length(lines)}}
  end

  defp json(other, _input, _params), do: unsupported(:json_compute, other)

  defp artifact("file_manifest", _input, params, opts) do
    with {:ok, workspace} <- workspace(opts),
         {:ok, files} <- manifest_files(workspace, params) do
      {:ok,
       %{
         operation: :file_manifest,
         files: files,
         count: length(files),
         truncated?: length(files) >= integer(params, :limit, @default_limit)
       }}
    end
  end

  defp artifact("file_render_preview", _input, params, opts) do
    with {:ok, workspace} <- workspace(opts),
         {:ok, resolved} <- Workspace.resolve_path(workspace, get(params, :path, nil), :read),
         {:ok, content} <- File.read(resolved.path) do
      max_bytes = integer(params, :max_bytes, 4_000)
      preview = binary_part(content, 0, min(byte_size(content), max_bytes))

      {:ok,
       %{
         operation: :file_render_preview,
         path: resolved.relative,
         preview: preview,
         byte_size: byte_size(content),
         truncated?: byte_size(content) > max_bytes
       }}
    end
  end

  defp artifact("artifact_read", _input, params, opts) do
    with {:ok, workspace} <- workspace(opts),
         {:ok, artifact} <-
           Persistence.get_artifact(workspace.persistence, get(params, :artifact_ref, "")) do
      {:ok, %{operation: :artifact_read, artifact: artifact}}
    end
  end

  defp artifact("artifact_write", input, params, opts) do
    with {:ok, workspace} <- workspace(opts) do
      artifact = %{
        kind: get(params, :kind, :safe_compute_artifact),
        content: get(params, :content, input),
        metadata: normalize_map(get(params, :metadata, %{}))
      }

      with {:ok, ref} <- Persistence.put_artifact(workspace.persistence, artifact) do
        {:ok,
         %{
           operation: :artifact_write,
           artifact_ref: ref,
           persisted?: not is_nil(ref),
           artifact: artifact
         }}
      end
    end
  end

  defp artifact("io_capture", input, _params, _opts) do
    {:ok,
     %{
       operation: :io_capture,
       status: get(input, :status, nil),
       output: get(input, :output, get(input, :text, stringify(input))),
       stderr: get(input, :stderr, ""),
       exit_status: get(input, :exit_status, nil)
     }}
  end

  defp artifact(other, _input, _params, _opts), do: unsupported(:artifact_compute, other)

  defp time("now", _input, params) do
    now = DateTime.utc_now()

    {:ok,
     %{
       operation: :time_now,
       utc: DateTime.to_iso8601(now),
       timezone: get(params, :timezone, "Etc/UTC")
     }}
  end

  defp time("parse", input, params) do
    value = get(params, :value, text_value(input, params))

    case parse_time(value) do
      {:ok, parsed} -> {:ok, Map.merge(%{operation: :time_parse}, parsed)}
      {:error, error} -> {:error, error}
    end
  end

  defp time("shift", input, params) do
    with {:ok, parsed} <- parse_time(get(params, :value, text_value(input, params))),
         {:ok, datetime} <- parsed_datetime(parsed) do
      unit = op_value(get(params, :unit, "day"))
      amount = integer(params, :amount, 0)
      seconds = amount * unit_seconds(unit)
      shifted = DateTime.add(datetime, seconds, :second)

      {:ok,
       %{operation: :time_shift, value: DateTime.to_iso8601(shifted), unit: unit, amount: amount}}
    end
  end

  defp time("compare", input, params) do
    with {:ok, left} <- parse_time(get(params, :left, text_value(input, params))),
         {:ok, right} <- parse_time(get(params, :right, get(params, :value, ""))),
         {:ok, left_dt} <- parsed_datetime(left),
         {:ok, right_dt} <- parsed_datetime(right) do
      {:ok,
       %{
         operation: :calendar_compare,
         relation: DateTime.compare(left_dt, right_dt),
         left: left.value,
         right: right.value
       }}
    end
  end

  defp time("deadline_plan", input, params) do
    path = path(get(params, :deadline_path, get(params, :path, "deadline")))
    now = DateTime.utc_now()

    records =
      input
      |> records()
      |> Enum.map(fn record ->
        deadline = record_data(record) |> get_path(path)

        label =
          with {:ok, parsed} <- parse_time(deadline),
               {:ok, deadline_dt} <- parsed_datetime(parsed) do
            if DateTime.compare(deadline_dt, now) == :lt, do: "overdue", else: "upcoming"
          else
            _error -> "unknown"
          end

        put_record_data(record, Map.put(record_data(record), "deadline_status", label))
      end)

    {:ok, %{operation: :deadline_plan, records: records, count: length(records)}}
  end

  defp time(other, _input, _params), do: unsupported(:time_compute, other)

  defp score("rank_records", input, params), do: rank_records(input, params)
  defp score("score_records", input, params), do: rank_records(input, params)

  defp score("bucket_records", input, params) do
    buckets = List.wrap(get(params, :buckets, []))

    with {:ok, ranked} <- rank_records(input, params) do
      records =
        Enum.map(ranked.records, fn record ->
          score = record_data(record) |> get("score", 0) |> number()
          bucket = bucket_for(score, buckets)
          put_record_data(record, Map.put(record_data(record), "bucket", bucket))
        end)

      {:ok, %{operation: :bucket_records, records: records, count: length(records)}}
    end
  end

  defp score("aggregate_metrics", input, params) do
    items = records(input)
    fields = path_list(get(params, :fields, get(params, :paths, [])))

    metrics =
      Map.new(fields, fn path ->
        values = Enum.map(items, &(record_data(&1) |> get_path(path) |> number()))
        key = Enum.join(path, ".")

        {key,
         %{
           count: length(values),
           sum: Enum.sum(values),
           average: average(values),
           min: Enum.min(values, fn -> nil end),
           max: Enum.max(values, fn -> nil end)
         }}
      end)

    {:ok, %{operation: :aggregate_metrics, metrics: metrics, count: length(items)}}
  end

  defp score(other, _input, _params), do: unsupported(:score_compute, other)

  defp rank_records(input, params) do
    items = records(input)
    criteria = List.wrap(get(params, :criteria, []))
    score_path = path(get(params, :score_by, get(params, :path, nil)))

    ranked =
      items
      |> Enum.map(fn record ->
        data = record_data(record)
        score = score_record(data, criteria, score_path)
        put_record_data(record, data |> Map.put("score", score))
      end)
      |> Enum.sort_by(&(record_data(&1) |> get("score", 0) |> number()), :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {record, rank} ->
        put_record_data(record, Map.put(record_data(record), "rank", rank))
      end)

    {:ok, %{operation: :rank_records, records: ranked, count: length(ranked)}}
  end

  defp score_record(data, [], []), do: data |> get("score", 0) |> number()
  defp score_record(data, [], path), do: data |> get_path(path) |> number()

  defp score_record(data, criteria, _path) do
    Enum.reduce(criteria, 0.0, fn criterion, acc ->
      path = path(get(criterion, :path, get(criterion, :key, nil)))
      weight = number(get(criterion, :weight, 1))
      value = get_path(data, path)

      acc + weight * criterion_score(value, criterion)
    end)
  end

  defp criterion_score(value, criterion) do
    cond do
      not is_nil(get(criterion, :equals, nil)) ->
        if value == get(criterion, :equals, nil), do: 1, else: 0

      contains = get(criterion, :contains, nil) ->
        if String.contains?(
             String.downcase(stringify(value)),
             String.downcase(to_string(contains))
           ), do: 1, else: 0

      true ->
        number(value)
    end
  end

  defp parse_jsonl(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, decoded} ->
          {:cont, {:ok, acc ++ [decoded]}}

        {:error, error} ->
          {:halt,
           {:error,
            Error.validation("invalid JSONL input",
              source: __MODULE__,
              details: %{line: line, error: inspect(error)}
            )}}
      end
    end)
    |> case do
      {:ok, records} ->
        {:ok,
         %{
           operation: :records_from_jsonl,
           records: records,
           data: records,
           count: length(records)
         }}

      error ->
        error
    end
  end

  defp manifest_files(workspace, params) do
    root_path = get(params, :path, ".")
    limit = integer(params, :limit, @default_limit)

    with {:ok, resolved} <- Workspace.resolve_path(workspace, root_path, :read) do
      paths =
        cond do
          File.regular?(resolved.path) ->
            [resolved.path]

          File.dir?(resolved.path) ->
            resolved.path
            |> Path.join("**/*")
            |> Path.wildcard(match_dot: get(params, :include_hidden, false))
            |> Enum.filter(&File.regular?/1)
            |> Enum.take(limit)

          true ->
            []
        end

      files =
        Enum.map(paths, fn path ->
          stat = File.stat(path)

          %{
            path: Path.relative_to(path, workspace.root),
            byte_size: stat_size(stat),
            sha256: if(get(params, :hash?, false), do: file_sha256(path), else: nil)
          }
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()
        end)

      {:ok, files}
    end
  end

  defp workspace(opts) do
    case Keyword.get(opts, :workspace) do
      %Workspace{} = workspace ->
        {:ok, workspace}

      _other ->
        {:error,
         Error.validation("safe artifact computing requires a workspace", source: __MODULE__)}
    end
  end

  defp parse_time(value) do
    value = to_string(value)

    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        {:ok, %{type: :datetime, value: value, datetime: datetime}}

      match?({:ok, _}, Date.from_iso8601(value)) ->
        {:ok, date} = Date.from_iso8601(value)
        {:ok, %{type: :date, value: value, date: date}}

      match?({:ok, _}, Time.from_iso8601(value)) ->
        {:ok, time} = Time.from_iso8601(value)
        {:ok, %{type: :time, value: value, time: time}}

      true ->
        {:error,
         Error.validation("could not parse ISO date/time value",
           source: __MODULE__,
           details: %{value: value}
         )}
    end
  end

  defp parsed_datetime(%{datetime: %DateTime{} = datetime}), do: {:ok, datetime}

  defp parsed_datetime(%{date: %Date{} = date}) do
    {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}
  end

  defp parsed_datetime(parsed),
    do:
      {:error,
       Error.validation("parsed value is not date-like", source: __MODULE__, details: parsed)}

  defp default_op(:collection_compute), do: "take"
  defp default_op(:string_compute), do: "trim"
  defp default_op(:json_compute), do: "parse"
  defp default_op(:artifact_compute), do: "file_manifest"
  defp default_op(:time_compute), do: "now"
  defp default_op(:score_compute), do: "rank_records"

  defp collection_result(operation, input, output) do
    %{
      operation: operation,
      records: output,
      items: output,
      count: length(output),
      input_count: length(input),
      truncated?: length(output) < length(input)
    }
  end

  defp text_value(input, params) do
    (get(params, :text, nil) || get(params, :value, nil) || get(input, :text, nil) ||
       get(input, :content, nil) || stringify(input))
    |> to_string()
    |> truncate_binary(integer(params, :max_bytes, @default_max_text_bytes))
  end

  defp data_value(%{"data" => data}), do: data
  defp data_value(%{data: data}), do: data
  defp data_value(input), do: input

  defp records(%{records: records}) when is_list(records), do: records
  defp records(%{"records" => records}) when is_list(records), do: records
  defp records(%{items: items}) when is_list(items), do: items
  defp records(%{"items" => items}) when is_list(items), do: items
  defp records(%{parts: parts}) when is_list(parts), do: parts
  defp records(%{"parts" => parts}) when is_list(parts), do: parts
  defp records(values) when is_list(values), do: values
  defp records(value), do: List.wrap(value)

  defp mapped_record(record, output) when is_map(record), do: Map.put(record, :output, output)
  defp mapped_record(record, output), do: %{input: record, output: output}

  defp record_data(%{data: data}) when is_map(data), do: data
  defp record_data(%{"data" => data}) when is_map(data), do: data
  defp record_data(record) when is_map(record), do: normalize_map(record)
  defp record_data(value), do: %{"value" => value}

  defp put_record_data(%{data: _data} = record, data), do: Map.put(record, :data, data)
  defp put_record_data(%{"data" => _data} = record, data), do: Map.put(record, "data", data)

  defp put_record_data(record, data) when is_map(record),
    do: data |> Map.merge(Map.drop(record, ["data", :data])) |> normalize_map()

  defp put_record_data(record, data), do: %{input: record, data: data}

  defp path(nil), do: []
  defp path(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp path(value), do: value |> to_string() |> String.split(".", trim: true)

  defp path_list(values),
    do: values |> List.wrap() |> Enum.map(&path/1) |> Enum.reject(&(&1 == []))

  defp get_path(value, []), do: value
  defp get_path(nil, _path), do: nil

  defp get_path(value, [key | rest]) when is_map(value),
    do: value |> get(key, nil) |> get_path(rest)

  defp get_path(_value, _path), do: nil

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map) and is_binary(key),
    do: Map.get(map, key, Map.get(map, existing_atom_key(map, key), default))

  defp get(_map, _key, default), do: default

  defp existing_atom_key(map, key) do
    Enum.find(Map.keys(map), fn
      atom when is_atom(atom) -> Atom.to_string(atom) == key
      _other -> false
    end)
  end

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {to_string(key), val} end)
  end

  defp normalize_map(_value), do: %{}

  defp op(params, default), do: params |> get(:op, get(params, :operation, default)) |> op_value()
  defp op_value(value) when is_atom(value), do: Atom.to_string(value)
  defp op_value(value), do: value |> to_string() |> String.downcase() |> String.replace("-", "_")

  defp integer(params, key, default) do
    case get(params, key, default) do
      value when is_integer(value) -> max(value, 0)
      value when is_binary(value) -> parse_integer(value, default)
      _other -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {int, ""} -> max(int, 0)
      _other -> default
    end
  end

  defp number(value) when is_integer(value) or is_float(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _rest} -> num
      :error -> 0
    end
  end

  defp number(_value), do: 0

  defp average(values) do
    numbers = Enum.map(values, &number/1)
    if numbers == [], do: 0, else: Enum.sum(numbers) / length(numbers)
  end

  defp key_string(nil), do: "nil"
  defp key_string(value), do: stringify(value)
  defp sort_key(nil), do: ""
  defp sort_key(value), do: stringify(value)
  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_number(value), do: to_string(value)
  defp stringify(value), do: inspect(value, limit: 40, printable_limit: 2_000)

  defp truthy?(value), do: value not in [false, nil, "", [], %{}]

  defp render_template(template, data) do
    Regex.replace(~r/\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}/, to_string(template), fn _match, key ->
      data |> get_path(String.split(key, ".")) |> stringify()
    end)
  end

  defp compile_regex(pattern) do
    case Regex.compile(to_string(pattern)) do
      {:ok, regex} ->
        {:ok, regex}

      {:error, reason} ->
        {:error,
         Error.validation("invalid regex pattern",
           source: __MODULE__,
           details: %{pattern: pattern, reason: inspect(reason)}
         )}
    end
  end

  defp byte_chunks(text, size) do
    size = max(size, 1)
    for <<chunk::binary-size(size) <- text>>, do: chunk
  end

  defp truncate_binary(value, max_bytes) when byte_size(value) <= max_bytes, do: value
  defp truncate_binary(value, max_bytes), do: binary_part(value, 0, max_bytes)

  defp stat_size({:ok, %File.Stat{size: size}}), do: size
  defp stat_size(_stat), do: nil

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp unit_seconds("week"), do: 7 * 24 * 60 * 60
  defp unit_seconds("day"), do: 24 * 60 * 60
  defp unit_seconds("hour"), do: 60 * 60
  defp unit_seconds("minute"), do: 60
  defp unit_seconds(_second), do: 1

  defp bucket_for(score, buckets) do
    buckets
    |> Enum.find_value("unbucketed", fn bucket ->
      min = get(bucket, :min, nil)
      max = get(bucket, :max, nil)

      cond do
        not is_nil(min) and score < number(min) -> nil
        not is_nil(max) and score > number(max) -> nil
        true -> to_string(get(bucket, :label, "bucket"))
      end
    end)
  end

  defp unsupported(family, op) do
    {:error,
     Error.validation("unsupported safe computing operation",
       source: __MODULE__,
       details: %{family: family, operation: op}
     )}
  end
end
