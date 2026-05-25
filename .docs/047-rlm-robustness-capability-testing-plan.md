# RLM Robustness Capability Testing Plan

Status: executed for initial robustness pass; capability gaps captured in
`.docs/048-rlm-robustness-gap-resolution-plan.md`

Date: 2026-05-23

Last reviewed: 2026-05-23 by inspecting the current assistant RLM, coding RLM,
SmokeRunner, field-service reliability fixtures, workbench labels, and git
history around the "repo rlm" wording.

Motivated by:

- `.docs/020-runic-rlm-architecture-explainer.md`
- `.docs/027-rlm-coding-agent-reliability-implementation-plan.md`
- `.docs/031-general-purpose-dynamic-rlm-workflow-generation-implementation-plan.md`
- `.docs/033-assistant-rlm-general-purpose-completion-and-smoke-plan.md`
- `.docs/036-runic-native-dynamic-workflow-generation-refactor-plan.md`
- `.docs/040-assistant-agent-evaluation-and-recommendations.md`
- The observed drift from a general RLM coordinator into a narrower "repo RLM"
  framing in the web workbench.

## Goal

Build a realistic robustness test track for RunicAI's RLM approach:

```text
user intent
  -> goals, requirements, and acceptance contract
  -> generated workflow blueprint with many components, agents, LLM calls, tools, and verification gates
  -> blueprint validation and compilation
  -> execution with observable intermediate outputs
  -> deterministic and LLM-judge assessment
  -> OODA repair through sub-workflows, edits, or modified plans
  -> incremental & final user-facing output when the goal(s) are actually satisfied
```

* Note that we do want stream partial outputs / presentation of progress to the user workbench UI so visible progress is made to the user

This is broader than a ReAct loop and broader than repository Q&A. The RLM
route should become the expert general-purpose task-completion agent for large
context and high-agency work. Coding is one important domain because it gives
us objective compilation, tests, runtime behavior, and file artifacts, but the
architecture must not collapse into "do file operations in a repo".

The testing program should answer:

"Can RunicAI's RLM agent dynamically adapt intent into a workflow, choose useful
components and subagents, produce working artifacts, verify them, repair from
observations, and explain residual gaps across varied DDD-style domains?"

## Agent Positioning

The current product language should distinguish two overlapping but different
agents:

- `assistant`: human-centric general assistant use cases: Q&A, research,
  document synthesis, web/browser/computer use, source-grounded reports, and
  normal conversation. It can use RLM workflow blueprints, but its product
  contract is user-facing assistance.
- `rlm`: expert workflow coordinator for larger task completion. It should turn
  user intent into goals, requirements, sub-workflows, delegated coding or
  analysis agents, verification loops, and final outputs. It should not be
  branded as repo-only. It should be able to do long running tasks with high level goal driven iteration.

The current workbench label `repo rlm` is misleading. It reflects the present
implementation route more than the intended product abstraction.

## Current Implementation Read

### Broad RLM substrate already exists

Useful general substrate is present:

- `RunicAI.Assistant.RLM.Agent` proposes, validates, compiles, runs, scorecards,
  and repairs assistant workflow blueprints.
- `RunicAI.Assistant.RLM.Coordinator` can ask a model for blueprint JSON,
  validate the result, repair validation failures, or fall back to generic
  workflows.
- `RunicAI.Assistant.RLM.WorkflowCompiler` now compiles accepted assistant
  blueprints into Runic workflows and executes through the shared
  `RunicAI.RLM.WorkflowExecutor` path.
- `RunicAI.RLM.ComponentCatalog` exposes generic components such as
  `source_discovery`, `source_splitter`, `source_materializer`, `tabular_parser`,
  `llm_map`, `record_map`, `record_group`, `document_compare`,
  `blueprint_reduce`, `report_composer`, `artifact_writer`,
  `objective_scorecard`, and safe compute components.
- `RunicAI.Assistant.RLM.SmokeRunner` already persists scenario reports,
  run JSON, events, blueprints, graph summaries, scorecards, and expectation
  results.

This is close to the intended RLM shape for document/research/data workflows.
It is not yet strong enough for broad expert task completion.

### Coding RLM is currently repo/workspace specific

The `rlm` terminal/workbench route currently delegates to
`RunicAI.Coding.RLM.Agent`. That agent:

- prepares a `RunicAI.Coding.RLM.CodebaseEnvironment`;
- indexes a workspace manifest, `AGENTS.md`, and source files;
- asks `RunicAI.Coding.RLM.Coordinator` for a coding workflow proposal;
- validates coding-specific `ProposalNode` kinds;
- compiles the proposal with `RunicAI.Coding.RLM.WorkflowCompiler`;
- executes nodes such as `tool`, `command`, `script`, `agent`, `edit`,
  `verification_gate`, `review_gate`, and `workflow_patch`;
- applies `ProgressGate` and optional `RepairLoop`.

That is valuable, but it is not the full RLM product surface. The root type is
`CodebaseEnvironment`, the prompt is explicitly "RLM coding coordinator", the
fallback recipe is `:repo_qa`, and the validators/tools assume local file,
command, patch, and repository workflows.

### Git history around "repo rlm"

History search found only one literal introduction of `repo rlm`:

- `e2c922a fix: streaming interactions` changed the workbench agent option text
  from `rlm` to `repo rlm` and the setup copy from `rlm: coding/RLM scorecard
  workflows` to `repo rlm: coding/RLM scorecard workflows`.

The deeper narrowing predates that label:

- `0f1c7f1 iterate rlm coding agent capabilities w/ app building exercise`
  introduced the coding-agent substrate, `CodebaseEnvironment`, coding RLM
  proposal/validator/compiler modules, field-service reliability fixtures, and
  the `mix runic_ai.coding.smoke` path.
- `cdfd62a dynamic coordinator rlm assistant use case` introduced the
  assistant RLM workflow-blueprint route and general shared RLM components.

So the label is a symptom. The implementation split currently leaves the web
`rlm` option mapped to the coding RLM route while the more general dynamic
workflow route lives under `assistant`.

## Current Limitations To Probe

### RLM route limitations

- Root environment is a local codebase. There is no generic RLM environment
  adapter that can compose repository files, web research, browser observations,
  generated artifacts, memory, external APIs, and child-agent results under one
  objective contract.
