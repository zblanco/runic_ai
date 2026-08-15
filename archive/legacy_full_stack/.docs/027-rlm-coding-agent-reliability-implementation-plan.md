# RLM Coding Agent Reliability Implementation Plan

Status: implementation in progress; generic reliability substrate, bounded
verify/repair/verify loop, strict command verification, wall-clock runtime
budgets, checkpoint persistence, ETS development persistence, LLM-extracted
objective contracts, LLM-as-judge semantic progress gates, and generic fallback
progress heuristics implemented; live benchmark rerun pending

Last verified: 2026-04-28 (`mix compile --warnings-as-errors`;
`mix test test/runic_ai/coding/rlm_reliability_test.exs`; `mix test`)

Date: 2026-04-27

Motivated by: strict RLM-owned FieldService smoke test, 2026-04-27

Depends on:

- `.docs/024-coding-harness-and-tools-implementation-plan.md`
- `.docs/025-standard-coding-agent-implementation-plan.md`
- `.docs/026-rlm-coding-agent-implementation-plan.md`

References:

- `.docs/023-rlm-coding-agent-investigation.md`
- `.docs/026-rlm-coding-agent-implementation-plan.md`
- `tmp/field_service_rlm_agent_owned_artifacts/strict_rlm_owned_build.json`

## Goal

Make the RunicAI RLM coding agent reliable enough to complete bounded local
coding tasks end to end without Codex manually doing the implementation work.

The motivating failure was useful: the RLM coordinator successfully proposed
and executed a workflow, created a Mix project, and delegated implementation to
a child coding agent, but the resulting project did not satisfy the requested
POC. It passed scaffold tests only, left compiler warnings, failed
`--warnings-as-errors`, did not wire the OTP supervision tree, and produced an
internally contradictory child-agent report.

This plan closes that gap.

The phase is successful when RunicAI can answer:

"Can an RLM coding agent turn a user objective into a verified working project
by planning, scaffolding, editing, testing, repairing, reviewing, and reporting
without relying on an outside agent to fill in implementation gaps?"

## Failure Summary From Strict Smoke

Observed issues:

- The parent RLM workflow marked the implementation child as satisfied even
  though the child reported incomplete work.
- `mix test` passed because generated scaffold tests remained, not because the
  requested behavior was verified.
- `mix compile --warnings-as-errors` failed, but warnings were not part of the
  acceptance gate.
- Required runtime wiring was missing: the application supervision tree did not
  start the Registry or DynamicSupervisor used by the generated facade.
- The workflow had no deterministic assertions for required modules,
  supervision children, public APIs, or domain behavior.
- The child agent had patch/tool friction and returned inconsistent completion
  metadata.
- The final RLM review noticed minor gaps but did not fail the workflow or
  trigger a repair continuation.

Primary conclusion:

The current RLM agent can orchestrate and partially implement, but reliability
requires stronger task contracts, typed edit nodes, child-agent exit semantics,
deterministic verification gates, and repair loops based on observed failures
rather than LLM self-report.

## Design Principles

- A workflow node is not complete because an LLM says it is complete.
- Passing generic commands is not sufficient; acceptance must be tied to the
  user objective.
- Scaffold-only generated projects must produce explicit repair needs, even
  when their generated compile and test commands pass.
- Mutation should happen through typed, validated edit artifacts.
- Verification should include tests, compiler warnings, runtime smoke checks,
  and deterministic source assertions.
- Child agents must have explicit roles, scopes, budgets, required outputs, and
  failure semantics.
- Long-running orchestration needs wall-clock budgets in addition to turn,
  tool-call, and command budgets.
- The coordinator should repair from concrete observations: compiler output,
  failed assertions, missing files, missing functions, failed runtime checks,
  and incomplete child reports.
- RLM-generated workflows may use generic coordination patterns for staging,
  decomposition, verification, repair, and review, but should not use
  language-, framework-, or task-specific workflow templates that hide weak
  dynamic planning.
