defmodule RunicAI.Steps.RLMMapLeaves do
  @moduledoc """
  Runic step that maps bounded materialized artifacts into leaf results.
  """

  require Runic

  alias RunicAI.RLM.LeafResult
  alias RunicAI.RLM.MaterializedArtifact

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :rlm_map_leaves)
    mapper = Keyword.get(opts, :mapper, &default_mapper/1)

    Runic.step(
      fn artifacts ->
        map_artifacts!(List.wrap(artifacts), mapper)
      end,
      name: name
    )
  end

  @spec map_artifacts([MaterializedArtifact.t()], (MaterializedArtifact.t() -> term())) ::
          {:ok, [LeafResult.t()]} | {:error, RunicAI.Error.t()}
  def map_artifacts(artifacts, mapper) when is_list(artifacts) and is_function(mapper, 1) do
    Enum.reduce_while(artifacts, {:ok, []}, fn %MaterializedArtifact{} = artifact, {:ok, acc} ->
      case call_mapper(mapper, artifact) do
        {:ok, %LeafResult{} = result} ->
          case LeafResult.validate(result) do
            {:ok, result} -> {:cont, {:ok, [result | acc]}}
            {:error, error} -> {:halt, {:error, error}}
          end

        {:ok, output} ->
          result =
            LeafResult.new!(output,
              id: "leaf:#{artifact.id}",
              artifact: artifact,
              slice: List.first(artifact.refs),
              metadata: %{artifact_id: artifact.id}
            )

          {:cont, {:ok, [result | acc]}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @spec map_artifacts!([MaterializedArtifact.t()], (MaterializedArtifact.t() -> term())) :: [
          LeafResult.t()
        ]
  def map_artifacts!(artifacts, mapper) do
    case map_artifacts(artifacts, mapper) do
      {:ok, results} -> results
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp call_mapper(mapper, artifact) do
    case mapper.(artifact) do
      {:ok, output} -> {:ok, output}
      {:error, %RunicAI.Error{} = error} -> {:error, error}
      output -> {:ok, output}
    end
  end

  defp default_mapper(%MaterializedArtifact{} = artifact), do: artifact.content
end
