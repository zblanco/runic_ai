# SQLite-Backed Agent And Workflow Durability Implementation Plan

Status: Phase 0 through Phase 6 implementation complete; follow-on work should
focus on real-run hardening, indexed metric expansion, retention/redaction
policy, and application-owned repo integration examples.

Date: 2026-05-02

Updated: 2026-05-03

Last verified: 2026-05-03 (`mix format`; `mix compile
--warnings-as-errors`; `mix test test/runic_ai/persistence
test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/agent_task_test.exs`;
`mix test`)

## Decision Update

The original proposal targeted a lightweight optional SQLite layer implemented
directly with `:exqlite`. The implementation direction is now Ecto-backed
SQLite by default:

- add `:ecto_sql` and `:ecto_sqlite3` as near-term dependencies;
- expose a default `RunicAI.Persistence.SQLite.Repo` using
  `Ecto.Adapters.SQLite3`;
- use Ecto migrations, schemas, changesets, and composable query modules for
  RunicAI's own store;
- keep caller-owned repos supported so applications can embed the same schemas
  and queries in their own persistence topology;
- keep JSONL as an export format and ETS as an optional live cache, not as the
  durable source of truth.

This is the only material change from the proposal. The goal is still local,
opt-in SQLite durability for agent harnesses, Runic workflow execution, workflow
management, tracing, debugging, evals, prompt tuning, and derived agent metrics.

## Goal

Build the first durable RunicAI agent and workflow store on SQLite using Ecto.
The store should support two related needs:

- operational persistence: durable execution, resume/replay, workflow facts,
  checkpoints, long-running jobs, periodic jobs, managed workflow definitions,
  and ad-hoc deterministic workflows that users can invoke by command;
- observability and evaluation: queryable sessions, conversations, messages,
  tool calls, review gates, subagents, runnable lifecycle events, scorecards,
  artifacts, repair attempts, trace timelines, prompt inputs/outputs, and
  metric data used to reason about salience, value, progress, and agent success.

Runic already supports both event/log based persistence and fact-level storage.
RunicAI should use that model directly instead of inventing a parallel workflow
durability layer.

## Motivated By

- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`
- `.docs/031-general-purpose-dynamic-rlm-workflow-generation-implementation-plan.md`
- `.docs/033-assistant-rlm-general-purpose-completion-and-smoke-plan.md`
- `.docs/036-runic-native-dynamic-workflow-generation-refactor-plan.md`
- existing `RunicAI.Coding.Persistence` adapters;
- existing `RunicAI.Terminal.Event` JSON-safe event contract;
- existing `RunicAI.RLM.WorkflowExecutor` runnable lifecycle events;
- `Runic.Runner.Store` event stream, snapshot, and fact callbacks.

## Design Principles

- Ecto SQLite is the default durable local database backend.
- Persistence remains opt-in. Core RunicAI components and workflows must still
  run without a database.
- The `Runic.Runner.Store` adapter is the operational durability path for
  workflow execution.
- Agent, chat, terminal, eval, and trace tables are read models over the same
  durable run identity.
- Append-only workflow events are kept as the causal source for replay.
- Fact storage is first-class so checkpoints do not need to inline every large
  value.
- Ecto schemas and changesets are public enough for users to build their own
  components and queries.
- Query modules should return `Ecto.Query` values where practical, not only
  execute opaque helper functions.
- SQLite details should use normal Ecto migrations, with raw SQL reserved for
  SQLite-specific pragmas, indexes, triggers, and FTS.
- WAL mode, single-writer expectations, and busy timeouts are part of the
  default SQLite configuration.
- JSON previews are optimized for inspection; Erlang term binaries are allowed
  for Runic-internal values that need exact reconstruction.
- Redaction and payload-size caps apply before writing terminal, prompt, tool,
  and message previews.

## Dependency Plan

Add normal dependencies:

```elixir
{:ecto_sql, "~> 3.13"},
{:ecto_sqlite3, "~> 0.22"}
```

`ecto_sqlite3` brings `exqlite` as the low-level driver. RunicAI should stop
building new persistence code directly on `Exqlite.Sqlite3`; the existing
`RunicAI.Coding.Persistence.SQLite` module can become a compatibility shim over
the Ecto store or be retired after equivalent coverage exists.

Default SQLite repo settings should mirror the proven local app shape used in
Libbit and Compendium:

- `pool_size: 1`
- `journal_mode: :wal`
- `synchronous: :normal`
- `busy_timeout: 15_000`
- `cache_size: -64_000`
- `temp_store: :memory`
- `queue_target: 1_000`
- `queue_interval: 5_000`

## Target Boundary

RunicAI should support both a package-owned default SQLite repo and caller-owned
Ecto repos.

Default local usage:

```elixir
{:ok, store} =
  RunicAI.Persistence.SQLite.open(
    database: ".runic_ai/runs.db",
    migrate?: true
  )

