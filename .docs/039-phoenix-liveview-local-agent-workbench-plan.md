# Phoenix LiveView Local Agent Workbench Plan

Status: planning

Date: 2026-05-05

Scope: a separate Phoenix LiveView application packaged alongside RunicAI for
local developer use, desktop packaging, and `runic_ai server` style startup.
This plan does not move Phoenix, LiveView, or web UI dependencies into the core
RunicAI library.

## Motivated By

- dissatisfaction with the limits of a TUI for a flexible coding-agent
  workbench;
- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`;
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`;
- `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`;
- `.docs/035-termui-coding-agent-terminal-interface-implementation-plan.md`;
- `.docs/038-ex-ratatui-tui-polish-implementation-plan.md`;
- `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`;
- `.docs/DESIGN.md`;
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

Keep two applications:

1. `runic_ai`: the library and runtime substrate. It owns workflows, agents,
   terminal events, persistence schemas, Runic runner integration, and query
   APIs. It remains usable without Phoenix.
2. `runic_ai_web` or equivalent: the Phoenix LiveView product application. It
   depends on RunicAI, owns the endpoint, router, assets, LiveViews, web
   components, hooks, local auth, desktop/server packaging, and first-run setup.

The web app may live in a sibling repo, a sibling directory, or an umbrella
application during development. The durable design constraint is that RunicAI
core should not gain a hard Phoenix dependency.

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

- RunicAI owns runtime behavior and durable records.
- The web app owns presentation, browser events, routes, assets, and packaging.
- Both terminal and web surfaces consume the same normalized event/read-model
  substrate.

## Packaging Direction

Use Livebook as a reference path, but stage the work conservatively.

### Escript Server

First target:

```sh
mix escript.install hex runic_ai_web
runic_ai server
```

Expected behavior:

- choose a default local data directory such as `~/.runic_ai` or an explicit
  `--data-path`;
- open or create a SQLite database;
- run migrations before endpoint start;
- start RunicAI runtime children under the web app supervision tree;
- run server on `localhost:8082` by default
- generate a one-time token or persistent local secret;
- print the local URL and token;
- support `--port`, `--ip`, `--data-path`, `--open-browser`, `--no-open`,
  `--log-level`, and `--database` flags.

### Mix/Dev Server

Development target:

```sh
mix phx.server
mix runic_ai.web.server
iex -S mix phx.server # to get iex involved
```

This path should use local path dependencies and Phoenix dev tooling without
changing the escript behavior.

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

- bind to `127.0.0.1` / `http://localhost:8082`
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

Default to a dark/night-mode theme derived from `.docs/DESIGN.md`.

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

- [ ] Decide app name, repo shape, and dependency boundary.
- [ ] Generate Phoenix LiveView skeleton in the separate app.
- [ ] Add RunicAI as a path dependency during development.
- [ ] Add Tailwind, Heroicons, MDEx, Mermaid JS, and SQLite dependencies.
- [ ] Define local config shape for data path, token, bind address, database,
      default model/client, and theme.
- [ ] Add `runic_ai server` command shape as a CLI contract.
- [ ] Add a minimal local-auth/token plug.
- [ ] Add first-run setup route and local health route.

Validation:

- [ ] `mix compile --warnings-as-errors` in the web app.
- [ ] `mix test` in the web app.
- [ ] Start server locally and confirm tokenized access.
- [ ] Confirm RunicAI core can still compile/test without Phoenix deps.

## Phase 1: Runtime And Persistence Bridge

Deliverables:

- [ ] Start RunicAI SQLite persistence under the web supervision tree.
- [ ] Run migrations on boot when configured.
- [ ] Start managed workflow/runtime children.
- [ ] Add query modules or adapter functions needed by LiveViews.
- [ ] Add PubSub invalidation events for sessions, messages, traces, logs,
      artifacts, review requests, and workflow graph updates.
- [ ] Add a read-only sessions index backed by SQLite.
- [ ] Add a read-only session show page backed by SQLite.

Validation:

- [ ] Seed or run a deterministic local session.
- [ ] Confirm session rows survive server restart.
- [ ] Confirm LiveViews hydrate from SQLite after restart.
- [ ] Confirm no page depends on the original BEAM process for historical data.

## Phase 2: Primary Chat Workbench

Deliverables:

- [ ] Build the persistent app shell and left session sidebar.
- [ ] Build session chat flow using grouped presentation entries.
- [ ] Add composer for new objectives and follow-up prompts.
- [ ] Add streaming/final message rendering.
- [ ] Add MDEx-rendered Markdown messages.
- [ ] Add compact and expanded debug modes.
- [ ] Add auto-scroll hook that respects user scroll position.
- [ ] Add secondary channels for thinking, tool calls, repair, and evidence.
- [ ] Add session status, model/client, workspace, and approval metadata.

Validation:

- [ ] Run an assistant smoke from the browser.
- [ ] Confirm messages persist and reload.
- [ ] Confirm streaming or progressive updates do not steal focus.
- [ ] Confirm Markdown, code fences, tables, and long output render correctly.

## Phase 3: Review, Tools, And Artifacts

Deliverables:

- [ ] Add HITL review cards in chat.
- [ ] Add review queue page.
- [ ] Add approve, deny, rewrite, and stop event handlers.
- [ ] Add tool activity panels.
- [ ] Add artifact/file-change panels.
- [ ] Add verification result summaries.
- [ ] Add durable decision history.

Validation:

- [ ] Exercise a run that requires approval.
- [ ] Confirm decisions persist before the runtime resumes.
- [ ] Confirm denied/rewrite paths are visible in session history.
- [ ] Confirm artifacts link back to run/tool/workflow source.

## Phase 4: Agent And Workflow Graph Views

Deliverables:

- [ ] Add agent index and built-in agent show pages.
- [ ] Render Assistant, Standard/ReAct, and RLM workflow graphs with Mermaid.
- [ ] Add run-specific proposal/materialized/execution graph toggles.
- [ ] Add selected node inspector.
- [ ] Add graph source fallback and copy controls.
- [ ] Add dark Mermaid theme integration.

Validation:

- [ ] Render known generated RLM graph.
- [ ] Render built-in agent graph.
- [ ] Confirm Mermaid failure shows source and does not crash the LiveView.
- [ ] Confirm graph state matches persisted run events.

## Phase 5: Debug Workbench

Deliverables:

- [ ] Logs page.
- [ ] Traces/events page.
- [ ] Managed workflows page.
- [ ] Scorecards/evals page.
- [ ] Context/source inspector.
- [ ] System health page.
- [ ] JSONL export from persisted rows.

Validation:

- [ ] Compare a browser debug view against the same run's JSONL export.
- [ ] Confirm filters are query-param backed and reloadable.
- [ ] Confirm large event sets paginate or stream without loading everything
      into assigns.

## Phase 6: Escript, Release, And Desktop Packaging

Deliverables:

- [ ] Build escript packaging.
- [ ] Include prebuilt assets for installation.
- [ ] Add release packaging.
- [ ] Add desktop packaging spike over the same local endpoint.
- [ ] Add install/update docs after behavior is real.
- [ ] Add support diagnostics export.

Validation:

- [ ] Install locally from package or path and run `runic_ai server`.
- [ ] Confirm first-run database creation and migrations.
- [ ] Confirm browser access uses tokenized URL.
- [ ] Confirm packaged assets do not require Node on end-user startup.
- [ ] Confirm desktop wrapper and browser server use the same routes.

## Phase 7: Polish And Power-User Controls

Deliverables:

- [ ] Command palette.
- [ ] Keyboard shortcuts.
- [ ] Saved filters.
- [ ] Pinning and bookmarks.
- [ ] Diff-focused artifact view.
- [ ] Prompt/model comparison affordances.
- [ ] Accessibility pass.
- [ ] Reduced-motion option.
- [ ] High-contrast theme option.

Validation:

- [ ] Browser screenshot pass across desktop and narrow widths.
- [ ] Keyboard-only pass for primary run/review flows.
- [ ] Confirm text does not overflow controls.
- [ ] Confirm dark theme contrast on core surfaces.

## Open Questions

- Should the first implementation live in a sibling repo or a sibling app in a
  temporary umbrella during development?
- Should the installed command be owned by `runic_ai_web` while still named
  `runic_ai`, or should core RunicAI eventually expose a CLI package that
  delegates to the web app?
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

Start with a sibling Phoenix app that depends on RunicAI by path and proves
three things:

1. `runic_ai server` can start a local authenticated LiveView app with SQLite
   and RunicAI runtime children.
2. The primary session workbench can launch an assistant run, show streamed or
   progressive chat, expose tool/review state, and reload from SQLite after a
   restart.
3. Agent show pages can render dark Mermaid workflow graphs for Assistant,
   Standard/ReAct, and RLM without embedding graph rendering into RunicAI core.

Once those are proven, invest in release/escript polish and only then desktop
packaging.
