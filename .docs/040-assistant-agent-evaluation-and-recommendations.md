# Assistant Agent Evaluation And Recommendations

Date: 2026-05-09

This note records a fresh QA pass over the default `mix runic_ai.agent
--agent assistant` path. The goal was to drive realistic assistant sessions
through source discovery, structured extraction, comparison, HITL write review,
scorecard repair, and browser-visible persistence, then compare observed
behavior against expected outcomes.

## Setup

Runtime:

- workspace: `/home/doops/wrk/runic_ai`
- model: `openai:gpt-5.4-mini`
- persistence: `.runic_ai/runs.db`
- JSONL traces: `tmp/assistant_eval/*.jsonl`
- renderer: `text`
- approval mode: mostly `safe`

Fixtures:

- `tmp/assistant_tickets.jsonl`
- `tmp/assistant_policy_old.md`
- `tmp/assistant_policy_new.md`
- `tmp/assistant_meeting_transcript.md`

Expected fixture facts:

- Tickets:
  - `T1` and `T3` are login/SSO/session failures.
  - `T1` and `T3` are high severity.
  - `T1` and `T3` block admins.
  - `T2` is a medium-severity billing issue involving duplicate invoice CSV
    rows and finance cleanup.
- Policy comparison:
  - response target changes from two business days to one business day.
  - security escalation changes from weekly to immediate.
  - enterprise customers gain a migration contact.
- HITL/write-path behavior:
  - an artifact-writing workflow should emit durable review request events.
  - `--approve safe` may auto-approve low-risk writes, but approval should be
    consistent with the write policy and should not loop through repeated
    approvals for a write that will never be allowed.

## Sessions

| Session | Intent | Expected | Actual |
| --- | --- | --- | --- |
| `assistant-eval-ticket-20260509` | Ticket clustering using `--client codex` | Either use Codex-backed model access or fail with a clear unsupported-client error before starting | Failed during blueprint generation with `function :codex.generate_text/3 is undefined` |
| `assistant-eval-ticket-20260509-default` | Ticket clustering with output artifact | Parse 3 JSONL rows, group login vs billing, emit HITL write review, write or clearly deny artifact | Parsed/composed correct ticket facts and emitted HITL review, but auto-approved low-risk write then failed repeatedly with `artifact write blocked by assistant write policy` |
| `assistant-eval-policy-20260509` | Policy comparison using repeated `--input` flags | Read both old and new policy files and compare them | Completed, but only discovered `tmp/assistant_policy_new.md`; answer was contaminated because expected facts were in the objective |
| `assistant-eval-policy-pathrefs-20260509` | Policy comparison by path references in objective, no expected facts in prompt | Discover both policy files, compare, return concrete deltas and satisfy scorecard | Discovered both files and produced correct raw comparison output, but first attempt said source text was unavailable; repair produced a better comparison report; final status remained blocked for missing source/provenance |
| `assistant-eval-ticket-answer-20260509` | Ticket clustering answer-only, no expected facts in prompt | Parse records, cluster themes, return answer with ticket IDs and pass scorecard | Parsed all records and composed the expected facts, but final status remained blocked for missing source/provenance |

## Observed Strengths

- The assistant can infer source paths from the objective. The
  `assistant-eval-policy-pathrefs-20260509` run discovered both policy files
  when they were mentioned directly in the objective.
- The generated workflow can select useful components:
  - ticket runs used `source_discovery`, `tabular_parser`, `record_map`,
    `record_group`, and `report_composer`.
  - policy comparison used `source_discovery`, `source_splitter`,
    `source_materializer`, `document_compare`, `llm_map`, `blueprint_reduce`,
    `llm_leaf`, and `objective_scorecard`.
- HITL persistence is present. The write-path ticket run created a durable
  `assistant_artifact_write` review request with `checkpoint: pre_write`,
  `risk: low`, and `safe?: true`.
- Scorecard repair is active. Runs that produced no output or lacked accepted
  provenance attempted bounded repair with a fallback `assistant:generic_report`
  workflow.

## Issues

