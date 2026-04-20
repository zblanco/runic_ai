defmodule RunicAI.Decomposition.Role do
  @moduledoc """
  Reusable special-purpose delegate profile for one child workflow kind.
  """

  alias RunicAI.Decomposition.Assignment
  alias RunicAI.Decomposition.Callable
  alias RunicAI.Error

  @valid_kinds [:agent, :workflow, :llm]

  @enforce_keys [:name, :kind, :description, :builder, :defaults, :metadata]
  defstruct [:name, :kind, :description, :builder, :defaults, :accepts, :metadata]

  @type accept_tag :: atom() | String.t()

  @type t :: %__MODULE__{
          name: String.t(),
          kind: :agent | :workflow | :llm,
          description: String.t(),
          builder: Callable.t(),
          defaults: map(),
          accepts: [accept_tag()],
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    name = Keyword.get(opts, :name)
    kind = Keyword.get(opts, :kind, :workflow)
    description = Keyword.get(opts, :description)
    builder = Keyword.get(opts, :builder)
    defaults = Keyword.get(opts, :defaults, %{})
    accepts = Keyword.get(opts, :accepts, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_name(name),
         :ok <- validate_kind(kind),
         :ok <- validate_description(description),
         :ok <- Callable.validate(builder, "decomposition role builder", __MODULE__),
         :ok <- validate_defaults(defaults),
         :ok <- validate_accepts(accepts),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         name: name,
         kind: kind,
         description: description,
         builder: builder,
         defaults: defaults,
         accepts: accepts,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, role} -> role
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = role) do
    new(
      name: role.name,
      kind: role.kind,
      description: role.description,
      builder: role.builder,
      defaults: role.defaults,
      accepts: role.accepts,
      metadata: role.metadata
    )
  end

  @spec from_input(t() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = role), do: validate(role)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation("expected a Decomposition.Role-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword()) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, role} -> role
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec accepts?(t(), accept_tag() | nil) :: boolean()
  def accepts?(%__MODULE__{accepts: []}, _tag), do: true
  def accepts?(%__MODULE__{}, nil), do: true

  def accepts?(%__MODULE__{accepts: accepts}, tag) when is_atom(tag) or is_binary(tag) do
    tag in accepts
  end

  @spec invoke(t(), Assignment.t()) :: term()
  def invoke(%__MODULE__{} = role, %Assignment{} = assignment) do
    Callable.invoke(role.builder, assignment)
  end

  defp validate_name(name) when is_binary(name) and name != "", do: :ok

  defp validate_name(name) do
    {:error,
     Error.validation("decomposition role name must be a non-empty string",
       source: __MODULE__,
       details: %{name: name}
     )}
  end

  defp validate_kind(kind) when kind in @valid_kinds, do: :ok

  defp validate_kind(kind) do
    {:error,
     Error.validation("invalid decomposition role kind: #{inspect(kind)}",
       source: __MODULE__,
       details: %{kind: kind, valid_kinds: @valid_kinds}
     )}
  end

  defp validate_description(description) when is_binary(description) and description != "",
    do: :ok

  defp validate_description(description) do
    {:error,
     Error.validation("decomposition role description must be a non-empty string",
       source: __MODULE__,
       details: %{description: description}
     )}
  end

  defp validate_defaults(defaults) when is_map(defaults), do: :ok

  defp validate_defaults(defaults) do
    {:error,
     Error.validation("decomposition role defaults must be a map",
       source: __MODULE__,
       details: %{defaults: defaults}
     )}
  end

  defp validate_accepts(accepts) when is_list(accepts) do
    if Enum.all?(accepts, &(is_atom(&1) or is_binary(&1))) do
      :ok
    else
      {:error,
       Error.validation("decomposition role accepts must contain only atoms or strings",
         source: __MODULE__,
         details: %{accepts: accepts}
       )}
    end
  end

  defp validate_accepts(accepts) do
    {:error,
     Error.validation("decomposition role accepts must be a list",
       source: __MODULE__,
       details: %{accepts: accepts}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("decomposition role metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
