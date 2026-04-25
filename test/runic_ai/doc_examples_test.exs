defmodule RunicAI.DocExamplesTest do
  use ExUnit.Case, async: true

  describe "README quick start examples" do
    test "direct LLM call with an injected fake client" do
      client = fn _model, _prompt, _opts ->
        result =
          RunicAI.LLM.Result.new!(
            RunicAI.Message.new!(:assistant, "hello from a fake model"),
            finish_reason: :stop
          )

        {:ok, result}
      end

      assert {:ok, result} =
               RunicAI.LLM.generate_text(
                 "test:model",
                 "Say hello",
                 client: client
               )

      assert RunicAI.LLM.Result.text(result) == "hello from a fake model"
    end

    test "chat agent kernel with an injected fake client" do
      require Runic

      alias Runic.Workflow
      alias RunicAI.Recipes.ChatAgentKernel

      client = fn _model, _prompt, _opts ->
        result =
          RunicAI.LLM.Result.new!(
            RunicAI.Message.new!(:assistant, "hello from the guide"),
            finish_reason: :stop,
            usage: %{input_tokens: 3, output_tokens: 4, total_tokens: 7}
          )

        {:ok, result}
      end

      workflow =
        ChatAgentKernel.new(
          model: "test:model",
          system: "You are concise.",
          client: client
        )
        |> Workflow.react_until_satisfied(%{user: "Say hello."})

      assert ChatAgentKernel.latest_reply_text(workflow) == "hello from the guide"
    end
  end
end
