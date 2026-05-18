defmodule RunicAI.Steps.LLMGenerate do
  @moduledoc """
  A Runic step that calls `RunicAI.LLM.generate_text/1`.

  ## Supported Input Shapes

  - `%RunicAI.LLM.Request{}`
  - `%RunicAI.Prompt{}`
  - a string prompt
  - a map with `:model`, `:prompt`, and optional request opts

  Step options can provide default request fields such as `:model` and `:client`,
  which makes it easier to compose behind a `PromptBuilder`.

  ## Output

  `{:ok, %RunicAI.LLM.Result{}}`, `{:retry, %RunicAI.Error{}}`, or
  `{:error, %RunicAI.Error{}}`.

  ## Example

      require Runic

      step = RunicAI.Steps.LLMGenerate.new(name: :call_llm)

      workflow = Runic.workflow(name: :gen, steps: [step])
      workflow = Runic.Workflow.react_until_satisfied(workflow, %{
        model: "anthropic:claude-haiku-4-5",
        prompt: "Hello!",
        client: &my_test_client/3
      })
  """

  require Runic

  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Streaming
  alias RunicAI.Terminal.Event

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :llm_generate)
    defaults = Keyword.drop(opts, [:name])

    Runic.step(
      fn input ->
        with {:ok, request} <- Request.from_input(input, defaults) do
          request
          |> merge_stream_opts(
            name,
            context(:event_sink),
            context(:run_id),
            context(:session_id),
            context(:agent)
          )
          |> Streaming.generate_text()
        end
      end,
      name: name
    )
  end

  defp merge_stream_opts(%Request{} = request, name, event_sink, run_id, session_id, agent) do
    opts =
      [
        stream_sink: terminal_stream_sink(event_sink, run_id, session_id, agent),
        run_id: run_id,
        session_id: session_id || run_id,
        agent: agent || :assistant,
        source_step: name,
        stream_id: stream_id(run_id, name),
        message_id: message_id(run_id, name),
        presentation_group_id: run_id || session_id
      ]
      |> Enum.reject(&blank_opt?/1)

    %{request | opts: Keyword.merge(request.opts, opts)}
  end

  defp terminal_stream_sink(event_sink, run_id, session_id, agent)
       when is_function(event_sink, 1) do
    fn stage ->
      stage
      |> Event.from_stream_stage(
        run_id: run_id,
        session_id: session_id || run_id,
        agent: agent || :assistant
      )
      |> event_sink.()
    end
  end

  defp terminal_stream_sink(_event_sink, _run_id, _session_id, _agent), do: nil

  defp stream_id(nil, _name), do: nil
  defp stream_id(run_id, name), do: "assistant:#{run_id}:#{name}"

  defp message_id(nil, _name), do: nil
  defp message_id(run_id, name), do: "stream:assistant:#{run_id}:#{name}"

  defp blank_opt?({_key, nil}), do: true
  defp blank_opt?({_key, ""}), do: true
  defp blank_opt?({_key, _value}), do: false
end
