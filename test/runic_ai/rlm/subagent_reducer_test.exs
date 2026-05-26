defmodule RunicAI.RLM.SubagentReducerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Decomposition.Result
  alias RunicAI.RLM.SubagentReducer

  test "accepts supported agreeing claims and records confidence metadata" do
    results = [
      Result.completed!("slice:a", %{
        claims: [
          %{
            id: "a1",
            claim: "Parser validates required fields",
            evidence_refs: ["lib/parser.ex:12"],
            confidence: 0.8
          }
        ]
      }),
      Result.completed!("slice:b", %{
        claims: [
          %{
            id: "b1",
            claim: "parser validates required fields",
            evidence_refs: ["test/parser_test.exs:9"],
            confidence: 0.9
          }
        ]
      })
    ]

    assert {:ok, reduced} = SubagentReducer.reduce(results)

    assert reduced.status == :accepted
    assert reduced.claim_count == 2
    assert [%{count: 2, task_ids: ["slice:a", "slice:b"]}] = reduced.agreements
    assert reduced.conflicts == []
    assert reduced.unsupported_claims == []
    assert reduced.missing_info_claims == []
    assert_in_delta reduced.confidence.average, 0.85, 0.001
  end

  test "flags explicit conflicts unsupported claims and missing information for review" do
    results = [
      %{
        task_id: "slice:a",
        status: :completed,
        output: %{
          claims: [
            %{
              id: "a1",
              claim: "The API is synchronous",
              evidence_refs: ["lib/api.ex:4"],
              confidence: 0.7,
              conflicts_with: ["b1"]
            },
            %{
              id: "a2",
              claim: "There may be an undocumented retry path",
              missing_info?: true,
              evidence_refs: ["lib/retry.ex:22"],
              confidence: 0.5,
              reviewer_notes: ["needs runtime trace"]
            }
          ]
        },
        metadata: %{role: "api reviewer", context_slice_id: "slice:a"}
      },
      %{
        task_id: "slice:b",
        status: :completed,
        output: %{
          claims: [
            %{
              id: "b1",
              claim: "The API is asynchronous",
              evidence_refs: ["lib/api.ex:20"],
              confidence: "0.75"
            },
            %{id: "b2", claim: "The API uses retries", confidence: 0.6}
          ]
        },
        metadata: %{role: "runtime reviewer", context_slice_id: "slice:b"}
      }
    ]

    assert {:ok, reduced} = SubagentReducer.reduce(results)

    assert reduced.status == :review
    assert [%{claim_id: "a1", target_claim_id: "b1"}] = reduced.conflicts
    assert Enum.map(reduced.unsupported_claims, & &1.id) == ["b2"]
    assert Enum.map(reduced.missing_info_claims, & &1.id) == ["a2"]

    a1 = Enum.find(reduced.claims, &(&1.id == "a1"))
    assert a1.role == "api reviewer"
    assert a1.source_slice_id == "slice:a"

    a2 = Enum.find(reduced.claims, &(&1.id == "a2"))
    assert a2.reviewer_notes == ["needs runtime trace"]

    assert reduced.summary == %{
             status: :review,
             claim_count: 4,
             agreement_count: 0,
             conflict_count: 1,
             unsupported_count: 1,
             missing_info_count: 1,
             incomplete_count: 0
           }
  end

  test "tracks incomplete and failed child results separately from claim review" do
    results = [
      Result.completed!("slice:a", %{
        claims: [%{claim: "Supported claim", evidence_refs: ["a.md:1"], confidence: 0.9}]
      }),
      Result.cancelled!("slice:b", metadata: %{reason: "cancelled by parent budget"}),
      Result.failed!("slice:c", :boom)
    ]

    assert {:ok, reduced} = SubagentReducer.reduce(results)

    assert reduced.status == :failed
    assert Enum.map(reduced.incomplete_results, & &1.task_id) == ["slice:b", "slice:c"]
    assert Enum.map(reduced.incomplete_results, & &1.status) == [:cancelled, :failed]
    assert reduced.summary.incomplete_count == 2
  end

  test "rejects invalid child result shapes" do
    assert {:error, error} =
             SubagentReducer.reduce([%{status: :completed, output: %{claims: []}}])

    assert error.kind == :validation
    assert error.message =~ "task_id"
  end
end
