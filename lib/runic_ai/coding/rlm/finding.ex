defmodule RunicAI.Coding.RLM.Finding do
  @moduledoc "Rankable diagnosis or review finding from an RLM coding workflow."

  alias RunicAI.Error

  @valid_severities [:info, :low, :medium, :high, :critical]

  @enforce_keys [:id, :summary, :severity, :evidence, :confidence, :metadata]
  defstruct [:id, :summary, :severity, evidence: [], confidence: 0.5, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          summary: String.t(),
          severity: atom(),
          evidence: [term()],
          confidence: number(),
          metadata: map()
        }

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(summary, opts \\ []) when is_binary(summary) and is_list(opts) do
    finding = %__MODULE__{
      id: Keyword.get(opts, :id) || "finding:#{System.unique_integer([:positive])}",
      summary: summary,
      severity: normalize_severity(Keyword.get(opts, :severity, :medium)),
      evidence: Keyword.get(opts, :evidence, []),
      confidence: Keyword.get(opts, :confidence, 0.5),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    validate(finding)
  end

  def new!(summary, opts \\ []) do
    case new(summary, opts) do
      {:ok, finding} -> finding
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = finding) do
    with :ok <- validate_id(finding.id),
         :ok <- validate_summary(finding.summary),
         :ok <- validate_severity(finding.severity),
         :ok <- validate_list(finding.evidence, :evidence),
         :ok <- validate_confidence(finding.confidence),
         :ok <- validate_map(finding.metadata, :metadata) do
      {:ok, finding}
    end
  end

  defp normalize_severity(value) when value in @valid_severities, do: value
  defp normalize_severity("info"), do: :info
  defp normalize_severity("low"), do: :low
  defp normalize_severity("medium"), do: :medium
  defp normalize_severity("high"), do: :high
  defp normalize_severity("critical"), do: :critical
  defp normalize_severity(value), do: value

  defp validate_id(id) when is_binary(id) and id != "", do: :ok

  defp validate_id(id),
    do:
      {:error,
       Error.validation("finding id must be a non-empty string",
         source: __MODULE__,
         details: %{id: id}
       )}

  defp validate_summary(summary) when is_binary(summary) and summary != "", do: :ok

  defp validate_summary(summary),
    do:
      {:error,
       Error.validation("finding summary must be a non-empty string",
         source: __MODULE__,
         details: %{summary: summary}
       )}

  defp validate_severity(severity) when severity in @valid_severities, do: :ok

  defp validate_severity(severity),
    do:
      {:error,
       Error.validation("invalid finding severity",
         source: __MODULE__,
         details: %{severity: severity}
       )}

  defp validate_confidence(value)
       when (is_integer(value) or is_float(value)) and value >= 0 and value <= 1,
       do: :ok

  defp validate_confidence(value),
    do:
      {:error,
       Error.validation("finding confidence must be between 0 and 1",
         source: __MODULE__,
         details: %{confidence: value}
       )}

  defp validate_list(value, _field) when is_list(value), do: :ok

  defp validate_list(value, field),
    do:
      {:error,
       Error.validation("finding #{field} must be a list",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}

  defp validate_map(value, _field) when is_map(value), do: :ok

  defp validate_map(value, field),
    do:
      {:error,
       Error.validation("finding #{field} must be a map",
         source: __MODULE__,
         details: %{field: field, value: value}
       )}
end
