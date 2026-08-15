defmodule RunicAI.RLM.TaskKind do
  @moduledoc """
  Small vocabulary of task shapes the default RLM planner understands.
  """

  @valid [
    :summarization,
    :qa,
    :classification,
    :extraction,
    :analysis,
    :report_generation,
    :codebase_qa,
    :custom
  ]

  @type t ::
          :summarization
          | :qa
          | :classification
          | :extraction
          | :analysis
          | :report_generation
          | :codebase_qa
          | :custom

  @spec valid?(term()) :: boolean()
  def valid?(kind), do: kind in @valid

  @spec valid_kinds() :: [t()]
  def valid_kinds, do: @valid
end
