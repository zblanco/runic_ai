# Standard Coding Agent OODA Reliability Implementation Plan

Status: core implementation complete; shared reliability facade,
StandardAgent objective gate, prompt updates, verification freshness summaries,
FieldService smoke runner, and live mini smoke verification are implemented

Date: 2026-04-29

Last verified: 2026-04-30 (`mix compile --warnings-as-errors`;
`mix test test/runic_ai/coding/standard_agent_test.exs`;
`mix test test/runic_ai/coding/standard_agent_remaining_test.exs`; `mix test`; live
`openai:gpt-5.4-mini` FieldService smoke)

Motivated by:

- StandardAgent FieldService smoke test success, 2026-04-29:
  `tmp/field_service_standard_agent_ooda_1777486889_artifacts/summary.json`
- RLM FieldService smoke test success, 2026-04-29:
  `tmp/field_service_rlm_repair_loop_1777480738_artifacts/summary.json`
- RLM reliability implementation plan:
  `.docs/027-rlm-coding-agent-reliability-implementation-plan.md`
- Standard coding agent implementation plan:
  `.docs/025-standard-coding-agent-implementation-plan.md`

Depends on:

- `.docs/024-coding-harness-and-tools-implementation-plan.md`
- `.docs/025-standard-coding-agent-implementation-plan.md`
- `.docs/027-rlm-coding-agent-reliability-implementation-plan.md`

## Goal

Apply the reliability lessons from the RLM coding agent work to the standard
ReAct-style `RunicAI.Coding.Agent`.

The standard agent should remain the direct, tactical local coding agent:
single-session, tool-driven, easy to run, and useful without recursive workflow
composition. It should not become an RLM coordinator and should not depend on
RLM-specific modules. It should, however, benefit from the same generic
evidence discipline:

- observe the actual workspace state,
- orient against an objective contract and verification evidence,
- decide whether to continue, repair, stop, or report failure,
- act through bounded tool calls,
- repeat until the objective is satisfied or the budget is exhausted.

The phase is successful when RunicAI can answer:

"Can the standard coding agent complete a small local project from a user
objective, verify it with concrete evidence, repair gaps from observed
failures, and stop only when the objective is actually satisfied?"

## Why This Matters

The RLM FieldService exercise exposed issues that are not unique to recursive
workflow agents:

- an agent can pass generated scaffold tests without satisfying the objective,
- a final answer can overstate completion,
- command success alone is not enough when tests are weak,
- brittle source-string checks can keep a completed task in repair mode,
- repair loops need current evidence, not stale failures,
- timeouts or failures can still leave useful workspace changes behind,
- completion should be based on observed artifacts and verification, not model
  self-report.

The standard ReAct agent is currently simpler and more direct, but it is still
susceptible to the same class of reliability failures. The fix is not recursive
planning. The fix is an evidence-grounded OODA loop around the existing
IntegratedToolAgent session.

## Verified Live Result

The `openai:gpt-5.4-mini` StandardAgent smoke passed after adding the objective
gate and command freshness fixes.

- Artifact directory:
  `tmp/field_service_standard_agent_ooda_1777486889_artifacts`
- Workspace:
  `tmp/field_service_standard_agent_ooda_1777486889/field_service_poc`
- Runtime: 2026-04-29T18:21:29Z to 2026-04-29T18:23:37Z.
- Final status: `ok`.
- Objective status: `objective_satisfied`.
- Tools used: `list_dir`, `find_files`, `apply_patch`, `compile_project`,
  `run_tests`.
- Agent repaired an initial compile failure caused by a local `apply/3`
  conflict, then reran compile and tests successfully.
- Independent verification passed:
  `mix compile --warnings-as-errors`, `mix test`, DynamicSupervisor, Registry,
  GenServer, timestamping, transition history, required states, and invalid
  transition coverage.

Comparison with the successful RLM smoke at
`tmp/field_service_rlm_repair_loop_1777480738_artifacts/summary.json`:

- Both runs used `openai:gpt-5.4-mini`.
- Both produced a passing FieldService proof of concept and independent
  verifier success.
- RLM used generated workflow coordination and one bounded repair iteration.
- StandardAgent completed as a direct ReAct worker with objective-gated repair,
  without recursive workflow decomposition.
- RLM remains the better fit for explicit dynamic workflow coordination.
  StandardAgent is now a useful tactical baseline with the same evidence
  discipline.

## Design Principles

- Keep StandardAgent independent from `RunicAI.Coding.RLM`.
- Extract or duplicate only generic coding reliability concepts into shared
  `RunicAI.Coding` modules.
- Do not add FieldService-, Mix-, Elixir-, Phoenix-, OTP-, or project-specific
  templates.
- Prefer generic acceptance contracts, source assertions, command evidence,
  runtime smokes, semantic objective judgement, and workspace deltas.
- Use the existing IntegratedToolAgent hooks where possible:
  `pre_answer_guard`, `continue_when`, `final_when`, budget policy, review
  gates, tool observations, and session state.
- Do not trust final-answer text as proof of completion.
- Treat every repair attempt as observable evidence: changed files, command
  output, scorecard status, and remaining risks.
- Let semantic LLM-as-judge checks resolve language variance and naming
  variance, but require durable evidence such as command results, files,
  source, tests, or runtime output.
- Keep live smoke tests realistic: a model should use the same tools a user
  would expose, and the harness should independently verify the result.
- Allow the standard ReAct agent to coordinate tactically when tools make that
  natural. It may use future bounded delegate/subagent tools for obviously
  parallelizable subtasks, such as independent research or review slices, but
  those tools should return ordinary evidence that flows through the same OODA
  gate rather than becoming an implicit RLM workflow coordinator.

## Relationship To RLM Reliability Work

The RLM implementation now has useful generic pieces, but many currently live
under `RunicAI.Coding.RLM`. The standard agent should not import RLM modules as
its public reliability layer.

Implementation should either:

- move generic modules to shared `RunicAI.Coding` namespaces and leave
  compatibility aliases in `RunicAI.Coding.RLM`, or
- introduce shared wrappers first and migrate call sites incrementally.

RLM-specific modules should remain RLM-specific:

- workflow proposal generation,
- graph compilation,
- recursive/decomposed child workflow coordination,
- reducers over workflow node observations,
- RLM coordination patterns.

Generic modules should become usable by both agents:

- acceptance checks and contracts,
- objective contracts and semantic judgement,
- objective evidence collection,
- scorecards,
- repair attempt records,
- workspace deltas,
- command-result freshness/deduplication,
- smoke-test report helpers.

## Proposed Shared Namespace

```text
lib/runic_ai/coding/
  objective_contract.ex
  objective_evidence.ex
  objective_judge.ex
  acceptance_check.ex
  acceptance_contract.ex
  objective_scorecard.ex
  repair_attempt.ex
  workspace_delta.ex
  ooda_loop.ex
  standard_agent/
    objective_gate.ex
    repair_context.ex
    smoke.ex
```

Compatibility modules can remain under `lib/runic_ai/coding/rlm/` while RLM
call sites migrate.

## Phase 0: Baseline StandardAgent FieldService Smoke

Deliverables:

- [x] Add a live smoke runner for the standard agent:
      `tmp/run_field_service_standard_agent_ooda_smoke.exs`.
- [x] The runner creates an isolated workspace under `./tmp`, prompts the
      standard agent to create `field_service_poc`, and requires the agent to do
      all project work through tools.
- [x] Expose enough generic tools for project creation and verification:
      read/search, `apply_patch`, profile verification tools, and either
      `project_command` or `run_command` under a strict `mix` allowlist.
- [x] Independently verify the resulting project after the agent stops:
      `mix compile --warnings-as-errors`, `mix test`, source evidence,
      timestamping, transition history, supervision/registry/process evidence,
      and invalid transition coverage.