- Final reports must distinguish "orchestration finished" from "objective
  satisfied".

## Anti-Template Constraint

This plan should not add Mix-, Elixir-, Phoenix-, OTP-, FieldService-, or
project-shape-specific workflow templates.

Reusable support is allowed only when it is generic coordination machinery:
acceptance contracts, edit nodes, child contracts, fan-out/fan-in controls,
verification gates, repair loops, scorecards, graph export, and language/tool
adapters. The RLM coordinator must still dynamically generate the actual
task-specific workflow from the user objective and workspace evidence.

## Proposed Namespace

```text
lib/runic_ai/coding/rlm/
  acceptance_contract.ex
  acceptance_check.ex
  child_contract.ex
  child_result.ex
  edit_node.ex
  edit_operation.ex
  edit_patch_set.ex
  checkpoint.ex
  progress_gate.ex
  repair_controller.ex
  verification_gate.ex
  verification_assertions.ex
  objective_requirement.ex
  objective_contract.ex
  objective_evidence.ex
  objective_judge.ex
  workflow_scorecard.ex
  coordination_patterns/
    staged_delivery.ex
    parallel_decomposition.ex
    verify_repair_loop.ex
    review_scorecard.ex
```

## Phase 0: Preserve The Failure As A Regression Fixture

Deliverables:

- [x] Capture the strict FieldService RLM-owned smoke as a named reliability
      fixture.
- [ ] Store the objective, accepted workflow proposal, trace, child-agent
      result, command outputs, final files, and review findings as replayable
      artifacts.
- [x] Persist bounded RLM checkpoints for prepare/proposal/compile/execution
      and per-node start/complete/failure through the existing coding
      persistence behaviour.
- [x] Define the expected outcome contract for this fixture:
      generated Mix app, functional core state machine, dynamically supervised
      WorkOrder GenServers, Registry lookup, timestamps/history, tests, and
      warnings-free compilation.
- [x] Add a failure taxonomy for the observed gaps: scaffold-test pass,
      missing supervision wiring, compiler-warning failure, incomplete child
      report, and weak parent success semantics.

Validation:

- [x] Deterministic fixture can be loaded in tests without live LLM calls.
- [x] Fixture scorecard marks the current strict run as incomplete.
- [ ] Fixture report clearly separates completed orchestration nodes from
      satisfied user deliverables.

## Phase 1: Acceptance Contracts

Deliverables:

- [x] Define `AcceptanceContract` for coding objectives.
- [x] Define `AcceptanceCheck` types:
      `:file_exists`, `:module_exists`, `:function_exists`,
      `:source_contains`, `:source_not_contains`, `:command_passes`,
      `:command_fails_with`, `:test_count_min`, `:warning_count_zero`,
      `:runtime_smoke`, `:child_status`, and `:artifact_present`.
- [x] Add contract fields for required deliverables, forbidden scaffold
      leftovers, required verification commands, and optional quality checks.
- [ ] Let the coordinator derive a draft acceptance contract from the user
      objective.
- [x] Add a generic progress gate that derives high-signal objective terms and
      fails scaffold-only or semantically empty implementation evidence.
- [x] Let generic coordination patterns provide contract hints without
      supplying prebuilt task-specific workflow graphs.
- [x] Add deterministic contract validation before final success.
- [x] Make command acceptance checks strict: malformed checks without a concrete
      command fail instead of matching an unrelated command observation, while
      supporting generated nested `params.args.argv` selectors, command `cwd`,
      and latest matching verification observations.

Validation:

- [x] Unit test contract construction and validation.
- [ ] Unit test each acceptance check type.
- [x] Test that scaffold tests alone fail a nontrivial coding contract.
- [x] Test that missing OTP supervision wiring can be represented as a failed
      source or runtime assertion.
- [x] Test nested command selectors, missing command selectors, command `cwd`,
      and latest matching observations.

