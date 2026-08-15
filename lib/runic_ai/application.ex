defmodule RunicAI.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    sandbox_opts =
      :runic_ai
      |> Application.get_env(:sandbox, [])
      |> Keyword.put_new(:name, RunicAI.Sandbox)

    children = [
      RunicAIWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:runic_ai, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: RunicAI.PubSub},
      {RunicAI.Workbench.StoreServer, Application.get_env(:runic_ai, :workbench, [])},
      RunicAI.Workbench.WorkflowRunner,
      {Task.Supervisor, name: RunicAI.Workbench.TaskSupervisor},
      {LitterBox, sandbox_opts},
      {RunicAI.Coding.SandboxSessionRegistry, name: RunicAI.Coding.SandboxSessionRegistry},
      {RunicAI.Runtime.Registry, []},
      {RunicAI.Runtime.SessionSupervisor, []},
      {Runic.Runner, name: RunicAI.Runtime.Runner},
      RunicAIWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RunicAI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RunicAIWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
