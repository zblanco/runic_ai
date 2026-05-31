defmodule RunicAI.Sandbox.GeneratedComponentCatalog do
  @moduledoc """
  Public facade for generated component catalog data structures.
  """

  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry
  alias RunicAI.Sandbox.GeneratedComponentCatalog.NegativeEvidence
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Query
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Store
  alias RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Context
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Trace

  @spec entry(keyword() | map()) :: {:ok, Entry.t()} | {:error, RunicAI.Error.t()}
  def entry(input), do: Entry.new(input)

  @spec entry!(keyword() | map()) :: Entry.t()
  def entry!(input), do: Entry.new!(input)

  @spec entry_from_component(term(), keyword()) ::
          {:ok, Entry.t()} | {:error, RunicAI.Error.t()}
  def entry_from_component(component, opts \\ []), do: Entry.from_component(component, opts)

  @spec query(keyword() | map()) :: {:ok, Query.t()} | {:error, RunicAI.Error.t()}
  def query(input), do: Query.new(input)

  @spec query!(keyword() | map()) :: Query.t()
  def query!(input), do: Query.new!(input)

  @spec capability_gap(keyword() | map()) ::
          {:ok, CapabilityGap.t()} | {:error, RunicAI.Error.t()}
  def capability_gap(input), do: CapabilityGap.new(input)

  @spec capability_gap!(keyword() | map()) :: CapabilityGap.t()
  def capability_gap!(input), do: CapabilityGap.new!(input)

  @spec prompt_context(String.t(), keyword()) :: {:ok, map()} | {:error, RunicAI.Error.t()}
  def prompt_context(objective, opts \\ []), do: Context.prompt_context(objective, opts)

  @spec prompt_context!(String.t(), keyword()) :: map()
  def prompt_context!(objective, opts \\ []), do: Context.prompt_context!(objective, opts)

  @spec gap_for_proposal(String.t(), term(), keyword()) ::
          {:ok, CapabilityGap.t()} | {:error, RunicAI.Error.t()}
  def gap_for_proposal(objective, proposal, opts \\ []),
    do: Context.gap_for_proposal(objective, proposal, opts)

  @spec search_context(String.t(), keyword()) ::
          {:ok, [RunicAI.Sandbox.GeneratedComponentCatalog.Result.t()]}
          | {:error, RunicAI.Error.t()}
  def search_context(objective, opts \\ []), do: Context.search(objective, opts)

  @spec best_match(String.t(), keyword()) ::
          {:ok, RunicAI.Sandbox.GeneratedComponentCatalog.Result.t() | nil}
          | {:error, RunicAI.Error.t()}
  def best_match(objective, opts \\ []), do: Context.best_match(objective, opts)

  @spec new_store(keyword()) :: {:ok, Store.t()} | {:error, RunicAI.Error.t()}
  def new_store(opts \\ []), do: Store.new(opts)

  @spec new_store!(keyword()) :: Store.t()
  def new_store!(opts \\ []), do: Store.new!(opts)

  @spec insert(Store.t(), Entry.t() | map() | keyword()) ::
          {:ok, Store.t()} | {:error, RunicAI.Error.t()}
  def insert(%Store{} = store, entry), do: Store.insert(store, entry)

  @spec record_negative_evidence(Store.t(), NegativeEvidence.t() | map() | keyword()) ::
          {:ok, Store.t()} | {:error, RunicAI.Error.t()}
  def record_negative_evidence(%Store{} = store, evidence),
    do: Store.record_negative_evidence(store, evidence)

  @spec record_reuse(Store.t(), String.t(), :success | :failure | String.t(), keyword()) ::
          {:ok, Store.t()} | {:error, RunicAI.Error.t()}
  def record_reuse(%Store{} = store, id, outcome, opts \\ []),
    do: Store.record_reuse(store, id, outcome, opts)

  @spec retire(Store.t(), String.t(), keyword()) :: {:ok, Store.t()} | {:error, RunicAI.Error.t()}
  def retire(%Store{} = store, id, opts \\ []), do: Store.retire(store, id, opts)

  @spec get(Store.t(), String.t()) :: {:ok, Entry.t()} | {:error, RunicAI.Error.t()}
  def get(%Store{} = store, id), do: Store.get(store, id)

  @spec list(Store.t()) :: [Entry.t()]
  def list(%Store{} = store), do: Store.list(store)

  @spec negative_evidence(Store.t()) :: [NegativeEvidence.t()]
  def negative_evidence(%Store{} = store), do: Store.negative_evidence(store)

  @spec search(Store.t(), Query.t() | map() | keyword()) ::
          {:ok, [RunicAI.Sandbox.GeneratedComponentCatalog.Result.t()]}
          | {:error, RunicAI.Error.t()}
  def search(%Store{} = store, query), do: Store.search(store, query)

  @spec search_negative_evidence(Store.t(), Query.t() | map() | keyword()) ::
          {:ok, [NegativeEvidence.t()]} | {:error, RunicAI.Error.t()}
  def search_negative_evidence(%Store{} = store, query),
    do: Store.search_negative_evidence(store, query)

  @spec trace_events(term()) :: {:ok, [map()]} | {:error, RunicAI.Error.t()}
  def trace_events(item), do: Trace.events(item)
end
