# Browser Agentic Scenario Remediation Implementation Plan

Date: 2026-05-09

Related documents:

- `.docs/042-browser-agentic-scenario-workflows.md`
- `.docs/042-browser-agentic-scenario-results.md`

This plan turns the 042 browser scenario findings into implementation slices.
The goal is to make the browser workbench a trustworthy operator surface for
assistant, standard, and RLM runs: no phantom approvals, no duplicated final
answers, no silent record loss, and clear blocked/completed states.

## Goals

- Browser `approval: ask` becomes a real pending review and resume path.
- Successful assistant RLM runs render one authoritative final answer.
- Structured record workflows preserve source records or fail visibly.
- Direct no-source assistance does not block on provenance.
- Source-grounded tasks require real source coverage and cite real paths.
- Same-session follow-ups receive prior conversation context.
- Missing comparison inputs block with a useful reason.
- Agent picker/runtime errors are surfaced cleanly and do not crash background
  tasks.

## Non-Goals

- Do not redesign the full planner or replace the current RLM component
  substrate.
- Do not require remote model calls in unit tests.
- Do not add broad UI redesign work beyond launch guidance and review controls
  needed to resolve the 042 failures.
- Do not move persistence away from the existing SQLite read model.

## Definition Of Done

The implementation is complete when:

- The focused regression tests added in this plan pass.
- `mix test` passes.
- A browser rerun of the regression targets from
  `.docs/042-browser-agentic-scenario-results.md` shows:
  - Scenario 1 completes without source/provenance risk.
  - Scenario 2 renders one final report.
  - Scenario 3 includes `T1`, `T2`, and `T3` or fails loudly.
  - Scenario 5 shows a pending review card and does not continue before browser
    approval.
  - Scenario 7 cites real repo paths with present source coverage.
  - Scenario 11 converts the prior checklist without asking the user to paste
    it.
  - Scenario 13c has no server error log.
  - Scenario 14 blocks with a missing comparison-source reason.

## Implementation Slices

### Slice 1: Baseline Regression Harness

Status: [x] Completed

Purpose: capture the 042 failures in focused tests before changing behavior.

Deliverables:

- [x] Add scenario-specific regression tests around persisted workbench
      projections in `test/runic_ai/workbench_test.exs` or a new
      `test/runic_ai/workbench_042_scenario_test.exs`.
- [x] Add component-level tests for record grouping, document comparison, and
      objective scorecard behavior in `test/runic_ai/assistant/rlm_components_test.exs`.
- [x] Add terminal presenter coverage for RLM scorecard structs in
      `test/runic_ai/terminal/runner_test.exs` or
      `test/runic_ai/terminal/event_presenter_test.exs`.
- [x] Add LiveView tests for review card buttons and launch helper copy in
      `test/runic_ai_web/workbench_live_test.exs`.

Test cases to add:

- [x] Direct no-source objective does not require provenance.
- [x] Duplicate assistant workflow output rows collapse to one visible message.
- [x] Ticket clustering preserves `ticket_id` values `T1`, `T2`, and `T3`.
- [x] A comparison objective with only one source returns an incomplete
      scorecard or blocked result.
- [x] Same-session follow-up passes prior visible messages as conversation
      history.
- [x] `RunicAI.Coding.RLM.WorkflowScorecard` can render in terminal final
      reports without Access errors.

Verification:

```bash
mix test test/runic_ai/workbench_test.exs
mix test test/runic_ai/assistant/rlm_components_test.exs
mix test test/runic_ai/terminal/runner_test.exs
mix test test/runic_ai_web/workbench_live_test.exs
```

Expected result before fixes: at least some new tests fail and reproduce the
042 issues.

### Slice 2: Browser HITL Pause And Resume

Status: [x] Completed

Purpose: make `approval: ask` in the browser a real blocking review surface
instead of a terminal fallback that auto-denies or a repair path that claims
approval.

Primary modules:

- `lib/runic_ai/workbench.ex`
- `lib/runic_ai/terminal/agent_runner.ex`
- `lib/runic_ai/terminal/review_prompt.ex`
- `lib/runic_ai/rlm/component_runtime.ex`
- `lib/runic_ai/persistence/harness_projection.ex`
- `lib/runic_ai_web/live/workbench_live.ex`

