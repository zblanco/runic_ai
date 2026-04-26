# RLM Coding Agent Implementation Plan

Status: draft implementation plan

Date: 2026-04-25

Depends on:

- `.docs/024-coding-harness-and-tools-implementation-plan.md`
- `.docs/025-standard-coding-agent-implementation-plan.md`
- `.docs/017-phase-9-rlm-execution-mode-and-recursive-long-context-workflows-implementation-plan.md`
- `.docs/020-runic-rlm-architecture-explainer.md`

References:

- `.docs/023-rlm-coding-agent-investigation.md`
- `.docs/022-coding-agent-capabilities-investigation.md`
- `/home/doops/wrk/runic/.docs/workflow-rewriting-rlm-exploration.md`

## Goal

Build a RunicAI coding agent whose outer strategy layer is an RLM coordinator
that can compose and rewrite purpose-built Runic workflows at runtime.

This plan builds on the shared coding harness and may use the standard coding
agent as a tactical child workflow, but the distinctive work here is the
coordinator-driven workflow proposal, validation, compilation, execution, and
recursive continuation loop.

The phase is successful when RunicAI can answer:

"How can a coding objective over a large codebase become a bounded,
policy-validated Runic workflow that the coordinator can extend recursively
through typed episodes, continuations, and plan patches?"

## Relationship To Standard Coding Agent

The standard coding agent is tactical and sequential. It is useful directly and
as an editor/verifier worker.

The RLM coding agent is strategic and recursive. It decides what workflow shape
should exist for a broad or ambiguous coding objective.

```text
RLM coordinator
  -> codebase environment
  -> workflow proposal
  -> compiled Runic workflow
  -> leaf nodes, tools, reducers, scripts, standard-agent children
  -> episodes / plan patches / final artifact
```

## Proposed Namespace

```text
lib/runic_ai/coding/rlm/
  agent.ex
  coordinator.ex
  codebase_environment.ex
  source_index.ex
  structural_splitter.ex
  workflow_proposal.ex
  proposal_node.ex
  workflow_validator.ex
  workflow_compiler.ex
  plan_patch_validator.ex
  artifact.ex
  finding.ex
  contract_fact.ex
  risk.ex
  patch_plan.ex
  verification_observation.ex
  reducers.ex
  recipe_library.ex
  continuation_policy.ex
```

## Design Principles

- The coordinator proposes workflow structure as data.
- Generated workflow data is inert until validated.
- Validation checks schema, allowed node kinds, path policy, tool policy,
  recursion, cost, and stop conditions.
- Compilation produces ordinary Runic workflows and ordinary RunicAI tools.
- Recipes are valid high-confidence shortcuts and seed patterns.
- Workers can return `Episode`, `Continuation`, or `PlanPatch`.
- Mutation happens late, narrowly, and through the common patch/edit tools.
- All broad exploration should be read-only by default.

## Phase 0: Workflow Proposal Contracts

Deliverables:

- [ ] Define `WorkflowProposal` with objective, assumptions, sources, nodes,
      edges, policies, expected artifacts, stop conditions, and metadata.
- [ ] Define `ProposalNode` with node kind, inputs, outputs, params, policy, and
      provenance.
- [ ] Define allowed node kinds: `:llm_leaf`, `:tool`, `:command`, `:script`,
      `:deterministic_step`, `:agent`, `:reducer`, `:review_gate`,
      `:workflow_patch`.
- [ ] Define `WorkflowValidationReport` with errors, warnings, estimated cost,
      and accepted/rejected node list.
- [ ] Map proposal artifacts to existing RLM contracts where possible:
      `Plan`, `PlanNode`, `PlanPatch`, `Episode`, `Continuation`,
      `CostEstimate`.

Validation:

- [ ] Unit test valid and invalid proposal construction.
- [ ] Unit test node-kind validation.
- [ ] Unit test missing stop condition rejection.
- [ ] Unit test cyclic graph rejection unless explicitly supported and bounded.

