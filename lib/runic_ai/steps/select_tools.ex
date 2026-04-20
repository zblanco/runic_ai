defmodule RunicAI.Steps.SelectTools do
  @moduledoc """
  Select the visible tool set for one turn.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Tool.Registry
  alias RunicAI.Tool.Selection

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :select_tools)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request ->
        select!(turn_request, options)
      end,
      name: name
    )
  end

  @spec select(TurnRequest.t(), keyword()) :: {:ok, Selection.t()} | {:error, RunicAI.Error.t()}
  def select(%TurnRequest{} = turn_request, opts \\ []) do
    with {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, registry} <- Registry.from_input(Keyword.get(opts, :registry)) do
      selector = Keyword.get(opts, :selector)
      static_visible_tools = Keyword.get(opts, :visible_tools)
      metadata = Keyword.get(opts, :metadata, %{})

      selector
      |> selector_value(turn_request, registry, static_visible_tools)
      |> selection_from_value(registry, metadata)
    end
  end

  @spec select!(TurnRequest.t(), keyword()) :: Selection.t()
  def select!(%TurnRequest{} = turn_request, opts \\ []) do
    case select(turn_request, opts) do
      {:ok, selection} -> selection
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp selector_value(nil, _turn_request, registry, nil), do: registry.tools

  defp selector_value(nil, _turn_request, _registry, static_visible_tools),
    do: static_visible_tools

  defp selector_value(selector, turn_request, registry, _static_visible_tools)
       when is_function(selector, 2),
       do: selector.(turn_request, registry)

  defp selector_value(selector, turn_request, _registry, _static_visible_tools)
       when is_function(selector, 1),
       do: selector.(turn_request)

  defp selector_value(value, _turn_request, _registry, _static_visible_tools), do: value

  defp selection_from_value({:ok, %Selection{} = selection}, _registry, _metadata),
    do: Selection.validate(selection)

  defp selection_from_value(%Selection{} = selection, _registry, _metadata),
    do: Selection.validate(selection)

  defp selection_from_value(value, registry, metadata) when is_list(value) do
    Selection.new(registry, value, metadata: metadata)
  end

  defp selection_from_value(nil, registry, metadata) do
    Selection.new(registry, registry.tools, metadata: metadata)
  end

  defp selection_from_value(other, _registry, _metadata) do
    {:error,
     RunicAI.Error.validation("unsupported tool selection result: #{inspect(other)}",
       source: __MODULE__
     )}
  end
end
