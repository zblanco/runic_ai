# Browser Agentic Scenario Results

Date: 2026-05-09

Sister document for `.docs/042-browser-agentic-scenario-workflows.md`.

This report records a browser/workbench evaluation pass against the scenarios in
the scenario workflow document. Scenario 1 and Scenario 11 were launched through
the browser composer. The remaining batch scenarios were launched through the
same workbench API used by the browser form, with browser inspection of the
resulting session pages where the user-facing behavior mattered most.

The evaluation goal was to compare expected user-facing behavior against actual
RunicAI agent behavior, then identify product, agent, and UX improvements.

## Scenario Results

| Scenario | Session | Expected | Actual | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| 1. Direct Assistance Without Source Grounding | `/sessions/web-session%3AHIDFCM08LK%3AAT%3A694c5dbf` | Complete with one no-source answer | Blocked with a usable three-bullet answer | Fail | Scorecard required provenance even though the prompt explicitly said not to inspect files. |
| 2. Source-Grounded Policy Comparison | `/sessions/web-eval-042-s02-policy-1778351453` | Complete, cite both policy files, include concrete policy deltas | Completed and included the one-day response target, immediate security escalation, and migration contact | Partial | Correct substance, but the final report rendered twice. |
| 3. Structured Ticket Clustering | `/sessions/web-eval-042-s03-tickets-1778351453` | Preserve T1, T2, and T3; fail if records drop | Completed with only T1 visible | Fail | The scorecard still passed despite missing T2 and T3. |
| 4. Meeting Transcript Action Extraction | `/sessions/web-eval-042-s04-meeting-1778351453` | Clean structured report with owners, dates, timestamps | Completed with correct sections and key facts | Partial | Output quality was good, but the final report rendered twice. |
| 5. Artifact Write With Browser HITL | `/sessions/web-eval-042-s05-hitl-1778351453` | Pending review card, wait for approval, then write file | Completed with no review requests and no file write | Fail | Browser showed `Reviews 0`; chat said "Approved" even though no browser approval happened. |
| 6. Unsafe Write Path And Policy Repair | `/sessions/web-eval-042-s06-policy-repair-1778351453` | Reject `tmp/` write, suggest `.docs/`, clearly say no write happened | Completed with no file write and no review | Partial | It avoided the unsafe write, but did not clearly surface the requested write failure as the primary outcome. |
| 7. Repository Research Summary | `/sessions/web-eval-042-s07-repo-1778351453` | Inspect repo, cite paths, complete with source coverage | Blocked for missing provenance | Fail | The answer was generic and provenance was missing after an explicit repo-inspection request. |
| 8. Code Review Scenario | `/sessions/web-eval-042-s08-review-1778351453` | Findings first, no edits, cite paths | Completed with review-shaped findings and cited paths | Partial | Useful answer, but duplicated final message. Findings may still need human verification. |
| 9. Coding Patch Scenario With Review Gate | `/sessions/web-eval-042-s09-patch-1778351453` | Identify files, show review gate before edits | Blocked with a planning response | Fail | No browser review appeared; no files changed, but the patch lane did not reach the expected gated-write workflow. |
| 10. Mermaid Diagram Research | `/sessions/web-eval-042-s10-mermaid-1778351453` | Complete with sourced Mermaid diagram | Blocked for missing provenance | Fail | Mermaid block was present, but repository evidence was not actually grounded. |
| 11. Multi-Turn Continuation | `/sessions/web-session%3AHIDFEU276L%3AX4%3Ac120cb37` | Follow-up uses previous checklist in same session | Completed but asked the user to paste the original checklist | Fail | Browser follow-up submitted with the same `run[session_id]`, but conversation carryover did not reach the agent. |
| 12. Recovery From Bad Or Missing Source | `/sessions/web-eval-042-s12-missing-1778351453` | Block/fail clearly without inventing content | Blocked clearly and named missing path | Pass | User-facing failure was clear enough; still duplicated scorecards internally. |
| 13a. Agent Picker Baseline: assistant | `/sessions/web-eval-042-s13-assistant-1778351453` | Complete or fail clearly | Blocked for missing provenance | Fail | Assistant agent is too strict for direct no-source tasks. |
| 13b. Agent Picker Baseline: standard | `/sessions/web-eval-042-s13-standard-1778351453` | Complete or fail clearly | Completed with one answer | Pass | Standard agent gave the best direct-answer behavior for this scenario. |
| 13c. Agent Picker Baseline: rlm | `/sessions/web-eval-042-s13-rlm-1778351453` | Complete or fail clearly | Session appeared completed, but server logged a task crash | Fail | `RunicAI.Coding.RLM.WorkflowScorecard.fetch/2` crash in final report rendering. |
| 14. Blocked Draft And Repair Visibility | `/sessions/web-eval-042-s14-blocked-1778351453` | Block because second source was missing | Completed with an empty comparison report | Fail | Scorecard passed even though the requested comparison was impossible. |