Deliverables:

- [x] Replace the browser `input_fun: fn _prompt -> "d\n" end` fallback in
      `RunicAI.Workbench.run_agent/1` with a browser-aware review decider.
- [x] Persist every browser review request as `pending` before returning a
      decision to the agent runtime.
- [x] Include review details needed by the UI:
      - kind/checkpoint/resume key
      - target path
      - write policy
      - risk/safety metadata
      - artifact content preview
      - suggested safe paths when applicable
- [x] Block agent continuation until `Workbench.record_review_decision/3`
      records approve, deny, stop, or rewrite for the same review id/resume key.
- [x] Broadcast review decision events so a running browser-launched task can
      resume without polling-only latency.
- [x] Re-read SQLite before resuming so the bridge is backed by the durable
      read model, not only process memory.
- [x] Return clear runtime outcomes:
      - approve -> continue and write
      - deny -> block and do not write
      - stop -> cancelled/blocked and do not write
      - rewrite -> continue with edited content/instructions
- [x] Ensure write-policy-invalid paths do not create misleading approval cards.

Recommended approach:

1. Add a small `RunicAI.Workbench.ReviewBridge` module or equivalent private
   workbench helper.
2. The bridge should create/persist a pending review event through the same
   terminal event path already consumed by `HarnessProjection`.
3. The bridge should wait on a PubSub decision message keyed by session id and
   review id, with a bounded timeout that leaves the session in a waiting or
   blocked state.
4. `record_review_decision/3` should persist the decision and broadcast the
   exact resume key.
5. The decider should translate persisted decisions into the existing
   `RunicAI.ReviewDecision` / review prompt decision shape expected by
   `AgentRunner`.

Verification:

- Unit/focused tests:

```bash
mix test test/runic_ai/workbench_test.exs
mix test test/runic_ai_web/workbench_live_test.exs
mix test test/runic_ai/assistant/rlm_agent_test.exs
```

- Browser/Tidewave regression:

1. Launch Scenario 5 from `.docs/042-browser-agentic-scenario-workflows.md`
   with `approval: ask`.
2. Before clicking any review button:
   - `snapshot.session.status` should be `running`, `waiting`, or `review`.
   - `snapshot.review_requests` should contain one pending
     `assistant_artifact_write`.
   - `.docs/browser-hitl-meeting-report.md` should not exist.
3. Click Approve in the browser.
4. After approval:
   - review status should be `approved`.
   - file should exist.
   - final chat should include `artifact_written:
     .docs/browser-hitl-meeting-report.md`.
5. Repeat with Deny/Stop:
   - file should not exist.
   - final chat should include `artifact_not_written: denied` or
     `artifact_not_written: cancelled`.

### Slice 3: Artifact Outcome Contract

Status: [x] Completed

Purpose: make artifact-write outcomes explicit and machine-checkable.

Primary modules:

- `lib/runic_ai/rlm/component_runtime.ex`
- `lib/runic_ai/rlm/components/artifact_writer.ex`
- `lib/runic_ai/rlm/components/objective_scorecard.ex`
- `lib/runic_ai/terminal/event.ex`
- `lib/runic_ai/persistence/harness_projection.ex`

Deliverables:

- [x] Add an artifact outcome payload for every artifact objective:
      - `artifact_written`
      - `artifact_not_written: denied`
      - `artifact_not_written: cancelled`
      - `artifact_not_written: policy_blocked`
      - `artifact_not_written: repair_answer_only`
- [x] Persist this outcome on the final message content JSON and, when
      applicable, artifact/review metadata.
- [x] Make repair paths preserve the requested write status instead of
      silently converting to a normal answer.
- [x] For policy-blocked paths, include suggested `.docs/` alternatives in the
      final chat and review/details metadata.
- [x] Prevent the agent from saying "Approved" unless a persisted browser
      review decision exists.

Verification:

- Scenario 5 approved run has `artifact_written`.
- Scenario 5 denied run has `artifact_not_written: denied`.
- Scenario 6 has `artifact_not_written: policy_blocked` and suggests a `.docs/`
  path.
- No requested file under `tmp/` is created in Scenario 6.

### Slice 4: Assistant Chat Message Deduplication

