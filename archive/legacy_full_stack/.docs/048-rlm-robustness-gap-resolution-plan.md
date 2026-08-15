# RLM Robustness Gap Resolution Plan

Status: in progress

Date: 2026-05-23

Last implementation pass: 2026-05-24.

This plan resolves the concrete gaps surfaced while executing
`.docs/047-rlm-robustness-capability-testing-plan.md`. The goal is to move the
RLM from a repo-shaped coding route toward the intended general-purpose
workflow coordinator:

```text
intent -> objective contract -> generated workflow -> validation -> execution
  -> evidence -> OODA repair -> final answer only when the goal is satisfied
```

## Smoke Evidence

Reports produced during the robustness execution pass:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-default-20260523-v2.md`
  and `.json`: seven project scenarios across `standard`, `assistant`, `rlm`,
  and `browser_tidewave` lanes. Result: 24 fail, 4 review, 0 pass.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-rlm-field-service-20260523.md`
  and `.json`: live `rlm` lane on Field Service Dispatch. Result: fail.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-standard-field-service-20260523.md`
  and `.json`: live `standard` lane on Field Service Dispatch. Result: fail.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-assistant-field-service-20260523.md`
  and `.json`: live `assistant` lane on Field Service Dispatch. Result: fail.
- `tmp/rlm_robustness/reports/browser-workbench-initial-snapshot.txt` and
  `browser-workbench-initial.png`: real browser launch evidence for the
  Phoenix workbench.
- `tmp/rlm_robustness/reports/browser-workbench-session-running-snapshot.txt`,
  `browser-workbench-session-running.png`, and
  `browser-workbench-session-after-wait-snapshot.txt`: real browser evidence
  for a launched `rlm` field-service session.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-final-rlm-guardrails-20260523.md`
  and `.json`: refreshed deterministic matrix after child-budget, proposal
  normalization, and scoring-honesty fixes.
- Targeted live `rlm` Field Service probes after the second implementation
  pass:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-child-budget-live-rlm-field-service-20260523.md`,
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-deadline-aware-child-budget-live-rlm-field-service-20260523.md`,
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-vocab-normalization-live-rlm-field-service-180s-20260523.md`,
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-mode-aware-child-budget-live-rlm-field-service-240s-20260523.md`,
  and
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-os-timeout-wrapper-live-rlm-field-service-150s-20260523.md`.
- Observability pass live `rlm` Field Service probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-trace-live-progress-rlm-field-service-90s-20260523.md`.
  Event trail:
  `tmp/rlm_robustness/workspaces/trace-live-progress-rlm-field-service-90s-20260523/field_service_dispatch/rlm/tmp/rlm-event-trail.jsonl`.
- Cleanup-grace validation probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-trace-live-cleanup-grace-rlm-field-service-65s-20260523.md`.
  Event trail:
  `tmp/rlm_robustness/workspaces/trace-live-cleanup-grace-rlm-field-service-65s-20260523/field_service_dispatch/rlm/tmp/rlm-event-trail.jsonl`.
- Parent-owned deterministic Elixir generation probes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-artifact-fix-rlm-field-service-45s-20260524.md`,
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-workflow-fix-rlm-45s-20260524.md`,
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-existing-app-rlm-45s-20260524.md`,
  and
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-rlm-live-catalog-all-pass-45s-20260524.md`.
  Result: the live `rlm` lane passed all seven current project-generation
  scenarios in `.docs/047`.
- Deterministic baseline after parent-owned generation:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-deterministic-20260524.md`.
  Result: scaffold rejection still catches most lanes; `existing_app_feature`
  remains a weak deterministic baseline when live lanes are disabled.
- Existing App deterministic tightening probes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-tightened-baseline-20260524.md`
  and
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-tightened-live-rlm-20260524.md`.
  Result: untouched `existing_app_feature` scaffold now fails deterministic
  checks, while the live `rlm` lane passes with compile, test, runtime-smoke,
  and event-trail evidence.
- Existing App output-excerpt regression probes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-output-excerpts-baseline-20260524.md`
  and
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-output-excerpts-live-rlm-20260524.md`.
  Result: the baseline still fails and the live `rlm` lane still passes after
  deterministic command checks began persisting bounded `stdout_excerpt` and
  `stderr_excerpt` fields in JSON report check details.
- Model/client preflight live RLM probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-model-client-preflight-existing-app-live-20260524.md`.
  Result: the live `rlm` lane still passes, and the terminal JSONL now starts
  with a `model_client_preflight` event containing the resolved provider,
  model, client, account mode, and resolver decision.
- Child live-event forwarding regression pass:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-child-live-events-rlm-catalog-45s-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios after adding live Codex JSONL forwarding.
- Child tool/review/verification live-event regression pass:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-child-tool-events-rlm-catalog-45s-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios after adding live integrated child tool event
  forwarding.
- In-tool command/process progress regression pass:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-in-tool-command-progress-rlm-catalog-45s-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios after adding command/process progress streaming.
- Browser operation progress regression pass:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-operation-progress-rlm-catalog-45s-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios after adding browser session operation events.
- Browser-lane backend probe after browser operation progress:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-operation-progress-browser-probe-field-service-20260524.md`.
  Result: `browser_tidewave` still fails for Field Service Dispatch because
  browser/UI evidence capture is incomplete. This confirms the remaining Phase
  6 work is not solved by browser-tool events alone.
- Browser-lane backend evidence probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-evidence-probe-field-service-20260524.md`.
  Result: `browser_tidewave` still fails, but now records a durable browser
  evidence artifact at
  `tmp/rlm_robustness/workspaces/browser-evidence-probe-field-service-20260524/field_service_dispatch/browser_tidewave/tmp/browser-evidence-field_service_dispatch.json`.
  The artifact captures session URL, launch options, Workbench launch/final
  projections, visible message/event/review/artifact state, and explicit
  missing DOM screenshot, browser console, and Tidewave-interaction checks.
- Live RLM catalog regression after browser evidence runner changes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-evidence-rlm-catalog-45s-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios.
- Browser-lane Chrome UI capture probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-capture-field-service-v3-20260524.md`.
  Result: `browser_tidewave` still fails, but now captures rendered session
  HTML, a structured DOM snapshot, and a PNG screenshot under the browser
  evidence artifact. Remaining UI gaps are browser console capture and normal
  Tidewave-driven UI interaction.
- Live RLM catalog regression after Chrome UI capture changes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-capture-rlm-catalog-45s-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios.
- Browser-lane normal Workbench UI launch probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-launch-field-service-v10-20260524.md`.
  Result: `browser_tidewave` now launches Field Service Dispatch through the
  rendered Workbench composer, captures DOM text, HTML, screenshot, console,
  network, launch/final projections, and final assistant-visible output. The
  remaining explicit UI check failure is Tidewave-specific follow-up
  interaction.
- Live RLM catalog regression after browser UI launch and projection
  hardening:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-launch-rlm-catalog-live-20260524.md`.
  Result: the live `rlm` lane passed all seven current project-generation
  scenarios with visible `message/assistant` final output events.
- Browser-lane same-session follow-up smoke, first attempt:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-follow-up-field-service-20260524.md`.
  Result: the browser runner submitted a follow-up through the same Workbench
  session, but the run exposed a false pass in the report layer. The session
  status was `failed` and the final visible output reported that the coding
  coordinator could not produce an accepted workflow proposal.
- Browser-lane same-session follow-up smoke after failed-status and context
  fixes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-follow-up-field-service-v3-20260524.md`.
  Result: `browser_tidewave` passed Field Service Dispatch with captured
  follow-up state, `browser_follow_up_captured?`, four visible messages, 60
  events, completed session status, and final visible output reporting
  `objective_satisfied`.
- Live RLM catalog regression after browser follow-up changes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-follow-up-rlm-catalog-live-20260524.md`.
  Result: the live `rlm` lane passed all seven current project-generation
  scenarios.
- Browser-lane plan-stage visibility smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-plan-stage-field-service-v2-20260524.md`.
  Result: Field Service Dispatch passed with browser evidence showing visible
  plan labels for objective, planning, implementation, verification, repair, and
  review. The plan cards now derive stage titles from persisted event phases
  such as `proposal_started`, `node_started`, and `compile_completed` instead of
  the old generic execution card.
- Browser-lane full catalog after plan-stage visibility checks:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-plan-stage-catalog-v2-20260524.md`.
  Result: all seven `browser_tidewave` rows passed. Each browser evidence file
  captured `plan_visibility_captured?`, `workflow_stage_plan_visible?`,
  `browser_follow_up_captured?`, completed session status, and four visible
  messages.
- Live RLM catalog regression after plan-stage visibility checks:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-plan-stage-rlm-catalog-live-20260524.md`.
  Result: the live `rlm` lane still passed all seven current
  project-generation scenarios.
- Browser repair-follow-up smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repair-followup-browser-v3-20260524.md`.
  Result: the new `field_service_repair_followup` scenario passed. Browser
  evidence captured an injected pre-follow-up `mix test` failure
  (`command_status: 2`), same-session follow-up submission, workflow-stage
  visibility, completed session status, and final deterministic pass.
- Browser full-catalog smoke after adding the repair-follow-up scenario:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repair-followup-browser-catalog-20260524.md`.
  Result: all eight `browser_tidewave` rows passed, including the repair
  fixture.
- Live RLM catalog regression after adding the repair-follow-up scenario:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repair-followup-rlm-catalog-live-20260524.md`.
  Result: all eight live `rlm` rows passed.
- Browser review-card approval smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-approval-v4-20260524.md`.
  Result: browser evidence captured a visible review card, submitted
  `review_decision` through the rendered form, recorded review status
  `approved`, and resumed the session to `completed`. The row still failed
  deterministic project checks because the RLM marked the objective satisfied
  while leaving the scaffold implementation unchanged.
- Browser repair follow-up regression after review/follow-up gating changes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-followup-regression-20260524.md`.
  Result: `field_service_repair_followup` still passed with injected failing
  `mix test` evidence, same-session follow-up, final deterministic pass, and
  `browser_follow_up_required?`/`browser_follow_up_captured?` true.
- Full test regression after the browser approval and persistence fixes:
  `mix test` passed with 660 tests, 0 failures, 2 skipped.
- Browser full-catalog smoke after threading deterministic objective contracts
  into seeded project generation:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-threaded-20260524.md`.
  Result: 8 pass, 1 fail. The failure was useful: `event_sourced_audit`
  generated field-service artifacts because `work order` outweighed explicit
  event-sourced audit intent.
- Browser full-catalog smoke after the first classifier correction:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-threaded-v2-20260524.md`.
  Result: 8 pass, 1 fail. The inverse failure caught `auditable allocation`
  being treated as the audit domain instead of inventory.
- Browser full-catalog smoke after token-boundary intent matching:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-boundary-v3-20260524.md`.
  Result: all nine `browser_tidewave` rows passed with correct generated
  artifacts for both `inventory_allocation` and `event_sourced_audit`.
- Full test regression after objective-contract threading and classifier
  boundary fixes:
  `mix test` passed with 670 tests, 0 failures, 2 skipped.
- Browser full-catalog smoke after structured contract and blocked-evidence
  projection checks:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-structured-evidence-20260524.md`.
  Result: all nine `browser_tidewave` rows passed. The new
  `structured_contract_requirements_visible` and
  `blocked_next_action_evidence_visible` UI checks passed for every row.
- Tiny-budget live RLM Field Service probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-blocked-evidence-rlm-field-service-20260524.md`.
  Result: failed as `error` before active node execution with `RLM runtime
  budget exhausted`; this confirms pre-execution budget exhaustion remains
  distinct from active-node blocked evidence.
- Full test regression after structured blocked-evidence projection:
  `mix test` passed with 672 tests, 0 failures, 2 skipped.
- Browser full-catalog smoke after Workbench contract/evidence UI rendering:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-ui-nilfix-20260524.md`.
  Result: all nine `browser_tidewave` rows passed. The rendered session DOM now
  exposes `Objective contract`, requirement IDs, required evidence, `Blocked
  evidence`, and next-action evidence. The validation rerun also caught and
  fixed a UI normalization bug where absent blocked-evidence facts rendered as
  literal `nil`.
- Full test regression after Workbench contract/evidence UI rendering:
  `mix test` passed with 673 tests, 0 failures, 2 skipped.
- Browser full-catalog smoke after Workbench live-progress UI rendering and
  smoke-runner assertion:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-live-progress-check-20260524.md`.
  Result: all nine `browser_tidewave` rows passed. Browser evidence now
  includes the explicit `live_progress_summary_visible` UI check, backed by
  the Workbench plan tab text. Field Service captured `LIVE PROGRESS`, `60
  persisted events`, and latest progress title `Agent finished`.
- Full test regression after live-progress UI and smoke-runner checks:
  `mix test` passed with 674 tests, 0 failures, 2 skipped.
- Browser full-catalog smoke after active progress context capture:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-active-progress-context-v2-20260524.md`.
  Result: all nine `browser_tidewave` rows passed. Browser evidence now
  includes the explicit `active_progress_context_visible` UI check. The
  review-approval row captures an early Plan-tab snapshot while the run is
  waiting for approval, showing `NODE implement_project`, `LIVE PROGRESS`, and
  the review gate before the approval decision is submitted.
- Targeted review-approval regression after the early Plan-tab snapshot changed
  browser focus:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-active-progress-review-fix-20260524.md`.
  Result: passed after the browser runner returned to the Reviews tab before
  submitting the approval decision.
- Targeted browser review smoke after real node-budget projection:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-active-budget-prefinal-review-20260524.md`.
  Result: passed with active Plan-tab evidence captured before final completion.
  The pre-approval snapshot shows `NODE implement_project`, `CHILD
  implement_project:edit`, `REMAINING 5.0m`, `MAX 5.0m`, and `CHILD BUDGET
  5.0m`.
- Browser full-catalog smoke after strict active child/budget checks:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-active-budget-prefinal-20260524.md`.
  Result: all nine `browser_tidewave` rows passed with the new
  `active_progress_budget_details_visible` check. The review-approval row also
  passes `active_progress_pre_final_visible`, proving browser-visible progress
  before approval continuation and final completion.
- Full test regression after active progress context capture:
  `mix test` passed with 674 tests, 0 failures, 2 skipped.
- Child-agent repair-loop smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-child-agent-repair-loop-v3-20260524.md`.
  Result: passed for the new `rlm_child_agent_repair_loop` scenario. The parent
  RLM captured the failing `mix test`, built structured repair evidence,
  launched the real `StandardAgent.patch/3` child-agent path, observed an
  `apply_patch` tool call against `lib/internal_repair_demo.ex`, reran
  verification, and completed with one repair and `objective_satisfied`.
- Semantic child-agent repair-loop smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-child-agent-repair-semantic-20260524.md`.
  Result: passed after replacing the semantic repair fixture executor with the
  real `StandardAgent.patch/3` child-agent path. The parent RLM captured the
  semantic `transition_history` failure, the child applied `apply_patch` to
  `lib/work_order.ex` and `test/work_order_test.exs`, and the parent reran
  `mix test` plus semantic judging before completing with one repair.
- LLM-judge child-agent repair-loop smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-child-agent-repair-20260524.md`.
  Result: passed after replacing the LLM-judge repair fixture executor with the
  same real child-agent/tool path. The repair handoff preserved LLM judge
  provenance for `transition_history`, the child patched WorkOrder transition
  history, and the parent reran verification before completing with one repair.
- Runtime-smoke child-agent repair-loop smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-child-agent-repair-20260524.md`.
  Result: passed after replacing the runtime-smoke repair fixture executor with
  the real child-agent/tool path. The parent RLM captured the failing
  `dispatch_flow` runtime smoke, the child applied `apply_patch` to
  `lib/dispatch_runtime.ex` and `test/dispatch_runtime_test.exs`, and the
  parent reran the runtime smoke before completing with one repair.
- Repeated-scenario harness smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repeated-scenario-child-repair-pair-20260524.md`.
  Result: passed with two rows after the robustness Mix task changed repeated
  `--scenario` and `--lane` flags to `:keep` parsing. The report contains both
  `rlm_semantic_repair_loop` and `rlm_llm_judge_repair_loop`, proving the
  harness no longer silently drops earlier repeated scenario flags.

## Workbench Contract UI Pass: 2026-05-24

Implemented changes:

- The Workbench plan tab now renders a first-class objective-contract panel
  from the projected session snapshot. It shows the inferred domain/profile,
  required evidence chips, and the first contract requirements.
- The Workbench plan tab now renders a first-class blocked-evidence panel. It
  shows blocked status, current node, child/elapsed/budget/latest-event facts
  when present, and concrete next actions.
- Blocked assistant messages now show projected next actions inline below the
  blocking reason, so chat users do not need to inspect debug JSON to know the
  next repair move.
