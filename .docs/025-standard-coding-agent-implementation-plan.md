# Standard Coding Agent Implementation Plan

Status: draft implementation plan

Date: 2026-04-25

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

- [ ] Define `RunicAI.Coding.Agent` wrapper around `IntegratedToolAgent`.
- [ ] Define default coding profile using the common tool registry.
- [ ] Define system/developer prompt builder from workspace instructions,
      profile, tool policy, and task input.
- [ ] Load `AGENTS.md` and relevant project instructions as context artifacts.
- [ ] Include git status and workspace summary in the initial turn.
- [ ] Define final answer expectations: summary, changed files, verification,
      and unresolved risks.

Validation:

- [ ] Unit test prompt assembly with and without `AGENTS.md`.
- [ ] Unit test profile construction and visible tool selection.
- [ ] Add a fake LLM one-turn answer test.

## Phase 1: Read-Only Coding Agent

Deliverables:

- [ ] Expose read/list/search/git-read tools to the model.
- [ ] Build a recipe that can answer repo questions without mutation.
- [ ] Add output caps and artifact references for long reads/searches.
- [ ] Add a `/explain-repo` or equivalent named recipe as an example command.
- [ ] Add trace events for tool visibility, tool calls, and observations.

Validation:

- [ ] Scripted LLM test for search -> read -> final answer.
- [ ] Test that write/command tools are not visible in read-only profile.
- [ ] Manual smoke: ask about a module in this repo and verify cited files.

## Phase 2: Patch Editing Loop

Deliverables:

- [ ] Enable `apply_patch` as the default editing tool.
- [ ] Add guard policy for write scope and risky paths.
- [ ] Teach the agent prompt to inspect before editing.
- [ ] Normalize patch errors into tool observations that support repair.
- [ ] Ensure changed-file summaries are carried into final answers.
- [ ] Add dry-run mode for planning-only sessions.

Validation:

- [ ] Scripted LLM test for bad patch -> diagnostic -> corrected patch.
- [ ] Test path policy blocks workspace escapes.
- [ ] Test final answer includes changed files and patch summary.

## Phase 3: Verification Loop

Deliverables:

- [ ] Enable curated command tools for Mix compile, test, and format.
- [ ] Add verification policy: targeted tests first, broader tests when needed.
- [ ] Parse command results into concise observations.
- [ ] Allow one or more repair cycles after failing verification.
- [ ] Add stop condition when verification passes or repair budget is exhausted.

Validation:

- [ ] Scripted tool test for failing test -> repair -> passing test.
- [ ] Test timeout and output cap behavior.
- [ ] Manual smoke with a temporary failing test fixture.

## Phase 4: Human Review And Risk Gates

Deliverables:

- [ ] Review-gate shell commands, destructive file operations, mutating git, and
      broad writes.
- [ ] Emit `ReviewRequest` with exact command/path/patch details.
- [ ] Support `ReviewDecision` allow, deny, rewrite, wait, and final-stop
      outcomes.
- [ ] Add budget gates for max tool calls, max command runtime, and max repair
      cycles.

Validation:

- [ ] Unit test review request payloads.
- [ ] Test denied operation becomes model-visible observation.
- [ ] Test rewritten operation executes the replacement plan.

## Phase 5: Named Coding Recipes And Commands

Deliverables:

- [ ] Add recipe registry for common coding tasks.
- [ ] Implement `/review` as diff/hunk-focused read-only review.
- [ ] Implement `/triage-bug` as read/search/log investigation without edits.
- [ ] Implement `/write-tests` as test-focused editing recipe.
- [ ] Implement `/fix-ci` as command-output-driven repair recipe.
- [ ] Let the general agent choose recipes when confidence is high, while still
      allowing direct user invocation.

Validation:

- [ ] Add scripted tests for each named recipe path.
- [ ] Add recipe selection tests with fake classifier output.
- [ ] Document which tools each recipe enables.

## Phase 6: Session Runtime And Resume

Deliverables:

- [ ] Integrate with `RunicAI.Runtime.SessionSpec` and integrated harness.
- [ ] Persist or serialize session snapshots through the common persistence
      behaviour when enabled.
- [ ] Support resume after review, wait, or process completion.
- [ ] Preserve trace trajectory and changed-file evidence across resumes.
- [ ] Add interruption handling that summarizes current work and stops safely.

Validation:

- [ ] Test session resume after pending review.
- [ ] Test session resume after failed verification.
- [ ] Test trace replay with scripted LLM/tool doubles.

## Phase 7: Codex-Managed Local Auth Path

Deliverables:

- [ ] Allow the model/client layer to route through the common Codex bridge when
      explicitly configured.
- [ ] Keep Codex use focused on subscription-backed local testing.
- [ ] Preserve the same tool policy and final answer expectations.
- [ ] Add clear fallback to ReqLLM API-key clients.

Validation:

- [ ] Unit test configuration selection.
- [ ] Event-normalization tests with Codex JSONL fixtures.
- [ ] Skip live Codex smoke tests unless local Codex CLI is present and opted in.

## Phase 8: Evaluation, Replay, And Documentation

Deliverables:

- [ ] Add evaluation cases for read-only QA, patch repair, test writing, and
      review.
- [ ] Add replay fixtures using `RunicAI.Testing.ScriptedLLM` and scripted
      tools.
- [ ] Add guide or internal doc examples only after API shape stabilizes.
- [ ] Add release checklist entry for coding-agent safety defaults.

Validation:

- [ ] `mix test` passes.
- [ ] Evaluation harness can run deterministic coding fixtures.
- [ ] Manual smoke checklist covers read, edit, verify, review, and resume.

## Done Criteria

- [ ] A user can run a local standard coding-agent workflow against a workspace.
- [ ] The agent can make patch edits and run focused verification.
- [ ] Risky operations are review-gated by default.
- [ ] Sessions are traceable and replayable.
- [ ] The agent can be used directly or as a child workflow by the RLM coding
      agent.

