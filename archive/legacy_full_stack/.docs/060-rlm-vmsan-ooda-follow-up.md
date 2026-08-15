# RLM Vmsan OODA Follow-up

Status: fixes applied, residual runtime gaps observed

Date: 2026-06-17

## Purpose

This note follows up on `.docs/059-rayops-vmsan-workflow-rlm-integration-report.md`
with the OODA loop used to harden the Workflow RLM browser path for a general
purpose coding-agent workflow. The RayOps prompt remains an arbitrary large
context creation task; the changes below are intended to improve any dynamic
workflow coding run, not to special-case RayOps.

The continuation goal loop is captured in
`.docs/061-sandbox-backed-dynamic-workflow-ooda-goal.md`.

## Loop 1: Launch Policy Drift

Observation:

- Browser launch submitted `approve=always`, `agent=rlm`, `mode=patch`,
  `sandbox_backend=vmsan`, and `sandbox_runtime=elixir`.
- The old terminal parser rejected `--approve always`, leaving the browser
  session running without useful events.

Action:

- Accepted `always` and boundary alias `all` in terminal CLI parsing.
- Added durable launch-failure recording around Workbench background startup.
- Preserved launch metadata across later capability events.
- Hydrated the follow-up composer from selected session launch metadata.
- Added Vmsan to the visible sandbox selector list.

Outcome:

- Browser RLM runs now progress past launch into model preflight, dynamic
  proposal generation, workflow compilation, and node execution.
- Session metadata persists `approval=always`, `mode=patch`,
  `write_policy=workspace_review`, `sandbox.backend=vmsan`,
  `sandbox.runtime=elixir`, and all selected runtimes.

## Loop 2: Empty Workspace Creation

Observation:

- With launch fixed, child implementation nodes saw an empty selected
  workspace and repeatedly stopped after `list_dir` or `find_files`.
- The child interpreted "inspect before editing" as requiring an existing
  Phoenix/Ecto app before it could create files.

Action:

- Enriched mutating RLM agent-node tasks with a generic empty-workspace
  instruction.
- Updated the implementation recipe with the same general rule.
- Updated standard patch-mode prompting so an empty workspace listing counts as
  sufficient inspection when the task asks to create or build new artifacts.

Outcome:

- Subsequent browser runs showed the empty-workspace instruction in the child
  task payload.
- The model behavior improved in one run enough to attempt `apply_patch`, but
  another run still chose to stop after read-only inspection. This is now a
  prompt/runtime robustness issue, not a launch or metadata issue.

## Loop 3: Nested Review Gates

Observation:

- A child patch agent attempted `apply_patch` and hit an internal pre-tool
  review gate with reason `patch_operations_not_inspectable`.
- The outer Workbench `approve=always` policy did not resume that nested child
  review, and no browser `review_requests` row was persisted.

Action:

- Added parent-review-decider propagation to Workflow RLM child-agent execution.
- Added child workflow auto-resume for approved or edited child review gates.
- Filtered stale child review requests after successful resume so completed
  child results are not misclassified as `needs_review`.
- Added `--approve always` handling to the terminal default review decider.

Outcome:

- Focused tests prove a review-gated child patch can be approved by the parent
  policy and complete with changed files.
- Browser runs no longer fail at the original approve-all parser mismatch.

## Loop 4: Approve-All Runaway

Observation:

- A later full browser run (`web-session:HJKGN649JP:7G:0723d5f6`) progressed
  farther: the child patch agent listed the empty workspace, hit a nested
  pre-tool review, received an automatic approval, and ran `apply_patch`.
- The run eventually produced a concrete `ray_ops` domain slice in the selected
  workspace, including schemas, a migration, and tests.
- The session still remained in a poor user-facing state because the outer
  objective loop kept asking for more approval/budget and browser approve-all
  kept resuming it. Persisted events showed five `objective_loop_resume`
  attempts before the cap fired.

Action:

- Preserved the source of persisted review decisions.
- Marked Workbench session-policy auto approvals with
  `source=session_approval_policy`.
- Added a source-aware objective auto-resume cap for browser approve-all
  decisions, while leaving deliberate manual approvals unblocked.

Outcome:

- The same session now has a durable blocked event:
  `Objective auto-resume limit reached`.
- Persisted review state shows the expected shape: five approved review
  requests and one pending budget approval, instead of an unbounded sequence of
  automatic resumes.
- This gives the UI a concrete state to render and the user a chance to make a
  new decision instead of watching an apparently endless running session.

## Current Residual Issues

1. Standard patch children can still emit malformed `apply_patch` input or
   report a failed first repair even when a later objective-loop resume recovers
   and creates files. A stronger runtime strategy may be needed: when a
   patch-mode child returns no changes after an empty-workspace creation task,
   retry with a narrower "create these files now" repair prompt inside the child
   before the outer RLM repair loop consumes iterations.

2. The browser UI does not clearly show the reason a child stopped without
   edits. The useful detail is in terminal event payloads, not in an immediate
   user-facing state.

3. Nested child review gates still emit noisy integrated-runtime warnings in
   tests during resume, even when the final child result is correct. That should
   be tracked separately because warning spam makes reliability harder to read.

4. Vmsan selection is persisted in capability metadata, but these runs still do
   not produce a clear user-facing proof that writes and commands executed
   inside Vmsan and were copied back to the selected workspace. The Workbench
   should expose sandbox session/proof artifacts for code-execution nodes.

## Validation

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/standard_agent_remaining_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
- Result: 156 tests, 0 failures.

Browser integration sessions observed:

- `web-session:HJKG4NGESQ:15:7d6095c3`: launch/policy fixed; failed after
  empty-workspace no-op implementation.
- `web-session:HJKG83FU7R:2O:e09f2a7d`: empty-workspace task enrichment reached
  the child task; still stopped without edits.
- `web-session:HJKGBQHORE:49:88d5e723`: child attempted `apply_patch` and hit
  nested review.
- `web-session:HJKGIYS6J7:5W:2139bc36`: latest run after child-review fixes;
  no persisted review request, but the model still chose read-only inspection
  and stopped without edits.
- `web-session:HJKGN649JP:7G:0723d5f6`: full RayOps/Vmsan browser run after
  patch-prompt fixes. The child agent hit a nested review, auto-approved it,
  ran `apply_patch`, and after objective-loop recovery produced files under
  `tmp/rayops-vmsan-ooda-5`:
  `lib/ray_ops.ex`, `lib/ray_ops/application.ex`,
  `lib/ray_ops/customer.ex`, `lib/ray_ops/fulfillment_stage.ex`,
  `lib/ray_ops/project.ex`, `lib/ray_ops/project_design.ex`,
  `lib/ray_ops/repo.ex`, `lib/ray_ops/tenant.ex`,
  `priv/repo/migrations/0001_create_ray_ops_domain.exs`,
  `test/ray_ops/domain_test.exs`, and
  `test/ray_ops/fulfillment_stage_test.exs`. It then exposed the approve-all
  objective-resume runaway, which is now capped.
