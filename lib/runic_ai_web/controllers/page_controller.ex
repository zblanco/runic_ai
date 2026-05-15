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

  defp runtime_status do
    if Code.ensure_loaded?(RunicAI.Runtime), do: "loaded", else: "missing"
  end
end
