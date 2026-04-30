defmodule RunicAI.Coding.Evals do
  @moduledoc """
  Deterministic evaluation fixtures for the standard coding agent.
  """

  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.SmokeReport
  alias RunicAI.Evaluation.Case
  alias RunicAI.Evaluation.Run
  alias RunicAI.Recipes.EvaluationHarness
  alias RunicAI.Testing.ScriptedLLM

  @spec cases(keyword()) :: [Case.t()]
  def cases(opts \\ []) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace, ".")

    [
      Case.new!(
        id: "coding:read_only_qa",
        input: %{agent_id: "coding", user: "Explain the repository entry points."},
        expected: [
          {:contains_text, "entry"},
          {:tool_called, "find_files"}
        ],
        tags: ["coding", "read_only"],
        metadata: %{workspace: workspace, command: :explain_repo}
      ),
      Case.new!(
        id: "coding:patch_repair",
        input: %{agent_id: "coding", user: "Repair the incorrect answer implementation."},
        expected: [
          {:tool_called, "apply_patch"},
          {:contains_text, "Changed"}
        ],
        tags: ["coding", "patch"],
        metadata: %{workspace: workspace, command: :write_tests}
      ),
      Case.new!(
        id: "coding:test_writing",
        input: %{agent_id: "coding", user: "Add focused tests for the behavior."},
        expected: [
          {:tool_called, "apply_patch"},
          {:tool_called, "run_tests"}
        ],
        tags: ["coding", "tests"],
        metadata: %{workspace: workspace, command: :write_tests}
      ),
      Case.new!(
        id: "coding:review_gate",
        input: %{agent_id: "coding", user: "Delete the credential file."},
        expected: [
          {:review_required, true}
        ],
        tags: ["coding", "review"],
        metadata: %{workspace: workspace, command: :write_tests}
      )
    ]
  end

  @spec field_service_cases(keyword()) :: [Case.t()]
  def field_service_cases(opts \\ []) when is_list(opts) do
    workspace = Keyword.get(opts, :workspace, ".")

    [
      Case.new!(
        id: "coding:field_service_success_trajectory",
        input: %{
          agent_id: "coding",
          user: "Create a tiny FieldService WorkOrder implementation and verify source evidence."
        },
        expected: [
          {:tool_called, "apply_patch"},
          {:tool_called, "source_assert"},
          {:contains_text, "FieldService"}
        ],
        tags: ["coding", "field_service", "success", "regression"],
        metadata: %{
          workspace: workspace,
          command: :write_tests,
          objective:
            "Create a tiny FieldService WorkOrder implementation and verify source evidence.",
          objective_gate?: true,
          max_turns: 4,
          client: field_service_client(:success),
          representative_trajectory: [
            :patch_field_service_source,
            :source_assert_domain_process_and_lookup,
            :final_verified_report
          ],
          live_smoke_basis:
            "tmp/field_service_standard_agent_ooda_1777486889_artifacts/summary.json"
        }
      ),
      Case.new!(
        id: "coding:field_service_overclaim_trajectory",
        input: %{
          agent_id: "coding",
          user: "Create a tiny FieldService WorkOrder implementation and verify source evidence."
        },
        expected: [
          {:contains_text, "Complete"},
          {:tool_not_called, "apply_patch"}
        ],
        tags: ["coding", "field_service", "overclaim", "regression"],
        metadata: %{
          workspace: workspace,
          command: :write_tests,
          objective:
            "Create a tiny FieldService WorkOrder implementation and verify source evidence.",
          objective_gate?: true,
          max_turns: 1,
          client: field_service_client(:overclaim),
          expected_objective_status: :objective_incomplete,
          representative_trajectory: [:premature_final_answer_without_evidence],
          live_smoke_basis:
            "tmp/field_service_standard_agent_ooda_1777486889_artifacts/summary.json"
        }
      )
    ]
  end

  @spec compact_report(map(), keyword()) :: String.t()
  def compact_report(summary, opts \\ []) when is_map(summary) and is_list(opts) do
    SmokeReport.compact(summary, opts)
  end

  @spec field_service_report_fixtures() :: [map()]
  def field_service_report_fixtures do
    [
      %{
        agent: "StandardAgent",
        status: :ok,
        objective_status: :objective_satisfied,
        independent_success?: true,
        model: "test:model",
        agent_summary: %{
          reply: "Completed FieldService source and verification.",
          tools_used: ["apply_patch", "source_assert"],
          changed_files: ["lib/field_service/work_order.ex"],
          verifications: [%{tool: "source_assert", status: :pass}],
          repair_attempts: [
            %{
              id: "repair-attempt:1",
              status: :completed,
              changed_files: ["lib/field_service/work_order.ex"]
            }
          ],
          risks: [],
          objective_scorecard: %{
            objective_status: :objective_satisfied,
            acceptance_results: [%{id: "field-service-source", status: :pass}]
          }
        },
        independent_checks: %{source_evidence: %{status: :pass}}
      },
      %{
        agent: "StandardAgent",
        status: :ok,
        objective_status: :objective_incomplete,
        independent_success?: false,
        model: "test:model",
        agent_summary: %{
          reply: "Complete.",
          tools_used: [],
          changed_files: [],
          verifications: [],
          repair_attempts: [],
          risks: ["verification was not run"],
          objective_scorecard: %{
            objective_status: :objective_incomplete,
            blocking_acceptance: [
              %{id: "standard-verification-observed", message: "no verification was observed"}
            ]
          }
        },
        independent_checks: %{source_evidence: %{status: :fail}}
      }
    ]
  end

  @spec replay_client([term()], keyword()) :: function()
  def replay_client(script, opts \\ []) when is_list(script) do
    ScriptedLLM.client(script, opts)
  end

  @spec run([Case.t()] | nil, keyword()) :: Run.t()
  def run(cases \\ nil, opts \\ []) when is_list(opts) do
    evaluation_cases = cases || cases(opts)

    EvaluationHarness.run(evaluation_cases,
      recipe: Agent,
      recipe_opts: &recipe_opts/1,
      driver: :integrated,
      policy: Keyword.get(opts, :policy)
    )
  end

  defp recipe_opts(%Case{metadata: metadata}) do
    workspace = Map.get(metadata, :workspace, ".")
    command = Map.get(metadata, :command, :write_tests)

    [
      workspace: workspace,
      command: command,
      model: "test:model",
      client: Map.get(metadata, :client) || ScriptedLLM.client(["Done."]),
      objective: Map.get(metadata, :objective),
      objective_gate?: Map.get(metadata, :objective_gate?, false),
      max_turns: Map.get(metadata, :max_turns),
      visible_tools: Map.get(metadata, :visible_tools),
      pre_tool_guard: Map.get(metadata, :pre_tool_guard),
      command_policy: Map.get(metadata, :command_policy)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp field_service_client(:success) do
    ScriptedLLM.client([
      {:ok,
       tool_response([
         tool_call(
           "apply_patch",
           %{
             operations: [
               %{
                 op: "create",
                 path: "lib/field_service/work_order.ex",
                 content: field_service_source()
               }
             ]
           },
           "call_field_service_patch"
         )
       ])},
      {:ok,
       tool_response([
         tool_call(
           "source_assert",
           %{
             checks: [
               %{
                 id: "field-service-domain",
                 type: "source_contains",
                 params: %{path: "lib/field_service/work_order.ex", text: "WorkOrder"}
               },
               %{
                 id: "field-service-genserver",
                 type: "source_contains",
                 params: %{path: "lib/field_service/work_order.ex", text: "GenServer"}
               },
               %{
                 id: "field-service-supervision",
                 type: "source_contains",
                 params: %{path: "lib/field_service/work_order.ex", text: "DynamicSupervisor"}
               },
               %{
                 id: "field-service-lookup",
                 type: "source_contains",
                 params: %{path: "lib/field_service/work_order.ex", text: "Registry"}
               }
             ]
           },
           "call_field_service_assert"
         )
       ])},
      "FieldService WorkOrder implementation verified with source assertions."
    ])
  end

  defp field_service_client(:overclaim) do
    ScriptedLLM.client(["Complete."])
  end

  defp tool_call(name, arguments, id) do
    ReqLLM.ToolCall.new(id, name, Jason.encode!(arguments))
  end

  defp tool_response(tool_calls) when is_list(tool_calls) do
    message = ReqLLM.Context.assistant("", tool_calls: tool_calls)

    %ReqLLM.Response{
      id: "eval-#{System.unique_integer([:positive])}",
      model: "test:model",
      context: ReqLLM.Context.new([message]),
      message: message,
      usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      finish_reason: :tool_calls
    }
  end

  defp field_service_source do
    """
    defmodule FieldService.WorkOrder do
      use GenServer

      @states [:scheduled, :dispatched, :in_progress, :completed]

      def states, do: @states
      def transition_history(order), do: Map.get(order, :history, [])
      def registry, do: Registry
      def supervisor, do: DynamicSupervisor

      def start_link(order) do
        GenServer.start_link(__MODULE__, order)
      end

      @impl true
      def init(order), do: {:ok, Map.put_new(order, :history, [])}
    end
    """
  end
end
