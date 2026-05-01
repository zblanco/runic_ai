defmodule RunicAI.Terminal.Theme do
  @moduledoc """
  Semantic terminal styling for RunicAI presentation layers.

  The Runic theme starts with the palette captured in `.docs/DESIGN.md`. The
  module keeps color choices centralized so CLI, Owl, and future TUI renderers
  can share the same semantic tokens.
  """

  alias RunicAI.Terminal.Event

  @type theme :: :runic | :plain
  @type color_mode :: :auto | :always | :never
  @type token ::
          :bg
          | :surface
          | :surface_elevated
          | :border
          | :text
          | :text_soft
          | :muted
          | :heading
          | :primary
          | :primary_soft
          | :focus
          | :gold
          | :bronze
          | :purple
          | :magenta
          | :success
          | :warning
          | :error
          | :info
          | :review
          | :rlm
          | :tool
          | :verification
          | :repair
          | :dim

  @hex %{
    bg: "#0B0D10",
    surface: "#13110E",
    surface_elevated: "#1D1812",
    border: "#5C4A32",
    text: "#E7D6B7",
    text_soft: "#C7B28A",
    muted: "#7C6D58",
    heading: "#F3C65F",
    primary: "#62F5D4",
    primary_soft: "#A6FFE9",
    focus: "#62F5D4",
    gold: "#F3C65F",
    bronze: "#B77A35",
    purple: "#A78BFA",
    magenta: "#FF5CCB",
    success: "#66E889",
    warning: "#F6A94D",
    error: "#FF5C73",
    info: "#6BB6FF",
    review: "#FF5CCB",
    rlm: "#A78BFA",
    tool: "#F3C65F",
    verification: "#66E889",
    repair: "#F6A94D",
    dim: "#7C6D58"
  }

  @bunt %{
    bg: :black,
    surface: :dimgray,
    surface_elevated: :chocolate,
    border: :goldenrod,
    text: :beige,
    text_soft: :khaki,
    muted: :dimgray,
    heading: [:bright, :gold],
    primary: :aquamarine,
    primary_soft: :lightcyan,
    focus: [:bright, :aqua],
    gold: :gold,
    bronze: :goldenrod,
    purple: :darkmagenta,
    magenta: :fuchsia,
    success: :springgreen,
    warning: :orange,
    error: :orangered,
    info: :deepskyblue,
    review: :fuchsia,
    rlm: :darkmagenta,
    tool: :gold,
    verification: :springgreen,
    repair: :orange,
    dim: :dimgray
  }

  @owl %{
    bg: :black,
    surface: :black_background,
    surface_elevated: :black_background,
    border: :yellow,
    text: :yellow,
    text_soft: :yellow,
    muted: :light_black,
    heading: [:bright, :yellow],
    primary: :cyan,
    primary_soft: [:bright, :cyan],
    focus: [:bright, :cyan],
    gold: [:bright, :yellow],
    bronze: :yellow,
    purple: :magenta,
    magenta: [:bright, :magenta],
    success: :green,
    warning: :yellow,
    error: :red,
    info: :blue,
    review: [:bright, :magenta],
    rlm: :magenta,
    tool: [:bright, :yellow],
    verification: :green,
    repair: :yellow,
    dim: :light_black
  }

  @spec format(IO.chardata(), token(), keyword()) :: String.t()
  def format(data, token, opts \\ []) do
    theme = Keyword.get(opts, :theme, :runic)
    color = Keyword.get(opts, :color, :auto)
    text = IO.chardata_to_string(data)

    case theme do
      :plain ->
        text

      :runic ->
        [bunt_sequence(token), text, :reset]
        |> Bunt.ANSI.format(emit?(color))
        |> IO.iodata_to_binary()
    end
  end

  @spec plain(IO.chardata()) :: String.t()
  def plain(data), do: IO.chardata_to_string(data)

  @spec ansi_fragment(token(), keyword()) :: String.t()
  def ansi_fragment(token, opts \\ []) do
    color = Keyword.get(opts, :color, :auto)

    token
    |> bunt_sequence()
    |> List.wrap()
    |> Bunt.ANSI.format(emit?(color))
    |> IO.iodata_to_binary()
  end

  @spec owl_tag(Owl.Data.t(), token(), keyword()) :: Owl.Data.t()
  def owl_tag(data, token, opts \\ []) do
    if Keyword.get(opts, :theme, :runic) == :plain do
      data
    else
      Owl.Data.tag(data, owl_sequence(token))
    end
  end

  @spec style_attrs(token()) :: map()
  def style_attrs(token) do
    %{
      token: token,
      hex: Map.fetch!(@hex, token),
      bunt: bunt_sequence(token),
      owl: owl_sequence(token)
    }
  end

  @spec token_for(Event.t()) :: token()
  def token_for(%Event{status: :error}), do: :error
  def token_for(%Event{status: :review}), do: :review
  def token_for(%Event{status: :waiting}), do: :warning
  def token_for(%Event{status: :blocked}), do: :warning
  def token_for(%Event{status: :running}), do: :primary
  def token_for(%Event{kind: :tool}), do: :tool
  def token_for(%Event{kind: :hitl}), do: :review
  def token_for(%Event{kind: :rlm_plan}), do: :rlm
  def token_for(%Event{kind: :rlm_node}), do: :rlm
  def token_for(%Event{kind: :verification}), do: :verification
  def token_for(%Event{kind: :repair}), do: :repair
  def token_for(%Event{kind: :error}), do: :error
  def token_for(%Event{kind: :summary}), do: :heading
  def token_for(%Event{}), do: :text

  @spec color_enabled?(color_mode()) :: boolean()
  def color_enabled?(color), do: emit?(color)

  defp emit?(:always), do: true
  defp emit?(:never), do: false

  defp emit?(:auto) do
    System.get_env("NO_COLOR") in [nil, ""] and Bunt.ANSI.enabled?()
  end

  defp emit?(_other), do: false

  defp bunt_sequence(token), do: Map.fetch!(@bunt, token)
  defp owl_sequence(token), do: Map.fetch!(@owl, token)
end
