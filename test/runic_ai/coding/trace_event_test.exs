defmodule RunicAI.Coding.TraceEventTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.TraceEvent
  alias RunicAI.Trace.Event

  test "builds redacted coding trace metadata for file, patch, command, and process activity" do
    file =
      TraceEvent.file_read(
        "lib/demo.ex",
        %{preview: "Authorization: Bearer abc.def.ghi", artifact_ref: "mem:123"},
        workspace_root: "/tmp/project",
        tool_name: "read_file"
      )

    assert %Event{} = file
    assert file.kind == :coding_file_read
    assert file.metadata.coding?
    assert file.metadata.path == "lib/demo.ex"
    assert file.metadata.artifact_ref == "mem:123"
    assert file.output.preview == "Authorization: Bearer [REDACTED]"

    assert TraceEvent.search(%{matches: []}).kind == :coding_search
    assert TraceEvent.patch(%{status: :ok}).kind == :coding_patch
    assert TraceEvent.command(%{status: :pass}).kind == :coding_command
    assert TraceEvent.process(%{status: :running}).kind == :coding_process
  end

  test "records a read, patch, and test-command trace sequence" do
    {:ok, store} = InMemory.start_link()
    persistence = {InMemory, store}

    events = [
      TraceEvent.file_read("lib/demo.ex", %{artifact_ref: "mem:read"}),
      TraceEvent.patch(%{status: :ok, changed_paths: ["lib/demo.ex"]}),
      TraceEvent.command(%{status: :pass, command: "mix test"})
    ]

    Enum.each(events, fn event ->
      assert :ok = Persistence.record_event(persistence, Map.from_struct(event))
    end)

    assert [
             %{kind: :coding_file_read},
             %{kind: :coding_patch},
             %{kind: :coding_command}
           ] = InMemory.events(store)
  end
end
