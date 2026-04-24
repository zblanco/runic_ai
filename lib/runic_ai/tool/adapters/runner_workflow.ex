defmodule RunicAI.Tool.Adapters.RunnerWorkflow do
  @moduledoc """
  Tool execution adapter that invokes a child Runic workflow through `Runic.Runner`.
  """

  @behaviour RunicAI.Tool.ExecutionAdapter

  alias Runic.Workflow
  alias RunicAI.Error

  @default_runner RunicAI.Runtime.Runner

  @impl true
  def execute(arguments, opts) when is_map(arguments) and is_list(opts) do
    with {:ok, runner} <- runner(opts),
         {:ok, workflow} <- workflow(arguments, opts),
         {:ok, workflow_id} <- workflow_id(arguments, opts),
         :ok <- start_workflow(runner, workflow_id, workflow, opts),
         :ok <- run_workflow(runner, workflow_id, arguments, opts),
         {:ok, output} <- fetch_output(runner, workflow_id, opts) do
      if Keyword.get(opts, :stop?, true) do
        _ = Runic.Runner.stop(runner, workflow_id, persist: Keyword.get(opts, :persist?, false))
      end

      {:ok, output}
    end
  end

  defp runner(opts) do
    case Keyword.get(opts, :runner, @default_runner) do
      runner when is_atom(runner) ->
        {:ok, runner}

      other ->
        {:error,
         Error.validation("runner workflow adapter runner must be an atom",
           source: __MODULE__,
           details: %{runner: other}
         )}
    end
  end

  defp workflow(arguments, opts) do
    cond do
      match?(%Workflow{}, Keyword.get(opts, :workflow)) ->
        {:ok, Keyword.fetch!(opts, :workflow)}

      is_function(Keyword.get(opts, :workflow_builder), 1) ->
        case Keyword.fetch!(opts, :workflow_builder).(arguments) do
          %Workflow{} = workflow ->
            {:ok, workflow}

          other ->
            {:error,
             Error.validation("runner workflow builder must return a Runic.Workflow",
               source: __MODULE__,
               details: %{workflow: other}
             )}
        end

      true ->
        {:error,
         Error.validation("runner workflow adapter requires :workflow or :workflow_builder",
           source: __MODULE__
         )}
    end
  end

  defp workflow_id(arguments, opts) do
    value =
      Keyword.get(opts, :workflow_id) ||
        Map.get(arguments, :workflow_id) ||
        Map.get(arguments, "workflow_id") ||
        {RunicAI.Tool.Adapters.RunnerWorkflow, System.unique_integer([:positive])}

    {:ok, value}
  end

  defp start_workflow(runner, workflow_id, workflow, opts) do
    runner_opts =
      opts
      |> Keyword.get(:runner_opts, [])
      |> Keyword.put_new(:executor, :inline)

    case Runic.Runner.start_workflow(runner, workflow_id, workflow, runner_opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp run_workflow(runner, workflow_id, arguments, opts) do
    input = Keyword.get(opts, :input, arguments)
    run_opts = Keyword.get(opts, :run_opts, [])

    case Runic.Runner.run(runner, workflow_id, input, run_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.from_reason(reason, source: __MODULE__)}
    end
  end

  defp fetch_output(runner, workflow_id, opts) do
    cond do
      component = Keyword.get(opts, :component) ->
        with {:ok, results} <-
               Runic.Runner.get_results(runner, workflow_id, components: [component]) do
          {:ok, Map.get(results, component)}
        end

      Keyword.get(opts, :structured?, false) ->
        Runic.Runner.get_results(runner, workflow_id, [])

      true ->
        with {:ok, results} <- Runic.Runner.get_results(runner, workflow_id) do
          {:ok, List.last(results)}
        end
    end
  end
end
