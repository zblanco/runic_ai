defmodule RunicAI.Coding.RLM.Coordinator do
  @moduledoc """
  RLM coding coordinator that proposes validated workflow data.
  """

  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.CoordinationPatterns
  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.ProposalNode
  alias RunicAI.Coding.RLM.RecipeLibrary
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowValidationReport
  alias RunicAI.Coding.RLM.WorkflowValidator
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result

  @default_model "openai:gpt-5.4-mini"
  @default_repair_attempts 1
  @default_generation_mode :json_text

  @spec propose(String.t(), CodebaseEnvironment.t(), keyword()) ::
          {:ok, WorkflowProposal.t(), WorkflowValidationReport.t()} | {:error, Error.t()}
  def propose(objective, %CodebaseEnvironment{} = environment, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    validation_opts = Keyword.get(opts, :validation_opts, [])

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
    caller explicitly enables mutation. Include at least one stop condition.

    Required output shape:
    - nodes MUST be a JSON array of objects.
    - each node object MUST include id, kind, and params.
    - node ids MUST be non-empty strings; never use null ids and never return
      node names as bare strings.
    - edges MUST be a JSON array of objects with from and to fields.
    - policies, metadata, and params MUST be JSON objects.
    - never return prose strings for nodes, edges, policies, or metadata.

    Node parameter conventions:
    - command nodes use params.args.argv and may only use allowed command executables.
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
    final verification gate.
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

    case generate_proposal_object(model, prompt(objective, environment, opts), opts, llm_opts) do
      {:ok, object} ->
        object
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
        repaired_object
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
        {:error,
         coordinator_error("RLM coding coordinator could not repair the workflow proposal",
           stage: :repair_generation,
           error: error_details(error),
           previous_errors: Enum.map(errors, &error_details/1)
         )}
    end
  end

  defp repair_prompt(objective, environment, opts, object, errors) do
    """
    You are repairing an invalid RunicAI RLM coding workflow proposal.

    Objective:
    #{objective}

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

  defp decode_generated_json(text) when is_binary(text) do
    text
    |> strip_markdown_fence()
    |> Jason.decode()
    |> case do
      {:ok, object} when is_map(object) ->
        {:ok, object}

      {:ok, value} ->
        {:error,
         Error.validation("generated workflow proposal JSON must decode to an object",
           source: __MODULE__,
           details: %{value: value}
         )}

      {:error, error} ->
        {:error,
         Error.validation("generated workflow proposal was not valid JSON",
           source: __MODULE__,
           details: %{error: Exception.message(error), text_preview: String.slice(text, 0, 4_000)}
         )}
    end
  end

  defp strip_markdown_fence(text) do
    text = String.trim(text)

    case Regex.run(~r/\A```(?:json)?\s*(.*?)\s*```\z/s, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      _other -> text
    end
  end

  defp validate_candidate(candidate, opts, validation_opts, stage) do
    with {:ok, proposal} <- WorkflowProposal.from_input(candidate),
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

  defp fallback_proposal(objective, environment, opts) do
    RecipeLibrary.proposal(Keyword.get(opts, :fallback_recipe, :repo_qa), objective,
      sources: source_refs(environment)
    )
  end

  defp maybe_fallback(objective, environment, opts, validation_opts, error) do
    if fallback_enabled?(opts) do
      fallback =
        objective
        |> fallback_proposal(environment, opts)
        |> validate_candidate(opts, validation_opts, :fallback)

      case fallback do
        {:ok, proposal, report} ->
          {:ok, proposal, report}

        {:error, fallback_error} ->
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
    Keyword.get(opts, :fallback?, not mutation_enabled?(opts))
  end

  defp mutation_enabled?(opts) do
    validation_opts = Keyword.get(opts, :validation_opts, [])
    Keyword.get(opts, :mutation?, false) or Keyword.get(validation_opts, :allow_mutation?, false)
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
      source: inspect(error.source)
    }
  end

  defp error_details(error) when is_map(error), do: error

  defp error_details(error) do
    %{kind: :unknown, message: inspect(error), details: %{}}
  end
end
