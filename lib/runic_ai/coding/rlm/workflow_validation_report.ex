defmodule RunicAI.Coding.RLM.WorkflowValidationReport do
  @moduledoc """
  Validation report for an RLM coding workflow proposal.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.CostEstimate

  @enforce_keys [:status, :errors, :warnings, :accepted_nodes, :rejected_nodes, :metadata]
  defstruct [
    :status,
    errors: [],
    warnings: [],
    accepted_nodes: [],
    rejected_nodes: [],
    estimated_cost: nil,
    metadata: %{}
  ]

  @type status :: :accepted | :rejected

  @type t :: %__MODULE__{
          status: status(),
          errors: [Error.t() | map()],
          warnings: [String.t() | map()],
          accepted_nodes: [String.t()],
          rejected_nodes: [String.t()],
          estimated_cost: CostEstimate.t() | nil,
          metadata: map()
        }

  @spec accepted?(t()) :: boolean()
  def accepted?(%__MODULE__{status: :accepted}), do: true
  def accepted?(%__MODULE__{}), do: false

  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    errors = Keyword.get(opts, :errors, [])

    %__MODULE__{
      status: Keyword.get(opts, :status, if(errors == [], do: :accepted, else: :rejected)),
      errors: errors,
      warnings: Keyword.get(opts, :warnings, []),
      accepted_nodes: Keyword.get(opts, :accepted_nodes, []),
      rejected_nodes: Keyword.get(opts, :rejected_nodes, []),
      estimated_cost: Keyword.get(opts, :estimated_cost),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec accept(keyword()) :: t()
  def accept(opts \\ []), do: new(Keyword.put(opts, :status, :accepted))

  @spec reject([Error.t() | map()], keyword()) :: t()
  def reject(errors, opts \\ []) when is_list(errors) do
    opts
    |> Keyword.put(:status, :rejected)
    |> Keyword.put(:errors, errors)
    |> new()
  end
end
