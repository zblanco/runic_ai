defmodule RunicAI.RLM.Environment do
  @moduledoc """
  Behaviour for external long-context source environments.

  Environments keep source material outside the root model context. Reads return
  typed refs, slices, and materialized artifacts so provenance stays visible.
  """

  alias RunicAI.RLM.EnvironmentRef
  alias RunicAI.RLM.MaterializedArtifact
  alias RunicAI.RLM.Slice
  alias RunicAI.RLM.SliceSet
  alias RunicAI.RLM.Source

  @type state :: term()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback put_source(state(), String.t(), keyword()) ::
              {:ok, EnvironmentRef.t(), state()} | {:error, term()}
  @callback get_source(state(), EnvironmentRef.t()) :: {:ok, Source.t()} | {:error, term()}
  @callback metadata(state(), EnvironmentRef.t()) :: {:ok, map()} | {:error, term()}
  @callback size(state(), EnvironmentRef.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback peek(state(), EnvironmentRef.t(), non_neg_integer(), non_neg_integer()) ::
              {:ok, MaterializedArtifact.t()} | {:error, term()}
  @callback slice(state(), EnvironmentRef.t(), non_neg_integer(), non_neg_integer(), keyword()) ::
              {:ok, Slice.t()} | {:error, term()}
  @callback split(state(), EnvironmentRef.t(), keyword()) ::
              {:ok, SliceSet.t()} | {:error, term()}
  @callback search(state(), EnvironmentRef.t(), String.t(), keyword()) ::
              {:ok, SliceSet.t()} | {:error, term()}
  @callback materialize(state(), EnvironmentRef.t() | Slice.t(), keyword()) ::
              {:ok, MaterializedArtifact.t()} | {:error, term()}
  @callback delete(state(), EnvironmentRef.t()) :: {:ok, state()} | {:error, term()}
end
