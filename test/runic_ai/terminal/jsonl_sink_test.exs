defmodule RunicAI.Terminal.JsonlSinkTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.JsonlSink

  test "writes one JSON object per event line" do
    path = Path.join(tmp_dir(), "trace.jsonl")
    event = Event.new!(:status, title: "Started", status: :running, data: %{phase: :start})

    assert {:ok, device} = JsonlSink.open(path)
    assert :ok = JsonlSink.write_event(device, event)
    assert :ok = JsonlSink.close(device)

    [line] = path |> File.read!() |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)

    assert decoded["kind"] == "status"
    assert decoded["title"] == "Started"
    assert decoded["data"]["phase"] == "start"
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-terminal-jsonl-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