workspace =
  RunicAI.Coding.Workspace.new!(
    root: ".",
    persistence: {RunicAI.Persistence.SQLite, store}
  )
```

Caller-owned repo usage:

```elixir
store =
  RunicAI.Persistence.SQLite.Store.new(
    repo: MyApp.RunicAIRepo,
    dynamic_repo: :my_workspace_repo
  )

RunicAI.Persistence.SQLite.migrate!(store)
RunicAI.Persistence.Queries.run_timeline(store, run_id)
```

Runner usage:

```elixir
children = [
  {RunicAI.Persistence.SQLite, database: ".runic_ai/runs.db", name: MyApp.Runs},
  {Runic.Runner,
   name: MyApp.Runner,
   store: RunicAI.Persistence.RunnerStore,
   store_opts: [repo: RunicAI.Persistence.SQLite.Repo, dynamic_repo: MyApp.Runs]}
]
```

The exact child spec API can change during implementation, but the boundary
should stay explicit: callers pass a repo/database handle, and RunicAI does not
silently create durable state unless persistence is configured.

## Proposed Namespace

```text
lib/runic_ai/persistence.ex
lib/runic_ai/persistence/store.ex
lib/runic_ai/persistence/sqlite.ex
lib/runic_ai/persistence/sqlite/repo.ex
lib/runic_ai/persistence/sqlite/store.ex
lib/runic_ai/persistence/sqlite/migrator.ex
lib/runic_ai/persistence/runner_store.ex
lib/runic_ai/persistence/queries.ex
lib/runic_ai/persistence/schemas/
  agent_session.ex
  workflow_run.ex
  managed_workflow.ex
  agent_conversation.ex
  agent_message.ex
  agent_message_chunk.ex
  tool_call.ex
  review_request.ex
  subagent_run.ex
  workflow_event.ex
  workflow_snapshot.ex
  workflow_fact.ex
  runnable_event.ex
  run_artifact.ex
  scorecard.ex
  repair_attempt.ex
  terminal_event.ex
