# RLM Objective Loop And OpsLogic Capability Plan

Status: implemented for the deterministic objective-loop substrate and
dependency-backed OpsLogic Phoenix/LiveView/Ecto app-shell smoke. The
generated product now also includes opt-in Postgres and browser smokes for
controlled environments with a usable database role and Chrome/Chromium.

Date: 2026-05-24

## Goal

Make built-in RunicAI agents reliable for project-scale objectives such as:

1. write an implementation plan for an OpsLogic Phoenix/LiveView field service
   SaaS under `tmp/ops_logic`;
2. present that plan to the active user-facing client;
3. resume after approval and implement it through repeated
   plan/write/verify/repair iterations;
4. stop only when objective evidence says the work is complete, or ask the
   operator to approve more budget when the run is incomplete but repairable.

This maps directly to the Codex goal pattern: one objective, one verifiable
stopping condition, concrete files/commands to read first, checkpointed
progress, and a clear pause point when budget or guidance is needed.

## Added Substrate

- `RunicAI.Coding.RLM.ObjectiveSession` records the objective, workflow
  iterations, scorecard status, open repair tasks, completed tasks, progress
  log, and budget approval requests.
- Workflow attempts can now report explicit objective task deltas through
  `:task_updates`, `:objective_tasks`, or context-level equivalents. The
  objective session normalizes those deltas into durable open/completed task
  lists, records them on each iteration, and preserves them through
  serialization so Web, CLI, and TUI clients can render planned, in-progress,
  blocked, review, and completed work instead of relying only on inferred
  repair needs.
- Repeated task updates for the same open task now replace the stale task
  entry with the latest non-completed state. This keeps long-running objectives
  from showing an old `:in_progress` title/status after a later workflow
  iteration reports the same task as `:blocked`, `:review`, or otherwise
  changed.
- Review approvals now close only the review checkpoint task. Planned or
  blocked objective work that was already open before the approval remains
  durable, so clients do not briefly lose the implementation checklist between
  "plan approved" and the next workflow iteration.
- `RunicAI.Coding.RLM.ObjectiveLoop` delegates each workflow attempt to an
  existing RLM runner, records the result in the objective session, and
  continues with a repair-oriented objective until the scorecard is satisfied
  or budget approval is required.
- `RunicAI.Coding.RLM.ObjectiveLoop` also accepts an
  `:objective_progress_sink` callback. It emits iteration-started,
  iteration-completed, and iteration-error snapshots with the objective session
  summary/state, current iteration, open/completed tasks, review requests, and
  budget requests so clients can show objective-level progress while the loop
  is still running.
- Budget exhaustion is now resumable instead of a dead-end pause.
  `RunicAI.Coding.RLM.ObjectiveSession.record_budget_decision/3` records an
  approved/edited/rejected/cancelled operator decision, extends the objective
  iteration budget on approval, and prepares the next objective. The
  `ObjectiveLoop` and terminal runner expose matching `resume_after_budget`
  entry points.
- Budget approval requests now carry an explicit lifecycle in the durable
  objective session. New requests are `:pending`; approval, edit, rejection, or
  cancellation stamps the matching request with `:status`, `:resolved_at`, and
  the operator decision. Projections also expose `pending_budget_requests`, and
  the Workbench objective panel renders only pending budget prompts while still
  preserving historical approved/rejected requests for audit and replay.
- Rejected or cancelled budget decisions are terminal blocked outcomes. They
  do not expand `max_iterations`, do not start another workflow attempt, and
  leave the resolved budget request in history with no pending budget prompts.
- Objective-loop review requests now use the same lifecycle contract. Plan
  review checkpoints are persisted as `:pending`; approval, edit, rejection, or
  cancellation stamps the matching review request with `:status`,
  `:resolved_at`, and the operator decision. Projections expose
  `pending_review_requests`, and the Workbench objective panel renders only
  pending review prompts while preserving resolved review history in the
  objective-session audit trail.
- Rejected or cancelled objective review decisions also become terminal
  blocked outcomes. The loop closes the review checkpoint, keeps the original
  iteration evidence, and refuses to dispatch a follow-up workflow unless the
  operator actually approved or edited the review.