## Evidence Summary

### Scenario 1: Direct Answer Blocked

Persisted snapshot:

- `status`: `blocked`
- `metrics.messages`: `1`
- `metrics.scorecards`: `3`
- scorecard risk: `source/provenance coverage was required but not present`
- visible answer: three useful bullets that did not claim source evidence

Assessment: direct no-source objectives should not require source provenance.

### Scenario 2: Policy Comparison Substance Passed, UI Duplicated

Persisted snapshot:

- `status`: `completed`
- `metrics.messages`: `2`
- `source_coverage`: `present`
- `provenance_count`: `5`
- expected facts present:
  - response target changed to one business day
  - security incidents escalated immediately
  - enterprise customers receive a migration contact

Assessment: the agent capability worked, but the chat read-model still exposes
two final workflow outputs for the same assistant result.

### Scenario 3: Ticket Clustering Dropped Records

Persisted snapshot:

- `status`: `completed`
- visible content included `T1`
- visible content did not include `T2`
- visible content did not include `T3`
- scorecard status: `objective_satisfied`

Assessment: this is a correctness bug, not just UX friction. The workflow lost
source records and the scorecard did not detect the record loss.

### Scenario 5: Browser HITL Did Not Happen

Browser session page:

- Chat tab showed two identical messages saying the write was approved.
- Reviews tab showed `Reviews 0`.
- No `.docs/browser-hitl-meeting-report.md` file was created.

Persisted snapshot:

- `status`: `completed`
- `metrics.review_requests`: `0`
- `metrics.artifacts`: `2`, both workflow metadata artifacts, not the requested report
- filtered runtime details showed a repair path that removed the artifact write

Assessment: this is high-severity UX friction. The user asked for approval-gated
artifact writing, but the agent converted that into a conversational approval
claim. The browser never became the decision point.

### Scenario 6: Unsafe Write Avoided But Not Explained

Filesystem check:

- `tmp/browser-policy-should-not-write.md` did not exist.

Persisted snapshot:

- `status`: `completed`
- `metrics.review_requests`: `0`
- visible output summarized the transcript

Assessment: the policy guard avoided the unsafe file write, but the final answer
should explicitly say the requested `tmp/` artifact was not written and should
offer a safe `.docs/` target.

### Scenario 11: Same Session, No Conversation Carryover

Browser follow-up form submitted:

- `run[session_id]`: `web-session:HIDFEU276L:X4:c120cb37`
- objective: `Now turn that checklist into acceptance criteria and keep the same order.`

Persisted snapshot:

- first answer: five-point checklist
- follow-up answer: `I can do that, but I need the original checklist first.`
- status: `completed`
- visible messages: `4` because each answer was duplicated

Assessment: same-session submission works at the UI/form level, but the agent
does not receive enough prior chat context to resolve the follow-up.

### Scenario 13c: RLM Agent Crash

Server error log:

```text
** (UndefinedFunctionError) function RunicAI.Coding.RLM.WorkflowScorecard.fetch/2 is undefined
...
lib/runic_ai/terminal/event_presenter.ex:204: RunicAI.Terminal.EventPresenter.render_rlm_final_report/1
```

Assessment: the final report presenter treats a `WorkflowScorecard` struct like
an Access-compatible map. This creates a confusing agent-picker baseline because
the browser can show a completed-looking session while the server logs a task
crash.

## Findings

1. Browser HITL is not a real blocking decision surface yet.

   `approval: ask` did not produce a pending review request for Scenario 5. The
   run completed with an "Approved" message, no review card, and no requested
   artifact file. This breaks the core expectation that the browser can approve,
   deny, stop, or rewrite gated work.

2. Assistant final outputs are still duplicated in chat for successful RLM runs.

   Scenarios 2, 4, 5, 6, 8, and 11 showed duplicate visible messages. The
   duplicates make it harder to tell which output is the authoritative final
   answer and create noise in multi-turn sessions.

3. Structured record workflows can silently drop records and still pass.

   Scenario 3 produced only `T1` from a three-record JSONL input while the
   scorecard reported `objective_satisfied`. This undermines trust in record
   clustering, triage, and batch summarization tasks.

4. Source/provenance requirements are over-applied for direct assistance and
   under-satisfied for repo research.

   Direct tasks that explicitly say "do not inspect files" still block on
   missing provenance, while repo research and Mermaid research can produce
   generic-looking output without real source grounding and then block late.

