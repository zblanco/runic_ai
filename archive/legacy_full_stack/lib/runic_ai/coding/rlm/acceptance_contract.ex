defmodule RunicAI.Coding.RLM.AcceptanceContract do
  @moduledoc """
  Objective-level acceptance contract for RLM coding workflows.

  Contracts collect deterministic checks, required artifacts, forbidden
  leftovers, and verification expectations. They are deliberately independent
  of any specific programming language or project generator.
  """

  alias RunicAI.Coding.RLM.AcceptanceCheck
  alias RunicAI.Coding.RLM.VerificationAssertions
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error

  @enforce_keys [
    :id,
    :objective,
    :checks,
    :required_artifacts,
    :forbidden_leftovers,
    :required_commands,
    :metadata
  ]
  defstruct [
    :id,
    :objective,
    checks: [],
    required_artifacts: [],
    forbidden_leftovers: [],
    required_commands: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          checks: [AcceptanceCheck.t()],
          required_artifacts: [term()],
          forbidden_leftovers: [term()],
          required_commands: [term()],
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    contract = %__MODULE__{
      id: Keyword.get(opts, :id) || "acceptance-contract:#{System.unique_integer([:positive])}",
      objective: objective,
      checks: Keyword.get(opts, :checks, []),
      required_artifacts: Keyword.get(opts, :required_artifacts, []),
      forbidden_leftovers: Keyword.get(opts, :forbidden_leftovers, []),
      required_commands: Keyword.get(opts, :required_commands, []),
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

  @spec draft(String.t(), keyword()) :: t()
  def draft(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    checks =
      []
      |> Kernel.++(file_checks(Keyword.get(opts, :required_files, [])))
      |> Kernel.++(source_contains_checks(Keyword.get(opts, :source_contains, [])))
      |> Kernel.++(source_not_contains_checks(Keyword.get(opts, :source_not_contains, [])))
      |> Kernel.++(command_checks(Keyword.get(opts, :required_commands, [])))
      |> Kernel.++(List.wrap(Keyword.get(opts, :checks, [])))

    new!(objective,
      checks: checks,
      required_artifacts: Keyword.get(opts, :required_artifacts, []),
      forbidden_leftovers: Keyword.get(opts, :forbidden_leftovers, []),
      required_commands: Keyword.get(opts, :required_commands, []),
      metadata: Map.merge(%{draft?: true}, normalize_map(Keyword.get(opts, :metadata, %{})))
    )
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = contract), do: validate(contract)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(get(input, :objective),
      id: get(input, :id),
      checks: get(input, :checks, []),
      required_artifacts: get(input, :required_artifacts, []),
      forbidden_leftovers: get(input, :forbidden_leftovers, []),
      required_commands: get(input, :required_commands, []),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("acceptance contract must be a map or AcceptanceContract",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = contract) do
    with :ok <- non_empty_string(contract.id, :id),
         :ok <- non_empty_string(contract.objective, :objective),
         {:ok, checks} <- normalize_checks(contract.checks),
         :ok <- list(contract.required_artifacts, :required_artifacts),
         :ok <- list(contract.forbidden_leftovers, :forbidden_leftovers),
         :ok <- list(contract.required_commands, :required_commands),
         :ok <- map(contract.metadata, :metadata) do
      {:ok, %{contract | checks: checks}}
    end
  end

  @spec evaluate(t() | map() | keyword(), Workspace.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def evaluate(contract_input, %Workspace{} = workspace, context \\ %{}) when is_map(context) do
    with {:ok, contract} <- from_input(contract_input) do
      results =
        Enum.map(contract.checks, &VerificationAssertions.evaluate(workspace, &1, context))

      {:ok,
       %{
         contract_id: contract.id,
         objective: contract.objective,
         status: status(results),
         results: results,
         passed: Enum.count(results, &(&1.status == :pass)),
         failed: Enum.count(results, &(&1.status == :fail)),
         skipped: Enum.count(results, &(&1.status == :skipped)),
         blocking_failures: Enum.filter(results, &AcceptanceCheck.blocking_failure?/1)
       }}
    end
  end

  @spec status([AcceptanceCheck.result()]) :: :satisfied | :incomplete
  def status(results) when is_list(results) do
    if Enum.any?(results, &AcceptanceCheck.blocking_failure?/1) do
      :incomplete
    else
      :satisfied
    end
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
     Error.validation("acceptance contract checks must be a list",
       source: __MODULE__,
       details: %{checks: checks}
     )}
  end

  defp file_checks(paths) do
    paths
    |> List.wrap()
    |> Enum.map(fn path ->
      AcceptanceCheck.new!(:file_exists, id: "file-exists:#{path}", params: %{path: path})
    end)
  end

  defp source_contains_checks(entries) do
    entries
    |> List.wrap()
    |> Enum.map(fn
      %{path: path, text: text} ->
        AcceptanceCheck.new!(:source_contains,
          id: "source-contains:#{path}:#{:erlang.phash2(text)}",
          params: %{path: path, text: text}
        )

      %{"path" => path, "text" => text} ->
        AcceptanceCheck.new!(:source_contains,
          id: "source-contains:#{path}:#{:erlang.phash2(text)}",
          params: %{path: path, text: text}
        )
    end)
  end

  defp source_not_contains_checks(entries) do
    entries
    |> List.wrap()
    |> Enum.map(fn
      %{path: path, text: text} ->
        AcceptanceCheck.new!(:source_not_contains,
          id: "source-not-contains:#{path}:#{:erlang.phash2(text)}",
          params: %{path: path, text: text}
        )

      %{"path" => path, "text" => text} ->
        AcceptanceCheck.new!(:source_not_contains,
          id: "source-not-contains:#{path}:#{:erlang.phash2(text)}",
          params: %{path: path, text: text}
        )
    end)
  end

  defp command_checks(commands) do
    commands
    |> List.wrap()
    |> Enum.map(fn command ->
      AcceptanceCheck.new!(:command_passes,
        id: "command-passes:#{:erlang.phash2(command)}",
        params: %{command: command}
      )
    end)
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("acceptance contract #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field) do
    {:error,
     Error.validation("acceptance contract #{field} must be a list",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp map(value, _field) when is_map(value), do: :ok

  defp map(value, field) do
    {:error,
     Error.validation("acceptance contract #{field} must be a map",
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