- Proposal vocabulary is coding-specific. `ProposalNode` kinds are useful, but
  the coordinator prompt and validator are framed around coding workflows,
  commands, edit nodes, verification gates, and repository evidence.
- Fallback behavior defaults to repo Q&A when mutation is not enabled. This can
  mask dynamic planning failure as a plausible repo analysis route.
- Execution is not fully Runic-native in the coding RLM path. The compiler
  creates a Runic workflow but still executes through an explicit ordered
  interpreter for nodes. That limits Runic scheduler, runner, and graph
  semantics as the authoritative runtime.
- Child-agent contracts exist, but runtime reliability is still unproven across
  diverse, multi-agent build tasks. The field-service fixture preserved one
  failure class, not a broad capability benchmark.
- Acceptance contracts are partially deterministic and partially model-derived.
  We need to measure whether they capture actual domain behavior or only surface
  path/module/source-string proxies.
- Repair loops are bounded but not yet proven as OODA loops for substantive
  architectural corrections, dependency changes, test additions, and
  runtime behavior fixes.
- The route does not yet separate "orchestration complete" from "user goal
  satisfied" strongly enough for every scenario.

### Assistant route limitations

- Assistant RLM has a more general blueprint/component path, but it is currently
  optimized for source-grounded document/data/report workflows, not high-agency
  project execution.
- The smoke matrix is mostly read/report oriented. It tests source cues,
  sections, and provenance, but not buildable software, dependency selection,
  migrations, runtime processes, or tool-heavy OODA repair.
- Scorecard provenance has been a recurring weakness. Useful outputs can remain
  blocked because provenance is missing or shaped differently than the
  scorecard expects.
- Some tooling integration gaps have appeared in manual QA, such as assistant
  `--client codex` normalization and repeated input parsing behavior.
- Dynamic workflow selection can choose the right component family but lose the
  product intent downstream, such as preserving raw records but producing empty
  groups, or comparing documents but asking for source text that was already
  materialized.
- Best repaired output and final chat-visible output can diverge when a run ends
  blocked.

### Shared limitations

- There is no unified objective contract that both assistant and RLM use to
  represent goals, requirements, constraints, acceptance checks, evidence, and
  judge rubrics.
- LLM-as-judge evaluation is not yet a first-class smoke lane with stable
  prompts, grading schemas, calibration examples, and deterministic cross-checks.
- Runtime artifacts are rich, but eval comparison needs clearer scenario-level
  metrics: planning quality, dependency choice, architecture quality,
  implementation completeness, test quality, verification honesty, repair
  effectiveness, and user-facing answer quality.
- Long-running runs need observable progress at the same granularity the web UI
  presents to users: proposal start/finish, node start/finish, child-agent
  activity, verification checks, repair attempts, elapsed time, remaining
  budget, and final blocked/satisfied status.
- Timeout handling must include process cleanup evidence. A lane that returns
  `blocked` while leaving a child `codex exec` process alive is still an
  integration failure.
- Current smokes do not vary enough by domain, project shape, ambiguity, and
  hidden failure mode to expose broad agent brittleness.
- New tool/component surface as described in `.docs/043-hermes-style-agent-tool-surface.md` may not be exposed to these rlm style agents properly

## Testing Strategy

Use coding/project-generation smokes as the first robustness track because they
give objective signals:

- generated files exist;
- dependencies compile;
- tests pass;
- warnings are zero;
- runtime smoke checks can exercise public APIs;
- source assertions can detect scaffold-only or superficial work;
- LLM judge can review architecture and domain fit from artifacts.

Each scenario should have:

- an intent prompt, not a hidden implementation recipe;
- expected goals and non-goals;
- domain requirements;
- dependency-selection expectations;
- required commands;
- deterministic checks;
- LLM-judge rubric;
- mutation/write policy;
- max runtime and max repair attempts;
- artifacts to persist;
- event/progress trail assertions;
- child subprocess cleanup assertions for timeout cases;
- manual smoke checklist for failure analysis.

The benchmark should explicitly compare at least three lanes:

- `standard`: direct tool calling agent loop (with coding capabilities);
- `assistant`: current assistant dynamic workflow route when allowed to use
  tools and write artifacts;
- `rlm`: intended coordinator route with child workflows and verification.
- `browser_tidewave`: browser-driven user-story validation where a Tidewave
  agent uses the RunicAI web workbench as a user would: launch a run, choose an
  agent/mode/profile, approve or deny reviews, inspect graph/events/artifacts,
  and decide whether the visible final state matches the scenario contract.

Do not let any lane pass solely because it says it succeeded.

The `browser_tidewave` lane is not just another execution backend. It tests the
human-facing product loop:

- can a user express the scenario naturally in the workbench composer;
- can the web UI expose enough planning, review, output, and failure evidence;
- can Tidewave drive approvals and follow-up instructions through normal
  browser interactions;
- can the agent recover when a user asks it to inspect a visible failure and
  continue;
- does the final chat-visible answer align with the best runtime artifact and
  scorecard state.

## Scenario Catalog

### Scenario A: Field Service Dispatch Platform

Intent:

> Build an Elixir proof of concept for a field service dispatch platform with
> work orders, technicians, assignment rules, state transitions, and runtime
> supervision. Include tests and a runtime smoke.

Expected architecture:

- Mix project or in-place app slice;
- domain modules for `WorkOrder`, `Technician`, `Dispatch`, and state machine;
- OTP process boundary for active work orders or dispatch sessions;
- `Registry` and `DynamicSupervisor` when processes are used;
- public API for create, assign, start, complete, cancel, and inspect history;
- tests for valid transitions, invalid transitions, assignment constraints,
  and runtime process lookup.

Verification:

- `mix compile --warnings-as-errors`;
- `mix test`;
- runtime smoke creates two technicians, creates three work orders, assigns
  based on skill/region, exercises transitions, and verifies history.

Judge focus:

- domain model is not scaffold-only;
- process supervision is justified and wired;
- tests exercise behavior, not generated defaults;
- API is usable by another module.

Browser/Tidewave user story path:

> As a field operations manager, I want to ask RunicAI in the web workbench to
> prototype dispatch logic for field technicians so I can inspect whether the
> generated system actually handles assignment, lifecycle transitions, runtime
> supervision, and evidence-backed verification.

Browser validation tasks:

