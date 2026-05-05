# ExRatatui Coding Agent Terminal Workbench Alternate Plan

Status: planning alternate to `.docs/035-termui-coding-agent-terminal-interface-implementation-plan.md`

Date: 2026-05-03

Motivated by:

- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`
- `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`
- `.docs/035-termui-coding-agent-terminal-interface-implementation-plan.md`
- `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`
- the new `RunicAI.Persistence.*` SQLite schemas, projections, query helpers,
  inspection helpers, eval helpers, replay helpers, and JSONL export helpers;
- Hermes-inspired terminal harness ergonomics and lifecycle hooks.

External references checked on 2026-05-03:

- ExRatatui package: https://hex.pm/packages/ex_ratatui
- ExRatatui docs: https://hexdocs.pm/ex_ratatui
- ExRatatui repository: https://github.com/mcass19/ex_ratatui
- Ratatui project: https://ratatui.rs

## Decision Framing

The existing 035 plan uses TermUI as the TUI dependency. This alternate plan
explores `ex_ratatui` instead.

The material change is not only a rendering library swap. Because 037 now gives
RunicAI a durable SQLite read model, the terminal surface should become a
query-backed agent workbench:

- hydrate recent sessions, runs, terminal timelines, scorecards, repairs,
  artifacts, and managed workflows from SQLite on startup;
- merge live terminal events into the same model while writing them through to
  SQLite first;
- let users search, resume, inspect, replay, export, compare, and evaluate runs
  without needing the original BEAM process to still be alive;
- keep the current `mix runic_ai.agent` CLI stable and build this as a separate
  alternate-screen app.

## Default Persistence Policy

RunicAI has two different integration modes, and the default storage behavior
should be explicit about which mode is in play.

1. Library embedding. A user depends on RunicAI from their own Elixir project,
   starts RunicAI pieces from `application.ex`, extends the system with their
   own components and integrations, and may provide their own persistence
   adapter or storage topology. In this mode, RunicAI should keep storage
   configurable and avoid surprising application-level side effects.
2. Local agent harness. A user checks out RunicAI and runs `mix runic_ai.agent`,
   `mix runic_ai.tui`, or another local terminal interface the way they would
   use Livebook or Hermes. In this mode, SQLite should be the default for
   feature-rich interactions.

For local harness commands and TUIs, default to SQLite without requiring
`--sqlite`. Use a predictable workspace-local database such as
`.runic_ai/runs.db`, create and migrate it automatically, and write terminal
events, workflow events, facts, review requests, artifacts, scorecards,
repairs, and managed workflow rows there by default. In-memory storage should
be an explicit opt-out for tests, demos, or ephemeral sessions.

CLI/TUI options should configure the default rather than invert it:

- no persistence flag: use SQLite at the default local harness path;
- `--sqlite PATH`: use SQLite at a caller-provided path;
- `--persistence memory` or equivalent: explicit ephemeral mode;
- `--persistence none`: explicit no-storage mode for narrow debugging;
- library APIs: accept adapter/repo/store options so embedding applications can
  supply their own persistence layer.

## ExRatatui Research Summary

As of the 2026-05-03 research pass, Hex lists `ex_ratatui` v0.8.2, last updated
2026-04-29, as "Elixir bindings for the Rust ratatui terminal UI library." The
dependency shape documented by the package is:

```elixir
{:ex_ratatui, "~> 0.8"}
```

The project README and HexDocs describe:

- Rustler NIF bindings to Rust `ratatui`;
- precompiled binaries through `rustler_precompiled`, with source builds
  possible via `EX_RATATUI_BUILD=true`;
- low-level direct APIs: `ExRatatui.run/1`, `draw/2`, `poll_event/1`,
  `terminal_size/0`;
- OTP-supervised apps through `ExRatatui.App`;
- callback runtime via `mount/1`, `render/2`, `handle_event/2`,
  `handle_info/2`, and `terminate/2`;
- reducer runtime via `use ExRatatui.App, runtime: :reducer`, intended for
  command/subscription driven apps with async effects and structured message
  handling;
- layouts through `ExRatatui.Layout.split/3` and `%ExRatatui.Layout.Rect{}`;
- rich styling through `%ExRatatui.Style{}` with named, RGB, and 256-color
  colors plus modifiers;
- rich text via `ExRatatui.Text.Span` and `Line`;
- stateful input refs created once in app state, such as
  `ExRatatui.text_input_new/0` and `ExRatatui.textarea_new/0`;
- headless testing with `test_mode: {width, height}`,
  `ExRatatui.Runtime.inject_event/2`, and `Runtime.snapshot/1`;
- runtime inspection/tracing;
- built-in local, SSH, and Erlang distribution transports.

Current widget coverage is enough for a serious RunicAI workbench:

- text/content: `Paragraph`, `Markdown`;
- structure: `Block`, `Tabs`, `Popup`, `Clear`;
- lists/data: `List`, `Table`, `WidgetList`, `Scrollbar`;
- activity/metrics: `Gauge`, `LineGauge`, `Sparkline`, `BarChart`,
  `Throbber`, `Chart`;
- input: `TextInput`, `Textarea`, `Checkbox`, slash-command helpers;
- graph/canvas experiments: `Canvas`, `Calendar`.

The Rust rendering surface is attractive for RunicAI because Ratatui gives us a
real terminal layout/rendering engine, large-list widgets, richer charts, and a
native terminal/event layer while the BEAM keeps the agent, persistence, and
workflow orchestration.

## Important Caveats

- This is a young package. Treat the first slice as a spike even though the API
  is already promising.
- The latest Hex package page reported v0.8.2 while HexDocs pages opened at
  v0.8.0 during this research pass. Pin dependency decisions carefully and
  verify docs against the locked package.
- It uses NIFs. Precompiled binaries reduce installation burden, but CI,
  release packaging, platform support, crash isolation, and source-build
  fallback need explicit verification.
- The app should tolerate `ex_ratatui` being unavailable. The current CLI and
  Owl renderer remain the non-NIF fallback path.
- A TUI should require a real TTY for local mode. Non-interactive runs should
  stay on `mix runic_ai.agent`.

## Persistence-Enabled Feature Improvements

The new SQLite read model lets the TUI support workflows that were not worth
building on top of a transient event buffer.

### Durable Session Workbench

- Recent runs panel from `RunicAI.Persistence.Queries.recent_runs/2`.
- Session/run picker with status, objective, model, workspace, scorecard, and
  latest event.
- Hydrate the selected run timeline from `terminal_events` after a fresh BEAM
  start.
- Live runs append through SQLite, then the TUI model refreshes from the same
  query path.
- JSONL export from SQLite, not only from a live sink.

### Query-Backed Search And Recall

- `/search TERM` across terminal event FTS.
- `/source TERM` for source cue and prompt evidence search.
- `/tools TOOL_NAME` for tool-call history and repeated failures.
- `/errors` for failed runnable rows and terminal errors.
- `/similar` later, once embeddings or derived metrics exist.

Hermes translation: implement `session_search` and transcript recall as
queries over RunicAI durable events first. Do not introduce Hermes memory-file
UX.

### Review And Pause Queue

- A review queue panel from `review_requests`.
- Resume keys, checkpoints, risk details, tool previews, and decisions shown
  even after a terminal restart.
- `/reviews` to jump between pending review gates.
- Approval/denial writes a new terminal event and, when the owning session is
  live, resumes the runtime.

### Managed Workflow Dashboard

- Managed workflows panel from `managed_workflows`.
- Filters for pending, active, paused, failed, and scheduled workflows.
- Show last run, checkpoint strategy, restart policy, trigger, and failure
  context.
- Start a command-invokable workflow from the TUI.
- Resume failed or paused durable workflows without the TUI owning the runner
  supervision tree.

### Agent/Workflow Observability

- Runnable lifecycle table from `runnable_events`.
- Native node detail with component id/type, policy, duration, input preview,
  output preview, and error preview.
- Scorecard panel with objective status, salience/value/progress metrics,
  residual risks, and changed artifacts.
- Repair diagnostics panel that can generate a repair prompt from persisted
  data.
- Artifact trail with paths, action, SHA, byte size, and graph/blueprint
  artifacts.

### Eval And Tuning Cockpit

- Cohort picker by objective status, agent, workflow key, date range, model, or
  workspace.
- Compare scorecards across recent runs.
- Inspect prompts, tool outputs, repairs, and final answers for prompt tuning.
- Export a cohort to JSONL or a structured report for offline eval work.

Hermes translation: lifecycle hooks such as `sync_turn`, `on_session_end`,
`on_pre_compress`, `on_memory_write`, and `on_delegation` become durable signal
views over RunicAI tables. The TUI should display and trigger those projections
only after the data exists in RunicAI's persistence model.

## Proposed Command Shape

Use a separate task so the current CLI remains stable:

```sh
mix runic_ai.tui --cwd .
mix runic_ai.tui --agent assistant --cwd .
mix runic_ai.tui --sqlite .runic_ai/runs.db --run assistant:cli:123
mix runic_ai.tui --sqlite .runic_ai/runs.db --ssh 2222
mix runic_ai.tui --persistence memory --cwd .
```

Initial options:

- `--agent standard|rlm|assistant`
- `--cwd PATH`
- `--persistence sqlite|memory|none` with `sqlite` as the local harness default
- `--sqlite PATH` to override the default SQLite database path
- `--run RUN_ID`
- `--model MODEL`
- `--client default|codex`
- `--mode read_only|patch|verify`
- `--approve never|safe|ask`
- `--session-id ID`
- `--theme runic|plain`
- `--graph text|mermaid|mmdflux`
- `--ssh PORT` only after local mode is stable

Do not add backend semantics that only exist in the TUI. Runtime controls should
flow through shared terminal runner options, persistence APIs, or managed
workflow APIs.

`mix runic_ai.agent` and `mix runic_ai.tui` should share this persistence
option model. A run started from the plain CLI should be visible in the TUI
without the user remembering to opt into SQLite first.

## Architecture

Prefer the reducer runtime for this app. RunicAI's TUI has async work, durable
queries, live event subscriptions, periodic refresh, export side effects, and
potential remote sessions. A single `update/2` path with commands and
subscriptions maps better than ad hoc `handle_info/2` branches.

```text
RunicAI runtime / Runner / assistant RLM
  -> RunicAI.Terminal.Event
  -> RunicAI.Persistence.SQLite.record_terminal_event/2
  -> RunicAI.Persistence.HarnessProjection
  -> RunicAI.Persistence.Queries / Inspection / Evals / Replay
  -> RunicAI.Terminal.ExRatatui.App
  -> ExRatatui reducer runtime
  -> Rust ratatui renderer
