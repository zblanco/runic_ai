defmodule RunicAI.LLM.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias RunicAI.LLM.ModelCatalog

  test "catalog exposes ReqLLM text-generation models grouped by provider" do
    catalog = ModelCatalog.catalog()

    assert catalog.default_provider == "openai"
    assert catalog.default_model_id == "gpt-5.4-mini"
    assert catalog.default_model == "openai:gpt-5.4-mini"

    openai = Enum.find(catalog.providers, &(&1.id == "openai"))

    assert openai
    assert Enum.any?(openai.models, &(&1.id == "gpt-5.4-mini"))
    refute Enum.any?(openai.models, &(&1.id == "text-embedding-3-large"))
  end
end
