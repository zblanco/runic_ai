defmodule RunicAI.Steps.PromptBuilder do
  @moduledoc """
  A Runic step that assembles a `%RunicAI.Prompt{}` from parts.

  ## Input

  A map with:
  - `:system` — (optional) system prompt string
  - `:user` — user message string
  - `:history` — (optional) list of existing `RunicAI.Message` or `ReqLLM.Message` values

  ## Output

  A `%RunicAI.Prompt{}` ready to pass to an LLM step.

  ## Example

      require Runic

      step = RunicAI.Steps.PromptBuilder.new(name: :build_prompt)

      workflow = Runic.workflow(name: :build, steps: [step])
      workflow = Runic.Workflow.react_until_satisfied(workflow, %{
        system: "You are a helpful assistant",
        user: "What is Elixir?"
      })
  """

  require Runic

  alias RunicAI.Message
  alias RunicAI.Prompt

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :prompt_builder)

    Runic.step(
      fn input ->
        history =
          input
          |> Map.get(:history, [])
          |> normalize_history!()

        system = Map.get(input, :system)
        user = Map.get(input, :user, "")

        messages =
          []
          |> maybe_append_system(system)
          |> Kernel.++(history)
          |> maybe_append_user(user)

        Prompt.new!(messages)
      end,
      name: name
    )
  end

  defp maybe_append_system(messages, nil), do: messages
  defp maybe_append_system(messages, ""), do: messages

  defp maybe_append_system(messages, system) do
    messages ++ [Message.new!(:system, system)]
  end

  defp maybe_append_user(messages, ""), do: messages

  defp maybe_append_user(messages, user) do
    messages ++ [Message.new!(:user, user)]
  end

  defp normalize_history!(history) do
    case Message.normalize_list(history) do
      {:ok, messages} -> messages
      {:error, error} -> raise ArgumentError, error.message
    end
  end
end
