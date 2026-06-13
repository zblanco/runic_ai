defmodule RunicAI.Agent.CapabilityResolverTest do
  use ExUnit.Case, async: true

  alias RunicAI.Agent.CapabilityResolver
  alias RunicAI.Agent.CapabilityProfile
  alias RunicAI.Agent.ToolExecution
  alias RunicAI.Coding.SandboxSessionRegistry
  alias RunicAI.Coding.Workspace
  alias RunicAI.ReviewDecision
  alias RunicAI.Tool.Registry

  test "local workbench keeps code execution hidden until explicitly enabled" do
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
    refute :code_execution in resolved.profile.toolsets
    assert "read_file" in resolved.visible_tools
    assert "apply_patch" in resolved.visible_tools
    assert "run_command" in resolved.visible_tools
    refute "execute_code" in resolved.visible_tools
    refute "sandbox_status" in resolved.visible_tools
    assert "memory_write" in resolved.visible_tools
    assert "memory_recall" in resolved.visible_tools
    assert "session_search" in resolved.visible_tools
    assert "clarify" in resolved.visible_tools

    assert "run_command" in resolved.gated_tools
    refute "execute_code" in resolved.gated_tools
    assert "memory_write" in resolved.gated_tools
    refute "memory_recall" in resolved.gated_tools
    refute "session_search" in resolved.gated_tools
    refute "clarify" in resolved.gated_tools

    run_command = Registry.fetch!(resolved.registry, "run_command")
    assert ToolExecution.requires_review?(run_command, resolved.profile)
  end

  test "explicit code execution toolset enables sandbox tools" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        agent: :assistant,
        profile: :local_workbench,
        toolsets: [:code_execution],
        approval: :safe
      )

    assert :code_execution in resolved.profile.toolsets
    assert "execute_code" in resolved.visible_tools
    assert "sandbox_status" in resolved.visible_tools
    assert "execute_code" in resolved.gated_tools
    refute "sandbox_status" in resolved.gated_tools
  end

  test "local feature flag can enable preset code execution tools" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        enable_code_execution?: true
      )

    assert :code_execution in resolved.profile.toolsets
    assert "execute_code" in resolved.visible_tools
    assert "sandbox_status" in resolved.visible_tools
  end

  test "code execution tool config enables sandbox tools without a duplicate toolset flag" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        tool_config: %{
          code_execution: %{
            backend: "docker",
            allowed_runtimes: ["elixir"],
            network: "host"
          }
        }
      )

    assert :code_execution in resolved.profile.toolsets
    assert "execute_code" in resolved.visible_tools
    assert "sandbox_status" in resolved.visible_tools
    assert resolved.profile.config.code_execution.backend == "docker"
    assert resolved.profile.config.code_execution.allowed_runtimes == ["elixir"]
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

  test "disabled code execution tool is removed from visible tools and blocked" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution],
        disabled_tools: ["execute_code"]
      )

    assert :code_execution in resolved.profile.toolsets
    assert "execute_code" in resolved.profile.disabled_tools
    assert "execute_code" in resolved.profile.disabled_available_tools
    refute "execute_code" in resolved.visible_tools
    refute "execute_code" in resolved.gated_tools
    assert "sandbox_status" in resolved.visible_tools

    assert {:error, error} =
             ToolExecution.execute(resolved.registry, "execute_code", %{code: "echo hidden"},
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

  test "invalid code execution sandbox backend fails closed" do
    workspace = sample_workspace()

    assert {:error, error} =
             CapabilityResolver.resolve(workspace,
               profile: :local_workbench,
               toolsets: [:code_execution],
               tool_config: %{code_execution: %{backend: "vmsna", allowed_runtimes: "bash"}}
             )

    assert error.message == "invalid sandbox backend"
    assert error.details.backend == "vmsna"

    assert_raise ArgumentError, "invalid sandbox backend", fn ->
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution],
        tool_config: %{code_execution: %{backend: "vmsna", allowed_runtimes: "bash"}}
      )
    end
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

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution]
      )

    approve = fn request, _context ->
      assert request.details.tool_name == "execute_code"
      assert request.details.runtime == :bash
      assert request.details.network == :disabled
      assert request.details.code_preview == "echo approved"
      assert request.details.sandbox_capability.sandbox_backend == :just_bash
      assert request.details.sandbox_capability.state_model == :one_shot
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

  test "stateful sandbox tools are visible and reviewed through code execution capability" do
    workspace = sample_workspace()
    {:ok, sandbox_sessions} = SandboxSessionRegistry.start_link()

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution],
        sandbox_session_registry: sandbox_sessions
      )

    assert "open_sandbox_session" in resolved.visible_tools
    assert "sandbox_exec" in resolved.visible_tools
    assert "sandbox_write_file" in resolved.visible_tools
    assert "sandbox_read_file" in resolved.visible_tools
    assert "checkpoint_sandbox" in resolved.visible_tools
    assert "restore_sandbox" in resolved.visible_tools
    assert "start_sandbox_service" in resolved.visible_tools
    assert "open_sandbox_proxy" in resolved.visible_tools
    assert "open_sandbox_session" in resolved.gated_tools
    assert "sandbox_exec" in resolved.gated_tools
    assert "start_sandbox_service" in resolved.gated_tools
    assert "open_sandbox_proxy" in resolved.gated_tools
    refute "sandbox_read_file" in resolved.gated_tools

    approve_open = fn request, _context ->
      assert request.details.tool_name == "open_sandbox_session"
      assert request.details.toolset == :code_execution
      assert request.details.sandbox_capability.sandbox_backend == :just_bash
      {:ok, ReviewDecision.new!(request.resume_key, :approved)}
    end

    assert {:ok, opened} =
             ToolExecution.execute(resolved.registry, "open_sandbox_session", %{},
               capability_profile: resolved.profile,
               review_decider: approve_open
             )

    assert opened.id =~ "sandbox_session_"

    approve_exec = fn request, _context ->
      assert request.details.tool_name == "sandbox_exec"
      assert request.details.session_id == opened.id
      assert request.details.code_preview == "echo stateful"
      {:ok, ReviewDecision.new!(request.resume_key, :approved)}
    end

    assert {:ok, result} =
             ToolExecution.execute(
               resolved.registry,
               "sandbox_exec",
               %{session_id: opened.id, runtime: "bash", code: "echo stateful"},
               capability_profile: resolved.profile,
               review_decider: approve_exec
             )

    assert result.status == :pass
    assert result.stdout == "stateful\n"

    service_review = fn request, _context ->
      assert request.details.tool_name == "start_sandbox_service"
      assert request.details.session_id == opened.id
      {:ok, ReviewDecision.new!(request.resume_key, :approved)}
    end

    assert {:error, service_error} =
             ToolExecution.execute(
               resolved.registry,
               "start_sandbox_service",
               %{session_id: opened.id, spec: %{name: "web"}},
               capability_profile: resolved.profile,
               review_decider: service_review
             )

    assert service_error.message =~ "does not support start_service"

    assert {:ok, %{status: :closed}} =
             ToolExecution.execute(
               resolved.registry,
               "close_sandbox_session",
               %{session_id: opened.id},
               capability_profile: resolved.profile
             )
  end

  test "code execution tool config selects sandbox profile backend runtime and network" do
    workspace = sample_workspace()

    resolved =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution],
        tool_config: %{
          "code_execution" => %{
            "backend" => "docker",
            "allowed_runtimes" => "python,node",
            "network" => "restricted",
            "stateful?" => true,
            "workspace" => %{"mode" => "copy_in", "persist?" => true},
            "state_model" => "persistent_workspace",
            "transport_model" => "docker_cli",
            "session" => "workspace",
            "checkpoint_policy" => %{"mode" => "manual"},
            "service_policy" => %{"allowed?" => false}
          }
        }
      )

    assert resolved.profile.config.code_execution["backend"] == "docker"
    assert resolved.profile.config.code_execution.allowed_runtimes == "python,node"
    refute Map.has_key?(resolved.profile.config.code_execution, :isolation_minimum)

    assert {:ok, status} =
             ToolExecution.execute(resolved.registry, "sandbox_status", %{},
               capability_profile: resolved.profile
             )

    assert status.profile.backend == :docker
    assert status.profile.runtimes == [:python, :node]
    assert status.profile.isolation_level == :container
    assert status.profile.network == :restricted
    assert status.profile.stateful?
    assert status.profile.workspace[:persist?]
    assert status.profile.metadata.state_model == "persistent_workspace"
    assert status.profile.metadata.transport_model == "docker_cli"
    assert status.profile.metadata.session == "workspace"
    assert status.profile.metadata.checkpoint_policy == %{"mode" => "manual"}

    execute_code = Registry.fetch!(resolved.registry, "execute_code")
    assert execute_code.metadata.sandbox_backend == :docker
    assert execute_code.metadata.isolation_level == :container
    assert execute_code.metadata.runtimes == [:python, :node]
    assert execute_code.metadata.state_model == :persistent_workspace
    assert execute_code.metadata.transport_model == :docker_cli
    assert execute_code.metadata.session == :workspace
    assert execute_code.metadata.checkpoint_policy == %{"mode" => "manual"}
    assert execute_code.metadata.service_policy == %{"allowed?" => false}
  end

  test "code execution tool config carries vmsan and remote stateful sandbox shapes" do
    workspace = sample_workspace()

    vmsan =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution],
        tool_config: %{
          code_execution: %{
            backend: :vmsan,
            allowed_runtimes: [:bash, :python],
            network: :disabled,
            session: :workspace,
            state_model: :checkpointable,
            transport_model: :local_microvm,
            checkpoint_policy: %{mode: :manual},
            backend_options: %{"sudo?" => true, "executable" => "/usr/bin/vmsan"}
          }
        }
      )

    vmsan_tool = Registry.fetch!(vmsan.registry, "execute_code")
    assert vmsan_tool.metadata.sandbox_backend == :vmsan
    assert vmsan_tool.metadata.isolation_level == :microvm
    assert vmsan_tool.metadata.state_model == :checkpointable
    assert vmsan_tool.metadata.transport_model == :local_microvm
    assert vmsan_tool.metadata.session == :workspace
    assert vmsan_tool.metadata.checkpoint_policy == %{mode: :manual}

    assert vmsan.profile.config.code_execution.backend == :vmsan

    remote =
      CapabilityResolver.resolve!(workspace,
        profile: :local_workbench,
        toolsets: [:code_execution],
        tool_config: %{
          code_execution: %{
            backend: :remote,
            allowed_runtimes: [:bash],
            network: :restricted,
            session: :run,
            state_model: :service_actor,
            transport_model: :remote_microvm,
            service_policy: %{mode: :actor},
            backend_options: %{provider: :sprites}
          }
        }
      )

    remote_tool = Registry.fetch!(remote.registry, "execute_code")
    assert remote_tool.metadata.sandbox_backend == :remote
    assert remote_tool.metadata.isolation_level == :remote_microvm
    assert remote_tool.metadata.state_model == :service_actor
    assert remote_tool.metadata.transport_model == :remote_microvm
    assert remote_tool.metadata.session == :run
    assert remote_tool.metadata.service_policy == %{mode: :actor}
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
