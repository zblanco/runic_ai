# Sandbox-Backed Dynamic Workflow OODA Goal

Status: active goal structure

Date: 2026-06-18

## Purpose

This document turns the RayOps/Vmsan follow-up in
`.docs/060-rlm-vmsan-ooda-follow-up.md` into a reusable goal loop for improving
RunicAI's sandbox-backed dynamic workflow interactions. The target is not to
make one prompt pass. The target is a repeatable product loop where a user can
ask the Workbench to solve a real coding or research problem, see visible
progress, approve meaningful pauses, and get a verifiable result from a
sandboxed dynamic workflow.

## Product Goal

Make browser-launched Workflow RLM sessions reliable enough that a user can
delegate an arbitrary real task and observe the system moving through:

1. goal understanding and workflow proposal;
2. sandbox/runtime preparation with visible proof;
3. dynamic workflow execution with phase, node, child-agent, tool, and review
   progress;
4. evidence-backed repair when a child fails, edits nothing, or produces an
   invalid artifact;
5. bounded human-in-the-loop approvals for tools, reviews, and budget;
6. completion only when objective evidence proves the task was solved, or a
   clear blocked state when it was not.

## Operating Loop

Each iteration follows OODA, and each loop must end with a browser observation
against a real session:

| Phase | Action | Required Evidence |
| --- | --- | --- |
| Observe | Run or inspect a Workbench dynamic workflow session and capture where the user experience or execution contract breaks. | Session id, selected workspace, terminal events, review rows, artifacts/files, browser snapshot or screenshot. |
| Orient | Classify the failure against the general workflow contract instead of the concrete prompt. | Root-cause note that names the generic capability gap and the current code seam. |
| Decide | Pick the smallest general-purpose change that improves all similar tasks. | Target files/modules, expected state transition, and validation plan. |
| Act | Change code, tests, prompts, or docs. Avoid prompt-only fixes when runtime state can enforce the contract. | Diff, focused tests, and updated docs or ledger entry. |
| Reobserve | Rerun a browser integration slice and compare against the last failure. | New session id, event/state delta, UI delta, files/artifacts, remaining issue list. |

## Completion Contract

The active goal is not complete until current evidence proves all of these:

- A Workbench-launched Workflow RLM session can execute a non-trivial dynamic
  workflow in a selected sandbox-backed workspace.
- The selected sandbox backend/runtime is visible before launch and represented
  in persisted session/workflow metadata.
- The UI shows enough progress for a user to understand the current phase,
  active node, child-agent/tool activity, pending approval, open repair task,
  and final state without reading raw event payloads.
- Side-effectful child-agent tool reviews can be approved by policy or by the
  operator, and nested child review gates resume correctly.
- Approve-all cannot cause unbounded objective-loop resume; budget and review
  pauses remain visible and manually recoverable.
- Empty-workspace creation tasks can produce real files in the selected
  workspace, and a no-op or malformed patch triggers a targeted repair before
  the outer objective loop burns iterations.
- The final answer/state is backed by artifacts, changed files, tests or smoke
  checks, and sandbox proof metadata.

## General Failure Taxonomy

Use this taxonomy while orienting. A new issue belongs here only if it can
repeat across arbitrary tasks.

| Category | Symptom | General Fix Shape |
| --- | --- | --- |
| Launch contract drift | Browser-selected policy/runtime is rejected or lost by CLI/runtime. | Normalize shared launch options once and persist launch failure events. |
| Sandbox ambiguity | User selected Vmsan/Docker/Sprites, but the run gives no proof of where work executed. | Add sandbox session/proof events and render them in Workbench. |
| Empty-workspace paralysis | Agent inspects an empty workspace and stops instead of creating requested artifacts. | Treat empty listing as valid inspection for creation tasks and enforce retry on no-op outputs. |
| Opaque child failure | Child stops, times out, or returns partial output, but the UI hides why. | Project child status, tool calls, review reason, repair attempt, and changed-file summary into the visible progress model. |
| Nested approval deadlock | A child tool review waits inside a dynamic workflow while the parent session appears running. | Propagate parent review deciders and persist or surface child review gates. |
| Approval runaway | Approve-all keeps resuming an objective that still needs budget/review. | Cap policy-driven resumes and leave a durable manual checkpoint. |
| Weak completion proof | Session says done without tests, changed files, artifacts, or sandbox proof. | Require objective scorecard evidence and render missing-proof tasks before completion. |
| Overfit workflow behavior | Core code names RayOps/OpsLogic/Repo QA as fallback behavior. | Replace use-case-specific generators/fallbacks with recipe capabilities and fixtures only in tests/evals. |

## Visual Progress Requirements

The Workbench should make these visible without forcing the user to inspect raw
events:

- launch configuration: agent, model/client, approval policy, mode,
  write-policy, workspace, sandbox backend, selected runtime, allowed runtimes;
- sandbox readiness: backend selected, backend accepted launch, session/proof
  id when available, workspace copy-in/copy-back status;
- workflow progress: proposal, compile, node started/completed, child budget,
  child-agent started, tool running/ok/error, review requested/approved;
- objective loop: current iteration, open tasks, completed tasks, latest error,
  pending review/budget request, auto-resume count, cap state;
- result proof: changed files, commands/checks attempted, artifacts, unresolved
  risks, and final blocked/completed reason.

## Slice Ledger

Work the next iterations in this order unless a browser observation exposes a
higher-priority blocker.

| Slice | Observe Input | Change Target | Validation Gate | Status |
| --- | --- | --- | --- | --- |
| 1. Sandbox proof projection | Vmsan runs persist selection but not execution proof. | Emit and render sandbox proof/session events for code-execution nodes. | Browser run shows selected backend plus execution/copy-back proof in the session UI. | smoke-validated |
| 2. Child no-op repair | Empty-workspace child can return no changes after attempting patch. | Add child-local no-op repair before outer objective-loop iteration repair. | Deterministic test where a patch child no-ops first, retries, and creates files. | browser-validated |
| 3. Malformed patch recovery | Child can emit invalid `apply_patch` input and burn an objective iteration. | Classify patch parse failures as repairable child failures with narrower retry prompts. | Focused test and browser run show invalid patch repaired inside child. | browser-validated |
| 4. Progress clarity | Useful child failure/review details are buried in payload text. | Promote child review/failure/changing-file summaries into `session_snapshot` and LiveView panels. | Browser snapshot shows clear active issue and next action without raw payload expansion. | browser-validated |
| 5. Workbench load performance | Small synthetic sessions can take minutes to open and emit browser/runtime noise. | Reduce eager session-page load/render work and clean up noisy probe routes/timeouts. | Browser navigation for a 16-event repair session returns promptly with no Bandit timeout or `.well-known` route errors. | browser-validated |
| 6. General eval matrix | RayOps alone cannot prove arbitrary-task reliability. | Add a small rotating eval set: empty app creation, existing app feature, research/report, refactor, denied tool review. | `mix runic_ai.rlm.robustness --matrix general_dynamic_workflow` records per-scenario pass/fail and artifacts. | browser-observed |
| 7. Browser-driven HITL eval capture | Browser matrix can launch/capture UI, but the denied-review lane failed before review-card interaction. | Make HITL review-card scenarios deterministic enough for the browser runner to observe approve/deny and final blocked/resumed state. | `--browser-ui-launch` captures DOM/console/network plus review-card decision evidence in a fresh session. | browser-validated |
| 8. Completion audit gate | Runs can look done while proof is weak. | Tighten objective scorecard/proof tasks before final success. | Browser run cannot complete without changed-file/check/artifact evidence appropriate to mode. | browser-observed |
| 9. Full matrix completion proof | The proof gate has only been reobserved against the denied-review control shape. | Run the browser matrix across creation, feature, research, refactor, and control shapes; repair weak or false-positive proof per shape. | `general_dynamic_workflow` browser evidence shows mode-appropriate completion proof for every passing row and explicit gaps for every failing row. | browser-observed |
| 10. Browser terminal wait and contract visibility | Approve-all lets write/refactor rows progress, but browser capture can stop while sessions are still running and objective contracts are missing from UI evidence. | Wait for terminal completion or explicit stable pending state; surface accepted objective contracts earlier in Workbench evidence. | Browser matrix rows end as completed/blocked or stable waiting states with visible contract and no premature final-output assertions. | browser-observed |
| 11. Workflow completion and repair convergence | Browser capture now records contracts, progress, and artifacts, but a write workflow can still remain running or fail behavioral-proof minimums after making files. | Improve objective-loop convergence, terminal-state transitions, and unmet-check reporting for incomplete workflow runs. | Empty-app and general write rows finish as completed with scorecard proof or blocked with actionable unmet checks, not indefinitely running at browser timeout. | browser-observed |
| 12. Deterministic acceptance feedback | Generated projects can satisfy internal generic scorecards while failing external deterministic objective checks, and terminal failures can be reported as UI capture gaps when final output is absent. | Feed deterministic/check-specific failures into the repair contract and classify terminal failed-with-evidence separately from browser capture failure. | Browser evidence distinguishes failed objective proof from capture failure, and repair prompts target exact failing checks such as module/API identity, tests, and smoke commands. | browser-validated |
| 13. Delivery-root grounding | A run can create a valid project under a scratch `tmp/` child while the selected workspace root still fails. | Add a generic delivery-root scorecard check that rejects accidental scratch-root implementation unless the objective or workflow explicitly targets that nested root. | Browser run creates and verifies deliverables at the selected workspace root, or fails with a root-mismatch repair need. | browser-validated |
| 14. Browser/devtools noise and scratch cleanup | Passing browser runs can still leave duplicate scratch project files and live-page console warnings unrelated to user-visible success. | Suppress or fix noisy integrated-lane `nil` handling, model-token warnings, Bandit timeout noise, and optional scratch duplicate cleanup/reporting. | DevTools current-page console has no actionable warnings/errors, and completion proof separates delivered files from scratch byproducts. | browser-validated |
| 15. Generated-project warning hygiene | The browser scenario passes, but generated Mix projects can emit Elixir-version deprecation warnings during `mix test`. | Feed warning-free verification expectations into generated-project repair prompts and/or deterministic checks without hardcoding a concrete app. | Browser run and manual `mix test` pass without warning output in the generated workspace. | next |