priv/runic_ai/repo/migrations/
test/runic_ai/persistence/
```

One schema module per file. Schema modules own changesets. Query construction
lives in `RunicAI.Persistence.Queries` or narrow query modules if the first file
gets too large.

## Storage Contracts

### `RunicAI.Persistence.Store`

This is the RunicAI-specific contract above the current coding-only persistence
behaviour.

Responsibilities:

- open or receive a store handle;
- migrate schema;
- create, update, and complete agent sessions;
- create and update managed workflow definitions;
- create workflow runs tied to sessions and managed workflows;
- append terminal and agent events;
- append runnable lifecycle events;
- record messages and message chunks;
- record tool calls, review gates, subagents, artifacts, scorecards, and repair
  attempts;
- expose query helpers for timelines, errors, messages, tool calls, artifacts,
  scorecards, facts, and recent runs.

The existing `RunicAI.Coding.Persistence` behaviour should delegate into this
store once equivalent artifact and generic event support exists.

### `RunicAI.Persistence.RunnerStore`

This implements `Runic.Runner.Store` with Ecto-backed SQLite tables.

Required callbacks:

- `init_store/1`
- `save/3`
- `load/2`

Stream and recovery callbacks:

- `append/3`
- `stream/2`
- `save_snapshot/4`
- `load_snapshot/2`
- `save_fact/3`
- `load_fact/2`
- `checkpoint/3`
- `delete/2`
- `list/1`
- `exists?/2`

This adapter is the critical operational piece. Durable Runic workflow
execution should go through Runic's store contract, while RunicAI-specific
tables provide queryable read models for harnesses, traces, evals, and
debugging.

## Ecto Schema Plan

All tables below should be created through Ecto migrations and represented by
Ecto schema modules unless noted otherwise. JSON fields should be maps at the
schema boundary. Blob fields are reserved for exact Runic or artifact
rehydration.

### Schema And Runs

`agent_sessions`

- `id`
- `agent_kind` such as `standard`, `assistant`, `rlm`, `subagent`
- `workspace_root`
- `objective`
- `model`
- `status`
- `started_at`
- `completed_at`
- `failed_at`
- `metadata_json`

`workflow_runs`

- `id`
- `workflow_key`
- `workflow_name`
- `session_id`
- `managed_workflow_id`
- `status`
- `trigger`
- `input_blob`
- `metadata_json`
- `last_event_sequence`
- `started_at`
- `completed_at`
- `failed_at`
- `last_checkpointed_at`
- `error_json`

`managed_workflows`

- `id`
- `workflow_key`
- `workflow_name`
- `scope_type`
- `scope_id`
- `status`
- `definition_kind`
- `definition_blob`
- `checkpoint_strategy`
- `restart_policy`
- `last_run_id`
- `metadata_json`
- timestamps

### Conversations

`agent_conversations`

- `id`
- `session_id`
- `workflow_run_id`
- `summary`
- `system_prompt`
- `strategy`
- `status`
- `first_message`
- `last_message_at`
- timestamps

`agent_messages`

- `id`
- `conversation_id`
- `session_id`
- `role`
- `message_kind`
- `source_step`
- `workflow_node`
- `runnable_id`
- `content`
- `content_json`
- `stream_complete`
- `transient`
- `supersedes_message_id`
- `presentation_group_id`
- `created_at`

`agent_message_chunks`

- `id`
- `message_id`
- `sequence`
- `chunk_kind`
- `content`
- `payload_json`
- `created_at`

### Tool Calls, Review Gates, And Subagents

`tool_calls`

- `id`
- `session_id`
- `conversation_id`
- `workflow_run_id`
- `parent_tool_call_id`
- `tool_name`
- `tool_id`
- `args_json`
- `result_json`
- `status`
- `error_json`
- `requested_at`
- `started_at`
- `completed_at`

`review_requests`

- `id`
- `session_id`
- `workflow_run_id`
- `tool_call_id`
- `kind`
- `checkpoint`
- `resume_key`
- `status`
- `details_json`
- `decision_json`
- timestamps

`subagent_runs`

- `id`
- `parent_session_id`
- `parent_workflow_run_id`
- `parent_tool_call_id`
- `agent_kind`
- `objective`
- `status`
- `started_at`
- `completed_at`
- `failed_at`
- `result_json`
- `error_json`
- `metadata_json`

### Workflow Events And Facts

`workflow_events`

- `id`
- `run_id`
- `sequence`
- `event_type`
- `node_name`
- `node_hash`
- `runnable_id`
- `component_id`
- `component_type`
- `payload_blob`
- `payload_json`
- `inserted_at`

`workflow_snapshots`

- `id`
- `run_id`
- `event_sequence`
- `workflow_blob`
- `metadata_json`
- `inserted_at`

`workflow_facts`

- `hash_key`
- `run_id`
- `producer_node`
- `component_id`
- `value_blob`
- `preview_json`
- `inserted_at`

`runnable_events`

- `id`
- `run_id`
- `sequence`
- `runnable_id`
- `node_name`
- `node_hash`
- `component_id`
- `component_type`
- `stage`
- `status`
- `input_preview`
- `output_preview`
- `error_json`
- `policy_json`
- `duration_ms`
- `inserted_at`

### Results And Inspection

`run_artifacts`

- `id`
- `run_id`
- `session_id`
- `path`
- `artifact_kind`
- `action`
- `sha256`
- `byte_size`
- `metadata_json`
- timestamps

`scorecards`

- `id`
- `run_id`
- `component_id`
- `objective_status`
- `scorecard_json`
- `created_at`

`repair_attempts`

- `id`
- `run_id`
- `sequence`
- `strategy`
- `reason_json`
- `diagnostics_json`
- `proposal_before_json`
- `proposal_after_json`
- `status`
- `created_at`

`terminal_events`

- `id`
- `session_id`
- `run_id`
- `sequence`
- `agent`
- `kind`
- `phase`
- `status`
- `title`
- `detail`
- `data_json`
- `at`

`terminal_events_fts`

- FTS5 over title, detail, message content previews, tool names, errors, and
  final answers.
- Implement with migration `execute/1` statements and keep Ecto query helpers
  around the FTS calls.

## Indexes And Constraints

Add indexes and constraints in the initial migrations:

- unique `workflow_runs.id`
- indexed `workflow_runs.workflow_key`
- indexed `workflow_runs.session_id`
- indexed `workflow_runs.managed_workflow_id`
- unique `managed_workflows.workflow_key`
- indexed `agent_conversations.session_id`
- indexed `agent_messages.conversation_id`
- unique `agent_message_chunks.message_id, sequence`
- indexed `tool_calls.workflow_run_id`
- indexed `tool_calls.tool_name`
- unique `workflow_events.run_id, sequence`
- indexed `workflow_events.node_name`
- indexed `workflow_events.runnable_id`
- indexed `workflow_events.component_id`
- indexed `workflow_events.event_type`
- unique latest snapshot lookup by `workflow_snapshots.run_id,
  event_sequence`
- unique `workflow_facts.hash_key`
- indexed `workflow_facts.run_id`
- unique `runnable_events.run_id, sequence`
- indexed `runnable_events.runnable_id`
- indexed `runnable_events.node_name`
- indexed `runnable_events.status`
- indexed `terminal_events.session_id`
- indexed `terminal_events.run_id`
- unique `terminal_events.run_id, sequence` when `run_id` is present

## Event Flow

The durable event path should be unified through the Ecto store:

```text
Runic runnable lifecycle
  -> WorkflowExecutor event_sink
  -> Terminal.Event / persistence event
  -> Ecto inserts into terminal_events + runnable_events
  -> optional JSONL export

