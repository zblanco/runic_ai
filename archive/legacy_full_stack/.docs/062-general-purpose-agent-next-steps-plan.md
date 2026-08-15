# General-Purpose Agent Next Steps Plan

Status: proposed

Date: 2026-06-26

## Purpose

This document summarizes the recent RunicAI work across `.docs/056` through
`.docs/061`, including the current `LitterBox` extraction, and recommends the
next implementation sequence for turning RunicAI into a more fully integrated
general-purpose agent product. The focus is dynamic workflow generation,
multi-agent coordination, sandbox-backed execution, durable workflow reuse, and
evidence-backed completion.

## Recent Work Summary

### 056: Long-Lived Multi-Agent Sandbox Substrate

`.docs/056-long-lived-multi-agent-session-sandbox-plan.md` established the
sandbox layer needed by larger agent workflows:

- persistent workspace and process-host capability tiers;
- warm pools, sessions, checkpoints, services, proxies, stdin/stdout process
  streams, and future PTY support;
- explicit MCP/model network boundaries where credentials stay on the host;
- dev sandbox versus execution sandbox roles;
- future Runic scheduler affinity, so sequential or parallel promises can run
  inside one warmed allocation rather than paying a host round trip per
  runnable.

The important product takeaway is that sandboxing is not a code-execution helper.
It is the execution substrate for multi-agent workflows, generated-component
proof, artifact promotion, and safe delegation.

### 057: Standard Agent Sandbox Tooling

`.docs/057-standard-agent-sandbox-tooling-plan.md` moved the sandbox substrate
toward an agent-facing tool surface:

- unified sandbox capability visibility across agents, subagents, workflows, and
  Workbench;
- host-to-sandbox upload, sandbox-to-staging download, diff, sync, move, copy,
  and promotion tools;
- durable sandbox object references with session id, path, hash, origin,
  runtime, backend, creator, and promotion state;
- review-gated promotion from sandbox outputs into host patches or generated
  component candidates;
- explicit subagent handoff semantics: session leases, object refs, path scopes,
  runtime policy, budgets, and output schemas.

The plan is still the right bridge between low-level LitterBox execution and
user-visible agent capability.

### 058: Dynamic Workflow Research And Workbench Direction

`.docs/058-dynamic-workflows-research-and-workbench-plan.md` compared Claude's
large-agent dynamic workflow model with RunicAI's better fit:

- Claude-style JavaScript scripts should not become the durable internal model.
  RunicAI should accept high-level workflow proposals, validate them, and compile
  them into native Runic graphs.
- High-level orchestration nodes are not necessarily single Runic components.
  `agent_map`, `workflow_map`, `verify_each`, `pairwise_compare`, and
  `loop_until_done` should lower to native `Runic.map`, `Runic.reduce`, joins,
  rules, FSMs, process managers, child workflow runs, and review gates.
- Pipeline semantics should be the default. Barriers need an explicit
  cross-item dependency.
- Each agent, tool, sandbox operation, verifier, and child workflow should have a
  schema, phase, label, policy, and observable progress.
- Saved workflow definitions should be SQLite-backed. The repo already has
  `managed_workflows`, `workflow_runs`, terminal events, artifacts, scorecards,
  and Workbench state in SQLite, so files should be import/export templates, not
  the canonical runtime library.

The research also identified the workflow patterns RunicAI should ship as
reusable templates: streaming pipeline, fanout with barrier, classify-and-act,
fanout-and-synthesize, adversarial review, tournament/rubric selection,
generate-and-filter, loop-until-done, migration/refactor, deep research, deep
verification, qualitative sorting, memory/rule adherence, root-cause
investigation, triage with quarantine, workflow-invokes-workflow, model/runtime
routing, and generated-component promotion.

### 059 and 060: Real Browser/Vmsan Workflow Hardening

`.docs/059-rayops-vmsan-workflow-rlm-integration-report.md` recorded a browser
integration failure where the selected Workflow RLM + Vmsan path looked running
but did not progress. The root causes were general:

- Workbench accepted `approve=always`, while terminal parsing rejected it.
- Background startup failures were not persisted, so sessions could appear
  running forever.
- launch metadata such as approval, mode, sandbox backend, and runtime was lost
  in session state.
- Vmsan selection was accepted in hidden payloads but not clearly visible in the
  form.
- selected sandbox did not produce visible execution proof.
- nested review gates blocked child work.
- empty-workspace creation tasks could stop after read-only inspection.

`.docs/060-rlm-vmsan-ooda-follow-up.md` applied and validated broad fixes:

- shared approve-all parsing and launch-failure persistence;
- persisted launch metadata and session-composer hydration;
- visible Vmsan selection;
- empty-workspace instructions for creation tasks;
- parent review-decider propagation into child agents;
- child review auto-resume;
- approve-all objective auto-resume caps;
- focused tests plus browser sessions proving files could be created after
  recovery.

The residual issues from 060 became the active 061 OODA loop.

### 061: Sandbox-Backed Dynamic Workflow OODA

`.docs/061-sandbox-backed-dynamic-workflow-ooda-goal.md` converted the browser
hardening work into a repeatable product loop. The current ledger has progressed
through sandbox proof projection, child no-op repair, malformed patch repair,
progress clarity, Workbench performance, a general dynamic workflow eval matrix,
HITL review capture, completion proof, terminal-wait handling, repair
convergence, deterministic acceptance feedback, delivery-root grounding,
DevTools/proof cleanup, warning-clean command evidence, browser evidence
normalization, fixture overfit cleanup, and command-first repair.

Current state from Slice 18:

- the broad browser `general_dynamic_workflow` matrix reached 4/5 passing rows;
- `empty_app_creation`, `existing_app_feature`, `research_report`, and
  `denied_tool_review` passed in the latest broad validation;
- `refactor_existing_module` passed in focused validation but failed in the
  latest broad run before implementation because generated workflow proposal
  repair produced invalid JSON;
- the remaining 061 blocker is proposal-generation and proposal-repair
  robustness, followed by a final full-matrix audit.

This matters because the latest failure is now above the tool-execution layer. It
is not a sandbox, patch, browser capture, or deterministic-check problem. The
next capability gap is making dynamic workflow proposals durable, repairable, and
valid before execution starts.

### LitterBox Extraction

The current checkout shows `runic_sandbox` has been extracted out of the
RunicAI repo into the sibling `litter_box` package:

- `mix.exs` depends on `{:litter_box, path: "../litter_box"}`;
- `RunicAI.Sandbox` is now a backwards-compatible facade delegating to
  `LitterBox`;
- RunicAI-specific code now references `LitterBox` types in coding tools,
  Workbench health, generated-component proof, sandbox session registry, and
  live-lane validation;
- `mix litter_box.validate_standalone` exists to smoke the extraction-facing API
  from a tiny separate Mix project.

This is the right boundary. `LitterBox` should own backend-neutral sandbox
contracts and execution. RunicAI should own intent, workflow planning, policy,
review, persistence, UI, scorecards, generated components, and promotion.

## Strategic Recommendation

The next highest-value work is not adding another isolated tool. It is connecting
the pieces into one product loop:

```text
user intent
  -> classify task shape and capability needs
  -> propose typed workflow blueprint
  -> validate and repair the blueprint before execution
  -> compile to native Runic graph and child workflow runs
  -> execute agents/tools/LitterBox sandboxes under shared policy
  -> show parent/child progress, reviews, artifacts, and proof in Workbench
  -> complete only with scorecard-backed evidence or block with a concrete reason
  -> save proven workflows/components for reuse
```

The implementation sequence below is ordered by integrated user capability and
risk. Each slice should keep the 061 browser-matrix discipline: focused tests
first, then a browser-backed evidence run.

## Recommended Implementation Plan

### Slice 1: Finish 061 Proposal Robustness Gate

User capability unlocked: a user can launch the general dynamic workflow matrix
without tasks getting stranded before execution by malformed proposal JSON.

Work:

- Add proposal-generation repair that is schema-first, not prose-first. When the
  coordinator emits invalid JSON or a structurally invalid proposal, capture the
  parse/validation diagnostics and retry with a minimal correction prompt that
  must return only the proposal object.
- Separate proposal repair from implementation repair in events and Workbench
  projection: `proposal_repair_started`, `proposal_repair_completed`,
  diagnostics, attempt count, and final validity.
- Persist the accepted objective contract before proposal repair, so failed
  proposal generation still leaves a user-visible contract and blocked reason.
- Add a fallback only for shape, not for domain. It is acceptable to use a generic
  typed skeleton such as `inspect -> implement -> verify` when the model omits
  structure; it is not acceptable to hardcode RayOps, support-ticket, refactor,
  or research behavior.
- Rerun the full `general_dynamic_workflow` browser matrix. 061 should close only
  when all rows pass or the remaining failures are terminal blocked states with
  explicit user-visible evidence.

Validation gate:

- focused proposal parser/repair tests;
- `mix compile --warnings-as-errors`;
- full browser matrix report showing valid proposal repair and no pre-execution
  JSON-stranding.

### Slice 2: Complete And Validate The LitterBox Boundary

User capability unlocked: RunicAI can rely on a stable sandbox package while
Workbench and agent workflows still expose one coherent sandbox capability
surface.

Work:

