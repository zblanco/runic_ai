defmodule RunicAI.Coding.PatchTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.Patch
  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace

  test "creates, updates, moves, and deletes files with hash metadata" do
    workspace = Workspace.new!(root: tmp_dir())

    create =
      Patch.apply_patch(workspace, %{
        operations: [%{op: "create", path: "lib/demo.ex", content: "one\n"}]
      })

    assert create.status == :ok
    assert File.read!(Path.join(workspace.root, "lib/demo.ex")) == "one\n"
    hash = create.after_hashes["lib/demo.ex"]

    update =
      Patch.apply_patch(workspace, %{
        operations: [%{op: :update, path: "lib/demo.ex", content: "two\n", expected_hash: hash}]
      })

    assert update.status == :ok
    assert update.before_hashes["lib/demo.ex"] == hash

    move =
      Patch.apply_patch(workspace, %{
        operations: [%{op: :move, from: "lib/demo.ex", to: "lib/moved.ex"}]
      })

    assert move.status == :ok
    assert File.exists?(Path.join(workspace.root, "lib/moved.ex"))

    delete =
      Patch.apply_patch(workspace, %{
        operations: [%{op: :delete, path: "lib/moved.ex"}]
      })

    assert delete.status == :ok
    refute File.exists?(Path.join(workspace.root, "lib/moved.ex"))
  end

  test "reports repairable hash mismatch diagnostics" do
    root = tmp_dir()
    File.write!(Path.join(root, "demo.txt"), "old\n")
    workspace = Workspace.new!(root: root)

    result =
      Patch.apply_patch(workspace, %{
        operations: [
          %{op: :update, path: "demo.txt", content: "new\n", expected_hash: "not-the-hash"}
        ]
      })

    assert result.status == :error
    assert [%{message: message, details: details}] = result.diagnostics
    assert message =~ "expected hash"
    assert details.actual_hash
    assert File.read!(Path.join(root, "demo.txt")) == "old\n"
  end

  test "supports fake bad-patch replay into a corrected patch" do
    root = tmp_dir()
    File.write!(Path.join(root, "demo.txt"), "old\n")
    workspace = Workspace.new!(root: root)

    bad =
      Patch.apply_patch(workspace, %{
        operations: [
          %{op: :update, path: "demo.txt", content: "new\n", expected_hash: "stale"}
        ]
      })

    assert bad.status == :error
    assert [%{details: %{actual_hash: actual_hash}}] = bad.diagnostics

    corrected =
      Patch.apply_patch(workspace, %{
        operations: [
          %{op: :update, path: "demo.txt", content: "new\n", expected_hash: actual_hash}
        ]
      })

    assert corrected.status == :ok
    assert File.read!(Path.join(root, "demo.txt")) == "new\n"
  end

  test "accepts standard text patch strings for model-friendly updates" do
    root = tmp_dir()
    File.write!(Path.join(root, "demo.txt"), "one\ntwo\nthree\n")
    workspace = Workspace.new!(root: root)

    result =
      Patch.apply_patch(workspace, %{
        operations: """
        *** Begin Patch
        *** Update File: demo.txt
        @@
         one
        -two
        +TWO
         three
        *** End Patch
        """
      })

    assert result.status == :ok
    assert result.changed_paths == ["demo.txt"]
    assert File.read!(Path.join(root, "demo.txt")) == "one\nTWO\nthree\n"
  end

  test "rejects under-escaped Elixir default arguments before writing" do
    workspace = Workspace.new!(root: tmp_dir())

    result =
      Patch.apply_patch(workspace, %{
        operations: [
          %{
            op: :create,
            path: "lib/demo.ex",
            content: ~S"""
            defmodule Demo do
              def start_link(_opts \ []) do
                :ok
              end
            end
            """
          }
        ]
      })

    assert result.status == :error
    assert [%{message: message, details: details}] = result.diagnostics
    assert message =~ "single backslash"
    assert details.guidance =~ "explicit function clauses"
    refute File.exists?(Path.join(workspace.root, "lib/demo.ex"))
  end

  test "supports dry-run without mutating files" do
    workspace = Workspace.new!(root: tmp_dir())

    result =
      Patch.apply_patch(
        workspace,
        %{operations: [%{op: :create, path: "demo.txt", content: "hello\n"}]},
        dry_run?: true
      )

    assert result.status == :dry_run
    refute File.exists?(Path.join(workspace.root, "demo.txt"))
  end

  test "enforces root jail and write policy" do
    workspace =
      Workspace.new!(
        root: tmp_dir(),
        path_policy: PathPolicy.new!(hidden_policy: :read_only)
      )

    outside =
      Patch.apply_patch(workspace, %{
        operations: [%{op: :create, path: "../outside.txt", content: "no\n"}]
      })

    hidden =
      Patch.apply_patch(workspace, %{
        operations: [%{op: :create, path: ".hidden", content: "no\n"}]
      })

    assert outside.status == :error
    assert hidden.status == :error
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
