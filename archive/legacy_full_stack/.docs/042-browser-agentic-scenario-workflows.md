# Browser Agentic Scenario Workflows

Date: 2026-05-09

This document defines browser-run scenarios for evaluating RunicAI agents through
the Phoenix LiveView workbench. Each scenario is written as an actionable user
story with launch instructions, expected agent behavior, and verification steps
using the UI plus Tidewave runtime queries.

The goal is not only to check whether a single prompt returns text. These
scenarios exercise practical agentic capabilities: direct assistance, research,
source-grounded comparison, structured extraction, coding review, artifact
writing, HITL review, repair behavior, and trace observability.

## Shared Setup

Open the workbench:

```text
http://localhost:4000/sessions/new
```

Use the browser composer unless a scenario says otherwise:

- Agent: `assistant` unless specified.
- Mode: `verify` unless specified.
- Approval: `safe` unless specified.
- Workspace: `/home/doops/wrk/runic_ai`.

Useful fixture files already present in this repo:

- `tmp/assistant_tickets.jsonl`
- `tmp/assistant_policy_old.md`
- `tmp/assistant_policy_new.md`
- `tmp/assistant_meeting_transcript.md`
- `.docs/039-phoenix-liveview-local-agent-workbench-plan.md`
- `.docs/040-assistant-agent-evaluation-and-recommendations.md`
- `.docs/041-browser-agent-evaluation-and-recommendations.md`

## Tidewave Helpers

### Launch A Browser Run

Use this from `browser_eval`, replacing the objective and select values:

```javascript
await browser.reload('/sessions/new');
await browser.eval(() => {
  document.querySelector('textarea[name="run[objective]"]').value = 'REPLACE_OBJECTIVE';
  document.querySelector('textarea[name="run[objective]"]').dispatchEvent(new Event('input', {bubbles: true}));
  document.querySelector('select[name="run[agent]"]').value = 'assistant';
  document.querySelector('select[name="run[mode]"]').value = 'verify';
  document.querySelector('select[name="run[approve]"]').value = 'safe';
  for (const el of document.querySelectorAll('select')) {
    el.dispatchEvent(new Event('input', {bubbles: true}));
    el.dispatchEvent(new Event('change', {bubbles: true}));
  }
  console.log('launch config:', JSON.stringify(Object.fromEntries(new FormData(document.querySelector('form')).entries())));
  document.querySelector('form').dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}));
});
await browser.wait(1000);
await browser.eval(() => console.log('session path:', window.location.pathname));
```

### Inspect The Rendered Chat

Use this after the session has navigated:

```javascript
console.log(await browser.snapshot(browser.locator('#message-scroll'), {limit: 160}));
```

### Poll A Persisted Session

Use this from Tidewave `project_eval`, replacing `SESSION_ID` with the decoded
session id from the URL. For example, `/sessions/web-session%3AABC` means
`SESSION_ID = "web-session:ABC"`.

```elixir
session_id = "SESSION_ID"

Enum.reduce_while(1..60, :timeout, fn attempt, _acc ->
  snapshot = RunicAI.Workbench.session_snapshot(session_id)
  status = get_in(snapshot || %{}, [:session, :status])
  metrics = get_in(snapshot || %{}, [:metrics])
  IO.puts("attempt=#{attempt} status=#{inspect(status)} metrics=#{inspect(metrics)}")

  if status in ["completed", "blocked", "failed"] do
    IO.inspect(Enum.map(snapshot.messages, fn message ->
      %{
        kind: message.kind,
        transient: message.transient,
        blocked?: get_in(message.content_json, ["blocked?"]),
        blocking_reason: get_in(message.content_json, ["blocking_reason"]),
        preview: String.slice(message.content || "", 0, 500)
      }
    end), label: "messages")

    IO.inspect(Enum.map(snapshot.review_requests, fn review ->
      %{
        kind: review.kind,
        status: review.status,
        path: get_in(review.details || %{}, ["path"]),
        decision: review.decision
      }
    end), label: "reviews")

    IO.inspect(Enum.map(snapshot.scorecards, fn scorecard ->
      %{
        status: scorecard.objective_status,
        risks: scorecard.residual_risks,
        source_coverage: get_in(scorecard.data || %{}, ["source_coverage"]),
        provenance_count: get_in(scorecard.data || %{}, ["provenance_count"])
      }
    end), label: "scorecards")

    {:halt, :ok}
  else
    Process.sleep(2_000)
    {:cont, :timeout}
  end
end)
```

### Check Server Errors