## Browser Integration Protocol

For every reobserve step:

1. Launch from the Workbench UI, not only the CLI.
2. Use a fresh workspace under `tmp/` unless the slice explicitly needs an
   existing project.
3. Select a sandbox backend/runtime intentionally and record both the visible
   UI value and persisted metadata.
4. Capture the session id and inspect `.runic_ai/runs.db` for terminal events,
   review requests, artifacts, and workflow status.
5. Use Chrome DevTools snapshot or screenshot to verify what the user can see.
6. Compare against the previous loop and update the slice ledger with the next
   blocker.

## Current Baseline

The latest known RayOps/Vmsan loop produced these general lessons:

- launch policy drift is fixed enough for `approve=always` sessions to start;
- empty-workspace instructions reach child agents;
- nested child review gates can be auto-approved by parent policy;
- browser approve-all is now capped for objective-loop auto-resume;
- actual files can be created in the selected workspace after recovery;
- remaining gaps are sandbox proof, child-local repair strength, and visible
  progress clarity.

## OODA Slice 1: Sandbox Proof Projection

Date: 2026-06-18

Observation:

- Prior browser RLM runs preserved selected sandbox metadata, but the Trace UI
  did not prove that a code-execution node actually ran inside the selected
  backend or copied changes back.
- The existing event stream already had `coding_sandbox_*` trace events with
  backend result metadata. The Workbench projection dropped session ids,
  backend proof ids, workspace mode, security-boundary, and copy-in/copy-back
  status.

Decision:

- Keep the backend contract general. Do not special-case Vmsan, RayOps, or a
  generated project.
- Normalize proof fields in `Workbench.session_snapshot/1` from existing
  sandbox trace event metadata and render them in the Workbench Trace panel.

Action:

- Added a normalized `proof` map to `snapshot.sandbox_executions`, including
  backend, sandbox, runtime, network, isolation level, security boundary,
  session/vm/container identifiers, workspace mode/mount, request file count,
  changed-file count, artifact count, and copy-in/copy-back status.
- Rendered proof labels in the Trace inspector, e.g. backend/runtime/session id
  plus `security boundary`, `copy-in ...`, `copy-back ...`, duration, and
  changed-file count.
- Added focused Workbench and LiveView tests for proof projection/rendering.

Validation:

- `mix test test/runic_ai/coding/tools_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed with 82 tests, 0 failures.
- Browser integration session:
  `web-session:OODA061SANDBOXPROOF`.
- Browser Trace panel showed:
  `vmsan / elixir / session vm-ooda061-proof` and
  `microvm - disabled - security boundary - copy-in request_files_uploaded -
  copy-back files_changed - 51ms - 1 changed`.
- SQLite evidence for the same session showed:
  `session_id=vm-ooda061-proof`, `backend=vmsan`,
  `isolation_level=microvm`, and changed file
  `lib/ooda061_probe.ex`.

Orientation:

- Slice 1 now proves that when a workflow/tool emits sandbox trace events,
  users can see sandbox proof without opening raw event payloads.
- This does not yet prove that every Workflow RLM child agent emits sandbox
  proof. The RayOps browser runs mostly used host patch/file tools, so they
  still need a policy/runtime decision about which side-effectful operations
  must go through sandbox code-execution events.
- Vmsan one-shot execution currently reports session/vm proof but does not
  inherently report copied-back filesystem deltas unless the backend result
  includes `files_changed` or artifacts. The UI now distinguishes
  `files_changed`, `artifacts_captured`, `no_changes_reported`, and
  `not_reported`, but the backend still needs stronger copy-back evidence for
  real Vmsan filesystem mutation flows.

## OODA Slice 2: Child No-Op Repair

Date: 2026-06-18

Observation:

- A patch-mode child can reply as if it inspected or considered the task but
  leave the workspace unchanged.
- The outer objective loop can then spend a broader repair iteration on a
  failure that belongs inside the child-agent contract: a mutating child either
  changed files, is waiting for review, or is blocked with a concrete reason.
- This is not RayOps-specific. Any empty project, generated app, report, or
  refactor task can hit the same no-op child failure.

Decision:

- Add a child-local repair attempt for patch-mode children only.
- Trigger it from observed workspace delta plus child summary, not from prompt
  keywords or named scenarios.
- Do not repair while a child review request is pending. Review is a control
  state, not a no-op failure.

Action:

- `RunicAI.Coding.RLM.WorkflowCompiler` now snapshots the child workspace
  before and after patch-mode child execution.
- When both the filesystem delta and child summary report no changed files, the
  compiler retries that child once with a narrower repair task requiring
  concrete file edits, a pending review, or a concrete blocking error.
- The retry emits `child_noop_repair_started` and
  `child_noop_repair_completed` node-stage events and merges observed changed
  files into the final child summary.
- `RunicAI.Coding.RLM.ChildResult` preserves
  `child_noop_repair_attempts` in metadata.
- Parent timeout classification treats the child no-op repair stages as active
  execution.

Validation:

- Focused regression:
  `mix test test/runic_ai/coding/rlm_agent_test.exs:1688` passed with 1 test,
  0 failures.
- Broader touched suite:
  `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed with 123 tests, 0 failures.
- Deterministic compiler/browser integration session:
  `web-session:OODA061NOOPREPAIR2`.
- The integration used the real `WorkflowCompiler` and standard child-agent
  tool path with a fake runtime LLM client. The first child response made no
  changes; the child-local repair prompt then called `apply_patch` and created
  `tmp/ooda061-noop-browser-2/lib/noop_repair.ex`.
- Browser Trace evidence showed:
  `child_noop_repair_started`, live `apply_patch` call/observation events,
  `child_noop_repair_completed` with
  `changed_files: ["lib/noop_repair.ex"]`, then
  `child_agent_completed` with `child_noop_repair_attempts: 1`.
- Console/network inspection showed no browser errors. The run did surface an
  environment warning from `mix run`: the host is over the inotify watch limit.

Orientation:

- Slice 2 closes the generic no-op child gap before the outer objective loop
  spends a full iteration. This should improve arbitrary creation/refactor
  workflows because it is based on actual workspace mutation evidence.
- The browser step was a persisted Workbench session generated from a
  deterministic compiler run, not a Workbench-composer launch. That tradeoff
  made the no-op path deterministic without a real model. A later eval slice
  still needs a true browser-launched workflow with a live or scripted model
  lane.
- The Trace view exposed the right raw events, but the user-facing main message
  was still too raw in this synthetic session because the summary detail was an
  inspected Elixir result. Real terminal-run summary projection should prefer a
  concise child/result view: changed files, checks, unresolved risks, and next
  action.
- Opening the small session in Chrome took roughly one minute even though the
  persisted event count was only 14. The page currently loads a large recent
  session sidebar and many inline icon data URLs; performance needs a separate
  UI/data-loading pass.

## OODA Slice 3: Malformed Patch Recovery

Date: 2026-06-18

Observation:

- `apply_patch` already returns structured `PatchResult` diagnostics for
  invalid operations, but the Workflow RLM child boundary previously treated a
  failed patch much like any other child output.
- In a general coding workflow, malformed patch input is a local child/tool
  failure. Spending a full outer objective-loop repair iteration for that shape
  wastes budget and hides the actionable issue from the user.
- This is not specific to one app scaffold. Any dynamic coding task can produce
  an invalid operation name, missing content field, wrong update shape, or
  otherwise valid JSON that fails the patch contract.

Decision:

- Add patch-failure-specific child repair before generic no-op repair.
- Trigger from standard child-agent patch summaries: failed patch status or
  non-empty diagnostics with no observed filesystem delta.
- Preserve no-op repair behavior and event names from Slice 2, but add
  reason-specific `child_patch_repair_started` and
  `child_patch_repair_completed` events.

Action:

- `RunicAI.Coding.RLM.WorkflowCompiler` now inspects failed child patch
  summaries before running the generic no-op repair check.
- Patch repair retries the same child with a narrower prompt that names the
  `apply_patch` schema and includes compact diagnostics from the failed patch.
- The final child summary carries `child_patch_repair_attempts`; the child
  result metadata preserves that value.
- Parent timeout classification now treats patch repair events as active child
  execution.

Validation:

- Focused regression:
  `mix test test/runic_ai/coding/rlm_agent_test.exs:1779` passed with 1 test,
  0 failures.
