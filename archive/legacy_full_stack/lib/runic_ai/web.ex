defmodule RunicAI.Web do
  @moduledoc """
  Deterministic web search and extraction facade for agent tools.

  The facade keeps provider-specific search/extract details behind a small
  adapter contract so agent workflows can work with stable source records.
  """

  alias RunicAI.Error

  @type source :: %{
          optional(:title) => String.t(),
          required(:url) => String.t(),
          optional(:snippet) => String.t(),
          optional(:markdown) => String.t(),
          optional(:provider) => atom() | String.t(),
          optional(:metadata) => map()
        }

  @callback search(String.t(), map(), keyword()) :: {:ok, [source()]} | {:error, term()}
  @callback extract(String.t(), map(), keyword()) :: {:ok, source()} | {:error, term()}

  @default_provider RunicAI.Web.Providers.Static

  @spec search(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def search(query, args \\ %{}, opts \\ [])
      when is_binary(query) and is_map(args) and is_list(opts) do
    provider = Keyword.get(opts, :provider, @default_provider)
    provider_opts = Keyword.get(opts, :provider_opts, opts)
    limit = positive_integer(Map.get(args, :limit, Map.get(args, "limit", 5)), 5)

    with {:ok, sources} <- dispatch(provider, :search, [query, args, provider_opts]) do
      records =
        sources
        |> List.wrap()
        |> Enum.take(limit)
        |> Enum.map(&source_record(&1, provider))

      {:ok,
       %{
         status: :ok,
         query: query,
         provider: provider_label(provider),
         count: length(records),
         results: records,
         source_refs: Enum.map(records, & &1.source_ref)
       }}
    end
  end

  @spec extract(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def extract(url, args \\ %{}, opts \\ [])
      when is_binary(url) and is_map(args) and is_list(opts) do
    provider = Keyword.get(opts, :provider, @default_provider)
    provider_opts = Keyword.get(opts, :provider_opts, opts)

    max_bytes =
      positive_integer(Map.get(args, :max_bytes, Map.get(args, "max_bytes", 30_000)), 30_000)

    with {:ok, source} <- dispatch(provider, :extract, [url, args, provider_opts]) do
      record =
        source
        |> source_record(provider)
        |> Map.update(:markdown, nil, &truncate_binary(&1, max_bytes))
        |> Map.put(:artifact_kind, :web_source)

      {:ok,
       %{
         status: :ok,
         provider: provider_label(provider),
         source: record,
         source_ref: record.source_ref
       }}
    end
  end

  @spec html_to_markdown(String.t()) :: String.t()
  def html_to_markdown(html) when is_binary(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(?:p|div|section|article|header|footer|li|h[1-6])>/i, "\n")
    |> String.replace(~r/<h1[^>]*>(.*?)<\/h1>/is, "# \\1\n")
    |> String.replace(~r/<h2[^>]*>(.*?)<\/h2>/is, "## \\1\n")
    |> String.replace(~r/<h3[^>]*>(.*?)<\/h3>/is, "### \\1\n")
    |> String.replace(~r/<li[^>]*>(.*?)<\/li>/is, "- \\1\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> html_unescape()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec title_from_html(String.t()) :: String.t() | nil
  def title_from_html(html) when is_binary(html) do
    case Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, html, capture: :all_but_first) do
      [title] -> title |> html_unescape() |> String.trim()
      _other -> nil
    end
  end

  defp dispatch(provider, operation, args) when is_atom(provider) do
    apply(provider, operation, args)
    |> normalize_result(provider)
  rescue
    exception -> {:error, Error.from_exception(exception, source: provider)}
  end

  defp dispatch(provider, operation, args) when is_function(provider, 3) do
    apply(provider, [operation | Enum.take(args, 2)])
    |> normalize_result(:function)
  end

  defp dispatch(provider, _operation, _args) do
    {:error,
     Error.validation("web provider must be a module or function",
       source: __MODULE__,
       details: %{provider: inspect(provider)}
     )}
  end

  defp normalize_result({:ok, value}, _provider), do: {:ok, value}
  defp normalize_result({:error, %Error{} = error}, _provider), do: {:error, error}

  defp normalize_result({:error, reason}, provider),
    do: {:error, Error.from_reason(reason, source: provider)}

  defp normalize_result(value, _provider), do: {:ok, value}

  defp source_record(source, provider) when is_map(source) do
    url = Map.get(source, :url, Map.get(source, "url", "about:blank"))
    title = Map.get(source, :title, Map.get(source, "title", url))
    snippet = Map.get(source, :snippet, Map.get(source, "snippet", ""))
    markdown = Map.get(source, :markdown, Map.get(source, "markdown"))
    fetched_at = Map.get(source, :fetched_at, Map.get(source, "fetched_at", DateTime.utc_now()))

    source_provider =
      Map.get(source, :provider, Map.get(source, "provider", provider_label(provider)))

    %{
      title: title,
      url: url,
      snippet: snippet,
      markdown: markdown,
      provider: source_provider,
      fetched_at: datetime_iso(fetched_at),
      source_ref: "web:#{Base.url_encode64(:crypto.hash(:sha256, url), padding: false)}",
      metadata: Map.get(source, :metadata, Map.get(source, "metadata", %{}))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp source_record(source, provider) when is_binary(source) do
    source_record(%{url: source, title: source}, provider)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp truncate_binary(nil, _max_bytes), do: nil

  defp truncate_binary(binary, max_bytes)
       when is_binary(binary) and byte_size(binary) > max_bytes,
       do: binary_part(binary, 0, max_bytes)

  defp truncate_binary(binary, _max_bytes), do: binary

  defp provider_label(provider) when is_atom(provider),
    do: provider |> Module.split() |> List.last() |> Macro.underscore()

  defp provider_label(_provider), do: :function

  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso(value), do: value

  defp html_unescape(value) do
    value
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end
end