- `mix runic_ai.agent --agent rlm --objective-loop` now opts into the
  objective loop from the terminal runner. `--max-objective-iterations N`
  bounds the number of workflow attempts before the loop asks for more budget.
- `RunicAI.Terminal.RLMRunner` emits an `:objective_loop` summary event with
  the objective-session summary, decision, open tasks, completed tasks, and
  budget requests so CLI/TUI/Web clients can render the loop state.
- `RunicAI.Terminal.RLMRunner` now bridges objective progress snapshots from
  the worker task back into terminal events with phase
  `:objective_loop_progress`, preserving live progress in the same persistence
  path used for RLM stages and final summaries.
- Persisted `:objective_loop_progress` events now participate in durable
  objective-loop queries and operator-request projection. A reconnect or
  process restart before the final `:objective_loop` summary can still reload
  the latest objective session, open tasks, approval requests, and blocking
  error from the progress event stream.
- Durable objective-loop projections now also fall back to
  `objective_session_state` when deriving review/budget approval requests,
  tasks, status, iteration counts, and inferred approval actions. An event that
  carries only the serialized session state can still produce actionable
  review-table rows and client-visible pending approval state.
- `RunicAI.Coding.RLM.ObjectiveLoop` now establishes a single wall-clock
  deadline for the whole objective loop when `:max_runtime_ms` is provided.
  Each workflow attempt receives the same `:run_deadline_ms` plus a decreasing
  `:max_runtime_ms` equal to the remaining objective runtime, and an expired
  deadline becomes a structured `:needs_budget_approval` checkpoint before
  another workflow attempt is started.
- Objective runtime budget state is durable across approval pauses. The
  `ObjectiveSession` metadata records `:run_deadline_ms` and
  `:max_runtime_ms`, serialized session state preserves those values, review
  resume keeps the original objective deadline, and budget approval can extend
  an expired runtime deadline through decision metadata such as
  `:additional_runtime_ms`.
- `RunicAI.Workbench.session_snapshot/1` folds those
  `:objective_loop_progress` events into the generic `:progress_summary`,
  normalizes objective runtime fields such as `:remaining_runtime_ms` and
  `:run_deadline_ms` for clients, and the Workbench Live progress panel
  renders objective status, action, iteration, open/completed task counts, and
  remaining objective runtime while the loop is still running.
- Browser review controls can carry optional `:additional_iterations` and
  `:additional_runtime_ms` values when approving objective-loop budget
  requests, so a paused loop can resume with both more iterations and a longer
  durable runtime deadline.
- Browser objective-loop budget decisions now preserve the full runtime-budget
  metadata contract supported by the functional core: `additional_iterations`,
  `additional_runtime_ms`, `approved_runtime_ms`, and `max_runtime_ms`.
  Persisted review-decision rows retain those values, and resumed objective
  sessions apply them when extending iteration and runtime budget.
- JSON-loaded objective-session metadata now replaces stale string/atom
  counterpart keys when runtime budget fields are updated. A browser approval
  against a session recovered only from `:objective_loop_progress` state can
  therefore extend the durable `run_deadline_ms` instead of re-persisting the
  expired deadline from the serialized pause event.
- `RunicAI.Persistence.Queries.latest_objective_loop_state/2` and
  `objective_loop_events/2` reload objective-loop state from persisted terminal
  events.
- `RunicAI.Workbench.session_snapshot/1` now includes `:objective_loop`, making
  objective-loop status, action, open tasks, and budget requests available
  after reconnect.
- `RunicAIWeb.WorkbenchLive` renders an Objective loop panel on the Plan tab so
  web clients can inspect loop status, action, iteration count, open repair
  tasks, completed task counts, and budget-request reasons.
- `RunicAI.Terminal.ExRatatui` now hydrates `:objective_loop` and folded
  `:progress_summary` state from the same SQLite terminal events. The TUI
  activity strip, Agent Activity panel, and Detail / Evidence panel render
  objective status, action, iteration, open/completed task counts, and
  remaining runtime so TUI users can see the same review/budget checkpoints as
  the web client.
