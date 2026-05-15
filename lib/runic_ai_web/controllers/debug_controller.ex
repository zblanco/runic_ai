defmodule RunicAIWeb.DebugController do
  use RunicAIWeb, :controller

  alias RunicAI.Workbench
  alias RunicAI.Workbench.Debug

  def export(conn, %{"run_id" => run_id}) do
    jsonl = Debug.jsonl(Workbench.store!(), run_id)

    conn
    |> put_resp_content_type("application/x-ndjson")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{filename(run_id)}.jsonl")
    )
    |> text(jsonl)
  end

  def diagnostics(conn, _params) do
    diagnostics = Debug.diagnostics(Workbench.store!())

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="runic-ai-diagnostics.json")
    )
    |> json(diagnostics)
  end

  defp filename(run_id) do
    run_id
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "runic-ai-run"
      value -> value
    end
  end
end
