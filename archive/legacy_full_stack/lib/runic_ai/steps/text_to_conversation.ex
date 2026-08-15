defmodule RunicAI.Steps.TextToConversation do
  @moduledoc """
  A Runic step that converts text exchanges into normalized `RunicAI.Message` values.

  Useful for seeding conversation history from a user prompt + assistant
  response pair, or from a flat list of alternating role/text tuples.

  ## Input Formats

  **Pair format** — a map with `:user` and `:assistant` strings:

      %{user: "Hello", assistant: "Hi there!"}

  **List format** — a list of `{role, text}` tuples:

      %{turns: [{:user, "Hello"}, {:assistant, "Hi!"}, {:user, "How are you?"}]}

  ## Output

  A list of `%RunicAI.Message{}` values.
  """

  require Runic

  alias RunicAI.Message

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :text_to_conversation)

    Runic.step(
      fn input ->
        build_context(input)
      end,
      name: name
    )
  end

  defp build_context(%{turns: turns}) when is_list(turns) do
    Enum.map(turns, fn {role, text} -> Message.new!(role, text) end)
  end

  defp build_context(%{user: user, assistant: assistant}) do
    [
      Message.new!(:user, user),
      Message.new!(:assistant, assistant)
    ]
  end

  defp build_context(%{messages: messages}) when is_list(messages) do
    case Message.normalize_list(messages) do
      {:ok, normalized_messages} -> normalized_messages
      {:error, error} -> raise ArgumentError, error.message
    end
  end
end
