# Phoenix LiveView Local Agent Workbench Plan

Status: implementation in progress

Date: 2026-05-05

Scope: a Phoenix LiveView surface for RunicAI local developer use, desktop
packaging, and `runic_ai server` style startup. The preferred prep path is an
in-repo Phoenix graft that lets this repository become the normal Phoenix
project root while preserving the existing RunicAI runtime/library modules.
A separate sibling `runic_ai_web` app with a path dependency remains viable for
early isolation, but an umbrella is not the default target.

## Motivated By

- dissatisfaction with the limits of a TUI for a flexible coding-agent
  workbench;
- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`;
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`;
- `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`;
- `.docs/035-termui-coding-agent-terminal-interface-implementation-plan.md`;
- `.docs/038-ex-ratatui-tui-polish-implementation-plan.md`;
- `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`;
- `DESIGN.md`;
- `.docs/design_refs/index.html`;
- `.docs/DESIGN-deprecated.md` as historical terminal/TUI design context;
- the existing `RunicAI.Terminal.Event` and `RunicAI.Persistence.*` surfaces;
- Livebook's local web application, escript, release, and desktop packaging
  shape: https://github.com/livebook-dev/livebook;
- Libbit's Phoenix/LiveView chat, interactor, MDEx, Tailwind, hook, and
  workflow-canvas patterns in `/home/doops/wrk/libbit`.

## Goal

Build a RunicAI web application that feels like a local developer workbench for
coding agents, not a hosted SaaS control panel and not a notebook clone.

The app should be able to:

- start from an installed command such as `runic_ai server`;
- bind locally by default and open a tokenized browser URL;
- boot a RunicAI supervision tree, SQLite repo, managed workflow registry,
  runtime workers, agent sessions, tracing, and queryable read models;
- provide a polished LiveView interface for prompt/chat operation, HITL review,
  tool activity, artifacts, workflow graphs, logs, traces, evals, and durable
  session history;
- later package as a desktop app using the same local Phoenix application
  foundation.

The Livebook comparison is about packaging and local-product posture:

- a Phoenix/LiveView application that can run locally;
- an escript or release entrypoint that starts the web server;
- local-first security defaults;
- a future desktop wrapper around the same web application.

RunicAI should not copy Livebook's notebook model. The RunicAI product center is
agent execution, Runic workflow inspection, coding-agent review, and durable
local observability.

## Product Boundary

Prefer one OTP application and one repository root for the local product:

1. Existing `RunicAI.*` modules remain the runtime/library substrate. They own
   workflows, agents, terminal events, persistence schemas, Runic runner
   integration, and query APIs.
2. New `RunicAIWeb.*` modules own the endpoint, router, assets, LiveViews, web
   components, hooks, local auth, desktop/server packaging, and first-run setup.
3. Phoenix dependencies may live in this repository. The important boundary is
   namespace and responsibility, not a separate OTP app.

This makes the repository a typical Phoenix project with a substantial RunicAI
runtime inside it. That is acceptable for the local workbench goal.

The main alternative is a sibling `/home/doops/wrk/runic_ai_web` Phoenix app
with `{:runic_ai, path: "../runic_ai"}` during development. That keeps the
dependency boundary cleaner at the cost of coordinating two repos and making
the eventual `runic_ai server` packaging path less direct.

Do not use an umbrella as the default migration path. Umbrellas are useful when
the project needs separate applications with different release compositions.
That is not currently the problem we are solving.

Core RunicAI should expose stable child specs and query functions the web app
can consume:

```elixir
children = [
  {RunicAI.Persistence.SQLite, database: path, migrate?: true},
  {RunicAI.Runtime, runtime_opts},
  {RunicAI.ManagedWorkflows, workflow_opts}
]
```

The exact child specs can change, but the ownership must stay clear:

- `RunicAI.*` owns runtime behavior and durable records.
- `RunicAIWeb.*` owns presentation, browser events, routes, assets, and
  packaging.
- Terminal and web surfaces consume the same normalized event/read-model
  substrate.

## Packaging Direction

Use Livebook as a reference path, but stage the work conservatively.

### Escript Server

First target:

```sh
mix escript.install hex runic_ai
runic_ai server
```

Expected behavior:

- choose a default local data directory such as `~/.runic_ai` or an explicit
  `--data-path`;
- open or create a SQLite database;
- run migrations before endpoint start;
- start RunicAI runtime children under the application supervision tree;
- run the Phoenix dev server on `localhost:4000` by default for local Tidewave
  MCP compatibility;
- reserve a separate default port for future escript/desktop packaging so it
  does not conflict with other users' Phoenix projects;
