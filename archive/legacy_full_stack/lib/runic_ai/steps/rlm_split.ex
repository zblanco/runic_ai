defmodule RunicAI.Steps.RLMSplit do
  @moduledoc """
  Runic step that splits an external RLM source into bounded slices.
  """

  require Runic

  alias RunicAI.RLM
  alias RunicAI.RLM.EnvironmentRef

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :rlm_split)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        with {:ok, environment, source_ref, split_opts} <- resolve_input(input, defaults),
             {:ok, slice_set} <- RLM.split(environment, source_ref, split_opts) do
          slice_set
        end
      end,
      name: name
    )
  end

  defp resolve_input(input, defaults) when is_map(input) and is_list(defaults) do
    environment =
      Map.get(input, :environment) || Map.get(input, "environment") ||
        Keyword.get(defaults, :environment)

    source_ref =
      Map.get(input, :source_ref) || Map.get(input, "source_ref") ||
        Keyword.get(defaults, :source_ref)

    split_opts =
      defaults
      |> Keyword.merge(Map.get(input, :split_opts) || Map.get(input, "split_opts") || [])
      |> Keyword.drop([:environment, :source_ref])

    case source_ref do
      %EnvironmentRef{} ->
        {:ok, environment, source_ref, split_opts}

      _ ->
        {:error, RunicAI.Error.validation("RLM split requires a source_ref", source: __MODULE__)}
    end
  end
end