Status: [x] Completed

Purpose: restore a clean chat transcript where each assistant turn has one
authoritative visible final message.

Primary modules:

- `lib/runic_ai/workbench.ex`
- `lib/runic_ai/persistence/harness_projection.ex`
- `lib/runic_ai/terminal/event.ex`
- `test/runic_ai/workbench_test.exs`

Deliverables:

- [x] Audit how assistant RLM completion events and final output message events
      become `agent_messages`.
- [x] Prefer one explicit final assistant output row per run/turn.
- [x] Mark provisional workflow-output rows transient when an equivalent final
      assistant output row exists.
- [x] Harden `RunicAI.Workbench.visible_chat_messages/1` so identical
      non-transient workflow outputs for the same run collapse to one visible
      message.
- [x] Preserve legitimate repeated text inside a single answer; only dedupe
      duplicate message rows, not repeated tokens or paragraphs.
- [x] Ensure scorecard summaries do not become chat-visible when a substantive
      assistant answer exists.

Verification:

```bash
mix test test/runic_ai/workbench_test.exs
mix test test/runic_ai/persistence/sqlite_test.exs
mix test test/runic_ai/terminal/event_test.exs
```

Browser/Tidewave checks:

- Scenario 2 `snapshot.metrics.messages == 1`.
- Scenario 4 `snapshot.metrics.messages == 1`.
- Scenario 8 `snapshot.metrics.messages == 1`.
- Multi-turn Scenario 11 shows one visible answer per turn, not two.

### Slice 5: Structured Record Preservation

Status: [x] Completed

Purpose: prevent ticket/record workflows from silently dropping source records.

Primary modules:

- `lib/runic_ai/assistant/rlm/coordinator.ex`
- `lib/runic_ai/rlm/components/record_group.ex`
- `lib/runic_ai/rlm/components/objective_scorecard.ex`
- `test/runic_ai/assistant/rlm_blueprint_test.exs`
- `test/runic_ai/assistant/rlm_components_test.exs`

Deliverables:

- [x] Change ticket recipe defaults to include `ticket_id` as the primary
      identity key.
- [x] Update `RecordGroup.dedupe/2` so missing configured identity keys do not
      collapse unrelated records into one group.
- [x] Emit structured diagnostics from record grouping:
      - `input_record_count`
      - `output_record_count`
      - `group_count`
      - `record_ids`
      - `dropped_record_ids`
      - `missing_identity_key_count`
- [x] Carry record diagnostics into the report and scorecard input.
- [x] Fail the scorecard when an objective says to preserve every id and any
      parsed record id is missing from the final output.
- [x] Include dropped-record diagnostics in the final blocked draft when the
      workflow cannot satisfy record preservation.

Verification:

```bash
mix test test/runic_ai/assistant/rlm_blueprint_test.exs
mix test test/runic_ai/assistant/rlm_components_test.exs
mix test test/runic_ai/assistant/rlm_agent_test.exs
```

Browser/Tidewave checks:

- Scenario 3 includes `T1`, `T2`, and `T3` with login count `2` and billing
  count `1`.
- If a synthetic JSONL file lacks `ticket_id`, the final status is blocked or
  includes a clear missing identity-key warning.

### Slice 6: Source And Provenance Policy Split

Status: [x] Completed

Purpose: make source requirements match user intent.

Primary modules:

- `lib/runic_ai/assistant/rlm/agent.ex`
- `lib/runic_ai/assistant/rlm/coordinator.ex`
- `lib/runic_ai/assistant/rlm/blueprint_proposal_prompt.ex`
- `lib/runic_ai/rlm/components/objective_scorecard.ex`

Deliverables:

- [x] Add or refine objective classification for:
      - direct assistance/no-source requested
      - explicit source/file/repo inspection
      - comparison
      - artifact write
      - missing source recovery
- [x] For direct no-source tasks, set `require_provenance?: false` and
      `source_coverage: not_required`.
- [x] For repo/file/research/code-review tasks, require discovered source
      artifacts and provenance.
- [x] If source discovery finds no relevant sources for a source-required
      objective, block with a clear missing-source or insufficient-source reason
      before producing a generic answer.
