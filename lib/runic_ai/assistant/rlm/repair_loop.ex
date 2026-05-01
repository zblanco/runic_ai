defmodule RunicAI.Assistant.RLM.RepairLoop do
  @moduledoc """
  Minimal repair loop for assistant workflow blueprints.

  Validation repair is targeted: the model receives the invalid blueprint object
  plus structured diagnostics and returns a corrected blueprint. The generic
  fallback remains the final recovery path.
  """

  alias RunicAI.Assistant.RLM.BlueprintProposalPrompt
  alias RunicAI.Assistant.RLM.BlueprintValidator
  alias RunicAI.Assistant.RLM.Coordinator
  alias RunicAI.Assistant.RLM.WorkflowBlueprint
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result

  @default_model "openai:gpt-5.4-mini"

  @spec fallback_repair(Workspace.t(), String.t(), Error.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def fallback_repair(%Workspace{} = workspace, objective, %Error{} = error, opts \\ []) do
    with {:ok, blueprint} <-
           Coordinator.fallback_blueprint(workspace, objective, Keyword.delete(opts, :blueprint)) do
      {:ok,
       %{
         status: :repaired,
         strategy: :generic_fallback_blueprint,
         reason: error.message,
         blueprint: blueprint
       }}
    end
  end

  @spec repair_blueprint_object(Workspace.t(), String.t(), map(), term(), Error.t(), keyword()) ::
          {:ok, WorkflowBlueprint.t()} | {:error, Error.t()}
  def repair_blueprint_object(
        %Workspace{} = _workspace,
        objective,
        manifest,
        invalid_object,
        %Error{} = error,
        opts \\ []
      ) do
    diagnostics = diagnostics(error)
    model = Keyword.get(opts, :model, @default_model)
    llm_opts = llm_opts(opts)

    prompt =
      BlueprintProposalPrompt.repair_prompt(
        objective,
        manifest,
        invalid_object,
        diagnostics,
        opts
      )

    with {:ok, object} <- generate_repair_object(model, prompt, llm_opts),
         {:ok, blueprint} <- WorkflowBlueprint.from_input(object),
         blueprint <- Coordinator.enforce_runtime_scorecard_params(blueprint, opts),
         {:ok, _report} <- BlueprintValidator.validate(blueprint, validation_opts(opts)) do
      {:ok,
       %{
         blueprint
         | metadata:
             blueprint.metadata
             |> Map.put(:proposal_kind, :validation_repair)
             |> Map.put(:repair_diagnostics, diagnostics)
       }}
    else
      {:error, %Error{} = repair_error} ->
        {:error,
         Error.validation("assistant blueprint validation repair failed",
           source: __MODULE__,
           details: %{repair_error: repair_error, original_error: error}
         )}
    end
  end

  @spec validation_repair(Workspace.t(), String.t(), term(), Error.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def validation_repair(
        %Workspace{} = workspace,
        objective,
        invalid_object,
        %Error{} = error,
        opts
      ) do
    manifest = Coordinator.capability_manifest(opts)

    with {:ok, blueprint} <-
           repair_blueprint_object(workspace, objective, manifest, invalid_object, error, opts) do
      {:ok,
       %{
         status: :repaired,
         strategy: :validation_diagnostic_repair,
         reason: error.message,
         diagnostics: diagnostics(error),
         blueprint: blueprint
       }}
    end
  end

  @spec scorecard_repair(Workspace.t(), String.t(), WorkflowBlueprint.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def scorecard_repair(
        %Workspace{} = workspace,
        objective,
        %WorkflowBlueprint{} = _blueprint,
        scorecard,
        opts
      )
      when is_map(scorecard) do
    reason = scorecard_reason(scorecard)

    repair_opts =
      opts
      |> Keyword.delete(:blueprint)
      |> Keyword.put(
        :required_sections,
        get(scorecard, :required_sections, Keyword.get(opts, :required_sections, []))
      )
      |> Keyword.put(
        :required_source_cues,
        get(scorecard, :required_source_cues, Keyword.get(opts, :required_source_cues, []))
      )
      |> Keyword.put(:require_artifact_quality?, true)
      |> maybe_put_output_path(get(scorecard, :artifact_path, Keyword.get(opts, :output_path)))

    with {:ok, blueprint} <-
           Coordinator.fallback_blueprint(
             workspace,
             scorecard_repair_objective(objective, scorecard),
             repair_opts
           ) do
      {:ok,
       %{
         status: :repaired,
         strategy: :scorecard_diagnostic_repair,
         reason: reason,
         diagnostics: scorecard_diagnostics(scorecard),
         blueprint: blueprint
       }}
    end
  end

  defp generate_repair_object(model, prompt, llm_opts) do
    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        result
        |> Result.text()
        |> decode_json()

      {:retry, %Error{} = error} ->
        {:error, error}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp decode_json(text) do
    text
    |> strip_markdown_fence()
    |> Jason.decode()
    |> case do
      {:ok, object} when is_map(object) ->
        {:ok, object}

      {:ok, value} ->
        {:error,
         Error.validation("repaired assistant blueprint JSON must decode to an object",
           source: __MODULE__,
           details: %{value: value}
         )}

      {:error, error} ->
        {:error,
         Error.validation("repaired assistant blueprint was not valid JSON",
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

  defp diagnostics(%Error{} = error) do
    nested_error = error.details[:error] || error.details["error"]

    report =
      error.details[:report] ||
        error.details["report"] ||
        nested_report(nested_error)

    cond do
      is_map(report) and is_list(report[:diagnostics]) ->
        report.diagnostics

      is_map(report) and is_list(report["diagnostics"]) ->
        report["diagnostics"]

      is_map(error.details) ->
        [
          %{
            severity: :error,
            code: :validation_error,
            message: error.message,
            details: error.details
          }
        ]

      true ->
        [%{severity: :error, code: :validation_error, message: error.message}]
    end
  end

  defp scorecard_repair_objective(objective, scorecard) do
    """
    #{objective}

    Scorecard repair diagnostics:
    #{Enum.map_join(scorecard_diagnostics(scorecard), "\n", &"- #{&1}")}

    Preserve all required source cues verbatim when they appear in the inputs:
    #{Enum.map_join(get(scorecard, :required_source_cues, []), "\n", &"- #{&1}")}
    """
  end

  defp scorecard_reason(scorecard) do
    case get(scorecard, :residual_risks, []) do
      [] -> "objective scorecard was incomplete"
      risks -> Enum.join(risks, "; ")
    end
  end

  defp scorecard_diagnostics(scorecard) do
    risks = get(scorecard, :residual_risks, [])

    quality_issues =
      scorecard
      |> get(:artifact_quality, %{})
      |> get(:issues, [])

    (risks ++ quality_issues)
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_put_output_path(opts, nil), do: opts
  defp maybe_put_output_path(opts, ""), do: opts
  defp maybe_put_output_path(opts, path), do: Keyword.put(opts, :output_path, path)

  defp nested_report(%Error{details: details}), do: details[:report] || details["report"]
  defp nested_report(%{details: details}), do: details[:report] || details["report"]
  defp nested_report(%{"details" => details}), do: details["report"] || details[:report]
  defp nested_report(_error), do: nil

  defp llm_opts(opts) do
    opts
    |> Keyword.get(:llm_opts, [])
    |> maybe_put_client(Keyword.get(opts, :client))
  end

  defp maybe_put_client(llm_opts, nil), do: llm_opts
  defp maybe_put_client(llm_opts, client), do: Keyword.put_new(llm_opts, :client, client)

  defp validation_opts(opts) do
    [
      max_generated_function_tier: Keyword.get(opts, :max_generated_function_tier, :tier1),
      max_nodes: Keyword.get(opts, :max_nodes)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp get(map, key, default) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(map, key, default) when is_map(map) and is_binary(key),
    do: Map.get(map, key, Map.get(map, existing_atom_key(map, key), default))

  defp get(_map, _key, default), do: default

  defp existing_atom_key(map, key) do
    Enum.find(Map.keys(map), fn
      atom when is_atom(atom) -> Atom.to_string(atom) == key
      _other -> false
    end)
  end
end