## Phase 1: Codebase Environment

Deliverables:

- [ ] Implement `CodebaseEnvironment` using the common workspace and path policy.
- [ ] Register repo manifest, instructions, source files, tests, diffs, logs,
      and prior session artifacts as source refs.
- [ ] Add structural slice modes: file, line window, search hit, diff hunk, and
      command log section.
- [ ] Add source metadata: path, language, size, checksum, kind, and tags.
- [ ] Add materialization by file/range/slice with provenance.

Validation:

- [ ] Unit test source registration and materialization.
- [ ] Unit test structural slice metadata.
- [ ] Unit test path policy enforcement.
- [ ] Integration test indexing this repo in read-only mode.

## Phase 2: Read-Only Coordinator

Deliverables:

- [ ] Implement coordinator prompt/request builder over objective, policy,
      source summaries, recipes, and allowed node kinds.
- [ ] Use `RunicAI.LLM.generate_object/4` or a structured-output equivalent to
      request `WorkflowProposal`.
- [ ] Add recipe library examples as seed patterns: repo QA, bug investigation,
      patch planning, review, verify.
- [ ] Add high-confidence route for explicitly invoked recipe commands.
- [ ] Add fallback to safe recipe when generated proposal fails validation.
- [ ] Keep first live coordinator read-only: no patch, shell, or mutating git.

Validation:

- [ ] Scripted LLM test for coordinator proposal generation.
- [ ] Test explicit command invokes recipe without open-ended synthesis.
- [ ] Test invalid generated proposal falls back to safe recipe.
- [ ] Manual smoke: generate a read-only investigation workflow for a failing
      test log.

## Phase 3: Workflow Compiler

Deliverables:

- [ ] Compile `:llm_leaf` nodes to bounded `RunicAI.LLM` steps over
      materialized artifacts.
- [ ] Compile `:tool` nodes to existing `RunicAI.Tool` execution steps.
- [ ] Compile `:command` nodes to guarded common command tools.
- [ ] Compile `:deterministic_step` nodes only from allowlisted modules.
- [ ] Compile `:reducer` nodes to deterministic or LLM-assisted reducers.
- [ ] Compile `:review_gate` nodes to existing guard/review/wait contracts.
- [ ] Compile `:agent` nodes to child workflows, initially standard coding
      agent read-only or editor/verifier recipes.
- [ ] Preserve proposal provenance in workflow metadata and trace events.

Validation:

- [ ] Unit test compilation of each node kind.
- [ ] Unit test rejected unsafe node kinds.
- [ ] Integration test proposal -> Runic workflow -> execution with fake LLMs.
- [ ] Assert trace links output artifacts back to proposal nodes and sources.

## Phase 4: Episodes, Plan Patches, And Recursive Expansion

Deliverables:

- [ ] Define how worker outputs normalize into `Episode`.
- [ ] Define plan patch schema for adding nodes, replacing nodes, changing
      edges, or adding continuation work.
- [ ] Implement `PlanPatchValidator` with max depth, max patch count, max child
      workflow count, cost estimate, and path/tool policy checks.
- [ ] Implement coordinator loop that accepts final, partial, blocked, extended,
      and failed episodes.
- [ ] Add decreasing-measure metadata for recursive continuations where
      practical, such as narrower source set, fewer failing tests, or smaller
      diff scope.

Validation:

- [ ] Unit test accepted and rejected plan patches.
- [ ] Test recursion stops at depth limit.
- [ ] Test patch count and child workflow budgets.
- [ ] Scripted episode test: worker proposes new search branch, coordinator
      validates and executes it.

## Phase 5: Coding Artifacts And Reducers

Deliverables:

- [ ] Define `Finding`, `ContractFact`, `Risk`, `PatchPlan`,
      `VerificationObservation`, and `RepairNeed` artifacts.
