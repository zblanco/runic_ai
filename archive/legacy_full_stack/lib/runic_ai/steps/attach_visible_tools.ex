defmodule RunicAI.Steps.AttachVisibleTools do
  @moduledoc """
  Attach the selected visible tools to a turn request's LLM options.
  """

  require Runic

  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Tool.Selection
  alias RunicAI.Tool.RequirementPolicy

  def new(opts \\ []) do
    name = Keyword.get(opts, :name, :attach_visible_tools)
    options = Keyword.drop(opts, [:name])

    Runic.step(
      fn %TurnRequest{} = turn_request, %Selection{} = selection ->
        attach!(turn_request, selection, options)
      end,
      name: name
    )
  end

  @spec attach(TurnRequest.t(), Selection.t(), keyword()) ::
          {:ok, TurnRequest.t()} | {:error, RunicAI.Error.t()}
  def attach(%TurnRequest{} = turn_request, %Selection{} = selection, opts \\ []) do
    with {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, selection} <- Selection.validate(selection),
         {:ok, tool_choice} <- resolve_tool_choice(turn_request, selection, opts),
         {:ok, req_tools} <- Selection.to_req_llm_tools(selection) do
      llm_opts =
        turn_request.llm_opts
        |> Keyword.delete(:tools)
        |> Keyword.delete(:tool_choice)
        |> maybe_put_tools(req_tools)
        |> maybe_put_override(:tool_choice, tool_choice)

      TurnRequest.new(turn_request.state,
        input_message: turn_request.input_message,
        history_window: turn_request.history_window,
        pinned_messages: turn_request.pinned_messages,
        observations: turn_request.observations,
        model: turn_request.model,
        llm_opts: llm_opts,
        metadata: turn_request.metadata
      )
    end
  end

  @spec attach!(TurnRequest.t(), Selection.t(), keyword()) :: TurnRequest.t()
  def attach!(%TurnRequest{} = turn_request, %Selection{} = selection, opts \\ []) do
    case attach(turn_request, selection, opts) do
      {:ok, attached_turn_request} -> attached_turn_request
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  defp maybe_put_tools(llm_opts, []), do: Keyword.delete(llm_opts, :tools)
  defp maybe_put_tools(llm_opts, req_tools), do: Keyword.put(llm_opts, :tools, req_tools)

  defp maybe_put_override(llm_opts, _key, nil), do: llm_opts
  defp maybe_put_override(llm_opts, key, value), do: Keyword.put(llm_opts, key, value)

  defp resolve_tool_choice(%TurnRequest{} = turn_request, %Selection{} = selection, opts) do
    cond do
      Keyword.has_key?(opts, :tool_choice) and Keyword.has_key?(opts, :tool_requirement) ->
        {:error,
         RunicAI.Error.validation(
           "attach_visible_tools accepts either :tool_choice or :tool_requirement, not both",
           source: __MODULE__
         )}

      Keyword.has_key?(opts, :tool_requirement) ->
        RequirementPolicy.resolve_tool_choice(
          Keyword.get(opts, :tool_requirement),
          turn_request,
          selection
        )

      true ->
        {:ok, Keyword.get(opts, :tool_choice)}
    end
  end
end
