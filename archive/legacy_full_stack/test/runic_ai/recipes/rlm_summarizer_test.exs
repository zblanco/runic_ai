defmodule RunicAI.Recipes.RLMSummarizerTest do
  use ExUnit.Case, async: true

  alias RunicAI.Recipes.RLMSummarizer
  alias RunicAI.RLM

  test "splits, materializes, maps leaves, and reduces a summary" do
    {:ok, environment} = RLM.init_environment()

    {:ok, source_ref, environment} =
      RLM.put_source(environment, "alpha beta gamma delta epsilon zeta", id: "doc")

    workflow =
      RLMSummarizer.react_until_resolution(
        [
          chunk_size: 12,
          mapper: fn artifact -> "summary(" <> String.trim(artifact.content) <> ")" end,
          reducer: fn results -> Enum.map_join(results, " | ", & &1.output) end
        ],
        %{environment: environment, source_ref: source_ref}
      )

    assert RLMSummarizer.latest_output(workflow) ==
             "summary(alpha beta g) | summary(amma delta e) | summary(psilon zeta)"
  end
end