- start the scenario from the composer with `rlm` or the current best RLM-like
  agent route;
- use `patch` mode and a local-workbench/coding-capable profile;
- approve low-risk writes only when the review card shows a compatible path;
- inspect the plan/graph tab for discovery, implementation, verification, and
  repair stages;
- inspect artifacts and final answer for the public API and runtime smoke
  result;
- issue one follow-up from the browser if tests fail: "Use the failure shown in
  the workbench to repair the implementation and rerun verification."

### Scenario B: Inventory Allocation And Replenishment

Intent:

> Build an Elixir inventory allocation service for warehouses, SKUs, reservations,
> stock movements, and reorder thresholds. It should support concurrent
> reservation attempts and produce auditable allocation decisions.

Expected architecture:

- pure domain core for stock, reservation, movement, and threshold rules;
- process or ETS-backed runtime only if justified;
- clear error values for insufficient stock, duplicate reservation, and stale
  release;
- property-style or randomized tests for stock never going negative;
- runtime smoke for concurrent reservations.

Dependency expectations:

- prefer standard library and OTP;
- well designed ecto / rdbms schemas and relationships with safe migrations
- may use `Decimal` only if money/precision is introduced;
- avoid introducing database dependencies unless scenario explicitly asks for
  persistence.

Verification:

- compile warnings as errors;
- tests include concurrent reservation smoke;
- source assertions reject a pure CRUD/scaffold-only solution.

Judge focus:

- allocation invariants;
- concurrency boundary;
- audit trail quality;
- dependency restraint.

Browser/Tidewave user story path:

> As an operations lead, I want to ask RunicAI from the browser to build an
> inventory allocation prototype that protects stock invariants under concurrent
> reservations and explains the allocation decisions it made.

Browser validation tasks:

- launch from the workbench without giving exact module names;
- check whether the agent asks for clarification only if persistence or
  database scope is genuinely ambiguous;
- verify the visible plan includes invariant-oriented tests and a runtime smoke;
- inspect command output for concurrent reservation tests;
- ask a browser follow-up to add a failing edge case if the first answer misses
  duplicate reservations or release semantics.

### Scenario C: Subscription Billing Rules Engine

Intent:

> Build an Elixir subscription billing rules engine with plans, metered usage,
> discounts, invoices, proration, and deterministic totals. Include tests for
> edge cases and a CLI or function smoke that prints one invoice.

Expected architecture:

- domain modules for plan, subscription, usage event, invoice, discount, and
  proration;
- uses `Decimal` for currency or clearly stores integer cents;
- no floating-point currency math;
- explicit rounding rules;
- tests for upgrade mid-cycle, usage tiers, coupons, and failed invalid input.

Verification:

- compile warnings as errors;
- tests pass;
- runtime smoke generates an invoice with line items and total;
- source assertion rejects `float` currency math.

Judge focus:

- correctness under edge cases;
- dependency choice;
- readable money model;
- no hand-wavy invoice output.

Browser/Tidewave user story path:

> As a SaaS product owner, I want to ask RunicAI in the web interface for a
> billing rules prototype so I can verify that it models money safely, handles
> proration and usage tiers, and produces a concrete invoice I can review.

Browser validation tasks:

- launch with a natural product prompt and no implementation recipe;
- verify the workbench shows whether `Decimal` or integer cents were chosen and
  why;
- inspect tests for proration, usage tiers, discounts, and invalid input;
- inspect the runtime smoke artifact for itemized invoice output;
- ask a follow-up to remove any floating-point currency math if the judge or
  source checks detect it.

### Scenario D: Clinic Appointment Scheduling

Intent:

> Build an Elixir scheduling service for clinics, providers, appointment slots,
> patient requests, cancellation, waitlists, and conflict detection.

Expected architecture:

- domain modules for provider availability, slot, appointment, waitlist, and
  scheduler;
- clear time representation with `Date`, `Time`, `NaiveDateTime`, or
  `DateTime`;
- deterministic conflict detection;
- waitlist promotion after cancellation;
- tests for overlapping slots, capacity, cancellation, and promotion.

Dependency expectations:

- standard library time types are enough unless timezone handling is explicit;
- no Phoenix or database dependency unless requested.

Verification:

- compile warnings as errors;
- tests pass;
- runtime smoke books two appointments, rejects an overlap, cancels one, and
  promotes a waitlisted request.

Judge focus:

- time modeling;
- conflict rules;
- user-intent translation into domain behavior;
- test relevance.

Browser/Tidewave user story path:

> As a clinic coordinator, I want to ask RunicAI through the web workbench to
> prototype appointment scheduling so I can see conflict detection, cancellation,
> waitlist promotion, and the exact verification evidence before trusting it.

Browser validation tasks:

- launch with `verify` first if the run is seeded into an existing app, then
  continue in `patch` mode;
- inspect whether the plan treats time explicitly instead of as loose strings;
- verify the final answer links or names tests covering overlaps and waitlist
  promotion;
- use the browser to request a repair if the output has only CRUD-style slots
  and no scheduling rules.

### Scenario E: Workflow Orchestration Mini Engine

Intent:

> Build a small Elixir workflow orchestration engine for jobs, dependencies,
> retries, failure policy, and trace events. It should execute a DAG of
> in-memory steps and expose results and events.

Expected architecture:

- graph validation for unknown dependencies and cycles;
- runner that respects dependencies;
- retry policy with bounded attempts;
- trace events for step started/completed/failed/retried;
- tests for dependency ordering, cycle rejection, retries, and failure stop.

Dependency expectations:

- may use `:digraph` or a small local topological sort;
- should not overfit to Runic internals unless the prompt explicitly asks for
  Runic integration.

Verification:

- compile warnings as errors;
- tests pass;
- runtime smoke executes a graph with one retrying step and one dependent step.

Judge focus:

- graph reasoning;
- failure semantics;
- observability;
- code architecture versus quick scripting.

Browser/Tidewave user story path:

> As a platform engineer, I want to ask RunicAI from the browser to build a
> small workflow runner so I can evaluate whether it understands DAG validation,
> retry policy, dependency ordering, and trace events.

Browser validation tasks:

- start from the workbench and require the final answer to summarize the DAG
  contract and verification commands;
- inspect graph/events in the RunicAI UI to see whether the agent's own
  workflow had distinct planning, build, verify, and repair stages;
