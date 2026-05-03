# Minimum Compelling CLI Terminal Interface Implementation Plan

Status: Option A vertical slice implemented; richer interactive resume,
rewrite review decisions, and future TUI renderers remain deferred

Date: 2026-04-30

Last verified: 2026-04-30 (`mix compile --warnings-as-errors`;
`mix test test/runic_ai/terminal`; `mix test`)

Motivated by:

- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`
- `.docs/028-standard-coding-agent-ooda-reliability-implementation-plan.md`
- `.docs/027-rlm-coding-agent-reliability-implementation-plan.md`
- Existing supervised standard-agent session runtime in `RunicAI.Runtime`.

Depends on:

- `.docs/024-coding-harness-and-tools-implementation-plan.md`
- `.docs/025-standard-coding-agent-implementation-plan.md`
- `.docs/026-rlm-coding-agent-implementation-plan.md`
- `.docs/027-rlm-coding-agent-reliability-implementation-plan.md`
- `.docs/028-standard-coding-agent-ooda-reliability-implementation-plan.md`

References:

- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`
- `lib/runic_ai/coding/session.ex`
- `lib/runic_ai/coding/review.ex`
- `lib/runic_ai/runtime.ex`
- `lib/runic_ai/runtime/session_server.ex`
- `lib/runic_ai/coding/rlm/agent.ex`

## Goal

Build the first RunicAI terminal harness as a no-dependency Mix task and
framework-neutral presentation layer.

The first implementation path is Option A from the exploration document:
`mix runic_ai.agent` with plain ANSI/text output, JSONL export, live
standard-agent runtime events, and RLM result presentation. It should prove the
agent semantics before introducing Owl, Termite, TermUI, or any alternate-screen
terminal framework.

The phase is successful when RunicAI can answer:

"Can a developer run a local standard or RLM coding objective from the terminal,
watch honest agent progress, handle review gates, inspect final evidence, and
export a machine-readable trace without a new UI dependency?"

## Product Shape

Initial command shape:

```sh
mix runic_ai.agent "add a health check endpoint" --agent standard --cwd .
mix runic_ai.agent "investigate failing checkout tests" --agent rlm --cwd .
mix runic_ai.agent --interactive --agent standard --cwd .
mix runic_ai.agent "summarize this repo" --agent standard --jsonl trace.jsonl
```

Initial option set:

- `--agent standard|rlm`
- `--cwd PATH`
- `--model MODEL`
- `--client CLIENT_ALIAS`
- `--interactive`
- `--jsonl PATH`
- `--detail hidden|collapsed|expanded`
- `--approve never|safe|ask`
- `--max-turns N`
- `--max-runtime-ms N`
- `--session-id ID`

The default should be single-query mode because it is easiest to test, easiest
to use in CI, and enough to validate the event timeline. Interactive mode can
reuse the same runner once one-shot execution is stable.

## Design Principles

- Keep Option A dependency-free.
- Make the presentation layer the stable contract, not the terminal renderer.
- Do not render raw runtime structs directly from the Mix task.
- Keep `RunicAI.Terminal.Event` framework-neutral so future Owl, Termite,
  TermUI, web, Livebook, or JSON renderers can consume the same event stream.
- Keep terminal modules out of core coding-agent decision logic.
- Do not make RLM core emit terminal-specific structs. RLM live hooks should
  emit raw stage data that the terminal runner normalizes.
- Use the supervised runtime path for the standard agent:
  `RunicAI.Coding.Session.spec/2`, `RunicAI.Runtime.start_session/1`,
  `RunicAI.Runtime.subscribe/1`, `RunicAI.Runtime.submit/2`, and
  `RunicAI.Runtime.drain/2`.
- Treat HITL as a core terminal workflow, not a final-report footnote.
- Token streaming is not required for this phase. Live trace events are the
  first streaming surface.
- Keep presenter output deterministic enough to unit test with
  `ExUnit.CaptureIO`.

## Presentation Layer Contract

The terminal harness should normalize standard-agent runtime messages, RLM
stage data, final RLM artifacts, and future token chunks into one small event
vocabulary.

```elixir
%RunicAI.Terminal.Event{
  id: String.t(),
  at: DateTime.t(),
  session_id: String.t() | nil,
  agent: :standard | :rlm,
  kind:
    :status
    | :message
    | :tool
    | :hitl
    | :rlm_plan
    | :rlm_node
    | :verification
    | :repair
    | :subagent
    | :chunk
    | :error
    | :summary,
  phase: atom() | nil,
  status: :pending | :running | :ok | :review | :waiting | :blocked | :error,
  title: String.t(),
  detail: String.t() | nil,
  data: map(),
  raw: term()
}
```

