defmodule RunicAI.Terminal.AgentTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "prints help for the terminal agent task" do
    Mix.Task.reenable("runic_ai.agent")

    output =
      capture_io(fn ->
        Mix.Task.run("runic_ai.agent", ["--help"])
      end)

    assert output =~ "Usage:"
    assert output =~ "mix runic_ai.agent"
  end
end
