defmodule RunicAIWeb.Router do
  use RunicAIWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug RunicAIWeb.Plugs.LocalAuth
    plug :put_root_layout, html: {RunicAIWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RunicAIWeb do
    pipe_through :browser

    live "/", WorkbenchLive, :index
    live "/sessions/new", WorkbenchLive, :new
    live "/reviews", WorkbenchLive, :reviews
    live "/agents", AgentLive, :index
    live "/agents/:agent_id", AgentLive, :show
    live "/runs/:run_id/graph", GraphLive, :show
    live "/debug", DebugLive, :logs
    live "/debug/logs", DebugLive, :logs
    live "/debug/traces", DebugLive, :traces
    live "/debug/managed", DebugLive, :managed
    live "/debug/scorecards", DebugLive, :scorecards
    live "/debug/context", DebugLive, :context
    live "/debug/health", DebugLive, :health
    live "/sessions/:session_id", WorkbenchLive, :show

    get "/health", PageController, :health
    get "/debug/export/:run_id", DebugController, :export
    get "/debug/diagnostics", DebugController, :diagnostics
  end

  # Other scopes may use custom stacks.
  # scope "/api", RunicAIWeb do
  #   pipe_through :api
  # end
end