Renderer responsibilities:

- Text presenter renders compact human output.
- JSONL sink writes one normalized event per line.
- Future Owl, Termite, TermUI, or web renderers consume the same event structs.
- Presenters may hide, collapse, or expand details, but they must not decide
  agent control flow.

Initial source mappings:

| Source | Terminal event |
| --- | --- |
| `{:runic_ai_runtime, id, :trace_event, event}` | normalized trace event |
| `{:runic_ai_runtime, id, :output, output}` | message, HITL, wait, or summary |
| `{:runic_ai_runtime, id, :snapshot, session}` | status and final summary |
| RLM `WorkflowProposal` | `:rlm_plan`, phase `:proposed` |
| RLM validation report | `:rlm_plan`, phase `:validated` |
| RLM compiled workflow | `:rlm_plan`, phase `:compiled` |
| RLM episodes | `:rlm_node`, phase `:episode` |
| RLM progress gate or scorecard | `:summary`, phase `:scorecard` |
| Future LLM token chunk | `:chunk`, phase `:assistant` or `:thinking` |

## Proposed Namespace

```text
lib/mix/tasks/
  runic_ai.agent.ex

lib/runic_ai/terminal/
  agent_runner.ex
  cli_options.ex
  event.ex
  event_presenter.ex
  jsonl_sink.ex
  standard_runner.ex
  rlm_runner.ex

test/runic_ai/terminal/
  cli_options_test.exs
  event_test.exs
  event_presenter_test.exs
  jsonl_sink_test.exs
  standard_runner_test.exs
  rlm_runner_test.exs
```

Module responsibilities:

- `Mix.Tasks.RunicAi.Agent` parses CLI arguments, starts the application, and
  delegates to `RunicAI.Terminal.AgentRunner`.
- `RunicAI.Terminal.CliOptions` owns option parsing and validation independent
  of Mix shell side effects.
- `RunicAI.Terminal.AgentRunner` chooses the standard or RLM runner and wires
  presenters/sinks.
- `RunicAI.Terminal.Event` owns the normalized event struct and constructors.
- `RunicAI.Terminal.EventPresenter` formats events and final reports as plain
  text or ANSI text.
- `RunicAI.Terminal.JsonlSink` writes normalized events with JSON-safe payloads.
- `RunicAI.Terminal.StandardRunner` runs the supervised standard coding agent.
- `RunicAI.Terminal.RLMRunner` runs the RLM coding agent and normalizes final
  artifacts, then later live stage events.

## Phase 0: Option A Skeleton And Event Contract

Deliverables:

- [x] Add `RunicAI.Terminal.Event` with the normalized fields, supported
      `kind`, `status`, and `agent` values.
- [x] Add constructor helpers that populate stable ids and timestamps.
- [x] Add source normalizers for generic runtime trace events, outputs, and
      snapshots without terminal rendering side effects.
- [x] Add source normalizers for RLM result artifacts:
      proposal, validation report, compiled workflow, episodes, repairs,
      scorecards, and persistence refs.
- [x] Add event redaction rules for large output, binary content, and
      potentially sensitive raw payloads.
- [x] Keep the raw source term available in memory for debugging but exclude or
      sanitize it from JSONL by default.

Validation:

- [x] Unit test event construction and validation.
- [x] Unit test standard runtime event mappings for known trace/output kinds.
- [x] Unit test RLM artifact mappings using deterministic fixture data.
- [x] Unit test redaction and output-size caps.

## Phase 1: Plain Text Presenter And JSONL Sink

Deliverables:

- [x] Add `RunicAI.Terminal.EventPresenter.render_event/2`.
- [x] Add `RunicAI.Terminal.EventPresenter.render_final_report/2`.
- [x] Support `detail: :hidden | :collapsed | :expanded`.
- [x] Render a stable header with session id, workspace, agent mode,
      model/client, policy, and trace/export path.
- [x] Render tool calls with name, argument preview, status, changed files, and
      concise output preview.
- [x] Render verification, repair, HITL, wait, and final scorecard events.
- [x] Render RLM proposal and execution graphs as compact text adjacency lists.
- [x] Add `RunicAI.Terminal.JsonlSink` with `open`, `write_event`, and `close`
      operations, or a small process-free equivalent.
- [x] Ensure JSONL lines include normalized fields and JSON-safe `data`, not
      arbitrary structs.

Validation:

- [x] Unit test presenter output with `ExUnit.CaptureIO`.
- [x] Unit test detail modes.
- [x] Unit test JSONL output can be decoded line by line.
- [x] Unit test long details are capped without corrupting UTF-8.

