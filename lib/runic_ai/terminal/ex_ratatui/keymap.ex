defmodule RunicAI.Terminal.ExRatatui.Keymap do
  @moduledoc """
  Keyboard mapping for the ExRatatui workbench.
  """

  alias ExRatatui.Event.Key
  alias ExRatatui.Event.Mouse

  @spec event_to_action(term()) :: term()
  def event_to_action(event), do: event_to_action(event, %{})

  @spec event_to_action(term(), map()) :: term()
  def event_to_action(%Key{code: "c", kind: "press", modifiers: modifiers}, _context) do
    if "ctrl" in modifiers,
      do: :quit,
      else: {:text_key, %Key{code: "c", kind: "press", modifiers: modifiers}}
  end

  def event_to_action(%Key{code: "s", kind: "press", modifiers: modifiers}, _context) do
    if "ctrl" in modifiers,
      do: :stop,
      else: {:text_key, %Key{code: "s", kind: "press", modifiers: modifiers}}
  end

  def event_to_action(%Key{code: "q", kind: "press", modifiers: modifiers}, _context) do
    if "ctrl" in modifiers,
      do: :quit,
      else: {:text_key, %Key{code: "q", kind: "press", modifiers: modifiers}}
  end

  def event_to_action(%Key{code: "tab", kind: "press"}, %{slash_mode?: true}),
    do: {:complete_suggestion, :next}

  def event_to_action(%Key{code: "back_tab", kind: "press"}, %{slash_mode?: true}),
    do: {:complete_suggestion, :prev}

  def event_to_action(%Key{code: "tab", kind: "press"}, _context), do: {:focus, :next}
  def event_to_action(%Key{code: "back_tab", kind: "press"}, _context), do: {:focus, :prev}
  def event_to_action(%Key{code: "f2", kind: "press"}, _context), do: :toggle_view

  def event_to_action(%Key{code: "page_up", kind: "press"}, %{view_mode: :chat}),
    do: {:scroll_conversation, :page_up}

  def event_to_action(%Key{code: "page_down", kind: "press"}, %{view_mode: :chat}),
    do: {:scroll_conversation, :page_down}

  def event_to_action(%Key{code: "home", kind: "press"}, %{focus: :conversation}),
    do: {:scroll_conversation, :home}

  def event_to_action(%Key{code: "end", kind: "press"}, %{focus: :conversation}),
    do: {:scroll_conversation, :end}

  def event_to_action(%Key{code: "up", kind: "press"}, %{focus: :conversation}),
    do: {:scroll_conversation, :up}

  def event_to_action(%Key{code: "down", kind: "press"}, %{focus: :conversation}),
    do: {:scroll_conversation, :down}

  def event_to_action(%Key{code: "up", kind: "press"}, %{focus: :composer, slash_mode?: false}),
    do: {:composer_history, :prev}

  def event_to_action(%Key{code: "down", kind: "press"}, %{focus: :composer, slash_mode?: false}),
    do: {:composer_history, :next}

  def event_to_action(%Key{code: "up", kind: "press"}, _context), do: {:move, -1}
  def event_to_action(%Key{code: "down", kind: "press"}, _context), do: {:move, 1}

  def event_to_action(
        %Key{code: "enter", kind: "press", modifiers: modifiers} = key,
        %{focus: :composer, slash_mode?: false}
      ) do
    if "shift" in modifiers, do: {:text_key, key}, else: :submit
  end

  def event_to_action(%Key{code: "enter", kind: "press"}, _context), do: :submit
  def event_to_action(%Key{code: "esc", kind: "press"}, _context), do: :cancel

  def event_to_action(%Key{code: "/", kind: "press"}, %{slash_mode?: false, composer_empty?: true}),
      do: :slash_mode

  def event_to_action(%Key{} = key, _context), do: {:text_key, key}

  def event_to_action(%Mouse{kind: "scroll_up"}, %{view_mode: :chat}),
    do: {:scroll_conversation, :up}

  def event_to_action(%Mouse{kind: "scroll_down"}, %{view_mode: :chat}),
    do: {:scroll_conversation, :down}

  def event_to_action(_event, _context), do: :ignore
end
