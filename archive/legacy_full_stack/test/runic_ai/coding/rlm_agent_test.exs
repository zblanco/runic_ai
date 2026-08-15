defmodule RunicAI.Coding.RLMAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.Coordinator
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.Finding
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.PlanPatchValidator
  alias RunicAI.Coding.RLM.ProgressGate
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.Reducers
  alias RunicAI.Coding.RLM.RecipeLibrary
  alias RunicAI.Coding.RLM.RepairLoop
  alias RunicAI.Coding.RLM.WorkflowCompiler
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Coding.Review
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Error
  alias RunicAI.LLM.TestClient
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.PlanPatch
  alias RunicAI.ReviewRequest

  defmodule ObjectFallbackClient do
    @behaviour RunicAI.LLM

    @impl true
    def generate_object(_model, _prompt, _schema, _opts) do
      {:error, RunicAI.Error.provider("structured output schema rejected")}
    end

    @impl true
    def generate_text(_model, _prompt, _opts) do
      proposal = %{
        objective: "fallback proposal",
        nodes: [
          %{id: "discover", kind: "tool", params: %{tool: "find_files", args: %{path: "."}}},
          %{id: "answer", kind: "reducer", params: %{reducer: "report"}}
        ],
        edges: [%{from: "discover", to: "answer"}],
        stop_conditions: ["answer returned"]
      }

      {:ok, RunicAI.LLM.TestClient.result(Jason.encode!(proposal))}
    end

    @impl true
    def stream_text(_model, _prompt, _opts), do: {:error, :unsupported}
  end

  test "proposal contracts accept valid data and reject invalid node kinds" do
    assert {:ok, node} = ProposalNode.new("inspect", :tool, params: %{tool: "find_files"})
    assert node.kind == :tool

    assert {:error, error} = ProposalNode.new("bad", "freeform_repl")
    assert error.message =~ "invalid proposal node kind"

    assert {:ok, json_node} =
             ProposalNode.from_input(
               Jason.encode!(%{
                 "id" => "json",
                 "kind" => "tool",
                 "params" => %{"tool" => "find_files"}
               })
             )

    assert json_node.id == "json"
    assert json_node.kind == :tool

    assert {:ok, json_proposal} =
             WorkflowProposal.from_input(%{
               "objective" => "Decode JSON string boundaries",
               "nodes" => [
                 Jason.encode!(%{
                   "id" => "json-node",
                   "kind" => "tool",
                   "params" => %{"tool" => "find_files"}
                 })
               ],
               "stop_conditions" => Jason.encode!(["decoded"])
             })

    assert [%ProposalNode{id: "json-node"}] = json_proposal.nodes
    assert json_proposal.stop_conditions == ["decoded"]

    assert {:error, error} = WorkflowProposal.from_input(%{"nodes" => []})
    assert error.message == "workflow proposal objective must be a non-empty string"

    assert {:error, error} = WorkflowProposal.new("Bad nodes", "not a list")
    assert error.message == "workflow proposal nodes must be a list"

    proposal =
      WorkflowProposal.new!(
        "Map proposal to RLM plan",
        [
          ProposalNode.new!("discover", :tool, params: %{tool: "find_files"}),
          ProposalNode.new!("answer", :reducer, params: %{reducer: "report"})
        ],
        edges: [%{from: "discover", to: "answer"}],
        stop_conditions: ["answer returned"]
      )

    assert {:ok, plan} = WorkflowProposal.to_plan(proposal)
    assert plan.root_node_ids == ["discover"]
    assert Enum.find(plan.nodes, &(&1.id == "answer")).parent_ids == ["discover"]
  end

  test "implementation recipe provides a generic mutating verification workflow seed" do
    proposal =
      RecipeLibrary.proposal(
        :implementation,
        "Build an Elixir proof of concept with tests and a runtime smoke"
      )

    assert proposal.metadata.recipe == :implementation
    assert proposal.metadata.seeded? == true
    assert proposal.metadata.objective_contract.metadata.mutation_required? == true

    assert Enum.map(proposal.nodes, & &1.kind) == [
             :deterministic_step,
             :agent,
             :agent,
             :verification_gate,
             :reducer
           ]

    assert Enum.map(proposal.nodes, & &1.id) == [
             "acceptance_contract",
             "implement",
             "verify_implementation",
             "verify",
             "summarize"
           ]

    contract_node = Enum.find(proposal.nodes, &(&1.id == "acceptance_contract"))
    assert contract_node.params.value.requirements != []
    assert "changed source paths" in contract_node.params.value.evidence_required

    implement_node = Enum.find(proposal.nodes, &(&1.id == "implement"))
    assert implement_node.params.mode == "patch"
    assert implement_node.params.contract.role == "implementer"
    assert implement_node.params.task =~ "Do not replace the objective with a repository summary"
    assert implement_node.params.task =~ "workspace is empty"
    assert implement_node.params.task =~ "Do not stop solely because there is no existing"
    assert implement_node.params.task =~ "source inspection alone"

    verifier_node = Enum.find(proposal.nodes, &(&1.id == "verify_implementation"))
    assert verifier_node.params.mode == "verify"
    assert verifier_node.params.contract.role == "verifier"
    assert verifier_node.params.contract.verification_commands != []
    assert verifier_node.params.task =~ "passing evidence is fresh"

    verify_node = Enum.find(proposal.nodes, &(&1.id == "verify"))
    assert verify_node.params.contract.objective =~ "Build an Elixir proof of concept"

    assert WorkflowValidationReport.accepted?(
             WorkflowValidator.validate(proposal,
               allow_mutation?: true,
               allow_commands?: true,
               allowed_commands: ["mix"],
               mode: :patch
             )
           )
  end

  test "deterministic objective contract captures project domain and evidence requirements" do
    contract =
      ObjectiveContract.infer!(
        "Build an Elixir field service dispatch proof of concept with tests and a runtime smoke"
      )

    assert contract.metadata.source == :deterministic_intent
    assert contract.metadata.domain == :generic
    assert contract.metadata.required_capabilities == ["coding", "patch", "verification"]

    assert contract.metadata.evidence_required == [
             "changed_files",
             "source",
             "tests",
             "command_result"
           ]

    requirement_ids = Enum.map(contract.requirements, & &1.id)
    assert "implementation_artifacts" in requirement_ids
    assert "requested_behavior" in requirement_ids
    assert "runtime_smoke" in requirement_ids
  end

  test "deterministic objective contract does not classify one-off domains" do
    contract =
      ObjectiveContract.infer!(
        "Build an Elixir event-sourced work order audit module that records events, rebuilds state, validates command transitions, and exports an audit report."
      )

    assert contract.metadata.domain == :generic

    requirement_ids = Enum.map(contract.requirements, & &1.id)
    assert "implementation_artifacts" in requirement_ids
    assert "requested_behavior" in requirement_ids
    refute "append_only_events" in requirement_ids
  end

  test "coordinator uses the generic implementation seed by default for mutating build objectives" do
    root = sample_project()
    environment = Agent.prepare!(root)

    assert {:ok, proposal, report} =
             Coordinator.propose(
               "Build an Elixir field service dispatch proof of concept with tests and a runtime smoke",
               environment,
               mode: :patch
             )

    assert proposal.metadata.recipe == :implementation
    assert WorkflowValidationReport.accepted?(report)
    assert Enum.any?(proposal.nodes, &(&1.id == "implement" and &1.kind == :agent))

    assert Enum.any?(
             proposal.nodes,
             &(&1.id == "verify" and &1.kind == :verification_gate)
           )
  end

  test "coordinator allows explicit dynamic planning instead of the generic implementation seed" do
    root = sample_project()
    environment = Agent.prepare!(root)

    proposal_json =
      Jason.encode!(%{
        "objective" => "Build a novel library",
        "nodes" => [
          %{
            "id" => "implement",
            "kind" => "agent",
            "params" => %{"mode" => "patch", "task" => "Implement the requested library."}
          }
        ],
        "stop_conditions" => ["implementation child completes"]
      })

    client = fn _model, _prompt, _opts -> {:ok, TestClient.result(proposal_json)} end

    assert {:ok, proposal, report} =
             Coordinator.propose("Build a novel library", environment,
               mode: :patch,
               seed_implementation?: false,
               client: client
             )

    refute proposal.metadata[:seeded?]
    assert WorkflowValidationReport.accepted?(report)
  end

  test "coding patch capability prompt does not advertise unavailable command nodes" do
    root = sample_project()
    environment = Agent.prepare!(root)
    caller = self()

    proposal_json =
      Jason.encode!(%{
        "objective" => "Change the library behavior",
        "nodes" => [
          %{
            "id" => "implement",
            "kind" => "agent",
            "params" => %{"mode" => "patch", "task" => "Apply the behavior change."}
          }
        ],
        "stop_conditions" => ["implementation child completes"]
      })

    client = fn _model, prompt, _opts ->
      send(caller, {:coordinator_prompt, prompt})
      {:ok, TestClient.result(proposal_json)}
    end

    assert {:ok, _proposal, _report} =
             Coordinator.propose("Change the library behavior", environment,
               mode: :patch,
               profile: :coding_patch,
               seed_implementation?: false,
               client: client
             )

    assert_receive {:coordinator_prompt, prompt}
    assert prompt =~ ~s("allow_commands?":false)
    refute prompt =~ ~s("kind":"command")
  end

  test "coordinator enriches mutating child agent tasks for empty workspace creation" do
    root = sample_project()
    environment = Agent.prepare!(root)

    candidate = %{
      "objective" => "Create a small application in the selected workspace",
      "nodes" => [
        %{
          "id" => "implement",
          "kind" => "agent",
          "params" => %{"mode" => "patch", "task" => "Create the application."}
        },
        %{"id" => "summarize", "kind" => "reducer", "params" => %{"reducer" => "report"}}
      ],
      "edges" => [%{"from" => "implement", "to" => "summarize"}],
      "stop_conditions" => ["application files created"]
    }

    assert {:ok, proposal, _report} =
             Coordinator.propose(
               "Create a small application in the selected workspace",
               environment,
               proposal: candidate,
               mode: :patch,
               validation_opts: [
                 allow_mutation?: true,
                 allowed_kinds: ProposalNode.allowed_kinds()
               ]
             )

    implement = Enum.find(proposal.nodes, &(&1.id == "implement"))
    assert implement.params.task =~ "Empty-workspace handling"
    assert implement.params.task =~ "Do not stop solely because there is no existing"

    assert implement.params.task =~
             "generated project root directly at the selected workspace root"

    assert implement.params.task =~ "Do not create scratch delivery roots"
    assert implement.params.task =~ "Preserve the objective's project identity"
    assert implement.params.task =~ "runtime smoke"
  end

  test "coordinator prompt exposes generic implementation recipes without deterministic generators" do
    root = sample_project()
    environment = Agent.prepare!(root)
    objective = "Build an Elixir field service dispatch proof of concept with tests"

    default_prompt = Coordinator.prompt(objective, environment, mode: :patch)
    refute default_prompt =~ "ElixirProjectGenerator"
    assert default_prompt =~ "implementation"
  end

  test "coordinator prompt includes prior conversation history for agent handoffs" do
    root = sample_project()
    environment = Agent.prepare!(root)

    prompt =
      Coordinator.prompt("Implement the first version as described", environment,
        mode: :patch,
        conversation_history: [
          %{
            role: "user",
            message_kind: "objective",
            content: "How should the LiveView game runtime be structured?"
          },
          %{
            role: "assistant",
            message_kind: "assistant",
            content:
              "Plan: use Phoenix LiveView, a DynamicSupervisor, GameSessionServer, ECS tables, and ReqLLM intent parsing."
          }
        ]
      )

    assert prompt =~ "Prior conversation context:"
    assert prompt =~ "User (objective):"
    assert prompt =~ "Assistant (assistant):"
    assert prompt =~ "DynamicSupervisor"
    assert prompt =~ "ReqLLM intent parsing"
  end

  test "progress gate treats patch mode as mutating and blocks no-op scaffold output" do
    workspace = Workspace.new!(root: sample_scaffold_mix_project())

    proposal =
      WorkflowProposal.new!(
        "Build a field service dispatch workflow with work orders, technicians, assignments, lifecycle, supervision, and tests",
        [
          ProposalNode.new!("implement_project", :edit,
            params: %{
              operations: [],
              expected_changed_files: ["lib/field_service_dispatch.ex"]
            }
          ),
          ProposalNode.new!("verify_project", :verification_gate, params: %{checks: []})
        ],
        edges: [%{from: "implement_project", to: "verify_project"}],
        stop_conditions: ["implementation and verification evidence are present"]
      )

    assert ProgressGate.enabled?(proposal, mode: :patch)

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            changed_files: [],
            metadata: %{
              original_objective:
                "Build a field service dispatch workflow with work orders, technicians, assignments, lifecycle, supervision, and tests"
            }
          },
          episodes: [],
          trace: []
        },
        mode: :patch
      )

    assert result.objective_scorecard.objective_status == :objective_incomplete

    implementation_result =
      Enum.find(
        result.objective_scorecard.acceptance_results,
        &(&1.id == "progress-implementation-activity")
      )

    assert implementation_result.status == :fail
    assert implementation_result.message =~ "did not record changed implementation files"

    assert Enum.any?(
             result.context.repair_needs,
             &(&1.target == "progress-implementation-activity")
           )
  end

  test "progress gate extracts objective terms from the original request not repair logs" do
    prompt = """
    Continue in this same session using the prior run evidence. Original objective: Repair or build FieldServiceDispatch in this workspace.
    It must include work orders, technicians, assignment rules, lifecycle transitions,
    runtime supervision, objective-specific tests, and a runtime smoke. Use the failing smoke evidence shown below to repair the field-service implementation.

    Observed failing smoke before this follow-up:
    {
      "output_preview": "Compiling 1 file (.ex)\\nAssertion with =~ failed\\nFieldServiceDispatchTest"
    }
    """

    terms = ProgressGate.objective_terms(prompt)

    assert "FieldServiceDispatch" in terms
    refute "Elixir" in terms
    refute "Compiling" in terms
    refute "Assertion" in terms
    refute "FieldServiceDispatchTest" in terms
  end

  test "progress gate does not block objective-specific patches on noisy instruction words" do
    workspace = Workspace.new!(root: sample_scaffold_mix_project())

    patch_set =
      EditPatchSet.new!(
        "Implement proof of concept",
        [
          RunicAI.Coding.RLM.EditOperation.new!(:create_file,
            params: %{
              path: "lib/proof_of_concept.ex",
              content: "defmodule ProofOfConcept do\n  def status, do: :ready\nend\n",
              overwrite: true
            }
          ),
          RunicAI.Coding.RLM.EditOperation.new!(:create_file,
            params: %{
              path: "test/proof_of_concept_test.exs",
              content:
                "defmodule ProofOfConceptTest do\n  use ExUnit.Case\n  test \"status\" do\n    assert ProofOfConcept.status() == :ready\n  end\nend\n",
              overwrite: true
            }
          )
        ],
        expected_changed_files: ["lib/proof_of_concept.ex", "test/proof_of_concept_test.exs"]
      )

    assert {:ok, output} = EditPatchSet.apply(workspace, patch_set)
    assert output.status == :ok

    proposal =
      WorkflowProposal.new!(
        "Build an Elixir proof of concept. Ask for follow-up if CLI tests fail.",
        [ProposalNode.new!("implement_project", :edit, params: %{patch_set: patch_set})],
        stop_conditions: ["implementation evidence exists"]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{
            workspace: workspace,
            changed_files: output.changed_paths,
            metadata: %{original_objective: proposal.objective}
          },
          episodes: [],
          trace: []
        },
        mode: :patch
      )

    assert result.objective_scorecard.objective_status == :objective_satisfied

    refute Enum.any?(
             result.objective_scorecard.acceptance_results,
             &(&1.id == "progress-semantic-coverage" and &1.status == :fail)
           )
  end

  test "proposal validation rejects missing stop conditions and cycles" do
    proposal =
      WorkflowProposal.new!(
        "Loop",
        [
          ProposalNode.new!("a", :tool, params: %{tool: "find_files"}),
          ProposalNode.new!("b", :reducer, params: %{reducer: "report"})
        ],
        edges: [%{from: "a", to: "b"}, %{from: "b", to: "a"}],
        stop_conditions: []
      )

    report = WorkflowValidator.validate(proposal)

    refute WorkflowValidationReport.accepted?(report)
    assert Enum.any?(report.errors, &(&1.details.reason == :missing_stop_condition))
    assert Enum.any?(report.errors, &(&1.details.reason == :cycle))
  end

  test "proposal validation rejects repo QA workflows for mutating objectives" do
    proposal =
      WorkflowProposal.new!(
        "Build an Elixir field service dispatch proof of concept with tests",
        [
          ProposalNode.new!("discover", :tool, params: %{tool: "find_files"}),
          ProposalNode.new!("read", :tool, params: %{tool: "read_many"}),
          ProposalNode.new!("answer", :reducer, params: %{reducer: "report"})
        ],
        edges: [%{from: "discover", to: "read"}, %{from: "read", to: "answer"}],
        stop_conditions: ["answer returned"],
        metadata: %{recipe: :repo_qa}
      )

    report =
      WorkflowValidator.validate(proposal,
        allow_mutation?: true,
        allowed_tools: ["find_files", "read_many"]
      )

    refute WorkflowValidationReport.accepted?(report)

    assert Enum.any?(
             report.errors,
             &(&1.details.reason == :read_only_workflow_for_mutating_objective)
           )

    assert Enum.any?(
             report.errors,
             &(&1.details.reason == :missing_required_objective_stage)
           )
  end

  test "proposal input normalizes common coordinator vocabulary drift" do
    assert {:ok, agent_node} =
             ProposalNode.from_input(%{
               "id" => "repair",
               "kind" => "agent",
               "params" => %{"mode" => "review_repair", "task" => "repair objective gaps"}
             })

    assert agent_node.params.mode == "patch"

    assert {:ok, contract_node} =
             ProposalNode.from_input(%{
               "id" => "contract",
               "kind" => "deterministic_step",
               "params" => %{
                 "task" => "derive acceptance contract",
                 "outputs" => ["acceptance_contract"]
               }
             })

    assert contract_node.params.action == "constant"
    assert contract_node.params.value.task == "derive acceptance contract"

    assert {:ok, requirements_node} =
             ProposalNode.from_input(%{
               "id" => "requirements",
               "kind" => "deterministic_step",
               "params" => %{
                 "purpose" => "derive acceptance requirements",
                 "requirements" => ["work orders", "technicians"]
               }
             })

    assert requirements_node.params.action == "constant"
    assert requirements_node.params.value.requirements == ["work orders", "technicians"]

    assert {:ok, review_node} =
             ProposalNode.from_input(%{
               "id" => "abstract-edit",
               "kind" => "edit",
               "params" => %{
                 "operations" => [
                   %{
                     "type" => "ensure_behavioral_surface",
                     "description" => "Ensure high-signal behavior exists"
                   }
                 ]
               }
             })

    assert review_node.kind == :review_gate
    assert review_node.params.focus == ["Ensure high-signal behavior exists"]

    proposal =
      WorkflowProposal.new!(
        "Build an Elixir dispatch proof of concept",
        [
          contract_node,
          ProposalNode.new!("implement", :agent,
            params: %{mode: "patch", task: "implement dispatch"}
          ),
          ProposalNode.new!("verify", :verification_gate,
            params: %{checks: [%{type: "file_exists", params: %{path: "lib/demo.ex"}}]}
          )
        ],
        edges: [%{from: "contract", to: "implement"}, %{from: "implement", to: "verify"}],
        stop_conditions: ["verified"]
      )

    assert WorkflowValidator.validate(proposal, allow_mutation?: true).status == :accepted
  end

  test "codebase environment indexes files and materializes structural slices" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    assert Enum.any?(CodebaseEnvironment.source_summaries(env), &(&1.path == "lib/demo.ex"))
    assert {:ok, artifact} = CodebaseEnvironment.materialize(env, "lib/demo.ex")
    assert artifact.content =~ "def answer"

    assert {:ok, slice} =
             CodebaseEnvironment.slice(env, "lib/demo.ex", :line_window,
               start_line: 2,
               end_line: 2
             )

    assert slice.metadata.slice_mode == :line_window

    assert {:error, error} = CodebaseEnvironment.register_file(env, "../outside.ex")
    assert error.message =~ "workspace root"
  end

  test "codebase environment skips binary and generated scratch files during indexing" do
    root = sample_project()
    File.mkdir_p!(Path.join(root, "tmp/browser-ui-launch"))
    File.write!(Path.join(root, "image.bin"), <<169, 200, 207, 131, 0, 72>>)
    File.write!(Path.join(root, "tmp/browser-ui-launch/session.png"), <<137, 80, 78, 71, 13, 10>>)

    assert {:ok, env} = CodebaseEnvironment.new(root, index?: true)
    summaries = CodebaseEnvironment.source_summaries(env)

    assert Enum.any?(summaries, &(&1.path == "lib/demo.ex"))
    refute Enum.any?(summaries, &(&1.path == "image.bin"))

    refute Enum.any?(summaries, fn summary ->
             is_binary(summary.path) and String.starts_with?(summary.path, "tmp/")
           end)
  end

  test "codebase environment indexes this repo in read-only mode" do
    assert {:ok, env} = CodebaseEnvironment.new(File.cwd!(), index?: true, file_limit: 30)

    assert Enum.any?(CodebaseEnvironment.source_summaries(env), &(&1.path == "AGENTS.md"))
  end

  test "coordinator rejects unsafe structured proposal output without implicit fallback" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    client = fn _model, _prompt, _schema, _opts ->
      {:ok,
       %{
         "objective" => "unsafe",
         "nodes" => [%{"id" => "shell", "kind" => "command", "params" => %{"command" => "rm"}}],
         "stop_conditions" => ["done"]
       }}
    end

    assert {:error, error} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               proposal_generation: :object,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert error.message =~ "could not produce an accepted workflow proposal"
    assert error.details.stage == :final
    refute inspect(error.details) =~ "fallback"
  end

  test "coordinator exposes shallow actionable diagnostics after proposal rejection" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    client = fn _model, _prompt, _schema, _opts ->
      {:ok,
       %{
         "objective" => "Change Demo",
         "nodes" => [
           %{
             "id" => "shell",
             "kind" => "command",
             "params" => %{"args" => %{"argv" => ["mix", "test"]}}
           }
         ],
         "stop_conditions" => ["done"]
       }}
    end

    assert {:error, error} =
             Coordinator.propose("Change Demo", env,
               client: client,
               mode: :patch,
               profile: :coding_patch,
               seed_implementation?: false,
               proposal_generation: :object,
               proposal_repair_attempts: 0
             )

    assert Enum.any?(error.details.diagnostics, fn diagnostic ->
             diagnostic[:reason] == :disallowed_node_kind and diagnostic[:node_ids] == ["shell"]
           end)
  end

  test "coordinator rejects malformed structured proposal output without implicit fallback" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    client = fn _model, _prompt, _schema, _opts ->
      {:ok,
       %{
         "objective" => "malformed",
         "nodes" => "1) inspect files 2) summarize",
         "stop_conditions" => ["done"]
       }}
    end

    assert {:error, error} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               proposal_generation: :object,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert error.message =~ "could not produce an accepted workflow proposal"
    assert error.details.stage == :final
  end

  test "coordinator only falls back when an explicit fallback recipe is provided" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    client = fn _model, _prompt, _schema, _opts ->
      {:ok,
       %{
         "objective" => "unsafe",
         "nodes" => [%{"id" => "shell", "kind" => "command", "params" => %{"command" => "rm"}}],
         "stop_conditions" => ["done"]
       }}
    end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               proposal_generation: :object,
               fallback?: true,
               fallback_recipe: :repo_qa,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert proposal.metadata.recipe == :repo_qa
    assert report.status == :accepted
  end

  test "coordinator falls back from object generation provider errors to JSON text" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: ObjectFallbackClient,
               proposal_generation: :object,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert Enum.map(proposal.nodes, & &1.id) == ["discover", "answer"]
  end

  test "coordinator accepts JSON text workflow proposals by default" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    proposal_json =
      Jason.encode!(%{
        "objective" => "Explain Demo",
        "nodes" => [
          %{"id" => "discover", "kind" => "tool", "params" => %{"tool" => "find_files"}},
          %{"id" => "answer", "kind" => "reducer", "params" => %{"reducer" => "report"}}
        ],
        "edges" => [%{"from" => "discover", "to" => "answer"}],
        "stop_conditions" => ["answer returned"]
      })

    client = fn _model, _prompt, _opts -> {:ok, TestClient.result(proposal_json)} end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert Enum.map(proposal.nodes, & &1.id) == ["discover", "answer"]
  end

  test "coordinator extracts JSON proposal objects from fenced model chatter" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    proposal_json =
      Jason.encode!(%{
        "objective" => "Explain Demo",
        "nodes" => [
          %{"id" => "discover", "kind" => "tool", "params" => %{"tool" => "find_files"}},
          %{"id" => "answer", "kind" => "reducer", "params" => %{"reducer" => "report"}}
        ],
        "edges" => [%{"from" => "discover", "to" => "answer"}],
        "stop_conditions" => ["answer returned"]
      })

    response = """
    Sure, here is the workflow proposal:

    ```json
    #{proposal_json}
    ```

    This plan should satisfy the request.
    """

    client = fn _model, _prompt, _opts -> {:ok, TestClient.result(response)} end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert Enum.map(proposal.nodes, & &1.id) == ["discover", "answer"]
  end

  test "coordinator normalizes generated proposals with missing stop conditions" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    proposal_json =
      Jason.encode!(%{
        "objective" => "Explain Demo",
        "nodes" => [
          %{"id" => "discover", "kind" => "tool", "params" => %{"tool" => "find_files"}},
          %{"id" => "answer", "kind" => "reducer", "params" => %{"reducer" => "report"}}
        ],
        "edges" => [%{"from" => "discover", "to" => "answer"}]
      })

    client = fn _model, _prompt, _opts -> {:ok, TestClient.result(proposal_json)} end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert proposal.stop_conditions == ["workflow reaches final node answer"]
  end

  test "coordinator merges partial repair responses over the previous proposal" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, prompt, _opts ->
      call = Elixir.Agent.get_and_update(calls, &{&1, &1 + 1})

      response =
        case call do
          0 ->
            %{
              "objective" => "Explain Demo",
              "nodes" => "discover then answer",
              "stop_conditions" => ["answer returned"]
            }

          _other ->
            assert prompt =~ "Return a complete corrected workflow proposal object"
            refute prompt =~ "targeted semantic"

            %{
              "nodes" => [
                %{"id" => "discover", "kind" => "tool", "params" => %{"tool" => "find_files"}},
                %{"id" => "answer", "kind" => "reducer", "params" => %{"reducer" => "report"}}
              ],
              "edges" => [%{"from" => "discover", "to" => "answer"}]
            }
        end

      {:ok, TestClient.result(Jason.encode!(response))}
    end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               proposal_repair_attempts: 1,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert proposal.objective == "Explain Demo"
    assert proposal.stop_conditions == ["answer returned"]
    assert Enum.map(proposal.nodes, & &1.id) == ["discover", "answer"]
  end

  test "coordinator repairs a normalized proposal with server-pinned typed operations" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, prompt, _opts ->
      call = Elixir.Agent.get_and_update(calls, &{&1, &1 + 1})

      response =
        case call do
          0 ->
            %{
              "id" => "cyclic-repair",
              "objective" => "Explain Demo",
              "nodes" => [
                %{
                  "id" => "discover",
                  "kind" => "tool",
                  "params" => %{"tool" => "find_files"}
                },
                %{
                  "id" => "answer",
                  "kind" => "reducer",
                  "params" => %{"reducer" => "report"}
                }
              ],
              "edges" => [
                %{"from" => "discover", "to" => "answer"},
                %{"from" => "answer", "to" => "discover"}
              ],
              "stop_conditions" => ["answer returned"]
            }

          _other ->
            assert prompt =~ "targeted semantic"
            assert prompt =~ "Current editable manifest"
            assert prompt =~ "disconnect: op,edge_id"
            refute prompt =~ "Return a complete corrected workflow proposal object"

            %{
              "base_revision" => 999,
              "base_hash" => "agent-cannot-override-server-pin",
              "operations" => [
                %{
                  "op" => "disconnect",
                  "edge_id" => "answer.context->discover.context"
                }
              ]
            }
        end

      {:ok, TestClient.result(Jason.encode!(response))}
    end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               proposal_repair_attempts: 1,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert proposal.id == "cyclic-repair"
    assert Enum.map(proposal.edges, &{&1.from, &1.to}) == [{"discover", "answer"}]

    assert %{
             strategy: :typed_operations,
             attempts: 1,
             batches: [
               %{
                 status: :applied,
                 base_revision: 1,
                 result_revision: 2,
                 affected_nodes: ["answer", "discover"]
               }
             ]
           } = report.metadata.coordinator_repair

    assert Elixir.Agent.get(calls, & &1) == 2
  end

  test "coordinator retries a rejected typed operation without mutating its semantic base" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, prompt, _opts ->
      call = Elixir.Agent.get_and_update(calls, &{&1, &1 + 1})

      response =
        case call do
          0 ->
            %{
              "id" => "retry-typed-repair",
              "objective" => "Explain Demo",
              "nodes" => [
                %{
                  "id" => "discover",
                  "kind" => "tool",
                  "params" => %{"tool" => "find_files"}
                },
                %{
                  "id" => "answer",
                  "kind" => "reducer",
                  "params" => %{"reducer" => "report"}
                }
              ],
              "edges" => [
                %{"from" => "discover", "to" => "answer"},
                %{"from" => "answer", "to" => "discover"}
              ],
              "stop_conditions" => ["answer returned"]
            }

          1 ->
            assert prompt =~ "Base revision: 1"

            %{
              "operations" => [
                %{"op" => "disconnect", "edge_id" => "missing.context->edge.context"}
              ]
            }

          _other ->
            assert prompt =~ "Base revision: 1"
            assert prompt =~ "workflow edge does not exist"

            %{
              "operations" => [
                %{
                  "op" => "disconnect",
                  "edge_id" => "answer.context->discover.context"
                }
              ]
            }
        end

      {:ok, TestClient.result(Jason.encode!(response))}
    end

    assert {:ok, _proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               proposal_repair_attempts: 2,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.metadata.coordinator_repair.attempts == 2

    assert [%{status: :rejected, base_revision: 1}, %{status: :applied, base_revision: 1}] =
             report.metadata.coordinator_repair.batches

    assert Elixir.Agent.get(calls, & &1) == 3
  end

  test "coordinator preserves invalid JSON proposal text previews near the error" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    response = """
    ```json
    {"objective": "broken", "nodes": [
    ```
    """

    client = fn _model, _prompt, _opts -> {:ok, TestClient.result(response)} end

    assert {:error, error} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               fallback?: false,
               proposal_repair_attempts: 0,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    [generation_error] = error.details.errors
    decode_error = generation_error.details.error

    assert decode_error.message =~ "not valid JSON"
    assert decode_error.text_preview =~ "\"objective\": \"broken\""
  end

  test "coordinator retries malformed JSON returned during proposal repair" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      call = Elixir.Agent.get_and_update(calls, &{&1, &1 + 1})

      response =
        case call do
          0 ->
            Jason.encode!(%{
              "objective" => "Refactor Demo",
              "nodes" => "inspect then patch",
              "stop_conditions" => ["refactor verified"]
            })

          1 ->
            """
            {"objective": "Refactor Demo", "nodes": [
            """

          _ ->
            Jason.encode!(%{
              "nodes" => [
                %{
                  "id" => "inspect",
                  "kind" => "tool",
                  "params" => %{"tool" => "find_files", "args" => %{"path" => "."}}
                },
                %{
                  "id" => "patch",
                  "kind" => "agent",
                  "params" => %{"mode" => "patch", "task" => "Refactor Demo and tests."}
                },
                %{
                  "id" => "verify",
                  "kind" => "verification_gate",
                  "params" => %{
                    "checks" => [
                      %{
                        "id" => "demo-source",
                        "type" => "source_contains",
                        "params" => %{"path" => "lib/demo.ex", "text" => "def answer"}
                      }
                    ]
                  }
                }
              ],
              "edges" => [
                %{"from" => "inspect", "to" => "patch"},
                %{"from" => "patch", "to" => "verify"}
              ]
            })
        end

      {:ok, TestClient.result(response)}
    end

    assert {:ok, proposal, report} =
             Coordinator.propose("Refactor Demo", env,
               client: client,
               fallback?: false,
               proposal_repair_attempts: 2,
               mode: :patch,
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_mutation?: true,
                 allowed_tools: ["find_files", "read_many"]
               ]
             )

    assert report.status == :accepted
    assert Enum.map(proposal.nodes, & &1.id) == ["inspect", "patch", "verify"]
    assert Elixir.Agent.get(calls, & &1) == 3
  end

  test "coordinator repairs malformed generated proposals for mutating objectives" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _schema, _opts ->
      call = Elixir.Agent.get_and_update(calls, &{&1, &1 + 1})

      case call do
        0 ->
          {:ok,
           %{
             "objective" => "create a demo project",
             "nodes" => "1) run mix new 2) verify it",
             "edges" => "create -> verify",
             "stop_conditions" => ["project created"]
           }}

        _ ->
          {:ok,
           %{
             "objective" => "create a demo project",
             "nodes" => [
               %{
                 "id" => "create",
                 "kind" => "command",
                 "params" => %{
                   "argv" => ["mix", "new", "field_service_demo"],
                   "args" => %{"argv" => ["mix", "new", "field_service_demo"]}
                 }
               },
               %{
                 "id" => "verify",
                 "kind" => "verification_gate",
                 "params" => %{
                   "checks" => [
                     %{
                       "id" => "mix-file",
                       "type" => "file_exists",
                       "params" => %{"path" => "field_service_demo/mix.exs"}
                     }
                   ]
                 }
               }
             ],
             "edges" => [%{"from" => "create", "to" => "verify"}],
             "stop_conditions" => ["mix project exists"],
             "metadata" => %{"source" => "repair"}
           }}
      end
    end

    assert {:ok, proposal, report} =
             Coordinator.propose("Create a tiny Mix project", env,
               client: client,
               seed_implementation?: false,
               proposal_generation: :object,
               fallback?: false,
               proposal_repair_attempts: 1,
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_mutation?: true,
                 allow_commands?: true,
                 allowed_commands: ["mix"]
               ]
             )

    assert report.status == :accepted
    assert Enum.map(proposal.nodes, & &1.kind) == [:command, :verification_gate]
    assert proposal.metadata == %{"source" => "repair"}
    assert Elixir.Agent.get(calls, & &1) == 2
  end

  test "validator normalizes direct argv lists under command args without crashing" do
    command =
      ProposalNode.new!("test", :command, params: %{args: ["mix", "test"]})

    proposal =
      WorkflowProposal.new!("Run the tests", [command], stop_conditions: ["tests pass"])

    report =
      WorkflowValidator.validate(proposal,
        allowed_kinds: ProposalNode.allowed_kinds(),
        allow_commands?: true,
        allowed_commands: ["mix"]
      )

    assert report.status == :accepted
    assert report.errors == []
  end

  test "coordinator does not silently fall back for mutating objectives when fallback is disabled" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    client = fn _model, _prompt, _schema, _opts ->
      {:ok,
       %{
         "objective" => "malformed",
         "nodes" => "inspect files then write code",
         "stop_conditions" => ["done"]
       }}
    end

    assert {:error, error} =
             Coordinator.propose("Create a tiny Mix project", env,
               client: client,
               seed_implementation?: false,
               proposal_generation: :object,
               fallback?: false,
               proposal_repair_attempts: 1,
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_mutation?: true,
                 allow_commands?: true,
                 allowed_commands: ["mix"]
               ]
             )

    assert error.message =~ "could not produce an accepted workflow proposal"
    assert error.details.stage == :final
  end

  test "coordinator does not silently fall back to repo QA in patch mode" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    read_only_proposal = %{
      "objective" => "Build an Elixir dispatch proof of concept",
      "nodes" => [
        %{"id" => "discover", "kind" => "tool", "params" => %{"tool" => "find_files"}},
        %{"id" => "read", "kind" => "tool", "params" => %{"tool" => "read_many"}},
        %{"id" => "answer", "kind" => "reducer", "params" => %{"reducer" => "report"}}
      ],
      "edges" => [
        %{"from" => "discover", "to" => "read"},
        %{"from" => "read", "to" => "answer"}
      ],
      "stop_conditions" => ["answer returned"],
      "metadata" => %{"recipe" => "repo_qa"}
    }

    client = fn _model, _prompt, _opts ->
      {:ok, TestClient.result(Jason.encode!(read_only_proposal))}
    end

    assert {:error, error} =
             Coordinator.propose("Build an Elixir dispatch proof of concept", env,
               client: client,
               mode: :patch,
               seed_implementation?: false,
               proposal_repair_attempts: 0,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert error.message =~ "could not produce an accepted workflow proposal"

    assert inspect(error.details) =~ "missing a required mutating node"
    refute inspect(error.details) =~ "fallback"
  end

  test "coordinator preserves provider failure reason summaries" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)

    provider_error =
      RunicAI.Error.provider("ReqLLM generate_text failed",
        details: %{
          reason:
            ReqLLM.Error.API.Request.exception(
              reason: "HTTP 400: model rejected prompt",
              status: 400,
              response_body: %{"error" => %{"message" => "prompt too large"}}
            ),
          reason_message: "API request failed (400): HTTP 400: model rejected prompt",
          status: 400,
          response_body_preview: ~s(%{"error" => %{"message" => "prompt too large"}})
        }
      )

    client = fn _model, _prompt, _opts -> {:error, provider_error} end

    assert {:error, error} =
             Coordinator.propose("Build an Elixir dispatch proof of concept", env,
               client: client,
               mode: :patch,
               seed_implementation?: false,
               fallback?: false,
               proposal_repair_attempts: 0
             )

    [generation_error] = error.details.errors
    provider_details = generation_error.details.error

    assert provider_details.message == "ReqLLM generate_text failed"
    assert provider_details.reason_message =~ "model rejected prompt"
    assert provider_details.status == 400
    assert provider_details.response_body_preview =~ "prompt too large"
  end

  test "coordinator retries a transient provider failure before proposal validation" do
    root = sample_project()
    env = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    proposal =
      Jason.encode!(%{
        id: "retry-repo-qa",
        objective: "Locate Demo.answer/0",
        assumptions: [],
        sources: ["repo:manifest"],
        nodes: [
          %{id: "discover", kind: "tool", params: %{tool: "find_files"}},
          %{id: "answer", kind: "reducer", params: %{reducer: "report"}}
        ],
        edges: [%{from: "discover", to: "answer"}],
        policies: %{},
        expected_artifacts: [],
        stop_conditions: ["answer returned"],
        metadata: %{}
      })

    client = fn _model, _prompt, _opts ->
      case Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 ->
          {:error,
           RunicAI.Error.provider("temporarily rate limited",
             retryable?: true,
             details: %{status: 429, retry_after_ms: 0}
           )}

        _other ->
          {:ok, TestClient.result(proposal)}
      end
    end

    assert {:ok, generated, report} =
             Coordinator.propose("Where is Demo.answer/0?", env,
               client: client,
               proposal_generation: :json_text,
               proposal_generation_retry_policy: [max_attempts: 2, backoff: 0],
               fallback?: false,
               validation_opts: [allowed_tools: ["find_files"]]
             )

    assert report.status == :accepted
    assert generated.id == "retry-repo-qa"
    assert Elixir.Agent.get(calls, & &1) == 2
  end

  test "agent compiles and executes a decomposed repo QA workflow" do
    root = sample_project()

    assert {:ok, result} =
             Agent.run(root, "Where is Demo.answer/0?",
               command: :repo_qa,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert result.validation_report.status == :accepted
    assert Enum.map(result.episodes, & &1.parent_node_id) == ["discover", "read", "answer"]
    assert result.output =~ "lib/demo.ex"
    assert result.workflow.name =~ "rlm_coding_workflow"
  end

  test "compiler topologically executes generated proposals that are not pre-sorted" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Where is Demo.answer/0?",
        [
          ProposalNode.new!("answer", :reducer, params: %{reducer: "report"}),
          ProposalNode.new!("read", :tool,
            params: %{tool: "read_many", args: %{paths: [], total_max_bytes: 4_000}}
          ),
          ProposalNode.new!("discover", :tool,
            params: %{tool: "find_files", args: %{path: ".", query: "demo", limit: 10}}
          )
        ],
        edges: [%{from: "discover", to: "read"}, %{from: "read", to: "answer"}],
        stop_conditions: ["answer returned"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert Enum.map(result.episodes, & &1.parent_node_id) == ["discover", "read", "answer"]
    assert result.output =~ "lib/demo.ex"
  end

  test "command nodes execute nested args shape accepted by generated proposals" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Run a harmless Mix command",
        [
          ProposalNode.new!("mix-version", :command,
            params: %{args: %{argv: ["mix", "--version"], timeout_ms: 10_000}}
          )
        ],
        stop_conditions: ["mix version command passed"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_commands?: true,
                 allowed_commands: ["mix"]
               ]
             )

    assert result.output.status == :pass
    assert result.output.argv == ["mix", "--version"]
  end

  test "command nodes record workspace files they create" do
    root = sample_mix_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Create a marker through an explicit command node",
        [
          ProposalNode.new!("create-marker", :command,
            params: %{
              args: %{
                argv: ["mix", "run", "-e", "File.write!(\"command-marker.txt\", \"ok\")"],
                metadata: %{safe?: true, requires_review?: false}
              }
            }
          )
        ],
        stop_conditions: ["marker created"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_commands?: true,
                 allowed_commands: ["mix"]
               ]
             )

    assert result.output.status == :pass
    assert "command-marker.txt" in result.context.changed_files
  end

  test "computing nodes execute safe component families inside coding RLM workflows" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    jsonl = """
    {"ticket":"T1","theme":"login","severity":"high"}
    {"ticket":"T2","theme":"billing","severity":"medium"}
    """

    proposal =
      WorkflowProposal.new!(
        "Rank tickets without shelling out",
        [
          ProposalNode.new!("input", :deterministic_step,
            params: %{action: "constant", value: %{text: jsonl}}
          ),
          ProposalNode.new!("parse", :computing,
            params: %{family: :json_compute, op: :records_from_jsonl}
          ),
          ProposalNode.new!("rank", :computing,
            params: %{
              family: :score_compute,
              op: :rank_records,
              criteria: [%{path: "severity", equals: "high", weight: 10}]
            }
          )
        ],
        edges: [%{from: "input", to: "parse"}, %{from: "parse", to: "rank"}],
        stop_conditions: ["ranked tickets"]
      )

    assert {:ok, result} = WorkflowCompiler.run(proposal, environment, %{})
    assert result.validation_report.status == :accepted
    assert [%{"rank" => 1, "score" => 10.0, "ticket" => "T1"} | _] = result.output.records
  end

  test "compiler accepts every proposal node kind when policy explicitly allows it" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    patch =
      PlanPatch.new!([PlanNode.new!("extra", :map_leaf)],
        metadata: %{depth: 0, patch_count: 0}
      )

    nodes = [
      ProposalNode.new!("llm", :llm_leaf, params: %{prompt: "summarize"}),
      ProposalNode.new!("tool", :tool, params: %{tool: "find_files", args: %{path: "."}}),
      ProposalNode.new!("command", :command,
        params: %{argv: ["git", "status", "--short"], args: %{argv: ["git", "status", "--short"]}}
      ),
      ProposalNode.new!("script", :script, params: %{script: "echo ok"}),
      ProposalNode.new!("compute", :computing,
        params: %{family: :collection_compute, op: :take, limit: 1}
      ),
      ProposalNode.new!("step", :deterministic_step,
        params: %{action: "constant", value: %{ok: true}}
      ),
      ProposalNode.new!("agent", :agent, params: %{mode: "read_only", task: "Explain Demo"}),
      ProposalNode.new!("edit", :edit,
        params: %{
          operations: [
            %{kind: "create_file", params: %{path: "tmp_marker.txt", content: "marker\n"}}
          ]
        }
      ),
      ProposalNode.new!("verification", :verification_gate,
        params: %{
          checks: [
            %{id: "marker", type: "file_exists", params: %{path: "tmp_marker.txt"}}
          ]
        }
      ),
      ProposalNode.new!("reducer", :reducer, params: %{reducer: "report"}),
      ProposalNode.new!("gate", :review_gate),
      ProposalNode.new!("patch", :workflow_patch, params: %{patch: patch})
    ]

    proposal =
      WorkflowProposal.new!("Compile every allowed node kind", nodes,
        stop_conditions: ["workflow compiled"]
      )

    assert {:ok, compiled} =
             WorkflowCompiler.compile(proposal, environment,
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allowed_tools: ["find_files"],
                 allow_mutation?: true,
                 allow_commands?: true,
                 allowed_commands: ["git"],
                 allow_scripts?: true
               ]
             )

    assert Map.keys(compiled.node_names) |> MapSet.new() ==
             Enum.map(nodes, & &1.id) |> MapSet.new()
  end

  test "agent nodes can call the standard coding agent as a child workflow" do
    root = sample_project()

    proposal =
      WorkflowProposal.new!(
        "Ask a child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child answer returned"]
      )

    assert {:ok, result} =
             Agent.run(root, "Ask a child agent",
               proposal: proposal,
               client: TestClient.client("Demo.answer/0 returns 42.")
             )

    assert %RunicAI.Coding.RLM.ChildResult{
             status: :completed,
             summary: "Demo.answer/0 returns 42."
           } = result.output
  end

  test "agent run returns a structured timeout when wall-clock budget is exhausted" do
    root = sample_project()

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(1_000)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:error, error} =
             Agent.run(root, "Ask a slow child agent",
               client: slow_client,
               max_runtime_ms: 20
             )

    assert error.kind == :timeout
    assert error.message == "RLM runtime budget exhausted"
    assert error.details.stage in [:rlm_agent_run, :proposal_generation]
  end

  test "agent run emits proposal lifecycle before execution" do
    root = sample_project()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    proposal =
      WorkflowProposal.new!(
        "Emit proposal lifecycle",
        [
          ProposalNode.new!("summary", :deterministic_step,
            params: %{action: "constant", value: "ready"}
          )
        ],
        stop_conditions: ["proposal observed"]
      )

    assert {:ok, _result} =
             Agent.run(root, "Emit proposal lifecycle",
               proposal: proposal,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    stages = events |> Elixir.Agent.get(& &1) |> Enum.map(& &1.stage)

    assert :proposal_started in stages
    assert :proposal_received in stages

    proposal_started = Enum.find(Elixir.Agent.get(events, & &1), &(&1.stage == :proposal_started))
    assert get_in(proposal_started, [:data, :objective_contract, :id]) =~ "objective-contract:"
    assert get_in(proposal_started, [:data, :objective_contract, :requirements]) != []

    assert Enum.find_index(stages, &(&1 == :proposal_started)) <
             Enum.find_index(stages, &(&1 == :proposal_received))
  end

  test "agent run emits proposal progress while coordinator generation is active" do
    root = sample_project()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    proposal_json =
      Jason.encode!(%{
        "objective" => "Emit proposal progress",
        "nodes" => [
          %{
            "id" => "summary",
            "kind" => "deterministic_step",
            "params" => %{"action" => "constant", "value" => "ready"}
          }
        ],
        "stop_conditions" => ["proposal observed"]
      })

    parent = self()

    slow_client = fn _model, _prompt, client_opts ->
      send(parent, {:proposal_client_opts, client_opts})
      Process.sleep(140)
      {:ok, TestClient.result(proposal_json)}
    end

    assert {:ok, _result} =
             Agent.run(root, "Emit proposal progress",
               client: slow_client,
               max_runtime_ms: 1_000,
               proposal_progress_tick_ms: 50,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &match?(
               %{stage: :proposal_progress, data: %{elapsed_ms: elapsed_ms}}
               when elapsed_ms >= 50,
               &1
             )
           )

    assert_receive {:proposal_client_opts, client_opts}
    refute Keyword.has_key?(client_opts, :max_runtime_ms)
    assert is_integer(Keyword.get(client_opts, :receive_timeout))
  end

  test "child agent runtime budget records a failed child result without aborting workflow" do
    root = sample_project()

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child attempted"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(1_000)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:ok, result} =
             Agent.run(root, "Ask a slow child agent",
               proposal: proposal,
               client: slow_client,
               max_child_runtime_ms: 20
             )

    assert %ChildResult{status: :failed, unresolved_risks: [risk]} = result.output
    assert risk == "RLM runtime budget exhausted"
  end

  test "child agent inherits a bounded runtime slice from the parent workflow budget" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child attempted"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(500)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: slow_client,
               max_runtime_ms: 900
             )

    assert %ChildResult{
             status: :failed,
             metadata: %{error_kind: :timeout, error_details: details}
           } = result.output

    assert details.timeout_ms in 400..450
    assert details.stage == :workflow_child_agent
    assert details.node_id == "child"
    assert details.mode == "read_only"
  end

  test "child agent timeout is capped by remaining parent deadline" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child attempted"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(500)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: slow_client,
               max_runtime_ms: 9_000,
               run_deadline_ms: System.monotonic_time(:millisecond) + 600
             )

    assert %ChildResult{
             status: :failed,
             metadata: %{error_kind: :timeout, error_details: details}
           } = result.output

    assert details.timeout_ms > 0
    assert details.timeout_ms <= 300
    assert details.node_id == "child"
  end

  test "child agent runtime can be capped by mode" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child attempted"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(500)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: slow_client,
               agent_opts: [max_runtime_ms: 10_000],
               child_runtime_mode_caps: %{read_only: 300}
             )

    assert %ChildResult{
             status: :failed,
             metadata: %{error_kind: :timeout, error_details: details}
           } = result.output

    assert details.timeout_ms == 300
    assert details.node_id == "child"
  end

  test "child agent runtime emits started and progress events before timeout" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child attempted"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(500)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: slow_client,
               child_runtime_mode_caps: %{read_only: 220},
               child_progress_tick_ms: 50,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    emitted = Elixir.Agent.get(events, & &1)

    assert %ChildResult{status: :failed} = result.output

    assert Enum.any?(
             emitted,
             &match?(%{stage: :child_agent_started, data: %{node_id: "child"}}, &1)
           )

    assert Enum.any?(
             emitted,
             &match?(
               %{
                 stage: :child_agent_progress,
                 data: %{node_id: "child", elapsed_ms: elapsed_ms}
               }
               when elapsed_ms >= 50,
               &1
             )
           )
  end

  test "child agent forwards live standard tool and verification events before completion" do
    root = sample_mix_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, TestClient.result("Verification: run_tests pass.")}
      else
        {:ok,
         TestClient.tool_response([
           TestClient.tool_call(
             "project_command",
             %{
               argv: [
                 "mix",
                 "run",
                 "-e",
                 ~S|IO.puts("child command phase one"); Process.sleep(80); IO.puts("child command phase two")|
               ]
             },
             id: "call_1"
           )
         ])}
      end
    end

    proposal =
      WorkflowProposal.new!(
        "Ask a child agent to verify Demo.answer/0",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "verify", task: "Run the focused Demo test."}
          )
        ],
        stop_conditions: ["child verification returned"]
      )

    assert {:ok, _result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: client,
               agent_review_gates?: false,
               child_runtime_mode_caps: %{verify: 5_000},
               validation_opts: [allow_mutation?: true, allow_verification?: true],
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    emitted = Elixir.Agent.get(events, & &1)

    tool_call_index =
      Enum.find_index(
        emitted,
        &match?(
          %{
            stage: :child_agent_event,
            data: %{
              node_id: "child",
              live?: true,
              child_event: %{kind: :coding_tool_call}
            }
          },
          &1
        )
      )

    verification_index =
      Enum.find_index(
        emitted,
        &match?(
          %{
            stage: :child_agent_event,
            data: %{
              node_id: "child",
              live?: true,
              child_event: %{kind: :coding_verification_observation}
            }
          },
          &1
        )
      )

    command_progress_index =
      Enum.find_index(
        emitted,
        &match?(
          %{
            stage: :child_agent_event,
            data: %{
              node_id: "child",
              live?: true,
              child_event: %{kind: :coding_command_progress}
            }
          },
          &1
        )
      )

    completed_index =
      Enum.find_index(emitted, &match?(%{stage: :child_agent_completed}, &1))

    assert is_integer(tool_call_index)
    assert is_integer(verification_index)
    assert is_integer(command_progress_index)
    assert is_integer(completed_index)
    assert tool_call_index < completed_index
    assert verification_index < completed_index
    assert command_progress_index < completed_index
  end

  test "child agent applies parent review decider to resume approved patch gates" do
    root = sample_project()
    File.write!(Path.join(root, "lib/old.ex"), "defmodule Old, do: nil\n")
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, TestClient.result("Changed files: lib/old.ex. Verification: not run.")}
      else
        {:ok,
         TestClient.tool_response([
           TestClient.tool_call(
             "apply_patch",
             %{operations: [%{op: "delete", path: "lib/old.ex"}]},
             id: "call_1"
           )
         ])}
      end
    end

    proposal =
      WorkflowProposal.new!(
        "Delete a file through a review-gated child patch agent",
        [
          ProposalNode.new!("child", :agent, params: %{mode: "patch", task: "Delete lib/old.ex."})
        ],
        stop_conditions: ["file deleted"]
      )

    review_decider = fn request, context ->
      assert context.child_agent? == true
      assert context.node_id == "child"
      {:ok, Review.allow(request, reason: "approved by parent policy")}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: client,
               review_decider: review_decider,
               validation_opts: [allow_mutation?: true],
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    refute File.exists?(Path.join(root, "lib/old.ex"))

    assert [%ChildResult{status: :completed, changed_files: ["lib/old.ex"]}] =
             result.context.child_results

    assert Enum.any?(
             Elixir.Agent.get(events, & &1),
             &match?(
               %{
                 stage: :child_agent_review_decided,
                 data: %{node_id: "child", decision_status: :approved}
               },
               &1
             )
           )
  end

  test "child agent can resume more than three approved patch gates" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      completed_calls = Enum.count(messages, &(&1.role == :tool))

      if completed_calls < 4 do
        number = completed_calls + 1

        {:ok,
         TestClient.tool_response([
           TestClient.tool_call(
             "apply_patch",
             %{
               operations: [
                 %{
                   op: "create",
                   path: "lib/review_#{number}.ex",
                   content: "defmodule Review#{number}, do: :ok\n"
                 }
               ]
             },
             id: "call_#{number}"
           )
         ])}
      else
        {:ok, TestClient.result("Created four reviewed files. Verification: not run.")}
      end
    end

    proposal =
      WorkflowProposal.new!(
        "Create four files through a review-gated child patch agent",
        [
          ProposalNode.new!("child", :agent, params: %{mode: "patch", task: "Create four files."})
        ],
        stop_conditions: ["four files created"]
      )

    review_decider = fn request, _context ->
      {:ok, Review.allow(request, reason: "approved by parent policy")}
    end

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: client,
               review_decider: review_decider,
               validation_opts: [allow_mutation?: true]
             )

    assert Enum.all?(1..4, &File.exists?(Path.join(root, "lib/review_#{&1}.ex")))

    assert [%ChildResult{status: :completed, changed_files: changed_files}] =
             result.context.child_results

    assert Enum.sort(changed_files) == Enum.map(1..4, &"lib/review_#{&1}.ex")
  end

  test "patch child retries locally after a no-op attempt before outer repair" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)
    parent = self()

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      prompt_text = Enum.map_join(messages, "\n", &to_string(&1.content))

      cond do
        Enum.any?(messages, &(&1.role == :tool)) ->
          {:ok, TestClient.result("Changed files: lib/noop_repair.ex. Verification: not run.")}

        String.contains?(prompt_text, "previous patch-mode child attempt") ->
          send(parent, :noop_repair_prompt_seen)

          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{
                     op: "create",
                     path: "lib/noop_repair.ex",
                     content: "defmodule NoopRepair, do: :ok\n"
                   }
                 ]
               },
               id: "repair_call"
             )
           ])}

        true ->
          {:ok, TestClient.result("I inspected the workspace but made no changes.")}
      end
    end

    proposal =
      WorkflowProposal.new!(
        "Create a file after a no-op child",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "patch", task: "Create lib/noop_repair.ex."}
          )
        ],
        stop_conditions: ["file created"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: client,
               agent_review_gates?: false,
               validation_opts: [allow_mutation?: true],
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert_receive :noop_repair_prompt_seen
    assert File.exists?(Path.join(root, "lib/noop_repair.ex"))

    assert [
             %ChildResult{
               status: :completed,
               changed_files: ["lib/noop_repair.ex"],
               metadata: %{child_noop_repair_attempts: 1}
             }
           ] = result.context.child_results

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &match?(
               %{
                 stage: :child_noop_repair_started,
                 data: %{node_id: "child", attempt: 1}
               },
               &1
             )
           )

    assert Enum.any?(
             emitted,
             &match?(
               %{
                 stage: :child_noop_repair_completed,
                 data: %{node_id: "child", changed_files: ["lib/noop_repair.ex"], repaired?: true}
               },
               &1
             )
           )
  end

  test "patch child does not spend no-op repair attempts on non-retryable provider failures" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      Elixir.Agent.update(calls, &(&1 + 1))

      {:error,
       Error.provider("generation failed",
         details: %{
           requested_model: "openai:gpt-5.6-terra",
           status: 429,
           reason_message: "insufficient_quota: credit balance exhausted"
         }
       )}
    end

    proposal =
      WorkflowProposal.new!(
        "Create a file",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "patch", task: "Create lib/provider_blocked.ex."}
          )
        ],
        stop_conditions: ["file created"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: client,
               agent_review_gates?: false,
               child_noop_repair_attempts: 3,
               validation_opts: [allow_mutation?: true]
             )

    assert Elixir.Agent.get(calls, & &1) == 1

    assert [%ChildResult{metadata: metadata}] = result.context.child_results
    assert metadata.child_noop_repair_attempts == nil

    assert [evidence] = metadata.generation_evidence
    assert evidence.status == 429
    assert evidence.retryable? == false

    assert {:error, %Error{} = repair_error} =
             RepairLoop.run(result, environment,
               client: client,
               max_repair_iterations: 3
             )

    assert repair_error.message =~ "non-retryable generation failure"
    assert repair_error.details.generation_evidence.status == 429
    assert Elixir.Agent.get(calls, & &1) == 1
  end

  test "patch child retries locally after malformed apply_patch input" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)
    parent = self()

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      prompt_text = Enum.map_join(messages, "\n", &to_string(&1.content))

      cond do
        Enum.any?(messages, &(&1.role == :tool)) ->
          {:ok, TestClient.result("Changed files: lib/malformed_patch_repair.ex.")}

        String.contains?(prompt_text, "called apply_patch, but the patch failed") ->
          send(parent, :patch_repair_prompt_seen)

          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{
                     op: "create",
                     path: "lib/malformed_patch_repair.ex",
                     content: "defmodule MalformedPatchRepair, do: :ok\n"
                   }
                 ]
               },
               id: "repair_call"
             )
           ])}

        true ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{
                 operations: [
                   %{
                     op: "make_file",
                     path: "lib/malformed_patch_repair.ex",
                     body: "defmodule MalformedPatchRepair, do: :ok\n"
                   }
                 ]
               },
               id: "bad_patch_call"
             )
           ])}
      end
    end

    proposal =
      WorkflowProposal.new!(
        "Create a file after a malformed patch",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "patch", task: "Create lib/malformed_patch_repair.ex."}
          )
        ],
        stop_conditions: ["file created"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: client,
               agent_review_gates?: false,
               validation_opts: [allow_mutation?: true],
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    assert_receive :patch_repair_prompt_seen
    assert File.exists?(Path.join(root, "lib/malformed_patch_repair.ex"))

    assert [
             %ChildResult{
               status: :completed,
               changed_files: ["lib/malformed_patch_repair.ex"],
               metadata: %{child_patch_repair_attempts: 1}
             }
           ] = result.context.child_results

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(
             emitted,
             &match?(
               %{
                 stage: :child_patch_repair_started,
                 data: %{node_id: "child", attempt: 1, reason: :apply_patch_failed}
               },
               &1
             )
           )

    assert Enum.any?(
             emitted,
             &match?(
               %{
                 stage: :child_patch_repair_completed,
                 data: %{
                   node_id: "child",
                   changed_files: ["lib/malformed_patch_repair.ex"],
                   repaired?: true
                 }
               },
               &1
             )
           )
  end

  test "child runtime reserves downstream verification and repair budget" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent with repair",
        [
          ProposalNode.new!("implement", :agent,
            params: %{mode: "patch", task: "Implement Demo.answer/0"}
          ),
          ProposalNode.new!("repair", :agent,
            params: %{mode: "patch", task: "Repair missing objective evidence"}
          ),
          ProposalNode.new!("verify", :verification_gate,
            params: %{checks: [%{type: "file_exists", params: %{path: "lib/demo.ex"}}]}
          )
        ],
        edges: [%{from: "implement", to: "repair"}, %{from: "repair", to: "verify"}],
        stop_conditions: ["repair budget reserved"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(500)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:ok, _result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: slow_client,
               mode: :patch,
               validation_opts: [allow_mutation?: true, allow_verification?: true],
               max_runtime_ms: 1_000,
               child_runtime_mode_caps: %{patch: 900},
               child_progress_tick_ms: 50,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    budget_event =
      events
      |> Elixir.Agent.get(& &1)
      |> Enum.find(&match?(%{stage: :child_budget_selected, data: %{node_id: "implement"}}, &1))

    assert budget_event.data.downstream_reserve_ms > 0
    assert budget_event.data.selected_timeout_ms <= budget_event.data.requested_timeout_ms
  end

  test "workflow compiler emits live node lifecycle events during execution" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    proposal =
      WorkflowProposal.new!(
        "Ask a child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child answer returned"]
      )

    assert {:ok, _result} =
             WorkflowCompiler.run(proposal, environment, %{},
               client: TestClient.client("Demo.answer/0 returns 42."),
               run_id: "test-run",
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    emitted = Elixir.Agent.get(events, & &1)

    assert Enum.any?(emitted, &match?(%{stage: :node_started, data: %{node_id: "child"}}, &1))

    assert Enum.any?(
             emitted,
             &match?(
               %{
                 stage: :node_completed,
                 status: :ok,
                 data: %{node_id: "child", output: %{type: :child_result, status: :completed}}
               },
               &1
             )
           )

    assert Enum.any?(
             emitted,
             &match?(%{stage: :child_agent_completed, data: %{node_id: "child"}}, &1)
           )
  end

  test "workflow compiler records timed-out command nodes as partial episodes" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)

    proposal =
      WorkflowProposal.new!(
        "Run a command that times out",
        [
          ProposalNode.new!("wait", :command,
            params: %{
              args: %{
                argv: ["sh", "-c", ~S|printf "waiting"; sleep 10|]
              }
            }
          )
        ],
        stop_conditions: ["command timeout observed"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               command_policy:
                 RunicAI.Coding.CommandPolicy.new!(
                   allowed_commands: ["sh"],
                   timeout_ms: 300
                 ),
               validation_opts: [allow_commands?: true, allowed_commands: ["sh"]],
               event_sink: fn _event -> :ok end
             )

    assert [episode] = result.episodes
    assert episode.status == :partial
    assert result.output.status == :timeout
    assert hd(result.output.diagnostics).code == :timeout
  end

  test "agent repair loop patches and re-verifies an incomplete objective" do
    root = sample_project()

    repair_executor = fn workspace, _objective, _opts ->
      File.write!(
        Path.join(workspace.root, "lib/demo.ex"),
        "defmodule Demo do\n  def answer, do: 42\n  def repaired, do: true\nend\n"
      )

      {:ok,
       ChildResult.new!(:completed,
         id: "repair-test",
         changed_files: ["lib/demo.ex"],
         summary: "Added Demo.repaired/0"
       )}
    end

    assert {:ok, result} =
             Agent.run(root, "Add Demo.repaired/0",
               proposal: repair_marker_proposal(),
               repair?: true,
               repair_opts: [max_iterations: 1, executor: repair_executor]
             )

    assert result.repair_status == :satisfied
    assert RepairLoop.satisfied?(result)
    assert File.read!(Path.join(root, "lib/demo.ex")) =~ "def repaired"
  end

  test "repair child honors approve-all policy without repeated patch review gates" do
    root = sample_project()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)
    parent = self()

    client = fn _model, %RunicAI.Prompt{messages: messages}, _opts ->
      if Enum.any?(messages, &(&1.role == :tool)) do
        {:ok, TestClient.result("Changed files: lib/demo.ex. Verification: source repaired.")}
      else
        {:ok,
         TestClient.tool_response([
           TestClient.tool_call(
             "apply_patch",
             %{
               operations: [
                 %{
                   op: "delete",
                   path: "lib/demo.ex"
                 },
                 %{
                   op: "create",
                   path: "lib/demo.ex",
                   content:
                     "defmodule Demo do\n  def answer, do: 42\n  def repaired, do: true\nend\n"
                 }
               ]
             },
             id: "repair_apply_patch"
           )
         ])}
      end
    end

    review_decider = fn %ReviewRequest{} = request, context ->
      send(parent, {:unexpected_repair_review, request.resume_key, context})
      {:ok, Review.allow(request, reason: "unexpected review")}
    end

    assert {:ok, result} =
             Agent.run(root, "Add Demo.repaired/0",
               proposal: repair_marker_proposal(),
               client: client,
               approval: :always,
               repair?: true,
               repair_opts: [max_iterations: 1],
               review_decider: review_decider,
               event_sink: fn event -> Elixir.Agent.update(events, &(&1 ++ [event])) end
             )

    refute_receive {:unexpected_repair_review, _resume_key, _context}

    assert result.repair_status == :satisfied
    assert RepairLoop.satisfied?(result)
    assert File.read!(Path.join(root, "lib/demo.ex")) =~ "def repaired"

    refute Enum.any?(
             Elixir.Agent.get(events, & &1),
             &match?(
               %{
                 stage: :repair_attempt_completed,
                 status: :review
               },
               &1
             )
           )
  end

  test "repair loop records a structured OODA repair plan from failed command evidence" do
    root = sample_mix_project()

    File.write!(Path.join(root, "test/demo_test.exs"), """
    defmodule DemoTest do
      use ExUnit.Case

      test "repair marker" do
        assert Demo.repaired?()
      end
    end
    """)

    repair_executor = fn workspace, objective, _opts ->
      assert objective =~ "Structured repair plan"
      assert objective =~ "observed_failure"
      assert objective =~ "verification_command"
      assert objective =~ "mix test"
      assert objective =~ "Command-first repair focus"
      assert objective =~ "Reproduce this failed command first: mix test"
      assert objective =~ "Command output preview"
      assert objective =~ "make the project compile before"
      assert objective =~ "Patch the smallest source or test slice"

      File.write!(
        Path.join(workspace.root, "lib/demo.ex"),
        "defmodule Demo do\n  def answer, do: 42\n  def repaired?, do: true\nend\n"
      )

      {:ok,
       ChildResult.new!(:completed,
         id: "command-repair-test",
         changed_files: ["lib/demo.ex"],
         summary: "Added Demo.repaired?/0"
       )}
    end

    parent = self()

    assert {:ok, result} =
             Agent.run(root, "Repair Demo.repaired?/0 and prove mix test passes",
               proposal: command_repair_proposal(),
               mode: :patch,
               validation_opts: [allow_mutation?: true, allow_commands?: true],
               repair?: true,
               repair_opts: [max_iterations: 1, executor: repair_executor],
               event_sink: fn event -> send(parent, {:rlm_event, event}) end
             )

    assert result.repair_status == :satisfied

    [attempt] = result.context.repair_attempts
    repair_plan = attempt.metadata.repair_plan

    assert repair_plan.observed_failure =~ "mix test"
    assert repair_plan.hypothesis =~ "failed verification command"
    assert repair_plan.planned_edit =~ "test-command-passed"
    assert repair_plan.verification_command == "mix test"
    assert repair_plan.stop_condition =~ "All blocking acceptance checks pass"

    assert_receive {:rlm_event,
                    %{
                      stage: :repair_attempt_started,
                      data: %{repair_plan: ^repair_plan}
                    }}

    assert_receive {:rlm_event,
                    %{
                      stage: :completed,
                      status: :ok,
                      data: %{repair_status: :satisfied}
                    }}
  end

  test "repair loop salvages timed-out child changes and re-verifies" do
    root = sample_project()

    slow_executor = fn workspace, _objective, _opts ->
      File.write!(
        Path.join(workspace.root, "lib/demo.ex"),
        "defmodule Demo do\n  def answer, do: 42\n  def repaired, do: true\nend\n"
      )

      Process.sleep(1_000)
      {:ok, ChildResult.new!(:completed, id: "slow-repair", summary: "Eventually done")}
    end

    assert {:ok, result} =
             Agent.run(root, "Add Demo.repaired/0",
               proposal: repair_marker_proposal(),
               repair?: true,
               repair_opts: [
                 max_iterations: 1,
                 executor: slow_executor,
                 max_child_runtime_ms: 20
               ]
             )

    assert result.repair_status == :satisfied
    assert RepairLoop.satisfied?(result)

    [attempt] = result.context.repair_attempts
    assert attempt.status == :timeout
    assert attempt.child_result.status == :partial
    assert "lib/demo.ex" in attempt.changed_files
    assert File.read!(Path.join(root, "lib/demo.ex")) =~ "def repaired"
  end

  test "agent repair loop fails explicitly when the repair budget is exhausted" do
    root = sample_project()

    no_op_executor = fn _workspace, _objective, _opts ->
      {:ok, ChildResult.new!(:completed, id: "noop-repair", summary: "No changes made")}
    end

    assert {:error, error} =
             Agent.run(root, "Add Demo.repaired/0",
               proposal: repair_marker_proposal(),
               repair?: true,
               repair_opts: [max_iterations: 1, executor: no_op_executor]
             )

    assert error.kind == :validation
    assert error.message =~ "repair loop exhausted"
    assert error.details.repair_status == :exhausted
    assert error.details.iterations == 1
  end

  test "scorecards treat latest acceptance result as authoritative for repairs" do
    failed = %{
      id: "demo-repaired-source",
      type: :source_contains,
      status: :fail,
      required?: true,
      message: "missing def repaired",
      metadata: %{}
    }

    passed = %{failed | status: :pass, message: "found def repaired"}

    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: [failed, passed],
        child_results: [%{id: "repair:1", status: :partial}]
      )

    assert WorkflowScorecard.current_acceptance_results(scorecard.acceptance_results) == [passed]
    assert scorecard.objective_status == :objective_satisfied
  end

  test "scorecards do not mark failed child workflows satisfied from unrelated passing checks" do
    passed = %{
      id: "command-policy-note",
      type: :semantic_requirement,
      status: :pass,
      required?: true,
      message: "command policy was documented",
      metadata: %{}
    }

    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: [passed],
        child_results: [%{id: "implement", status: :failed}]
      )

    assert scorecard.objective_status == :failed
  end

  test "independent durable acceptance can supersede a failed child after repair" do
    source_pass = %{
      id: "implementation-present",
      type: :source_contains,
      status: :pass,
      required?: true,
      message: "source contains repaired implementation",
      metadata: %{}
    }

    test_pass = %{
      id: "tests-pass",
      type: :command_passes,
      status: :pass,
      required?: true,
      message: "command passed",
      metadata: %{command: ["mix", "test"]}
    }

    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: [source_pass, test_pass],
        child_results: [%{id: "implement", status: :failed}]
      )

    assert scorecard.objective_status == :objective_satisfied

    assert RunicAI.Coding.RLM.RepairController.from_scorecard(
             scorecard,
             scorecard.acceptance_results
           ) == []
  end

  test "scorecards let semantic acceptance supersede naming-variant heuristic failures" do
    source_name_mismatch = %{
      id: "public-facade-present",
      type: :source_contains,
      status: :fail,
      required?: true,
      message: "source is missing expected text",
      metadata: %{text: "schedule_work_order"}
    }

    semantic_pass = %{
      id: "semantic:public_facade",
      type: :semantic_requirement,
      status: :pass,
      required?: true,
      message: "public facade exposes scheduling operations",
      metadata: %{confidence: "high"}
    }

    compile_pass = %{
      id: "compile-passes-final",
      type: :command_passes,
      status: :pass,
      required?: true,
      message: "command passed",
      metadata: %{command: ["mix", "compile", "--warnings-as-errors"]}
    }

    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: [source_name_mismatch, semantic_pass, compile_pass],
        child_results: [%{id: "repair:1", status: :partial}]
      )

    assert WorkflowScorecard.blocking_acceptance_results(scorecard.acceptance_results) == []
    assert scorecard.objective_status == :objective_satisfied
  end

  test "child result marks explicit incomplete replies as partial" do
    child =
      RunicAI.Coding.RLM.ChildResult.from_agent_summary(%{
        status: :idle,
        reply: "I wasn’t able to complete the implementation because verification failed."
      })

    assert child.status == :partial
  end

  test "child result preserves review requests as needs_review control state" do
    request =
      ReviewRequest.new!(:tool_execution,
        checkpoint: :pre_tool,
        resume_key: "review:child:apply_patch",
        subject: %{tool_name: "apply_patch"},
        details: %{tool_name: "apply_patch"}
      )

    child =
      ChildResult.from_agent_summary(%{
        status: :review,
        latest_review_request: request,
        changed_files: [],
        tools_used: ["find_files", "apply_patch"]
      })

    assert child.status == :needs_review
    assert ChildResult.episode_status(child) == :blocked
    assert child.metadata.review_request.resume_key == "review:child:apply_patch"
    assert child.metadata.review_request.kind == :tool_execution
  end

  test "child result preserves raw generation evidence for operator diagnosis" do
    evidence = %{
      requested_model: "openai:gpt-5.6-terra",
      finish_reason: :stop,
      tool_choice: :required,
      tool_call_count: 0,
      usage: %{total_tokens: 120}
    }

    child =
      ChildResult.from_agent_summary(%{
        status: :idle,
        reply: "Unable to continue",
        generation_evidence: [evidence]
      })

    assert child.metadata.generation_evidence == [evidence]
  end

  test "plan patch validation enforces recursive expansion budgets" do
    patch =
      PlanPatch.new!(
        [
          PlanNode.new!("extra-1", :map_leaf),
          PlanNode.new!("extra-2", :map_leaf)
        ],
        metadata: %{depth: 2, patch_count: 1}
      )

    assert PlanPatchValidator.validate(patch, nil, max_patch_nodes: 2).status == :accepted
    assert PlanPatchValidator.validate(patch, nil, max_patch_nodes: 1).status == :rejected
  end

  test "script nodes are disabled by default by proposal validation" do
    proposal =
      WorkflowProposal.new!(
        "Try a helper script",
        [ProposalNode.new!("script", :script, params: %{script: "echo ok"})],
        stop_conditions: ["script output captured"]
      )

    assert WorkflowValidator.validate(proposal).status == :rejected

    assert WorkflowValidator.validate(proposal,
             allowed_kinds: ProposalNode.allowed_kinds(),
             allow_scripts?: true
           ).status == :accepted
  end

  test "script nodes execute through sandbox code execution when enabled" do
    root = sample_project()
    environment = CodebaseEnvironment.new!(root, index?: true)
    parent = self()

    proposal =
      WorkflowProposal.new!(
        "Run a helper script",
        [ProposalNode.new!("script", :script, params: %{script: "echo rlm-sandbox"})],
        stop_conditions: ["script output captured"]
      )

    assert {:ok, result} =
             WorkflowCompiler.run(proposal, environment, %{},
               validation_opts: [
                 allowed_kinds: ProposalNode.allowed_kinds(),
                 allow_scripts?: true
               ],
               allow_scripts?: true,
               tool_config: %{
                 code_execution: %{
                   backend: :just_bash,
                   session: :one_shot,
                   state_model: :one_shot,
                   transport_model: :in_process,
                   checkpoint_policy: %{mode: :none}
                 }
               },
               event_sink: fn event -> send(parent, {:sandbox_event, event}) end
             )

    assert result.output.status == :pass
    assert result.output.output == "rlm-sandbox\n"
    assert result.output.metadata.tool == :execute_code
    assert result.output.metadata.sandbox_backend == :just_bash
    assert result.output.metadata.sandbox_capability.state_model == :one_shot
    assert result.output.metadata.sandbox_capability.transport_model == :in_process
    assert result.output.metadata.sandbox_capability.checkpoint_policy == %{mode: :none}

    assert_receive {:sandbox_event, %{kind: :coding_sandbox_started}}
    assert_receive {:sandbox_event, %{kind: :coding_sandbox_completed, status: :pass}}
  end

  test "local workbench capability profile enables command script and edit proposal nodes" do
    proposal =
      WorkflowProposal.new!(
        "Use local workbench tools",
        [
          ProposalNode.new!("command", :command, params: %{argv: ["git", "status", "--short"]}),
          ProposalNode.new!("script", :script, params: %{script: "echo ok"}),
          ProposalNode.new!("edit", :edit,
            params: %{
              operations: [
                %{kind: "create_file", params: %{path: "tmp_marker.txt", content: "marker\n"}}
              ]
            }
          )
        ],
        stop_conditions: ["local workbench nodes accepted"]
      )

    assert WorkflowValidator.validate(proposal).status == :rejected

    report =
      WorkflowValidator.validate(proposal,
        profile: :local_workbench,
        toolsets: [:code_execution],
        mode: :verify
      )

    assert report.status == :accepted
  end

  test "verification gates require non-empty checks or contract" do
    proposal =
      WorkflowProposal.new!(
        "Empty verification gate",
        [ProposalNode.new!("gate", :verification_gate, params: %{checks: []})],
        stop_conditions: ["gate evaluated"]
      )

    report = WorkflowValidator.validate(proposal)

    assert report.status == :rejected
    assert Enum.any?(report.errors, &(&1.details.reason == :missing_verification_contract))
  end

  test "verification command checks require exact upstream command nodes" do
    gate =
      ProposalNode.new!("gate", :verification_gate,
        params: %{
          checks: [
            %{id: "tests", type: "command_passes", params: %{argv: ["mix", "test"]}}
          ]
        }
      )

    unbound =
      WorkflowProposal.new!(
        "Run tests",
        [gate],
        stop_conditions: ["tests pass"]
      )

    report = WorkflowValidator.validate(unbound)

    assert report.status == :rejected
    assert Enum.any?(report.errors, &(&1.details.reason == :unbound_verification_command))

    bound =
      WorkflowProposal.new!(
        "Run tests",
        [
          ProposalNode.new!("test", :command, params: %{args: %{argv: ["mix", "test"]}}),
          gate
        ],
        edges: [%{from: "test", to: "gate"}],
        stop_conditions: ["tests pass"]
      )

    assert WorkflowValidator.validate(bound,
             allow_commands?: true,
             allowed_commands: ["mix"]
           ).status == :accepted
  end

  test "progress gate includes changed files produced by child workflows" do
    root = sample_project()
    workspace = Workspace.new!(root: root)

    proposal =
      WorkflowProposal.new!(
        "Implement child-owned source changes",
        [ProposalNode.new!("child", :agent, params: %{mode: "patch", task: "implement"})],
        stop_conditions: ["implementation exists"]
      )

    child =
      ChildResult.new!(:partial,
        id: "child",
        changed_files: ["lib/demo.ex"],
        unresolved_risks: [
          "verification was not run",
          "turn ended with error: provider: transient"
        ]
      )

    result =
      ProgressGate.apply(
        %{
          proposal: proposal,
          context: %{workspace: workspace, changed_files: [], child_results: [child]},
          episodes: [],
          trace: []
        },
        mode: :patch,
        progress_policy: [lexical_coverage?: false]
      )

    assert result.objective_scorecard.changed_files == ["lib/demo.ex"]
    assert result.objective_scorecard.residual_risks == []

    assert Enum.any?(
             result.objective_scorecard.acceptance_results,
             &(&1.id == "progress-implementation-activity" and &1.status == :pass)
           )
  end

  test "reducers dedupe findings and derive repair needs from failed verification" do
    findings =
      Reducers.reduce_findings([
        Finding.new!("wrong return value", severity: :high, confidence: 0.9) |> elem_or_self(),
        Finding.new!("wrong return value", severity: :medium, confidence: 0.5) |> elem_or_self()
      ])

    assert length(findings) == 1
    assert hd(findings).severity == :high

    observations = [
      RunicAI.Coding.RLM.VerificationObservation.new!(:fail,
        command: ["mix", "test"],
        output_preview: "1 failure"
      )
    ]

    assert [%RunicAI.Coding.RLM.RepairNeed{}] = Reducers.repair_needs(observations)
  end

  test "report reducer formats file tool outputs as markdown instead of inspected maps" do
    report =
      Reducers.reduce(:report, [
        %{
          count: 1,
          files: [
            %{
              path: "README.md",
              byte_size: 14,
              truncated?: false,
              content: "# Demo\n\nhello"
            }
          ]
        }
      ])

    assert report =~ "## File output"
    assert report =~ "### `README.md`"
    assert report =~ "```markdown\n# Demo\n\nhello\n```"
    refute report =~ "%{"
    refute report =~ "\\n"
  end

  test "codex JSONL events normalize into coding RLM artifacts" do
    jsonl = ~s({"type":"message","content":"working"}\n{"type":"result","message":"done"}\n)

    assert {:ok, artifacts} = Agent.codex_events_to_artifacts(jsonl)
    assert Enum.map(artifacts, & &1.kind) == [:codex_event, :codex_event]
  end

  test "agent persists run snapshots when workspace persistence is configured" do
    root = sample_project()
    {:ok, store} = InMemory.start_link()
    workspace = Workspace.new!(root: root, persistence: {InMemory, store})

    assert {:ok, result} =
             Agent.run(workspace, "Where is Demo.answer/0?",
               command: :repo_qa,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert is_binary(result.persistence_ref)
    assert Enum.any?(InMemory.events(store), &(&1.kind == :rlm_coding_checkpoint))
    assert Enum.any?(InMemory.events(store), &(&1.kind == :rlm_coding_run_persisted))
    assert Enum.any?(InMemory.artifacts(store), &(&1.kind == :rlm_coding_checkpoint))
    assert Enum.any?(InMemory.artifacts(store), &(&1.kind == :rlm_coding_run))
    assert {:ok, [snapshot]} = Agent.search_sessions({InMemory, store}, "Demo.answer")
    assert {:ok, replay} = Agent.replay_session(snapshot)
    assert replay.status == :replayed
    assert replay.node_ids == ["discover", "read", "answer"]
    assert replay.artifact_count == length(result.episodes)
    assert replay.checkpoint_refs != []
  end

  test "deterministic RLM coding eval fixtures report proposals and source refs" do
    root = sample_project()

    run =
      RunicAI.Coding.RLM.Evals.run(RunicAI.Coding.RLM.Evals.cases(workspace: root),
        client: TestClient.client("child ok")
      )

    assert run.aggregate.cases == 3
    assert run.aggregate.passed == 3
    assert Enum.all?(run.results, &Map.has_key?(&1, :accepted_graph))
    assert Enum.all?(run.results, &Map.has_key?(&1, :source_refs))
  end

  defp sample_project do
    root =
      Path.join(System.tmp_dir!(), "runic-ai-rlm-coding-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def answer, do: 42\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp sample_mix_project do
    root =
      Path.join(System.tmp_dir!(), "runic-ai-rlm-coding-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project

      def project do
        [app: :demo, version: "0.1.0", elixir: "~> 1.15"]
      end
    end
    """)

    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\n  def answer, do: 42\nend\n")
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/demo_test.exs"), """
    defmodule DemoTest do
      use ExUnit.Case

      test "answer" do
        assert Demo.answer() == 42
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp sample_scaffold_mix_project do
    root =
      Path.join(System.tmp_dir!(), "runic-ai-rlm-coding-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule FieldServiceReviewApproval.MixProject do
      use Mix.Project

      def project do
        [app: :field_service_review_approval, version: "0.1.0", elixir: "~> 1.15"]
      end
    end
    """)

    File.write!(
      Path.join(root, "lib/field_service_review_approval.ex"),
      "defmodule FieldServiceReviewApproval do\n  def hello, do: :world\nend\n"
    )

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/field_service_review_approval_test.exs"), """
    defmodule FieldServiceReviewApprovalTest do
      use ExUnit.Case

      test "greets the world" do
        assert FieldServiceReviewApproval.hello() == :world
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp repair_marker_proposal do
    WorkflowProposal.new!(
      "Add Demo.repaired/0",
      [
        ProposalNode.new!("verify-repaired", :verification_gate,
          params: %{
            checks: [
              %{
                id: "demo-repaired-source",
                type: "source_contains",
                params: %{path: "lib/demo.ex", text: "def repaired"}
              }
            ]
          }
        )
      ],
      stop_conditions: ["Demo.repaired/0 is present in source"]
    )
  end

  defp command_repair_proposal do
    WorkflowProposal.new!(
      "Repair Demo.repaired?/0 and prove mix test passes",
      [
        ProposalNode.new!("test_project", :command,
          params: %{
            args: %{
              argv: ["mix", "test"],
              metadata: %{safe?: true, requires_review?: false}
            }
          }
        ),
        ProposalNode.new!("verify-repaired", :verification_gate,
          params: %{
            checks: [
              %{
                id: "demo-repaired-source",
                type: "source_contains",
                params: %{path: "lib/demo.ex", text: "def repaired?"}
              },
              %{
                id: "test-command-passed",
                type: "command_passes",
                params: %{argv: ["mix", "test"]}
              }
            ]
          }
        )
      ],
      edges: [%{from: "test_project", to: "verify-repaired"}],
      stop_conditions: ["Demo.repaired?/0 is present and mix test passes"]
    )
  end

  defp elem_or_self({:ok, value}), do: value
  defp elem_or_self(value), do: value
end
