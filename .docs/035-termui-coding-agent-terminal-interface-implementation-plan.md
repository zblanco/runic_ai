# TermUI Coding Agent Terminal Interface Implementation Plan

Status: planning

Date: 2026-05-01

Motivated by:

- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`
- `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`
- `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`
- `.docs/DESIGN.md`
- The existing `RunicAI.Terminal.Event` contract and terminal runners.
- The new `RunicAI.Persistence.*` SQLite schemas, query helpers, inspection
  helpers, eval helpers, replay helpers, and JSONL export helpers.

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

The persistence work from `.docs/037` changes the expected shape of this TUI.
TermUI should not be only a richer renderer over a live in-memory event stream.
It should become a SQLite-backed agent workbench:

- hydrate recent sessions, runs, events, scorecards, repairs, artifacts, and
  managed workflows from SQLite on startup;
- write live terminal events through persistence before updating the UI model;
- use the same query paths for live sessions and postmortem inspection;
- support search, resume, review, replay, export, eval, and prompt-tuning
  workflows even when the original BEAM process is gone;
- keep JSONL as an export and interchange surface rather than the primary
  source of truth.

## Default Persistence Policy

RunicAI has two different integration modes, and the default persistence
behavior should match the mode.

1. Library embedding. A user depends on RunicAI from their own Elixir project,
   starts RunicAI pieces from `application.ex`, adds their own components and
   integrations, and may provide their own persistence adapter or storage
   topology. In this mode, RunicAI should keep storage configurable and avoid
   surprising application-level side effects.
2. Local agent harness. A user checks out RunicAI and runs `mix runic_ai.agent`,
   `mix runic_ai.tui`, or another local terminal interface the way they would
   use Livebook or Hermes. In this mode, SQLite should be the default for
   feature-rich interactions.

For the local harness path, default to SQLite without requiring `--sqlite`.
Use a predictable workspace-local database such as `.runic_ai/runs.db`, create
and migrate it automatically, and write terminal events, workflow events,
facts, review requests, artifacts, scorecards, repairs, and managed workflow
rows there by default. In-memory storage should be an explicit opt-out for
tests, demos, or ephemeral sessions, not the default interactive path.

CLI/TUI options should configure the default rather than invert it:

- no persistence flag: use SQLite at the default local harness path;
- `--sqlite PATH`: use SQLite at a caller-provided path;
- `--persistence memory` or equivalent: explicit ephemeral mode;
- `--persistence none`: explicit no-storage mode for narrow debugging;
- library APIs: accept adapter/repo/store options so embedding applications can
  supply their own persistence layer.

## Goal

Build a developer terminal interface that lets someone use RunicAI coding
agents practically from an interactive terminal and inspect durable agent
workflows after the fact.

The first phases prove that TermUI can consume the same RunicAI event model as
the CLI while using SQLite as the durable read model. Later phases add
Hermes-inspired ergonomics that fit RunicAI:

- durable run/session picker,
- live session timeline,
- query-backed search and recall,
- non-blocking objective composer,
- review/HITL dialogs,
- tool and verification detail panes,
- RLM proposal and execution graph views,
- managed workflow panels,
- eval, tracing, and scorecard comparison panels,
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
- use SQLite tables as the source of truth for session history, workflow
  events, runnable traces, scorecards, repairs, artifacts, and review gates,
- expose eval/tuning views over persisted prompts, tool results, repairs,
  scorecards, and derived metrics,
- prioritize coding-agent workspaces, patch policy, verification, and residual
  risk over generic chat affordances.

Do not copy:

- personality systems,
- marketplace skill surfaces,
- voice/image/media features,
- provider-specific brand workflows,
- decorative skins,
- mouse-heavy flows as the primary path,
- Hermes memory-file conventions.

Hermes lifecycle ideas should be translated as persisted RunicAI signals and
query views. For example, `prefetch`, `sync_turn`, `on_session_end`,
`on_pre_compress`, `on_memory_write`, and `on_delegation` become durable signal
projections over RunicAI events, facts, traces, scorecards, artifacts, and
managed workflow rows. Do not add Hermes-specific memory files or sidecar state
when the same behavior can be expressed as RunicAI persistence data.

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

TermUI remains attractive as the BEAM-native option. Unlike the ExRatatui
alternate, this path avoids a Rust/NIF dependency and should be easier to ship
inside ordinary Mix workflows. The tradeoff is that large-list rendering,
charts, remote terminal transports, and terminal event handling may be less
capable than a Rust Ratatui surface. The implementation should therefore lean
on persistence queries and bounded projections rather than trying to keep large
unbounded UI state in memory.

## Persistence-Enabled Workbench Features

The TUI should expose capabilities that are only practical because RunicAI now
has a queryable durable read model.

### Durable Session Workbench

- Recent runs panel from `RunicAI.Persistence.Queries.recent_runs/2`.
- Session/run picker with status, objective, model, workspace, scorecard, and
  latest event.
- Selected-run timeline hydrated from persisted terminal and runnable events.
- Live sessions append through SQLite first, then refresh the UI projection
  from the same query helpers used for postmortems.
- JSONL export generated from persisted rows.

### Query-Backed Search And Recall

- `/search TERM` across persisted terminal events.
- `/source TERM` for source cues, prompt evidence, and cited context.
- `/tools [name]` for tool-call history and repeated failures.
- `/errors` for failed runnable rows, terminal errors, and repair-triggering
  events.
- `/similar` later, once embeddings or derived similarity metrics exist.

This is the RunicAI translation of Hermes session search and transcript recall:
search the durable RunicAI event/fact model first.

### Review And Pause Queue

- Review queue panel from persisted review requests.
- Resume keys, checkpoints, risk details, tool previews, and decisions remain
  inspectable after a restart.
- Approval, denial, stop, and rewrite decisions write durable review/terminal
  events.
- If the owning runtime is still live, the TUI resumes it through the shared
  runtime APIs. If not, the request remains an inspectable durable record.

### Managed Workflow Dashboard

- Managed workflows panel with pending, active, paused, failed, and scheduled
  filters.
- Show trigger, restart policy, checkpoint strategy, latest run, latest event,
  and failure context.
- Start command-invokable workflows from the TUI only by delegating to shared
  managed workflow APIs.
- Resume failed or paused workflows without the TUI owning the runner topology.

### Agent/Workflow Observability

- Runnable lifecycle table from persisted runnable events.
- Node detail with component id/type, policy, duration, input preview, output
  preview, and error preview.
- Scorecard panel for objective status, salience/value/progress metrics,
  residual risks, changed artifacts, and verification observations.
- Repair diagnostics panel that can generate a repair prompt from persisted
  evidence.
- Artifact trail for file paths, actions, checksums, byte sizes, graph
  artifacts, and blueprint artifacts.

### Eval And Tuning Cockpit

- Cohort picker by objective status, agent, workflow key, model, workspace, and
  date range.
- Compare scorecards across recent runs.
- Inspect prompt inputs, tool outputs, repair attempts, source cues, and final
  answers for prompt tuning.
- Export selected cohorts to JSONL or a structured report for offline evals.

## Command Shape

Use a separate Mix task so the current CLI remains stable:

```sh
mix runic_ai.tui --cwd .
mix runic_ai.tui --agent standard --cwd .
mix runic_ai.tui --agent rlm --cwd . --session-id rlm:demo
mix runic_ai.tui --agent assistant --cwd .
mix runic_ai.tui --sqlite .runic_ai/runs.db --run assistant:cli:123
mix runic_ai.tui --sqlite .runic_ai/runs.db --jsonl tmp/session.jsonl --theme runic
mix runic_ai.tui --persistence memory --cwd .
```

Initial options should mirror the CLI where practical:

- `--agent standard|rlm|assistant`
- `--cwd PATH`
- `--persistence sqlite|memory|none` with `sqlite` as the local harness default
- `--sqlite PATH` to override the default SQLite database path
- `--run RUN_ID`
- `--model MODEL`
- `--client default|codex`
- `--mode read_only|patch|verify`
- `--approve never|safe|ask`
- `--detail hidden|collapsed|expanded`
- `--jsonl PATH` for export/import compatibility, not as the primary durable
  store
- `--session-id ID`
- `--theme runic|plain`
- `--graph text|mmdflux`

Do not add an option that changes backend semantics only for the TUI. If the
TUI needs a new control, add it to the shared terminal option model or to a
presentation-only state field.

`mix runic_ai.agent` and `mix runic_ai.tui` should share this persistence
option model. A run started from the plain CLI should be visible in the TUI
without the user remembering to opt into SQLite first.

## Architecture

TermUI should sit above the same terminal boundary as the CLI:

```text
RunicAI agent/runtime/RLM code
  -> RunicAI.Terminal.Event
  -> RunicAI.Persistence.SQLite / Ecto Repo
  -> RunicAI.Persistence.HarnessProjection
  -> RunicAI.Persistence.Queries / Inspection / Evals / Replay
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
  persistence_view.ex
  commands.ex
  views/
    root.ex
    status_bar.ex
    run_picker.ex
    timeline.ex
    details.ex
    composer.ex
    review_dialog.ex
    rlm_graph.ex
    managed_workflows.ex
    evidence.ex
    evals.ex