- generate a one-time token or persistent local secret;
- print the local URL and token;
- support `--port`, `--ip`, `--data-path`, `--open-browser`, `--no-open`,
  `--log-level`, and `--database` flags.

### Mix/Dev Server

Development target:

```sh
mix phx.server
mix runic_ai.server
iex -S mix phx.server # to get iex involved
```

For an in-repo graft, `mix phx.server` is the normal Phoenix development path.
If the sibling-app option is chosen first, the sibling app should use a local
path dependency on this repository and keep the same eventual server contract.

### Release

Second packaging target:

- build a server release for users who want a standalone local web server;
- include prebuilt assets;
- avoid requiring asset compilation on install;
- keep runtime config in environment variables and CLI options;
- support headless local server usage.

### Desktop App

Later packaging target:

- wrap the same local Phoenix endpoint in a desktop shell;
- keep the browser app and desktop app sharing the same LiveView routes,
  persistence, auth, and assets;
- avoid desktop-only features in the first LiveView implementation unless they
  degrade cleanly in the browser.

## Security Defaults

RunicAI web will execute commands, read files, write files, call LLM providers,
and store traces. The local security model must be explicit from the first
slice.

Required defaults:

- bind to `127.0.0.1` / `http://localhost:4000` in development
- require a tokenized local URL or local auth secret;
- treat remote bind as opt-in;
- require explicit configuration before exposing the server beyond localhost;
- store secrets outside trace/message tables;
- redact prompt, tool, and environment payloads before writing previews;
- make destructive tool approvals visible and durable;
- preserve path-policy and command-policy decisions from the runtime;
- provide a clear first-run page for database path, provider keys, model
  defaults, and local access settings.

The web app should not assume that "local" means safe. Local pages can still
trigger high-impact operations.

## Dependency Direction

Initial web dependencies:

- Phoenix and Phoenix LiveView for the application and UI.
- `ecto_sqlite3` through RunicAI persistence or the web app repo, depending on
  final ownership.
- Tailwind and Phoenix component composition for UI.
- Heroicons through Phoenix's normal `<.icon>` path.
- `mdex` for Markdown-to-HTML rendering, syntax highlighting, tables,
  tasklists, autolinks, and alert-style content.
- Mermaid JS for browser graph rendering.
- Phoenix LiveView JS commands and hooks for client-side interaction.

Avoid early dependencies that create a second application model:

- no React/Svelte workflow canvas until Mermaid and LiveView-native graph
  views hit their limits;
- no separate SPA router;
- no websocket protocol parallel to LiveView unless a concrete browser feature
  requires it;
- no workspace-scoped dynamic repos copied from Libbit unless RunicAI later
  needs multiple independent local stores.

## LiveView Implementation Conventions

Use these conventions for the future web app:

- `mount/3` sets stable defaults, empty streams, subscriptions, and assign
  shape.
- `handle_params/3` loads page data that depends on route params, query params,
  filters, selected tabs, database pagination, or search context.
- `handle_event/3` handles server-side effects such as starting a run,
  submitting a prompt, approving a tool call, replaying a workflow, cancelling
  a session, or changing persisted settings.
- Phoenix JS commands handle browser-local state such as dropdowns, popovers,
  disclosure state, selected client-side tabs, focus management, and purely
  visual transitions.
- Hooks handle browser APIs such as Mermaid rendering, auto-scroll, clipboard,
  local measurements, keyboard shortcuts, drag/drop, file selection, and editor
  integrations.
- LiveView streams render sessions, messages, trace rows, logs, artifacts, and
  graph event lists.
- Long-running runtime work writes durable state first, broadcasts a small
  event, and lets LiveViews refresh from the same query functions used for
  postmortem views.

This mirrors Libbit's strongest pattern without carrying over its workspace
repo scope.

## Visual System

Default to the dark/night-mode web design system in root `DESIGN.md`, with the
exported prototype in `.docs/design_refs/index.html` as the concrete reference
artifact. `.docs/DESIGN.md` is deprecated for web UI work and remains terminal
and TUI design history.

Web palette mapping:

| Design Token | Web Use |
| --- | --- |
| `bg` | body background and empty app shell |
| `surface` | sidebar, top bars, compact panels |
| `surface_elevated` | active session panels, modals, composer |
| `border` | bronze separators and quiet outlines |
| `text` | primary content |
| `text_soft` | secondary labels and metadata |
| `muted` | timestamps, inactive sessions, disabled actions |
| `primary` | focus, current run, active controls |
| `gold` | tool and evidence accents |
| `purple` | RLM plan/workflow surfaces |
| `magenta` | HITL, review, rewrite, policy prompts |
| `success` | passed checks and accepted actions |
| `warning` | waiting, partial evidence, repair |
| `error` | failed checks, denied operations, exceptions |
| `info` | neutral links and trace metadata |