- inspect generated code for cycle detection and retry trace events;
- ask a follow-up to add a cycle-rejection test if only happy-path execution was
  implemented.

### Scenario F: Event-Sourced Work Order Audit

Intent:

> Build an Elixir event-sourced work order audit module that records events,
> rebuilds state, validates command transitions, and exports an audit report.

Expected architecture:

- event structs or tagged maps;
- command handler that emits events;
- reducer/projection that rebuilds state;
- immutable history;
- tests for replay, invalid commands, and report rendering.

Verification:

- compile warnings as errors;
- tests pass;
- runtime smoke runs commands, replays history, and compares projected state.

Judge focus:

- event-sourcing semantics;
- command/event separation;
- audit report usefulness;
- no mutable state shortcuts masquerading as events.

Browser/Tidewave user story path:

> As an audit/compliance user, I want to ask RunicAI in the web interface to
> build an event-sourced work-order audit module so I can inspect immutable
> event history, replay, invalid command handling, and a rendered audit report.

Browser validation tasks:

- launch with a prompt that emphasizes auditability rather than file layout;
- inspect the final artifact for command/event/reducer separation;
- check the workbench logs for compile/test/runtime smoke evidence;
- ask a follow-up to repair if the implementation mutates a single state map
  without preserving event history.

### Scenario G: Existing App Feature Slice

Intent:

> In a generated Phoenix or plain Mix seed app, add a bounded feature slice with
> domain modules, tests, and one integration smoke. The agent must inspect the
> existing project before planning edits.

Expected architecture:

- source discovery first;
- plan reflects existing project shape;
- edits are narrow and compatible with generated code;
- tests use existing test conventions.

Verification:

- compile warnings as errors;
- tests pass;
- changed-file inventory matches the feature scope;
- judge checks whether edits respect existing conventions.

Judge focus:

- adapting to existing code instead of generating an isolated greenfield answer;
- minimal, coherent edits;
- no unrelated churn.

Browser/Tidewave user story path:

> As a developer working in an existing project, I want to use the RunicAI
> workbench to add one bounded feature slice while watching whether the agent
> inspects the current app, respects conventions, requests safe approvals, and
> reports exactly what changed.

Browser validation tasks:

- open the seeded app in the workbench and launch from the composer without
  passing hidden fixture data;
- confirm the plan starts with source discovery and convention detection;
- approve only the specific write operations needed for the feature;
- inspect changed-file inventory in the artifacts/details panel;
- ask a follow-up to revert or narrow unrelated changes if the diff is too
  broad.

### Scenario H: Field Service Repair Follow-Up

Intent:

> In a broken field-service Mix app, use the browser Workbench to observe a real
> failing smoke, send a same-session repair follow-up, and verify that the
> repaired app satisfies the field-service dispatch contract.

Expected architecture:

- start from a broken but recognizable field-service implementation;
- preserve the field-service domain shape while repairing assignment,
  lifecycle, runtime supervision, and smoke behavior;
- keep repair edits bounded to the workspace and relevant source/tests.

Verification:

- pre-follow-up `mix test` fails with concrete field-service/runtime evidence;
- follow-up stays in the same Workbench session;
- final compile and tests pass;
- deterministic field-service checks pass after repair.

Browser validation tasks:

- launch the broken field-service workspace from the composer;
- capture the failing `mix test` evidence before the follow-up;
- send a repair follow-up using the visible failure evidence;
- inspect plan-stage visibility and final assistant output;
- confirm the final workspace passes deterministic checks.

### Scenario I: Field Service Review Approval

Intent:

> From the browser Workbench, launch a field-service project-generation run with
> approval set to ask, wait for the side-effectful RLM node review card, approve
> it through the normal UI, and verify that the session records the decision and
> resumes.

Expected behavior:

- the run enters a visible `review` state before side-effectful work proceeds;
- the review card includes a stable review id and actionable approve/rewrite/deny
  affordances;
- approving once through the browser records an approved review decision;
- the session resumes to a terminal state after the decision.

Verification:

- browser evidence includes `review_decision_required?`,
  `review_card_captured?`, and `review_decision_captured?`;
- Workbench projection shows one review request with status `approved`;
- plan evidence still shows objective, planning, implementation, verification,
  repair, and review stages;
- deterministic project checks still gate the final row, so an approved session
  that leaves scaffold code unchanged remains a failed robustness run.

Browser validation tasks:

- launch from the composer with approval set to ask;
- wait for the review card rather than treating `running` as enough evidence;
- approve once through the review form;
- inspect the final visible output and review status;
- fail the scenario if deterministic checks do not prove real implementation.

## SmokeRunner Extensions

### New scenario type

Add a coding/project scenario struct separate from assistant document scenarios:

```elixir
%RunicAI.Evals.ProjectScenario{
  id: "rlm_project:field_service_dispatch",
  prompt: "...",
  workspace_factory: :mix_project,
      lanes: [:standard, :assistant, :rlm, :browser_tidewave],
  required_commands: [
    ["mix", "compile", "--warnings-as-errors"],
    ["mix", "test"]
  ],
  runtime_smokes: [
    %{id: "dispatch_flow", command: ["mix", "run", "tmp/smoke_dispatch.exs"]}
  ],
  deterministic_checks: [...],
  judge_rubric: %{},
  budgets: %{max_runtime_ms: 1_800_000, max_repairs: 2}
}
```

Keep fixture and eval definitions as data. Do not add domain-specific workflow
templates for the agent to pick.

### Workspace factory

The runner should create isolated temp workspaces per lane and scenario:

- empty Mix project;
- generated Mix project with default scaffold tests;
- seeded existing app with small conventions;
- intentionally failing/incomplete app for repair scenarios.

Persist:

- objective;
- generated proposal/blueprint;
- validation report;
- command outputs;
- changed files and hashes;
- final artifact tree summary;
- scorecards;
- judge results;
- final user-visible output;
- repair history.

### Deterministic checks

Add reusable check types:

- file exists;
- module exists;
- function exported;
- source contains;
- source does not contain;
- glob contains;
- command passes;
- command output contains;
- warning count zero;
- test count minimum;
- changed-file count range;
- changed-file allowlist/denylist;
- runtime smoke pass;
- dependency allowlist/denylist;
- scaffold residue absent;
- generated project compiles from clean checkout.

