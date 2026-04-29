defmodule RunicAI.Coding.AgentState do
  @moduledoc """
  Derived state and summaries for standard coding-agent runs.

  The integrated recipe owns the live state. This module extracts coding-specific
  evidence from that state: visible tools, tool calls, patch summaries, changed
  files, verification results, and trace events.
  """

  alias Runic.Workflow
  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Message
  alias RunicAI.Recipes.IntegratedToolAgent
  alias RunicAI.Trace.Event

  @verification_tools ~w(compile_project run_tests run_formatter run_linter)

  @type summary :: %{
          required(:status) => atom() | nil,
          required(:reply) => String.t() | nil,
          required(:visible_tools) => [String.t()],
          required(:tools_used) => [String.t()],
          required(:changed_files) => [String.t()],
          required(:patches) => [map()],
          required(:verifications) => [map()],
          required(:risks) => [String.t()]
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
    verifications = verification_summaries(tool_messages)

    %{
      status: session.status,
      reply: latest_assistant_reply(session),
      visible_tools: visible_tools(session),
      tools_used: tools_used(session),
      changed_files: changed_files(patches),
      patches: patches,
      verifications: verifications,
      risks: risks(verifications)
    }
  end

  def summary(nil, _agent_id) do
    %{
      status: nil,
      reply: nil,
      visible_tools: [],
      tools_used: [],
      changed_files: [],
      patches: [],
      verifications: [],
      risks: ["coding session was not found"]
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
    visibility_event(session) ++ tool_call_events(session) ++ observation_events(session)
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
        exit_status: field(result, :exit_status),
        output_preview: field(result, :output_preview) || field(result, :output),
        truncated?: field(result, :truncated?) || false,
        artifact_ref: field(result, :artifact_ref)
      }
    end)
  end

  defp changed_files(patches) do
    patches
    |> Enum.flat_map(& &1.changed_paths)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp risks([]), do: ["verification was not run"]

  defp risks(verifications) do
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

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_map, _key), do: nil

  defp list_field(map, key) do
    case field(map, key) do
      value when is_list(value) -> value
      _other -> []
    end
  end

  defp atomish(map, key) do
    case field(map, key) do
      value when is_atom(value) -> value
      value when is_binary(value) -> value
      nil -> nil
      value -> inspect(value)
    end
  end
end
