defmodule RunicAI.Coding.StandardAgentRemainingTest do
  use ExUnit.Case, async: false

  alias Runic.Workflow
  alias RunicAI.Coding.Agent
  alias RunicAI.Coding.Codex.EventNormalizer
  alias RunicAI.Coding.Evals
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.Recipe
  alias RunicAI.Coding.RecipeRegistry
  alias RunicAI.Coding.Review
  alias RunicAI.Coding.Session
  alias RunicAI.Coding.Workspace
  alias RunicAI.Evaluation.Case
  alias RunicAI.LLM.TestClient
  alias RunicAI.Prompt, as: TurnPrompt
  alias RunicAI.Testing.ScriptedLLM

  test "review gate emits exact patch details and resumes after allow" do
    root = sample_project()
    File.write!(Path.join(root, "lib/old.ex"), "defmodule Old, do: nil\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "delete", path: "lib/old.ex"}]},
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/old.ex. Verification: not run.")}
      end
    end

    workflow =
      Agent.patch(workspace, "Remove the local secret fixture.",
        model: "test:model",
        client: client
      )

    review_request = Agent.latest_review_request(workflow)
    assert review_request.checkpoint == :pre_tool
    assert review_request.subject.calls |> hd() |> Map.get(:tool_name) == "apply_patch"

    review_payload = review_request.details.guard_decision.details.review_request
    assert review_payload.reason == :destructive_patch

    assert get_in(review_payload, [:calls, Access.at(0), :arguments, :operations]) == [
             %{"op" => "delete", "path" => "lib/old.ex"}
           ]

    workflow =
      Workflow.react_until_satisfied(workflow, %{review_decision: Review.allow(review_request)})

    refute File.exists?(Path.join(root, "lib/old.ex"))
    assert Agent.summary(workflow).changed_files == ["lib/old.ex"]
  end

  test "review rewrite executes the replacement execution plan" do
    root = sample_project()
    File.write!(Path.join(root, ".env"), "TOKEN=secret\n")
    workspace = Workspace.new!(root: root)

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "delete", path: ".env"}]},
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/demo.ex. Verification: not run.")}
      end
    end

    workflow =
      Agent.patch(workspace, "Make the safer replacement.", model: "test:model", client: client)

    review_request = Agent.latest_review_request(workflow)
    original_plan = review_request.subject
    [call] = original_plan.calls

    replacement_plan = %{
      original_plan
      | calls: [
          %{
            call
            | arguments: %{
                operations: [%{op: "update", path: "lib/demo.ex", content: demo_source(42)}]
              }
          }
        ]
    }

    workflow =
      Workflow.react_until_satisfied(workflow, %{
        review_decision: Review.rewrite(review_request, replacement_plan)
      })

    assert File.exists?(Path.join(root, ".env"))
    assert File.read!(Path.join(root, "lib/demo.ex")) == demo_source(42)
    assert Agent.summary(workflow).changed_files == ["lib/demo.ex"]
  end

  test "command policy denial is returned as a model-visible tool observation" do
    workspace = Workspace.new!(root: sample_project())

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("run_command", %{argv: ["rm", "-rf", "tmp"]}, id: "call_1")
           ])}

        _ ->
          tool_message = List.last(tool_messages(messages))
          assert tool_message.content =~ "command is blocked by command policy"
          {:ok, TestClient.result("Blocked unsafe command; no files changed.")}
      end
    end

    workflow =
      Agent.run(workspace, "Try the unsafe command.",
        model: "test:model",
        client: client,
        visible_tools: ["run_command"],
        pre_tool_guard: nil,
        command_policy: [allowed_commands: ["git"]]
      )

    assert Agent.summary(workflow).reply == "Blocked unsafe command; no files changed."
  end

  test "named recipe registry and selector expose standard commands" do
    assert RecipeRegistry.names() == [:explain_repo, :fix_ci, :review, :triage_bug, :write_tests]

    assert %Recipe{name: :review, mode: :read_only} = RecipeRegistry.fetch!("/review")

    assert %Recipe{name: :fix_ci, mode: :verify} =
             Agent.select_recipe("ignored", classifier: fn _ -> :fix_ci end)

    assert %Recipe{name: :triage_bug, mode: :read_only} = Agent.select_recipe("/triage-bug crash")
  end

  test "coding sessions persist snapshots and resume review-gated work" do
    {:ok, store} = InMemory.start_link()
    root = sample_project()

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "update", path: "lib/demo.ex", content: demo_source(42)}]},
               id: "call_1"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/demo.ex.")}
      end
    end

    session =
      Session.new(root,
        mode: :patch,
        model: "test:model",
        client: client,
        review_gate_opts: [max_patch_bytes: 1]
      )
      |> Session.submit(%{agent_id: "coding", user: "Patch Demo.answer/0."})

    assert session.status == :review
    assert {:ok, ref} = Session.persist_snapshot(session, {InMemory, store})
    assert [_event] = InMemory.events(store)
    assert {:ok, _artifact} = InMemory.get_artifact(store, ref)

    review_request = List.last(session.outputs).latest_review_request
    resumed = Session.resume(session, %{review_decision: Review.allow(review_request)})

    assert resumed.status == :idle
    assert Session.snapshot(resumed).summary.changed_files == ["lib/demo.ex"]
  end

  test "session spec routes the coding agent through the integrated runtime contract" do
    spec =
      Session.spec(sample_project(),
        mode: :read_only,
        model: "test:model",
        client: ScriptedLLM.client(["ok"])
      )

    assert spec.kind == :integrated
    assert spec.recipe == Agent
    assert Keyword.fetch!(spec.recipe_opts, :workspace).root
  end

  @tag timeout: 60_000
  test "coding session resumes after failed verification pauses on risky repair" do
    root = failing_mix_project()

    client = fn _model, %TurnPrompt{messages: messages}, _opts ->
      case tool_count(messages) do
        0 ->
          {:ok,
           TestClient.tool_response([
             TestClient.tool_call("run_tests", %{args: ["test/smoke_test.exs"]}, id: "call_1")
           ])}

        1 ->
          assert List.last(tool_messages(messages)).content =~ "\"status\":\"fail\""

          {:ok,
           TestClient.tool_response([
             TestClient.tool_call(
               "apply_patch",
               %{operations: [%{op: "update", path: "lib/smoke.ex", content: smoke_source(42)}]},
               id: "call_2"
             )
           ])}

        _ ->
          {:ok, TestClient.result("Changed files: lib/smoke.ex. Verification was repaired.")}
      end
    end

    session =
      Session.new(root,
        mode: :verify,
        model: "test:model",
        client: client,
        review_gate_opts: [max_patch_bytes: 1]
      )
      |> Session.submit(%{agent_id: "coding", user: "Fix the failing smoke test."})

    assert session.status == :review
    assert [%{status: "fail"}] = Session.snapshot(session).summary.verifications

    review_request = List.last(session.outputs).latest_review_request
    resumed = Session.resume(session, %{review_decision: Review.allow(review_request)})

    assert resumed.status == :idle
    assert File.read!(Path.join(root, "lib/smoke.ex")) == smoke_source(42)
    assert Session.snapshot(resumed).summary.changed_files == ["lib/smoke.ex"]
  end

  test "Codex configuration is opt-in and JSONL events normalize deterministically" do
    assert Agent.client(:codex) == RunicAI.Coding.Codex.Client

    req_runtime = Agent.initial_runtime(workspace: sample_project(), model: "test:model")
    req_session = req_runtime.agents["coding"]

    refute Keyword.has_key?(get_in(req_session.metadata, [:turn_defaults, :llm_opts]), :workspace)
    refute Keyword.has_key?(get_in(req_session.metadata, [:turn_defaults, :llm_opts]), :root)

    codex_runtime =
      Agent.initial_runtime(workspace: sample_project(), model: "test:model", client: :codex)

    codex_session = codex_runtime.agents["coding"]

    assert Keyword.has_key?(
             get_in(codex_session.metadata, [:turn_defaults, :llm_opts]),
             :workspace
           )

    assert Keyword.has_key?(get_in(codex_session.metadata, [:turn_defaults, :llm_opts]), :root)

    jsonl = ~s({"type":"message","content":"working"}\n{"type":"result","message":"done"}\n)
    assert {:ok, normalized} = EventNormalizer.normalize_jsonl(jsonl)
    assert normalized.final == %{"type" => "result", "message" => "done"}
    assert Enum.map(normalized.trace_events, & &1.kind) == [:codex_exec_event, :codex_exec_event]
  end

  test "coding eval fixtures can run through the evaluation harness" do
    root = sample_project()

    evaluation_case =
      Case.new!(
        id: "coding:deterministic_smoke",
        input: %{agent_id: "coding", user: "Explain the fixture."},
        expected: [{:contains_text, "Done"}],
        metadata: %{
          workspace: root,
          command: :explain_repo,
          client: ScriptedLLM.client(["Done."])
        }
      )

    run = Evals.run([evaluation_case])

    assert length(Evals.cases(workspace: root)) == 4
    assert [%{status: :passed}] = run.results
    assert run.aggregate.cases_passed == 1
  end

  defp tool_count(messages), do: messages |> tool_messages() |> length()
  defp tool_messages(messages), do: Enum.filter(messages, &(&1.role == :tool))

  defp sample_project do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), demo_source(41))
    root
  end

  defp failing_mix_project do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Smoke.MixProject do
      use Mix.Project

      def project do
        [
          app: :smoke,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end
    end
    """)

    File.write!(Path.join(root, "lib/smoke.ex"), smoke_source(41))
    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/smoke_test.exs"), """
    defmodule SmokeTest do
      use ExUnit.Case, async: true

      test "answer" do
        assert Smoke.answer() == 42
      end
    end
    """)

    root
  end

  defp demo_source(answer) do
    """
    defmodule Demo do
      def answer, do: #{answer}
    end
    """
  end

  defp smoke_source(answer) do
    """
    defmodule Smoke do
      def answer, do: #{answer}
    end
    """
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-standard-agent-remaining-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
