defmodule RunicAI.Steps.ApplyIntegratedTurnResult do
  @moduledoc """
  Apply a completed turn back into the owning integrated session.
  """

  import Kernel, except: [apply: 2, apply: 3]

  require Runic

  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Error
  alias RunicAI.Integrated.Emission
  alias RunicAI.Integrated.SessionState
  alias RunicAI.LLM.GenerationEvidence
  alias RunicAI.LLM.Result, as: LLMResult
  alias RunicAI.Rules.ContinueChat

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :apply_integrated_turn_result)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn bundle, %TurnResult{} = turn_result ->
        apply_result!(bundle, turn_result, options)
      end,
      name: name
    )
  end

  @spec apply_result(map(), TurnResult.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def apply_result(
        %{agent_id: agent_id, session: %SessionState{} = session, turn_request: turn_request},
        %TurnResult{} = turn_result,
        opts
      )
      when is_binary(agent_id) and is_list(opts) do
    with {:ok, turn_result} <- TurnResult.validate(turn_result),
         {:ok, updated_agent_state} <-
           State.apply_turn_result(session.agent_state, turn_request, turn_result),
         {:ok, continue_decision} <-
           ContinueChat.decide(updated_agent_state, turn_result, continue_opts(opts)) do
      updated_session =
        session
        |> SessionState.with_agent_state!(updated_agent_state)
        |> SessionState.clear_pending_work!(status: next_status(turn_result, continue_decision))
        |> put_control(:last_continue_decision, continue_decision)
        |> increment_model_usage(turn_result)
        |> SessionState.reconcile_queue()

      {:ok,
       %{
         session: updated_session,
         emissions: build_emissions(agent_id, turn_result, continue_decision)
       }}
    end
  end

  def apply_result(other, _turn_result, _opts) do
    {:error,
     Error.validation("apply_integrated_turn_result expects a materialized turn bundle",
       source: __MODULE__,
       details: %{bundle: other}
     )}
  end

  @spec apply_result!(map(), TurnResult.t(), keyword()) :: map()
  def apply_result!(bundle, %TurnResult{} = turn_result, opts \\ []) do
    case apply_result(bundle, turn_result, opts) do
      {:ok, update} -> update
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp continue_opts(opts) do
    Keyword.take(opts, [:max_turns, :stop_pattern, :continue_when])
  end

  defp next_status(%TurnResult{kind: :final}, _decision), do: :completed
  defp next_status(%TurnResult{kind: :error}, _decision), do: :halted
  defp next_status(_turn_result, %ContinueDecision{action: :stop}), do: :completed
  defp next_status(_turn_result, %ContinueDecision{action: :halt}), do: :halted
  defp next_status(_turn_result, %ContinueDecision{}), do: :idle

  defp build_emissions(agent_id, %TurnResult{kind: :reply} = turn_result, _decision) do
    [Emission.new!(agent_id, :reply, value: turn_result)]
  end

  defp build_emissions(agent_id, %TurnResult{kind: :final} = turn_result, _decision) do
    [Emission.new!(agent_id, :final, value: turn_result)]
  end

  defp build_emissions(
         agent_id,
         %TurnResult{kind: :error},
         %ContinueDecision{} = continue_decision
       ) do
    [Emission.new!(agent_id, :status, value: continue_decision)]
  end

  defp build_emissions(_agent_id, _turn_result, _decision), do: []

  defp put_control(%SessionState{} = session, key, value) do
    %SessionState{session | control: Map.put(session.control, key, value)}
  end

  defp increment_model_usage(%SessionState{} = session, %TurnResult{
         raw: %LLMResult{} = llm_result
       }) do
    usage = normalize_usage(llm_result.usage)
    token_usage = normalize_usage(Map.get(session.control, :token_usage, %{}))

    %SessionState{
      session
      | control:
          session.control
          |> Map.put(:attempts, Map.get(session.control, :attempts, 0) + 1)
          |> Map.put(:model_calls, Map.get(session.control, :model_calls, 0) + 1)
          |> Map.put(:token_usage, merge_usage(token_usage, usage))
          |> maybe_increment_retries(llm_result)
          |> GenerationEvidence.append(llm_result)
    }
  end

  defp increment_model_usage(%SessionState{} = session, %TurnResult{} = turn_result) do
    retries =
      if get_in(turn_result.details, [:retryable]) do
        Map.get(session.control, :retries, 0) + 1
      else
        Map.get(session.control, :retries, 0)
      end

    control =
      session.control
      |> Map.put(:attempts, Map.get(session.control, :attempts, 0) + 1)
      |> Map.put(:retries, retries)
      |> maybe_append_generation_error(turn_result)

    %SessionState{
      session
      | control: control
    }
  end

  defp maybe_append_generation_error(control, %TurnResult{details: %{error: %Error{} = error}}),
    do: GenerationEvidence.append_error(control, error)

  defp maybe_append_generation_error(control, _turn_result), do: control

  defp maybe_increment_retries(control, %LLMResult{}),
    do: Map.put(control, :retries, Map.get(control, :retries, 0))

  defp normalize_usage(usage) when is_map(usage), do: usage
  defp normalize_usage(_usage), do: %{}

  defp merge_usage(left, right) do
    %{
      input_tokens: Map.get(left, :input_tokens, 0) + Map.get(right, :input_tokens, 0),
      output_tokens: Map.get(left, :output_tokens, 0) + Map.get(right, :output_tokens, 0),
      total_tokens: Map.get(left, :total_tokens, 0) + Map.get(right, :total_tokens, 0)
    }
  end
end
