defmodule RunicAI.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {RunicAI.Runtime.Registry, []},
      {RunicAI.Runtime.SessionSupervisor, []},
      {Runic.Runner, name: RunicAI.Runtime.Runner}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: RunicAI.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