- LiveView regression fixtures now seed structured `objective_contract` and
  `blocked_evidence` payloads, covering both chat and plan-tab rendering.
- UI value normalization now treats absent values as absent instead of rendering
  `nil` as text.

Validation after this pass:

- `mix test test/runic_ai_web/workbench_live_test.exs` passed: 14 tests,
  0 failures.
- `mix test test/runic_ai_web/workbench_live_test.exs test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 52 tests, 0 failures.
- `mix test` passed: 673 tests, 0 failures, 2 skipped.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-ui-nilfix-20260524.md`
  passed all nine `browser_tidewave` rows with DOM evidence for contract and
  blocked-evidence UI.

Remaining gaps surfaced by this pass:

- The plan tab still does not expose a full event trail with remaining budget
  and latest progress as a timeline; it only renders projected contract and
  blocked-evidence summaries.
- Current-node/elapsed/budget fields only become visible when the projected
  blocked evidence contains those values. Active in-flight runs still need
  streaming session-detail UI, not only final blocked projections.
- Review rejection/edited-instruction browser checks remain unimplemented.

## Workbench Live Progress UI Pass: 2026-05-24

Implemented changes:

- Workbench session snapshots now project a `progress_summary` from persisted
  terminal events and blocked evidence. It includes event count, latest
  progress event, current node/child, elapsed time, selected child timeout,
  max runtime, and remaining runtime when those values are present.
- The Workbench plan tab and trace inspector now render a `Live progress`
  panel with persisted event count, latest progress title/detail, current
  node/child, and runtime budget facts.
- The browser UI runner now detects `Live progress` and persisted event text in
  the plan tab.
- The robustness runner now includes a `live_progress_summary_visible` browser
  UI check so future browser catalog passes must prove the progress panel is
  actually visible.

Validation after this pass:

- `mix test test/runic_ai/workbench_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed: 26 tests, 0 failures.
- `mix test test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed: 53 tests, 0 failures.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-live-progress-check-20260524.md`
  passed all nine `browser_tidewave` rows with
  `live_progress_summary_visible` passing in browser evidence.
- `mix test` passed: 674 tests, 0 failures, 2 skipped.

Remaining gaps surfaced by this pass:

- Successful deterministic browser rows expose event count/latest progress, but
  naturally lack current-node and remaining-budget facts after completion. We
  still need an active-running or blocked browser smoke that captures these
  fields while the run is in flight or budget-limited.
- The UI exposes the persisted event trail summary, but not yet a clickable
  event-trail artifact path or a richer timeline grouped by proposal, child
  node, tool, verification, and repair stages.
- Checkpointed blocked-result artifacts still do not carry the same current
  node/current child/latest progress fields as final message/scorecard
  projections.

## Browser Active Progress Context Pass: 2026-05-24

Implemented changes:

- The browser UI runner now captures an early Plan-tab progress snapshot
  immediately after the session route is reached, before follow-up or review
  continuation flows.
- The browser runner records `active_plan_text_preview`,
  `active_progress_snapshot_captured?`,
  `active_progress_current_context_visible?`, and
  `active_progress_budget_visible?` in browser evidence.
- Browser review-decision automation now returns to the Reviews tab after the
  early Plan snapshot, so approval/rejection flows are not hidden by the Plan
  tab capture.
- The robustness runner now requires `active_progress_context_visible` for
  browser UI launched rows. The check can pass from the early Plan snapshot or
  from the durable Workbench projection when current-node evidence is present.
- The deterministic browser probe emits a budget-selection and node-started
  progress pair before final completion, so browser smokes have reliable
  current-node and budget-context evidence to render.
- Workbench progress projection now keeps current-node and budget facts from
  the latest event that actually carries those fields instead of losing them
  when the latest event is only a scorecard/final message.

Validation after this pass:

- `mix test test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed: 38 tests, 0 failures.
- `mix test test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs test/runic_ai_web/workbench_live_test.exs`
  passed: 53 tests, 0 failures.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-active-progress-review-fix-20260524.md`
  passed the targeted review-approval row after restoring review-tab focus.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-active-progress-context-v2-20260524.md`
  passed all nine `browser_tidewave` rows with
  `active_progress_context_visible` and `live_progress_summary_visible`
  checks passing.
- `mix test` passed: 674 tests, 0 failures, 2 skipped.

Remaining gaps surfaced by this pass:

- Resolved in the next pass: browser evidence now proves current child and
  remaining budget in the active Plan snapshot, and review-gated runs must
  prove the snapshot was captured before final completion.
- Review rejection/edit flows are still untested; this pass only preserved and
  revalidated approval.

## Browser Active Budget Details Pass: 2026-05-24

Implemented changes:

- `RunicAI.Coding.RLM.WorkflowCompiler` now emits a real
  `node_budget_selected` event for every RLM workflow node. The event includes
  `node_id`, `current_child`, `remaining_ms`, `max_runtime_ms`, and
  `selected_timeout_ms`, so deterministic edit/reducer/verification nodes have
  the same browser-visible budget facts as child-agent nodes.
- Existing `child_budget_selected` events now include `current_child` and
  `child_agent_id`, so parent progress projection can render child context
  consistently across node and child-agent execution.
- Workbench progress projection now retains `remaining_ms` from the latest
  event that actually carries `remaining_ms`, instead of losing it when a later
  event only carries `max_runtime_ms`.
- The browser runner now records explicit
  `active_progress_child_visible?`, `active_progress_remaining_visible?`, and
  `active_progress_pre_final_visible?` booleans from the active Plan-tab
  snapshot.
- The robustness runner now adds `active_progress_budget_details_visible` for
  all browser UI launches and `active_progress_pre_final_visible` for
  review-gated browser runs.

Validation after this pass:

- `mix test test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs test/runic_ai_web/workbench_live_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 112 tests, 0 failures.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-active-budget-prefinal-review-20260524.md`
  passed the targeted review-approval row. The active pre-approval Plan
  snapshot shows `NODE implement_project`, `CHILD implement_project:edit`,
  `REMAINING 5.0m`, `MAX 5.0m`, and `CHILD BUDGET 5.0m`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-active-budget-prefinal-20260524.md`
  passed all nine `browser_tidewave` rows with the stricter active child/budget
  checks. The review-approval row also passed the pre-final active-progress
  check before approval continuation.

Remaining gaps surfaced by this pass:

- The review-gated active snapshot proves pre-final browser visibility for a
  gated node, but the non-review scenarios are still so fast that their early
  snapshots often show final `Agent finished` progress. A future long-running
  browser smoke should use a real delayed child-agent/tool run to prove
  streaming progress during active execution without relying on a review gate.
- Review rejection/edit flows are still untested.

## Browser Long-Running Progress Probe Pass: 2026-05-24

Implemented changes:

- Added a `progress_observability` RLM recipe and
  `browser_progress_observability` smoke scenario. The scenario launches
  through the browser Workbench in `verify` mode, runs a bounded delayed
  command that emits `rlm_progress_tick=1..5`, and requires a pre-final
  Plan-tab snapshot with visible current node, current child, remaining
  budget, and live command progress.
- Browser-launched RLM runs can now receive scenario-specific `toolsets`,
  `tool_config`, and `mode` values, so smoke scenarios can exercise specific
  coordinator routes without falling back to generic repo-QA behavior.
- Browser evidence capture now canonicalizes token-auth session URLs as
  `/sessions/:id?token=...` and supports repo-local `runic_ai.server` DB
  sharing for backend projection checks.
- Deterministic `acceptance_contract` node outputs now populate the RLM
  runtime context, so seeded and probe workflows project structured objective
  contracts into Workbench snapshots and browser evidence.
- Browser follow-up capture now waits for the follow-up Plan tab to settle on
  `Agent finished` before final evidence capture, and retries Plan-tab
  selection until plan/progress markers are actually visible.

Validation after this pass:

- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/workbench_test.exs test/runic_ai/terminal/runner_test.exs`
  passed: 123 tests, 0 failures.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-progress-observability-contract-20260524.md`
  passed the targeted progress-observability row. Browser evidence shows
  completed session status, `rlm_progress_tick=1..5` final output, structured
  `progress_ticks` objective contract, `active_progress_pre_final_visible?`,
  and visible child/budget facts.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-field-service-plan-retry-20260524.md`
  confirmed the browser follow-up capture fix: Field Service now shows final
  output, structured contract, blocked next-action evidence, live progress,
  and follow-up state. It still fails for the correct reason:
  `objective_incomplete`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-followup-capture-20260524.md`
  ran the 10-row browser catalog. Result: 5 pass, 5 fail. All failed rows have
  complete browser/UI evidence and fail because the RLM blocked with
  `objective_incomplete`, not because the evidence capture was missing.

Remaining gaps surfaced by this pass:

- The original observability gaps are materially closed for browser smokes:
  proposal heartbeat, node/child/tool progress, command progress, active
  pre-final Plan evidence, budget facts, structured blocked output, and
  browser capture are all observable in reports.
- The next gap is capability quality, not observability. The deterministic
  generator still blocks on Field Service, Subscription Billing, Workflow
  Orchestration, Existing App Feature, and the injected Field Service repair
  follow-up. Each failed row records changed files and a structured contract,
  but the generated implementation does not satisfy all acceptance checks.
- Repair is still shallow. Follow-up runs preserve context and failing evidence
  now, but they often regenerate or summarize incomplete work instead of using
  failed acceptance results to drive a minimal domain-specific repair.
- Review rejection/edit flows and Tidewave-specific session metadata remain
  unimplemented.

## Browser Command-Evidence Completion Pass: 2026-05-24

Implemented changes:

- Seeded project-generation workflows now include explicit `compile_project`,
  `test_project`, and `runtime_smoke` command nodes after implementation and
  before verification. The verification gate requires passing command evidence
  instead of inferring success from source/test files alone.
- `ElixirProjectGenerator` now exposes profile-specific runtime-smoke commands
  for Field Service, Inventory, Billing, Clinic Scheduling, Workflow
  Orchestration, Event-Sourced Audit, Existing App Feature, and generic
  projects.
- Patch-mode RLM validation now allows bounded command nodes for safe `mix`
  and `git` commands, and generated safe command nodes can continue after an
  implementation review approval without triggering unrelated review cards.
- Browser capture now waits for the final agent state after review approval and
  after same-session repair follow-ups. The outer browser process timeout now
  scales when a scenario includes a follow-up prompt, so the CDP runner does
  not fail after the backend run has already completed.

Validation after this pass:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 104 tests, 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed after the review-continuation and browser-timeout fixes: 72 tests, 0
  failures.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-command-evidence-subscription-20260524.md`
  passed the targeted Subscription Billing row with compile, test, and
  runtime-smoke command evidence.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-final-wait-20260524.md`
  passed the targeted review-approval row after safe generated command nodes
  continued without extra review interruption and the browser runner captured
  final completion.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-followup-final-wait-20260524.md`
  passed the targeted same-session repair follow-up row after follow-up capture
  and timeout handling were corrected.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-command-evidence-catalog-green-20260524.md`
  passed all 10 current `browser_tidewave` rows: Field Service Dispatch,
  Inventory Allocation, Subscription Billing, Clinic Scheduling, Workflow
  Orchestration, Event-Sourced Audit, Existing App Feature, browser progress
  observability, review approval, and repair follow-up.

Remaining gaps surfaced by this pass:

- The browser catalog is now green for the seeded deterministic generator
  profiles, but this does not prove open-ended RLM workflow synthesis. The
  parent-owned generator should either become a general component with clear
  applicability limits or be replaced by resumable child sessions for domains
  outside its contract.
- Runtime command evidence is now available in the seeded path, but failed
  compile/test/runtime results are not yet a structured repair loop input for
  arbitrary workflows.
- The general RLM route is still coding/workspace centered. Assistant, browser,
  research, memory, and non-code artifact workflows still need the same shared
  objective contract and evidence-gated completion semantics.
- Review rejection/edit flows, Tidewave-specific session metadata, LLM judge
  calibration, and child-subprocess cleanup regression coverage remain open.

## Structured Repair-Plan Pass: 2026-05-24

Implemented changes:

- Each `RepairLoop` iteration now builds a structured repair plan with
  `observed_failure`, `hypothesis`, `planned_edit`, `verification_command`, and
  `stop_condition`.
- The repair plan is emitted in `repair_attempt_started`, included in the child
  repair prompt, persisted in `RepairAttempt.metadata`, and repeated in the
  `repair_attempt_completed` event. Failed command output is summarized into
  the plan so compile/test/runtime evidence is a first-class repair input.
- Patch-mode terminal RLM runs now enable bounded repair by default, with
  `--repair`, `--no-repair`, and `--max-repairs` controls. The robustness live
  lane passes each scenario's `max_repairs` budget into the real terminal route.

Validation after this pass:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 128 tests, 0 failures.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-repair-enabled-field-service-20260524.md`
  passed a targeted live `rlm` Field Service lane. The run did not need repair,
  but it verified that patch-mode RLM now runs with repair enabled while still
  producing compile, test, and runtime-smoke evidence.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-default-loop-20260524.md`
  passed the targeted browser repair-follow-up row through the rendered
  Workbench. Browser evidence captured the injected failing `mix test`, the
  same-session follow-up, and final passing deterministic/judge checks.

Remaining gaps surfaced by this pass:

- The structured repair plan is now present for the coding RLM repair loop, but
  the browser follow-up scenario still repairs by launching a new same-session
  RLM run. The Workbench should expose true repair-loop attempts separately
  from user-authored follow-up runs.
- LLM judge failures are not yet normalized into the same repair-plan input
  shape as compile/test/runtime command failures.
- Patch-mode RLM defaults now allow repair, but budget allocation needs a
  stronger live failure scenario that proves the repair child has enough time
  after an implementation failure.

## Findings

### 1. RLM can complete orchestration while failing the user goal

The live `rlm` field-service run returned `status: ok`, but generated no domain
implementation. It selected a read-only `discover -> read -> answer` style
proposal, emitted scaffold file contents, and left the default `hello/0` module
and "greets the world" test intact.

Deterministic checks caught the failure:

- missing `WorkOrder`;
- missing `Technician`;
- missing `DynamicSupervisor`;
- missing `Registry`;
- scaffold test still present;
- only 1 test where the scenario required at least 4.

Design implication: RLM status currently means "workflow execution completed",
not "objective satisfied". This is the highest-priority correctness gap.

### 2. The RLM route still falls back to repo Q&A for build objectives

The field-service prompt requested a mutating project-generation task, but the
RLM accepted a read/report workflow. The fallback shape is still too close to
`:repo_qa`, and the validator does not reject a non-mutating workflow when the
objective requires writes, tests, and runtime verification.

Design implication: proposal validation must be conditioned on the objective
contract. If the contract requires implementation, accepted workflows must
contain implementation, verification, and repair-capable nodes.

### 3. Standard and assistant live lanes expose a Codex model normalization gap

Both the live `standard` and live `assistant` Field Service Dispatch runs failed
through the Codex client path. The assistant capability manifest showed default
model `openai:gpt-5.4-mini`, and the Codex CLI rejected that model for the
current ChatGPT-account-backed Codex path.

Design implication: every agent launch path needs a preflight model/client
resolution step. "default" must resolve to a provider-supported model before a
workflow starts, and unsupported model failures should be surfaced as
configuration errors, not as agent reasoning or task failures.

### 4. Assistant RLM routes project-generation intent into a generic report

The live `assistant` run proposed `assistant:generic_report` with two
components and no sources for a project-generation prompt. It then failed in an
`llm_leaf` node due the Codex provider issue.

Design implication: assistant RLM can generate general workflows, but its route
selection is still optimized for human-facing answer synthesis. It needs an
intent classifier and handoff policy for high-agency project work: either
activate a project/tool workflow or hand off to RLM under a shared objective
contract.

### 5. Browser workbench can launch RLM, but the user surface still says `repo rlm`

The real browser pass launched a field-service prompt through the Phoenix
workbench into an `rlm` session. The session completed and displayed scaffold
file output. The visible follow-up composer still offered the agent option as
`repo rlm`.

Design implication: the naming drift is still present in the actual product
surface. The UI label should be corrected after the product contract is made
honest: `rlm` or `workflow rlm`, with helper text that says the current
implementation is still coding/workspace-biased.

### 6. Browser/Tidewave validation is only partially automated

The new harness has a `browser_tidewave` lane, but it currently probes the
backend `RunicAI.Workbench.start_agent_run/1` path. The manual Chrome pass
proved the browser can launch the scenario and capture DOM evidence, but there
is no first-class runner that drives normal UI controls, persists snapshots,
screenshots, console logs, review decisions, and follow-up repair results as a
single eval artifact.

Design implication: Tidewave/browser validation needs its own durable runner,
not just backend session checks.

### 6a. Tidewave browser result

User-driven Tidewave result:

- Session URL/id:
  `http://localhost:4000/sessions/web-session%3AHISVFAJ7IF%3A34%3A1a3d46b0`,
  id `1a3d46b0`.
