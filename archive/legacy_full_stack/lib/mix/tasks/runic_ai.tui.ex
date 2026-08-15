defmodule Mix.Tasks.RunicAi.Tui do
  @moduledoc """
  Run the SQLite-backed RunicAI terminal workbench.

      mix runic_ai.tui --cwd .
      mix runic_ai.tui --agent assistant --cwd .
      mix runic_ai.tui --run assistant:cli:123
      mix runic_ai.tui --persistence memory

  Local harness usage defaults to SQLite at `.runic_ai/runs.db`. Use
  `--sqlite PATH` to choose another database, or `--persistence memory|none`
  for explicit ephemeral/debug modes.

  SSH transport is a local-development spike and is disabled unless `--ssh` is
  provided. SSH requires an explicit `--ssh-password` so local dev auth is not
  implicit.
  """

  use Mix.Task

  alias RunicAI.Terminal.ExRatatui.App
  alias RunicAI.Terminal.ExRatatui.Options

  @shortdoc "Run the RunicAI ExRatatui workbench"

  @impl true
  def run(args) do
    shell = Mix.shell()

    with {:ok, options} <- Options.parse(args),
         :ok <- maybe_help(options, shell),
         {:ok, _apps} <- Application.ensure_all_started(:runic_ai),
         {:ok, pid} <- start_app(options) do
      wait_for_exit(pid)
    else
      :help ->
        :ok

      {:error, reason} ->
        Mix.raise(error_message(reason))
    end
  end

  defp maybe_help(%Options{help?: true}, shell) do
    shell.info(Options.usage())
    :help
  end

  defp maybe_help(%Options{}, _shell), do: :ok

  defp start_app(%Options{ssh_port: port} = options) when is_integer(port) do
    App.start_link(
      app_opts: [options: options],
      transport: :ssh,
      port: port,
      auto_host_key: true,
      pwdfun: ssh_password_fun(options.ssh_password),
      name: nil
    )
  end

  defp start_app(%Options{} = options) do
    App.start_link(options: options, name: nil)
  end

  defp wait_for_exit(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, :shutdown} ->
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        Mix.raise("runic_ai.tui exited: #{inspect(reason)}")
    end
  end

  defp ssh_password_fun(password) when is_binary(password) do
    fn _user, candidate -> to_string(candidate) == password end
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(reason), do: inspect(reason)
end