## Phase 2: First-Class Edit Nodes

Deliverables:

- [x] Add a first-class `:edit` proposal node kind for validated file mutation.
- [x] Define `EditPatchSet` with objective, target paths, before hashes,
      operations, expected changed files, and metadata.
- [x] Define `EditOperation` variants:
      `:apply_unified_patch`, `:replace_file`, `:create_file`,
      `:delete_file`, and `:format_files`.
- [x] Route all edit operations through existing workspace/path policy.
- [x] Fix patch tool schema friction so metadata is always a map and tool
      observations are easy for LLM children to repair from.
- [x] Record before/after file hashes and patch summaries in trace artifacts.
- [x] Make edit nodes fail loudly when no files changed, expected files are
      missing, or path policy blocks the operation.
- [x] Validate edit operation kinds before execution so invalid generated edit
      nodes become coordinator-repairable proposal errors instead of runtime
      exceptions.
- [x] Return structured errors when child agent `workspace_path` scopes point
      at missing directories instead of raising during execution.

Validation:

- [x] Unit test patch set validation.
- [ ] Unit test path escape rejection.
- [x] Unit test no-op edit detection.
- [x] Unit test invalid edit operation validation returns a structured error.
- [x] Unit test missing child workspace scopes return structured errors.
- [ ] Integration test bad patch -> diagnostic -> corrected patch.
- [x] Integration test RLM proposal -> edit node -> changed-file artifact.

## Phase 3: Child-Agent Contracts And Exit Semantics

Deliverables:

- [x] Define `ChildContract` with role, scope, allowed tools, required
      artifacts, verification commands, stop criteria, and budgets.
- [x] Define `ChildResult` with status:
      `:completed`, `:partial`, `:blocked`, `:failed`, or `:needs_review`.
- [x] Require child agents to return changed files, file hashes, commands run,
      command statuses, contract checks attempted, unresolved risks, and a
      self-assessed confidence reason.
- [x] Make parent RLM nodes fail or continue when child status is not
      `:completed`.
- [x] Add per-child wall-clock budgets for generated agent nodes so slow
      children are recorded as failed child results instead of forcing a
      whole-run timeout.
- [x] Treat contradictory child outputs as failed verification, not success.
- [ ] Add role-specific child prompts for planner, implementer, test writer,
      verifier, reviewer, and repairer.
- [x] Pass narrow write scopes and exact acceptance checks into implementer and
      repair children.

Validation:

- [x] Unit test child result normalization.
- [x] Test child agent runtime budget records a failed child result without
      aborting the workflow.
- [x] Test incomplete child status prevents parent node satisfaction.
- [ ] Test child changed-file claims are checked against actual file hashes.
- [x] Test parent generates `RepairNeed` from child `:partial` and `:failed`
      results.

## Phase 4: Generic Coordination Patterns

Deliverables:

- [x] Add generic coordination patterns, not language-, framework-, or
      domain-specific workflow templates.
- [x] Define a `StagedDelivery` pattern:
      understand objective -> derive acceptance contract -> inspect workspace ->
      plan work -> execute bounded changes -> verify -> repair or report.
- [x] Define a `ParallelDecomposition` pattern where the coordinator must
      dynamically choose child roles, scopes, dependencies, and fan-in gates
      from the objective and workspace evidence.
- [x] Define a `VerifyRepairLoop` pattern that can wrap any generated workflow
      with acceptance checks, repair continuations, and budgeted retries.
- [x] Define a `ReviewScorecard` pattern that turns completed child outputs,
      verification observations, and residual risks into a final objective
      status.
- [x] Require the coordinator to synthesize task-specific nodes, edges, child
      contracts, and verification checks at runtime rather than selecting a
      prebuilt Mix/Elixir/project workflow.
- [x] Ensure every generated fan-in has a deterministic merge gate that checks
      changed files, command status, child status, and contract progress.

Validation:

