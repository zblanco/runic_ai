defmodule RunicAI.Sandbox.GeneratedComponentProposalPrompt do
  @moduledoc """
  Prompt and schema helpers for generated sandbox component contracts.

  This prompt asks for a component contract only. Code generation, sandbox
  writes, tests, repair, and promotion are separate reviewed phases.
  """

  alias RunicAI.Sandbox.GeneratedComponent

  @spec schema() :: keyword()
  def schema do
    [
      id: [type: :string, required: true],
      name: [type: :string, required: true],
      language: [type: :string, required: true],
      runtime: [type: :string, required: true],
      entrypoint: [type: :string, required: true],
      capability_profile: [type: :string],
      sandbox_profile: [type: :string],
      source_artifacts: [type: {:list, :map}],
      test_artifacts: [type: {:list, :map}],
      interface: [type: :map, required: true],
      verification: [type: :map, required: true],
      promotion_status: [type: :string, required: true],
      provenance: [type: {:list, :map}],
      metadata: [type: :map]
    ]
  end

  @spec manifest(keyword()) :: map()
  def manifest(opts \\ []) when is_list(opts) do
    %{
      languages: Enum.map(GeneratedComponent.languages(), &Atom.to_string/1),
      promotion_statuses: Enum.map(GeneratedComponent.promotion_statuses(), &Atom.to_string/1),
      default_language:
        Atom.to_string(normalize_language(Keyword.get(opts, :default_language, :python))),
      default_runtime: Keyword.get(opts, :default_runtime, "python"),
      default_capability_profile: Keyword.get(opts, :capability_profile, "sandbox_docker_read"),
      default_sandbox_profile: Keyword.get(opts, :sandbox_profile, "local_code"),
      default_policy: %{
        network: "disabled",
        filesystem: "sandbox_only",
        promotion_requires_review: true
      },
      required_contract_sections: [
        "interface.inputs",
        "interface.outputs",
        "verification.commands",
        "verification.expected_artifacts",
        "verification.acceptance_checks"
      ]
    }
  end

  @spec prompt(String.t(), keyword()) :: String.t()
  def prompt(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    manifest = Keyword.get(opts, :manifest, manifest(opts))

    """
    You are proposing a RunicAI sandbox generated-component contract.

    Objective:
    #{objective}

    Context summary:
    #{context_summary(opts)}

    Available context refs:
    #{Jason.encode!(Keyword.get(opts, :context_refs, []))}

    Capability manifest:
    #{Jason.encode!(manifest)}

    Return one JSON object matching the generated-component contract. This is a
    contract proposal only. Do not write source code, tests, shell commands, or
    workflow blueprints. The next phase will generate and test code inside a
    sandbox if this contract is accepted.

    Required behavior:
    - Choose the least powerful language/runtime that fits the objective.
    - Default to network disabled and sandbox-only filesystem access.
    - Set promotion_status to "draft".
    - Leave source_artifacts and test_artifacts empty unless the caller
      supplied concrete artifact refs.
    - Describe inputs and outputs under interface using stable names, types,
      required flags, and short descriptions.
    - Include verification.commands, verification.expected_artifacts, and
      verification.acceptance_checks.
    - Include metadata.policy with network, filesystem, and review
      requirements.
    - Include metadata.risks for ambiguity, unsafe operations, unsupported
      runtime assumptions, or host-materialization needs.
    - Do not request host writes or broader tools in the contract. Promotion
      into the host repo must happen through a later review gate.

    Required top-level shape:
    #{Jason.encode!(shape_example(objective, opts))}

    Return only valid JSON. Do not wrap it in Markdown fences and do not add
    prose outside the JSON object.
    """
  end

  @spec repair_prompt(String.t(), map() | term(), [map()], keyword()) :: String.t()
  def repair_prompt(objective, invalid_object, diagnostics, opts \\ [])
      when is_binary(objective) and is_list(opts) do
    """
    You are repairing an invalid RunicAI sandbox generated-component contract.

    Objective:
    #{objective}

    Capability manifest:
    #{Jason.encode!(Keyword.get(opts, :manifest, manifest(opts)))}

    Validation diagnostics:
    #{Jason.encode!(json_safe(diagnostics))}

    Previous invalid object:
    #{Jason.encode!(json_safe(invalid_object))}

    Return one corrected generated-component contract JSON object. Repair only
    the contract shape, enum values, interface, verification plan, or policy
    metadata. Do not generate source code or tests. Keep promotion_status as
    "draft" unless the previous object already referenced verified artifacts.

    Required top-level shape:
    #{Jason.encode!(shape_example(objective, opts))}

    Return only valid JSON.
    """
  end

  @spec shape_example(String.t(), keyword()) :: map()
  def shape_example(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    id = Keyword.get(opts, :id, default_id(objective))
    language = normalize_language(Keyword.get(opts, :default_language, :python))
    runtime = Keyword.get(opts, :default_runtime, Atom.to_string(language))

    %{
      id: id,
      name: Keyword.get(opts, :name, human_name(objective)),
      language: Atom.to_string(language),
      runtime: runtime,
      entrypoint: Keyword.get(opts, :entrypoint, "component.py:run"),
      capability_profile: Keyword.get(opts, :capability_profile, "sandbox_docker_read"),
      sandbox_profile: Keyword.get(opts, :sandbox_profile, "local_code"),
      source_artifacts: Keyword.get(opts, :source_artifacts, []),
      test_artifacts: Keyword.get(opts, :test_artifacts, []),
      interface: %{
        inputs: [
          %{
            name: "input",
            type: "any",
            required: true,
            description: "Objective-specific structured input."
          }
        ],
        outputs: [
          %{
            name: "output",
            type: "any",
            required: true,
            description: "Structured result satisfying the objective contract."
          }
        ],
        error_shape: %{
          type: "object",
          required: ["message"],
          description: "Structured component error."
        }
      },
      verification: %{
        status: "planned",
        commands: [default_test_command(language)],
        expected_artifacts: [],
        acceptance_checks: [
          "unit tests pass in sandbox",
          "output matches interface.outputs",
          "no host filesystem or network access is required"
        ]
      },
      promotion_status: "draft",
      provenance: provenance(opts),
      metadata: %{
        objective: objective,
        policy: %{
          network: "disabled",
          filesystem: "sandbox_only",
          promotion_requires_review: true
        },
        risks: []
      }
    }
  end

  @spec contract_from_proposal(map() | keyword()) ::
          {:ok, GeneratedComponent.t()} | {:error, RunicAI.Error.t()}
  def contract_from_proposal(proposal), do: GeneratedComponent.from_input(proposal)

  defp default_id(objective) do
    slug =
      objective
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 48)

    "generated:#{if slug == "", do: "component", else: slug}"
  end

  defp human_name(objective) do
    objective
    |> String.trim()
    |> case do
      "" -> "Generated component"
      text -> String.slice(text, 0, 80)
    end
  end

  defp default_test_command(:elixir), do: "mix test"
  defp default_test_command(:node), do: "npm test"
  defp default_test_command(:bash), do: "bash test_component.sh"
  defp default_test_command(:wasm), do: "run sandbox wasm component tests"
  defp default_test_command(_language), do: "python -m pytest"

  defp normalize_language(language) when language in [:elixir, :python, :node, :bash, :wasm],
    do: language

  defp normalize_language(language) when is_binary(language) do
    GeneratedComponent.languages()
    |> Enum.find(&(Atom.to_string(&1) == language))
    |> case do
      nil -> :python
      language -> language
    end
  end

  defp normalize_language(_language), do: :python

  defp provenance(opts) do
    opts
    |> Keyword.get(:provenance, [])
    |> List.wrap()
    |> Enum.map(&json_safe/1)
  end

  defp context_summary(opts) do
    case Keyword.get(opts, :context_summary, "") do
      nil -> ""
      summary -> summary
    end
  end

  defp json_safe(value), do: json_safe(value, 0)

  defp json_safe(_value, depth) when depth > 8, do: "[depth limit]"

  defp json_safe(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp json_safe(value, _depth) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value, _depth) when is_binary(value) do
    if String.valid?(value) do
      String.slice(value, 0, 4_000)
    else
      "[binary #{byte_size(value)} bytes]"
    end
  end

  defp json_safe(%module{} = value, depth) do
    value
    |> Map.from_struct()
    |> Map.put(:__struct__, inspect(module))
    |> json_safe(depth + 1)
  end

  defp json_safe(value, depth) when is_list(value) do
    value
    |> Enum.take(100)
    |> Enum.map(&json_safe(&1, depth + 1))
  end

  defp json_safe(value, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> json_safe(depth + 1)
  end

  defp json_safe(value, depth) when is_map(value) do
    value
    |> Enum.take(100)
    |> Map.new(fn {key, val} -> {json_safe_key(key), json_safe(val, depth + 1)} end)
  end

  defp json_safe(value, _depth), do: inspect(value, limit: 20, printable_limit: 2_000)

  defp json_safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_safe_key(key) when is_binary(key), do: key
  defp json_safe_key(key), do: inspect(key)
end