- [x] Write `summary.json`, `summary.inspect`, `run_result.inspect`, and a
      compact Markdown report to an artifact directory.
- [x] Ensure the smoke reports both agent-declared status and independent
      verifier status.

Validation:

- [x] Dry fixture can run with scripted/fake clients without network.
- [x] Live smoke can run with `openai:gpt-5.4-mini`.
- [x] Baseline result records whether the current standard agent succeeds,
      partially succeeds, or overclaims completion.

## Phase 1: Shared Objective And Acceptance Substrate

Deliverables:

- [x] Move generic RLM reliability modules into shared coding namespaces or add
      shared wrapper modules:
      `AcceptanceCheck`, `AcceptanceContract`, `ObjectiveContract`,
      `ObjectiveEvidence`, `ObjectiveJudge`, `WorkflowScorecard` or renamed
      `ObjectiveScorecard`.
- [x] Preserve existing RLM public APIs with compatibility aliases or thin
      wrappers.
- [x] Keep Zoi-based structured schemas for objective extraction and judgement.
- [x] Keep deterministic acceptance checks generic and data-first.
- [x] Add shared support for latest-result semantics: newer evidence for the
      same check supersedes older evidence.
- [x] Add shared support for semantic acceptance superseding brittle heuristic
      source/name failures when required semantic checks and durable evidence
      pass.

Validation:

- [x] Existing RLM reliability tests continue to pass.
- [x] StandardAgent tests can construct and evaluate objective contracts without
      importing `RunicAI.Coding.RLM`.
- [x] Scorecard tests cover latest-result semantics and semantic override of
      naming-variant source checks.

## Phase 2: StandardAgent Objective Gate

Deliverables:

- [x] Add `RunicAI.Coding.StandardAgent.ObjectiveGate`.
- [x] The gate derives a scorecard from:
      changed files, patch observations, command observations, source
      assertions, runtime smoke results, objective contract results, and
      semantic judge results.
- [x] Integrate the gate through the StandardAgent run loop and retain a
      `continue_when` helper for hook-based usage where the runtime supports
      automatic answer continuation.
- [x] In verify mode, prevent final success when the scorecard is incomplete
      and repair budget remains.
- [x] When incomplete, inject a compact model-visible remediation prompt with:
      current objective status, blocking checks, latest failing commands,
      changed files, workspace delta, and explicit next verification target.
- [x] When budget is exhausted, allow a final answer only if it clearly reports
      incomplete status and remaining blocking evidence.

Validation:

- [x] Scripted model attempts to answer success after insufficient evidence; gate
      forces continuation or incomplete final answer.
- [x] Scripted model fixes missing implementation activity after passing tests;
      gate permits final success.
- [x] Scripted model exhausts repair budget; summary reports incomplete
      scorecard and risks.

## Phase 3: Workspace Delta And Repair Attempt Evidence

Deliverables:

- [x] Add shared `WorkspaceDelta` and `RepairAttempt` modules usable by
      StandardAgent and RLM.
- [x] Capture before/after snapshots around each mutating action group or
      repair turn.
- [x] Record created, modified, deleted, and changed paths in the agent
      summary.
- [x] Attach repair attempt evidence to session metadata or trace events.
- [x] Make timeout/exhaustion observations salvageable: if files changed before
      the budget stopped the agent, the next orientation step should verify the
      workspace rather than discard the attempt.
- [x] Preserve checkpoint/persistence hooks through existing RunicAI coding
      persistence instead of adding a new storage mechanism.

Validation:

- [x] Unit test workspace delta excludes build/dependency directories.
- [x] Unit test timed/exhausted repair attempt still reports changed files.
- [x] Session resume preserves repair attempt evidence.

## Phase 4: Prompt And ReAct Loop Contract

Deliverables:

- [x] Update `RunicAI.Coding.Prompt` for verify mode with explicit OODA
      behavior:
      observe files/commands, orient against objective evidence, decide whether
      to patch or verify, act with bounded tools, and repeat.
