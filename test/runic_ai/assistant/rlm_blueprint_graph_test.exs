defmodule RunicAI.Assistant.RLMBlueprintGraphTest do
  use ExUnit.Case, async: true

  alias Runic.Component
  alias Runic.Workflow
  alias RunicAI.Assistant.RLM.BlueprintGraph
  alias RunicAI.Assistant.RLM.BlueprintProposalPrompt
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.RLM.ComponentError
  alias RunicAI.RLM.ComponentCatalog
  alias RunicAI.RLM.ComponentFactory
  alias RunicAI.RLM.ComponentRuntime
  alias RunicAI.RLM.WorkflowExecutor
  alias RunicAI.RLM.WorkflowResults
  alias RunicAI.LLM.TestClient

  test "component catalog covers every assistant component type and compiles contracts" do
    assert ComponentBlueprint.types() == ComponentCatalog.types()

    manifest = BlueprintProposalPrompt.manifest()
    assert manifest.components == Enum.map(ComponentCatalog.types(), &Atom.to_string/1)

    for type <- ComponentCatalog.types() do
      component = ComponentBlueprint.new!("node_#{type}", type, params: params_for(type))

      assert {:ok, spec} = ComponentCatalog.spec_from_blueprint(component)
      assert spec.execution_shape in [:step, :side_effect_step, :map, :reduce]
      assert spec.inputs != []
      assert spec.outputs != []

      case spec.execution_shape do
        shape when shape in [:step, :side_effect_step] ->
          assert {:ok, runic_component} = ComponentFactory.to_runic(spec)
          assert Component.inputs(runic_component) == spec.inputs
          assert Component.outputs(runic_component) == spec.outputs

        :map ->
          item_step = ComponentFactory.map_items_step(spec, name: "items_#{spec.id}")
          assert Component.inputs(item_step) == spec.inputs

          assert {:ok, runic_component} =
                   ComponentFactory.native_map(spec, name: "map_#{spec.id}")

          assert Component.outputs(runic_component) != []

        :reduce ->
          assert {:ok, runic_component} =
                   ComponentFactory.native_reduce(spec, "map_parent", name: "reduce_#{spec.id}")

          assert Component.outputs(runic_component) != []
      end
    end
  end

  test "component catalog returns structured invalid parameter diagnostics" do
    component =
      ComponentBlueprint.new!("split", :source_splitter, params: %{max_bytes: 0})

    assert {:error, %Error{} = error} = ComponentCatalog.spec_from_blueprint(component)
    assert error.details.code == :invalid_component_params
    assert error.details.param == :max_bytes
  end

  test "blueprint graph uses Multigraph for roots leaves and batch order" do
    blueprint =
      WorkflowBlueprint.new!(
        "Branch",
        [
          ComponentBlueprint.new!("discover", :source_discovery),
          ComponentBlueprint.new!("split", :source_splitter),
          ComponentBlueprint.new!("parse", :tabular_parser),
          ComponentBlueprint.new!("compose", :report_composer)
        ],
        edges: [
          %{from: "discover", to: "split"},
          %{from: "discover", to: "parse"},
          %{from: "split", to: "compose"},
          %{from: "parse", to: "compose"}
        ],
        stop_conditions: ["composed"]
      )

    assert {:ok, graph} = BlueprintGraph.build(blueprint)

    assert Enum.map(graph.roots, & &1.id) == ["discover"]
    assert Enum.map(graph.leaves, & &1.id) == ["compose"]

    batch_ids = Enum.map(graph.batches, fn batch -> batch |> Enum.map(& &1.id) |> Enum.sort() end)
    assert ["parse", "split"] in batch_ids

    summary = BlueprintGraph.summary(graph)
    assert summary.roots == ["discover"]
    assert summary.leaves == ["compose"]
  end

  test "blueprint graph reports endpoint and cycle diagnostics" do
    duplicate =
      WorkflowBlueprint.new!(
        "Duplicate",
        [
          ComponentBlueprint.new!("same", :source_splitter),
          ComponentBlueprint.new!("same", :tabular_parser)
        ],
        stop_conditions: ["done"]
      )

    assert Enum.any?(
             BlueprintGraph.diagnostics(duplicate),
             &(&1.code == :duplicate_component_ids)
           )

    bad_endpoint =
      WorkflowBlueprint.new!(
        "Bad endpoint",
        [ComponentBlueprint.new!("split", :source_splitter)],
        edges: [%{from: "missing", to: "split"}],
        stop_conditions: ["done"]
      )

    assert Enum.any?(BlueprintGraph.diagnostics(bad_endpoint), &(&1.code == :unknown_edge_source))

    cycle =
      WorkflowBlueprint.new!(
        "Cycle",
        [
          ComponentBlueprint.new!("discover", :source_discovery),
          ComponentBlueprint.new!("split", :source_splitter)
        ],
        edges: [%{from: "discover", to: "split"}, %{from: "split", to: "discover"}],
        stop_conditions: ["done"]
      )

    assert Enum.any?(BlueprintGraph.diagnostics(cycle), &(&1.code == :cycle))
  end

  test "blueprint graph reports root leaf and isolated component diagnostics" do
    blueprint =
      WorkflowBlueprint.new!(
        "Branch",
        [
          ComponentBlueprint.new!("discover", :source_discovery),
          ComponentBlueprint.new!("split", :source_splitter),
          ComponentBlueprint.new!("unused", :report_composer)
        ],
        edges: [%{from: "discover", to: "split"}],
        stop_conditions: ["done"]
      )

    diagnostics =
      BlueprintGraph.diagnostics(blueprint, include_root_leaf_diagnostics?: true)

    assert Enum.any?(diagnostics, &(&1.code == :root_components))
    assert Enum.any?(diagnostics, &(&1.code == :leaf_components))

    assert Enum.any?(
             diagnostics,
             &(&1.code == :unreachable_component and &1.details.component_ids == ["unused"])
           )
  end

  test "workflow compiler stores runtime adapter context in Runic run_context" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Compile runtime context",
        [
          ComponentBlueprint.new!("split", :source_splitter),
          ComponentBlueprint.new!("compose", :report_composer),
          ComponentBlueprint.new!("write", :artifact_writer, params: %{path: ".docs/out.md"})
        ],
        edges: [%{from: "split", to: "compose"}, %{from: "compose", to: "write"}],
        stop_conditions: ["done"],
        policies: %{budgets: %{max_runtime_ms: 1_000}}
      )

    assert {:ok, compiled} = WorkflowCompiler.compile(blueprint, workspace)

    split_name = compiled.node_names["split"]
    split_step = Workflow.get_component(compiled.workflow, split_name)

    assert Function.info(split_step.work, :module) == {:module, ComponentRuntime}
    assert Function.info(split_step.work, :name) == {:name, :run}
    assert compiled.run_context_requirements[split_name] == [component: :required]
    assert Workflow.get_run_context(compiled.workflow, split_name).component.id == "split"
    assert Enum.any?(compiled.scheduler_policies, &match?({:default, %{timeout_ms: 1_000}}, &1))
  end

  test "workflow compiler rejects incompatible Runic port contracts" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Bad ports",
        [
          ComponentBlueprint.new!("produce_records", :source_discovery,
            outputs: [out: [type: :records]]
          ),
          ComponentBlueprint.new!("write", :artifact_writer,
            params: %{path: ".docs/out.md"},
            inputs: [in: [type: :artifact]]
          )
        ],
        edges: [%{from: "produce_records", to: "write"}],
        stop_conditions: ["done"]
      )

    assert {:error, %Error{} = error} = WorkflowCompiler.compile(blueprint, workspace)
    assert error.details.code == :port_type_mismatch
    assert error.details.component_id == "write"
  end

  test "workflow executor returns component errors as repairable diagnostics" do
    component = ComponentBlueprint.new!("split", :source_splitter)
    assert {:ok, spec} = ComponentCatalog.spec_from_blueprint(component)

    error = Error.validation("component failed", details: %{reason: :bad_input})

    assert {:ok, runic_component} =
             ComponentFactory.to_runic(spec,
               work: fn _input -> raise ComponentError, error: error, component: component end
             )

    workflow = Workflow.new(name: "failed_component") |> Workflow.add(runic_component)

    assert {:error, %Error{} = returned} = WorkflowExecutor.run(workflow, %{})
    assert returned.message == "component failed"
    assert returned.details.component_id == "split"
    assert returned.details.component_type == :source_splitter
  end

  test "workflow results extracts fact outputs from Runic productions" do
    component = ComponentBlueprint.new!("compose", :report_composer)
    assert {:ok, spec} = ComponentCatalog.spec_from_blueprint(component)

    output = %{text: "done"}

    assert {:ok, runic_component} =
             ComponentFactory.to_runic(spec,
               name: "compose",
               work: fn _input -> output end
             )

    workflow = Workflow.new(name: "results") |> Workflow.add(runic_component)
    assert {:ok, workflow} = WorkflowExecutor.run(workflow, %{})

    compiled = %{
      output_name: "compose",
      node_names: %{"compose" => "compose"},
      component_specs: [%{id: "compose", type: :report_composer, execution_shape: :step}]
    }

    extracted = WorkflowResults.extract(workflow, compiled)

    assert extracted.output == output
    assert extracted.intermediate_outputs == %{"compose" => output}
  end

  test "workflow compiler executes native Runic map and reduce facts asynchronously" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n{"theme":"billing"}\n))
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Summarize tickets",
        [
          ComponentBlueprint.new!("discover", :source_discovery,
            params: %{paths: ["tickets.jsonl"]}
          ),
          ComponentBlueprint.new!("parse", :tabular_parser, params: %{format: "jsonl"}),
          ComponentBlueprint.new!("map", :record_map,
            params: %{function: %{tier: :tier1, op: :pick, keys: ["theme"]}}
          ),
          ComponentBlueprint.new!("reduce", :blueprint_reduce, params: %{strategy: :join}),
          ComponentBlueprint.new!("compose", :report_composer)
        ],
        edges: [
          %{from: "discover", to: "parse"},
          %{from: "parse", to: "map"},
          %{from: "map", to: "reduce"},
          %{from: "reduce", to: "compose"}
        ],
        stop_conditions: ["report composed"]
      )

    assert {:ok, result} = WorkflowCompiler.run(blueprint, workspace, %{}, async: true)

    assert result.intermediate_outputs["map"].component_id == "map"
    assert result.intermediate_outputs["reduce"].count == 2
    assert result.output.text =~ "Assistant Report"

    assert result.execution_metrics.nodes_executed > 0
    assert result.execution_metrics.record_map_calls == 2
    assert result.execution_metrics.reduce_calls >= 1
    assert result.budget_summary.metrics.nodes_executed > 0
    assert result.budget_summary.metrics.record_map_calls == 2
    assert result.execution_metrics.component_counts["record_map"] == 1

    assert Enum.any?(
             result.native_nodes,
             &(&1.kind == :map and &1.production_count == 2)
           )

    assert result.compiled.graph_summary.runic.serializers.mermaid =~ "flowchart"
    assert is_list(result.compiled.graph_summary.runic.serializers.cytoscape)
  end

  test "native map scheduler policy limits concurrency and retries item calls" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n))
    workspace = Workspace.new!(root: root)
    parent = self()

    blueprint =
      WorkflowBlueprint.new!(
        "Retry tickets",
        [
          ComponentBlueprint.new!("discover", :source_discovery,
            params: %{paths: ["tickets.jsonl"]}
          ),
          ComponentBlueprint.new!("parse", :tabular_parser, params: %{format: "jsonl"}),
          ComponentBlueprint.new!("map", :record_map,
            params: %{prompt: "Classify {{record}}", max_concurrency: 1},
            policy: %{max_retries: 1, base_delay_ms: 0}
          ),
          ComponentBlueprint.new!("reduce", :blueprint_reduce)
        ],
        edges: [
          %{from: "discover", to: "parse"},
          %{from: "parse", to: "map"},
          %{from: "map", to: "reduce"}
        ],
        stop_conditions: ["done"]
      )

    assert {:ok, compiled} = WorkflowCompiler.compile(blueprint, workspace)

    map_policy =
      Enum.find_value(compiled.scheduler_policies, fn
        {{:name, regex}, policy} ->
          if Regex.match?(regex, compiled.node_names["map"]), do: policy

        _other ->
          nil
      end)

    assert map_policy.max_retries == 1
    assert Keyword.fetch!(map_policy.executor_opts, :max_concurrency) == 1

    {:ok, call_count} = Elixir.Agent.start_link(fn -> 0 end)

    client = fn _model, _prompt, _opts ->
      call = Elixir.Agent.get_and_update(call_count, &{&1, &1 + 1})
      send(parent, {:client_call, call})

      if call == 0 do
        {:error, Error.validation("transient map failure")}
      else
        {:ok, TestClient.result("classified")}
      end
    end

    assert {:ok, result} =
             WorkflowCompiler.run(blueprint, workspace, %{}, client: client, async: true)

    assert result.output.count == 1
    assert result.execution_metrics.record_map_calls == 1
    assert Elixir.Agent.get(call_count, & &1) == 2
    assert_receive {:client_call, 0}
    assert_receive {:client_call, 1}
  end

  test "native map item failures return repairable runnable diagnostics" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n))
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Summarize tickets",
        [
          ComponentBlueprint.new!("discover", :source_discovery,
            params: %{paths: ["tickets.jsonl"]}
          ),
          ComponentBlueprint.new!("parse", :tabular_parser, params: %{format: "jsonl"}),
          ComponentBlueprint.new!("map", :record_map, params: %{prompt: "Classify {{record}}"}),
          ComponentBlueprint.new!("reduce", :blueprint_reduce)
        ],
        edges: [
          %{from: "discover", to: "parse"},
          %{from: "parse", to: "map"},
          %{from: "map", to: "reduce"}
        ],
        stop_conditions: ["done"]
      )

    client = fn _model, _prompt, _opts ->
      {:error, Error.validation("map item failed", details: %{reason: :forced})}
    end

    assert {:error, %Error{} = error} =
             WorkflowCompiler.run(blueprint, workspace, %{}, client: client)

    assert error.details.component_id == "map"
    assert error.details.component_type == :record_map
    assert is_integer(error.details.runnable_id)
  end

  test "explicit budget ledger component reports budget overruns as structured errors" do
    root = tmp_dir()
    File.write!(Path.join(root, "tickets.jsonl"), ~s({"theme":"login"}\n{"theme":"billing"}\n))
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Budget tickets",
        [
          ComponentBlueprint.new!("discover", :source_discovery,
            params: %{paths: ["tickets.jsonl"]}
          ),
          ComponentBlueprint.new!("parse", :tabular_parser, params: %{format: "jsonl"}),
          ComponentBlueprint.new!("map", :record_map,
            params: %{function: %{tier: :tier1, op: :identity}}
          ),
          ComponentBlueprint.new!("reduce", :blueprint_reduce),
          ComponentBlueprint.new!("budget", :budget_ledger,
            params: %{component_type: :llm_map, max_llm_map_calls: 1}
          )
        ],
        edges: [
          %{from: "discover", to: "parse"},
          %{from: "parse", to: "map"},
          %{from: "map", to: "reduce"},
          %{from: "reduce", to: "budget"}
        ],
        stop_conditions: ["budget checked"]
      )

    assert {:error, %Error{} = error} = WorkflowCompiler.run(blueprint, workspace)
    assert error.message =~ "budget exceeded"
    assert error.details.component_id == "budget"
    assert [%{limit: :max_llm_map_calls}] = error.details.violations
  end

  test "optional Runic runner execution mode starts runs queries and stops workflow" do
    root = tmp_dir()
    File.write!(Path.join(root, "input.md"), "hello\n")
    workspace = Workspace.new!(root: root)

    blueprint =
      WorkflowBlueprint.new!(
        "Compose",
        [
          ComponentBlueprint.new!("discover", :source_discovery, params: %{paths: ["input.md"]}),
          ComponentBlueprint.new!("split", :source_splitter),
          ComponentBlueprint.new!("compose", :report_composer)
        ],
        edges: [%{from: "discover", to: "split"}, %{from: "split", to: "compose"}],
        stop_conditions: ["done"]
      )

    workflow_id = {:test_runner, System.unique_integer([:positive])}

    assert {:ok, result} =
             WorkflowCompiler.run(blueprint, workspace, %{},
               execution_mode: :runner,
               workflow_id: workflow_id
             )

    assert result.output.text =~ "Assistant Report"
  end

  defp params_for(:artifact_writer), do: %{path: ".docs/out.md"}
  defp params_for(_type), do: %{}

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-assistant-graph-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
