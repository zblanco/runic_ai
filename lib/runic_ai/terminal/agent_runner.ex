defmodule RunicAI.Terminal.AgentRunner do
  @moduledoc """
  Orchestrates terminal presentation around backend agent runners.

  Backend modules emit normalized events. This module wires those events to
  plain text output, JSONL export, and review prompts.
  """

  alias RunicAI.Coding.Review
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.AssistantRunner
  alias RunicAI.Terminal.CliOptions
  alias RunicAI.Terminal.JsonlSink
  alias RunicAI.Terminal.RLMRunner
  alias RunicAI.Terminal.Renderer
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

    with {:ok, jsonl} <- JsonlSink.open(options.jsonl_path) do
      try do
        renderer = Renderer.new(options, opts)
        output_fun.(Renderer.render_header(renderer, header_opts(options, renderer)))

        event_sink = event_sink(jsonl, output_fun, renderer)

        if options.interactive? do
          run_interactive(options, event_sink, input_fun, output_fun, renderer)
        else
          run_once(options, event_sink, input_fun, output_fun, renderer)
        end
      after
        JsonlSink.close(jsonl)
      end
    end
  end

  defp run_once(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer) do
    runner_opts = runner_opts(options, event_sink, input_fun, output_fun, renderer)

    result =
      case options.agent do
        :assistant -> AssistantRunner.run(options.objective, runner_opts)
        :standard -> StandardRunner.run(options.objective, runner_opts)
        :rlm -> RLMRunner.run(options.objective, runner_opts)
      end

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
            renderer
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
                   renderer
                 ) do
              {:ok, result} ->
                interactive_loop(options, event_sink, input_fun, output_fun, renderer, result)

              {:error, %Error{} = error} ->
                {:error, error}
            end
        end
    end
  end

  defp run_interactive_objective(options, objective, event_sink, input_fun, output_fun, renderer) do
    options = %{options | objective: objective}
    run_once(options, event_sink, input_fun, output_fun, renderer)
  end

  defp runner_opts(%CliOptions{} = options, event_sink, input_fun, output_fun, renderer) do
    [
      cwd: options.cwd,
      model: options.model,
      client: options.client,
      max_turns: options.max_turns,
      max_runtime_ms: options.max_runtime_ms,
      session_id: options.session_id,
      mode: options.mode,
      input_paths: options.input_paths,
      output_path: options.output_path,
      max_generated_function_tier: max_generated_function_tier(options.allow_generated_functions),
      write_policy: options.write_policy,
      event_sink: event_sink,
      review_decider: review_decider(options, input_fun, output_fun, renderer)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp max_generated_function_tier(:tier0), do: :tier0
  defp max_generated_function_tier(:tier1), do: :tier1
  defp max_generated_function_tier(:tier2_review), do: :tier2

  defp event_sink(jsonl, output_fun, renderer) do
    fn event ->
      _ = JsonlSink.write_event(jsonl, event)

      event
      |> then(&Renderer.render_event(renderer, &1))
      |> output_fun.()

      :ok
    end
  end

  defp review_decider(%CliOptions{} = options, input_fun, output_fun, renderer) do
    fn request, context ->
      case options.approve do
        :never ->
          {:ok, Review.deny(request, reason: "review denied by --approve never")}

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

    case input_fun.("> ") do
      nil ->
        {:error,
         Error.validation("review prompt reached EOF before a decision",
           source: __MODULE__,
           details: %{resume_key: request.resume_key}
         )}

      input ->
        case String.trim(String.downcase(input)) do
          value when value in ["a", "approve", "allow", "y", "yes"] ->
            {:ok, Review.allow(request, reason: "approved in terminal")}

          value when value in ["d", "deny", "reject", "n", "no"] ->
            {:ok, Review.deny(request, reason: "denied in terminal")}

          value when value in ["s", "stop", "cancel", "final_stop"] ->
            {:ok, Review.final_stop(request, reason: "stopped in terminal")}

          _other ->
            {:error,
             Error.validation("unknown review decision",
               source: __MODULE__,
               details: %{input: input, valid: ["approve", "deny", "final stop"]}
             )}
        end
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
      renderer: renderer.name,
      theme: renderer.theme,
      color: renderer.color
    }
  end
end
