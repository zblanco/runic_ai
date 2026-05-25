defmodule RunicAI.Agent.CapabilityResolverTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Agent.CapabilityProfile
  alias RunicAI.Agent.ToolExecution
  alias RunicAI.Coding.Workspace
  alias RunicAI.ReviewDecision
  alias RunicAI.Tool.Registry

  test "local workbench expands existing tools into visible and gated capability sets" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        agent: :assistant,
        profile: :local_workbench,
        approval: :safe
      )

    assert %CapabilityProfile{} = resolved.profile
    assert resolved.profile.name == :local_workbench
    assert :terminal in resolved.profile.toolsets
    assert :code_execution in resolved.profile.toolsets
    assert "read_file" in resolved.visible_tools
    assert "apply_patch" in resolved.visible_tools
    assert "run_command" in resolved.visible_tools
    assert "execute_code" in resolved.visible_tools
    assert "sandbox_status" in resolved.visible_tools
    assert "memory_write" in resolved.visible_tools
    assert "memory_recall" in resolved.visible_tools
    assert "session_search" in resolved.visible_tools
    assert "clarify" in resolved.visible_tools

    assert "run_command" in resolved.gated_tools
    assert "execute_code" in resolved.gated_tools
    assert "memory_write" in resolved.gated_tools
    refute "sandbox_status" in resolved.gated_tools
    refute "memory_recall" in resolved.gated_tools
    refute "session_search" in resolved.gated_tools
    refute "clarify" in resolved.gated_tools

    run_command = Registry.fetch!(resolved.registry, "run_command")
    assert ToolExecution.requires_review?(run_command, resolved.profile)
  end

  test "disabled tools are represented separately and blocked at tool execution time" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        disabled_tools: ["run_command"]
      )

    assert "run_command" in resolved.profile.disabled_tools
    assert "run_command" in resolved.profile.disabled_available_tools
    refute "run_command" in resolved.visible_tools

    assert {:error, error} =
             ToolExecution.execute(resolved.registry, "run_command", %{argv: ["git", "status"]},
               capability_profile: resolved.profile
             )

    assert error.message =~ "not visible"
  end

  test "standard assistant and rlm local workbench profiles expose memory and session recall" do
    workspace = sample_workspace()

    for agent <- [:standard, :assistant, :rlm] do
      resolved = CapabilityResolver.resolve!(workspace, agent: agent, profile: :local_workbench)

      assert "memory_write" in resolved.visible_tools
      assert "memory_recall" in resolved.visible_tools
      assert "session_search" in resolved.visible_tools
      assert "clarify" in resolved.visible_tools
      assert resolved.profile.agent == agent
    end
  end

  test "research and full local profiles expose web media browser and delegation surfaces" do
    workspace = sample_workspace()

    research = CapabilityResolver.resolve!(workspace, profile: :research)
    assert "web_search" in research.visible_tools
    assert "web_extract" in research.visible_tools
    assert "browser_navigate" in research.visible_tools
    assert "browser_vision" in research.visible_tools
    assert "vision_analyze" in research.visible_tools

    full = CapabilityResolver.resolve!(workspace, profile: :full_local)
    assert "delegate_task" in full.visible_tools
    assert "clarify" in full.visible_tools
    assert "image_generate" in full.visible_tools
    assert "delegate_task" in full.gated_tools
    assert "browser_click" in full.gated_tools
  end

  test "unknown toolsets and disabled tools fail during resolution" do
    workspace = sample_workspace()

    assert {:error, toolset_error} =
             CapabilityResolver.resolve(workspace,
               profile: :local_workbench,
               toolsets: ["ether"]
             )

    assert toolset_error.message =~ "unknown capability toolset"

    assert {:error, tool_error} =
             CapabilityResolver.resolve(workspace,
               profile: :local_workbench,
               disabled_tools: ["summon_fire"]
             )

    assert tool_error.message =~ "disabled unknown tools"
  end

  test "mode-derived profiles stay narrow when no profile override is requested" do
    workspace = sample_workspace()

    resolved = CapabilityResolver.resolve!(workspace, mode: :read_only)

    assert resolved.profile.name == :coding_read
    assert "read_file" in resolved.visible_tools
    assert "git_status" in resolved.visible_tools
    refute "apply_patch" in resolved.visible_tools
    refute "run_command" in resolved.visible_tools
    assert "memory_recall" in resolved.visible_tools
    refute "session_search" in resolved.visible_tools
    refute resolved.command_policy.allow_shell
  end

  test "review decisions gate approve reject and edit paths for local tools" do
    workspace = sample_workspace()
    resolved = CapabilityResolver.resolve!(workspace, profile: :local_workbench)

    approve = fn request, _context ->
      {:ok, ReviewDecision.new!(request.resume_key, :approved)}
    end

    assert {:ok, code_result} =
             ToolExecution.execute(resolved.registry, "execute_code", %{code: "echo approved"},
               capability_profile: resolved.profile,
               review_decider: approve
             )

    assert code_result.status == :pass
    assert code_result.output == "approved\n"

    reject = fn request, _context ->
      {:ok, ReviewDecision.new!(request.resume_key, :rejected)}
    end

    assert {:error, denied} =
             ToolExecution.execute(resolved.registry, "run_command", %{argv: ["git", "status"]},
               capability_profile: resolved.profile,
               review_decider: reject
             )

    assert denied.message =~ "denied by review"

    edit = fn request, _context ->
      {:ok,
       ReviewDecision.new!(request.resume_key, :edited,
         edited_value: %{
           arguments: %{
             operations: [
               %{op: "create", path: "approved.txt", content: "approved\n"}
             ]
           }
         }
       )}
    end

    assert {:ok, patch_result} =
             ToolExecution.execute(
               resolved.registry,
               "apply_patch",
               %{operations: [%{op: "create", path: "rejected.txt", content: "rejected\n"}]},
               capability_profile: resolved.profile,
               review_decider: edit
             )

    assert patch_result.status == :ok
    assert File.read!(Path.join(workspace.root, "approved.txt")) == "approved\n"
    refute File.exists?(Path.join(workspace.root, "rejected.txt"))
  end

  defp sample_workspace do
    root =
      Path.join(System.tmp_dir!(), "runic-ai-capabilities-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "README.md"), "demo\n")
    File.write!(Path.join(root, "lib/demo.ex"), "defmodule Demo do\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)
    Workspace.new!(root: root)
  end
end
