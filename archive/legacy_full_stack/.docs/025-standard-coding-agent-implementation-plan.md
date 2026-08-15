# Standard Coding Agent Implementation Plan

Status: implementation complete; deterministic tests/docs and live GPT-5.4-mini smokes verified

Date: 2026-04-25

Last verified: 2026-04-27 (`mix test`; `mix docs`; `RUNIC_AI_LIVE_SMOKE=1 mix test test/runic_ai/coding/live_smoke_test.exs --include live_smoke`; `mix run /tmp/runic_ai_readonly_live_smoke.exs`; `mix run /tmp/runic_ai_agent_live_smoke.exs`)

Depends on:

- `.docs/024-coding-harness-and-tools-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/012-phase-6-stateful-integrated-agent-recipes-implementation-plan.md`
- `.docs/015-phase-8-advanced-runtime-adapters-and-optimization-hooks-implementation-plan.md`

References:

- `.docs/022-coding-agent-capabilities-investigation.md`
- `.docs/023-rlm-coding-agent-investigation.md`

## Goal

Build a conventional local coding agent recipe on top of the shared coding
harness and existing RunicAI integrated tool-agent substrate.

This is the near-term practical agent: a single workflow-owned coding session
that can read files, search, apply patches, run tests, ask for review, and
produce a concise final answer.

The phase is successful when RunicAI can answer:

"How do I run a local coding agent workflow in a project, with safe tools,
patch-based editing, verification commands, approval gates, traceability, and
resume-friendly state?"

## Relationship To RLM Coding Agent

The standard coding agent is the tactical worker.

It can be used directly by users for ordinary tasks, and it can also become an
editor/verifier child workflow for the RLM coding agent.

```text
user -> standard coding agent

or

RLM coordinator -> standard coding agent child workflow
```

The standard agent should not depend on the RLM agent. The RLM agent may depend
on this plan later.

## Proposed Namespace

```text
lib/runic_ai/coding/
  agent.ex
  agent_state.ex
  prompt.ex
  recipe.ex
  recipes/
    review.ex
    fix_ci.ex
    explain_repo.ex
    write_tests.ex
    triage_bug.ex
  harness.ex
```

Most of the low-level tool modules live in the common harness plan.

## Design Principles

- Build on `RunicAI.Recipes.IntegratedToolAgent` instead of inventing a new
  loop.
- Keep the first version narrow: local workspace, patch edits, Mix verification.
- Use structured patch tools before shell commands.
- Make final answers report changed files, tests run, failures, and residual
  risk.
- Use review gates for destructive tools, broad shell commands, mutating git,
  and hidden/credential-like files.
- Keep the agent useful with fake LLM clients and scripted tools.
- Let recipes/commands be first-class when the user asks for known workflows.

## Phase 0: Agent Profile And Prompt Contract

Deliverables:

- [x] Define `RunicAI.Coding.Agent` wrapper around `IntegratedToolAgent`.
- [x] Define default coding profile using the common tool registry.
- [x] Define system/developer prompt builder from workspace instructions,
      profile, tool policy, and task input.
- [x] Load `AGENTS.md` and relevant project instructions as context artifacts.
- [x] Include git status and workspace summary in the initial turn.
- [x] Define final answer expectations: summary, changed files, verification,
      and unresolved risks.

Validation:

- [x] Unit test prompt assembly with `AGENTS.md`.
- [x] Unit test profile construction and visible tool selection.
- [x] Add fake LLM read/search answer tests.

## Phase 1: Read-Only Coding Agent

Deliverables:

- [x] Expose read/list/search/git-read tools to the model.
- [x] Build a recipe that can answer repo questions without mutation.
- [x] Add output caps and artifact references for long reads/searches.
- [x] Add a `/explain-repo` or equivalent named recipe as an example command.
- [x] Add trace events for tool visibility, tool calls, and observations.

Validation:

- [x] Scripted LLM test for search -> read -> final answer.
- [x] Test that write/command tools are not visible in read-only profile.
- [x] Manual smoke: ask about a module in this repo and verify cited files.

## Phase 2: Patch Editing Loop

Deliverables:

- [x] Enable `apply_patch` as the default editing tool.
- [x] Add guard policy for write scope and risky paths.
- [x] Teach the agent prompt to inspect before editing.
- [x] Normalize patch errors into tool observations that support repair.
- [x] Ensure changed-file summaries are carried into final answers.
- [x] Add dry-run mode for planning-only sessions.

Validation:

- [x] Scripted LLM test for bad patch -> diagnostic -> corrected patch.
- [x] Test path policy blocks workspace escapes.
- [x] Test final answer includes changed files and patch summary.

## Phase 3: Verification Loop

Deliverables:

- [x] Enable curated command tools for Mix compile, test, and format.
- [x] Add verification policy: targeted tests first, broader tests when needed.
- [x] Parse command results into concise observations.
- [x] Allow one or more repair cycles after failing verification.
- [x] Add stop condition when verification passes or repair budget is exhausted.

Validation:

- [x] Scripted tool test for failing test -> repair -> passing test.
- [x] Test timeout and output cap behavior through coding command policy.
- [x] Manual smoke with a temporary failing test fixture.

## Phase 4: Human Review And Risk Gates

Deliverables:

- [x] Review-gate shell commands, destructive file operations, mutating git, and
      broad writes.
- [x] Emit `ReviewRequest` with exact command/path/patch details.
- [x] Support `ReviewDecision` allow, deny, rewrite, wait, and final-stop
      outcomes.
- [x] Add budget gates for max tool calls, max command runtime, and max repair
      cycles.

Validation:

- [x] Unit test review request payloads.
- [x] Test denied operation becomes model-visible observation.
- [x] Test rewritten operation executes the replacement plan.

## Phase 5: Named Coding Recipes And Commands

Deliverables:

- [x] Add recipe registry for common coding tasks.
- [x] Implement `/review` as diff/hunk-focused read-only review.
- [x] Implement `/triage-bug` as read/search/log investigation without edits.
- [x] Implement `/write-tests` as test-focused editing recipe.
- [x] Implement `/fix-ci` as command-output-driven repair recipe.
- [x] Let the general agent choose recipes when confidence is high, while still
      allowing direct user invocation.

Validation:

- [x] Add scripted tests for each named recipe path.
- [x] Add recipe selection tests with fake classifier output.
- [x] Document which tools each recipe enables.

## Phase 6: Session Runtime And Resume

Deliverables:

- [x] Integrate with `RunicAI.Runtime.SessionSpec` and integrated harness.
- [x] Persist or serialize session snapshots through the common persistence
      behaviour when enabled.
- [x] Support resume after review, wait, or process completion.
- [x] Preserve trace trajectory and changed-file evidence across resumes.
- [x] Add interruption handling that summarizes current work and stops safely.

Validation:

- [x] Test session resume after pending review.
- [x] Test session resume after failed verification.
- [x] Test trace replay with scripted LLM/tool doubles.

## Phase 7: Codex-Managed Local Auth Path

Deliverables:

- [x] Allow the model/client layer to route through the common Codex bridge when
      explicitly configured.
- [x] Keep Codex use focused on subscription-backed local testing.
- [x] Preserve the same tool policy and final answer expectations.
- [x] Add clear fallback to ReqLLM API-key clients.

Validation:

- [x] Unit test configuration selection.
- [x] Event-normalization tests with Codex JSONL fixtures.
- [x] Skip live Codex smoke tests unless local Codex CLI is present and opted in.

## Phase 8: Evaluation, Replay, And Documentation

Deliverables:

- [x] Add evaluation cases for read-only QA, patch repair, test writing, and
      review.
- [x] Add replay fixtures using `RunicAI.Testing.ScriptedLLM` and scripted
      tools.
- [x] Add guide or internal doc examples only after API shape stabilizes.
- [x] Add release checklist entry for coding-agent safety defaults.

Validation:

- [x] `mix test` passes.
- [x] Evaluation harness can run deterministic coding fixtures.
- [x] Manual smoke checklist covers read, edit, verify, review, and resume.

## Done Criteria

- [x] A user can run a local standard coding-agent workflow against a workspace.
- [x] The agent can make patch edits and run focused verification.
- [x] Risky operations are review-gated by default.
- [x] Sessions are traceable and replayable.
- [x] The agent can be used directly or as a child workflow by the RLM coding
      agent.