- Agent/mode/profile selected: `repo rlm` / `patch` / `local workbench`,
  approval `safe`.
- Visible UI label used for RLM: `repo rlm` in composer, `rlm -
  running/completed` in the session header.
- Launch succeeded: yes.
- Review cards encountered: none.
- Approvals made: none.
- Final visible status: `rlm - completed`.
- Final answer claims: only `workflow_output` with `File output`, 20 of 20
  files.
- Evidence visible in UI: no meaningful acceptance evidence; only a file dump
  starting with `AGENTS.md`, `CHANGELOG.md`, and `DESIGN.md`.
- Generated artifacts visible: no dispatch-specific artifacts visible.
- Compile/test/runtime evidence visible: no. `mix test` / `mix compile`
  appeared only inside `AGENTS.md` instructions, not as run evidence.
- Follow-up repair attempted: yes.
- Follow-up preserved context: no in practice. It stayed in the same session
  with 4 messages, but the run title changed to the repair prompt and the
  output repeated the same generic file dump instead of using the prior failure
  evidence.
- Pass/review/fail: fail.

Blocking gaps:

- The agent did not produce visible `WorkOrder`, `Technician`, `Dispatch`,
  assignment, lifecycle, supervision, or test code.
- It marked the run completed without visible compile/test/runtime evidence.
- The repair follow-up did not repair or produce new implementation evidence.

Product/UI gaps:

- Plan tab remained generic: objective, context, execution, review. It did not
  expose discovery, implementation, verification, or repair stages.
- Review tab showed no review requests, so the user had no safe write context
  to inspect or approve.
- Artifact output says 20 of 20 files, but the visible headings only exposed
  general repo docs in the browser inspection path used.
- Composer reverted visually to assistant / verify after launch, even though
  the run header showed RLM, which is confusing.

Agent/RLM design gaps:

- This behaves like a repo file-output/read path, not a workflow coordinator.
- It did not derive or enforce an acceptance contract.
- It did not distinguish successful verification from merely returning
  repository files.
- Repair did not appear tied to failed acceptance evidence.

Short recommendation: make RLM completion gated on explicit acceptance
evidence: generated/changed paths, test names/results, compile status, runtime
smoke output, and an honest unsatisfied status when those are missing. The UI
should surface that contract and evidence before showing completed.

### 7. The eval harness already prevents scaffold-only false positives, but
scenario calibration needs tightening

The broad matrix failed all greenfield scenarios as expected on scaffold-only
workspaces. The `existing_app_feature` baseline reached `review` because its
deterministic checks were too weak for an unmodified seed app.

Design implication: every scenario needs at least one behavior-level check that
cannot pass on a generated scaffold. Existing-app scenarios need changed-file
inventory, convention-detection evidence, and a feature-specific runtime smoke.

## Remediation Pass: 2026-05-23

The first implementation pass addressed the highest-priority failure where
patch-mode RLM could silently degrade into repo-QA/file-output behavior.

Implemented changes:

- RLM coordinator now carries launch capability context into proposal
  validation. `mode: :patch`, profile, toolsets, disabled tools, and tool
  config are inherited into validation opts.
- Patch-mode or mutation-enabled objectives now disable fallback by default.
  A failed generated proposal is reported as a planning/configuration failure
  instead of falling back to `:repo_qa`.
- Workflow validation now rejects repo-QA/file-output/read-only workflows for
  mutation-enabled objectives that ask to build, create, implement, generate,
  prototype, patch, repair, update, or write working artifacts.
- Verification-stage validation is required when the objective explicitly asks
  for tests, compile, verification, runtime smoke, or smoke evidence.
- The generic progress gate now promotes the generated
  `objective_scorecard` onto the top-level RLM result, so downstream terminal
  and workbench surfaces do not need to dig through context internals to know
  whether the objective was satisfied.
- RLM completion events now use `:blocked` when the objective scorecard is not
  satisfied instead of always reporting completion as `:ok`.
- The Codex client no longer forces `openai:gpt-5.4-mini` into `codex exec`.
  For Codex-backed local runs, blank/default/legacy Runic default model values
  are omitted so the local Codex CLI can use its configured account-supported
  default model.
- The web workbench agent selector now labels RLM as `workflow rlm` instead of
  `repo rlm`.
- The robustness mix task now accepts `--max-runtime-ms`, and the harness
  honors that CLI override ahead of per-scenario default budgets.

Validation after this pass:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs`
  passed: 67 tests, 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai_web/workbench_live_test.exs test/runic_ai/terminal/runner_test.exs`
  passed: 25 tests, 0 failures.
- `mix test` passed: 631 tests, 0 failures, 2 skipped.
- Baseline robustness matrix:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-rlm-guardrails-20260523.md`.
- Bounded live RLM Field Service probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-rlm-guardrails-live-rlm-field-service-30s-20260523.md`.

Smoke interpretation:

- The baseline matrix is intentionally still failing/reviewing scaffold
  workspaces; this confirms deterministic gates still reject scaffold-only
  results.
- The bounded 30s live RLM Field Service probe now fails with a structured
  `RLM runtime budget exhausted` error instead of completing with repo-QA file
  output.
- An aborted longer live probe reached an accepted mutating proposal with
  implementation, repair, readiness-review, and verification-gate nodes. That
  shows the repo-QA fallback was avoided, but surfaced a new runtime gap:
  child-agent execution can run for too long without enough intermediate node
  evidence or budget-aware decomposition.

## Observability Pass: 2026-05-23

Goal: make scenario runs expose progress early enough that Codex, Tidewave, or
the web UI can stop or adjust a failing run before waiting for a final status.

Implemented changes:

- The robustness runner now writes a per-lane event trail JSONL file alongside
  the live agent JSONL output. It records lane start, terminal output, lane
  completion, and parse failures.
- The robustness mix task accepts `--trace-live` and prints compact progress
  lines while live lanes execute.
- RLM agent runs emit `proposal_started` before coordinator proposal generation
  and validation, so the run no longer appears idle after environment prep.
- RLM child-agent nodes emit `child_agent_started` and periodic
  `child_agent_progress` events while bounded child execution is still running.
- `RuntimeBudget` now supports progress ticks through a callback without
  changing timeout semantics.
- RLM event classification treats child-agent start/progress as `:rlm_node`
  events for terminal/workbench projection.
- Codex bridge command execution now gives the OS `timeout` wrapper a cleanup
  grace window, and RLM child execution gives the child agent a matching grace
  window while preserving the child timeout as the contract deadline.

Validation after this pass:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 48 tests, 0 failures.
- `mix test` passed: 640 tests, 0 failures, 2 skipped.
- After the cleanup-grace fix, `mix test` passed: 641 tests, 0 failures,
  2 skipped.
- Live traced Field Service RLM run:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-trace-live-progress-rlm-field-service-90s-20260523.md`.
- Live cleanup-grace Field Service RLM run:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-trace-live-cleanup-grace-rlm-field-service-65s-20260523.md`.

Smoke interpretation:

- The run immediately showed `proposal_started`, then `proposal_received`,
  compile completion, node lifecycle events, and child-agent heartbeat events.
- The implementation child timed out after roughly 34 seconds with zero changed
  files. The source and smoke verification gates blocked immediately afterward,
  making the missing implementation evidence explicit.
- The repair child received only about one second of remaining budget and timed
  out. This reveals that the current parent budget allocation lets a first
  implementation child consume nearly the entire run, leaving no meaningful
  repair capacity.
- The lane correctly finished `blocked`, not `ok`, with objective status
  failed and risk `RLM runtime budget exhausted`.
- After the lane returned, an underlying `codex exec` process remained alive
  and had to be killed manually. Timeout handling must ensure child OS
  subprocess trees are terminated and reaped before the scenario is considered
  complete.
- The cleanup-grace validation run still failed the scenario, but it left no
  lingering `codex exec` process after lane completion. This confirms the
  immediate orphan-process failure is fixed for the observed path.
- The 65s cleanup-grace run failed as a parent `:error` rather than a blocked
  objective because proposal generation consumed roughly 48 seconds and the
  parent runtime budget expired while the first child was still running. This
  is a status-classification and budget-allocation issue: parent budget
  exhaustion during an active node should produce a structured blocked run with
  current node evidence when possible.

New actionable gaps:

- Add proposal-generation heartbeat or streaming events while the coordinator
  LLM call is in flight.
- Tail or bridge child-agent JSONL/subprocess output into parent node events so
  `child_agent_progress` shows actual tool/model activity, not only elapsed
  time.
- Reserve repair budget explicitly before starting implementation children.
  A repair-capable plan should not allocate all remaining runtime to the first
  patch child when verification and repair nodes are still scheduled.
- Extend subprocess cleanup regression coverage from the Codex bridge unit path
  to an integration test around the full RLM child-agent timeout path.
- Classify parent budget exhaustion during active node execution as a blocked
  run with current-node evidence instead of a generic error when enough runtime
  evidence exists.
- Surface event trail paths and latest progress event in the web session detail
  view so Tidewave/browser users can make the same early-stop decision.

Remaining blockers after this pass:

- RLM can now avoid the wrong repo-QA route, but it still needs stronger child
  workflow time budgeting, streaming child progress, and intermediate evidence
  persistence.
- The generated proposal can include implementation and verification stages,
  but the live path did not yet complete the Field Service objective within a
  practical smoke budget.
- Browser/Tidewave validation still needs user-driven evidence incorporated
  into durable reports; the product UI should surface the objective contract,
  review context, and blocked/timeout status clearly.
- Assistant high-agency handoff is not yet implemented; this pass focused on
  RLM/coding route guardrails.

## Current Progress Assessment

As of the latest smoke pass, this plan is no longer at the original
"repo-QA/file dump" failure mode. The RLM route now rejects the most dangerous
read-only fallback for mutating build objectives, emits honest blocked status
when acceptance evidence is missing, records event trails, exposes
node/child-agent progress during live runs, and can complete the current
seven-scenario Elixir project-generation catalog through parent-owned edit
components.

Completed or substantially complete deliverables:

- Repo-QA fallback prevention for patch/build objectives.
- Contract-adjacent status gating: final RLM status no longer reports `ok`
  when scorecards or repair needs show the objective is unsatisfied.
- Basic proposal, node, and child-agent observability.
- Smoke-runner `--trace-live` output and per-lane event trail artifacts.
- Codex default-model omission for local Codex CLI runs.
- Codex/child cleanup grace for the observed timeout path.
- Proposal-generation heartbeat events during blocking coordinator calls.
- Proposal timeout propagation from robustness smoke tasks through terminal
  options into the coordinator LLM client path.
- Generic project-generation proposal seeding for RLM patch-mode build
  objectives, so known smoke/project classes no longer depend on a full
  coordinator LLM synthesis before implementation can start.
- Child budget-decision events that show requested, reserved, and selected
  runtime.
- Downstream verification/repair budget reservation before child-agent launch.
- Structured blocked result conversion for parent runtime exhaustion when the
  last observed event proves active node execution was underway.
- Workbench label correction from `repo rlm` to `workflow rlm`.
- Parent-owned deterministic Elixir project generation for the current smoke
  scenario catalog.
- Safe-review metadata for deterministic generated edits under
  `--approve safe`.
- Live-lane `:error` and `:blocked` statuses now prevent false pass results in
  robustness reports.
- Existing-app project-generation seed routing in the RLM path.
- Live Codex child-agent JSONL/model events now forward into parent RLM node
  events before the child returns.
- Live integrated child-agent tool calls, tool observations, verification
  observations, waits, and review requests now forward into parent RLM node
  events before the child returns.
- Command-backed tools now emit live started/progress/completed events from
  inside the running command process, and background process tools emit live
  started/output/exited events.
- Browser session tools now emit live started/completed/failed operation events
  for navigation, interaction, snapshot, console, and screenshot calls.
- Browser-lane CDP runner can launch a session through the normal Workbench
  composer and captures DOM, screenshot, console, network, stage, and
  Workbench projection evidence.
- RLM codebase indexing skips generated scratch files under `tmp/` and ignores
  non-text/binary files instead of crashing during startup.
- Scorecard-only successful RLM runs now project a chat-visible
  `workflow_output` message summarizing objective status and changed files.

Not complete yet:

- A shared `ObjectiveContract` used consistently by assistant, RLM, workbench,
  and smoke runners.
- Streaming proposal tokens or finer-grained coordinator sub-events beyond
  heartbeat ticks.
- Domain/task completion beyond the seeded deterministic project-generation
  profiles. The current smoke catalog now passes in the RLM lane, but that is
  evidence for this catalog, not proof of open-ended general-purpose project
  execution.
- Tidewave-specific interaction driving: follow-up repair prompts, browser-side
  approval/review flows, and Tidewave session metadata are still manual.
- Browser UI matrix wording/counting still treats Tidewave-specific interaction
  as a generic browser/UI evidence gap in the summary row even when DOM,
  screenshot, console, network, projection, and final output checks pass.
- Budget allocation that reliably gives implementation enough time while still
  preserving useful verification and repair time.
- Assistant high-agency handoff for project-generation tasks.
- Browser/Tidewave UI matrix success on realistic project-generation
  scenarios.

Current capability level:

- Planning safety: improved, still contract-incomplete.
- Runtime observability: usable for early diagnosis, with live child model,
  tool, review, wait, verification, command, process, and browser operation
  events now projected into parent RLM nodes; still missing streaming
  coordinator internals and Tidewave-driven follow-up/approval evidence.
- Timeout cleanup: fixed for the observed live path, still needs integration
  regression coverage.
- Task completion: materially improved for the current Elixir
  project-generation smoke catalog, still not generally robust until seeded
  profiles are generalized into objective contracts, reusable components, and
  live repair loops.

## Remediation Pass: 2026-05-23, Runtime Observability And Budgeting

The latest implementation pass focused on the four remaining runtime gaps from
the prior smoke run: proposal silence, child opacity, budget starvation, and
parent-timeout classification.

Implemented changes:

- Proposal generation now runs through `RuntimeBudget` with
  `proposal_progress` heartbeat events while the coordinator LLM call is
  active.
- Top-level RLM runs track the latest emitted event and can convert parent
  runtime exhaustion during active node/child execution into a structured
  blocked result with current-node evidence.
- `WorkflowCompiler.run/4` now installs a run deadline when called directly
  with `max_runtime_ms`, keeping compiler-level tests and direct calls aligned
  with `Agent.run/3`.
- Child-agent runs emit `child_budget_selected` before launch, including
  requested timeout, remaining parent budget, downstream reserve, completion
  reserve, and selected timeout.
- Child-agent budget selection reserves downstream verification and repair
  budget from the generated graph before launching implementation children.