- Broader touched suite:
  `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed with 124 tests, 0 failures.
- `git diff --check` passed.
- Deterministic compiler/browser integration session:
  `web-session:OODA061PATCHREPAIR`.
- The integration used the real `WorkflowCompiler` and standard child-agent
  tool path with a fake runtime LLM client. The first child called
  `apply_patch` with invalid operation `op: "make_file"`; child patch repair
  retried with a valid create operation and produced
  `tmp/ooda061-patch-repair-browser/lib/malformed_patch_repair.ex`.
- Browser Trace evidence showed the failed patch diagnostics:
  `reason: :apply_patch_failed`, diagnostic `invalid_patch`, operation
  `make_file`, then `child_patch_repair_completed` with
  `changed_files: ["lib/malformed_patch_repair.ex"]`, and
  `child_agent_completed` with `child_patch_repair_attempts: 1`.

Orientation:

- Slice 3 closes the child-local malformed patch gap for structured patch
  failures that return diagnostics without changing the workspace.
- The Trace panel now contains the right information, but it is still displayed
  as raw payload text. A user should not need to parse Elixir inspect output to
  understand that the agent recovered from an invalid patch operation.
- Session navigation took more than two minutes in Chrome for a 16-event
  synthetic session, making progress visibility unreliable from a user
  perspective even when backend execution is fast.
- Console inspection also showed a Bandit transport timeout and repeated
  `.well-known/oauth-authorization-server` route errors. Those appear separate
  from the RLM repair logic, but they affect confidence in browser-launched
  runs and should be tracked as Workbench UX/runtime cleanup.
- `mix run` continued to emit the host inotify watch-limit warning. This is an
  environment issue, but it adds noise to deterministic integration evidence.

## OODA Slice 4: Progress Clarity

Date: 2026-06-18

Observation:

- Slice 3 emitted the right child patch repair events, but the Trace UI still
  required the user to read raw payload text to understand the failure and
  recovery.
- A generally useful coding agent needs repair state to be visible as product
  state: what failed, what retry ran, what changed, and what the user should do
  next.

Decision:

- Keep raw terminal events available, but derive a concise child-repair
  projection from persisted events in `Workbench.session_snapshot/1`.
- Render repair cards in the existing Trace panel instead of adding a
  scenario-specific result view.

Action:

- `Workbench.session_snapshot/1` now includes `child_repairs` plus a
  `metrics.child_repairs` count.
- The projection groups `child_noop_repair_*` and `child_patch_repair_*`
  events by type, node, and attempt, then exposes status, reason, diagnostics,
  changed files, and a next action.
- The Workbench LiveView Trace panel now renders a `Child repairs` section with
  status, mode/attempt metadata, changed-file facts, diagnostics, and next
  action while preserving raw event records below it.
- Added focused Workbench and LiveView tests for the snapshot projection and
  rendered repair card.

Validation:

- Focused tests:
  `mix test test/runic_ai/workbench_test.exs:182 test/runic_ai_web/workbench_live_test.exs:595`
  passed with 2 tests, 0 failures.
- Broader touched suite:
  `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed with 126 tests, 0 failures.
- `git diff --check` passed.
- Browser integration reobserve used session:
  `web-session:OODA061PATCHREPAIR`.
- Browser Trace evidence showed a visible `CHILD REPAIRS` card with status
  `REPAIRED`, title `Malformed patch repaired`, detail
  `Patch repair attempt 1 for child. Changed lib/malformed_patch_repair.ex.
  Diagnostic: invalid patch operation (invalid_patch) op=make_file.`, changed
  file `lib/malformed_patch_repair.ex`, diagnostic facts, mode `patch`, and
  next action `Continue downstream verification or final objective proof.`

Orientation:

- Slice 4 makes child-local repair progress understandable without expanding
  raw payloads, which helps arbitrary coding workflows that hit no-op or
  malformed-patch failures.
- The synthetic session's main summary still showed raw Elixir inspect output.
  Result summarization should eventually use the same structured proof fields
  instead of dumping internal terms.
- Browser navigation for the same small 16-event session took more than nine
  minutes during the reobserve step. That is now a higher-priority blocker
  than broader eval coverage because it prevents reliable user observation of
  otherwise-correct backend progress.
- Console inspection still showed a Bandit transport timeout and repeated
  `.well-known/oauth-authorization-server` route errors. Those are likely
  Workbench runtime/browser integration issues rather than RLM child-repair
  issues, but they materially hurt confidence in browser-launched workflows.

## OODA Slice 5: Workbench Load Performance

Date: 2026-06-18

Observation:

- Server-side projection was not the nine-minute bottleneck for
  `web-session:OODA061PATCHREPAIR`: `Workbench.recent_sessions(limit: 40)` was
  about 9 ms and `Workbench.session_snapshot/1` was about 12 ms in `mix run`.
- The browser route still carried avoidable weight. The initial HTML for the
  16-event repair session was about 173 KB, and unknown
  `.well-known/oauth-authorization-server` probes returned Phoenix debugger
  pages around 69 KB each while logging router exceptions.
- Chrome performance tracing before the fix showed normal sub-second LCP in a
  clean reload, so the prior nine-minute DevTools wait was not reproducible as
  a pure page-load trace. The route/probe noise was still concrete and harmful
  to integration confidence.

Decision:

- Bound and compact the Workbench recent-session sidebar on session pages. A
  user needs nearby navigation context, not full metadata for 40 sessions in
  the initial render path.
- Add explicit lightweight handlers for OAuth well-known probe paths so
  browser/MCP discovery traffic does not become debugger output or router
  exception noise.

Action:

- Added `Workbench.recent_session_summaries/1`, a compact projection for
  sidebar usage that omits full session metadata and capability payloads.
- Changed `WorkbenchLive` session loading to request 16 compact recent-session
  summaries instead of 40 full session views.
- Added explicit routes for
  `/.well-known/oauth-authorization-server` and nested paths such as
  `/.well-known/oauth-authorization-server/tidewave/mcp`.
- The new route returns a small JSON 404 explaining that the Workbench does
  not expose OAuth authorization metadata there.
- Added LiveView/controller tests for the bounded sidebar and lightweight
  well-known probe responses.

Validation:

- Focused tests:
  `mix test test/runic_ai_web/workbench_live_test.exs:56 test/runic_ai_web/workbench_live_test.exs:77`
  passed with 2 tests, 0 failures.
- Broader touched web/workbench suite:
  `mix test test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed with 58 tests, 0 failures.
- `git diff --check` passed.
- Warm `curl` checks against the live server showed:
  session HTML `200`, 127488 bytes, 0.669729 s; well-known probe `404`, 110
  bytes, 0.256112 s.
- Browser integration reobserve used session:
  `web-session:OODA061PATCHREPAIR`.
- Chrome performance trace after the fix showed LCP around 841 ms with TTFB
  around 668 ms and CLS 0.00.
- Browser console after reload showed only the LiveView mount and
  `restore_preferences` debug messages. The prior Bandit timeout and
  `.well-known` router errors did not reappear.

Orientation:

- Slice 5 removes the concrete route-probe noise and reduces eager session
  page payload, making the browser observation loop reliable enough to
  continue.
- The page is still not especially lean: the initial HTML is about 127 KB and
  TTFB remains the largest LCP component. A later UI pass should consider
  deferred sidebar loading, route-level compression, and reducing static shell
  markup.
- The next higher-value step is not more page tuning. The product risk is now
  whether the dynamic workflow agent behaves generally across different task
  shapes, so the next OODA loop should build and run the general eval matrix.

## OODA Slice 6: General Eval Matrix

Date: 2026-06-18

Observation:

- Previous robustness coverage had useful project-oriented scenarios, but it
  did not provide a named, reusable matrix for arbitrary dynamic-workflow task
  shapes.
- RayOps/OpsLogic/Repo QA examples are useful stress prompts, but they should
  not become backup behavior in core logic. The eval harness needs generic task
  shapes rather than named-app fallbacks.
- The Workbench page also crashed for an older in-memory snapshot because the
  Trace panel assumed newer `child_repairs` fields were always present.
- A denied-review browser session exposed stale session-agent projection:
  review decision events could overwrite a selected RLM session's visible agent
  as `assistant`, even while workflow details still said `rlm blocked`.

Decision:

- Reuse the robustness catalog and runner as the general eval surface instead
  of adding scenario-specific production behavior.
- Add a named `general_dynamic_workflow` matrix that spans creation,
  extension, research/reporting, refactor, and HITL denial control tasks.
- Preserve existing session agent attribution for passive events like review
  decisions, but still allow explicit route-decision events to change the
  stored session agent when RLM intentionally routes to the assistant path.

Action:

- Added `RunicAI.RLM.Robustness.scenario_matrix/1` and
  `mix runic_ai.rlm.robustness --matrix general_dynamic_workflow`.
- Added scenarios for `empty_app_creation`, `research_report`,
  `refactor_existing_module`, and `denied_tool_review`; marked
  `existing_app_feature` as part of the same general matrix.
- Added workspace factory seeds for empty workspaces, documentation-only
  report workspaces, and messy existing-module refactor workspaces.
- Added `task_shape` to matrix result rows and report output.
- Hardened Workbench Trace rendering for snapshots that predate
  `sandbox_executions` or `child_repairs`.
- Fixed review-decision attribution by recording decisions with the selected
  session agent and by preserving session agent projection except for explicit
  route events.

Validation:

- Focused tests passed:
  `mix test test/runic_ai/workbench_test.exs:1649 test/runic_ai/workbench_test.exs:1900 test/runic_ai_web/workbench_live_test.exs:600 test/runic_ai/rlm/robustness_test.exs:33 test/runic_ai/rlm/robustness_test.exs:158 test/runic_ai/rlm/robustness_test.exs:231 test/runic_ai/rlm/robustness_test.exs:375 test/runic_ai/rlm/robustness_test.exs:602`
  with 8 tests, 0 failures.
- Matrix run:
  `mix runic_ai.rlm.robustness --matrix general_dynamic_workflow --lane browser_tidewave --label ooda061-general-matrix-2`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-general-matrix-2.md`.
- Manual browser observation of session
  `browser-rlm-robustness:denied_tool_review:HJLH3J0BVG:2V:cf2b27d8`
  showed the review card, Deny button, and post-denial blocked state with
  `Review deny`, 8 persisted events, and no `DeniedSideEffect` file.
- Fresh browser-driven robustness run:
  `mix runic_ai.rlm.robustness --scenario denied_tool_review --lane browser_tidewave --label ooda061-denied-review-regression --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-denied-review-regression.md`.
- The fresh browser artifact captured DOM, screenshot, console, network, plan
  stages, and live progress. It had `selected_agent: "rlm"`,
  `console_error_count: 0`, and `network_failure_count: 0`.
- Backend projection for the fresh session
  `browser-rlm-robustness:denied_tool_review:HJLHDUDB6H:3:de89cdf6`
  showed `%{agent: "rlm", status: "failed", events: 14}`.

Orientation:

- Slice 6 now gives the project a general-purpose eval matrix instead of
  relying on a single named app prompt or a hardcoded fallback.
