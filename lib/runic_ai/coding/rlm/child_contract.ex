defmodule RunicAI.Coding.RLM.ChildContract do
  @moduledoc """
  Contract passed from an RLM coordinator to a child coding workflow.

  The contract gives child agents a bounded role, scope, tool budget, required
  artifacts, and stop criteria. It is generic coordination data, not a
  framework-specific workflow shortcut.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Error

  @roles [:planner, :implementer, :test_writer, :verifier, :reviewer, :repairer, :investigator]

  @enforce_keys [
    :id,
    :role,
    :scope,
    :allowed_tools,
    :required_artifacts,
    :verification_commands,
    :acceptance_checks,
    :stop_criteria,
    :budgets,
    :metadata
  ]
  defstruct [
    :id,
    :role,
    scope: [],
    allowed_tools: [],
    required_artifacts: [],
    verification_commands: [],
    acceptance_checks: [],
    stop_criteria: [],
    budgets: %{},
    metadata: %{}
  ]

  @type role ::
          :planner
          | :implementer
          | :test_writer
          | :verifier
          | :reviewer
          | :repairer
          | :investigator

  @type t :: %__MODULE__{
          id: String.t(),
          role: role(),
          scope: [term()],
          allowed_tools: [String.t()],
          required_artifacts: [term()],
          verification_commands: [term()],
          acceptance_checks: [AcceptanceCheck.t()],
          stop_criteria: [term()],
          budgets: map(),
          metadata: map()
        }

  @spec roles() :: [role()]
  def roles, do: @roles

  @spec new(role() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(role, opts \\ []) when is_list(opts) do
    contract = %__MODULE__{
      id: Keyword.get(opts, :id) || "child-contract:#{System.unique_integer([:positive])}",
      role: normalize_role(role),
      scope: Keyword.get(opts, :scope, []),
      allowed_tools: Keyword.get(opts, :allowed_tools, []),
      required_artifacts: Keyword.get(opts, :required_artifacts, []),
      verification_commands: Keyword.get(opts, :verification_commands, []),
      acceptance_checks: Keyword.get(opts, :acceptance_checks, []),
      stop_criteria: Keyword.get(opts, :stop_criteria, []),
      budgets: normalize_map(Keyword.get(opts, :budgets, %{})),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(contract)
  end

  @spec new!(role() | String.t(), keyword()) :: t()
  def new!(role, opts \\ []) do
    case new(role, opts) do
      {:ok, contract} -> contract
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword() | nil) :: {:ok, t() | nil} | {:error, Error.t()}
  def from_input(nil), do: {:ok, nil}
  def from_input(%__MODULE__{} = contract), do: validate(contract)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(get(input, :role, :implementer),
      id: get(input, :id),
      scope: List.wrap(get(input, :scope, [])),
      allowed_tools: List.wrap(get(input, :allowed_tools, [])),
      required_artifacts: List.wrap(get(input, :required_artifacts, [])),
      verification_commands: List.wrap(get(input, :verification_commands, [])),
      acceptance_checks: List.wrap(get(input, :acceptance_checks, [])),
      stop_criteria: List.wrap(get(input, :stop_criteria, [])),
      budgets: get(input, :budgets, %{}),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("child contract must be a map, ChildContract, or nil",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = contract) do
    with :ok <- non_empty_string(contract.id, :id),
         :ok <- valid_role(contract.role),
         :ok <- list(contract.scope, :scope),
         :ok <- string_list(contract.allowed_tools, :allowed_tools),
         :ok <- list(contract.required_artifacts, :required_artifacts),
         :ok <- list(contract.verification_commands, :verification_commands),
         {:ok, acceptance_checks} <- normalize_checks(contract.acceptance_checks),
         :ok <- list(contract.stop_criteria, :stop_criteria),
         :ok <- map(contract.budgets, :budgets),
         :ok <- map(contract.metadata, :metadata) do
      {:ok, %{contract | acceptance_checks: acceptance_checks}}
    end
  end

  defp normalize_role(role) when role in @roles, do: role
  defp normalize_role("planner"), do: :planner
  defp normalize_role("implementer"), do: :implementer
  defp normalize_role("test_writer"), do: :test_writer
  defp normalize_role("verifier"), do: :verifier
  defp normalize_role("reviewer"), do: :reviewer
  defp normalize_role("repairer"), do: :repairer
  defp normalize_role("investigator"), do: :investigator
  defp normalize_role(role), do: role

  defp valid_role(role) when role in @roles, do: :ok

  defp valid_role(role) do
    {:error,
     Error.validation("invalid child contract role",
       source: __MODULE__,
       details: %{role: role, valid_roles: @roles}
     )}
  end

  defp normalize_checks(checks) when is_list(checks) do
    checks
    |> Enum.reduce_while({:ok, []}, fn check, {:ok, acc} ->
      case AcceptanceCheck.from_input(check) do
        {:ok, check} -> {:cont, {:ok, [check | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, Enum.reverse(checks)}
      error -> error
    end
  end

  defp normalize_checks(checks) do
    {:error,
     Error.validation("child contract acceptance_checks must be a list",
       source: __MODULE__,
       details: %{acceptance_checks: checks}
     )}
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("child contract #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field) do
    {:error,
     Error.validation("child contract #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string_list(value, field) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: list(value, field)
  end

  defp string_list(value, field), do: list(value, field)

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("child contract #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