These should be shared with existing `RunicAI.Coding.RLM.AcceptanceCheck` where
practical instead of creating another parallel contract language.

### LLM-as-judge lane

Add judge evaluation after deterministic checks. The judge should receive:

- original objective;
- expected goals and non-goals;
- summary of files changed;
- relevant source excerpts;
- test names and command results;
- runtime smoke transcript;
- final agent report;
- deterministic check results.

The judge must return structured JSON:

```json
{
  "overall": "pass|review|fail",
  "scores": {
    "intent_translation": 1,
    "workflow_planning": 1,
    "dependency_selection": 1,
    "architecture_quality": 1,
    "domain_correctness": 1,
    "test_quality": 1,
    "verification_honesty": 1,
    "repair_effectiveness": 1,
    "user_output_quality": 1
  },
  "blocking_failures": [],
  "notable_strengths": [],
  "evidence": []
}
```

Use deterministic checks as hard gates. The judge can upgrade `review` to
`pass` only when all required deterministic gates passed. It can downgrade any
run when code quality, domain fit, or verification honesty is poor.

### Capability metrics

Every run report should include:

- proposal generation attempts;
- validation failures and repairs;
- compiled workflow node count;
- selected component/tool kinds;
- child-agent count and status distribution;
- LLM call count and token estimates where available;
- command count and failed command count;
- repair count and repair cause;
- deterministic pass/review/fail;
- judge pass/review/fail;
- final status shown to the user.

### Browser/Tidewave validation lane

Add a browser validation harness that can drive the same scenario catalog
through the Phoenix workbench with Tidewave. This lane should capture what a
user can actually see and do, not only backend run data.

The lane should record:

- browser session URL;
- selected agent, mode, profile, approval policy, model, and cwd;
- composer prompt and any follow-up prompts;
- visible session state after launch;
- review cards shown, decisions made, and whether policy allowed the approved
  action;
- plan/graph cards shown in the workspace;
- artifact list and selected artifact content;
- inspector events/logs/details used by Tidewave;
- final chat-visible assistant output;
- any browser console errors or LiveView crashes;
- screenshots or structured DOM snapshots at start, review, completion, and
  failure states.

The browser lane should use the same deterministic and judge checks as the
backend lanes, then add UI-specific checks:

- selected agent route matches the intended lane;
- launch form preserves agent/mode/profile/options;
- input/output paths are visible or recoverable from run details;
- review requests are actionable and not contradictory with policy;
- blocked runs show the best available output and repair reason;
- successful runs expose command/test/runtime evidence without requiring
  database inspection;
- follow-up prompts attach to the same session and use prior run context.

### Result matrix

Write matrices to `tmp/rlm_robustness/reports`, for example:

- `rlm-robustness-matrix-standard.md`;
- `rlm-robustness-matrix-assistant.md`;
- `rlm-robustness-matrix-rlm.md`;
- `rlm-robustness-lane-comparison.md`.

Each row should show:

```text
scenario | lane | status | compile | tests | runtime smoke | judge | repairs | main gap
```

For browser matrices, extend each row with:

```text
scenario | browser status | visible final output | reviews | artifacts | follow-up repair | UI gaps
```

## Manual Runtime Smoke Questions

Use live LLM calls to answer questions that static analysis cannot:

- Does the agent infer the right acceptance contract from a natural-language
  prompt without being handed module names and file paths?
- Does it choose dependencies conservatively and explain tradeoffs?
- Does it inspect generated compiler/test failures and repair the actual cause?
- Does it add meaningful tests before relying on `mix test`?
- Does it reject scaffold-only success?
- Does it coordinate child agents with bounded, tailored context instead of
  dumping the full root conversation into each child?
- Does it preserve domain language and constraints across sub-workflows?
- Does it avoid overfitting to FieldService after seeing that fixture?
- Does it produce final user output only when evidence supports completion?
- Does it surface partial success and residual risk honestly?
- Does the workbench show the best available output, graph, reviews, and
  failures for blocked runs?
- Can a Tidewave/browser user complete the scenario without hidden CLI-only
  controls?
- Do review cards, artifacts, graph summaries, and inspector details provide
  enough evidence for a user to decide whether the goal was satisfied?
- Does a browser follow-up continue the same objective context instead of
  starting an unrelated run?

## Initial Execution Report

The first robustness pass added an executable project-scenario smoke harness,
ran broad baseline checks, ran targeted live agent lanes, and performed a real
browser workbench launch.

Generated reports:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-default-20260523-v2.md`
  and `.json`: all seven scenarios across `standard`, `assistant`, `rlm`, and
  `browser_tidewave`. Result: 24 fail, 4 review, 0 pass.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-rlm-field-service-20260523.md`
  and `.json`: live `rlm` Field Service Dispatch probe. Result: fail.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-standard-field-service-20260523.md`
  and `.json`: live `standard` Field Service Dispatch probe. Result: fail.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-live-assistant-field-service-20260523.md`
  and `.json`: live `assistant` Field Service Dispatch probe. Result: fail.
- `tmp/rlm_robustness/reports/browser-workbench-initial-snapshot.txt` and
  `browser-workbench-initial.png`: real browser evidence for the workbench
  landing/composer surface.
- `tmp/rlm_robustness/reports/browser-workbench-session-running-snapshot.txt`,
  `browser-workbench-session-running.png`, and
  `browser-workbench-session-after-wait-snapshot.txt`: real browser evidence
  for a launched `rlm` Field Service Dispatch session.

Concrete findings:

- Live `rlm` orchestration returned `ok` while leaving scaffold code intact and
  failing the field-service acceptance checks.
- The RLM route accepted a read-only file-output workflow for a mutating build
  objective.
- Live `standard` and `assistant` lanes surfaced a Codex model/client
  normalization failure before substantive work began.
- Assistant RLM selected `assistant:generic_report` for a project-generation
  objective.
- The real browser workbench still exposes the user-facing option as
  `repo rlm`.
- Browser automation is not yet first-class: the harness backend-probes
  `RunicAI.Workbench`, while the manual Chrome pass captured real DOM evidence.
- Scenario checks correctly reject scaffold-only greenfield results, but the
  original `existing_app_feature` baseline needed stronger behavior-level
  checks. The later Existing App tightening pass closes this specific baseline
  weakness.

