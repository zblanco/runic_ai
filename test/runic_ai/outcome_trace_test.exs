defmodule RunicAI.OutcomeTraceTest do
  use ExUnit.Case, async: true

  alias RunicAI.Control.Trace
  alias RunicAI.Outcome

  test "terminal outcomes cannot be overwritten by later progress" do
    progress = Outcome.new!(%{"kind" => "progress", "value" => %{"percent" => 50}})
    completed = Outcome.new!(%{"kind" => "completed", "value" => %{"answer" => 42}})
    late = Outcome.new!(%{"kind" => "progress", "value" => %{"percent" => 90}})

    assert Outcome.select([progress, completed, late]) == completed
    assert {:ok, ^completed} = completed |> Outcome.encode() |> Outcome.decode()
  end

  test "trace sinks are supplied entirely by the host" do
    event =
      Trace.event!(%{
        "id" => "event-1",
        "sequence" => 0,
        "component" => "tool.execute",
        "status" => "succeeded",
        "occurred_at" => "2026-08-15T12:00:00Z"
      })

    assert :ok = RunicAI.TraceSink.emit(nil, event, %{})

    assert {:ok, "run-1"} =
             RunicAI.TraceSink.emit(
               fn _received, context -> {:ok, context["run_id"]} end,
               event,
               %{"run_id" => "run-1"}
             )
  end
end
