defmodule RunicAI.Sandbox.GeneratedComponentCatalogTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentCatalog
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Store

  test "builds a searchable entry from a promotable generated component" do
    component = component(:invoice, intent_tags: [:parse, :normalize, :tabular])

    assert {:ok, entry} =
             GeneratedComponentCatalog.entry_from_component(component,
               promotion_decision: %{
                 action: :promote,
                 reason: :component_promotable,
                 details: %{target: :artifact}
               }
             )

    assert %Entry{} = entry
    assert entry.id == "generated:invoice"
    assert entry.status == :catalog_available
    assert entry.promotion_target == :artifact
    assert entry.component_kind == :sandbox_execute
    assert entry.intent_tags == [:parse, :normalize, :tabular]
    assert [%{name: "rows", type: "list<object>"}] = entry.input_signature
    assert [%{name: "invoice_facts", type: "list<object>"}] = entry.output_signature
    assert entry.artifacts.source == [%{path: "component.py", ref: "source:invoice"}]
    assert entry.artifacts.tests == [%{path: "test_component.py", ref: "test:invoice"}]
    assert entry.metadata.promotion_decision.target == :artifact
  end

  test "rejects non-promotable generated components" do
    draft =
      GeneratedComponent.new!(
        id: "generated:draft",
        name: "Draft",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run",
        interface: %{inputs: [%{name: "input"}], outputs: [%{name: "output"}]},
        verification: %{status: :planned},
        promotion_status: :draft
      )

    assert {:error, error} = GeneratedComponentCatalog.entry_from_component(draft)
    assert error.kind == :validation
    assert error.details.component_id == "generated:draft"
  end

  test "in-memory store inserts, lists, gets, and ranks entries by contract and policy" do
    invoice =
      component(:invoice,
        intent_tags: [:parse, :normalize, :tabular],
        inputs: [%{name: "rows", type: "list<object>"}],
        outputs: [%{name: "invoice_facts", type: "list<object>"}],
        salience: %{reuse_count: 3, successful_reuse_count: 2, domains: ["invoices"]}
      )
      |> entry!()

    report =
      component(:report,
        intent_tags: [:render, :markdown],
        inputs: [%{name: "facts", type: "list<object>"}],
        outputs: [%{name: "markdown", type: "string"}]
      )
      |> entry!()

    retired =
      component(:retired,
        intent_tags: [:parse, :normalize, :tabular],
        inputs: [%{name: "rows", type: "list<object>"}],
        outputs: [%{name: "invoice_facts", type: "list<object>"}]
      )
      |> entry!(status: :catalog_retired)

    assert {:ok, store} = GeneratedComponentCatalog.new_store(entries: [report])
    assert {:ok, store} = GeneratedComponentCatalog.insert(store, invoice)
    assert {:ok, store} = GeneratedComponentCatalog.insert(store, retired)

    assert Enum.map(GeneratedComponentCatalog.list(store), & &1.id) == [
             "generated:invoice",
             "generated:report",
             "generated:retired"
           ]

    assert {:ok, got} = GeneratedComponentCatalog.get(store, "generated:invoice")
    assert got.id == "generated:invoice"

    assert {:ok, results} =
             GeneratedComponentCatalog.search(store,
               objective: "Normalize invoice rows into invoice facts",
               intent_tags: [:parse, :normalize],
               inputs: [%{name: "rows"}],
               outputs: [%{name: "invoice_facts"}],
               component_kind: :sandbox_execute,
               runtime: :python,
               policy: %{network: :disabled}
             )

    assert [%{entry: %{id: "generated:invoice"}}] = results
    assert hd(results).score > 80
    assert :intent_tags_exact in hd(results).reasons
    assert :input_signature_match in hd(results).reasons
    assert :output_signature_match in hd(results).reasons
    assert :policy_match in hd(results).reasons
    assert :successful_reuse in hd(results).reasons
  end

  test "records and searches negative evidence separately from reusable entries" do
    assert {:ok, store} =
             GeneratedComponentCatalog.new_store(
               negative_evidence: [
                 %{
                   id: "negative:invoice-proof",
                   component_id: "generated:invoice-draft",
                   objective: "Normalize invoice rows",
                   required_contract: %{
                     intent_tags: [:parse, :normalize],
                     inputs: [%{name: "rows"}],
                     outputs: [%{name: "invoice_facts"}],
                     runtime: :python
                   },
                   candidates: [%{id: "generated:generic-parser"}],
                   proof_id: "proof:invoice",
                   command: "python -m pytest",
                   diagnostics: %{stderr_preview: "assertion failed"},
                   source_artifacts: [%{path: "component.py"}],
                   test_artifacts: [%{path: "test_component.py"}],
                   reason: :component_not_promotable
                 }
               ]
             )

    assert [%{id: "negative:invoice-proof"}] = GeneratedComponentCatalog.negative_evidence(store)

    assert {:ok, evidence} =
             GeneratedComponentCatalog.search_negative_evidence(store,
               objective: "Normalize invoice rows",
               intent_tags: [:parse, :normalize],
               inputs: [%{name: "rows"}],
               outputs: [%{name: "invoice_facts"}],
               runtime: :python
             )

    assert [%{component_id: "generated:invoice-draft"}] = evidence
  end

  test "records successful reuse so useful entries rank higher" do
    reusable =
      component("invoice-reusable",
        intent_tags: [:parse, :normalize],
        inputs: [%{name: "rows", type: "list<object>"}],
        outputs: [%{name: "invoice_facts", type: "list<object>"}]
      )
      |> entry!()

    fresh =
      component("invoice-fresh",
        intent_tags: [:parse, :normalize],
        inputs: [%{name: "rows", type: "list<object>"}],
        outputs: [%{name: "invoice_facts", type: "list<object>"}]
      )
      |> entry!()

    store = GeneratedComponentCatalog.new_store!(entries: [fresh, reusable])

    assert {:ok, store} =
             GeneratedComponentCatalog.record_reuse(
               store,
               "generated:invoice-reusable",
               :success,
               used_at: ~U[2026-05-31 12:00:00Z],
               objective: "Normalize invoice rows"
             )

    assert {:ok, results} =
             GeneratedComponentCatalog.search(store,
               objective: "Normalize invoice rows",
               intent_tags: [:parse, :normalize],
               inputs: [%{name: "rows"}],
               outputs: [%{name: "invoice_facts"}],
               component_kind: :sandbox_execute,
               runtime: :python,
               policy: %{network: :disabled}
             )

    assert [%{entry: %{id: "generated:invoice-reusable"}} | _rest] = results
    assert :successful_reuse in hd(results).reasons

    assert {:ok, entry} = GeneratedComponentCatalog.get(store, "generated:invoice-reusable")
    assert entry.salience.reuse_count == 1
    assert entry.salience.successful_reuse_count == 1
    assert entry.salience.last_used_at == ~U[2026-05-31 12:00:00Z]
    assert entry.metadata.last_reuse_outcome.objective == "Normalize invoice rows"
  end

  test "retires entries after repeated failed reuse without deleting evidence" do
    entry =
      component("invoice-retiring",
        intent_tags: [:parse, :normalize],
        inputs: [%{name: "rows", type: "list<object>"}],
        outputs: [%{name: "invoice_facts", type: "list<object>"}]
      )
      |> entry!()

    store = GeneratedComponentCatalog.new_store!(entries: [entry])

    assert {:ok, store} =
             GeneratedComponentCatalog.record_reuse(
               store,
               "generated:invoice-retiring",
               "failure",
               used_at: ~U[2026-05-31 12:00:00Z],
               retire_after_failures: 2,
               details: %{diagnostic: :contract_mismatch}
             )

    assert {:ok, still_available} =
             GeneratedComponentCatalog.get(store, "generated:invoice-retiring")

    assert still_available.status == :catalog_available
    assert still_available.salience.failed_reuse_count == 1

    assert {:ok, store} =
             GeneratedComponentCatalog.record_reuse(
               store,
               "generated:invoice-retiring",
               :failure,
               used_at: ~U[2026-05-31 12:05:00Z],
               retired_at: ~U[2026-05-31 12:06:00Z],
               retire_after_failures: 2
             )

    assert {:ok, retired} = GeneratedComponentCatalog.get(store, "generated:invoice-retiring")
    assert retired.status == :catalog_retired
    assert retired.salience.reuse_count == 2
    assert retired.salience.failed_reuse_count == 2
    assert retired.salience.last_failure_at == ~U[2026-05-31 12:05:00Z]
    assert retired.metadata.retirement.reason == :reuse_failures
    assert retired.metadata.retirement.at == ~U[2026-05-31 12:06:00Z]

    assert Enum.map(GeneratedComponentCatalog.list(store), & &1.id) == [
             "generated:invoice-retiring"
           ]

    assert {:ok, results} =
             GeneratedComponentCatalog.search(store,
               objective: "Normalize invoice rows",
               intent_tags: [:parse, :normalize],
               inputs: [%{name: "rows"}],
               outputs: [%{name: "invoice_facts"}]
             )

    assert results == []
  end

  test "manually retires a catalog entry" do
    entry = component("manual-retire", intent_tags: [:parse]) |> entry!()
    store = GeneratedComponentCatalog.new_store!(entries: [entry])

    assert {:ok, store} =
             GeneratedComponentCatalog.retire(store, "generated:manual-retire",
               retired_at: ~U[2026-05-31 13:00:00Z],
               reason: :policy_revoked,
               details: %{review_id: "review:1"}
             )

    assert {:ok, retired} = GeneratedComponentCatalog.get(store, "generated:manual-retire")
    assert retired.status == :catalog_retired
    assert retired.metadata.retirement.reason == :policy_revoked
    assert retired.metadata.retirement.details.review_id == "review:1"
  end

  test "projects catalog records into trace-ready event maps" do
    entry =
      component("traceable",
        intent_tags: [:parse, :normalize],
        inputs: [%{name: "rows", type: "list<object>"}],
        outputs: [%{name: "invoice_facts", type: "list<object>"}]
      )
      |> entry!(
        promotion_decision: %{
          action: :promote,
          reason: :component_promotable,
          details: %{target: :artifact}
        }
      )

    store = GeneratedComponentCatalog.new_store!(entries: [entry])

    {:ok, [search_result]} =
      GeneratedComponentCatalog.search(store,
        objective: "Normalize invoice rows",
        intent_tags: [:parse, :normalize],
        inputs: [%{name: "rows"}],
        outputs: [%{name: "invoice_facts"}]
      )

    assert {:ok, search_events} = GeneratedComponentCatalog.trace_events(search_result)

    assert [%{type: :generated_component_catalog_search_result, entry_id: "generated:traceable"}] =
             search_events

    assert {:ok, store} =
             GeneratedComponentCatalog.record_reuse(store, "generated:traceable", :success,
               used_at: ~U[2026-05-31 15:00:00Z],
               objective: "Normalize invoice rows"
             )

    assert {:ok, store} =
             GeneratedComponentCatalog.retire(store, "generated:traceable",
               retired_at: ~U[2026-05-31 15:10:00Z],
               reason: :policy_revoked
             )

    assert {:ok, retired} = GeneratedComponentCatalog.get(store, "generated:traceable")
    assert {:ok, entry_events} = GeneratedComponentCatalog.trace_events(retired)

    assert Enum.map(entry_events, & &1.type) == [
             :generated_component_catalog_entry_retired,
             :generated_component_catalog_promotion_recorded,
             :generated_component_catalog_reuse_recorded,
             :generated_component_catalog_retired
           ]

    reuse_event =
      Enum.find(entry_events, &(&1.type == :generated_component_catalog_reuse_recorded))

    assert reuse_event.reuse_outcome.objective == "Normalize invoice rows"
    assert reuse_event.successful_reuse_count == 1

    gap =
      GeneratedComponentCatalog.capability_gap!(
        objective: "Normalize invoice rows",
        required_contract: %{intent_tags: [:parse], inputs: [%{name: "rows"}]},
        candidates: [],
        selected_action: :generate_leaf,
        reason: "no catalog match"
      )

    assert {:ok, gap_events} = GeneratedComponentCatalog.trace_events(gap)

    assert [%{type: :generated_component_capability_gap_decided, selected_action: :generate_leaf}] =
             gap_events

    evidence = hd(negative_evidence_store().negative_evidence |> Map.values())
    assert {:ok, evidence_events} = GeneratedComponentCatalog.trace_events(evidence)
    assert [%{type: :generated_component_negative_evidence_recorded}] = evidence_events
  end

  test "validates lookup queries" do
    assert {:error, error} =
             GeneratedComponentCatalog.search(Store.new!(), objective: "", intent_tags: [])

    assert error.kind == :validation
    assert error.details.objective == ""
  end

  defp entry!(component, opts \\ []) do
    GeneratedComponentCatalog.entry_from_component(component, opts)
    |> case do
      {:ok, entry} -> entry
      {:error, error} -> raise error.message
    end
  end

  defp component(suffix, opts) do
    id = "generated:#{suffix}"
    inputs = Keyword.get(opts, :inputs, [%{name: "rows", type: "list<object>"}])
    outputs = Keyword.get(opts, :outputs, [%{name: "invoice_facts", type: "list<object>"}])
    salience = Keyword.get(opts, :salience, %{})

    GeneratedComponent.new!(
      id: id,
      name: "Generated #{suffix}",
      language: :python,
      runtime: :python,
      entrypoint: "component.py:run",
      source_artifacts: [%{path: "component.py", ref: "source:#{suffix}"}],
      test_artifacts: [%{path: "test_component.py", ref: "test:#{suffix}"}],
      interface: %{inputs: inputs, outputs: outputs},
      verification: %{status: :pass, command: "python -m pytest"},
      promotion_status: :verified,
      metadata: %{
        intent_tags: Keyword.get(opts, :intent_tags, []),
        network: :disabled,
        salience: salience
      }
    )
  end

  defp negative_evidence_store do
    GeneratedComponentCatalog.new_store!(
      negative_evidence: [
        %{
          id: "negative:trace",
          component_id: "generated:traceable-draft",
          objective: "Normalize invoice rows",
          required_contract: %{intent_tags: [:parse], inputs: [%{name: "rows"}]},
          candidates: [],
          proof_id: "proof:trace",
          command: "python -m pytest",
          diagnostics: %{stderr_preview: "assertion failed"},
          reason: :component_not_promotable
        }
      ]
    )
  end
end
