defmodule RunicAI.Terminal.RendererTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Renderer

  test "auto renderer can be forced to text for non-TTY capture" do
    {:ok, options} = CliOptions.parse(["summarize", "--cwd", File.cwd!(), "--renderer", "auto"])

    renderer = Renderer.new(options, force_text?: true)

    assert renderer.name == :text
  end
end
