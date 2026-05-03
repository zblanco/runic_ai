defmodule RunicAI.Coding.AgentState do
  @moduledoc """
  Derived state and summaries for standard coding-agent runs.

  The integrated recipe owns the live state. This module extracts coding-specific
  evidence from that state: visible tools, tool calls, patch summaries, changed
  files, verification results, and trace events.
  """

  alias Runic.Workflow
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Coding.RepairAttempt
  alias RunicAI.Coding.RLM.RepairAttempt, as: RepairAttemptStruct
  alias RunicAI.Coding.StandardAgent.ObjectiveGate
  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Message
  alias RunicAI.Recipes.IntegratedToolAgent
  alias RunicAI.Trace.Event

  @verification_tools ~w(compile_project run_tests run_formatter run_linter project_command runtime_smoke source_assert)
  @rendered_diagram_max_count 6
  @rendered_diagram_max_bytes 8_000

  @type summary :: %{
          required(:status) => atom() | nil,
          required(:reply) => String.t() | nil,
          required(:visible_tools) => [String.t()],
          required(:tools_used) => [String.t()],
          required(:rendered_diagrams) => [map()],
          required(:changed_files) => [String.t()],
          required(:created_files) => [String.t()],
          required(:modified_files) => [String.t()],
          required(:deleted_files) => [String.t()],
          required(:workspace_delta) => map(),
          required(:patches) => [map()],
          required(:repair_attempts) => [map()],
          required(:verifications) => [map()],
          required(:risks) => [String.t()],
          required(:last_error) => String.t() | nil,
          required(:objective_status) => atom() | nil,
          required(:objective_scorecard) => map() | nil
        }

  @spec summary(Workflow.t() | SessionState.t() | nil, String.t() | atom()) :: summary()
  def summary(workflow_or_session, agent_id \\ "coding")

  def summary(%Workflow{} = workflow, agent_id) do
    workflow
    |> IntegratedToolAgent.session(agent_id)
    |> summary(agent_id)
    |> Map.put(:reply, IntegratedToolAgent.latest_reply_text(workflow, agent_id))
  end

  def summary(%SessionState{} = session, _agent_id) do
    tool_messages = tool_messages(session)
    patches = patch_summaries(tool_messages)
    workspace_delta = aggregate_delta(patches)
    repair_attempts = repair_attempt_summaries(session, patches)
    verifications = verification_summaries(tool_messages)
    rendered_diagrams = rendered_diagram_summaries(tool_messages)
    objective_evaluation = objective_evaluation(session)
    last_error = latest_error(session)

    %{
      status: session.status,
      reply: latest_assistant_reply(session),
      visible_tools: visible_tools(session),
      tools_used: tools_used(session),
      rendered_diagrams: rendered_diagrams,
      changed_files: changed_files(workspace_delta),
      created_files: workspace_delta.created,
      modified_files: workspace_delta.modified,
      deleted_files: workspace_delta.deleted,
      workspace_delta: workspace_delta,
      patches: patches,
      repair_attempts: repair_attempts,
      verifications: verifications,
      risks: risks(verifications, objective_evaluation, last_error),
      last_error: last_error,
      objective_status: objective_status(objective_evaluation),
      objective_scorecard: scorecard_summary(objective_evaluation)
    }
  end

  def summary(nil, _agent_id) do
    %{
      status: nil,
      reply: nil,
      visible_tools: [],
      tools_used: [],
      rendered_diagrams: [],
      changed_files: [],
      created_files: [],
      modified_files: [],
      deleted_files: [],
      workspace_delta: empty_delta(),
      patches: [],
      repair_attempts: [],
      verifications: [],
      risks: ["coding session was not found"],
      last_error: nil,
      objective_status: nil,
      objective_scorecard: nil
    }
  end

  @spec trace_events(Workflow.t() | SessionState.t() | nil, String.t() | atom()) :: [Event.t()]
  def trace_events(workflow_or_session, agent_id \\ "coding")

  def trace_events(%Workflow{} = workflow, agent_id) do
    workflow
    |> IntegratedToolAgent.session(agent_id)
    |> trace_events(agent_id)
  end

  def trace_events(%SessionState{} = session, _agent_id) do
    visibility_event(session) ++
      tool_call_events(session) ++
      observation_events(session) ++
      verification_events(session) ++
      repair_attempt_events(session)
  end

  def trace_events(nil, _agent_id), do: []

  @spec tool_messages(SessionState.t()) :: [Message.t()]
  def tool_messages(%SessionState{} = session) do
    Enum.filter(session.agent_state.conversation.messages, &(&1.role == :tool))
  end

  @spec tools_used(SessionState.t()) :: [String.t()]
  def tools_used(%SessionState{} = session) do
    session
    |> tool_messages()
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec visible_tools(SessionState.t()) :: [String.t()]
  def visible_tools(%SessionState{} = session) do
    session
    |> get_in([Access.key(:metadata), :lane_options, :visible_tools])
    |> case do
      tools when is_list(tools) -> tools
      _other -> []
    end
  end

  defp latest_assistant_reply(%SessionState{} = session) do
    session.agent_state.conversation.messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, content: content} -> content
      _message -> nil
    end)
  end

  defp patch_summaries(tool_messages) do
    tool_messages
    |> Enum.filter(&(&1.name == "apply_patch"))
    |> Enum.map(fn message ->
      result = message |> tool_payload() |> result_payload()

      %{
        status: atomish(result, :status),
        changed_paths: list_field(result, :changed_paths),
        operation_summaries: list_field(result, :operation_summaries),
        before_hashes: map_field(result, :before_hashes),
        after_hashes: map_field(result, :after_hashes),
        delta: patch_delta(result),
        diagnostics: list_field(result, :diagnostics),
        dry_run?: atomish(result, :status) == "dry_run"
      }
    end)
  end

  defp verification_summaries(tool_messages) do
    tool_messages
    |> Enum.filter(&(&1.name in @verification_tools))
    |> Enum.map(fn message ->
      result = message |> tool_payload() |> result_payload()

      %{
        tool: message.name,
        status: atomish(result, :status),
        command: field(result, :command),
        argv: field(result, :argv),
        cwd: field(result, :cwd),
        exit_status: field(result, :exit_status),
        output_preview: field(result, :output_preview) || field(result, :output),
        truncated?: field(result, :truncated?) || false,
        artifact_ref: field(result, :artifact_ref),
        source_assert?: message.name == "source_assert",
        runtime_smoke?: message.name == "runtime_smoke",
        results: list_field(result, :results),
        passed: field(result, :passed),
        failed: field(result, :failed),
        skipped: field(result, :skipped),
        metadata: map_field(result, :metadata)
      }
    end)
  end

  defp rendered_diagram_summaries(tool_messages) do
    tool_messages
    |> Enum.filter(&(&1.name == "render_mermaid"))
    |> Enum.map(fn message ->
      result = message |> tool_payload() |> result_payload()
      rendered = field(result, :rendered)

      %{
        status: atomish(result, :status),
        source: field(result, :source),
        path: field(result, :path),
        heading: field(result, :heading),
        container: field(result, :container),
        diagram_index: field(result, :diagram_index),
        requested_diagram_index: field(result, :requested_diagram_index),
        line_start: field(result, :line_start),
        line_end: field(result, :line_end),
        command: field(result, :command),
        format: field(result, :format),
        color: field(result, :color),
        exit_status: field(result, :exit_status),
        rendered: rendered_preview(rendered),
        rendered_truncated?: rendered_truncated?(rendered),
        tool_truncated?: field(result, :truncated?) || false,
        error: field(result, :error)
      }
    end)
    |> Enum.filter(fn diagram ->
      diagram.rendered not in [nil, ""] or diagram.error not in [nil, ""]
    end)
    |> Enum.take(@rendered_diagram_max_count)
  end

  defp aggregate_delta(patches) do
    Enum.reduce(patches, empty_delta(), fn patch, acc ->
      patch_delta = Map.get(patch, :delta, empty_delta())

      %{
        created: merge_paths(acc.created, Map.get(patch_delta, :created, [])),
        modified: merge_paths(acc.modified, Map.get(patch_delta, :modified, [])),
        deleted: merge_paths(acc.deleted, Map.get(patch_delta, :deleted, [])),
        changed: merge_paths(acc.changed, Map.get(patch_delta, :changed, []))
      }
    end)
  end

  defp empty_delta, do: %{created: [], modified: [], deleted: [], changed: []}

  defp patch_delta(result) do
    before_hashes = map_field(result, :before_hashes)
    after_hashes = map_field(result, :after_hashes)
    changed_paths = list_field(result, :changed_paths)

    paths =
      [Map.keys(before_hashes), Map.keys(after_hashes), changed_paths]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    delta =
      Enum.reduce(paths, empty_delta(), fn path, acc ->
        before_hash = Map.get(before_hashes, path)
        after_hash = Map.get(after_hashes, path)

        cond do
          is_nil(before_hash) and is_binary(after_hash) ->
            %{acc | created: [path | acc.created]}

          is_binary(before_hash) and is_nil(after_hash) ->
            %{acc | deleted: [path | acc.deleted]}

          before_hash != after_hash ->
            %{acc | modified: [path | acc.modified]}

          path in changed_paths ->
            %{acc | modified: [path | acc.modified]}

          true ->
            acc
        end
      end)

    changed =
      delta.created
      |> Kernel.++(delta.modified)
      |> Kernel.++(delta.deleted)
      |> Kernel.++(changed_paths)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      created: Enum.sort(Enum.uniq(delta.created)),
      modified: Enum.sort(Enum.uniq(delta.modified)),
      deleted: Enum.sort(Enum.uniq(delta.deleted)),
      changed: changed
    }
  end

  defp changed_files(delta) do
    delta.changed
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp repair_attempt_summaries(%SessionState{} = session, patches) do
    workspace_root = workspace_root(session) || "."
    timestamp = DateTime.utc_now()

    patches
    |> Enum.with_index(1)
    |> Enum.map(fn {patch, iteration} ->
      status = repair_attempt_status(patch)

      RepairAttempt.new!(
        iteration: iteration,
        status: status,
        workspace_root: workspace_root,
        started_at: timestamp,
        completed_at: timestamp,
        changed_files: list_field(patch, :changed_paths),
        delta: Map.get(patch, :delta, empty_delta()),
        metadata: %{
          source: :standard_agent_patch_observation,
          patch_status: Map.get(patch, :status),
          dry_run?: Map.get(patch, :dry_run?, false),
          diagnostics: Map.get(patch, :diagnostics, [])
        }
      )
      |> summarize_repair_attempt()
    end)
  end

  defp repair_attempt_status(%{status: status, diagnostics: diagnostics}) do
    cond do
      status in [:ok, "ok"] -> :completed
      status in [:dry_run, "dry_run"] -> :partial
      diagnostics not in [nil, []] -> :failed
      true -> :partial
    end
  end

  defp summarize_repair_attempt(%RepairAttemptStruct{} = attempt) do
    %{
      id: attempt.id,
      iteration: attempt.iteration,
      status: attempt.status,
      workspace_root: attempt.workspace_root,
      started_at: attempt.started_at,
      completed_at: attempt.completed_at,
      changed_files: attempt.changed_files,
      delta: attempt.delta,
      metadata: attempt.metadata
    }
  end

  defp risks(verifications, objective_evaluation, last_error) do
    []
    |> Kernel.++(verification_risks(verifications))
    |> Kernel.++(objective_risks(objective_evaluation))
    |> Kernel.++(error_risks(last_error))
    |> Enum.uniq()
  end

  defp error_risks(nil), do: []
  defp error_risks(last_error), do: ["turn ended with error: #{last_error}"]

  defp verification_risks([]), do: ["verification was not run"]

  defp verification_risks(verifications) do
    failures =
      verifications
      |> latest_by_tool()
      |> Enum.reject(fn verification ->
        verification.status in [:pass, "pass"]
      end)

    case failures do
      [] -> []
      failures -> Enum.map(failures, &"#{&1.tool} ended with status #{&1.status}")
    end
  end

  defp objective_risks(nil), do: []

  defp objective_risks(%{status: :objective_satisfied}), do: []

  defp objective_risks(%{status: status, blocking_acceptance: blocking}) do
    [
      "objective gate ended with status #{status}"
      | Enum.map(blocking, fn result ->
          id = field(result, :id) || field(result, :type) || "acceptance"
          message = field(result, :message) || "blocking check failed"
          "#{id}: #{message}"
        end)
    ]
  end

  defp objective_status(nil), do: nil
  defp objective_status(%{status: status}), do: status

  defp latest_error(%SessionState{
         agent_state: %{last_turn_result: %TurnResult{kind: :error} = result}
       }) do
    result.details
    |> field(:error)
    |> case do
      %Error{} = error -> error_summary(error)
      nil -> error_summary(result.raw)
      other -> error_summary(other)
    end
  end

  defp latest_error(%SessionState{}), do: nil

  defp error_summary(%Error{} = error) do
    [to_string(error.kind), error.message]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(": ")
  end

  defp error_summary(nil), do: nil
  defp error_summary(error) when is_binary(error), do: error
  defp error_summary(error), do: inspect(error, limit: 5, printable_limit: 300)

  defp objective_evaluation(%SessionState{} = session) do
    metadata = session.agent_state.metadata || %{}

    with true <- field(metadata, :objective_gate?) in [true, "true"],
         objective when is_binary(objective) and objective != "" <- field(metadata, :objective),
         workspace_root when is_binary(workspace_root) and workspace_root != "" <-
           field(metadata, :workspace_root),
         true <- File.dir?(workspace_root) do
      workspace = Workspace.from_input!(workspace_root)

      ObjectiveGate.evaluate(workspace, objective, session,
        require_changes?: field(metadata, :mode) in [:patch, "patch", :verify, "verify"],
        require_verification?: field(metadata, :mode) in [:verify, "verify"]
      )
    else
      _other -> nil
    end
  end

  defp scorecard_summary(nil), do: nil

  defp scorecard_summary(%{scorecard: scorecard} = evaluation) do
    %{
      id: field(scorecard, :id),
      objective_status: field(scorecard, :objective_status),
      acceptance_results: summarize_results(field(scorecard, :acceptance_results)),
      command_statuses: summarize_results(field(scorecard, :command_statuses)),
      changed_files: field(scorecard, :changed_files) || [],
      residual_risks: field(scorecard, :residual_risks) || [],
      blocking_acceptance: summarize_results(evaluation.blocking_acceptance),
      source_assertions: summarize_results(evaluation.source_assertions),
      objective_contract: field(field(scorecard, :metadata) || %{}, :objective_contract),
      objective_judgement: field(field(scorecard, :metadata) || %{}, :objective_judgement),
      objective_evidence_summary:
        field(field(scorecard, :metadata) || %{}, :objective_evidence_summary)
    }
  end

  defp summarize_results(nil), do: []

  defp summarize_results(results) when is_list(results) do
    Enum.map(results, &summarize_result/1)
  end

  defp summarize_results(result), do: summarize_result(result)

  defp summarize_result(result) when is_map(result) do
    %{
      id: field(result, :id),
      type: field(result, :type),
      status: field(result, :status),
      message: field(result, :message),
      command: field(result, :argv) || field(result, :command),
      cwd: field(result, :cwd),
      output_preview: field(result, :output_preview) || field(result, :output),
      metadata: field(result, :metadata) || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp summarize_result(result), do: result

  defp latest_by_tool(verifications) do
    verifications
    |> Enum.reduce(%{}, fn verification, acc ->
      Map.put(acc, verification.tool, verification)
    end)
    |> Map.values()
  end

  defp visibility_event(%SessionState{} = session) do
    [
      Event.new!(
        :coding_tool_visibility,
        agent_id: session.agent.id,
        output: %{visible_tools: visible_tools(session)},
        metadata: %{coding?: true, session_status: session.status}
      )
    ]
  end

  defp tool_call_events(%SessionState{} = session) do
    session.agent_state.conversation.messages
    |> Enum.filter(&(&1.role == :assistant))
    |> Enum.flat_map(fn message ->
      message
      |> get_in([Access.key(:metadata), :tool_calls])
      |> normalize_tool_calls()
      |> Enum.map(fn call ->
        Event.new!(
          :coding_tool_call,
          agent_id: session.agent.id,
          output: TraceRedactor.redact(call),
          metadata: %{coding?: true, tool_name: tool_call_name(call)}
        )
      end)
    end)
  end

  defp observation_events(%SessionState{} = session) do
    session
    |> tool_messages()
    |> Enum.map(fn message ->
      Event.new!(
        :coding_tool_observation,
        agent_id: session.agent.id,
        output: TraceRedactor.redact(tool_payload(message)),
        metadata: %{coding?: true, tool_name: message.name}
      )
    end)
  end

  defp verification_events(%SessionState{} = session) do
    session
    |> tool_messages()
    |> verification_summaries()
    |> Enum.map(fn verification ->
      Event.new!(
        :coding_verification_observation,
        agent_id: session.agent.id,
        output: TraceRedactor.redact(verification),
        metadata: %{
          coding?: true,
          verification?: true,
          tool_name: verification.tool,
          status: verification.status
        }
      )
    end)
  end

  defp repair_attempt_events(%SessionState{} = session) do
    patches =
      session
      |> tool_messages()
      |> patch_summaries()

    session
    |> repair_attempt_summaries(patches)
    |> Enum.map(fn attempt ->
      Event.new!(
        :coding_repair_attempt,
        agent_id: session.agent.id,
        status: attempt.status,
        output: TraceRedactor.redact(attempt),
        metadata: %{
          coding?: true,
          repair_attempt?: true,
          iteration: attempt.iteration,
          changed_files: attempt.changed_files
        }
      )
    end)
  end

  defp normalize_tool_calls(nil), do: []
  defp normalize_tool_calls(calls) when is_list(calls), do: calls
  defp normalize_tool_calls(_calls), do: []

  defp tool_call_name(%{name: name}), do: name
  defp tool_call_name(%{"name" => name}), do: name
  defp tool_call_name(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.name(call)
  defp tool_call_name(_call), do: nil

  defp tool_payload(%Message{content: content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> decoded
      {:error, _error} -> %{"raw" => content}
    end
  end

  defp result_payload(payload), do: field(payload, :result) || %{}

  defp rendered_preview(rendered) when is_binary(rendered) do
    truncate_utf8(rendered, @rendered_diagram_max_bytes)
  end

  defp rendered_preview(_rendered), do: nil

  defp rendered_truncated?(rendered) when is_binary(rendered) do
    byte_size(rendered) > @rendered_diagram_max_bytes
  end

  defp rendered_truncated?(_rendered), do: false

  defp workspace_root(%SessionState{} = session) do
    field(session.agent_state.metadata || %{}, :workspace_root) ||
      get_in(session.metadata, [Access.key(:turn_defaults), :metadata, :workspace_root])
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_map, _key), do: nil

  defp map_field(map, key) do
    case field(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp list_field(map, key) do
    case field(map, key) do
      value when is_list(value) -> value
      _other -> []
    end
  end

  defp merge_paths(left, right) do
    left
    |> Kernel.++(right)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp atomish(map, key) do
    case field(map, key) do
      value when is_atom(value) -> value
      value when is_binary(value) -> value
      nil -> nil
      value -> inspect(value)
    end
  end

  defp truncate_utf8(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate_utf8(value, max_bytes) do
    value
    |> binary_part(0, max_bytes)
    |> valid_utf8_prefix()
  end

  defp valid_utf8_prefix(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> valid_utf8_prefix()
    end
  end
end
