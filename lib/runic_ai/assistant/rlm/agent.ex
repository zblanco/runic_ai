defmodule RunicAI.Assistant.RLM.Agent do
  @moduledoc """
  General-purpose dynamic RLM assistant agent.

  The agent proposes a workflow blueprint, validates it, compiles it into a
  Runic graph backed by anonymous functions/components, executes the graph, and
  returns artifacts plus an evidence scorecard.
  """

  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.RepairLoop
  alias RunicAI.Assistant.RLM.WorkflowCompiler
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @default_workflow_response_max_tokens 12_000
  @default_blueprint_generation_timeout_ms 180_000
  @max_conversation_history_messages 12
  @max_conversation_history_chars 16_000
  @workspace_reference_terms [
    "workspace",
    "repo",
    "repository",
    "codebase",
    "files",
    "directory",
    "project",
    ".docs",
    ".runic_ai",
    "mix.exs"
  ]
  @source_action_terms [
    "find",
    "locate",
    "search",
    "scan",
    "read",
    "open",
    "inspect",
    "summarize",
    "summarise",
    "review",
    "grep",
    "list",
    "show me"
  ]
  @source_target_terms [
    "file",
    "files",
    "folder",
    "directory",
    "dir",
    "path",
    "plan",
    "plans",
    "doc",
    "docs",
    "document",
    "module",
    "test",
    "tests",
    "migration",
    "source"
  ]
  @path_reference_pattern ~r/(^|\s)(\.\.?\/|[a-z0-9_.-]+\/[a-z0-9_.\/-]*|[a-z0-9_.-]+\.(exs?|md|livemd|json|ya?ml|toml|txt|db|sqlite))(\s|$|[,.])/i
  @explicit_path_reference_pattern ~r/(^|[\s`'"(\[])(~\/[^\s`'",;:)\]}]+|\/[A-Za-z0-9._~\/-]+|\.{1,2}\/[A-Za-z0-9._\/-]+|[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]*|[A-Za-z0-9_.-]+\.(?:exs?|md|livemd|json|ya?ml|toml|txt|db|sqlite))(?=$|[\s`'",;:).\]}])/i

  @spec run(Workspace.t() | Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(workspace_input, objective, opts \\ [])
      when is_binary(objective) and objective != "" and is_list(opts) do
    run_id = Keyword.get(opts, :run_id) || "assistant:#{System.unique_integer([:positive])}"
    event_sink = Keyword.get(opts, :event_sink, fn _stage -> :ok end)

    with {:ok, workspace} <- workspace_from_input(workspace_input, opts) do
      opts =
        opts
        |> maybe_put_inferred_input_paths(objective, workspace)
        |> maybe_put_inferred_output_path(objective)
        |> maybe_put_source_requirements(objective)

      history = conversation_history(opts)

      opts =
        opts
        |> Keyword.put(:conversation_history, history)
        |> Keyword.put(:conversation_context, format_conversation_history(history))

      emit(event_sink, run_id, :started, :running, %{
        objective: objective,
        conversation_history_count: length(history),
        workspace: workspace.root,
        inputs: Keyword.get(opts, :input_paths, []),
        output: Keyword.get(opts, :output_path)
      })

      emit(event_sink, run_id, :capability_manifest_prepared, :ok, %{
        capabilities: Coordinator.capability_manifest(opts)
      })

      result = propose_validate_execute(workspace, objective, opts, run_id, event_sink)

      case result do
        {:ok, result} ->
          artifact_outcome = artifact_outcome(result.artifacts, opts)

          emit(
            event_sink,
            run_id,
            :completed,
            result_status(result.scorecard),
            result
            |> completed_data()
            |> Map.put(:artifact_paths, artifact_paths(result.artifacts))
            |> Map.put(:artifact_outcome, artifact_outcome)
            |> Map.put(:scorecard, result.scorecard)
          )

          {:ok,
           result
           |> Map.put(:agent, :assistant)
           |> Map.put(:run_id, run_id)
           |> Map.put(:session_id, run_id)
           |> Map.put(:artifact_outcome, artifact_outcome)
           |> Map.put(:status, result_status(result.scorecard))}

        {:error, %Error{} = error} ->
          emit(event_sink, run_id, :failed, :error, %{error: error})
          {:error, error}
      end
    end
  end

  defp propose_validate_execute(workspace, objective, opts, run_id, event_sink) do
    with {:ok, blueprint} <- generate_blueprint(workspace, objective, opts, run_id, event_sink) do
      emit(event_sink, run_id, :blueprint_proposed, :ok, %{
        blueprint_id: blueprint.id,
        component_count: length(blueprint.components),
        sources: blueprint.sources
      })

      case BlueprintValidator.validate(blueprint, validation_opts(opts)) do
        {:ok, report} ->
          execute_blueprint(workspace, objective, blueprint, report, opts, run_id, event_sink, [])

        {:error, %Error{} = error} ->
          repair_and_execute(workspace, objective, opts, run_id, event_sink, error)
      end
    end
  end

  defp generate_blueprint(workspace, objective, opts, run_id, event_sink) do
    with {:ok, timeout_ms} <- blueprint_generation_timeout(opts) do
      started_at = System.monotonic_time(:millisecond)

      emit(event_sink, run_id, :blueprint_generation_started, :running, %{
        model: Keyword.get(opts, :model),
        timeout_ms: timeout_ms,
        proposal_generation: Keyword.get(opts, :proposal_generation, :json_text),
        conversation_history_count: length(conversation_history(opts))
      })

      result =
        case run_coordinator_proposal(workspace, objective, opts, timeout_ms) do
          {:ok, blueprint} ->
            emit(event_sink, run_id, :blueprint_generation_completed, :ok, %{
              elapsed_ms: elapsed_ms(started_at),
              blueprint_id: blueprint.id,
              component_count: length(blueprint.components),
              sources: blueprint.sources
            })

            {:ok, blueprint}

          {:error, %Error{} = error} ->
            emit(event_sink, run_id, :blueprint_generation_completed, :error, %{
              elapsed_ms: elapsed_ms(started_at),
              error: error
            })

            {:error, error}
        end

      result
    end
  end

  defp run_coordinator_proposal(workspace, objective, opts, timeout_ms)
       when timeout_ms in [nil, :infinity] do
    safe_coordinator_proposal(workspace, objective, opts)
  end

  defp run_coordinator_proposal(workspace, objective, opts, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        safe_coordinator_proposal(workspace, objective, opts)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error,
         Error.from_reason(reason,
           kind: :unexpected,
           message: "assistant blueprint generation task exited",
           source: __MODULE__,
           metadata: %{stage: :blueprint_generation}
         )}

      nil ->
        {:error,
         Error.timeout("assistant blueprint generation timed out",
           source: __MODULE__,
           details: %{timeout_ms: timeout_ms}
         )}
    end
  end

  defp safe_coordinator_proposal(workspace, objective, opts) do
    Coordinator.propose(workspace, objective, opts)
  rescue
    exception ->
      {:error,
       Error.from_exception(exception,
         kind: :unexpected,
         source: Coordinator,
         metadata: %{stage: :blueprint_generation}
       )}
  catch
    kind, reason ->
      {:error,
       Error.from_reason(reason,
         kind: :unexpected,
         message: "assistant blueprint generation exited",
         source: Coordinator,
         details: %{exit_kind: kind},
         metadata: %{stage: :blueprint_generation}
       )}
  end

  defp blueprint_generation_timeout(opts) do
    case Keyword.get(
           opts,
           :blueprint_generation_timeout_ms,
           @default_blueprint_generation_timeout_ms
         ) do
      nil ->
        {:ok, @default_blueprint_generation_timeout_ms}

      :infinity ->
        {:ok, :infinity}

      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        {:ok, timeout_ms}

      timeout_ms ->
        {:error,
         Error.validation("assistant blueprint_generation_timeout_ms must be a positive integer",
           source: __MODULE__,
           details: %{blueprint_generation_timeout_ms: timeout_ms}
         )}
    end
  end

  defp elapsed_ms(started_at) do
    System.monotonic_time(:millisecond) - started_at
  end

  defp repair_and_execute(workspace, objective, opts, run_id, event_sink, error) do
    emit(event_sink, run_id, :validation_completed, :error, %{error: error})

    repair =
      case Keyword.fetch(opts, :blueprint) do
        {:ok, invalid_blueprint} ->
          RepairLoop.validation_repair(workspace, objective, invalid_blueprint, error, opts)

        :error ->
          {:error, error}
      end

    repair =
      case repair do
        {:ok, repair} -> {:ok, repair}
        {:error, _repair_error} -> RepairLoop.fallback_repair(workspace, objective, error, opts)
      end

    with {:ok, repair} <- repair,
         blueprint = repair.blueprint,
         {:ok, report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
      emit(event_sink, run_id, :repair_completed, :ok, %{
        strategy: repair.strategy,
        reason: repair.reason,
        blueprint_id: blueprint.id
      })

      execute_blueprint(workspace, objective, blueprint, report, opts, run_id, event_sink, [
        Map.drop(repair, [:blueprint])
      ])
    end
  end

  defp execute_blueprint(
         workspace,
         objective,
         blueprint,
         report,
         opts,
         run_id,
         event_sink,
         repair_history
       ) do
    emit(event_sink, run_id, :validation_completed, :ok, %{validation_report: report})

    run_opts =
      opts
      |> Keyword.put(:run_id, run_id)
      |> Keyword.put(:event_sink, event_sink)
      |> Keyword.put(:objective, objective)
      |> put_default_execution_llm_limit()

    case WorkflowCompiler.run(blueprint, workspace, workflow_input(objective, opts), run_opts) do
      {:ok, result} ->
        result = put_assistant_facing_output(result)

        emit(event_sink, run_id, :execution_completed, :ok, %{
          output: output_summary(result.output),
          artifacts: result.artifacts
        })

        scorecard = result.scorecard || fallback_scorecard(result, opts)

        emit(event_sink, run_id, :scorecard_completed, result_status(scorecard), %{
          scorecard: scorecard
        })

        execution_result =
          result
          |> Map.put(:scorecard, scorecard)
          |> Map.put(:objective_scorecard, scorecard)
          |> Map.put(:repair_history, repair_history)
          |> Map.put(:persistence_ref, nil)

        maybe_repair_scorecard(
          workspace,
          objective,
          blueprint,
          opts,
          run_id,
          event_sink,
          repair_history,
          execution_result
        )

      {:error, %Error{} = error} ->
        emit(event_sink, run_id, :execution_failed, :error, %{error: error})

        maybe_repair_runtime(
          workspace,
          objective,
          blueprint,
          opts,
          run_id,
          event_sink,
          repair_history,
          error
        )
    end
  end

  defp maybe_repair_runtime(
         workspace,
         objective,
         blueprint,
         opts,
         run_id,
         event_sink,
         repair_history,
         error
       ) do
    if runtime_repair_needed?(repair_history, opts) do
      emit(event_sink, run_id, :repair_attempt_started, :running, %{
        strategy: :runtime_diagnostic_repair,
        reason: error.message,
        error: error
      })

      case RepairLoop.runtime_repair(workspace, objective, blueprint, error, opts) do
        {:ok, repair} ->
          blueprint = repair.blueprint

          with {:ok, report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
            emit(event_sink, run_id, :repair_completed, :ok, %{
              strategy: repair.strategy,
              reason: repair.reason,
              blueprint_id: blueprint.id
            })

            execute_blueprint(
              workspace,
              objective,
              blueprint,
              report,
              Keyword.put(opts, :repair_runtime?, false),
              run_id,
              event_sink,
              repair_history ++ [Map.drop(repair, [:blueprint])]
            )
          else
            {:error, %Error{} = repair_error} ->
              emit(event_sink, run_id, :repair_attempt_completed, :error, %{
                strategy: Map.get(repair, :strategy),
                error: repair_error
              })

              {:error, error}
          end

        {:error, %Error{} = repair_error} ->
          emit(event_sink, run_id, :repair_attempt_completed, :error, %{
            strategy: :runtime_diagnostic_repair,
            error: repair_error
          })

          {:error, error}
      end
    else
      {:error, error}
    end
  end

  defp maybe_repair_scorecard(
         workspace,
         objective,
         blueprint,
         opts,
         run_id,
         event_sink,
         repair_history,
         execution_result
       ) do
    scorecard = execution_result.scorecard

    if scorecard_repair_needed?(scorecard, repair_history, opts) do
      emit(event_sink, run_id, :scorecard_repair_started, :running, %{
        scorecard: scorecard,
        residual_risks: Map.get(scorecard || %{}, :residual_risks, [])
      })

      case RepairLoop.scorecard_repair(workspace, objective, blueprint, scorecard, opts) do
        {:ok, repair} ->
          blueprint = repair.blueprint

          with {:ok, report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
            emit(event_sink, run_id, :repair_completed, :ok, %{
              strategy: repair.strategy,
              reason: repair.reason,
              blueprint_id: blueprint.id
            })

            execute_blueprint(
              workspace,
              objective,
              blueprint,
              report,
              Keyword.put(opts, :repair_scorecard?, false),
              run_id,
              event_sink,
              repair_history ++ [Map.drop(repair, [:blueprint])]
            )
          else
            {:error, %Error{} = error} ->
              emit(event_sink, run_id, :scorecard_repair_completed, :error, %{error: error})
              {:ok, execution_result}
          end

        {:error, %Error{} = error} ->
          emit(event_sink, run_id, :scorecard_repair_completed, :error, %{error: error})
          {:ok, execution_result}
      end
    else
      {:ok, execution_result}
    end
  end

  defp scorecard_repair_needed?(scorecard, repair_history, opts) do
    Keyword.get(opts, :repair_scorecard?, true) and result_status(scorecard) == :blocked and
      not Enum.any?(repair_history, fn repair ->
        Map.get(repair, :strategy) in [
          :scorecard_diagnostic_repair,
          "scorecard_diagnostic_repair"
        ]
      end)
  end

  defp runtime_repair_needed?(repair_history, opts) do
    Keyword.get(opts, :repair_runtime?, true) and
      not Enum.any?(repair_history, fn repair ->
        Map.get(repair, :strategy) in [
          :runtime_diagnostic_repair,
          "runtime_diagnostic_repair",
          :runtime_fallback_blueprint,
          "runtime_fallback_blueprint"
        ]
      end)
  end

  defp maybe_put_source_requirements(opts, objective) do
    objective = String.downcase(objective || "")

    cond do
      no_source_requested?(objective) ->
        Keyword.delete(opts, :require_provenance?)

      declared_source_inputs?(opts) or workspace_grounded_objective?(objective) ->
        Keyword.put_new(opts, :require_provenance?, true)

      true ->
        opts
    end
  end

  defp no_source_requested?(objective) do
    String.contains?(objective, [
      "do not inspect files",
      "don't inspect files",
      "do not read files",
      "don't read files",
      "do not inspect the repo",
      "don't inspect the repo",
      "without source",
      "no source inspection"
    ])
  end

  defp declared_source_inputs?(opts) do
    not empty_listish?(Keyword.get(opts, :input_paths, [])) or
      not empty_listish?(Keyword.get(opts, :inputs, []))
  end

  defp maybe_put_inferred_input_paths(opts, objective, %Workspace{} = workspace) do
    if declared_source_inputs?(opts) do
      opts
    else
      case infer_existing_input_paths(objective, workspace) do
        [] ->
          if workspace_grounded_objective?(String.downcase(objective || "")) and
               not no_source_requested?(String.downcase(objective || "")) do
            Keyword.put(opts, :input_paths, ["."])
          else
            opts
          end

        paths ->
          opts
          |> Keyword.put(:input_paths, paths)
          |> Keyword.put(:inferred_input_paths, paths)
      end
    end
  end

  defp maybe_put_inferred_output_path(opts, objective) do
    if Keyword.get(opts, :output_path) in [nil, ""] do
      case infer_output_path(objective) do
        nil -> opts
        path -> Keyword.put(opts, :output_path, path)
      end
    else
      opts
    end
  end

  defp infer_output_path(objective) when is_binary(objective) do
    Regex.scan(
      ~r/\b(?:write|save|create|persist|output|report)\b.{0,120}?\b(?:to|at|as|in)\s+(`[^`]+`|"[^"]+"|'[^']+'|[A-Za-z0-9_.\/-]+\.(?:md|txt|json|jsonl|csv|exs?|livemd))/i,
      objective,
      capture: :all_but_first
    )
    |> Enum.map(fn [path] -> normalize_referenced_path(path) end)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
  end

  defp infer_output_path(_objective), do: nil

  defp infer_existing_input_paths(objective, %Workspace{} = workspace) do
    objective
    |> path_candidates()
    |> Enum.filter(&existing_readable_path?(workspace, &1))
    |> Enum.uniq()
  end

  defp path_candidates(objective) do
    @explicit_path_reference_pattern
    |> Regex.scan(objective, capture: :all_but_first)
    |> Enum.map(fn [_prefix, path] -> normalize_referenced_path(path) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_referenced_path(path) do
    path
    |> String.trim(~s(`'" ))
    |> String.replace(~r/[,.!?;:)\]}]+$/, "")
  end

  defp existing_readable_path?(%Workspace{} = workspace, path) do
    with {:ok, resolved} <- Workspace.resolve_path(workspace, path, :read) do
      File.exists?(resolved.path)
    else
      _error -> false
    end
  end

  defp workspace_grounded_objective?(objective) do
    contains_objective_term?(objective, @workspace_reference_terms) or
      Regex.match?(@path_reference_pattern, objective) or
      source_action_reference?(objective)
  end

  defp source_action_reference?(objective) do
    contains_objective_term?(objective, @source_action_terms) and
      contains_objective_term?(objective, @source_target_terms)
  end

  defp contains_objective_term?(objective, terms) do
    Enum.any?(terms, &objective_term?(objective, &1))
  end

  defp objective_term?(objective, term) do
    cond do
      String.contains?(term, [".", "/"]) ->
        String.contains?(objective, term)

      String.contains?(term, " ") ->
        String.contains?(objective, term)

      true ->
        Regex.match?(
          Regex.compile!("(^|[^a-z0-9_])#{Regex.escape(term)}($|[^a-z0-9_])"),
          objective
        )
    end
  end

  defp workflow_input(objective, opts) do
    history = conversation_history(opts)

    %{
      current_request: objective,
      conversation_history: history,
      conversation_context: format_conversation_history(history)
    }
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
        kind -> " / #{kind}"
      end

    "[#{role}#{kind}]\n#{String.trim(message.content)}"
  end

  defp truncate_history(text) when byte_size(text) <= @max_conversation_history_chars, do: text

  defp truncate_history(text) do
    omitted = byte_size(text) - @max_conversation_history_chars

    text
    |> binary_part(omitted, @max_conversation_history_chars)
    |> then(&("[older conversation context omitted: #{omitted} bytes]\n" <> &1))
  end

  defp put_default_execution_llm_limit(opts) do
    llm_opts =
      opts
      |> Keyword.get(:llm_opts, [])
      |> maybe_put_workflow_response_max_tokens(opts)

    Keyword.put(opts, :llm_opts, llm_opts)
  end

  defp maybe_put_workflow_response_max_tokens(llm_opts, opts) do
    if output_limit_configured?(llm_opts) do
      llm_opts
    else
      Keyword.put(
        llm_opts,
        :max_tokens,
        Keyword.get(
          opts,
          :workflow_response_max_tokens,
          Keyword.get(opts, :direct_response_max_tokens, @default_workflow_response_max_tokens)
        )
      )
    end
  end

  defp output_limit_configured?(llm_opts) do
    Enum.any?(
      [:max_tokens, :max_completion_tokens, :max_output_tokens],
      &Keyword.has_key?(llm_opts, &1)
    )
  end

  defp empty_listish?(nil), do: true
  defp empty_listish?([]), do: true
  defp empty_listish?(value), do: value in ["", false]

  defp workspace_from_input(%Workspace{} = workspace, _opts), do: Workspace.validate(workspace)

  defp workspace_from_input(root, opts) when is_binary(root) do
    Workspace.new(
      root: root,
      path_policy: path_policy(Keyword.get(opts, :write_policy, :docs_only), opts)
    )
  end

  defp workspace_from_input(input, _opts), do: Workspace.from_input(input)

  defp path_policy(:docs_only, opts) do
    PathPolicy.new!(
      read_root_jail: Keyword.get(opts, :read_root_jail, false),
      hidden_policy: :allow,
      allowed_write_roots: [".docs"],
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
    )
  end

  defp path_policy("docs_only", opts), do: path_policy(:docs_only, opts)
  defp path_policy("docs-only", opts), do: path_policy(:docs_only, opts)

  defp path_policy(:workspace_review, opts) do
    PathPolicy.new!(
      read_root_jail: Keyword.get(opts, :read_root_jail, false),
      hidden_policy: :allow,
      allowed_write_roots: ["."],
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
    )
  end

  defp path_policy("workspace_review", opts), do: path_policy(:workspace_review, opts)
  defp path_policy("workspace-review", opts), do: path_policy(:workspace_review, opts)

  defp path_policy(_policy, opts) do
    PathPolicy.new!(
      read_root_jail: Keyword.get(opts, :read_root_jail, false),
      hidden_policy: :allow,
      allowed_write_roots: ["."],
      max_file_bytes: Keyword.get(opts, :max_file_bytes, 5_242_880)
    )
  end

  defp validation_opts(opts) do
    [
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      max_nodes: Keyword.get(opts, :max_nodes),
      profile: Keyword.get(opts, :profile),
      toolsets: Keyword.get(opts, :toolsets, []),
      disabled_tools: Keyword.get(opts, :disabled_tools, []),
      tool_config: Keyword.get(opts, :tool_config, %{}),
      capability_profile: Keyword.get(opts, :capability_profile)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp fallback_scorecard(result, opts) do
    output_text = output_text(result.output)

    objective_status =
      if String.trim(output_text) != "" or result.artifacts != [] do
        :objective_satisfied
      else
        :objective_incomplete
      end

    %{
      id: "scorecard:fallback",
      objective_status: objective_status,
      artifact_path: Keyword.get(opts, :output_path),
      artifact_status: if(result.artifacts == [], do: :not_required, else: :present),
      residual_risks:
        if(objective_status == :objective_satisfied, do: [], else: ["no output produced"])
    }
  end

  defp result_status(%{objective_status: status})
       when status in [:objective_satisfied, "objective_satisfied"],
       do: :ok

  defp result_status(%{objective_status: status})
       when status in [:objective_incomplete, "objective_incomplete"],
       do: :blocked

  defp result_status(_scorecard), do: :ok

  defp artifact_paths(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, :path) || Map.get(&1, "path")))
    |> Enum.reject(&is_nil/1)
  end

  defp artifact_outcome(artifacts, opts) do
    paths = artifact_paths(artifacts)

    cond do
      paths != [] ->
        %{status: "artifact_written", paths: paths}

      output_path = requested_output_path(opts) ->
        %{status: "artifact_not_written", reason: "repair_answer_only", path: output_path}

      true ->
        nil
    end
  end

  defp requested_output_path(opts) do
    case Keyword.get(opts, :output_path) do
      path when is_binary(path) ->
        if String.trim(path) == "", do: nil, else: path

      path ->
        path
    end
  end

  defp completed_data(result) do
    text = result |> Map.get(:output) |> output_text()

    if text == "" do
      %{}
    else
      %{output_text: text}
    end
  end

  defp output_summary(%{text: text}) when is_binary(text), do: %{text_preview: preview(text)}
  defp output_summary(value), do: %{preview: preview(value)}

  defp output_text(%{text: text}) when is_binary(text), do: text
  defp output_text(%{"text" => text}) when is_binary(text), do: text
  defp output_text(value) when is_binary(value), do: value
  defp output_text(_value), do: ""

  defp put_assistant_facing_output(result) when is_map(result) do
    output = Map.get(result, :output)

    if scorecard_output?(output) do
      case assistant_facing_output(result) do
        nil -> result
        assistant_output -> Map.put(result, :output, assistant_output)
      end
    else
      result
    end
  end

  defp assistant_facing_output(result) do
    result
    |> Map.get(:component_results, [])
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: type, output: output}
      when type in [:llm_leaf, :report_composer, :blueprint_reduce] and not is_nil(output) ->
        output

      _other ->
        nil
    end)
  end

  defp scorecard_output?(%{objective_status: _status}), do: true
  defp scorecard_output?(%{"objective_status" => _status}), do: true
  defp scorecard_output?(_output), do: false

  defp emit(event_sink, run_id, stage, status, data) when is_function(event_sink, 1) do
    try do
      event_sink.(%{run_id: run_id, stage: stage, status: status, data: data})
    rescue
      _exception -> :ok
    end
  end

  defp emit(_event_sink, _run_id, _stage, _status, _data), do: :ok

  defp preview(value) when is_binary(value) do
    if String.length(value) > 220, do: String.slice(value, 0, 220) <> "...", else: value
  end

  defp preview(value), do: inspect(value, limit: 12, printable_limit: 220)
end
