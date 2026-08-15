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

  test "reconciles a create after an unknown completion without touching the file" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)
    patch = %{operations: [%{op: :create, path: "result.txt", content: "done\n"}]}

    first = Patch.apply_patch(workspace, patch)
    assert first.status == :ok

    path = Path.join(root, "result.txt")
    mtime = File.stat!(path).mtime

    replay =
      Patch.reconcile_after_unknown(workspace, patch, %{
        attempt: 2,
        prior_attempt_id: "patch-attempt-1",
        prior_outcome: :unknown_after_dispatch
      })

    assert replay.status == :reconciled
    assert replay.metadata.reconciliation.outcome == :matched_after_state
    assert replay.metadata.reconciliation.prior_attempt_id == "patch-attempt-1"

    assert [%{reconciliation_outcome: :matched_after_state, physically_changed?: false}] =
             replay.operation_summaries

    assert File.read!(path) == "done\n"
    assert File.stat!(path).mtime == mtime
  end

  test "replay applies only operations missing after a partial unknown attempt" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)

    first_content = "first\n"
    second_before = "before\n"
    File.write!(Path.join(root, "first.txt"), first_content)
    File.write!(Path.join(root, "second.txt"), second_before)

    patch = %{
      operations: [
        %{
          op: :update,
          path: "first.txt",
          content: "after-first\n",
          expected_hash: Patch.sha256(first_content)
        },
        %{
          op: :update,
          path: "second.txt",
          content: "after-second\n",
          expected_hash: Patch.sha256(second_before)
        }
      ]
    }

    first_only = %{patch | operations: [hd(patch.operations)]}
    assert Patch.apply_patch(workspace, first_only).status == :ok
    first_mtime = File.stat!(Path.join(root, "first.txt")).mtime

    replay =
      Patch.reconcile_after_unknown(workspace, patch, %{
        attempt: 2,
        prior_attempt_id: "partial-attempt-1",
        prior_outcome: "unknown_after_dispatch"
      })

    assert replay.status == :ok
    assert replay.metadata.reconciliation.outcome == :partially_reconciled
    assert replay.metadata.reconciliation.reconciled_operations == 1
    assert replay.metadata.reconciliation.applied_operations == 1
    assert File.stat!(Path.join(root, "first.txt")).mtime == first_mtime
    assert File.read!(Path.join(root, "second.txt")) == "after-second\n"
  end

  test "reconciliation refuses missing mutation proof and conflicting post-state" do
    root = tmp_dir()
    workspace = Workspace.new!(root: root)
    File.write!(Path.join(root, "demo.txt"), "desired\n")

    no_hash =
      Patch.reconcile_after_unknown(
        workspace,
        %{operations: [%{op: :update, path: "demo.txt", content: "desired\n"}]},
        %{
          attempt: 2,
          prior_attempt_id: "attempt-1",
          prior_outcome: :unknown_after_dispatch
        }
      )

    assert no_hash.status == :error
    assert [%{message: message}] = no_hash.diagnostics
    assert message =~ "requires a SHA-256 expected_hash"

    invalid_context =
      Patch.reconcile_after_unknown(
        workspace,
        %{
          operations: [
            %{
              op: :update,
              path: "demo.txt",
              content: "desired\n",
              expected_hash: Patch.sha256("before\n")
            }
          ]
        },
        %{attempt: 1, prior_attempt_id: "attempt-1", prior_outcome: :unknown_after_dispatch}
      )

    assert invalid_context.status == :error
    assert [%{code: :invalid_replay_context}] = invalid_context.diagnostics

    conflict =
      Patch.reconcile_after_unknown(
        workspace,
        %{
          operations: [
            %{
              op: :update,
              path: "demo.txt",
              content: "different\n",
              expected_hash: Patch.sha256("before\n")
            }
          ]
        },
        %{
          attempt: 2,
          prior_attempt_id: "attempt-1",
          prior_outcome: :unknown_after_dispatch
        }
      )

    assert conflict.status == :error
    assert [%{message: conflict_message}] = conflict.diagnostics
    assert conflict_message =~ "expected hash does not match"
    assert File.read!(Path.join(root, "demo.txt")) == "desired\n"
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