- The fresh browser-driven run proved the attribution fix for new sessions:
  RLM stays visible as RLM after launch/failure, while explicit routing tests
  still prove non-workspace RLM requests can route to assistant.
- The HITL denial eval is not yet reliable as an automated approve/deny
  regression. In the fresh `--browser-ui-launch` run, the RLM workflow failed
  during proposal generation with
  `validation: RLM coding coordinator could not produce an accepted workflow proposal`
  before it produced a review card. The runner correctly reported
  `browser/UI evidence capture is incomplete` because
  `review_decision form not found before timeout`.
- The older manually denied session remains useful evidence for the browser
  control path, but it was created before the attribution fix and therefore
  should not be used to judge current projection correctness.
- Most matrix rows are expected to fail deterministic checks when no live or
  scripted agent performs the actual work. The value of the matrix is the
  per-task-shape artifact/evidence contract; the next loop should make the
  browser-driven HITL lane deterministic enough to exercise review decisions
  end to end.

## OODA Slice 7: Browser-Driven HITL Eval Capture

Date: 2026-06-18

Observation:

- Slice 6 added the denied-review scenario, but a real
  `--browser-ui-launch` run submitted the objective through the already-running
  Phoenix server. The robustness task's fake review-producing `run_fun` lived
  in the Mix process, so the external server used the real RLM path and failed
  before creating a review card.
- After prelaunching the review session in the Mix process, Chrome found the
  review form, but the first implementation submitted before LiveView was
  connected. The browser console showed `Failed to push form submit Error: no
  connection`, while the capture helper incorrectly reported the decision as
  submitted.
- Once the submit path waited for a connected LiveView owner, the Deny action
  persisted. The objective loop then created a second pending review because
  the fixture modeled the denied control as an incomplete objective.

Decision:

- Keep this deterministic behavior in the robustness harness. Do not add
  production code paths named for RayOps, OpsLogic, or denied-tool review.
- Add an eval-only prelaunch path for scenarios that explicitly opt in with
  `browser_review_prelaunch?`.
- Treat a denied control review as the satisfied objective for that eval:
  the proof is that the browser review was denied and no unauthorized side
  effect occurred.
- Let review-card capture satisfy the active-context checks for review-gated
  moments, instead of requiring unrelated child-node labels while the user is
  looking at an approval card.

Action:

- The robustness browser lane now prelaunches opted-in review scenarios in the
  Mix process, then passes the existing session URL to the CDP runner.
- `priv/robustness/browser_ui_runner.js` can open an existing session URL,
  wait for a connected LiveView owner, retry review submission until the
  decision is actually pushed, and report `existing_session_opened?`.
- The denied-review scenario opts into prelaunch, caps browser objective
  iterations at 1, and declares `expected_lane_status: :blocked`.
- The browser probe fixture marks a requested denial with rejected/denied
  status as `objective_satisfied`, preventing a second pending review.
- The robustness judge/runner now respect expected lane statuses, and UI checks
  accept captured review-card decisions as valid active context and terminal
  evidence for this control path.

Validation:

- Focused tests passed:
  `mix test test/runic_ai/rlm/robustness_test.exs:33 test/runic_ai/rlm/robustness_test.exs:158 test/runic_ai/rlm/robustness_test.exs:231 test/runic_ai/rlm/robustness_test.exs:602 test/runic_ai/rlm/robustness_test.exs:900 test/runic_ai/rlm/robustness_test.exs:1035`
  with 6 tests, 0 failures.
- Browser integration command:
  `mix runic_ai.rlm.robustness --scenario denied_tool_review --lane browser_tidewave --label ooda061-hitl-deny-pass --browser-ui-launch --browser-ui-capture`.
- The matrix report
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-hitl-deny-pass.md`
  passed: status `pass`, deterministic `pass`, judge `pass`, main gap `none`.
- The browser evidence
  `tmp/rlm_robustness/workspaces/ooda061-hitl-deny-pass/denied_tool_review/browser_tidewave/tmp/browser-evidence-denied_tool_review.json`
  recorded `review_decision_captured? == true`,
  `console_error_count == 0`, `network_failure_count == 0`,
  `review_statuses == ["denied"]`, and final output containing
  `Review decision evidence: :rejected`.
- The browser console showed LiveView handling `review_decision` with
  `action => "deny"` and no errors.
- The workspace contained the seeded app files and browser evidence artifacts;
  deterministic checks confirmed `DeniedSideEffect` was absent and changed-file
  count was 0 outside ignored runtime artifacts.

Orientation:

- Slice 7 closes the immediate HITL eval harness gap. The browser runner can
  now exercise a rendered review card, submit a denial, and include the result
  in the same matrix artifact.
- There is still a semantic UX question: the final session status for the
  passing eval is `completed`, because the control objective was "deny the
  side effect and prove it was respected." The review row itself is `denied`
  and the output reports rejection. If product semantics require the overall
  session to remain `blocked` after any denial, that should be a separate
  objective-loop policy change, not a harness workaround.
- The matrix note still says `--browser-ui-launch` launches through the
  composer. That remains true for normal browser scenarios, but prelaunched
  review scenarios open an existing session so the external browser can drive
  the review card produced by the Mix-process fixture.

## OODA Slice 8: Completion Audit Gate

Date: 2026-06-18

Observation:

- Prior slices could tell whether a browser run passed the eval harness, but
  the Workbench projection did not expose one normalized completion-proof
  object for users, UI checks, or future runners.
- A generally useful coding agent should not look complete merely because it
  emitted a final message. The proof should say whether completion is backed
  by scorecard status, objective contract, changed files, artifacts, sandbox
  executions, or explicit review-control evidence.
- The first implementation of this projection overcounted evidence: it treated
  arbitrary nested `path` strings from browser/UI payloads as changed files and
  artifacts. In a denied-review control session that produced no files, the
  stale evidence incorrectly reported 169 changed files and 169 artifacts.

Decision:

- Add a generic `completion_proof` projection to
  `Workbench.session_snapshot/1`. Keep it independent of RayOps, OpsLogic,
  Repo QA, or any other named scenario.
- Let the robustness runner interpret that projection by generic task shape:
  creation/feature/refactor work requires changed files plus scorecard or
  sandbox proof; research requires an artifact or changed file; denied-review
  control work requires review denial plus final output.
- Fix evidence extraction so only explicit completion keys such as
  `changed_files`, `changed_paths`, `artifact_paths`, and `artifacts` count.
  Plain nested `path` fields are not completion evidence unless they are part
  of a typed artifact object.

Action:

- `Workbench.session_snapshot/1` now returns `completion_proof` with status,
  readiness, missing proof reasons, proof categories, final-output presence,
  scorecard/objective-contract flags, changed files, artifact paths, sandbox
  execution count, and review decision statuses.
- The browser robustness evidence now includes the session
  `completion_proof`, the scenario `task_shape`, and a
  `completion_proof_visible` UI check.
- Added focused tests for completed scorecard-backed sessions, denied-review
  sessions with noisy nested browser paths, and the denied-review browser UI
  check.

Validation:

- Focused tests passed:
  `mix test test/runic_ai/workbench_test.exs:176 test/runic_ai/workbench_test.exs:240 test/runic_ai/rlm/robustness_test.exs:1035`
  with 3 tests, 0 failures.
- `git diff --check` passed.
- Browser integration command:
  `mix runic_ai.rlm.robustness --scenario denied_tool_review --lane browser_tidewave --label ooda061-completion-proof-deny-fixed --browser-ui-launch --browser-ui-capture`.
- The matrix report
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-completion-proof-deny-fixed.md`
  passed: status `pass`, deterministic `pass`, judge `pass`, main gap `none`.
- Fresh browser evidence session:
  `browser-rlm-robustness:denied_tool_review:HJLI34F1TW:3:38e1fcd1`.
- Browser evidence file:
  `tmp/rlm_robustness/workspaces/ooda061-completion-proof-deny-fixed/denied_tool_review/browser_tidewave/tmp/browser-evidence-denied_tool_review.json`.
- The corrected completion proof recorded
  `ready? == true`, `missing == []`, `proof_categories ==
  ["final_output", "review_decision"]`, `denied_review? == true`,
  `final_output? == true`, `changed_file_count == 0`, and
  `artifact_count == 0`.
- The same evidence recorded `review_decision_captured? == true`,
  `console_error_count == 0`, and `network_failure_count == 0`.
- Chrome DevTools MCP was available for page/console/snapshot inspection, but
  the exposed MCP surface in this run listed only existing pages and did not
  provide navigation. The fresh browser observation therefore came from the
  robustness CDP runner, while MCP confirmed the currently selected Chrome tab
  was an older denied-review Workbench page.

Orientation:

- Slice 8 gives users and evaluators a single product-level completion proof
  instead of scattered event payloads, and it prevents browser/UI path noise
  from masquerading as deliverables.
- The reobserve step proves the control-task shape: a denied side effect can
  complete only with explicit final output plus denied-review evidence, and
  without falsely claiming changed files or artifacts.
- This does not yet prove the write/research/refactor task shapes in a fresh
  browser-launched matrix. The next loop should run
  `general_dynamic_workflow` with browser capture and repair any task shape
  where completion proof is too weak, too strict, or missing from the user's
  visible final state.

## OODA Slice 9: Full Matrix Completion Proof

Date: 2026-06-18

Observation:

- The first full browser matrix with the Slice 8 proof gate showed a
  false-positive proof state for active sessions: running rows had
  `ready? == true` and `completion_proof_visible` reported pass even though
  no final output, changed files, artifacts, sandbox proof, or scorecard were
  present.
- The same run showed creation and feature rows stuck with pending
  `rlm_node_execution` reviews under the default browser `safe` policy. The
  Workbench already has an `approve all` policy action that persists
  `runtime_approval == "always"` and approves pending non-budget reviews, but
  the robustness browser harness was not using that mode for normal
  completion-oriented matrix rows.