```

Responsibilities:

- `Mix.Tasks.RunicAi.Tui` parses options, resolves the local harness
  persistence default, opens/configures SQLite unless explicitly overridden,
  starts the app, and reports startup errors.
- `RunicAI.Terminal.TermUI.App` implements the TermUI Elm root.
- `Model` stores current workspace, loaded run summaries, selected run,
  selected event, bounded timeline projection, filters, running tasks, review
  request, composer text, detail mode, graph mode, eval cohort, and final
  evidence.
- `PersistenceView` converts Ecto structs and query result rows into stable UI
  structs so views do not know schema internals.
- `EventBridge` subscribes to `RunicAI.Runtime`, runs RLM/assistant stage
  sinks, converts backend messages into `RunicAI.Terminal.Event`, writes them
  through persistence, and emits refresh messages for the Elm update loop.
- `Commands` owns side effects: query runs, start session, submit objective,
  resume review, stop session, export JSONL, render graph, resume managed
  workflow, and open editor.
- `Views` render pure TermUI view trees from model state.

No TermUI module should inspect raw `RunicAI.Harness.Session`,
`WorkflowProposal`, RLM result structs, or Ecto schemas directly. If a view
needs data, the event normalizer, final-result normalizer, or
`PersistenceView` should expose a stable presentation field.

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

SQLite is the source of truth. The app model should keep only a bounded
presentation projection:

- append normalized `RunicAI.Terminal.Event` values through persistence first,
- retain raw terms only outside the UI model or behind debug mode,
- keep query cursors and visible windows instead of unbounded event buffers,
- keep loaded run summaries, selected run id, selected event id, active
  filters, pending review id, and eval cohort id separately,
- keep final reports as normalized maps,
- cap visible event history by count and byte size,
- expose JSONL export from persisted rows as the full-fidelity interchange
  path.

Suggested TUI messages:

```elixir
{:load_recent_runs, filters}
{:load_run, run_id}
{:query_result, request_id, {:ok, result} | {:error, error}}
{:terminal_event, session_id, %RunicAI.Terminal.Event{}}
{:persisted_event, session_id, event_id}
{:submit_objective, text}
{:runner_result, session_id, {:ok, result} | {:error, error}}
{:review_decision, request_id, decision}
{:select_run, run_id}
{:select_event, event_id}
{:set_detail, :hidden | :collapsed | :expanded}
{:set_graph_mode, :text | :mmdflux}
{:export_session, session_id, path}
{:search, scope, term}
{:resume_workflow, workflow_id}
{:stop_session, session_id}
{:slash_command, command, args}
```

The TUI may add view-local messages, but backend actions should remain explicit
and testable.

## Phase 0: TermUI Dependency And Runtime Spike

Deliverables:

- [ ] Add `{:term_ui, "~> 0.2"}` behind a normal dependency decision or a
      focused branch if the dependency surface needs review first.
- [ ] Add `mix runic_ai.tui --help` with default SQLite behavior,
      `--persistence`, `--sqlite`, `--run`, `--jsonl`, and existing
      agent/approval/model options documented.
- [ ] Build a tiny TermUI root that renders the Runic status bar, a placeholder
      timeline, and a composer field.
- [ ] Thread local harness persistence defaults through option parsing and open
      the default SQLite backend without requiring `--sqlite`.
- [ ] Support `--sqlite PATH` as a location override and explicit ephemeral
      storage as an opt-out.
- [ ] Verify it starts and exits cleanly from `mix runic_ai.tui`.
- [ ] Verify terminal state restoration after quit, `Ctrl+C`, and raised
      startup errors.
- [ ] Record whether TermUI runs cleanly under Mix and IEx in this repo.

Validation:

- [ ] `mix compile --warnings-as-errors`
- [ ] Unit test option parsing.
- [ ] Unit test pure `Model` init/update functions.
- [ ] Manual TTY smoke: start app without `--sqlite`, verify default SQLite is
      created/migrated, type, quit, terminal restored.

## Phase 1: Query-Backed Read-Only Workbench

Deliverables:

- [ ] Load recent runs from `RunicAI.Persistence.Queries`.
- [ ] Load selected-run timeline, runnable events, scorecard status, failed
      runnables, artifacts, repairs, and tool calls from query helpers.
- [ ] Add a small scripted fixture database for TUI development and tests.
- [ ] Render run picker, scrollable timeline, selected-event details, and
      status bar from persisted rows.
- [ ] Add status bar fields for workspace, agent, model/client, session, mode,
      approval policy, and current phase.
- [ ] Implement focus movement between timeline, details, and composer.
- [ ] Implement detail mode toggles without backend work.
- [ ] Implement `/search`, `/errors`, `/tools`, `/artifacts`, `/scorecard`,
      `/repairs`, and `/export` against persistence queries.
- [ ] Hydrate correctly from an on-disk database after a fresh BEAM start.

Validation:

- [ ] Unit test model updates for run load, event selection, focus, filters,
      and detail mode.
- [ ] Unit test slash commands mapped to persistence queries.
- [ ] Manual TTY smoke with fixture database at narrow and wide terminal sizes.
- [ ] Manual smoke against the default database produced by `mix runic_ai.agent`
      with no persistence flag.
- [ ] Manual smoke against an overridden database produced with
      `mix runic_ai.agent --sqlite PATH`.

## Phase 2: Standard-Agent Live Session

Deliverables:

- [ ] Wire the TUI to `RunicAI.Coding.Session.spec/2`,
      `RunicAI.Runtime.start_session/1`, `subscribe/1`, `submit/2`, and
      `drain/2` through `EventBridge`.
- [ ] Allow objective submission from the composer.
- [ ] Keep input responsive while a run is active.
- [ ] Write terminal events to SQLite before updating the TUI model.
- [ ] Refresh current run panes from query results so live and postmortem paths
      match.
- [ ] Render OODA phase, tool, wait, review, verification, repair, output, and
      snapshot events live.
- [ ] Add stop/interruption control that returns partial evidence when
      available.
- [ ] Keep JSONL export working from persisted TUI session rows.

Validation:

- [ ] Unit test EventBridge mapping with scripted runtime messages.
- [ ] Integration test a scripted standard-agent session through the bridge.
- [ ] Assert TUI-visible event count equals the SQLite timeline count.
- [ ] Manual smoke a read-only standard-agent objective.

## Phase 3: HITL Review Dialogs

Deliverables:

- [ ] Render review requests as modal dialogs with reason, checkpoint, tool,
      path/command preview, risk, and allowed decisions.
- [ ] Support approve, deny, and final stop.
- [ ] Support rewrite through a controlled text area or editor handoff.
- [ ] Respect `--approve never|safe|ask`.
- [ ] Persist review decisions as terminal/review events.
- [ ] Show review decisions in the timeline after submission through the
      persisted query path.
- [ ] Keep pending reviews inspectable after process restart.
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
      persistence stages as separate timeline rows loaded from durable events.
- [ ] Show runnable table from persisted runnable events.
- [ ] Add an RLM graph pane that starts with current text adjacency rendering.
- [ ] Add tables for nodes, dependencies, policy, expected outputs, warnings,
      errors, episodes, artifacts, changed files, verification observations,
      scorecard, and residual risks.
- [ ] Let the user switch between proposal graph and materialized execution
      graph where both are persisted.
- [ ] Keep RLM final-result rendering aligned with the CLI/Owl final report.

Validation:

- [ ] Unit test RLM stage updates and graph selection.
- [ ] Integration test scripted RLM run with proposal, validation warning,
      episode, repair, and final scorecard.
- [ ] Assert persisted workflow rows, runnable rows, scorecard rows, artifacts,
      repairs, and graph rows are visible in the TUI.
- [ ] Manual smoke a conservative RLM objective.

## Phase 5: Managed Workflows And Background Runs

Deliverables:

- [ ] Add managed workflow table with pending, active, paused, failed, and
      scheduled filters.
- [ ] Show trigger, restart policy, checkpoint strategy, latest run, elapsed
      time, review-needed state, latest evidence, and failure context.
- [ ] Start command-invokable managed workflows from the TUI by delegating to
      shared managed workflow APIs.
- [ ] Resume durable workflows by delegating to caller-owned runner APIs.
- [ ] Add background session visibility only after foreground standard and RLM
      sessions are stable.
- [ ] Keep active-session cache as a projection only; SQLite remains the source
      of truth.

Validation:

- [ ] Headless/unit tests for managed workflow filters and resume command
      generation.
- [ ] Unit test session summary aggregation.
- [ ] Integration test with one foreground and one background scripted run.

## Phase 6: Eval, Tuning, And Hermes-Inspired Signals

Deliverables:

- [ ] Add eval cohort panel using `RunicAI.Persistence.Evals`.
- [ ] Compare objective status, scorecard fields, repair counts, tool failures,
      artifact counts, model, workspace, agent, and workflow dimensions.
- [ ] Add prompt, source-cue, tool-output, repair, and final-answer inspection
      for selected runs.
- [ ] Add derived signal views for Hermes-like lifecycle concepts: prefetch
      candidates, session recall, sync-turn facts, delegation summaries, and
      on-session-end summaries.
- [ ] Keep these views derived from RunicAI persisted signals, not new memory
      files.

Validation:

- [ ] Unit tests for cohort grouping and selected-run detail hydration.
- [ ] Manual smoke over a small multi-run SQLite database.

## Phase 7: Developer Workflow Controls And Graph Rendering

Deliverables:

- [ ] Add slash commands:
      `/help`, `/clear`, `/detail`, `/export`, `/stop`, `/agent`, `/mode`,
      `/approve`, `/graph`, `/session`, `/runs`, `/search`, `/errors`,
      `/reviews`, `/tools`, `/artifacts`, `/managed`, `/scorecard`,
      `/repairs`, `/eval`, `/resume`, and `/quit`.
- [ ] Add a compact command palette only after slash commands are stable.
- [ ] Add session list and session switching.
- [ ] Add resume/export affordances around run id, workflow id, session id,
      SQLite database, and JSONL path.
- [ ] Add detail filters:
      all events, tools only, reviews only, verification only, errors only,
      RLM only, managed workflows only.
- [ ] Add evidence view:
      objective status, changed files, verification commands, residual risks,
      artifacts, and final response.
- [ ] Add workspace write-policy indicators and warnings for patch mode.
- [ ] Reuse `RunicAI.Terminal.GraphPresenter` from the Owl/Bunt plan.
- [ ] Add a TUI graph mode that renders Mermaid source as text for debugging.
- [ ] Add optional `mmdflux` CLI rendering for terminal graph text.
- [ ] Cache rendered graph output by graph checksum, terminal width, and graph
      mode.
- [ ] Render graph warnings in the UI without failing the agent session.
- [ ] Keep native mmdflux/Rust NIF work out of this phase unless a separate
      feasibility decision accepts the dependency impact, build targets,
      release packaging, scheduler impact, crash isolation, and fallback
      strategy.

Validation:

- [ ] Unit test slash command parsing and update messages.
- [ ] Unit test filter state and session switching.
- [ ] Unit test graph cache keys and fallback paths.
- [ ] Unit test mmdflux wrapper with fake executable.
- [ ] Manual smoke with two scripted sessions.
- [ ] Manual smoke if `mmdflux` is installed.

## Phase 8: Hardening, Tests, And Docs

Deliverables:

- [ ] Document the TUI task in task moduledocs.
- [ ] Add internal docs explaining CLI vs Owl CLI vs TermUI TUI.
- [ ] Add accessibility and fallback behavior from `.docs/DESIGN.md`.
- [ ] Ensure all renderable states have no overlapping text at narrow widths.
- [ ] Ensure terminal state restoration under normal exit, app error, backend
      error, timeout, and interruption.
- [ ] Verify read-only hydration works after a fresh BEAM start from an
      existing SQLite database.
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
- [ ] Manual multi-run SQLite workbench smoke.

## Implementation Order

1. TermUI skeleton with default SQLite option plumbing.
2. Query-backed read-only workbench over persisted runs.
3. Standard-agent live session and composer with write-through persistence.
4. HITL review dialog backed by persisted review events.
5. RLM/assistant workflow views from persisted workflow/runnable data.
6. Managed workflow and background-run panels.
7. Eval, tuning, and Hermes-inspired signal views.
8. Developer slash commands, filters, export, and optional graph rendering.
9. Hardening and manual verification.

The main success condition is not visual novelty. The TUI succeeds when a
developer can keep typing, see exactly what the agent is doing, review risky
actions, inspect persisted evidence, resume or export durable runs, and
understand the Runic workflow behind an RLM run without leaving the terminal.
