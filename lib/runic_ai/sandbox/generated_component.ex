defmodule RunicAI.Sandbox.GeneratedComponent do
  @moduledoc """
  Contract for code generated and verified inside a sandbox.

  A generated component is still data at this layer. It records the source
  artifacts, runtime, entrypoint, value interface, verification evidence,
  promotion status, and optional Runic component wrapper metadata without
  depending on a particular sandbox backend.
  """

  alias RunicAI.Assistant.RLM.ComponentBlueprint
  alias RunicAI.Error

  @languages [:elixir, :python, :node, :bash, :wasm, :other]
  @promotion_statuses [:draft, :verified, :promoted, :rejected]

  @enforce_keys [
    :id,
    :name,
    :language,
    :runtime,
    :entrypoint,
    :source_artifacts,
    :test_artifacts,
    :interface,
    :verification,
    :promotion_status,
    :metadata
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :name,
    :language,
    :runtime,
    :entrypoint,
    :capability_profile,
    :sandbox_profile,
    :component_blueprint,
    source_artifacts: [],
    test_artifacts: [],
    interface: %{},
    verification: %{},
    promotion_status: :draft,
    provenance: [],
    metadata: %{}
  ]

  @type language :: :elixir | :python | :node | :bash | :wasm | :other
  @type promotion_status :: :draft | :verified | :promoted | :rejected

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          language: language(),
          runtime: atom() | String.t(),
          entrypoint: String.t(),
          capability_profile: atom() | String.t() | nil,
          sandbox_profile: atom() | String.t() | nil,
          component_blueprint: ComponentBlueprint.t() | map() | nil,
          source_artifacts: [map() | String.t()],
          test_artifacts: [map() | String.t()],
          interface: map(),
          verification: map(),
          promotion_status: promotion_status(),
          provenance: [term()],
          metadata: map()
        }

  @spec languages() :: [language()]
  def languages, do: @languages

  @spec promotion_statuses() :: [promotion_status()]
  def promotion_statuses, do: @promotion_statuses

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)

    with :ok <- validate_non_empty_string(get(input, :id), :id),
         :ok <- validate_non_empty_string(get(input, :name), :name),
         {:ok, language} <- normalize_language(get(input, :language)),
         :ok <- validate_runtime(get(input, :runtime)),
         :ok <- validate_non_empty_string(get(input, :entrypoint), :entrypoint),
         :ok <- validate_optional_profile(get(input, :capability_profile), :capability_profile),
         :ok <- validate_optional_profile(get(input, :sandbox_profile), :sandbox_profile),
         :ok <- validate_artifacts(get(input, :source_artifacts, []), :source_artifacts),
         :ok <- validate_artifacts(get(input, :test_artifacts, []), :test_artifacts),
         :ok <- validate_map(get(input, :interface, %{}), :interface),
         :ok <- validate_map(get(input, :verification, %{}), :verification),
         {:ok, promotion_status} <-
           normalize_promotion_status(get(input, :promotion_status, :draft)),
         {:ok, component_blueprint} <-
           normalize_component_blueprint(get(input, :component_blueprint)),
         :ok <- validate_list(get(input, :provenance, []), :provenance),
         :ok <- validate_map(get(input, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         id: get(input, :id),
         name: get(input, :name),
         language: language,
         runtime: get(input, :runtime),
         entrypoint: get(input, :entrypoint),
         capability_profile: get(input, :capability_profile),
         sandbox_profile: get(input, :sandbox_profile),
         component_blueprint: component_blueprint,
         source_artifacts: get(input, :source_artifacts, []),
         test_artifacts: get(input, :test_artifacts, []),
         interface: get(input, :interface, %{}),
         verification: get(input, :verification, %{}),
         promotion_status: promotion_status,
         provenance: get(input, :provenance, []),
         metadata: get(input, :metadata, %{})
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, component} -> component
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = component), do: validate(component)
  def from_input(input) when is_list(input) or is_map(input), do: new(input)

  def from_input(input) do
    {:error,
     Error.validation("expected generated component input",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = component) do
    new(%{
      id: component.id,
      name: component.name,
      language: component.language,
      runtime: component.runtime,
      entrypoint: component.entrypoint,
      capability_profile: component.capability_profile,
      sandbox_profile: component.sandbox_profile,
      component_blueprint: component.component_blueprint,
      source_artifacts: component.source_artifacts,
      test_artifacts: component.test_artifacts,
      interface: component.interface,
      verification: component.verification,
      promotion_status: component.promotion_status,
      provenance: component.provenance,
      metadata: component.metadata
    })
  end

  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{promotion_status: status, verification: verification}) do
    status in [:verified, :promoted] and
      verification_status(verification) in [:pass, :passed, :ok]
  end

  @spec promotable?(t()) :: boolean()
  def promotable?(%__MODULE__{} = component) do
    verified?(component) and component.source_artifacts != [] and component.entrypoint != ""
  end

  @spec to_component_blueprint(t(), keyword()) ::
          {:ok, ComponentBlueprint.t()} | {:error, Error.t()}
  def to_component_blueprint(%__MODULE__{} = component, opts \\ []) when is_list(opts) do
    if promotable?(component) do
      ComponentBlueprint.new(
        Keyword.get(opts, :id, component.id),
        Keyword.get(opts, :type, :sandbox_execute),
        params: blueprint_params(component, opts),
        inputs: Keyword.get(opts, :inputs, ["input"]),
        outputs: Keyword.get(opts, :outputs, ["output"]),
        policy: Keyword.get(opts, :policy, %{}),
        provenance: component.provenance,
        metadata: Map.merge(component.metadata, %{generated_component_id: component.id})
      )
    else
      {:error,
       Error.validation(
         "generated component must be verified and have source artifacts before promotion",
         source: __MODULE__,
         details: %{
           id: component.id,
           promotion_status: component.promotion_status,
           verification_status: verification_status(component.verification),
           source_artifact_count: length(component.source_artifacts)
         }
       )}
    end
  end

  defp blueprint_params(%__MODULE__{} = component, opts) do
    %{
      generated_component?: true,
      component_id: component.id,
      language: component.language,
      runtime: component.runtime,
      entrypoint: component.entrypoint,
      source_artifacts: component.source_artifacts,
      test_artifacts: component.test_artifacts,
      interface: component.interface,
      capability_profile: component.capability_profile,
      sandbox_profile: component.sandbox_profile
    }
    |> Map.merge(Keyword.get(opts, :params, %{}))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp verification_status(verification) when is_map(verification) do
    get(verification, :status, nil)
    |> normalize_known_atom([:pass, :passed, :ok, :fail, :failed, :error])
    |> case do
      {:ok, status} -> status
      {:error, _error} -> nil
    end
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp validate_non_empty_string(value, _field) when is_binary(value) and value != "",
    do: :ok

  defp validate_non_empty_string(value, field) do
    {:error,
     Error.validation("generated component #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_language(language), do: normalize_known_atom(language, @languages, :language)

  defp normalize_promotion_status(status),
    do: normalize_known_atom(status, @promotion_statuses, :promotion_status)

  defp normalize_known_atom(value, allowed, field \\ nil)

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
     Error.validation("invalid generated component #{field}",
       source: __MODULE__,
       details: %{field: field, value: value, valid: allowed}
     )}
  end

  defp validate_runtime(runtime) when is_atom(runtime), do: :ok
  defp validate_runtime(runtime) when is_binary(runtime) and runtime != "", do: :ok

  defp validate_runtime(runtime) do
    {:error,
     Error.validation("generated component runtime must be an atom or non-empty string",
       source: __MODULE__,
       details: %{runtime: runtime}
     )}
  end

  defp validate_optional_profile(nil, _field), do: :ok
  defp validate_optional_profile(profile, _field) when is_atom(profile), do: :ok

  defp validate_optional_profile(profile, _field) when is_binary(profile) and profile != "",
    do: :ok

  defp validate_optional_profile(profile, field) do
    {:error,
     Error.validation("generated component #{field} must be an atom, string, or nil",
       source: __MODULE__,
       details: %{field: field, value: profile}
     )}
  end

  defp validate_artifacts(artifacts, field) when is_list(artifacts) do
    if Enum.all?(artifacts, &(is_binary(&1) or is_map(&1))) do
      :ok
    else
      {:error,
       Error.validation("generated component #{field} must contain only maps or strings",
         source: __MODULE__,
         details: %{field: field, value: artifacts}
       )}
    end
  end

  defp validate_artifacts(artifacts, field) do
    {:error,
     Error.validation("generated component #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: artifacts}
     )}
  end

  defp normalize_component_blueprint(nil), do: {:ok, nil}

  defp normalize_component_blueprint(%ComponentBlueprint{} = blueprint),
    do: ComponentBlueprint.validate(blueprint)

  defp normalize_component_blueprint(blueprint) when is_map(blueprint) or is_list(blueprint),
    do: ComponentBlueprint.from_input(blueprint)

  defp normalize_component_blueprint(blueprint) do
    {:error,
     Error.validation(
       "generated component component_blueprint must be a component blueprint or nil",
       source: __MODULE__,
       details: %{component_blueprint: blueprint}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("generated component #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field) do
    {:error,
     Error.validation("generated component #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