Runic Runner durable events
  -> Runic.Runner.Store append/checkpoint/fact callbacks
  -> Ecto inserts into workflow_events + workflow_snapshots + workflow_facts

Component outputs
  -> Runic facts
  -> WorkflowResults extraction
  -> scorecards, artifacts, intermediate previews
  -> Ecto read-model rows
```

The same identity chain should connect all surfaces:

- `agent_sessions.id`
- `workflow_runs.session_id`
- `terminal_events.session_id`
- `workflow_events.run_id`
- `tool_calls.workflow_run_id`
- `scorecards.run_id`
- `run_artifacts.run_id`

## Query Goals

The first query layer should make these questions easy:

- What happened in this run, in order?
- Which Runic node failed and what input was it processing?
- Which component produced this artifact?
- Which tool calls were requested, denied, failed, or completed?
- Which review gate paused execution and what resume key was issued?
- Which subagents were launched and what did they return?
- Which repair attempt changed the blueprint?
- What scorecard blocked or accepted the result?
- Which facts were produced by a node?
- What was the latest run for this stable workflow key?
- Which runs mentioned this path, source cue, tool name, prompt text, or error?
- Which runs had high value/progress/salience scores for a given objective
  class?

Initial query functions should include:

- `RunicAI.Persistence.Queries.recent_runs/1`
- `RunicAI.Persistence.Queries.latest_run_for_workflow/2`
- `RunicAI.Persistence.Queries.run_timeline/2`
- `RunicAI.Persistence.Queries.failed_runnables/2`
- `RunicAI.Persistence.Queries.tool_calls/2`
- `RunicAI.Persistence.Queries.conversation_messages/2`
- `RunicAI.Persistence.Queries.artifacts_for_run/2`
- `RunicAI.Persistence.Queries.scorecards_for_run/2`
- `RunicAI.Persistence.Queries.facts_for_node/3`
- `RunicAI.Persistence.Queries.search_events/2`

Where practical, query helpers should return an `Ecto.Query` from a `*_query`
function and execute it from a paired helper. That keeps the public surface
composable for users.

## Example Ecto Query Composition

The query layer intentionally exposes `*_query` functions so application-owned
repos and custom harness components can compose their own filters before
execution:

```elixir
import Ecto.Query

base =
  RunicAI.Persistence.Queries.scorecards_for_status_query(
    "objective_incomplete"
  )

high_salience =
  from(scorecard in base,
    where: fragment("json_extract(?, '$.salience') >= ?", scorecard.scorecard_json, 0.7)
  )

