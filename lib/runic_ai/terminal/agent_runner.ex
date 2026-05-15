defmodule RunicAI.Terminal.AgentRunner do
  @moduledoc """
  Orchestrates terminal presentation around backend agent runners.

  Backend modules emit normalized events. This module wires those events to
  plain text output, JSONL export, and review prompts.
  """

  alias RunicAI.Coding.Review
  alias RunicAI.Error
  alias RunicAI.Persistence.SQLite
  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.AssistantRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.Event
  alias RunicAI.Terminal.InteractiveContext
  alias RunicAI.Terminal.JsonlSink
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Terminal.Renderer
  alias RunicAI.Terminal.ReviewPrompt
  alias RunicAI.Terminal.StandardRunner

  @spec run(CliOptions.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(options, opts \\ [])

  def run(%CliOptions{help?: true}, opts) do
    output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)
    output_fun.(CliOptions.usage())
    {:ok, %{status: :help}}
  end

  def run(%CliOptions{} = options, opts) do
    output_fun = Keyword.get(opts, :output_fun, &IO.puts/1)
    input_fun = Keyword.get(opts, :input_fun, &IO.gets/1)

    with {:ok, jsonl} <- JsonlSink.open(options.jsonl_path),
         {:ok, persistence} <- open_persistence(options, opts) do
      try do
        renderer = Renderer.new(options, opts)
        output_fun.(Renderer.render_header(renderer, header_opts(options, renderer)))

        event_sink = event_sink(jsonl, persistence_store(persistence), output_fun, renderer)

        if options.interactive? do
          run_interactive(options, event_sink, input_fun, output_fun, renderer)
        else
          run_once(options, event_sink, input_fun, output_fun, renderer, opts)
        end
      after
        close_persistence(persistence)
        JsonlSink.close(jsonl)
      end
    end
  end

  defp run_once(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer, opts) do
    runner_opts = runner_opts(options, event_sink, input_fun, output_fun, renderer, opts)

    result =
      case options.agent do
        :assistant -> AssistantRunner.run(options.objective, runner_opts)
        :standard -> StandardRunner.run(options.objective, runner_opts)
        :rlm -> RLMRunner.run(options.objective, runner_opts)
      end

    emit_final_event(result, options, event_sink)
    render_final(result, output_fun, renderer)
    result
  end

  defp run_interactive(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer) do
    initial =
      case options.objective do
        nil ->
          :ok

        "" ->
          :ok

        objective ->
          run_interactive_objective(
            options,
            objective,
            event_sink,
            input_fun,
            output_fun,
            renderer,
            nil
          )
      end

    case initial do
      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        interactive_loop(options, event_sink, input_fun, output_fun, renderer, nil)
    end
  end

  defp interactive_loop(options, event_sink, input_fun, output_fun, renderer, last_result) do
    case input_fun.("runic_ai> ") do
      nil ->
        {:ok, last_result || %{status: :completed}}

      input ->
        objective = String.trim(input)

        cond do
          objective in ["", "\n"] ->
            interactive_loop(options, event_sink, input_fun, output_fun, renderer, last_result)

          objective in [":quit", "/quit", "quit"] ->
            {:ok, last_result || %{status: :completed}}

          true ->
            case run_interactive_objective(
                   options,
                   objective,
                   event_sink,
                   input_fun,
                   output_fun,
                   renderer,
                   last_result
                 ) do
              {:ok, result} ->
                interactive_loop(options, event_sink, input_fun, output_fun, renderer, result)

              {:error, %Error{} = error} ->
                {:error, error}
            end
        end
    end
  end

  defp run_interactive_objective(
         options,
         objective,
         event_sink,
         input_fun,
         output_fun,
         renderer,
         last_result
       ) do
    options = %{options | objective: InteractiveContext.add_carryover(objective, last_result)}
    run_once(options, event_sink, input_fun, output_fun, renderer, [])
  end

  defp runner_opts(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer, opts) do
    [
      cwd: options.cwd,
      model: options.model,
      client: options.client,
      max_turns: options.max_turns,
      max_runtime_ms: options.max_runtime_ms,
      session_id: options.session_id,
      run_id: Keyword.get(opts, :run_id),
      conversation_history: Keyword.get(opts, :conversation_history, []),
      mode: options.mode,
      input_paths: options.input_paths,
      output_path: options.output_path,
      max_generated_function_tier: max_generated_function_tier(options.allow_generated_functions),
      write_policy: options.write_policy,
      event_sink: event_sink,
      review_decider:
        Keyword.get(opts, :review_decider) ||
          review_decider(options, input_fun, output_fun, renderer, event_sink),
      run_fun: Keyword.get(opts, :run_fun)
    ]
    |> Keyword.merge(CliOptions.concurrency_opts(options))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp max_generated_function_tier(:tier0), do: :tier0
  defp max_generated_function_tier(:tier1), do: :tier1
  defp max_generated_function_tier(:tier2_review), do: :tier2

  defp event_sink(jsonl, persistence, output_fun, renderer) do
    fn event ->
      _ = JsonlSink.write_event(jsonl, event)
      _ = write_persistence_event(persistence, event)

      event
      |> then(&Renderer.render_event(renderer, &1))
      |> output_fun.()

      :ok
    end
  end

  defp open_persistence(%CliOptions{} = options, opts) do
    case Keyword.fetch(opts, :persistence) do
      {:ok, persistence} ->
        {:ok, {:external, persistence}}

      :error ->
        open_cli_persistence(options)
    end
  end

  defp open_cli_persistence(%CliOptions{persistence: :none}), do: {:ok, {:external, nil}}

  defp open_cli_persistence(%CliOptions{persistence: :memory}) do
    case SQLite.open(database: ":memory:", migrate?: true) do
      {:ok, store} -> {:ok, {:owned, store}}
      {:error, _reason} = error -> error
    end
  end

  defp open_cli_persistence(%CliOptions{persistence: :sqlite, sqlite_path: path}) do
    case SQLite.open(database: path, migrate?: true) do
      {:ok, store} -> {:ok, {:owned, store}}
      {:error, _reason} = error -> error
    end
  end

  defp persistence_store({_ownership, store}), do: store

  defp close_persistence({:owned, %RunicAI.Persistence.SQLite.Store{} = store}),
    do: SQLite.close(store)

  defp close_persistence(_persistence), do: :ok

  defp write_persistence_event(%RunicAI.Persistence.SQLite.Store{} = store, event) do
    with {:ok, persisted} <- SQLite.record_terminal_event(store, event) do
      RunicAI.Workbench.broadcast_terminal_event(persisted)
      {:ok, persisted}
    end
  end

  defp write_persistence_event(_persistence, _event), do: :ok

  defp review_decider(%CliOptions{} = options, input_fun, output_fun, renderer, event_sink) do
    fn request, context ->
      case options.approve do
        :never ->
          reason = "review denied by --approve never"
          emit_review_blocked(event_sink, request, context, reason)
          {:ok, Review.deny(request, reason: reason)}

        :safe ->
          if safe_review?(request) do
            {:ok, Review.allow(request, reason: "review approved by --approve safe")}
          else
            ask_review(request, context, input_fun, output_fun, renderer)
          end

        :ask ->
          ask_review(request, context, input_fun, output_fun, renderer)
      end
    end
  end

  defp ask_review(%ReviewRequest{} = request, _context, input_fun, output_fun, renderer) do
    output_fun.(Renderer.render_review_prompt(renderer, request))

    prompt_opts =
      if renderer.name == :owl do
        [renderer: :owl]
      else
        [renderer: :text, input_fun: input_fun]
      end

    ReviewPrompt.decide(request, prompt_opts)
  end

  defp emit_review_blocked(event_sink, request, context, reason) do
    event = ReviewPrompt.blocked_event(request, Map.take(context, [:session_id]), reason)

    event_sink.(event)
  end

  defp emit_final_event({:ok, result}, %CliOptions{} = options, event_sink) when is_map(result) do
    status = Map.get(result, :status, :ok)

    event =
      Event.new!(:summary,
        session_id: Map.get(result, :session_id) || options.session_id,
        agent: options.agent,
        phase: :final,
        status: terminal_status(status),
        title: "Agent finished",
        detail: "status: #{status}",
        data: %{
          run_id: Map.get(result, :run_id) || Map.get(result, :session_id) || options.session_id,
          result_status: status,
          objective_status: objective_status(result)
        }
      )

    event_sink.(event)
  end

  defp emit_final_event({:error, %Error{} = error}, %CliOptions{} = options, event_sink) do
    artifact_outcome = Event.artifact_outcome_from_error(error)

    event =
      Event.new!(:error,
        session_id: options.session_id,
        agent: options.agent,
        phase: :final,
        status: :error,
        title: "Agent failed",
        detail: error.message,
        data:
          %{
            run_id: options.session_id,
            error: Map.take(error, [:kind, :message, :details, :source, :retryable?, :metadata])
          }
          |> maybe_put(:artifact_outcome, artifact_outcome)
          |> maybe_put(:suggested_paths, suggested_paths(artifact_outcome))
      )

    event_sink.(event)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp suggested_paths(nil), do: nil
  defp suggested_paths(%{suggested_paths: paths}) when is_list(paths), do: paths
  defp suggested_paths(%{"suggested_paths" => paths}) when is_list(paths), do: paths
  defp suggested_paths(_outcome), do: nil

  defp terminal_status(status) when status in [:blocked, "blocked"], do: :blocked
  defp terminal_status(status) when status in [:error, :failed, "error", "failed"], do: :error
  defp terminal_status(_status), do: :ok

  defp objective_status(result) do
    case Map.get(result, :scorecard, Map.get(result, :objective_scorecard, %{})) do
      %{objective_status: status} -> status
      %{"objective_status" => status} -> status
      _other -> nil
    end
  end

  defp safe_review?(%ReviewRequest{} = request) do
    request.metadata[:safe?] in [true, "true"] or
      request.details[:safe?] in [true, "true"] or
      request.details[:risk] in [:low, "low"]
  end

  defp render_final({:ok, result}, output_fun, renderer) when is_map(result) do
    result
    |> then(&Renderer.render_final_report(renderer, &1))
    |> output_fun.()
  end

  defp render_final({:error, %Error{} = error}, output_fun, _renderer) do
    output_fun.("Final report\n  status: error\n  error: #{error.message}")
  end

  defp header_opts(%CliOptions{} = options, %Renderer{} = renderer) do
    %{
      session_id: options.session_id,
      cwd: options.cwd,
      agent: options.agent,
      model: options.model || "default",
      client: options.client_label || "default",
      mode: options.mode,
      approve: options.approve,
      detail: options.detail,
      jsonl_path: options.jsonl_path,
      sqlite_path: options.sqlite_path,
      persistence: options.persistence,
      renderer: renderer.name,
      theme: renderer.theme,
      color: renderer.color
    }
    |> Map.merge(Map.new(CliOptions.concurrency_opts(options)))
  end
end
