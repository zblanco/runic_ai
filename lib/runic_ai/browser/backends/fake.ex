defmodule RunicAI.Browser.Backends.Fake do
  @moduledoc """
  Deterministic browser backend for tests and offline contract validation.
  """

  @behaviour RunicAI.Browser.Backend

  @impl true
  def init(opts) do
    {:ok,
     %{
       url: Keyword.get(opts, :url, "about:blank"),
       title: Keyword.get(opts, :title, "Fake Browser"),
       html:
         Keyword.get(opts, :html, "<html><title>Fake Browser</title><button>OK</button></html>"),
       console: Keyword.get(opts, :console, []),
       actions: []
     }}
  end

  @impl true
  def navigate(state, url, _args) do
    html = Map.get(state, :pages, %{}) |> Map.get(url, state.html)
    state = %{state | url: url, html: html, actions: [{:navigate, url} | state.actions]}
    {:ok, state, observation(state, :navigated)}
  end

  @impl true
  def snapshot(state, _args), do: {:ok, state, observation(state, :snapshot)}

  @impl true
  def click(state, selector, _args) do
    state = %{state | actions: [{:click, selector} | state.actions]}
    {:ok, state, observation(state, :clicked) |> Map.put(:selector, selector)}
  end

  @impl true
  def type(state, selector, text, _args) do
    state = %{state | actions: [{:type, selector, text} | state.actions]}
    {:ok, state, observation(state, :typed) |> Map.merge(%{selector: selector, text: text})}
  end

  @impl true
  def press(state, key, _args) do
    state = %{state | actions: [{:press, key} | state.actions]}
    {:ok, state, observation(state, :pressed) |> Map.put(:key, key)}
  end

  @impl true
  def scroll(state, args) do
    direction = Map.get(args, :direction, Map.get(args, "direction", "down"))
    state = %{state | actions: [{:scroll, direction} | state.actions]}
    {:ok, state, observation(state, :scrolled) |> Map.put(:direction, direction)}
  end

  @impl true
  def console(state, _args) do
    {:ok, state,
     %{status: :ok, url: state.url, events: state.console, count: length(state.console)}}
  end

  @impl true
  def screenshot(state, _args) do
    {:ok, state,
     %{
       status: :ok,
       url: state.url,
       media_type: "image/png",
       image: fake_png(),
       byte_size: byte_size(fake_png())
     }}
  end

  @impl true
  def close(_state), do: :ok

  defp observation(state, action) do
    snapshot = html_snapshot(state.html)

    %{
      status: :ok,
      action: action,
      url: state.url,
      title: title(state),
      snapshot: snapshot,
      refs: refs(snapshot),
      console_count: length(state.console)
    }
  end

  defp title(%{html: html, title: fallback}) do
    RunicAI.Web.title_from_html(html) || fallback
  end

  defp html_snapshot(html) do
    html
    |> RunicAI.Web.html_to_markdown()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, index} -> "[ref=e#{index}] #{line}" end)
    |> Enum.join("\n")
  end

  defp refs(snapshot) do
    Regex.scan(~r/\[ref=(e\d+)\]\s*(.+)/, snapshot)
    |> Enum.map(fn [_match, ref, label] -> {ref, %{label: label}} end)
    |> Map.new()
  end

  defp fake_png do
    <<137, 80, 78, 71, 13, 10, 26, 10>>
  end
end
