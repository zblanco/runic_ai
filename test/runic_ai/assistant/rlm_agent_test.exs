defmodule RunicAI.Assistant.RLMAgentTest do
  use ExUnit.Case, async: true

  alias RunicAI.Assistant.RLM.Agent
  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Assistant.RLM.SmokeRunner
  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Review
  alias RunicAI.Coding.Workspace
  alias RunicAI.LLM.TestClient

  test "compiles and executes a generated split/map/reduce/write workflow" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    blueprint = report_blueprint(".docs/report.md")

    assert {:ok, result} =
             WorkflowCompiler.run(blueprint, workspace, %{},
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only
             )

    assert result.scorecard.objective_status == :objective_satisfied
    assert File.read!(Path.join(root, ".docs/report.md")) =~ "High Level Overview"
    assert result.intermediate_outputs["write"].status == :written
  end

  test "assistant workflow artifact writes use the review decider when provided" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow, allowed_write_roots: [".docs"])
      )

    parent = self()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    review_decider = fn request, context ->
      send(parent, {:artifact_write_review, request, context})
      {:ok, Review.deny(request, reason: "denied in test")}
    end

    assert {:error, error} =
             WorkflowCompiler.run(report_blueprint(".docs/report.md"), workspace, %{},
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only,
               run_id: "assistant-review-test",
               review_decider: review_decider,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert error.message =~ "artifact write denied by review"
    refute File.exists?(Path.join(root, ".docs/report.md"))

    assert_receive {:artifact_write_review, request, %{workspace: ^workspace}}
    assert request.kind == :assistant_artifact_write
    assert request.checkpoint == :pre_write
    assert request.details.path == ".docs/report.md"

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :review_requested and &1.status == :review))
    assert Enum.any?(emitted, &(&1.stage == :review_completed and &1.status == :blocked))
  end

  test "assistant agent builds the generic fallback workflow and emits stages" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               input_paths: ["chapter.md"],
               output_path: ".docs/report.md",
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.agent == :assistant
    assert result.status == :ok
    assert File.exists?(Path.join(root, ".docs/report.md"))

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :blueprint_proposed))
    assert Enum.any?(emitted, &(&1.stage == :node_completed))
    assert Enum.any?(emitted, &(&1.stage == :scorecard_completed))
  end

  test "assistant fallback uses the default model when --model is omitted" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    parent = self()

    client = fn model, prompt, _opts ->
      send(parent, {:model_used, model})

      text =
        if prompt =~ "Merged notes:" do
          "# High Level Overview\n\nDefault model path worked."
        else
          "slice note"
        end

      {:ok, TestClient.result(text)}
    end

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               input_paths: ["chapter.md"],
               output_path: ".docs/report.md",
               client: client,
               write_policy: :docs_only
             )

    assert result.status == :ok
    assert_receive {:model_used, "openai:gpt-5.4-mini"}
    refute_receive {:model_used, nil}
  end

  test "assistant answers simple no-input objectives through a workflow graph" do
    root = tmp_dir()
    parent = self()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn model, prompt, opts ->
      if prompt =~ "workflow coordinator" do
        send(parent, {:planner_prompt, model, prompt, opts})
        {:ok, TestClient.result(Jason.encode!(simple_response_blueprint()))}
      else
        send(parent, {:execution_prompt, model, prompt, opts})
        {:ok, TestClient.result("Frogs hum softly beside the moonlit reeds.")}
      end
    end

    assert {:ok, result} =
             Agent.run(root, "Write me a poem about frogs",
               client: client,
               model: "test:model",
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.status == :ok
    refute Map.get(result, :direct_response?, false)
    assert result.output.text =~ "Frogs hum softly"
    assert result.scorecard.objective_status == :objective_satisfied

    assert_receive {:planner_prompt, "test:model", planner_prompt, _planner_opts}
    assert planner_prompt =~ "Always return a workflow blueprint"
    assert planner_prompt =~ "Write me a poem about frogs"

    assert_receive {:execution_prompt, "test:model", execution_prompt, llm_opts}
    assert execution_prompt =~ "Write me a poem about frogs"
    assert llm_opts[:max_tokens] == 12_000

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :blueprint_generation_started))
    assert Enum.any?(emitted, &(&1.stage == :blueprint_generation_completed and &1.status == :ok))
    assert Enum.any?(emitted, &(&1.stage == :blueprint_proposed))
    assert Enum.any?(emitted, &(&1.stage == :node_completed))

    assert Enum.any?(
             emitted,
             &(&1.stage == :completed and &1.data.output_text =~ "Frogs hum softly")
           )

    refute Enum.any?(emitted, &(&1.stage == :direct_response_started))
  end

  test "assistant infers readable path references as declared source inputs" do
    root = tmp_dir()
    external = tmp_dir()
    File.write!(Path.join(external, "notes.md"), "Runic keeps workflow facts durable.\n")
    parent = self()

    client = fn model, prompt, opts ->
      if prompt =~ "workflow coordinator" do
        send(parent, {:planner_prompt, model, prompt, opts})
        {:ok, TestClient.result(Jason.encode!(simple_response_blueprint()))}
      else
        {:ok, TestClient.result("Path inference exercised.")}
      end
    end

    assert {:ok, result} =
             Agent.run(root, "Summarize the notes in #{external}",
               client: client,
               model: "test:model",
               repair_scorecard?: false
             )

    assert result.status == :blocked
    assert_receive {:planner_prompt, "test:model", planner_prompt, _planner_opts}
    assert planner_prompt =~ Jason.encode!([external])
    assert planner_prompt =~ "read-only source components"
    assert planner_prompt =~ "cannot access declared local paths"
  end

  test "assistant repairs generated source workflows that skip source splitting" do
    root = tmp_dir()
    external = tmp_dir()
    File.write!(Path.join(external, "notes.md"), "Runic keeps workflow facts durable.\n")
    parent = self()

    client = fn _model, prompt, _opts ->
      cond do
        prompt =~ "workflow coordinator" ->
          send(parent, :planner_called)
          {:ok, TestClient.result(Jason.encode!(bad_materializer_blueprint(external)))}

        prompt =~ "repairing an invalid" ->
          send(parent, :repair_called)
          assert prompt =~ "missing_source_splitter"
          {:ok, TestClient.result(Jason.encode!(good_source_summary_blueprint(external)))}

        prompt =~ "Runic keeps workflow facts durable." ->
          send(parent, :source_content_seen)
          {:ok, TestClient.result("Runic keeps workflow facts durable and visible.")}

        true ->
          {:ok, TestClient.result("Runic keeps workflow facts durable and visible.")}
      end
    end

    assert {:ok, result} =
             Agent.run(root, "Summarize the notes in #{external}",
               client: client,
               model: "test:model"
             )

    assert result.status == :ok
    assert result.scorecard.source_coverage == :present
    assert_receive :planner_called
    assert_receive :repair_called
    assert_receive :source_content_seen
  end

  test "assistant source workflows skip policy-blocked files during broad scans" do
    root = tmp_dir()
    File.write!(Path.join(root, "README.md"), "Visible project purpose.\n")
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/prod.secret.exs"), "import Config\n")
    parent = self()

    client = fn _model, prompt, _opts ->
      if prompt =~ "Visible project purpose." do
        send(parent, :safe_source_seen)
      end

      refute prompt =~ "prod.secret.exs"
      {:ok, TestClient.result("Visible project purpose summarized.")}
    end

    assert {:ok, result} =
             Agent.run(root, "Summarize this project",
               blueprint: good_source_summary_blueprint("."),
               client: client,
               model: "test:model"
             )

    assert result.status == :ok
    assert result.scorecard.source_coverage == :present
    assert_receive :safe_source_seen
  end

  test "assistant source workflows truncate broad source sets before splitting" do
    root = tmp_dir()

    for index <- 1..5 do
      File.write!(Path.join(root, "project_#{index}.md"), "Project #{index} purpose.\n")
    end

    parent = self()

    client = fn _model, prompt, _opts ->
      if prompt =~ "Project 1 purpose." do
        send(parent, :bounded_sources_seen)
      end

      refute prompt =~ "Project 5 purpose."
      {:ok, TestClient.result("Bounded project summaries composed.")}
    end

    assert {:ok, result} =
             Agent.run(root, "Summarize projects",
               blueprint:
                 good_source_summary_blueprint(
                   ".",
                   %{"paths" => ["."], "max_depth" => 1, "max_files" => 5},
                   %{"strategy" => "paragraph", "max_sources" => 2}
                 ),
               client: client,
               model: "test:model"
             )

    assert result.status == :ok
    assert result.intermediate_outputs["discover"].count == 5
    assert result.intermediate_outputs["split"].truncated?
    assert result.intermediate_outputs["split"].source_count == 2
    assert result.intermediate_outputs["split"].input_source_count == 5
    assert_receive :bounded_sources_seen
  end

  test "assistant blueprint generation times out with persisted diagnostic stages" do
    root = tmp_dir()
    parent = self()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn _model, prompt, _opts ->
      if prompt =~ "workflow coordinator" do
        send(parent, :planner_called)
        Process.sleep(:infinity)
      else
        {:ok, TestClient.result("unexpected execution response")}
      end
    end

    assert {:error, error} =
             Agent.run(root, "Write me a poem about frogs",
               client: client,
               model: "test:model",
               blueprint_generation_timeout_ms: 10,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert error.kind == :timeout
    assert error.message =~ "assistant blueprint generation timed out"
    assert_receive :planner_called

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :blueprint_generation_started))

    assert Enum.any?(
             emitted,
             &(&1.stage == :blueprint_generation_completed and &1.status == :error)
           )

    assert Enum.any?(emitted, &(&1.stage == :failed))
    refute Enum.any?(emitted, &(&1.stage == :blueprint_proposed))
    refute Enum.any?(emitted, &(&1.stage == :node_started))
  end

  test "assistant workflow proposal and execution receive prior conversation history" do
    root = tmp_dir()
    parent = self()

    client = fn _model, prompt, _opts ->
      if prompt =~ "workflow coordinator" do
        send(parent, {:planner_prompt, prompt})
        {:ok, TestClient.result(Jason.encode!(conversation_response_blueprint()))}
      else
        send(parent, {:execution_prompt, prompt})
        {:ok, TestClient.result("The full story continues from the outline.")}
      end
    end

    assert {:ok, result} =
             Agent.run(root, "Now write the rest of the story.",
               client: client,
               model: "test:model",
               conversation_history: [
                 %{
                   role: "assistant",
                   message_kind: "direct_response",
                   content: "Outline: a falling piano, the God of Paths, and -100 luck."
                 }
               ]
             )

    assert result.status == :ok
    refute Map.get(result, :direct_response?, false)
    assert result.output.text =~ "full story continues"

    assert_receive {:planner_prompt, prompt}
    assert prompt =~ "Conversation context"
    assert prompt =~ "Outline: a falling piano"
    assert prompt =~ "Now write the rest of the story."

    assert_receive {:execution_prompt, execution_prompt}
    assert execution_prompt =~ "Outline: a falling piano"
  end

  test "assistant routes explicit workflow construction objectives through planning" do
    root = tmp_dir()
    parent = self()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn model, prompt, _opts ->
      cond do
        prompt =~ "workflow coordinator" ->
          send(parent, {:planner_prompt, model, prompt})
          {:ok, TestClient.result(Jason.encode!(creative_workflow_blueprint()))}

        true ->
          send(parent, {:execution_prompt, prompt})
          {:ok, TestClient.result("# Chapter 1\n\nThe story draft begins with a coherent scene.")}
      end
    end

    objective =
      "Now the whole story. Build a workflow that expands this outline, fans out to " <>
        "write every chapter, chunks the draft if needed, then reviews it from an editor perspective."

    assert {:ok, result} =
             Agent.run(root, objective,
               client: client,
               model: "test:model",
               proposal_generation: :json_text,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    refute Map.get(result, :direct_response?, false)

    assert_receive {:planner_prompt, "test:model", planner_prompt}
    assert planner_prompt =~ "Build a workflow"
    assert planner_prompt =~ "fans out"

    assert_receive {:execution_prompt, execution_prompt}
    assert execution_prompt =~ "story drafting context"
    assert execution_prompt =~ "write every chapter"
    refute_receive {:direct_prompt, _, _}

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :blueprint_proposed))
    refute Enum.any?(emitted, &(&1.stage == :direct_response_started))
  end

  test "assistant workflow response respects explicit caller output limits" do
    root = tmp_dir()
    parent = self()

    client = fn _model, prompt, opts ->
      if prompt =~ "workflow coordinator" do
        {:ok, TestClient.result(Jason.encode!(simple_response_blueprint()))}
      else
        send(parent, {:execution_opts, opts})
      end

      {:ok, TestClient.result("short answer")}
    end

    assert {:ok, result} =
             Agent.run(root, "Answer directly",
               client: client,
               model: "test:model",
               llm_opts: [max_output_tokens: 321, temperature: 0.1]
             )

    assert result.status == :ok
    assert_receive {:execution_opts, llm_opts}
    assert llm_opts[:max_output_tokens] == 321
    assert llm_opts[:temperature] == 0.1
    refute Keyword.has_key?(llm_opts, :max_tokens)
  end

  test "assistant routes workspace path objectives through workflow planning" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, ".docs"))
    File.write!(Path.join(root, ".docs/035-termui-plan.md"), "TermUI plan for durable TUI work.")

    parent = self()
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn model, prompt, _opts ->
      cond do
        prompt =~ "workflow coordinator" ->
          send(parent, {:planner_prompt, model, prompt})
          {:ok, TestClient.result(Jason.encode!(direct_workflow_blueprint()))}

        true ->
          send(parent, {:execution_prompt, prompt})
          {:ok, TestClient.result("The 035 plan is for the durable TUI workbench.")}
      end
    end

    assert {:ok, result} =
             Agent.run(root, "Inside .docs/ - find me the plan prefixed 035 and summarize it",
               client: client,
               model: "test:model",
               proposal_generation: :json_text,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.status == :ok
    refute Map.get(result, :direct_response?, false)

    assert_receive {:planner_prompt, "test:model", planner_prompt}
    assert planner_prompt =~ ".docs/"
    assert_receive {:execution_prompt, execution_prompt}
    assert execution_prompt =~ "Summarize the available request context."
    refute_receive {:direct_prompt, _, _}

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :blueprint_proposed))
    refute Enum.any?(emitted, &(&1.stage == :direct_response_started))
  end

  test "assistant workflow can read explicit external paths without switching workspace" do
    root = tmp_dir()
    external = tmp_dir()
    File.write!(Path.join(external, "workflow.md"), "Runic graphs keep durable facts.\n")

    blueprint =
      WorkflowBlueprint.new!(
        "Read sibling project notes",
        [
          ComponentBlueprint.new!("discover", :source_discovery,
            params: %{paths: [external], extensions: ["md"], max_files: 4}
          ),
          ComponentBlueprint.new!("split", :source_splitter, params: %{max_sources: 4}),
          ComponentBlueprint.new!("materialize", :source_materializer),
          ComponentBlueprint.new!("synthesize", :llm_leaf,
            params: %{prompt: "Explain {{items}}", max_group_items: 2}
          ),
          ComponentBlueprint.new!("verify", :objective_scorecard)
        ],
        edges: [
          %{from: "discover", to: "split"},
          %{from: "split", to: "materialize"},
          %{from: "materialize", to: "synthesize"},
          %{from: "synthesize", to: "verify"}
        ],
        stop_conditions: ["answer produced"]
      )

    parent = self()

    client = fn _model, prompt, _opts ->
      if prompt =~ "Runic graphs keep durable facts." do
        send(parent, :external_source_prompt_seen)
      end

      {:ok, TestClient.result("Runic graphs keep durable facts visible.")}
    end

    assert {:ok, result} =
             Agent.run(root, "Read the sibling project notes",
               blueprint: blueprint,
               client: client,
               model: "test:model"
             )

    assert result.status == :ok
    assert result.repair_history == []
    assert result.scorecard.source_coverage == :present
    assert result.scorecard.provenance_count > 0
    assert result.intermediate_outputs["discover"].count == 1
    assert [%{absolute_path: absolute_path}] = result.intermediate_outputs["discover"].sources
    assert absolute_path == Path.join(external, "workflow.md")
    assert_receive :external_source_prompt_seen
  end

  test "assistant attempts one scorecard repair when source cues are missing" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    {:ok, reduce_calls} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    client = fn _model, prompt, _opts ->
      text =
        cond do
          prompt =~ "Merged notes:" ->
            call = Elixir.Agent.get_and_update(reduce_calls, &{&1, &1 + 1})

            if call == 0 do
              "# High Level Overview\n\nAda arrived."
            else
              "# High Level Overview\n\nAda arrived and Bea found the key."
            end

          true ->
            "slice note"
        end

      {:ok, TestClient.result(text)}
    end

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               input_paths: ["chapter.md"],
               output_path: ".docs/report.md",
               required_sections: ["High Level Overview"],
               required_source_cues: ["Bea found the key"],
               require_artifact_quality?: true,
               client: client,
               model: "test:model",
               write_policy: :docs_only,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.status == :ok
    assert result.scorecard.objective_status == :objective_satisfied
    assert [%{strategy: :scorecard_diagnostic_repair}] = result.repair_history

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :scorecard_repair_started))
  end

  test "assistant repairs runtime writer failures with a bounded fallback blueprint" do
    root = tmp_dir()
    File.write!(Path.join(root, "chapter.md"), "Ada arrived.\n\nBea found the key.\n")
    {:ok, events} = Elixir.Agent.start_link(fn -> [] end)

    blueprint =
      WorkflowBlueprint.new!(
        "Write a high level report",
        [
          ComponentBlueprint.new!("split", :source_splitter,
            params: %{strategy: :paragraph, max_bytes: 100}
          ),
          ComponentBlueprint.new!("materialize", :source_materializer),
          ComponentBlueprint.new!("map", :llm_map),
          ComponentBlueprint.new!("join", :blueprint_reduce),
          ComponentBlueprint.new!("synthesize", :llm_leaf),
          ComponentBlueprint.new!("write", :artifact_writer,
            params: %{path: "tmp/report.md", write_policy: :docs_only}
          ),
          ComponentBlueprint.new!("verify", :verification)
        ],
        sources: ["chapter.md"],
        edges: [
          %{from: "split", to: "materialize"},
          %{from: "materialize", to: "map"},
          %{from: "map", to: "join"},
          %{from: "join", to: "synthesize"},
          %{from: "synthesize", to: "write"},
          %{from: "write", to: "verify"}
        ],
        stop_conditions: ["artifact written"]
      )

    assert {:ok, result} =
             Agent.run(root, "Write a high level report",
               blueprint: blueprint,
               input_paths: ["chapter.md"],
               client: scripted_client(),
               model: "test:model",
               write_policy: :docs_only,
               event_sink: fn stage -> Elixir.Agent.update(events, &(&1 ++ [stage])) end
             )

    assert result.status == :ok
    refute File.exists?(Path.join(root, "tmp/report.md"))
    assert [%{strategy: :runtime_fallback_blueprint}] = result.repair_history

    emitted = Elixir.Agent.get(events, & &1)
    assert Enum.any?(emitted, &(&1.stage == :execution_failed))
    assert Enum.any?(emitted, &(&1.stage == :repair_attempt_started))
    assert Enum.any?(emitted, &(&1.stage == :repair_completed))
  end

  test "smoke runner writes a scenario report with comparable trace summary" do
    root = tmp_dir()

    assert {:ok, smoke} =
             SmokeRunner.run_scenario(root, :meeting_actions,
               client: scripted_client(),
               model: "test:model",
               proposal_strategy: :fallback
             )

    assert smoke.summary.nodes_generated > 0
    assert smoke.matrix_entry.expectation_status in [:pass, :review, :fail]
    assert File.exists?(Path.join(root, smoke.report_path))
    assert File.exists?(Path.join(root, smoke.run_path))
    report = File.read!(Path.join(root, smoke.report_path))
    assert report =~ "Trace Summary"
    assert report =~ "Runic Graph"
    assert report =~ "Native Runtime Nodes"
    assert report =~ "Mermaid"
    assert report =~ "Expected Vs Observed"

    assert {:ok, run_details} = Jason.decode(File.read!(Path.join(root, smoke.run_path)))
    assert is_map(run_details["graph_summary"])
    assert is_map(run_details["intermediate_outputs"])
    assert run_details["trace_summary"]["nodes_executed"] > 0
    assert run_details["execution_metrics"]["nodes_executed"] > 0
    assert is_list(run_details["native_nodes"])

    assert Enum.any?(
             run_details["native_nodes"],
             &(&1["production_count"] > 0)
           )

    assert Enum.any?(
             run_details["events"],
             &(get_in(&1, ["data", "runnable", "node"]) != nil)
           )

    assert File.read!(Path.join(root, "tmp/assistant_research_brief.md")) =~
             "Recursive Language Models"
  end

  defp report_blueprint(path) do
    WorkflowBlueprint.new!(
      "Write a report",
      [
        ComponentBlueprint.new!("split", :source_splitter,
          params: %{strategy: :paragraph, max_bytes: 100}
        ),
        ComponentBlueprint.new!("materialize", :source_materializer),
        ComponentBlueprint.new!("map", :llm_map),
        ComponentBlueprint.new!("join", :blueprint_reduce),
        ComponentBlueprint.new!("synthesize", :llm_leaf),
        ComponentBlueprint.new!("write", :artifact_writer,
          params: %{path: path, write_policy: :docs_only}
        ),
        ComponentBlueprint.new!("verify", :verification, params: %{artifact_path: path})
      ],
      sources: ["chapter.md"],
      edges: [
        %{from: "split", to: "materialize"},
        %{from: "materialize", to: "map"},
        %{from: "map", to: "join"},
        %{from: "join", to: "synthesize"},
        %{from: "synthesize", to: "write"},
        %{from: "write", to: "verify"}
      ],
      stop_conditions: ["artifact written"]
    )
  end

  defp direct_workflow_blueprint do
    %{
      "id" => "assistant:test_direct_workflow",
      "objective" => "Summarize the requested workspace plan.",
      "sources" => [],
      "components" => [
        %{
          "id" => "discover_sources",
          "type" => "source_discovery",
          "params" => %{
            "paths" => [".docs"],
            "extensions" => ["md"],
            "include_hidden?" => true,
            "max_files" => 8
          }
        },
        %{
          "id" => "split_sources",
          "type" => "source_splitter",
          "params" => %{"strategy" => "paragraph", "max_sources" => 8}
        },
        %{"id" => "materialize_sources", "type" => "source_materializer", "params" => %{}},
        %{
          "id" => "synthesize_response",
          "type" => "llm_leaf",
          "params" => %{
            "strategy" => "llm_reduce",
            "group_prompt" => "Summarize the available request context.",
            "prompt" => "Return the requested summary.",
            "max_group_items" => 12
          }
        },
        %{"id" => "verify_objective", "type" => "objective_scorecard", "params" => %{}}
      ],
      "edges" => [
        %{"from" => "discover_sources", "to" => "split_sources"},
        %{"from" => "split_sources", "to" => "materialize_sources"},
        %{"from" => "materialize_sources", "to" => "synthesize_response"},
        %{"from" => "synthesize_response", "to" => "verify_objective"}
      ],
      "stop_conditions" => ["summary produced"]
    }
  end

  defp simple_response_blueprint do
    %{
      "id" => "assistant:test_simple_response_workflow",
      "objective" => "Answer the current user request.",
      "sources" => [],
      "components" => [
        %{
          "id" => "respond",
          "type" => "llm_leaf",
          "params" => %{
            "strategy" => "llm_reduce",
            "group_prompt" => "Prepare answer context for {{objective}} from {{input}}.",
            "prompt" => "Answer the current request from this context: {{items}}",
            "max_group_items" => 1
          }
        },
        %{"id" => "verify_objective", "type" => "objective_scorecard", "params" => %{}}
      ],
      "edges" => [
        %{"from" => "respond", "to" => "verify_objective"}
      ],
      "stop_conditions" => ["assistant response produced"]
    }
  end

  defp conversation_response_blueprint do
    %{
      "id" => "assistant:test_conversation_response_workflow",
      "objective" => "Continue the prior conversation.",
      "sources" => [],
      "components" => [
        %{
          "id" => "continue_story",
          "type" => "llm_leaf",
          "params" => %{
            "strategy" => "llm_reduce",
            "group_prompt" =>
              "Use the conversation history in {{input}} to resolve references for {{objective}}.",
            "prompt" => "Continue the story using this prepared context: {{items}}",
            "max_group_items" => 1
          }
        },
        %{"id" => "verify_objective", "type" => "objective_scorecard", "params" => %{}}
      ],
      "edges" => [
        %{"from" => "continue_story", "to" => "verify_objective"}
      ],
      "stop_conditions" => ["continuation produced"]
    }
  end

  defp creative_workflow_blueprint do
    %{
      "id" => "assistant:test_creative_workflow",
      "objective" => "Write a story through a generated workflow.",
      "sources" => [],
      "components" => [
        %{
          "id" => "draft_story",
          "type" => "llm_leaf",
          "params" => %{
            "strategy" => "llm_reduce",
            "group_prompt" => "Prepare story drafting context from {{input}}.",
            "prompt" => "Write every chapter from this plan and context: {{items}}",
            "max_group_items" => 4
          }
        },
        %{"id" => "verify_objective", "type" => "objective_scorecard", "params" => %{}}
      ],
      "edges" => [
        %{"from" => "draft_story", "to" => "verify_objective"}
      ],
      "stop_conditions" => ["story drafted"]
    }
  end

  defp bad_materializer_blueprint(path) do
    %{
      "id" => "assistant:test_bad_materializer",
      "objective" => "Summarize local notes.",
      "sources" => [%{"id" => "notes", "path" => path}],
      "components" => [
        %{
          "id" => "discover",
          "type" => "source_discovery",
          "params" => %{"paths" => [path], "max_depth" => 2}
        },
        %{
          "id" => "pick",
          "type" => "blueprint_transform",
          "params" => %{"function" => %{"tier" => "tier0", "op" => "identity"}}
        },
        %{"id" => "materialize", "type" => "source_materializer", "params" => %{}},
        %{
          "id" => "synthesize",
          "type" => "llm_leaf",
          "params" => %{"prompt" => "Summarize {{items}}"}
        },
        %{"id" => "verify", "type" => "objective_scorecard", "params" => %{}}
      ],
      "edges" => [
        %{"from" => "discover", "to" => "pick"},
        %{"from" => "pick", "to" => "materialize"},
        %{"from" => "materialize", "to" => "synthesize"},
        %{"from" => "synthesize", "to" => "verify"}
      ],
      "stop_conditions" => ["summary produced"]
    }
  end

  defp good_source_summary_blueprint(
         path,
         discovery_params \\ %{"max_depth" => 2, "max_files" => 8},
         splitter_params \\ %{"strategy" => "paragraph", "max_sources" => 8}
       ) do
    %{
      "id" => "assistant:test_good_source_summary",
      "objective" => "Summarize local notes.",
      "sources" => [%{"id" => "notes", "path" => path}],
      "components" => [
        %{
          "id" => "discover",
          "type" => "source_discovery",
          "params" => Map.put_new(discovery_params, "paths", [path])
        },
        %{
          "id" => "split",
          "type" => "source_splitter",
          "params" => splitter_params
        },
        %{"id" => "materialize", "type" => "source_materializer", "params" => %{}},
        %{
          "id" => "synthesize",
          "type" => "llm_leaf",
          "params" => %{
            "strategy" => "llm_reduce",
            "prompt" => "Summarize the source evidence: {{items}}",
            "max_group_items" => 4
          }
        },
        %{"id" => "verify", "type" => "objective_scorecard", "params" => %{}}
      ],
      "edges" => [
        %{"from" => "discover", "to" => "split"},
        %{"from" => "split", "to" => "materialize"},
        %{"from" => "materialize", "to" => "synthesize"},
        %{"from" => "synthesize", "to" => "verify"}
      ],
      "stop_conditions" => ["summary produced"]
    }
  end

  defp scripted_client do
    fn _model, prompt, _opts ->
      text =
        cond do
          prompt =~ "Merged notes:" ->
            "# High Level Overview\n\nAda arrived and Bea found the key.\n\n## Takeaways\n\nThe plot moved forward."

          prompt =~ "Partial notes group" ->
            "Ada arrived. Bea found the key."

          true ->
            "slice note: #{String.slice(prompt, 0, 40)}"
        end

      {:ok, TestClient.result(text)}
    end
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-assistant-agent-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