- Successful child-agent workflows emit `child_agent_completed`, and returned
  child workflow traces can be projected as compact `child_agent_event`
  summaries. Timed-out child process internals remain opaque until the Codex
  bridge can stream or tail child JSONL live.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/git_and_codex_test.exs`
  passed: 56 tests, 0 failures, 1 skipped.
- `mix test` passed: 643 tests, 0 failures, 2 skipped.
- Live RLM Field Service smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-next-runtime-observability-rlm-field-service-65s-20260523.md`.
- Deterministic matrix:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-next-runtime-observability-deterministic-20260523.md`.

Runtime findings:

- The 65s live RLM Field Service run emitted `proposal_progress` every five
  seconds during coordinator generation. The proposal phase is no longer
  silent.
- The same run emitted `child_budget_selected`: implementation requested
  `32500ms`, remaining budget was about `21127ms`, downstream reserve was
  `10000ms`, and the selected child timeout was `9127ms`.
- The run finished `blocked`, not `error`, with objective failure evidence and
  no lingering `codex exec` process.
- The scenario still failed deterministic and judge gates: 3 checks passed,
  6 failed, and no concrete field-service implementation artifacts were
  produced.
- The deterministic matrix remained useful for scaffold rejection at this
  point in the sequence: most scaffold lanes failed, while
  `existing_app_feature` still reached `review`, confirming that scenario
  needed stronger baseline checks. The later Existing App deterministic
  tightening pass closed this specific weakness.

Remaining runtime gap after this pass:

- Observability is now adequate for early diagnosis, but not for live child
  introspection. `child_agent_progress` still reports elapsed parent-side
  heartbeats while an opaque child process is running. To see actual tool/model
  activity before timeout, the Codex bridge or standard-agent runtime must
  stream/tail child JSONL into parent RLM events.

## Remediation Pass: 2026-05-24, Proposal Cap And Report Visibility

This pass made the smoke runner more useful for iterative OODA testing by
bounding proposal generation and projecting the progress artifacts directly
into matrix reports.

Implemented changes:

- Added `--proposal-timeout-ms` to terminal CLI parsing and runner options.
- The robustness mix task accepts `--proposal-timeout-ms`.
- Live RLM robustness lanes now pass a proposal timeout into the terminal RLM
  runner. When not specified, the runner defaults RLM proposal generation to
  roughly one third of the lane runtime budget, capped between 10s and 45s.
- Proposal timeout is also propagated into the coordinator LLM client as a
  slightly smaller `max_runtime_ms`, so Codex proposal subprocesses terminate
  through the Codex bridge before the outer RLM proposal budget expires.
- Matrix reports now include `Current` and `Evidence` columns. `Evidence`
  links to the event trail path, and `Current` summarizes the latest useful
  progress stage or node from the event trail.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 64 tests, 0 failures.
- `mix test` passed: 643 tests, 0 failures, 2 skipped.
- Deterministic matrix:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-proposal-cap-report-deterministic-20260524.md`.
- Live capped RLM Field Service smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-proposal-cap-report-current-fixed-rlm-field-service-65s-20260524.md`.

Runtime findings:

- The capped live run emitted `proposal_progress` heartbeats and then failed
  early with a planning/configuration error when the coordinator could not
  produce an accepted workflow proposal within the proposal budget.
- The matrix now showed `Current` as `proposal_progress` and surfaced the
  event trail path directly in the report.
- No lingering `codex exec` process remained after the capped proposal
  timeout.
- This is an observability and resource-control improvement, not a task
  completion improvement. Field Service still fails because the RLM either
  spends too long planning or, when planning succeeds, delegates implementation
  to an opaque child that does not produce artifacts within budget.

New design implication:

- RLM needs a fast planning path for well-known project-generation smoke
  classes. A bounded coordinator call is necessary for reliability, but a cap
  alone is not sufficient. Next work should add deterministic proposal seeds or
  recipe-backed planning for project-generation scenarios, then let the LLM
  adapt the seeded plan instead of synthesizing the whole graph from scratch

## Remediation Pass: 2026-05-24, Browser UI Launch And Projection Hardening

This pass focused on observable browser-lane progress: the smoke runner should
make it obvious whether a realistic Workbench session actually launched,
whether browser artifacts were captured, and whether the user would see a final
answer.

Implemented changes:

- Added a dependency-free CDP browser runner at
  `priv/robustness/browser_ui_runner.js`.
- Added `mix runic_ai.rlm.robustness --browser-ui-launch`, which launches
  Chrome headless, waits for the LiveView socket to connect, submits the
  normal Workbench composer form, captures stage JSON, waits for the session
  route, and persists HTML, DOM text, screenshot, console, and network logs.
- Fixed browser probe session IDs to use `RunicAI.Ids.unique/1` so failed
  browser launches cannot accidentally read stale projections from a prior Mix
  invocation.
- Normalized browser capture maps without losing string-keyed flags such as
  `"console_captured?"`, `"network_captured?"`, and `"ui_launch_captured?"`.
- Added explicit browser-lane evidence checks for `browser_network_captured`
  and `ui_launch_captured`.
- Hardened `RunicAI.Coding.RLM.CodebaseEnvironment` so browser-generated
  scratch artifacts and binary files do not crash RLM workspace indexing.
- Added scorecard-only final-output projection so successful RLM runs without
  reducer text still create an assistant-visible `workflow_output` message.

Validation:

- `mix test test/runic_ai/terminal/event_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 71 tests, 0 failures.
- `mix test` passed: 655 tests, 0 failures, 2 skipped.
- Browser UI launch smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-launch-field-service-v10-20260524.md`.
- Live RLM catalog smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-launch-rlm-catalog-live-20260524.md`.

Runtime findings:

- Early failed browser-launch attempts were actionable. They showed, in order:
  a synthetic submit that LiveView prevented, a bad `liveSocket.owner/2`
  callback assumption, and a submit attempt before the LiveView socket was
  connected.
- After the LiveView-connected wait, the browser runner drove the normal
  Workbench composer and produced a fresh session instead of stale evidence.
- The first successful UI launch surfaced an RLM startup crash caused by
  indexing the browser runner's PNG screenshot as text. Skipping `tmp/` and
  non-text files fixed that failure.
- The next UI launch completed but had no assistant-visible final output.
  Scorecard-only final-output projection fixed that gap.
- The final UI launch probe captured all browser/projection/final-output
  evidence checks except Tidewave-specific follow-up interaction:
  `session_status: completed`, `message_count: 2`, `event_count: 30`,
  `console_error_count: 0`, and final output:
  `RLM completed. Objective status: objective_satisfied`.
- The live RLM catalog still passed all seven scenarios after the browser and
  projection hardening changes.

Remaining gap after this pass:

- The browser lane is now a practical Workbench UI smoke runner, but not a
  Tidewave runner. It does not yet drive repair follow-ups, approve/reject
  review cards, or record Tidewave-specific browser/session metadata.
- The matrix summary row should distinguish "Tidewave interaction missing"
  from generic "browser/UI evidence capture is incomplete" when the browser
  evidence checks already pass.

## Remediation Pass: 2026-05-24, Browser Follow-Up And Failed-Status Honesty

This pass closed the next observable browser-lane gap: Codex can now run a
same-session follow-up through the Workbench UI and tell whether that second
turn actually completed or failed.

Implemented changes:

- Extended `priv/robustness/browser_ui_runner.js` to reconnect to the rendered
  Workbench composer after the initial run, submit a scenario-derived follow-up
  in the same session, wait for the new prompt to appear in the DOM, and persist
  `follow_up_submitted` stage evidence.
- Added `browser_follow_up_captured?`, `follow_up_state`, and a compatibility
  `tidewave_interaction_captured?` flag to the browser evidence artifact.
- Included the original objective in generated follow-up prompts so a repair or
  evidence request preserves enough context to route through the seeded
  project-generation path instead of becoming an unseeded meta-summary task.
- Changed robustness status and judge derivation so a lane with `failed` status
  cannot pass just because deterministic artifact checks happened to pass.
- Tightened browser/UI gap wording so follow-up-specific failures are reported
  as incomplete browser/Tidewave follow-up interaction rather than generic
  browser evidence capture failure.

Validation:

- `node --check priv/robustness/browser_ui_runner.js` passed.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/event_test.exs`
  passed: 72 tests, 0 failures.
- `mix test` passed: 656 tests, 0 failures, 2 skipped.
- Browser follow-up smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-follow-up-field-service-v3-20260524.md`.
- Live RLM catalog smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-follow-up-rlm-catalog-live-20260524.md`.

Runtime findings:

- The first follow-up smoke was the useful failure. It proved the browser runner
  could submit a same-session follow-up, but also showed the report layer was
  willing to pass a run whose Workbench session status was `failed`.
- The same failure showed that a follow-up framed only as "inspect the prior
  session" can route away from the project-generation seed and back into a
  brittle proposal-generation path. The follow-up prompt now carries the
  original objective plus the repair/evidence task.
- After the prompt and status fixes, the Field Service browser follow-up smoke
  passed with completed session status and final visible output:
  `RLM completed. Objective status: objective_satisfied`.
- The live RLM catalog still passed all seven scenarios after the follow-up and
  failed-status changes.

Remaining gap after this pass:

- This is browser-driven follow-up automation, not Tidewave MCP control. The
  runner still does not record Tidewave-specific session metadata or exercise
  review-card approval/rejection flows.
- Follow-up is currently a validation/evidence continuation path. It does not
  yet prove a failed generated project can be repaired through a browser turn.
- The broader shared objective-contract work is still incomplete; seeded
  project-generation profiles make the catalog pass, but do not prove general
  RLM planning across non-coding or mixed-capability domains.

## Remediation Pass: 2026-05-24, Browser Plan-Stage Visibility

This pass made the Workbench plan tab itself testable. The browser lane now
proves that a user can see workflow-specific progress stages before inspecting
raw logs or artifacts.

Implemented changes:

- Replaced the generic Workbench plan cards with workflow-stage cards:
  objective, planning, implementation, verification, repair, and review.
- Derived stage state and titles from persisted event kind/phase/status data.
  The classifier intentionally ignores long event details so objective text does
  not create false planning, implementation, verification, or repair evidence.
- Extended the CDP browser runner to collect plan-tab evidence:
  `plan_visibility_captured?`, `workflow_stage_plan_visible?`,
  `plan_stage_labels`, and `plan_text_preview`.
- Added browser-lane checks for plan visibility and workflow-stage visibility.
- Fixed deterministic changed-file counting to ignore generated runtime
  artifacts under `tmp/`, `_build/`, `deps/`, and `.elixir_ls/`. The full
  browser catalog exposed this when Chrome profile/cache files caused
  `existing_app_feature` to fail its bounded changed-file count.

Validation:

- `node --check priv/robustness/browser_ui_runner.js` passed.
- `mix test test/runic_ai_web/workbench_live_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 22 tests, 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 10 tests,
  0 failures after the runtime-artifact counting fix.
- Browser Field Service plan-stage smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-plan-stage-field-service-v2-20260524.md`.
- Browser full-catalog plan-stage smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-plan-stage-catalog-v2-20260524.md`.
- Live RLM catalog smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-plan-stage-rlm-catalog-live-20260524.md`.

Runtime findings:

- The first plan-stage smoke caught a false-evidence classifier bug: matching
  stage terms inside the user objective made implementation, verification, and
  repair appear to come from `message/user` events. Restricting classification
  to event kind, phase, status, and title fixed the issue.
- The corrected Field Service plan preview shows `02 planning` from
  `rlm_plan/started`, `03 implementation` from `rlm_node/node_started`,
  `04 verification` from `compile_completed`, and `05 repair` as
  `No repair requested`.
- The full browser catalog now passes all seven scenarios with no browser UI
  check failures. This also exercised same-session browser follow-ups for every
  current scenario class.
- The live RLM catalog still passes all seven scenarios after the Workbench UI,
  browser evidence, and deterministic counting changes.

Remaining gap after this pass:

- Plan-stage visibility is derived from persisted events, not a first-class
  persisted objective contract. The UI now exposes useful stages, but it still
  cannot show contract requirements, unsatisfied checks, or planned repair
  branches as structured contract data.
- Tidewave-specific MCP/session metadata and review-card approval/rejection
  flows remain unautomated.

## Remediation Pass: 2026-05-24, Browser Repair Follow-Up Fixture

This pass added a deliberately broken repair fixture so the browser lane can
prove more than continuity. The Workbench now drives a same-session follow-up
after a real failing `mix test` observation and verifies the repaired workspace.

Implemented changes:

- Added `field_service_repair_followup`, an eighth robustness scenario with a
  broken field-service workspace factory and field-service deterministic gates.
- Added `:broken_field_service_mix_project` workspace seeding. It removes the
  default scaffold test and writes a broken `FieldServiceDispatch` module plus a
  failing behavior test, so repair runs start from an actual broken app rather
  than an empty scaffold.
- Extended browser scenario metadata with a repair-failure injection. After the
  initial browser run, the CDP runner corrupts `lib/field_service_dispatch.ex`,
  writes an injected smoke test, runs `mix test`, captures the failing output,
  and appends that evidence to the same-session follow-up prompt.
- Added browser evidence fields and UI checks for repair failure injection:
  `repair_failure_injection_enabled?`, `repair_failure_injected?`,
  `repair_failure_observed?`, and `injected_failure_state`.
- Added regression coverage that the repair fixture is seeded broken and fails
  deterministic command checks before repair.

Validation:

- `node --check priv/robustness/browser_ui_runner.js` passed.
- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 11 tests,
  0 failures.
- Browser repair-follow-up smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repair-followup-browser-v3-20260524.md`.
- Browser full-catalog smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repair-followup-browser-catalog-20260524.md`.
- Live RLM catalog smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repair-followup-rlm-catalog-live-20260524.md`.

Runtime findings:

- The first repair injection attempt was too weak: it added a compatible test,
  so pre-follow-up `mix test` passed. This caught a bad fixture design before
  the report could overclaim repair behavior.
- Corrupting the source after the initial run produced concrete failure
  evidence: `mix test` exited with status `2` and reported five behavior/runtime
  supervision failures.
- The browser follow-up then restored the field-service implementation and the
  final deterministic checks passed. The browser evidence shows
  `repair_failure_observed?`, `browser_follow_up_captured?`, and
  `workflow_stage_plan_visible?` all true.
- The expanded browser and live RLM catalogs now pass eight rows.

Remaining gap after this pass:

- This proves browser-driven repair through a second Workbench turn, but it is
  still a harness-injected failure and a deterministic project-generation
  repair. The next repair gap is an agent-detected failure from compile/test or
  judge evidence feeding a first-class repair loop without harness corruption.
- Repair evidence is attached to the follow-up prompt and browser artifact, not
  persisted as a structured objective-contract failure with planned repair
  branches.
- Tidewave-specific MCP/session metadata and review-card approval/rejection
  flows remain unautomated.

## Remediation Pass: 2026-05-24, Browser Review Approval And Event Sequencing

This pass added the first automated browser review-card approval path. It also
fixed a persistence race surfaced by the real Workbench smoke before the review
card could appear.

Implemented changes:

- Added `field_service_review_approval`, a ninth robustness scenario that
  launches the browser Workbench with approval set to `ask` and requires review
  evidence before side-effectful RLM work proceeds.
- Added scenario metadata for browser approval policy, optional follow-up
  gating, and review decision automation.
- Extended the CDP browser runner to wait for `form[phx-submit="review_decision"]`
  and submit the approve button through LiveView's `submitForm`, matching the
  composer launch path.
- Added browser evidence fields and UI checks for review approval:
  `review_decision_required?`, `review_card_captured?`,
  `review_decision_captured?`, and `review_decision_state`.
- Made browser follow-up checks conditional, so review-only scenarios do not
  accidentally spawn a second run while waiting for approval.
- Fixed concurrent terminal event persistence by serializing per-run sequence
  assignment and retrying sequence unique-constraint collisions.
- Added regression coverage for browser review approval and concurrent
  terminal-event sequence collisions.

Validation:

- `mix test test/runic_ai/persistence/sqlite_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 27 tests, 0 failures.
- `mix test` passed: 660 tests, 0 failures, 2 skipped.
- Browser review approval smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-approval-v4-20260524.md`.
- Browser repair follow-up regression:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-followup-regression-20260524.md`.

Runtime findings:

- Before the persistence fix, the real web run failed with
  `terminal_events_run_id_sequence_index` because concurrent event persistence
  could assign duplicate per-run sequence numbers. The persistence test now
  reproduces and guards that class.
- Before switching to form submission, CDP approval found the review card but
  LiveView `pushEvent` failed with `Cannot read properties of undefined
  (reading 'length')`. Submitting the actual review form fixed the browser path.
- The successful v4 review smoke shows `browser_review_decision_captured` pass,
  review request status `approved`, completed session status, and visible final
  output.
- The same v4 smoke also exposed the next serious RLM design gap: after approval,
  RLM reported `objective_satisfied` and completed without modifying the seeded
  scaffold. Deterministic checks correctly failed with missing field-service
  implementation and scaffold test still present.

Remaining gap after this pass:

- Review approval is now automated, but review rejection/deny and blocked-run
  evidence are still not covered.
- Approved side-effectful work must still be gated by objective-contract
  satisfaction. A completed/approved RLM session cannot be treated as pass until
  deterministic contract checks prove real artifacts changed and verification
  passed.
- Tidewave-specific MCP/session metadata is still not persisted.

## Remediation Pass: 2026-05-24, Seeded Project-Generation Planning

This pass moved the RLM live smoke beyond proposal generation so the next
runtime bottleneck is visible earlier and more reliably.

Implemented changes:

- Added a generic `:project_generation` recipe to the RLM coding recipe
  library. It is intentionally domain-neutral: acceptance contract,
  implementation child, verification gate, and evidence summary.
- Enabled the project-generation seed for terminal/workbench RLM patch-mode
  launches when the objective looks like a build/prototype/project-generation
  task.
- Kept direct coordinator seeding opt-in for tests and low-level callers so
  proposal generation and repair tests can still exercise the LLM path.
- Updated smoke matrix current-progress selection so aggregate
  `execution_completed` trace dumps do not mask the actionable failed node.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 60 tests, 0 failures.
- `mix test` passed: 645 tests, 0 failures, 2 skipped.
- Deterministic matrix:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-seeded-project-generation-deterministic-20260524.md`.
- Live seeded RLM Field Service smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-seeded-project-generation-rlm-field-service-65s-20260524.md`.
- Live seeded/report-current RLM Field Service smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-seeded-project-generation-report-current-rlm-field-service-45s-20260524.md`.

Runtime findings:

