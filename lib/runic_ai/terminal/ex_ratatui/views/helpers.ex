defmodule RunicAI.Terminal.ExRatatui.Views.Helpers do
  @moduledoc false

  alias ExRatatui.Widgets.Block
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Theme

  @spec block(String.t(), Model.t()) :: Block.t()
  def block(title, %Model{} = model) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :plain,
      border_style: Theme.style(:border, model),
      padding: {1, 1, 0, 0}
    }
  end

  @spec short(term(), non_neg_integer()) :: String.t()
  def short(value, limit \\ 80)

  def short(nil, _limit), do: ""

  def short(value, limit) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(limit)
  end

  def short(value, limit), do: value |> inspect(limit: 8, printable_limit: limit) |> short(limit)

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(text, limit) when byte_size(text) <= limit, do: text
  def truncate(text, limit) when limit <= 3, do: String.slice(text, 0, limit)
  def truncate(text, limit), do: String.slice(text, 0, limit - 3) <> "..."

  @spec time(term()) :: String.t()
  def time(%DateTime{} = dt),
    do: dt |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_iso8601()

  def time(nil), do: "-"
  def time(other), do: short(other, 16)

  @spec pending_hitl_count(Model.t()) :: non_neg_integer()
  def pending_hitl_count(%Model{} = model), do: length(pending_hitl_items(model))

  @spec pending_hitl_items(Model.t()) :: [map()]
  def pending_hitl_items(%Model{} = model) do
    durable_review_items =
      model.review_requests
      |> Enum.map(&normalize_hitl_item(&1, :review))
      |> Enum.filter(&pending_hitl?/1)

    objective_items =
      objective_pending_items(model.objective_loop, :pending_review_requests, :objective_review) ++
        objective_pending_items(model.objective_loop, :pending_budget_requests, :objective_budget)

    durable_review_items
    |> Kernel.++(objective_items)
    |> Enum.uniq_by(&hitl_key/1)
  end

  defp objective_pending_items(loop, key, kind) do
    loop
    |> field(key)
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_hitl_item(&1, kind))
    |> Enum.filter(&pending_hitl?/1)
  end

  defp normalize_hitl_item(item, default_kind) when is_map(item) do
    details = field(item, :details) || %{}
    nested_request = field(details, :review_request) || %{}

    %{
      id: field(item, :id) || field(item, :resume_key),
      resume_key: field(item, :resume_key) || field(nested_request, :resume_key),
      kind: field(item, :kind) || default_kind,
      source: default_kind,
      status: field(item, :status) || "pending",
      details: details,
      reason:
        field(item, :reason) ||
          field(details, :reason) ||
          field(nested_request, :reason) ||
          field(item, :suggested_next_action)
    }
  end

  defp pending_hitl?(item) do
    field(item, :status) in [nil, :pending, "pending", :review, "review", :waiting, "waiting"]
  end

  defp hitl_key(item) do
    field(item, :resume_key) ||
      legacy_objective_hitl_key(item) ||
      field(item, :id) ||
      inspect(item)
  end

  defp legacy_objective_hitl_key(item) do
    details = field(item, :details) || %{}

    objective_loop? =
      field(details, "objective_loop?") in [true, "true"] or
        field(item, :source) in [:objective_review, :objective_budget]

    reason = field(item, :reason)

    if objective_loop? and is_binary(reason), do: "objective-loop:#{reason}"
  end

  defp field(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_map, _key), do: nil
end
