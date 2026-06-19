defmodule RunicAI.Coding.RLM.Coordinator do
  @moduledoc """
  RLM coding coordinator that proposes validated workflow data.
  """

  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.CoordinationPatterns
  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.RecipeLibrary
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result

  @default_model "openai:gpt-5.4-mini"
  @default_repair_attempts 2
  @default_generation_mode :json_text
  @max_conversation_history_messages 12
  @max_conversation_history_chars 16_000

  @spec propose(String.t(), CodebaseEnvironment.t(), keyword()) ::
          {:ok, WorkflowProposal.t(), WorkflowValidationReport.t()} | {:error, Error.t()}
  def propose(objective, %CodebaseEnvironment{} = environment, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    opts = normalize_coordination_opts(opts)
    validation_opts = Keyword.fetch!(opts, :validation_opts)
    seeded_result = maybe_implementation_seed(objective, environment, opts, validation_opts)

    result =
      cond do
        Keyword.has_key?(opts, :proposal) ->
          opts
          |> Keyword.fetch!(:proposal)
          |> validate_candidate(opts, validation_opts, :provided)

        command = Keyword.get(opts, :command) ->
          command
          |> RecipeLibrary.proposal(objective, sources: source_refs(environment))
          |> validate_candidate(opts, validation_opts, :recipe)

        not is_nil(seeded_result) ->
          seeded_result

        true ->
          generate_and_validate(objective, environment, opts, validation_opts)
      end

    case result do
      {:ok, proposal, report} -> {:ok, proposal, report}
      {:error, error} -> maybe_fallback(objective, environment, opts, validation_opts, error)
    end
  end

  @spec prompt(String.t(), CodebaseEnvironment.t(), keyword()) :: String.t()
  def prompt(objective, %CodebaseEnvironment{} = environment, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    """
    You are the RunicAI RLM coding coordinator.

    Objective:
    #{objective}

    Prior conversation context:
    #{conversation_context(opts)}

    Sources:
    #{Jason.encode!(CodebaseEnvironment.source_summaries(environment, Keyword.get(opts, :source_limit, 40)))}

    Allowed node kinds:
    #{Jason.encode!(ProposalNode.allowed_kinds())}

    Recipe seeds:
    #{Jason.encode!(RecipeLibrary.summaries())}

    Generic coordination patterns:
    #{Jason.encode!(CoordinationPatterns.prompt_summary())}

    Policy constraints:
    #{Jason.encode!(policy_summary(opts))}

    Return a bounded workflow proposal. Prefer read-only exploration unless the
    caller explicitly enables mutation. When mutation is enabled or the
    objective asks to build, create, implement, add, update, fix, generate, or
    prototype a working artifact, do not produce a repository summary,
    file-dump, or read-only Q&A workflow. Include implementation, verification,
    and evidence-producing steps, or return a blocked workflow that explains
    the missing permission or capability.

    Required output shape:
    - nodes MUST be a JSON array of objects.
    - each node object MUST include id, kind, and params.
    - assumptions MUST be a JSON array of strings.
    - sources MUST be a JSON array of source ref strings from the Sources list,
      not full source objects.
    - node ids MUST be non-empty strings; never use null ids and never return
      node names as bare strings.
    - edges MUST be a JSON array of objects with from and to fields.
    - policies, metadata, and params MUST be JSON objects.
    - never return prose strings for nodes, edges, policies, or metadata.

    Node parameter conventions:
    - command nodes use params.args.argv and may only use allowed command executables.
      Commands must be non-interactive and include flags that disable prompts
      or dependency installation. For Phoenix scaffolds, use --no-install.
    - agent nodes use params.mode and params.task; when implementing inside a generated subproject, include params.workspace_path with that relative directory.
    - edit nodes use params.operations or params.patch_set; use an agent node for implementation work that is not already a concrete file operation.
    - verification_gate nodes use params.checks or params.contract.
    - verification checks must use one of the allowed acceptance check types.
    - command_passes/command_fails_with checks must include a concrete command
      selector. Prefer params.argv as an argv array; params.command as a string
      and params.args.argv are accepted for compatibility. Never emit command
      checks without argv or command.
    - source_contains/source_not_contains checks may use params.path for a file
      or directory, params.paths for multiple paths, or params.glob/globs for
      layout-tolerant source assertions.
    - Prefer directory/glob source assertions for behavior or architecture
      evidence unless the user explicitly requires an exact file path.
    - Do not invent exact module names, nested namespaces, or file paths unless
      the workflow also creates those exact artifacts.
    - The proposal graph must be acyclic unless policy explicitly allows
      bounded recursion. Do not encode repair as verify -> repair -> verify
      cycles; use a linear repair/review node before final verification and let
      the outer repair loop handle retries.

    Generic valid node shapes:
    #{Jason.encode!(node_shape_examples())}

    Do not select or assume language-, framework-, generator-, or domain-specific
    workflow templates. Use generic coordination patterns only as control-flow
    guidance, then synthesize task-specific nodes, edges, child contracts, and
    acceptance checks from the objective and workspace evidence.

    Before mutation, derive acceptance checks. For coding objectives, do not
    treat scaffold tests or a generic command pass as sufficient proof of
    objective satisfaction. Use verification_gate nodes when allowed.

    Mutating workflows are also checked by a generic progress gate. It will
    reject scaffold-only work, default generated tests, missing source evidence
    for high-signal objective terms, and child implementation nodes that do not
    produce concrete edit or verification evidence. Prefer small executable
    implementation steps that create or patch real source and tests before the
    final verification gate. Avoid over-splitting into many child agent nodes:
    for small generated projects, prefer one patch agent that implements source,
    tests, and smoke evidence together, followed by a verification gate.
    """
  end

  @spec schema() :: keyword()
  def schema do
    [
      id: [type: :string],
      objective: [type: :string, required: true],
      assumptions: [type: {:list, :string}],
      sources: [type: {:list, :string}],
      nodes: [
        type: {:list, :map},
        required: true,
        doc:
          "Workflow node objects. Each node must include non-empty string id, string kind, and object params."
      ],
      edges: [
        type: {:list, :map},
        doc: "Workflow edge objects. Each edge must include string from and string to."
      ],
      policies: [type: :any],
      expected_artifacts: [type: :any],
      stop_conditions: [type: {:list, :string}, required: true],
      metadata: [type: :any]
    ]
  end

  defp generate_and_validate(objective, environment, opts, validation_opts) do
    model = Keyword.get(opts, :model, @default_model)

    llm_opts =
      opts
      |> Keyword.get(:llm_opts, [])
      |> maybe_put_client(Keyword.get(opts, :client))
      |> maybe_put_receive_timeout(Keyword.get(opts, :proposal_llm_timeout_ms))

    case generate_proposal_object(model, prompt(objective, environment, opts), opts, llm_opts) do
      {:ok, object} ->
        object
        |> normalize_generated_candidate(objective)
        |> validate_candidate(opts, validation_opts, :generated)
        |> maybe_repair(objective, environment, opts, validation_opts, model, llm_opts, object)

      {:error, error} ->
        {:error,
         coordinator_error("RLM coding coordinator could not generate a workflow proposal",
           stage: :generation,
           error: error_details(error)
         )}
    end
  end

  defp maybe_repair(
         {:ok, _proposal, _report} = result,
         _objective,
         _environment,
         _opts,
         _validation_opts,
         _model,
         _llm_opts,
         _object
       ),
       do: result

  defp maybe_repair(
         {:error, error},
         objective,
         environment,
         opts,
         validation_opts,
         model,
         llm_opts,
         object
       ) do
    repair_attempts = Keyword.get(opts, :proposal_repair_attempts, @default_repair_attempts)

    repair_generated(
      objective,
      environment,
      opts,
      validation_opts,
      model,
      llm_opts,
      object,
      [error],
      repair_attempts
    )
  end

  defp repair_generated(
         _objective,
         _environment,
         _opts,
         _validation_opts,
         _model,
         _llm_opts,
         _object,
         errors,
         0
       ) do
    {:error, proposal_failure_error(:generated, errors)}
  end

  defp repair_generated(
         objective,
         environment,
         opts,
         validation_opts,
         model,
         llm_opts,
         object,
         errors,
         attempts_left
       ) do
    repair_prompt = repair_prompt(objective, environment, opts, object, errors)

    case generate_proposal_object(model, repair_prompt, opts, llm_opts) do
      {:ok, repaired_object} ->
        object
        |> merge_repaired_candidate(repaired_object)
        |> normalize_generated_candidate(objective)
        |> validate_candidate(opts, validation_opts, :repaired)
        |> case do
          {:ok, _proposal, _report} = result ->
            result

          {:error, error} ->
            repair_generated(
              objective,
              environment,
              opts,
              validation_opts,
              model,
              llm_opts,
              repaired_object,
              [error | errors],
              attempts_left - 1
            )
        end

      {:error, error} ->
        repair_generated(
          objective,
          environment,
          opts,
          validation_opts,
          model,
          llm_opts,
          object,
          [error | errors],
          attempts_left - 1
        )
    end
  end

  defp repair_prompt(objective, environment, opts, object, errors) do
    """
    You are repairing an invalid RunicAI RLM coding workflow proposal.

    Objective:
    #{objective}

    Prior conversation context:
    #{conversation_context(opts)}

    Sources:
    #{Jason.encode!(CodebaseEnvironment.source_summaries(environment, Keyword.get(opts, :source_limit, 40)))}

    Allowed node kinds:
    #{Jason.encode!(ProposalNode.allowed_kinds())}

    Policy constraints:
    #{Jason.encode!(policy_summary(opts))}

    Validation errors:
    #{Jason.encode!(Enum.map(errors, &error_details/1))}

    Previous invalid object:
    #{Jason.encode!(object)}

    Return a complete corrected workflow proposal object. The corrected object
    must satisfy the schema exactly: nodes and edges are JSON arrays of objects;
    policies, metadata, and params are JSON objects; stop_conditions is a
    non-empty JSON array. Every node object must include a non-empty string id,
    string kind, and object params. Never return node names as bare strings and
    never return null node ids. Command nodes must put executable argv under
    params.args.argv and may only use allowed command executables. Convert any
    non-concrete edit node into an agent node with a patch/write_tests/verify
    mode and a concrete task. Verification gates must include checks or a
    contract. Source checks should use directory/glob selectors when exact file
    layout is not required. The edge graph must be acyclic unless policy
    explicitly allows bounded recursion; do not produce verify -> repair ->
    verify cycles. Do not summarize the repair in prose.
    """
  end

  defp generate_proposal_object(model, prompt, opts, llm_opts) do
    case Keyword.get(opts, :proposal_generation, @default_generation_mode) do
      :object ->
        case LLM.generate_object(model, prompt, schema(), llm_opts) do
          {:ok, object} ->
            {:ok, object}

          {:error, error} ->
            if Keyword.get(opts, :object_generation_fallback?, true) do
              generate_json_text_proposal(model, prompt, llm_opts)
            else
              {:error, error}
            end
        end

      :json_text ->
        generate_json_text_proposal(model, prompt, llm_opts)
    end
  end

  defp generate_json_text_proposal(model, prompt, llm_opts) do
    prompt = """
    #{prompt}

    Return only one valid JSON object. Do not wrap it in Markdown fences.
    The JSON object must contain these top-level fields:
    id, objective, assumptions, sources, nodes, edges, policies,
    expected_artifacts, stop_conditions, metadata.
    """

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        result
        |> Result.text()
        |> decode_generated_json()

      {:retry, error} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp conversation_context(opts) do
    opts
    |> Keyword.get(:conversation_context)
    |> case do
      context when is_binary(context) and context != "" ->
        truncate_history(context)

      _other ->
        opts
        |> conversation_history()
        |> format_conversation_history()
    end
  end

  defp conversation_history(opts) do
    opts
    |> Keyword.get(:conversation_history, [])
    |> List.wrap()
    |> Enum.map(&normalize_history_message/1)
    |> Enum.reject(&(String.trim(&1.content) == ""))
    |> Enum.take(-@max_conversation_history_messages)
  end

  defp normalize_history_message(message) when is_map(message) do
    %{
      role: history_field(message, :role) || "message",
      message_kind: history_field(message, :message_kind) || history_field(message, :kind),
      content: history_content(history_field(message, :content))
    }
  end

  defp normalize_history_message(message) when is_binary(message) do
    %{role: "message", message_kind: nil, content: message}
  end

  defp normalize_history_message(message) do
    %{role: "message", message_kind: nil, content: inspect(message)}
  end

  defp history_field(message, key) when is_map(message) do
    Map.get(message, key) || Map.get(message, Atom.to_string(key))
  end

  defp history_content(nil), do: ""
  defp history_content(content) when is_binary(content), do: content
  defp history_content(content), do: inspect(content)

  defp format_conversation_history([]), do: "[]"

  defp format_conversation_history(history) do
    history
    |> Enum.map(&format_history_message/1)
    |> Enum.join("\n\n")
    |> truncate_history()
  end

  defp format_history_message(message) do
    role =
      message.role
      |> to_string()
      |> String.capitalize()

    kind =
      case message.message_kind do
        nil -> ""
        "" -> ""
        kind -> " (#{kind})"
      end

    "#{role}#{kind}:\n#{message.content}"
  end

  defp truncate_history(text) when byte_size(text) <= @max_conversation_history_chars, do: text

  defp truncate_history(text) do
    omitted = byte_size(text) - @max_conversation_history_chars

    text
    |> binary_part(omitted, @max_conversation_history_chars)
    |> then(&("[earlier conversation omitted]\n" <> &1))
  end

  defp decode_generated_json(text) when is_binary(text) do
    candidates = json_text_candidates(text)

    Enum.find_value(candidates, fn candidate ->
      case Jason.decode(candidate) do
        {:ok, object} when is_map(object) -> {:ok, object}
        _other -> nil
      end
    end) ||
      decode_generated_json_error(text, candidates)
  end

  defp strip_markdown_fence(text) do
    text = String.trim(text)

    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      _other -> text
    end
  end

  defp json_text_candidates(text) do
    stripped = strip_markdown_fence(text)

    fenced =
      ~r/```(?:json)?\s*(.*?)\s*```/si
      |> Regex.scan(text, capture: :all_but_first)
      |> Enum.map(fn [json] -> String.trim(json) end)

    balanced =
      [first_balanced_json_object(text), first_balanced_json_object(stripped)]
      |> Enum.reject(&is_nil/1)

    [String.trim(text), stripped | fenced ++ balanced]
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp first_balanced_json_object(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.drop_while(&(&1 != ?{))
    |> case do
      [] -> nil
      chars -> collect_balanced_json(chars, 0, false, false, [])
    end
  end

  defp collect_balanced_json([], _depth, _in_string?, _escaped?, _acc), do: nil

  defp collect_balanced_json([char | rest], depth, in_string?, escaped?, acc) do
    acc = [char | acc]

    cond do
      in_string? and escaped? ->
        collect_balanced_json(rest, depth, true, false, acc)

      in_string? and char == ?\\ ->
        collect_balanced_json(rest, depth, true, true, acc)

      in_string? and char == ?" ->
        collect_balanced_json(rest, depth, false, false, acc)

      in_string? ->
        collect_balanced_json(rest, depth, true, false, acc)

      char == ?" ->
        collect_balanced_json(rest, depth, true, false, acc)

      char == ?{ ->
        collect_balanced_json(rest, depth + 1, false, false, acc)

      char == ?} ->
        depth = depth - 1

        if depth == 0 do
          acc |> Enum.reverse() |> List.to_string()
        else
          collect_balanced_json(rest, depth, false, false, acc)
        end

      true ->
        collect_balanced_json(rest, depth, false, false, acc)
    end
  end

  defp decode_generated_json_error(text, candidates) do
    {error_message, value} =
      candidates
      |> Enum.find_value(fn candidate ->
        case Jason.decode(candidate) do
          {:ok, value} -> {:decoded_non_object, value}
          {:error, error} -> {:decode_error, Exception.message(error)}
        end
      end)
      |> case do
        {:decoded_non_object, value} ->
          {"generated workflow proposal JSON must decode to an object", value}

        {:decode_error, message} ->
          {"generated workflow proposal was not valid JSON", message}

        nil ->
          {"generated workflow proposal was not valid JSON", "no JSON object candidate found"}
      end

    details =
      case error_message do
        "generated workflow proposal JSON must decode to an object" ->
          %{value: value, text_preview: String.slice(text, 0, 4_000)}

        _other ->
          %{error: value, text_preview: String.slice(text, 0, 4_000)}
      end

    {:error, Error.validation(error_message, source: __MODULE__, details: details)}
  end

  defp validate_candidate(candidate, opts, validation_opts, stage) do
    with {:ok, proposal} <- WorkflowProposal.from_input(candidate),
         proposal <- enrich_mutating_agent_tasks(proposal, opts),
         :ok <- require_node_kinds(proposal, opts) do
      report = WorkflowValidator.validate(proposal, validation_opts)

      if WorkflowValidationReport.accepted?(report) do
        {:ok, proposal, report}
      else
        {:error,
         coordinator_error("RLM coding workflow proposal was rejected by policy",
           stage: stage,
           validation_errors: Enum.map(report.errors, &error_details/1),
           rejected_nodes: report.rejected_nodes,
           proposal_id: proposal.id
         )}
      end
    else
      {:error, error} ->
        {:error,
         coordinator_error("RLM coding workflow proposal had an invalid shape",
           stage: stage,
           error: error_details(error)
         )}
    end
  end

  defp enrich_mutating_agent_tasks(%WorkflowProposal{} = proposal, opts) do
    if mutation_enabled?(opts) do
      %{proposal | nodes: Enum.map(proposal.nodes, &enrich_mutating_agent_task/1)}
    else
      proposal
    end
  end

  defp enrich_mutating_agent_task(%ProposalNode{kind: :agent, params: params} = node) do
    mode = params |> param_value(:mode) |> to_string()

    if mode in ["patch", "verify"] do
      task =
        params
        |> param_value(:task)
        |> append_empty_workspace_instruction()

      %{node | params: put_param_value(params, :task, task)}
    else
      node
    end
  end

  defp enrich_mutating_agent_task(node), do: node

  @empty_workspace_instruction """

  Empty-workspace handling:
  - If the selected workspace is empty or does not contain a suitable existing
    project, treat that as permission to create the requested project inside
    the selected workspace or the objective's named subdirectory.
  - When the objective does not explicitly name a nested project directory,
    place the generated project root directly at the selected workspace root:
    root-level manifests such as mix.exs, package.json, pyproject.toml,
    source directories, tests, and runtime smoke entry points belong at that
    root. Do not create scratch delivery roots such as tmp/, generated/, app/,
    demo/, or a duplicate project directory just to hold the answer.
  - Do not stop solely because there is no existing application to patch.
  - Do not inspect or edit parent/sibling workspaces to compensate for an empty
    selected workspace.
  - Create objective-specific source, tests, and verification evidence instead
    of leaving a scaffold or repository summary.
  - Preserve the objective's project identity when naming generated apps,
    modules, files, tests, and smoke APIs. Do not shorten a multi-word domain
    noun phrase to a generic subset if the objective names a fuller concept.
  - If the objective asks for a runtime smoke, expose a concrete non-interactive
    smoke entry point in the generated project and verify it from the project
    root before claiming completion.
  """

  defp append_empty_workspace_instruction(task) when is_binary(task) do
    if String.contains?(task, "Empty-workspace handling") do
      task
    else
      String.trim(task) <> @empty_workspace_instruction
    end
  end

  defp append_empty_workspace_instruction(_task), do: String.trim(@empty_workspace_instruction)

  defp param_value(params, key) when is_map(params),
    do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp param_value(_params, _key), do: nil

  defp put_param_value(params, key, value) when is_map(params) do
    params
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end

  defp fallback_proposal(objective, environment, opts) do
    case Keyword.fetch(opts, :fallback_recipe) do
      {:ok, recipe} ->
        {:ok, RecipeLibrary.proposal(recipe, objective, sources: source_refs(environment))}

      :error ->
        {:error, explicit_fallback_required_error()}
    end
  end

  defp maybe_fallback(objective, environment, opts, validation_opts, error) do
    if fallback_enabled?(opts) do
      case fallback_proposal(objective, environment, opts) do
        {:ok, proposal} ->
          proposal
          |> validate_candidate(opts, validation_opts, :fallback)
          |> case do
            {:ok, proposal, report} ->
              {:ok, proposal, report}

            {:error, fallback_error} ->
              {:error, proposal_failure_error(:fallback, [fallback_error, error])}
          end

        {:error, %Error{} = fallback_error} ->
          {:error, proposal_failure_error(:fallback, [fallback_error, error])}
      end
    else
      {:error, proposal_failure_error(:final, [error])}
    end
  end

  defp source_refs(%CodebaseEnvironment{} = environment) do
    environment.source_index
    |> RunicAI.Coding.RLM.SourceIndex.list()
    |> Enum.map(& &1.ref.source_id)
  end

  defp maybe_put_client(llm_opts, nil), do: llm_opts
  defp maybe_put_client(llm_opts, client), do: Keyword.put_new(llm_opts, :client, client)

  defp maybe_put_receive_timeout(llm_opts, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: Keyword.put_new(llm_opts, :receive_timeout, timeout_ms)

  defp maybe_put_receive_timeout(llm_opts, _timeout_ms), do: llm_opts

  defp normalize_generated_candidate(candidate, objective) when is_map(candidate) do
    candidate
    |> unwrap_candidate()
    |> put_default_objective(objective)
    |> put_default_stop_conditions()
  end

  defp normalize_generated_candidate(candidate, _objective), do: candidate

  defp merge_repaired_candidate(previous, repaired) when is_map(previous) and is_map(repaired) do
    previous
    |> unwrap_candidate()
    |> Map.merge(unwrap_candidate(repaired))
  end

  defp merge_repaired_candidate(_previous, repaired), do: repaired

  defp unwrap_candidate(candidate) when is_map(candidate) do
    Enum.find_value(
      [:workflow_proposal, "workflow_proposal", :proposal, "proposal", :workflow, "workflow"],
      candidate,
      fn key ->
        case Map.get(candidate, key) do
          value when is_map(value) -> value
          _other -> nil
        end
      end
    ) || candidate
  end

  defp put_default_objective(candidate, objective) when is_map(candidate) do
    case field(candidate, :objective) do
      value when is_binary(value) and value != "" -> candidate
      _other -> Map.put(candidate, "objective", objective)
    end
  end

  defp put_default_stop_conditions(candidate) when is_map(candidate) do
    case field(candidate, :stop_conditions) do
      [_first | _rest] ->
        candidate

      _other ->
        nodes = normalize_candidate_nodes(field(candidate, :nodes))
        final_node = List.last(nodes)

        stop_condition =
          case field(final_node || %{}, :id) do
            id when is_binary(id) and id != "" -> "workflow reaches final node #{id}"
            _other -> "workflow reaches its final accepted node"
          end

        Map.put(candidate, "stop_conditions", [stop_condition])
    end
  end

  defp normalize_candidate_nodes(nodes) when is_list(nodes), do: nodes
  defp normalize_candidate_nodes(_nodes), do: []

  defp maybe_implementation_seed(objective, environment, opts, validation_opts) do
    if implementation_seed_enabled?(objective, opts) do
      objective_contract = ObjectiveContract.infer!(objective)

      RecipeLibrary.proposal(:implementation, objective,
        sources: source_refs(environment),
        objective_contract: objective_contract
      )
      |> validate_candidate(opts, validation_opts, :seeded_recipe)
    end
  end

  defp implementation_seed_enabled?(objective, opts) do
    implementation_recipe_enabled?(opts) and
      mutation_enabled?(opts) and
      implementation_objective?(objective)
  end

  defp implementation_recipe_enabled?(opts) do
    Keyword.get(opts, :seed_implementation?, Keyword.get(opts, :seed_project_generation?, false))
  end

  defp implementation_objective?(objective) when is_binary(objective) do
    objective = String.downcase(objective)

    Regex.match?(
      ~r/(^|[^a-z0-9_])(add|build|change|create|fix|generate|implement|modify|patch|prototype|repair|update|write)([^a-z0-9_]|$)/,
      objective
    )
  end

  defp implementation_objective?(_objective), do: false

  defp policy_summary(opts) do
    validation_opts = Keyword.get(opts, :validation_opts, [])

    %{
      allowed_commands: Keyword.get(validation_opts, :allowed_commands, []),
      allow_mutation?: Keyword.get(validation_opts, :allow_mutation?, false),
      allow_commands?: Keyword.get(validation_opts, :allow_commands?, false),
      allow_scripts?: Keyword.get(validation_opts, :allow_scripts?, false),
      required_any_node_kinds:
        Keyword.get(opts, :required_any_node_kinds, inferred_required_any_node_kinds(opts)),
      required_all_node_kinds: Keyword.get(opts, :required_all_node_kinds, []),
      allowed_acceptance_check_types: AcceptanceCheck.types()
    }
  end

  defp node_shape_examples do
    [
      %{
        id: "scaffold",
        kind: "command",
        params: %{args: %{argv: ["allowed-command", "arg"], cwd: "."}}
      },
      %{
        id: "implement",
        kind: "agent",
        params: %{
          mode: "patch",
          workspace_path: "relative/project",
          task: "Implement a concrete slice and verify it."
        }
      },
      %{
        id: "verify",
        kind: "verification_gate",
        params: %{
          checks: [
            %{id: "required-file", type: "file_exists", params: %{path: "relative/path"}},
            %{
              id: "source-evidence",
              type: "source_contains",
              params: %{glob: "relative/**/*.ex", text: "ExpectedEvidence"}
            },
            %{
              id: "tests-pass",
              type: "command_passes",
              params: %{argv: ["allowed-command", "test"]}
            }
          ]
        }
      }
    ]
  end

  defp fallback_enabled?(opts) do
    Keyword.get(opts, :fallback?, false)
  end

  defp explicit_fallback_required_error do
    coordinator_error("RLM coding fallback requires an explicit fallback_recipe",
      stage: :fallback,
      reason: :missing_fallback_recipe
    )
  end

  defp mutation_enabled?(opts) do
    validation_opts = Keyword.get(opts, :validation_opts, [])

    Keyword.get(opts, :mutation?, false) or
      Keyword.get(opts, :mode) == :patch or
      Keyword.get(validation_opts, :allow_mutation?, false)
  end

  defp normalize_coordination_opts(opts) do
    validation_opts =
      opts
      |> Keyword.get(:validation_opts, [])
      |> inherit_capability_opts(opts)
      |> maybe_enable_mutation(opts)

    Keyword.put(opts, :validation_opts, validation_opts)
  end

  defp inherit_capability_opts(validation_opts, opts) do
    Enum.reduce(
      [:mode, :profile, :toolsets, :disabled_tools, :tool_config],
      validation_opts,
      fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> Keyword.put_new(acc, key, value)
          :error -> acc
        end
      end
    )
  end

  defp maybe_enable_mutation(validation_opts, opts) do
    if Keyword.get(opts, :mode) == :patch or Keyword.get(opts, :mutation?, false) do
      validation_opts
      |> Keyword.put_new(:allow_mutation?, true)
      |> Keyword.put_new(:allow_verification?, true)
      |> Keyword.put_new(:allow_commands?, true)
      |> Keyword.put_new(:allowed_commands, ["mix", "git"])
    else
      validation_opts
    end
  end

  defp require_node_kinds(%WorkflowProposal{} = proposal, opts) do
    node_kinds = Enum.map(proposal.nodes, & &1.kind)

    cond do
      missing_required = missing_required_node_kinds(node_kinds, opts) ->
        {:error,
         coordinator_error("RLM coding workflow proposal is missing required node kinds",
           stage: :node_kind_requirements,
           missing_kinds: missing_required,
           node_kinds: node_kinds
         )}

      missing_any = missing_any_node_kind?(node_kinds, opts) ->
        {:error,
         coordinator_error("RLM coding workflow proposal is missing a required mutating node",
           stage: :node_kind_requirements,
           required_any_node_kinds: missing_any,
           node_kinds: node_kinds
         )}

      true ->
        :ok
    end
  end

  defp missing_required_node_kinds(node_kinds, opts) do
    required = Keyword.get(opts, :required_all_node_kinds, [])
    missing = required -- node_kinds
    if missing == [], do: nil, else: missing
  end

  defp missing_any_node_kind?(node_kinds, opts) do
    required_any =
      if Keyword.has_key?(opts, :required_any_node_kinds) do
        Keyword.fetch!(opts, :required_any_node_kinds)
      else
        inferred_required_any_node_kinds(opts)
      end

    cond do
      required_any == [] -> nil
      Enum.any?(required_any, &(&1 in node_kinds)) -> nil
      true -> required_any
    end
  end

  defp inferred_required_any_node_kinds(opts) do
    if mutation_enabled?(opts), do: [:command, :agent, :edit], else: []
  end

  defp proposal_failure_error(stage, errors) do
    coordinator_error("RLM coding coordinator could not produce an accepted workflow proposal",
      stage: stage,
      errors: Enum.map(errors, &error_details/1)
    )
  end

  defp coordinator_error(message, details) do
    Error.validation(message, source: __MODULE__, details: Map.new(details))
  end

  defp error_details(%Error{} = error) do
    %{
      kind: error.kind,
      message: error.message,
      details: error.details,
      source: inspect(error.source),
      retryable?: error.retryable?,
      reason_message: error_reason_message(error),
      status: error_detail(error, :status),
      response_body_preview: error_detail(error, :response_body_preview),
      text_preview: error_detail(error, :text_preview)
    }
    |> compact_map()
  end

  defp error_details(error) when is_map(error), do: error

  defp error_details(error) do
    %{kind: :unknown, message: inspect(error), details: %{}}
  end

  defp error_reason_message(%Error{} = error) do
    error_detail(error, :reason_message) || reason_message(error_detail(error, :reason))
  end

  defp reason_message(nil), do: nil
  defp reason_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp reason_message(reason) when is_binary(reason), do: reason
  defp reason_message(reason), do: inspect(reason, limit: 20, printable_limit: 512)

  defp error_detail(%Error{details: details}, key), do: field(details, key)

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, to_string(key))

  defp field(_value, _key), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