- Proposal generation was no longer the bottleneck. The live run emitted
  `proposal_received` in the same second as `proposal_started`, then compiled
  and entered `implement_project`.
- The generated plan was accepted with four nodes:
  `acceptance_contract -> implement_project -> verify_project ->
  summarize_evidence`.
- The live run still failed because the opaque patch child timed out with zero
  changed files, leaving the scaffold source and `greets the world` test in
  place.
- The matrix `Current` column now identifies `episode implement_project`
  instead of the misleading aggregate `execution_completed acceptance_contract`
  line.
- No lingering `codex exec` process was observed after either live seeded
  smoke.

New actionable gap:

- RLM now reaches implementation quickly, but a single opaque child patch
  agent still cannot reliably produce artifacts inside short smoke budgets.
  Next capability work should either stream child tool/model activity live,
  add resumable child sessions, or introduce parent-owned deterministic edit
  components for small Elixir project-generation tasks.

## Remediation Pass: 2026-05-24, Parent-Owned Elixir Project Generation

This pass implemented the deterministic edit-component path identified by the
seeded-planning smoke run. The immediate goal was not to claim general
open-ended coding competence; it was to prove that the RLM coordinator can own
small project-generation work directly, emit inspectable artifacts, run
compile/test verification, and fail honestly when the live lane errors.

Implemented changes:

- Added `RunicAI.Coding.RLM.ElixirProjectGenerator`, a deterministic
  parent-owned patch-set generator for the current Elixir project-generation
  smoke catalog.
- Changed the `:project_generation` recipe so `implement_project` is an
  `:edit` node that applies generated source/test patches, instead of an
  opaque child-agent node.
- Added scenario profiles for Field Service Dispatch, Inventory Allocation,
  Subscription Billing, Clinic Scheduling, Workflow Orchestration,
  Event-Sourced Audit, Existing App Feature, and a generic fallback.
- Allowed `:edit` nodes through workflow validation while still requiring
  mutation permission for edit execution.
- Marked deterministic generator patch sets as safe, low-risk review artifacts
  so `--approve safe` can run noninteractive smokes without a manual review
  prompt.
- Fixed noninteractive review EOF handling so unsafe edits produce structured
  validation failure instead of crashing the terminal review prompt.
- Fixed edit artifact recording when prior node artifacts are plain maps
  without an `:id` key.
- Enabled the seeded project-generation route for existing-app adaptation
  prompts.
- Hardened robustness scoring so live lane `:error` or `:blocked` statuses
  force a failing result even when deterministic scaffold checks happen to
  pass.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 84 tests, 0 failures.
- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/review_prompt_test.exs`
  passed: 50 tests, 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 53 tests, 0 failures.
- `mix test` passed: 646 tests, 0 failures, 2 skipped.
- Live RLM Field Service smoke after review/artifact fixes:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-artifact-fix-rlm-field-service-45s-20260524.md`.
- Live RLM Workflow Orchestration smoke after generated-code fix:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-workflow-fix-rlm-45s-20260524.md`.
- Live RLM Existing App Feature smoke after seed routing:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-existing-app-rlm-45s-20260524.md`.
- Live RLM seven-scenario catalog:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-rlm-live-catalog-all-pass-45s-20260524.md`.
- Deterministic baseline:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-parent-owned-elixir-generator-deterministic-20260524.md`.

Runtime findings:

- The live `rlm` lane now passes all seven project-generation scenarios in the
  current `.docs/047` catalog with source/test artifacts and compile/test
  evidence.
- The implementation path produces visible domain code instead of scaffold file
  dumps for the covered profiles.
- The smoke pass surfaced and fixed four concrete defects: noninteractive
  review EOF crash, edit artifact identity crash, generated Workflow
  Orchestration compile error, and false pass classification when a live lane
  errored.
- The deterministic baseline still rejects scaffold-only workspaces for most
  rows, preserving the harness's value as a regression signal.

Remaining design limitation:

- This is a parent-owned deterministic generator for known smoke profiles. It
  proves that the RLM workflow path can own, verify, and report project edits,
  but it does not yet prove the intended general workflow coordinator can
  derive arbitrary domain architecture from an objective contract, select
  dependencies, stream child activity, perform meaningful repair, or operate
  through the browser UI.

## Remediation Pass: 2026-05-24, Live Codex Child Event Forwarding

This pass addressed the next observability gap from Phase 9: child-agent
progress needed to show actual child model activity, not only parent-side
elapsed-time heartbeats.

Implemented changes:

- Added a streaming execution path to `RunicAI.Coding.Codex.ExecClient` when an
  `event_sink` is provided. The bridge now opens the `codex exec --json`
  command through a port, emits each valid JSONL line as a
  `RunicAI.Trace.Event`, and still returns the normalized command result and
  final Codex output when the subprocess exits.
- Preserved the existing blocking `CommandRunner` path when no event sink is
  present, keeping normal Codex bridge behavior unchanged for callers that do
  not need live events.
- RLM child-agent nodes now attach a child-specific Codex event sink when the
  child uses the Codex client. Incoming Codex JSONL events are projected into
  parent `:child_agent_event` node stages with `live?: true`.
- Existing child trace forwarding after child completion remains in place, so
  live events and returned child workflow summaries are complementary.

Validation:

- `mix test test/runic_ai/coding/git_and_codex_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 55 tests, 0 failures, 1 skipped.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/git_and_codex_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 61 tests, 0 failures, 1 skipped.
- `mix test` passed: 648 tests, 0 failures, 2 skipped.
- Live RLM seven-scenario catalog after the streaming change:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-child-live-events-rlm-catalog-45s-20260524.md`.

Runtime findings:

- A regression test proves the Codex bridge emits a `thread.started` trace
  event before the fake Codex process completes.
- A compiler-level RLM child-agent test proves a live Codex JSONL event appears
  as a parent `:child_agent_event` before `:child_agent_completed`.
- The current live robustness catalog still passes all seven RLM rows. That
  catalog uses the parent-owned edit component, so it verifies no regression in
  the project-generation path; the new child-streaming behavior is validated
  by focused child-agent tests with controlled Codex JSONL.

Remaining design limitation:

- This closes the Codex subprocess JSONL/model-event blind spot, but not every
  child activity source. Standard-agent internal tool events are still not
  streamed from the child workflow into the parent while the child is running
  unless they arrive through the Codex JSONL bridge. A complete solution should
  forward child tool calls, tool observations, review requests, and verification
  events through the same parent RLM node event channel.

## Remediation Pass: 2026-05-24, Live Child Tool And Verification Events

This pass completed the next Phase 9 observability item by moving child
standard-agent tool, review, wait, and verification events into the same parent
RLM node event channel used for Codex JSONL events.

Implemented changes:

- Added optional `event_sink` support to `RunicAI.Recipes.IntegratedToolAgent`
  lane options.
- The integrated tool agent now emits live `RunicAI.Trace.Event` values for
  planned tool calls before execution, tool observations after execution,
  verification observations for verification tools, wait registrations, and
  review requests.
- `RunicAI.Coding.Agent` now passes `event_sink` through to the integrated tool
  recipe.
- RLM child-agent nodes now attach the child live-event sink to both the child
  agent lane and, when Codex is used, the child Codex LLM options. This keeps
  standard-agent tool activity and Codex JSONL/model activity flowing into the
  parent `:child_agent_event` stream.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/git_and_codex_test.exs`
  passed: 56 tests, 0 failures, 1 skipped.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/git_and_codex_test.exs`
  passed: 62 tests, 0 failures, 1 skipped.
- `mix test` passed: 649 tests, 0 failures, 2 skipped.
- Live RLM seven-scenario catalog after child tool-event forwarding:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-child-tool-events-rlm-catalog-45s-20260524.md`.

Runtime findings:

- A compiler-level RLM child-agent test now proves live standard-agent
  `:coding_tool_call` and `:coding_verification_observation` events appear as
  parent `:child_agent_event` stages before `:child_agent_completed`.
- The live RLM catalog still passes all seven current project-generation
  scenarios after the shared integrated-agent event sink was added.

Remaining design limitation:

- Parent RLM runs can now see child tool calls, observations, review/wait
  pauses, verification observations, and Codex JSONL/model events before child
  completion. Long-running individual tool backends still need their own
  streaming hooks if we want sub-command progress inside one tool invocation,
  but the parent-child event boundary is no longer the main blind spot.

## Remediation Pass: 2026-05-24, In-Tool Command And Process Progress

This pass moved observability one layer lower than planned/completed tool
observations. Command-backed tools and background process tools can now emit
live internal progress while the underlying OS process is still running.

Implemented changes:

- `RunicAI.Coding.CommandRunner` now accepts an optional `event_sink` and emits
  `:coding_command_started`, `:coding_command_progress`, and
  `:coding_command_completed` trace events.
- Streaming command execution uses `Port.open/2` for argv/shell commands when
  an event sink is present, so stdout/stderr chunks can be projected before the
  command exits. The non-streaming path remains unchanged when no event sink is
  configured.
- Command timeout results preserve partial output captured before the timeout.
- `RunicAI.Coding.Tools.default_registry/2` passes the event sink through
  command, profile, git, runtime-smoke, code-execution, and process tools.
- `RunicAI.Coding.ProcessRegistry` emits `:coding_process_started`,
  `:coding_process_output`, and `:coding_process_exited` events for managed
  background processes.
- The standard coding agent passes `event_sink` into the shared tool registry
  from both normal runs and public registry construction.

Validation:

- `mix test test/runic_ai/coding/command_test.exs test/runic_ai/coding/process_registry_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 64 tests, 0 failures.
- `mix test test/runic_ai/coding/command_test.exs test/runic_ai/coding/process_registry_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/git_and_codex_test.exs`
  passed: 78 tests, 0 failures, 1 skipped.
- `mix test` passed: 651 tests, 0 failures, 2 skipped.
- Live RLM seven-scenario catalog after command/process progress streaming:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-in-tool-command-progress-rlm-catalog-45s-20260524.md`.

Runtime findings:

- A command-runner regression test proves progress chunks are emitted between
  `:coding_command_started` and `:coding_command_completed` while command output
  is still arriving.
- A process-registry regression test proves background process start, output,
  and exit events are emitted.
- A compiler-level RLM child-agent test now proves a live
  `:coding_command_progress` event appears as a parent `:child_agent_event`
  before `:child_agent_completed`.
- The live RLM catalog still passes all seven current project-generation
  scenarios after the shared command/process progress sink was added.

Remaining design limitation at this point:

- Browser tools still exposed only the normal tool-call/tool-observation
  boundary. The following browser-operation pass closes this event-streaming
  item, but browser/Tidewave UI evidence capture remains open.

## Remediation Pass: 2026-05-24, Browser Operation Progress Events

This pass completed the browser-tool progress item from Phase 9 by adding
structured operation events at the shared `RunicAI.Browser.Session` boundary.
Browser-capable agents can now surface browser operation milestones before the
final browser tool observation is appended to the model conversation.

Implemented changes:

- `RunicAI.Browser.Session` now accepts an optional `event_sink` at session
  start or per operation.
- Browser session operations emit `:browser_operation_started`,
  `:browser_operation_completed`, and `:browser_operation_failed` events with
  operation metadata for navigation, snapshot, click, type, press, scroll,
  console, and screenshot calls.
- Browser event output is redacted and summarized: snapshot previews are capped,
  image payloads are represented by byte size/media metadata, and typed text is
  represented by byte count rather than raw text.
- `RunicAI.Coding.Tools.default_registry/2` passes the active event sink into
  browser tool options, so normal tool execution, child agents, and RLM parent
  node streams can receive browser operation events.

Validation:

- `mix test test/runic_ai/coding/tools_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 28 tests, 0 failures.
- Live RLM seven-scenario catalog after browser operation progress events:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-operation-progress-rlm-catalog-45s-20260524.md`.
- Browser-lane backend probe after browser operation progress events:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-operation-progress-browser-probe-field-service-20260524.md`.

Runtime findings:

- The browser tool regression now proves navigation start events and completed
  snapshot, click, and screenshot events are emitted with compact evidence.
- The live RLM catalog still passes all seven current project-generation
  scenarios after browser session operation events were added.
- The `browser_tidewave` backend probe still fails Field Service Dispatch with
  `browser/UI evidence capture is incomplete`, confirming that first-class
  browser/Tidewave runner evidence remains separate from browser-tool event
  streaming.

Remaining design limitation:

- Phase 6 is still open: the robustness harness needs a real browser/Tidewave
  runner that captures DOM screenshots, browser console, session UI projection,
  approval/review cards, and follow-up repair behavior from the web interface.

## Remediation Pass: 2026-05-24, Browser Workbench Evidence Artifact

This pass addressed the next Phase 6 gap that made browser-lane failures too
opaque for iterative smoke testing. The `browser_tidewave` lane still uses a
backend Workbench probe rather than a real browser driver, but it now writes a
durable evidence artifact that explains exactly what was observed and what is
still missing.

Implemented changes:

- Browser-lane smoke runs now persist a per-scenario JSON evidence artifact
  under the isolated workspace.
- The artifact records the Workbench session URL, launch options, launch
  result, launch snapshot, final snapshot, selected agent, message/event counts,
  event phases/statuses, run status, review state, artifact state, tool names,
  and final assistant-visible output preview.
- Browser-lane evidence includes explicit UI checks for session URL capture,
  Workbench projection visibility, agent-route visibility, visible state,
  final output, review state, artifact state, DOM screenshot capture, browser
  console capture, and normal Tidewave interaction capture.
- Matrix evidence links now prefer the browser evidence artifact for
  `browser_tidewave` rows when no event trail is available.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 6 tests, 0 failures.
- Browser-lane Field Service probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-evidence-probe-field-service-20260524.md`.
- Live RLM seven-scenario catalog regression:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-evidence-rlm-catalog-45s-20260524.md`.
- `mix test` passed: 651 tests, 0 failures, 2 skipped.

Runtime findings:

- The browser-lane backend probe now passes checks for session URL capture,
  launch projection, final projection, agent route visibility, message/event
  state, final chat-visible output, review state, and artifact state.
- The same run still fails, correctly, because DOM/browser screenshot capture,
  browser console capture, and normal Tidewave interaction are not implemented
  by the backend probe.
- This means Codex can now inspect browser-lane smoke failures from files
  without relying on manual UI notes, but true browser/Tidewave automation is
  still required before the lane can validate the user-facing web experience.

## Remediation Pass: 2026-05-24, Chrome Browser UI Capture

This pass added an opt-in rendered-page capture path for browser-lane smokes.
It does not yet drive the Workbench composer like a user or Tidewave agent, but
it closes the prior blind spot where the `browser_tidewave` lane had no DOM or
screenshot artifact from the actual web surface.

Implemented changes:

- `mix runic_ai.rlm.robustness` accepts `--browser-ui-capture`,
  `--browser-workbench-url`, and `--browser-capture-timeout-ms`.
- When enabled, `browser_tidewave` uses local Chrome headless to open the
  Workbench session URL and persist rendered HTML, a structured DOM text
  snapshot, a PNG screenshot, and raw Chrome output under the browser evidence
  directory.
- Browser evidence now has separate checks for DOM snapshot capture and
  screenshot capture, while browser console capture and Tidewave interaction
  remain explicit failing checks.
- Tests can inject a `browser_ui_capture_fun`, which gives future Tidewave or
  MCP-driven runners a clean seam for replacing the Chrome headless probe with
  richer browser automation.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 7 tests, 0 failures.
- Browser-lane Field Service Chrome capture probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-capture-field-service-v3-20260524.md`.
- Live RLM seven-scenario catalog regression:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-ui-capture-rlm-catalog-45s-20260524.md`.
- `mix test` passed: 652 tests, 0 failures, 2 skipped.

Runtime findings:

- The browser-lane Field Service probe now passes DOM snapshot and screenshot
  checks when a local Workbench is running at `http://localhost:4000`.
- The persisted DOM snapshot shows the browser-visible session state,
  including `rlm - completed`, the Plan tab, final browser-probe output, and
  the `workflow rlm` composer label.
- The lane still fails, correctly, because the Chrome headless probe does not
  capture real page console events and does not drive the normal UI controls or
  Tidewave follow-up/repair flow.

## Remediation Pass: 2026-05-23, Child Budgets And Runtime Evidence

The second implementation pass addressed the next failures surfaced by live
RLM field-service probes: opaque child-agent stalls, expensive proposal repair
round trips, child processes surviving timeouts, and false objective-satisfied
status when implementation nodes failed.

Implemented changes:

- `WorkflowCompiler` now emits live node lifecycle events for every generated
  workflow node with compact output and error summaries.
- RLM child-agent runtime is bounded by the parent run deadline, node mode, and
  explicit child limits. Read-only inspection, patch, test-writing, and verify
  nodes no longer share one undifferentiated timeout.
