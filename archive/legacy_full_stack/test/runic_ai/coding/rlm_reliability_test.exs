defmodule RunicAI.Coding.RLMReliabilityTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.AcceptanceContract
  alias RunicAI.Coding.RLM.Checkpoint
  alias RunicAI.Coding.RLM.ChildContract
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.CoordinationPatterns
  alias RunicAI.Coding.RLM.Coordinator
  alias RunicAI.Coding.RLM.EditOperation
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.ObjectiveEvidence
  alias RunicAI.Coding.RLM.ObjectiveJudge
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.ProgressGate
  alias RunicAI.Coding.RLM.ReliabilityFixtures
  alias RunicAI.Coding.RLM.RepairController
  alias RunicAI.Coding.RLM.VerificationGate
  alias RunicAI.Coding.RLM.WorkflowCompiler
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Persistence.ETS
  alias RunicAI.Coding.Tools
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.RLM.CodebaseEnvironment

  defmodule SemanticJudgeFallbackClient do
    @behaviour RunicAI.LLM

    @impl true
    def generate_object(_model, _prompt, _schema, _opts) do
      {:error, RunicAI.Error.provider("structured output schema rejected")}
    end

    @impl true
    def generate_text(_model, prompt, _opts) do
      cond do
        prompt =~ "Judge whether a coding implementation satisfies" ->
          {:ok,
           RunicAI.LLM.TestClient.result(
             Jason.encode!(%{
               status: "incomplete",
               summary: "history missing",
               requirement_results: [
                 %{
                   requirement_id: "transition_history",
                   status: "incomplete",
                   rationale: "No history evidence found.",
                   evidence_refs: ["lib/work_order.ex"],
                   repair_instruction: "Add transition history."
                 }
               ],
               risks: []
             })
           )}

        prompt =~ "Extract a generic semantic acceptance contract" ->
          {:ok,
           RunicAI.LLM.TestClient.result(
             Jason.encode!(%{
               requirements: [
                 %{
                   id: "transition_history",
                   kind: "behavior",
                   description: "Work orders keep transition history.",
                   required: true,
                   evidence_needed: ["source", "tests"],
                   acceptance_criteria: ["history is stored"]
                 }
               ],
               assumptions: [],
               out_of_scope: []
             })
           )}

        true ->
          {:ok, RunicAI.LLM.TestClient.result("{}")}
      end
    end

    @impl true
    def stream_text(_model, _prompt, _opts), do: {:error, :unsupported}
  end

  test "acceptance contracts fail missing source assertions instead of trusting generic success" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("FieldService POC",
        checks: [
          AcceptanceCheck.new!(:file_exists,
            id: "state-machine",
            params: %{path: "lib/state_machine.ex"}
          ),
          AcceptanceCheck.new!(:source_not_contains,
            id: "no-scaffold-test",
            params: %{path: "test/demo_test.exs", text: "greets the world"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :incomplete
    assert Enum.any?(evaluation.blocking_failures, &(&1.id == "state-machine"))
    assert Enum.any?(evaluation.blocking_failures, &(&1.id == "no-scaffold-test"))
  end

  test "child results normalize incomplete reports and prevent satisfaction without proof" do
    contract =
      ChildContract.new!(:implementer,
        required_artifacts: ["lib/field_service/work_orders.ex"],
        verification_commands: [["mix", "test"]]
      )

    child =
      ChildResult.from_agent_summary(
        %{
          status: :satisfied,
          reply: "I could not complete the implementation.",
          changed_files: [],
          verifications: []
        },
        contract
      )

    assert child.status == :partial

    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: [],
        child_results: [child]
      )

    assert scorecard.objective_status == :objective_incomplete
  end

  test "child results use the latest verification for each command after repair" do
    contract = ChildContract.new!(:verifier, verification_commands: ["project-native checks"])

    child =
      ChildResult.from_agent_summary(
        %{
          status: :satisfied,
          reply: "Repaired and verified.",
          verifications: [
            %{command: "mix test", status: :fail, exit_status: 2},
            %{command: "mix test", status: :pass, exit_status: 0},
            %{command: "mix format --check-formatted", status: :pass, exit_status: 0}
          ]
        },
        contract
      )

    assert child.status == :completed
  end

  test "execution evidence requires current project-native checks rather than source inspection" do
    child_without_checks =
      ChildResult.new!(:completed,
        id: "implement",
        changed_files: ["lib/example.ex"],
        command_statuses: []
      )

    missing =
      RunicAI.Coding.RLM.ExecutionEvidence.result(%{child_results: [child_without_checks]})

    assert missing.status == :fail
    assert missing.message =~ "without executable verification"

    child_with_checks = %{
      child_without_checks
      | command_statuses: [
          %{command: "compile_project", status: :pass},
          %{command: "run_tests", status: :pass}
        ]
    }

    passing =
      RunicAI.Coding.RLM.ExecutionEvidence.result(%{child_results: [child_with_checks]})

    assert passing.status == :pass

    child_with_failed_smoke = %{
      child_with_checks
      | command_statuses:
          child_with_checks.command_statuses ++
            [
              %{
                command: "runtime_smoke",
                argv: ["mix", "run", "-e", "Demo.Smoke.run()"],
                exit_status: 1,
                status: :fail,
                output_preview: "undefined function smoke/0"
              }
            ]
    }

    failing =
      RunicAI.Coding.RLM.ExecutionEvidence.result(%{
        child_results: [child_with_failed_smoke]
      })

    assert failing.status == :fail
    assert failing.metadata.observed.output_preview =~ "undefined function"

    repaired =
      RunicAI.Coding.RLM.ExecutionEvidence.result(%{
        child_results: [child_with_failed_smoke],
        command_results: [
          %{
            argv: ["mix", "run", "-e", "Demo.Smoke.run()"],
            command: "runtime_smoke",
            exit_status: 0,
            status: :pass,
            output_preview: "ok"
          }
        ]
      })

    assert repaired.status == :pass

    mutation_helper_failure =
      RunicAI.Coding.RLM.ExecutionEvidence.result(%{
        child_results: [
          %{
            command_statuses: [
              %{
                tool: "run_command",
                argv: ["printf", "%s\\n", "content", ">", ".formatter.exs"],
                status: :fail
              },
              %{tool: "run_tests", argv: ["mix", "test"], status: :pass}
            ]
          }
        ]
      })

    assert mutation_helper_failure.status == :pass

    normalized_rerun =
      RunicAI.Coding.RLM.ExecutionEvidence.result(%{
        child_results: [
          %{command_statuses: [%{command: "mix test", status: :fail, exit_status: 1}]}
        ],
        command_results: [%{argv: ["mix", "test"], status: :pass, exit_status: 0}]
      })

    assert normalized_rerun.status == :pass
  end

  test "seeded implementation progress cannot complete without executable verification" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    proposal =
      RunicAI.Coding.RLM.RecipeLibrary.proposal(
        :implementation,
        "Build a small library in the selected workspace"
      )

    results =
      ProgressGate.evaluate(
        workspace,
        proposal,
        %{changed_files: ["lib/example.ex"], child_results: [], command_results: []},
        []
      )

    execution = Enum.find(results, &(&1.id == "implementation-execution-verification"))
    assert execution.status == :fail
  end

  test "verification gate enforces execution evidence for mutating objective contracts" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("Build the requested library",
        metadata: %{mutation_required?: true}
      )

    assert {:ok, result} = VerificationGate.run(workspace, contract, %{})
    assert result.status == :objective_incomplete

    assert Enum.any?(
             result.scorecard.acceptance_results,
             &(&1.id == "implementation-execution-verification" and &1.status == :fail)
           )
  end

  test "edit patch sets apply typed operations and reject no-op outcomes" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    patch_set =
      EditPatchSet.new!(
        "create marker",
        [
          EditOperation.new!(:create_file,
            params: %{path: "lib/marker.ex", content: "defmodule Marker do\nend\n"}
          )
        ],
        expected_changed_files: ["lib/marker.ex"]
      )

    assert {:ok, result} = EditPatchSet.apply(workspace, patch_set)
    assert result.status == :ok
    assert result.changed_paths == ["lib/marker.ex"]

    empty_patch =
      EditPatchSet.new!("do nothing", [], expected_changed_files: ["lib/missing.ex"])

    assert {:ok, result} = EditPatchSet.apply(workspace, empty_patch)
    assert result.status == :error
    assert Enum.any?(result.diagnostics, &(&1.kind == :no_changed_paths))
  end

  test "edit patch sets reconcile a durable unknown-after-dispatch replay" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    patch_set =
      EditPatchSet.new!(
        "create durable marker",
        [
          EditOperation.new!(:create_file,
            params: %{path: "lib/durable_marker.ex", content: "defmodule DurableMarker do\nend\n"}
          )
        ],
        id: "edit:durable-marker",
        expected_changed_files: ["lib/durable_marker.ex"]
      )

    assert {:ok, first} = EditPatchSet.apply(workspace, patch_set)
    assert first.status == :ok

    path = Path.join(root, "lib/durable_marker.ex")
    mtime = File.stat!(path).mtime

    assert {:ok, replay} =
             EditPatchSet.apply(workspace, patch_set,
               replay_context: %{
                 attempt: 2,
                 prior_attempt_id: "workflow-node-attempt-1",
                 prior_outcome: :unknown_after_dispatch
               }
             )

    assert replay.status == :reconciled
    assert [%{status: :reconciled} = operation_result] = replay.operation_results
    assert operation_result.metadata.reconciliation.outcome == :matched_after_state
    assert File.stat!(path).mtime == mtime
  end

  test "verification gates emit scorecards and repair needs from failed checks" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify project",
        checks: [
          AcceptanceCheck.new!(:file_exists, id: "missing", params: %{path: "lib/missing.ex"})
        ]
      )

    assert {:ok, result} = VerificationGate.run(workspace, contract, %{})
    assert result.status == :objective_incomplete
    assert result.scorecard.objective_status == :objective_incomplete
    assert [%RunicAI.Coding.RLM.RepairNeed{}] = result.repair_needs
  end

  test "a positive verifier claim cannot override missing deterministic acceptance proof" do
    root = sample_project()
    File.write!(Path.join(root, "lib/plausible.ex"), "defmodule Plausible do\nend\n")
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("implement and prove Plausible.run/1",
        checks: [
          AcceptanceCheck.new!(:file_exists,
            id: "plausible-artifact",
            params: %{path: "lib/plausible.ex"}
          ),
          AcceptanceCheck.new!(:function_exists,
            id: "required-run-function",
            params: %{path: "lib/plausible.ex", name: "run", arity: 1}
          )
        ]
      )

    asserted_complete = %{
      status: :ok,
      verifier: :agent_report,
      summary: "The implementation is complete and the artifact looks valid."
    }

    assert {:ok, result} =
             VerificationGate.run(workspace, contract, %{
               changed_files: ["lib/plausible.ex"],
               verification_observations: [asserted_complete]
             })

    assert result.status == :objective_incomplete
    assert result.scorecard.objective_status == :objective_incomplete

    assert Enum.any?(
             result.evaluation.results,
             &(&1.id == "plausible-artifact" and &1.status == :pass)
           )

    assert Enum.any?(
             result.evaluation.results,
             &(&1.id == "required-run-function" and &1.status == :fail)
           )

    assert Enum.any?(result.repair_needs, &(&1.target == "required-run-function"))
  end

  test "verification gates defer semantic requirement checks without crashing" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify semantic requirement",
        checks: [
          AcceptanceCheck.new!(:semantic_requirement,
            id: "semantic-behavior",
            params: %{text: "implementation satisfies the requested behavior"}
          )
        ]
      )

    assert {:ok, result} = VerificationGate.run(workspace, contract, %{})
    assert result.status == :objective_satisfied
    assert [%{status: :skipped, required?: false, metadata: metadata}] = result.evaluation.results
    assert metadata.category == :semantic_requirement_deferred
  end

  test "source checks accept common model-generated text aliases" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify aliases",
        checks: [
          AcceptanceCheck.new!(:source_contains,
            id: "substring",
            params: %{path: "lib/demo.ex", substring: "def answer"}
          ),
          AcceptanceCheck.new!(:source_contains,
            id: "pattern",
            params: %{path: "lib/demo.ex", pattern: "42"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :satisfied
  end

  test "source checks can search directories and globs without assuming exact layout" do
    root = sample_project()
    workspace = Workspace.new!(root: root)
    File.mkdir_p!(Path.join(root, "lib/nested"))

    File.write!(
      Path.join(root, "lib/nested/runtime.ex"),
      "defmodule Demo.Runtime do\n  use GenServer\nend\n"
    )

    contract =
      AcceptanceContract.new!("verify layout-tolerant source assertions",
        checks: [
          AcceptanceCheck.new!(:source_contains,
            id: "directory",
            params: %{path: "lib", text: "def answer"}
          ),
          AcceptanceCheck.new!(:source_contains,
            id: "glob",
            params: %{glob: "lib/**/*.ex", text: "use GenServer"}
          ),
          AcceptanceCheck.new!(:source_not_contains,
            id: "directory-negative",
            params: %{path: "lib", text: "use Registry"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :satisfied
  end

  test "source glob checks fall back to nested generated project directories" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-rlm-nested-source-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "generated_app/lib"))

    File.write!(
      Path.join(root, "generated_app/lib/demo.ex"),
      "defmodule Demo.WorkOrder do\nend\n"
    )

    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify nested source",
        checks: [
          AcceptanceCheck.new!(:source_contains,
            id: "nested-source",
            params: %{glob: "lib/**/*.ex", text: "WorkOrder"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :satisfied
    assert [%{metadata: %{paths: ["generated_app/lib/demo.ex"]}}] = evaluation.results
  end

  test "negative source glob checks pass when no files match" do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-rlm-negative-empty-glob-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "notes/roadmap.md"), "# Roadmap\n")

    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify no code delivery",
        checks: [
          AcceptanceCheck.new!(:source_not_contains,
            id: "no-deliveryrisk-in-lib",
            params: %{glob: "lib/**/*.ex", text: "DeliveryRisk"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :satisfied
    assert [%{status: :pass, metadata: %{paths: [], file_count: 0}}] = evaluation.results
  end

  test "source globs remain confined to the workspace root" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("reject escaping source globs",
        checks: [
          AcceptanceCheck.new!(:source_contains,
            id: "escaping-glob",
            params: %{glob: "../**/*.ex", text: "defmodule"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :incomplete

    assert [%{message: message}] = evaluation.blocking_failures
    assert message =~ "cannot escape"
  end

  test "command checks use nested args and do not match unrelated commands" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify command result",
        checks: [
          AcceptanceCheck.new!(:command_passes,
            id: "test-command",
            params: %{args: %{argv: ["mix", "test"]}}
          )
        ]
      )

    context = %{
      command_results: [
        %{command: "mix new demo", argv: ["mix", "new", "demo"], status: :pass},
        %{command: "mix test", argv: ["mix", "test"], status: :fail, output: "1 failure"}
      ]
    }

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, context)
    assert evaluation.status == :incomplete
    assert [%{message: "command did not pass", metadata: metadata}] = evaluation.blocking_failures
    assert metadata.observed.argv == ["mix", "test"]
  end

  test "command checks without a concrete command fail instead of matching any observation" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("reject malformed command checks",
        checks: [
          AcceptanceCheck.new!(:command_passes, id: "missing-command", params: %{})
        ]
      )

    context = %{
      command_results: [
        %{command: "mix new demo", argv: ["mix", "new", "demo"], status: :pass}
      ]
    }

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, context)
    assert evaluation.status == :incomplete
    assert [%{message: message}] = evaluation.blocking_failures
    assert message =~ "requires command or argv"
  end

  test "command checks honor cwd and prefer the latest matching observation" do
    root = sample_project()
    File.mkdir_p!(Path.join(root, "demo"))
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify project command result",
        checks: [
          AcceptanceCheck.new!(:command_passes,
            id: "project-test-command",
            params: %{argv: ["mix", "test"], cwd: "demo"}
          )
        ]
      )

    context = %{
      command_results: [
        %{command: "mix test", argv: ["mix", "test"], cwd: root, status: :pass},
        %{
          command: "mix test",
          argv: ["mix", "test"],
          cwd: Path.join(root, "demo"),
          status: :fail
        },
        %{
          command: "mix test",
          argv: ["mix", "test"],
          cwd: Path.join(root, "demo"),
          status: :pass
        }
      ]
    }

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, context)
    assert evaluation.status == :satisfied
    assert [%{metadata: metadata}] = evaluation.results
    assert metadata.observed.cwd == Path.join(root, "demo")
  end

  test "aggregate command-output checks prefer latest matching command observations" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify latest command output",
        checks: [
          AcceptanceCheck.new!(:test_count_min,
            id: "test-count",
            params: %{min: 3}
          ),
          AcceptanceCheck.new!(:warning_count_zero, id: "warning-free")
        ]
      )

    context = %{
      command_results: [
        %{
          command: "mix test",
          argv: ["mix", "test"],
          cwd: root,
          status: :pass,
          output: "warning: deprecated option\n2 tests, 0 failures\n"
        },
        %{
          command: "mix compile --warnings-as-errors",
          argv: ["mix", "compile", "--warnings-as-errors"],
          cwd: root,
          status: :pass,
          output: ""
        },
        %{
          command: "mix test",
          argv: ["mix", "test"],
          cwd: root,
          status: :pass,
          output: "Running ExUnit\n\n....\n4 tests, 0 failures\n"
        }
      ]
    }

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, context)
    assert evaluation.status == :satisfied
    assert Enum.all?(evaluation.results, &(&1.status == :pass))
  end

  test "function_exists checks accept common name slash arity notation" do
    root = sample_project()

    File.write!(Path.join(root, "lib/event_normalizer.ex"), """
    defmodule EventNormalizer do
      def parse_event(raw), do: raw
    end
    """)

    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify function notation",
        checks: [
          AcceptanceCheck.new!(:function_exists,
            id: "parse-event",
            params: %{function: "parse_event/1"}
          )
        ]
      )

    assert {:ok, evaluation} = AcceptanceContract.evaluate(contract, workspace, %{})
    assert evaluation.status == :satisfied
    assert [%{status: :pass, metadata: metadata}] = evaluation.results
    assert metadata.function == "parse_event"
    assert metadata.arity == 1
  end

  test "changed file count checks are not treated as test count observations" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    contract =
      AcceptanceContract.new!("verify changed file count",
        checks: [
          %{
            id: "changed-file-count-min",
            type: "test_count_min",
            params: %{min: 1}
          },
          %{
            id: "changed-file-count-max",
            type: "test_count_min",
            params: %{min: 2}
          }
        ]
      )

    assert {:ok, evaluation} =
             AcceptanceContract.evaluate(contract, workspace, %{
               changed_files: ["reports/delivery_risk_report.md"]
             })

    assert evaluation.status == :satisfied
    assert Enum.all?(evaluation.results, &(&1.type == :changed_file_count_between))
    assert Enum.all?(evaluation.results, &(&1.status == :pass))
  end

  test "coordinator prompt steers generated checks toward generic acyclic workflows" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    prompt =
      Coordinator.prompt("Implement a small feature", env,
        validation_opts: [allow_mutation?: true]
      )

    assert prompt =~ "proposal graph must be acyclic"
    assert prompt =~ "directory/glob source assertions"
    assert prompt =~ "checks without argv or command"
    assert prompt =~ "Do not invent exact module names"
    assert prompt =~ "outer repair loop"
  end

  test "coordinator structured schema rejects bare string workflow nodes" do
    schema = Coordinator.schema()

    assert get_in(schema, [:nodes, :type]) == {:list, :map}
    assert get_in(schema, [:edges, :type]) == {:list, :map}
    assert get_in(schema, [:stop_conditions, :type]) == {:list, :string}
  end

  test "changed-file inventory reports hashes, language, and line counts" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    assert {:ok, inventory} =
             Tools.changed_file_inventory(workspace, %{paths: ["lib/demo.ex"]})

    assert [
             %{
               path: "lib/demo.ex",
               regular?: true,
               language: :elixir,
               line_count: line_count,
               sha256: sha256
             }
           ] = inventory.files

    assert line_count >= 3
    assert is_binary(sha256)
  end

  test "compiler executes generic edit and verification gate nodes" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Create a marker file and verify it exists",
        [
          ProposalNode.new!("edit", :edit,
            params: %{
              operations: [
                %{
                  kind: "create_file",
                  params: %{path: "lib/marker.ex", content: "defmodule Marker do\nend\n"}
                }
              ],
              expected_changed_files: ["lib/marker.ex"]
            }
          ),
          ProposalNode.new!("gate", :verification_gate,
            params: %{
              contract: %{
                objective: "marker exists",
                checks: [
                  %{id: "marker-file", type: "file_exists", params: %{path: "lib/marker.ex"}}
                ]
              }
            }
          )
        ],
        edges: [%{from: "edit", to: "gate"}],
        stop_conditions: ["scorecard produced"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_mutation?: true
               ]
             )

    assert result.output.status == :objective_satisfied

    assert [%RunicAI.Coding.RLM.WorkflowScorecard{objective_status: :objective_satisfied}] =
             result.context.scorecards
  end

  test "validator returns structured errors for invalid edit operations" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Reject invalid edit operations",
        [
          ProposalNode.new!("bad_edit", :edit,
            params: %{
              operations: [
                %{kind: "write_file", params: %{path: "lib/demo.ex", content: "invalid"}}
              ],
              expected_changed_files: ["lib/demo.ex"]
            }
          )
        ],
        edges: [],
        stop_conditions: ["structured error"]
      )

    assert {:error, error} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_mutation?: true
               ]
             )

    assert error.message == "cannot compile rejected RLM coding workflow proposal"
    assert inspect(error.details) =~ "invalid edit operation kind"
  end

  test "compiler returns structured errors for missing child workspace scopes" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Run a child in a missing workspace",
        [
          ProposalNode.new!("child", :agent,
            params: %{
              mode: "read_only",
              task: "Explain the project.",
              workspace_path: "missing_project"
            }
          )
        ],
        edges: [],
        stop_conditions: ["child attempted"]
      )

    assert {:error, error} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_mutation?: true
               ]
             )

    assert error.message == "agent workspace_path does not exist"
    assert error.details.workspace_path == "missing_project"
  end

  test "runtime budget catches orchestration exceptions as structured errors" do
    assert {:error, error} =
             RunicAI.Coding.RLM.RuntimeBudget.run(
               fn -> raise "boom" end,
               timeout_ms: 1_000,
               stage: :test_stage
             )

    assert error.kind == :unexpected
    assert error.message == "boom"
    assert error.details.stage == :test_stage
  end

  test "coordination patterns are generic and require dynamic task-specific nodes" do
    patterns = CoordinationPatterns.all()

    assert Enum.map(patterns, & &1.name) == [
             :staged_delivery,
             :parallel_decomposition,
             :verify_repair_loop,
             :review_scorecard
           ]

    assert Enum.all?(patterns, &(get_in(&1, [:metadata, :generic?]) == true))
    refute inspect(patterns) =~ "GeneratedMixProject"
    refute inspect(patterns) =~ "FieldService"
  end

  test "strict FieldService smoke is preserved as an incomplete regression fixture" do
    fixture = ReliabilityFixtures.strict_field_service_smoke()
    scorecard = ReliabilityFixtures.score_original_failure(fixture)

    assert fixture.metadata.template? == false
    assert fixture.expected_scorecard_status == :objective_incomplete
    assert scorecard.objective_status == :objective_incomplete
  end

  test "generic progress gate rejects scaffold-only projects with trivial tests" do
    root = mix_scaffold_project()
    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Create a FieldService WorkOrder GenServer with DynamicSupervisor Registry and ExUnit tests",
        [
          ProposalNode.new!("scaffold", :command, params: %{args: %{argv: ["mix", "new", "."]}}),
          ProposalNode.new!("verify", :verification_gate, params: %{checks: []})
        ],
        edges: [%{from: "scaffold", to: "verify"}],
        stop_conditions: ["verified"]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            child_results: [],
            command_results: [%{argv: ["mix", "test"], status: :pass}],
            changed_files: [],
            scorecards: [],
            repair_needs: [],
            verification_observations: [],
            risks: []
          }
        },
        validation_opts: [allow_mutation?: true]
      )

    assert [%WorkflowScorecard{objective_status: :objective_incomplete}] =
             result.context.scorecards

    assert %WorkflowScorecard{objective_status: :objective_incomplete} =
             result.objective_scorecard

    failure_ids =
      result.context.scorecards
      |> List.last()
      |> Map.fetch!(:acceptance_results)
      |> Enum.filter(&(&1.status == :fail))
      |> Enum.map(& &1.id)

    assert "progress-no-default-scaffold" in failure_ids
    assert "progress-meaningful-tests" in failure_ids
    assert "progress-implementation-activity" in failure_ids

    scaffold_failure =
      result.context.scorecards
      |> List.last()
      |> Map.fetch!(:acceptance_results)
      |> Enum.find(&(&1.id == "progress-no-default-scaffold"))

    assert Enum.any?(
             scaffold_failure.metadata.locations,
             &(&1.path == "lib/field_service_poc.ex" and &1.marker == "def hello do")
           )

    assert scaffold_failure.metadata.repair_instruction =~ "Remove or replace"
  end

  test "generic progress gate does not treat every :world atom as scaffold residue" do
    root = sample_project()
    File.rm!(Path.join(root, "test/demo_test.exs"))

    File.write!(Path.join(root, "lib/world_router.ex"), """
    defmodule WorldRouter do
      def route(:world), do: {:ok, :dispatch_dashboard}
      def route(other), do: {:error, other}
    end
    """)

    File.write!(Path.join(root, "test/world_router_test.exs"), """
    defmodule WorldRouterTest do
      use ExUnit.Case

      test "routes world dashboard requests" do
        assert WorldRouter.route(:world) == {:ok, :dispatch_dashboard}
      end
    end
    """)

    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Add a world dashboard route with ExUnit tests",
        [ProposalNode.new!("edit", :edit, params: %{operations: []})],
        stop_conditions: ["implemented"]
      )

    results =
      ProgressGate.evaluate(workspace, proposal, %{
        changed_files: ["lib/world_router.ex", "test/world_router_test.exs"]
      })

    scaffold_result = Enum.find(results, &(&1.id == "progress-no-default-scaffold"))

    assert scaffold_result.status == :pass
  end

  test "generic progress gate accepts objective-specific implementation evidence" do
    root = sample_project()
    File.rm!(Path.join(root, "test/demo_test.exs"))

    File.write!(Path.join(root, "lib/field_service.ex"), """
    defmodule FieldService.WorkOrder do
      use GenServer
      def supervisor, do: DynamicSupervisor
      def registry, do: Registry
    end
    """)

    File.write!(Path.join(root, "test/field_service_test.exs"), """
    defmodule FieldServiceTest do
      use ExUnit.Case
      test "WorkOrder uses DynamicSupervisor and Registry" do
        assert FieldService.WorkOrder.supervisor() == DynamicSupervisor
        assert FieldService.WorkOrder.registry() == Registry
      end
    end
    """)

    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Create a FieldService WorkOrder GenServer with DynamicSupervisor Registry and ExUnit tests",
        [ProposalNode.new!("edit", :edit, params: %{operations: []})],
        stop_conditions: ["implemented"]
      )

    results =
      ProgressGate.evaluate(workspace, proposal, %{changed_files: ["lib/field_service.ex"]})

    refute Enum.any?(results, &(&1.status == :fail))
  end

  test "generic progress gate rejects accidental scratch-root delivery" do
    root = sample_project()
    File.mkdir_p!(Path.join(root, "tmp/lib"))
    File.mkdir_p!(Path.join(root, "tmp/test"))

    File.write!(Path.join(root, "tmp/lib/support_ticket_triage.ex"), """
    defmodule SupportTicketTriage do
      def classify(ticket), do: %{priority: ticket.priority}
    end
    """)

    File.write!(Path.join(root, "tmp/test/support_ticket_triage_test.exs"), """
    defmodule SupportTicketTriageTest do
      use ExUnit.Case
      test "runtime smoke", do: assert SupportTicketTriage.classify(%{priority: :high})
    end
    """)

    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Create a support ticket triage Mix project with tests and a runtime smoke",
        [
          ProposalNode.new!("implement", :agent, params: %{mode: "patch"}),
          ProposalNode.new!("verify", :verification_gate, params: %{checks: []})
        ],
        edges: [%{from: "implement", to: "verify"}],
        stop_conditions: ["verified"]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            child_results: [],
            command_results: [],
            changed_files: [
              "tmp/lib/support_ticket_triage.ex",
              "tmp/test/support_ticket_triage_test.exs"
            ],
            scorecards: [],
            repair_needs: [],
            verification_observations: [],
            risks: []
          }
        },
        validation_opts: [allow_mutation?: true]
      )

    delivery_failure =
      Enum.find(
        result.objective_scorecard.acceptance_results,
        &(&1.id == "progress-delivery-root")
      )

    assert delivery_failure.status == :fail
    assert delivery_failure.message =~ "scratch paths"

    assert delivery_failure.metadata.scratch_files == [
             "tmp/lib/support_ticket_triage.ex",
             "tmp/test/support_ticket_triage_test.exs"
           ]

    assert Enum.any?(result.context.repair_needs, &(&1.target == "progress-delivery-root"))
  end

  test "generic progress gate allows explicitly requested nested delivery roots" do
    root = sample_project()
    File.mkdir_p!(Path.join(root, "tmp/support_ticket_triage/lib"))
    File.mkdir_p!(Path.join(root, "tmp/support_ticket_triage/test"))

    File.write!(Path.join(root, "tmp/support_ticket_triage/lib/support_ticket_triage.ex"), """
    defmodule SupportTicketTriage do
      def classify(ticket), do: %{priority: ticket.priority}
    end
    """)

    File.write!(
      Path.join(root, "tmp/support_ticket_triage/test/support_ticket_triage_test.exs"),
      """
      defmodule SupportTicketTriageTest do
        use ExUnit.Case
        test "runtime smoke", do: assert SupportTicketTriage.classify(%{priority: :high})
      end
      """
    )

    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Create the support ticket triage Mix project in ./tmp/support_ticket_triage with tests and a runtime smoke",
        [
          ProposalNode.new!("implement", :agent,
            params: %{mode: "patch", workspace_path: "tmp/support_ticket_triage"}
          )
        ],
        stop_conditions: ["verified"]
      )

    results =
      ProgressGate.evaluate(workspace, proposal, %{
        changed_files: [
          "tmp/support_ticket_triage/lib/support_ticket_triage.ex",
          "tmp/support_ticket_triage/test/support_ticket_triage_test.exs"
        ]
      })

    delivery_result = Enum.find(results, &(&1.id == "progress-delivery-root"))

    assert delivery_result.status == :pass
    assert "tmp/support_ticket_triage" in delivery_result.metadata.allowed_delivery_roots
  end

  test "objective contracts extract semantic requirements through structured LLM output" do
    client = fn _model, prompt, _schema, _opts ->
      assert prompt =~ "Extract a generic semantic acceptance contract"
      assert prompt =~ "transition history"

      {:ok,
       %{
         "requirements" => [
           %{
             "id" => "transition_history",
             "kind" => "behavior",
             "description" => "Work orders retain transition history.",
             "required" => true,
             "evidence_needed" => ["source", "tests"],
             "acceptance_criteria" => [
               "state includes a history collection",
               "valid transitions append history entries"
             ]
           }
         ],
         "assumptions" => [],
         "out_of_scope" => []
       }}
    end

    assert {:ok, contract} =
             ObjectiveContract.extract("Build a workflow that records transition history.",
               model: "test:model",
               client: client
             )

    assert contract.objective == "Build a workflow that records transition history."
    assert [requirement] = contract.requirements
    assert requirement.id == "transition_history"
    assert requirement.kind == "behavior"
    assert requirement.evidence_needed == ["source", "tests"]

    assert requirement.acceptance_criteria == [
             "state includes a history collection",
             "valid transitions append history entries"
           ]
  end

  test "semantic schemas use strict Zoi JSON schema objects" do
    contract_schema = ObjectiveContract.schema()
    judge_schema = ObjectiveJudge.schema()

    assert contract_schema["additionalProperties"] == false

    assert get_in(contract_schema, ["properties", "requirements", "items", "additionalProperties"]) ==
             false

    assert judge_schema["additionalProperties"] == false

    assert get_in(judge_schema, [
             "properties",
             "requirement_results",
             "items",
             "additionalProperties"
           ]) == false
  end

  test "objective evidence includes workflow proposal details for semantic judging" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Coordinate implementation and verification.",
        [
          ProposalNode.new!("scaffold", :command, params: %{args: %{argv: ["mix", "new", "."]}}),
          ProposalNode.new!("implement", :agent, params: %{workspace_path: "demo"}),
          ProposalNode.new!("verify", :verification_gate,
            params: %{checks: [%{type: "command_passes", params: %{argv: ["mix", "test"]}}]}
          )
        ],
        edges: [%{from: "scaffold", to: "implement"}, %{from: "implement", to: "verify"}],
        stop_conditions: ["verified"]
      )

    evidence = ObjectiveEvidence.gather(workspace, %{proposal: proposal})

    assert get_in(evidence, [:workflow, :proposal, :nodes])
           |> Enum.map(& &1.kind) == ["command", "agent", "verification_gate"]

    assert get_in(evidence, [:workflow, :proposal, :nodes])
           |> Enum.any?(&(get_in(&1, [:params, "workspace_path"]) == "demo"))
  end

  test "objective evidence preserves explicitly changed files under requested tmp projects" do
    root = sample_project()
    File.mkdir_p!(Path.join(root, "tmp/ops_logic/lib/ops_logic"))
    File.mkdir_p!(Path.join(root, "tmp/lib"))

    File.write!(Path.join(root, "tmp/ops_logic/lib/ops_logic/work_orders.ex"), """
    defmodule OpsLogic.WorkOrders do
      def schedule, do: :ok
    end
    """)

    File.write!(Path.join(root, "tmp/lib/noise.ex"), """
    defmodule RuntimeNoise do
    end
    """)

    workspace = Workspace.new!(root: root)

    evidence =
      ObjectiveEvidence.gather(workspace, %{
        changed_files: ["tmp/ops_logic/lib/ops_logic/work_orders.ex"]
      })

    paths = Enum.map(evidence.files, & &1.path)

    assert "tmp/ops_logic/lib/ops_logic/work_orders.ex" in paths
    refute "tmp/lib/noise.ex" in paths

    assert %{content: content} =
             Enum.find(evidence.files, &(&1.path == "tmp/ops_logic/lib/ops_logic/work_orders.ex"))

    assert content =~ "OpsLogic.WorkOrders"
  end

  test "semantic progress does not require lexical term coverage when LLM judge is enabled" do
    root = sample_project()
    File.rm!(Path.join(root, "test/demo_test.exs"))

    File.write!(Path.join(root, "lib/work_order.ex"), """
    defmodule WorkOrder do
      defstruct [:id, :history]
    end
    """)

    File.write!(Path.join(root, "test/work_order_test.exs"), """
    defmodule WorkOrderTest do
      use ExUnit.Case
      test "history field exists", do: assert %WorkOrder{history: []}
    end
    """)

    workspace = Workspace.new!(root: root)

    objective =
      "You are RunicAI RLM. Codex only operates the run. Implement transition history."

    contract =
      ObjectiveContract.new!(objective,
        requirements: [
          %{
            id: "transition_history",
            kind: "behavior",
            description: "Work orders keep transition history.",
            required: true,
            evidence_needed: ["source", "tests"],
            acceptance_criteria: ["history is represented in source and tests"]
          }
        ]
      )

    judge = fn _contract, _evidence, _opts ->
      {:ok,
       %{
         status: "satisfied",
         requirement_results: [
           %{
             requirement_id: "transition_history",
             status: "satisfied",
             message: "history is represented"
           }
         ]
       }}
    end

    proposal =
      WorkflowProposal.new!(
        "Implement transition history.",
        [ProposalNode.new!("edit", :edit, params: %{operations: []})],
        stop_conditions: ["implemented"]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            child_results: [],
            command_results: [],
            changed_files: ["lib/work_order.ex", "test/work_order_test.exs"],
            scorecards: [],
            repair_needs: [],
            verification_observations: [],
            risks: [],
            metadata: %{original_objective: objective}
          }
        },
        semantic_progress?: true,
        objective_contract: contract,
        semantic_judge: judge,
        validation_opts: [allow_mutation?: true]
      )

    scorecard = List.last(result.context.scorecards)
    refute Enum.any?(scorecard.acceptance_results, &(&1.id == "progress-semantic-coverage"))
    assert scorecard.objective_status == :objective_satisfied
  end

  test "semantic judge falls back from structured object generation to JSON text" do
    contract =
      ObjectiveContract.new!("Implement transition history",
        requirements: [
          %{
            id: "transition_history",
            kind: "behavior",
            description: "Work orders keep transition history.",
            required: true,
            evidence_needed: ["source"],
            acceptance_criteria: ["history is stored"]
          }
        ]
      )

    assert {:ok, judgement} =
             ObjectiveJudge.evaluate(contract, %{files: []},
               model: "test:model",
               client: SemanticJudgeFallbackClient
             )

    assert judgement.status == :incomplete
    assert judgement.metadata.source == :llm_json_text
    assert judgement.metadata.model == "test:model"
    assert judgement.metadata.fallback? == true
    assert judgement.metadata.fallback_reason == :object_generation_failed
    assert judgement.metadata.prompt_sha256 =~ ~r/^[a-f0-9]{64}$/

    assert [%{requirement_id: "transition_history", status: :incomplete}] =
             judgement.requirement_results

    [acceptance_result] = ObjectiveJudge.acceptance_results(contract, judgement)
    assert acceptance_result.metadata.judge.source == :llm_json_text
    assert acceptance_result.metadata.judge.model == "test:model"
    assert acceptance_result.metadata.judge.prompt_sha256 == judgement.metadata.prompt_sha256
  end

  test "semantic progress extraction uses the original objective from run metadata" do
    root = sample_project()
    File.rm!(Path.join(root, "test/demo_test.exs"))
    File.write!(Path.join(root, "lib/work_order.ex"), "defmodule WorkOrder do\nend\n")

    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Implement a work order state machine.",
        [ProposalNode.new!("edit", :edit, params: %{operations: []})],
        stop_conditions: ["implemented"]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            child_results: [],
            command_results: [],
            changed_files: ["lib/work_order.ex"],
            scorecards: [],
            repair_needs: [],
            verification_observations: [],
            risks: [],
            metadata: %{
              original_objective:
                "Implement a work order state machine that keeps transition history."
            }
          }
        },
        semantic_progress?: true,
        model: "test:model",
        client: SemanticJudgeFallbackClient,
        validation_opts: [allow_mutation?: true]
      )

    assert result.context.objective_contract.objective =~ "transition history"
    scorecard = List.last(result.context.scorecards)
    assert Enum.any?(scorecard.acceptance_results, &(&1.id == "semantic:transition_history"))
  end

  test "semantic progress judge blocks incomplete requirements and creates repair needs" do
    root = sample_project()
    File.rm!(Path.join(root, "test/demo_test.exs"))

    File.write!(Path.join(root, "lib/work_order.ex"), """
    defmodule WorkOrder do
      defstruct [:id, :status]
      def complete(order), do: %{order | status: :completed}
    end
    """)

    workspace = Workspace.new!(root: root)

    objective =
      "Implement a work order state machine that timestamps transitions and keeps transition history."

    contract =
      ObjectiveContract.new!(objective,
        requirements: [
          %{
            id: "transition_history",
            kind: "behavior",
            description: "Work orders keep transition history for state changes.",
            required: true,
            evidence_needed: ["source", "tests"],
            acceptance_criteria: ["history is stored", "transitions append history entries"]
          }
        ]
      )

    judge = fn _contract, evidence, _opts ->
      source = Enum.map_join(evidence.files, "\n", & &1.content)

      status =
        if String.contains?(String.downcase(source), "history") do
          "satisfied"
        else
          "incomplete"
        end

      {:ok,
       %{
         status: status,
         summary: "semantic check completed",
         requirement_results: [
           %{
             requirement_id: "transition_history",
             status: status,
             rationale: "No source or test evidence stores transition history.",
             evidence_refs: ["lib/work_order.ex"],
             repair_instruction:
               "Add a history field, append entries during transitions, and assert it in tests."
           }
         ]
       }}
    end

    proposal =
      WorkflowProposal.new!(
        objective,
        [ProposalNode.new!("edit", :edit, params: %{operations: []})],
        stop_conditions: ["implemented"]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            child_results: [],
            command_results: [],
            changed_files: ["lib/work_order.ex"],
            scorecards: [],
            repair_needs: [],
            verification_observations: [],
            risks: []
          }
        },
        semantic_progress?: true,
        objective_contract: contract,
        semantic_judge: judge,
        validation_opts: [allow_mutation?: true]
      )

    assert result.context.objective_contract.id == contract.id
    assert [%{status: :incomplete}] = result.context.objective_judgements

    assert Enum.any?(
             hd(result.context.objective_evidence_summaries).files,
             &(&1.path == "lib/work_order.ex")
           )

    scorecard = List.last(result.context.scorecards)
    assert scorecard.objective_status == :objective_incomplete

    semantic_failure =
      Enum.find(scorecard.acceptance_results, &(&1.id == "semantic:transition_history"))

    assert semantic_failure.status == :fail
    assert semantic_failure.metadata.repair_instruction =~ "Add a history field"

    assert Enum.any?(
             result.context.repair_needs,
             &(&1.metadata.category == :semantic_requirement_incomplete)
           )
  end

  test "repair controller ignores acceptance maps in command repairs and keeps latest argv result" do
    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: [],
        child_results: [],
        command_statuses: [
          %{id: "acceptance-command", type: :command_passes, status: :fail, required?: true},
          %{
            argv: ["mix", "test"],
            command: "mix test",
            cwd: "/workspace",
            status: :fail,
            output_preview: "wrong cwd"
          },
          %{
            argv: ["mix", "test"],
            command: "mix test",
            cwd: "/workspace/app",
            status: :pass,
            output_preview: "3 tests, 0 failures"
          },
          %{
            argv: ["mix", "compile", "--warnings-as-errors"],
            command: "mix compile --warnings-as-errors",
            cwd: "/workspace/app",
            status: :fail,
            output_preview: "warning: clauses with the same name and arity"
          }
        ]
      )

    repairs = RepairController.from_scorecard(scorecard, [])

    assert Enum.map(repairs, & &1.reason) == [
             "command fail: mix compile --warnings-as-errors"
           ]

    assert hd(repairs).metadata.output_preview =~ "warning: clauses"
  end

  test "RLM checkpoints persist through the coding persistence behaviour" do
    {:ok, store} = ETS.start_link()

    assert {:ok, ref} =
             Checkpoint.record({ETS, store}, :node_completed, %{node_id: "edit", status: :ok},
               run_id: "run-1",
               node_id: "edit"
             )

    assert {:ok, %{kind: :rlm_coding_checkpoint, stage: :node_completed}} =
             Persistence.get_artifact({ETS, store}, ref)

    assert [
             %{
               kind: :rlm_coding_checkpoint,
               stage: :node_completed,
               node_id: "edit",
               artifact_ref: ^ref
             }
           ] = ETS.events(store)
  end

  defp sample_project do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-rlm-reliability-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def answer, do: 42\nend\n")
    File.write!(Path.join(root, "test/demo_test.exs"), "test \"greets the world\", do: :ok\n")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp mix_scaffold_project do
    root =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-rlm-scaffold-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "lib/field_service_poc.ex"), """
    defmodule FieldServicePoc do
      @moduledoc "Documentation for `FieldServicePoc`."
      @doc "Hello world."
      def hello do
        :world
      end
    end
    """)

    File.write!(Path.join(root, "test/field_service_poc_test.exs"), """
    defmodule FieldServicePocTest do
      use ExUnit.Case
      test "greets the world" do
        assert FieldServicePoc.hello() == :world
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
