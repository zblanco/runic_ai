defmodule RunicAI.ControlTest do
  use ExUnit.Case, async: true

  alias RunicAI.Control.{Budget, Guard, Handoff, RetryPolicy, Suspension, Trace}
  alias RunicAI.Error

  test "budget accounting is immutable, round-trippable, and rejects overruns" do
    budget = Budget.new!(%{"steps" => 2, "llm_calls" => 1})
    assert {:ok, charged} = Budget.charge(budget, %{"steps" => 1, "llm_calls" => 1})
    assert budget.used["steps"] == 0
    assert Budget.remaining(charged)["steps"] == 1
    assert {:ok, ^charged} = charged |> Budget.encode() |> Budget.decode()

    assert {:error, %Error{code: "budget_exhausted"}} =
             Budget.charge(charged, %{"llm_calls" => 1})
  end

  test "retry decisions respect attempts, error classes, and unsafe replay" do
    policy = RetryPolicy.new!(%{"max_attempts" => 3, "base_delay_ms" => 10})
    error = Error.new!(:timeout, "upstream_timeout", "timed out")
    assert {:retry, 10} = RetryPolicy.decide(policy, error, 1)

    assert {:retry, 20} =
             RetryPolicy.decide(policy, error, 2, replay: :unsafe, idempotency: "key")

    assert {:stop, :unsafe_replay} = RetryPolicy.decide(policy, error, 1, replay: :unsafe)
    assert {:stop, :attempts_exhausted} = RetryPolicy.decide(policy, error, 3)
    assert {:ok, ^policy} = policy |> RetryPolicy.encode() |> RetryPolicy.decode()
  end

  test "guards expose allow, deny, and review as distinct outcomes" do
    allow = Guard.new!(%{"id" => "policy.read", "decision" => "allow", "reason" => "safe"})
    review = Guard.new!(%{"id" => "policy.write", "decision" => "review", "reason" => "mutation"})
    deny = Guard.new!(%{"id" => "policy.secret", "decision" => "deny", "reason" => "blocked"})
    assert :ok = Guard.enforce(allow)
    assert {:review, ^review} = Guard.enforce(review)
    assert {:error, %Error{code: "guard_denied"}} = Guard.enforce(deny)
    assert {:ok, ^review} = review |> Guard.encode() |> Guard.decode()
  end

  test "suspensions validate exact resume identity and payload contracts" do
    request =
      Suspension.request!(%{
        "id" => "review-1",
        "kind" => "review",
        "reason" => "confirm write",
        "resume" => %{
          "type" => "object",
          "properties" => %{"ticket" => %{"type" => "string"}},
          "required" => ["ticket"],
          "additional_properties" => false
        }
      })

    resume =
      Suspension.resume!(%{
        "request_id" => "review-1",
        "outcome" => "approved",
        "value" => %{"ticket" => "A-1"}
      })

    assert {:ok, %{"ticket" => "A-1"}} = Suspension.resolve(request, resume)
    assert {:ok, ^request} = request |> Suspension.encode() |> Suspension.decode()
    assert {:ok, ^resume} = resume |> Suspension.encode() |> Suspension.decode()
  end

  test "handoffs and ordered trace events survive JSON round trips" do
    handoff =
      Handoff.new!(%{
        "id" => "handoff-1",
        "source" => "planner",
        "target" => "writer",
        "objective" => "draft result",
        "payload" => %{"facts" => [1, 2]}
      })

    assert {:ok, ^handoff} =
             handoff |> Handoff.encode() |> Jason.encode!() |> Jason.decode!() |> Handoff.decode()

    event =
      Trace.event!(%{
        "id" => "event-1",
        "sequence" => 0,
        "component" => "llm.generate",
        "status" => "started",
        "occurred_at" => "2026-08-15T12:00:00Z"
      })

    assert {:ok, trace} = Trace.new("run-1") |> Trace.append(event)

    assert {:ok, ^trace} =
             trace |> Trace.encode() |> Jason.encode!() |> Jason.decode!() |> Trace.decode()

    assert {:error, _issues} = Trace.append(trace, event)
  end
end