5. Missing-input and impossible-comparison cases are not scored strictly enough.

   Scenario 14 completed with an effectively empty comparison report even though
   the user intentionally omitted the second document. The scorecard accepted
   provenance from the one available source instead of checking whether the
   comparison objective itself was satisfiable.

6. Multi-turn continuity is not connected to the assistant planner.

   The browser includes the same session id in the follow-up request, but the
   assistant still asks the user to paste prior content. The planner sees
   `conversation_history_count` in traces, but the generated prompt/context is
   not sufficient for practical continuation.

7. Agent picker labels expose implementation names without operational guidance.

   The same direct objective behaved differently across `assistant`, `standard`,
   and `rlm`: assistant blocked, standard completed cleanly, and rlm logged a
   server crash. The UI does not explain these tradeoffs before launch.

8. Artifact-write objectives can be repaired into non-write answers without a
   clear user-facing contract.

   Scenario 5 and Scenario 6 both avoided durable writes, but Scenario 5 claimed
   approval and Scenario 6 did not foreground the blocked write. The user needs
   a clear distinction between "artifact written", "write denied", "write
   policy blocked", and "answer produced instead".

## Recommendations

1. Implement browser-backed HITL as a durable pause/resume path.

   Replace the current browser `input_fun` fallback for `approval: ask` with a
   review bridge that creates a pending review request, pauses agent execution,
   and resumes only after `RunicAI.Workbench.record_review_decision/3` records
   approve, deny, stop, or rewrite. The review card should show target path,
   policy, risk metadata, and content preview before any mutation.

2. Deduplicate assistant final outputs at the projection/read-model boundary.

   Keep intermediate workflow output transient and expose only one final
   assistant message per completed assistant result. If both a workflow-completed
   event and an assistant-final-output event contain identical content, prefer
   the explicit assistant final output and hide the redundant workflow row.

3. Add record-count invariants to structured workflows and scorecards.

   `tabular_parser` and `record_group` should carry `input_record_count`,
   `output_record_count`, and dropped-record diagnostics. The scorecard should
   fail when a prompt says to preserve every record/id and the output lacks any
   parsed source ids.

4. Fix ticket dedupe defaults for real schemas.

   The ticket recipe should recognize `ticket_id` as a primary identity key, not
   only `ticket` or `id`. More generally, dedupe should avoid collapsing records
   when a configured key is missing; missing-key rows need per-record identity or
   an explicit validation failure.

5. Split direct-answer and source-grounded objective policy.

   Add an objective classifier or planner signal for "direct assistance, no
   source inspection requested" so direct answers do not require provenance. For
   repo/file/research objectives, require actual discovered source artifacts and
   make late generic fallback fail with a useful blocked draft.

6. Tighten comparison objective validation.

   Document comparison should require two or more comparable source documents
   unless the objective explicitly asks for a single-source summary. A one-source
   comparison should block with "missing comparison source" instead of producing
   an empty report and passing.

7. Thread conversation history into follow-up prompts.

   For same-session launches, include prior visible user/assistant messages in
   the assistant input context and test pronoun/reference continuations such as
   "that checklist", "the previous answer", and "same order".

8. Fix RLM final report rendering for struct scorecards.

   `RunicAI.Terminal.EventPresenter.render_rlm_final_report/1` should use
   struct fields or normalize scorecards to maps before using Access-style
   reads. Add a regression test using `RunicAI.Coding.RLM.WorkflowScorecard`.

9. Make launch controls explain practical runtime choices.

   Add concise helper text or a details disclosure for:

   - `assistant`: best for RLM-style source workflows and structured assistant
     reports, currently stricter about scorecards.
   - `standard`: best for direct conversational answers and simple local agent
     runs.
   - `rlm`: coding/RLM workflow path with scorecard and patch-oriented behavior.

   The UI should also show mode/approval implications: `verify` should not
   mutate files, `patch` can propose writes, and `ask` should pause in the
   browser.

10. Make write-policy outcomes explicit in final messages.

    Every artifact objective should end with a durable status line:

    - `artifact_written: path`
    - `artifact_not_written: denied`
    - `artifact_not_written: policy_blocked`
    - `artifact_not_written: repair_answer_only`

    This status should be persisted in artifact/review metadata and rendered in
    chat.

## Regression Targets

The next evaluation pass should treat these as passing criteria:

- Scenario 1 completes without source/provenance risk.
- Scenario 2 renders one final report.
- Scenario 3 includes T1, T2, and T3 or fails loudly.
- Scenario 5 shows a pending review card and does not continue before browser
  approval.
- Scenario 7 cites real repo paths with present source coverage.
- Scenario 11 converts the prior checklist without asking the user to paste it.
- Scenario 13c has no server error log.
- Scenario 14 blocks with a missing comparison-source reason.