- TUI HITL counts now merge durable review-table rows with
  `objective_loop.pending_review_requests` and
  `objective_loop.pending_budget_requests`. This keeps the activity strip,
  Agent Activity panel, and Detail / Evidence panel honest when an
  objective-loop approval checkpoint exists only in the objective-session
  projection.
- `RunicAI.Coding.RLM.ObjectiveSession` recognizes first-class
  `RunicAI.ReviewRequest` values from RLM results. A completed planning
  workflow that needs operator approval now stops as
  `:needs_review_approval` with decision action `:request_review_approval`,
  rather than pretending the larger objective is complete or consuming repair
  budget.
- Terminal, persistence, Workbench, and the Workbench Live plan tab now carry
  `review_requests` and `latest_review_request` alongside open tasks and
  budget requests. This gives Web/CLI/TUI clients a stable state to render
  when an OpsLogic plan is ready for approval before implementation resumes.
- `RunicAI.Coding.RLM.ObjectiveLoop.resume_after_review/4` accepts a paused
  `ObjectiveSession` plus an approved or edited `RunicAI.ReviewDecision`,
  validates the resume key, records the decision in the same progress log, and
  continues the same objective session with the next workflow iteration. A
  rejected or cancelled decision becomes a terminal blocked decision.
- `RunicAI.Coding.RLM.ObjectiveSession.to_map/1` and `from_map/1` provide a
  JSON-safe session-state contract. Objective-loop terminal events persist this
  state as `objective_session_state`, and
  `RunicAI.Persistence.Queries.latest_objective_session/2` plus
  `RunicAI.Workbench.latest_objective_session/1` can reload it for
  cross-process approval/resume flows.
- Browser-owned Workbench RLM launches now opt into `--objective-loop` and
  pass `--max-objective-iterations`, so web RLM sessions get the same durable
  objective tracking, review pause, and budget state as terminal RLM sessions.
- Objective-loop plan review requests are projected into the normal durable
  review table. When a browser review decision approves or edits one of those
  requests, `RunicAI.Workbench.record_review_decision/3` reloads the persisted
  objective session and starts `RunicAI.Terminal.RLMRunner.resume_after_review/3`,
  continuing the same objective run from the approval checkpoint.
- Objective-loop budget requests are projected through the same durable review
  table. Approving one of those requests from Workbench reloads the persisted
  `ObjectiveSession`, extends the loop budget, and starts
  `RunicAI.Terminal.RLMRunner.resume_after_budget/3` against the same run.
- Objective-loop summary events also reconcile resolved review/budget request
  records back into the durable review table. This keeps terminal and TUI runs
  from leaving an objective-loop approval row permanently `pending` after the
  final objective summary carries an approved, denied, or cancelled request in
  the serialized `ObjectiveSession`.
- Browser review decisions now require the durable review row to still be
  pending. Repeated clicks or late duplicate submissions against an already
  approved, denied, or cancelled objective-loop checkpoint are rejected before
  another decision event or resume task can be recorded.
- Workbench review denial and budget cancellation now settle the persisted
  objective loop as `:blocked` with action `:stop_blocked`, reconcile the
  durable review-table row as `denied` or `cancelled`, clear pending
  review/budget prompts, and preserve the one-iteration history instead of
  accidentally resuming implementation work.
- Terminal RLM sessions now use the same objective-loop approval boundary as
  the Workbench. When a one-shot CLI run reaches an objective plan review or
  budget approval checkpoint, `RunicAI.Terminal.AgentRunner` renders the normal
  review prompt, maps the answer through `RunicAI.Terminal.ReviewPrompt`, and
  resumes the same `ObjectiveSession` through `resume_after_review/3` or
  `resume_after_budget/3` before emitting the final report.
- Terminal denial and final-stop answers use the same blocked contract as the
  functional core and Workbench. A denied plan review or cancelled budget prompt
  resolves the request, returns final status `:blocked`, and does not run
  another objective iteration.
- Terminal objective-loop auto-resume now has an explicit visible cap. If a
  one-shot terminal run still needs another review or budget approval after the
  configured automatic resume limit, `AgentRunner` emits an
  `Objective auto-resume limit reached` event and annotates the final report
  instead of silently returning a still-paused result.