RunicAI.Persistence.SQLite.with_repo(store, fn ->
  store.repo.all(high_salience)
end)
```

Managed workflow queries use the same pattern:

```elixir
RunicAI.Persistence.Queries.managed_workflows_query(
  status: [:paused, :failed]
)
```

## Implementation Phases

### Phase 0: Ecto Dependency And Repo Foundation

Deliverables:

- [x] Add `:ecto_sql` and `:ecto_sqlite3` dependencies.
- [x] Add `RunicAI.Persistence.SQLite.Repo`.
- [x] Add `RunicAI.Persistence.SQLite.Store` handle with `repo`,
      `dynamic_repo`, `database`, and migration metadata.
- [x] Add `RunicAI.Persistence.SQLite.open/1`, `child_spec/1`,
      `with_repo/2`, and `migrate!/1`.
- [x] Use Ecto dynamic repos so one repo module can address multiple local
      SQLite files when a harness starts per-workspace databases.
- [x] Configure WAL, busy timeout, cache, and queue settings.
- [x] Add migration loader under `priv/runic_ai/repo/migrations`.
- [x] Add test helpers for temporary on-disk SQLite databases and in-memory
      databases when supported by the adapter.

Validation:

- [x] `mix deps.get`
- [x] `mix compile --warnings-as-errors`
- [x] migration test creates all tables in a temporary database;
- [x] migration test can run twice without changing schema state;
- [x] dynamic repo test can isolate two database files in the same BEAM.

### Phase 1: Schemas, Changesets, And Query Modules

Deliverables:

- [x] Add schema modules for all tables in this plan.
- [x] Add changesets with required fields, status validation, JSON field
      normalization, timestamp handling, and size/redaction boundaries.
- [x] Add insert/update helpers for sessions, workflow runs, conversations,
      messages, chunks, tool calls, review requests, subagents, artifacts,
      scorecards, repair attempts, terminal events, runnable events, workflow
      events, snapshots, and facts.
- [x] Add `RunicAI.Persistence.Queries` with composable `Ecto.Query` builders
      and execution helpers.
- [x] Add FTS migration and `search_events/2` query helper.

Validation:

- [x] changeset tests reject invalid statuses and missing required identity
      fields;
- [x] query tests cover timeline ordering, latest workflow run, tool-call
      filtering, scorecard filtering, and FTS search;
- [x] JSON preview and blob fields round-trip representative terminal events,
      Runic events, facts, scorecards, and artifact metadata.

### Phase 2: Runic Runner Store Adapter

Deliverables:

- [x] Add `RunicAI.Persistence.RunnerStore` implementing
      `Runic.Runner.Store`.
- [x] Persist append-only workflow events with `(run_id, sequence)` uniqueness.
- [x] Implement `stream/2` as an ordered Ecto query that returns an enumerable.
- [x] Implement snapshot save/load using latest snapshot by event sequence.
- [x] Implement fact save/load with content-addressed keys.
- [x] Implement `save/3`, `load/2`, `checkpoint/3`, `delete/2`, `list/1`, and
      `exists?/2` for compatibility with Runner expectations.
- [x] Wrap writes in transactions where sequence counters and event rows must
      move together.
- [x] Add bounded busy-write retry for known SQLite busy errors beyond the repo
      busy timeout.

Validation:

- [x] `Runic.Runner` can start, run, checkpoint, stop, resume, and list a
      workflow using only the Ecto SQLite store.
- [x] A failed workflow can be inspected without replaying opaque blobs.
- [x] Snapshot plus tail events reconstructs the same workflow as full event
      replay.
- [x] Fact storage round-trips large component values without inlining them in
      every event.

### Phase 3: Coding And Assistant Harness Write-Through

Deliverables:

- [x] Adapt or replace `RunicAI.Coding.Persistence.SQLite` with the Ecto store.
- [x] Keep `RunicAI.Coding.Persistence.InMemory` and ETS useful for tests and
      live caches.
- [x] Wire `RunicAI.Terminal.Event.to_json_map/2` into `terminal_events` in
      addition to JSONL export.
- [x] Store standard coding-agent sessions, messages/events, tool calls,
      artifacts, review gates, and final summaries.
- [x] Store assistant/RLM blueprint proposal, validation, compilation,
      runnable start/complete/failure, repairs, scorecards, artifacts, and
      final summaries.
- [x] Store compact graph serializer payloads or artifact refs for generated
      Runic graphs.
- [x] Ensure prompt inputs, source cues, tool output previews, and final answers
      are queryable while respecting redaction and size caps.

Validation:

- [x] a standard coding-agent run creates a session, messages/events, tool
      calls, artifacts, review records, and a final summary;
- [x] an assistant RLM run creates workflow run rows, runnable events, native
      node details, scorecards, artifact rows, and repair attempts when
      applicable;
- [x] terminal JSONL and SQLite event counts match for a run;
- [x] persisted rows are sufficient to generate the same compact terminal
      timeline after a fresh BEAM start.

### Phase 4: Managed Workflow Operations

Deliverables:

- [x] Add create/update APIs for `managed_workflows`.
- [x] Store stable `workflow_key` separately from concrete `run_id`.
- [x] Add restart policy and checkpoint strategy changesets.
- [x] Add query helpers for pending, active, failed, paused, and scheduled
      managed workflows.
- [x] Add a small manager API that can resume durable workflows without owning
      the caller's supervision tree.
- [x] Keep room for periodic/cron triggers, command-invokable workflows, and
      dynamic workflows built by agents.

Validation:

- [x] a managed workflow definition can create multiple concrete runs;
- [x] latest run lookup by `workflow_key` works after process restart;
- [x] a paused or failed managed workflow can be listed with enough context for
      a harness to resume, repair, or report it.

### Phase 5: Inspection, Replay, And Eval Helpers

Deliverables:

- [x] Add query helpers for run timeline, graph summary, failed runnable,
      artifact trail, scorecard status, prompt/source-cue search, and repair
      diagnostics.
- [x] Add replay helpers that reconstruct a workflow through Runic events and
      summarize terminal events without requiring a running process.
- [x] Add a CLI/debug command to inspect recent runs and print a compact
      timeline.
- [x] Add eval/tuning helpers that can pull scorecards, messages, prompts,
      tool outputs, repairs, and derived metrics for a run cohort.
- [x] Document example Ecto queries for users building their own harness
      components.

Validation:

- [x] a test can terminate a run midstream, resume it, and inspect both
      pre-resume and post-resume events;
- [x] a failed assistant run can produce a repair prompt from persisted
      diagnostics;
- [x] query helpers work against an on-disk database after a fresh BEAM start;
- [x] an eval helper can compare a cohort of runs by objective status and
      scorecard data.

### Phase 6: Optional ETS Projection And JSONL Export

Deliverables:

- [x] Keep ETS as a live cache for active terminal UI state.
- [x] Derive ETS rows from SQLite events or write through to SQLite first.
- [x] Keep JSONL as a portable export format.
- [x] Add export helpers that can write terminal-event JSONL from SQLite after
      a run.
- [x] Avoid exposing ETS as the durable API.

Validation:

- [x] ETS can be disabled without losing durable run history;
- [x] JSONL export from SQLite matches live JSONL for deterministic fixture
      events;
- [x] SQLite remains sufficient for postmortem inspection.

## Resolved And Open Design Decisions

Resolved:

- Use Ecto SQLite3 as the default durable local backend.
- Use Ecto migrations and schemas rather than raw SQL strings for the schema.
- Implement `Runic.Runner.Store` directly.
- Preserve append-only event streams and fact-level storage.
- Keep JSONL as an export surface.
- Keep ETS as a live projection/cache, not durable state.

Open:

- Should local databases default to `.runic_ai/runs.db`, `tmp/runic_ai.db`, or
  an explicit caller path only?
- Should assistant smoke runner write SQLite rows immediately, or remain
  file-only until the terminal harness uses the store?
- Which scorecard and derived-metric fields deserve first-class indexed
  columns versus staying in `scorecard_json` until query pressure is clearer?
- How much `Runic.Workflow` snapshotting should happen by default versus only
  after checkpoints, pauses, failures, or completion?
- Should prompt/message FTS include raw prompt bodies by default, or require an
  explicit opt-in because of secret and data-retention concerns?

## Recommended Follow-Up

The implementation plan is complete. Follow-up work should now come from real
run pressure rather than additional substrate planning:

1. run the terminal harness against longer standard and assistant sessions with
   `--sqlite` enabled and inspect the resulting read models;
2. decide which scorecard and derived metric fields deserve first-class indexed
   columns after observing eval queries;
3. add retention, redaction, and raw-prompt opt-in policy before broad prompt
   FTS usage;
4. add application-owned repo examples once a downstream app embeds the schemas
   and query modules.
