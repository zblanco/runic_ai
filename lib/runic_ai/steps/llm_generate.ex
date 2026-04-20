defmodule RunicAI.Steps.LLMGenerate do
  @moduledoc """
  A Runic step that calls `RunicAI.LLM.generate_text/1`.

  ## Supported Input Shapes

  - `%RunicAI.LLM.Request{}`
  - `%RunicAI.Prompt{}`
  - a string prompt
  - a map with `:model`, `:prompt`, and optional request opts

  Step options can provide default request fields such as `:model` and `:client`,
  which makes it easier to compose behind a `PromptBuilder`.

  ## Output

  `{:ok, %RunicAI.LLM.Result{}}`, `{:retry, %RunicAI.Error{}}`, or
  `{:error, %RunicAI.Error{}}`.

  ## Example

      require Runic

      step = RunicAI.Steps.LLMGenerate.new(name: :call_llm)

      workflow = Runic.workflow(name: :gen, steps: [step])
      workflow = Runic.Workflow.react_until_satisfied(workflow, %{
        model: "anthropic:claude-haiku-4-5",
        prompt: "Hello!",
        client: &my_test_client/3
      })
  """

  require Runic

  alias RunicAI.LLM
  alias RunicAI.LLM.Request

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :llm_generate)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        with {:ok, request} <- Request.from_input(input, defaults) do
          LLM.generate_text(request)
        end
      end,
      name: name
    )
  end
end
