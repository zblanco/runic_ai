defmodule RunicAI.Steps.GenerateTurn do
  @moduledoc """
  Generate one conversational turn from a turn request and its assembled prompt.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.LLM
  alias RunicAI.LLM.Streaming
  alias RunicAI.Prompt
  alias RunicAI.Terminal.Event

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :generate_turn)

    Runic.step(
      fn input ->
        {turn_request, prompt} = step_input(input)

        generate(
          turn_request,
          prompt,
          stream_opts(
            name,
            context(:event_sink),
            context(:run_id),
            context(:session_id),
            context(:agent)
          )
        )
      end,
      name: name
    )
  end

  @spec generate(TurnRequest.t(), Prompt.t(), keyword()) ::
          {:ok, RunicAI.LLM.Result.t()}
          | {:retry, RunicAI.Error.t()}
          | {:error, RunicAI.Error.t()}
  def generate(%TurnRequest{} = turn_request, %Prompt{} = prompt, opts \\ []) do
    with {:ok, llm_request} <- TurnRequest.to_llm_request(turn_request, prompt) do
      llm_request
      |> merge_stream_opts(opts)
      |> Streaming.generate_text()
    end
  end

  defp merge_stream_opts(%LLM.Request{} = request, opts) do
    %{request | opts: Keyword.merge(request.opts, Enum.reject(opts, &blank_opt?/1))}
  end

  defp stream_opts(name, event_sink, run_id, session_id, agent) do
    [
      stream_sink: terminal_stream_sink(event_sink, run_id, session_id, agent),
      run_id: run_id,
      session_id: session_id || run_id,
      agent: agent || :standard,
      message_kind: "stream",
      source_step: name,
      stream_id: stream_id(run_id, name),
      message_id: message_id(run_id, name),
      presentation_group_id: run_id || session_id
    ]
  end

  defp terminal_stream_sink(event_sink, run_id, session_id, agent)
       when is_function(event_sink, 1) do
    fn stage ->
      stage
      |> Event.from_stream_stage(
        run_id: run_id,
        session_id: session_id || run_id,
        agent: agent || :standard
      )
      |> event_sink.()
    end
  end

  defp terminal_stream_sink(_event_sink, _run_id, _session_id, _agent), do: nil

  defp step_input([%TurnRequest{} = turn_request, %Prompt{} = prompt]), do: {turn_request, prompt}
  defp step_input({%TurnRequest{} = turn_request, %Prompt{} = prompt}), do: {turn_request, prompt}

  defp stream_id(nil, _name), do: nil
  defp stream_id(run_id, name), do: "assistant:#{run_id}:#{name}"

  defp message_id(nil, _name), do: nil
  defp message_id(run_id, name), do: "stream:assistant:#{run_id}:#{name}"

  defp blank_opt?({_key, nil}), do: true
  defp blank_opt?({_key, ""}), do: true
  defp blank_opt?({_key, _value}), do: false
end
