defmodule RunicAI.Coding.RLM.ProgressGate do
  @moduledoc """
  Generic progress verification for mutating RLM coding runs.

  The gate catches the failure mode where a workflow creates a scaffold, passes
  trivial generated tests, and then reports success without implementing the
  objective. It is intentionally domain-agnostic: it can use an extracted
  semantic objective contract plus an evidence-first judge, while retaining
  cheap deterministic checks for scaffold leftovers and implementation activity.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.ExecutionEvidence
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.ObjectiveEvidence
  alias RunicAI.Coding.RLM.ObjectiveJudge
  alias RunicAI.Coding.RLM.RepairController
  alias RunicAI.Coding.RLM.WorkflowProposal
  alias RunicAI.Coding.RLM.WorkflowScorecard
  alias RunicAI.Coding.Workspace

  @scaffold_markers [
    "Hello world.",
    "greets the world",
    "def hello do"
  ]

  @objective_stop_terms MapSet.new([
                          "Assertion",
                          "Build",
                          "Compiling",
                          "Continue",
                          "Elixir",
                          "ExUnit",
                          "Failing",
                          "Generated",
                          "If",
                          "Include",
                          "Mix",
                          "Observed",
                          "Original",
                          "Preserve",
                          "Repair",
                          "RLM",
                          "Send",
                          "The",
                          "Use"
                        ])

  @spec enabled?(WorkflowProposal.t(), keyword()) :: boolean()
  def enabled?(%WorkflowProposal{} = proposal, opts) when is_list(opts) do
    policy = Keyword.get(opts, :progress_policy, [])

    cond do
      policy in [false, :disabled] ->
        false

      Keyword.has_key?(opts, :progress_gate?) ->
        Keyword.fetch!(opts, :progress_gate?)

      true ->
        mutation_enabled?(opts) and mutating_proposal?(proposal)
    end
  end

  @spec apply(map(), keyword()) :: map()
  def apply(result, opts \\ []) when is_map(result) and is_list(opts) do
    proposal = Map.get(result, :proposal)

    if match?(%WorkflowProposal{}, proposal) and enabled?(proposal, opts) do
      do_apply(result, proposal, opts)
    else
      result
    end
  end

  @spec evaluate(Workspace.t(), WorkflowProposal.t(), map(), keyword()) ::
          [AcceptanceCheck.result()]
  def evaluate(%Workspace{} = workspace, %WorkflowProposal{} = proposal, context, opts \\ [])
      when is_map(context) and is_list(opts) do
    evaluate_with_metadata(workspace, proposal, context, opts).results
  end

  @spec evaluate_with_metadata(Workspace.t(), WorkflowProposal.t(), map(), keyword()) :: map()
  def evaluate_with_metadata(
        %Workspace{} = workspace,
        %WorkflowProposal{} = proposal,
        context,
        opts
      )
      when is_map(context) and is_list(opts) do
    objective = semantic_objective(proposal, context, opts)
    policy = Keyword.get(opts, :progress_policy, [])
    terms = objective_terms(objective, policy)
    workspace_evidence = workspace_evidence(workspace, policy, context)
    semantic_enabled? = semantic_progress_enabled?(opts, context)

    deterministic_results =
      [
        semantic_coverage_result(terms, workspace_evidence, policy, semantic_enabled?),
        scaffold_marker_result(workspace_evidence),
        meaningful_tests_result(objective, terms, workspace_evidence, policy, semantic_enabled?),
        implementation_activity_result(context, workspace_evidence, policy),
        delivery_root_result(proposal, objective, context, workspace_evidence, policy),
        execution_verification_result(proposal, context, policy)
      ]
      |> Enum.reject(&is_nil/1)

    semantic = semantic_evaluation(workspace, objective, proposal, context, opts)

    %{
      results: deterministic_results ++ semantic.results,
      objective: objective,
      objective_contract: semantic.objective_contract,
      objective_judgement: semantic.objective_judgement,
      objective_evidence_summary: semantic.objective_evidence_summary
    }
  end

  defp execution_verification_result(proposal, context, policy) do
    if execution_verification_required?(proposal, policy) do
      ExecutionEvidence.result(context)
    end
  end

  defp execution_verification_required?(proposal, policy) do
    case policy_value(policy, :require_execution_verification?, :default) do
      value when value in [true, "true"] -> true
      value when value in [false, "false"] -> false
      _default -> seeded_implementation?(proposal)
    end
  end

  defp seeded_implementation?(%WorkflowProposal{metadata: metadata}) when is_map(metadata) do
    (Map.get(metadata, :recipe) || Map.get(metadata, "recipe")) in [
      :implementation,
      "implementation"
    ] and
      (Map.get(metadata, :seeded?) || Map.get(metadata, "seeded?")) in [true, "true"]
  end

  defp seeded_implementation?(_proposal), do: false

  @spec objective_terms(String.t(), keyword() | map() | false | nil) :: [String.t()]
  def objective_terms(objective, policy \\ []) when is_binary(objective) do
    (explicit_terms(policy) ++ (objective |> acceptance_objective_text() |> extracted_terms()))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.take(max_terms(policy))
  end

  defp do_apply(result, proposal, opts) do
    context = Map.get(result, :context, %{})
    workspace = Map.fetch!(context, :workspace)
    progress = evaluate_with_metadata(workspace, proposal, context, opts)
    progress_results = progress.results
    previous_scorecard = context |> Map.get(:scorecards, []) |> List.wrap() |> List.last()

    acceptance_results =
      previous_scorecard
      |> previous_acceptance_results()
      |> Kernel.++(progress_results)

    scorecard =
      WorkflowScorecard.new!(
        acceptance_results: acceptance_results,
        child_results: List.wrap(Map.get(context, :child_results, [])),
        command_statuses: List.wrap(Map.get(context, :command_results, [])),
        changed_files: changed_files(context),
        repair_count: repair_count(previous_scorecard),
        residual_risks: residual_risks(context, acceptance_results),
        metadata: %{
          gate: :generic_progress,
          objective: progress.objective,
          proposal_objective: proposal.objective,
          objective_contract: summarize_contract(progress.objective_contract),
          objective_judgement: summarize_judgement(progress.objective_judgement),
          objective_evidence_summary: progress.objective_evidence_summary,
          high_signal_terms:
            objective_terms(progress.objective, Keyword.get(opts, :progress_policy, []))
        }
      )

    repair_needs = RepairController.from_scorecard(scorecard, acceptance_results)

    context =
      context
      |> update_in([:verification_observations], &Enum.uniq(List.wrap(&1) ++ progress_results))
      |> update_in([:scorecards], &(List.wrap(&1) ++ [scorecard]))
      |> update_in([:repair_needs], &Enum.uniq(List.wrap(&1) ++ repair_needs))
      |> maybe_put_objective_contract(progress.objective_contract)
      |> maybe_append_objective_judgement(progress.objective_judgement)
      |> maybe_append_objective_evidence_summary(progress.objective_evidence_summary)

    result
    |> Map.put(:context, context)
    |> Map.put(:episodes, Map.get(context, :episodes, []))
    |> Map.put(:trace, Map.get(context, :trace, []))
    |> Map.put(:objective_scorecard, scorecard)
    |> Map.put(:output, scorecard)
  end

  defp semantic_coverage_result([], _evidence, _policy, _semantic_enabled?), do: nil

  defp semantic_coverage_result(terms, evidence, policy, true) do
    if truthy_policy?(policy, :lexical_coverage?) do
      semantic_coverage_result(terms, evidence, policy, false)
    end
  end

  defp semantic_coverage_result(terms, evidence, policy, _semantic_enabled?) do
    if truthy_policy?(policy, :lexical_coverage?) do
      lexical_semantic_coverage_result(terms, evidence, policy)
    end
  end

  defp lexical_semantic_coverage_result(terms, evidence, policy) do
    required = required_term_matches(terms, policy)
    matched = Enum.filter(terms, &contains_term?(evidence.source_text, &1))
    missing = terms -- matched
    check = progress_check("progress-semantic-coverage")

    if length(matched) >= required do
      AcceptanceCheck.result(check, :pass, "workspace source covers objective terms", %{
        matched_terms: matched,
        missing_terms: missing,
        required_matches: required,
        source_files: evidence.source_files
      })
    else
      AcceptanceCheck.result(
        check,
        :fail,
        "workspace source does not cover enough objective terms",
        %{
          matched_terms: matched,
          missing_terms: missing,
          required_matches: required,
          source_files: evidence.source_files
        }
      )
    end
  end

  defp scaffold_marker_result(evidence) do
    locations = scaffold_marker_locations(evidence)
    markers = locations |> Enum.map(& &1.marker) |> Enum.uniq()
    check = progress_check("progress-no-default-scaffold")

    if locations == [] do
      AcceptanceCheck.result(
        check,
        :pass,
        "workspace source does not contain default scaffold markers",
        %{}
      )
    else
      AcceptanceCheck.result(check, :fail, "workspace still contains default scaffold markers", %{
        markers: markers,
        locations: locations,
        repair_instruction:
          "Remove or replace default generated scaffold placeholders in the listed files."
      })
    end
  end

  defp meaningful_tests_result(objective, terms, evidence, policy, semantic_enabled?) do
    if test_requested?(objective) do
      check = progress_check("progress-meaningful-tests")
      matched = Enum.filter(terms, &contains_term?(evidence.test_text, &1))
      required = min(required_test_term_matches(terms, policy), length(terms))
      scaffold_markers = Enum.filter(@scaffold_markers, &String.contains?(evidence.test_text, &1))

      cond do
        evidence.test_files == [] ->
          AcceptanceCheck.result(
            check,
            :fail,
            "objective requested tests but no test files were found",
            %{}
          )

        scaffold_markers != [] ->
          AcceptanceCheck.result(
            check,
            :fail,
            "tests still contain default scaffold assertions",
            %{
              markers: scaffold_markers,
              matched_terms: matched
            }
          )

        semantic_enabled? or not truthy_policy?(policy, :lexical_coverage?) ->
          AcceptanceCheck.result(
            check,
            :pass,
            "test files are present and default scaffold assertions are absent",
            %{
              test_files: evidence.test_files,
              matched_terms: matched,
              semantic_judge?: semantic_enabled?
            }
          )

        length(matched) < required ->
          AcceptanceCheck.result(check, :fail, "tests do not cover enough objective terms", %{
            matched_terms: matched,
            required_matches: required,
            test_files: evidence.test_files
          })

        true ->
          AcceptanceCheck.result(check, :pass, "tests contain objective-specific evidence", %{
            matched_terms: matched,
            test_files: evidence.test_files
          })
      end
    end
  end

  defp implementation_activity_result(context, evidence, policy) do
    min_files = integer_policy(policy, :min_source_files, 1)
    changed = changed_files(context)
    check = progress_check("progress-implementation-activity")

    cond do
      changed != [] ->
        AcceptanceCheck.result(check, :pass, "workflow recorded changed files", %{
          changed_files: changed
        })

      truthy_policy?(policy, :allow_existing_source_without_changes?) and
          length(evidence.source_files) >= min_files ->
        AcceptanceCheck.result(
          check,
          :pass,
          "workspace contains implementation source files",
          %{
            source_files: evidence.source_files,
            min_source_files: min_files
          }
        )

      true ->
        AcceptanceCheck.result(
          check,
          :fail,
          "mutating workflow did not record changed implementation files",
          %{
            changed_files: changed,
            source_files: evidence.source_files,
            min_source_files: min_files
          }
        )
    end
  end

  defp delivery_root_result(proposal, objective, context, evidence, policy) do
    if truthy_policy?(policy, :allow_scratch_delivery_root?) do
      nil
    else
      changed = Map.get(evidence, :changed_source_files, [])
      check = progress_check("progress-delivery-root")
      allowed_roots = explicit_delivery_roots(proposal, objective, context)
      scratch_files = Enum.filter(changed, &scratch_delivery_path?(&1, allowed_roots))
      root_files = changed -- scratch_files

      cond do
        changed == [] ->
          nil

        scratch_files == [] ->
          AcceptanceCheck.result(
            check,
            :pass,
            "implementation files target the selected workspace root",
            %{
              changed_files: changed,
              allowed_delivery_roots: allowed_roots
            }
          )

        root_files != [] ->
          AcceptanceCheck.result(
            check,
            :pass,
            "implementation includes selected workspace root deliverables",
            %{
              changed_files: changed,
              scratch_files: scratch_files,
              root_files: root_files,
              allowed_delivery_roots: allowed_roots
            }
          )

        true ->
          AcceptanceCheck.result(
            check,
            :fail,
            "implementation files were written under scratch paths instead of the selected workspace root",
            %{
              scratch_files: scratch_files,
              allowed_delivery_roots: allowed_roots,
              repair_instruction:
                "Move or recreate the deliverable at the selected workspace root, or explicitly target the nested workspace path when that is intentional."
            }
          )
      end
    end
  end

  defp workspace_evidence(%Workspace{} = workspace, policy, context) do
    source_globs =
      List.wrap(
        policy_value(policy, :source_globs, [
          "lib/**/*.ex",
          "src/**/*",
          "*/lib/**/*.ex",
          "*/src/**/*"
        ])
      )

    test_globs =
      List.wrap(
        policy_value(policy, :test_globs, [
          "test/**/*_test.exs",
          "spec/**/*",
          "*/test/**/*_test.exs",
          "*/spec/**/*"
        ])
      )

    source_files = matching_files(workspace, source_globs)
    test_files = matching_files(workspace, test_globs)
    changed = changed_source_or_test_files(workspace, context)
    changed_tests = Enum.filter(changed, &(&1 in test_files or String.contains?(&1, "/test/")))

    source_files = if changed == [], do: source_files, else: changed
    test_files = if changed_tests == [], do: test_files, else: changed_tests
    source_entries = read_file_entries(workspace, Enum.uniq(source_files ++ test_files))
    test_entries = read_file_entries(workspace, test_files)

    %{
      source_files: source_files,
      test_files: test_files,
      changed_source_files: changed,
      changed_test_files: changed_tests,
      source_entries: source_entries,
      test_entries: test_entries,
      source_text: entries_text(source_entries),
      test_text: entries_text(test_entries)
    }
  end

  defp changed_source_or_test_files(workspace, context) do
    context
    |> changed_files()
    |> Enum.filter(fn path ->
      safe_relative_glob?(path) and
        (String.ends_with?(path, [".ex", ".exs"]) or
           String.starts_with?(path, ["lib/", "test/"]) or
           String.contains?(path, ["/lib/", "/test/"])) and
        File.regular?(Path.join(workspace.root, path))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp matching_files(workspace, globs) do
    globs
    |> Enum.flat_map(fn glob ->
      if safe_relative_glob?(glob) do
        workspace.root
        |> Path.join(glob)
        |> Path.wildcard()
      else
        []
      end
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn path ->
      case Workspace.relative_path(workspace, path) do
        {:ok, relative} -> [relative]
        {:error, _error} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp read_file_entries(workspace, paths) do
    paths
    |> Enum.flat_map(fn relative ->
      path = Path.join(workspace.root, relative)

      case File.read(path) do
        {:ok, content} -> [%{path: relative, content: content}]
        {:error, _error} -> []
      end
    end)
  end

  defp entries_text(entries) do
    entries
    |> Enum.map(& &1.content)
    |> Enum.join("\n")
  end

  defp safe_relative_glob?(glob) when is_binary(glob) and glob != "" do
    Path.type(glob) == :relative and ".." not in Path.split(glob)
  end

  defp safe_relative_glob?(_glob), do: false

  defp explicit_delivery_roots(%WorkflowProposal{} = proposal, objective, context) do
    proposal_roots =
      proposal.nodes
      |> Enum.flat_map(fn node ->
        params = Map.get(node, :params, %{})
        [param_from(params, :workspace_path), param_from(params, :cwd), param_from(params, :root)]
      end)

    metadata = Map.get(context, :metadata, %{})

    (proposal_roots ++
       objective_delivery_roots(objective) ++
       objective_delivery_roots(
         Map.get(metadata, :original_objective) || Map.get(metadata, "original_objective")
       ))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_delivery_root/1)
    |> Enum.reject(&(&1 in [nil, "", "."]))
    |> Enum.uniq()
  end

  defp param_from(params, key) when is_map(params) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp objective_delivery_roots(objective) when is_binary(objective) do
    ~r/(?:\.\/)?(?:tmp|apps|packages|examples|fixtures)\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*/
    |> Regex.scan(objective)
    |> List.flatten()
  end

  defp objective_delivery_roots(_objective), do: []

  defp normalize_delivery_root(root) when is_binary(root) do
    root =
      root
      |> String.trim()
      |> String.trim_leading("./")
      |> String.trim_trailing("/")

    parts = Path.split(root)

    case parts do
      [prefix, name | _rest] when prefix in ["tmp", "apps", "packages", "examples", "fixtures"] ->
        Path.join(prefix, name)

      _other ->
        root
    end
  end

  defp scratch_delivery_path?(path, allowed_roots) do
    scratch_path?(path) and not Enum.any?(allowed_roots, &path_under_root?(path, &1))
  end

  defp scratch_path?(path) when is_binary(path) do
    String.starts_with?(path, ["tmp/", ".tmp/", ".runic_ai/"])
  end

  defp scratch_path?(_path), do: false

  defp path_under_root?(path, root) when is_binary(path) and is_binary(root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp path_under_root?(_path, _root), do: false

  defp extracted_terms(objective) do
    camel_terms =
      objective
      |> then(&Regex.scan(~r/\b[A-Z][A-Za-z0-9_]{2,}\b/, &1))
      |> List.flatten()

    quoted_terms =
      objective
      |> then(&Regex.scan(~r/`([^`]+)`|"([^"]+)"/, &1))
      |> Enum.flat_map(fn captures -> tl(captures) end)
      |> Enum.flat_map(&String.split(&1, ~r/[^A-Za-z0-9_]+/, trim: true))

    (camel_terms ++ quoted_terms)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&MapSet.member?(@objective_stop_terms, &1))
  end

  defp scaffold_marker_locations(evidence) do
    evidence
    |> Map.get(:source_entries, [])
    |> Enum.flat_map(fn entry ->
      @scaffold_markers
      |> Enum.filter(&String.contains?(entry.content, &1))
      |> Enum.map(fn marker -> %{path: entry.path, marker: marker} end)
    end)
  end

  defp semantic_evaluation(workspace, objective, proposal, context, opts) do
    if semantic_progress_enabled?(opts, context) do
      with {:ok, contract} <- ObjectiveContract.ensure(objective, context, opts) do
        evidence =
          ObjectiveEvidence.gather(workspace, Map.put(context, :proposal, proposal), opts)

        case ObjectiveJudge.evaluate(contract, evidence, opts) do
          {:ok, judgement} ->
            %{
              results: ObjectiveJudge.acceptance_results(contract, judgement),
              objective_contract: contract,
              objective_judgement: judgement,
              objective_evidence_summary: ObjectiveEvidence.summary(evidence)
            }

          {:error, error} ->
            %{
              results: [semantic_error_result(:judge_failed, error)],
              objective_contract: contract,
              objective_judgement: nil,
              objective_evidence_summary: ObjectiveEvidence.summary(evidence)
            }
        end
      else
        {:error, error} ->
          %{
            results: [semantic_error_result(:contract_extraction_failed, error)],
            objective_contract: nil,
            objective_judgement: nil,
            objective_evidence_summary: nil
          }
      end
    else
      %{
        results: [],
        objective_contract: nil,
        objective_judgement: nil,
        objective_evidence_summary: nil
      }
    end
  end

  defp semantic_objective(%WorkflowProposal{} = proposal, context, opts) do
    (Keyword.get(opts, :semantic_objective) ||
       get_in(context, [:metadata, :original_objective]) ||
       proposal.objective)
    |> acceptance_objective_text()
  end

  defp acceptance_objective_text(objective) when is_binary(objective) do
    objective
    |> prefer_original_objective()
    |> truncate_evidence_tail()
    |> String.trim()
  end

  defp prefer_original_objective(objective) do
    case String.split(objective, "Original objective:", parts: 2) do
      [_before, original] -> original
      _other -> objective
    end
  end

  defp truncate_evidence_tail(objective) do
    [
      "Use the failing smoke evidence",
      "Observed failing smoke",
      "Observed failing evidence",
      "Observed failure",
      "Failing smoke",
      "\n{\n",
      "\n```"
    ]
    |> Enum.reduce(objective, fn marker, acc ->
      case String.split(acc, marker, parts: 2) do
        [head, _tail] -> head
        _other -> acc
      end
    end)
  end

  defp semantic_progress_enabled?(opts, context) do
    Keyword.get(opts, :semantic_progress?, false) or Keyword.has_key?(opts, :objective_contract) or
      match?(%ObjectiveContract{}, Map.get(context, :objective_contract)) or
      Keyword.has_key?(opts, :semantic_judge)
  end

  defp semantic_error_result(reason, error) do
    check =
      AcceptanceCheck.new!(:semantic_requirement,
        id: "semantic:progress:#{reason}",
        params: %{reason: reason},
        metadata: %{source: __MODULE__}
      )

    AcceptanceCheck.result(check, :fail, "semantic progress evaluation failed", %{
      reason: reason,
      error: error_details(error),
      category: :semantic_progress_failure
    })
  end

  defp explicit_terms(policy) do
    policy
    |> policy_value(:required_terms, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp contains_term?(content, term) do
    content
    |> String.downcase()
    |> String.contains?(String.downcase(term))
  end

  defp required_term_matches([], _policy), do: 0

  defp required_term_matches(terms, policy) do
    explicit = policy_value(policy, :min_term_matches)

    cond do
      is_integer(explicit) and explicit >= 0 ->
        explicit

      length(terms) <= 2 ->
        length(terms)

      true ->
        min(max(3, ceil(length(terms) * 0.5)), length(terms))
    end
  end

  defp required_test_term_matches([], _policy), do: 0

  defp required_test_term_matches(terms, policy) do
    explicit = policy_value(policy, :min_test_term_matches)

    cond do
      is_integer(explicit) and explicit >= 0 -> explicit
      length(terms) <= 2 -> 1
      true -> min(2, length(terms))
    end
  end

  defp progress_check(id) do
    AcceptanceCheck.new!(:artifact_present,
      id: id,
      params: %{kind: :generic_progress},
      metadata: %{source: __MODULE__}
    )
  end

  defp maybe_put_objective_contract(context, nil), do: context

  defp maybe_put_objective_contract(context, %ObjectiveContract{} = contract),
    do: Map.put_new(context, :objective_contract, contract)

  defp maybe_append_objective_judgement(context, nil), do: context

  defp maybe_append_objective_judgement(context, judgement) do
    update_in(context, [:objective_judgements], &(List.wrap(&1) ++ [judgement]))
  end

  defp maybe_append_objective_evidence_summary(context, nil), do: context

  defp maybe_append_objective_evidence_summary(context, summary) do
    update_in(context, [:objective_evidence_summaries], &(List.wrap(&1) ++ [summary]))
  end

  defp summarize_contract(nil), do: nil

  defp summarize_contract(%ObjectiveContract{} = contract) do
    %{
      id: contract.id,
      requirement_count: length(contract.requirements),
      requirements:
        Enum.map(contract.requirements, fn requirement ->
          %{
            id: requirement.id,
            kind: requirement.kind,
            description: requirement.description,
            required?: requirement.required?
          }
        end)
    }
  end

  defp summarize_judgement(nil), do: nil

  defp summarize_judgement(judgement) when is_map(judgement) do
    %{
      status: Map.get(judgement, :status),
      summary: Map.get(judgement, :summary),
      risks: Map.get(judgement, :risks, []),
      requirement_results:
        judgement
        |> Map.get(:requirement_results, [])
        |> Enum.map(&Map.take(&1, [:requirement_id, :status, :message, :repair_instruction]))
    }
  end

  defp error_details(%RunicAI.Error{} = error) do
    %{kind: error.kind, message: error.message, details: error.details}
  end

  defp error_details(error), do: %{message: inspect(error)}

  defp changed_files(context) do
    context_files = context |> Map.get(:changed_files, []) |> List.wrap()

    child_files =
      context
      |> Map.get(:child_results, [])
      |> List.wrap()
      |> Enum.flat_map(fn child -> List.wrap(child_field(child, :changed_files)) end)

    (context_files ++ child_files)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp residual_risks(context, acceptance_results) do
    context_risks = context |> Map.get(:risks, []) |> List.wrap()

    child_risks =
      context
      |> Map.get(:child_results, [])
      |> List.wrap()
      |> Enum.flat_map(fn child ->
        List.wrap(child_field(child, :unresolved_risks) || child_field(child, :risks))
      end)

    risks = Enum.uniq(context_risks ++ child_risks)

    if Enum.any?(acceptance_results, &AcceptanceCheck.blocking_failure?/1) do
      risks
    else
      Enum.reject(risks, &superseded_execution_risk?/1)
    end
  end

  defp superseded_execution_risk?(risk) when is_binary(risk) do
    String.starts_with?(risk, ["verification was not run", "turn ended with error: provider:"])
  end

  defp superseded_execution_risk?(_risk), do: false

  defp previous_acceptance_results(%WorkflowScorecard{} = scorecard),
    do: scorecard.acceptance_results

  defp previous_acceptance_results(_scorecard), do: []

  defp repair_count(%WorkflowScorecard{} = scorecard), do: scorecard.repair_count
  defp repair_count(_scorecard), do: 0

  defp test_requested?(objective) do
    objective
    |> String.downcase()
    |> String.contains?(["test", "exunit", "spec", "verify"])
  end

  defp mutating_proposal?(%WorkflowProposal{} = proposal) do
    Enum.any?(proposal.nodes, &(&1.kind in [:command, :agent, :edit, :script]))
  end

  defp mutation_enabled?(opts) do
    validation_opts = Keyword.get(opts, :validation_opts, [])

    Keyword.get(opts, :allow_mutation?, Keyword.get(validation_opts, :allow_mutation?, false)) or
      Keyword.get(opts, :mode) == :patch or Keyword.get(validation_opts, :mode) == :patch or
      :patch in List.wrap(Keyword.get(opts, :toolsets, [])) or
      :patch in List.wrap(Keyword.get(validation_opts, :toolsets, []))
  end

  defp max_terms(policy), do: integer_policy(policy, :max_terms, 12)

  defp integer_policy(policy, key, default) do
    case policy_value(policy, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _value -> default
    end
  end

  defp policy_value(policy, key, default \\ nil)

  defp policy_value(false, _key, default), do: default
  defp policy_value(nil, _key, default), do: default

  defp policy_value(policy, key, default) when is_list(policy),
    do: Keyword.get(policy, key, default)

  defp policy_value(policy, key, default) when is_map(policy),
    do: Map.get(policy, key, Map.get(policy, Atom.to_string(key), default))

  defp truthy_policy?(policy, key), do: policy_value(policy, key, false) in [true, true, "true"]

  defp child_field(child, key) when is_map(child),
    do: Map.get(child, key, Map.get(child, Atom.to_string(key)))

  defp child_field(_child, _key), do: nil
end
