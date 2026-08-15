defmodule RunicAI.PackageBoundaryTest do
  use ExUnit.Case, async: true

  test "the library has no application callback or supervised children" do
    application = Application.spec(:runic_ai)
    applications = application[:applications]

    assert application[:mod] == []

    assert Enum.all?(
             [:kernel, :stdlib, :elixir, :logger, :runic, :req_llm, :jason, :zoi],
             &(&1 in applications)
           )

    refute Enum.any?(
             [:phoenix, :ecto, :ecto_sql, :ecto_sqlite3, :bandit],
             &(&1 in applications)
           )
  end

  test "the legacy archive is not compiled" do
    refute Code.ensure_loaded?(RunicAIWeb.Endpoint)
    refute Code.ensure_loaded?(RunicAI.Workbench)
    refute Code.ensure_loaded?(RunicAI.Persistence.SQLite)
  end
end
