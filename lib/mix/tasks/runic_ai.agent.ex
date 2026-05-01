defmodule Mix.Tasks.RunicAi.Agent do
  @moduledoc """
  Run a RunicAI coding agent from the terminal.

      mix runic_ai.agent "summarize this repository" --agent standard --cwd .
      mix runic_ai.agent "plan a fix for failing tests" --agent rlm --cwd .
      mix runic_ai.agent --interactive --agent standard --cwd .
      mix runic_ai.agent "inspect the harness" --jsonl tmp/trace.jsonl
      mix runic_ai.agent "inspect the harness" --renderer owl --theme runic

  Presentation options:

    * `--renderer auto|text|owl`
    * `--color auto|always|never`
    * `--theme runic|plain`
    * `--progress auto|off`
    * `--unicode auto|always|never`
    * `--graph text|mermaid|mmdflux`
  """

  use Mix.Task

  alias RunicAI.Terminal.AgentRunner
  alias RunicAI.Terminal.CliOptions

  @shortdoc "Run a RunicAI coding agent terminal session"

  @impl true
  def run(args) do
    shell = Mix.shell()

    with {:ok, options} <- CliOptions.parse(args),
         {:ok, _apps} <- Application.ensure_all_started(:runic_ai),
         {:ok, result} <- AgentRunner.run(options, output_fun: &shell.info/1) do
      maybe_raise_for_unsatisfied(result)
    else
      {:error, error} ->
        Mix.raise(error_message(error))
    end
  end

  defp maybe_raise_for_unsatisfied(%{status: status}) when status in [:blocked, :error] do
    Mix.raise("runic_ai.agent finished with status #{status}")
  end

  defp maybe_raise_for_unsatisfied(_result), do: :ok

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