The resolution plan for these gaps is
`.docs/048-rlm-robustness-gap-resolution-plan.md`.

Follow-up remediation reports from the first guardrail implementation pass:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-rlm-guardrails-20260523.md`
  and `.json`: baseline matrix after RLM guardrails.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-rlm-guardrails-live-rlm-field-service-30s-20260523.md`
  and `.json`: bounded live `rlm` Field Service Dispatch probe after
  guardrails. Result: structured timeout instead of repo-QA file output.

Follow-up remediation reports from child-budget and scoring-honesty passes:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-final-rlm-guardrails-20260523.md`
  and `.json`: deterministic matrix after final RLM guardrails.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-after-os-timeout-wrapper-live-rlm-field-service-150s-20260523.md`
  and `.json`: bounded live `rlm` Field Service probe showing accepted workflow
  and node-level evidence, but failing deterministic gates because child patch
  agents timed out before producing source/test artifacts.

Follow-up remediation reports from browser completion-gating passes:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-gated-v2-20260524.md`:
  browser review approval was captured and the run now blocks honestly with
  `objective_incomplete` when the approved edit records no changed files.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-gated-regression-v3-20260524.md`:
  same-session browser repair follow-up passes after repair-log evidence was
  excluded from heuristic objective-term extraction.

Follow-up remediation reports from browser project-generation passes:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-generator-cleanup-v1-20260524.md`:
  review approval now resumes into a successful create/cleanup edit instead of
  failing on missing target files.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-after-generator-cleanup-20260524.md`:
  repair follow-up remained green after generator create/cleanup changes.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-after-lexical-optional-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass through the rendered
  Workbench launch path with deterministic checks and heuristic judge pass.
  This is still seeded-generator success, not proof that the general RLM
  coordinator can synthesize arbitrary project implementations.

Follow-up remediation reports from objective-contract threading:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-threaded-20260524.md`:
  8 pass, 1 fail. The failed `event_sourced_audit` row exposed a work-order
  overlap bug in deterministic intent classification.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-threaded-v2-20260524.md`:
  8 pass, 1 fail. The failed `inventory_allocation` row exposed an
  `auditable` substring bug in audit classification.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-boundary-v3-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass after token-boundary intent
  matching. Inventory and event-sourced audit now generate the expected
  domain-specific files.

Follow-up remediation reports from structured projection checks:

- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-structured-evidence-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass with browser UI checks for
  structured objective-contract requirements and blocked-run next-action
  evidence.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-blocked-evidence-rlm-field-service-20260524.md`:
  tiny-budget live `rlm` Field Service probe fails before active node execution
  as a runtime-budget `error`, preserving the distinction between
  pre-execution exhaustion and active-node blocked evidence.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-contract-ui-nilfix-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass after rendering the
  objective contract and blocked-evidence summaries as first-class Workbench
  UI sections. The rerun also fixed a visible `nil` normalization bug in empty
  blocked-evidence facts.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-live-progress-check-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass with the new
  `live_progress_summary_visible` UI check. Browser evidence now proves the
  Workbench plan tab exposes the live progress panel and persisted event count.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-active-progress-context-v2-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass with the new
  `active_progress_context_visible` UI check. The review-approval row captures
  an early Plan-tab snapshot while the session is waiting for review, including
  visible current-node progress before approval continuation.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-active-progress-review-fix-20260524.md`:
  targeted review-approval regression pass after ensuring the browser runner
  returns from the early Plan-tab snapshot to the Reviews tab before submitting
  approval.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-active-budget-prefinal-review-20260524.md`:
  targeted review-approval browser smoke after real RLM node-budget projection.
  The active Plan snapshot is captured before final completion while the run is
  review-gated, and explicitly shows `NODE implement_project`, `CHILD
  implement_project:edit`, `REMAINING 5.0m`, `MAX 5.0m`, and `CHILD BUDGET
  5.0m`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-active-budget-prefinal-20260524.md`:
  all 9 current `browser_tidewave` scenarios pass after adding strict active
  progress checks for visible child and remaining budget. The review-approval
  row also passes the pre-final active-progress check before approval
  continuation.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-progress-observability-contract-20260524.md`:
  targeted pass for the new `browser_progress_observability` scenario. The
  browser-launched RLM run executes a delayed command, captures pre-final Plan
  evidence with current child and remaining budget, projects a structured
  `progress_ticks` objective contract, and completes with
  `rlm_progress_tick=1..5` final output.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-catalog-followup-capture-20260524.md`:
  current 10-row browser catalog after follow-up capture hardening. Result:
  5 pass, 5 fail. The failures are now capability failures, not capture
  failures: Field Service, Subscription Billing, Workflow Orchestration,
  Existing App Feature, and injected Field Service repair follow-up all block
  with `objective_incomplete` while still showing final output, structured
  contract requirements, live progress, blocked next actions, and follow-up
  state where applicable.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-command-evidence-subscription-20260524.md`:
  targeted Subscription Billing pass after project-generation workflows began
  executing `mix compile --warnings-as-errors`, `mix test`, and a
  profile-specific runtime smoke command as first-class RLM command nodes.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-review-final-wait-20260524.md`:
  targeted review-approval pass after command nodes generated by the seeded
  workflow were marked safe to continue after the implementation review, and
  browser capture waited for the final agent state instead of snapshotting a
  still-running command.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-followup-final-wait-20260524.md`:
  targeted same-session repair follow-up pass after the browser runner's
  process timeout was expanded to cover the initial run plus follow-up run.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-command-evidence-catalog-green-20260524.md`:
  all 10 current `browser_tidewave` scenarios pass through the rendered
  Workbench launch path with deterministic checks, heuristic judge pass,
  visible final output, and in-run compile/test/runtime-smoke command
  evidence. This proves the current seeded browser catalog path, not arbitrary
  open-ended RLM synthesis.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-repair-enabled-field-service-20260524.md`:
  targeted live `rlm` lane pass after patch-mode terminal runs began enabling
  bounded repair by default. The seeded Field Service run did not need repair,
  but it verified that the live terminal path still records compile, test, and
  runtime-smoke command evidence with repair budget available.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-browser-repair-default-loop-20260524.md`:
  targeted browser-launched repair follow-up pass after the terminal/Workbench
  RLM route began carrying bounded repair defaults. The browser evidence
  captured the injected failing `mix test` output, same-session follow-up, and
  final passing deterministic/judge result.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-internal-repair-loop-v4-20260524.md`:
  targeted live `rlm` lane pass for a controlled failing Mix project that
  forces the actual internal `RepairLoop`, not a browser/user follow-up. The
  run starts with failing `mix test` evidence, emits a structured repair plan,
  patches `lib/internal_repair_demo.ex`, reruns verification, records one
  repair attempt, and completes with `RLM Completed ok`. The final event trail
  records the changed implementation file without temporary event-log noise.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-repair-loop-20260524.md`:
  targeted live `rlm` lane pass for a controlled semantic-judge failure. The
  initial `mix test` and verification gate pass, the semantic objective judge
  blocks `transition_history`, the internal `RepairLoop` receives the judge
  requirement/message/repair instruction as structured evidence, patches
  `lib/work_order.ex` and `test/work_order_test.exs`, reruns `mix test`, and
  completes with one repair and `objective_satisfied`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-smoke-repair-loop-20260524.md`:
  targeted live `rlm` lane pass for a controlled runtime-smoke failure. The
  initial unit tests pass, the `dispatch_flow` runtime smoke fails with
  `{:error, :supervision_not_started}`, the internal `RepairLoop` receives the
  named runtime-smoke failure as structured evidence, patches
  `lib/dispatch_runtime.ex` and `test/dispatch_runtime_test.exs`, reruns the
  smoke command, and completes with one repair and `objective_satisfied`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-llm-judge-audit-20260524.md`:
  targeted local fake-LLM judge smoke. The fake judge tries to pass a skipped
  standard lane, the judge records `source=llm`, model, prompt hash, prompt
  excerpt, and response excerpt, and deterministic/lane gating downgrades the
  row to `fail` with `lane execution was skipped`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-smoke-repair-judge-audit-20260524.md`:
  targeted live `rlm` runtime-smoke repair pass after the judge/report status
  change. The row still passes with one repair, preserving the named
  runtime-smoke repair behavior while the matrix now treats explicit judge
  failures as failed rows instead of review rows.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-llm-judge-repair-loop-20260524.md`:
  targeted live `rlm` lane pass for a controlled LLM-style semantic judge
  failure. Initial `mix test` passes, the JSON-text semantic judge blocks
  `transition_history` with prompt/model/hash provenance, the internal
  `RepairLoop` receives that judge failure as structured evidence, patches
  `lib/work_order.ex` and `test/work_order_test.exs`, reruns `mix test`, and
  completes with one repair and `objective_satisfied`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-child-agent-repair-loop-v3-20260524.md`:
  targeted live `rlm` lane pass for a controlled failing Mix project that
  forces internal repair through the real child-agent/tool path. The parent RLM
  captures the failing `mix test`, launches `StandardAgent.patch/3`, the child
  applies an `apply_patch` tool call to `lib/internal_repair_demo.ex`, and the
  parent reruns verification before completing with one repair and
  `objective_satisfied`.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-child-agent-repair-semantic-20260524.md`:
  targeted live `rlm` lane pass after replacing the semantic repair fixture
  executor with the real child-agent/tool repair path. The parent RLM records
  the semantic `transition_history` failure, the child agent applies
  `apply_patch` to `lib/work_order.ex` and `test/work_order_test.exs`, and the
  parent reruns `mix test` plus the semantic judge before completing with one
  repair.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-semantic-child-agent-repair-20260524.md`:
  targeted live `rlm` lane pass after replacing the LLM-judge repair fixture
  executor with the same real child-agent/tool repair path. The repair handoff
  includes LLM judge provenance for `transition_history`, the child agent
  patches WorkOrder transition history, and the parent reruns verification
  before completing with one repair.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-rlm-runtime-child-agent-repair-20260524.md`:
  targeted live `rlm` lane pass after replacing the runtime-smoke repair
  fixture executor with the real child-agent/tool repair path. The parent RLM
  captures the failing `dispatch_flow` runtime smoke, the child agent applies
  `apply_patch` to `lib/dispatch_runtime.ex` and
  `test/dispatch_runtime_test.exs`, and the parent reruns the runtime smoke
  before completing with one repair.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-repeated-scenario-child-repair-pair-20260524.md`:
  targeted live `rlm` lane pass proving the robustness Mix task now preserves
  repeated `--scenario` flags. The report contains both
  `rlm_semantic_repair_loop` and `rlm_llm_judge_repair_loop` rows, each passing
  with one real child-agent repair.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-tightened-baseline-20260524.md`:
  untouched seeded `existing_app_feature` scaffold now fails deterministic
  checks instead of slipping through a weak existing-app baseline.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-tightened-live-rlm-20260524.md`:
  targeted live `rlm` lane pass after tightening `existing_app_feature`
  behavior checks. The run passes compile, test, runtime smoke, deterministic
  checks, heuristic judge, and records event-trail evidence.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-output-excerpts-baseline-20260524.md`
  and
  `tmp/rlm_robustness/reports/rlm-robustness-matrix-existing-app-output-excerpts-live-rlm-20260524.md`:
  targeted baseline/live pair after deterministic command checks began
  persisting bounded `stdout_excerpt` and `stderr_excerpt` fields. The baseline
  still fails on the missing runtime-smoke function, and the live `rlm` row
  still passes.
- `tmp/rlm_robustness/reports/rlm-robustness-matrix-model-client-preflight-existing-app-live-20260524.md`:
  targeted live `rlm` pass after adding shared model/client preflight. The
  terminal JSONL now records `model_client_preflight` before backend execution,
  including provider, effective model, client label, account mode, and resolver
  decision.

## Implementation Plan

### Phase 1: Naming and framing audit

- [x] Audit user-facing `repo rlm` copy and confirm it still appears in the
      real browser workbench agent selector.
- [x] Replace user-facing `repo rlm` copy with wording that preserves the
      broader RLM intent, such as `rlm` or `workflow rlm`.
- [ ] Keep implementation-specific descriptions honest: current route is a
      coding/workspace RLM until the general coordinator route lands.
- [ ] Add workbench help text that distinguishes assistant, standard, and RLM
      by product contract rather than current implementation limitation.

### Phase 2: Shared objective contract

