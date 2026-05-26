defmodule RunicAI.RLM.ContextSlicer do
  @moduledoc """
  Builds bounded context-slice contracts for delegated RLM work.

  This module is a planning helper. It turns file sets, repo areas, document
  sections, artifact groups, and review roles into `ContextSliceContract`
  values that can be attached to `SubagentAssignment` without copying broad
  context into the root coordinator prompt.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.Components.SourceSplitter
  alias RunicAI.RLM.ContextSliceContract
  alias RunicAI.RLM.EnvironmentRef

  @source_kinds [
    :file_set,
    :repo_area,
    :document_section,
    :artifact_partition,
    :review_role
  ]

  @type slice_family ::
          :file_set | :repo_area | :document_section | :artifact_partition | :review_role

  @spec source_kinds() :: [slice_family()]
  def source_kinds, do: @source_kinds

  @spec file_set(Workspace.t(), [String.t() | map()], keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def file_set(workspace, paths, opts \\ [])

  def file_set(%Workspace{} = workspace, paths, opts) when is_list(paths) do
    with {:ok, result} <- SourceSplitter.run(workspace, paths, splitter_opts(opts)) do
      slices =
        Enum.map(result.slices, fn slice ->
          source_ref(:file_set, slice.id,
            label: slice.path,
            metadata:
              compact_metadata(slice, opts)
              |> Map.merge(%{path: slice.path, source_family: :file_set})
          )
          |> contract(:code, slice, opts)
        end)

      {:ok, envelope(:file_set, slices, result)}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def file_set(_workspace, paths, _opts) do
    {:error,
     Error.validation("context slicer file_set requires a list of paths",
       source: __MODULE__,
       details: %{paths: paths}
     )}
  end

  @spec repo_areas(Workspace.t(), [String.t() | map()], keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def repo_areas(workspace, areas, opts \\ [])

  def repo_areas(%Workspace{} = workspace, areas, opts) when is_list(areas) do
    with {:ok, result} <- SourceSplitter.run(workspace, areas, splitter_opts(opts)) do
      slices =
        Enum.map(result.slices, fn slice ->
          area = area_for(slice.path, areas)

          source_ref(:repo_area, slice.id,
            label: area,
            metadata:
              compact_metadata(slice, opts)
              |> Map.merge(%{path: slice.path, repo_area: area, source_family: :repo_area})
          )
          |> contract(:code, slice, opts)
        end)

      {:ok, envelope(:repo_area, slices, result)}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def repo_areas(_workspace, areas, _opts) do
    {:error,
     Error.validation("context slicer repo_areas requires a list of areas",
       source: __MODULE__,
       details: %{areas: areas}
     )}
  end

  @spec document_sections([map() | String.t()], keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def document_sections(documents, opts \\ [])

  def document_sections(documents, opts) when is_list(documents) do
    slices =
      documents
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {document, index} ->
        document
        |> document_sections_for(index, opts)
        |> Enum.with_index(1)
        |> Enum.map(fn {section, section_index} ->
          id = "#{section.id}:section:#{section_index}"

          source_ref(:document_section, id,
            label: section.label,
            metadata:
              compact_metadata(section, opts)
              |> Map.merge(%{
                document_id: section.document_id,
                section_label: section.label,
                source_family: :document_section
              })
          )
          |> contract(:document, section, opts)
        end)
      end)

    {:ok, envelope(:document_section, slices, %{count: length(slices), truncated?: false})}
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def document_sections(documents, _opts) do
    {:error,
     Error.validation("context slicer document_sections requires a list",
       source: __MODULE__,
       details: %{documents: documents}
     )}
  end

  @spec artifact_partitions([map() | String.t()], keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def artifact_partitions(artifacts, opts \\ [])

  def artifact_partitions(artifacts, opts) when is_list(artifacts) do
    group_by = opt(opts, :group_by, :kind)

    slices =
      artifacts
      |> Enum.with_index(1)
      |> Enum.group_by(fn {artifact, _index} -> artifact_group(artifact, group_by) end)
      |> Enum.flat_map(fn {group, entries} ->
        entries
        |> Enum.with_index(1)
        |> Enum.map(fn {{artifact, original_index}, group_index} ->
          id = artifact_id(artifact, original_index)

          source_ref(:artifact_partition, id,
            label: group,
            metadata: %{
              artifact_ref: artifact_ref(artifact),
              artifact_group: group,
              group_index: group_index,
              source_family: :artifact_partition
            }
          )
          |> contract(:artifact, %{id: id, slice_id: group, provenance: [artifact]}, opts)
        end)
      end)

    {:ok, envelope(:artifact_partition, slices, %{count: length(slices), truncated?: false})}
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def artifact_partitions(artifacts, _opts) do
    {:error,
     Error.validation("context slicer artifact_partitions requires a list",
       source: __MODULE__,
       details: %{artifacts: artifacts}
     )}
  end

  @spec review_roles([String.t() | atom() | map()], [ContextSliceContract.t()], keyword() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def review_roles(roles, context_slices, opts \\ [])

  def review_roles(roles, context_slices, opts)
      when is_list(roles) and is_list(context_slices) do
    with {:ok, roles} <- validate_roles(roles),
         {:ok, context_slices} <- validate_context_slices(context_slices) do
      slices =
        for role <- roles,
            context_slice <- context_slices do
          source_ref(:review_role, "#{role.id}:#{context_slice.id}",
            label: role.name,
            metadata: %{
              review_role: role.name,
              source_slice_id: context_slice.id,
              source_family: :review_role
            }
          )
          |> ContextSliceContract.new!(
            id: "review:#{role.id}:#{context_slice.id}",
            source_kind: :structured,
            slice_id: context_slice.slice_id || context_slice.id,
            token_budget: opt(opts, :token_budget, context_slice.token_budget),
            byte_budget: opt(opts, :byte_budget, context_slice.byte_budget),
            expected_output_schema: opt(opts, :expected_output_schema, role.output_schema),
            merge_policy: opt(opts, :merge_policy, %{mode: :by_role}),
            review_policy: Map.merge(role.review_policy, %{role: role.name}),
            provenance: [context_slice | context_slice.provenance],
            metadata: %{
              review_role: role.name,
              source_slice_id: context_slice.id,
              source_family: :review_role
            }
          )
        end

      {:ok, envelope(:review_role, slices, %{count: length(slices), truncated?: false})}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  def review_roles(roles, context_slices, _opts) do
    {:error,
     Error.validation("context slicer review_roles requires role and context slice lists",
       source: __MODULE__,
       details: %{roles: roles, context_slices: context_slices}
     )}
  end

  defp splitter_opts(opts) do
    opts
    |> opts_map()
    |> Map.take([
      :strategy,
      "strategy",
      :max_bytes,
      "max_bytes",
      :max_sources,
      "max_sources",
      :max_directory_files,
      "max_directory_files",
      :max_file_bytes,
      "max_file_bytes"
    ])
  end

  defp source_ref(family, id, opts) do
    EnvironmentRef.new!(__MODULE__, "#{family}:#{id}",
      label: Keyword.get(opts, :label),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  defp contract(%EnvironmentRef{} = ref, source_kind, source, opts) do
    ContextSliceContract.new!(ref,
      id: slice_id(ref, source),
      source_kind: source_kind,
      slice_id: source[:slice_id] || source[:id],
      token_budget: opt(opts, :token_budget, nil),
      byte_budget: opt(opts, :byte_budget, source[:byte_size]),
      expected_output_schema: opt(opts, :expected_output_schema, nil),
      merge_policy: opt(opts, :merge_policy, nil),
      review_policy: opt(opts, :review_policy, nil),
      provenance: source[:provenance] || [ref],
      metadata: Map.merge(ref.metadata, %{slice_family: ref_family(ref)})
    )
  end

  defp envelope(family, slices, source_result) do
    %{
      family: family,
      slices: slices,
      count: length(slices),
      source_count: map_get(source_result, :source_count, nil),
      input_source_count: map_get(source_result, :input_source_count, nil),
      truncated?: map_get(source_result, :truncated?, false)
    }
  end

  defp document_sections_for(document, index, opts) when is_binary(document) do
    document_sections_for(%{id: "document_#{index}", text: document}, index, opts)
  end

  defp document_sections_for(document, index, opts) when is_map(document) do
    id = map_get(document, :id, "document_#{index}")
    text = to_string(map_get(document, :text, map_get(document, :content, "")))

    text
    |> sections(opt(opts, :strategy, :markdown_heading))
    |> Enum.with_index(1)
    |> Enum.map(fn {section, section_index} ->
      Map.merge(section, %{
        id: "#{id}:#{section_index}",
        document_id: id,
        byte_size: byte_size(section.text),
        provenance: [%{document_id: id, label: section.label, line_span: section.line_span}]
      })
    end)
  end

  defp document_sections_for(_document, _index, _opts), do: []

  defp sections(text, strategy) when strategy in [:markdown_heading, "markdown_heading"] do
    lines = String.split(text, "\n", trim: false)

    lines
    |> Enum.with_index(1)
    |> Enum.chunk_while(
      nil,
      fn {line, line_number}, acc ->
        heading? = String.match?(line, ~r/^\#{1,6}\s+/)

        cond do
          is_nil(acc) ->
            {:cont, new_section(line, line_number)}

          heading? ->
            {:cont, acc, new_section(line, line_number)}

          true ->
            {:cont, append_line(acc, line, line_number)}
        end
      end,
      fn
        nil -> {:cont, []}
        acc -> {:cont, acc, []}
      end
    )
    |> Enum.map(&finish_section/1)
  end

  defp sections(text, _strategy) do
    text
    |> String.split("\n\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.map(fn {section, index} ->
      %{label: "section #{index}", text: section, line_span: nil}
    end)
  end

  defp new_section(line, line_number) do
    %{
      label: heading_label(line, line_number),
      lines: [line],
      start_line: line_number,
      end_line: line_number
    }
  end

  defp append_line(section, line, line_number) do
    %{section | lines: section.lines ++ [line], end_line: line_number}
  end

  defp finish_section(section) do
    %{
      label: section.label,
      text: Enum.join(section.lines, "\n"),
      line_span: [section.start_line, section.end_line]
    }
  end

  defp heading_label(line, fallback_line) do
    case Regex.run(~r/^\#{1,6}\s+(.+)$/, line) do
      [_match, label] -> String.trim(label)
      _other -> "section #{fallback_line}"
    end
  end

  defp artifact_group(artifact, group_by) do
    artifact
    |> map_get(group_by, map_get(artifact, :kind, :artifact))
    |> to_string()
  end

  defp artifact_id(artifact, index) do
    artifact_ref(artifact) || map_get(artifact, :id, "artifact_#{index}")
  end

  defp artifact_ref(artifact) when is_binary(artifact), do: artifact

  defp artifact_ref(artifact) when is_map(artifact) do
    map_get(artifact, :ref, map_get(artifact, :artifact_ref, map_get(artifact, :path, nil)))
  end

  defp artifact_ref(_artifact), do: nil

  defp area_for(path, areas) do
    areas
    |> Enum.map(fn
      area when is_binary(area) -> area
      area when is_map(area) -> map_get(area, :path, map_get(area, :area, nil))
      _other -> nil
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find(path, &String.starts_with?(path, &1))
  end

  defp compact_metadata(source, opts) do
    metadata =
      %{
        source_id: source[:source_id] || source[:id],
        start_line: source[:start_line],
        end_line: source[:end_line],
        byte_size: source[:byte_size],
        char_count: source[:char_count],
        line_span: source[:line_span]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case opt(opts, :preview_bytes, 0) do
      bytes when is_integer(bytes) and bytes > 0 ->
        Map.put(
          metadata,
          :preview,
          source[:text]
          |> to_string()
          |> binary_part(0, min(bytes, byte_size(to_string(source[:text]))))
        )

      _other ->
        metadata
    end
  end

  defp validate_context_slices(slices) do
    Enum.reduce_while(slices, {:ok, []}, fn slice, {:ok, acc} ->
      case ContextSliceContract.from_input(slice) do
        {:ok, slice} -> {:cont, {:ok, acc ++ [slice]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_roles(roles) do
    Enum.reduce_while(roles, {:ok, []}, fn role, {:ok, acc} ->
      role = normalize_role(role)

      case validate_role(role) do
        {:ok, role} -> {:cont, {:ok, acc ++ [role]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_role(role) when is_atom(role),
    do: %{id: Atom.to_string(role), name: Atom.to_string(role)}

  defp normalize_role(role) when is_binary(role), do: %{id: role, name: role}

  defp normalize_role(role) when is_map(role) do
    %{
      id: map_get(role, :id, map_get(role, :name, nil)),
      name: map_get(role, :name, map_get(role, :id, nil)),
      output_schema: map_get(role, :output_schema, %{}),
      review_policy: map_get(role, :review_policy, %{})
    }
  end

  defp normalize_role(role), do: %{id: nil, name: role}

  defp validate_role(%{id: id, name: name} = role) when is_binary(id) and id != "" do
    if is_binary(name) and name != "" do
      {:ok, Map.put_new(role, :review_policy, %{}) |> Map.put_new(:output_schema, %{})}
    else
      invalid_role(role)
    end
  end

  defp validate_role(role), do: invalid_role(role)

  defp invalid_role(role) do
    {:error,
     Error.validation("review role must have a non-empty id and name",
       source: __MODULE__,
       details: %{role: role}
     )}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)

  defp opt(opts, key, default) do
    opts = opts_map(opts)
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_value, _key, default), do: default

  defp slice_id(%EnvironmentRef{} = ref, source), do: source[:id] || ref.source_id

  defp ref_family(%EnvironmentRef{} = ref) do
    case String.split(ref.source_id, ":", parts: 2) do
      ["file_set" | _] -> :file_set
      ["repo_area" | _] -> :repo_area
      ["document_section" | _] -> :document_section
      ["artifact_partition" | _] -> :artifact_partition
      ["review_role" | _] -> :review_role
      _other -> :context
    end
  end
end
