defmodule RunicAI.Terminal.ReviewPrompt do
  @moduledoc """
  Testable terminal review-decision mapping.

  `AgentRunner` owns when to ask. This module owns how terminal input, Owl
  selections, and editor rewrites become `RunicAI.ReviewDecision` values.
  """

  alias RunicAI.Coding.Review
  alias RunicAI.Error
  alias RunicAI.ReviewRequest
  alias RunicAI.Terminal.Event

  @type renderer :: :text | :owl

  @spec decide(ReviewRequest.t(), keyword()) ::
          {:ok, RunicAI.ReviewDecision.t()} | {:error, Error.t()}
  def decide(%ReviewRequest{} = request, opts \\ []) do
    case Keyword.get(opts, :renderer, :text) do
      :owl ->
        decide_with_owl(request, opts)

      _other ->
        decide_with_input(request, input_line(opts), opts)
    end
  end

  @spec decide_with_input(ReviewRequest.t(), String.t() | nil, keyword()) ::
          {:ok, RunicAI.ReviewDecision.t()} | {:error, Error.t()}
  def decide_with_input(request, input, opts \\ [])

  def decide_with_input(%ReviewRequest{} = request, nil, _opts) do
    {:error,
     Error.validation("review prompt reached EOF before a decision",
       source: __MODULE__,
       details: %{resume_key: request.resume_key}
     )}
  end

  def decide_with_input(%ReviewRequest{} = request, input, opts) when is_binary(input) do
    input
    |> parse_choice()
    |> complete_choice(request, opts)
  end

  @spec blocked_event(ReviewRequest.t(), map() | keyword(), String.t()) :: Event.t()
  def blocked_event(%ReviewRequest{} = request, context, reason) when is_binary(reason) do
    context = Map.new(context)

    Event.new!(:hitl,
      session_id: context[:session_id] || context["session_id"],
      agent: :standard,
      phase: :review,
      status: :blocked,
      title: "Review blocked by --approve never",
      detail: reason,
      data: %{
        kind: request.kind,
        checkpoint: request.checkpoint,
        resume_key: request.resume_key,
        details: request.details,
        reason: reason
      },
      raw: request
    )
  end

  defp decide_with_owl(%ReviewRequest{} = request, opts) do
    choices = available_choices(request, editor_available?(opts))
    select_fun = Keyword.get(opts, :select_fun, &Owl.IO.select/2)

    choice =
      select_fun.(choices,
        label: "Review decision",
        render_as: fn choice -> choice_label(choice) end
      )

    complete_choice(choice, request, opts)
  end

  defp input_line(opts) do
    input_fun = Keyword.get(opts, :input_fun, &IO.gets/1)
    input_fun.("> ")
  end

  defp parse_choice(input) do
    case String.trim(String.downcase(input)) do
      value when value in ["a", "approve", "allow", "y", "yes"] -> :approve
      value when value in ["d", "deny", "reject", "n", "no"] -> :deny
      value when value in ["r", "rewrite", "edit", "e"] -> :rewrite
      value when value in ["s", "stop", "cancel", "final_stop"] -> :stop
      _other -> :unknown
    end
  end

  defp complete_choice(:approve, %ReviewRequest{} = request, _opts) do
    {:ok, Review.allow(request, reason: "approved in terminal")}
  end

  defp complete_choice(:deny, %ReviewRequest{} = request, _opts) do
    {:ok, Review.deny(request, reason: "denied in terminal")}
  end

  defp complete_choice(:stop, %ReviewRequest{} = request, _opts) do
    {:ok, Review.final_stop(request, reason: "stopped in terminal")}
  end

  defp complete_choice(:rewrite, %ReviewRequest{} = request, opts) do
    cond do
      :edit not in request.options ->
        {:error,
         Error.validation("review request does not allow rewrite",
           source: __MODULE__,
           details: %{resume_key: request.resume_key, options: request.options}
         )}

      not editor_available?(opts) ->
        {:error,
         Error.validation("review rewrite requires ELIXIR_EDITOR",
           source: __MODULE__,
           details: %{resume_key: request.resume_key}
         )}

      true ->
        rewrite_in_editor(request, opts)
    end
  end

  defp complete_choice(:unknown, %ReviewRequest{} = _request, _opts) do
    {:error,
     Error.validation("unknown review decision",
       source: __MODULE__,
       details: %{valid: ["approve", "deny", "rewrite", "final stop"]}
     )}
  end

  defp rewrite_in_editor(%ReviewRequest{} = request, opts) do
    editor_fun = Keyword.get(opts, :editor_fun, &Owl.IO.open_in_editor/1)

    edited =
      request
      |> rewrite_initial_text()
      |> editor_fun.()

    {:ok, Review.rewrite(request, edited, reason: "rewritten in terminal")}
  rescue
    exception ->
      {:error,
       Error.from_exception(exception,
         kind: :validation,
         source: __MODULE__,
         message: "review rewrite editor failed"
       )}
  end

  defp available_choices(%ReviewRequest{} = request, editor_available?) do
    [
      request_option(request, :approve, :approve),
      request_option(request, :reject, :deny),
      if(editor_available?, do: request_option(request, :edit, :rewrite)),
      request_option(request, :cancel, :stop)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp request_option(%ReviewRequest{options: options}, option, choice) do
    if option in options, do: choice
  end

  defp choice_label(:approve), do: "Approve"
  defp choice_label(:deny), do: "Deny"
  defp choice_label(:rewrite), do: "Rewrite in editor"
  defp choice_label(:stop), do: "Final stop"

  defp editor_available?(opts) do
    Keyword.has_key?(opts, :editor_fun) or System.get_env("ELIXIR_EDITOR") not in [nil, ""]
  end

  defp rewrite_initial_text(%ReviewRequest{subject: subject}) when is_binary(subject), do: subject

  defp rewrite_initial_text(%ReviewRequest{details: details}) do
    details[:command] || details["command"] || details[:path] || details["path"] ||
      inspect(details, pretty: true, limit: 50)
  end
end
