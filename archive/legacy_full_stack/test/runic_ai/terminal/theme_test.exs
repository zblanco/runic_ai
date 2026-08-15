defmodule RunicAI.Terminal.ThemeTest do
  use ExUnit.Case, async: false

  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.Theme

  test "formats Runic colors and can disable color" do
    assert Theme.format("active", :primary, color: :always) =~ "\e["
    assert Theme.format("active", :primary, color: :never) == "active"
    assert Theme.format("active", :primary, theme: :plain, color: :always) == "active"
  end

  test "auto color respects NO_COLOR" do
    previous = System.get_env("NO_COLOR")
    System.put_env("NO_COLOR", "1")

    try do
      assert Theme.format("active", :primary, color: :auto) == "active"
    after
      if previous do
        System.put_env("NO_COLOR", previous)
      else
        System.delete_env("NO_COLOR")
      end
    end
  end

  test "maps event status and kind to semantic tokens" do
    review = Event.new!(:hitl, status: :review, title: "Review", data: %{})
    tool = Event.new!(:tool, status: :ok, title: "Tool", data: %{})
    error = Event.new!(:message, status: :error, title: "Error", data: %{})

    assert Theme.token_for(review) == :review
    assert Theme.token_for(tool) == :tool
    assert Theme.token_for(error) == :error
  end

  test "exposes style attributes for future renderers" do
    attrs = Theme.style_attrs(:primary)

    assert attrs.hex == "#62F5D4"
    assert attrs.token == :primary
    assert attrs.bunt in [:aquamarine, [:bright, :aqua]]
  end

  test "raises a useful error for unknown theme tokens" do
    assert_raise ArgumentError, ~r/unknown terminal theme token :bogus/, fn ->
      Theme.style_attrs(:bogus)
    end

    assert_raise ArgumentError, ~r/valid tokens:/, fn ->
      Theme.format("bad", :bogus, color: :never)
    end
  end
end
