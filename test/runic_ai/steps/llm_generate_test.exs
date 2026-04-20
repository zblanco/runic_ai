defmodule RunicAI.Steps.LLMGenerateTest do
  use ExUnit.Case, async: true

  require Runic
  alias Runic.Workflow
  alias RunicAI.LLM.Result
  alias RunicAI.LLM.TestClient
  alias RunicAI.Message
  alias RunicAI.Prompt

  describe "LLMGenerate step" do
    test "calls generate_text with a function client" do
      step = RunicAI.Steps.LLMGenerate.new(name: :gen)

      workflow = Runic.workflow(name: :test_gen, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          model: "test:fake",
          prompt: "What is Elixir?",
          client: TestClient.client("Elixir is a functional language.")
        })

      [{:ok, result}] = Workflow.raw_productions(workflow)
      assert %Result{} = result
      assert Result.text(result) == "Elixir is a functional language."
    end

    test "can consume a prompt directly when configured with model defaults" do
      step =
        RunicAI.Steps.LLMGenerate.new(
          name: :gen,
          model: "test:fake",
          client: TestClient
        )

      workflow = Runic.workflow(name: :test_gen2, steps: [step])

      prompt = Prompt.new!([Message.new!(:user, "Hello")])

      workflow =
        Workflow.react_until_satisfied(workflow, prompt)

      [{:ok, result}] = Workflow.raw_productions(workflow)
      assert Result.text(result) =~ "I received: Hello"
    end

    test "forwards extra keys as opts" do
      client = fn _model, _prompt, opts ->
        {:ok, TestClient.result("max=#{opts[:max_tokens]}")}
      end

      step = RunicAI.Steps.LLMGenerate.new(name: :gen)

      workflow = Runic.workflow(name: :test_opts, steps: [step])

      workflow =
        Workflow.react_until_satisfied(workflow, %{
          model: "test:fake",
          prompt: "Hi",
          client: client,
          max_tokens: 100
        })

      [{:ok, result}] = Workflow.raw_productions(workflow)
      assert Result.text(result) == "max=100"
    end
  end
end