- After the approve-all harness change, the existing-app and refactor rows
  moved past review gates and showed approved reviews plus changed-file proof,
  but the browser capture still stopped while those sessions were `running`.
  The empty-app and research rows failed proposal generation before producing
  objective contracts or final proof.
- The denied-review control row briefly failed after the full approve-all run
  because completion proof only treated assistant messages as final output.
  The durable final summary event already carried the output evidence.

Decision:

- Make `completion_proof.ready?` mean actual completed, evidence-backed
  readiness. Active sessions should be pending, and terminal non-completed
  sessions should remain blocked/failed instead of being called complete.
- Keep approval behavior general: use the existing session approval policy and
  approve-all semantics for browser eval rows that are intended to test task
  completion, while preserving explicit denial for the denied-review control
  row.
- Treat final summary event payloads as valid final-output evidence in the
  Workbench completion projection, because they are durable session records and
  may exist even when no assistant chat message was written.

Action:

- `Workbench.session_snapshot/1` completion proof now includes `terminal?` and
  `blocked?`; `ready?` is false until the session is completed and has
  completion evidence.
- Completion proof now folds embedded scorecards and objective contracts from
  final/progress terminal events, not only persisted scorecard rows.
- Completion proof now recognizes final summary payloads such as
  `output_text`, `reply_text`, and `final_output` as final-output evidence.
- The robustness browser completion check now reports active sessions as
  `Session still running; completion proof pending`, terminal non-completed
  sessions as not requiring completion proof, and completed sessions without
  mode-appropriate proof as failures.
- The general dynamic workflow browser matrix now sets
  `browser_approval: :always` for non-denial completion rows, and the runner
  accepts `always`/`all` approval values. The denied-review row remains an
  explicit ask-and-deny control case.

Validation:

- Focused tests passed:
  `mix test test/runic_ai/rlm/robustness_test.exs:164 test/runic_ai/workbench_test.exs:182 test/runic_ai/workbench_test.exs:239 test/runic_ai/workbench_test.exs:293 test/runic_ai/rlm/robustness_test.exs:1035`
  with 5 tests, 0 failures.
- `git diff --check` passed.
- Browser matrix command:
  `mix runic_ai.rlm.robustness --matrix general_dynamic_workflow --lane browser_tidewave --label ooda061-full-matrix-approve-all --browser-ui-launch --browser-ui-capture`.
- The matrix report
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-full-matrix-approve-all.md`
  still failed all rows except deterministic denial, but the row evidence was
  more informative:
  `empty_app_creation` launched with `approve == "always"` and failed before
  completion; `existing_app_feature` launched with `approve == "always"`,
  had `review_statuses == ["approved"]`, `changed_file_count == 7`,
  `final_output? == true`, and remained `running`; `refactor_existing_module`
  launched with `approve == "always"`, had `review_statuses == ["approved"]`,
  `changed_file_count == 3`, `final_output? == true`, and remained
  `running`; `research_report` launched with `approve == "always"` and failed
  before completion; `denied_tool_review` remained an explicit ask-and-deny
  row.
- Denied-control proof rerun:
  `mix runic_ai.rlm.robustness --scenario denied_tool_review --lane browser_tidewave --label ooda061-deny-final-output-proof --browser-ui-launch --browser-ui-capture`.
- The denied-control rerun report
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-deny-final-output-proof.md`
  passed with status `pass`, deterministic `pass`, judge `pass`, and main gap
  `none`.
- The denied-control evidence recorded `terminal? == true`,
  `completed? == true`, `ready? == true`, `missing == []`,
  `proof_categories == ["final_output", "scorecard", "review_decision"]`,
  `denied_review? == true`, `final_output? == true`,
  `changed_file_count == 0`, `artifact_count == 0`, and no browser console or
  network failures.

Orientation:

- Slice 9 separates three generic states that the previous gate conflated:
  active/pending, failed or blocked, and completed with proof.
- Approve-all works as a persisted Workbench policy and now works as an eval
  harness setting for normal completion rows. That addresses the review-pause
  shape without weakening the denied-review control test.
- The next blocker is not completion proof itself. It is the browser runner and
  workflow contract path: write/refactor rows can make changes but are captured
  before terminal completion, while empty/research rows fail proposal
  generation and never expose a structured objective contract. The next loop
  should make browser capture wait for terminal completion or a stable pending
  state, and make accepted objective contracts visible early enough for users
  and evals to understand what the agent is trying to prove.

## OODA Slice 10: Browser Terminal Wait And Contract Visibility

Observation:

- The browser matrix could now launch approve-all rows, but capture still
  stopped before the backend reached a terminal or stable pending state.
- Workbench only exposed objective contracts after later progress or scorecard
  events, so proposal-generation failures produced no visible contract for the
  user or eval harness to inspect.
- After the browser runner waited longer, the Node/CDP process timeout became
  the next capture failure: several rows were killed before DOM, screenshot,
  console, and network artifacts were written.

Decision:

- Emit a deterministic best-effort objective contract at `proposal_started`
  rather than waiting for a later child or scorecard event.
- Project objective contracts from nested RLM stage payloads in Workbench
  snapshots so early proposal state is user-visible.
- Make the browser runner wait for active progress evidence and a terminal,
  review, or stable pending checkpoint, and size the Elixir process timeout to
  include those waits.
- Treat terminal-wait plan evidence as valid active-progress evidence when the
  final capture occurs after the active-plan panel has moved.

Action:

- Updated `RunicAI.Coding.RLM.Agent` to attach an inferred objective contract
  to `proposal_started` events.
- Removed concrete scenario inference from `ObjectiveContract` and kept generic
  behavior/evidence requirements for non-mutating tasks.
- Updated `RunicAI.Workbench` to project nested stage objective contracts.
- Updated `RunicAI.RLM.Robustness.Runner` and
  `priv/robustness/browser_ui_runner.js` so browser captures wait for active
  progress and terminal or stable pending state before collecting final UI
  evidence.