- The auto-resume cap event carries the same objective-session summary/state,
  objective decision, task lists, and approval request lists as normal
  objective-loop events. Workbench and TUI progress summaries can therefore
  reload the capped run and still show the objective, current approval action,
  and pending budget/review context.
- Auto-resume cap events also project their pending review/budget request into
  the normal durable review table. A web or TUI client that reloads a capped
  terminal run can therefore render the pending approval as an actionable HITL
  row instead of only showing passive objective-loop context.
- Approving that projected cap request from Workbench reloads the serialized
  `ObjectiveSession`, extends the objective budget, resumes the same run, and
  records the request as approved without leaving stale pending status behind
  from JSON-loaded session state.
- Objective-session review and budget lifecycle updates now normalize
  JSON-loaded request maps before stamping decisions. This prevents mixed
  atom/string keys from preserving an old `"pending"` status after approval,
  rejection, or cancellation and keeps pending-count projections stable after
  serialization round trips.
- Durable objective-loop queries include the explicit
  `Objective auto-resume limit reached` resume event as objective-loop state
  while ignoring ordinary resume-start events. This lets Workbench and TUI
  reload the capped objective as the latest loop state instead of showing the
  older pre-resume budget/review checkpoint.
- Objective-loop queries now accept either the session id or the run id. This
  matters for browser-launched RLM runs where the durable session id and the
  RLM run id differ.
- `RunicAI.Coding.RLM.ElixirProjectGenerator` now treats explicit plan-file
  references such as `./tmp/ops_logic/PLAN.md` as project-root evidence for
  `tmp/ops_logic`, so follow-up prompts can say "implement this plan" without
  accidentally scaffolding below the plan file.
- The deterministic OpsLogic field-service generator now emits more of the
  requested product architecture: scheduling context, Postgres persistence
  boundary and SQL migration, dependency-backed Phoenix/LiveView dispatcher and
  worker modules, a Phoenix router with LiveView and webhook routes, Ecto Repo
  and schema modules, and tests that verify those seams compile and remain
  discoverable.
- The generated OpsLogic project now declares Phoenix, Phoenix LiveView,
  Ecto SQL, Postgrex, Bandit, Phoenix HTML, Jason, and LazyHTML dependencies,
  writes `config/config.exs` plus `config/test.exs`, and verifies the app with
  `mix deps.get`, `mix compile --warnings-as-errors`, `mix test`, and a
  runtime smoke command.
- The generated app now includes a Phoenix app shell: `OpsLogicWeb`,
  `OpsLogicWeb.Endpoint`, a real Phoenix router with LiveView and webhook
  routes, webhook controller/error JSON modules, endpoint supervision, and
  LiveView tests using `Phoenix.LiveViewTest.live_isolated/2`.
- The generated work-order context now exposes Ecto-backed persistence
  boundaries with `OpsLogic.Repo`, `OpsLogic.WorkOrders.ScheduledWorkOrder`,
  changesets, and an `Ecto.Multi` persistence plan for scheduled work orders.
  It also exposes a persisted worker lifecycle API for advancing scheduled
  work orders through `accept`, `initiate_travel`, `arrive`, `start`, and
  `complete`. Test config disables starting the Repo so the smoke does not
  require a local Postgres server, while non-test app supervision still includes
  the Repo.
- The generated app now includes `mix ops_logic.db_smoke`, an opt-in
  Postgres-backed smoke task that starts the Repo, creates the required tables
  if needed, seeds customer/worker/request rows, persists a scheduled work
  order through the domain `Ecto.Multi`, records a work-order event, reads the
  persisted rows back through dispatcher/worker LiveView-facing mount state,
  advances the worker LiveView event core through `initiate_travel`, and prints
  `opslogic_db_smoke_pass` after verifying the scheduled row, event log, and
  LiveView-facing lifecycle state.
