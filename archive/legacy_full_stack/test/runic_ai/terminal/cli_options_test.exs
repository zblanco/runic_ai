defmodule RunicAI.Terminal.CliOptionsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.CliOptions

  test "parses one-shot standard options" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize repo",
               "--agent",
               "standard",
               "--cwd",
               cwd,
               "--detail",
               "expanded",
               "--approve",
               "never",
               "--max-turns",
               "3",
               "--max-runtime-ms",
               "1000",
               "--proposal-timeout-ms",
               "300",
               "--jsonl",
               "tmp/trace.jsonl"
             ])

    assert opts.objective == "summarize repo"
    assert opts.agent == :standard
    assert opts.detail == :expanded
    assert opts.approve == :never
    assert opts.max_turns == 3
    assert opts.max_runtime_ms == 1_000
    assert opts.proposal_timeout_ms == 300
    assert opts.renderer == :auto
    assert opts.color == :auto
    assert opts.theme == :runic
    assert String.starts_with?(opts.jsonl_path, cwd)
    assert opts.persistence == :sqlite
    assert opts.sqlite_path == Path.join([cwd, ".runic_ai", "runs.db"])
  end

  test "parses approve-all aliases" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize repo",
               "--agent",
               "rlm",
               "--cwd",
               cwd,
               "--approve",
               "always"
             ])

    assert opts.approve == :always

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize repo",
               "--agent",
               "rlm",
               "--cwd",
               cwd,
               "--approve",
               "all"
             ])

    assert opts.approve == :always
  end

  test "parses presentation options" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize repo",
               "--cwd",
               cwd,
               "--renderer",
               "owl",
               "--color",
               "always",
               "--theme",
               "plain",
               "--progress",
               "off",
               "--unicode",
               "never",
               "--graph",
               "mermaid"
             ])

    assert opts.renderer == :owl
    assert opts.color == :always
    assert opts.theme == :plain
    assert opts.progress == :off
    assert opts.unicode == :never
    assert opts.graph == :mermaid
  end

  test "parses capability profile and toolset options" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "inspect repo",
               "--cwd",
               cwd,
               "--profile",
               "local-workbench",
               "--toolsets",
               "terminal,code-execution",
               "--disable-tool",
               "run_command",
               "--disable-tool=process_kill",
               "--allow-tool",
               "read_file",
               "--tool-config",
               "terminal.timeout_ms=120000",
               "--tool-config",
               "terminal.shell_review=always"
             ])

    assert opts.profile == "local-workbench"
    assert opts.toolsets == ["terminal", "code-execution"]
    assert opts.disabled_tools == ["run_command", "process_kill"]
    assert opts.allowed_tools == ["read_file"]

    assert opts.tool_config == %{
             "terminal" => %{"timeout_ms" => 120_000, "shell_review" => "always"}
           }
  end

  test "allows help without an objective" do
    assert {:ok, opts} = CliOptions.parse(["--help"])
    assert opts.help?
  end

  test "rejects invalid agent values" do
    cwd = tmp_dir()
    assert {:error, error} = CliOptions.parse(["do work", "--agent", "unknown", "--cwd", cwd])
    assert error.message =~ "invalid runic_ai.agent agent"
  end

  test "parses assistant route options" do
    cwd = tmp_dir()
    File.mkdir_p!(Path.join(cwd, "tmp"))

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize chapter",
               "--agent",
               "assistant",
               "--cwd",
               cwd,
               "--input",
               "tmp/chapter.md",
               "--output",
               ".docs/chapter.md",
               "--allow-generated-functions",
               "tier2-review",
               "--write-policy",
               "docs-only"
             ])

    assert opts.agent == :assistant
    assert opts.input_paths == ["tmp/chapter.md"]
    assert opts.output_path == ".docs/chapter.md"
    assert opts.allow_generated_functions == :tier2_review
    assert opts.write_policy == :docs_only

    assert CliOptions.concurrency_opts(opts) == [
             async: true,
             max_concurrency: 4,
             max_llm_map_concurrency: 4,
             max_llm_map_calls: 80
           ]
  end

  test "preserves repeated assistant input paths" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "--agent",
               "assistant",
               "--cwd",
               cwd,
               "--input",
               "tmp/old.md",
               "--input=tmp/new.md",
               "compare policies"
             ])

    assert opts.input_paths == ["tmp/old.md", "tmp/new.md"]
  end

  test "normalizes codex client alias to the callable client module" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse(["summarize repo", "--cwd", cwd, "--client", "codex"])

    assert opts.client == RunicAI.Coding.Codex.Client
    assert opts.client_label == "codex"
    assert opts.model == nil
    assert opts.model_resolution.decision == "codex_account_default"
    assert opts.model_resolution.effective_model == "codex-account-default"
  end

  test "remaps legacy Runic default model before Codex execution" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize repo",
               "--cwd",
               cwd,
               "--client",
               "codex",
               "--model",
               "openai:gpt-5.4-mini"
             ])

    assert opts.model == nil
    assert opts.requested_model == "openai:gpt-5.4-mini"
    assert opts.model_resolution.decision == "codex_account_default"

    assert Enum.any?(
             opts.model_resolution.warnings,
             &String.contains?(&1, "legacy Runic default")
           )
  end

  test "rejects provider-prefixed explicit models for Codex before launch" do
    cwd = tmp_dir()

    assert {:error, error} =
             CliOptions.parse([
               "summarize repo",
               "--cwd",
               cwd,
               "--client",
               "codex",
               "--model",
               "openai:gpt-4o"
             ])

    assert error.message =~ "unsupported model for local Codex client"
    assert error.details.requested_model == "openai:gpt-4o"
  end

  test "parses explicit concurrency options" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "summarize chapter",
               "--agent",
               "assistant",
               "--cwd",
               cwd,
               "--no-async",
               "--max-concurrency",
               "2",
               "--max-llm-map-concurrency",
               "3",
               "--max-llm-map-calls",
               "12"
             ])

    assert opts.async? == false
    assert opts.max_concurrency == 2
    assert opts.max_llm_map_concurrency == 3
    assert opts.max_llm_map_calls == 12

    assert CliOptions.concurrency_opts(opts) == [
             async: false,
             max_concurrency: 2,
             max_llm_map_concurrency: 3,
             max_llm_map_calls: 12
           ]
  end

  test "parses bounded RLM repair controls" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "repair objective",
               "--agent",
               "rlm",
               "--cwd",
               cwd,
               "--repair",
               "--max-repairs",
               "2"
             ])

    assert opts.repair? == true
    assert opts.max_repairs == 2

    assert {:ok, opts} =
             CliOptions.parse([
               "repair objective",
               "--agent",
               "rlm",
               "--cwd",
               cwd,
               "--no-repair",
               "--max-repairs",
               "0"
             ])

    assert opts.repair? == false
    assert opts.max_repairs == 0
  end

  test "parses opt-in RLM objective loop controls" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "build OpsLogic",
               "--agent",
               "rlm",
               "--cwd",
               cwd,
               "--objective-loop",
               "--max-objective-iterations",
               "4"
             ])

    assert opts.objective_loop? == true
    assert opts.max_objective_iterations == 4

    assert {:ok, opts} =
             CliOptions.parse([
               "build OpsLogic",
               "--agent",
               "rlm",
               "--cwd",
               cwd,
               "--no-objective-loop"
             ])

    assert opts.objective_loop? == false
  end

  test "uses the coordinator default for deterministic project generation unless overridden" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse([
               "build OpsLogic",
               "--agent",
               "rlm",
               "--mode",
               "patch",
               "--cwd",
               cwd
             ])

    assert opts.seed_project_generation? == nil

    assert {:ok, opts} =
             CliOptions.parse([
               "build OpsLogic",
               "--agent",
               "rlm",
               "--mode",
               "patch",
               "--cwd",
               cwd,
               "--seed-project-generation"
             ])

    assert opts.seed_project_generation? == true

    assert {:ok, opts} =
             CliOptions.parse([
               "build OpsLogic",
               "--agent",
               "rlm",
               "--mode",
               "patch",
               "--cwd",
               cwd,
               "--no-seed-project-generation"
             ])

    assert opts.seed_project_generation? == false
  end

  test "does not add concurrency defaults to standard agent unless requested" do
    cwd = tmp_dir()

    assert {:ok, opts} = CliOptions.parse(["inspect", "--agent", "standard", "--cwd", cwd])
    assert CliOptions.concurrency_opts(opts) == []

    assert {:ok, opts} =
             CliOptions.parse([
               "inspect",
               "--agent",
               "standard",
               "--cwd",
               cwd,
               "--async",
               "--max-concurrency",
               "2"
             ])

    assert CliOptions.concurrency_opts(opts) == [async: true, max_concurrency: 2]
  end

  test "rejects JSONL paths outside the workspace and tmp dir" do
    cwd = tmp_dir()

    assert {:error, error} =
             CliOptions.parse(["do work", "--cwd", cwd, "--jsonl", "/etc/runic-ai.jsonl"])

    assert error.message =~ "--jsonl"
  end

  test "parses SQLite persistence path inside the workspace" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse(["do work", "--cwd", cwd, "--sqlite", ".runic_ai/runs.db"])

    assert opts.persistence == :sqlite
    assert opts.sqlite_path == Path.join([cwd, ".runic_ai", "runs.db"])
  end

  test "parses explicit ephemeral persistence opt outs" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             CliOptions.parse(["do work", "--cwd", cwd, "--persistence", "memory"])

    assert opts.persistence == :memory
    assert opts.sqlite_path == nil

    assert {:ok, opts} =
             CliOptions.parse(["do work", "--cwd", cwd, "--persistence", "none"])

    assert opts.persistence == :none
    assert opts.sqlite_path == nil
  end

  test "rejects sqlite path when persistence is explicitly not sqlite" do
    cwd = tmp_dir()

    assert {:error, error} =
             CliOptions.parse([
               "do work",
               "--cwd",
               cwd,
               "--persistence",
               "memory",
               "--sqlite",
               ".runic_ai/runs.db"
             ])

    assert error.message =~ "--sqlite"
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "runic-ai-terminal-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
