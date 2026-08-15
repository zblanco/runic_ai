defmodule RunicAI.JSONValueTest do
  use ExUnit.Case, async: true

  alias RunicAI.JSONValue

  test "normalizes trusted atom keys and produces canonical JSON" do
    assert {:ok, normalized} = JSONValue.normalize(%{"a" => 1, z: [true, nil]})
    assert normalized == %{"a" => 1, "z" => [true, nil]}
    assert JSONValue.canonical_json!(normalized) == ~s({"a":1,"z":[true,null]})
  end

  test "rejects atom/string key collisions with a nested path" do
    assert {:error, [%{path: ["outer", "name"], message: "atom/string key collision"}]} =
             JSONValue.normalize(%{"outer" => %{:name => 1, "name" => 2}})
  end

  test "hashes are independent of object insertion order" do
    assert JSONValue.semantic_hash!(%{"b" => 2, "a" => 1}) ==
             JSONValue.semantic_hash!(%{"a" => 1, "b" => 2})
  end

  test "rejects structs and non-JSON terms" do
    assert {:error, [%{path: [], message: "unsupported JSON value"}]} =
             JSONValue.normalize(Date.utc_today())

    assert {:error, [%{path: [0], message: "unsupported JSON value"}]} =
             JSONValue.normalize([self()])
  end
end
