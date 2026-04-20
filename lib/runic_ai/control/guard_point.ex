defmodule RunicAI.Control.GuardPoint do
  @moduledoc """
  Named workflow boundaries where guard evaluation may occur.
  """

  alias RunicAI.Error

  @standard_points [:pre_tool, :post_tool, :pre_answer, :pre_handoff, :pre_continue]

  @type t :: :pre_tool | :post_tool | :pre_answer | :pre_handoff | :pre_continue | atom()

  @spec standard_points() :: [atom()]
  def standard_points, do: @standard_points

  @spec standard?(atom()) :: boolean()
  def standard?(point) when is_atom(point), do: point in @standard_points
  def standard?(_point), do: false

  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(point) when is_atom(point), do: :ok

  def validate(point) do
    {:error,
     Error.validation("guard point must be an atom, got: #{inspect(point)}", source: __MODULE__)}
  end
end