- Child timeout details include node id, mode, objective, timeout, and
  workspace root. Timed-out child nodes return failed `ChildResult`s and allow
  downstream verification to report concrete acceptance failures.
- `codex exec` child calls receive the child budget and are wrapped in the OS
  `timeout` command when available. Timed-out smoke subprocesses were checked
  and cleaned up during this pass.
- Proposal normalization now handles common coordinator vocabulary drift:
  `review_repair` agent modes become patch-capable child agents; actionless
  deterministic acceptance-contract nodes become constant deterministic steps;
  abstract edit-intent nodes become review gates instead of invalid edit
  operations.
- Scorecard derivation now treats failed child workflows as objective failure
  even if a later policy-note or unrelated verification node passes.
- Completion status now blocks when progress-gate repair needs remain.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/git_and_codex_test.exs`
  passed: 78 tests, 0 failures, 1 skipped.
- `mix test` passed: 637 tests, 0 failures, 2 skipped.
- Deterministic smoke matrix:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-final-rlm-guardrails-20260523.md`.
- Live RLM Field Service smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-os-timeout-wrapper-live-rlm-field-service-150s-20260523.md`.

Runtime findings after the fixes:

- The field-service live lane now reaches an accepted workflow with
  implementation, test, review, and verification nodes. It no longer returns a
  generic repo file dump as the final answer.
- The scenario still fails deterministic and judge gates because no real
  dispatch source/test artifacts are produced before the child patch agents
  time out.
- The remaining design gap is no longer "RLM is just repo QA"; it is now
  "child coding agents are too slow/opaque for bounded generated-project
  execution and do not stream durable edit/tool evidence back to the parent."
- The next capability work should add resumable/streaming child sessions,
  deterministic small-project edit components, or a parent-owned patch plan
  executor so RLM can make progress without waiting for a long opaque child
  process.

## Remediation Pass: 2026-05-24, Completion Gate And Repair Evidence Hygiene

This pass followed up on the browser review-approval smoke where the RLM
approved a side-effectful node, failed to change files, and still surfaced an
`objective_satisfied` final status. The fix makes completion derive from
progress-gate evidence and prevents repair prompt logs from becoming false
semantic requirements.

Implemented changes:

- `ProgressGate` now treats `mode: :patch` and patch toolsets as mutating even
  when `allow_mutation?` is not explicitly set.
- Mutating workflows no longer pass the implementation-activity check just
  because scaffold source files exist. Unless a policy explicitly allows
  existing-source-only completion, the run must record changed implementation
  files.
- `ProgressGate.apply/2` now projects the generated objective scorecard onto
  the top-level RLM result so final status and UI projection do not lose the
  contract outcome.
- RLM final completion now reports `blocked` when progress-gate repair needs
  remain or any workflow trace entry failed.
- Repair follow-up prompts are sanitized before heuristic objective-term
  extraction: the gate prefers the `Original objective:` segment, truncates
  observed smoke/failure evidence, and filters generic process/language/log
  terms such as `Repair`, `Elixir`, `Compiling`, and `Assertion`.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs` passed: 51 tests, 0
  failures.
- `mix test test/runic_ai/persistence/sqlite_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 27 tests, 0 failures.
- Browser review approval smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-gated-v2-20260524.md`.
- Browser repair follow-up regression:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-gated-regression-v3-20260524.md`.

Runtime findings after the fixes:

- The review-approval browser smoke now captures the review card and approval
  decision, then blocks honestly with visible `Objective status:
  objective_incomplete` when the approved edit produces no changed files. It
  still fails the matrix because the dispatch project was not implemented,
  which is now a capability gap rather than a false-success/status bug.
- The repair-follow-up browser smoke passes again after sanitizing repair
  evidence. It completes with `objective_satisfied`, records changed source and
  test paths, and the generated workspace passes `mix test`.
- The next issue is workflow capability, not completion honesty: the
  review-approval path needs either a real implementation component after
  approval or a repair continuation from the blocked scorecard, instead of
  stopping after a no-op edit.

## Remediation Pass: 2026-05-24, Browser Catalog Project Generation Pass

This pass used the review-approval failure as the next concrete OODA input.
The approved edit was no longer overclaiming, but it still failed because the
deterministic project generator emitted update operations for files that did
not exist in fresh scenario workspaces. After fixing that, the broader browser
catalog exposed a second false negative: lexical progress heuristics were
blocking runs that already had deterministic compile/test/runtime evidence.

Implemented changes:

- `ElixirProjectGenerator` now emits create-with-overwrite operations for
  generated source and test files, so fresh workspaces and repair workspaces
  both apply cleanly.
- The generator removes root-level Mix scaffold source/test files discovered in
  the source index, excluding generated targets and existing-app feature work.
  This eliminates leftover `greets the world` scaffold tests from browser
  project-generation scenarios.
- Generic lexical objective coverage is now opt-in via `progress_policy:
  [lexical_coverage?: true]`. The default hard progress gate focuses on
  changed-file evidence, scaffold removal, test presence, and explicit
  deterministic/verification evidence instead of brittle prompt-term matching.
- Added regressions for fresh-scenario generator application, scaffold cleanup,
  noisy instruction-word progress gating, and updated the scaffold-only
  reliability fixture to assert the remaining hard failures.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs` passed: 53 tests, 0
  failures.
- `mix test test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs`
  passed: 85 tests, 0 failures.
- `mix test test/runic_ai/persistence/sqlite_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 27 tests, 0 failures.
- `mix test` passed: 664 tests, 0 failures, 2 skipped.
- Browser review approval smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-generator-cleanup-v1-20260524.md`.
- Browser repair follow-up regression:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-after-generator-cleanup-20260524.md`.
- Full browser-lane catalog:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-after-lexical-optional-20260524.md`.

Runtime findings after the fixes:

- The full `browser_tidewave` catalog now passes all 9 current scenarios through
  the rendered Workbench UI launch path. The approval scenario captures an
  approved review decision and completes with generated dispatch source/tests.
- Deterministic checks pass for every browser scenario, including compile/test
  commands and repair-follow-up verification.
- This is meaningful progress for Workbench observability and bounded project
  completion, but it is not proof of a fully general RLM coordinator. The pass
  is still heavily aided by seeded deterministic Elixir project-generation
  components for known smoke domains.
- The next capability gap is to generalize from the seeded generator into a
  contract-driven implementation path: infer the objective contract, select
  components/adapters, and synthesize checks without depending on scenario
  profile matching.

## Remediation Pass: 2026-05-24, Deterministic Objective Contract Threading

This pass made the seeded Elixir project-generation route consume an explicit
coding objective contract instead of selecting generator profiles only from raw
prompt text at the final implementation step.

Implemented changes:

- Added deterministic `RunicAI.Coding.RLM.ObjectiveContract.infer/2` and
  `infer!/2` for the coding RLM route. It records domain, generation profile,
  mutation policy, required capabilities, evidence classes, and
  objective-specific requirements.
- Threaded the inferred contract through seeded project-generation proposal
  metadata, the deterministic `acceptance_contract` node value, and generated
  patch-set metadata.
- Changed `ElixirProjectGenerator` to prefer `generation_profile` from the
  objective contract when choosing the implementation profile.
- Replaced raw substring domain matching with token/phrase-boundary matching
  so `event-sourced work order audit` selects audit, while `auditable
  allocation decisions` remains inventory.
- Added regression tests for field service, event-sourced audit, auditable
  inventory allocation, explicit contract profile overrides, and generator
  fallback profile selection.

Validation:

- `mix test test/runic_ai/coding/rlm_agent_test.exs` passed: 59 tests,
  0 failures.
- `mix test test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 103 tests, 0 failures.
- Browser full-catalog smoke after the first contract-threading pass:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-threaded-20260524.md`
  failed only `event_sourced_audit`, surfacing the work-order/audit ambiguity.
- Browser full-catalog smoke after audit-first correction:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-threaded-v2-20260524.md`
  failed only `inventory_allocation`, surfacing the `auditable` substring
  ambiguity.
- Browser full-catalog smoke after token-boundary matching:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-boundary-v3-20260524.md`
  passed all nine `browser_tidewave` rows.
- `mix test` passed: 670 tests, 0 failures, 2 skipped.

Runtime findings after the fixes:

- The contract metadata now flows into visible proposal and acceptance-contract
  evidence for seeded project-generation runs.
- The browser catalog catches semantic routing regressions quickly because the
  generated artifact paths are scenario-specific and checked before the judge
  can pass.
- The RLM can now complete the current Workbench catalog with correct domain
  artifacts, compile/test evidence, follow-up repair evidence, and review
  approval evidence.

Remaining gap after this pass:

- The contract is still `RunicAI.Coding.RLM.ObjectiveContract`, not a shared
  top-level contract used by assistant, browser, research, memory, and coding
  routes.
- The contract is deterministic and heuristic for the current smoke domains.
  It is useful as a reliability guard, but it does not yet prove open-ended
  domain understanding or dependency selection.
- The generator still covers known smoke profiles. The next implementation
  work should promote these requirement/evidence structures into reusable
  workflow validation and repair inputs, then use LLM-derived contracts for
  novel domains with deterministic gates around the resulting evidence.

## Remediation Pass: 2026-05-24, Structured Contract And Blocked Evidence Projection

This pass targeted the remaining Workbench projection gap: a browser user and
smoke harness could see final text and stage labels, but not a durable
machine-readable contract or blocked-run next-action evidence.

Implemented changes:

- RLM final workflow-output events now include structured
  `objective_contract`, `repair_needs`, `blocked_evidence`, and `next_actions`
  fields when available.
- RLM scorecard summary events now carry the same contract and blocked-evidence
  fields, so the evidence is available even if the final assistant message is
  filtered or deduplicated.
- Blocked evidence includes current node, current child, elapsed/runtime budget
  details, latest progress event, repair needs, residual risks, unsatisfied
  acceptance results, and the objective contract.
- `Workbench.session_snapshot/1` now exposes top-level `objective_contract`
  and `blocked_evidence` projections derived from persisted events, messages,
  and scorecards.
- Browser robustness visible-state capture now records objective-contract
  presence, requirement count, evidence requirements, blocked-evidence
  presence, blocked current node, and next-action count.
- Browser UI checks now fail if an RLM browser row lacks structured contract
  requirements, and fail blocked/failed sessions if no blocked next-action
  evidence is visible.

Validation:

- `mix test test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs`
  passed: 26 tests, 0 failures.
- `mix test test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 38 tests, 0 failures.
- `mix test test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/persistence/sqlite_test.exs test/runic_ai/terminal/event_test.exs test/runic_ai/workbench_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 144 tests, 0 failures.
- Browser full-catalog smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-structured-evidence-20260524.md`
  passed all nine `browser_tidewave` rows with
  `structured_contract_requirements_visible` and
  `blocked_next_action_evidence_visible` checks passing.
- Tiny-budget live RLM Field Service probe:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-blocked-evidence-rlm-field-service-20260524.md`
  failed before active node execution with a runtime-budget `error`, preserving
  the distinction between pre-execution budget exhaustion and active-node
  blocked evidence.
- `mix test` passed: 672 tests, 0 failures, 2 skipped.

Runtime findings:

- Real browser-launched RLM sessions now preserve the objective contract in the
  Workbench snapshot, and the smoke runner grades that as a browser-visible
  product requirement.
- Passing sessions do not require blocked evidence, but blocked/failed browser
  sessions now have a harness-level check requiring next-action evidence.
- The tiny-budget live probe exhausted during proposal/planning, before active
  node execution. That should remain an `error`/configuration-budget class
  unless partial active workflow evidence exists.

Remaining gap after this pass:

- The UI still needs first-class rendering for contract requirements and
  blocked next actions; the projection and smoke evidence are present, but the
  current plan view remains mostly stage/card oriented.
- Review rejection and blocked-run browser scenarios still need real UI smokes,
  not only event/projection regressions.
- The contract is still coding-scoped; shared assistant/RLM objective-contract
  promotion remains open.

## Remediation Pass: 2026-05-24, Live Internal Repair Loop Smoke

This pass targeted the remaining repair gap after same-session browser
follow-up repair began passing: the RLM needed a live smoke proving that its
own `RepairLoop` can consume failed command evidence, produce a structured
repair plan, modify the workspace, and re-run verification without relying on
the user to send a follow-up prompt.

Implemented changes:

- Added a robustness workspace fixture, `internal_repair_mix_project`, that
  starts with a deterministic failing `mix test`.
- Added scenario `rlm_internal_repair_loop`, scoped to the `rlm` lane, with a
  one-repair budget and deterministic checks for the repaired source and
  passing test command.
- Extended the live robustness runner so it can pass a concrete workflow
  proposal and repair executor through the terminal `RLMRunner` path. This
  keeps the smoke on the real `RLMRunner -> Agent.run -> RepairLoop` route
  while avoiding an unrelated coordinator-proposal LLM call for the fixture.
- Added repair-count and repair-summary evidence to live lane reports, and a
  `Repairs` column to matrix markdown output.
- Fixed RLM final event status so a repaired run with a latest
  `objective_satisfied` scorecard emits `completed ok` instead of consulting a
  stale pre-repair repair-need snapshot.
- Excluded `tmp` and `.runic_ai` paths from workspace-delta evidence so event
  trails and persistence files do not appear as repaired implementation
  artifacts.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/coding/standard_agent_remaining_test.exs`
  passed: 113 tests, 0 failures.
- Targeted live RLM repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-internal-repair-loop-v4-20260524.md`.

Runtime findings after the fixes:

- The final smoke row passes deterministic gates and judge checks with one
  repair attempt.
- The event trail shows the first `mix test` failing, the verification gate
  reporting `objective_incomplete`, `repair_attempt_started` with a structured
  plan that names the failing command, `repair_attempt_completed` with changed
  file `lib/internal_repair_demo.ex`, and final `RLM Completed ok`.
- This proves the internal repair loop for failed command evidence in a
  controlled coding fixture. It does not yet prove LLM-judge failure repair,
  open-ended domain repair, or shared assistant/RLM repair contracts.

## Remediation Pass: 2026-05-24, Semantic Judge Repair Loop Smoke

This pass extended the repair-loop evidence path from command failures to a
semantic objective-judge failure. The target failure mode is a run where
compile/tests can pass, but the objective contract is still not semantically
satisfied.

Implemented changes:

- `RepairController` now preserves acceptance-result `message`, semantic
  requirement metadata, and judge `evidence_refs` in repair needs.
- `RepairLoop` now includes semantic requirement id, description, judge
  message, repair instruction, and evidence refs in the structured repair
  plan's `observed_failure`.
- Repair needs are prioritized so high-signal compile/test/semantic/runtime
  failures drive the plan before generic implementation-activity failures such
  as "no changed files".
- Terminal RLM runner options now pass semantic-progress controls through to
  the underlying RLM agent, including `objective_contract`, `semantic_judge`,
  semantic model/client options, and semantic/progress evidence policies.
- Added `rlm_semantic_repair_loop`, a live `rlm` lane scenario where the
  initial `mix test` passes but the semantic judge blocks `transition_history`.
  The repair executor only proceeds when it receives structured semantic judge
  evidence, then patches `WorkOrder` transition history and tests.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 132 tests, 0 failures.
- Targeted live RLM semantic repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-repair-loop-20260524.md`.

Runtime findings after the fixes:

- The smoke row passes deterministic gates and heuristic judge checks with one
  repair attempt.
- The event trail shows `mix test` passing before repair, `ProgressGate`
  producing a semantic repair need for `transition_history`,
  `repair_attempt_started` with the semantic requirement and judge message,
  `repair_attempt_completed` with changed files `lib/work_order.ex` and
  `test/work_order_test.exs`, and final `objective_satisfied`.
- This proves the internal repair loop can consume structured semantic judge
  evidence in a controlled fixture. It does not yet prove failures from a real
  external LLM judge, novel-domain runtime smokes, or a shared non-coding
  objective contract.

## Remediation Pass: 2026-05-24, Runtime Smoke Repair Loop Smoke

This pass targeted the remaining runtime-smoke repair gap: RLM workflows could
run smoke commands, but runtime-smoke acceptance checks did not have a durable
`runtime_smokes` evidence channel that could be updated during repair.

Implemented changes:

- Command nodes marked with `purpose: :runtime_smoke` now record named
  runtime-smoke observations in workflow context, in addition to ordinary
  command results.
- Repair-loop verification commands now support `runtime_smoke` acceptance
  checks with concrete `argv`, rerun the smoke after a repair attempt, and
  update the named runtime-smoke observation with latest-result semantics.
- Runtime-smoke verification now checks the latest matching smoke observation
  instead of a stale pre-repair failure.
- `RepairController` classifies runtime-smoke failures separately from generic
  test failures, preserves smoke ids and output previews in repair needs, and
  prioritizes runtime-smoke repair evidence before lower-signal generic
  failures.
- `RepairLoop` includes named runtime-smoke evidence in the structured repair
  plan's `observed_failure`.
- Added `rlm_runtime_smoke_repair_loop`, a live `rlm` lane scenario where
  `mix test` passes but `dispatch_flow` runtime smoke fails before repair and
  passes after repair.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 134 tests, 0 failures.
- Targeted live RLM runtime-smoke repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-smoke-repair-loop-20260524.md`.

