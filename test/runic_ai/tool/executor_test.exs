defmodule RunicAI.Tool.ExecutorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error
  alias RunicAI.Tool.Binding
  alias RunicAI.Tool.Call
  alias RunicAI.Tool.Executor
  alias RunicAI.Tool.Observation
  alias RunicAI.Tool.Result
  alias RunicAI.Tool.SpecTest

  test "validates arguments and outputs around an approved binding" do
    call = Call.new!(%{id: "call-1", tool: "test.echo", arguments: %{text: "hello"}})

    binding =
      Binding.new!(SpecTest.spec(), fn arguments, _context ->
        {:ok, %{"echo" => arguments["text"]}}
      end)

    assert {:ok, %Result{status: :ok, output: %{"echo" => "hello"}} = result} =
             Executor.execute(call, binding, %{})

    observation = Observation.message(result)
    assert observation.role == :tool
    assert observation.name == "test.echo"
  end

  test "missing and denied bindings are distinct" do
    call = Call.new!(%{id: "call-1", tool: "test.echo", arguments: %{text: "hello"}})

    assert {:error, %Error{code: "missing_tool_binding"}} = Executor.execute(call, nil, %{})

    denied =
      Binding.new!(SpecTest.spec(), fn _arguments, _context -> {:ok, %{"echo" => "never"}} end,
        authorize: fn _call, _context -> false end
      )

    assert {:error, %Error{code: "tool_binding_denied"}} = Executor.execute(call, denied, %{})
  end

  test "output contract failures remain visible" do
    call = Call.new!(%{id: "call-1", tool: "test.echo", arguments: %{text: "hello"}})
    binding = Binding.new!(SpecTest.spec(), fn _arguments, _context -> {:ok, %{"echo" => 42}} end)

    assert {:error, %Error{code: "invalid_tool_output", details: %{"issues" => issues}}} =
             Executor.execute(call, binding, %{})

    assert Enum.any?(issues, &(&1["path"] == ["echo"]))
  end
end