- Run and fix the extraction smoke: `mix litter_box.validate_standalone`.
- Run focused RunicAI sandbox tests that prove the facade, tools, generated
  component proof, Workbench health, and live-lane code still agree on LitterBox
  types.
- Update stale docs and UI copy from `runic_sandbox` to `LitterBox` where the
  package boundary matters, while leaving historical docs unchanged when they are
  clearly retrospective.
- Keep new RunicAI code using `LitterBox` directly unless it is intentionally
  preserving backward compatibility through `RunicAI.Sandbox`.

Validation gate:

- standalone LitterBox smoke passes;
- RunicAI focused sandbox/proof/workbench tests pass;
- `git diff --check` and compile pass.

### Slice 3: Make Workflow Definitions First-Class In SQLite

User capability unlocked: users can save, inspect, rerun, version, and invoke
generated workflows instead of treating every dynamic workflow as an ephemeral
session.

Work:

- Evolve `managed_workflows` rather than adding a disconnected store unless a
  schema migration proves the existing table cannot carry the new fields.
- Add first-class blueprint fields around the existing durable definition:
  `definition_kind: :blueprint`, blueprint JSON, input/output schema JSON, policy
  JSON, compiled hash, optional compiled artifact, version lineage, source, tags,
  examples, and last proof metadata.
- Add `RunicAI.WorkflowDefinitions` or extend
  `RunicAI.Persistence.ManagedWorkflows` with explicit APIs:
  `validate_blueprint/1`, `create_definition/2`, `revise_definition/3`,
  `compile_definition/2`, `create_run/3`, `archive/2`, and `search/2`.
- Store generated workflow proposals from successful 061-style runs as draft
  workflow definitions when the user chooses save/promote.
- Render a Workbench workflow library: draft/active/failed definitions, version,
  last run, last proof, expected inputs, policy summary, and launch button.

Validation gate:

- persistence tests for definition create/update/version/run linkage;
- Workbench tests for workflow library display and launch;
- one saved dynamic workflow reruns from SQLite and links child runs/artifacts
  back to the definition.

### Slice 4: Implement The High-Level Blueprint Compiler

User capability unlocked: RunicAI can plan expressive workflows at a high level
while still giving Runic control over scheduling, retries, placement, and
observability.

Work:

- Promote the 058 blueprint model into code, reusing existing
  `WorkflowProposal`, assistant `WorkflowBlueprint`, `Plan`, and `PlanNode`
  pieces where they already fit.
- Define a small initial node catalog:
  `agent_task`, `agent_map`, `workflow_task`, `workflow_map`, `tool_call`,
  `sandbox_exec`, `transform`, `reduce`, `join`, `condition`, `review_gate`, and
  `objective_scorecard`.
- Compile collection nodes into native Runic graph shapes. `agent_map` and
  `workflow_map` must not become opaque steps that call `Enum.map` internally.
- Reject unjustified barriers and missing schemas at validation time.
- Preserve phase labels, agent labels, policy, model route, sandbox route,
  expected artifacts, and output schema metadata on compiled nodes.

Validation gate:

- compiler unit tests proving high-level map/reduce/join lowering;
- graph diagnostics for invalid barriers and missing schemas;
- a browser workflow graph preview that distinguishes pipeline, parallel, and
  barrier edges.

### Slice 5: Add Parent/Child Workflow Orchestration

User capability unlocked: a top-level agent can coordinate reusable workflows,
not just one-off child agents.

Work:

- Implement `workflow_task` as a child `workflow_run` linked to a stored workflow
  definition with scoped inputs, budgets, tool policies, sandbox leases, and
  output schema gates.
- Implement `workflow_map` for running a saved workflow per item with bounded
  concurrency and resumable child run state.
- Project parent/child run trees into Workbench: active child, queued child,
  failed child, completed child, retry/restart action, and child artifacts.
- Allow restarting one failed child without rerunning completed siblings.

Validation gate:

- persistence tests for parent/child run linkage;
- compiler tests for `workflow_task` and `workflow_map`;
- browser session showing parent workflow progress, child run tree, and a child
  restart or blocked state.

### Slice 6: Build LitterBox-Backed Sandbox Objects And Promotion

User capability unlocked: agents can safely create artifacts in sandboxes,
inspect them, compare them, and promote them into host patches or reusable
components under review.

Work:

- Implement the 057 object manifest: file/directory/checkpoint/process-log/
  service-preview refs with hash, size, origin, session id, backend, runtime,
  creator, and promotion state.
- Add `sandbox_upload`, `sandbox_download`, `sandbox_diff`, and
  `promote_sandbox_changes` as policy-aware tools over LitterBox sessions.
- Store manifests in run artifacts and attach object refs to child-agent outputs,
  workflow outputs, and completion proof.
