defmodule RunicAI.Workflows.CoordinatorTypedRepairLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live_smoke

  if System.get_env("RUNIC_AI_LIVE_WORKFLOW_REPAIR") != "1" do
    @moduletag skip:
                 "set RUNIC_AI_LIVE_WORKFLOW_REPAIR=1 to run the live typed workflow repair test"
  end

  alias RunicAI.Coding.RLM.CodebaseEnvironment
  alias RunicAI.Coding.RLM.Coordinator
  alias RunicAI.LLM.ReqLLMClient
  alias RunicAI.LLM.TestClient

  @model "openai:gpt-5.6-luna"

  @tag timeout: 180_000
  test "gpt-5.6-luna repairs a seeded cycle with a typed operation transaction" do
    root = tmp_dir()
    environment = CodebaseEnvironment.new!(root, index?: true)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    client = fn model, prompt, opts ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:ok, TestClient.result(Jason.encode!(cyclic_proposal()))}
        _repair -> ReqLLMClient.generate_text(model, prompt, opts)
      end
    end

    assert {:ok, proposal, report} =
             Coordinator.propose("Explain the workspace in one final report", environment,
               model: @model,
               client: client,
               fallback?: false,
               proposal_repair_attempts: 1,
               validation_opts: [allowed_tools: ["find_files", "read_many"]]
             )

    assert report.status == :accepted
    assert report.metadata.coordinator_repair.strategy == :typed_operations
    assert report.metadata.coordinator_repair.attempts == 1

    assert [%{status: :applied, operations: operations}] =
             report.metadata.coordinator_repair.batches

    assert length(operations) <= 2
    assert Enum.map(proposal.edges, &{&1.from, &1.to}) == [{"discover", "answer"}]
    assert Agent.get(calls, & &1) == 2
  end

  defp cyclic_proposal do
    %{
      "id" => "luna-typed-cycle-repair",
      "objective" => "Explain the workspace in one final report",
      "nodes" => [
        %{
          "id" => "discover",
          "kind" => "tool",
          "params" => %{"tool" => "find_files", "args" => %{"path" => "."}}
        },
        %{
          "id" => "answer",
          "kind" => "reducer",
          "params" => %{"reducer" => "report"}
        }
      ],
      "edges" => [
        %{"from" => "discover", "to" => "answer"},
        %{"from" => "answer", "to" => "discover"}
      ],
      "stop_conditions" => ["answer returned"]
    }
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-workflow-repair-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    File.write!(Path.join(path, "README.md"), "# Workflow repair fixture\n")
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