Runtime findings after the fixes:

- The smoke row passes deterministic gates and heuristic judge checks with one
  repair attempt.
- The event trail shows unit tests passing, the `runtime_smoke` command
  failing, `verify_runtime` blocking, `repair_attempt_started` with
  `dispatch_flow` runtime-smoke evidence, `repair_attempt_completed` with
  changed files `lib/dispatch_runtime.ex` and
  `test/dispatch_runtime_test.exs`, the rerun smoke output
  `runtime_smoke_pass`, and final `objective_satisfied`.
- This proves controlled runtime-smoke repair. It does not yet satisfy the
  broader requirement for behavior-level runtime smoke scripts across every
  scenario or real external LLM-judge repair.

## LLM Judge Calibration And Audit Pass

Implemented:

- `RunicAI.RLM.Robustness.Judge` now has a reusable structured judge prompt
  and normalized output shape for `overall`, dimension scores, blocking
  failures, notable strengths, and evidence.
- LLM judge results now persist audit metadata in the JSON report: source,
  model, prompt SHA-256, bounded prompt excerpt, bounded response excerpt, and
  fallback status.
- Decode and provider failures now produce an explicit `heuristic_fallback`
  audit record instead of silently looking like a normal heuristic judge pass.
- Deterministic and lane gates are enforced after an LLM response is decoded.
  A claimed LLM pass is downgraded to `fail` when deterministic checks fail or
  the lane is skipped, errored, failed, or blocked.
- Matrix status derivation now treats explicit judge failures as failed rows
  instead of reducing deterministic-pass/judge-fail combinations to `review`.
- Added calibrated judge fixtures for known-good, scaffold-only,
  partially-correct, over-engineered, and invalid-JSON fallback outputs.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 23 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 139 tests, 0 failures.
- Fake local LLM-judge audit smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-llm-judge-audit-20260524.md`.
- Regression live RLM runtime-smoke repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-smoke-repair-judge-audit-20260524.md`.

Findings:

- The fake LLM-judge smoke surfaced a real status-composition gap: a judge
  `fail` was previously reported as matrix `review` when deterministic checks
  passed. This is now fixed and covered by the persisted-audit report test.
- At this point in the sequence the LLM-judge path was auditable and
  deterministic-gated, but did not yet feed judge failures into the internal
  `RepairLoop`. The following pass closes that controlled-fixture gap.

## LLM Judge Repair Loop Pass

Implemented:

- `RunicAI.Coding.RLM.ObjectiveJudge` now attaches audit metadata to
  LLM-backed semantic judgements: source, model, prompt SHA-256, bounded prompt
  excerpt, bounded response excerpt, fallback status, and fallback error when
  object generation falls back to JSON text.
- Semantic acceptance results now carry judge metadata into
  `RepairController`, and repair needs preserve it for the repair handoff.
- `RepairLoop` includes LLM semantic judge provenance in the structured repair
  plan's observed failure, alongside requirement id, judge message, evidence
  refs, repair instruction, verification command, and stop condition.
- The terminal runner now forwards `semantic_judge_generation`, allowing the
  live RLM route to run the JSON-text judge path instead of silently defaulting
  back to object generation.
- The robustness workspace factory now removes the active scenario's generated
  scaffold files generically for repair-loop seed workspaces. The new
  `rlm_llm_judge_repair_loop` smoke exposed this because stale scenario
  scaffold files were taking repair priority ahead of the semantic judge need.
- Added `rlm_llm_judge_repair_loop`, a live `rlm` lane scenario where initial
  `mix test` passes, an LLM-style semantic judge blocks `transition_history`,
  repair consumes the judge evidence, and the final scorecard is satisfied.

Validation:

- `mix test test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/rlm/robustness_test.exs`
  passed: 56 tests, 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 140 tests, 0 failures.
- Targeted live RLM LLM-judge repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-llm-judge-repair-loop-20260524.md`.

Findings:

- The smoke row passes deterministic gates and heuristic matrix judge checks
  with one repair attempt.
- The JSON report records the repair plan observed failure as
  `acceptance fail: semantic_requirement`, the `transition_history`
  requirement, the LLM judge message, evidence refs, the planned edit, and
  `LLM semantic judge: llm_json_text: test:semantic-judge: <prompt hash>`.
- This proves the internal repair loop can consume an LLM-style semantic judge
  failure with provenance. It still uses a deterministic fake judge client, so
  it does not prove calibration against a live external model.

## Child-Agent Repair Loop Pass

Implemented:

- Added `rlm_child_agent_repair_loop`, a controlled live `rlm` scenario for a
  failing Mix project where repair is delegated through the real
  `StandardAgent.patch/3` child-agent path instead of a deterministic fixture
  repair executor.
- Added a production-local fake child LLM response builder for the smoke runner
  so Mix task execution can drive the child agent without depending on
  `test/support` modules.
- The child-agent path now emits repair evidence that includes the parent
  failure context, child workflow identity, `apply_patch` tool activity, changed
  implementation path, and parent-owned post-repair verification.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 25 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 141 tests, 0 failures.
- Targeted live RLM child-agent repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-child-agent-repair-loop-v3-20260524.md`.

Findings:

- The first Mix-task smoke caught a real harness mistake: the runner referenced
  `RunicAI.LLM.TestClient`, which is only compiled in the test environment.
  That leak is fixed by local response-building helpers in production code.
- The passing smoke proves the parent RLM can hand a command failure to an
  actual child coding agent, observe tool-level patch activity, rerun
  verification, and finish with one repair attempt.
- The remaining repair gap narrowed to the non-child `rlm_internal_repair_loop`
  fixture. The command child-agent scenario now proves real child-agent repair
  behavior for command failures.

## Semantic Child-Agent Repair Pass

Implemented:

- Replaced the deterministic `semantic_repair_loop_executor` for both
  `rlm_semantic_repair_loop` and `rlm_llm_judge_repair_loop` with the real
  `StandardAgent.patch/3` fallback path.
- Added a semantic child repair client that only emits an `apply_patch` tool
  call when the parent repair prompt contains the structured semantic handoff:
  `Structured repair plan`, `semantic requirement`, `transition history`, and
  `mix test`.
- Updated regression tests to require persisted child-agent/tool evidence:
  `standard_coding_agent`, `apply_patch`, and `lib/work_order.ex`.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 25 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 141 tests, 0 failures.
- Targeted live RLM semantic child-agent repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-child-agent-repair-semantic-20260524.md`.
- Targeted live RLM LLM-judge child-agent repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-child-agent-repair-20260524.md`.

Findings:

- The CLI previously accepted only one repeated `--scenario` flag in a single
  command, so the first semantic and LLM-judge smokes were run separately to
  avoid treating missing rows as coverage. The later harness parsing pass fixed
  this and added regression coverage.
- Both rows passed deterministic gates and heuristic matrix judge checks with
  one repair attempt, child result source `standard_coding_agent`, and
  `apply_patch` in the persisted JSONL evidence.
- Runtime-smoke repair was the last controlled repair class still backed by a
  deterministic fixture executor; the following pass closes it.

## Runtime-Smoke Child-Agent Repair Pass

Implemented:

- Replaced the deterministic `runtime_smoke_repair_loop_executor` with the real
  `StandardAgent.patch/3` fallback path.
- Added a runtime-smoke child repair client that only emits an `apply_patch`
  tool call when the parent repair prompt contains the structured runtime
  handoff: `Structured repair plan`, `runtime smoke`, and `dispatch_flow`.
- Updated regression tests to require persisted child-agent/tool evidence:
  `standard_coding_agent`, `apply_patch`, and `lib/dispatch_runtime.ex`.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 25 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 141 tests, 0 failures.
- Targeted live RLM runtime-smoke child-agent repair smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-child-agent-repair-20260524.md`.

Findings:

- The row passed deterministic gates and heuristic matrix judge checks with one
  repair attempt, child result source `standard_coding_agent`, `apply_patch` in
  persisted JSONL evidence, and final runtime output `runtime_smoke_pass`.
- The controlled repair classes for command, semantic judge, LLM-style judge,
  and runtime-smoke failures now all have real child-agent/tool-path coverage.
- The only remaining `repair_executor` in the robustness runner is the
  deliberately narrower `rlm_internal_repair_loop` parent-loop fixture, which
  should either stay clearly labeled as a harness-only parent-loop smoke or be
  retired in favor of `rlm_child_agent_repair_loop`.

## Harness Parsing And Fixture Labeling Pass

Implemented:

- Changed the robustness Mix task parser for `--scenario` and `--lane` from
  `:string` to `:keep`, preserving repeated flags instead of retaining only the
  last value.
- Added `Mix.Tasks.RunicAi.Rlm.Robustness.parse_args/1` as a small testable
  parser seam and regression coverage for repeated scenario and lane flags.
- Relabeled `rlm_internal_repair_loop` as `RLM Parent-Loop Repair Fixture` and
  added explicit metadata that it is a parent-loop fixture, not child-agent
  repair coverage.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 26 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 142 tests, 0 failures.
- `mix compile --warnings-as-errors` passed.
- Targeted repeated-scenario smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-repeated-scenario-child-repair-pair-20260524.md`.

Findings:

- The repeated-scenario smoke now produces two rows, one for
  `rlm_semantic_repair_loop` and one for `rlm_llm_judge_repair_loop`; both pass
  with one child-agent repair.
- The remaining parent-loop fixture is now explicitly labeled as harness-only,
  which removes the ambiguity between parent repair evidence handling and real
  child-agent repair capability.

## Existing App Deterministic Tightening Pass

Implemented:

- Captured baseline workspace file paths and SHA-256 fingerprints before
  browser, standard, assistant, or RLM execution.
- Changed `changed_file_count_between` to fail when no baseline exists and to
  count modified seeded files, not only newly added paths.
- Tightened `existing_app_feature` deterministic checks so the seeded scaffold
  must add an integration-smoke feature module, adapt to `ExistingApp.Accounts`,
  include five or more tests, compile, run tests, and pass a named runtime
  smoke output.
- Added regression coverage that verifies the untouched seeded app fails and a
  bounded feature slice passes with changed files in
  `lib/existing_app_feature.ex` and `test/existing_app_feature_test.exs`.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 27 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 143 tests, 0 failures.
- `mix compile --warnings-as-errors` passed.
- Untouched baseline smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-tightened-baseline-20260524.md`
  failed as expected with deterministic `fail`.
- Targeted live RLM smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-tightened-live-rlm-20260524.md`
  passed with 10 passed checks, deterministic `pass`, judge `pass`, and event
  trail
  `tmp/rlm_robustness/workspaces/existing-app-tightened-live-rlm-20260524/existing_app_feature/rlm/tmp/rlm-event-trail.jsonl`.

Findings:

- Path-only changed-file accounting missed mutations to seeded scaffold files,
  which allowed an untouched or weakly changed existing app path to look better
  than it was. Fingerprint baselines now make that failure mode observable.
- The baseline smoke emitted an inotify watch warning and a stale
  `kill: No such process` message after report generation. It did not block the
  smoke, but it should stay visible if watcher-heavy browser runs become flaky.
- This closes the known `existing_app_feature` deterministic weakness. It does
  not close the broader Phase 7 item to add behavior-level runtime smoke scripts
  for every scenario.

## Per-Check Output Evidence Pass

Implemented:

- Replaced deterministic command-check merged-output capture with a temporary
  stdout/stderr capture wrapper.
- Persisted bounded `stdout_excerpt`, `stderr_excerpt`, combined `output`, and
  truncation flags in every command check's JSON report details.
- Kept the previous bounded `output` field for compatibility with existing
  judge and report consumers.
- Added regression coverage for oversized stdout plus stderr so report details
  cannot accidentally grow unbounded or lose stderr evidence.

Validation:

- `mix test test/runic_ai/rlm/robustness_test.exs` passed: 28 tests,
  0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs`
  passed: 144 tests, 0 failures.
- `mix compile --warnings-as-errors` passed.
- Untouched Existing App baseline smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-output-excerpts-baseline-20260524.md`
  failed as expected and its JSON report includes stderr evidence for the
  missing `ExistingAppFeature.integration_smoke/0` runtime-smoke failure.
- Targeted live Existing App RLM smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-output-excerpts-live-rlm-20260524.md`
  passed with deterministic `pass`, judge `pass`, and bounded command stdout
  excerpts for compile, test, and runtime-smoke checks.

Findings:

- This closes the Phase 7 report-evidence gap for deterministic command checks.
  It does not yet add equivalent stdout/stderr excerpt normalization for every
  browser evidence artifact or all non-deterministic child process event
  payloads.
- The baseline smoke again emitted the inotify watch warning and stale
  `kill: No such process` message after report generation. The report and JSON
  were still written successfully.

## Model/Client Preflight Resolver Pass

Implemented:

- Added `RunicAI.Agent.ModelClientResolver` as the shared launch preflight for
  model/client resolution.
- Wired the resolver into `RunicAI.Terminal.CliOptions`, so `standard`,
  `assistant`, `rlm`, Workbench-launched runs, and robustness live lanes share
  the same resolution path.
- Wired the resolver into the ExRatatui/TUI options path and fixed TUI agent
  starts to pass the selected client alias into `CliOptions.parse/1`.
- Kept direct `RunicAI.Coding.Codex.Client` calls aligned by delegating Codex
  model normalization to the shared resolver.
- Codex launches now map blank/default/legacy `openai:gpt-5.4-mini` model
  requests to the local Codex account default instead of passing the unsupported
  provider model to `codex exec`.
- Explicit provider-prefixed models such as `openai:gpt-4o` are rejected before
  a Codex session starts.
- `AgentRunner` now emits and persists a `model_client_preflight` terminal
  event before backend execution, and runner session-start events include the
  same resolver decision.

Validation:

- `mix test test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/runner_test.exs`
  passed: 26 tests, 0 failures.
- `mix test test/runic_ai/coding/git_and_codex_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/runner_test.exs`
  passed: 34 tests, 0 failures, 1 skipped.
- `mix test test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/ex_ratatui/options_test.exs`
  passed: 31 tests, 0 failures.
- `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_reliability_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/terminal/cli_options_test.exs test/runic_ai/terminal/ex_ratatui/options_test.exs test/runic_ai/coding/git_and_codex_test.exs`
  passed: 160 tests, 0 failures, 1 skipped.
- `mix compile --warnings-as-errors` passed.
- `mix run -e 'alias RunicAI.Terminal.CliOptions; {:ok, opts} = CliOptions.parse(["demo", "--client", "codex", "--model", "openai:gpt-5.4-mini"]); IO.inspect(%{model: opts.model, requested_model: opts.requested_model, decision: opts.model_resolution.decision, effective_model: opts.model_resolution.effective_model})'`
  printed `model: nil`, requested model `openai:gpt-5.4-mini`, decision
  `codex_account_default`, and effective model `codex-account-default`.
- `mix run -e 'alias RunicAI.Terminal.CliOptions; IO.inspect(CliOptions.parse(["demo", "--client", "codex", "--model", "openai:gpt-4o"]))'`
  returned a validation error before launch with requested model
  `openai:gpt-4o`.
- Targeted live RLM smoke:
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-model-client-preflight-existing-app-live-20260524.md`
  passed with deterministic `pass`, judge `pass`, and a visible
  `status/model_client_preflight` event in
  `tmp/rlm_robustness/workspaces/model-client-preflight-existing-app-live-20260524/existing_app_feature/rlm/tmp/rlm.jsonl`.

Findings:

- The preflight event initially lacked a stable run id when `AgentRunner` had
  to let the backend runner generate one. That caused JSONL and SQLite timeline
  counts to diverge for persisted terminal runs. `AgentRunner` now assigns the
  session id before emitting preflight evidence, restoring parity.
- This closes the concrete launch preflight gap for terminal, Workbench, TUI,
  and robustness live-lane entrypoints. It does not yet prove that every
  non-terminal API caller uses the resolver, nor does it classify all possible
  external provider failures beyond the explicit Codex provider-prefix case.

## Resolution Phases

### Phase 1: Model and client preflight

- [x] Add a shared model/client resolver used by `standard`, `assistant`,
      `rlm`, workbench, TUI, and smoke tasks.
- [x] For `--client codex`, avoid forcing the unsupported legacy Runic default
      model into the local Codex CLI path.
- [x] For `--client codex`, resolve blank/default model to a Codex-supported
      model for the local account type.
