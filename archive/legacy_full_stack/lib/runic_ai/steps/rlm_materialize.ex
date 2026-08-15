defmodule RunicAI.Steps.RLMMaterialize do
  @moduledoc """
  Runic step that materializes RLM slices just before leaf work.
  """

  require Runic

  alias RunicAI.RLM
  alias RunicAI.RLM.Slice
  alias RunicAI.RLM.SliceSet

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :rlm_materialize)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        with {:ok, environment, slices, materialize_opts} <- resolve_input(input, defaults),
             {:ok, artifacts} <- materialize_all(environment, slices, materialize_opts) do
          artifacts
        end
      end,
      name: name
    )
  end

  defp resolve_input(%SliceSet{} = slice_set, defaults) do
    {:ok, Keyword.get(defaults, :environment), slice_set.slices,
     Keyword.drop(defaults, [:environment])}
  end

  defp resolve_input(%Slice{} = slice, defaults) do
    {:ok, Keyword.get(defaults, :environment), [slice], Keyword.drop(defaults, [:environment])}
  end

  defp resolve_input(input, defaults) when is_map(input) do
    environment =
      Map.get(input, :environment) || Map.get(input, "environment") ||
        Keyword.get(defaults, :environment)

    slices =
      case Map.get(input, :slice_set) || Map.get(input, "slice_set") || Map.get(input, :slices) ||
             Map.get(input, "slices") do
        %SliceSet{} = slice_set -> slice_set.slices
        %Slice{} = slice -> [slice]
        slices when is_list(slices) -> slices
        nil -> []
      end

    {:ok, environment, slices, Keyword.drop(defaults, [:environment])}
  end

  defp materialize_all(environment, slices, opts) do
    Enum.reduce_while(slices, {:ok, []}, fn %Slice{} = slice, {:ok, acc} ->
      case RLM.materialize(environment, slice, opts) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      error -> error
    end
  end
end
