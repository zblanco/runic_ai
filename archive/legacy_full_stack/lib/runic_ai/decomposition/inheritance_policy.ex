defmodule RunicAI.Decomposition.InheritancePolicy do
  @moduledoc """
  Declarative policy describing what parent context and capability slices a
  child assignment inherits.
  """

  alias RunicAI.Error

  @valid_context_modes [:handoff, :bundle, :refs, :none]
  @valid_tool_modes [:inherit, :subset, :override, :none]
  @valid_budget_modes [:slice, :copy, :fresh, :none]

  @enforce_keys [
    :context_mode,
    :max_context_refs,
    :tool_mode,
    :allowed_tools,
    :budget_mode,
    :budget_overrides,
    :metadata
  ]
  defstruct [
    :context_mode,
    :max_context_refs,
    :tool_mode,
    :allowed_tools,
    :budget_mode,
    :budget_overrides,
    :memory_scope,
    :metadata
  ]

  @type t :: %__MODULE__{
          context_mode: :handoff | :bundle | :refs | :none,
          max_context_refs: pos_integer(),
          tool_mode: :inherit | :subset | :override | :none,
          allowed_tools: [String.t()],
          budget_mode: :slice | :copy | :fresh | :none,
          budget_overrides: map(),
          memory_scope: term(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    context_mode = Keyword.get(opts, :context_mode, :handoff)
    max_context_refs = Keyword.get(opts, :max_context_refs, 12)
    tool_mode = Keyword.get(opts, :tool_mode, :none)
    allowed_tools = Keyword.get(opts, :allowed_tools, [])
    budget_mode = Keyword.get(opts, :budget_mode, :none)
    budget_overrides = Keyword.get(opts, :budget_overrides, %{})
    memory_scope = Keyword.get(opts, :memory_scope)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_context_mode(context_mode),
         :ok <- validate_positive(:max_context_refs, max_context_refs),
         :ok <- validate_tool_mode(tool_mode),
         :ok <- validate_allowed_tools(allowed_tools),
         :ok <- validate_budget_mode(budget_mode),
         :ok <- validate_budget_overrides(budget_overrides),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         context_mode: context_mode,
         max_context_refs: max_context_refs,
         tool_mode: tool_mode,
         allowed_tools: allowed_tools,
         budget_mode: budget_mode,
         budget_overrides: budget_overrides,
         memory_scope: memory_scope,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(
      context_mode: policy.context_mode,
      max_context_refs: policy.max_context_refs,
      tool_mode: policy.tool_mode,
      allowed_tools: policy.allowed_tools,
      budget_mode: policy.budget_mode,
      budget_overrides: policy.budget_overrides,
      memory_scope: policy.memory_scope,
      metadata: policy.metadata
    )
  end

  @spec from_input(t() | keyword() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(other) do
    {:error,
     Error.validation(
       "expected an InheritancePolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | keyword() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp validate_context_mode(mode) when mode in @valid_context_modes, do: :ok

  defp validate_context_mode(mode) do
    {:error,
     Error.validation("invalid inheritance context_mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{context_mode: mode, valid_context_modes: @valid_context_modes}
     )}
  end

  defp validate_tool_mode(mode) when mode in @valid_tool_modes, do: :ok

  defp validate_tool_mode(mode) do
    {:error,
     Error.validation("invalid inheritance tool_mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{tool_mode: mode, valid_tool_modes: @valid_tool_modes}
     )}
  end

  defp validate_budget_mode(mode) when mode in @valid_budget_modes, do: :ok

  defp validate_budget_mode(mode) do
    {:error,
     Error.validation("invalid inheritance budget_mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{budget_mode: mode, valid_budget_modes: @valid_budget_modes}
     )}
  end

  defp validate_positive(_field, value) when is_integer(value) and value > 0, do: :ok

  defp validate_positive(field, value) do
    {:error,
     Error.validation("inheritance policy #{field} must be a positive integer",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_allowed_tools(allowed_tools) when is_list(allowed_tools) do
    if Enum.all?(allowed_tools, &is_binary/1) do
      :ok
    else
      {:error,
       Error.validation("inheritance allowed_tools must contain only strings",
         source: __MODULE__,
         details: %{allowed_tools: allowed_tools}
       )}
    end
  end

  defp validate_allowed_tools(allowed_tools) do
    {:error,
     Error.validation("inheritance allowed_tools must be a list of tool names",
       source: __MODULE__,
       details: %{allowed_tools: allowed_tools}
     )}
  end

  defp validate_budget_overrides(budget_overrides) when is_map(budget_overrides), do: :ok

  defp validate_budget_overrides(budget_overrides) do
    {:error,
     Error.validation("inheritance budget_overrides must be a map",
       source: __MODULE__,
       details: %{budget_overrides: budget_overrides}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("inheritance policy metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end
end
