defmodule RunicAI.Sandbox.GeneratedComponentCatalog.CapabilityGap do
  @moduledoc """
  Decision record explaining why catalog reuse was insufficient.

  A generated component proposal must carry one of these records so later trace
  and catalog consumers can see the candidates considered, why they were not
  selected, and why generation was allowed.
  """

  alias RunicAI.Error
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Entry
  alias RunicAI.Sandbox.GeneratedComponentCatalog.Result

  @actions [
    :reuse_exact,
    :reuse_adapted,
    :compose_existing,
    :generate_leaf,
    :repair_generated,
    :request_review,
    :reject
  ]

  @enforce_keys [
    :id,
    :objective,
    :required_contract,
    :candidates,
    :selected_action,
    :selected_component_id,
    :reason,
    :metadata
  ]
  @derive Jason.Encoder
  defstruct [
    :id,
    :objective,
    :required_contract,
    :candidates,
    :selected_action,
    :selected_component_id,
    :reason,
    :metadata
  ]

  @type action ::
          :reuse_exact
          | :reuse_adapted
          | :compose_existing
          | :generate_leaf
          | :repair_generated
          | :request_review
          | :reject

  @type t :: %__MODULE__{
          id: String.t(),
          objective: String.t(),
          required_contract: map(),
          candidates: [map()],
          selected_action: action(),
          selected_component_id: String.t() | nil,
          reason: String.t(),
          metadata: map()
        }

  @spec actions() :: [action()]
  def actions, do: @actions

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(input) when is_list(input) or is_map(input) do
    input = input_map(input)

    with :ok <- validate_non_empty_string(get(input, :id, default_id(input)), :id),
         :ok <- validate_non_empty_string(get(input, :objective), :objective),
         {:ok, required_contract} <-
           normalize_map(get(input, :required_contract, %{}), :required_contract),
         {:ok, candidates} <- normalize_candidates(get(input, :candidates, [])),
         {:ok, selected_action} <- normalize_action(get(input, :selected_action)),
         :ok <-
           validate_optional_string(get(input, :selected_component_id), :selected_component_id),
         :ok <- validate_non_empty_string(get(input, :reason), :reason),
         {:ok, metadata} <- normalize_map(get(input, :metadata, %{}), :metadata),
         :ok <-
           validate_action_consistency(
             selected_action,
             get(input, :selected_component_id),
             candidates
           ) do
      {:ok,
       %__MODULE__{
         id: get(input, :id, default_id(input)),
         objective: get(input, :objective),
         required_contract: required_contract,
         candidates: candidates,
         selected_action: selected_action,
         selected_component_id: get(input, :selected_component_id),
         reason: get(input, :reason),
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword() | map()) :: t()
  def new!(input) do
    case new(input) do
      {:ok, gap} -> gap
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = gap) do
    new(%{
      id: gap.id,
      objective: gap.objective,
      required_contract: gap.required_contract,
      candidates: gap.candidates,
      selected_action: gap.selected_action,
      selected_component_id: gap.selected_component_id,
      reason: gap.reason,
      metadata: gap.metadata
    })
  end

  @spec generation_allowed?(t()) :: boolean()
  def generation_allowed?(%__MODULE__{selected_action: action})
      when action in [:generate_leaf, :repair_generated],
      do: true

  def generation_allowed?(%__MODULE__{}), do: false

  @spec candidate_ids(t()) :: [String.t()]
  def candidate_ids(%__MODULE__{candidates: candidates}) do
    candidates
    |> Enum.map(&get(&1, :id))
    |> Enum.reject(&is_nil/1)
  end

  @spec candidate_from_result(Result.t() | Entry.t() | map()) :: map()
  def candidate_from_result(%Result{} = result) do
    %{
      id: result.entry.id,
      status: result.entry.status,
      score: result.score,
      match_reasons: result.reasons,
      promotion_target: result.entry.promotion_target,
      rejection_reason: nil
    }
  end

  def candidate_from_result(%Entry{} = entry) do
    %{
      id: entry.id,
      status: entry.status,
      score: nil,
      match_reasons: [],
      promotion_target: entry.promotion_target,
      rejection_reason: nil
    }
  end

  def candidate_from_result(candidate) when is_map(candidate), do: candidate

  defp validate_action_consistency(action, selected_component_id, candidates)
       when action in [:reuse_exact, :reuse_adapted] do
    candidate_ids = Enum.map(candidates, &get(&1, :id))

    cond do
      is_nil(selected_component_id) ->
        {:error,
         Error.validation(
           "generated component capability gap reuse requires selected_component_id",
           source: __MODULE__,
           details: %{selected_action: action}
         )}

      selected_component_id in candidate_ids ->
        :ok

      true ->
        {:error,
         Error.validation(
           "generated component capability gap selected component was not a candidate",
           source: __MODULE__,
           details: %{
             selected_component_id: selected_component_id,
             candidate_ids: candidate_ids
           }
         )}
    end
  end

  defp validate_action_consistency(action, nil, _candidates)
       when action in [
              :generate_leaf,
              :repair_generated,
              :compose_existing,
              :request_review,
              :reject
            ],
       do: :ok

  defp validate_action_consistency(action, selected_component_id, _candidates)
       when action in [:generate_leaf, :repair_generated] and not is_nil(selected_component_id) do
    {:error,
     Error.validation(
       "generated component capability gap generation must not select a catalog component",
       source: __MODULE__,
       details: %{selected_action: action, selected_component_id: selected_component_id}
     )}
  end

  defp validate_action_consistency(_action, _selected_component_id, _candidates), do: :ok

  defp normalize_candidates(candidates) when is_list(candidates) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
      case normalize_candidate(candidate) do
        {:ok, candidate} -> {:cont, {:ok, acc ++ [candidate]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp normalize_candidates(candidates) do
    {:error,
     Error.validation("generated component capability gap candidates must be a list",
       source: __MODULE__,
       details: %{candidates: candidates}
     )}
  end

  defp normalize_candidate(%Result{} = result), do: {:ok, candidate_from_result(result)}
  defp normalize_candidate(%Entry{} = entry), do: {:ok, candidate_from_result(entry)}

  defp normalize_candidate(candidate) when is_map(candidate) do
    if get(candidate, :id) |> is_binary() do
      {:ok, candidate}
    else
      {:error,
       Error.validation("generated component capability gap candidates require ids",
         source: __MODULE__,
         details: %{candidate: candidate}
       )}
    end
  end

  defp normalize_candidate(candidate) do
    {:error,
     Error.validation(
       "generated component capability gap candidate must be a map or catalog result",
       source: __MODULE__,
       details: %{candidate: candidate}
     )}
  end

  defp normalize_action(action) when action in @actions, do: {:ok, action}

  defp normalize_action(action) when is_binary(action) do
    normalized = action |> String.downcase() |> String.replace("-", "_")

    @actions
    |> Enum.find(&(Atom.to_string(&1) == normalized))
    |> case do
      nil -> invalid_action(action)
      action -> {:ok, action}
    end
  end

  defp normalize_action(action), do: invalid_action(action)

  defp invalid_action(action) do
    {:error,
     Error.validation("invalid generated component capability gap selected_action",
       source: __MODULE__,
       details: %{selected_action: action, valid: @actions}
     )}
  end

  defp normalize_map(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map(value, field) do
    {:error,
     Error.validation("generated component capability gap #{field} must be a map",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_non_empty_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_non_empty_string(value, field) do
    {:error,
     Error.validation("generated component capability gap #{field} must be a non-empty string",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_optional_string(nil, _field), do: :ok
  defp validate_optional_string(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_optional_string(value, field) do
    {:error,
     Error.validation(
       "generated component capability gap #{field} must be a non-empty string or nil",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp default_id(input) do
    objective = get(input, :objective, "generated component")

    slug =
      objective
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 48)

    "gap:#{if slug == "", do: "generated_component", else: slug}"
  end

  defp input_map(input) when is_map(input), do: input
  defp input_map(input) when is_list(input), do: Map.new(input)

  defp get(map, key, default \\ nil)
  defp get(nil, _key, default), do: default

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp get(_other, _key, default), do: default
end