- Added focused regression coverage for early contract emission, Workbench
  projection, and browser terminal-wait evidence.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs:882 test/runic_ai/coding/rlm_agent_test.exs:1262 test/runic_ai/workbench_test.exs:112`
  passed with 3 tests and 0 failures.
- `mix test test/runic_ai/coding/rlm_agent_test.exs:1262 test/runic_ai/workbench_test.exs:62 test/runic_ai/workbench_test.exs:112 test/runic_ai/workbench_test.exs:182 test/runic_ai/workbench_test.exs:239 test/runic_ai/workbench_test.exs:293 test/runic_ai/rlm/robustness_test.exs:164 test/runic_ai/rlm/robustness_test.exs:882 test/runic_ai/rlm/robustness_test.exs:1035`
  passed with 8 selected tests and 0 failures.
- `mix runic_ai.rlm.robustness --matrix general_dynamic_workflow --lane browser_tidewave --label ooda061-terminal-wait-contract --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-terminal-wait-contract.md`.
  The denied-review control passed, and non-denied rows now exposed objective
  contracts, including rows that failed during proposal generation.
- `mix runic_ai.rlm.robustness --matrix general_dynamic_workflow --lane browser_tidewave --label ooda061-active-final-capture --browser-ui-launch --browser-ui-capture`
  exposed the browser process-timeout regression: longer terminal waits worked
  conceptually but several captures were killed before final artifacts were
  collected.
- After resizing the process timeout and adding terminal-wait plan-evidence
  fallback, `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-empty-progress-fallback --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-empty-progress-fallback.md`.
  The browser evidence had objective contract visibility, changed files, DOM
  screenshot/console/network artifacts, no console or network failures, active
  context/child/remaining evidence, and no UI fail ids. The remaining failure
  was the real workflow-quality gap: `behavioral test minimum was not met`.

Orientation:

- Slice 10 moves the primary failure out of browser capture and projection.
  The user can now see the contract and progress evidence, and the eval harness
  can distinguish UI capture gaps from task-quality gaps.
- The next blocker is convergence: write workflows can make files and produce
  final output while still failing the behavioral proof minimum or remaining
  non-terminal at capture time. The next loop should make incomplete objective
  runs either repair toward the unmet checks or finish blocked with specific
  actionable evidence.

## OODA Slice 11: Workflow Completion And Repair Convergence

Observation:

- `ooda061-empty-progress-fallback` showed a completed browser capture with
  no UI fail ids, but the generated project lived under `tmp/browser_tidewave`
  and failed the root-level deterministic contract.
- Persisted events showed repeated objective-loop review approvals despite the
  browser launch using approve-all. Repair children were still hitting
  review-gated `apply_patch` requests, exhausting auto-resume attempts instead
  of repairing.
- After approval propagation fixes, the project moved to the workspace root and
  the Workbench session reached terminal states, but deterministic checks still
  exposed objective-quality gaps around public module identity, tests, and
  runtime smoke behavior.

Decision:

- Treat approve-all as an active runtime policy for repair children: if the
  parent launch or resumed session policy is `always`, child repair runs should
  not create another local patch review gate.
- Persisted mid-session approval policy must carry into objective-loop resumes,
  not only approve the currently pending card.
- Make new-project prompts preserve the full objective identity for generated
  app/module/test/smoke names instead of deriving names from the lane,
  workspace basename, or a shortened domain phrase.
- Increase the default repair budget from two to four iterations. Two attempts
  were enough to add files, but not enough for generated projects that need
  compile, facade/API, test, and runtime-smoke repair.

Action:

- Updated `RunicAI.Coding.RLM.RepairLoop` so repair child options inherit
  approval/review-gate settings and disable repair-child review gates when the
  active approval policy is approve-all.
- Updated `RunicAI.Workbench` objective resume options to include the current
  session approval policy and a policy-aware review decider.
- Added generic project-identity and runtime-smoke instructions to
  `RunicAI.Coding.RLM.Coordinator`, `RecipeLibrary`, and repair prompts.
- Raised `RepairLoop` default repair iterations from 2 to 4.
- Added focused tests for approve-all repair-child behavior, mid-session
  approval-policy resume propagation, and coordinator task enrichment.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs:221 test/runic_ai/coding/rlm_agent_test.exs:2055 test/runic_ai/workbench_test.exs:1174 test/runic_ai/workbench_test.exs:2084`
  passed with 4 tests and 0 failures.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice11-approve-all-repair --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice11-approve-all-repair.md`.
  The run created a root Mix project and completed in Workbench with terminal
  proof; deterministic checks improved from 1/10 to 4/10, but the generated
  API was still named too generically (`TicketTriage` instead of the
  objective-implied public identity).
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice11-identity-smoke --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice11-identity-smoke.md`.
  Deterministic checks improved to 7/10 and generated
  `lib/support_ticket_triage.ex`, but the run ended failed after repair-loop
  exhaustion. Browser DOM, screenshot, console, and network artifacts were
  captured with zero console and network failures.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice11-repair-budget --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice11-repair-budget.md`.
  The larger budget allowed a longer attempt, but the live model took a weaker
  path and still ended failed. The browser UI failure was only
  `final_output_visible`, while DOM/screenshot/console/network capture passed.
- Manual verification inside
  `tmp/rlm_robustness/workspaces/ooda061-slice11-identity-smoke/empty_app_creation/browser_tidewave`
  showed `mix compile --warnings-as-errors` passed, `mix test` failed due
  concrete generated behavior/API mismatch, and the scenario smoke failed when
  the expected public API was absent or inconsistent.

Orientation:

- Slice 11 fixed the approve-all repair-loop churn and improved root-workspace
  generation, but it did not make arbitrary generated projects reliably pass.
- The next blocker is acceptance feedback fidelity. The agent needs exact
  failing deterministic checks and command output as repair-contract inputs,
  and the browser matrix should classify terminal failed-with-evidence as an
  objective failure rather than a browser capture failure when UI artifacts are
  present.

## OODA Slice 12: Deterministic Acceptance Feedback

Observation:

- Slice 11 browser runs could fail root-level deterministic checks after the
  internal RLM workflow believed the objective was complete or exhausted.
- Browser captures also reported `final_output_visible` as a UI gap for terminal
  failed sessions even when DOM, screenshot, console, network, and blocked
  evidence were captured.
- `ooda061-slice12-acceptance-feedback` improved the empty-app scenario to
  9/10, generated the correct root `support_ticket_triage` project, and passed
  manual `mix compile --warnings-as-errors`, `mix test`, and runtime-smoke
  checks. The only remaining deterministic miss was the exact root facade
  `priority` source check.
- `ooda061-slice12-main-gap` then showed a worse stochastic path: the generated
  project landed under `workspace/tmp`, and the report correctly named
  `deterministic file_exists failed: mix.exs: file missing` as the main gap
  instead of hiding it as a browser capture failure.

Decision:

- Append deterministic scenario acceptance checks to the launched objective for
  both CLI and browser lanes, so the agent sees the same contract the evaluator
  will enforce.
- Persist deterministic failure summaries into matrix evidence and prefer those
  summaries in the report `Main gap`.
- Treat terminal failed-with-blocked-evidence plus captured DOM/screenshot/
  console/network artifacts as objective failure evidence, not incomplete UI
  capture.

Action:

- Updated `RunicAI.RLM.Robustness.Runner` to derive acceptance-check lines from
  scenario checks and include them in the objective submitted through the
  Workbench browser path.
- Added deterministic failure summaries to matrix evidence and report-gap
  selection.
- Updated final-output UI checking so a failed terminal state with blocked
  evidence and browser artifacts passes the capture check.
- Added focused robustness tests for browser objective injection and
  deterministic failure evidence.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs:717 test/runic_ai/rlm/robustness_test.exs:894`
  passed with 2 tests and 0 failures.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice12-acceptance-feedback --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice12-acceptance-feedback.md`.
  It reached 9/10 deterministic checks with zero browser UI gaps and zero
  console/network failures.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice12-main-gap --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice12-main-gap.md`.
  It failed 1/10 because files were under `workspace/tmp`, and the report main
  gap was the exact missing root `mix.exs`.

Orientation:

- Slice 12 made failure evidence much more actionable. The user and evaluator
  can now see the specific failing deterministic target instead of an opaque
  `lane execution failed` or UI-capture complaint.
- The next blocker was not another prompt wording issue. It was a delivery-root
  contract gap: generic progress scoring could treat nested `tmp/` source as
  meaningful implementation even when the selected workspace root was the
  requested deliverable.

## OODA Slice 13: Delivery-Root Grounding

Observation:

- `ooda061-slice12-main-gap` produced a valid-looking support-ticket project
  under `workspace/tmp`, while the evaluator correctly failed root-level
  `mix.exs`, source, tests, and command checks.
- This is a general coding-agent reliability issue: a child can solve the task
  in a scratch child directory while the parent workspace remains incomplete.
- Existing progress evidence scanned nested `*/lib` and `*/test` paths, which
  is useful for explicitly requested nested projects but too permissive for
  accidental scratch delivery.

Decision:

- Enforce a generic selected-workspace delivery-root check in the RLM progress
  gate.
- Keep nested delivery valid only when the objective or proposal explicitly
  names the nested root, for example `./tmp/support_ticket_triage` or a node
  `workspace_path`.
- Feed accidental scratch-root delivery into the same acceptance/repair path as
  any other objective gap.

Action:

- Updated `RunicAI.Coding.RLM.ProgressGate` with
  `progress-delivery-root`, which fails when changed source/test files are only
  under scratch prefixes such as `tmp/` and no explicit nested delivery root is
  present.
- Added policy escape hatch `allow_scratch_delivery_root?` for evals or
  workflows that intentionally treat scratch output as the deliverable.
- Added focused reliability tests for accidental `tmp/lib` delivery and
  explicitly requested `./tmp/<project>` delivery.

Validation:

- `mix test test/runic_ai/coding/rlm_reliability_test.exs:696 test/runic_ai/coding/rlm_reliability_test.exs:754`
  passed with 2 tests and 0 failures.
- `mix test test/runic_ai/coding/rlm_reliability_test.exs` passed with 35 tests
  and 0 failures.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice13-delivery-root --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice13-delivery-root.md`.
  The row passed: 10/10 deterministic checks, judge pass, zero UI gaps, and no
  deterministic failures.
- Manual verification in
  `tmp/rlm_robustness/workspaces/ooda061-slice13-delivery-root/empty_app_creation/browser_tidewave`
  passed:
  `mix compile --warnings-as-errors`, `mix test` with 5 tests and 0 failures,
  and the runtime smoke printed `empty_app_creation_smoke_pass`.
- Chrome DevTools was attached to
  `http://localhost:4000/sessions/browser-rlm-robustness%3Aempty_app_creation%3AHJLJWCASTF%3A3%3A45224266`.
  The full-page screenshot was saved to
  `tmp/rlm_robustness/reports/ooda061-slice13-chrome-devtools-session.png`,
  and network requests returned 200s.

Remaining issues observed:

- The completed workspace still contained a duplicate scratch copy under
  `tmp/support_ticket_triage/` in addition to the correct root project. This
  did not affect deterministic success, but it is noisy completion evidence and
  should be separated from delivered files or cleaned up.
- Browser UI evidence still reports active progress current-context and child
  booleans as false in the final capture. The run passed because terminal proof
  was complete, but the live progress affordance remains weaker than desired.
- Direct Chrome DevTools current-page console showed repeated warnings:
  `Runnable failed for node ... :process_integrated_lane ... %BadMapError{term: nil}`,
  repeated `Renamed :max_tokens to :max_completion_tokens for reasoning models`,
  and one Bandit transport timeout. The headless robustness capture counted
  zero console errors, so this is a devtools/live-page noise and backend
  robustness issue rather than a blocking scenario failure.

Orientation:

- The selected workspace can now be treated as the delivery root for arbitrary
  coding tasks unless the user or workflow explicitly targets a nested root.
- The next loop should reduce browser/devtools noise and completion-proof noise:
  fix or suppress the integrated-lane nil warning, avoid repeated model-option
  warnings, make Bandit timeouts non-alarming where expected, and distinguish
  scratch byproducts from delivered files in the final proof.

## OODA Slice 14: Browser/DevTools Noise And Proof Cleanup

Observation:

- Slice 13 achieved the functional target for the empty-app scenario, but the
  current browser page still showed noisy warnings in DevTools:
  `process_integrated_lane` received a nil production and raised
  `%BadMapError{term: nil}`, OpenAI reasoning-model options repeatedly renamed
  `:max_tokens`, and one Bandit transport timeout appeared in the console.
- The completion proof mixed delivered files with scratch byproducts, and in
  one run included `[depth limit]` as if it were a changed file.
- Browser active-progress booleans were still false even though the visible
  plan text contained node and child-agent progress evidence.

Decision:

- Treat non-ready integrated-lane productions as no-op emissions instead of
  invoking the lane processor.
- Prefer `:max_completion_tokens` for Assistant RLM default workflow response
  limits while preserving explicit caller limits such as `:max_output_tokens`.
- Separate delivered changed files from scratch changed files in Workbench
  completion proof, and reject serializer sentinel strings from path lists.
- Broaden the browser runner's active-progress detection and allow final plan
  evidence to satisfy active context/child visibility when pre-final sampling
  misses it.

Action:

- Updated `RunicAI.Recipes.IntegratedAgentKernel` to ignore non-ready lane
  values instead of calling the processor with nil.
- Updated `RunicAI.Assistant.RLM.Agent` default execution token limit from
  `:max_tokens` to `:max_completion_tokens`.
- Updated `RunicAI.Workbench` completion proof with
  `delivered_changed_files`, `scratch_changed_files`, and `all_changed_files`,
  while keeping `changed_files` as the delivered list for compatibility.