- `RunicAI.RLM.Robustness.DeterministicChecks` supports
  `:command_passes_if_env` so expensive or environment-dependent checks can be
  part of a scenario without making the default matrix depend on local
  Postgres. When the env var is unset, the check is recorded as skipped and the
  deterministic result is review-grade instead of a full pass. The OpsLogic
  catalog runs `mix ops_logic.db_smoke` when
  `RUN_OPSLOGIC_POSTGRES_SMOKE=1` is set.
- `RunicAI.Coding.RLM.ObjectiveEvidence` now preserves explicitly changed
  files under requested generated-project paths such as `tmp/ops_logic` while
  still excluding broad `tmp`, `deps`, `node_modules`, and build-output globs.
  This keeps semantic objective judging evidence-first for prompts that
  intentionally ask the agent to build inside `./tmp`.
- The generated app now includes `mix ops_logic.browser_smoke`, an opt-in
  browser smoke task that starts the Phoenix endpoint with the Repo enabled,
  migrates/seeds the LiveView fixture rows, drives `/dispatch` and
  `/worker/work-orders` through headless Chrome/Chromium via
  `priv/browser_smoke_runner.js`, and verifies the worker state was persisted
  as `traveling` with a `travel_started` event. The robustness catalog runs
  this check only when `RUN_OPSLOGIC_BROWSER_SMOKE=1` is set.
- The robustness catalog now includes
  `opslogic_objective_loop_approval_resume`, an explicit scenario for the
  original two-turn OpsLogic shape: write `tmp/ops_logic/PLAN.md`, pause for
  review, resume after approval, then verify plan, product-shape files,
  compile, tests, and runtime smoke under `tmp/ops_logic`.
- `RunicAI.RLM.Robustness.Runner` has an OpsLogic-specific live-lane fixture
  for that catalog scenario. It launches the RLM terminal path with
  `--objective-loop`, writes the plan, records a review pause, drives the
  terminal approval prompt, resumes the same `ObjectiveSession`, applies the
  generated OpsLogic project, and records objective-loop evidence in the matrix
  report.
- `test/runic_ai/coding/rlm_objective_loop_test.exs` includes a deterministic
  OpsLogic two-turn regression: first write and satisfy the reviewable plan
  objective, then run an approved implementation objective that reads the plan,
  generates `tmp/ops_logic`, and verifies product-shape files, compile, tests,
  and runtime smoke.
- `test/runic_ai/coding/rlm_objective_loop_test.exs` also covers declined
  operator checkpoints: review rejection and budget cancellation both return
  `:stop_blocked`, resolve the matching request lifecycle record, keep the
  original iteration count, and prove no additional runner is invoked.
- `RunicAI.Coding.RLM.ObjectiveSession` treats blank edited operator decisions
  as absent edits, so review and budget approvals with whitespace-only
  replacement text fall back to the default continuation objective instead of
  resuming a workflow with an empty objective.
- Persisted or operator-supplied blank `next_objective` values are normalized
  away before the next workflow objective is selected. Reloaded sessions and
  review/budget resume overrides therefore fall back to the original objective
  or generated continuation prompt instead of dispatching an empty workflow.
- Objective-loop timeout and other budget-style errors now generate budget
  requests for the active workflow iteration, including the case where a shared
  runtime deadline expires before the first workflow attempt. Operator-facing
  budget approval checkpoints therefore start at iteration `1`, not an
  impossible iteration `0`.
- JSON-style runner results now classify `context.runtime_timeout` and
  context-level `repair_status` with the same typed access used elsewhere in
  `ObjectiveSession`. A string-keyed blocked runner result therefore becomes a
  structured `:needs_budget_approval` checkpoint instead of silently continuing
  as a generic running objective.
- Recording an objective-loop error clears stale `latest_result` and
  `next_objective` state before publishing the checkpoint. Budget and failure
  clients therefore see the current blocking error instead of a previous
  continuation prompt or scorecard.
- Approving a review or budget request clears stale `latest_error` state when
  the session returns to planning. Resumed sessions therefore report the active
  continuation state, not the error that led to the already-approved checkpoint.
- `ObjectiveSession.summary/1` and browser/TUI progress summaries now expose
  the current objective-loop error kind and message. Budget and failure
  checkpoints can therefore tell user-facing clients why the objective is
  waiting without requiring those clients to parse the full serialized session
  state.
