defmodule RunicAI.Coding.GitAndCodexTest do
  use ExUnit.Case, async: false

  alias RunicAI.Coding.Codex.ExecClient
  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.WorkflowCompiler
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.TraceRedactor
  alias RunicAI.Coding.Workspace

  test "git read tools run through command policy when git is available" do
    if System.find_executable("git") do
      root = tmp_dir()
      System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
      File.write!(Path.join(root, "README.md"), "hello\n")
      System.cmd("git", ["add", "README.md"], cd: root, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "initial"], cd: root, stderr_to_stdout: true)

      workspace = Workspace.new!(root: root)
      policy = CommandPolicy.new!(allowed_commands: ["git"])

      assert {:ok, status} = Tools.git_status(workspace, %{}, policy)
      assert status.status in [:pass, :fail]
      assert status.command =~ "git status"
    else
      assert true
    end
  end

  test "git read tools do not escape a nested workspace into its parent repository" do
    if System.find_executable("git") do
      parent_root = tmp_dir()
      nested_root = Path.join(parent_root, "isolated-workspace")
      File.mkdir_p!(nested_root)
      System.cmd("git", ["init"], cd: parent_root, stderr_to_stdout: true)

      workspace = Workspace.new!(root: nested_root)
      policy = CommandPolicy.new!(allowed_commands: ["git"])

      assert {:error, error} = Tools.git_status(workspace, %{}, policy)
      assert error.details.code == :workspace_not_git_root
      assert error.details.workspace_root == nested_root
    else
      assert true
    end
  end

  test "redacts secret-looking trace payloads" do
    value = %{
      api_key: "sk-thisshouldberedacted",
      nested: ["Authorization: Bearer abc.def.ghi", "path .env"]
    }

    redacted = TraceRedactor.redact(value)

    assert redacted.api_key == "[REDACTED]"
    assert hd(redacted.nested) == "Authorization: Bearer [REDACTED]"
    assert Enum.at(redacted.nested, 1) =~ "[REDACTED_PATH]"
  end

  test "normalizes codex JSONL events into trace events" do
    jsonl =
      ~s({"type":"message","content":"hello"}\n{"type":"result","status":"ok","api_key":"sk-secretsecretsecret"}\n)

    assert {:ok, normalized} = EventNormalizer.normalize_jsonl(jsonl)
    assert length(normalized.raw_events) == 2
    assert [%RunicAI.Trace.Event{} | _] = normalized.trace_events
    assert normalized.final["api_key"] == "[REDACTED]"
  end

  test "normalizes current codex exec assistant message events" do
    jsonl =
      ~s({"type":"thread.started","thread_id":"thread-1"}\n) <>
        ~s({"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"{\\\"ok\\\":true}"}}\n) <>
        ~s({"type":"turn.completed","usage":{"output_tokens":4}}\n) <>
        "2026-04-28T16:47:11Z ERROR codex_core::session: failed to record rollout items\n"

    assert {:ok, normalized} = EventNormalizer.normalize_jsonl(jsonl)
    assert normalized.final == %{"type" => "item.completed", "text" => ~s({"ok":true})}
    assert normalized.diagnostics != []
  end

  test "codex exec wrapper gives OS timeout a cleanup grace window" do
    workspace = Workspace.new!(root: tmp_dir())
    bin_dir = tmp_dir()
    timeout_path = Path.join(bin_dir, "timeout")
    old_path = System.get_env("PATH") || ""

    File.write!(timeout_path, """
    #!/bin/sh
    sleep 0.2
    printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"cleanup grace observed"}}'
    """)

    File.chmod!(timeout_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)

    assert {:ok, result} =
             ExecClient.run(workspace, "fake prompt",
               max_runtime_ms: 50,
               close_stdin?: false
             )

    assert result.command.status == :pass
    assert result.final["text"] == "cleanup grace observed"
    assert result.command.duration_ms >= 150
  end

  test "codex exec streams JSONL trace events before command completion" do
    workspace = Workspace.new!(root: tmp_dir())

    install_fake_codex([
      jsonl_printf(%{"type" => "thread.started", "status" => "running"}),
      "sleep 0.2\n",
      jsonl_printf(%{
        "type" => "item.completed",
        "item" => %{"type" => "agent_message", "text" => "streamed child answer"}
      }),
      "sleep 0.2\n",
      jsonl_printf(%{"type" => "turn.completed", "status" => "ok"})
    ])

    parent = self()

    task =
      Task.async(fn ->
        result =
          ExecClient.run(workspace, "fake prompt",
            event_sink: fn event -> send(parent, {:codex_stream_event, event}) end
          )

        send(parent, {:codex_stream_done, result})
        result
      end)

    assert_receive {:codex_stream_event,
                    %RunicAI.Trace.Event{
                      kind: :codex_exec_event,
                      metadata: %{codex_event_type: "thread.started"}
                    }},
                   500

    refute_receive {:codex_stream_done, _result}, 50

    assert_receive {:codex_stream_done, {:ok, result}}, 1_000
    assert result.final["text"] == "streamed child answer"
    assert result.command.metadata.streamed? == true

    assert {:ok, _result} = Task.yield(task, 0) || {:ok, Task.await(task)}
  end

  test "RLM child agents forward live Codex JSONL events into parent node events" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def answer, do: 42\nend\n")

    install_fake_codex([
      jsonl_printf(%{"type" => "thread.started", "status" => "running"}),
      "sleep 0.1\n",
      jsonl_printf(%{
        "type" => "item.completed",
        "item" => %{"type" => "agent_message", "text" => "child observed Demo.answer/0"}
      }),
      "sleep 0.1\n",
      jsonl_printf(%{"type" => "turn.completed", "status" => "ok"})
    ])

    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Agent.start_link(fn -> [] end)

    proposal =
      WorkflowProposal.new!(
        "Ask child to inspect Demo.answer/0",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0 briefly."}
          )
        ],
        stop_conditions: ["child answer returned"]
      )

    assert {:ok, _result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: RunicAI.Coding.Codex.Client,
               child_runtime_mode_caps: %{read_only: 2_000},
               event_sink: fn event -> Agent.update(events, &(&1 ++ [event])) end
             )

    emitted = Agent.get(events, & &1)

    live_index =
      Enum.find_index(
        emitted,
        &match?(
          %{
            stage: :child_agent_event,
            data: %{
              node_id: "child",
              live?: true,
              child_event: %{kind: :codex_exec_event}
            }
          },
          &1
        )
      )

    completed_index =
      Enum.find_index(emitted, &match?(%{stage: :child_agent_completed}, &1))

    assert is_integer(live_index)
    assert is_integer(completed_index)
    assert live_index < completed_index
  end

  unless System.get_env("RUNIC_AI_CODEX_SMOKE") == "1" and System.find_executable("codex") do
    @tag skip: "set RUNIC_AI_CODEX_SMOKE=1 with codex on PATH to run the Codex bridge smoke"
  end

  @tag timeout: 180_000
  test "codex exec bridge can use the local subscription-backed CLI when enabled" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:ok, result} =
             ExecClient.run(workspace, "Say CODING_CODEX_SMOKE_DONE and nothing else.",
               sandbox_mode: "read-only",
               approval_mode: "never",
               max_runtime_ms: 120_000
             )

    assert result.command.status == :pass
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp install_fake_codex(script_lines) do
    bin_dir = tmp_dir()
    codex_path = Path.join(bin_dir, "codex")
    old_path = System.get_env("PATH") || ""

    File.write!(codex_path, ["#!/bin/sh\n" | script_lines])
    File.chmod!(codex_path, 0o755)
    System.put_env("PATH", bin_dir <> ":" <> old_path)
    on_exit(fn -> System.put_env("PATH", old_path) end)
  end

  defp jsonl_printf(event) do
    "printf '%s\\n' #{shell_quote(Jason.encode!(event))}\n"
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