- Updated `priv/robustness/browser_ui_runner.js` active-progress detection for
  current-node and child-agent labels.
- Added focused tests for integrated-kernel non-ready behavior, Assistant RLM
  token opts, and Workbench completion-proof scratch/sentinel cleanup.

Validation:

- `mix test test/runic_ai/recipes/integrated_chat_agent_test.exs test/runic_ai/workbench_test.exs:230 test/runic_ai/assistant/rlm_agent_test.exs:300 test/runic_ai/assistant/rlm_agent_test.exs:610 test/runic_ai/coding/rlm_reliability_test.exs`
  passed with 41 selected tests and 0 failures.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice14-proof-clean --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice14-proof-clean.md`.
  The row passed: 10/10 deterministic checks, judge pass, zero UI gaps, and no
  deterministic failures.
- The resulting completion proof reported 7 delivered changed files,
  0 scratch changed files, no `[depth limit]` sentinel, `ready? true`,
  `scorecard_satisfied? true`, and proof categories
  `final_output`, `scorecard`, `objective_contract`, and `changed_files`.
- Browser capture for the same run reported active progress context and child
  visibility as true, with zero console errors and zero network failures.
- Chrome DevTools opened the exact current session
  `http://localhost:4000/sessions/browser-rlm-robustness%3Aempty_app_creation%3AHJLKQBW99K%3A3%3Ad3a9f3c7`.
  Current-page console had no warnings/errors/issues, network requests had no
  failures, and the full-page screenshot was saved to
  `tmp/rlm_robustness/reports/ooda061-slice14-proof-clean-devtools.png`.
- Manual root workspace verification in
  `tmp/rlm_robustness/workspaces/ooda061-slice14-proof-clean/empty_app_creation/browser_tidewave`
  passed `mix compile --warnings-as-errors`, `mix test` with 4 tests and
  0 failures, and the runtime smoke printed `empty_app_creation_smoke_pass`.

Remaining issues observed:

- `mix test` in the generated project emitted Elixir 1.19 deprecation warnings
  for setting `elixirc_options: [warnings_as_errors: true]` in `mix.exs`.
  The commands passed, but a general-purpose coding agent should avoid
  producing warning-noisy projects.
- The browser UI capture still records `capture_session_url` as the base URL in
  one normalized field even though the evidence has the correct session URL and
  DevTools opened the correct session. This is probe-normalization noise rather
  than a user-visible Workbench failure.
- `terminal_wait_observed?` remains false in the browser capture even when
  persisted completion proof is terminal. The UI checks pass, but terminal-wait
  evidence should be normalized against persisted terminal proof in a future
  cleanup.

Orientation:

- Slice 14 removed the main DevTools noise and made completion proof easier to
  trust for root-delivered coding tasks.
- The next blocker is generated-project quality rather than workflow
  orchestration: the agent can satisfy the scenario while leaving warning-noisy
  Mix configuration behind. The next loop should make warning-free generated
  projects part of the generic coding-agent verification contract without
  hardcoding support-ticket-specific behavior.

## Next Action

Slice 15 is complete. Continue with Slice 16 only if a new integration run shows
another reliability gap that blocks a generally useful dynamic coding workflow.

## Slice 15: Warning-Clean Command Evidence And Current-Result Scorecards

Observation:

- The Slice 14 browser run passed deterministic checks, but manual generated
  project verification showed `mix test` warning output from generated Mix
  configuration. A general coding workflow should not call warning-noisy command
  output success just because the exit code is zero.
- The first Slice 15 browser run proved the new warning-clean deterministic
  check worked: the generated project eventually had warning-free `mix test`
  output and deterministic checks passed 11/11. However, Workbench still marked
  the session failed because the internal RLM scorecard kept stale warning output
  from an earlier repair attempt.
- Report evidence also dropped final output for browser-launched sessions even
  when Workbench visible state showed the final output and completion proof.

Orientation:

- Robustness deterministic checks needed a reusable command-quality check, not a
  support-ticket-specific rule.
- Internal acceptance checks should keep command history for audit, but
  scorecard satisfaction must evaluate the latest observation per command
  signature. Otherwise a repaired command can never clear old warning/test-count
  failures.
- Browser report evidence should preserve the visible final output when the
  direct pre-capture snapshot does not include the final assistant message.

Action:

- Added generic deterministic check type
  `:command_passes_without_warnings`, with bounded output evidence and
  `warning_count`.
- Exposed that check in scenario acceptance text as
  `command passes without warning output: ...`, and added it to
  `empty_app_creation` for `mix test`.
- Included `:command_passes_without_warnings` in command-failure judging.
- Changed RLM verification assertions so `test_count_min` and
  `warning_count_zero` parse only the latest command observation per argv/cwd
  signature.
- Added browser-runner final-output fallback from
  `browser_evidence.visible_state.final_output_preview`.

Validation:

- `mix test test/runic_ai/coding/rlm_reliability_test.exs:363 test/runic_ai/coding/rlm_reliability_test.exs:403 test/runic_ai/rlm/robustness_test.exs:93 test/runic_ai/rlm/robustness_test.exs:760`
  passed with 4 selected tests and 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs:760 test/runic_ai/rlm/robustness_test.exs:975 test/runic_ai/coding/rlm_reliability_test.exs:403`
  passed with 3 selected tests and 0 failures.
- `mix compile --warnings-as-errors` passed.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice15-final-output-evidence --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice15-final-output-evidence.md`.
  The row passed: deterministic pass, judge pass, 11 passed checks, 0 failed
  checks, zero UI gaps, and no main gap.
- The final report JSON now includes
  `final_output: "empty_app_creation_smoke_pass"`.
- Latest browser evidence reports session status `completed`, completion proof
  `ready? true`, `completed? true`, `scorecard_satisfied? true`,
  `final_output? true`, 4 delivered changed files, 0 scratch changed files,
  zero console errors, zero network failures, UI launch captured, workflow plan
  visible, and active progress child visible.
- The generated project source/test/mix files for the final run contain no
  `warning:` text, and deterministic warning-free `mix test` reported
  `warning_count: 0`.

Chrome DevTools note:

- The Chrome DevTools MCP initially remained selected on an older run, which
  correctly showed old Slice 14 console warnings/errors and was not valid
  evidence for Slice 15.
- Opening the latest session with `google-chrome --new-tab` created a new
  DevTools target that stayed on `about:blank`; this MCP surface did not expose
  a navigation command. The authoritative latest-session browser evidence is
  therefore the browser runner capture for
  `http://localhost:4000/sessions/browser-rlm-robustness%3Aempty_app_creation%3AHJLL67GGF1%3A3%3A84fe6684`.

Remaining issues observed:

- Slice 16 should normalize terminal-wait evidence and recalibrate heuristic
  repair-effectiveness scoring so passing runs do not carry misleading
  low-quality dimensions.

## Slice 16: Browser Evidence Normalization And Passing-Run Judge Scores

Observation:

- Slice 15's final browser run passed, but the evidence still had confusing
  UX/report signals: `terminal_wait_observed?` could be false even when
  Workbench completion proof was terminal, and heuristic
  `repair_effectiveness` could be 0 on a successful completed run simply because
  no explicit repair count was present.
- The first Slice 16 integration pass confirmed the judge-score fix, but exposed
  a JSON key-shape issue: top-level `terminal_wait_observed?` was true while
  nested `terminal_wait_state.observed` remained false because the captured map
  had string keys and the normalizer added atom keys.

Orientation:

- Browser timing evidence and persisted Workbench proof are two different
  signals. The raw timeout reason is still useful, but final browser evidence
  should present a coherent terminal state when persisted completion proof is
  terminal.
- Judge dimensions should describe user-facing quality. A completed lane with
  deterministic pass, final output, and no UI gaps is repair-effective even if
  it did not need a counted repair loop.
- Evidence maps crossing the JS/Elixir boundary need JSON-key-safe updates to
  avoid duplicate atom/string fields.

Action:

- Normalized browser UI capture in the Elixir runner after merging browser
  capture with Workbench visible state. If completion proof is terminal, the
  runner now sets `terminal_wait_observed?` and
  `terminal_wait_state.observed` consistently and records
  `source: "persisted_completion_proof"`.
- Added JSON-key-safe field replacement for normalized browser evidence.
- Recalibrated heuristic `repair_effectiveness` to score successful
  deterministic-pass, non-failed lanes as 1 even when `repair_count` is 0.
- Added regression coverage for terminal-wait normalization and successful
  no-repair judge scoring.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs:475 test/runic_ai/rlm/robustness_test.exs:490 test/runic_ai/rlm/robustness_test.exs:990`
  passed with 3 selected tests and 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs:990` passed after the
  JSON-key normalization fix.
- `mix compile --warnings-as-errors` passed.
- `mix runic_ai.rlm.robustness --scenario empty_app_creation --lane browser_tidewave --label ooda061-slice16-terminal-state-json --browser-ui-launch --browser-ui-capture`
  wrote
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice16-terminal-state-json.md`.
  The row passed with deterministic pass, judge pass, 11 passed checks,
  0 failed checks, final output `empty_app_creation_smoke_pass`, and no UI gaps.
- The final report JSON scored all heuristic judge dimensions as 1, including
  `repair_effectiveness` and `user_output_quality`.
- Latest browser evidence reports session status `completed`, terminal
  completion proof, `ready? true`, `scorecard_satisfied? true`,
  5 delivered changed files, 0 scratch changed files, zero console errors,
  zero network failures, and `terminal_wait_state.observed: true` with
  `source: "persisted_completion_proof"`.
- The generated project source/test/mix files for the final run contain no
  `warning:` text.

Remaining issues observed:

- The Chrome DevTools MCP surface available in this session still lacks an
  explicit navigation/page-selection command, so current-session inspection is
  limited when the selected target is not the browser-runner session. The
  browser-runner capture remains the authoritative current-session browser
  evidence.
- Full completion of 061 still needs a broader requirement-by-requirement audit
  across the dynamic workflow matrix, not just the empty-workspace coding slice.

## Slice 17: General Matrix Audit And Fixture Overfit Cleanup

Observation:

- A full browser-launched `general_dynamic_workflow` matrix exposed that the
  empty-workspace slice is not enough proof of the 061 contract. The matrix run
  at
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice17-general-matrix.md`
  produced 5 rows:
  `research_report` and `denied_tool_review` passed; `empty_app_creation`,
  `existing_app_feature`, and `refactor_existing_module` failed.
