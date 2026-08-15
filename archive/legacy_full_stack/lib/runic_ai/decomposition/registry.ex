defmodule RunicAI.Decomposition.Registry do
  @moduledoc """
  Validated registry of named decomposition roles.
  """

  alias RunicAI.Decomposition.Role
  alias RunicAI.Error

  @enforce_keys [:roles, :metadata]
  defstruct [:roles, :metadata]

  @type t :: %__MODULE__{
          roles: [Role.t()],
          metadata: map()
        }

  @spec new([Role.t() | keyword()], keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(roles \\ [], opts \\ []) when is_list(roles) and is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, normalized_roles} <- normalize_roles(roles),
         :ok <- validate_unique_names(normalized_roles),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{roles: normalized_roles, metadata: metadata}}
    end
  end

  @spec new!([Role.t() | keyword()], keyword()) :: t()
  def new!(roles \\ [], opts \\ []) do
    case new(roles, opts) do
      {:ok, registry} -> registry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | [Role.t() | keyword()] | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = registry), do: validate(registry)
  def from_input(roles) when is_list(roles), do: new(roles)

  def from_input(other) do
    {:error,
     Error.validation(
       "expected a Decomposition.Registry-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | [Role.t() | keyword()] | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, registry} -> registry
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = registry) do
    new(registry.roles, metadata: registry.metadata)
  end

  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{roles: roles}), do: Enum.map(roles, & &1.name)

  @spec fetch(t(), String.t()) :: {:ok, Role.t()} | {:error, Error.t()}
  def fetch(%__MODULE__{roles: roles} = registry, name) when is_binary(name) do
    case Enum.find(roles, &(&1.name == name)) do
      %Role{} = role ->
        {:ok, role}

      nil ->
        {:error,
         Error.validation("unknown decomposition role: #{inspect(name)}",
           source: __MODULE__,
           details: %{role_name: name, available_roles: names(registry)}
         )}
    end
  end

  @spec fetch!(t(), String.t()) :: Role.t()
  def fetch!(%__MODULE__{} = registry, name) do
    case fetch(registry, name) do
      {:ok, role} -> role
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp normalize_roles(roles) do
    roles
    |> Enum.reduce_while({:ok, []}, fn role, {:ok, acc} ->
      case normalize_role(role) do
        {:ok, normalized_role} -> {:cont, {:ok, [normalized_role | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, normalized_roles} -> {:ok, Enum.reverse(normalized_roles)}
      error -> error
    end
  end

  defp normalize_role(%Role{} = role), do: Role.validate(role)
  defp normalize_role(opts) when is_list(opts), do: Role.new(opts)

  defp normalize_role(other) do
    {:error,
     Error.validation("registry roles must be Role values or keyword opts",
       source: __MODULE__,
       details: %{role: other}
     )}
  end

  defp validate_unique_names(roles) do
    names = Enum.map(roles, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        {:error,
         Error.validation("decomposition registry role names must be unique",
           source: __MODULE__,
           details: %{duplicate_names: duplicates}
         )}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition registry metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
