defmodule RunicAI.Web.Providers.Static do
  @moduledoc """
  Static web provider used for tests, fixtures, and offline workflows.
  """

  @behaviour RunicAI.Web

  alias RunicAI.Error
  alias RunicAI.Web

  @impl true
  def search(query, _args, opts) when is_binary(query) and is_list(opts) do
    sources = Keyword.get(opts, :sources, [])
    normalized_query = String.downcase(query)

    results =
      sources
      |> Enum.map(&normalize_source/1)
      |> Enum.filter(&matches?(&1, normalized_query))

    {:ok, results}
  end

  @impl true
  def extract(url, args, opts) when is_binary(url) and is_map(args) and is_list(opts) do
    cond do
      html = arg(args, :html, nil) ->
        {:ok, html_source(url, html)}

      markdown = arg(args, :markdown, nil) ->
        {:ok,
         %{
           url: url,
           title: arg(args, :title, url),
           markdown: markdown,
           snippet: snippet(markdown)
         }}

      source = find_source(url, Keyword.get(opts, :sources, [])) ->
        {:ok, ensure_markdown(source)}

      String.starts_with?(url, "file://") ->
        extract_file(String.replace_prefix(url, "file://", ""))

      true ->
        {:error,
         Error.validation("static web provider cannot extract unknown URL",
           source: __MODULE__,
           details: %{url: url}
         )}
    end
  end

  defp find_source(url, sources) do
    sources
    |> Enum.map(&normalize_source/1)
    |> Enum.find(&(Map.get(&1, :url) == url))
  end

  defp normalize_source(source) when is_map(source) do
    %{
      title: field(source, :title),
      url: field(source, :url),
      snippet: field(source, :snippet),
      markdown: field(source, :markdown),
      html: field(source, :html),
      provider: field(source, :provider),
      metadata: field(source, :metadata) || %{}
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_source(url) when is_binary(url), do: %{url: url, title: url, snippet: ""}

  defp matches?(source, query) do
    [source[:title], source[:url], source[:snippet], source[:markdown]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&String.contains?(&1, query))
  end

  defp ensure_markdown(%{markdown: markdown} = source) when is_binary(markdown), do: source

  defp ensure_markdown(%{html: html} = source) when is_binary(html),
    do: html_source(source.url, html, source)

  defp ensure_markdown(%{snippet: snippet} = source),
    do: Map.put(source, :markdown, snippet || "")

  defp ensure_markdown(source), do: Map.put(source, :markdown, "")

  defp html_source(url, html, source \\ %{}) do
    markdown = Web.html_to_markdown(html)

    %{
      url: url,
      title: Map.get(source, :title) || Web.title_from_html(html) || url,
      snippet: Map.get(source, :snippet) || snippet(markdown),
      markdown: markdown,
      provider: :static
    }
  end

  defp extract_file(path) do
    case File.read(path) do
      {:ok, html} ->
        {:ok, html_source("file://#{path}", html, %{title: Path.basename(path)})}

      {:error, reason} ->
        {:error,
         Error.validation("static web provider could not read file URL",
           source: __MODULE__,
           details: %{path: path, reason: reason}
         )}
    end
  end

  defp snippet(markdown) when is_binary(markdown) do
    markdown
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 300)
  end

  defp arg(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
