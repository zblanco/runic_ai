# TermUI Coding Agent Terminal Interface Implementation Plan

Status: planning

Date: 2026-05-01

Motivated by:

- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`
- `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`
- `.docs/DESIGN.md`
- The existing `RunicAI.Terminal.Event` contract and terminal runners.

External references:

- TermUI v0.2.0: https://hex.pm/packages/term_ui and https://hexdocs.pm/term_ui
- TermUI repository: https://github.com/pcharbon70/term_ui
- mmdflux: https://github.com/kevinswiber/mmdflux and https://docs.rs/mmdflux

## Context

Option D from `.docs/029` was previously deferred because TermUI documented
OTP 28+ for native raw terminal mode while the repo was still on OTP 27. The
local environment is now Elixir 1.19.5 on OTP 28, so TermUI is viable for a
separate presentation layer.

This plan intentionally does not replace the current Mix CLI or the Owl/Bunt
enhancement plan. It creates a separate terminal application for developer
workflows that need panes, non-blocking input, review dialogs, scrollable event
history, session panels, and richer RLM workflow visualization.

## Goal

Build a developer terminal interface that lets someone use RunicAI coding
agents practically from an interactive terminal.

The first phases prove that TermUI can consume the same RunicAI event model as
the CLI. Later phases add Hermes-inspired ergonomics that fit RunicAI:

- live session timeline,
- non-blocking objective composer,
- review/HITL dialogs,
- tool and verification detail panes,
- RLM proposal and execution graph views,
- session resume/export controls,
- detail toggles,
- interruption and stop controls,
- practical developer status line.

## What To Translate From Hermes

Hermes is a useful reference for terminal-first agent ergonomics, not a product
specification for RunicAI.

Translate:

- single objective submission and interactive sessions,
- non-blocking input while the agent runs,
- status line with model/session/workspace/approval state,
- tool progress and review prompts,
- session list/resume/export,
- slash commands for local terminal actions,
- detail toggles for thinking, tools, evidence, and errors,
- stop/interruption controls,
- background session visibility later.

Adapt to RunicAI:

- make the OODA phases visible for standard agents,
- make RLM proposal, validation, compilation, execution, repair, and scorecard
  stages first-class,
- expose Runic workflow shape rather than hiding it behind chat messages,
- keep JSONL traces and final evidence reports available,
- prioritize coding-agent workspaces, patch policy, verification, and residual
  risk over generic chat affordances.

Do not copy:

- personality systems,
- marketplace skill surfaces,
- voice/image/media features,
- provider-specific brand workflows,
- decorative skins,
- mouse-heavy flows as the primary path,
- Hermes memory-file conventions unless RunicAI has a matching runtime need.

## TermUI Fit

TermUI v0.2.0 is documented as a direct-mode terminal UI framework for
Elixir/BEAM using an Elm-style `init/update/view` model. Its public docs and
repository describe:

- predictable state management through The Elm Architecture,
- differential rendering,
- theming and true color,
- OTP integration,
- IEx-compatible execution,
- widgets including `SplitPane`, `Tabs`, `TextInput`, `Dialog`,
  `AlertDialog`, `Table`, `Viewport`, `LogViewer`, `StreamWidget`,
  `CommandPalette`, `TreeView`, `FormBuilder`, and progress-style widgets.

These map directly onto RunicAI needs:

- `LogViewer` for the event timeline and trace history.
- `SplitPane` for timeline, details, transcript, graph, and evidence.
- `TextInput` for objectives and review rewrite text.
- `Dialog` and `AlertDialog` for HITL review decisions.
- `Tabs` for standard/RLM/session/evidence views.
- `Table` for tools, changed files, verification results, and scorecards.
- `StreamWidget` for future high-volume event or token streams.
- `CommandPalette` for discoverable local commands after the core controls are
  stable.

## Command Shape

Use a separate Mix task so the current CLI remains stable:

```sh
mix runic_ai.tui --cwd .
mix runic_ai.tui --agent standard --cwd .
mix runic_ai.tui --agent rlm --cwd . --session-id rlm:demo
mix runic_ai.tui --jsonl tmp/session.jsonl --theme runic
```

Initial options should mirror the CLI where practical:

- `--agent standard|rlm|assistant`
- `--cwd PATH`
- `--model MODEL`
- `--client default|codex`
- `--mode read_only|patch|verify`
- `--approve never|safe|ask`
- `--detail hidden|collapsed|expanded`
- `--jsonl PATH`
- `--session-id ID`
- `--theme runic|plain`
- `--graph text|mmdflux`

Do not add an option that changes backend semantics only for the TUI. If the
TUI needs a new control, add it to the shared terminal option model or to a
presentation-only state field.

## Architecture

TermUI should sit above the same terminal boundary as the CLI:

```text
RunicAI agent/runtime/RLM code
  -> RunicAI.Terminal.Event
  -> RunicAI.Terminal.EventStream
  -> RunicAI.Terminal.TermUI.App
  -> TermUI runtime
