defmodule RunicAI.Coding.PersistenceTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Persistence
  alias RunicAI.Coding.Persistence.ETS
  alias RunicAI.Coding.Persistence.InMemory
  alias RunicAI.Coding.Persistence.SQLite

  test "in-memory persistence stores artifacts and events" do
    {:ok, store} = InMemory.start_link()

    assert {:ok, ref} =
             Persistence.put_artifact({InMemory, store}, %{
               content: "hello",
               sha256: "abc",
               metadata: %{kind: :test}
             })

    assert ref == "mem:abc"
    assert {:ok, artifact} = Persistence.get_artifact({InMemory, store}, ref)
    assert artifact.content == "hello"

    assert :ok = Persistence.record_event({InMemory, store}, %{kind: :coding_command})
    assert [%{kind: :coding_command}] = InMemory.events(store)
  end

  test "ETS persistence stores artifacts and events" do
    {:ok, store} = ETS.start_link()

    assert {:ok, ref} =
             Persistence.put_artifact({ETS, store}, %{
               content: "hello",
               sha256: "abc",
               metadata: %{kind: :test}
             })

    assert ref == "ets:abc"
    assert {:ok, artifact} = Persistence.get_artifact({ETS, store}, ref)
    assert artifact.content == "hello"

    assert :ok = Persistence.record_event({ETS, store}, %{kind: :rlm_coding_checkpoint})
    assert [%{kind: :rlm_coding_checkpoint}] = ETS.events(store)
  end

  test "SQLite persistence is optional but usable when exqlite is available" do
    if SQLite.available?() do
      {:ok, conn} = SQLite.open(":memory:")
      on_exit(fn -> SQLite.close(conn) end)

      assert {:ok, 1} = SQLite.schema_version(conn)

      assert {:ok, ref} =
               SQLite.put_artifact(conn, %{
                 content: "payload",
                 sha256: "def",
                 metadata: %{kind: :sqlite_test}
               })

      assert ref == "sqlite:def"
      assert {:ok, artifact} = SQLite.get_artifact(conn, ref)
      assert artifact.content == "payload"

      assert :ok =
               SQLite.record_event(conn, %{
                 kind: :coding_command,
                 status: :pass,
                 metadata: %{artifact_ref: ref}
               })

      assert {:ok, [%{kind: :coding_command, status: :pass}]} = SQLite.events(conn)
    else
      assert {:error, error} = SQLite.open(":memory:")
      assert error.kind == :unsupported
    end
  end
end
