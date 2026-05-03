defmodule RunicAI.Terminal.Renderer do
  @moduledoc """
  Renderer selection and dispatch for terminal presentation.
  """

  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.EventPresenter
  alias RunicAI.Terminal.OwlPresenter

  @enforce_keys [:name, :detail, :color, :theme, :unicode, :progress, :graph]
  defstruct [
    :name,
    :detail,
    :color,
    :theme,
    :unicode,
    :progress,
    :graph
  ]

  @type t :: %__MODULE__{}

  @spec new(CliOptions.t(), keyword()) :: t()
  def new(%CliOptions{} = options, opts \\ []) do
    %__MODULE__{
      name: resolve_name(options.renderer, opts),
      detail: options.detail,
      color: options.color,
      theme: options.theme,
      unicode: options.unicode,
      progress: options.progress,
      graph: options.graph
    }
  end

  @spec render_header(t(), map() | keyword()) :: String.t()
  def render_header(%__MODULE__{name: :owl} = renderer, opts) do
    opts
    |> Map.new()
    |> Map.merge(%{
      renderer: renderer.name,
      theme: renderer.theme,
      color: renderer.color
    })
    |> OwlPresenter.render_header(renderer_opts(renderer))
  end

  def render_header(%__MODULE__{} = renderer, opts) do
    opts
    |> Map.new()
    |> Map.merge(%{renderer: renderer.name, theme: renderer.theme, color: renderer.color})
    |> EventPresenter.render_header()
  end

  @spec render_event(t(), Event.t()) :: String.t()
  def render_event(%__MODULE__{name: :owl} = renderer, %Event{} = event) do
    OwlPresenter.render_event(event, renderer_opts(renderer))
  end

  def render_event(%__MODULE__{} = renderer, %Event{} = event) do
    EventPresenter.render_event(event,
      detail: renderer.detail,
      graph: renderer.graph,
      color: renderer.color
    )
  end

  @spec render_final_report(t(), map()) :: String.t()
  def render_final_report(%__MODULE__{name: :owl} = renderer, result) when is_map(result) do
    OwlPresenter.render_final_report(result, renderer_opts(renderer))
  end

  def render_final_report(%__MODULE__{} = _renderer, result) when is_map(result) do
    EventPresenter.render_final_report(result)
  end

  @spec render_review_prompt(t(), ReviewRequest.t()) :: String.t()
  def render_review_prompt(%__MODULE__{name: :owl} = renderer, %ReviewRequest{} = request) do
    OwlPresenter.render_review_prompt(request, renderer_opts(renderer))
  end

  def render_review_prompt(%__MODULE__{} = _renderer, %ReviewRequest{} = request) do
    EventPresenter.render_review_prompt(request)
  end

  defp renderer_opts(%__MODULE__{} = renderer) do
    [
      detail: renderer.detail,
      color: renderer.color,
      theme: renderer.theme,
      unicode: renderer.unicode,
      progress: renderer.progress,
      graph: renderer.graph
    ]
  end

  defp resolve_name(:text, _opts), do: :text
  defp resolve_name(:owl, _opts), do: :owl

  defp resolve_name(:auto, opts) do
    cond do
      Keyword.get(opts, :force_text?, false) -> :text
      non_interactive_terminal?() -> :text
      true -> :owl
    end
  end

  defp non_interactive_terminal? do
    System.get_env("CI") in ["1", "true"] or
      System.get_env("TERM") in [nil, "", "dumb"] or
      not IO.ANSI.enabled?()
  end
end