- Workbench progress summaries now fold final `:objective_loop` summary
  events directly, not only live `:objective_loop_progress` events. Browser
  progress panels therefore retain objective, action, iteration budget, and
  latest-error details after a loop pauses for plan review or budget approval.
- Durable objective-loop projections now include `latest_error`,
  `latest_error_kind`, and `latest_error_message` from the objective-session
  summary/state. Clients that consume `snapshot.objective_loop` directly can
  render the blocking reason without re-parsing raw terminal event payloads.
- The Workbench Live progress panel renders objective-loop error details as a
  first-class fact. Browser users can see the blocking timeout or budget reason
  on the Plan tab without opening raw event JSON.
- ExRatatui activity summary, activity, and detail views render the objective
  error kind/message when present, so terminal users can see the blocking
  runtime or repair reason alongside objective status, action, iteration,
  task, and remaining-budget progress.
- Plain terminal objective-loop summary events now include the latest
  objective error in their human-readable detail string. Non-TUI CLI output
  therefore reports the same blocking budget or timeout reason that web and
  TUI clients receive from structured objective-session state.
- Generic terminal final events now prefer the objective-loop session status
  over the inner workflow scorecard status. A paused auto-resume-capped run
  therefore reports final `objective_status: needs_budget_approval`, not the
  stale inner `objective_incomplete` scorecard, so clients can render the next
  actionable approval state from the final event alone.
- `RunicAI.ReviewDecision.from_input/1` accepts JSON-style client maps with
  string keys and string statuses, `RunicAI.ResumeSignal.from_input/1` accepts
  string-keyed maps for known resume kinds, and `ObjectiveSession` covers those
  maps for both review and budget resume decisions. This keeps browser, CLI,
  TUI, and persisted decision payloads on the same typed approval boundary
  without converting arbitrary user strings into atoms.
- Malformed review decision and resume signal maps now return structured
  validation errors for missing resume keys, invalid statuses, and unsupported
  string resume kinds instead of raising before the objective loop can report a
  useful operator-facing failure.
- `test/runic_ai/rlm/robustness_test.exs` now includes the live
  `opslogic_objective_loop_approval_resume` lane regression, proving the
  robustness runner can drive plan creation, approval capture, resume, and
  deterministic verification through the same terminal RLM objective-loop
  surface.
- The robustness catalog also includes
  `opslogic_objective_loop_budget_resume`, which forces the OpsLogic objective
  loop to stop after one iteration, records an objective budget approval
  request, approves additional iterations, resumes the same `ObjectiveSession`,
  and verifies the final OpsLogic product shape.
- `test/runic_ai/rlm/robustness_test.exs` includes the live
  `opslogic_objective_loop_budget_resume` lane regression, proving that
  iteration-budget exhaustion is a resumable operator checkpoint rather than a
  failed or falsely-complete objective.
- `test/runic_ai/workbench_test.exs` covers the same declined-checkpoint
  contract through persisted browser-facing sessions: denying an objective
  review or stopping a budget request produces a blocked objective-loop
  snapshot, clears pending prompts, resolves the durable review row, and does
  not advance beyond the original iteration.
- `test/runic_ai/terminal/runner_test.exs` covers the CLI declined-checkpoint
  contract: terminal `deny` and `stop` answers return a blocked final result,
  stamp review/budget request history, and prove the second objective iteration
  is not dispatched.
- `test/runic_ai/persistence/sqlite_test.exs` and
  `test/runic_ai/workbench_test.exs` assert that an auto-resume cap event
  becomes both latest objective-loop state and a normal pending durable review
  row, preserving the "approve more budget if desired" path after reload.
- `test/runic_ai/workbench_test.exs` also proves the projected cap review row
  can be approved to resume the same serialized objective session through the
  next workflow iteration and finish the objective.
- `test/runic_ai/coding/rlm_objective_loop_test.exs` covers JSON-loaded review
  and budget request lifecycle updates directly, including pending-count
  behavior after `ObjectiveSession.to_map/1` and `from_map/1` round trips.

