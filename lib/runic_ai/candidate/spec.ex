defmodule RunicAI.Candidate.Spec do
  @moduledoc """
  Explicit recipe candidate that can be assigned to a runtime session.
  """

  alias RunicAI.Error

  @enforce_keys [:id, :recipe, :recipe_opts, :metadata]
  defstruct [:id, :recipe, recipe_opts: [], metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          recipe: module(),
          recipe_opts: keyword(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    id = Keyword.get(opts, :id)
    recipe = Keyword.get(opts, :recipe)
    recipe_opts = Keyword.get(opts, :recipe_opts, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_id(id),
         :ok <- validate_recipe(recipe),
         :ok <- validate_keyword(recipe_opts, :recipe_opts),
         :ok <- validate_map(metadata, :metadata) do
      {:ok, %__MODULE__{id: id, recipe: recipe, recipe_opts: recipe_opts, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, spec} -> spec
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = spec), do: validate(spec)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Candidate.Spec-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = spec) do
    new(id: spec.id, recipe: spec.recipe, recipe_opts: spec.recipe_opts, metadata: spec.metadata)
  end

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id) do
    {:error,
     Error.validation("candidate id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  defp validate_recipe(recipe) when is_atom(recipe) and not is_nil(recipe), do: :ok

  defp validate_recipe(recipe) do
    {:error,
     Error.validation("candidate recipe must be a module",
       source: __MODULE__,
       details: %{recipe: recipe}
     )}
  end

  defp validate_keyword(value, _field) when is_list(value), do: :ok

  defp validate_keyword(value, field) do
    {:error,
     Error.validation("candidate #{field} must be a keyword list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field) do
    {:error,
     Error.validation("candidate #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end
end