- [x] Unit test generic coordination pattern expansion.
- [ ] Test generated graphs are acyclic and bounded.
- [ ] Test pattern expansion preserves user path and tool constraints.
- [x] Scripted RLM test verifies the FieldService objective still requires
      dynamic task-specific graph synthesis, not a prebuilt project template.

## Phase 5: Verification Gates

Deliverables:

- [x] Add `VerificationGate` nodes that evaluate acceptance checks and emit
      structured `VerificationObservation` and `RepairNeed` artifacts.
- [x] Add default Elixir/Mix gates:
      `mix format --check-formatted`, `mix compile --warnings-as-errors`,
      targeted `mix test`, full `mix test`, and project-specific `mix run -e`
      runtime smoke.
- [x] Add source assertions for generated app tasks:
      application children present, no scaffold-only test file, required
      modules/functions present, and expected public facade callable.
- [x] Make source assertions layout-tolerant for generic coding tasks by
      supporting file, directory, multi-path, and glob selectors while keeping
      selectors confined to the workspace root.
- [x] Make command assertions normalize argv and `cwd` from top-level and nested
      generated shapes, require exact observed command matches, and prefer the
      latest matching observation after repair reruns.
- [x] Add minimum meaningful test detection:
      test files must exercise requested domain behavior, not only generated
      scaffold functions.
- [x] Add generic semantic progress detection so mutating workflows fail when
      source/test evidence does not cover high-signal terms from the objective.
- [x] Add LLM-driven objective contract extraction so semantic requirements are
      explicit, structured, and independent of hardcoded keyword lists.
- [x] Add an evidence-first LLM semantic judge that scores each requirement
      against source, tests, command results, child summaries, and verification
      observations.
- [x] Persist semantic contracts, judge results, and compact evidence summaries
      with RLM coding run snapshots.
- [x] Parse compile warnings, ExUnit failures, and runtime errors into
      file/line-scoped repair facts.
- [x] Prevent final success when required verification gates are skipped.

Validation:

- [ ] Unit test command-output parsing for Mix compile/test failures.
- [x] Unit test scaffold-test detection.
- [x] Unit test source assertions over generated OTP application files.
- [x] Unit test directory/glob source assertions and escaping glob rejection.
- [x] Unit test command assertions do not pass on unrelated command results or
      stale observations from the wrong working directory.
- [x] Unit test structured objective-contract extraction.
- [x] Unit test semantic judge failures create blocking scorecard results and
      repair needs.
- [ ] Integration test warnings-as-errors failure creates targeted repair work.
- [ ] Integration test runtime smoke catches missing supervisor wiring.

## Phase 6: Repair Controller

Deliverables:

- [x] Implement `RepairController` that consumes `RepairNeed` artifacts and
      proposes bounded continuations.
- [x] Add repair categories:
      compile error, compiler warning, test failure, missing deliverable,
      missing runtime wiring, incomplete child result, and weak test coverage.
- [ ] Route repairs to the smallest suitable child role:
      implementer for code gaps, test writer for missing coverage, verifier for
      command reruns, reviewer for semantic risk.
- [ ] Track decreasing measures such as fewer failing checks, fewer warnings,
      fewer missing deliverables, and narrower changed-file sets.
- [x] Stop with an explicit incomplete status when repair budget is exhausted.
- [x] Add wall-clock runtime budgets for repair children so a slow child agent
      or generated verification loop returns a structured timeout.
- [x] Catch orchestration exceptions inside runtime-budgeted tasks and return
      structured errors instead of linked-task caller exits.
- [x] Add repair-loop summaries to final artifacts.

Validation:

- [x] Unit test repair classification.
- [x] Test repair budget exhaustion returns incomplete, not success.
- [x] Test repair child wall-clock budget exhaustion returns a structured
      timeout.
- [x] Test runtime-budgeted orchestration exceptions return structured errors.
- [x] Test successful repair updates acceptance scorecard.
- [ ] Scripted fixture: missing supervisor child -> repair -> runtime smoke
      passes.

