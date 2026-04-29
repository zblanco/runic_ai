defmodule RunicAI.Coding.RLM.ObjectiveJudge do
  @moduledoc """
  LLM-backed semantic judge for objective requirements.

  The judge scores extracted requirements against concrete evidence. It is
  deliberately evidence-first: child summaries are included as context, but
  source, test, command, and verification evidence should drive the verdict.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.ObjectiveContract
  alias RunicAI.Coding.RLM.ObjectiveRequirement
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result

  @default_model "openai:gpt-5.4-mini"

  @type requirement_result :: %{
          required(:requirement_id) => String.t(),
          required(:status) => :pass | :fail | :skipped,
          required(:message) => String.t(),
          required(:metadata) => map()
        }

  @spec evaluate(ObjectiveContract.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(%ObjectiveContract{} = contract, evidence, opts \\ [])
      when is_map(evidence) and is_list(opts) do
    cond do
      contract.requirements == [] ->
        {:ok,
         %{
           status: :skipped,
           requirement_results: [],
           summary: "no semantic requirements were extracted",
           metadata: %{reason: :empty_contract}
         }}

      judge = Keyword.get(opts, :semantic_judge) ->
        judge_contract(judge, contract, evidence, opts)

      true ->
        llm_judge(contract, evidence, opts)
    end
  end

  @spec acceptance_results(ObjectiveContract.t(), map()) :: [AcceptanceCheck.result()]
  def acceptance_results(%ObjectiveContract{} = contract, judgement) when is_map(judgement) do
    result_by_id =
      judgement
      |> Map.get(:requirement_results, Map.get(judgement, "requirement_results", []))
      |> List.wrap()
      |> Map.new(fn result -> {field(result, :requirement_id), result} end)

    Enum.map(contract.requirements, fn requirement ->
      result = Map.get(result_by_id, requirement.id)
      check = requirement_check(requirement)

      case result do
        nil ->
          AcceptanceCheck.result(
            check,
            :fail,
            "semantic judge did not evaluate requirement",
            %{
              requirement: requirement_summary(requirement),
              category: :semantic_requirement_unknown
            }
          )

        result ->
          AcceptanceCheck.result(
            check,
            normalize_acceptance_status(field(result, :status)),
            message(result),
            Map.merge(
              %{
                requirement: requirement_summary(requirement),
                confidence: field(result, :confidence),
                evidence_refs: string_list(field(result, :evidence_refs)),
                repair_instruction: field(result, :repair_instruction),
                category: :semantic_requirement
              },
              normalize_map(field(result, :metadata))
            )
          )
      end
    end)
  end

  @spec schema() :: map()
  def schema do
    ReqLLM.Schema.to_json(zoi_schema())
  end

  @spec zoi_schema() :: term()
  def zoi_schema do
    requirement_result =
      Zoi.object(
        %{
          "requirement_id" => Zoi.string(),
          "status" => Zoi.string(),
          "message" => Zoi.optional(Zoi.string()),
          "rationale" => Zoi.optional(Zoi.string()),
          "evidence_refs" => Zoi.optional(Zoi.array(Zoi.string())),
          "confidence" => Zoi.optional(Zoi.string(coerce: true)),
          "repair_instruction" => Zoi.optional(Zoi.string())
        },
        unrecognized_keys: :strip
      )

    Zoi.object(
      %{
        "status" => Zoi.string(),
        "summary" => Zoi.optional(Zoi.string()),
        "requirement_results" => Zoi.array(requirement_result),
        "risks" => Zoi.optional(Zoi.array(Zoi.string()))
      },
      unrecognized_keys: :strip
    )
  end

  @spec prompt(ObjectiveContract.t(), map()) :: String.t()
  def prompt(%ObjectiveContract{} = contract, evidence) when is_map(evidence) do
    """
    Judge whether a coding implementation satisfies a semantic objective contract.

    Rules:
    - Judge each requirement independently.
    - Use only the provided evidence. Do not assume unstated code exists.
    - A child-agent summary is not proof unless source, tests, commands, or
      artifacts support it.
    - Source and test evidence prove implementation behavior. Workflow
      proposal, trace, episode, command, and child-result evidence can prove
      coordination and process requirements.
    - For negative provenance constraints such as "do not use a prebuilt
      template", treat task-specific workflow metadata, scaffold commands,
      project-specific source, and absence of contradictory evidence as
      sufficient practical evidence. Do not require impossible external proof.
    - Return unknown or incomplete when evidence is insufficient.
    - Required requirements with unknown or incomplete evidence should block
      objective satisfaction.
    - Do not require exact wording from the objective; interpret equivalent
      semantics across languages, frameworks, and naming styles.

    Requirement status values:
    - satisfied: evidence proves the requirement
    - incomplete: evidence shows partial or missing implementation
    - failed: evidence contradicts the requirement
    - unknown: evidence is insufficient to decide
    - not_applicable: requirement is optional or explicitly out of scope

    Objective:
    #{contract.objective}

    Contract:
    #{Jason.encode!(contract_payload(contract), pretty: true)}

    Evidence:
    #{Jason.encode!(evidence, pretty: true)}
    """
  end

  defp judge_contract(judge, contract, evidence, opts) when is_function(judge, 3) do
    judge.(contract, evidence, opts)
    |> normalize_judgement(contract)
  end

  defp judge_contract(judge, contract, evidence, _opts) when is_function(judge, 2) do
    judge.(contract, evidence)
    |> normalize_judgement(contract)
  end

  defp llm_judge(contract, evidence, opts) do
    model = Keyword.get(opts, :semantic_model, Keyword.get(opts, :model, @default_model))

    llm_opts =
      opts
      |> Keyword.get(:semantic_llm_opts, Keyword.get(opts, :llm_opts, []))
      |> maybe_put_client(Keyword.get(opts, :semantic_client, Keyword.get(opts, :client)))

    case Keyword.get(opts, :semantic_judge_generation, :object) do
      :json_text -> llm_judge_json_text(model, contract, evidence, llm_opts)
      _mode -> llm_judge_object(model, contract, evidence, llm_opts)
    end
  end

  defp llm_judge_object(model, contract, evidence, llm_opts) do
    case LLM.generate_object(model, prompt(contract, evidence), schema(), llm_opts) do
      {:ok, object} ->
        normalize_judgement(object, contract)

      {:error, error} ->
        llm_judge_json_text(model, contract, evidence, llm_opts, fallback_error: error)
    end
  end

  defp llm_judge_json_text(model, contract, evidence, llm_opts, opts \\ []) do
    prompt = """
    #{prompt(contract, evidence)}

    Return only one valid JSON object. Do not wrap it in Markdown fences.
    """

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        result
        |> Result.text()
        |> decode_json()
        |> case do
          {:ok, object} -> normalize_judgement(object, contract)
          error -> error
        end

      {:retry, error} ->
        {:error, error}

      {:error, error} ->
        {:error, Keyword.get(opts, :fallback_error, error)}
    end
  end

  defp normalize_judgement({:ok, judgement}, contract),
    do: normalize_judgement(judgement, contract)

  defp normalize_judgement({:error, %Error{} = error}, _contract), do: {:error, error}

  defp normalize_judgement(judgement, contract) when is_map(judgement) do
    with {:ok, judgement} <- cast_judgement(judgement) do
      requirement_results =
        judgement
        |> field(:requirement_results)
        |> List.wrap()
        |> normalize_requirement_results(contract)

      {:ok,
       %{
         status: normalize_overall_status(field(judgement, :status), requirement_results),
         summary: field(judgement, :summary) || "",
         requirement_results: requirement_results,
         risks: string_list(field(judgement, :risks)),
         metadata: normalize_map(field(judgement, :metadata))
       }}
    end
  end

  defp normalize_judgement(other, _contract) do
    {:error,
     Error.validation("semantic objective judge returned an unsupported result",
       source: __MODULE__,
       details: %{result: inspect(other, limit: 20)}
     )}
  end

  defp normalize_requirement_results(results, contract) do
    known_ids = MapSet.new(Enum.map(contract.requirements, & &1.id))

    results
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn result ->
      requirement_id = field(result, :requirement_id) || field(result, :id)

      %{
        requirement_id: requirement_id,
        status: normalize_requirement_status(field(result, :status)),
        message: message(result),
        rationale: field(result, :rationale),
        evidence_refs: string_list(field(result, :evidence_refs)),
        confidence: field(result, :confidence),
        repair_instruction: field(result, :repair_instruction),
        metadata: normalize_map(field(result, :metadata))
      }
    end)
    |> Enum.filter(fn result -> is_binary(result.requirement_id) end)
    |> Enum.filter(fn result -> MapSet.member?(known_ids, result.requirement_id) end)
    |> Enum.uniq_by(& &1.requirement_id)
  end

  defp cast_judgement(judgement) do
    case Zoi.parse(zoi_schema(), stringify_keys(judgement)) do
      {:ok, judgement} ->
        {:ok, judgement}

      {:error, errors} ->
        {:error,
         Error.validation("semantic objective judge output did not match schema",
           source: __MODULE__,
           details: %{errors: inspect(errors, limit: 20)}
         )}
    end
  end

  defp requirement_check(%ObjectiveRequirement{} = requirement) do
    AcceptanceCheck.new!(:semantic_requirement,
      id: "semantic:#{requirement.id}",
      required?: requirement.required?,
      params: %{requirement_id: requirement.id},
      metadata: %{requirement: requirement_summary(requirement)}
    )
  end

  defp requirement_summary(%ObjectiveRequirement{} = requirement) do
    %{
      id: requirement.id,
      kind: requirement.kind,
      description: requirement.description,
      required?: requirement.required?,
      evidence_needed: requirement.evidence_needed,
      acceptance_criteria: requirement.acceptance_criteria
    }
  end

  defp contract_payload(%ObjectiveContract{} = contract) do
    %{
      id: contract.id,
      objective: contract.objective,
      requirements: Enum.map(contract.requirements, &requirement_summary/1)
    }
  end

  defp normalize_acceptance_status(status) do
    case normalize_requirement_status(status) do
      :satisfied -> :pass
      :not_applicable -> :skipped
      :incomplete -> :fail
      :failed -> :fail
      :unknown -> :fail
    end
  end

  defp normalize_requirement_status(status)
       when status in [:satisfied, :incomplete, :failed, :unknown, :not_applicable],
       do: status

  defp normalize_requirement_status(status) when is_binary(status) do
    case String.downcase(status) do
      "pass" -> :satisfied
      "passed" -> :satisfied
      "satisfied" -> :satisfied
      "complete" -> :satisfied
      "completed" -> :satisfied
      "incomplete" -> :incomplete
      "partial" -> :incomplete
      "missing" -> :incomplete
      "fail" -> :failed
      "failed" -> :failed
      "unknown" -> :unknown
      "insufficient" -> :unknown
      "skipped" -> :not_applicable
      "not_applicable" -> :not_applicable
      "not applicable" -> :not_applicable
      _other -> :unknown
    end
  end

  defp normalize_requirement_status(_status), do: :unknown

  defp normalize_overall_status(status, requirement_results) do
    normalized =
      case normalize_requirement_status(status) do
        :satisfied -> :satisfied
        :not_applicable -> :satisfied
        :incomplete -> :incomplete
        :failed -> :failed
        :unknown -> :unknown
      end

    cond do
      Enum.any?(requirement_results, &(&1.status in [:incomplete, :failed, :unknown])) ->
        :incomplete

      requirement_results != [] ->
        :satisfied

      true ->
        normalized
    end
  end

  defp message(result) do
    field(result, :message) || field(result, :rationale) || field(result, :summary) ||
      "semantic requirement was #{field(result, :status) || :unknown}"
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
         Error.validation("semantic judge JSON must decode to an object",
           source: __MODULE__,
           details: %{value: value}
         )}

      {:error, error} ->
        {:error,
         Error.validation("semantic judge JSON was invalid",
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

  defp string_list(values) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value -> inspect(value)
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(value) when is_binary(value), do: [value]
  defp string_list(_value), do: []

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil

  defp maybe_put_client(llm_opts, nil), do: llm_opts
  defp maybe_put_client(llm_opts, client), do: Keyword.put_new(llm_opts, :client, client)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