- [x] Prevent generic repo summaries from passing as source-grounded research.
- [x] Ensure Mermaid/research responses cite real paths when source grounding is
      required.

Verification:

```bash
mix test test/runic_ai/assistant/rlm_agent_test.exs
mix test test/runic_ai/assistant/rlm_blueprint_test.exs
mix test test/runic_ai/assistant/rlm_components_test.exs
```

Browser/Tidewave checks:

- Scenario 1 completes with `source_coverage: not_required`.
- Scenario 7 completes with present source coverage and cites:
  - `lib/runic_ai/workbench.ex`
  - `lib/runic_ai_web/live/workbench_live.ex`
  - `lib/runic_ai/persistence/harness_projection.ex`
  - `lib/runic_ai/assistant/rlm/agent.ex`
- Scenario 10 completes with a Mermaid block and present source coverage.
- Scenario 12 remains blocked/failed clearly for the missing source path.

### Slice 7: Comparison Objective Validation

Status: [x] Completed

Purpose: make impossible comparison requests block instead of producing empty
reports.

Primary modules:

- `lib/runic_ai/rlm/components/document_compare.ex`
- `lib/runic_ai/rlm/components/report_composer.ex`
- `lib/runic_ai/rlm/components/objective_scorecard.ex`
- `lib/runic_ai/assistant/rlm/coordinator.ex`

Deliverables:

- [x] Require at least two comparable source documents for comparison
      objectives unless the objective explicitly requests a single-source
      summary.
- [x] Return a structured diagnostic from `DocumentCompare` when fewer than two
      comparable sources are available.
- [x] Prevent `ReportComposer` from turning zero comparisons into an empty
      "successful" comparison report.
- [x] Make the scorecard fail when `comparison_required? == true` and
      `comparison_count == 0`.
- [x] Render the blocked draft with a direct next action, such as "provide the
      second policy document path".

Verification:

```bash
mix test test/runic_ai/assistant/rlm_components_test.exs
mix test test/runic_ai/assistant/rlm_agent_test.exs
```

Browser/Tidewave checks:

- Scenario 2 still completes successfully with two policy files.
- Scenario 14 blocks with missing comparison-source reason and does not render
  an empty report as completed.

### Slice 8: Same-Session Conversation Carryover

Status: [x] Completed

Purpose: make browser follow-ups behave like real conversation turns.

Primary modules:

- `lib/runic_ai/workbench.ex`
- `lib/runic_ai/terminal/agent_runner.ex`
- `lib/runic_ai/assistant/rlm/agent.ex`
- `lib/runic_ai/assistant/rlm/blueprint_proposal_prompt.ex`
- `lib/runic_ai_web/live/workbench_live.ex`

Deliverables:

- [x] When `start_agent_run/1` receives an existing `session_id`, load prior
      visible chat messages from SQLite.
- [x] Convert prior messages into the `conversation_history` shape expected by
      `AgentRunner`.
- [x] Exclude transient/provisional rows from conversation history.
- [x] Deduplicate repeated final rows before passing history to the agent.
- [x] Include both prior user objectives and assistant final answers.
- [x] Make assistant conversation-response blueprints use
      `conversation_context` for references like "that checklist", "same
      order", and "the previous answer".

Verification:

```bash
mix test test/runic_ai/workbench_test.exs
mix test test/runic_ai/assistant/rlm_agent_test.exs
mix test test/runic_ai_web/workbench_live_test.exs
```

Browser/Tidewave checks:

1. Run Scenario 11 part 1 in the browser.
2. Submit the follow-up in the same session.
3. Assert the second answer maps the five original checklist items to
   acceptance criteria.
4. Assert it does not ask the user to paste the checklist.
5. Assert visible messages are one answer per turn.

### Slice 9: RLM Scorecard Rendering Crash

Status: [x] Completed

Purpose: fix the Scenario 13c task crash and make agent picker failures
trustworthy.

Primary modules:

- `lib/runic_ai/terminal/event_presenter.ex`
- `lib/runic_ai/coding/rlm/workflow_scorecard.ex`
- `test/runic_ai/terminal/runner_test.exs`
- `test/runic_ai/terminal/event_test.exs`

Deliverables:

