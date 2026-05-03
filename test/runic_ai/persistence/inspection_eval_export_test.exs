defmodule RunicAI.Persistence.InspectionEvalExportTest do
  use ExUnit.Case, async: true

  alias RunicAI.Persistence.Evals
  alias RunicAI.Persistence.Export
  alias RunicAI.Persistence.Inspection
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite

  test "query, eval, and export helpers work after reopening an on-disk database" do
    path =
      Path.join(
        System.tmp_dir!(),
        "runic-ai-persistence-#{System.unique_integer([:positive])}.db"
      )

    {:ok, store} = SQLite.open(database: path)

    on_exit(fn ->
      SQLite.close(store)
      File.rm_rf!(path)
      File.rm_rf!(path <> "-shm")
      File.rm_rf!(path <> "-wal")
    end)

    assert {:ok, _event} =
             SQLite.record_terminal_event(store, %{
               id: "event:eval:start",
               session_id: "run:eval:1",
               agent: :assistant,
               kind: :rlm_node,
               phase: :node_failed,
               status: :error,
               title: "Assistant RLM node failed",
               detail: "artifact writer requires a non-empty path",
               data_json: %{
                 stage: :node_failed,
                 data: %{
                   runnable: %{
                     id: "runnable:writer",
                     node: "assistant_node_2_write",
                     component_id: "write",
                     component_type: "artifact_writer"
                   },
                   error: %{message: "artifact writer requires a non-empty path"}
                 }
               },
               at: ~U[2026-05-03 13:00:00Z]
             })

    assert {:ok, _event} =
             SQLite.record_terminal_event(store, %{
               id: "event:eval:scorecard",
               session_id: "run:eval:1",
               agent: :assistant,
               kind: :summary,
               phase: :scorecard,
               status: :blocked,
               title: "Assistant RLM objective objective_incomplete",
               detail: "changed=0 risks=1",
               data_json: %{
                 scorecard: %{
                   objective_status: :objective_incomplete,
                   residual_risks: ["missing output path"],
                   salience: 0.6,
                   progress: 0.4
                 }
               },
               at: ~U[2026-05-03 13:00:01Z]
             })

    :ok = SQLite.close(store)
    {:ok, reopened} = SQLite.open(database: path)

    on_exit(fn -> SQLite.close(reopened) end)

    assert Enum.any?(Inspection.run_timeline(reopened, "run:eval:1"), &(&1.status == "error"))
    assert %{component_id: "write"} = Inspection.failed_runnable(reopened, "run:eval:1")
    assert Inspection.repair_prompt(reopened, "run:eval:1") =~ "artifact writer"

    assert %{"objective_incomplete" => 1} =
             Evals.compare_by_objective_status(reopened, objective_status: :objective_incomplete)

    assert [%{metrics: %{scorecard_count: 1}}] = Evals.cohort(reopened, run_ids: ["run:eval:1"])

    assert [%{title: "Assistant RLM node failed"}] =
             Inspection.prompt_source_cue_search(reopened, "artifact")

    exported = Export.terminal_jsonl(reopened, "run:eval:1")

    assert exported |> String.split("\n", trim: true) |> length() ==
             length(Queries.run_timeline(reopened, "run:eval:1"))
  end
end