Use Tidewave `get_logs`:

```text
tail: 100
level: error
```

Expected: no new error logs for normal completed, blocked, or review-waiting
agent runs.

## Scenario 1: Direct Assistance Without Source Grounding

User story:

As an operator, I want to ask a direct product-design question and receive a
normal answer without forcing the agent to inspect files.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Direct assistance scenario: In three concise bullets, describe what a local AI
agent workbench should show while an agent is running. Do not inspect files or
claim source evidence.
```

Expected behavior:

- The agent returns exactly or approximately three useful bullets.
- The run should complete, not block, because the user explicitly requested no
  source inspection.
- The answer should not claim it inspected the repo or cite files.

UI verification:

- Chat shows one final assistant answer.
- No `blocked draft` cue should appear.
- The session status in the sidebar should be `completed`.

Tidewave verification:

- `snapshot.session.status == "completed"`.
- `snapshot.metrics.messages == 1`.
- `snapshot.review_requests == []`.
- Scorecard risks should not include
  `source/provenance coverage was required but not present`.

Failure signals:

- The run is `blocked` only because provenance is missing.
- Multiple identical workflow output messages appear.
- The answer claims it read files despite the objective saying not to.

## Scenario 2: Source-Grounded Policy Comparison

User story:

As a support operations lead, I want the agent to compare two policy files and
summarize concrete operational changes.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Policy comparison scenario: Compare tmp/assistant_policy_old.md and
tmp/assistant_policy_new.md. Return material changes, affected stakeholders,
open questions, migration recommendations, and cite the source paths.
```

Expected behavior:

- The agent discovers both files.
- Output includes these facts:
  - response target changed from two business days to one business day.
  - security escalation changed from weekly to immediate.
  - enterprise customers now receive a migration contact.
- The run should complete with present source/provenance coverage.

UI verification:

- Chat shows a comparison report once.
- The inspector trace includes source discovery, document comparison, and
  scorecard events.
- Artifacts may include workflow graph/blueprint records, but no write artifact
  is required.

Tidewave verification:

- `snapshot.session.status == "completed"`.
- `snapshot.messages` contains the three expected policy facts.
- `snapshot.scorecards` have `objective_satisfied`.
- `source_coverage == "present"` and `provenance_count > 0`.

Failure signals:

- Only one of the two files is referenced.
- The output says source text was unavailable.
- The same final report renders twice.

## Scenario 3: Structured Ticket Clustering

User story:

As a support triage lead, I want the agent to cluster incoming tickets by theme,
preserve ticket IDs, and report counts and impacts.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Ticket clustering scenario: Cluster tmp/assistant_tickets.jsonl into themes.
Return theme counts, severity distribution, repeated failure modes, customer
impact, and example ticket IDs. Preserve every ticket_id from the source.
```

Expected behavior:

- The agent parses all three JSONL records.
- Output includes:
  - login/SSO/session theme with `T1` and `T3`.
  - billing theme with `T2`.
  - counts: login = 2, billing = 1.
  - high severity for `T1` and `T3`, medium severity for `T2`.
  - admin blocking impact for login issues.
- The scorecard should fail if records are dropped.

UI verification:

- Chat report includes all three ticket IDs.
- Trace includes `tabular_parser` and `record_group` or equivalent structured
  record steps.
- No duplicate final messages.

Tidewave verification:

- Search `Enum.map(snapshot.messages, & &1.content)` for `T1`, `T2`, and `T3`.
- Inspect runnable events for parsed and grouped record counts.
- Confirm scorecard is not satisfied if only one record appears.

Failure signals:

- Output includes only `T1`.
- Group count or record count is lower than the parsed source count without an
  explicit truncation warning.
- Scorecard passes despite missing `T2` or `T3`.

## Scenario 4: Meeting Transcript Action Extraction

User story:

As a product manager, I want an agent to read a meeting transcript and produce a
structured action register.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Meeting actions scenario: Read tmp/assistant_meeting_transcript.md. Return a
structured report with Decisions, Actions, Risks, Open Questions, owners, dates,
and source timestamp references.
```

Expected behavior:

- Decisions includes docs-only write policy retained.
- Actions includes Bea adding a trace summary helper by Friday.
- Risks includes plausible outputs without source coverage.
- Open questions includes when dynamic proposals should fall back to recipes.
- Output should be sectioned without repeating the same full report under every
  section.

UI verification:

- Chat shows one clean structured report.
- Trace shows source discovery/materialization and either report composition or
  direct synthesis.
- No write review should appear because no artifact path is requested.

