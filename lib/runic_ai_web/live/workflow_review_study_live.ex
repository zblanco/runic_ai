defmodule RunicAIWeb.WorkflowReviewStudyLive do
  @moduledoc false

  use RunicAIWeb, :live_view

  alias RunicAI.Workbench
  alias RunicAI.Workflows.ReviewComprehensionStudy
  alias RunicAI.Workflows.SemanticDiffPresenter

  @impl true
  def mount(%{"case_id" => case_id} = params, _session, socket) do
    participant_id = normalize_participant(Map.get(params, "participant"))
    participant_kind = participant_kind(params, participant_id)

    case ReviewComprehensionStudy.fetch_case(case_id) do
      {:ok, study_case} ->
        arm = ReviewComprehensionStudy.assigned_arm(participant_id, case_id)

        {:ok,
         socket
         |> assign(:page_title, "Workflow Review Study")
         |> assign(:study_case, study_case)
         |> assign(:participant_id, participant_id)
         |> assign(:participant_kind, participant_kind)
         |> assign(:arm, arm)
         |> assign(:started_at_ms, nil)
         |> assign(:actions, 0)
         |> assign(:result, nil)
         |> assign(:record_error, nil)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Unknown workflow review study case")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("begin_review_study", _params, %{assigns: %{started_at_ms: nil}} = socket) do
    {:noreply,
     socket
     |> assign(:started_at_ms, System.monotonic_time(:millisecond))
     |> assign(:actions, 1)}
  end

  def handle_event("begin_review_study", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event(
        "submit_review_study",
        %{"answers" => answers},
        %{assigns: %{started_at_ms: started_at_ms, result: nil}} = socket
      )
      when is_integer(started_at_ms) do
    elapsed_ms = max(System.monotonic_time(:millisecond) - started_at_ms, 0)
    actions = socket.assigns.actions + 1
    result = ReviewComprehensionStudy.score(socket.assigns.study_case, answers)

    case ReviewComprehensionStudy.record(
           Workbench.store!(),
           socket.assigns.study_case,
           socket.assigns.participant_id,
           socket.assigns.arm,
           answers,
           elapsed_ms: elapsed_ms,
           actions: actions,
           participant_kind: socket.assigns.participant_kind
         ) do
      {:ok, _rows} ->
        {:noreply,
         socket
         |> assign(:result, Map.put(result, :elapsed_ms, elapsed_ms))
         |> assign(:actions, actions)}

      {:error, reason} ->
        {:noreply, assign(socket, :record_error, inspect(reason))}
    end
  end

  def handle_event("submit_review_study", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:projection, SemanticDiffPresenter.present(assigns.study_case))
      |> assign(:next_case, next_case(assigns.study_case.id))

    ~H"""
    <main class="min-h-screen bg-rune-ink px-5 py-10 text-rune-text">
      <section class="mx-auto max-w-3xl rounded-3xl border border-rune-text/10 bg-black/25 p-6 shadow-2xl runic-frost">
        <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-rune-cyan">
          Counterbalanced workflow review study
        </p>
        <h1 class="mt-2 text-2xl font-semibold">{@study_case.title}</h1>
        <p class="mt-2 text-sm leading-6 text-rune-text-soft">
          Review the assigned representation once, then answer three questions. The result records correctness, elapsed attention time, and review actions. It does not execute the proposed change.
        </p>

        <div class="mt-5 flex flex-wrap gap-2 font-mono text-[10px] text-rune-muted">
          <span class="rounded-full border border-rune-text/10 px-3 py-1">
            participant {@participant_id}
          </span>
          <span class="rounded-full border border-rune-text/10 px-3 py-1">
            case {@study_case.id}
          </span>
          <span class="rounded-full border border-rune-text/10 px-3 py-1">
            assigned format {format_label(@arm)}
          </span>
        </div>

        <button
          :if={is_nil(@started_at_ms)}
          id="begin-review-study"
          type="button"
          phx-click="begin_review_study"
          class="mt-8 rounded-full border border-rune-primary/30 bg-rune-primary/15 px-5 py-2 text-sm font-semibold text-rune-primary-soft"
        >
          Begin timed review
        </button>

        <div :if={@started_at_ms && is_nil(@result)} id="review-study-task" class="mt-7 space-y-5">
          <section class="rounded-2xl border border-rune-text/10 bg-rune-ink/50 p-4">
            <p class="font-mono text-[10px] uppercase tracking-wide text-rune-muted">Objective</p>
            <p class="mt-1 text-sm leading-6">{@study_case.objective}</p>
            <p class="mt-3 font-mono text-[10px] uppercase tracking-wide text-rune-muted">
              Existing context
            </p>
            <p class="mt-1 text-sm leading-6 text-rune-text-soft">{@study_case.context}</p>
          </section>

          <section
            :if={@arm == :semantic}
            id="study-semantic-view"
            data-study-arm="semantic"
            class="rounded-2xl border border-rune-cyan/20 bg-rune-cyan/[0.035] p-4"
          >
            <p class="font-mono text-[10px] uppercase tracking-wide text-rune-cyan">
              Proposed semantic changes
            </p>
            <p class="mt-1 text-xs text-rune-muted">{@projection.summary}</p>
            <ol class="mt-3 space-y-2">
              <li
                :for={change <- @projection.changes}
                class="grid grid-cols-[auto_1fr] gap-3 rounded-xl border border-rune-text/10 bg-black/20 p-3"
              >
                <span class="h-fit rounded-full border border-rune-cyan/20 px-2 py-0.5 font-mono text-[9px] uppercase text-rune-cyan">
                  {change.kind}
                </span>
                <span>
                  <strong class="block text-sm">{change.title}</strong>
                  <span class="mt-1 block text-xs leading-5 text-rune-text-soft">{change.detail}</span>
                </span>
              </li>
            </ol>
            <div
              :for={diagnostic <- @study_case.diagnostics}
              class="mt-3 rounded-xl border border-rune-warning/25 bg-rune-warning/10 p-3"
            >
              <p class="font-mono text-[10px] uppercase text-rune-warning">
                {diagnostic.severity} · {diagnostic.code}
              </p>
              <p class="mt-1 text-xs leading-5 text-rune-text-soft">{diagnostic.message}</p>
            </div>
          </section>

          <section
            :if={@arm == :raw_json}
            id="study-raw-json-view"
            data-study-arm="raw_json"
            class="rounded-2xl border border-rune-text/10 bg-black/20 p-4"
          >
            <p class="font-mono text-[10px] uppercase tracking-wide text-rune-muted">
              Proposed revision data
            </p>
            <pre class="mt-3 max-h-[420px] overflow-auto whitespace-pre-wrap rounded-xl bg-rune-ink/80 p-4 font-mono text-[11px] leading-5 text-rune-text-soft">{Jason.encode!(
                ReviewComprehensionStudy.public_payload(@study_case),
                pretty: true
              )}</pre>
          </section>

          <form id="review-study-form" phx-submit="submit_review_study" class="space-y-4">
            <fieldset
              :for={question <- @study_case.questions}
              class="rounded-2xl border border-rune-text/10 bg-black/20 p-4"
            >
              <legend class="px-1 text-sm font-semibold">{question.prompt}</legend>
              <label
                :for={option <- question.options}
                class="mt-2 flex cursor-pointer items-center gap-2 text-sm text-rune-text-soft"
              >
                <input
                  type="radio"
                  name={"answers[#{question.id}]"}
                  value={option.value}
                  required
                  class="accent-rune-cyan"
                />
                {option.label}
              </label>
            </fieldset>
            <button
              type="submit"
              class="rounded-full border border-rune-primary/30 bg-rune-primary/15 px-5 py-2 text-sm font-semibold text-rune-primary-soft"
            >
              Submit review answers
            </button>
          </form>
        </div>

        <section
          :if={@result}
          id="review-study-result"
          class="mt-7 rounded-2xl border border-rune-primary/25 bg-rune-primary/[0.06] p-5"
        >
          <p class="font-mono text-[10px] uppercase tracking-wide text-rune-primary-soft">
            Result recorded
          </p>
          <p class="mt-2 text-lg font-semibold">
            {@result.correct}/{@result.total} correct · {@result.elapsed_ms} ms
          </p>
          <p class="mt-2 text-sm leading-6 text-rune-text-soft">
            The assigned arm, answers, correctness, elapsed time, and action count are retained in the workflow evaluation ledger.
          </p>
          <.link
            :if={@next_case}
            navigate={
              ~p"/workflow-review-study/#{@next_case}?participant=#{@participant_id}&source=#{@participant_kind}"
            }
            class="mt-4 inline-block rounded-full border border-rune-cyan/25 px-4 py-2 text-sm text-rune-cyan"
          >
            Continue to the counterbalanced case
          </.link>
        </section>

        <p :if={@record_error} class="mt-4 text-sm text-rune-error">
          Could not record result: {@record_error}
        </p>
      </section>
    </main>
    """
  end

  defp next_case(case_id) do
    ids = Enum.map(ReviewComprehensionStudy.cases(), & &1.id)

    case Enum.find_index(ids, &(&1 == case_id)) do
      nil -> nil
      index -> Enum.at(ids, index + 1)
    end
  end

  defp normalize_participant(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
    |> String.slice(0, 64)
    |> case do
      "" -> "local-operator"
      participant -> participant
    end
  end

  defp normalize_participant(_value), do: "local-operator"

  defp participant_kind(%{"source" => "scripted"}, _participant_id), do: :scripted

  defp participant_kind(_params, participant_id) do
    if Enum.any?(
         ["browser-proof-", "scripted-", "automation-"],
         &String.starts_with?(participant_id, &1)
       ) do
      :scripted
    else
      :human
    end
  end

  defp format_label(:semantic), do: "A"
  defp format_label(:raw_json), do: "B"
end