- Add Workbench object browser and review lane for staged artifacts, diffs,
  promotion target, and proof status.
- Connect generated-component promotion so proven sandbox outputs can become
  catalog entries rather than disappearing at run end.

Validation gate:

- package/tool tests for manifests, staging, diffs, and promotion payloads;
- browser run that uploads input, produces sandbox output, stages it, shows a
  diff, and promotes a reviewed host patch or component candidate.

### Slice 7: Ship Built-In General Workflow Templates

User capability unlocked: users can ask for common high-level outcomes and get a
structured, inspectable workflow rather than a single conversational loop.

Start with five templates:

- `deep_research`: angles, source gathering, claim extraction, adversarial
  verification, cited synthesis.
- `coding_change`: inspect, implement, command-first repair, scorecard proof,
  patch/artifact summary.
- `migration_refactor`: inventory, shard, builder children, verifier children,
  merge/promotion gate, full verification.
- `adversarial_review`: dimension finders, finding schema, verifier agents,
  verdict gate, confirmed report.
- `generated_component_promotion`: intent, sandbox build, proof, review gate,
  catalog promotion, future reuse hint.

Work:

- Store templates as SQLite workflow definitions with source `:system`.
- Let the intent classifier route to a template and fill structured args instead
  of asking the model to invent every graph from scratch.
- Keep the model free to propose new graphs, but prefer template adaptation when
  the intent clearly matches a built-in pattern.

Validation gate:

- one browser-backed eval per template;
- Workbench shows template source, adapted args, compiled graph, and proof.

### Slice 8: Generalize Completion Proof And Scorecards Beyond Coding

User capability unlocked: RunicAI can finish research, review, migration, and
component-promotion workflows with the same trust model currently being hardened
for coding.

Work:

- Extract the completion proof concept from Workbench/Coding RLM into a shared
  proof contract usable by all workflow definitions.
- Support mode-specific proof categories: citations, claim verdicts, changed
  files, command results, sandbox objects, denied reviews, promoted components,
  child workflow outputs, and human approvals.
- Make final output selection proof-aware everywhere: answer episodes can win,
  but raw command output must not outrank a satisfied scorecard or verified
  artifact summary.
- Add missing-proof UI that tells the user what evidence is absent and whether
  the session is still running, blocked, failed, or complete.

Validation gate:

- Workbench tests for research, review, coding, and denied-review proof shapes;
- browser eval where a research workflow cannot complete without cited artifact
  proof and a coding workflow cannot complete without changed-file/check proof.

### Slice 9: Close The Reuse Flywheel

User capability unlocked: RunicAI becomes better over time by reusing proven
workflows and components before generating new ones.

Work:

- During planning, query saved workflow definitions and generated component
  catalog entries before asking the model to generate a new plan.
- Record reuse decisions and misses: why a workflow/component was used, adapted,
  rejected, or newly generated.
- Promote successful one-off workflows into draft definitions with the exact
  objective, graph, schemas, policy, artifacts, scorecard, and validation
  evidence.
- Add Workbench actions: save as workflow, promote component, fork workflow,
  archive weak workflow, compare versions, rerun latest proof.

Validation gate:

- a second run of a previously solved task uses the saved workflow definition or
  explains why it did not;
- Workbench displays reuse provenance and last-proof status.

## Recommended Near-Term Order

1. Finish 061 with proposal JSON repair and a final general matrix audit.
2. Validate and document the LitterBox extraction boundary.
3. Promote dynamic workflow definitions into durable SQLite-managed objects.
4. Compile high-level blueprints into native Runic graph structure.
5. Add `workflow_task` / `workflow_map` parent-child orchestration.
6. Add sandbox object manifests, transfer, diff, and promotion.
7. Ship built-in templates for deep research, coding change, migration/refactor,
   adversarial review, and generated-component promotion.
8. Generalize completion proof and scorecards across workflow modes.
9. Close the workflow/component reuse flywheel.

This order keeps the system honest. It first stabilizes the active dynamic
workflow path, then makes successful workflows durable, then expands into richer
multi-agent coordination and sandbox-backed artifact promotion.

## Completion Criteria For This Plan

The next phase should be considered complete when a user can:

- launch a task from Workbench using natural intent;
- see the selected workflow template or generated blueprint before execution;
- approve or reject the plan with visible phases, child agents, policy, budgets,
  sandbox profile, runtimes, and mutation gates;
- watch parent and child workflow progress without reading raw event payloads;
- inspect LitterBox sandbox proof, objects, diffs, command output, reviews, and
  completion proof;
- receive a final answer only when the objective scorecard is satisfied, or a
  blocked state with precise unmet checks;
- save a successful workflow or component for future reuse;
- rerun the saved workflow and get linked run/proof history.