Tidewave verification:

- `snapshot.metrics.review_requests == 0`.
- Message content includes `Ada`, `Bea`, `Cam`, `Friday`, and timestamps or
  equivalent source references.
- Scorecard has present source coverage when provenance is required.

Failure signals:

- Same paragraph appears under every section.
- Output omits owners or timestamps.
- Run blocks even though source evidence is present.

## Scenario 5: Artifact Write With Browser HITL

User story:

As an operator, I want the agent to prepare an artifact write, pause for browser
review, show the exact artifact preview, and continue only after my decision.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `ask`

Objective:

```text
Browser HITL write scenario: Write a Markdown report to
.docs/browser-hitl-meeting-report.md summarizing
tmp/assistant_meeting_transcript.md. Include Decisions, Actions, Risks, and Open
Questions. Wait for approval before writing.
```

Expected behavior:

- A pending review card appears before the file is written.
- Review details show:
  - path: `.docs/browser-hitl-meeting-report.md`
  - write policy: `docs_only`
  - safe/risk metadata
  - artifact content preview
- The run waits until the browser decision is recorded.
- Approve writes the file.
- Deny/stop prevents the file write and leaves the run blocked or waiting.
- Rewrite updates the artifact content or write instructions before continuing.

UI verification:

- In the chat or Reviews tab, review controls are interactable.
- The review status changes from pending to approved/denied/cancelled/edited
  after clicking a button.
- The final status matches the decision.

Tidewave verification:

- Before decision:
  - `snapshot.review_requests` contains a pending `assistant_artifact_write`.
  - target file should not exist.
- After approve:
  - review status is `approved`.
  - `.docs/browser-hitl-meeting-report.md` exists.
  - artifact table includes the path.
- After deny/stop:
  - review status is `denied` or `cancelled`.
  - target file does not exist.

Failure signals:

- `approval: ask` immediately auto-denies through terminal fallback.
- File is written before browser approval.
- Review card is retrospective only.
- Repair marks the run completed after a denied write without user acceptance.

## Scenario 6: Unsafe Write Path And Policy Repair

User story:

As an operator, I want the agent to reject writes outside the allowed policy and
suggest a safe path instead of asking me to approve something policy cannot
permit.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Write policy scenario: Summarize tmp/assistant_meeting_transcript.md and write
the report to tmp/browser-policy-should-not-write.md.
```

Expected behavior:

- The write should be blocked before review because default browser writes are
  docs-only.
- The review card should not ask for approval of a path policy cannot permit.
- The run should suggest a `.docs/browser-policy-should-not-write.md` style path.
- A repair may produce a non-written answer, but should clearly state the write
  did not happen.

UI verification:

- No misleading low-risk approve card for `tmp/...`.
- Blocking reason or trace mentions write policy.
- If a blocked draft appears, it says the requested file was not written.

Tidewave verification:

- Target file under `tmp/` does not exist.
- Trace contains an artifact writer policy validation error.
- Review requests should be empty or should reference only policy-compatible
  `.docs/` suggestions.

Failure signals:

- Browser asks user to approve a policy-impossible write.
- Repeated review loops for the same blocked path.
- Run completes as if the artifact was written when it was not.

## Scenario 7: Repository Research Summary

User story:

As an engineer, I want the agent to inspect the current repo and explain what it
does, using source evidence rather than generic claims.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Repo research scenario: Inspect this repository and explain what RunicAI is for,
how the Phoenix workbench fits in, and which modules own agent persistence,
browser launching, and assistant RLM execution. Cite file paths.
```

Expected behavior:

- Output names concrete modules and files, such as:
  - `lib/runic_ai/workbench.ex`
  - `lib/runic_ai_web/live/workbench_live.ex`
  - `lib/runic_ai/persistence/harness_projection.ex`
  - `lib/runic_ai/assistant/rlm/agent.ex`
- Output explains RunicAI as a toolbox/workbench around Runic workflows and LLM
  components.
- Source coverage is present.

UI verification:

- Trace shows repo/file discovery and source splitting/materialization.
- Chat answer contains cited paths.
- No file writes or HITL reviews should occur.

Tidewave verification:

- Message content includes the expected file paths.
- `source_coverage == "present"`.
- Tool/run artifacts include workflow graph/blueprint only.

Failure signals:

- Generic answer with no file paths.
- Claims unrelated architecture.
- Blocks due missing source coverage after citing paths.

## Scenario 8: Code Review Scenario

User story:

