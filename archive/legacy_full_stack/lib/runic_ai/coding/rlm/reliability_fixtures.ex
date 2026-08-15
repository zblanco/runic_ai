defmodule RunicAI.Coding.RLM.ReliabilityFixtures do
  @moduledoc """
  Deterministic reliability fixtures derived from live RLM coding smokes.

  Fixtures preserve observed failures as benchmark targets. They do not provide
  workflow templates or task-specific shortcuts to the coordinator.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.AcceptanceContract
  alias RunicAI.Coding.RLM.WorkflowScorecard

  @strict_field_service_artifact "tmp/field_service_rlm_agent_owned_artifacts/strict_rlm_owned_build.json"

  @spec strict_field_service_smoke() :: map()
  def strict_field_service_smoke do
    contract =
      AcceptanceContract.draft(
        "Create an Elixir FieldService proof of concept with a state machine, dynamically supervised WorkOrder processes, meaningful tests, warnings-free compilation, and runtime smoke verification.",
        required_files: [
          "lib/field_service_rlm_agent_owned/application.ex",
          "lib/field_service_rlm_agent_owned/work_orders.ex",
          "lib/field_service_rlm_agent_owned/work_orders/work_order_server.ex",
          "lib/field_service_rlm_agent_owned/work_orders/work_order_state_machine.ex"
        ],
        source_contains: [
          %{path: "lib/field_service_rlm_agent_owned/application.ex", text: "Registry"},
          %{path: "lib/field_service_rlm_agent_owned/application.ex", text: "DynamicSupervisor"}
        ],
        source_not_contains: [
          %{path: "test/field_service_rlm_agent_owned_test.exs", text: "greets the world"}
        ],
        required_commands: [
          ["mix", "compile", "--warnings-as-errors"],
          ["mix", "test"]
        ],
        checks: [
          AcceptanceCheck.new!(:test_count_min, id: "meaningful-tests", params: %{min: 4})
        ],
        metadata: %{fixture: :strict_field_service_smoke}
      )

    %{
      id: "rlm_reliability:strict_field_service_smoke",
      artifact_path: @strict_field_service_artifact,
      contract: contract,
      observed_failures: [
        :scaffold_test_pass,
        :missing_supervision_wiring,
        :compiler_warning_failure,
        :incomplete_child_report,
        :weak_parent_success_semantics
      ],
      expected_scorecard_status: :objective_incomplete,
      metadata: %{template?: false, generic_regression_fixture?: true}
    }
  end

  @spec cases() :: [map()]
  def cases, do: [strict_field_service_smoke()]

  @spec score_original_failure(map()) :: WorkflowScorecard.t()
  def score_original_failure(fixture \\ strict_field_service_smoke()) do
    WorkflowScorecard.new!(
      acceptance_results: [
        AcceptanceCheck.result(
          AcceptanceCheck.new!(:source_contains,
            id: "application-supervision",
            params: %{path: "lib/application.ex", text: "DynamicSupervisor"}
          ),
          :fail,
          "application supervision wiring was missing"
        )
      ],
      child_results: [
        %{
          id: "implement_and_verify",
          status: :partial,
          role: :implementer,
          changed_files: [],
          file_hashes: %{},
          commands: [],
          command_statuses: [],
          checks_attempted: [],
          unresolved_risks: ["child reported incomplete work"],
          summary: "child reported inability to complete",
          confidence: nil,
          metadata: %{}
        }
      ],
      metadata: %{fixture_id: fixture.id}
    )
  end
end