### 1. `--client codex` Is Not Wired For Assistant RLM

`assistant-eval-ticket-20260509` failed immediately:

```text
function :codex.generate_text/3 is undefined (module :codex is not available)
```

The CLI accepts `--client codex`, but the assistant RLM path receives the atom
and tries to call it as a module. Coding-agent paths have richer Codex client
normalization, but assistant RLM does not appear to share that bridge yet.

Recommendation:

- Normalize assistant `:codex` to the actual Codex client module or reject it
  before starting a run with a clear error.
- Prefer sharing the coding-agent client normalization path where practical.

### 2. Repeated `--input` Flags Collapse To The Last Value

`RunicAI.Terminal.CliOptions.parse/1` currently returns only the last repeated
`--input` value:

```elixir
["--input", "tmp/assistant_policy_old.md", "--input", "tmp/assistant_policy_new.md"]
# => ["tmp/assistant_policy_new.md"]
```

That made `assistant-eval-policy-20260509` discover only the new policy file.
The run still completed because the prompt itself included expected facts, which
is a test-design smell and a product hazard.

Recommendation:

- Fix CLI parsing so repeated `--input` values are preserved.
- Add a regression test for multi-input source discovery.
- In the UI, show the resolved input list before launch so users can see whether
  both files are actually included.

### 3. Write Policy And HITL Approval Can Contradict Each Other

`assistant-eval-ticket-20260509-default` produced a low-risk artifact write
review and `--approve safe` approved it. The artifact writer then rejected the
same path:

```text
artifact write blocked by assistant write policy
path: tmp/assistant_eval/artifacts/ticket-themes.md
policy: docs_only
```

The scheduler retried the write, causing repeated review-request/review-completed
events for an action that policy would never allow.

Recommendation:

- Run write-policy validation before asking for review. If the path is outside
  `docs_only`, do not ask for approval; emit a normal policy error and offer
  a repair target.
- Include policy-compatible suggested paths in the review request, for example
  `.docs/...` for `docs_only`.
- Treat "approved but policy-blocked" as a repairable path-selection error, not
  as a repeated HITL loop.

### 4. Scorecard Provenance Checks Reject Useful Structured Outputs

Both answer-only runs produced useful structured output but ended blocked:

- ticket answer output included all three ticket IDs and correct raw facts.
- policy path-reference output produced a `Comparison Report` with old/new file
  provenance and correct change candidates.

The scorecard still reported:

```text
source/provenance coverage was required but not present
```

Recommendation:

- Teach `ObjectiveScorecard` to recognize provenance emitted by
  `report_composer`, `document_compare`, `tabular_parser`, and `record_group`.
- Preserve provenance metadata alongside composed text, not only inside rendered
  prose.
- Distinguish "answer factually useful but provenance formatting incomplete"
  from "objective incomplete"; the UI and repair loop should present those
  differently.

### 5. Blocked Runs Can Hide The Best Available Answer In Chat

For `assistant-eval-policy-pathrefs-20260509`, the persisted chat message showed
the first incomplete answer saying source text was unavailable. Later events
contained a better repaired comparison report, but the session still ended
blocked and the better report was not the chat-visible assistant answer.

For `assistant-eval-ticket-answer-20260509`, the event stream contained the
useful `Record Report`, but the chat-visible messages were only summary lines:

```text
changed=0 risks=1
status: blocked
```

Recommendation:

- Persist the best available repaired output as a visible assistant draft even
  when final status is blocked.
- Mark it as "blocked: needs provenance repair" instead of replacing it with
  only scorecard summary text.
- In the workbench, add a "Best output" or "Last repaired output" panel for
  blocked runs.

### 6. Dynamic Workflows Sometimes Pick A Good Component But Lose Product Intent

The policy path-reference run used `document_compare`, which is the right
component, but the first generated path then asked the user to provide source
text even though sources had been materialized. The ticket run used
`record_group`, but `groups` came back empty while raw records were preserved
and the report composer fell back to a flat summary.

Recommendation:

- Prefer curated blueprints for common assistant tasks:
  - `jsonl_ticket_cluster`
  - `document_pair_compare`
  - `meeting_actions`
  - `notes_digest`
  - `docs_only_report_write`
- Let dynamic planning choose among these recipes before generating a fully
  bespoke graph.
- Use component-level acceptance contracts, for example:
  - `record_group` must produce non-empty groups when a grouping key is present.
  - `document_compare` must feed change candidates directly into synthesis.
  - `report_composer` must carry provenance fields forward.

## UX Recommendations

- Show "planned inputs" and "resolved inputs" separately in the workbench. This
  would have exposed the repeated-`--input` collapse immediately.
- Add a HITL policy preview: path, write policy, risk, safe flag, and whether
  approval can actually permit the action.
- In the review card, show when a decision was automatic because of
  `--approve safe` vs manually approved in the browser or terminal.
- For blocked sessions, surface:
  - best generated output,
  - blocking scorecard reason,
  - repair attempt summary,
  - suggested next action.
- Add a compare view for generated workflow vs repaired fallback workflow so it
  is obvious when repair improved the content but not the final status.

## Suggested Implementation Slices

1. Fix CLI/client plumbing:
   - [x] preserve repeated `--input`.
   - [x] normalize `--client codex` to the callable Codex client module for
     assistant RLM.
2. Fix write-policy/HITL ordering:
   - [x] validate path against write policy before review.
   - [x] avoid repeated approval loops for deterministic policy failures.
3. Improve provenance scoring:
   - [x] accept structured provenance from `document_compare`, `tabular_parser`,
     `record_group`, and `report_composer`.
   - [x] keep metadata provenance attached to final answer payloads.
4. Improve blocked-run persistence and UX:
   - [x] persist best repaired output as visible blocked draft.
   - [x] carry blocking reason metadata with the draft message.
   - [x] add a workbench blocked-draft cue with the blocking reason.
5. Add curated assistant recipes:
   - [x] start with ticket clustering and document comparison because both already
     showed useful latent capability but weak finalization.

## Implementation Status

Implemented on 2026-05-09:

- `mix runic_ai.agent` now preserves repeated `--input` flags, including
  `--input path` and `--input=path`.
- `--client codex` now resolves to `RunicAI.Coding.Codex.Client` instead of
  passing the raw `:codex` atom into assistant RLM.
- Artifact writes validate the target path against the write policy before
  emitting HITL review requests. Policy-blocked paths now return a normal
  validation error with suggested `.docs/` paths instead of asking for approval
  that cannot permit the write.
- `report_composer` preserves nested provenance from records, groups,
  comparisons, sources, slices, and outputs. `ObjectiveScorecard` now counts
  structured provenance/source references across those component outputs.
- Assistant final outputs are projected as visible `workflow_output` messages
  for both satisfied and blocked runs. Blocked drafts carry `blocked?` and
  `blocking_reason` metadata so the workbench can distinguish "useful answer,
  needs repair" from "no answer".
- The coordinator now prefers curated recipes for common tabular clustering and
  document comparison tasks before asking the LLM to generate a bespoke
  blueprint. The shortcut is intentionally narrow so general workspace/path
  objectives still exercise dynamic workflow planning.

Verification:

- `mix test test/runic_ai/terminal/cli_options_test.exs test/runic_ai/assistant/rlm_components_test.exs test/runic_ai/terminal/event_test.exs test/runic_ai/persistence/sqlite_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_agent_test.exs`
- `mix test`
- Browser snapshot of `/sessions/qa-blocked-draft-196` confirmed the
  workbench renders the visible `blocked draft` cue and blocking reason.

## Bottom Line

The assistant has real latent capability: it can discover sources, parse JSONL,
compare documents, compose reports, emit HITL reviews, and attempt bounded
repair. The main gaps are not raw capability gaps. They are orchestration and UX
gaps around input preservation, client selection, write-policy semantics,
provenance recognition, and blocked-run presentation.

The highest-leverage improvement is to make the default assistant choose stable
curated workflows for common structured tasks, then reserve dynamic blueprint
generation for cases that do not match those recipes.
