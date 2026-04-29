defmodule RunicAI.Coding.RLM.ChildResult do
  @moduledoc """
  Normalized result returned by a child coding workflow.

  Parent RLM workflows should use this status, not free-form child text, when
  deciding whether an objective is complete or needs repair.
  """

  alias RunicAI.Coding.RLM.ChildContract
  alias RunicAI.Error

  @statuses [:completed, :partial, :blocked, :failed, :needs_review]

  @enforce_keys [
    :id,
    :status,
    :role,
    :changed_files,
    :file_hashes,
    :commands,
    :command_statuses,
    :checks_attempted,
    :unresolved_risks,
    :confidence,
    :summary,
    :metadata
  ]
  defstruct [
    :id,
    :status,
    :role,
    changed_files: [],
    file_hashes: %{},
    commands: [],
    command_statuses: [],
    checks_attempted: [],
    unresolved_risks: [],
    confidence: nil,
    summary: "",
    metadata: %{}
  ]

  @type status :: :completed | :partial | :blocked | :failed | :needs_review

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          role: atom() | nil,
          changed_files: [Path.t()],
          file_hashes: map(),
          commands: [term()],
          command_statuses: [term()],
          checks_attempted: [term()],
          unresolved_risks: [String.t()],
          confidence: number() | nil,
          summary: String.t(),
          metadata: map()
        }

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec new(status() | String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(status, opts \\ []) when is_list(opts) do
    result = %__MODULE__{
      id: Keyword.get(opts, :id) || "child-result:#{System.unique_integer([:positive])}",
      status: normalize_status(status),
      role: Keyword.get(opts, :role),
      changed_files: Keyword.get(opts, :changed_files, []),
      file_hashes: normalize_map(Keyword.get(opts, :file_hashes, %{})),
      commands: Keyword.get(opts, :commands, []),
      command_statuses: Keyword.get(opts, :command_statuses, []),
      checks_attempted: Keyword.get(opts, :checks_attempted, []),
      unresolved_risks: Keyword.get(opts, :unresolved_risks, []),
      confidence: Keyword.get(opts, :confidence),
      summary: Keyword.get(opts, :summary, ""),
      metadata: normalize_map(Keyword.get(opts, :metadata, %{}))
    }

    validate(result)
  end

  @spec new!(status() | String.t(), keyword()) :: t()
  def new!(status, opts \\ []) do
    case new(status, opts) do
      {:ok, result} -> result
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_input(%__MODULE__{} = result), do: validate(result)

  def from_input(input) when is_list(input) do
    input |> Map.new() |> from_input()
  end

  def from_input(input) when is_map(input) do
    new(get(input, :status, :partial),
      id: get(input, :id),
      role: get(input, :role),
      changed_files: List.wrap(get(input, :changed_files, [])),
      file_hashes: get(input, :file_hashes, %{}),
      commands: List.wrap(get(input, :commands, [])),
      command_statuses: List.wrap(get(input, :command_statuses, [])),
      checks_attempted: List.wrap(get(input, :checks_attempted, [])),
      unresolved_risks: List.wrap(get(input, :unresolved_risks, get(input, :risks, []))),
      confidence: get(input, :confidence),
      summary: get(input, :summary, get(input, :reply, "")),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(input) do
    {:error,
     Error.validation("child result must be a map or ChildResult",
       source: __MODULE__,
       details: %{input: input}
     )}
  end

  @spec from_agent_summary(map(), ChildContract.t() | nil, keyword()) :: t()
  def from_agent_summary(summary, contract \\ nil, opts \\ []) when is_map(summary) do
    {:ok, contract} = ChildContract.from_input(contract)

    status = derive_status(summary, contract)

    new!(status,
      id: Keyword.get(opts, :id) || (contract && contract.id) || "child-result:standard-agent",
      role: contract && contract.role,
      changed_files: List.wrap(field(summary, :changed_files)),
      commands: observed_commands(summary),
      command_statuses: observed_command_statuses(summary),
      checks_attempted: contract_checks(contract),
      unresolved_risks: List.wrap(field(summary, :risks)),
      summary: field(summary, :reply) || "",
      metadata: %{
        source: :standard_coding_agent,
        raw_status: field(summary, :status),
        tools_used: List.wrap(field(summary, :tools_used))
      }
    )
  end

  @spec completed?(t() | map()) :: boolean()
  def completed?(%__MODULE__{status: :completed}), do: true

  def completed?(input) do
    case from_input(input) do
      {:ok, %__MODULE__{status: :completed}} -> true
      _other -> false
    end
  end

  @spec episode_status(t()) :: :satisfied | :partial | :blocked | :failed
  def episode_status(%__MODULE__{status: :completed}), do: :satisfied
  def episode_status(%__MODULE__{status: :partial}), do: :partial
  def episode_status(%__MODULE__{status: :blocked}), do: :blocked
  def episode_status(%__MODULE__{status: :needs_review}), do: :blocked
  def episode_status(%__MODULE__{status: :failed}), do: :failed

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = result) do
    with :ok <- non_empty_string(result.id, :id),
         :ok <- valid_status(result.status),
         :ok <- list(result.changed_files, :changed_files),
         :ok <- map(result.file_hashes, :file_hashes),
         :ok <- list(result.commands, :commands),
         :ok <- list(result.command_statuses, :command_statuses),
         :ok <- list(result.checks_attempted, :checks_attempted),
         :ok <- string_list(result.unresolved_risks, :unresolved_risks),
         :ok <- optional_number(result.confidence, :confidence),
         :ok <- string(result.summary, :summary),
         :ok <- map(result.metadata, :metadata) do
      {:ok, result}
    end
  end

  defp derive_status(summary, nil) do
    cond do
      blocked?(summary) -> :blocked
      failed?(summary) -> :failed
      incomplete_text?(field(summary, :reply)) -> :partial
      terminal_status?(field(summary, :status)) -> :completed
      has_reply?(summary) -> :completed
      true -> :partial
    end
  end

  defp derive_status(summary, %ChildContract{} = contract) do
    base = derive_status(summary, nil)

    cond do
      base != :completed ->
        base

      missing_required_artifacts?(summary, contract) ->
        :partial

      missing_verification?(summary, contract) ->
        :partial

      failed_verification?(summary) ->
        :partial

      true ->
        :completed
    end
  end

  defp terminal_status?(status),
    do: status in [:satisfied, :completed, :complete, "satisfied", "completed", "complete"]

  defp blocked?(summary),
    do: field(summary, :status) in [:waiting, :review, :blocked, "waiting", "review", "blocked"]

  defp failed?(summary), do: field(summary, :status) in [:failed, :error, "failed", "error"]

  defp incomplete_text?(text) when is_binary(text) do
    text = String.downcase(text)

    Enum.any?(
      [
        "could not complete",
        "couldn't complete",
        "couldn’t complete",
        "unable to complete",
        "wasn't able to complete",
        "wasn’t able to complete",
        "not able to complete",
        "incomplete",
        "not completed",
        "failed to"
      ],
      &String.contains?(text, &1)
    )
  end

  defp incomplete_text?(_text), do: false

  defp has_reply?(summary) do
    case field(summary, :reply) do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end

  defp missing_required_artifacts?(_summary, %ChildContract{required_artifacts: []}), do: false

  defp missing_required_artifacts?(summary, %ChildContract{} = contract) do
    changed_files = MapSet.new(List.wrap(field(summary, :changed_files)))

    contract.required_artifacts
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&(not MapSet.member?(changed_files, &1)))
  end

  defp missing_verification?(_summary, %ChildContract{verification_commands: []}), do: false

  defp missing_verification?(summary, %ChildContract{}) do
    List.wrap(field(summary, :verifications)) == []
  end

  defp failed_verification?(summary) do
    summary
    |> field(:verifications)
    |> List.wrap()
    |> Enum.any?(fn verification ->
      field(verification, :status) not in [:pass, "pass"]
    end)
  end

  defp observed_commands(summary) do
    summary
    |> field(:verifications)
    |> List.wrap()
    |> Enum.map(&(field(&1, :command) || field(&1, :tool)))
    |> Enum.reject(&is_nil/1)
  end

  defp observed_command_statuses(summary) do
    summary
    |> field(:verifications)
    |> List.wrap()
    |> Enum.map(fn verification ->
      %{
        command: field(verification, :command) || field(verification, :tool),
        status: field(verification, :status)
      }
    end)
  end

  defp contract_checks(nil), do: []
  defp contract_checks(%ChildContract{} = contract), do: contract.acceptance_checks

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status("completed"), do: :completed
  defp normalize_status("partial"), do: :partial
  defp normalize_status("blocked"), do: :blocked
  defp normalize_status("failed"), do: :failed
  defp normalize_status("needs_review"), do: :needs_review
  defp normalize_status(status), do: status

  defp valid_status(status) when status in @statuses, do: :ok

  defp valid_status(status) do
    {:error,
     Error.validation("invalid child result status",
       source: __MODULE__,
       details: %{status: status, valid_statuses: @statuses}
     )}
  end

  defp non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp non_empty_string(value, field) do
    {:error,
     Error.validation("child result #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp string(value, _field) when is_binary(value), do: :ok

  defp string(value, field) do
    {:error,
     Error.validation("child result #{field} must be a string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp list(value, _field) when is_list(value), do: :ok

  defp list(value, field) do
    {:error,
     Error.validation("child result #{field} must be a list",
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
     Error.validation("child result #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp optional_number(nil, _field), do: :ok
  defp optional_number(value, _field) when is_number(value), do: :ok

  defp optional_number(value, field) do
    {:error,
     Error.validation("child result #{field} must be a number or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(value) when is_list(value), do: Map.new(value)
  defp normalize_map(_value), do: %{}

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil
end
