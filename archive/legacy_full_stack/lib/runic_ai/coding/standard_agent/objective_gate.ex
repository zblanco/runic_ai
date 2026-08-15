defmodule RunicAI.Coding.StandardAgent.ObjectiveGate do
  @moduledoc """
  Evidence-grounded OODA gate for the standard ReAct coding agent.

  The gate is intentionally not a coordinator. It derives objective evidence
  from the current ReAct transcript and decides whether a direct coding session
  should continue, stop as satisfied, or stop as incomplete after its budget is
  exhausted.
  """

  alias RunicAI.Agent.ContinueDecision
  alias RunicAI.Agent.State, as: AgentState
  alias RunicAI.Agent.TurnResult
  alias RunicAI.Coding.AcceptanceCheck
  alias RunicAI.Coding.AcceptanceContract
  alias RunicAI.Coding.ObjectiveContract
  alias RunicAI.Coding.ObjectiveEvidence
  alias RunicAI.Coding.ObjectiveJudge
  alias RunicAI.Coding.ObjectiveScorecard
  alias RunicAI.Coding.Workspace
  alias RunicAI.Integrated.SessionState
  alias RunicAI.Message

  @command_tools ~w(compile_project run_tests run_formatter run_linter project_command runtime_smoke run_command)
  @verification_tools @command_tools ++ ~w(source_assert)

  @type evaluation :: %{
          required(:status) => atom(),
          required(:scorecard) => ObjectiveScorecard.t(),
          required(:acceptance_results) => [AcceptanceCheck.result()],
          required(:blocking_acceptance) => [AcceptanceCheck.result()],
          required(:changed_files) => [Path.t()],
          required(:command_results) => [map()],
          required(:latest_command_results) => [map()],
          required(:source_assertions) => [map()],
          required(:objective_contract) => term(),
          required(:objective_judgement) => map() | nil,
          required(:objective_evidence_summary) => map() | nil,
          required(:repair_prompt) => String.t() | nil
        }

  @spec continue_when(Workspace.t(), String.t(), keyword()) ::
          (AgentState.t(), TurnResult.t() -> ContinueDecision.t())
  def continue_when(%Workspace{} = workspace, objective, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    max_turns = Keyword.get(opts, :objective_gate_max_turns, Keyword.get(opts, :max_turns))

    fn %AgentState{} = state, %TurnResult{} = turn_result ->
      cond do
        TurnResult.tool_requests?(turn_result) ->
          ContinueDecision.continue!(:tool_requests)

        turn_result.kind == :error ->
          ContinueDecision.halt!(:turn_error)

        true ->
          evaluation = evaluate(workspace, objective, state, opts)

          cond do
            evaluation.status == :objective_satisfied ->
              ContinueDecision.stop!(:objective_satisfied,
                metadata: decision_metadata(evaluation)
              )

            max_turns_reached?(state, max_turns) ->
              ContinueDecision.stop!(:objective_incomplete,
                metadata: decision_metadata(evaluation)
              )

            true ->
              ContinueDecision.continue!(:objective_incomplete,
                metadata: decision_metadata(evaluation)
              )
          end
      end
    end
  end

  @spec evaluate(Workspace.t(), String.t(), AgentState.t() | SessionState.t() | map(), keyword()) ::
          evaluation()
  def evaluate(%Workspace{} = workspace, objective, input, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    context =
      input
      |> context_from_input()
      |> Map.put(:workspace_root, workspace.root)
      |> normalize_evidence_context()

    {semantic_acceptance_results, context} = semantic_results(workspace, objective, context, opts)

    acceptance_results =
      []
      |> Kernel.++(contract_results(workspace, objective, context, opts))
      |> Kernel.++(source_assertion_results(context))
      |> Kernel.++(command_acceptance_results(context))
      |> Kernel.++(required_evidence_results(context, opts))
      |> Kernel.++(semantic_acceptance_results)

    scorecard =
      ObjectiveScorecard.new!(
        acceptance_results: acceptance_results,
        child_results: [],
        command_statuses: Map.get(context, :latest_command_results, []),
        changed_files: Map.get(context, :changed_files, []),
        residual_risks: Map.get(context, :risks, []),
        metadata: %{
          gate: :standard_agent_ooda,
          objective: objective,
          objective_contract: summarize_contract(Map.get(context, :objective_contract)),
          objective_judgement: summarize_judgement(Map.get(context, :objective_judgement)),
          objective_evidence_summary: Map.get(context, :objective_evidence_summary)
        }
      )

    blocking_acceptance = ObjectiveScorecard.blocking_acceptance_results(acceptance_results)
    status = scorecard.objective_status

    %{
      status: status,
      scorecard: scorecard,
      acceptance_results: acceptance_results,
      blocking_acceptance: blocking_acceptance,
      changed_files: Map.get(context, :changed_files, []),
      command_results: Map.get(context, :command_results, []),
      latest_command_results: Map.get(context, :latest_command_results, []),
      source_assertions: Map.get(context, :source_assertions, []),
      objective_contract: Map.get(context, :objective_contract),
      objective_judgement: Map.get(context, :objective_judgement),
      objective_evidence_summary: Map.get(context, :objective_evidence_summary),
      repair_prompt: repair_prompt(objective, status, blocking_acceptance, context)
    }
  end

  @spec satisfied?(evaluation()) :: boolean()
  def satisfied?(%{scorecard: scorecard}), do: ObjectiveScorecard.objective_satisfied?(scorecard)

  @spec context_from_input(AgentState.t() | SessionState.t() | map()) :: map()
  def context_from_input(%SessionState{} = session), do: context_from_input(session.agent_state)

  def context_from_input(%AgentState{} = state) do
    tool_observations =
      state.conversation.messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.map(&tool_observation/1)

    %{
      changed_files: changed_files(tool_observations),
      command_results: command_results(tool_observations),
      source_assertions: source_assertions(tool_observations),
      verification_observations: verification_observations(tool_observations),
      risks: source_assertion_risks(tool_observations),
      tool_observations: tool_observations,
      conversation_turns: state.conversation.turns
    }
  end

  def context_from_input(context) when is_map(context) do
    context
    |> Map.put_new(:changed_files, [])
    |> Map.put_new(:command_results, [])
    |> Map.put_new(:source_assertions, [])
    |> Map.put_new(:verification_observations, [])
    |> Map.put_new(:risks, [])
    |> Map.put_new(:tool_observations, [])
  end

  defp contract_results(workspace, objective, context, opts) do
    case Keyword.get(opts, :acceptance_contract) do
      nil ->
        []

      contract_input ->
        case AcceptanceContract.evaluate(contract_input, workspace, context) do
          {:ok, evaluation} ->
            List.wrap(Map.get(evaluation, :results))

          {:error, error} ->
            [
              AcceptanceCheck.result(
                AcceptanceCheck.new!(:artifact_present, id: "acceptance-contract-valid"),
                :fail,
                "acceptance contract could not be evaluated",
                %{error: error.message, objective: objective}
              )
            ]
        end
    end
  end

  defp source_assertion_results(context) do
    context
    |> Map.get(:source_assertions, [])
    |> Enum.flat_map(fn assertion -> List.wrap(field(assertion, :results)) end)
  end

  defp command_acceptance_results(context) do
    context
    |> Map.get(:latest_command_results, [])
    |> Enum.map(fn command ->
      status = if field(command, :status) in [:pass, "pass"], do: :pass, else: :fail

      AcceptanceCheck.result(
        AcceptanceCheck.new!(:command_passes,
          id: "command:#{:erlang.phash2(command_signature(command))}"
        ),
        status,
        command_message(command, status),
        %{
          command: normalized_command(command),
          cwd: field(command, :cwd),
          output_preview: field(command, :output_preview) || field(command, :output)
        }
      )
    end)
  end

  defp required_evidence_results(context, opts) do
    []
    |> maybe_require_verification(context, opts)
    |> maybe_require_changes(context, opts)
  end

  defp maybe_require_verification(results, context, opts) do
    if Keyword.get(opts, :require_verification?, true) and
         Map.get(context, :command_results, []) == [] and
         Map.get(context, :source_assertions, []) == [] do
      [
        AcceptanceCheck.result(
          AcceptanceCheck.new!(:artifact_present, id: "standard-verification-observed"),
          :fail,
          "no verification command or source assertion was observed",
          %{}
        )
        | results
      ]
    else
      results
    end
  end

  defp maybe_require_changes(results, context, opts) do
    if Keyword.get(opts, :require_changes?, false) and Map.get(context, :changed_files, []) == [] do
      [
        AcceptanceCheck.result(
          AcceptanceCheck.new!(:artifact_present, id: "standard-implementation-activity"),
          :fail,
          "no changed files were observed",
          %{}
        )
        | results
      ]
    else
      results
    end
  end

  defp semantic_results(workspace, objective, context, opts) do
    if semantic_enabled?(opts) do
      with {:ok, contract} <- ObjectiveContract.ensure(objective, context, opts) do
        evidence =
          ObjectiveEvidence.gather(workspace, Map.put(context, :objective, objective), opts)

        case ObjectiveJudge.evaluate(contract, evidence, opts) do
          {:ok, judgement} ->
            results = ObjectiveJudge.acceptance_results(contract, judgement)

            {results,
             context
             |> Map.put(:objective_contract, contract)
             |> Map.put(:objective_judgement, judgement)
             |> Map.put(:objective_evidence_summary, ObjectiveEvidence.summary(evidence))}

          {:error, error} ->
            {semantic_error_result(error), context}
        end
      else
        {:error, error} -> {semantic_error_result(error), context}
      end
    else
      {[], context}
    end
  end

  defp semantic_enabled?(opts) do
    Keyword.get(opts, :semantic_progress?, false) or Keyword.has_key?(opts, :objective_contract) or
      Keyword.has_key?(opts, :semantic_judge)
  end

  defp semantic_error_result(error) do
    [
      AcceptanceCheck.result(
        AcceptanceCheck.new!(:semantic_requirement, id: "semantic:objective_judge"),
        :fail,
        "semantic objective judgement failed",
        %{error: error.message}
      )
    ]
  end

  defp tool_observation(%Message{name: name, content: content}) do
    payload =
      case Jason.decode(content || "") do
        {:ok, decoded} -> decoded
        {:error, _error} -> %{"raw" => content}
      end

    %{tool: name, result: field(payload, :result) || payload}
  end

  defp changed_files(observations) do
    observations
    |> Enum.filter(&(&1.tool == "apply_patch"))
    |> Enum.flat_map(fn observation ->
      List.wrap(field(observation.result, :changed_paths))
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp command_results(observations) do
    observations
    |> Enum.filter(&(&1.tool in @command_tools))
    |> Enum.map(fn observation ->
      observation.result
      |> normalize_map()
      |> Map.put_new(:tool, observation.tool)
    end)
  end

  defp source_assertions(observations) do
    observations
    |> Enum.filter(&(&1.tool == "source_assert"))
    |> Enum.map(fn observation ->
      observation.result
      |> normalize_map()
      |> Map.put_new(:tool, observation.tool)
    end)
  end

  defp verification_observations(observations) do
    observations
    |> Enum.filter(&(&1.tool in @verification_tools))
    |> Enum.map(& &1.result)
  end

  defp source_assertion_risks(observations) do
    observations
    |> Enum.filter(fn observation ->
      observation.tool == "source_assert" and
        field(observation.result, :status) not in [:pass, "pass"]
    end)
    |> Enum.map(fn observation ->
      "#{observation.tool} ended with status #{field(observation.result, :status)}"
    end)
    |> Enum.uniq()
  end

  defp normalize_evidence_context(context) do
    command_results =
      context
      |> Map.get(:command_results, [])
      |> Enum.map(&normalize_command_result(&1, context))

    latest_command_results = latest_by_command(command_results, context)

    context
    |> Map.put(:command_results, command_results)
    |> Map.put(:latest_command_results, latest_command_results)
    |> Map.put(:risks, command_risks(latest_command_results, Map.get(context, :risks, [])))
  end

  defp latest_by_command(commands, context) do
    commands
    |> Enum.map(&normalize_command_result(&1, context))
    |> drop_superseded_directory_failures()
    |> Enum.reverse()
    |> Enum.uniq_by(&command_signature/1)
    |> Enum.reverse()
  end

  defp command_signature(command) do
    {normalized_command(command), field(command, :cwd)}
  end

  defp drop_superseded_directory_failures(commands) do
    indexed = Enum.with_index(commands)

    indexed
    |> Enum.reject(fn {command, index} ->
      failed?(command) and later_directory_pass?(command, index, indexed)
    end)
    |> Enum.map(fn {command, _index} -> command end)
  end

  defp later_directory_pass?(command, index, indexed) do
    command_key = normalized_command(command)
    cwd = field(command, :cwd)

    Enum.any?(indexed, fn {later, later_index} ->
      later_index > index and passing?(later) and normalized_command(later) == command_key and
        same_or_descendant_cwd?(cwd, field(later, :cwd))
    end)
  end

  defp same_or_descendant_cwd?(nil, _later_cwd), do: false
  defp same_or_descendant_cwd?(_cwd, nil), do: false

  defp same_or_descendant_cwd?(cwd, later_cwd) do
    cwd = Path.expand(cwd)
    later_cwd = Path.expand(later_cwd)

    cwd == later_cwd or String.starts_with?(later_cwd, cwd <> "/")
  end

  defp normalize_command_result(command, context) do
    command = normalize_map(command)
    argv = normalized_command(command)
    cwd = normalize_cwd(field(command, :cwd), context)

    command
    |> Map.put(:argv, argv)
    |> Map.put(:command, Enum.join(argv, " "))
    |> maybe_put(:cwd, cwd)
    |> Map.put(:status, normalize_status(field(command, :status)))
  end

  defp normalized_command(command) do
    cond do
      is_list(field(command, :argv)) ->
        command
        |> field(:argv)
        |> normalize_argv()

      is_binary(field(command, :command)) ->
        command
        |> field(:command)
        |> split_command()

      is_binary(field(command, :tool)) ->
        [field(command, :tool)]

      true ->
        []
    end
  end

  defp normalize_argv([single]) when is_binary(single), do: split_command(single)
  defp normalize_argv(argv) when is_list(argv), do: Enum.map(argv, &to_string/1)
  defp normalize_argv(_argv), do: []

  defp split_command(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> case do
      [] -> [command]
      argv -> argv
    end
  rescue
    ArgumentError -> String.split(command, ~r/\s+/, trim: true)
  end

  defp normalize_cwd(nil, _context), do: nil

  defp normalize_cwd(cwd, context) when is_binary(cwd) do
    workspace_root = field(context, :workspace_root)

    cond do
      Path.type(cwd) == :absolute ->
        Path.expand(cwd)

      is_binary(workspace_root) and workspace_root != "" ->
        Path.expand(cwd, workspace_root)

      true ->
        Path.expand(cwd)
    end
  end

  defp normalize_cwd(cwd, _context), do: cwd

  defp normalize_status(status) when status in [:pass, :fail, :timeout, :killed, :blocked],
    do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "pass" -> :pass
      "fail" -> :fail
      "timeout" -> :timeout
      "killed" -> :killed
      "blocked" -> :blocked
      _other -> status
    end
  end

  defp normalize_status(status), do: status

  defp passing?(command), do: field(command, :status) in [:pass, "pass"]
  defp failed?(command), do: field(command, :status) not in [:pass, "pass", nil]

  defp command_risks(commands, existing_risks) do
    command_risks =
      commands
      |> Enum.reject(&passing?/1)
      |> Enum.map(fn command ->
        "#{field(command, :tool) || "command"} ended with status #{field(command, :status)}"
      end)

    existing_risks
    |> List.wrap()
    |> Kernel.++(command_risks)
    |> Enum.uniq()
  end

  defp command_message(command, :pass) do
    "command passed: #{format_command(command)}"
  end

  defp command_message(command, _status) do
    "command failed: #{format_command(command)}"
  end

  defp format_command(command) do
    case normalized_command(command) do
      argv when is_list(argv) -> Enum.join(argv, " ")
      command when is_binary(command) -> command
      other -> inspect(other)
    end
  end

  defp repair_prompt(_objective, :objective_satisfied, _blocking, _context), do: nil

  defp repair_prompt(objective, status, blocking, context) do
    """
    Objective is not yet satisfied: #{status}.

    Objective:
    #{objective}

    Blocking evidence:
    #{inspect(Enum.map(blocking, &blocking_summary/1), pretty: true, limit: 20)}

    Latest command evidence:
    #{inspect(Enum.map(Map.get(context, :latest_command_results, []), &command_summary/1), pretty: true, limit: 20)}

    Changed files:
    #{inspect(Map.get(context, :changed_files, []), limit: 20)}

    Continue by inspecting the current workspace, patching the smallest missing
    slice, and running concrete verification from the correct working directory.
    """
  end

  defp blocking_summary(result) do
    %{
      id: field(result, :id),
      type: field(result, :type),
      status: field(result, :status),
      message: field(result, :message),
      metadata: field(result, :metadata) || %{}
    }
  end

  defp command_summary(command) do
    %{
      status: field(command, :status),
      command: field(command, :argv) || field(command, :command),
      cwd: field(command, :cwd),
      output_preview: field(command, :output_preview) || field(command, :output)
    }
  end

  defp decision_metadata(evaluation) do
    %{
      objective_status: evaluation.status,
      blocking_acceptance: Enum.map(evaluation.blocking_acceptance, &blocking_summary/1),
      changed_files: evaluation.changed_files,
      command_results: Enum.map(evaluation.latest_command_results, &command_summary/1),
      repair_prompt: evaluation.repair_prompt
    }
  end

  defp max_turns_reached?(_state, nil), do: false

  defp max_turns_reached?(%AgentState{} = state, max_turns) when is_integer(max_turns),
    do: state.conversation.turns >= max_turns

  defp summarize_contract(nil), do: nil

  defp summarize_contract(contract) do
    %{
      id: field(contract, :id),
      objective: field(contract, :objective),
      requirement_count: length(List.wrap(field(contract, :requirements)))
    }
  end

  defp summarize_judgement(nil), do: nil

  defp summarize_judgement(judgement) do
    %{
      status: field(judgement, :status),
      summary: field(judgement, :summary),
      risks: field(judgement, :risks) || []
    }
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil
end
