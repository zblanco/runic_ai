defmodule RunicAI.Coding.WorkspaceTest do
  use ExUnit.Case, async: true

  alias RunicAI.Coding.PathPolicy
  alias RunicAI.Coding.Workspace

  test "constructs a workspace and detects Mix projects" do
    root = tmp_dir()
    File.write!(Path.join(root, "mix.exs"), "defmodule Demo.MixProject do\nend\n")

    workspace = Workspace.new!(root: root)

    assert workspace.root == root
    assert workspace.profile.name == :mix
    assert workspace.profile.language == :elixir
  end

  test "rejects traversal above the workspace root" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:error, error} = Workspace.resolve_path(workspace, "../outside.ex", :read)
    assert error.kind == :validation
    assert error.message =~ "escapes"
  end

  test "normalizes absolute paths inside the workspace root" do
    root = tmp_dir()
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\nend\n")

    workspace = Workspace.new!(root: root)

    assert {:ok, resolved} =
             Workspace.resolve_path(workspace, Path.join(root, "lib/demo.ex"), :read)

    assert resolved.relative == "lib/demo.ex"
    assert resolved.path == Path.join(root, "lib/demo.ex")
  end

  test "rejects absolute paths outside the workspace root" do
    workspace = Workspace.new!(root: tmp_dir())
    outside = Path.join(tmp_dir(), "outside.ex")

    assert {:error, error} = Workspace.resolve_path(workspace, outside, :read)
    assert error.kind == :validation
    assert error.message =~ "outside workspace root"
  end

  test "can allow read-only paths outside the workspace root without allowing writes" do
    root = tmp_dir()
    outside = tmp_dir()
    File.write!(Path.join(outside, "notes.md"), "# Notes\n")

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(read_root_jail: false)
      )

    outside_file = Path.join(outside, "notes.md")

    assert {:ok, resolved} = Workspace.resolve_path(workspace, outside_file, :read)
    assert resolved.path == outside_file
    assert resolved.relative == outside_file

    assert {:ok, relative_resolved} =
             Workspace.resolve_path(workspace, Path.relative_to(outside_file, root), :read)

    assert relative_resolved.path == outside_file

    assert {:error, error} = Workspace.resolve_path(workspace, outside_file, :write)
    assert error.message =~ "workspace-relative"
  end

  test "allows hidden reads by default but rejects hidden writes" do
    root = tmp_dir()
    File.write!(Path.join(root, ".formatter.exs"), "[]\n")
    workspace = Workspace.new!(root: root)

    assert {:ok, _resolved} = Workspace.resolve_path(workspace, ".formatter.exs", :read)
    assert {:error, error} = Workspace.resolve_path(workspace, ".formatter.exs", :write)
    assert error.message =~ "read-only"
  end

  test "rejects credential-looking paths by default" do
    workspace = Workspace.new!(root: tmp_dir())

    assert {:error, error} = Workspace.resolve_path(workspace, ".env", :read)
    assert error.message =~ "credential"
  end

  test "rejects symlink escapes" do
    root = tmp_dir()
    outside = tmp_dir()
    File.write!(Path.join(outside, "secret.txt"), "nope\n")
    File.ln_s!(outside, Path.join(root, "linked"))

    workspace = Workspace.new!(root: root)

    assert {:error, error} = Workspace.resolve_path(workspace, "linked/secret.txt", :read)
    assert error.message =~ "workspace root"
  end

  test "can be configured for hidden writes" do
    root = tmp_dir()

    workspace =
      Workspace.new!(
        root: root,
        path_policy: PathPolicy.new!(hidden_policy: :allow)
      )

    assert {:ok, _resolved} = Workspace.resolve_path(workspace, ".github/workflow.yml", :write)
  end

  defp tmp_dir do
    path = Path.join(System.tmp_dir!(), "runic-ai-coding-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
