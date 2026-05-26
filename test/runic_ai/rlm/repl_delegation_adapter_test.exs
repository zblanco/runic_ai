defmodule RunicAI.RLM.REPLDelegationAdapterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Workspace
  alias RunicAI.RLM.ContextSlicer
  alias RunicAI.RLM.DelegationAdapters.REPL
  alias RunicAI.RLM.REPL.PythonRuntime
  alias RunicAI.RLM.SubagentAssignment
  alias RunicAI.RLM.SubagentReducer

  test "runs gated sandbox REPL assignments through the Python runtime" do
    workspace = sample_workspace()
    {:ok, sliced} = ContextSlicer.file_set(workspace, ["README.md"])
    [context_slice] = sliced.slices

    {:ok, registry} =
      RunicAI.REPLFakeSandboxRegistry.start_link(
        response:
          {:ok,
           %{
             status: :ok,
             stdout:
               PythonRuntime.final_marker() <>
                 ~s({"answer":"context inspected","evidence_refs":["artifact://repl"],"confidence":0.8}),
             stderr: "",
             exit_status: 0,
             duration_ms: 3,
             backend: :docker,
             isolation_level: :container
           }}
      )

    assignment =
      sandbox_repl_assignment(
        context_slice: context_slice,
        output_schema: %{required: ["answer"]},
        budgets: %{rlm_queries: 1, llm_queries: 0, max_depth: 3}
      )

    assert {:ok, result} =
             REPL.run(workspace, assignment,
               registry: registry,
               sandbox_session_id: "sandbox:repl",
               symbolic_context_handle: "ctx",
               code: "set_final({'answer': 'ignored-by-fake'})"
             )

    assert result.gates == %{
             symbolic_context_handle: "ctx",
             max_depth: 3,
             parent_depth: 1,
             subquery_budget: 1
           }

    assert result.repl_state.sandbox_session_id == "sandbox:repl"
    assert result.repl_state.context_ref == "ctx"
    assert result.repl_state.budgets.rlm_queries == 1
    assert result.child_result.status == :completed

    assert %{claims: [%{claim: "context inspected", evidence_refs: ["artifact://repl"]}]} =
             result.child_result.output

    assert {:ok, reduced} = SubagentReducer.reduce([result.child_result])
    assert reduced.status == :accepted

    assert [%{session_id: "sandbox:repl", request: request}] =
             RunicAI.REPLFakeSandboxRegistry.requests(registry)

    assert request.runtime == :python
    assert request.source =~ "def rlm_query"
    assert request.source =~ "ctx"
  end

  test "requires explicit symbolic context and subquery gates" do
    workspace = sample_workspace()
    assignment = sandbox_repl_assignment(budgets: %{max_depth: 3})

    assert {:error, error} =
             REPL.run(workspace, assignment,
               registry: self(),
               sandbox_session_id: "sandbox:repl",
               code: "set_final({'answer': 'done'})"
             )

    assert error.kind == :validation
    assert error.details.field == :symbolic_context_handle
  end

  test "rejects assignments that exceed the recursion depth limit" do
    workspace = sample_workspace()

    assignment =
      sandbox_repl_assignment(
        budgets: %{rlm_queries: 1, max_depth: 1},
        parent: %{
          run_id: "run:parent",
          strategy: :subagent_delegation,
          fallback: :direct_standard_agent,
          depth: 1
        }
      )

    assert {:error, error} =
             REPL.run(workspace, assignment,
               registry: self(),
               sandbox_session_id: "sandbox:repl",
               symbolic_context_handle: "ctx",
               code: "set_final({'answer': 'done'})"
             )

    assert error.kind == :validation
    assert error.message =~ "depth limit exceeded"
    assert error.details.parent_depth == 1
    assert error.details.max_depth == 1
  end

  test "maps failed sandbox turns to failed child results" do
    workspace = sample_workspace()

    {:ok, registry} =
      RunicAI.REPLFakeSandboxRegistry.start_link(
        response:
          {:ok,
           %{
             status: :error,
             stdout: "boom",
             stderr: "traceback",
             exit_status: 1,
             duration_ms: 2
           }}
      )

    assignment = sandbox_repl_assignment(budgets: %{rlm_queries: 0, max_depth: 3})

    assert {:ok, result} =
             REPL.run(workspace, assignment,
               registry: registry,
               sandbox_session_id: "sandbox:repl",
               symbolic_context_handle: "ctx",
               code: "raise Exception('boom')"
             )

    assert result.child_result.status == :failed
    assert result.child_result.error.message =~ "repl_delegate_failed"
    assert result.child_result.metadata.observation.exit_status == 1
  end

  defp sandbox_repl_assignment(opts) do
    parent =
      Keyword.get(opts, :parent, %{
        run_id: "run:parent",
        strategy: :subagent_delegation,
        fallback: :direct_standard_agent,
        depth: 1
      })

    SubagentAssignment.new!(
      id: Keyword.get(opts, :id, "assignment:repl"),
      role: Keyword.get(opts, :role, "repl worker"),
      objective: Keyword.get(opts, :objective, "Inspect context in a REPL"),
      strategy: :sandbox_repl,
      agent_kind: :workflow,
      context_slice: Keyword.get(opts, :context_slice),
      capability_profile: :sandbox_docker_read,
      visible_tools: [:sandbox_execute],
      budgets: Keyword.get(opts, :budgets, %{rlm_queries: 1, max_depth: 3}),
      output_schema: Keyword.get(opts, :output_schema, %{}),
      parent: parent
    )
  end

  defp sample_workspace do
    root =
      Path.join([
        System.tmp_dir!(),
        "runic-ai-repl-delegation-adapter-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "# Sample\n\nhello\n")
    Workspace.new!(root: root)
  end
end
