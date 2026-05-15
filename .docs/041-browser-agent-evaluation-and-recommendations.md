# Browser Agent Evaluation And Recommendations

Date: 2026-05-09

This note records a browser-driven QA pass over the local RunicAI workbench at
`/sessions/new`. The goal was to interact with the app as a user would, launch
real agent sessions through the LiveView composer, compare outcomes against
expected assistant behavior, and identify friction in the agent UX and runtime
capabilities.

## Setup

Runtime:

- workspace: `/home/doops/wrk/runic_ai`
- browser route: `http://localhost:4000/sessions/new`
- default agent: `assistant`
- default model: assistant runtime default, currently `openai:gpt-5.4-mini`
- persistence: `.runic_ai/runs.db`
- fixtures:
  - `tmp/assistant_tickets.jsonl`
  - `tmp/assistant_policy_old.md`
  - `tmp/assistant_policy_new.md`
  - `tmp/assistant_meeting_transcript.md`

Verification surfaces:

- browser form submissions through Tidewave browser interactions.
- `RunicAI.Workbench.session_snapshot/1` for persisted messages, events,
  scorecards, reviews, and artifacts.
- browser snapshot of rendered chat output.
- server error logs; no error logs were recorded during this pass.

## Expectations

The workbench should support the following common operator workflows:

- Direct answer: return a useful non-source answer without forcing provenance
  when the user explicitly says not to inspect files.
- Source-grounded comparison: infer explicit path references, read both files,
  compare concrete changes, and render one final answer.
- Structured-data analysis: parse all records, group them reliably, preserve IDs
  and counts, and fail or warn if records are dropped.
- Write with HITL: when approval is set to `ask`, pause for browser review before
  writing, show policy/risk/path details, then continue based on the user's
  browser decision.
- Agent choice: make it clear when to use `assistant`, `standard`, or `rlm`, and
  expose enough launch configuration to express inputs, outputs, model/client,
  approval policy, and write policy.

## Sessions

| Session | Browser Task | Expected | Actual |
| --- | --- | --- | --- |
| `web-session:HIDC2F52EV:L:bfff9ea5` | Direct three-bullet answer, explicitly "Do not inspect files" | Complete with a direct answer and no provenance gate | Produced a useful answer, but ended `blocked` with `source/provenance coverage was required but not present` |
| `web-session:HIDC2TZ0QM:24:9f5fc7f4` | Compare old/new support policy files | Read both files, return concrete deltas, complete | Completed and captured all expected policy changes, but rendered the same final report twice |
| `web-session:HIDC37A8IX:3B:1e3a774f` | Cluster support tickets from JSONL | Include all three tickets, two themes, correct counts and severities | Completed, but output only included `T1`; `T2` and `T3` were lost |
| `web-session:HIDC3JYSUL:4O:7ae843d0` | Write a report to `.docs/browser-eval-hitl-report.md` with approval intended as ask | Browser review should wait for a manual decision before writing | The run launched with `approve: safe`, auto-approved the write, created the artifact, duplicated the report, and the artifact repeated the same content under every requested section |
| `web-session:HIDC49CKM2:6Y:bc315210` | Controlled `approve: ask` write probe | Browser review should stay pending with actionable approve/deny/rewrite/stop buttons | The launch correctly recorded `approve: ask`, but terminal-shaped review handling immediately denied the write with no browser decision; repair then completed with a non-written answer |

## Observed Strengths

- Browser launch and session routing worked reliably for assistant runs. Each
  successful submit created a session and navigated to `/sessions/:id`.
- Explicit path inference worked in browser-launched sessions. The policy
  comparison and meeting transcript write tasks found the referenced files.
- The policy comparison recipe is materially better after the previous fixes:
  it found both old/new files, emitted provenance, and completed with
  `source_coverage: present`.
- The blocked-draft UI cue works. Direct-answer session
  `web-session:HIDC2F52EV:L:bfff9ea5` showed a visible blocked draft with the
  blocking reason.
- Artifact write policy details are now visible in review records. Review
  details included path, write policy, suggested `.docs/` path, and input
  preview.

## Issues

### 1. Direct Answers Can Be Incorrectly Blocked By Provenance

The direct-answer task explicitly said not to inspect files. The assistant still
ended blocked for missing source/provenance, even though it produced a useful
answer.

Impact:

- A normal chat answer looks failed in the browser.
- Users may learn to ignore blocked status, which weakens the value of the
  scorecard.

Recommendation:

- Split objective classification before scorecard setup:
  - `direct_answer`: no provenance required unless the user requests source
    grounding.
  - `source_grounded_answer`: provenance required.
  - `artifact_write`: artifact and write-policy checks required.
- Respect explicit user constraints like "do not inspect files" as a strong
  signal against `require_provenance?`.
- Show why a scorecard required provenance in the UI, not only the missing
  reason.

### 2. Completed Assistant Runs Render Duplicate Final Messages

The policy compare, ticket cluster, and write sessions all rendered two
identical `workflow_output` messages. One came from the workflow completed
stage; the other came from the final assistant result message.

Impact:

- The chat transcript looks noisy and less trustworthy.
- It obscures whether repair improved the final answer or just duplicated it.

Recommendation:

- Deduplicate visible assistant workflow outputs by run, content hash, and
  message kind.
- Prefer one canonical final answer row:
  - provisional node outputs should stay transient.
  - completed-stage output and final-result output should collapse to one
    visible message.
- Keep the scorecard/status metadata attached to that canonical final message.

