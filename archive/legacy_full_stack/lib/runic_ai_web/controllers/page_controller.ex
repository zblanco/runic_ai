defmodule RunicAIWeb.PageController do
  use RunicAIWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      app_version: Application.spec(:runic_ai, :vsn) || "dev",
      runtime_status: runtime_status()
    )
  end

  def health(conn, _params) do
    text(conn, "ok")
  end

  def well_known_unavailable(conn, _params) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: "not_found",
      detail: "RunicAI Workbench does not expose OAuth authorization metadata on this route."
    })
  end

  defp runtime_status do
    if Code.ensure_loaded?(RunicAI.Runtime), do: "loaded", else: "missing"
  end
end