## Phase 7: Default Prompting And Policy

Deliverables:

- [x] Update RLM coordinator default prompt to require an acceptance contract
      before mutation.
- [x] Prompt the coordinator to produce acyclic proposals and layout-tolerant
      acceptance checks unless exact files/modules are explicitly required.
- [x] Tighten coordinator structured-output schema so `nodes` and `edges` must
      be object arrays and stop conditions must be strings, reducing malformed
      bare-string node proposals.
- [x] Add provider-agnostic fallback from structured object generation to JSON
      text proposal generation when a provider rejects nested object schemas.
- [x] Prompt the coordinator to emit concrete command selectors for command
      acceptance checks and prefer top-level argv arrays.
- [ ] Update coding child prompts to state that scaffold tests do not prove
      completion.
- [ ] Require warnings-free compilation by default for Elixir tasks unless the
      user explicitly relaxes this.
- [ ] Require meaningful tests for requested behavior when a task creates or
      changes behavior.
- [ ] Require final reports to include:
      acceptance scorecard, changed files, commands run, failed/skipped checks,
      repair attempts, and residual risks.
- [ ] Prompt children to prefer small, conventional code and deterministic
      tests over broad generated code; for Elixir tasks, include conventional
      Elixir and OTP wiring expectations.
- [x] Add Elixir child-agent prompt guidance for JSON-escaped default argument
      syntax, preferring explicit function clauses when writing full files.
- [x] Prompt coordinator to use only generic coordination patterns and to
      synthesize task-specific workflow structure from the objective,
      workspace, and acceptance contract.
- [x] Add operator control for whole-run RLM wall-clock budget via
      `:max_runtime_ms`, returning structured timeout errors when exhausted.
- [x] Prompt the coordinator that mutating workflows are checked by a generic
      progress gate and must produce concrete source/test evidence, not only
      scaffold commands.

Validation:

- [ ] Snapshot test prompt construction.
- [x] Unit test coordinator schema uses object arrays for workflow nodes and
      edges.
- [x] Unit test object-generation provider failures fall back to JSON text
      proposal generation.
- [x] Unit test whole-run wall-clock budget exhaustion.
- [ ] Scripted LLM test rejects "tests passed" when only scaffold tests ran.
- [ ] Scripted LLM test asks for repair when warnings remain.

## Phase 8: Tooling Additions For Coding Reliability

Deliverables:

- [x] Add a source assertion tool for paths, modules, functions, and forbidden
      scaffold leftovers.
- [x] Add a generic project command adapter with stable output parsing and an
      initial Mix implementation.
- [x] Add a generic runtime smoke helper interface with an initial Elixir/Mix
      implementation that can execute project-local code through guarded
      `mix run -e`.
- [x] Add a changed-file inventory tool that reports paths, hashes, language,
      line counts, and git status.
- [x] Add pre-write patch diagnostics for under-escaped Elixir default
      arguments and refresh written file mtimes so build tools detect rapid
      repair edits reliably.
- [ ] Add a lightweight workflow graph export tool for Mermaid and Livebook
      reports.
- [x] Add ETS-backed development/test persistence for coding artifacts and
      checkpoint events, alongside the optional SQLite persistence adapter.
- [ ] Add optional dependency-aware tool selection for `rg`, `just_bash`,
      `exqlite`, and Codex-backed model routing while keeping defaults safe.

Validation:

- [x] Unit test source assertion tool.
- [x] Unit test changed-file inventory.
- [x] Unit test patch diagnostics for under-escaped Elixir default arguments.
- [ ] Integration test guarded runtime smoke over a generated Mix project.
- [ ] Report export embeds coordinator and child workflow graphs.

## Phase 9: Success Semantics And Scorecards

Deliverables:

- [x] Define `WorkflowScorecard` with objective status, acceptance check
      statuses, command statuses, child statuses, changed files, repair count,
      and residual risks.
