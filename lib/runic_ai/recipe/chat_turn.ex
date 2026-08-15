defmodule RunicAI.Recipe.ChatTurn do
  @moduledoc "Minimal one-generation chat-turn workflow."

  require Runic

  alias RunicAI.Component.LLMGenerate

  def new(client, opts \\ []) do
    name = Keyword.get(opts, :name, :chat_turn)
    generate_opts = Keyword.drop(opts, [:name])

    Runic.workflow(
      name: name,
      steps: [LLMGenerate.new(client, Keyword.put(generate_opts, :name, :generate))]
    )
  end
end