As a maintainer, I want the agent to review a targeted area of code and identify
risks without editing files.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Code review scenario: Review lib/runic_ai/workbench.ex and
lib/runic_ai_web/live/workbench_live.ex for UX or persistence bugs around
browser-launched agent runs. Return findings first with file paths and concrete
behavioral risk. Do not modify files.
```

Expected behavior:

- Output is review-shaped:
  - findings first,
  - severity/risk,
  - file paths,
  - concrete behavior,
  - residual questions.
- No artifact write, no patch, no HITL review.
- The run should not claim tests were run unless they were.

UI verification:

- Chat answer is not a generic summary.
- Inspector trace shows source discovery/materialization for the two files.
- No review requests appear.

Tidewave verification:

- Message content includes both requested file paths.
- `snapshot.metrics.review_requests == 0`.
- `snapshot.artifacts` does not include changed files.

Failure signals:

- Agent edits files in verify mode.
- Agent returns broad praise/summary without findings.
- Agent invents test results.

## Scenario 9: Coding Patch Scenario With Review Gate

User story:

As a developer, I want to ask for a very small code change and have the agent
respect write controls and show the patch/write risk before mutating files.

Launch settings:

- Agent: `standard` or `assistant`, depending on which coding path is under
  test.
- Mode: `patch`
- Approval: `ask`

Objective:

```text
Coding patch scenario: Add a focused regression test proving that repeated
assistant workflow output messages are deduplicated in browser chat. Keep the
change limited to tests unless implementation is required. Ask for approval
before modifying files.
```

Expected behavior:

- The agent plans the change and identifies relevant test files.
- Before writing, the browser shows a review card with patch/write details.
- If approved, only relevant files are changed.
- If denied, no files are changed and the session remains blocked/cancelled.

UI verification:

- Review card includes patch or write context.
- Trace shows file discovery and patch/write stage.
- Final answer summarizes changed files and verification.

Tidewave verification:

- Check review status and changed artifact records.
- Run `git diff --stat` separately to confirm files touched.
- Verify any claimed tests were actually run or recorded.

Failure signals:

- Files change before approval.
- Review controls are not actionable.
- Agent writes outside the expected test/implementation scope.

## Scenario 10: Mermaid Diagram Research

User story:

As a technical writer, I want the agent to produce a Mermaid diagram grounded in
repo evidence.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Mermaid research scenario: Read the RunicAI workbench and persistence code and
produce a concise explanation plus a Mermaid sequence diagram showing browser
launch -> AgentRunner -> terminal events -> SQLite projection -> LiveView
refresh. Cite source paths.
```

Expected behavior:

- Output includes a Mermaid code block.
- Diagram includes browser/LiveView, Workbench, AgentRunner, assistant runner,
  SQLite persistence/projection, and LiveView refresh.
- Source paths are cited in prose.

UI verification:

- Markdown renders without breaking the chat transcript.
- Mermaid block is visible as code or rendered diagram, depending on current
  workbench support.
- Source paths appear near the explanation.

Tidewave verification:

- Message content includes ````mermaid`.
- Message content includes the expected component names.
- Source coverage is present.

Failure signals:

- Mermaid syntax is malformed.
- Diagram is generic and not tied to RunicAI modules.
- Browser console logs rendering errors.

## Scenario 11: Multi-Turn Continuation

User story:

As a user, I want to continue a prior browser session and have the agent use the
current conversation context instead of treating my follow-up as isolated.

Launch settings:

- Start with Agent: `assistant`, Mode: `verify`, Approval: `safe`.
- Use the same session composer after the first answer.

First objective:

```text
Multi-turn scenario part 1: Create a five-point checklist for evaluating browser
agent UX. Keep it concise.
```

Follow-up objective in the same session:

```text
Now turn that checklist into acceptance criteria and keep the same order.
```

Expected behavior:

- The follow-up should refer to the previous checklist.
- It should not ask the user to paste the checklist again.
- It should preserve order and convert each item to acceptance criteria.

UI verification:

- Same session remains selected.
- The new answer appears after the original answer.
- The answer clearly uses prior context.

Tidewave verification:

- `snapshot.messages` contains both assistant outputs.
- Launch event or runner options include conversation carryover/history.
- Follow-up answer content maps to the original checklist items.

Failure signals:

- Follow-up ignores prior answer.
- Agent asks "which checklist?" despite same-session context.
- Session switches unexpectedly.

## Scenario 12: Recovery From Bad Or Missing Source

User story:

As an operator, I want the agent to fail clearly when a referenced file does not
exist, and suggest a useful next action.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Missing source scenario: Summarize tmp/does-not-exist-for-browser-eval.md and
cite the source path.
```

