defmodule RunicAI.Sandbox.GeneratedComponentBuilderTest do
  use ExUnit.Case, async: true

  alias RunicAI.Sandbox.GeneratedComponent
  alias RunicAI.Sandbox.GeneratedComponentBuilder

  test "writes source and test files then verifies the component in the sandbox" do
    {:ok, registry} =
      RunicAI.GeneratedComponentFakeSandboxRegistry.start_link(
        exec_responses: [
          {:ok,
           %{
             status: :ok,
             exit_status: 0,
             stdout: "1 passed",
             stderr: "",
             duration_ms: 12,
             backend: :fake,
             isolation_level: :fake
           }}
        ]
      )

    component = component()

    assert {:ok, result} =
             GeneratedComponentBuilder.run(component,
               registry: registry,
               sandbox_session_id: "sandbox:component",
               source_files: [%{path: "component.py", content: "def run(input): return input"}],
               test_files: [%{path: "test_component.py", content: "def test_run(): assert True"}]
             )

    assert result.status == :verified
    assert result.component.promotion_status == :verified
    assert GeneratedComponent.promotable?(result.component)
    assert result.component.verification.status == :pass
    assert result.component.verification.command == "python -m pytest"
    assert length(result.attempts) == 1
    assert [%{kind: :source, path: "component.py"}] = result.source_artifacts
    assert [%{kind: :test, path: "test_component.py"}] = result.test_artifacts

    assert [
             %{path: "component.py", session_id: "sandbox:component"},
             %{path: "test_component.py", session_id: "sandbox:component"}
           ] = RunicAI.GeneratedComponentFakeSandboxRegistry.writes(registry)

    assert [%{request: request}] = RunicAI.GeneratedComponentFakeSandboxRegistry.execs(registry)
    assert request.runtime == :bash
    assert request.source == "python -m pytest"
    assert request.network == :disabled
  end

  test "repairs failed sandbox tests and retries within the attempt budget" do
    {:ok, registry} =
      RunicAI.GeneratedComponentFakeSandboxRegistry.start_link(
        exec_responses: [
          {:ok, %{status: :error, exit_status: 1, stdout: "", stderr: "failed"}},
          {:ok, %{status: :ok, exit_status: 0, stdout: "1 passed", stderr: ""}}
        ]
      )

    repair_fun = fn repair_context ->
      assert repair_context.attempt == 1
      assert repair_context.execution.exit_status == 1

      {:ok,
       %{
         source_files: [
           %{path: "component.py", content: "def run(input): return {'ok': True}"}
         ]
       }}
    end

    assert {:ok, result} =
             GeneratedComponentBuilder.run(component(),
               registry: registry,
               sandbox_session_id: "sandbox:component",
               source_files: [%{path: "component.py", content: "broken"}],
               test_files: [%{path: "test_component.py", content: "def test_run(): assert True"}],
               max_repair_attempts: 1,
               repair_fun: repair_fun
             )

    assert result.status == :verified
    assert Enum.map(result.attempts, & &1.status) == [:failed, :pass]

    assert Enum.map(RunicAI.GeneratedComponentFakeSandboxRegistry.writes(registry), & &1.path) ==
             [
               "component.py",
               "test_component.py",
               "component.py"
             ]
  end

  test "returns a failed draft component when tests fail and no repair remains" do
    {:ok, registry} =
      RunicAI.GeneratedComponentFakeSandboxRegistry.start_link(
        exec_responses: [
          {:ok, %{status: :error, exit_status: 1, stdout: "", stderr: "still failing"}}
        ]
      )

    assert {:ok, result} =
             GeneratedComponentBuilder.run(component(),
               registry: registry,
               sandbox_session_id: "sandbox:component",
               source_files: [%{path: "component.py", content: "broken"}],
               test_files: [%{path: "test_component.py", content: "def test_run(): assert False"}]
             )

    assert result.status == :failed
    assert result.component.promotion_status == :draft
    assert result.component.verification.status == :failed
    assert result.component.verification.diagnostics.stderr_preview == "still failing"
    refute GeneratedComponent.promotable?(result.component)
  end

  test "validates required registry session and test command" do
    assert {:error, error} =
             GeneratedComponentBuilder.run(component(), sandbox_session_id: "sandbox:component")

    assert error.kind == :validation
    assert error.details.field == :registry

    {:ok, registry} = RunicAI.GeneratedComponentFakeSandboxRegistry.start_link()

    no_command =
      GeneratedComponent.new!(
        id: "generated:no-command",
        name: "No command",
        language: :python,
        runtime: :python,
        entrypoint: "component.py:run"
      )

    assert {:error, error} =
             GeneratedComponentBuilder.run(no_command,
               registry: registry,
               sandbox_session_id: "sandbox:component"
             )

    assert error.kind == :validation
    assert error.details.field == :test_command
  end

  defp component do
    GeneratedComponent.new!(
      id: "generated:component",
      name: "Component",
      language: :python,
      runtime: :python,
      entrypoint: "component.py:run",
      interface: %{inputs: [%{name: "input"}], outputs: [%{name: "output"}]},
      verification: %{commands: ["python -m pytest"]},
      promotion_status: :draft
    )
  end
end
