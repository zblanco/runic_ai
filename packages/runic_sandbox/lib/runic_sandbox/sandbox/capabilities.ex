defmodule RunicSandbox.Capabilities do
  @moduledoc """
  Provider-neutral capability flags for a sandbox backend or session.
  """

  alias RunicSandbox.Error

  @enforce_keys [
    :exec?,
    :files?,
    :inline_files?,
    :artifacts?,
    :session_files?,
    :checkpoints?,
    :services?,
    :proxy?,
    :leases?,
    :streaming?,
    :network_policy?,
    :persistent_identity?,
    :metadata
  ]
  defstruct exec?: false,
            files?: false,
            inline_files?: false,
            artifacts?: false,
            session_files?: false,
            checkpoints?: false,
            services?: false,
            proxy?: false,
            leases?: false,
            streaming?: false,
            network_policy?: false,
            persistent_identity?: false,
            metadata: %{}

  @type t :: %__MODULE__{
          exec?: boolean(),
          files?: boolean(),
          inline_files?: boolean(),
          artifacts?: boolean(),
          session_files?: boolean(),
          checkpoints?: boolean(),
          services?: boolean(),
          proxy?: boolean(),
          leases?: boolean(),
          streaming?: boolean(),
          network_policy?: boolean(),
          persistent_identity?: boolean(),
          metadata: map()
        }

  @spec new(keyword() | map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = capabilities), do: validate(capabilities)
  def new(input) when is_list(input), do: input |> Map.new() |> new()

  def new(input) when is_map(input) do
    capabilities = %__MODULE__{
      exec?: get(input, :exec?, false),
      files?: get(input, :files?, false),
      inline_files?: get(input, :inline_files?, false),
      artifacts?: get(input, :artifacts?, false),
      session_files?: get(input, :session_files?, get(input, :files?, false)),
      checkpoints?: get(input, :checkpoints?, false),
      services?: get(input, :services?, false),
      proxy?: get(input, :proxy?, false),
      leases?: get(input, :leases?, false),
      streaming?: get(input, :streaming?, false),
      network_policy?: get(input, :network_policy?, false),
      persistent_identity?: get(input, :persistent_identity?, false),
      metadata: get(input, :metadata, %{})
    }

    validate(capabilities)
  end

  @spec new!(keyword() | map() | t()) :: t()
  def new!(input \\ []) do
    case new(input) do
      {:ok, capabilities} -> capabilities
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec one_shot_exec(keyword() | map()) :: t()
  def one_shot_exec(input \\ []) do
    input = Map.new(input)

    %{
      exec?: true,
      files?: false,
      inline_files?: true,
      artifacts?: false,
      session_files?: false,
      checkpoints?: false,
      services?: false,
      proxy?: false,
      leases?: false,
      streaming?: get(input, :streaming?, false),
      network_policy?: get(input, :network_policy?, false),
      persistent_identity?: get(input, :persistent_identity?, false),
      metadata: get(input, :metadata, %{})
    }
    |> new!()
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = capabilities) do
    with :ok <- validate_boolean(capabilities.exec?, :exec?),
         :ok <- validate_boolean(capabilities.files?, :files?),
         :ok <- validate_boolean(capabilities.inline_files?, :inline_files?),
         :ok <- validate_boolean(capabilities.artifacts?, :artifacts?),
         :ok <- validate_boolean(capabilities.session_files?, :session_files?),
         :ok <- validate_boolean(capabilities.checkpoints?, :checkpoints?),
         :ok <- validate_boolean(capabilities.services?, :services?),
         :ok <- validate_boolean(capabilities.proxy?, :proxy?),
         :ok <- validate_boolean(capabilities.leases?, :leases?),
         :ok <- validate_boolean(capabilities.streaming?, :streaming?),
         :ok <- validate_boolean(capabilities.network_policy?, :network_policy?),
         :ok <- validate_boolean(capabilities.persistent_identity?, :persistent_identity?),
         :ok <- validate_map(capabilities.metadata, :metadata) do
      {:ok, capabilities}
    end
  end

  @spec to_map(t() | map()) :: map()
  def to_map(%__MODULE__{} = capabilities), do: Map.from_struct(capabilities)
  def to_map(capabilities) when is_map(capabilities), do: capabilities

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("sandbox capability #{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("sandbox capability #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
