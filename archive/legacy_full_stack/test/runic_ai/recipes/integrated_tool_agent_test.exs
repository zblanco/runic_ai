defmodule RunicAI.Recipes.IntegratedToolAgentTest do
  use ExUnit.Case, async: true

  alias Runic.Workflow
  alias RunicAI.Control.GuardDecision
  alias RunicAI.Error
  alias RunicAI.Prompt
  alias RunicAI.Recipes.IntegratedToolAgent
  alias RunicAI.Tool.Definition

  test "resolves a tool loop to quiescence inside one workflow-owned run" do
    workflow =
      IntegratedToolAgent.new(
        default_agent_id: "agent",
        model: "test:model",
        registry: [weather_tool()],
        client: weather_client()
      )
      |> Workflow.react_until_satisfied(%{user: "What's the weather in Paris?"})

    session = IntegratedToolAgent.session(workflow, "agent")

    assert IntegratedToolAgent.latest_reply_text(workflow, "agent") == "Paris is sunny."
    assert session.status == :idle
    assert session.agent_state.conversation.turns == 2

    assert Enum.map(session.agent_state.conversation.messages, & &1.role) == [
             :user,
             :assistant,
             :tool,
             :assistant
           ]
  end

  test "retains provider error evidence when generation halts before a response" do
    client = fn _model, _prompt, _opts ->
      {:error,
       Error.provider("generation failed",
         source: RunicAI.LLM.ReqLLMClient,
         details: %{
           requested_model: "openai:gpt-5.6-sol",
           status: 400,
           reason_type: "ReqLLM.Error.API.Request",
           reason_message: "unsupported option"
         }
       )}
    end

    workflow =
      IntegratedToolAgent.new(
        default_agent_id: "agent",
        model: "openai:gpt-5.6-sol",
        registry: [weather_tool()],
        client: client,
        generation_retry_policy: [max_attempts: 1]
      )
      |> Workflow.react_until_satisfied(%{user: "Make a change"})

    session = IntegratedToolAgent.session(workflow, "agent")

    assert session.status == :halted

    assert [evidence] = session.control.generation_evidence
    assert evidence.requested_model == "openai:gpt-5.6-sol"
    assert evidence.status == 400
    assert evidence.reason_message == "unsupported option"
  end

  test "pauses for review and resumes through the same workflow runtime" do
    workflow =
      IntegratedToolAgent.new(
        default_agent_id: "agent",
        model: "test:model",
        registry: [weather_tool()],
        client: weather_client(),
        pre_tool_guard: fn _request -> :review end
      )
      |> Workflow.react_until_satisfied(%{user: "What's the weather in Paris?"})

    review_request = IntegratedToolAgent.latest_review_request(workflow, "agent")
    session = IntegratedToolAgent.session(workflow, "agent")

    assert review_request.checkpoint == :pre_tool
    assert session.status == :review

    workflow =
      Workflow.react_until_satisfied(
        workflow,
        %{review_decision: %{resume_key: review_request.resume_key, status: :approved}}
      )

    resumed_session = IntegratedToolAgent.session(workflow, "agent")

    assert IntegratedToolAgent.latest_reply_text(workflow, "agent") == "Paris is sunny."
    assert resumed_session.status == :idle
    assert resumed_session.pending_work == nil
  end

  test "tool_requirement :required relaxes after the first tool batch during review resume" do
    client = fn _model, %Prompt{messages: messages}, opts ->
      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          assert opts[:tool_choice] == :required

          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: "Paris"}, id: "call_1")
             ],
             "Let me check."
           )}

        tool_message ->
          assert tool_message.content =~ "\"sunny\""
          assert opts[:tool_choice] == :auto
          {:ok, RunicAI.LLM.TestClient.result("Paris is sunny.")}
      end
    end

    workflow =
      IntegratedToolAgent.new(
        default_agent_id: "agent",
        model: "test:model",
        registry: [weather_tool()],
        client: client,
        tool_requirement: :required,
        pre_tool_guard: fn _request -> :review end
      )
      |> Workflow.react_until_satisfied(%{user: "What's the weather in Paris?"})

    review_request = IntegratedToolAgent.latest_review_request(workflow, "agent")

    workflow =
      Workflow.react_until_satisfied(
        workflow,
        %{review_decision: %{resume_key: review_request.resume_key, status: :approved}}
      )

    assert IntegratedToolAgent.latest_reply_text(workflow, "agent") == "Paris is sunny."
    session = IntegratedToolAgent.session(workflow, "agent")

    assert session.status == :idle

    assert Enum.map(session.control.generation_evidence, & &1.tool_call_count) == [1, 0]
  end

  test "keeps one agent waiting while another agent completes independently" do
    workflow =
      IntegratedToolAgent.new(
        model: "test:model",
        registry: [weather_tool()],
        client: weather_client(),
        agents: [
          [id: "alpha"],
          [id: "beta"]
        ],
        pre_tool_guard: fn request ->
          location =
            request.execution_plan.calls
            |> List.first()
            |> Map.get(:arguments)
            |> Map.get(:location)

          if location == "Paris" do
            GuardDecision.wait!(:hold,
              metadata: %{until: DateTime.add(DateTime.utc_now(), 60, :second)}
            )
          else
            :allow
          end
        end
      )
      |> Workflow.react_until_satisfied(%{
        agent_id: "alpha",
        user: "What's the weather in Paris?"
      })
      |> Workflow.react_until_satisfied(%{
        agent_id: "beta",
        user: "What's the weather in Berlin?"
      })

    alpha = IntegratedToolAgent.session(workflow, "alpha")
    beta = IntegratedToolAgent.session(workflow, "beta")

    assert alpha.status == :waiting
    assert match?(%RunicAI.Wait{}, alpha.pending_work.request)
    assert beta.status == :idle
    assert List.last(beta.agent_state.conversation.messages).content == "Berlin is sunny."
  end

  test "resumes a scheduled wake for the correct agent lane" do
    workflow =
      IntegratedToolAgent.new(
        default_agent_id: "agent",
        model: "test:model",
        registry: [weather_tool()],
        client: weather_client(),
        pre_tool_guard: fn _request ->
          GuardDecision.wait!(:hold,
            metadata: %{until: DateTime.add(DateTime.utc_now(), 60, :second)}
          )
        end
      )
      |> Workflow.react_until_satisfied(%{user: "What's the weather in Paris?"})

    wait = IntegratedToolAgent.latest_wait(workflow, "agent")
    runtime = IntegratedToolAgent.runtime_state(workflow)

    assert runtime.scheduled[wait.resume_key].agent_id == "agent"

    workflow =
      Workflow.react_until_satisfied(
        workflow,
        %{wake: %{resume_key: wait.resume_key}}
      )

    assert IntegratedToolAgent.latest_reply_text(workflow, "agent") == "Paris is sunny."
    assert IntegratedToolAgent.session(workflow, "agent").status == :idle
  end

  defp weather_client do
    fn _model, %Prompt{messages: messages}, _opts ->
      last_user =
        messages
        |> Enum.filter(&(&1.role == :user))
        |> List.last()
        |> Map.get(:content)

      case Enum.find(messages, &(&1.role == :tool)) do
        nil ->
          location =
            cond do
              String.contains?(last_user, "Berlin") -> "Berlin"
              true -> "Paris"
            end

          {:ok,
           RunicAI.LLM.TestClient.tool_response(
             [
               RunicAI.LLM.TestClient.tool_call("get_weather", %{location: location},
                 id: "call_1"
               )
             ],
             "Let me check."
           )}

        tool_message ->
          assert tool_message.content =~ "\"sunny\""
          location = if String.contains?(last_user, "Berlin"), do: "Berlin", else: "Paris"
          {:ok, RunicAI.LLM.TestClient.result("#{location} is sunny.")}
      end
    end
  end

  defp weather_tool do
    Definition.new!(
      name: "get_weather",
      description: "Get the weather for a city",
      parameter_schema: [location: [type: :string, required: true]],
      executor: fn %{location: location} ->
        {:ok, %{location: location, forecast: "sunny"}}
      end
    )
  end
end
