defmodule RunicAI.Coding.ReviewGate do
  @moduledoc """
  Coding-agent guard evaluator for risky local operations.

  The standard coding agent uses this module as its default `:pre_tool_guard`.
  It allows ordinary read, search, safe patch, and curated verification tools,
  while pausing for human review before broad writes, destructive patch
  operations, shell/process commands, formatter writes, and mutating git
  commands.
  """

  alias RunicAI.Control.GuardDecision
  alias RunicAI.Control.GuardRequest
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.ExecutionPlan

  @always_allow ~w(
    list_dir find_files read_file read_range read_many search_text search_regex
    git_status git_diff git_log git_show git_branch
    compile_project run_tests run_linter
    source_assert changed_file_inventory
  )

  @always_review ~w(run_command start_process process_write process_kill run_formatter)

  @mutating_git ~w(add am apply bisect branch checkout cherry-pick clean commit config
                   gc init merge mv pull push rebase reset restore revert rm stash switch tag worktree)

  @sensitive_names ~w(.env .envrc .netrc .npmrc .pypirc .gemrc id_rsa id_dsa id_ecdsa
                      id_ed25519 credentials secrets secret key pem p12 pfx)

  @default_max_patch_operations 12
  @default_max_patch_bytes 64_000
  @default_max_repair_cycles 4

  @type classification :: %{
          required(:action) => :allow | :review,
          required(:reason) => atom(),
          required(:details) => map()
        }

  @spec evaluate(GuardRequest.t()) :: GuardDecision.t()
  def evaluate(%GuardRequest{} = request), do: evaluate(request, [])

  @spec evaluate(GuardRequest.t(), keyword()) :: GuardDecision.t()
  def evaluate(%GuardRequest{execution_plan: %ExecutionPlan{} = plan} = request, opts)
      when is_list(opts) do
    plan
    |> classify_plan(request, opts)
    |> decision()
  end

  def evaluate(%GuardRequest{} = _request, _opts), do: GuardDecision.allow!(:no_tool_plan)

  @spec classify_plan(ExecutionPlan.t(), GuardRequest.t(), keyword()) :: classification()
  def classify_plan(%ExecutionPlan{} = plan, %GuardRequest{} = request, opts \\ [])
      when is_list(opts) do
    calls = plan.calls
    call_details = Enum.map(calls, &call_details/1)

    calls
    |> Enum.map(&classify_call(&1, request, opts))
    |> most_restrictive(%{
      calls: call_details,
      call_count: length(calls),
      guard_point: request.point
    })
  end

  defp decision(%{action: :allow, reason: reason, details: details}) do
    GuardDecision.allow!(reason,
      details: details,
      metadata: %{coding_review_gate?: true, review_required?: false}
    )
  end

  defp decision(%{action: :review, reason: reason, details: details}) do
    GuardDecision.review!(reason,
      details: Map.put(details, :review_request, review_payload(reason, details)),
      metadata: %{coding_review_gate?: true, review_required?: true}
    )
  end

  defp classify_call(%CallRequest{tool_name: name} = call, _request, _opts)
       when name in @always_allow do
    allow(:safe_coding_tool, call, %{git_read_only?: String.starts_with?(name, "git_")})
  end

  defp classify_call(%CallRequest{tool_name: "apply_patch"} = call, request, opts) do
    if repair_cycle_exhausted?(request, opts) do
      review(:repair_cycle_budget_exhausted, call, %{
        repair_cycles: repair_cycles(request),
        max_repair_cycles: Keyword.get(opts, :max_repair_cycles, @default_max_repair_cycles)
      })
    else
      classify_patch(call, opts)
    end
  end

  defp classify_call(%CallRequest{tool_name: name} = call, _request, _opts)
       when name in @always_review do
    review(risky_tool_reason(call), call, %{
      tool_name: name,
      command: command_summary(call),
      mutating_git?: mutating_git_command?(call)
    })
  end

  defp classify_call(%CallRequest{} = call, _request, _opts) do
    review(:unknown_coding_tool, call, %{tool_name: call.tool_name})
  end

  defp classify_patch(%CallRequest{} = call, opts) do
    operations = call.arguments |> get(:operations, []) |> review_operations()

    cond do
      operations == :unknown ->
        review(:patch_operations_not_inspectable, call, %{operations: operations})

      length(operations) > Keyword.get(opts, :max_patch_operations, @default_max_patch_operations) ->
        review(:broad_patch, call, %{operation_count: length(operations)})

      patch_content_bytes(operations) >
          Keyword.get(opts, :max_patch_bytes, @default_max_patch_bytes) ->
        review(:large_patch, call, %{byte_size: patch_content_bytes(operations)})

      destructive_patch?(operations) ->
        review(:destructive_patch, call, %{operations: operation_summaries(operations)})

      Enum.any?(operations, &risky_patch_path?/1) ->
        review(:risky_patch_path, call, %{operations: operation_summaries(operations)})

      true ->
        allow(:safe_patch, call, %{operations: operation_summaries(operations)})
    end
  end

  defp review_operations(operations) when is_list(operations), do: operations

  defp review_operations(operations) when is_binary(operations) do
    if String.contains?(operations, "*** Begin Patch") do
      operations
      |> String.split("\n", trim: true)
      |> Enum.reduce([], fn
        "*** Add File: " <> path, acc ->
          [%{op: "create", path: path, content: operations} | acc]

        "*** Update File: " <> path, acc ->
          [%{op: "update", path: path, content: operations} | acc]

        "*** Delete File: " <> path, acc ->
          [%{op: "delete", path: path, content: ""} | acc]

        _line, acc ->
          acc
      end)
      |> Enum.reverse()
      |> case do
        [] -> :unknown
        parsed -> parsed
      end
    else
      :unknown
    end
  end

  defp review_operations(_operations), do: :unknown

  defp most_restrictive(classifications, base_details) do
    review =
      Enum.find(classifications, fn classification -> classification.action == :review end)

    case review do
      nil ->
        %{
          action: :allow,
          reason: :safe_coding_tool_plan,
          details:
            Map.put(base_details, :classifications, Enum.map(classifications, & &1.details))
        }

      review ->
        %{
          action: :review,
          reason: review.reason,
          details:
            base_details
            |> Map.put(:selected, review.details)
            |> Map.put(:classifications, Enum.map(classifications, & &1.details))
        }
    end
  end

  defp allow(reason, call, extra) do
    %{
      action: :allow,
      reason: reason,
      details: Map.merge(call_details(call), extra)
    }
  end

  defp review(reason, call, extra) do
    %{
      action: :review,
      reason: reason,
      details: Map.merge(call_details(call), extra)
    }
  end

  defp call_details(%CallRequest{} = call) do
    %{
      call_id: call.id,
      tool_name: call.tool_name,
      arguments: call.arguments,
      request_index: call.request_index
    }
  end

  defp review_payload(reason, details) do
    %{
      reason: reason,
      calls: Map.get(details, :calls, []),
      selected: Map.get(details, :selected),
      required_decision: :human_review
    }
  end

  defp destructive_patch?(operations) do
    Enum.any?(operations, fn operation ->
      op = operation |> get(:op, nil) |> to_string()
      op in ["delete", "move"]
    end)
  end

  defp risky_tool_reason(%CallRequest{} = call) do
    cond do
      mutating_git_command?(call) -> :mutating_git_command
      shell_command?(call) -> :shell_command
      call.tool_name in ~w(process_write process_kill) -> :destructive_process_operation
      true -> :risky_coding_tool
    end
  end

  defp shell_command?(%CallRequest{} = call) do
    backend = get(call.arguments, :backend, nil)
    shell = get(call.arguments, :shell, nil)
    backend in ["shell", :shell, "just_bash", :just_bash] or not is_nil(shell)
  end

  defp mutating_git_command?(%CallRequest{} = call) do
    argv = get(call.arguments, :argv, nil)
    command = get(call.arguments, :command, nil)

    case normalize_command_words(argv, command, get(call.arguments, :args, [])) do
      ["git", subcommand | _rest] -> subcommand in @mutating_git
      _other -> false
    end
  end

  defp normalize_command_words(argv, _command, _args) when is_list(argv) do
    Enum.map(argv, &to_string/1)
  end

  defp normalize_command_words(_argv, command, args) when is_binary(command) do
    [command | Enum.map(List.wrap(args), &to_string/1)]
  end

  defp normalize_command_words(_argv, _command, _args), do: []

  defp command_summary(%CallRequest{} = call) do
    %{
      argv: get(call.arguments, :argv, nil),
      command: get(call.arguments, :command, nil),
      args: get(call.arguments, :args, []),
      backend: get(call.arguments, :backend, nil),
      cwd: get(call.arguments, :cwd, nil)
    }
  end

  defp risky_patch_path?(operation) do
    operation
    |> patch_paths()
    |> Enum.any?(&risky_path?/1)
  end

  defp patch_paths(operation) do
    [get(operation, :path, nil), get(operation, :from, nil), get(operation, :to, nil)]
    |> Enum.reject(&is_nil/1)
  end

  defp risky_path?(path) when is_binary(path) do
    segments = Path.split(path)
    basename = Path.basename(path)
    lower = String.downcase(basename)

    Path.type(path) == :absolute or
      ".." in segments or
      path in ["", "."] or
      Enum.any?(segments, &hidden_segment?/1) or
      Enum.any?(@sensitive_names, &String.contains?(lower, &1))
  end

  defp risky_path?(_path), do: true

  defp hidden_segment?("."), do: false
  defp hidden_segment?(".."), do: true
  defp hidden_segment?(segment), do: String.starts_with?(segment, ".")

  defp patch_content_bytes(operations) do
    Enum.reduce(operations, 0, fn operation, acc ->
      acc + byte_size(to_string(get(operation, :content, "")))
    end)
  end

  defp repair_cycle_exhausted?(%GuardRequest{} = request, opts) do
    max_repair_cycles = Keyword.get(opts, :max_repair_cycles, @default_max_repair_cycles)

    is_integer(max_repair_cycles) and max_repair_cycles >= 0 and
      repair_cycles(request) >= max_repair_cycles
  end

  defp repair_cycles(%GuardRequest{} = request) do
    request.state.conversation.messages
    |> Enum.count(&(&1.role == :tool and &1.name == "apply_patch"))
  end

  defp operation_summaries(operations) do
    Enum.map(operations, fn operation ->
      %{
        op: get(operation, :op, nil),
        path: get(operation, :path, nil),
        from: get(operation, :from, nil),
        to: get(operation, :to, nil),
        content_bytes: byte_size(to_string(get(operation, :content, "")))
      }
    end)
  end

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_map, _key, default), do: default
end
