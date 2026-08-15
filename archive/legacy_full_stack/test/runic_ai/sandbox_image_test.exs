defmodule RunicAI.SandboxImageTest do
  use ExUnit.Case, async: true

  @agent_cli_dir Path.expand("../../priv/runic_ai/sandbox/agent-cli", __DIR__)
  @dockerfile Path.join(@agent_cli_dir, "Dockerfile")
  @check_script Path.join(@agent_cli_dir, "runic-agent-cli-check")

  test "agent CLI image declares runtime tools, proxy env defaults, and install hooks" do
    dockerfile = File.read!(@dockerfile)

    for package <- [
          "bash",
          "build-essential",
          "curl",
          "elixir",
          "erlang-dev",
          "git",
          "jq",
          "nodejs",
          "npm",
          "python3",
          "ripgrep",
          "sqlite3"
        ] do
      assert dockerfile =~ package
    end

    assert dockerfile =~ "RUNIC_AGENT_HOME=/opt/runic-ai/agents"
    assert dockerfile =~ "RUNIC_MCP_URL=http://host.docker.internal:4000"
    assert dockerfile =~ "RUNIC_MODEL_PROXY_URL=http://host.docker.internal:4100"
    assert dockerfile =~ "ARG AGENT_CLI_APT_PACKAGES"
    assert dockerfile =~ "ARG AGENT_CLI_NPM_PACKAGES"
    assert dockerfile =~ "ARG RUNIC_AGENT_UID=10001"
    assert dockerfile =~ "USER ${RUNIC_AGENT_UID}:${RUNIC_AGENT_GID}"
    assert dockerfile =~ "runic-agent-cli-check"

    refute dockerfile =~ "python3-minimal"
    refute dockerfile =~ "ANTHROPIC_API_KEY"
    refute dockerfile =~ "OPENAI_API_KEY"
    refute dockerfile =~ "GEMINI_API_KEY"
  end

  test "agent CLI discovery script reports missing tools as explicit skips" do
    {output, 0} = System.cmd("bash", [@check_script, "runic-missing-cli-test"])

    assert output == "runic-missing-cli-test\tskipped\tnot installed\n"
  end
end
