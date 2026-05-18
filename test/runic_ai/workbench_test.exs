defmodule RunicAI.WorkbenchTest do
  use ExUnit.Case, async: false

  alias RunicAI.Event
  alias RunicAI.Workbench
  alias RunicAI.Persistence.SQLite
  alias RunicAI.ReviewRequest

  setup do
    SQLite.migrate!(Workbench.store!())
    :ok
  end

  test "records terminal events and hydrates a durable session snapshot" do
    session_id = unique_session_id("snapshot")

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("start"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :status,
               phase: :session,
               status: :running,
               title: "Workbench run queued",
               detail: "Inspect the workbench",
               data_json: %{
                 run_id: session_id,
                 cwd: File.cwd!(),
                 objective: "Inspect the workbench",
                 model: "test:model"
               },
               at: DateTime.utc_now()
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("message"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "Assistant response",
               detail: "The workbench has **durable** chat.",
               data_json: %{reply_text: "The workbench has **durable** chat."},
               at: DateTime.utc_now()
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert snapshot.session.status == "running"
    assert snapshot.session.objective == "Inspect the workbench"
    assert [%{content: content}] = snapshot.messages
    assert content =~ "durable"
    assert snapshot.metrics.events == 2
  end

  test "records core events without requiring the web layer to consume terminal events" do
    session_id = unique_session_id("core-event")
    :ok = Workbench.subscribe_session(session_id)

    event =
      Event.workflow_effect!(:analysis,
        id: unique_event_id("core-analysis"),
        session_id: session_id,
        run_id: session_id,
        agent: :assistant,
        source_step: :analysis,
        content: "Core analysis progress"
      )

    assert {:ok, _event} = Workbench.record_event(event)
    assert_receive {:workbench, :event, %Event{session_id: ^session_id, kind: :message}}

    assert snapshot = Workbench.session_snapshot(session_id)

    assert [%{kind: "analysis", transient: true, content: "Core analysis progress"}] =
             snapshot.messages

    assert snapshot.metrics.events == 1
  end

  test "session snapshot keeps transient workflow outputs and assistant summaries out of chat" do
    session_id = unique_session_id("visible-chat")
    at = ~U[2026-05-05 18:49:41Z]

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("intermediate"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :rlm_node,
               phase: :node_completed,
               status: :ok,
               title: "Assistant RLM Node completed ok",
               detail: "synthesis complete",
               data_json: %{
                 stage: :node_completed,
                 status: :ok,
                 data: %{
                   node_id: "assistant_node_7_synthesize",
                   type: :llm_leaf,
                   output: %{text: "I only have one notes block and no repo context."}
                 }
               },
               at: at
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("transient-final"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :rlm_node,
               phase: :node_completed,
               status: :ok,
               title: "Assistant RLM Node completed ok",
               detail: "synthesis complete",
               data_json: %{
                 stage: :node_completed,
                 status: :ok,
                 data: %{
                   node_id: "assistant_node_6_synthesize_report",
                   type: :llm_leaf,
                   output: %{text: "# Durably Merged Repo Report\n\nTransient copy."}
                 }
               },
               at: DateTime.add(at, 1, :second)
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("completed"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :rlm_plan,
               phase: :completed,
               status: :ok,
               title: "Assistant RLM Completed ok",
               detail: "completed",
               data_json: %{
                 stage: :completed,
                 status: :ok,
                 data: %{output_text: "# Durably Merged Repo Report\n\nFinal copy."}
               },
               at: DateTime.add(at, 2, :second)
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("scorecard"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :summary,
               phase: :scorecard,
               status: :ok,
               title: "Assistant RLM objective objective_satisfied",
               detail: "changed=0 risks=0",
               data_json: %{scorecard: %{objective_status: :objective_satisfied}},
               at: DateTime.add(at, 3, :second)
             })

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("final"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :summary,
               phase: :final,
               status: :ok,
               title: "Agent finished",
               detail: "status: ok",
               data_json: %{},
               at: DateTime.add(at, 4, :second)
             })

    assert snapshot = Workbench.session_snapshot(session_id)
    assert [%{kind: "workflow_output", content: content, transient: false}] = snapshot.messages
    assert content == "# Durably Merged Repo Report\n\nFinal copy."
    assert snapshot.metrics.messages == 1
    assert snapshot.metrics.events == 5
  end

  test "session snapshot deduplicates equivalent assistant final workflow outputs" do
    session_id = unique_session_id("dedupe-final")
    content = "# Comparison Report\n\n- Response target is one business day."
    at = ~U[2026-05-09 18:30:00Z]

    for {label, kind, phase, data, offset} <- [
          {"completed", :rlm_plan, :completed,
           %{stage: :completed, data: %{output_text: content}}, 0},
          {"final", :message, :assistant,
           %{
             role: "assistant",
             message_kind: "workflow_output",
             content: content,
             output_text: content,
             blocked?: false
           }, 1}
        ] do
      assert {:ok, _event} =
               Workbench.record_terminal_event(%{
                 id: unique_event_id(label),
                 session_id: session_id,
                 run_id: session_id,
                 agent: :assistant,
                 kind: kind,
                 phase: phase,
                 status: :ok,
                 title: "Assistant output",
                 detail: content,
                 data_json: data,
                 at: DateTime.add(at, offset, :second)
               })
    end

    assert %{messages: [%{content: ^content}], metrics: %{messages: 1}} =
             Workbench.session_snapshot(session_id)
  end

  test "starts a browser-owned assistant run with the configured runner function" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("launch")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Reply from the browser",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify",
               "max_runtime_ms" => "123456"
             })

    assert run_id != session_id

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert Enum.any?(
               snapshot.messages,
               &(&1.role == "user" and &1.content == "Reply from the browser")
             )

      assert Enum.any?(snapshot.messages, &String.contains?(&1.content, "Browser run complete"))
      assert Enum.any?(snapshot.events, &(&1.phase == "direct_response_completed"))

      assert Enum.any?(
               snapshot.events,
               &(&1.run_id == run_id and get_in(&1.data, ["max_runtime_ms"]) == 123_456)
             )

      assert Enum.any?(snapshot.runs, &(&1.id == run_id))
    end)
  end

  test "browser follow-up messages stay in the session with distinct turn runs" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("follow-up")

    assert {:ok, %{session_id: ^session_id, run_id: first_run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "First browser request",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify"
             })

    eventually(fn ->
      assert Workbench.session_snapshot(session_id).messages
             |> Enum.any?(&String.contains?(&1.content, "First browser request"))
    end)

    assert {:ok, %{session_id: ^session_id, run_id: second_run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Second browser request",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify"
             })

    assert first_run_id != second_run_id
    assert first_run_id != session_id
    assert second_run_id != session_id

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      user_messages =
        snapshot.messages
        |> Enum.filter(&(&1.role == "user"))
        |> Enum.map(& &1.content)

      assert "First browser request" in user_messages
      assert "Second browser request" in user_messages

      run_ids = Enum.map(snapshot.runs, & &1.id)
      assert first_run_id in run_ids
      assert second_run_id in run_ids
    end)
  end

  test "browser repo RLM requests without workspace cues route to assistant" do
    previous = Application.get_env(:runic_ai, :workbench, [])
    caller = self()

    run_fun = fn cwd, objective, opts ->
      send(caller, {:conversation_history, opts[:conversation_history]})
      fake_assistant_run(cwd, objective, opts)
    end

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, run_fun)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("rlm-route")

    objective =
      "Build a graph memory system for a Wandering Inn text adventure game."

    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("prior-rlm-output"),
               session_id: session_id,
               run_id: "rlm:web:prior",
               agent: :rlm,
               kind: :message,
               phase: :assistant,
               status: :ok,
               title: "RLM final output",
               detail: "## File output\n\nAGENTS.md",
               data_json: %{
                 run_id: "rlm:web:prior",
                 role: "assistant",
                 message_kind: "workflow_output",
                 content: "## File output\n\nAGENTS.md",
                 presentation_group_id: "rlm:web:prior"
               },
               at: DateTime.utc_now()
             })

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => objective,
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify"
             })

    assert String.starts_with?(run_id, "assistant:web")
    assert_receive {:conversation_history, history}
    refute Enum.any?(history, &String.contains?(&1.content, "AGENTS.md"))

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.agent == "assistant"
      assert Enum.any?(snapshot.messages, &(&1.role == "user" and &1.content == objective))
      assert Enum.any?(snapshot.messages, &String.contains?(&1.content, "Browser run complete"))

      assert Enum.any?(snapshot.events, fn event ->
               event.agent == "assistant" and
                 get_in(event.data, ["requested_agent"]) == "rlm" and
                 get_in(event.data, ["routed_agent"]) == "assistant" and
                 get_in(event.data, ["route_reason"]) == "non_workspace_rlm_objective"
             end)
    end)
  end

  test "browser repo RLM requests with workspace cues stay on the RLM runner" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      Keyword.put(previous, :run_fun, &__MODULE__.fake_assistant_run/3)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("rlm-route-code")

    assert {:ok, %{session_id: ^session_id, run_id: run_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Inspect the RunicAI repo tests for failures",
               "agent" => "rlm",
               "cwd" => File.cwd!(),
               "approve" => "safe",
               "mode" => "verify"
             })

    assert String.starts_with?(run_id, "rlm:web")

    eventually(fn ->
      snapshot = Workbench.session_snapshot(session_id)

      assert snapshot.session.agent == "rlm"

      refute Enum.any?(
               snapshot.events,
               &(get_in(&1.data, ["route_reason"]) == "non_workspace_rlm_objective")
             )
    end)
  end

  test "browser approval ask creates a pending review and resumes after browser decision" do
    previous = Application.get_env(:runic_ai, :workbench, [])

    Application.put_env(
      :runic_ai,
      :workbench,
      previous
      |> Keyword.put(:run_fun, &__MODULE__.fake_browser_review_run/3)
      |> Keyword.put(:max_runtime_ms, 2_000)
    )

    on_exit(fn -> Application.put_env(:runic_ai, :workbench, previous) end)

    session_id = unique_session_id("browser-review")
    review_id = "review:browser-artifact:#{session_id}"

    assert {:ok, %{session_id: ^session_id}} =
             Workbench.start_agent_run(%{
               "session_id" => session_id,
               "objective" => "Write .docs/browser-review.md after approval",
               "agent" => "assistant",
               "cwd" => File.cwd!(),
               "approve" => "ask",
               "mode" => "verify"
             })

    eventually(fn ->
      assert %{review_requests: [%{id: ^review_id, status: "pending"}]} =
               Workbench.session_snapshot(session_id)
    end)

    assert {:ok, _event} =
             Workbench.record_review_decision(session_id, review_id, %{
               "action" => "approve"
             })

    eventually(fn ->
      assert %{review_requests: [%{status: "approved"}], messages: messages} =
               Workbench.session_snapshot(session_id)

      assert Enum.any?(messages, &String.contains?(&1.content, "artifact_written"))
    end)
  end

  test "records browser review decisions as durable review history" do
    for {action, expected_status} <- [
          {"approve", "approved"},
          {"deny", "denied"},
          {"stop", "cancelled"},
          {"rewrite", "approved"}
        ] do
      session_id = unique_session_id("review-#{action}")
      review_id = "review:#{session_id}"
      seed_review_request(session_id, review_id)

      params =
        case action do
          "rewrite" -> %{"action" => action, "rewrite" => "Use a safer command."}
          _other -> %{"action" => action, "rewrite" => ""}
        end

      assert {:ok, _event} = Workbench.record_review_decision(session_id, review_id, params)

      assert %{review_requests: [%{status: ^expected_status, decision: decision}]} =
               Workbench.session_snapshot(session_id)

      assert decision["decision"] == action
    end
  end

  def fake_assistant_run(_cwd, objective, opts) do
    event_sink = Keyword.fetch!(opts, :event_sink)

    event_sink.(%{
      stage: :direct_response_completed,
      status: :ok,
      data: %{
        reply_text: "Browser run complete: #{objective}",
        output: %{text_preview: "Browser run complete: #{objective}"}
      }
    })

    {:ok,
     %{
       scorecard: %{objective_status: :objective_satisfied},
       artifacts: [],
       repair_history: []
     }}
  end

  def fake_browser_review_run(_cwd, _objective, opts) do
    review_id = "review:browser-artifact:#{opts[:session_id]}"

    request =
      ReviewRequest.new!(:assistant_artifact_write,
        checkpoint: :pre_write,
        resume_key: review_id,
        options: [:approve, :reject, :edit, :cancel],
        details: %{
          path: ".docs/browser-review.md",
          write_policy: :docs_only,
          input_preview: %{text_preview: "# Browser Review"}
        },
        metadata: %{safe?: true, risk: :low}
      )

    {:ok, decision} = opts[:review_decider].(request, %{session_id: opts[:session_id]})

    output =
      case decision.status do
        :approved -> "artifact_written: .docs/browser-review.md"
        status -> "artifact_not_written: #{status}"
      end

    {:ok,
     %{
       output_text: output,
       scorecard: %{objective_status: :objective_satisfied},
       artifacts: [],
       repair_history: []
     }}
  end

  defp seed_review_request(session_id, review_id) do
    assert {:ok, _event} =
             Workbench.record_terminal_event(%{
               id: unique_event_id("review"),
               session_id: session_id,
               run_id: session_id,
               agent: :assistant,
               kind: :hitl,
               phase: :review_requested,
               status: :review,
               title: "Review requested",
               detail: "review #{review_id}",
               data_json: %{
                 stage: :review_requested,
                 status: :review,
                 data: %{
                   id: review_id,
                   kind: :browser_review,
                   checkpoint: :pre_tool,
                   resume_key: review_id,
                   options: [:approve, :reject, :edit, :cancel],
                   details: %{tool_name: "apply_patch"}
                 }
               },
               at: DateTime.utc_now()
             })
  end

  defp eventually(fun, attempts \\ 40)

  defp eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    exception ->
      if attempts == 1 do
        reraise exception, __STACKTRACE__
      else
        Process.sleep(25)
        eventually(fun, attempts - 1)
      end
  end

  defp unique_session_id(label),
    do: "test:workbench:#{label}:#{System.unique_integer([:positive])}"

  defp unique_event_id(label), do: "test:event:#{label}:#{System.unique_integer([:positive])}"
end
