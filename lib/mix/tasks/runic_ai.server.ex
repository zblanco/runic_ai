defmodule Mix.Tasks.RunicAi.Server do
  @moduledoc """
  Start the local RunicAI Phoenix workbench.

      mix runic_ai.server
      mix runic_ai.server --port 4000 --data-path ~/.runic_ai
      mix runic_ai.server --no-open
  """

  use Mix.Task

  @shortdoc "Start the local RunicAI web workbench"

  @impl true
  def run(args) do
    shell = Mix.shell()
    RunicAI.Server.serve(args, output_fun: &shell.info/1)
  end
end