Design preferences:

- Inter is the default UI font.
- Use backdrop blur, opacity, and rounded edges where they improve hierarchy.
- Tailwind CSS v4 uses `app.css` as a configuration surface. Use it for
  Tailwind setup, theme/design tokens, font configuration, plugins, and the
  design scheme that should be shared across the app.
- Prefer Tailwind classes in colocated HEEx markup for ordinary styling. Add
  custom CSS only when it belongs to the shared design scheme or when Tailwind
  and component composition cannot express the behavior cleanly.
- Prefer colocated HEEx markup with Tailwind classes and reusable function
  components.
- Use cards for repeated session/message/artifact items and modals, not for
  every page section.
- Keep the default screen dense, work-focused, and useful without a marketing
  landing page.
- Do not put explanatory feature-tour copy in the primary workbench. The UI
  should show runs, decisions, evidence, and controls directly.

## Primary App Shell

Use a persistent shell:

- left sidebar for sessions, saved runs, agents, managed workflows, debug
  views, evals, settings, and help/reference;
- top bar for active session, workspace root, model/client, runtime status,
  SQLite status, provider status, and auth/bind mode;
- main pane for the current route;
- optional right inspector for selected event, file, tool call, graph node,
  scorecard, or artifact;
- persistent composer in session/chat routes.

The sidebar should list recent sessions by default:

- running sessions first;
- waiting/HITL sessions next;
- failed sessions with clear status;
- recently completed sessions;
- filters for agent type, status, workspace root, model, and date.

### UX Calibration From Reference Interface

The reference interface reinforces the shape RunicAI should use for the first
browser workbench slice:

- keep a stable left sidebar with recent sessions, status dots, compact titles,
  and minimal chrome;
- keep the center pane chat-first, with the composer always reachable and
  diagnostic detail kept adjacent instead of interrupting the chat flow;
- use a right-side debug layer split into two regions: a top record browser
  with a type selector and dense table, and a lower append-only event log;
- make the debug layer table-driven for sessions, tool calls, messages, runs,
  events, and later traces/artifacts/scorecards;
- let compact/expanded modes control diagnostic density rather than changing
  the primary chat layout;
- adapt the layout to the Runic dark palette from `DESIGN.md`, using
  bronze separators, restrained surfaces, mint focus, gold tool accents, and
  explicit status text in addition to color.
- keep the prototype component inventory as near-term backlog: right inspector
  collapse, persisted client tab state, first-class Plan tab content, durable
  review controls, artifact provenance rows, query-backed logs/traces filters,
  and dark Mermaid graph rendering.

## UX Pages And Facets

### Session Chat Workbench

This is the primary view.

It should include:

- prompt/composer with model, agent, approval mode, workspace root, and
  optional slash commands;
- streamed assistant/final messages;
- grouped tool activity;
- compact and expanded debug modes;
- visible HITL prompts with approve, deny, rewrite, and resume controls;
- files changed, tests run, artifacts, and residual risk summaries;
- secondary channels for thinking, tool calls, repair attempts, and evidence;
- per-message actions: copy, pin, inspect source event, regenerate/retry when
  supported, collapse/expand details;
- durable session timeline behind the chat flow.

Design note: chat is the operator surface, not the whole product model. The
page should make Runic workflow state, tool work, evidence, and review gates
visible without requiring users to read raw traces.

### New Objective Page

For cases where chat is too open-ended, provide a structured run launcher:

- objective text;
- agent type: Assistant, Standard/ReAct, RLM;
- workspace root and path policy;
- model/client;
- approval mode;
- persistence target;
- concurrency/timeout limits;
- initial context attachments;
- expected verification command or smoke target.

This can start as a modal or a first-run empty state, then become its own page
when configuration grows.

### Sessions And Runs

Queryable index over SQLite:

- session id, title/objective, status, agent, model, workspace, start/end time;
- active, waiting, failed, repaired, completed, cancelled filters;
- resume, replay, export JSONL, duplicate objective, delete/redact controls;
- saved views for "needs review", "failed checks", "recent artifacts", and
  "long-running".

### Agent Index

List built-in and configured agents:

- Assistant;
- Standard/ReAct;
- RLM;
- coding-agent variants;
- user-defined managed workflow agents later.

Each agent row should show:

- purpose;
- default model/client;
- default approval policy;
- default concurrency;
- available tools;
- recent success/failure metrics;
- last runs.

### Agent Show

Each default agent should have a show page:

- current configuration;
- model and tool policy;
- prompt/source templates when inspectable;
- Mermaid-rendered workflow graph;
- recent runs and scorecards;
- failure/repair patterns;
- launch button with prefilled agent type.