- [x] Update `RunicAI.Terminal.EventPresenter.render_rlm_final_report/1` to use
      struct fields or normalize scorecards to maps before Access-style reads.
- [x] Add a regression test with
      `%RunicAI.Coding.RLM.WorkflowScorecard{}` containing `changed_files`,
      `acceptance_results`, and `residual_risks`.
- [x] Ensure any task crash becomes a persisted failed session with a visible
      error message instead of only an error log.

Verification:

```bash
mix test test/runic_ai/terminal/runner_test.exs
mix test test/runic_ai/terminal/event_test.exs
```

Browser/Tidewave checks:

- Scenario 13c with agent `rlm` finishes without an error log matching
  `WorkflowScorecard.fetch/2`.
- If the run fails for legitimate reasons, the session status and chat explain
  the failure.

### Slice 10: Launch Controls And Agent Picker Guidance

Status: [x] Completed

Purpose: reduce operator confusion before launching a run.

Primary module:

- `lib/runic_ai_web/live/workbench_live.ex`

Deliverables:

- [x] Add compact helper text or a details disclosure for agent choices:
      - `assistant`: structured/source-grounded RLM assistant workflows
      - `standard`: direct conversational/local agent runs
      - `rlm`: coding/RLM scorecard and patch-oriented workflows
- [x] Add mode hints:
      - `verify`: inspect/analyze without intended mutation
      - `patch`: may propose file changes
      - `read only`: no writes expected
- [x] Add approval hints:
      - `safe`: auto-approve low-risk policy-compatible actions
      - `ask`: pause in browser before gated actions
      - `never`: deny writes/reviews
- [x] Ensure helper text is concise and does not crowd the composer.

Verification:

```bash
mix test test/runic_ai_web/workbench_live_test.exs
```

Browser checks:

- `/sessions/new` explains agent/mode/approval tradeoffs without requiring
  internal implementation knowledge.
- Agent picker Scenario 13 can be interpreted from the UI before running.

## Final Verification Pass

After all slices are implemented:

```bash
mix format
mix test
```

Then rerun the browser scenarios from
`.docs/042-browser-agentic-scenario-workflows.md`:

- Scenario 1
- Scenario 2
- Scenario 3
- Scenario 5 with approve
- Scenario 5 with deny/stop
- Scenario 6
- Scenario 7
- Scenario 10
- Scenario 11
- Scenario 12
- Scenario 13 across `assistant`, `standard`, and `rlm`
- Scenario 14

For each rerun, record:

- session URL
- actual status
- visible message count
- review request count/status
- artifact outcome
- source coverage/provenance count
- scorecard status and residual risks
- server error log check

Expected final state:

- No duplicate final assistant messages.
- No unapproved writes.
- No silent record drops.
- No source-required task completes without source coverage.
- No direct no-source task blocks on provenance.
- No same-session follow-up loses prior context.
- No RLM scorecard renderer crash.

## Implementation Update - 2026-05-09

Completed in this pass:

- Slice 1 regression coverage for workbench review flow, duplicate final
  messages, record preservation, comparison scorecards, artifact review
  scheduling, and RLM scorecard rendering.
- Slice 2 browser HITL pause/resume. Browser-launched `approval: ask` runs now
  persist pending review requests, wait on durable browser decisions, and resume
  after approval.
- Slice 4 visible chat deduplication. Equivalent assistant final workflow-output
  rows collapse to one visible message.
- Slice 5 core record preservation. Ticket recipes prefer `ticket_id`, missing
  identity keys no longer collapse unrelated records, and record diagnostics are
  carried through report outputs.
- Slice 6 source/provenance split for direct no-source tasks and
  workspace-grounded path inference.
- Slice 7 comparison-required scorecard failure when fewer than two comparable
  sources are available.
- Slice 8 same-session conversation carryover from prior visible messages.
- Slice 9 RLM scorecard rendering crash fix for
  `%RunicAI.Coding.RLM.WorkflowScorecard{}`.

Additional fixes made while verifying:

- Browser review decisions now accept approval/deny/stop payloads without a
  `rewrite` field.
- Reviewed artifact writer nodes override generated 10s IO scheduler policies
  with the human-review runtime window.
- Artifact synthesis strips runtime approval instructions from the LLM-facing
  objective so "wait for approval" does not become artifact content.
