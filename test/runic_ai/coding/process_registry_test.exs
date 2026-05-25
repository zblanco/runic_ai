defmodule RunicAI.Coding.ProcessRegistryTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.CommandPolicy
  alias RunicAI.Coding.ProcessRegistry
  alias RunicAI.Coding.Workspace

  test "starts, logs, polls, writes to, and kills a background process" do
    {:ok, registry} = ProcessRegistry.start_link()
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["cat"])

    assert {:ok, handle} =
             ProcessRegistry.start_process(registry, workspace, %{argv: ["cat"]}, policy: policy)

    assert handle.status == :running
    assert :ok = ProcessRegistry.write(registry, handle.id, "hello\n")

    assert eventually(fn ->
             {:ok, log} = ProcessRegistry.log(registry, handle.id)
             String.contains?(log.output, "hello")
           end)

    assert {:ok, killed} = ProcessRegistry.kill(registry, handle.id)
    assert killed.status == :killed

    assert {:ok, polled} = ProcessRegistry.poll(registry, handle.id)
    assert polled.status == :killed
  end

  test "emits live process lifecycle and output events" do
    {:ok, registry} = ProcessRegistry.start_link()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)
    workspace = Workspace.new!(root: tmp_dir())
    policy = CommandPolicy.new!(allowed_commands: ["cat"])

    assert {:ok, handle} =
             ProcessRegistry.start_process(registry, workspace, %{argv: ["cat"]},
               policy: policy,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert :ok = ProcessRegistry.write(registry, handle.id, "hello\n")

    assert eventually(fn ->
             Elixir.Agent.get(events, fn emitted ->
               Enum.any?(
                 emitted,
                 &(&1.kind == :coding_process_output and
                     String.contains?(&1.output.output_preview, "hello"))
               )
             end)
           end)

    assert {:ok, _killed} = ProcessRegistry.kill(registry, handle.id)

    assert eventually(fn ->
             Elixir.Agent.get(events, fn emitted ->
               Enum.any?(emitted, &(&1.kind == :coding_process_started)) and
                 Enum.any?(emitted, &(&1.kind == :coding_process_exited))
             end)
           end)
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