### 3. Ticket Clustering Dropped Records But Still Passed

The JSONL ticket clustering run produced only:

```text
T1: login, high, admins blocked
```

Expected:

- `T1` and `T3` in the login/SSO group.
- `T2` in the billing group.
- counts: login = 2, billing = 1.

Likely cause:

- The curated ticket recipe defaulted dedupe keys to `["ticket", "id"]`, while
  the records use `ticket_id`.
- Missing dedupe keys collapse to the same `nil` value, so records can be
  incorrectly deduped away.
- The scorecard accepted the truncated report because it only saw provenance,
  not expected record coverage.

Recommendation:

- Make `record_group` dedupe skip keys that are absent on all records, or treat
  missing-key dedupe as invalid.
- Expand ticket recipe defaults to include common ID fields:
  `ticket_id`, `ticket`, `id`, `case_id`, `issue_id`.
- Add component acceptance contracts:
  - parsed record count must equal grouped input count unless truncation is
    explicit.
  - grouped output must preserve source record IDs.
  - scorecard should flag record loss when the objective asks for counts or
    examples.

### 4. Browser HITL Is Not Actually User-Interactive For Running Agents

The controlled `approve: ask` write probe recorded `approve: ask`, but the review
was immediately denied by the terminal-style input fallback. The browser never
had a chance to approve, rewrite, deny, or stop the running agent.

Impact:

- The visible review card is retrospective, not a true pause/resume control.
- A user selecting `approval: ask` cannot actually participate in the decision.
- Repair can mask the denied write by completing a non-write answer, even when
  the user asked for a file.

Recommendation:

- Replace browser `input_fun: fn _prompt -> "d\n" end` with a durable wait/review
  bridge:
  - emit pending review request.
  - suspend the agent run.
  - resume when `Workbench.record_review_decision/3` records the browser
    decision.
- Show automatic decisions distinctly from manual decisions:
  - `auto-approved by approval: safe`
  - `manual approved by browser`
  - `auto-denied by terminal fallback`
- If a write was denied, do not mark the overall objective as completed unless
  the repaired plan clearly satisfies a non-write alternative accepted by the
  user.

### 5. Artifact Quality Is Not Strong Enough

The generated `.docs/browser-eval-hitl-report.md` contained the correct meeting
facts, but repeated the full summary under each requested section:

- Decisions repeated the entire report.
- Actions repeated the entire report.
- Risks repeated the entire report.
- Open Questions repeated the entire report.

Impact:

- The artifact is technically written and scorecard-satisfied, but not a
  polished report.
- Users have to manually clean output that the agent should be able to structure.

Recommendation:

- Add a report-composer quality contract:
  - repeated section body detection should apply before write approval.
  - section templates should receive the relevant slice of structured content,
    not the whole rendered report each time.
- Add artifact preview to the review card, not just `input_preview`.
- Make "approve write" mean "approve this exact artifact preview", not just
  "approve that some write may happen".

### 6. Browser Launch Controls Are Too Thin For Real Agent Work

The browser composer exposes only objective, agent, mode, and approval. Important
agent options are hidden or unavailable:

- input paths,
- output path,
- write policy,
- model,
- client,
- max runtime/concurrency,
- expected artifact format,
- whether sources are required.

Impact:

- Users have to encode operational configuration inside prose.
- The app cannot show "planned inputs" vs "resolved inputs" before launch.
- The agent may infer the wrong path, recipe, or review behavior.

Recommendation:

- Add an advanced launch drawer with structured fields:
  - sources,
  - output path,
  - write policy,
  - model/client,
  - provenance requirement,
  - recipe preference.
- Show resolved launch config after submit:
  - selected agent,
  - model/client,
  - approval policy,
  - resolved inputs,
  - intended output path,
  - selected recipe/workflow type.

### 7. Agent Choice Needs Product Guidance

The UI exposes `assistant`, `standard`, and `rlm` as bare select values. A normal
operator has no in-product guidance on when to choose each.

Recommendation:

- Replace the bare select with an agent picker that shows:
  - best for,
  - source access behavior,
  - write/HITL behavior,
  - expected latency,
  - risk level.
- Default to assistant, but surface why another agent might be better for a
  given objective.

## Priority Fixes

1. Make browser HITL truly interactive.
   This is the largest UX gap because the app displays review controls but the
   running agent does not actually wait for them.
2. Deduplicate final assistant messages.
   The duplicate transcript issue appears in most successful browser sessions.
3. Fix record dedupe/coverage for structured data recipes.
   Ticket clustering is a common business workflow and currently loses records
   while reporting success.
4. Improve direct-answer classification.
   Direct non-source answers should not be blocked by provenance.
5. Strengthen artifact preview and quality gates.
   A write approval should review the actual artifact content and catch repeated
   sections before writing.
6. Add structured launch controls.
   The browser needs to expose enough of the agent runtime to avoid prose-only
   configuration.

## Bottom Line

The browser workbench is close enough to evaluate real agent behavior: sessions
launch, persist, render, and surface scorecards/reviews/artifacts. The strongest
latent capability is source-grounded workflow execution; the policy comparison
now works well at the data level.

The major product gap is orchestration fidelity. Browser review controls are not
yet true pause/resume controls, final answers duplicate, record coverage can be
lost without detection, and the launch form hides the structured inputs needed
for robust agent work. The next implementation pass should focus less on adding
new model skills and more on making the browser the authoritative operator
surface for launch configuration, HITL decisions, final-output projection, and
workflow quality gates.
