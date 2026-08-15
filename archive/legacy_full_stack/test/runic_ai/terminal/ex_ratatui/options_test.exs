defmodule RunicAI.Terminal.ExRatatui.OptionsTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.ExRatatui.Options

  test "defaults local harness persistence to workspace SQLite" do
    cwd = tmp_dir()

    assert {:ok, opts} = Options.parse(["--cwd", cwd])

    assert opts.persistence == :sqlite
    assert opts.sqlite_path == CliOptions.default_sqlite_path(cwd)
    assert opts.agent == :assistant
  end

  test "supports sqlite path override and explicit ephemeral opt out" do
    cwd = tmp_dir()

    assert {:ok, opts} = Options.parse(["--cwd", cwd, "--sqlite", "tmp/runs.db"])
    assert opts.persistence == :sqlite
    assert opts.sqlite_path == Path.join(cwd, "tmp/runs.db")

    assert {:ok, opts} = Options.parse(["--cwd", cwd, "--persistence", "memory"])
    assert opts.persistence == :memory
    assert opts.sqlite_path == nil
  end

  test "rejects sqlite path when persistence is not sqlite" do
    cwd = tmp_dir()

    assert {:error, error} =
             Options.parse([
               "--cwd",
               cwd,
               "--persistence",
               "none",
               "--sqlite",
               "tmp/runs.db"
             ])

    assert error.message =~ "--sqlite"
  end

  test "requires explicit password auth when SSH transport is enabled" do
    cwd = tmp_dir()

    assert {:error, error} = Options.parse(["--cwd", cwd, "--ssh", "40222"])
    assert error.message =~ "--ssh requires --ssh-password"

    assert {:ok, options} =
             Options.parse(["--cwd", cwd, "--ssh", "40222", "--ssh-password", "secret"])

    assert options.ssh_port == 40_222
    assert options.ssh_password == "secret"
  end

  test "uses shared model/client resolver for Codex options" do
    cwd = tmp_dir()

    assert {:ok, opts} =
             Options.parse([
               "--cwd",
               cwd,
               "--client",
               "codex",
               "--model",
               "openai:gpt-5.4-mini"
             ])

    assert opts.client == "codex"
    assert opts.client_label == "codex"
    assert opts.model == nil
    assert opts.requested_model == "openai:gpt-5.4-mini"
    assert opts.model_resolution.decision == "codex_account_default"

    assert {:error, error} =
             Options.parse(["--cwd", cwd, "--client", "codex", "--model", "openai:gpt-4o"])

    assert error.message =~ "unsupported model for local Codex client"
  end

  defp tmp_dir do
    path =
      Path.join(System.tmp_dir!(), "runic-ai-tui-options-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
