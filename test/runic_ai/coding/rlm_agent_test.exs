defmodule RunicAI.Coding.RLMAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.RLM.Agent
  alias RunicAI.Coding.RLM.ChildResult
  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.Coordinator
  alias RunicAI.Coding.RLM.Finding
  alias RunicAI.Coding.RLM.PlanPatchValidator
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.Reducers
  alias RunicAI.Coding.RLM.RepairLoop
  alias RunicAI.Coding.RLM.WorkflowCompiler
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Coding.Workspace
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.LLM.TestClient
  alias RunicAI.RLM.PlanNode
  alias RunicAI.RLM.PlanPatch

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

  test "codebase environment indexes this repo in read-only mode" do
    assert {:ok, env} = CodebaseEnvironment.new(File.cwd!(), index?: true, file_limit: 30)

    assert Enum.any?(CodebaseEnvironment.source_summaries(env), &(&1.path == "AGENTS.md"))
  end

  test "coordinator uses structured proposal output and falls back when rejected" do
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
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert proposal.metadata.recipe == :repo_qa
    assert report.status == :accepted
  end

  test "coordinator falls back when structured proposal output is malformed" do
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

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain Demo", env,
               client: client,
               proposal_generation: :object,
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

    proposal =
      WorkflowProposal.new!(
        "Ask a slow child agent",
        [
          ProposalNode.new!("child", :agent,
            params: %{mode: "read_only", task: "Explain Demo.answer/0"}
          )
        ],
        stop_conditions: ["child answer returned"]
      )

    slow_client = fn _model, _prompt, _opts ->
      Process.sleep(1_000)
      {:ok, TestClient.result("eventually done")}
    end

    assert {:error, error} =
             Agent.run(root, "Ask a slow child agent",
               proposal: proposal,
               client: slow_client,
               max_runtime_ms: 20
             )

    assert error.kind == :timeout
    assert error.message == "RLM runtime budget exhausted"
    assert error.details.stage == :rlm_agent_run
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

  defp elem_or_self({:ok, value}), do: value
  defp elem_or_self(value), do: value
end