- [x] Reject unsupported provider/model combinations before starting a session.
- [x] Persist the resolved provider, model, client, account mode when known,
      and resolver decision in session artifacts.
- [x] Add regression tests where `openai:gpt-5.4-mini` is rejected or remapped
      before Codex execution.

Exit criteria:

- Field-service `standard` and `assistant` live lanes reach actual agent
  execution instead of provider startup failure.
- Provider/model errors are classified as launch configuration failures in
  reports.

### Phase 2: Shared objective contract

- [ ] Introduce `RunicAI.ObjectiveContract` or equivalent shared data structure
      for goals, non-goals, required capabilities, mutation policy,
      acceptance checks, evidence requirements, judge rubric, and residual risk.
- [x] Add a coding-scoped deterministic objective contract for seeded RLM
      project-generation runs.
- [ ] Generate the contract from user intent before route-specific planning.
- [x] Generate the coding-scoped contract before seeded recipe construction for
      the project-generation route.
- [ ] Map assistant scorecards and coding acceptance contracts into this shared
      contract.
- [ ] Persist the contract, contract revisions, and all check results in
      workbench and smoke artifacts.
- [x] Persist the coding-scoped contract in seeded proposal metadata,
      acceptance-contract node output, patch-set metadata, and browser smoke
      evidence.
- [x] Project the latest coding-scoped objective contract into Workbench session
      snapshots and browser visible-state evidence.
- [x] Make final agent status derive from contract satisfaction, not only
      workflow completion.

Exit criteria:

- The live `rlm` field-service run cannot report `ok` while domain checks fail.
- Final answers distinguish `completed`, `blocked`, `partial`, and
  `configuration_failed`.

### Phase 3: Contract-aware workflow validation

- [x] Extend RLM proposal validation with objective-required node classes for
      mutation-enabled build/project objectives.
- [ ] Extend RLM proposal validation with a complete objective contract for
      discovery, implementation, verification, repair, and final synthesis.
- [x] Thread seeded project-generation contract metadata into workflow proposal
      construction and deterministic acceptance evidence.
- [x] Reject read-only `repo_qa` workflows for objectives requiring mutation.
- [x] Require verification gates when the objective explicitly asks for
      compile/test/runtime smoke evidence.
- [ ] Require verification gates when the full objective contract includes
      compile/test/runtime checks.
- [ ] Require repair-capable loops when deterministic or judge checks fail and
      the budget allows repair.
- [ ] Add validator diagnostics that explain which contract requirement the
      proposal failed to cover.

Exit criteria:

- A field-service build objective cannot compile to only `discover -> read ->
  answer`.
- A project-generation proposal without tests or runtime verification is
  rejected before execution.

### Phase 4: RLM route broadening

- [ ] Split the product-level RLM coordinator from
      `RunicAI.Coding.RLM.Agent`.
- [ ] Introduce environment adapters for codebase, browser, web/research,
      memory, generated artifacts, durable workbench sessions, and child-agent
      results.
- [ ] Treat coding as one adapter or sub-workflow under the general RLM route.
- [ ] Expose the tool/component surface from
      `.docs/043-hermes-style-agent-tool-surface.md` to RLM planning through a
      capability manifest that is not repo-only.
- [ ] Prefer Runic-native workflow execution for generated workflows where it
      can preserve graph semantics, scheduler behavior, and observability.

Exit criteria:

- The `rlm` route can plan non-repo tasks without pretending they are codebase
  Q&A.
- Coding tasks still work, but are represented as coding sub-workflows under a
  broader objective contract.

### Phase 5: Assistant handoff and high-agency project route

- [ ] Add assistant intent detection for project generation, code mutation,
      runtime debugging, browser use, research, and normal Q&A.
- [ ] For high-agency project work, either use a project-capable assistant
      workflow or hand off to RLM with the objective contract intact.
- [ ] Prevent `assistant:generic_report` from being accepted for build/mutation
      objectives unless the user explicitly asks only for a report.
- [ ] Preserve assistant strengths for human-centric Q&A and research while
      avoiding silent downgrade of project tasks.

Exit criteria:

- The field-service assistant lane either delegates to an implementation route
  or reports that the requested capability is unavailable. It must not attempt a
  generic report as if it were a build.

### Phase 6: First-class browser/Tidewave eval runner

- [ ] Add a browser/Tidewave runner that starts the Phoenix workbench, launches
      scenarios through normal UI controls, and records the resulting session
      URL.
- [x] Add an opt-in browser runner that launches scenarios through normal
      Workbench UI controls against an already-running Phoenix workbench and
      records the resulting session URL.
- [x] Persist backend Workbench browser-lane evidence for session URL, launch
      projection, final projection, review state, artifact state, and final
      chat-visible output.
- [x] Persist rendered Workbench session DOM snapshots and screenshots when
      `--browser-ui-capture` is enabled against a running local workbench.
- [x] Persist browser console logs and network failures for UI-launched browser
      probes.
- [x] Persist graph/plan visibility checks for browser-launched Workbench
      sessions.
- [x] Persist browser review approval decisions and review decision state for
      browser-launched Workbench sessions.
- [ ] Persist Tidewave-specific session metadata.
- [x] Exercise at least one follow-up repair from the browser against an
      intentionally failing scenario.
- [x] Exercise one same-session browser follow-up for Field Service Dispatch and
      persist follow-up state in the browser evidence artifact.
- [x] Exercise same-session browser follow-up continuity for every current
      scenario class.
- [x] Add backend browser-lane checks for session URL, launch/final Workbench
      projection, agent-route visibility, visible state, review state, artifact
      state, and final output.
- [x] Add browser UI checks for rendered DOM snapshot and screenshot capture.
- [x] Add browser UI checks for console capture and continuity of follow-up
      context in the Field Service smoke.
- [x] Add real UI checks for workflow plan-stage visibility.
- [x] Add real UI checks for review-card approval affordances and approval
      decision capture.
- [x] Add real UI checks for structured contract requirements and blocked-run
      evidence.
- [ ] Add real UI checks for visible mode/profile and review rejection/edit
      flows.
- [x] Add browser evidence checks for structured contract requirements and
      blocked-run next-action evidence.
- [x] Render structured contract requirements and blocked-run next-action
      evidence in Workbench plan/chat UI.
- [x] Capture an early browser Plan-tab progress snapshot and assert active
      progress current-node context is visible for browser UI launches.
- [x] Capture active browser Plan-tab progress evidence for current child and
      remaining runtime budget, and require pre-final evidence for the
      review-gated approval scenario.
- [x] Replace user-facing `repo rlm` with `workflow rlm` after product
      copy is made accurate.
- [x] Pass the current 10-scenario browser Workbench catalog through normal UI
      launch with deterministic evidence, review approval, and repair follow-up.

Exit criteria:

- Browser/Tidewave rows include UI evidence, not just backend session state.
- A browser user can tell whether the agent actually satisfied the scenario.

### Phase 7: Robustness harness hardening

- [ ] Add behavior-level runtime smoke scripts for every scenario.
- [x] Tighten `existing_app_feature` so an untouched scaffold cannot pass
      deterministic checks.
- [x] Add command timeouts that actually enforce wall-clock limits.
- [x] Add live trace output and per-lane event trail artifacts for scenario
      runs.
- [x] Persist per-check stdout/stderr excerpts with bounded size.
- [x] Include the latest event trail path and current progress in matrix
      reports.
- [x] Prefer actionable failed/current node evidence over aggregate trace dumps
      when summarizing live smoke progress.
- [x] Prevent live lane `:error`, `:blocked`, or `:failed` results from being
      reported as pass/review only because deterministic scaffold checks passed.
- [x] Add regression coverage for no-op patch completion overclaims and
      repair-log terms contaminating objective progress checks.
- [x] Add regression coverage for fresh project-generation patch application
      and scaffold cleanup in browser scenario workspaces.
- [x] Add a live internal RLM repair-loop fixture that consumes failing command
      evidence and recovers within the scenario repair budget.
- [x] Add a live internal RLM repair-loop fixture that consumes semantic
      objective-judge evidence and recovers within the scenario repair budget.
- [x] Add a live internal RLM repair-loop fixture that consumes named
      runtime-smoke evidence and recovers within the scenario repair budget.
- [x] Add a live internal RLM repair-loop fixture that consumes LLM-style
      semantic judge evidence with judge provenance and recovers within the
      scenario repair budget.
- [x] Add a live internal RLM repair-loop fixture that delegates a failing
      command repair to the real child-agent/tool path and recovers within the
      scenario repair budget.
- [x] Add live semantic and LLM-judge repair-loop fixtures that delegate
      repairs to the real child-agent/tool path and recover within the scenario
      repair budget.
- [x] Add a live runtime-smoke repair-loop fixture that delegates repair to the
      real child-agent/tool path and recovers within the scenario repair
      budget.
- [x] Preserve repeated `--scenario` and `--lane` Mix task flags and prove
      multi-scenario smoke rows are not silently dropped.
- [x] Relabel the older `rlm_internal_repair_loop` as a parent-loop-only
      harness fixture so it is not mistaken for child-agent repair coverage.
- [x] Add calibrated LLM judge fixtures: known-good, scaffold-only,
      partially-correct, and over-engineered.
- [x] Require deterministic gates before LLM judge pass.

Exit criteria:

- The harness cannot produce false passes on scaffold workspaces.
- Judge output is auditable and comparable across agent changes.

### Phase 8: OODA repair as a product requirement

- [ ] Feed compile/test/runtime/judge failures back into repair workflows with
      structured evidence, not raw transcript blobs.
- [x] Feed an injected runtime/test failure into a browser follow-up repair
      scenario and verify the repaired workspace.
- [x] Feed a failing command/verification result into the internal RLM
      `RepairLoop` and verify the repaired workspace in the same live run.
- [x] Feed a semantic objective-judge failure into the internal RLM
      `RepairLoop` and verify the repaired workspace in the same live run.
- [x] Feed a named runtime-smoke failure into the internal RLM `RepairLoop`
      and verify the repaired workspace in the same live run.
- [x] Feed an LLM-style semantic judge failure with judge provenance into the
      internal RLM `RepairLoop` and verify the repaired workspace in the same
      live run.
- [x] Feed a failing command/verification result into a real child-agent repair
      path and verify the repaired workspace in the same live run.
- [x] Feed semantic and LLM-style judge failures into real child-agent repair
      paths and verify the repaired workspace in the same live run.
- [x] Feed a runtime-smoke failure into a real child-agent repair path and
      verify the repaired workspace in the same live run.
- [x] Require each repair iteration to state the observed failure, hypothesis,
      planned edit, verification command, and stop condition.
- [x] Reserve a repair budget before launching implementation children when a
      generated plan includes repair nodes.
- [x] Add a smoke-task `--max-runtime-ms` override and make the harness honor it
      ahead of scenario defaults.
- [x] Bound repair attempts by scenario budget and surface residual risks when
      budget is exhausted.
- [ ] Persist best-known artifact state and make the workbench final answer use
      the best verified output, not the last attempted output.
- [x] Persist blocked RLM final-output evidence with repair needs,
      unsatisfied acceptance checks, current node, latest progress, and next
      actions when the blocked result includes that data.

Exit criteria:

- A failing field-service run attempts a domain-relevant repair instead of
  stopping at scaffold output.
- Blocked runs show the best partial output and the exact failed acceptance
  checks.

### Phase 9: Runtime observability and cleanup

- [x] Emit `proposal_started` before coordinator proposal generation.
- [x] Emit child-agent start and periodic progress events during bounded child
      execution.
- [x] Persist smoke event trails as JSONL artifacts.
- [x] Add Codex bridge cleanup grace so OS timeout can terminate child process
      trees before the Elixir command timeout fires.
- [x] Add RLM child wrapper cleanup grace while preserving the child timeout as
      the contract deadline.
- [x] Emit proposal-generation heartbeats during long coordinator calls.
- [x] Forward live Codex child-agent JSONL/model activity into parent RLM node
      events before the child returns.
- [x] Forward live child-agent tool/review/verification activity into parent
      RLM node events before the child returns or times out.
- [x] Add in-tool progress streaming for long-running command/process tools
      where planned/completed observations are not enough.
- [x] Add a long-running browser smoke with a real delayed command/tool event
      stream and require pre-final Plan-tab progress evidence.
- [x] Pass the 10-row browser Workbench catalog with in-run compile, test, and
      runtime-smoke evidence captured as RLM command-node results.
- [x] Add browser-tool operation progress streaming for navigation, interaction,
      snapshot, screenshot, and console milestones.
- [x] Forward returned child workflow trace summaries into parent RLM node
      events when the child workflow completes.
- [x] Verify child subprocess cleanup for the observed parent-budget-expired
      live path.
- [ ] Add integration regression coverage for orphaned Codex subprocesses after
      full RLM child timeout.
- [x] Expose persisted event-trail count, latest progress, current node,
      elapsed time, and remaining budget in the web session UI when the
      projection contains those values.
- [ ] Expose event-trail artifact paths and grouped proposal/node/tool/repair
      timeline details in the web session UI.
- [x] Expose current node, elapsed time, budget facts, and next actions in the
      web session UI when projected blocked evidence contains those values.

Exit criteria:

- A live scenario run shows planning, proposal, implementation, verification,
  repair, and final status transitions in real time.
- A timed-out child agent leaves no orphaned `codex exec` process.
- Browser users can see enough progress evidence to stop, approve, or repair a
  run before the final answer.

### Phase 10: Runtime budget allocation and timeout classification

- [x] Track proposal-generation elapsed time as a first-class budget segment.
- [x] Add a proposal budget or proposal heartbeat timeout so coordinator calls
      cannot silently consume most of a scenario budget.
- [x] Add a deterministic proposal seed for generic project-generation
      objectives so RLM patch-mode smoke runs can enter implementation without
      full coordinator LLM graph synthesis.
- [x] Add a parent-owned deterministic edit component for current Elixir
      project-generation smoke profiles.
- [x] Reserve verification and repair budget before launching implementation
      children when the generated graph contains verification or repair nodes.
- [x] Allocate child budgets from graph shape: implementation, verification,
      repair, and final synthesis should each receive bounded budget slices.
- [x] Emit budget-decision events that show parent budget, elapsed time,
      reserved repair time, selected child timeout, and remaining budget.
- [x] Convert parent runtime exhaustion during active child/node execution into
      a structured blocked result when partial execution evidence exists.
- [ ] Persist current node, current child, elapsed time, and last progress event
      in checkpointed blocked-result artifacts, not only final
      message/scorecard projection events.
- [x] Persist current node, current child, elapsed time, and last progress event
      in blocked RLM final-message and scorecard event payloads when active
      workflow evidence exists.
- [x] Persist latest progress and event trail path in smoke matrix reports.

Exit criteria:

- A 65s Field Service run does not spend most of its runtime silently in
  proposal generation without heartbeat evidence.
- A generated plan with repair nodes leaves meaningful runtime for repair.
- Parent budget exhaustion during active node execution reports `blocked` with
  current-node evidence instead of generic `error`.

## Near-Term Execution Order

1. Generalize the parent-owned Elixir project-generation component beyond the
   current seeded profiles, and decide when to prefer deterministic components
   versus resumable child sessions. The current browser catalog passes, but by
   using known-domain generator profiles.
2. Promote the coding-scoped deterministic objective contract into a shared
   `RunicAI.ObjectiveContract` used by assistant, RLM, browser, memory,
   research, and coding routes. Project generation now consumes a contract, but
   only inside the coding RLM seeded route.
3. Completed: `rlm_internal_repair_loop` is relabeled as a parent-loop-only
   harness smoke. Command, semantic, LLM-judge, and runtime-smoke failure
   classes now prove the parent loop, evidence contract, and real
   child-agent/tool path.
4. Persist current node, current child, elapsed time, event trail path, and
   latest progress in checkpointed blocked-result artifacts, not only the
   final message/scorecard event projection.
5. Add integration regression coverage for child subprocess cleanup after full
   RLM child timeout.
6. Generalize behavior-level runtime smoke scripts beyond the seeded Elixir
   profiles and tighten Existing App checks against richer integration
   behavior.
7. Re-run the seven-scenario matrix with live `standard`, `assistant`, `rlm`,
   and browser lanes.
8. Promote repeated failures into regression tests and update this plan with
   completed checkboxes.

## Capability Gate

The RLM should not be described as generally robust until the live matrix can
show, across at least Field Service, Inventory Allocation, Billing, Clinic
Scheduling, Workflow Orchestration, Event-Sourced Audit, and Existing App
Feature:

- accepted objective contracts;
- contract-aware workflow plans;
- working generated artifacts;
- compile/test/runtime evidence;
- meaningful repair on at least one seeded failure;
- browser-visible progress and final evidence;
- no final `ok` status when acceptance checks fail.