For Assistant, Standard/ReAct, and RLM, the graph view should distinguish:

- static/default workflow shape;
- generated proposal graph for RLM-style runs;
- materialized Runic workflow graph;
- observed execution path.

### Workflow Graph Viewer

Dedicated graph page for a run or managed workflow:

- Mermaid dark theme render;
- source Mermaid text;
- graph metadata;
- selected node details;
- node status overlay from observed events;
- proposal vs execution toggle;
- layout refresh when graph source changes;
- fallback text adjacency when Mermaid fails.

Use a browser hook for Mermaid rendering. Cache successful render state by
graph hash, theme, and viewport width where practical.

### HITL Review Queue

Review work should be first-class:

- queue of pending approvals;
- command/path/tool preview;
- risk reason and policy trigger;
- diff or artifact preview;
- approve once, deny, rewrite, approve pattern, stop session;
- durable decision history;
- filter by session, agent, risk, tool, and workspace.

This should not be buried inside chat scrollback.

### Tool And Capability Registry

Developer interface for understanding what the agent can do:

- configured tools;
- command policies;
- path policies;
- LLM provider capabilities;
- tool schemas;
- recent tool failures;
- per-tool audit history;
- disabled or unavailable tools with reasons.

### Artifacts And File Changes

Coding agents need a page that treats outputs as real work products:

- generated files;
- patches and diffs;
- command output;
- verification logs;
- saved reports;
- downloadable/exportable artifacts;
- artifact provenance back to run, tool, and workflow node.

The first version can be per-session. A global artifact index can come later.

### Logs, Traces, And Events

Debug interface analogous to the TUI debug workbench:

- terminal events;
- runnable lifecycle events;
- workflow events;
- logs captured from the runtime;
- trace spans;
- errors and repair triggers;
- raw JSON preview with redaction;
- filters for kind, status, phase, component, session, and time.

This page should read from durable SQLite tables, not a LiveView-only memory
buffer.

### Managed Workflows

RunicAI should expose workflow management as a product concept:

- workflow definitions;
- schedules;
- triggers;
- current and previous runs;
- checkpoints/facts/snapshots;
- manual run controls;
- pause/resume/cancel;
- workflow-level scorecards and artifacts.

This is where RunicAI starts to diverge from a pure chat app.

### Evals And Scorecards

Inspection and comparison view:

- objective scorecards;
- smoke scenario results;
- repair counts;
- model/client comparisons;
- prompt variant comparisons;
- failure clusters;
- source-cue coverage;
- verification command outcomes.

This should make it practical to tune agents from observed local runs.

### Context And Memory Inspector

Developer-facing context view:

- source files selected;
- prompt inputs;
- source cues;
- token estimates;
- context compaction events;
- remembered facts when that substrate exists;
- rejected or redacted context.

This should help answer why the agent did or did not see a piece of evidence.

### Settings And First-Run Setup

Local app setup:

- data path and SQLite database path;
- provider API keys and model aliases;
- default agent/model/approval settings;
- theme;
- auth token and bind address;
- update channel for desktop later;
- import/export/redaction settings;
- diagnostics bundle export.

Settings should be boring and explicit. This application controls local code
execution.

### System Health

Operational view:

- app version;
- RunicAI version;
- SQLite migration status;
- supervisor/runtime status;
- active workers;
- provider smoke status;
- disk usage;
- database size;
- WAL/checkpoint status;
- failed background tasks.

This page will save time during desktop and escript support.

## Data Flow

Target live data path:

```text
Browser event or runtime event
  -> LiveView event handler or RunicAI runtime
  -> RunicAI runtime writes durable event/message/artifact rows
  -> PubSub broadcasts small invalidation/update event
  -> LiveView reloads the affected projection through query modules
  -> LiveView streams or assigns bounded UI data
```

The durable store remains the source of truth.

Avoid:

- rendering directly from in-memory runtime structs;
- keeping large traces only in LiveView assigns;
- using browser state as the only record of review decisions;
- letting Mermaid source, Markdown HTML, or artifact previews bypass redaction
  and sanitization.

## Markdown And Mermaid

Markdown:

- use MDEx in the server-side projection path for trusted rendered message
  HTML;
- enable tables, tasklists, autolinks, strikethrough, alerts, and code syntax
  highlighting;
- store raw Markdown plus rendered HTML where useful for fast chat rendering;
- sanitize or tag-filter untrusted content;
- expose raw Markdown in inspectors for debugging.
- https://hex.pm/packages/mdex_mermaid enables MDEX to render mermaid diagrams inside markdown blocks 

Mermaid:

- render in the browser with Mermaid JS and a dark theme;
- support code-fenced Mermaid blocks in Markdown;
- support explicit graph artifacts from RunicAI;
- show source when rendering fails;
- keep graph rendering out of core RunicAI logic;
- do not require Mermaid for terminal or JSONL outputs.

## Phase 0: Product Boundary And App Skeleton

Deliverables:

- [x] Decide between in-repo Phoenix graft and sibling path-dependency app.
- [x] If grafting in-repo, generate a temporary Phoenix app as a donor and
      copy/adapt its Phoenix-specific files into this repository.
- [x] Do not generate the sibling `/home/doops/wrk/runic_ai_web` app for the
      first implementation slice.
- [x] Add Tailwind, Heroicons, MDEx, Mermaid JS, and SQLite dependencies.
      Tailwind, Heroicons, MDEx, SQLite, and the browser Mermaid loader are now
      present; graph-specific Mermaid surfaces remain in Phase 4.
- [ ] Define local config shape for data path, token, bind address, database,
      default model/client, and theme. Data path, database, default
      agent/model/client, approval, mode, and theme are present; token/bind
      packaging config remains.
- [ ] Add `runic_ai server` command shape as a CLI contract.
- [ ] Add a minimal local-auth/token plug.
- [ ] Add first-run setup route and local health route.
- [x] Preserve existing RunicAI CLI, terminal, persistence, docs, and test
      behavior during the structural change.

Validation:

- [x] `mix compile --warnings-as-errors`.
- [x] `mix test`.
- [ ] Start server locally and confirm tokenized access. Existing dev server
      rendered the workbench over localhost; tokenized access remains pending.
- [ ] Confirm existing `mix runic_ai.agent`, `mix runic_ai.runs`, and
      `mix runic_ai.tui` entrypoints still work or have clear replacements.

## Phase 1: Runtime And Persistence Bridge

Deliverables:

- [x] Start RunicAI SQLite persistence under the web supervision tree.
- [x] Run migrations on boot when configured.
- [x] Start runtime children used by the web workbench.
- [x] Add query modules or adapter functions needed by LiveViews.
- [x] Add PubSub invalidation events for sessions, messages, traces, logs,
      artifacts, review requests, and workflow graph updates through the
      terminal-event persistence path.
- [x] Add a read-only sessions index backed by SQLite.
- [x] Add a read-only session show page backed by SQLite.

Validation:

- [x] Seed or run a deterministic local session.
- [ ] Confirm session rows survive server restart.
- [x] Confirm LiveViews hydrate from SQLite.
- [x] Confirm no page depends on the original BEAM process for historical data.

## Phase 2: Primary Chat Workbench

Deliverables:

- [x] Build the persistent app shell and left session sidebar.
- [x] Apply the `DESIGN.md` / `.docs/design_refs/index.html` prototype shell:
      frosted sidebar, chat-first center pane, persistent composer, topbar
      pills, workspace tabs, right inspector tabs, and shared OKLCH tokens.
- [x] Build session chat flow using grouped presentation entries.
- [x] Add composer for new objectives and follow-up prompts. `/sessions/new`
      now provides an explicit empty-session state from the sidebar, while
      selected session routes carry the current `session_id` through composer
      submissions for follow-up continuity.
- [x] Add streaming/final message rendering.
- [x] Add MDEx-rendered Markdown messages.
- [x] Add compact and expanded debug modes.
- [x] Add auto-scroll hook that respects user scroll position.
- [x] Add secondary channels for thinking, tool calls, repair, and evidence.
- [x] Add session status, model/client, workspace, and approval metadata.

Validation:

- [x] Run a deterministic assistant smoke through the browser-owned launch
      path.
- [x] Confirm messages persist and reload.
- [x] Confirm streaming or progressive updates do not steal focus. The
      browser-verified new-session and review interactions preserved composer
      focus boundaries; the auto-scroll hook remains the only scroll behavior.
- [x] Confirm Markdown rendering in LiveView tests. Code fence/table/long-output
      browser checks remain for the visual QA pass.

## Phase 3: Review, Tools, And Artifacts

Deliverables:

- [x] Add prototype-style visual shells for HITL review cards in chat when
      persisted review/approval events are present.
- [x] Add review queue page. `/reviews` selects the first recent session with a
      pending review and the session-level Reviews tab lists durable review
      requests.
- [x] Add approve, deny, rewrite, and stop event handlers. Browser handlers
      persist terminal review-decision events through `RunicAI.Workbench`
      before the LiveView reloads the durable snapshot.
- [x] Add tool activity visual panels from the existing persisted message,
      terminal event, tool call, and workflow run projections.