## Phase 2: Mix Task And CLI Option Parsing

Deliverables:

- [x] Add `Mix.Tasks.RunicAi.Agent` for `mix runic_ai.agent`.
- [x] Add `RunicAI.Terminal.CliOptions` with strict option parsing.
- [x] Validate `--agent`, `--cwd`, `--detail`, `--approve`,
      `--max-turns`, and `--max-runtime-ms`.
- [x] Accept the objective as the remaining positional argument in single-query
      mode.
- [x] Require either an objective or `--interactive`.
- [x] Pass model/client options through to the selected agent path without
      hard-coding provider assumptions.
- [x] Create parent directories for `--jsonl PATH` only when the path is inside
      the workspace or another explicitly allowed output directory.
- [x] Return nonzero Mix task failures for invalid options, runner errors, and
      objective-unsatisfied final states when the runner can prove that status.

Validation:

- [x] Unit test valid option combinations.
- [x] Unit test invalid option combinations and error messages.
- [x] Unit test single-query positional objective parsing.
- [x] Manual smoke: `mix runic_ai.agent --help`.

## Phase 3: Live Standard-Agent Runner

Deliverables:

- [x] Build a standard-agent `SessionSpec` with
      `RunicAI.Coding.Session.spec/2`.
- [x] Start the supervised session through `RunicAI.Runtime.start_session/1`.
- [x] Subscribe the CLI process with `RunicAI.Runtime.subscribe/1`.
- [x] Submit the objective and drain the session in a worker task so the parent
      process can keep receiving subscriber messages.
- [x] Normalize and render these messages live:
      `:trace_event`, `:output`, and `:snapshot`.
- [x] Render a final report from `RunicAI.Coding.Session.snapshot/2` and
      runtime outputs.
- [x] Stop or unsubscribe from the runtime session at the end of one-shot runs
      unless the user requested a resumable session.
- [x] Propagate `--max-turns` and `--max-runtime-ms` into the runtime policy or
      runner budget in a way that matches existing harness semantics.
- [ ] Make interrupted or timed-out sessions report partial evidence, changed
      files, and residual risk instead of only returning an error.

Validation:

- [x] Unit test the receive loop with scripted runtime messages.
- [x] Integration test a scripted standard-agent session that emits visible
      tools, one tool call, one observation, and a final answer.
- [ ] Integration test a failing or budget-exhausted standard-agent session
      renders partial evidence.
- [ ] Manual smoke:
      `mix runic_ai.agent "summarize this repo's coding harness" --agent standard --cwd .`.

## Phase 4: HITL Review Loop

Deliverables:

- [x] Detect `ReviewRequest` values in runtime outputs and snapshots.
- [x] Render a review prompt with reason, tool/action, path/command preview,
      and risk summary.
- [x] Support `--approve never` by denying or blocking review-gated actions
      without prompting.
- [x] Support `--approve ask` with initial controls:
      approve, deny, and final stop.
- [x] Support `--approve safe` only for requests the existing review metadata
      can classify as safe. Otherwise fall back to ask.
- [x] Resume the standard runtime with `RunicAI.Coding.Review.allow/2`,
      `deny/2`, or `final_stop/2`.
- [ ] Add rewrite support after approve, deny, and final stop are stable.
- [x] Make non-interactive stdin behavior explicit: fail blocked with a clear
      event rather than hanging forever when prompting is impossible.

Validation:

- [x] Unit test review request detection.
- [x] Unit test approve, deny, and final-stop decision construction.
- [ ] Integration test review-gated standard session blocks, renders prompt,
      resumes, and completes after approval.
- [ ] Integration test non-interactive blocked review exits cleanly.

## Phase 5: RLM Final-Result Runner

Deliverables:

- [x] Run RLM objectives through `RunicAI.Coding.RLM.Agent.run/3`.
- [x] Render start and completion events around the RLM run even before live
      RLM stage events exist.
- [x] Normalize final result artifacts into presentation events:
      proposal, validation report, compiled plan summary, workflow output,
      episodes, repair attempts, objective scorecard, changed files,
      verification observations, residual risks, and persistence ref.
- [x] Render RLM proposal graph and materialized execution graph separately.
- [x] Respect `--max-runtime-ms` through existing RLM runtime budget support.
- [x] Return a failure status when RLM returns an error or an objective
      scorecard proves the objective is unsatisfied.

Validation:

- [x] Unit test RLM result normalization with deterministic fixtures.
- [x] Unit test RLM graph text rendering.
- [x] Integration test a scripted RLM proposal/result renders proposal,
      validation, episodes, and scorecard.