- Review metadata now includes the artifact text preview.
- Successful artifact final messages carry `artifact_paths` and an
  `artifact_outcome` payload.
- Workbench launch accepts per-run `max_runtime_ms` values.
- `WorkbenchTest` now migrates its own SQLite store, removing cross-file test
  order coupling.
- LiveView terminal-event refreshes are now debounced and hydrated through
  `start_async/3`, so workspace/inspector tab clicks are not blocked behind
  SQLite snapshot loading and Markdown rendering while a workflow is running.

Verification completed:

```bash
mix test test/runic_ai/terminal/event_test.exs test/runic_ai/terminal/runner_test.exs test/runic_ai/workbench_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/assistant/rlm_agent_test.exs test/runic_ai_web/workbench_live_test.exs
# 65 tests, 0 failures

mix test
# 571 tests, 0 failures, 2 skipped
```

Browser/Tidewave approval verification:

- Session:
  `/sessions/web-eval-042-hitl-click-fixed-1778353919`
- Before approval:
  - status: `review`
  - review status: `pending`
  - file `.docs/browser-hitl-meeting-report.md`: absent
  - visible preview contained the actual meeting report sections
- Browser click:
  - `Approve once` returned `true`
  - LiveView displayed `Review decision recorded`
- After approval:
  - session status: `completed`
  - review status: `approved`
  - visible messages: `1`
  - file `.docs/browser-hitl-meeting-report.md`: present
  - artifact table includes `.docs/browser-hitl-meeting-report.md`
  - file content includes Decisions, Actions, Risks, and Open Questions from
    `tmp/assistant_meeting_transcript.md`

Browser/Tidewave tab-responsiveness verification:

- Session: `/sessions/web-tabs-flood-1778354377`
- A burst of 80 persisted terminal events was broadcast to the selected
  session.
- During the event burst:
  - `Plan` tab click returned `true`
  - inspector `Details` tab click returned `true`
  - the Plan tab rendered the updated persisted projection with `81 events`
- Error log check for `web-tabs` returned no entries.

Final follow-up completion:

- Slice 3 now carries explicit not-written outcomes for denied, cancelled,
  policy-blocked, and answer-only artifact paths. Runtime errors expose a
  normalized `artifact_outcome`, terminal error events promote it into
  message `content_json`, and projected error messages include the visible
  `artifact_not_written: ...` line with suggested `.docs/` paths when present.
- Browser rewrite decisions now continue the artifact write using the edited
  content instead of being handled as a blocked/denied review outcome.
- Slice 10 now uses a compact composer `Run setup` disclosure for agent, mode,
  and approval hints without expanding the default composer footprint.

Final verification:

```bash
mix format --check-formatted
# passed

mix test test/runic_ai/terminal/event_test.exs test/runic_ai/terminal/runner_test.exs
# 18 tests, 0 failures

mix test test/runic_ai/assistant/rlm_agent_test.exs test/runic_ai_web/workbench_live_test.exs
# 30 tests, 0 failures

mix test
# 576 tests, 0 failures, 2 skipped
```

Browser/Tidewave verification:

- `/sessions/new` composer exposes the compact `Run setup` disclosure.
- Expanding it shows the expected `assistant`, `standard`, `rlm`, `verify`,
  `patch`, `read only`, `safe`, `ask`, and `never` hints.
- Runtime evaluation of `RunicAI.Terminal.Event.artifact_outcome_from_error/1`
  returned `%{status: "artifact_not_written", reason: "denied", path:
  ".docs/report.md", suggested_paths: [".docs/report.md"]}`.

## Suggested Implementation Order

1. Slice 1: Baseline Regression Harness
2. Slice 2: Browser HITL Pause And Resume
3. Slice 3: Artifact Outcome Contract
4. Slice 4: Assistant Chat Message Deduplication
5. Slice 5: Structured Record Preservation
6. Slice 6: Source And Provenance Policy Split
7. Slice 7: Comparison Objective Validation
8. Slice 8: Same-Session Conversation Carryover
9. Slice 9: RLM Scorecard Rendering Crash
10. Slice 10: Launch Controls And Agent Picker Guidance
11. Final browser scenario rerun and results update
