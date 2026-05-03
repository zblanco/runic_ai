defmodule Mix.Tasks.RunicAi.Runs do
  @moduledoc """
  Inspect durable RunicAI SQLite runs.

      mix runic_ai.runs --sqlite .runic_ai/runs.db
      mix runic_ai.runs --sqlite .runic_ai/runs.db --run assistant:cli:123
      mix runic_ai.runs --sqlite .runic_ai/runs.db --run assistant:cli:123 --export-jsonl tmp/run.jsonl
  """

  use Mix.Task

  alias RunicAI.Persistence.Export
  alias RunicAI.Persistence.Inspection
  alias RunicAI.Persistence.Queries
  alias RunicAI.Persistence.SQLite

  @shortdoc "Inspect RunicAI SQLite run history"

  @switches [
    sqlite: :string,
    run: :string,
    limit: :integer,
    export_jsonl: :string,
    help: :boolean
  ]

  @impl true
  def run(args) do
    shell = Mix.shell()

    with {:ok, opts} <- parse(args),
         {:ok, _apps} <- Application.ensure_all_started(:runic_ai),
         {:ok, store} <- SQLite.open(database: opts.sqlite, migrate?: true) do
      try do
        inspect_runs(store, opts, shell)
      after
        SQLite.close(store)
      end
    else
      {:help, usage} -> shell.info(usage)
      {:error, reason} -> Mix.raise(error_message(reason))
    end
  end

  defp parse(args) do
    case OptionParser.parse(args, strict: @switches, aliases: [s: :sqlite, r: :run]) do
      {opts, _argv, []} ->
        opts = Map.new(opts)

        cond do
          Map.get(opts, :help) ->
            {:help, usage()}

          not is_binary(Map.get(opts, :sqlite)) ->
            {:error, "--sqlite PATH is required"}

          true ->
            {:ok, Map.put_new(opts, :limit, 20)}
        end

      {_opts, _argv, invalid} ->
        {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  defp inspect_runs(store, %{run: run_id, export_jsonl: path}, shell)
       when is_binary(run_id) and is_binary(path) do
    :ok = Export.write_terminal_jsonl(store, run_id, path)
    shell.info("exported #{run_id} terminal JSONL to #{path}")
  end

  defp inspect_runs(store, %{run: run_id}, shell) when is_binary(run_id) do
    shell.info("Run #{run_id}")

    Enum.each(Inspection.run_timeline(store, run_id), fn event ->
      shell.info(
        "#{event.sequence || "-"} #{event.status} #{event.kind}: #{event.title}#{detail(event)}"
      )
    end)

    case Inspection.failed_runnable(store, run_id) do
      nil -> :ok
      failed -> shell.info("failed runnable: #{inspect(failed, limit: 12)}")
    end
  end

  defp inspect_runs(store, %{limit: limit}, shell) do
    store
    |> Queries.recent_runs(limit: limit)
    |> Enum.each(fn run ->
      shell.info(
        "#{run.id} #{run.status} #{run.workflow_key} #{run.started_at || run.inserted_at}"
      )
    end)
  end

  defp detail(%{detail: nil}), do: ""
  defp detail(%{detail: ""}), do: ""
  defp detail(%{detail: detail}), do: " - #{detail}"

  defp usage do
    """
    Usage:
      mix runic_ai.runs --sqlite PATH [--limit N]
      mix runic_ai.runs --sqlite PATH --run RUN_ID
      mix runic_ai.runs --sqlite PATH --run RUN_ID --export-jsonl PATH
    """
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(reason), do: inspect(reason)
end