- `refactor_existing_module` failed because the deterministic check rejected
  any use of `String.split(raw, ",")`, even when the agent had separated
  parsing, validation, normalization, and tests. This was a fixture overfit: the
  generic requirement is to avoid the old monolithic normalize implementation,
  not to ban a normal parser primitive.
- `existing_app_feature` passed external checks in one broad-matrix run but the
  internal progress gate failed on `:world` in a changed source file. This was
  another overfit: `:world` is too broad to treat as scaffold residue across
  arbitrary code.
- After fixing those overfits, `refactor_existing_module` passed in the
  two-row browser rerun
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice17-progress-marker-refactor.md`.
- `existing_app_feature` remains a real reliability gap. The latest focused run
  at
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice17-existing-feature-alignment.md`
  failed because the generated implementation introduced invalid Elixir syntax
  in tests and a runtime smoke shape mismatch. The repair loop exhausted without
  converging.

Orientation:

- The matrix is now distinguishing harness overfit from actual workflow
  unreliability. Refactor was blocked by a brittle check, while existing-feature
  is blocked by repair convergence on generated code that compiles/runs
  incorrectly.
- Scaffold-residue detection should catch concrete generated scaffolds such as
  `def hello do` and `greets the world`, but should not treat every common atom
  value as proof of scaffold-only work.
- Refactor evals should prefer behavioral and structural acceptance checks over
  banning ordinary implementation primitives.

Action:

- Removed the overbroad `:world` scaffold marker from
  `RunicAI.Coding.RLM.ProgressGate`.
- Added regression coverage proving the progress gate does not treat every
  `:world` atom as scaffold residue while preserving the scaffold-only
  rejection fixture.
- Changed the refactor deterministic check to reject the original monolithic
  assignment shape
  `[type, id, timestamp] = String.split(raw, ",")` instead of all
  `String.split(raw, ",")` usage.
- Changed the existing-feature test evidence check from the phrase
  `integration smoke` to the actual `integration_smoke` API identifier.

Validation:

- `mix test test/runic_ai/coding/rlm_reliability_test.exs:643 test/runic_ai/coding/rlm_reliability_test.exs:707 test/runic_ai/rlm/robustness_test.exs:284`
  passed with 3 selected tests and 0 failures.
- `mix test test/runic_ai/coding/rlm_reliability_test.exs:643 test/runic_ai/coding/rlm_reliability_test.exs:707 test/runic_ai/rlm/robustness_test.exs:423`
  passed with 3 selected tests and 0 failures.
- `mix compile --warnings-as-errors` passed.
- `mix runic_ai.rlm.robustness --scenario existing_app_feature --scenario refactor_existing_module --lane browser_tidewave --label ooda061-slice17-progress-marker-refactor --browser-ui-launch --browser-ui-capture`
  wrote a 2-row browser report. The refactor row passed with deterministic
  pass, judge pass, 8/8 checks, final output showing 5 tests and 0 failures,
  zero console errors, and zero network failures.
- `mix runic_ai.rlm.robustness --scenario existing_app_feature --lane browser_tidewave --label ooda061-slice17-existing-feature-alignment --browser-ui-launch --browser-ui-capture`
  confirmed the remaining existing-feature failure is real generated-code
  convergence: deterministic failures include invalid test syntax and runtime
  smoke mismatch, with terminal failed Workbench proof and zero browser
  console/network failures.

Remaining issues observed:

- `existing_app_feature` needs a general repair-convergence improvement. The
  system should use the exact compile/test/runtime failure output to produce a
  smaller repair task that fixes invalid syntax and smoke shape instead of
  continuing broad feature rewrites.
- The empty-app row failed once in the full matrix at coordinator proposal
  generation before implementation began, despite passing repeatedly as a
  single-scenario run. The next audit should determine whether this was model
  stochasticity or a proposal-schema/repair bug.
- Full 061 completion remains open until the general matrix passes or each
  failing row has explicit, user-visible blocked evidence aligned with the
  completion contract.

## Slice 18: Command-First Repair, Root Placement, Report Verification, And Final Output Hygiene

Observation:

- The focused `existing_app_feature` browser run from Slice 17 failed because
  generated tests contained invalid Elixir syntax and the runtime smoke returned
  a shape that did not match the verifier. The repair loop did not lead with
  the exact failing command output.
- The broad browser matrix at
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-full-general-browser.md`
  showed `existing_app_feature` and `refactor_existing_module` passing, but
  `empty_app_creation` and `research_report` failing.
- `empty_app_creation` created a valid-looking Mix project under `tmp/` first,
  then burned repair iterations moving work to the selected workspace root.
- `research_report` initially launched in `verify` mode even though writing
  `reports/delivery_risk_report.md` is a workspace mutation. After switching
  to patch mode, it created the report but the verifier treated
  `source_not_contains_glob("lib/**/*.ex", "DeliveryRisk")` as a failure when
  no `lib/**/*.ex` files existed.
- A later broad run exposed an internal generated-check mismatch: the proposal
  used `test_count_min` for changed-file-count checks, causing a documentation
  task to wait for ExUnit output even after the report artifact passed external
  deterministic checks.
- Browser evidence also reproduced the original UX smell: final output could
  become a raw `git status` / file listing instead of the relevant changed
  artifact and objective evidence.

Orientation:

- These are general workflow reliability issues, not RayOps- or repo-QA-specific
  cases. The durable fixes are stronger generic repair handoff evidence,
  workspace-root placement invariants, correct negative assertion semantics,
  proper acceptance-check primitives, and final-output prioritization.
- A user-facing coding workflow should surface the satisfied objective,
  changed files, verification evidence, or blocked reason. Incidental command
  stdout should not become the assistant answer when a scorecard exists.
- Negative source assertions are guards. In a documentation-only workspace,
  "no matching code files" should satisfy "do not contain this forbidden code
  marker."

Action:

- Added a command-first repair focus block to repair objectives. It includes
  the failed command, status, cwd, output preview, and guidance to fix
  compile/test/runtime-smoke failures before weaker source-text checks.
- Strengthened mutating child-agent instructions so generated projects are
  rooted at the selected workspace root unless the objective explicitly names a
  nested project directory. Scratch roots such as `tmp/`, `generated/`, `app/`,
  and duplicate project directories are called out as invalid delivery roots.
- Changed the research-report browser scenario to patch mode because producing
  a report artifact is a mutation even when code edits are forbidden.
- Changed `source_not_contains` verification so empty glob matches pass with
  explicit `{paths: [], file_count: 0}` metadata.
- Added `changed_file_count_between` as a first-class acceptance check and
  normalized generated `test_count_min` checks whose id/metadata clearly target
  changed-file counts into the changed-file-count primitive.
- Changed RLM terminal final-output selection so answer episodes still win, but
  command-like episodes and raw command output cannot outrank a satisfied
  scorecard summary.

Validation:

- Focused tests passed:
  `mix test test/runic_ai/coding/rlm_agent_test.exs:221 test/runic_ai/coding/rlm_agent_test.exs:2122 test/runic_ai/coding/rlm_reliability_test.exs:1303`.
- Negative-glob, changed-file-count normalization, and final-output regressions
  passed through focused `mix test` selections, including
  `test/runic_ai/coding/rlm_reliability_test.exs` and
  `test/runic_ai/terminal/event_test.exs`.
- `mix compile --warnings-as-errors` passed after each code slice, including
  the final event-output change.
- Focused browser validations:
  - `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-command-first-repair.md`
    passed `existing_app_feature` with 10/10 checks.
  - `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-root-report-focused.md`
    passed `empty_app_creation` with 11/11 checks and created the Mix project
    at the selected workspace root.
  - `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-research-negative-glob.md`
    passed `research_report` after negative source glob semantics were fixed.
  - `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-final-output-priority.md`
    passed `research_report` and showed final output as:
    `RLM completed. Objective status: objective_satisfied. Changed files:
    reports/delivery_risk_report.md`.
  - `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-final-output-episode-filter.md`
    passed `research_report` with session status `completed`, zero console
    errors, zero network failures, and the same relevant scorecard final output.
- Broad browser validation:
  - `tmp/rlm_robustness/reports/rlm-robustness-matrix-ooda061-slice18-final-general-browser-v2.md`
    passed `empty_app_creation`, `existing_app_feature`, `research_report`, and
    `denied_tool_review`.
  - The same broad run failed `refactor_existing_module` before implementation
    because the generated workflow proposal/repair was not valid JSON. Earlier
    focused refactor browser validation in Slice 17 passed, so this is now a
    proposal-generation stochasticity/repair gap rather than a deterministic
    refactor-check overfit.

Remaining issues observed:

- Full 061 completion is still open. The latest broad browser matrix is 4/5,
  with `refactor_existing_module` failing at proposal generation due invalid
  generated JSON. The next OODA slice should harden proposal generation and
  proposal repair so invalid JSON cannot strand a valid refactor task before
  implementation.
- Research-report final output is fixed in focused validation after command
  episode filtering. The next broad matrix should be repeated after proposal
  JSON hardening to confirm both fixes hold together in one full run.
- The Chrome DevTools MCP visible target still remains `about:blank` for the
  external MCP connection while the harness controls its own Chrome process.
  Browser-runner artifacts are therefore the reliable browser evidence source
  for these integration tests unless the harness exposes its CDP target to the
  MCP session.
