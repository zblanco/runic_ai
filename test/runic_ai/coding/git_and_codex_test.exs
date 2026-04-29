defmodule RunicAI.Coding.GitAndCodexTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Codex.ExecClient
  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.CommandPolicy
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
end
