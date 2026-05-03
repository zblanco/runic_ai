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
               "--jsonl",
               "tmp/trace.jsonl"
             ])

    assert opts.objective == "summarize repo"
    assert opts.agent == :standard
    assert opts.detail == :expanded
    assert opts.approve == :never
    assert opts.max_turns == 3
    assert opts.renderer == :auto
    assert opts.color == :auto
    assert opts.theme == :runic
    assert String.starts_with?(opts.jsonl_path, cwd)
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

    assert opts.sqlite_path == Path.join([cwd, ".runic_ai", "runs.db"])
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "runic-ai-terminal-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
