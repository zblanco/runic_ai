defmodule RunicAI.Tool.CallPlanBatchTest do
  use ExUnit.Case, async: true

  alias RunicAI.Tool.Batch
  alias RunicAI.Tool.Binding
  alias RunicAI.Tool.Call
  alias RunicAI.Tool.CallPlan
  alias RunicAI.Tool.Result
  alias RunicAI.Tool.SpecTest

  test "call plans preserve every dependency and expose executable layers" do
    plan =
      CallPlan.new!([
        %{id: "a", tool: "test.echo", arguments: %{text: "a"}},
        %{id: "b", tool: "test.echo", arguments: %{text: "b"}},
        %{id: "c", tool: "test.echo", arguments: %{text: "c"}, dependencies: ["a", "b"]}
      ])

    assert [[%Call{id: "a"}, %Call{id: "b"}], [%Call{id: "c", dependencies: ["a", "b"]}]] =
             CallPlan.layers(plan)

    assert {:ok, ^plan} =
             plan |> CallPlan.encode() |> Jason.encode!() |> Jason.decode!() |> CallPlan.decode()
  end

  test "native Runic map/reduce executes and collects an independent batch" do
    calls = [
      Call.new!(%{id: "a", tool: "test.echo", arguments: %{text: "a"}}),
      Call.new!(%{id: "b", tool: "test.echo", arguments: %{text: "b"}})
    ]

    binding =
      Binding.new!(SpecTest.spec(), fn arguments, _context ->
        {:ok, %{"echo" => arguments["text"]}}
      end)

    resolver = fn "test.echo", _context -> binding end

    assert results = Batch.execute(calls, resolver)
    assert Enum.sort(Enum.map(results, fn {:ok, %Result{call_id: id}} -> id end)) == ["a", "b"]
  end

  test "rejects unknown dependencies and cycles" do
    assert {:error, [%{path: ["calls", "a", "dependencies"]}]} =
             CallPlan.new([%{id: "a", tool: "test.echo", dependencies: ["missing"]}])

    assert {:error, [%{path: ["calls"], message: message}]} =
             CallPlan.new([
               %{id: "a", tool: "test.echo", dependencies: ["b"]},
               %{id: "b", tool: "test.echo", dependencies: ["a"]}
             ])

    assert message =~ "cycle"
  end
end