- [x] Add artifact/file-change visual placeholders in the inspector using
      current artifact, tool call, scorecard, and workflow run projections.
- [x] Add verification result summaries.
- [x] Add durable decision history.

Validation:

- [x] Exercise a run that requires approval. Verified in-browser with
      `web-review-smoke:27399`.
- [x] Confirm decisions persist before the runtime resumes. Browser approval
      wrote `review:web-smoke:22340` with status `approved` and a decision
      payload in SQLite before the LiveView snapshot reloaded.
- [x] Confirm denied/rewrite paths are visible in session history. Focused
      Workbench tests cover approve, deny, rewrite, and stop decision
      projection.
- [x] Confirm artifacts link back to run/tool/workflow source. The inspector now
      renders persisted artifact, tool-call, scorecard, and workflow-run rows
      with their source ids/metadata.

## Phase 4: Agent And Workflow Graph Views

Deliverables:

- [x] Add agent index and built-in agent show pages. `/agents` lists the
      built-in Assistant, Standard/ReAct, and RLM agents; `/agents/:agent_id`
      renders each agent configuration, recent runs, graph, and node inspector.
- [x] Render Assistant, Standard/ReAct, and RLM workflow graphs with Mermaid.
      Built-in graph maps render through the web Mermaid hook while preserving
      source fallback text.
- [x] Add run-specific proposal/materialized/execution graph toggles.
      `/runs/:run_id/graph` can switch between generated proposal,
      materialized Runic graph, and observed execution path sources when those
      persisted read models exist.
- [x] Add selected node inspector.
- [x] Add graph source fallback and copy controls. Graph pages keep Mermaid
      source and adjacency fallback visible and expose SVG/source copy buttons.
- [x] Add dark Mermaid theme integration.

Validation:

- [x] Render known generated RLM graph. Browser-verified
      `web-phase4-rlm:18187` proposal and materialized graph routes rendered
      Mermaid SVG successfully.
- [x] Render built-in agent graph. Browser-verified `/agents/assistant`
      rendered the built-in Assistant graph with the Mermaid dark theme.
- [x] Confirm Mermaid failure shows source and does not crash the LiveView.
      Browser-verified `web-phase4-invalid:18251` shows the source fallback and
      keeps the LiveView alive when Mermaid rejects invalid source.
- [x] Confirm graph state matches persisted run events. Browser-verified the
      execution graph for `web-phase4-rlm:18187` shows three terminal events,
      one runnable event, and `ok` node statuses from persisted run events.

## Phase 5: Debug Workbench

Deliverables:

- [x] Logs page. `/debug/logs` renders paginated terminal events from the
      durable SQLite read model with run/session/kind/status/phase/search
      filters.
- [x] Traces/events page. `/debug/traces` renders terminal, runnable lifecycle,
      and workflow-event panels for a selected run using bounded queries.
- [x] Managed workflows page. `/debug/managed` renders managed workflow
      definitions and last-run metadata with status/search filters.
- [x] Scorecards/evals page. `/debug/scorecards` renders objective scorecards
      and component status rows with run/status filters.
- [x] Context/source inspector. `/debug/context` renders selected run source
      cues, chat-visible messages, artifacts, and workflow facts.
- [x] System health page. `/debug/health` renders local runtime, SQLite
      database, bind, and persisted row counts.
- [x] JSONL export from persisted rows. `/debug/export/:run_id` streams
      persisted terminal events as newline-delimited JSON.

Validation:

- [x] Compare a browser debug view against the same run's JSONL export.
      Browser-verified `web-phase5-debug:118915`: `/debug/logs?...&limit=2`
      showed 2 of 5 rows while `/debug/export/web-phase5-debug%3A118915`
      returned 5 JSONL lines and matching first/second event titles.
- [x] Confirm filters are query-param backed and reloadable.
      Browser-verified direct reloads for logs, traces, scorecards, context,
      health, and `/debug/managed?status=paused&q=phase-five-debug-web-118915`.
- [x] Confirm large event sets paginate or stream without loading everything
      into assigns. Browser-verified `limit=2` rendering and tests cover
      bounded LiveView assigns. The first managed-workflow browser pass exposed
      SQLite's lack of `ilike`; the search query now uses SQLite-compatible
      `like` and has regression coverage.

## Phase 6: Escript, Release, And Desktop Packaging

Deliverables:

- [x] Build escript packaging. `mix.exs` now exposes a `runic_ai` escript
      through `RunicAI.Server`, whose `server` command configures Phoenix,
      SQLite, token auth, local bind, and the workbench runtime before startup.
- [x] Include prebuilt assets for installation. `priv/static` is included in
      package files and `mix assets.deploy` builds digested CSS/JS/static
      assets for release/package startup.