```

Proposed namespace:

```text
lib/mix/tasks/
  runic_ai.tui.ex

lib/runic_ai/terminal/ex_ratatui/
  app.ex
  model.ex
  update.ex
  commands.ex
  subscriptions.ex
  event_bridge.ex
  persistence_view.ex
  keymap.ex
  slash_commands.ex
  theme.ex
  views/
    root.ex
    status_bar.ex
    run_picker.ex
    timeline.ex
    details.ex
    composer.ex
    review_modal.ex
    workflow_graph.ex
    managed_workflows.ex
    evidence.ex
    evals.ex
```

Responsibilities:

- `Mix.Tasks.RunicAi.Tui`: parse CLI options, ensure TTY/local or configure SSH,
  resolve the local harness persistence default, open/configure SQLite unless
  explicitly overridden, start the app.
- `App`: `use ExRatatui.App, runtime: :reducer`.
- `Model`: pure state for selected run/session, focus ring, input refs, filters,
  loaded query results, live status, pending review, graph mode, eval cohort.
- `Commands`: run queries, start/stop sessions, submit objectives, apply review
  decisions, export JSONL, resume managed workflows, render graphs.
- `Subscriptions`: periodic active-run refresh, live event mailbox drain, clock
  ticks for spinners, optional managed workflow polling.
- `PersistenceView`: convert Ecto structs into stable UI structs so views do
  not know schema internals.
- `EventBridge`: adapt live terminal events to write-through persistence and
  reducer messages.
- `Views`: pure ExRatatui widget construction.

## Core Layout

First useful layout:

```text
┌ RunicAI ─ workspace ─ agent/model ─ sqlite ─ status ─────────────┐
│ Runs / Filters      │ Timeline                         │ Detail  │
│ recent/active       │ terminal + runnable events        │ event   │
│ paused/failed       │ live + durable                     │ output  │
├─────────────────────┴──────────────────────────────────┴─────────┤
│ Composer / slash command / review reply                           │
└───────────────────────────────────────────────────────────────────┘
```

Expanded workflow/eval layout:

```text
┌ Status / Query / Cohort                                           ┐
├ Runs ┬ Timeline ┬ Workflow Graph ┬ Evidence / Scorecard / Repairs ┤
│      │          │                │                                 │
├ Managed workflows / Reviews / Artifacts / Tool calls              ┤
└ Composer / slash command                                          ┘
```

Use `WidgetList` for long timelines, `Table` for runs/tools/scorecards,
`Markdown` for assistant responses and repair prompts, `Textarea` for
multi-line objectives and review rewrites, `Popup` for review/HITL, `Tabs` for
main workbench sections, and `Sparkline`/`Gauge`/`Chart` for eval metrics only
where they clarify the data.

## Keyboard And Commands

Keyboard first:

- `Ctrl+Q` / `Ctrl+C`: quit or prompt to stop active work.
- `Ctrl+S`: stop active session.
- `Tab` / `Shift+Tab`: focus movement.
- `Up` / `Down`: move the active selection.
- `Enter`: submit composer or slash command.
- `Esc`: cancel slash command mode.
- `/`: slash command mode when the composer is empty.
- Plain printable keys always belong to the active composer or slash input.
- Resume, export, filter/search, detail, graph, and help actions are slash
  commands unless a future modal implements scoped, focus-local shortcuts.

Slash commands:

- `/help`
- `/runs [query]`
- `/search TERM`
- `/errors`
- `/reviews`
- `/tools [name]`
- `/artifacts`
- `/scorecard`
- `/repairs`
- `/managed [status]`
- `/resume`
- `/export [path]`
- `/eval objective_satisfied|objective_incomplete`
- `/graph text|mermaid|mmdflux`
- `/stop`
- `/quit`

## Implementation Phases

### Phase 0: Dependency And NIF Spike

Deliverables:

- [x] Add `{:ex_ratatui, "~> 0.8"}` on a focused branch.
- [x] Verify `mix deps.get` and `mix compile` download/use precompiled NIFs on
      the local platform.
- [x] Verify source-build fallback with `EX_RATATUI_BUILD=true` only if the
      local Rust toolchain is already available or explicitly installed.
- [x] Add `mix runic_ai.tui --help` with default SQLite behavior,
      `--persistence`, `--sqlite`, `--run`, and existing agent/model/approval
      options documented.
- [x] Add a minimal local app that starts, renders one paragraph, handles `q`,
      exits, and restores the terminal.
- [x] Verify running without `--sqlite` creates/migrates the default local
      SQLite database.
- [x] Verify `--sqlite PATH` overrides the database path and explicit ephemeral
      storage opts out.
- [x] Add a headless `test_mode` test with `Runtime.inject_event/2`.

Validation:

- [x] `mix compile --warnings-as-errors`
- [x] focused TUI tests
- [x] manual TTY smoke: start without `--sqlite`, verify default SQLite is
      created/migrated, resize, quit, terminal restored

### Phase 1: Query-Backed Read-Only Workbench

Deliverables:

- [x] Open SQLite through `RunicAI.Persistence.SQLite` by default for local
      harness mode.
- [x] Load recent runs, selected run timeline, scorecard status, failed
      runnable, artifacts, repairs, and tool calls through query helpers.
- [x] Render run picker, timeline, detail pane, and status bar.
- [x] Implement `/search`, `/errors`, `/artifacts`, `/scorecard`, `/repairs`,
      and `/export`.
- [x] Hydrate correctly from an on-disk database after a fresh BEAM start.

Validation:

- [x] Headless tests for model hydration and focus.
- [x] Headless tests for slash commands mapped to persistence queries.
- [x] Manual smoke against the default database produced by `mix runic_ai.agent`
      with no persistence flag.
- [x] Manual smoke against an overridden database produced with
      `mix runic_ai.agent --sqlite PATH`.

### Phase 2: Live Standard-Agent Session

Deliverables:

- [x] Submit objectives from `Textarea`/composer.
- [x] Run standard agent through the existing terminal runner path.
- [x] Write terminal events to SQLite before updating the TUI model.
- [x] Refresh current run panes from query results so live and postmortem paths
      match.
- [x] Keep composer/input responsive while the run is active.
- [x] Support stop/interruption and durable partial evidence.

Validation:

- [x] Scripted standard-agent integration test with headless events.
- [x] Manual read-only standard-agent smoke.
- [x] Event count in TUI equals SQLite timeline count.

### Phase 3: Review Queue And HITL Modal

Deliverables:

- [x] Render pending `review_requests`.
- [x] Open focused review modal with checkpoint, resume key, tool/path/command
      preview, risk, and allowed decisions.
- [x] Support approve, deny, stop, and rewrite.
- [x] Persist the decision as terminal/review events.
- [x] Resume a live session when the runtime handle exists.
- [x] Keep pending reviews inspectable after process restart.

Validation:

- [x] Unit tests for review state transitions.
- [x] Integration test review-gated scripted session resumes after approval.
- [x] Manual review-gated smoke.

### Phase 4: RLM And Assistant Workflow Views

Deliverables:

- [x] Render assistant/RLM phases from durable terminal events:
      proposal, validation, compilation, runnable start/complete/failure,
      repair, scorecard, artifacts, final summary.
- [x] Show runnable table from `runnable_events`.
- [x] Show graph summary/artifact from persisted graph serializer payloads.
- [x] Switch between proposal graph and materialized execution graph where both
      exist.
- [x] Show residual risks, changed files, verification observations, and
      source cues.

Validation:

- [x] Scripted assistant run creates workflow rows, runnable rows, scorecard,
      artifacts, repair rows, and graph rows visible in the TUI.
- [x] Manual conservative assistant/RLM smoke.

### Phase 5: Managed Workflows And Background Runs

Deliverables:

- [x] Managed workflow table with pending, active, paused, failed, scheduled
      filters.
- [x] Start command-invokable managed workflows from the TUI.
- [x] Resume durable workflows by delegating to caller-owned runner APIs.
- [x] Show background session cards with phase, elapsed time, review-needed
      state, and latest evidence.
- [x] Keep active-session cache as a projection only; SQLite remains the source
      of truth.

Validation:

- [x] Headless tests for managed workflow filters and resume command
      generation.
- [x] Integration test with one foreground and one background scripted run.

### Phase 6: Eval, Tuning, And Hermes-Inspired Signals

Deliverables:

- [x] Eval cohort panel using `RunicAI.Persistence.Evals`.
- [x] Compare objective status, scorecard fields, repair counts, tool failures,
      artifact counts, and model/workspace dimensions.
- [x] Add prompt/source-cue inspection for selected runs.
- [x] Add derived signal views for Hermes-like lifecycle concepts:
      prefetch candidates, session recall, sync-turn facts, delegation
      summaries, and on-session-end summaries.
- [x] Keep these views derived from RunicAI persisted signals, not new memory
      files.

Validation:

- [x] Headless tests for cohort grouping and selected-run detail hydration.
- [x] Manual smoke over a small multi-run SQLite database.

### Phase 7: Remote Transport Spike

Deliverables:

- [x] Spike `transport: :ssh` for local development only.
- [x] Confirm each SSH client gets isolated TUI state but shared SQLite-backed
      run history.
- [x] Decide whether remote TUI belongs in RunicAI core or an optional example.
- [x] Do not expose SSH by default.

Validation:

- [x] Manual local SSH smoke with generated dev host key.
- [x] Security note for auth, host keys, and disabled-by-default behavior.

### Phase 8: Hardening And Accessibility

Deliverables:

- [x] Terminal restore verification under normal quit, crash, startup error,
      timeout, and backend error.
- [x] Narrow-width layouts at 80x24 and 100x30.
- [x] Non-color/ASCII fallback.
- [x] Render-loop budget checks for large timelines and cohorts.
- [x] NIF/platform compatibility note.
- [x] Internal docs explaining CLI vs Owl CLI vs ExRatatui workbench.

Validation:

- [x] `mix format`
- [x] `mix compile --warnings-as-errors`
- [x] `mix test test/runic_ai/terminal test/runic_ai/persistence`
- [x] `mix test`
- [x] manual TTY smoke at narrow and wide sizes
- [x] manual live read-only standard-agent smoke
- [x] manual review-gated smoke
- [x] manual assistant/RLM smoke

## Implementation Notes

Completed on 2026-05-03.

- `mix runic_ai.agent`, `mix runic_ai.runs`, and `mix runic_ai.tui` now use
  the local harness default SQLite path unless persistence is explicitly set to
  `memory` or `none`.
- `mix runic_ai.tui` is an ExRatatui reducer app over the durable SQLite read
  model. It uses bounded app state only for visible projections and reloads
  runs, timelines, reviews, managed workflows, eval cohorts, artifacts, repairs,
  tool calls, scorecards, graph summaries, and Hermes-like derived signals from
  query helpers.
- Live objective submission goes through `RunicAI.Terminal.AgentRunner` with the
  already-open SQLite store, so event counts in the TUI and SQLite timeline stay
  aligned.
- The terminal runner now emits a final durable summary/error event after a run
  returns. This keeps read models from being left `running` after process exit
  and preserves failed/blocked/completed final state for postmortem debugging.
- Default CLI run IDs and terminal event IDs now use globally unique IDs rather
  than BEAM-local `System.unique_integer/1` values, which avoids collisions
  across repeated Mix invocations writing to the same local SQLite database.
- SSH remains a local-development spike. It is disabled by default and requires
  `--ssh-password`; ExRatatui generates/reuses a dev host key under the RunicAI
  priv directory when `auto_host_key: true` is used.
- Follow-up interactive input testing found that plain printable shortcuts made
  normal objectives and slash commands impossible to type. Plain letters now flow
  to the active textarea, with global quit/stop shortcuts on control chords and
  structural keys.
- Follow-up assistant debugging found that simple no-input prompts from the TUI,
  such as creative writing requests, were routed through an unnecessary generated
  source workflow and blocked as `no output produced`. The assistant now uses a
  direct single-call response lane for simple no-input/no-output requests while
  keeping durable lifecycle events and a scorecard.
- Follow-up conversation UX work made the local harness TUI chat-first by
  default. The primary view now renders a normal conversation surface with user
  turns, assistant outputs, and a compact agent activity pane for HITL, tools,
  artifacts, scorecards, and repairs. The prior run picker, timeline, evidence,
  graph, managed workflow, and eval panes remain available as the debug view via
  `/debug` or `F2`.
- TUI submissions now generate a run id before dispatch, persist the submitted
  objective as a first-class `agent_messages` user row, and pass that id through
  `--session-id` so the user turn, assistant output, lifecycle events, and final
  summary share one durable transcript.

Verification evidence:

- `mix deps.get`
- `EX_RATATUI_BUILD=true mix deps.compile ex_ratatui --force`
- `mix deps.compile ex_ratatui --force`
- `mix runic_ai.tui --help`
- `mix runic_ai.runs --help`
- `mix runic_ai.tui --cwd /tmp/runic-ai-tui-smoke` then `ctrl-q`; verified
  `/tmp/runic-ai-tui-smoke/.runic_ai/runs.db` exists and terminal restored.
- `mix runic_ai.agent "Inspect this empty workspace and report that no changes
  are needed." --agent standard --client codex --model gpt-5.2 --mode read-only
  --approve never --max-turns 1 --max-runtime-ms 90000 --cwd
  /tmp/runic-ai-agent-smoke-final --renderer text --color never`; completed with
  durable run `coding:cli:HI6UBETKIR:3:8b8c58c2`.
- `mix runic_ai.runs --cwd /tmp/runic-ai-agent-smoke-final --limit 5`; printed
  the completed durable run above.
- `mix runic_ai.tui --cwd /tmp/runic-ai-agent-smoke-final` then `ctrl-q`; displayed
  the completed run timeline and final summary from SQLite.
- OTP SSH smoke started the ExRatatui SSH transport with `auto_host_key: true`,
  authenticated with explicit password auth, allocated a PTY, received 3580
  render bytes, sent `ctrl-q`, and stopped the daemon.
- `mix runic_ai.tui --cwd /tmp/runic-ai-tui-interface-pass --persistence memory`
  interactive PTY pass: `/help` submitted and rendered help,
  `/search does-not-exist` stayed visible as a zero-result search, and
  `query review errors` remained in the composer without `q`, `e`, or `r`
  triggering global shortcuts.
- `RunicAI.Terminal.AssistantRunner.run/2` smoke with a fake client for `Write me
  a poem about frogs`; emitted `direct_response_started`,
  `direct_response_completed`, and `scorecard_completed`, then returned `:ok`.
- `mix test test/runic_ai/terminal/ex_ratatui`
- `mix test test/runic_ai/terminal test/runic_ai/persistence`
- SQLite-backed chat smoke through `RunicAI.Terminal.ExRatatui.Commands`:
  persisted `{"user", "objective", "Write me a poem about frogs"}` and
  `{"assistant", "direct_response", "Visible assistant output"}` for the same
  `assistant:tui:*` run id.
- `mix test test/runic_ai/terminal/ex_ratatui/workbench_test.exs
  test/runic_ai/persistence/sqlite_test.exs`; 20 tests, 0 failures.
- `mix test test/runic_ai/terminal test/runic_ai/persistence`; 90 tests, 0
  failures.
- `mix test`; 479 tests, 0 failures, 2 skipped.

## Recommendation

Prefer this ExRatatui alternate over the TermUI plan if the Phase 0 spike proves
the NIF dependency is stable in this repo. The package has the right shape for a
query-backed RunicAI workbench: supervised OTP apps, reducer runtime for async
effects, headless tests, stateful text inputs, rich widgets, large-list support,
and optional remote transports.

Keep the first implementation read-only and query-backed. Once the workbench can
inspect existing SQLite runs well, add live session control and review handling.
That ordering keeps the TUI grounded in the durable persistence model we just
built and avoids coupling the UI to one live process shape too early.