- [ ] Implement finding reducer for deduplication and ranking.
- [ ] Implement contract reducer for API/behavior/test constraints.
- [ ] Implement risk reducer for blast radius and safety review.
- [ ] Implement patch-plan reducer that produces ordered edit steps and
      verification strategy.
- [ ] Implement verification reducer for pass/fail/blocked/flaky output.

Validation:

- [ ] Unit test reducers on deterministic fixtures.
- [ ] Scripted LLM tests for artifact extraction from code slices.
- [ ] Evaluation fixture: failing log + repo slices -> ranked diagnosis.

## Phase 6: Editor And Verifier Integration

Deliverables:

- [ ] Allow the coordinator to call standard coding-agent child workflows for
      editor and verifier roles.
- [ ] Pass narrow write scopes and expected artifacts into editor children.
- [ ] Require editor children to return patch summaries and changed-file hashes.
- [ ] Require verifier children to return command observations and status.
- [ ] Feed failed verification into `RepairNeed` and continuation generation.

Validation:

- [ ] Integration test RLM diagnosis -> standard-agent patch child -> verifier.
- [ ] Test narrow write-scope enforcement.
- [ ] Test failed verifier output generates targeted continuation.

## Phase 7: Scripts, Commands, And Advanced Node Kinds

Deliverables:

- [ ] Add sandboxed `:script` nodes for generated helper scripts only when
      explicitly enabled.
- [ ] Use `just_bash` or another sandbox backend for safe script experiments
      where practical.
- [ ] Keep real workspace mutation out of generated scripts unless review-gated.
- [ ] Add command-node policies for verifier commands and read-only diagnostics.
- [ ] Add artifact capture for script output.

Validation:

- [ ] Unit test script policy validation.
- [ ] Test script node disabled by default.
- [ ] Smoke test safe sandboxed script over virtual/input data.

## Phase 8: Persistence And Runtime

Deliverables:

- [ ] Persist source indexes, proposals, validation reports, compiled plan
      metadata, episodes, plan patches, artifacts, commands, and traces.
- [ ] Add session search over prior RLM coding runs.
- [ ] Support resume after wait/review/process completion.
- [ ] Integrate with `RunicAI.Runtime.SessionSpec` and runner-backed execution
      where available.

Validation:

- [ ] Unit test serialization for proposals, episodes, and artifacts.
- [ ] Integration test resume after pending review.
- [ ] Replay test from persisted trace with scripted doubles.

## Phase 9: Codex-Managed Local Auth Path

Deliverables:

- [ ] Allow coordinator or leaf LLM calls to use the common Codex auth bridge
      when explicitly configured.
- [ ] Keep Codex optional and not responsible for recursive decomposition.
- [ ] Normalize observed Codex events into RLM trace artifacts.
- [ ] Preserve policy and validation boundaries even when model access is routed
      through Codex.

Validation:

- [ ] Unit test Codex event normalization into RLM artifacts.
- [ ] Skipped live smoke test for local subscription-backed model access.

## Phase 10: Evaluation And Recipe Baselines

Deliverables:

- [ ] Add read-only codebase QA evaluation cases.
- [ ] Add bug investigation evaluation cases.
- [ ] Add patch-planning evaluation cases.
- [ ] Compare generated workflow proposals against named recipe baselines.
- [ ] Track cost estimates, actual calls, source coverage, and repair cycles.
- [ ] Add safety regression tests for invalid workflow proposals.

Validation:

- [ ] Deterministic evaluation harness runs in `mix test` or a separate smoke
      script.
- [ ] Reports include proposal, accepted graph, source refs, artifacts, and
      final answer.

## Done Criteria

- [ ] Coordinator can generate a read-only workflow proposal from a coding
      objective.
- [ ] Proposal validation prevents unsafe or unbounded workflows.
- [ ] Compiler turns accepted proposals into executable Runic workflows.
- [ ] Workers can return episodes and validated plan patches.
- [ ] The RLM agent can use the standard coding agent for narrow edit/verify
      child workflows.
- [ ] Sessions are traceable, replayable, and persistable.

