defmodule RunicAI.Sandbox.GeneratedComponentCatalog.Trace do
  @moduledoc """
  Read-model event projection for generated component catalog records.

  These events are intentionally plain maps so terminal, trace, and future UI
  surfaces can explain catalog search, reuse, negative evidence, and retirement
  without coupling to the in-memory store.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry
  alias RunicAI.Sandbox.GeneratedComponentCatalog.NegativeEvidence
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Result

  @spec events(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def events(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case events(item) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  def events(%Result{} = result) do
    {:ok,
     [
       event(:generated_component_catalog_search_result, %{
         entry_id: result.entry.id,
         score: result.score,
         match_reasons: result.reasons,
         query: result.metadata.query
       })
     ]}
  end

  def events(%CapabilityGap{} = gap) do
    {:ok,
     [
       event(:generated_component_capability_gap_decided, %{
         gap_id: gap.id,
         objective: gap.objective,
         selected_action: gap.selected_action,
         selected_component_id: gap.selected_component_id,
         candidate_ids: CapabilityGap.candidate_ids(gap),
         reason: gap.reason
       })
     ]}
  end

  def events(%NegativeEvidence{} = evidence) do
    {:ok,
     [
       event(:generated_component_negative_evidence_recorded, %{
         evidence_id: evidence.id,
         component_id: evidence.component_id,
         objective: evidence.objective,
         reason: evidence.reason,
         proof_id: evidence.proof_id,
         command: evidence.command
       })
     ]}
  end

  def events(%Entry{} = entry) do
    status_type =
      if Entry.available?(entry),
        do: :generated_component_catalog_entry_available,
        else: :generated_component_catalog_entry_retired

    {:ok,
     [
       event(status_type, entry_summary(entry)),
       promotion_event(entry),
       reuse_event(entry),
       retirement_event(entry)
     ]
     |> Enum.reject(&is_nil/1)}
  end

  def events(item) do
    {:error,
     Error.validation("generated component catalog trace events require a catalog record",
       source: __MODULE__,
       details: %{item: inspect(item)}
     )}
  end

  defp promotion_event(%Entry{} = entry) do
    case value_get(entry.metadata, :promotion_decision) do
      nil ->
        nil

      decision ->
        event(
          :generated_component_catalog_promotion_recorded,
          Map.merge(entry_summary(entry), %{promotion_decision: decision})
        )
    end
  end

  defp reuse_event(%Entry{} = entry) do
    case value_get(entry.metadata, :last_reuse_outcome) do
      nil ->
        nil

      outcome ->
        event(
          :generated_component_catalog_reuse_recorded,
          Map.merge(entry_summary(entry), %{reuse_outcome: outcome})
        )
    end
  end

  defp retirement_event(%Entry{} = entry) do
    case value_get(entry.metadata, :retirement) do
      nil ->
        nil

      retirement ->
        event(
          :generated_component_catalog_retired,
          Map.merge(entry_summary(entry), %{retirement: retirement})
        )
    end
  end

  defp entry_summary(%Entry{} = entry) do
    %{
      entry_id: entry.id,
      name: entry.name,
      status: entry.status,
      promotion_target: entry.promotion_target,
      component_kind: entry.component_kind,
      runtime: entry.runtime,
      intent_tags: entry.intent_tags,
      verification_status: value_get(entry.verification, :status),
      reuse_count: value_get(entry.salience, :reuse_count, 0),
      successful_reuse_count: value_get(entry.salience, :successful_reuse_count, 0),
      failed_reuse_count: value_get(entry.salience, :failed_reuse_count, 0)
    }
  end

  defp event(type, data), do: Map.put(data, :type, type)

  defp value_get(map, key, default \\ nil)
  defp value_get(nil, _key, default), do: default

  defp value_get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value_get(_other, _key, default), do: default
end
