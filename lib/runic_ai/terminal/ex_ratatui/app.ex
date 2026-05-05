defmodule RunicAI.Terminal.ExRatatui.App do
  @moduledoc """
  ExRatatui reducer app for the RunicAI local agent workbench.
  """

  use ExRatatui.App, runtime: :reducer

  alias RunicAI.Terminal.ExRatatui.Commands
  alias RunicAI.Terminal.ExRatatui.LogCapture
  alias RunicAI.Terminal.ExRatatui.Model
  alias RunicAI.Terminal.ExRatatui.Options
  alias RunicAI.Terminal.ExRatatui.Subscriptions
  alias RunicAI.Terminal.ExRatatui.Update
  alias RunicAI.Terminal.ExRatatui.Views.Root

  @impl true
  def init(opts) do
    options = Keyword.fetch!(opts, :options)
    external_store = Keyword.get(opts, :store)

    with {:ok, store, owner?} <- store_for(options, external_store) do
      LogCapture.attach(self())

      composer_ref = Keyword.get(opts, :composer_ref) || ExRatatui.textarea_new()
      slash_ref = Keyword.get(opts, :slash_ref) || ExRatatui.textarea_new()

      model =
        options
        |> Model.new(
          store: store,
          store_owner?: owner?,
          composer_ref: composer_ref,
          slash_ref: slash_ref,
          run_fun: Keyword.get(opts, :run_fun),
          managed_start_fun: Keyword.get(opts, :managed_start_fun),
          resume_fun: Keyword.get(opts, :resume_fun)
        )

      {:ok, model, commands: Update.init_commands(model)}
    end
  end

  @impl true
  def render(%Model{} = model, frame), do: Root.render(model, frame)

  @impl true
  def update(msg, %Model{} = model), do: Update.update(msg, model)

  @impl true
  def subscriptions(%Model{} = model), do: Subscriptions.subscriptions(model)

  @impl true
  def terminate(_reason, %Model{} = model) do
    LogCapture.detach(self())
    Commands.close_store(model.store, model.store_owner?)
  end

  defp store_for(%Options{} = _options, %RunicAI.Persistence.SQLite.Store{} = store),
    do: {:ok, store, false}

  defp store_for(%Options{} = options, _external_store), do: Commands.open_store(options)
end