- [x] Add release packaging. The project now has a `:runic_ai` release shape
      plus runtime defaults that bind locally, accept `RUNIC_AI_SERVER`,
      `RUNIC_AI_IP`, `RUNIC_AI_PORT`, and avoid requiring a hosted
      `SECRET_KEY_BASE` for local releases.
- [x] Add desktop packaging spike over the same local endpoint.
      `RunicAI.Server.Desktop` defines the desktop wrapper contract as the same
      `runic_ai server` entrypoint and route space, not a separate app.
- [x] Add install/update docs after behavior is real. This phase now records
      the concrete command contract and validation notes below; public install
      docs can be promoted later when distribution choices settle.
- [x] Add support diagnostics export. `/debug/diagnostics` exports a redacted
      JSON support bundle with app version, endpoint config, workbench config,
      persistence health, and row counts.

Validation:

- [x] Install locally from package or path and run `runic_ai server`.
      Verified the path command with
      `mix runic_ai.server --port 4108 --data-path tmp/phase-6-server-smoke-nowatch --token phase6-token --no-open`.
- [x] Confirm first-run database creation and migrations. The server smoke
      created `runs.db`, `runs.db-shm`, `runs.db-wal`, and `secret_key_base`
      under `tmp/phase-6-server-smoke-nowatch`.
- [x] Confirm browser access uses tokenized URL. `GET /` without token returned
      `401 RunicAI local access token required`; `GET /?token=phase6-token`
      returned `200` and set the local auth session cookie.
- [x] Confirm packaged assets do not require Node on end-user startup.
      `mix assets.deploy` produced digested assets under `priv/static`; the
      package/release path serves those assets from Phoenix static files.
- [x] Confirm desktop wrapper and browser server use the same routes.
      `RunicAI.Server.Desktop.server_args/1` delegates to `runic_ai server`,
      and `entry_route/1` preserves normal browser routes such as `/` and
      `/sessions/new`.

## Phase 7: Polish And Power-User Controls

Deliverables:

- [x] Command palette.
- [x] Keyboard shortcuts.
- [x] Saved filters.
- [x] Pinning and bookmarks.
- [x] Diff-focused artifact view.
- [x] Prompt/model comparison affordances.
- [x] Accessibility pass.
- [x] Reduced-motion option.
- [x] High-contrast theme option.

Validation:

- [x] Browser screenshot pass across desktop and narrow widths.
      Chrome-devtools screenshots were saved to `tmp/phase-7-desktop.png` at
      1440x1000 and `tmp/phase-7-narrow.png` at 390x844 against
      `http://127.0.0.1:4109/?token=phase7-token`.
- [x] Keyboard-only pass for primary run/review flows. Browser-verified
      `Ctrl+K` opened the command palette and `Esc` closed it. `/`, `g n`,
      `g r`, and `g l` are wired in `WorkbenchPreferences`, and LiveView tests
      cover command-palette, pin/filter, display-mode, artifact, bookmark, and
      comparison interactions.
- [x] Confirm text does not overflow controls. Phase 7 controls use stable
      min-height, truncation, table-fixed/debug overflow, scroll containers,
      and narrow-width breakpoints; focused LiveView tests render these states.
- [x] Confirm dark theme contrast on core surfaces. High-contrast mode now
      swaps token values at `[data-contrast="high"]`, and focus-visible outlines
      use the primary token across links, buttons, inputs, selects, and
      textareas.

Phase 7 verification commands:

- `mix test test/runic_ai/server_test.exs test/runic_ai_web/workbench_live_test.exs test/runic_ai_web/debug_live_test.exs`
  -> 17 tests, 0 failures.
- `mix compile --warnings-as-errors` -> passed.
- `mix test` -> 554 tests, 0 failures, 2 skipped.
- `mix assets.deploy` -> built digested static assets in `priv/static`.
- Browser screenshot/keyboard pass -> opened
  `http://127.0.0.1:4109/?token=phase7-token`, captured desktop and narrow
  screenshots, verified the command palette via `Ctrl+K`, and saw no browser
  console errors.

### Phase 7 Tidewave UX User Story Walkthrough

Use this as the browser-side validation script for a Tidewave agent.

Precondition:

1. Start the web app with `mix phx.server` on `http://localhost:4000`, or use a
   tokenized local server URL printed by `mix runic_ai.server --no-open`.
