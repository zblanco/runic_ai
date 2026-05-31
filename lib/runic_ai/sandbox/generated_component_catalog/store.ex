defmodule RunicAI.Sandbox.GeneratedComponentCatalog.Store do
  @moduledoc """
  In-memory generated component catalog store.

  This is intentionally a plain data structure. It gives the coordinator and
  promotion flow a stable API now while leaving durable storage as a later
  replacement.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry
  alias RunicAI.Sandbox.GeneratedComponentCatalog.NegativeEvidence
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Query
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Result

  @enforce_keys [:entries, :negative_evidence, :metadata]
  @derive Jason.Encoder
  defstruct entries: %{}, negative_evidence: %{}, metadata: %{}

  @type t :: %__MODULE__{
          entries: %{String.t() => Entry.t()},
          negative_evidence: %{String.t() => NegativeEvidence.t()},
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_metadata(metadata),
         {:ok, store} <-
           insert_many(
             %__MODULE__{entries: %{}, negative_evidence: %{}, metadata: metadata},
             Keyword.get(opts, :entries, [])
           ),
         {:ok, store} <-
           record_negative_evidence_many(store, Keyword.get(opts, :negative_evidence, [])) do
      {:ok, store}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, store} -> store
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec insert(t(), Entry.t() | map() | keyword()) :: {:ok, t()} | {:error, Error.t()}
  def insert(%__MODULE__{} = store, entry_input) do
    with {:ok, entry} <- normalize_entry(entry_input) do
      {:ok, %{store | entries: Map.put(store.entries, entry.id, entry)}}
    end
  end

  @spec record_negative_evidence(t(), NegativeEvidence.t() | map() | keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def record_negative_evidence(%__MODULE__{} = store, evidence_input) do
    with {:ok, evidence} <- normalize_negative_evidence(evidence_input) do
      {:ok, %{store | negative_evidence: Map.put(store.negative_evidence, evidence.id, evidence)}}
    end
  end

  @spec list(t()) :: [Entry.t()]
  def list(%__MODULE__{} = store) do
    store.entries
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @spec negative_evidence(t()) :: [NegativeEvidence.t()]
  def negative_evidence(%__MODULE__{} = store) do
    store.negative_evidence
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @spec get(t(), String.t()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def get(%__MODULE__{} = store, id) when is_binary(id) and id != "" do
    case Map.fetch(store.entries, id) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         Error.validation("generated component catalog entry not found",
           source: __MODULE__,
           details: %{id: id}
         )}
    end
  end

  def get(%__MODULE__{}, id) do
    {:error,
     Error.validation("generated component catalog entry id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  @spec record_reuse(t(), String.t(), :success | :failure | atom(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def record_reuse(store, id, outcome, opts \\ [])

  def record_reuse(%__MODULE__{} = store, id, outcome, opts)
      when is_binary(id) and id != "" and is_list(opts) do
    with {:ok, entry} <- get(store, id),
         {:ok, outcome} <- normalize_reuse_outcome(outcome),
         {:ok, entry} <- update_reuse(entry, outcome, opts) do
      {:ok, %{store | entries: Map.put(store.entries, entry.id, entry)}}
    end
  end

  def record_reuse(%__MODULE__{}, id, _outcome, _opts) do
    {:error,
     Error.validation("generated component catalog reuse id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  @spec retire(t(), String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def retire(store, id, opts \\ [])

  def retire(%__MODULE__{} = store, id, opts)
      when is_binary(id) and id != "" and is_list(opts) do
    with {:ok, entry} <- get(store, id),
         {:ok, entry} <- retire_entry(entry, opts) do
      {:ok, %{store | entries: Map.put(store.entries, entry.id, entry)}}
    end
  end

  def retire(%__MODULE__{}, id, _opts) do
    {:error,
     Error.validation("generated component catalog retire id must be a non-empty string",
       source: __MODULE__,
       details: %{id: id}
     )}
  end

  @spec search(t(), Query.t() | map() | keyword()) :: {:ok, [Result.t()]} | {:error, Error.t()}
  def search(%__MODULE__{} = store, query_input) do
    with {:ok, query} <- normalize_query(query_input) do
      results =
        store
        |> list()
        |> Enum.filter(&Entry.available?/1)
        |> Enum.map(&score(&1, query))
        |> Enum.reject(&(&1.score <= 0))
        |> Enum.sort_by(fn result -> {-result.score, result.entry.id} end)
        |> Enum.take(query.top_k)

      {:ok, results}
    end
  end

  @spec search_negative_evidence(t(), Query.t() | map() | keyword()) ::
          {:ok, [NegativeEvidence.t()]} | {:error, Error.t()}
  def search_negative_evidence(%__MODULE__{} = store, query_input) do
    with {:ok, query} <- normalize_query(query_input) do
      evidence =
        store
        |> negative_evidence()
        |> Enum.map(&{negative_evidence_score(&1, query), &1})
        |> Enum.reject(fn {score, _evidence} -> score <= 0 end)
        |> Enum.sort_by(fn {score, evidence} -> {-score, evidence.id} end)
        |> Enum.take(query.top_k)
        |> Enum.map(fn {_score, evidence} -> evidence end)

      {:ok, evidence}
    end
  end

  defp insert_many(store, entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, store}, fn entry, {:ok, acc} ->
      case insert(acc, entry) do
        {:ok, store} -> {:cont, {:ok, store}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp insert_many(_store, entries) do
    {:error,
     Error.validation("generated component catalog entries must be a list",
       source: __MODULE__,
       details: %{entries: entries}
     )}
  end

  defp record_negative_evidence_many(store, evidence) when is_list(evidence) do
    Enum.reduce_while(evidence, {:ok, store}, fn evidence, {:ok, acc} ->
      case record_negative_evidence(acc, evidence) do
        {:ok, store} -> {:cont, {:ok, store}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp record_negative_evidence_many(_store, evidence) do
    {:error,
     Error.validation("generated component catalog negative evidence must be a list",
       source: __MODULE__,
       details: %{negative_evidence: evidence}
     )}
  end

  defp normalize_entry(%Entry{} = entry), do: Entry.validate(entry)
  defp normalize_entry(input) when is_map(input) or is_list(input), do: Entry.new(input)

  defp normalize_entry(input) do
    {:error,
     Error.validation("generated component catalog store expected an entry",
       source: __MODULE__,
       details: %{entry: input}
     )}
  end

  defp normalize_negative_evidence(%NegativeEvidence{} = evidence),
    do: NegativeEvidence.validate(evidence)

  defp normalize_negative_evidence(input) when is_map(input) or is_list(input),
    do: NegativeEvidence.new(input)

  defp normalize_negative_evidence(input) do
    {:error,
     Error.validation("generated component catalog store expected negative evidence",
       source: __MODULE__,
       details: %{negative_evidence: input}
     )}
  end

  defp normalize_query(%Query{} = query), do: Query.validate(query)
  defp normalize_query(input) when is_map(input) or is_list(input), do: Query.new(input)

  defp normalize_query(input) do
    {:error,
     Error.validation("generated component catalog store expected a query",
       source: __MODULE__,
       details: %{query: input}
     )}
  end

  defp normalize_reuse_outcome(outcome) when outcome in [:success, :failure],
    do: {:ok, outcome}

  defp normalize_reuse_outcome(outcome) when is_binary(outcome) do
    case String.downcase(outcome) do
      "success" -> {:ok, :success}
      "failure" -> {:ok, :failure}
      _other -> invalid_reuse_outcome(outcome)
    end
  end

  defp normalize_reuse_outcome(outcome), do: invalid_reuse_outcome(outcome)

  defp invalid_reuse_outcome(outcome) do
    {:error,
     Error.validation("invalid generated component catalog reuse outcome",
       source: __MODULE__,
       details: %{outcome: outcome, valid: [:success, :failure]}
     )}
  end

  defp update_reuse(%Entry{} = entry, outcome, opts) do
    now = Keyword.get(opts, :used_at, DateTime.utc_now())

    metadata =
      Map.put(entry.metadata || %{}, :last_reuse_outcome, reuse_metadata(outcome, opts, now))

    salience =
      entry.salience
      |> Map.put(:reuse_count, value_get(entry.salience, :reuse_count, 0) + 1)
      |> update_reuse_counts(outcome, now)

    entry = %{entry | salience: salience, metadata: metadata}

    cond do
      outcome == :failure and should_retire?(entry, opts) ->
        retire_entry(entry, Keyword.put_new(opts, :reason, :reuse_failures))

      true ->
        Entry.validate(entry)
    end
  end

  defp update_reuse_counts(salience, :success, now) do
    salience
    |> Map.put(:successful_reuse_count, value_get(salience, :successful_reuse_count, 0) + 1)
    |> Map.put(:last_used_at, now)
  end

  defp update_reuse_counts(salience, :failure, now) do
    salience
    |> Map.put(:failed_reuse_count, value_get(salience, :failed_reuse_count, 0) + 1)
    |> Map.put(:last_failure_at, now)
  end

  defp reuse_metadata(outcome, opts, now) do
    %{
      outcome: outcome,
      at: now,
      objective: Keyword.get(opts, :objective),
      workflow_id: Keyword.get(opts, :workflow_id),
      details: Keyword.get(opts, :details, %{})
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp should_retire?(%Entry{} = entry, opts) do
    case Keyword.get(opts, :retire_after_failures) do
      failures when is_integer(failures) and failures > 0 ->
        value_get(entry.salience, :failed_reuse_count, 0) >= failures

      _other ->
        false
    end
  end

  defp retire_entry(%Entry{} = entry, opts) do
    now = Keyword.get(opts, :retired_at, DateTime.utc_now())
    reason = Keyword.get(opts, :reason, :manual_retirement)

    metadata =
      Map.put(entry.metadata || %{}, :retirement, %{
        reason: reason,
        at: now,
        details: Keyword.get(opts, :details, %{})
      })

    Entry.validate(%{entry | status: :catalog_retired, metadata: metadata})
  end

  defp score(%Entry{} = entry, %Query{} = query) do
    {score, reasons} =
      [
        tag_score(entry, query),
        signature_score(entry.input_signature, query.inputs, :input_signature_match),
        signature_score(entry.output_signature, query.outputs, :output_signature_match),
        component_kind_score(entry, query),
        runtime_score(entry, query),
        policy_score(entry, query),
        promotion_score(entry),
        salience_score(entry)
      ]
      |> Enum.reduce({0, []}, fn {points, reason}, {total, reasons} ->
        if points > 0 do
          {total + points, reasons ++ [reason]}
        else
          {total, reasons}
        end
      end)

    score = if semantically_relevant?(reasons), do: score, else: 0

    Result.new!(entry: entry, score: score, reasons: reasons, metadata: %{query: query.objective})
  end

  defp negative_evidence_score(%NegativeEvidence{} = evidence, %Query{} = query) do
    contract = evidence.required_contract

    {score, reasons} =
      [
        negative_tag_score(value_get(contract, :intent_tags, []), query.intent_tags),
        negative_signature_score(value_get(contract, :inputs, []), query.inputs),
        negative_signature_score(value_get(contract, :outputs, []), query.outputs),
        negative_runtime_score(value_get(contract, :runtime), query.runtime)
      ]
      |> Enum.reduce({0, []}, fn {points, reason}, {total, reasons} ->
        if points > 0, do: {total + points, [reason | reasons]}, else: {total, reasons}
      end)

    if semantically_relevant?(reasons), do: score, else: 0
  end

  defp negative_tag_score(entry_tags, query_tags) do
    entry_tags = MapSet.new(Enum.map(entry_tags, &tag_key/1))
    query_tags = MapSet.new(Enum.map(query_tags, &tag_key/1))
    overlap = MapSet.intersection(entry_tags, query_tags) |> MapSet.size()

    if overlap > 0, do: {20 + overlap, :negative_intent_tags}, else: {0, nil}
  end

  defp negative_signature_score(entry_ports, query_ports) do
    {_points, reason} = signature_score(entry_ports, query_ports, :negative_signature_match)
    if reason, do: {10, reason}, else: {0, nil}
  end

  defp negative_runtime_score(runtime, runtime), do: {4, :negative_runtime_match}

  defp negative_runtime_score(runtime, query_runtime) when not is_nil(query_runtime) do
    if to_string(runtime) == to_string(query_runtime),
      do: {4, :negative_runtime_match},
      else: {0, nil}
  end

  defp negative_runtime_score(_runtime, _query_runtime), do: {0, nil}

  defp semantically_relevant?(reasons) do
    Enum.any?(
      reasons,
      &(&1 in [
          :intent_tags_exact,
          :intent_tags_partial,
          :input_signature_match,
          :output_signature_match,
          :negative_intent_tags,
          :negative_signature_match
        ])
    )
  end

  defp tag_score(%Entry{intent_tags: entry_tags}, %Query{intent_tags: query_tags}) do
    entry_tags = MapSet.new(Enum.map(entry_tags, &tag_key/1))
    query_tags = MapSet.new(Enum.map(query_tags, &tag_key/1))
    overlap = MapSet.intersection(entry_tags, query_tags) |> MapSet.size()

    case {MapSet.size(query_tags), overlap} do
      {0, _overlap} -> {0, nil}
      {_count, 0} -> {0, nil}
      {count, ^overlap} when overlap == count -> {40, :intent_tags_exact}
      _other -> {20 + overlap, :intent_tags_partial}
    end
  end

  defp signature_score(_entry_ports, [], _reason), do: {0, nil}

  defp signature_score(entry_ports, query_ports, reason) do
    entry_names = MapSet.new(Enum.map(entry_ports, &port_name/1) |> Enum.reject(&is_nil/1))
    query_names = MapSet.new(Enum.map(query_ports, &port_name/1) |> Enum.reject(&is_nil/1))

    cond do
      MapSet.size(query_names) == 0 ->
        {0, nil}

      MapSet.subset?(query_names, entry_names) ->
        {15, reason}

      MapSet.size(MapSet.intersection(entry_names, query_names)) > 0 ->
        {8, reason}

      true ->
        {0, nil}
    end
  end

  defp component_kind_score(%Entry{component_kind: kind}, %Query{component_kind: kind})
       when not is_nil(kind),
       do: {10, :component_kind_match}

  defp component_kind_score(_entry, _query), do: {0, nil}

  defp runtime_score(%Entry{runtime: runtime}, %Query{runtime: runtime}) when not is_nil(runtime),
    do: {8, :runtime_match}

  defp runtime_score(%Entry{runtime: runtime}, %Query{runtime: query_runtime})
       when not is_nil(query_runtime) do
    if to_string(runtime) == to_string(query_runtime), do: {8, :runtime_match}, else: {0, nil}
  end

  defp runtime_score(_entry, _query), do: {0, nil}

  defp policy_score(%Entry{sandbox_profile: sandbox_profile}, %Query{policy: policy}) do
    requested_network = value_get(policy, :network)
    entry_network = value_get(sandbox_profile, :network)

    cond do
      is_nil(requested_network) ->
        {0, nil}

      requested_network == entry_network or
          to_string(requested_network) == to_string(entry_network) ->
        {10, :policy_match}

      true ->
        {0, nil}
    end
  end

  defp promotion_score(%Entry{promotion_target: :artifact}), do: {5, :artifact_promoted}
  defp promotion_score(%Entry{promotion_target: :host_repo}), do: {4, :host_repo_promoted}
  defp promotion_score(_entry), do: {0, nil}

  defp salience_score(%Entry{salience: salience}) do
    reuse_count = value_get(salience, :reuse_count, 0)
    successful = value_get(salience, :successful_reuse_count, 0)
    failed = value_get(salience, :failed_reuse_count, 0)

    cond do
      successful > failed and successful > 0 -> {min(successful - failed, 10), :successful_reuse}
      reuse_count > 0 -> {1, :prior_reuse}
      true -> {0, nil}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("generated component catalog store metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp tag_key(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp tag_key(tag), do: to_string(tag)

  defp port_name(%{name: name}) when is_binary(name), do: name
  defp port_name(%{"name" => name}) when is_binary(name), do: name
  defp port_name(name) when is_binary(name), do: name
  defp port_name(_port), do: nil

  defp value_get(map, key, default \\ nil)
  defp value_get(nil, _key, default), do: default

  defp value_get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value_get(_other, _key, default), do: default
end