Expected behavior:

- The run should not invent a summary.
- It should complete blocked or failed with a clear missing-source reason.
- It should suggest checking the path or selecting an existing source.

UI verification:

- Chat shows a blocked draft or error with the missing path.
- Inspector trace shows source discovery/read failure.
- No artifact write or review should appear.

Tidewave verification:

- `snapshot.session.status in ["blocked", "failed"]`.
- Message or event detail includes the missing path.
- Scorecard residual risks explain the source problem.

Failure signals:

- Agent fabricates content.
- Agent reports success with no source coverage.
- Error is only visible in raw logs and not in chat.

## Scenario 13: Agent Picker Baseline

User story:

As a new operator, I want to understand what `assistant`, `standard`, and `rlm`
mean before choosing one.

Launch settings:

- Run the same simple objective with each agent value:
  - `assistant`
  - `standard`
  - `rlm`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Agent picker baseline: In two bullets, explain what a local AI workbench should
show while an agent is running. Do not inspect files.
```

Expected behavior:

- Each agent either completes or fails clearly.
- The UI should make differences visible:
  - runtime behavior,
  - trace shape,
  - tool/review support,
  - output style.
- The launch form should not require users to know internal agent names.

UI verification:

- Compare sidebar/session statuses for each run.
- Compare trace and message structure in the inspector.
- Note whether the UI provides enough information to choose the right agent.

Tidewave verification:

- Query each session snapshot.
- Compare metrics:
  - event count,
  - messages,
  - review requests,
  - artifacts,
  - scorecards.

Failure signals:

- Selecting an agent silently does nothing.
- The app remains on `/sessions/new` without an error or session.
- The UI exposes agent names without explaining practical tradeoffs.

## Scenario 14: Blocked Draft And Repair Visibility

User story:

As an operator, I want to understand what output is usable when a run blocks and
what repair is needed next.

Launch settings:

- Agent: `assistant`
- Mode: `verify`
- Approval: `safe`

Objective:

```text
Blocked draft scenario: Read tmp/assistant_policy_old.md and produce a sourced
comparison against a second policy document that I forgot to provide.
```

Expected behavior:

- The run should recognize the missing comparison source.
- If it produces a partial draft, it should be marked as blocked.
- The UI should show:
  - best available output,
  - blocking reason,
  - repair attempt summary,
  - suggested next action.

UI verification:

- A `blocked draft` cue is visible if partial output exists.
- Blocking reason is legible without opening raw traces.
- Plan/trace tabs show repair attempts.

Tidewave verification:

- `snapshot.session.status == "blocked"`.
- Final message has `content_json["blocked?"] == true`.
- Scorecard residual risks explain missing source/provenance.
- Repair events are present when repair was attempted.

Failure signals:

- Useful repaired output is hidden behind only a scorecard summary.
- The run shows `completed` even though the requested comparison was impossible.
- No next action is visible.

## Cross-Scenario Quality Checklist

For every scenario, record:

- Session URL and decoded session id.
- Objective, agent, mode, approval value.
- Expected status and actual status.
- Number of visible chat messages.
- Whether duplicate final output appeared.
- Whether blocked status matched real user-facing incompleteness.
- Whether source/provenance requirements were appropriate.
- Whether all requested source records/files were represented.
- Whether HITL controls were automatic, manual, retrospective, or nonfunctional.
- Whether artifacts were written only when expected.
- Whether the UI made the next action obvious.

## Recommended Report Format

When running a batch of these scenarios, write a follow-up `.docs` report with:

```text
## Scenario Results

| Scenario | Session | Expected | Actual | Status | Notes |
| --- | --- | --- | --- | --- | --- |

## Findings

1. Highest severity issue
2. Next issue
3. Next issue

## Evidence

- Browser snapshot refs or excerpts.
- `RunicAI.Workbench.session_snapshot/1` summaries.
- Relevant scorecard residual risks.
- Review request details.
- Artifact paths and file existence.

## Recommendations

- Fixes ordered by product/user impact.
```

## Current Known Risks To Watch

These are expected to appear until fixed:

- Direct no-source tasks may block on provenance.
- Successful assistant runs may render duplicate final messages.
- Ticket clustering may drop records if dedupe keys do not match the input
  schema.
- Browser `approval: ask` may not truly pause for browser review.
- Artifact reports may repeat full content under multiple requested sections.

Treat these as regression targets: once fixed, the same scenarios should be
rerun and the expected results above should become passing behavior.
