defmodule RunicAI.Tool.Adapters.Command do
  @moduledoc """
  Tool execution adapter for direct OS command invocation via `System.cmd/3`.

  Commands are executed without a shell. Pass a fixed `:command` and `:args`
  through adapter opts, or provide `command`/`args` in the tool arguments when
  the tool intentionally exposes that surface.
  """

  @behaviour RunicAI.Tool.ExecutionAdapter

  alias RunicAI.Error

  @impl true
  def execute(arguments, opts) when is_map(arguments) and is_list(opts) do
    with {:ok, command} <- command(arguments, opts),
         {:ok, args} <- args(arguments, opts),
         {:ok, cd} <- cd(arguments, opts) do
      do_execute(command, args, cd, opts)
    end
  end

  defp do_execute(command, args, cd, opts) do
    system_opts =
      []
      |> maybe_put(:cd, cd)
      |> Keyword.put(:stderr_to_stdout, Keyword.get(opts, :stderr_to_stdout, true))
      |> Keyword.merge(Keyword.get(opts, :system_opts, []))

    {output, status} = System.cmd(command, args, system_opts)

    result = %{
      command: command,
      args: args,
      output: output,
      exit_status: status
    }

    if status == 0 do
      {:ok, result}
    else
      {:error,
       Error.new(:command_failed, "command execution failed",
         source: __MODULE__,
         details: result,
         retryable?: Keyword.get(opts, :retryable?, false)
       )}
    end
  rescue
    exception ->
      {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp command(arguments, opts) do
    value =
      Keyword.get(opts, :command) || Map.get(arguments, :command) || Map.get(arguments, "command")

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error,
       Error.validation("command adapter requires a non-empty command",
         source: __MODULE__,
         details: %{command: value}
       )}
    end
  end

  defp args(arguments, opts) do
    value =
      Keyword.get(opts, :args, Map.get(arguments, :args) || Map.get(arguments, "args") || [])

    if is_list(value) and Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error,
       Error.validation("command adapter args must be a list of strings",
         source: __MODULE__,
         details: %{args: value}
       )}
    end
  end

  defp cd(arguments, opts) do
    value = Keyword.get(opts, :cd) || Map.get(arguments, :cd) || Map.get(arguments, "cd")

    cond do
      is_nil(value) -> {:ok, nil}
      is_binary(value) and value != "" -> {:ok, value}
      true -> {:error, Error.validation("command adapter cd must be a non-empty string or nil")}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
