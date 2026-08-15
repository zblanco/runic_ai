defmodule RunicAI.Coding.RLM.CoordinationPatterns do
  @moduledoc """
  Registry of generic coordination patterns for RLM coding workflows.

  These patterns describe reusable control structure only. They do not encode
  Mix, Elixir, OTP, or domain-specific project workflows.
  """

  alias RunicAI.Coding.RLM.CoordinationPatterns.ParallelDecomposition
  alias RunicAI.Coding.RLM.CoordinationPatterns.ReviewScorecard
  alias RunicAI.Coding.RLM.CoordinationPatterns.StagedDelivery
  alias RunicAI.Coding.RLM.CoordinationPatterns.VerifyRepairLoop

  @spec all() :: [map()]
  def all do
    [
      StagedDelivery.pattern(),
      ParallelDecomposition.pattern(),
      VerifyRepairLoop.pattern(),
      ReviewScorecard.pattern()
    ]
  end

  @spec names() :: [atom()]
  def names, do: Enum.map(all(), & &1.name)

  @spec fetch(atom() | String.t()) :: {:ok, map()} | :error
  def fetch("staged_delivery"), do: fetch(:staged_delivery)
  def fetch("parallel_decomposition"), do: fetch(:parallel_decomposition)
  def fetch("verify_repair_loop"), do: fetch(:verify_repair_loop)
  def fetch("review_scorecard"), do: fetch(:review_scorecard)
  def fetch(name) when is_binary(name), do: :error

  def fetch(name) when is_atom(name) do
    Enum.find(all(), &(&1.name == name))
    |> case do
      nil -> :error
      pattern -> {:ok, pattern}
    end
  end

  @spec prompt_summary() :: [map()]
  def prompt_summary do
    Enum.map(all(), fn pattern ->
      %{
        name: pattern.name,
        generic?: get_in(pattern, [:metadata, :generic?]) == true,
        requires_dynamic_nodes?: Map.get(pattern, :requires_dynamic_nodes?, false)
      }
    end)
  end
end
