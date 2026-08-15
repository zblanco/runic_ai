defmodule RunicAIWeb.Markdown do
  @moduledoc """
  Markdown rendering boundary for web-visible agent content.

  Messages keep raw Markdown in SQLite. LiveViews render through this module so
  the parser, sanitizer, and styling stay centralized.
  """

  import Phoenix.HTML, only: [html_escape: 1, raw: 1, safe_to_string: 1]

  @mdex_options [
    extension: [
      autolink: true,
      strikethrough: true,
      table: true,
      tasklist: true
    ],
    parse: [
      smart: true
    ],
    render: [
      unsafe_: false
    ],
    syntax_highlight: [
      formatter: {:html_inline, theme: "ayu_dark"}
    ]
  ]

  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: raw("")

  def to_html(markdown) when is_binary(markdown) do
    options = Keyword.put(@mdex_options, :sanitize, MDEx.Document.default_sanitize_options())

    markdown
    |> MDEx.to_html!(options)
    |> raw()
  rescue
    _exception ->
      markdown
      |> html_escape()
      |> safe_to_string()
      |> raw()
  end
end
