defmodule RunicAI.Assistant.RLMBlueprintTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.FunctionBlueprint
  alias RunicAI.Assistant.RLM.RepairLoop
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.SandboxSessionRegistry
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.LLM.TestClient
  alias RunicAI.RLM.ComponentRuntime
  alias RunicAI.ReviewDecision
  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentCatalog

  test "constructs and validates a workflow blueprint" do
    split = ComponentBlueprint.new!("split", :source_splitter)
    write = ComponentBlueprint.new!("write", :artifact_writer, params: %{path: ".docs/out.md"})

    blueprint =
      WorkflowBlueprint.new!("Write report", [split, write],
        id: "assistant-test",
        sources: ["tmp/source.md"],
        edges: [%{from: "split", to: "write"}],
        stop_conditions: ["artifact written"]
      )

    assert blueprint.id == "assistant-test"
    assert [%{path: "tmp/source.md"}] = blueprint.sources
    assert {:ok, report} = BlueprintValidator.validate(blueprint)
    assert report.status == :accepted
  end

  test "prompt includes generated component catalog candidates when provided" do
    workspace = Workspace.new!(root: tmp_dir())
    store = generated_component_catalog_store()

    prompt =
      Coordinator.prompt("Normalize invoice rows", workspace,
        generated_component_catalog: store,
        generated_component_intent_tags: [:parse, :normalize],
        generated_component_inputs: [%{name: "rows"}],
        generated_component_outputs: [%{name: "invoice_facts"}],
        generated_component_kind: :sandbox_execute,
        generated_component_runtime: :python,
        generated_component_policy: %{network: :disabled}
      )

    assert prompt =~ "Generated component catalog context"
    assert prompt =~ "generated:invoice-normalizer"
    assert prompt =~ "Prefer an exact catalog candidate"
    assert prompt =~ "capability gap decision"
  end

  test "notifies caller when coordinator selects a generated component catalog entry" do
    workspace = Workspace.new!(root: tmp_dir())
    store = generated_component_catalog_store()
    parent = self()

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Normalize invoice rows",
               generated_component_catalog: store,
               generated_component_intent_tags: [:parse, :normalize],
               generated_component_inputs: [%{name: "rows"}],
               generated_component_outputs: [%{name: "invoice_facts"}],
               generated_component_kind: :sandbox_execute,
               generated_component_runtime: :python,
               generated_component_policy: %{network: :disabled},
               generated_component_catalog_reuse_callback: fn event ->
                 send(parent, {:catalog_reuse, event})
                 :ok
               end,
               validate?: false
             )

    assert blueprint.metadata.proposal_kind == :generated_component_catalog_reuse

    assert_receive {:catalog_reuse,
                    %{
                      type: :generated_component_catalog_reuse_selected,
                      entry_id: "generated:invoice-normalizer",
                      score: score,
                      reasons: reasons
                    }}

    assert score > 0
    assert :intent_tags_exact in reasons
  end

  test "rejects duplicate ids, unknown edges, and missing stop conditions" do
    blueprint =
      WorkflowBlueprint.new!(
        "Bad graph",
        [
          ComponentBlueprint.new!("same", :source_splitter),
          ComponentBlueprint.new!("same", :llm_map)
        ],
        edges: [%{from: "missing", to: "same"}],
        stop_conditions: []
      )

    report = BlueprintValidator.report(blueprint)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :duplicate_component_ids))
    assert Enum.any?(report.diagnostics, &(&1.code == :unknown_edge_source))
    assert Enum.any?(report.diagnostics, &(&1.code == :missing_stop_conditions))
  end

  test "rejects artifact writers without concrete paths" do
    blueprint =
      WorkflowBlueprint.new!(
        "Write report",
        [
          ComponentBlueprint.new!("compose", :report_composer),
          ComponentBlueprint.new!("write", :artifact_writer, params: %{path: nil})
        ],
        edges: [%{from: "compose", to: "write"}],
        stop_conditions: ["artifact written"]
      )

    report = BlueprintValidator.report(blueprint)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :invalid_artifact_writer_path))
  end

  test "runtime repair removes blank artifact writers when no output path was requested" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Summarize",
        [
          ComponentBlueprint.new!("compose", :report_composer),
          ComponentBlueprint.new!("write", :artifact_writer, params: %{path: nil}),
          ComponentBlueprint.new!("score", :objective_scorecard)
        ],
        edges: [%{from: "compose", to: "write"}, %{from: "write", to: "score"}],
        stop_conditions: ["artifact written", "objective scorecard checked"]
      )

    error =
      Error.validation("artifact writer requires a non-empty path",
        details: %{path: nil}
      )

    assert {:ok, repair} = RepairLoop.runtime_repair(workspace, "Summarize", blueprint, error)

    assert repair.strategy == :runtime_diagnostic_repair
    assert Enum.map(repair.blueprint.components, & &1.id) == ["compose", "score"]
    assert repair.blueprint.edges == [%{from: "compose", to: "score"}]
    assert "final assistant output produced" in repair.blueprint.stop_conditions
    assert {:ok, report} = BlueprintValidator.validate(repair.blueprint)
    assert report.status == :accepted
  end

  test "rejects generated functions above policy tier" do
    function = FunctionBlueprint.new!(:tier2, source: "fn input -> input end")

    blueprint =
      WorkflowBlueprint.new!(
        "Transform",
        [
          ComponentBlueprint.new!("transform", :blueprint_transform,
            params: %{function: function}
          )
        ],
        stop_conditions: ["transformed"]
      )

    report = BlueprintValidator.report(blueprint, max_generated_function_tier: :tier1)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :function_tier_rejected))
  end

  test "tool_leaf components validate against the active capability profile" do
    blueprint =
      WorkflowBlueprint.new!(
        "Check sandbox status",
        [ComponentBlueprint.new!("sandbox", :tool_leaf, params: %{tool: "sandbox_status"})],
        stop_conditions: ["sandbox status returned"]
      )

    assert BlueprintValidator.report(blueprint,
             profile: :local_workbench,
             toolsets: [:code_execution]
           ).status == :accepted

    report = BlueprintValidator.report(blueprint, profile: :safe)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :toolset_disabled))

    disabled_report =
      BlueprintValidator.report(blueprint,
        profile: :local_workbench,
        toolsets: [:code_execution],
        disabled_tools: ["sandbox_status"]
      )

    assert disabled_report.status == :rejected
    assert Enum.any?(disabled_report.diagnostics, &(&1.code == :toolset_disabled))
  end

  test "tool_leaf runtime executes visible tools through the capability registry" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Check sandbox status",
        [ComponentBlueprint.new!("sandbox", :tool_leaf, params: %{tool: "sandbox_status"})],
        stop_conditions: ["sandbox status returned"]
      )

    {:ok, runtime} =
      ComponentRuntime.initial_context(workspace, blueprint,
        profile: :local_workbench,
        toolsets: [:code_execution]
      )

    component = hd(blueprint.components)

    assert {:ok, status} = ComponentRuntime.execute_node(component, %{}, runtime)
    assert status.default_backend == :just_bash
    assert [%{name: :just_bash}] = status.backends
  end

  test "sandbox components validate against the active capability profile" do
    {:ok, sandbox_sessions} = SandboxSessionRegistry.start_link()

    blueprint =
      WorkflowBlueprint.new!(
        "Run sandbox code",
        [
          ComponentBlueprint.new!("status", :sandbox_status),
          ComponentBlueprint.new!("execute", :sandbox_execute,
            params: %{runtime: :bash, code: "echo sandboxed"}
          )
        ],
        edges: [%{from: "status", to: "execute"}],
        stop_conditions: ["sandbox code returned"]
      )

    assert BlueprintValidator.report(blueprint,
             profile: :local_workbench,
             toolsets: [:code_execution]
           ).status == :accepted

    report = BlueprintValidator.report(blueprint, profile: :safe)

    assert report.status == :rejected
    assert Enum.any?(report.diagnostics, &(&1.code == :toolset_disabled))

    disabled_report =
      BlueprintValidator.report(blueprint,
        profile: :local_workbench,
        toolsets: [:code_execution],
        disabled_tools: ["execute_code"]
      )

    assert disabled_report.status == :rejected

    assert Enum.any?(
             disabled_report.diagnostics,
             &(&1.code == :toolset_disabled and &1.details.tool_name == "execute_code")
           )

    stateful =
      WorkflowBlueprint.new!(
        "Use stateful sandbox",
        [
          ComponentBlueprint.new!("open", :sandbox_open_session),
          ComponentBlueprint.new!("exec", :sandbox_session_exec,
            params: %{runtime: :bash, code: "echo stateful"}
          ),
          ComponentBlueprint.new!("service", :sandbox_start_service,
            params: %{spec: %{name: "web"}}
          ),
          ComponentBlueprint.new!("proxy", :sandbox_open_proxy)
        ],
        edges: [
          %{from: "open", to: "exec"},
          %{from: "open", to: "service"},
          %{from: "service", to: "proxy"}
        ],
        stop_conditions: ["sandbox code returned"]
      )

    assert BlueprintValidator.report(stateful,
             profile: :local_workbench,
             toolsets: [:code_execution],
             sandbox_session_registry: sandbox_sessions
           ).status == :accepted
  end

  test "sandbox_execute runtime executes through the reviewed capability registry" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Run sandbox code",
        [
          ComponentBlueprint.new!("execute", :sandbox_execute,
            params: %{runtime: :bash, code: "echo component"}
          )
        ],
        stop_conditions: ["sandbox code returned"]
      )

    {:ok, runtime} =
      ComponentRuntime.initial_context(workspace, blueprint,
        profile: :local_workbench,
        toolsets: [:code_execution],
        review_decider: fn request, _context ->
          assert request.details.tool_name == "execute_code"
          assert request.details.code_preview == "echo component"
          {:ok, ReviewDecision.new!(request.resume_key, :approved)}
        end
      )

    component = hd(blueprint.components)

    assert {:ok, result} = ComponentRuntime.execute_node(component, %{}, runtime)
    assert result.status == :pass
    assert result.output == "component\n"
    assert result.metadata.tool == :execute_code
  end

  test "artifact writer review denials preserve the review request in runtime errors" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Write reviewed artifact",
        [
          ComponentBlueprint.new!("write", :artifact_writer,
            params: %{path: ".docs/out.md", write_policy: :docs_only}
          )
        ],
        stop_conditions: ["artifact written"]
      )

    {:ok, runtime} =
      ComponentRuntime.initial_context(workspace, blueprint,
        run_id: "assistant:test-review-denial",
        review_decider: fn request, _context ->
          {:ok, ReviewDecision.new!(request.resume_key, :cancelled)}
        end
      )

    component = hd(blueprint.components)

    assert {:error, %Error{} = error} =
             ComponentRuntime.execute_node(component, "Reviewed report", runtime)

    assert error.details.resume_key ==
             "review:artifact_writer:assistant:test-review-denial:.docs/out.md"

    assert error.details.review_request.resume_key == error.details.resume_key
    assert error.details.review_request.kind == :assistant_artifact_write
    assert error.details.review_request.checkpoint == :pre_write
  end

  test "sandbox session components execute through reviewed stateful tools" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)
    {:ok, sandbox_sessions} = SandboxSessionRegistry.start_link()

    blueprint =
      WorkflowBlueprint.new!(
        "Run stateful sandbox code",
        [
          ComponentBlueprint.new!("open", :sandbox_open_session),
          ComponentBlueprint.new!("exec", :sandbox_session_exec,
            params: %{runtime: :bash, code: "echo component-session"}
          ),
          ComponentBlueprint.new!("close", :sandbox_close_session)
        ],
        edges: [%{from: "open", to: "exec"}, %{from: "exec", to: "close"}],
        stop_conditions: ["sandbox session closed"]
      )

    review_decider = fn request, _context ->
      assert request.details.tool_name in ["open_sandbox_session", "sandbox_exec"]
      {:ok, ReviewDecision.new!(request.resume_key, :approved)}
    end

    {:ok, runtime} =
      ComponentRuntime.initial_context(workspace, blueprint,
        profile: :local_workbench,
        toolsets: [:code_execution],
        sandbox_session_registry: sandbox_sessions,
        review_decider: review_decider
      )

    [open, exec, close] = blueprint.components

    assert {:ok, opened} = ComponentRuntime.execute_node(open, %{}, runtime)
    assert opened.id =~ "sandbox_session_"

    assert {:ok, result} = ComponentRuntime.execute_node(exec, opened, runtime)
    assert result.status == :pass
    assert result.stdout == "component-session\n"

    assert {:ok, closed} = ComponentRuntime.execute_node(close, result, runtime)
    assert closed.status == :closed
  end

  test "round-trips generated blueprints through JSON-safe maps" do
    blueprint =
      WorkflowBlueprint.new!("Round trip", [ComponentBlueprint.new!("split", "source_splitter")],
        sources: [%{"id" => "chapter", "path" => "tmp/chapter.md"}],
        stop_conditions: ["done"]
      )

    json = Jason.encode!(blueprint)
    decoded = Jason.decode!(json)

    assert {:ok, decoded_blueprint} = WorkflowBlueprint.from_input(decoded)
    assert decoded_blueprint.objective == "Round trip"
    assert hd(decoded_blueprint.components).type == :source_splitter
  end

  test "coordinator accepts a generated non-report workflow blueprint" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n))
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      blueprint =
        %{
          id: "assistant:ticket_clusters",
          objective: "Cluster tickets",
          sources: [%{id: "tickets", path: "tickets.jsonl"}],
          components: [
            %{id: "discover", type: "source_discovery", params: %{paths: ["tickets.jsonl"]}},
            %{id: "parse", type: "tabular_parser", params: %{format: "jsonl"}},
            %{id: "group", type: "record_group", params: %{group_by: "theme"}},
            %{id: "compose", type: "report_composer", params: %{title: "Ticket Themes"}},
            %{id: "write", type: "artifact_writer", params: %{path: ".docs/tickets.md"}},
            %{
              id: "score",
              type: "objective_scorecard",
              params: %{artifact_path: ".docs/tickets.md"}
            }
          ],
          edges: [
            %{from: "discover", to: "parse"},
            %{from: "parse", to: "group"},
            %{from: "group", to: "compose"},
            %{from: "compose", to: "write"},
            %{from: "write", to: "score"}
          ],
          stop_conditions: ["artifact written", "scorecard satisfied"],
          policies: %{generated_functions: %{max_tier: "tier1"}, budgets: %{max_nodes: 12}},
          metadata: %{proposal_kind: "model_proposed"}
        }

      {:ok, TestClient.result(Jason.encode!(blueprint))}
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Cluster tickets",
               input_paths: ["tickets.jsonl"],
               output_path: ".docs/tickets.md",
               proposal_strategy: :dynamic,
               client: client,
               model: "test:model"
             )

    assert Enum.map(blueprint.components, & &1.type) == [
             :source_discovery,
             :tabular_parser,
             :record_group,
             :report_composer,
             :artifact_writer,
             :objective_scorecard
           ]

    score = Enum.find(blueprint.components, &(&1.type == :objective_scorecard))
    assert score.params["artifact_path"] == ".docs/tickets.md"
    refute Map.has_key?(score.params, :artifact_path)
    assert blueprint.metadata["proposal_kind"] == :generated
    refute Map.has_key?(blueprint.metadata, :proposal_kind)
  end

  test "coordinator prefers curated ticket clustering recipe for common tabular tasks" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"ticket":"T1","theme":"login"}\n))
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      flunk("curated recipe should not call the blueprint generation client")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Cluster support tickets by theme",
               input_paths: ["tickets.jsonl"],
               output_path: ".docs/tickets.md",
               client: client,
               model: "test:model"
             )

    assert blueprint.metadata.proposal_kind == :curated_recipe
    assert blueprint.metadata.recipe == :parse_normalize_report

    assert %{type: :record_group, params: params} =
             Enum.find(blueprint.components, &(&1.type == :record_group))

    assert params.group_by == "theme"
    assert params.dedupe_by == ["ticket_id", "ticket", "id"]
  end

  test "coordinator routed proposal mode records strategy and skips LLM graph synthesis" do
    root = tmp_dir()
    File.write!(Path.join(root, "a.md"), "alpha\n")
    File.write!(Path.join(root, "b.md"), "beta\n")
    File.write!(Path.join(root, "c.md"), "gamma\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      flunk("routed strategy should use a conservative evidence slice before LLM graph synthesis")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Extract risks from these files and write a report",
               input_paths: ["a.md", "b.md", "c.md"],
               proposal_strategy: :routed,
               client: client,
               model: "test:model"
             )

    assert blueprint.metadata.proposal_kind == :routed_strategy
    assert blueprint.metadata.strategy_route.strategy == :lambda_workflow
    assert blueprint.metadata.strategy_route.fallback == :subagent_delegation
    assert blueprint.metadata.strategy_route.budgets.max_leaf_calls >= 9
    assert Enum.any?(blueprint.components, &(&1.type == :llm_map))
    assert Enum.any?(blueprint.components, &(&1.type == :objective_scorecard))
  end

  test "coordinator evidence-first proposal mode aliases routed least-powerful planning" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n))
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      flunk("evidence-first planning should not synthesize a full workflow graph first")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Build a reusable parser component for these records",
               input_paths: ["tickets.jsonl"],
               proposal_strategy: :evidence_first,
               repeated_transform?: true,
               client: client,
               model: "test:model"
             )

    assert blueprint.metadata.proposal_kind == :routed_strategy
    assert blueprint.metadata.strategy_route.strategy == :generated_sandbox_component
    assert blueprint.metadata.strategy_route.fallback == :sandbox_repl
    assert Enum.any?(blueprint.components, &(&1.type == :tabular_parser))
  end

  test "coordinator defaults to evidence-first routing before dynamic graph synthesis" do
    root = tmp_dir()
    File.write!(Path.join(root, "a.md"), "alpha\n")
    File.write!(Path.join(root, "b.md"), "beta\n")
    File.write!(Path.join(root, "c.md"), "gamma\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, _prompt, _opts ->
      flunk("default coordinator path should gather evidence before full graph synthesis")
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Extract risks from these files and write a report",
               input_paths: ["a.md", "b.md", "c.md"],
               client: client,
               model: "test:model"
             )

    assert blueprint.metadata.proposal_kind == :routed_strategy
    assert blueprint.metadata.strategy_route.strategy == :lambda_workflow
    assert Enum.any?(blueprint.components, &(&1.type == :llm_map))
  end

  test "coordinator exposes deterministic routing decisions" do
    workspace = Workspace.new!(root: tmp_dir())

    decision =
      Coordinator.route(workspace, "Build a reusable parser component for these CSV exports",
        repeated_transform?: true
      )

    assert decision.strategy == :generated_sandbox_component
    assert decision.fallback == :sandbox_repl
    assert decision.metadata.workspace_root == workspace.root
  end

  test "coordinator prepares explicit component-builder subagent assignments" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:ok, assignment} =
             Coordinator.component_builder_assignment(
               workspace,
               "Build a reusable parser component for these CSV exports",
               id: "assignment:component-builder",
               run_id: "run:parent",
               max_sandbox_executions: 3
             )

    assert assignment.id == "assignment:component-builder"
    assert assignment.role == "component_builder"
    assert assignment.strategy == :generated_sandbox_component
    assert assignment.agent_kind == :workflow
    assert assignment.capability_profile == :local_workbench

    assert assignment.visible_tools == [
             "open_sandbox_session",
             "sandbox_write_file",
             "sandbox_exec",
             "sandbox_read_file",
             "sandbox_list_files",
             "close_sandbox_session"
           ]

    assert assignment.budgets.max_sandbox_executions == 3
    assert assignment.budgets.require_tests?
    assert assignment.review_policy.network == :disabled
    assert assignment.review_policy.host_materialization == :requires_review

    assert assignment.output_schema.required == [
             "generated_component",
             "source_artifacts",
             "test_artifacts",
             "verification",
             "claims"
           ]

    assert assignment.parent.run_id == "run:parent"
    assert assignment.parent.strategy == :generated_sandbox_component
    assert assignment.parent.fallback == :sandbox_repl
    assert assignment.metadata.assignment_kind == :component_builder
    assert assignment.metadata.generated_component_policy.require_contract_first?
    assert assignment.prompt =~ "Propose the component contract before writing code"
    assert assignment.prompt =~ "Do not materialize code into the host repository"
  end

  test "coordinator repairs invalid generated blueprint diagnostics" do
    root = tmp_dir()
    File.write!(Path.join(root, "input.md"), "hello\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, prompt, _opts ->
      blueprint =
        if prompt =~ "repairing an invalid" do
          %{
            id: "assistant:repaired",
            objective: "Write report",
            sources: [%{id: "input", path: "input.md"}],
            components: [
              %{id: "split", type: "source_splitter", params: %{}},
              %{id: "compose", type: "report_composer", params: %{title: "Report"}},
              %{id: "score", type: "objective_scorecard", params: %{}}
            ],
            edges: [%{from: "split", to: "compose"}, %{from: "compose", to: "score"}],
            stop_conditions: ["scorecard satisfied"],
            policies: %{generated_functions: %{max_tier: "tier1"}},
            metadata: %{}
          }
        else
          %{
            id: "assistant:bad",
            objective: "Write report",
            components: [%{id: "split", type: "source_splitter", params: %{}}],
            edges: [%{from: "missing", to: "split"}],
            stop_conditions: ["done"],
            policies: %{},
            metadata: %{}
          }
        end

      {:ok, TestClient.result(Jason.encode!(blueprint))}
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Write report",
               input_paths: ["input.md"],
               proposal_strategy: :dynamic,
               client: client,
               model: "test:model",
               fallback?: false
             )

    assert blueprint.id == "assistant:repaired"
    assert blueprint.metadata.proposal_kind == :validation_repair
  end

  test "coordinator repair prompt accepts diagnostics containing nested errors" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)
    parent = self()

    client = fn _model, prompt, _opts ->
      blueprint =
        if prompt =~ "repairing an invalid" do
          send(parent, {:repair_prompt, prompt})

          %{
            id: "assistant:repaired_function",
            objective: "Pick repos",
            components: [
              %{
                id: "respond",
                type: "llm_leaf",
                params: %{
                  strategy: "llm_reduce",
                  group_prompt: "Use {{input}}",
                  prompt: "Respond from {{items}}",
                  max_group_items: 1
                }
              },
              %{id: "score", type: "objective_scorecard", params: %{}}
            ],
            edges: [%{from: "respond", to: "score"}],
            stop_conditions: ["response produced"],
            policies: %{generated_functions: %{max_tier: "tier1"}},
            metadata: %{}
          }
        else
          %{
            id: "assistant:bad_function",
            objective: "Pick repos",
            components: [
              %{
                id: "bad_transform",
                type: "blueprint_transform",
                params: %{function: %{tier: "tier0"}}
              },
              %{id: "score", type: "objective_scorecard", params: %{}}
            ],
            edges: [%{from: "bad_transform", to: "score"}],
            stop_conditions: ["response produced"],
            policies: %{generated_functions: %{max_tier: "tier1"}},
            metadata: %{}
          }
        end

      {:ok, TestClient.result(Jason.encode!(blueprint))}
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Pick repos",
               proposal_strategy: :dynamic,
               client: client,
               model: "test:model",
               fallback?: false
             )

    assert blueprint.id == "assistant:repaired_function"
    assert_receive {:repair_prompt, prompt}
    assert prompt =~ "tier0 function blueprints require a built-in operation"
    refute prompt =~ "%RunicAI.Error{"
  end

  test "coordinator changes strategy instead of repairing the same invalid shape repeatedly" do
    root = tmp_dir()
    File.write!(Path.join(root, "schema.json"), ~s({"rows":[{"id":1}]}\n))
    workspace = Workspace.new!(root: root)

    client = fn _model, prompt, _opts ->
      if prompt =~ "repairing an invalid" do
        flunk("same-shape repair should be skipped after repeated failures")
      else
        blueprint = %{
          id: "assistant:bad-repeated-shape",
          objective: "Explore unknown schema",
          components: [%{id: "only", type: "source_splitter", params: %{}}],
          edges: [%{from: "missing", to: "only"}],
          stop_conditions: [],
          policies: %{},
          metadata: %{}
        }

        {:ok, TestClient.result(Jason.encode!(blueprint))}
      end
    end

    assert {:ok, blueprint} =
             Coordinator.propose(workspace, "Explore unknown schema and probe the data",
               proposal_strategy: :dynamic,
               input_paths: ["schema.json"],
               client: client,
               model: "test:model",
               fallback?: false,
               repair_attempts: 2
             )

    assert blueprint.metadata.proposal_kind == :strategy_change_repair
    assert blueprint.metadata.strategy_route.strategy == :sandbox_repl
    assert blueprint.metadata.rerouted_to == :subagent_delegation
    assert blueprint.metadata.repair_failure.message =~ "rejected"
    assert Enum.any?(blueprint.components, &(&1.type == :llm_map))
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-assistant-blueprint-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp generated_component_catalog_store do
    component =
      GeneratedComponent.new!(
        id: "generated:invoice-normalizer",
        name: "Invoice normalizer",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run",
        source_artifacts: [%{path: "component.py", ref: "source:invoice"}],
        test_artifacts: [%{path: "test_component.py", ref: "test:invoice"}],
        interface: %{
          inputs: [%{name: "rows", type: "list<object>"}],
          outputs: [%{name: "invoice_facts", type: "list<object>"}]
        },
        verification: %{status: :pass, command: "python -m pytest"},
        promotion_status: :verified,
        metadata: %{intent_tags: [:parse, :normalize], network: :disabled}
      )

    {:ok, entry} = GeneratedComponentCatalog.entry_from_component(component)
    GeneratedComponentCatalog.new_store!(entries: [entry])
  end
end
