defmodule RunicAI.Coding.RLM.ObjectiveContract do
  @moduledoc """
  Structured semantic contract extracted from a coding objective.

  The contract is not a workflow template. It is a generic checklist of
  objective requirements that downstream planners, verifiers, and repair loops
  can use regardless of language, framework, or project type.
  """

  alias RunicAI.Coding.RLM.ObjectiveRequirement
  alias RunicAI.Error
  alias RunicAI.LLM
  alias RunicAI.LLM.Result

  @default_model "openai:gpt-5.4-mini"
  @default_max_requirements 16

  @enforce_keys [:id, :objective, :requirements, :metadata]
  defstruct [:id, :objective, requirements: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          requirements: [ObjectiveRequirement.t()],
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    contract = %__MODULE__{
      id: Keyword.get(opts, :id) || "objective-contract:#{:erlang.phash2(objective)}",
      objective: objective,
      requirements: Keyword.get(opts, :requirements, []),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(contract)
  end

  @spec new!(String.t(), keyword()) :: t()
  def new!(objective, opts \\ []) do
    case new(objective, opts) do
      {:ok, contract} -> contract
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = contract), do: validate(contract)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(string_value(input, :objective) || "",
      id: string_value(input, :id),
      requirements: value(input, :requirements, []),
      metadata: value(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("objective contract must be a map or ObjectiveContract",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = contract) do
    with :ok <- non_empty_string(contract.id, :id),
         :ok <- non_empty_string(contract.objective, :objective),
         {:ok, requirements} <- normalize_requirements(contract.requirements),
         :ok <- map(contract.metadata, :metadata) do
      {:ok, %{contract | requirements: requirements}}
    end
  end

  @spec ensure(String.t(), map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def ensure(objective, context, opts \\ []) when is_binary(objective) and is_map(context) do
    cond do
      match?(%__MODULE__{}, Map.get(context, :objective_contract)) ->
        from_input(Map.fetch!(context, :objective_contract))

      Keyword.has_key?(opts, :objective_contract) ->
        opts |> Keyword.fetch!(:objective_contract) |> from_input()

      true ->
        extract(objective, opts)
    end
  end

  @spec infer(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def infer(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    mutation_required? = mutation_required?(objective)
    verification = verification_requirements(objective)

    requirements =
      []
      |> Kernel.++(artifact_requirements(mutation_required?))
      |> Kernel.++(generic_behavior_requirements(mutation_required?))
      |> Kernel.++(verification)

    metadata =
      %{
        source: :deterministic_intent,
        domain: :generic,
        mutation_required?: mutation_required?,
        required_capabilities: required_capabilities(mutation_required?, verification),
        evidence_required: evidence_required(mutation_required?, verification)
      }
      |> Map.merge(normalize_map(Keyword.get(opts, :metadata, %{})))

    new(objective, requirements: requirements, metadata: metadata)
  end

  @spec infer!(String.t(), keyword()) :: t()
  def infer!(objective, opts \\ []) do
    case infer(objective, opts) do
      {:ok, contract} -> contract
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = contract) do
    %{
      id: contract.id,
      objective: contract.objective,
      requirements: Enum.map(contract.requirements, &requirement_to_map/1),
      metadata: contract.metadata
    }
  end

  @spec extract(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def extract(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    model = Keyword.get(opts, :semantic_model, Keyword.get(opts, :model, @default_model))

    llm_opts =
      opts
      |> Keyword.get(:semantic_llm_opts, Keyword.get(opts, :llm_opts, []))
      |> maybe_put_client(Keyword.get(opts, :semantic_client, Keyword.get(opts, :client)))

    case Keyword.get(opts, :semantic_contract_generation, :object) do
      :json_text -> extract_json_text(model, objective, opts, llm_opts)
      _mode -> extract_object(model, objective, opts, llm_opts)
    end
  end

  @spec schema() :: map()
  def schema do
    ReqLLM.Schema.to_json(zoi_schema())
  end

  @spec zoi_schema() :: term()
  def zoi_schema do
    requirement =
      Zoi.object(
        %{
          "id" => Zoi.string(),
          "kind" => Zoi.string(),
          "description" => Zoi.string(),
          "required" => Zoi.optional(Zoi.boolean()),
          "evidence_needed" => Zoi.optional(Zoi.array(Zoi.string())),
          "acceptance_criteria" => Zoi.optional(Zoi.array(Zoi.string()))
        },
        unrecognized_keys: :strip
      )

    Zoi.object(
      %{
        "requirements" => Zoi.array(requirement),
        "assumptions" => Zoi.optional(Zoi.array(Zoi.string())),
        "out_of_scope" => Zoi.optional(Zoi.array(Zoi.string()))
      },
      unrecognized_keys: :strip
    )
  end

  @spec prompt(String.t(), keyword()) :: String.t()
  def prompt(objective, opts \\ []) when is_binary(objective) do
    max_requirements = Keyword.get(opts, :max_semantic_requirements, @default_max_requirements)

    """
    Extract a generic semantic acceptance contract for this coding objective.

    Return only requirements that must be true for the objective to be complete.
    Do not create a workflow plan, do not assume a programming language unless
    the objective names one, and do not invent task-specific templates.

    For each requirement:
    - id: stable snake_case identifier
    - kind: short generic category such as behavior, artifact, verification,
      quality, constraint, or integration
    - description: one concrete requirement in plain language
    - required: true unless the objective clearly marks it optional
    - evidence_needed: evidence classes such as source, tests, command_result,
      runtime_result, child_summary, or artifact
    - acceptance_criteria: observable criteria a judge can verify from evidence

    Limit the contract to the #{max_requirements} highest-signal requirements.

    Objective:
    #{objective}
    """
  end

  defp artifact_requirements(false), do: []

  defp artifact_requirements(true) do
    [
      %{
        id: "implementation_artifacts",
        kind: "artifact",
        description:
          "Create or update durable source artifacts that implement the requested behavior.",
        required: true,
        evidence_needed: ["source", "changed_files"],
        acceptance_criteria: [
          "changed source paths are recorded",
          "source files contain objective-specific implementation code"
        ]
      }
    ]
  end

  defp generic_behavior_requirements(false) do
    [
      requirement(
        "grounded_response",
        "evidence",
        "Provide a final response grounded in the inspected objective evidence.",
        [
          "final response directly addresses the objective",
          "response cites or summarizes the evidence used to reach the answer"
        ]
      )
    ]
  end

  defp generic_behavior_requirements(true) do
    [
      requirement(
        "requested_behavior",
        "behavior",
        "Implement the behavior requested by the objective.",
        [
          "source artifacts contain objective-specific behavior",
          "verification evidence addresses the objective rather than generic scaffold behavior"
        ]
      )
    ]
  end

  defp verification_requirements(objective) do
    objective = String.downcase(objective)

    []
    |> maybe_requirement(
      String.contains?(objective, "test") or String.contains?(objective, "exunit"),
      requirement("tests", "verification", "Provide objective-specific tests.", [
        "tests run without failures",
        "tests do not contain default scaffold assertions"
      ])
    )
    |> maybe_requirement(
      String.contains?(objective, "compile"),
      requirement("compile", "verification", "Compile the project successfully.", [
        "compile command exits successfully"
      ])
    )
    |> maybe_requirement(
      String.contains?(objective, "runtime smoke") or String.contains?(objective, "smoke"),
      requirement("runtime_smoke", "verification", "Provide runtime smoke evidence.", [
        "runtime smoke completes successfully"
      ])
    )
  end

  defp maybe_requirement(requirements, true, requirement), do: requirements ++ [requirement]
  defp maybe_requirement(requirements, false, _requirement), do: requirements

  defp requirement(id, kind, description, criteria) do
    %{
      id: id,
      kind: kind,
      description: description,
      required: true,
      evidence_needed: evidence_for_kind(kind),
      acceptance_criteria: criteria
    }
  end

  defp evidence_for_kind("verification"), do: ["tests", "command_result", "runtime_result"]
  defp evidence_for_kind("artifact"), do: ["source", "changed_files"]
  defp evidence_for_kind("evidence"), do: ["final_answer", "source", "artifact"]
  defp evidence_for_kind(_kind), do: ["source", "tests"]

  defp required_capabilities(false, verification) do
    if verification == [], do: ["analysis"], else: ["analysis", "verification"]
  end

  defp required_capabilities(true, verification) do
    ["coding", "patch"] ++ if verification == [], do: [], else: ["verification"]
  end

  defp evidence_required(false, verification) do
    if verification == [], do: ["final_answer"], else: ["verification_evidence"]
  end

  defp evidence_required(true, verification) do
    ["changed_files", "source"] ++
      if verification == [], do: [], else: ["tests", "command_result"]
  end

  defp mutation_required?(objective) do
    objective = String.downcase(objective)

    Regex.match?(
      ~r/(^|[^a-z0-9_])(add|build|create|fix|generate|implement|patch|repair|update)([^a-z0-9_]|$)/,
      objective
    )
  end

  defp requirement_to_map(requirement) do
    %{
      id: requirement.id,
      kind: requirement.kind,
      description: requirement.description,
      required: requirement.required?,
      evidence_needed: requirement.evidence_needed,
      acceptance_criteria: requirement.acceptance_criteria,
      metadata: requirement.metadata
    }
  end

  defp extract_object(model, objective, opts, llm_opts) do
    case LLM.generate_object(model, prompt(objective, opts), schema(), llm_opts) do
      {:ok, object} ->
        from_generated_object(object, objective, opts)

      {:error, error} ->
        if Keyword.get(opts, :semantic_object_fallback?, true) do
          extract_json_text(model, objective, opts, llm_opts)
        else
          {:error, error}
        end
    end
  end

  defp extract_json_text(model, objective, opts, llm_opts) do
    prompt = """
    #{prompt(objective, opts)}

    Return only one valid JSON object. Do not wrap it in Markdown fences.
    """

    case LLM.generate_text(model, prompt, llm_opts) do
      {:ok, %Result{} = result} ->
        result
        |> Result.text()
        |> decode_json()
        |> case do
          {:ok, object} -> from_generated_object(object, objective, opts)
          error -> error
        end

      {:retry, error} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp from_generated_object(object, objective, opts) when is_map(object) do
    with {:ok, object} <- cast_generated_object(object) do
      from_cast_object(object, objective, opts)
    end
  end

  defp from_generated_object(object, _objective, _opts) do
    {:error,
     Error.validation("objective contract extraction must return an object",
       source: __MODULE__,
       details: %{object: object}
     )}
  end

  defp from_cast_object(object, objective, opts) do
    requirements =
      object
      |> value(:requirements, [])
      |> List.wrap()
      |> Enum.take(Keyword.get(opts, :max_semantic_requirements, @default_max_requirements))

    metadata =
      %{
        source: :llm_extraction,
        assumptions: string_list(value(object, :assumptions, [])),
        out_of_scope: string_list(value(object, :out_of_scope, []))
      }
      |> Map.merge(normalize_map(value(object, :metadata, %{})))

    new(objective, requirements: requirements, metadata: metadata)
  end

  defp cast_generated_object(object) do
    case Zoi.parse(zoi_schema(), stringify_keys(object)) do
      {:ok, object} ->
        {:ok, object}

      {:error, errors} ->
        {:error,
         Error.validation("objective contract output did not match schema",
           source: __MODULE__,
           details: %{errors: inspect(errors, limit: 20)}
         )}
    end
  end

  defp normalize_requirements(requirements) when is_list(requirements) do
    requirements
    |> Enum.reduce_while({:ok, []}, fn requirement, {:ok, acc} ->
      case ObjectiveRequirement.from_input(requirement) do
        {:ok, requirement} -> {:cont, {:ok, [requirement | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, requirements} -> {:ok, Enum.reverse(requirements)}
      error -> error
    end
  end

  defp normalize_requirements(requirements) do
    {:error,
     Error.validation("objective contract requirements must be a list",
       source: __MODULE__,
       details: %{requirements: requirements}
     )}
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
         Error.validation("objective contract JSON must decode to an object",
           source: __MODULE__,
           details: %{value: value}
         )}

      {:error, error} ->
        {:error,
         Error.validation("objective contract JSON was invalid",
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

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("objective contract #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("objective contract #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
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

  defp string_value(map, key) do
    case value(map, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp maybe_put_client(llm_opts, nil), do: llm_opts
  defp maybe_put_client(llm_opts, client), do: Keyword.put_new(llm_opts, :client, client)

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