- [x] Distinguish statuses:
      `:orchestration_complete`, `:objective_satisfied`,
      `:objective_incomplete`, `:blocked`, and `:failed`.
- [x] Require final RLM answer/report to use the scorecard status, not a loose
      natural-language verdict.
- [x] Persist scorecards, repair history, and checkpoint refs with RLM traces
      for replay and benchmark comparison.
- [ ] Add scorecard reducers across dynamic child workflows.

Validation:

- [x] Unit test status derivation.
- [x] Test child failure prevents `:objective_satisfied`.
- [x] Test skipped required check prevents `:objective_satisfied`.
- [x] Replay strict FieldService fixture and confirm scorecard reports
      `:objective_incomplete`.

## Phase 10: Live Smoke Benchmarks

Deliverables:

- [x] Add a live smoke script for the FieldService generated Mix project task.
- [ ] Add a smaller fixture for a single-file Elixir bug fix.
- [ ] Add a medium fixture for a multi-file library feature with tests.
- [ ] Add benchmark metrics:
      task completion, acceptance pass rate, repair cycles, command count, tool
      count, token estimate, elapsed time, and final code review findings.
- [x] Support cheap model runs through GPT-5.4-mini or Codex-backed equivalent.
- [x] Support replay with scripted doubles so regressions run in normal tests.

Validation:

- [x] Deterministic replay tests pass in `mix test`.
- [x] Live smoke is opt-in and writes artifacts under repo-local `tmp/`.
- [ ] Live smoke report includes workflow graph, child graphs, scorecard, and
      generated project review.
- [x] Live smoke rerun after reliability fixes returns bounded artifacts rather
      than hanging indefinitely.
- [ ] Live smoke still fails the FieldService objective: latest GPT-5.4-mini
      run timed out at the whole-run budget after producing only scaffold-level
      project files and passing scaffold tests.

## Phase 11: Documentation And Operator Controls

Deliverables:

- [ ] Document when to use standard coding agent vs RLM coding agent.
- [ ] Document reliability modes:
      read-only, plan-only, edit-with-review, autonomous-with-gates, and live
      benchmark.
- [ ] Document default budgets and how to override them.
- [ ] Document required controls for generated project tasks.
- [ ] Document how to inspect scorecards, traces, changed files, and repair
      loops.
- [ ] Add examples for operating the RLM agent as a user without manually doing
      the coding work.

Validation:

- [ ] Docs include the FieldService fixture as an example.
- [ ] Docs explain why generic `mix test` is not a sufficient success signal.
- [ ] Docs include recovery guidance for incomplete scorecards.

## Recommended Implementation Order

1. Preserve the strict FieldService smoke as a replayable failure fixture.
2. Implement acceptance contracts and scorecards.
3. Implement verification gates, source assertions, and the initial Mix command
   adapter.
4. Fix child-agent status propagation.
5. Add first-class edit nodes and patch-set artifacts.
6. Add generic coordination patterns without Mix-, Elixir-, or domain-specific
   workflow shortcuts.
7. Add repair controller loops.
8. Re-run the FieldService fixture live with GPT-5.4-mini or Codex-backed
   equivalent.

## Done Criteria

- [x] RLM coding workflows cannot report success when child agents report
      incomplete or failed work.
- [x] RLM coding workflows cannot report success when required acceptance
      checks are skipped.
- [ ] Generated Mix project tasks include meaningful tests, warnings-free
      compilation, and runtime smoke checks by default.
- [x] Mutating RLM workflows produce generic repair needs when they only create
      scaffold files or trivial generated tests.
- [ ] The FieldService generated project fixture passes its acceptance contract
      end to end without Codex manually editing app code.
- [ ] Final reports include objective status, acceptance scorecard, workflow
      graph, child workflow summaries, changed files, verification commands,
      repairs, and residual risks.
- [ ] Deterministic replay tests cover the original strict smoke failure.