```

Proposed namespace:

```text
lib/mix/tasks/
  runic_ai.tui.ex

lib/runic_ai/terminal/term_ui/
  app.ex
  model.ex
  event_stream.ex
  event_bridge.ex
  commands.ex
  views/
    root.ex
    status_bar.ex
    timeline.ex
    details.ex
    composer.ex
    review_dialog.ex
    rlm_graph.ex
    evidence.ex
```

Responsibilities:

- `Mix.Tasks.RunicAi.Tui` parses options, starts the app, and reports startup
  errors.
- `RunicAI.Terminal.TermUI.App` implements the TermUI Elm root.
- `Model` stores current workspace, sessions, selected session, event buffers,
  running tasks, selected event, review request, composer text, detail mode,
  graph mode, and final evidence.
- `EventBridge` subscribes to `RunicAI.Runtime`, runs RLM/assistant stage
  sinks, and converts backend messages into `RunicAI.Terminal.Event`.
- `Commands` owns side effects: start session, submit objective, resume review,
  stop session, export JSONL, render graph, and open editor.
- `Views` render pure TermUI view trees from model state.

No TermUI module should inspect raw `RunicAI.Harness.Session`,
`WorkflowProposal`, or RLM result structs directly. If a view needs data, the
event normalizer or final-result normalizer should expose a stable presentation
field.

## Core UI Layout

First useful layout:

```text
+------------------------------------------------------------------+
| RunicAI  workspace  agent  model  approval  session  status      |
+-------------------------------+----------------------------------+
| Timeline                      | Detail                           |
| - OODA phases                 | selected event                   |
| - tool calls                  | command/output preview           |
| - review requests             | changed files                    |
| - RLM stages                  | verification/evidence            |
+-------------------------------+----------------------------------+
| Composer: objective / slash command / review reply                |
+------------------------------------------------------------------+
```

RLM layout after graph support:

```text
+------------------------------------------------------------------+
| Status                                                           |
+------------------------+-----------------------+-----------------+
| RLM stages             | Workflow graph        | Evidence        |
| proposal/validate/...  | proposal/execution    | scorecard/risk  |
+------------------------+-----------------------+-----------------+
| Composer / commands                                             |
+------------------------------------------------------------------+
```

Controls should work from the keyboard first:

- `Ctrl+C` or `q`: quit or ask to stop running work.
- `Ctrl+S`: stop current session.
- `Tab`: move focus between timeline, details, graph, composer.
- `Enter`: submit objective or activate selected decision.
- `/`: open command input.
- `?`: show local help dialog.
- `a`, `d`, `s`, `r` in review dialog: approve, deny, final stop, rewrite.
- `1`, `2`, `3`, `4`: switch primary tabs if tabs are active.
- `v`: cycle detail visibility.
- `e`: export current session trace/report.

## Event And State Model

The app model should keep event storage small and bounded:

- append normalized `RunicAI.Terminal.Event` values,
- retain raw terms only outside the UI model or behind debug mode,
- keep an indexed event buffer per session,
- keep selected event id separately,
- keep final reports as normalized maps,
- cap visible event history by count and byte size,
- expose JSONL export as the durable full-fidelity path.

Suggested TUI messages:

```elixir
{:terminal_event, session_id, %RunicAI.Terminal.Event{}}
{:submit_objective, text}
{:runner_result, session_id, {:ok, result} | {:error, error}}
{:review_decision, request_id, decision}
{:select_event, event_id}
{:set_detail, :hidden | :collapsed | :expanded}
{:set_graph_mode, :text | :mmdflux}
{:export_session, session_id, path}
{:stop_session, session_id}
{:slash_command, command, args}
```

The TUI may add view-local messages, but backend actions should remain explicit
and testable.

## Phase 0: TermUI Dependency And Runtime Spike

Deliverables:

- [ ] Add `{:term_ui, "~> 0.2"}` behind a normal dependency decision or a
      focused branch if the dependency surface needs review first.
- [ ] Add `mix runic_ai.tui --help`.
- [ ] Build a tiny TermUI root that renders the Runic status bar, a placeholder
      timeline, and a composer field.
- [ ] Verify it starts and exits cleanly from `mix runic_ai.tui`.
- [ ] Verify terminal state restoration after quit, `Ctrl+C`, and raised
      startup errors.
- [ ] Record whether TermUI runs cleanly under Mix and IEx in this repo.

Validation:

- [ ] `mix compile --warnings-as-errors`
- [ ] Unit test option parsing.
- [ ] Unit test pure `Model` init/update functions.
- [ ] Manual TTY smoke: start app, type, quit, terminal restored.

## Phase 1: Scripted Event Feed Prototype

Deliverables:

- [ ] Add a scripted in-memory event source that emits representative
      standard, RLM, review, tool, verification, repair, and error events.
- [ ] Render those events in a scrollable timeline.
- [ ] Render selected-event details in a detail pane.
- [ ] Add status bar fields for workspace, agent, model/client, session, mode,
      approval policy, and current phase.
- [ ] Implement focus movement between timeline, details, and composer.
- [ ] Implement detail mode toggles without backend work.

Validation:

- [ ] Unit test model updates for event append, selection, focus, and detail
      mode.
- [ ] Manual TTY smoke with scripted feed at narrow and wide terminal sizes.

## Phase 2: Standard-Agent Live Session

Deliverables:

- [ ] Wire the TUI to `RunicAI.Coding.Session.spec/2`,
      `RunicAI.Runtime.start_session/1`, `subscribe/1`, `submit/2`, and
      `drain/2` through `EventBridge`.
- [ ] Allow objective submission from the composer.
- [ ] Keep input responsive while a run is active.
- [ ] Render OODA phase, tool, wait, review, verification, repair, output, and
      snapshot events live.
- [ ] Add stop/interruption control that returns partial evidence when
      available.
- [ ] Keep JSONL export working for TUI sessions.

Validation:

- [ ] Unit test EventBridge mapping with scripted runtime messages.
- [ ] Integration test a scripted standard-agent session through the bridge.
- [ ] Manual smoke a read-only standard-agent objective.

## Phase 3: HITL Review Dialogs

Deliverables:

- [ ] Render review requests as modal dialogs with reason, checkpoint, tool,
      path/command preview, risk, and allowed decisions.
- [ ] Support approve, deny, and final stop.
- [ ] Support rewrite through a controlled text area or editor handoff.
- [ ] Respect `--approve never|safe|ask`.
- [ ] Show review decisions in the timeline after submission.
- [ ] Make EOF/non-interactive paths impossible for the TUI by requiring a TTY
      at startup.

Validation:

- [ ] Unit test review state transitions.
- [ ] Integration test review-gated scripted session resumes after approval.
- [ ] Manual smoke a review request and terminal restoration after dialog close.

## Phase 4: RLM And Assistant Workflow Views

Deliverables:

- [ ] Wire RLM and assistant runners through stage sinks into the TUI event
      bridge.
- [ ] Show proposal, validation, compile, execution, progress gate, repair, and
      persistence stages as separate timeline rows.
- [ ] Add an RLM graph pane that starts with current text adjacency rendering.
- [ ] Add tables for nodes, dependencies, policy, expected outputs, warnings,
      errors, episodes, artifacts, changed files, verification observations,
      scorecard, and residual risks.
- [ ] Let the user switch between proposal graph and materialized execution
      graph.
- [ ] Keep RLM final-result rendering aligned with the CLI/Owl final report.

Validation:

- [ ] Unit test RLM stage updates and graph selection.
- [ ] Integration test scripted RLM run with proposal, validation warning,
      episode, repair, and final scorecard.
- [ ] Manual smoke a conservative RLM objective.

## Phase 5: mmdflux Graph Renderer

Deliverables:

- [ ] Reuse `RunicAI.Terminal.GraphPresenter` from the Owl/Bunt plan.
- [ ] Add a TUI graph mode that renders Mermaid source as text for debugging.
- [ ] Add optional `mmdflux` CLI rendering for terminal graph text.
- [ ] Cache rendered graph output by graph checksum, terminal width, and graph
      mode.
- [ ] Render graph warnings in the UI without failing the agent session.
- [ ] Draft a separate Rust NIF feasibility note before making mmdflux native:
      dependency impact, Rustler use, build targets, release packaging,
      scheduler impact, crash isolation, and fallback strategy.

Validation:

- [ ] Unit test graph cache keys and fallback paths.
- [ ] Unit test mmdflux wrapper with fake executable.
- [ ] Manual smoke if `mmdflux` is installed.

## Phase 6: Developer Workflow Controls

Deliverables:

- [ ] Add slash commands:
      `/help`, `/clear`, `/detail`, `/export`, `/stop`, `/agent`, `/mode`,
      `/approve`, `/graph`, `/session`, and `/quit`.
- [ ] Add a compact command palette only after slash commands are stable.
- [ ] Add session list and session switching.
- [ ] Add resume/export affordances around session id and JSONL path.
- [ ] Add detail filters:
      all events, tools only, reviews only, verification only, errors only,
      RLM only.
- [ ] Add evidence view:
      objective status, changed files, verification commands, residual risks,
      artifacts, and final response.
- [ ] Add workspace write-policy indicators and warnings for patch mode.

Validation:

- [ ] Unit test slash command parsing and update messages.
- [ ] Unit test filter state and session switching.
- [ ] Manual smoke with two scripted sessions.

## Phase 7: Background Sessions And Advanced Panels

Deliverables:

- [ ] Add background session visibility only after foreground standard and RLM
      sessions are stable.
- [ ] Show running sessions, current phase, elapsed time, review-needed state,
      and latest evidence.
- [ ] Add subagent/decomposition panels only where RunicAI emits normalized
      `:subagent` events.
- [ ] Add context/memory panels only after RunicAI runtime exposes stable
      context or memory artifacts for terminal presentation.
- [ ] Avoid Hermes-specific memory file UX unless RunicAI adopts a matching
      concept.

Validation:

- [ ] Unit test session summary aggregation.
- [ ] Manual smoke with one foreground and one scripted background session.

## Phase 8: Hardening, Tests, And Docs

Deliverables:

- [ ] Document the TUI task in task moduledocs.
- [ ] Add internal docs explaining CLI vs Owl CLI vs TermUI TUI.
- [ ] Add accessibility and fallback behavior from `.docs/DESIGN.md`.
- [ ] Ensure all renderable states have no overlapping text at narrow widths.
- [ ] Ensure terminal state restoration under normal exit, app error, backend
      error, timeout, and interruption.
- [ ] Add a short manual verification report for the first live model-backed
      smoke.

Validation:

- [ ] `mix format`
- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test test/runic_ai/terminal`
- [ ] `mix test`
- [ ] Manual TTY smoke at 80x24 and a wider terminal.
- [ ] Manual read-only standard-agent smoke.
- [ ] Manual review-gated standard-agent smoke.
- [ ] Manual RLM smoke.

## Implementation Order

1. TermUI skeleton with scripted events.
2. Standard-agent live session and composer.
3. HITL review dialog.
4. RLM/assistant workflow views.
5. Optional mmdflux graph rendering.
6. Developer slash commands, filters, export, and session controls.
7. Background sessions and advanced panels.
8. Hardening and manual verification.

The main success condition is not visual novelty. The TUI succeeds when a
developer can keep typing, see exactly what the agent is doing, review risky
actions, inspect evidence, and understand the Runic workflow behind an RLM run
without leaving the terminal.
