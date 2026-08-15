defmodule RunicAI.Workflows.IntentStrategyComparator do
  @moduledoc """
  End-to-end comparator for direct, exact reuse, adaptation, fresh drafting,
  and deliberate negative selection.

  The comparator seeds and proves one reusable workflow, activates it, then
  evaluates routing truth separately from authoring and execution. Adaptation
  and fresh drafting receive isolated workspaces and independently tracked
  authoring/execution model calls so an existing artifact cannot make a failed
  arm look successful.
  """

  alias RunicAI.LLM.ReqLLMClient
  alias RunicAI.LLM.Result
  alias RunicAI.Persistence.SQLite.Store
  alias RunicAI.Persistence.WorkflowDefinitions
  alias RunicAI.Workflows.Compiler
  alias RunicAI.Workflows.IntentPlanner
  alias RunicAI.Workflows.IntentRouter

  @spec run_case(Store.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_case(%Store{} = store, eval_case, opts \\ [])
      when is_map(eval_case) and is_list(opts) do
    model = Keyword.get(opts, :model, "openai:gpt-5.6-luna")
    base_workspace = Keyword.fetch!(opts, :base_workspace)

    with {:ok, base} <- seed_proven_base(store, base_workspace, eval_case, model, opts),
         {:ok, direct_route} <- IntentRouter.route(store, direct_request(eval_case)),
         {:ok, exact_route} <- IntentRouter.route(store, base_request(eval_case)),
         {:ok, negative_route} <- IntentRouter.route(store, negative_request(eval_case)),
         {:ok, direct_agent} <- run_direct_agent_arm(eval_case, model, opts),
         {:ok, adapted} <- run_authored_arm(:adapt, store, eval_case, model, opts),
         {:ok, drafted} <- run_authored_arm(:draft, store, eval_case, model, opts) do
      rows =
        [
          route_row(:direct, :direct, direct_route),
          direct_agent,
          route_row(:reuse_exact, :reuse_exact, exact_route),
          route_row(:negative_selection, :draft, negative_route),
          adapted,
          drafted
        ]
        |> Enum.reject(&is_nil/1)

      {:ok,
       %{
         case_id: value(eval_case, :id, "intent-strategy-comparison"),
         task_family: value(eval_case, :task_family, "workflow_routing"),
         base: base_summary(base),
         rows: rows,
         all_pass?: Enum.all?(rows, &(&1.status == :pass)),
         comparison: comparison(rows)
       }}
    end
  end

  defp run_direct_agent_arm(eval_case, model, opts) do
    case Keyword.get(opts, :direct_agent) do
      nil ->
        {:ok, nil}

      executor when is_function(executor, 4) ->
        workspace = workspace_for(:direct_agent, opts)
        request = target_request(eval_case)
        base_client = Keyword.get(opts, :client, ReqLLMClient)
        {:ok, execution_tracker} = Agent.start_link(fn -> [] end)
        execution_client = tracked_client(base_client, execution_tracker)
        started = System.monotonic_time(:millisecond)

        try do
          outcome = executor.(workspace, request, model, execution_client)
          execution = mark_direct_agent_execution(outcome)
          proof = verify_outcome(execution, workspace, request, eval_case)
          execution_calls = Agent.get(execution_tracker, &Enum.reverse/1)
          passed? = proof == :ok

          {:ok,
           %{
             arm: :direct_agent,
             status: if(passed?, do: :pass, else: :fail),
             metrics: %{
               expected_strategy: :direct_agent,
               actual_strategy: :direct_agent,
               route_correct: true,
               verified_success: passed?,
               latency_ms: System.monotonic_time(:millisecond) - started,
               authoring_usage: %{calls: 0},
               execution_usage: usage_totals(execution_calls),
               total_tokens: total_tokens(execution_calls),
               authoring_calls: 0,
               execution_calls: length(execution_calls),
               execution_tool_calls: tool_call_count(execution_calls),
               semantic_change_paths: nil
             },
             diagnostics: %{
               execution: outcome_summary(execution),
               proof: proof_summary(proof)
             },
             artifacts: %{
               request: request,
               execution_calls: execution_calls,
               output_path: request.output_path,
               execution_summary: direct_agent_execution_summary(execution)
             }
           }}
        after
          Agent.stop(execution_tracker)
        end

      other ->
        {:error, {:invalid_direct_agent_executor, other}}
    end
  end

  defp mark_direct_agent_execution({:ok, execution}) when is_map(execution),
    do: {:ok, Map.put(execution, :evaluation_arm, :direct_agent)}

  defp mark_direct_agent_execution({:ok, execution}),
    do: {:ok, %{evaluation_arm: :direct_agent, result: execution}}

  defp mark_direct_agent_execution(other), do: other

  defp direct_agent_execution_summary({:ok, execution}) when is_map(execution) do
    Map.take(execution, [:evaluation_arm, :status, :objective_status, :changed_files, :tools_used])
  end

  defp direct_agent_execution_summary({:error, error}),
    do: %{status: :error, error: inspect(error)}

  defp direct_agent_execution_summary(other), do: %{status: :unknown, result: inspect(other)}

  defp seed_proven_base(store, workspace, eval_case, model, opts) do
    request = base_request(eval_case)

    planner_opts =
      [
        strategy: :workflow,
        workflow_key: value(eval_case, :base_workflow_key, "intent-comparator-base"),
        workflow_name: request.objective,
        blueprint: value(eval_case, :base_blueprint),
        dialect: Keyword.get(opts, :dialect),
        coding_proposal: Keyword.get(opts, :base_coding_proposal),
        coding_opts: Keyword.get(opts, :coding_opts),
        compile_opts: Keyword.get(opts, :compile_opts),
        model: model,
        client: Keyword.get(opts, :base_client, Keyword.get(opts, :client, ReqLLMClient)),
        write_policy: Keyword.get(opts, :write_policy, :docs_only)
      ]
      |> compact_opts()

    with {:ok, %{status: :drafted} = planned} <-
           IntentPlanner.plan(store, workspace, request, planner_opts),
         {:ok, execution} <-
           Compiler.run(
             planned.ir,
             workspace,
             request.input,
             execution_options(
               model,
               Keyword.get(opts, :base_client, Keyword.get(opts, :client)),
               opts
             ) ++
               [objective: request.objective]
           ),
         :ok <- verify(execution, workspace, request, eval_case),
         {:ok, _review} <-
           WorkflowDefinitions.request_review(store, planned.definition.workflow.id),
         {:ok, _approval} <- WorkflowDefinitions.approve(store, planned.definition.workflow.id),
         {:ok, _activation} <- WorkflowDefinitions.activate(store, planned.definition.workflow.id) do
      {:ok, %{planned: planned, execution: execution}}
    end
  end

  defp run_authored_arm(arm, store, eval_case, model, opts) do
    workspace = workspace_for(arm, opts)
    request = target_request(eval_case)
    base_client = Keyword.get(opts, :client, ReqLLMClient)
    {:ok, author_tracker} = Agent.start_link(fn -> [] end)
    {:ok, execution_tracker} = Agent.start_link(fn -> [] end)
    author_client = tracked_client(base_client, author_tracker)
    execution_client = tracked_client(base_client, execution_tracker)
    started = System.monotonic_time(:millisecond)

    try do
      plan_opts = authored_plan_opts(arm, eval_case, request, model, author_client, opts)
      planning = IntentPlanner.plan(store, workspace, request, plan_opts)

      {execution, route} =
        case planning do
          {:ok, %{status: :drafted} = planned} ->
            result =
              Compiler.run(
                planned.ir,
                workspace,
                request.input,
                execution_options(model, execution_client, opts) ++
                  [objective: request.objective]
              )

            {result, planned}

          other ->
            {{:error, :planning_failed}, other}
        end

      proof = verify_outcome(execution, workspace, request, eval_case)
      expected = arm
      actual = strategy(route)
      author_calls = Agent.get(author_tracker, &Enum.reverse/1)
      execution_calls = Agent.get(execution_tracker, &Enum.reverse/1)
      passed? = actual == expected and proof == :ok

      {:ok,
       %{
         arm: arm,
         status: if(passed?, do: :pass, else: :fail),
         metrics: %{
           expected_strategy: expected,
           actual_strategy: actual,
           route_correct: actual == expected,
           verified_success: proof == :ok,
           latency_ms: System.monotonic_time(:millisecond) - started,
           authoring_usage: usage_totals(author_calls),
           execution_usage: usage_totals(execution_calls),
           total_tokens: total_tokens(author_calls) + total_tokens(execution_calls),
           authoring_calls: length(author_calls),
           execution_calls: length(execution_calls),
           execution_tool_calls: tool_call_count(execution_calls),
           semantic_change_paths: semantic_change_paths(route)
         },
         diagnostics: %{
           planning: outcome_summary(planning),
           execution: outcome_summary(execution),
           proof: proof_summary(proof)
         },
         artifacts: %{
           request: request,
           route: route_summary(route),
           authoring_calls: author_calls,
           execution_calls: execution_calls,
           output_path: request.output_path
         }
       }}
    after
      Agent.stop(author_tracker)
      Agent.stop(execution_tracker)
    end
  end

  defp authored_plan_opts(:adapt, eval_case, _request, model, client, opts) do
    [
      strategy: :workflow,
      workflow_key: value(eval_case, :adapted_workflow_key, "intent-comparator-adapted"),
      model: model,
      client: client,
      adapt_operations: Keyword.get(opts, :adapt_operations),
      write_policy: Keyword.get(opts, :write_policy, :docs_only),
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      compile_opts: Keyword.get(opts, :compile_opts)
    ]
    |> compact_opts()
  end

  defp authored_plan_opts(:draft, eval_case, _request, model, client, opts) do
    [
      strategy: :workflow,
      exact_similarity: 2.0,
      adapt_similarity: 2.0,
      workflow_key: value(eval_case, :drafted_workflow_key, "intent-comparator-drafted"),
      blueprint: Keyword.get(opts, :draft_blueprint),
      dialect: Keyword.get(opts, :dialect),
      coding_proposal: Keyword.get(opts, :draft_coding_proposal),
      coding_opts: Keyword.get(opts, :coding_opts),
      model: model,
      client: client,
      write_policy: Keyword.get(opts, :write_policy, :docs_only),
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      compile_opts: Keyword.get(opts, :compile_opts)
    ]
    |> compact_opts()
  end

  defp route_row(arm, expected, route) do
    actual = route.strategy

    %{
      arm: arm,
      status: if(actual == expected, do: :pass, else: :fail),
      metrics: %{
        expected_strategy: expected,
        actual_strategy: actual,
        route_correct: actual == expected,
        verified_success: actual == expected,
        latency_ms: 0,
        authoring_calls: 0,
        execution_calls: 0,
        execution_tool_calls: 0,
        total_tokens: 0
      },
      diagnostics: %{reasons: route.reasons, rationale: route.rationale},
      artifacts: %{route: route_summary(route)}
    }
  end

  defp verify_outcome({:ok, execution}, workspace, request, eval_case),
    do: verify(execution, workspace, request, eval_case)

  defp verify_outcome({:error, error}, _workspace, _request, _eval_case), do: {:error, error}

  defp verify(execution, workspace, request, eval_case) do
    case value(eval_case, :verify) do
      verifier when is_function(verifier, 3) ->
        verifier.(execution, workspace, request)

      _other ->
        verify_default(execution, workspace, request)
    end
  end

  defp verify_default(execution, workspace, request) do
    path = request.output_path && Path.join(workspace.root, request.output_path)

    cond do
      not direct_agent_execution?(execution) and
          get_in(execution, [:scorecard, :objective_status]) != :objective_satisfied ->
        {:error, :objective_not_satisfied}

      not is_binary(path) or not File.regular?(path) ->
        {:error, :artifact_missing}

      true ->
        body = File.read!(path)
        missing = Enum.reject(request.required_sections, &markdown_heading?(body, &1))

        if missing == [], do: :ok, else: {:error, {:missing_sections, missing}}
    end
  end

  defp direct_agent_execution?(execution),
    do: Map.get(execution, :evaluation_arm) == :direct_agent

  defp markdown_heading?(body, section) do
    pattern =
      "^\\s*[#]{1,6}\\s+" <> Regex.escape(to_string(section)) <> "(?:\\s+[#]+)?\\s*$"

    Regex.match?(Regex.compile!(pattern, "mi"), body)
  end

  defp tracked_client(client, tracker) do
    fn model, prompt, opts ->
      started = System.monotonic_time(:millisecond)
      outcome = invoke_client(client, model, prompt, opts)

      call = %{
        model: model,
        prompt: prompt_text(prompt),
        response: response_text(outcome),
        finish_reason: outcome_finish_reason(outcome),
        tool_calls: outcome_tool_calls(outcome),
        latency_ms: System.monotonic_time(:millisecond) - started,
        usage: outcome_usage(outcome),
        status: if(successful_text_outcome?(outcome), do: :ok, else: :error)
      }

      Agent.update(tracker, &[call | &1])
      outcome
    end
  end

  defp invoke_client(client, model, prompt, opts) when is_function(client, 3),
    do: client.(model, prompt, opts)

  defp invoke_client(client, model, prompt, opts) when is_atom(client),
    do: client.generate_text(model, prompt, opts)

  defp response_text({:ok, %Result{} = result}), do: Result.text(result)

  defp response_text({:ok, %ReqLLM.Response{} = response}),
    do: ReqLLM.Response.text(response) || ""

  defp response_text(outcome), do: inspect(outcome)

  defp prompt_text(prompt) when is_binary(prompt), do: prompt

  defp prompt_text(prompt) do
    inspect(prompt, pretty: false, limit: :infinity, printable_limit: :infinity)
  end

  defp outcome_usage({:ok, %Result{usage: usage}}), do: usage || %{}
  defp outcome_usage({:ok, %ReqLLM.Response{usage: usage}}), do: usage || %{}
  defp outcome_usage(_outcome), do: %{}

  defp outcome_finish_reason({:ok, %Result{finish_reason: finish_reason}}), do: finish_reason

  defp outcome_finish_reason({:ok, %ReqLLM.Response{finish_reason: finish_reason}}),
    do: finish_reason

  defp outcome_finish_reason(_outcome), do: nil

  defp outcome_tool_calls({:ok, %Result{} = result}) do
    result
    |> tool_calls_from_raw()
    |> case do
      [] -> tool_calls_from_message(result.message)
      calls -> calls
    end
    |> Enum.map(&tool_call_summary/1)
  end

  defp outcome_tool_calls({:ok, %ReqLLM.Response{} = response}) do
    response
    |> ReqLLM.Response.tool_calls()
    |> List.wrap()
    |> Enum.map(&tool_call_summary/1)
  end

  defp outcome_tool_calls(_outcome), do: []

  defp tool_calls_from_raw(%Result{raw: %ReqLLM.Response{} = response}) do
    response
    |> ReqLLM.Response.tool_calls()
    |> List.wrap()
  end

  defp tool_calls_from_raw(_result), do: []

  defp tool_calls_from_message(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get(:tool_calls, Map.get(metadata, "tool_calls", []))
    |> List.wrap()
  end

  defp tool_calls_from_message(_message), do: []

  defp tool_call_summary(call) do
    call = ReqLLM.ToolCall.from_map(call)

    %{
      id: Map.get(call, :id),
      name: Map.get(call, :name),
      arguments: Map.get(call, :arguments, %{})
    }
  end

  defp successful_text_outcome?({:ok, %Result{}}), do: true
  defp successful_text_outcome?({:ok, %ReqLLM.Response{}}), do: true
  defp successful_text_outcome?(_outcome), do: false

  defp usage_totals(calls) do
    calls
    |> Enum.flat_map(&Map.to_list(&1.usage || %{}))
    |> Enum.reduce(%{calls: length(calls)}, fn
      {key, amount}, acc when is_number(amount) -> Map.update(acc, key, amount, &(&1 + amount))
      _entry, acc -> acc
    end)
  end

  defp total_tokens(calls) do
    calls
    |> usage_totals()
    |> value(:total_tokens, 0)
  end

  defp tool_call_count(calls) do
    Enum.reduce(calls, 0, fn call, count -> count + length(List.wrap(call.tool_calls)) end)
  end

  defp comparison(rows) do
    by_arm = Map.new(rows, &{&1.arm, &1})
    adapt = by_arm.adapt.metrics
    draft = by_arm.draft.metrics
    direct_agent = by_arm[:direct_agent] && by_arm.direct_agent.metrics

    %{
      both_verified: adapt.verified_success and draft.verified_success,
      adapt_total_tokens: adapt.total_tokens,
      draft_total_tokens: draft.total_tokens,
      token_delta: draft.total_tokens - adapt.total_tokens,
      adapt_latency_ms: adapt.latency_ms,
      draft_latency_ms: draft.latency_ms,
      latency_delta_ms: draft.latency_ms - adapt.latency_ms,
      adapt_semantic_change_paths: adapt.semantic_change_paths,
      direct_agent_verified: direct_agent && direct_agent.verified_success,
      direct_agent_total_tokens: direct_agent && direct_agent.total_tokens,
      direct_agent_latency_ms: direct_agent && direct_agent.latency_ms,
      adapt_minus_direct_tokens: direct_agent && adapt.total_tokens - direct_agent.total_tokens,
      draft_minus_direct_tokens: direct_agent && draft.total_tokens - direct_agent.total_tokens
    }
  end

  defp semantic_change_paths(%{edit: %{diff: diff}}), do: count_change_paths(diff)
  defp semantic_change_paths(_route), do: nil

  defp count_change_paths(value) when is_map(value) do
    Enum.reduce(value, 0, fn {_key, child}, acc -> acc + count_change_paths(child) end)
  end

  defp count_change_paths(value) when is_list(value), do: max(length(value), 1)
  defp count_change_paths(_value), do: 1

  defp route_summary(%{route: route} = planned) do
    route_summary(route)
    |> Map.put(:definition_hash, planned.definition.revision.semantic_hash)
    |> Map.put(:compiled_hash, planned.artifact.compiled_hash)
  end

  defp route_summary(%{strategy: strategy} = route) do
    %{
      strategy: strategy,
      rationale: route.rationale,
      reasons: route.reasons,
      selected: selected_summary(route.selected),
      candidates: Enum.map(route.candidates, &candidate_summary/1)
    }
  end

  defp route_summary(other), do: %{outcome: inspect(other)}

  defp selected_summary(nil), do: nil

  defp selected_summary(selected) do
    %{
      reference: selected.reference,
      compatible: selected.compatible?,
      adaptable: selected.adaptable?,
      objective_similarity: selected.objective_similarity
    }
  end

  defp candidate_summary(candidate) do
    %{
      reference: candidate.reference,
      compatible: candidate.compatible?,
      adaptable: candidate.adaptable?,
      objective_similarity: candidate.objective_similarity,
      reasons: candidate.reasons
    }
  end

  defp base_summary(base) do
    %{
      workflow_key: base.planned.definition.workflow.workflow_key,
      revision: base.planned.definition.revision.revision,
      definition_hash: base.planned.definition.revision.semantic_hash,
      compiled_hash: base.planned.artifact.compiled_hash,
      verified: true
    }
  end

  defp strategy(%{strategy: strategy}), do: strategy
  defp strategy({:ok, %{strategy: strategy}}), do: strategy
  defp strategy(_other), do: :error

  defp outcome_summary({:ok, %{strategy: strategy} = result}) do
    %{status: :ok, strategy: strategy, route: route_summary(result)}
  end

  defp outcome_summary({:ok, result}) when is_map(result), do: %{status: :ok}
  defp outcome_summary({:error, error}), do: %{status: :error, error: inspect(error)}
  defp outcome_summary(other), do: %{status: :error, error: inspect(other)}

  defp proof_summary(:ok), do: %{status: :pass}
  defp proof_summary({:error, reason}), do: %{status: :fail, reason: inspect(reason)}

  defp workspace_for(arm, opts) do
    case Keyword.fetch!(opts, :workspace_for) do
      fun when is_function(fun, 1) -> fun.(arm)
      workspaces when is_map(workspaces) -> Map.fetch!(workspaces, arm)
    end
  end

  defp execution_options(model, client, opts) do
    defaults = [
      model: model,
      client: client,
      async: true,
      timeout: 180_000,
      llm_timeout_ms: 180_000,
      receive_timeout: 120_000
    ]

    Keyword.merge(defaults, Keyword.get(opts, :execution_opts, []))
  end

  defp compact_opts(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)

  defp direct_request(eval_case),
    do: value(eval_case, :direct_request, %{objective: "Explain the result briefly"})

  defp base_request(eval_case), do: eval_case |> value(:base_request) |> normalize_request()
  defp target_request(eval_case), do: eval_case |> value(:target_request) |> normalize_request()
  defp negative_request(eval_case), do: value(eval_case, :negative_request)

  defp normalize_request(request) when is_map(request) do
    %{
      objective: value(request, :objective),
      input: value(request, :input, %{}),
      input_paths: value(request, :input_paths, []) |> List.wrap(),
      output_path: value(request, :output_path),
      required_sections: value(request, :required_sections, []) |> List.wrap(),
      metadata: value(request, :metadata, %{})
    }
  end

  defp value(input, key, default \\ nil) when is_map(input),
    do: Map.get(input, key, Map.get(input, Atom.to_string(key), default))
end
