defmodule RunicAI.Control.RecoveryTest do
  use ExUnit.Case, async: true

  alias RunicAI.Control.Recovery

  test "honors predicates declared on retry and fallback policies" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    primary = fn ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)
      {:ok, {:primary, attempt}}
    end

    assert {:ok, :fallback} =
             Recovery.run(primary,
               retry_policy: [
                 max_attempts: 2,
                 backoff: 0,
                 retry_if: &match?({:ok, {:primary, _}}, &1)
               ],
               fallback_policy: [
                 alternates: [fn -> {:ok, :fallback} end],
                 fallback_if: &match?({:ok, {:primary, _}}, &1)
               ]
             )

    assert Agent.get(attempts, & &1) == 2
  end
end