- [x] Add final-answer requirements for objective scorecard status and
      remaining blocking checks.
- [x] Add guidance that passing generated scaffold tests is not sufficient for
      nontrivial feature objectives.
- [x] Add guidance to run verification from the correct project directory when
      creating a nested project.
- [x] Add guidance to use semantic objective requirements and deterministic
      checks as the acceptance checklist.
- [x] Keep read-only and patch-only prompts lightweight; the full OODA contract
      should primarily apply to verify mode and named repair recipes.

Validation:

- [x] Prompt tests assert OODA/scorecard language only appears where intended.
- [x] Existing read-only prompt tests remain concise and unchanged in behavior.
- [x] Scripted nested-project task verifies commands run in the generated
      project directory.

## Phase 5: Command And Verification Freshness

Deliverables:

- [x] Normalize command observations into a latest-by-command-and-cwd view.
- [x] Treat a failing command in the wrong directory as repair evidence, not as
      proof the objective is still failed after a later passing command in the
      correct directory.
- [x] Add explicit `cwd` to verification summaries.
- [x] Let acceptance checks match commands by argv, command text, task, and cwd.
- [x] Add a generic `source_assert` verification pass for StandardAgent smoke
      checks when deterministic checks are generated by a harness.
- [x] Add optional runtime smoke hooks to StandardAgent verification recipes.

Validation:

- [x] Failing `mix test` at workspace root followed by passing `mix test` in a
      nested project results in satisfied command evidence.
- [x] Failed latest command remains blocking.
- [x] Source assertions and runtime smokes appear in summaries and trace events.

## Phase 6: StandardAgent FieldService OODA Smoke

Deliverables:

- [x] Run the FieldService exercise with `openai:gpt-5.4-mini` using
      StandardAgent, not RLM.
- [x] The standard agent must create the Mix project, write code, run
      verification, repair failures, and produce a final answer.
- [x] Codex or any outside harness may only prompt the agent and independently
      verify/report results.
- [x] The smoke report should include:
      final status, objective scorecard, repair attempts, changed files,
      command timeline, independent checks, and unresolved risks.
- [x] Compare against RLM smoke results:
      time, tool calls, repair iterations, final correctness, and failure mode.

Validation:

- [x] `mix compile --warnings-as-errors` passes in generated project.
- [x] `mix test` passes in generated project.
- [x] Independent checks pass for:
      DynamicSupervisor, Registry or equivalent lookup, GenServer,
      timestamping, transition history, required states, public facade, and
      invalid transition coverage.
- [x] Agent-reported status agrees with independent verifier status.

## Phase 7: Reporting And Regression Fixtures

Deliverables:

- [x] Add deterministic StandardAgent regression fixtures based on the
      FieldService smoke.
- [x] Store representative successful and failed trajectories.
- [x] Add compact report generation shared with the RLM smoke where possible.
- [x] Report should separate:
      model trajectory, tool evidence, objective scorecard, independent
      verification, and residual risk.
- [x] Add a comparison section for StandardAgent vs RLM on the same exercise.

Validation:

- [x] Regression fixtures can run in tests without live LLM calls.
- [x] Live smoke artifacts are readable without requiring the original process.
- [x] Report makes overclaiming obvious when the model says complete but the
      scorecard or independent verifier disagrees.

## Expected Outcome

After this plan, StandardAgent should be more reliable without becoming an RLM:

- It remains a direct ReAct tool agent.
- It gains objective-grounded stopping criteria.
- It can repair from observed evidence rather than final-answer confidence.
- It can use semantic judgement for language variance while requiring durable
  proof.
- It can complete and report on the FieldService exercise through the same
  smoke-test discipline used for RLM.

This gives us a clean comparison point:

```text
StandardAgent = direct OODA ReAct worker
RLM Agent     = dynamic workflow coordinator with recursive/decomposed OODA
```

Both should share evidence, contracts, scorecards, and smoke reporting. Only
the coordination strategy should differ.
