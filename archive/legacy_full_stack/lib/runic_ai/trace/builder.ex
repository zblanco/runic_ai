defmodule RunicAI.Trace.Builder do
  @moduledoc false

  alias Runic.Workflow
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Agent.State
  alias RunicAI.Control.BudgetDecision
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.Result, as: ChildResult
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.Session
  alias RunicAI.Integrated.Emission
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Integrated.Signal
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Memory.ReadResult
  alias RunicAI.Prompt
  alias RunicAI.ResumeSignal
  alias RunicAI.Retrieval.Result, as: RetrievalResult
  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest
  alias RunicAI.Tool.BatchResult
  alias RunicAI.Tool.CallRequest
  alias RunicAI.Tool.CallResult
  alias RunicAI.Tool.ExecutionPlan
  alias RunicAI.Trace.CapturePolicy
  alias RunicAI.Trace.Event
  alias RunicAI.Wait
  alias ReqLLM.Response, as: ReqLLMResponse

  @spec events_from_workflow(Workflow.t(), Session.t(), term(), map(), Policy.t(), keyword()) ::
          [Event.t()]
  def events_from_workflow(
        %Workflow{} = workflow,
        %Session{} = session,
        input,
        output,
        %Policy{} = policy,
        opts \\ []
      ) do
    capture_policy = policy.capture_policy || CapturePolicy.new!()
    elapsed_ms = Keyword.get(opts, :elapsed_ms, 0)

    initial_events =
      submitted_input_events(input, session, capture_policy)

    raw_events =
      workflow
      |> Workflow.raw_productions()
      |> Enum.reverse()
      |> Enum.reduce(
        {[], %{pending_turn_request: nil, capture_policy: capture_policy, session: session}},
        fn
          fact, {events, context} ->
            {new_events, updated_context} = fact_events(fact, context)
            {events ++ new_events, updated_context}
        end
      )
      |> elem(0)

    initial_events ++
      raw_events ++ terminal_events(output, session, capture_policy, elapsed_ms, raw_events)
  end

  @spec failure_events(Session.t(), term(), Exception.t() | term(), Policy.t(), keyword()) :: [
          Event.t()
        ]
  def failure_events(%Session{} = session, input, reason, %Policy{} = policy, opts \\ []) do
    capture_policy = policy.capture_policy || CapturePolicy.new!()
    elapsed_ms = Keyword.get(opts, :elapsed_ms, 0)

    submitted_input_events(input, session, capture_policy) ++
      [
        Event.new!(
          :workflow_failed,
          recipe: session.recipe,
          agent_id: current_agent_id(input, session),
          status: :error,
          input: CapturePolicy.capture(capture_policy, input, field: :input),
          output: CapturePolicy.capture(capture_policy, reason, field: :output),
          measurements: %{elapsed_ms: elapsed_ms},
          metadata: %{session_id: session.id}
        )
      ]
  end

  defp submitted_input_events(%ReviewDecision{} = review_decision, %Session{} = session, policy) do
    [
      Event.new!(
        :review_resolution_submitted,
        recipe: session.recipe,
        agent_id: current_agent_id(review_decision, session),
        input: CapturePolicy.capture(policy, review_decision, field: :input),
        metadata: %{session_id: session.id}
      )
    ]
  end

  defp submitted_input_events(%ResumeSignal{} = resume_signal, %Session{} = session, policy) do
    [
      Event.new!(
        :resume_submitted,
        recipe: session.recipe,
        agent_id: current_agent_id(resume_signal, session),
        input: CapturePolicy.capture(policy, resume_signal, field: :input),
        metadata: %{session_id: session.id}
      )
    ]
  end

  defp submitted_input_events(%{kind: kind} = signal, %Session{} = session, policy)
       when kind in [:review_decision, :resume, :wake, :stop, :spawn] do
    event_kind =
      case kind do
        :review_decision -> :review_resolution_submitted
        :resume -> :resume_submitted
        :wake -> :wake_submitted
        _ -> :signal_submitted
      end

    [
      Event.new!(
        event_kind,
        recipe: session.recipe,
        agent_id: current_agent_id(signal, session),
        input: CapturePolicy.capture(policy, signal, field: :input),
        metadata: %{session_id: session.id}
      )
    ]
  end

  defp submitted_input_events(_input, _session, _policy), do: []

  defp fact_events(%TurnRequest{} = turn_request, context) do
    event =
      Event.new!(
        :turn_started,
        recipe: context.session.recipe,
        agent_id: current_agent_id(turn_request, context.session),
        input: CapturePolicy.capture(context.capture_policy, turn_request, field: :input),
        metadata: %{session_id: context.session.id}
      )

    {[event], %{context | pending_turn_request: turn_request}}
  end

  defp fact_events(%Signal{} = signal, context) do
    if Signal.turn_signal?(signal) do
      event =
        Event.new!(
          :turn_started,
          recipe: context.session.recipe,
          agent_id: signal.agent_id,
          input: CapturePolicy.capture(context.capture_policy, signal, field: :input),
          metadata: %{session_id: context.session.id}
        )

      {[event], context}
    else
      {[], context}
    end
  end

  defp fact_events(%{session: %SessionState{} = session, signal: %Signal{} = signal}, context) do
    if Signal.turn_signal?(signal) do
      llm_request =
        Event.new!(
          :llm_request,
          recipe: context.session.recipe,
          agent_id: session.agent.id,
          input:
            CapturePolicy.capture(
              context.capture_policy,
              %{
                signal: signal,
                turn_defaults: Map.get(session.metadata, :turn_defaults, %{})
              },
              field: :input
            ),
          metadata: %{session_id: context.session.id}
        )

      {[llm_request], context}
    else
      {[], context}
    end
  end

  defp fact_events(%{session: %SessionState{} = session, emissions: emissions}, context)
       when is_list(emissions) do
    events =
      session
      |> integrated_session_events(context)
      |> Kernel.++(
        Enum.flat_map(emissions, fn
          %Emission{kind: :review, value: %ReviewRequest{} = review_request} = emission ->
            [
              Event.new!(
                :review_requested,
                recipe: context.session.recipe,
                agent_id: emission.agent_id,
                status: :review,
                output:
                  CapturePolicy.capture(
                    context.capture_policy,
                    review_request,
                    field: :output
                  ),
                metadata: %{
                  session_id: context.session.id,
                  checkpoint: review_request.checkpoint
                }
              ),
              Event.new!(
                :emission,
                recipe: context.session.recipe,
                agent_id: emission.agent_id,
                status: emission.kind,
                output: CapturePolicy.capture(context.capture_policy, emission, field: :output),
                metadata: %{session_id: context.session.id}
              )
            ]

          %Emission{kind: :wait, value: %Wait{} = wait} = emission ->
            [
              Event.new!(
                :wait_registered,
                recipe: context.session.recipe,
                agent_id: emission.agent_id,
                status: :wait,
                output: CapturePolicy.capture(context.capture_policy, wait, field: :output),
                metadata: %{session_id: context.session.id, reason: wait.reason}
              ),
              Event.new!(
                :emission,
                recipe: context.session.recipe,
                agent_id: emission.agent_id,
                status: emission.kind,
                output: CapturePolicy.capture(context.capture_policy, emission, field: :output),
                metadata: %{session_id: context.session.id}
              )
            ]

          %Emission{} = emission ->
            [
              Event.new!(
                :emission,
                recipe: context.session.recipe,
                agent_id: emission.agent_id,
                status: emission.kind,
                output: CapturePolicy.capture(context.capture_policy, emission, field: :output),
                metadata: %{session_id: context.session.id}
              )
            ]

          _other ->
            []
        end)
      )

    {events, context}
  end

  defp fact_events(
         %Prompt{} = prompt,
         %{pending_turn_request: %TurnRequest{} = turn_request} = context
       ) do
    event =
      Event.new!(
        :llm_request,
        recipe: context.session.recipe,
        agent_id: current_agent_id(turn_request, context.session),
        input:
          CapturePolicy.capture(
            context.capture_policy,
            %{turn_request: turn_request, prompt: prompt},
            field: :input
          ),
        metadata: %{session_id: context.session.id, model: turn_request.model}
      )

    {[event], %{context | pending_turn_request: nil}}
  end

  defp fact_events(%Prompt{} = prompt, context) do
    event =
      Event.new!(
        :llm_request,
        recipe: context.session.recipe,
        agent_id: current_agent_id(prompt, context.session),
        input: CapturePolicy.capture(context.capture_policy, prompt, field: :input),
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events({:ok, %LLMResult{} = result}, context), do: fact_events(result, context)
  defp fact_events({:ok, %ReqLLMResponse{} = result}, context), do: fact_events(result, context)

  defp fact_events(%LLMResult{} = result, context) do
    event =
      Event.new!(
        :llm_result,
        recipe: context.session.recipe,
        agent_id: current_agent_id(result, context.session),
        output: CapturePolicy.capture(context.capture_policy, result, field: :output),
        measurements: normalize_usage(result.usage),
        metadata: %{session_id: context.session.id, finish_reason: result.finish_reason}
      )

    {[event], context}
  end

  defp fact_events(%ReqLLMResponse{} = result, context) do
    event =
      Event.new!(
        :llm_result,
        recipe: context.session.recipe,
        agent_id: current_agent_id(result, context.session),
        output: CapturePolicy.capture(context.capture_policy, result, field: :output),
        measurements: normalize_usage(result.usage),
        metadata: %{session_id: context.session.id, finish_reason: result.finish_reason}
      )

    {[event], context}
  end

  defp fact_events(%ExecutionPlan{} = execution_plan, context) do
    plan_event =
      Event.new!(
        :tool_plan,
        recipe: context.session.recipe,
        agent_id: current_agent_id(execution_plan, context.session),
        output: CapturePolicy.capture(context.capture_policy, execution_plan, field: :output),
        measurements: %{tool_calls: length(execution_plan.calls)},
        metadata: %{session_id: context.session.id}
      )

    call_events =
      Enum.map(execution_plan.calls, fn %CallRequest{} = call_request ->
        Event.new!(
          :tool_call,
          recipe: context.session.recipe,
          agent_id: current_agent_id(call_request, context.session),
          output: CapturePolicy.capture(context.capture_policy, call_request, field: :output),
          metadata: %{session_id: context.session.id, tool_name: call_request.tool_name}
        )
      end)

    {[plan_event | call_events], context}
  end

  defp fact_events(%BatchResult{} = batch_result, context) do
    events =
      Enum.map(batch_result.results, fn %CallResult{} = call_result ->
        Event.new!(
          :tool_result,
          recipe: context.session.recipe,
          agent_id: current_agent_id(call_result, context.session),
          status: call_result.status,
          output: CapturePolicy.capture(context.capture_policy, call_result, field: :output),
          measurements: call_result_measurements(call_result),
          metadata: %{session_id: context.session.id, tool_name: call_result.request.tool_name}
        )
      end)

    {events, context}
  end

  defp fact_events(%BudgetDecision{} = budget_decision, context) do
    event =
      Event.new!(
        :budget_decision,
        recipe: context.session.recipe,
        agent_id: current_agent_id(budget_decision, context.session),
        status: budget_decision.status,
        output: CapturePolicy.capture(context.capture_policy, budget_decision, field: :output),
        measurements: %{estimated_cost: budget_decision.snapshot.estimated_cost || 0.0},
        metadata: %{session_id: context.session.id, action: budget_decision.action}
      )

    {[event], context}
  end

  defp fact_events(%GuardDecision{} = guard_decision, context) do
    event =
      Event.new!(
        :guard_decision,
        recipe: context.session.recipe,
        agent_id: current_agent_id(guard_decision, context.session),
        status: guard_decision.action,
        output: CapturePolicy.capture(context.capture_policy, guard_decision, field: :output),
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(%RetrievalResult{} = retrieval_result, context) do
    event =
      Event.new!(
        :retrieval_result,
        recipe: context.session.recipe,
        agent_id: current_agent_id(retrieval_result, context.session),
        output: CapturePolicy.capture(context.capture_policy, retrieval_result, field: :output),
        measurements: %{documents: length(retrieval_result.documents)},
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(%ReadResult{} = read_result, context) do
    event =
      Event.new!(
        :memory_result,
        recipe: context.session.recipe,
        agent_id: current_agent_id(read_result, context.session),
        output: CapturePolicy.capture(context.capture_policy, read_result, field: :output),
        measurements: %{entries: length(read_result.entries)},
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(%ReviewRequest{} = review_request, context) do
    event =
      Event.new!(
        :review_requested,
        recipe: context.session.recipe,
        agent_id: current_agent_id(review_request, context.session),
        status: :review,
        output: CapturePolicy.capture(context.capture_policy, review_request, field: :output),
        metadata: %{session_id: context.session.id, checkpoint: review_request.checkpoint}
      )

    {[event], context}
  end

  defp fact_events(%Wait{} = wait, context) do
    event =
      Event.new!(
        :wait_registered,
        recipe: context.session.recipe,
        agent_id: current_agent_id(wait, context.session),
        status: :wait,
        output: CapturePolicy.capture(context.capture_policy, wait, field: :output),
        metadata: %{session_id: context.session.id, reason: wait.reason}
      )

    {[event], context}
  end

  defp fact_events(%Assignment{} = assignment, context) do
    event =
      Event.new!(
        :child_assignment,
        recipe: context.session.recipe,
        agent_id: current_agent_id(assignment, context.session),
        output: CapturePolicy.capture(context.capture_policy, assignment, field: :output),
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(%ChildResult{} = result, context) do
    event =
      Event.new!(
        :child_result,
        recipe: context.session.recipe,
        agent_id: current_agent_id(result, context.session),
        status: result.status,
        output: CapturePolicy.capture(context.capture_policy, result, field: :output),
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(%Emission{} = emission, context) do
    event =
      Event.new!(
        :emission,
        recipe: context.session.recipe,
        agent_id: emission.agent_id,
        status: emission.kind,
        output: CapturePolicy.capture(context.capture_policy, emission, field: :output),
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(%TurnResult{} = turn_result, context) do
    event =
      Event.new!(
        :turn_completed,
        recipe: context.session.recipe,
        agent_id: current_agent_id(turn_result, context.session),
        status: turn_result.kind,
        output: CapturePolicy.capture(context.capture_policy, turn_result, field: :output),
        metadata: %{session_id: context.session.id}
      )

    {[event], context}
  end

  defp fact_events(_fact, context), do: {[], context}

  defp terminal_events(output, %Session{} = session, capture_policy, elapsed_ms, raw_events) do
    (recovered_output_events(output, session, capture_policy, raw_events) ++
       [
         maybe_output_event(output, session, capture_policy, raw_events),
         workflow_quiesced_event(output, session, capture_policy, elapsed_ms)
       ])
    |> Enum.reject(&is_nil/1)
  end

  defp recovered_output_events(
         %{state: %State{} = state},
         %Session{} = session,
         capture_policy,
         raw_events
       ) do
    if Enum.any?(raw_events, &(&1.kind in [:tool_call, :tool_result])) do
      []
    else
      recover_conversation_tool_events(state, session, capture_policy)
    end
  end

  defp recovered_output_events(_output, _session, _capture_policy, _raw_events), do: []

  defp maybe_output_event(
         %{review_request: %ReviewRequest{} = review_request},
         %Session{} = session,
         capture_policy,
         raw_events
       ) do
    if Enum.any?(raw_events, &(&1.kind == :review_requested)) do
      nil
    else
      Event.new!(
        :review_requested,
        recipe: session.recipe,
        agent_id: current_agent_id(review_request, session),
        status: :review,
        output: CapturePolicy.capture(capture_policy, review_request, field: :output),
        metadata: %{session_id: session.id, source: :output}
      )
    end
  end

  defp maybe_output_event(
         %{wait: %Wait{} = wait},
         %Session{} = session,
         capture_policy,
         raw_events
       ) do
    if Enum.any?(raw_events, &(&1.kind == :wait_registered)) do
      nil
    else
      Event.new!(
        :wait_registered,
        recipe: session.recipe,
        agent_id: current_agent_id(wait, session),
        status: :wait,
        output: CapturePolicy.capture(capture_policy, wait, field: :output),
        metadata: %{session_id: session.id, source: :output}
      )
    end
  end

  defp maybe_output_event(_output, _session, _capture_policy, _raw_events), do: nil

  defp workflow_quiesced_event(output, %Session{} = session, capture_policy, elapsed_ms) do
    Event.new!(
      :workflow_quiesced,
      recipe: session.recipe,
      agent_id: current_agent_id(output, session),
      status: output_status(output),
      output: CapturePolicy.capture(capture_policy, output, field: :output),
      measurements: %{elapsed_ms: elapsed_ms},
      metadata: %{session_id: session.id}
    )
  end

  defp normalize_usage(usage) when is_map(usage), do: usage
  defp normalize_usage(_usage), do: %{}

  defp call_result_measurements(%CallResult{} = call_result) do
    elapsed_ms =
      case {call_result.started_at, call_result.completed_at} do
        {%DateTime{} = started_at, %DateTime{} = completed_at} ->
          DateTime.diff(completed_at, started_at, :millisecond)

        _ ->
          0
      end

    %{elapsed_ms: elapsed_ms}
  end

  defp current_agent_id(%{agent_id: agent_id}, _session) when is_binary(agent_id), do: agent_id

  defp current_agent_id(%{agent: %{id: agent_id}}, _session) when is_binary(agent_id),
    do: agent_id

  defp current_agent_id(%SessionState{agent: %{id: agent_id}}, _session) when is_binary(agent_id),
    do: agent_id

  defp current_agent_id(%{metadata: metadata}, _session) when is_map(metadata),
    do: Map.get(metadata, :agent_id) || Map.get(metadata, "agent_id")

  defp current_agent_id(%ResumeSignal{resume_key: resume_key}, _session)
       when is_binary(resume_key),
       do: nil

  defp current_agent_id(%ReviewDecision{resume_key: _resume_key}, _session), do: nil

  defp current_agent_id(_value, %Session{snapshot: %{agent: %{id: agent_id}}})
       when is_binary(agent_id),
       do: agent_id

  defp current_agent_id(_value, _session), do: nil

  defp output_status(%{review_request: %ReviewRequest{}}), do: :review
  defp output_status(%{wait: %Wait{}}), do: :wait
  defp output_status(%{turn_result: %TurnResult{kind: kind}}), do: kind
  defp output_status(%{emissions: emissions}) when is_list(emissions), do: :ok
  defp output_status(_output), do: :ok

  defp integrated_session_events(%SessionState{} = session, context) do
    case session.agent_state.last_turn_result do
      %TurnResult{} = turn_result ->
        tool_events =
          if turn_result.kind == :tool_requests do
            session.control
            |> Map.get(:last_tool_traces, [])
            |> Enum.flat_map(fn
              %{execution_plan: %ExecutionPlan{} = execution_plan, batch_result: batch_result} ->
                plan_event =
                  Event.new!(
                    :tool_plan,
                    recipe: context.session.recipe,
                    agent_id: session.agent.id,
                    output:
                      CapturePolicy.capture(
                        context.capture_policy,
                        execution_plan,
                        field: :output
                      ),
                    measurements: %{tool_calls: length(execution_plan.calls)},
                    metadata: %{session_id: context.session.id}
                  )

                call_events =
                  Enum.map(execution_plan.calls, fn %CallRequest{} = call_request ->
                    Event.new!(
                      :tool_call,
                      recipe: context.session.recipe,
                      agent_id: session.agent.id,
                      output:
                        CapturePolicy.capture(
                          context.capture_policy,
                          call_request,
                          field: :output
                        ),
                      metadata: %{
                        session_id: context.session.id,
                        tool_name: call_request.tool_name
                      }
                    )
                  end)

                result_events =
                  case batch_result do
                    %BatchResult{} = batch_result ->
                      Enum.map(batch_result.results, fn %CallResult{} = call_result ->
                        Event.new!(
                          :tool_result,
                          recipe: context.session.recipe,
                          agent_id: session.agent.id,
                          status: call_result.status,
                          output:
                            CapturePolicy.capture(
                              context.capture_policy,
                              call_result,
                              field: :output
                            ),
                          measurements: call_result_measurements(call_result),
                          metadata: %{
                            session_id: context.session.id,
                            tool_name: call_result.request.tool_name
                          }
                        )
                      end)

                    _ ->
                      []
                  end

                [plan_event | call_events] ++ result_events

              _ ->
                []
            end)
          else
            []
          end

        llm_result_events =
          case turn_result.raw do
            %LLMResult{} = result ->
              [
                Event.new!(
                  :llm_result,
                  recipe: context.session.recipe,
                  agent_id: session.agent.id,
                  output: CapturePolicy.capture(context.capture_policy, result, field: :output),
                  measurements: normalize_usage(result.usage),
                  metadata: %{session_id: context.session.id, finish_reason: result.finish_reason}
                )
              ]

            _ ->
              []
          end

        tool_events ++
          llm_result_events ++
          [
            Event.new!(
              :turn_completed,
              recipe: context.session.recipe,
              agent_id: session.agent.id,
              status: turn_result.kind,
              output: CapturePolicy.capture(context.capture_policy, turn_result, field: :output),
              metadata: %{session_id: context.session.id}
            )
          ]

      _ ->
        []
    end
  end

  defp recover_conversation_tool_events(%State{} = state, %Session{} = session, capture_policy) do
    {events, _pending_calls} =
      Enum.reduce(state.conversation.messages, {[], %{}}, fn
        %RunicAI.Message{role: :assistant, metadata: metadata} = message,
        {events, _pending_calls} ->
          tool_calls =
            Map.get(metadata || %{}, :tool_calls) || Map.get(metadata || %{}, "tool_calls") || []

          if tool_calls == [] do
            {events, %{}}
          else
            call_requests =
              tool_calls
              |> Enum.with_index()
              |> Enum.map(fn {tool_call, request_index} ->
                CallRequest.from_provider!(tool_call, request_index: request_index)
              end)

            plan = ExecutionPlan.new!(call_requests, metadata: %{reason: :recovered})

            llm_result =
              LLMResult.new!(message,
                finish_reason: :tool_calls,
                usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
              )

            llm_result_event =
              Event.new!(
                :llm_result,
                recipe: session.recipe,
                agent_id: current_agent_id(state, session),
                output: CapturePolicy.capture(capture_policy, llm_result, field: :output),
                measurements: normalize_usage(llm_result.usage),
                metadata: %{session_id: session.id, finish_reason: llm_result.finish_reason}
              )

            plan_event =
              Event.new!(
                :tool_plan,
                recipe: session.recipe,
                agent_id: current_agent_id(state, session),
                output: CapturePolicy.capture(capture_policy, plan, field: :output),
                measurements: %{tool_calls: length(call_requests)},
                metadata: %{session_id: session.id, recovered: true}
              )

            call_events =
              Enum.map(call_requests, fn %CallRequest{} = call_request ->
                Event.new!(
                  :tool_call,
                  recipe: session.recipe,
                  agent_id: current_agent_id(state, session),
                  output: CapturePolicy.capture(capture_policy, call_request, field: :output),
                  metadata: %{
                    session_id: session.id,
                    tool_name: call_request.tool_name,
                    recovered: true
                  }
                )
              end)

            pending_calls = Map.new(call_requests, &{&1.id, &1})

            {events ++ [llm_result_event, plan_event | call_events], pending_calls}
          end

        %RunicAI.Message{role: :tool, name: tool_name, metadata: metadata, content: content},
        {events, pending_calls} ->
          tool_call_id =
            Map.get(metadata || %{}, :tool_call_id) || Map.get(metadata || %{}, "tool_call_id")

          call_request =
            Map.get(pending_calls, tool_call_id) ||
              Enum.find_value(pending_calls, fn {_id, request} ->
                if request.tool_name == tool_name, do: request
              end)

          if is_nil(call_request) do
            {events, pending_calls}
          else
            output =
              Map.get(metadata || %{}, :tool_output) || Map.get(metadata || %{}, "tool_output") ||
                content

            call_result =
              CallResult.ok!(call_request, output, metadata: %{recovered: true})

            event =
              Event.new!(
                :tool_result,
                recipe: session.recipe,
                agent_id: current_agent_id(state, session),
                status: :ok,
                output: CapturePolicy.capture(capture_policy, call_result, field: :output),
                measurements: call_result_measurements(call_result),
                metadata: %{
                  session_id: session.id,
                  tool_name: call_request.tool_name,
                  recovered: true
                }
              )

            {events ++ [event], Map.delete(pending_calls, call_request.id)}
          end

        _message, acc ->
          acc
      end)

    events
  end
end
