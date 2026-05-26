defmodule RunicAI.RLM.REPLStateTest do
  use ExUnit.Case, async: true

  alias RunicAI.RLM.REPL.EnvironmentFunction
  alias RunicAI.RLM.REPL.PythonRuntime
  alias RunicAI.RLM.REPL.State

  test "repl state validates sandbox session handles and default mediated functions" do
    {:ok, state} =
      State.new("sandbox_session_1",
        runtime: "python",
        context_ref: "artifact://context/large.txt",
        budgets: %{llm_queries: 4, rlm_queries: 1}
      )

    assert state.runtime == :python
    assert state.sandbox_session_id == "sandbox_session_1"
    assert state.context_ref == "artifact://context/large.txt"
    assert state.budgets == %{llm_queries: 4, rlm_queries: 1}

    assert EnvironmentFunction.default_names() == [
             "peek",
             "read_slice",
             "write_artifact",
             "llm_query",
             "rlm_query",
             "delegate",
             "checkpoint",
             "set_final"
           ]

    assert Enum.map(state.environment_functions, & &1.name) == EnvironmentFunction.default_names()

    assert Enum.find(state.environment_functions, &(&1.name == "llm_query")).budget_key ==
             :llm_queries

    assert Enum.find(state.environment_functions, &(&1.name == "checkpoint")).review_required?
  end

  test "repl state records variables observations checkpoints and final result" do
    state = State.new!("sandbox_session_2")

    assert {:ok, state} =
             State.put_variable(state, "buffers", %{kind: :sandbox_variable, name: "buffers"},
               kind: :sandbox_variable
             )

    assert state.variables["buffers"].kind == :sandbox_variable

    assert {:ok, state} =
             State.add_observation(state, %{
               kind: :stdout,
               byte_size: 128,
               preview: "bounded output"
             })

    assert [%{kind: :stdout, preview: "bounded output"}] = state.observations

    assert {:ok, state} =
             State.add_checkpoint(state, %{id: "checkpoint_1", ref: "checkpoint://one"})

    assert [%{id: "checkpoint_1"}] = state.checkpoints

    assert {:ok, state} = State.set_final(state, %{answer: "done"})
    assert state.final_result == %{answer: "done"}
  end

  test "repl contracts reject unknown runtimes and function kinds without atomizing strings" do
    assert {:error, error} = State.new("sandbox_session_3", runtime: "ruby")
    assert error.kind == :validation
    assert error.details.valid_runtimes == State.runtimes()

    assert {:ok, function} =
             EnvironmentFunction.new(%{
               "name" => "custom_peek",
               "arity" => 1,
               "kind" => "context_read",
               "budget_key" => :environment_reads,
               "review_required?" => false
             })

    assert function.kind == :context_read

    assert {:error, error} =
             EnvironmentFunction.new(%{
               name: "bad",
               arity: 1,
               kind: "unknown",
               review_required?: false
             })

    assert error.kind == :validation
    assert error.details.kind == "unknown"
  end

  test "repl state enforces llm and recursive query budgets and batch sizes" do
    state =
      State.new!("sandbox_session_budget",
        budgets: %{
          llm_queries: %{limit: 3, used: 0, max_batch_size: 2},
          rlm_queries: 1
        }
      )

    assert State.budget_status(state, :llm_queries) == %{
             limit: 3,
             used: 0,
             remaining: 3,
             max_batch_size: 2
           }

    assert :ok = State.validate_batch(state, :llm_queries, 2)

    assert {:error, error} = State.validate_batch(state, :llm_queries, 3)
    assert error.kind == :validation
    assert error.details.max_batch_size == 2

    assert {:ok, state} = State.consume_budget(state, :llm_queries, 2)
    assert State.budget_status(state, :llm_queries).remaining == 1

    assert {:error, error} = State.consume_budget(state, :llm_queries, 2)
    assert error.kind == :validation
    assert error.details.budget_key == :llm_queries

    assert {:ok, state} = State.consume_budget(state, :rlm_queries)
    assert State.budget_status(state, :rlm_queries).remaining == 0

    assert {:error, error} = State.consume_budget(state, :rlm_queries)
    assert error.kind == :validation
    assert error.details.budget_key == :rlm_queries

    assert {:error, error} =
             State.new("sandbox_session_bad_budget",
               budgets: %{llm_queries: %{limit: 1, used: 2}}
             )

    assert error.kind == :validation
    assert error.details.budget_key == :llm_queries
    assert error.details.used == 2
  end

  test "python runtime executes one sandbox turn and records bounded observations" do
    stdout =
      """
      before
      #{PythonRuntime.final_marker()}{"answer":"done","count":2}
      after
      """

    {:ok, registry} =
      RunicAI.REPLFakeSandboxRegistry.start_link(
        response:
          {:ok,
           %{
             status: :ok,
             stdout: stdout,
             stderr: "warning output",
             exit_status: 0,
             duration_ms: 12,
             backend: :docker,
             isolation_level: :container
           }}
      )

    state =
      State.new!("sandbox_session_42",
        variables: %{
          "items" => %{value: ["a", "b"], kind: :value},
          "missing" => %{value: nil, kind: :value}
        }
      )

    assert {:ok, result} =
             PythonRuntime.execute_turn(
               state,
               "print('turn ran')\nset_final({'answer': 'ignored-by-fake'})",
               registry,
               max_observation_bytes: 8,
               final_schema: %{required: ["answer"]}
             )

    assert result.final_result == %{"answer" => "done", "count" => 2}
    assert result.state.final_result == %{"answer" => "done", "count" => 2}

    assert [
             %{
               kind: :python_turn,
               stdout_preview: "before\na",
               stderr_preview: "warning ",
               stdout_bytes: 12,
               stderr_bytes: 14,
               truncated?: true
             }
           ] = result.state.observations

    assert [%{session_id: "sandbox_session_42", request: request}] =
             RunicAI.REPLFakeSandboxRegistry.requests(registry)

    assert request.runtime == :python
    assert request.source =~ "def llm_query"
    assert request.source =~ "set_final({'answer': 'ignored-by-fake'})"
    assert request.source =~ ~s(\\"items\\":[\\"a\\",\\"b\\"])
    assert request.source =~ ~s(\\"missing\\":null)
  end

  test "python runtime exposes read_slice over injected context variables" do
    python = System.find_executable("python3") || System.find_executable("python")

    {:ok, registry} =
      RunicAI.REPLFakeSandboxRegistry.start_link(
        response: fn %{request: request} ->
          if python do
            {output, exit_status} =
              System.cmd(python, ["-c", request.source], stderr_to_stdout: true)

            {:ok,
             %{
               status: if(exit_status == 0, do: :ok, else: :error),
               stdout: output,
               stderr: "",
               exit_status: exit_status,
               duration_ms: 1,
               backend: :test_python,
               isolation_level: :host_process
             }}
          else
            {:ok,
             %{
               status: :ok,
               stdout:
                 PythonRuntime.final_marker() <>
                   ~s({"chunk_count":3,"first_chunk":"alpha needle","needle_mentions":2}),
               stderr: "",
               exit_status: 0,
               duration_ms: 1,
               backend: :fake,
               isolation_level: :fake
             }}
          end
        end
      )

    context = "alpha needle\nbeta clean\ngamma needle\n"

    state =
      State.new!("sandbox_session_context",
        variables: %{"context" => %{value: context, kind: :external_ref}}
      )

    code = """
    text = peek("context")
    chunks = [read_slice("context", {"offset": offset, "length": 13}) for offset in range(0, len(text), 13)]
    subquery_results = [
        {"chunk": index, "needle_mentions": chunk.count("needle"), "preview": chunk}
        for index, chunk in enumerate(chunks)
    ]
    set_final({
        "chunk_count": len(chunks),
        "needle_mentions": sum(item["needle_mentions"] for item in subquery_results),
        "first_chunk": read_slice("context", 0, 12)
    })
    """

    assert {:ok, result} =
             PythonRuntime.execute_turn(state, code, registry,
               final_schema: %{required: ["chunk_count", "needle_mentions"]}
             )

    assert result.final_result["chunk_count"] >= 3
    assert result.final_result["needle_mentions"] == 2
    assert result.final_result["first_chunk"] == "alpha needle"

    assert [%{request: request}] = RunicAI.REPLFakeSandboxRegistry.requests(registry)
    assert request.source =~ "def read_slice"
    assert request.source =~ ~s(\\"context\\":\\"alpha needle)
  end

  test "python runtime validates final result schemas" do
    {:ok, registry} =
      RunicAI.REPLFakeSandboxRegistry.start_link(
        response:
          {:ok,
           %{
             status: :ok,
             stdout: PythonRuntime.final_marker() <> ~s({"other":"value"}),
             stderr: "",
             exit_status: 0
           }}
      )

    state = State.new!("sandbox_session_43")

    assert {:error, error} =
             PythonRuntime.execute_turn(state, "set_final({'other': 'value'})", registry,
               final_schema: %{required: ["answer"]}
             )

    assert error.kind == :validation
    assert error.details.missing_required == ["answer"]
  end
end
