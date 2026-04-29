defmodule RunicAI.Coding.RLM.ObjectiveEvidence do
  @moduledoc """
  Compact evidence bundle for semantic objective judging.

  Evidence gathering is generic: it samples changed files, likely source/test
  files, command results, child summaries, and verification observations without
  assuming a language or project generator.
  """

  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.RLM.WorkflowProposal

  @default_globs [
    "lib/**/*",
    "*/lib/**/*",
    "src/**/*",
    "*/src/**/*",
    "app/**/*",
    "*/app/**/*",
    "test/**/*",
    "*/test/**/*",
    "spec/**/*",
    "*/spec/**/*",
    "packages/**/*",
    "README*",
    "*.{ex,exs,erl,hrl,js,jsx,ts,tsx,py,rb,go,rs,java,kt,md,json,yml,yaml,toml}"
  ]

  @excluded_segments MapSet.new([
                       ".git",
                       "_build",
                       "deps",
                       "node_modules",
                       "tmp",
                       "dist",
                       "build",
                       ".elixir_ls",
                       ".next",
                       "coverage"
                     ])

  @spec gather(Workspace.t(), map(), keyword()) :: map()
  def gather(%Workspace{} = workspace, context, opts \\ [])
      when is_map(context) and is_list(opts) do
    policy = Keyword.get(opts, :semantic_evidence_policy, Keyword.get(opts, :progress_policy, []))
    changed_files = string_list(Map.get(context, :changed_files, []))
    selected_files = selected_files(workspace, changed_files, policy)

    %{
      workspace_root: workspace.root,
      changed_files: changed_files,
      files: read_selected_files(workspace, selected_files, policy),
      command_results: command_summaries(context),
      child_results: child_summaries(context),
      verification_observations: observation_summaries(context),
      workflow: workflow_summary(context),
      risks: string_list(Map.get(context, :risks, [])),
      parent_outputs: summarize_value(Map.get(context, :parent_outputs, []), 4_000),
      metadata: %{
        selected_file_count: length(selected_files),
        max_files: integer_policy(policy, :max_files, 40),
        max_file_bytes: integer_policy(policy, :max_file_bytes, 8_000),
        max_total_bytes: integer_policy(policy, :max_total_bytes, 80_000)
      }
    }
  end

  @spec summary(map()) :: map()
  def summary(evidence) when is_map(evidence) do
    %{
      changed_files: Map.get(evidence, :changed_files, []),
      files: Enum.map(Map.get(evidence, :files, []), &Map.take(&1, [:path, :bytes, :truncated?])),
      command_results:
        Enum.map(Map.get(evidence, :command_results, []), &Map.take(&1, [:argv, :cwd, :status])),
      child_results:
        Enum.map(Map.get(evidence, :child_results, []), &Map.take(&1, [:id, :status, :role])),
      workflow: Map.get(evidence, :workflow, %{}),
      verification_count: length(Map.get(evidence, :verification_observations, [])),
      risk_count: length(Map.get(evidence, :risks, []))
    }
  end

  defp selected_files(%Workspace{} = workspace, changed_files, policy) do
    globs = List.wrap(policy_value(policy, :globs, @default_globs))
    max_files = integer_policy(policy, :max_files, 40)

    glob_files =
      globs
      |> Enum.flat_map(&glob_files(workspace, &1))

    (changed_files ++ glob_files)
    |> Enum.uniq()
    |> Enum.reject(&excluded_path?/1)
    |> Enum.take(max_files)
  end

  defp glob_files(workspace, glob) when is_binary(glob) and glob != "" do
    if safe_relative_glob?(glob) do
      workspace.root
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(fn path ->
        case Workspace.relative_path(workspace, path) do
          {:ok, relative} -> [relative]
          {:error, _error} -> []
        end
      end)
    else
      []
    end
  end

  defp glob_files(_workspace, _glob), do: []

  defp read_selected_files(workspace, selected_files, policy) do
    max_file_bytes = integer_policy(policy, :max_file_bytes, 8_000)
    max_total_bytes = integer_policy(policy, :max_total_bytes, 80_000)

    selected_files
    |> Enum.reduce_while({[], 0}, fn relative, {files, total_bytes} ->
      path = Path.join(workspace.root, relative)

      case File.read(path) do
        {:ok, content} ->
          content = strip_binary(content)
          bytes = byte_size(content)
          remaining = max(max_total_bytes - total_bytes, 0)
          take = min(max_file_bytes, remaining)

          if take == 0 do
            {:halt, {files, total_bytes}}
          else
            excerpt = String.slice(content, 0, take)

            file = %{
              path: relative,
              content: excerpt,
              bytes: bytes,
              truncated?: bytes > byte_size(excerpt)
            }

            {:cont, {[file | files], total_bytes + byte_size(excerpt)}}
          end

        {:error, _error} ->
          {:cont, {files, total_bytes}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp strip_binary(content) do
    if String.valid?(content), do: content, else: inspect(content, limit: 10_000)
  end

  defp command_summaries(context) do
    context
    |> Map.get(:command_results, [])
    |> List.wrap()
    |> Enum.map(fn command ->
      %{
        argv: field(command, :argv),
        command: field(command, :command),
        cwd: field(command, :cwd),
        status: field(command, :status),
        exit_status: field(command, :exit_status),
        output_preview:
          string_slice(field(command, :output_preview) || field(command, :output), 4_000)
      }
    end)
  end

  defp child_summaries(context) do
    context
    |> Map.get(:child_results, [])
    |> List.wrap()
    |> Enum.map(fn child ->
      %{
        id: field(child, :id),
        role: field(child, :role),
        status: field(child, :status),
        changed_files: string_list(field(child, :changed_files)),
        summary: string_slice(field(child, :summary), 4_000),
        unresolved_risks: string_list(field(child, :unresolved_risks) || field(child, :risks))
      }
    end)
  end

  defp observation_summaries(context) do
    context
    |> Map.get(:verification_observations, [])
    |> List.wrap()
    |> Enum.map(fn observation ->
      %{
        id: field(observation, :id),
        type: field(observation, :type),
        status: field(observation, :status),
        message: string_slice(field(observation, :message), 1_000),
        metadata: summarize_value(field(observation, :metadata), 2_000)
      }
    end)
  end

  defp workflow_summary(context) when is_map(context) do
    %{
      proposal: proposal_summary(field(context, :proposal)),
      trace: trace_summary(field(context, :trace)),
      episodes: episode_summaries(field(context, :episodes))
    }
  end

  defp workflow_summary(_context), do: %{}

  defp proposal_summary(%WorkflowProposal{} = proposal) do
    %{
      id: proposal.id,
      objective: proposal.objective,
      nodes: Enum.map(proposal.nodes, &proposal_node_summary/1),
      edges: Enum.map(proposal.edges, &jsonable(&1, 3)),
      stop_conditions: Enum.map(proposal.stop_conditions, &jsonable(&1, 3)),
      expected_artifacts: Enum.map(proposal.expected_artifacts, &jsonable(&1, 3)),
      metadata: jsonable(proposal.metadata, 3)
    }
  end

  defp proposal_summary(proposal) when is_map(proposal) do
    proposal_summary =
      case WorkflowProposal.from_input(proposal) do
        {:ok, %WorkflowProposal{} = proposal} -> proposal_summary(proposal)
        {:error, _error} -> jsonable(proposal, 4)
      end

    proposal_summary
  end

  defp proposal_summary(_proposal), do: nil

  defp proposal_node_summary(node) do
    %{
      id: field(node, :id),
      kind: stringify(field(node, :kind)),
      params: jsonable(field(node, :params) || %{}, 4),
      inputs: jsonable(field(node, :inputs) || [], 3),
      outputs: jsonable(field(node, :outputs) || [], 3),
      policy: jsonable(field(node, :policy) || %{}, 3),
      metadata: jsonable(field(node, :metadata) || %{}, 3)
    }
  end

  defp trace_summary(trace) do
    trace
    |> List.wrap()
    |> Enum.take(-40)
    |> Enum.map(&jsonable(&1, 4))
  end

  defp episode_summaries(episodes) do
    episodes
    |> List.wrap()
    |> Enum.take(-40)
    |> Enum.map(fn episode ->
      %{
        id: field(episode, :id),
        status: stringify(field(episode, :status)),
        parent_node_id: field(episode, :parent_node_id),
        worker_id: field(episode, :worker_id),
        metadata: jsonable(field(episode, :metadata) || %{}, 3)
      }
    end)
  end

  defp excluded_path?(relative) do
    relative
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@excluded_segments, &1))
  end

  defp safe_relative_glob?(glob) when is_binary(glob) and glob != "" do
    Path.type(glob) == :relative and ".." not in Path.split(glob)
  end

  defp safe_relative_glob?(_glob), do: false

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp string_list(_values), do: []

  defp string_slice(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp string_slice(nil, _max), do: nil
  defp string_slice(value, max), do: value |> inspect(limit: 50) |> String.slice(0, max)

  defp summarize_value(value, max), do: string_slice(value, max)

  defp jsonable(value, depth) when depth <= 0, do: summarize_value(value, 1_000)

  defp jsonable(value, _depth)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp jsonable(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp jsonable(value, depth) when is_list(value) do
    Enum.map(value, &jsonable(&1, depth - 1))
  end

  defp jsonable(%_struct{} = value, depth) do
    value
    |> Map.from_struct()
    |> jsonable(depth - 1)
  end

  defp jsonable(value, depth) when is_map(value) do
    Map.new(value, fn {key, value} -> {stringify(key), jsonable(value, depth - 1)} end)
  end

  defp jsonable(value, _depth), do: summarize_value(value, 1_000)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value, limit: 20)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil

  defp integer_policy(policy, key, default) do
    case policy_value(policy, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp policy_value(policy, key, default)

  defp policy_value(false, _key, default), do: default
  defp policy_value(nil, _key, default), do: default

  defp policy_value(policy, key, default) when is_list(policy),
    do: Keyword.get(policy, key, default)

  defp policy_value(policy, key, default) when is_map(policy),
    do: Map.get(policy, key, Map.get(policy, Atom.to_string(key), default))
end