The important behavior is that repair exhaustion and iteration exhaustion are
not final success. They become `:needs_budget_approval` with a structured
decision that web, CLI, and TUI clients can render as "approve more budget or
stop here".

## Verification

- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/coding/rlm_agent_test.exs:324`
- `mix test test/runic_ai/coding/rlm_agent_test.exs:324`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/persistence/sqlite_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
- `mix test test/runic_ai/workbench_test.exs:667`
- `mix test test/runic_ai/workbench_test.exs:746`
- `mix test test/runic_ai/workbench_test.exs:764 test/runic_ai/persistence/sqlite_test.exs:302`
- `mix test test/runic_ai/rlm/robustness_test.exs`
- `mix test test/runic_ai/rlm/robustness_test.exs:962`
- `mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/persistence/sqlite_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
- `mix test test/runic_ai/rlm/robustness_test.exs:80 test/runic_ai/coding/rlm_objective_loop_test.exs --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/workbench_test.exs:190 --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/terminal/runner_test.exs --trace`
- `mix test test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/workbench_test.exs:882 --trace`
- `mix test test/runic_ai/rlm/robustness_test.exs:139 test/runic_ai/rlm/robustness_test.exs:1003 --trace`
- `mix test test/runic_ai/rlm/robustness_test.exs`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/coding/rlm_agent_test.exs:324 test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/persistence/sqlite_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs && mix compile --warnings-as-errors`
- `mix test test/runic_ai/rlm/robustness_test.exs:1004 test/runic_ai/rlm/robustness_test.exs:1048 --trace`
- `mix test test/runic_ai/terminal/runner_test.exs:352 test/runic_ai/terminal/runner_test.exs:426 --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/workbench_test.exs:882 test/runic_ai/rlm/robustness_test.exs:1048 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/workbench_test.exs:180 test/runic_ai/workbench_test.exs:888 test/runic_ai_web/workbench_live_test.exs:245 --trace`
- `mix test test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/coding/rlm_objective_loop_test.exs --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:536 --trace`
- `mix test test/runic_ai/rlm/robustness_test.exs:121 test/runic_ai/rlm/robustness_test.exs:140 --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/rlm/robustness_test.exs:121 test/runic_ai/rlm/robustness_test.exs:140 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/terminal/ex_ratatui/workbench_test.exs --trace`
- `mix test test/runic_ai/terminal/ex_ratatui/workbench_test.exs test/runic_ai/terminal/runner_test.exs:352 test/runic_ai/terminal/runner_test.exs:426 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs --trace`
- `mix test test/runic_ai/workbench_test.exs:888 --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/workbench_test.exs:888 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/workbench_test.exs:821 test/runic_ai/workbench_test.exs:888 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/terminal/ex_ratatui/workbench_test.exs:60 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/persistence/sqlite_test.exs:477 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/workbench_test.exs:821 test/runic_ai/workbench_test.exs:895 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/terminal/runner_test.exs:416 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/terminal/runner_test.exs:426 test/runic_ai/terminal/ex_ratatui/workbench_test.exs:90 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/persistence/sqlite_test.exs:302 test/runic_ai/workbench_test.exs:233 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs test/runic_ai/workbench_test.exs --trace`
- `mix test test/runic_ai/terminal/runner_test.exs:426 test/runic_ai/terminal/runner_test.exs:649 --trace`
- `mix test test/runic_ai/persistence/sqlite_test.exs:302 test/runic_ai/workbench_test.exs:233 --trace`
- `mix test test/runic_ai/persistence/sqlite_test.exs:302 test/runic_ai/workbench_test.exs:233 test/runic_ai/terminal/ex_ratatui/workbench_test.exs:90 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/workbench_test.exs:296 --trace`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:608 test/runic_ai/coding/rlm_objective_loop_test.exs:660 --trace`
- `mix test test/runic_ai/rlm/robustness_test.exs:80 test/runic_ai/rlm/robustness_test.exs:1005 test/runic_ai/rlm/robustness_test.exs:1049 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_reliability_test.exs:760 test/runic_ai/coding/rlm_reliability_test.exs:787 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:608 test/runic_ai/coding/rlm_reliability_test.exs:787 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/control/control_contracts_test.exs:19 test/runic_ai/coding/rlm_objective_loop_test.exs:657 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/control/control_contracts_test.exs:19 test/runic_ai/control/control_contracts_test.exs:76 test/runic_ai/coding/rlm_objective_loop_test.exs:657 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:608 test/runic_ai/coding/rlm_objective_loop_test.exs:657 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:277 test/runic_ai/coding/rlm_objective_loop_test.exs:324 test/runic_ai/coding/rlm_objective_loop_test.exs:660 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:504 test/runic_ai/coding/rlm_objective_loop_test.exs:277 test/runic_ai/coding/rlm_objective_loop_test.exs:324 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:504 test/runic_ai/coding/rlm_objective_loop_test.exs:525 test/runic_ai/coding/rlm_objective_loop_test.exs:277 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:504 test/runic_ai/workbench_test.exs:233 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/terminal/ex_ratatui/workbench_test.exs:60 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/terminal/runner_test.exs:214 --trace`
- `mix test test/runic_ai/workbench_test.exs:289 test/runic_ai_web/workbench_live_test.exs:265 --trace`
- `mix test test/runic_ai/persistence/sqlite_test.exs:302 test/runic_ai/workbench_test.exs:533 test/runic_ai_web/workbench_live_test.exs:265 --trace`
- `mix test test/runic_ai/persistence/sqlite_test.exs:442 test/runic_ai/workbench_test.exs:180 --trace`
- `mix test test/runic_ai/workbench_test.exs:1212 --trace`
- `mix test test/runic_ai/workbench_test.exs:538 --trace`
- `mix test test/runic_ai/persistence/sqlite_test.exs:442 test/runic_ai/workbench_test.exs:180 test/runic_ai/workbench_test.exs:538 test/runic_ai/workbench_test.exs:1346 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/coding/rlm_objective_loop_test.exs:57 --trace`
- `mix test test/runic_ai/terminal/runner_test.exs:517 --trace`
- `mix test test/runic_ai/terminal/runner_test.exs:383 test/runic_ai/terminal/runner_test.exs:457 test/runic_ai/terminal/runner_test.exs:517 test/runic_ai/terminal/runner_test.exs:686 --trace && mix compile --warnings-as-errors`
- `mix test test/runic_ai/persistence/sqlite_test.exs:536 --trace`
- `mix test test/runic_ai/persistence/sqlite_test.exs:302 test/runic_ai/persistence/sqlite_test.exs:442 test/runic_ai/persistence/sqlite_test.exs:536 test/runic_ai/persistence/sqlite_test.exs:656 test/runic_ai/persistence/sqlite_test.exs:773 --trace && mix compile --warnings-as-errors`