- [ ] Extract a shared objective contract that can represent requirements,
      acceptance checks, evidence requirements, judge rubrics, and residual
      risks for assistant and RLM routes.
- [x] Add a coding-scoped deterministic objective contract for seeded RLM
      project-generation runs.
- [ ] Map existing assistant scorecard requirements and coding
      `AcceptanceContract` checks into this shared contract.
- [ ] Persist the contract and all check results in run artifacts.
- [x] Persist the coding-scoped contract in seeded proposal metadata,
      acceptance-contract node output, patch-set metadata, and browser smoke
      evidence.
- [x] Project the latest coding-scoped contract into Workbench session
      snapshots and browser visible-state evidence.

### Phase 3: Project scenario runner

- [x] Add isolated workspace factories for project-generation smokes.
- [x] Add project scenario data for Scenarios A-G.
- [x] Add a deliberately broken repair-follow-up scenario.
- [x] Run lanes independently and persist comparable reports.
- [x] Ensure generated workspaces are cleaned or stored under `tmp` only.

### Phase 4: Browser/Tidewave validation lane

- [x] Add browser user-story prompts and validation tasks to project scenarios.
- [x] Add a backend workbench probe for the `browser_tidewave` lane.
- [x] Run one real browser workbench launch and persist DOM/screenshot evidence.
- [ ] Add a Tidewave-driven workbench runner that launches scenarios through
      the normal web UI.
- [x] Persist browser session URLs, visible state snapshots, selected artifacts,
      console errors, network failures, plan-stage evidence, follow-up prompts,
      and final chat-visible output for browser-launched runs.
- [x] Persist browser-driven review approval decisions in browser evidence.
- [ ] Persist Tidewave-specific session metadata.
- [x] Add UI-specific pass/review/fail checks for launch state, graph/plan
      visibility, follow-up continuity, review approval, and final output.
- [x] Add UI-specific pass/review/fail checks for review approval, repair
      follow-up, and blocked-run final status in browser-launched sessions.
- [x] Pass the current browser Workbench scenario catalog through normal UI
      launch with deterministic project evidence.
- [x] Add UI-specific pass/review/fail checks for artifacts, structured
      contract requirements, and blocked-run next-action evidence beyond final
      status.
- [x] Render structured objective-contract requirements and blocked-run
      next-action evidence in the Workbench plan/chat UI.
- [x] Add UI-specific pass/fail checks for live-progress summary visibility,
      including persisted event count and latest progress evidence.
- [x] Add UI-specific pass/fail checks for active Plan-tab progress context,
      including current-node evidence before review continuation.
- [x] Add a long-running browser progress scenario that proves pre-final
      command/tool progress without relying on a review gate.
- [x] Pass the 10-row browser Workbench catalog with in-run compile, test, and
      runtime-smoke evidence captured as RLM command-node results.
- [x] Carry bounded RLM repair settings through terminal and robustness live
      lanes so patch-mode RLM runs can enter repair when acceptance evidence
      fails.

### Phase 5: Judge lane

- [x] Add deterministic-gated heuristic judge output for the initial harness.
- [x] Add structured LLM judge prompts and schemas.
- [x] Calibrate judge output on known good, scaffold-only, and partially
      correct fixtures.
- [x] Require deterministic gates before judge pass.
- [x] Persist judge result in JSON and markdown reports.
- [x] Persist judge prompt, result, model, and source excerpts for LLM-judge
      audit.

### Phase 6: RLM coordinator broadening

- [ ] Introduce a general RLM route that is not rooted only in
      `CodebaseEnvironment`.
- [ ] Let the route compose source, web, browser, memory, coding, tool,
      delegation, and artifact environments under one objective contract.
- [ ] Treat coding as one adapter/sub-workflow, not the identity of RLM.
- [ ] Prefer Runic-native execution for generated workflows where possible.

### Phase 7: Live benchmark cadence

- [x] Run the full baseline matrix and targeted live agent probes.
- [ ] Run the full matrix with a live model weekly or after substantial agent
      changes.
- [x] Store reports under `tmp/rlm_robustness` and summarize durable findings
      in `.docs` only when they change product direction.
- [x] Promote repeated completion-overclaim and repair-log contamination
      failure modes into deterministic regression fixtures.
- [x] Promote fresh-generator missing-file and scaffold-cleanup failures into
      deterministic regression fixtures.
- [x] Promote a live internal RLM repair-loop fixture that consumes failing
      command evidence and recovers within the scenario repair budget.
- [x] Promote a live internal RLM repair-loop fixture that consumes semantic
      objective-judge evidence and recovers within the scenario repair budget.
- [x] Promote a live internal RLM repair-loop fixture that consumes named
      runtime-smoke evidence and recovers within the scenario repair budget.
- [x] Promote a live internal RLM repair-loop fixture that consumes LLM-style
      semantic judge evidence with judge provenance and recovers within the
      scenario repair budget.
- [x] Promote a live internal RLM repair-loop fixture that delegates a command
      repair to the real child-agent/tool path and recovers within the scenario
      repair budget.
- [x] Promote live semantic and LLM-judge repair-loop fixtures that delegate
      repairs to the real child-agent/tool path and recover within the scenario
      repair budget.
- [x] Promote the live runtime-smoke repair-loop fixture to delegate repair to
      the real child-agent/tool path and recover within the scenario repair
      budget.
- [x] Add regression coverage and live smoke evidence that repeated
      `--scenario` and `--lane` flags are preserved by the robustness Mix task.
- [ ] Avoid promoting task-specific scenario solutions into templates unless
      they become generic coordination or verification machinery.

## Pass Criteria For The Robustness Track

The RLM route should not be considered broadly capable until it can repeatedly:

- infer a correct objective contract from realistic intent;
- generate an accepted workflow blueprint without a hand-authored task template;
- choose appropriate components, child agents, tools, and verification gates;
- produce working code or artifacts in isolated workspaces;
- pass compile/test/runtime smokes;
- repair from real compiler, test, runtime, or judge observations;
- preserve domain semantics across sub-workflows;
- present the best final answer or partial result clearly to the user;
- distinguish objective satisfaction from orchestration completion.

The immediate target should be a small but hard matrix: Field Service,
Inventory Allocation, Billing Rules, Clinic Scheduling, Workflow Orchestration,
and Event-Sourced Audit across `standard`, `assistant`, and `rlm` lanes.
