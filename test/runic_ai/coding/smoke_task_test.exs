defmodule RunicAI.Coding.SmokeTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "runs the terminal smoke task against a minimal Mix workspace" do
    root = mix_project_fixture()
    Mix.Task.reenable("runic_ai.coding.smoke")

    output =
      capture_io(fn ->
        Mix.Task.run("runic_ai.coding.smoke", ["--cwd", root, "--session-id", "test-smoke"])
      end)

    assert output =~ "Session: test-smoke"
    assert output =~ "Patch dry-run status: dry_run"
    assert output =~ "Command status: pass"
    assert output =~ "Final observation: smoke complete"
  end

  defp mix_project_fixture do
    root = tmp_dir()

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Demo.MixProject do\n  use Mix.Project\n  def project, do: [app: :demo, version: \"0.1.0\", elixir: \"~> 1.18\"]\nend\n"
    )

    root
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