The OpsLogic regression exercises the current deterministic field-service
project generator. It proves objective-loop continuation, artifact reuse,
dependency-backed Phoenix/LiveView/Ecto scaffolding, endpoint/router/LiveView
test wiring, Ecto schema and `Ecto.Multi` persistence boundaries,
LiveView-facing persisted mount state, click-driven LiveView tests, persisted
worker lifecycle transitions, and verification behavior without depending on a
live LLM. By default it does not depend on a live Postgres server or browser,
but skipped opt-in smokes keep the OpsLogic robustness rows at `review` rather
than claiming complete external verification. Setting
`RUN_OPSLOGIC_POSTGRES_SMOKE=1` enables the generated DB smoke, and setting
`RUN_OPSLOGIC_BROWSER_SMOKE=1` enables the generated browser smoke in
environments with a usable Postgres role plus Chrome/Chromium. Those opt-in
smokes were not run on this machine because local Postgres rejects the current
OS user role.

## Remaining Integration Slice

- Run `RUN_OPSLOGIC_POSTGRES_SMOKE=1 RUN_OPSLOGIC_BROWSER_SMOKE=1` in CI or
  another controlled environment with a real Postgres role and Chrome/Chromium
  to collect live DB/browser evidence for the generated app. The verifier
  artifact is now generated; the remaining external slice is provisioning and
  executing it in that environment.
