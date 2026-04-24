defmodule RunicAI.Tool.Adapters.ExecutionAdapterTest do
  use ExUnit.Case, async: false

  require Runic

  alias Runic.Workflow
  alias RunicAI.Tool.Adapters.Command
  alias RunicAI.Tool.Adapters.ExternalWorker
  alias RunicAI.Tool.Adapters.RunnerWorkflow
  alias RunicAI.Tool.ExecutionAdapter

  test "command adapter executes a fixed command without a shell" do
    executor = ExecutionAdapter.to_executor(Command, command: "printf", args: ["hello"])

    assert {:ok, %{output: "hello", exit_status: 0}} = executor.(%{})
  end

  test "external worker adapter normalizes callback results" do
    assert {:ok, %{accepted: true}} =
             ExternalWorker.execute(%{job: "a"},
               callback: fn args -> %{accepted: args.job == "a"} end
             )
  end

  test "runner workflow adapter invokes a child workflow as a tool capability" do
    workflow =
      Workflow.new(name: :double_child)
      |> Workflow.add(Runic.step(fn %{value: value} -> value * 2 end, name: :double))

    assert {:ok, 8} =
             RunnerWorkflow.execute(%{value: 4},
               workflow: workflow,
               component: :double,
               workflow_id: {:adapter_test, System.unique_integer([:positive])}
             )
  end
end
