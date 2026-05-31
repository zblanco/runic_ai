defmodule RunicAI.Sandbox.GeneratedComponentCatalog.Entry do
  @moduledoc """
  Searchable catalog record for a promoted generated sandbox component.

  Entries are storage-neutral. They carry enough contract, policy, provenance,
  proof, and salience metadata for later workflow planning to reuse a component
  without regenerating its source.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponent

  @statuses [:catalog_available, :catalog_retired]
  @promotion_targets [:ephemeral, :artifact, :host_repo]
  @component_kinds [:sandbox_execute, :step, :map, :reduce, :rule, :accumulator, :tool_adapter]

  @enforce_keys [
    :id,
    :name,
    :status,
    :promotion_target,
    :component_kind,
    :language,
    :runtime,
    :entrypoint,
    :intent_tags,
    :input_signature,
    :output_signature,
    :sandbox_profile,
    :verification,
    :artifacts,
    :provenance,
    :salience,
    :metadata,
    :component
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :name,
    :source,
    :status,
    :promotion_target,
    :component_kind,
    :language,
    :runtime,
    :entrypoint,
    :intent_tags,
    :input_signature,
    :output_signature,
    :examples,
    :sandbox_profile,
    :verification,
    :artifacts,
    :provenance,
    :salience,
    :metadata,
    :component
  ]

  @type status :: :catalog_available | :catalog_retired
  @type promotion_target :: :ephemeral | :artifact | :host_repo
  @type component_kind ::
          :sandbox_execute | :step | :map | :reduce | :rule | :accumulator | :tool_adapter

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          source: atom(),
          status: status(),
          promotion_target: promotion_target(),
          component_kind: component_kind(),
          language: GeneratedComponent.language(),
          runtime: atom() | String.t(),
          entrypoint: String.t(),
          intent_tags: [atom() | String.t()],
          input_signature: [map()],
          output_signature: [map()],
          examples: [map()],
          sandbox_profile: map(),
          verification: map(),
          artifacts: map(),
          provenance: [term()],
          salience: map(),
          metadata: map(),
          component: GeneratedComponent.t()
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec promotion_targets() :: [promotion_target()]
  def promotion_targets, do: @promotion_targets

  @spec component_kinds() :: [component_kind()]
  def component_kinds, do: @component_kinds

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)

    with {:ok, component} <- component(input),
         :ok <- validate_non_empty_string(get(input, :id, component.id), :id),
         :ok <- validate_non_empty_string(get(input, :name, component.name), :name),
         {:ok, status} <-
           normalize_known_atom(get(input, :status, :catalog_available), @statuses, :status),
         {:ok, promotion_target} <-
           normalize_known_atom(
             get(input, :promotion_target, :artifact),
             @promotion_targets,
             :promotion_target
           ),
         {:ok, component_kind} <-
           normalize_known_atom(
             get(input, :component_kind, :sandbox_execute),
             @component_kinds,
             :component_kind
           ),
         {:ok, language} <- normalize_language(get(input, :language, component.language)),
         :ok <- validate_runtime(get(input, :runtime, component.runtime)),
         :ok <-
           validate_non_empty_string(get(input, :entrypoint, component.entrypoint), :entrypoint),
         {:ok, intent_tags} <- normalize_tags(get(input, :intent_tags, [])),
         {:ok, input_signature} <-
           normalize_signature(get(input, :input_signature, interface_ports(component, :inputs))),
         {:ok, output_signature} <-
           normalize_signature(
             get(input, :output_signature, interface_ports(component, :outputs))
           ),
         {:ok, examples} <- normalize_map_list(get(input, :examples, []), :examples),
         {:ok, sandbox_profile} <-
           normalize_map(
             get(input, :sandbox_profile, default_sandbox_profile(component)),
             :sandbox_profile
           ),
         {:ok, verification} <-
           normalize_map(get(input, :verification, component.verification), :verification),
         {:ok, artifacts} <-
           normalize_map(get(input, :artifacts, default_artifacts(component)), :artifacts),
         {:ok, provenance} <-
           normalize_list(get(input, :provenance, component.provenance), :provenance),
         {:ok, salience} <- normalize_map(get(input, :salience, default_salience()), :salience),
         {:ok, metadata} <- normalize_map(get(input, :metadata, component.metadata), :metadata) do
      {:ok,
       %__MODULE__{
         id: get(input, :id, component.id),
         name: get(input, :name, component.name),
         source: get(input, :source, :agent_generated),
         status: status,
         promotion_target: promotion_target,
         component_kind: component_kind,
         language: language,
         runtime: get(input, :runtime, component.runtime),
         entrypoint: get(input, :entrypoint, component.entrypoint),
         intent_tags: intent_tags,
         input_signature: input_signature,
         output_signature: output_signature,
         examples: examples,
         sandbox_profile: sandbox_profile,
         verification: verification,
         artifacts: artifacts,
         provenance: provenance,
         salience: salience,
         metadata: metadata,
         component: component
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, entry} -> entry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = entry) do
    new(%{
      id: entry.id,
      name: entry.name,
      source: entry.source,
      status: entry.status,
      promotion_target: entry.promotion_target,
      component_kind: entry.component_kind,
      language: entry.language,
      runtime: entry.runtime,
      entrypoint: entry.entrypoint,
      intent_tags: entry.intent_tags,
      input_signature: entry.input_signature,
      output_signature: entry.output_signature,
      examples: entry.examples,
      sandbox_profile: entry.sandbox_profile,
      verification: entry.verification,
      artifacts: entry.artifacts,
      provenance: entry.provenance,
      salience: entry.salience,
      metadata: entry.metadata,
      component: entry.component
    })
  end

  @spec from_component(GeneratedComponent.t() | map() | keyword(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def from_component(component_input, opts \\ []) when is_list(opts) do
    with {:ok, component} <- GeneratedComponent.from_input(component_input),
         :ok <- require_promotable(component) do
      decision = Keyword.get(opts, :promotion_decision)
      promotion = promotion_metadata(decision)

      metadata =
        component.metadata
        |> Map.merge(Keyword.get(opts, :metadata, %{}))
        |> maybe_put(:promotion_decision, decision_summary(decision))

      new(%{
        id: Keyword.get(opts, :id, component.id),
        name: Keyword.get(opts, :name, component.name),
        source: Keyword.get(opts, :source, :agent_generated),
        status: Keyword.get(opts, :status, :catalog_available),
        promotion_target:
          Keyword.get(opts, :promotion_target, Map.get(promotion, :target, :artifact)),
        component_kind: Keyword.get(opts, :component_kind, :sandbox_execute),
        language: Keyword.get(opts, :language, component.language),
        runtime: Keyword.get(opts, :runtime, component.runtime),
        entrypoint: Keyword.get(opts, :entrypoint, component.entrypoint),
        intent_tags: Keyword.get(opts, :intent_tags, tags_from(component)),
        input_signature: Keyword.get(opts, :input_signature, interface_ports(component, :inputs)),
        output_signature:
          Keyword.get(opts, :output_signature, interface_ports(component, :outputs)),
        examples: Keyword.get(opts, :examples, examples_from(component)),
        sandbox_profile: Keyword.get(opts, :sandbox_profile, default_sandbox_profile(component)),
        verification: Keyword.get(opts, :verification, verification_from(component)),
        artifacts: Keyword.get(opts, :artifacts, default_artifacts(component)),
        provenance: Keyword.get(opts, :provenance, component.provenance),
        salience:
          Keyword.get(opts, :salience, get(component.metadata, :salience, default_salience())),
        metadata: metadata,
        component: component
      })
    end
  end

  @spec available?(t()) :: boolean()
  def available?(%__MODULE__{status: :catalog_available}), do: true
  def available?(%__MODULE__{}), do: false

  defp require_promotable(%GeneratedComponent{} = component) do
    if GeneratedComponent.promotable?(component) do
      :ok
    else
      {:error,
       Error.validation("generated component catalog entries require promotable components",
         source: __MODULE__,
         details: %{
           component_id: component.id,
           promotion_status: component.promotion_status,
           source_artifact_count: length(component.source_artifacts)
         }
       )}
    end
  end

  defp component(input) do
    case get(input, :component) do
      nil -> GeneratedComponent.from_input(input)
      component -> GeneratedComponent.from_input(component)
    end
  end

  defp tags_from(%GeneratedComponent{metadata: metadata}) when is_map(metadata) do
    metadata
    |> get(:intent_tags, [])
    |> case do
      [] -> get(metadata, :tags, [])
      tags -> tags
    end
  end

  defp examples_from(%GeneratedComponent{interface: interface}) when is_map(interface) do
    case get(interface, :examples, []) do
      examples when is_list(examples) -> examples
      _other -> []
    end
  end

  defp verification_from(%GeneratedComponent{} = component) do
    proof_ref =
      component.metadata
      |> get(:last_generated_component_proof, %{})
      |> get(:proof_id)

    component.verification
    |> maybe_put(:proof_ref, proof_ref)
  end

  defp default_sandbox_profile(%GeneratedComponent{} = component) do
    %{
      profile: component.sandbox_profile,
      capability_profile: component.capability_profile,
      network: get(component.metadata, :network, :disabled)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp default_artifacts(%GeneratedComponent{} = component) do
    %{source: component.source_artifacts, tests: component.test_artifacts}
  end

  defp default_salience do
    %{
      reuse_count: 0,
      successful_reuse_count: 0,
      last_used_at: nil,
      domains: []
    }
  end

  defp promotion_metadata(nil), do: %{}

  defp promotion_metadata(decision) when is_map(decision) do
    details = get(decision, :details, %{})

    %{
      action: get(decision, :action),
      target: get(details, :target)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp promotion_metadata(_decision), do: %{}

  defp decision_summary(nil), do: nil

  defp decision_summary(decision) when is_map(decision) do
    details = get(decision, :details, %{})

    %{
      action: get(decision, :action),
      reason: get(decision, :reason),
      target: get(details, :target)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decision_summary(decision), do: %{value: decision}

  defp interface_ports(%GeneratedComponent{interface: interface}, key) when is_map(interface) do
    case get(interface, key, []) do
      ports when is_list(ports) -> ports
      _other -> []
    end
  end

  defp normalize_signature(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn
      port, {:ok, acc} when is_map(port) ->
        {:cont, {:ok, acc ++ [port]}}

      port, {:ok, acc} when is_binary(port) and port != "" ->
        {:cont, {:ok, acc ++ [%{name: port}]}}

      port, _acc ->
        {:halt,
         {:error,
          Error.validation("generated component catalog signatures require maps or names",
            source: __MODULE__,
            details: %{port: port}
          )}}
    end)
  end

  defp normalize_signature(value) do
    {:error,
     Error.validation("generated component catalog signature must be a list",
       source: __MODULE__,
       details: %{value: value}
     )}
  end

  defp normalize_tags(tags) when is_list(tags) do
    tags
    |> Enum.reduce_while({:ok, []}, fn tag, {:ok, acc} ->
      case normalize_tag(tag) do
        {:ok, tag} -> {:cont, {:ok, acc ++ [tag]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_tags(tags) do
    {:error,
     Error.validation("generated component catalog intent_tags must be a list",
       source: __MODULE__,
       details: %{intent_tags: tags}
     )}
  end

  defp normalize_tag(tag) when is_atom(tag), do: {:ok, tag}

  defp normalize_tag(tag) when is_binary(tag) and tag != "" do
    normalized =
      tag |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

    if normalized == "" do
      {:error,
       Error.validation("generated component catalog tag must not normalize to empty",
         source: __MODULE__,
         details: %{tag: tag}
       )}
    else
      {:ok, normalized}
    end
  end

  defp normalize_tag(tag) do
    {:error,
     Error.validation("generated component catalog tag must be an atom or string",
       source: __MODULE__,
       details: %{tag: tag}
     )}
  end

  defp normalize_map_list(value, _field) when is_list(value) and value == [], do: {:ok, []}

  defp normalize_map_list(value, field) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      {:ok, value}
    else
      {:error,
       Error.validation("generated component catalog #{field} entries must be maps",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
    end
  end

  defp normalize_map_list(value, field) do
    {:error,
     Error.validation("generated component catalog #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map(value, field) do
    {:error,
     Error.validation("generated component catalog #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_list(value, _field) when is_list(value), do: {:ok, value}

  defp normalize_list(value, field) do
    {:error,
     Error.validation("generated component catalog #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_language(language) do
    normalize_known_atom(language, GeneratedComponent.languages(), :language)
  end

  defp normalize_known_atom(value, allowed, field) when is_atom(value) do
    if value in allowed do
      {:ok, value}
    else
      invalid_known_atom(value, allowed, field)
    end
  end

  defp normalize_known_atom(value, allowed, field) when is_binary(value) do
    normalized = value |> String.downcase() |> String.replace("-", "_")

    allowed
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> invalid_known_atom(value, allowed, field)
      value -> {:ok, value}
    end
  end

  defp normalize_known_atom(value, allowed, field), do: invalid_known_atom(value, allowed, field)

  defp invalid_known_atom(value, allowed, field) do
    {:error,
     Error.validation("invalid generated component catalog #{field}",
       source: __MODULE__,
       details: %{field: field, value: value, valid: allowed}
     )}
  end

  defp validate_runtime(runtime) when is_atom(runtime), do: :ok
  defp validate_runtime(runtime) when is_binary(runtime) and runtime != "", do: :ok

  defp validate_runtime(runtime) do
    {:error,
     Error.validation("generated component catalog runtime must be an atom or non-empty string",
       source: __MODULE__,
       details: %{runtime: runtime}
     )}
  end

  defp validate_non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_non_empty_string(value, field) do
    {:error,
     Error.validation("generated component catalog #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil)
  defp get(nil, _key, default), do: default

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_other, _key, default), do: default

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