- [ ] Manual smoke:
      `mix runic_ai.agent "plan how to fix a failing test log" --agent rlm --cwd .`.

## Phase 6: RLM Live Stage Sink

Deliverables:

- [x] Add an RLM `:event_sink` or `:stage_sink` option that receives
      presentation-neutral stage maps or structs.
- [x] Emit stage events at these boundaries:
      environment prepared, proposal received, validation completed, compile
      completed, execution started, episode completed, progress gate completed,
      repair attempt started, repair attempt completed, persistence completed.
- [x] Keep terminal modules out of `RunicAI.Coding.RLM`; the RLM runner should
      convert stage data into `RunicAI.Terminal.Event`.
- [x] Ensure sink failures do not crash successful RLM work unless explicitly
      configured for test strictness.
- [ ] Thread the sink through coordinator, compiler, progress gate, repair
      loop, and persistence boundaries with minimal API churn.

Validation:

- [x] Unit test sink delivery order for the happy path.
- [ ] Unit test sink delivery for validation failure and repair paths.
- [ ] Unit test sink exceptions are contained.
- [x] Integration test RLM live rendering without waiting for the final result.

## Phase 7: Interactive Mode And Session Export

Deliverables:

- [x] Add a simple `--interactive` loop for standard-agent sessions.
- [ ] Reuse the same session handle across turns in interactive standard mode.
- [x] Support entering a new objective, empty-line no-op, and `:quit`.
- [x] Keep RLM interactive mode conservative: either one objective per run or
      explicit confirmation before starting another RLM run.
- [x] Add a final session export summary that reports JSONL path, session id,
      workspace root, final status, changed files, verification results, and
      residual risks.
- [x] Add `--session-id ID` support for deterministic session naming.
- [ ] Document resume limitations clearly. Full persisted resume can be a later
      phase once the terminal event model is stable.

Validation:

- [x] Unit test interactive command parsing independent of stdin.
- [ ] Integration test two standard-agent turns in one session with scripted
      clients.
- [ ] Manual smoke: `mix runic_ai.agent --interactive --agent standard --cwd .`.

## Phase 8: Documentation, Examples, And Manual Smoke

Deliverables:

- [x] Add task docs to `Mix.Tasks.RunicAi.Agent`.
- [ ] Add a short usage section to project docs or README if that is where
      existing public task docs live.
- [x] Add examples for standard one-shot, RLM one-shot, JSONL export, review
      gating, and detail modes.
- [ ] Add a local smoke script only if the Mix task invocation becomes too long
      for repeatable manual verification.
- [ ] Record manual smoke artifacts under `tmp/` with summary JSON or markdown
      when live model runs are used.

Validation:

- [x] `mix compile --warnings-as-errors`.
- [x] `mix test test/runic_ai/terminal`.
- [x] `mix test`.
- [ ] Manual standard-agent smoke in a read-only repo-inspection task.
- [ ] Manual standard-agent mutating smoke in an isolated `tmp` workspace.
- [ ] Manual RLM smoke in an isolated `tmp` workspace.

## Initial Non-Goals

- Full alternate-screen TUI.
- Owl, Termite, TermUI, Ratatouille, or any other UI dependency.
- Mouse support, split panes, modal overlays, command palettes, or scrollback
  management.
- Token-by-token provider streaming.
- Background session dashboards.
- Marketplace skills, personality systems, image paste, or voice features.
- Making RLM depend on terminal modules.

## Future UI Path

The follow-on UI path depends on whether the no-dependency CLI proves the event
model and control flow:

- If the CLI is useful but visually plain, add an Owl renderer over
  `RunicAI.Terminal.Event`. This follow-on is now tracked and partially
  implemented in
  `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`.
- If developers need panes, modal HITL controls, non-blocking input, and
  scrollback, revisit TermUI after the OTP compatibility decision.
- If the project wants to own terminal mechanics on OTP 27, do a focused
  Termite spike.
- Any future TUI must reuse the event model, runners, and JSONL trace shape from
  this plan instead of reimplementing agent execution.

## Implementation Order

1. Event contract and text presenter.
2. CLI option parser and Mix task shell.
3. Live standard-agent runner.
4. HITL review loop.
5. RLM final-result presentation.
6. RLM live stage sink.
7. Interactive mode and export polish.
8. Documentation and manual smoke verification.

This order keeps the first useful vertical slice small:

```sh
mix runic_ai.agent "summarize this repo's coding harness" --agent standard --cwd .
```

Once that produces a live, honest, exportable timeline, the same presentation
layer can support richer terminal renderers without changing the agent runtime
contract.