2. If the browser has no sessions with reviews/artifacts, seed one through
   Tidewave eval before opening the page:

   ```elixir
   alias RunicAI.Workbench

   session_id = "tidewave-phase7:#{System.unique_integer([:positive])}"
   now = DateTime.utc_now()

   Workbench.record_terminal_event(%{
     id: "tidewave-phase7:start:#{System.unique_integer([:positive])}",
     session_id: session_id,
     run_id: session_id,
     agent: :assistant,
     kind: :status,
     phase: :session,
     status: :running,
     title: "Phase 7 browser validation",
     detail: "Validate command palette, filters, pins, artifacts, and comparison.",
     data_json: %{run_id: session_id, cwd: File.cwd!(), objective: "Phase 7 browser validation", model: "test:model"},
     at: now
   })

   Workbench.record_terminal_event(%{
     id: "tidewave-phase7:artifact:#{System.unique_integer([:positive])}",
     session_id: session_id,
     run_id: session_id,
     agent: :assistant,
     kind: :summary,
     phase: :completed,
     status: :ok,
     title: "Phase 7 artifact",
     detail: "diff artifact ready",
     data_json: %{
       artifacts: [
         %{
           path: "lib/example.ex",
           kind: "diff",
           action: "updated",
           payload: %{
             title: "Phase 7 diff",
             preview: "lib/example.ex",
             diff: "@@ -1 +1\n-old browser line\n+new browser line"
           }
         }
       ]
     },
     at: DateTime.add(now, 1, :second)
   })

   session_id
   ```

Walkthrough:

1. Open `/` or `/sessions/<seeded-session-id>` and confirm the workbench shell
   renders with the command palette button, saved filter list, composer, and
   inspector.
2. Press `Ctrl+K` or `Cmd+K`. Confirm the command palette opens, contains New
   session, Focus composer, Review queue, Logs and traces, filter commands, and
   display-mode commands. Press `Esc` and confirm it closes.
3. Press `/` and confirm focus moves to the objective composer without changing
   route or scroll state.
4. Select or open a seeded session, click `Pin`, then click the Pinned saved
   filter. Confirm the URL includes `?filter=pinned` and the pinned session
   remains visible.
5. Toggle high contrast and reduced motion. Confirm the root workbench element
   changes to `data-contrast="high"` and `data-motion="reduced"` and the UI
   remains legible.
6. Open the Artifacts inspector tab. Confirm the diff-focused panel displays
   the artifact title and the `+new browser line` diff line. Click Bookmark and
   confirm the artifact state changes to Bookmarked.
7. Click Compare for the selected session, open the Details inspector tab, and
   confirm the Prompt/model comparison panel lists the selected run with its
   model.
8. Use `g l` and `g r` from the workbench. Confirm they route to Logs and
   Reviews respectively without requiring mouse interaction.
9. Resize to a narrow viewport. Confirm controls wrap instead of overlapping,
   the right inspector drops away at the configured breakpoint, and the
   composer remains reachable.

## Open Questions

- Should the first implementation be an in-repo Phoenix graft or a sibling
  `/home/doops/wrk/runic_ai_web` app with a path dependency?
- If the sibling app is used first, when should it be folded back into this
  repository for `runic_ai server` packaging?
- Should the local database default to the current workspace's `.runic_ai`
  directory or an OS user-data directory?
- How much first-run setup should happen before the main workbench appears?
- Should browser auto-open be default for escript installs, or should the
  command only print the tokenized URL?
- What is the minimum viable desktop wrapper: Tauri, ElixirKit-style release
  flow, or a lighter OS-specific launcher?
- Which graph representation should be canonical for built-in agents: stored
  Mermaid source, Runic workflow introspection, or a serializer output that can
  produce Mermaid and other formats?

## Near-Term Recommendation

Prefer an in-repo Phoenix graft unless an initial scratch implementation needs
the isolation of a sibling app.

The safest graft path is:

1. Generate a temporary Phoenix LiveView project outside the repo using the
   desired options.
2. Copy only Phoenix-owned files into this repo: `config`, `assets`,
   `priv/static`, endpoint/router/components/LiveViews, and dependency/config
   additions.
3. Keep existing `RunicAI.*` source, tests, mix tasks, docs, persistence, and
   terminal behavior in place.
4. Add `RunicAIWeb.*` modules alongside `RunicAI.*`, not inside the runtime
   namespaces.
5. Run the existing RunicAI verification before adding real UI behavior.

The first functional slice should prove three things:

1. `runic_ai server` can start a local authenticated LiveView app with SQLite
   and RunicAI runtime children.
2. The primary session workbench can launch an assistant run, show streamed or
   progressive chat, expose tool/review state, and reload from SQLite after a
   restart.
3. Agent show pages can render dark Mermaid workflow graphs for Assistant,
   Standard/ReAct, and RLM without embedding graph rendering into RunicAI core.

Once those are proven, invest in release/escript polish and only then desktop
packaging.
