# Phase 7 Implementation Plan: Observability, Testing, And Evaluation

Status: draft implementation plan

Date: 2026-04-21

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`
- `.docs/009-phase-5-multi-agent-and-decomposition-workflows-implementation-plan.md`
- `.docs/012-phase-6-stateful-integrated-agent-recipes-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/010-react-vs-rlm-for-workflow-native-agent-composition.md`
- `.docs/013-phase-6-manual-verification-report.md`
- `/home/doops/wrk/libbit/apps/core/lib/core/agents/runic_agent_loop.ex`
- `/home/doops/wrk/libbit/apps/core/lib/core/events/runner_events.ex`
- `/home/doops/wrk/libbit/apps/core/lib/core/workflows/runner_session.ex`

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic workflow API:
  `https://hexdocs.pm/runic/Runic.Workflow.html`
- Official Runic package README:
  `https://hexdocs.pm/runic/readme.html`
- Tidewave lookup keys:
  `Runic`, `Runic.Workflow`, `Runic.Workflow.react_until_satisfied/3`,
  `Runic.Workflow.raw_productions/1`, `Runic.Workflow.results/2`,
  `Runic.Workflow.attach_after_hook/3`, `Runic.accumulator/3`,
  `Runic.map/2`, `Runic.reduce/3`, `Runic.state_of/1`

## Goal

Build the operability layer promised in the roadmap so RunicAI users can
observe, test, replay, and evaluate both recipe tracks without turning the
library into a bespoke runtime first.

Phase 7 is successful when RunicAI has a clear answer to:

"How do I see what happened inside an agent workflow, drive that workflow in a
repeatable way for tests and evaluations, compare candidate recipe changes
against stable metrics, and do all of that without prematurely committing the
library to one OTP topology?"

## Current Starting Point

Phase 6 leaves the library with two strong recipe families and a good typed
substrate:

- external-state turn-processor recipes:
  `RunicAI.Recipes.ChatAgentKernel`,
  `RunicAI.Recipes.ConversationalToolAgent`,
  `RunicAI.Recipes.GuardedOperatorToolAgent`,
  `RunicAI.Recipes.MemoryAwareToolAgent`
- workflow-owned stateful recipes:
  `RunicAI.Recipes.IntegratedAgentKernel`,
  `RunicAI.Recipes.IntegratedChatAgent`,
  `RunicAI.Recipes.IntegratedToolAgent`
- shared contracts:
  `RunicAI.Agent.*`, `RunicAI.Tool.*`, `RunicAI.Control.*`,
  `RunicAI.Wait`, `RunicAI.ReviewRequest`, `RunicAI.ResumeSignal`,
  `RunicAI.ReviewDecision`, `RunicAI.Context.*`, `RunicAI.Decomposition.*`,
  `RunicAI.Integrated.*`
- a basic deterministic test seam:
  `RunicAI.LLM.TestClient`
- provider-backed manual verification patterns through real IEx and Tidewave

What is still missing is the Phase 7 operability layer above that substrate:

- one structured semantic trace model across both recipe families
- a trajectory artifact that can support replay and regression comparison
- deterministic doubles beyond a single fake LLM client
- a harness layer that can drive either recipe family in a repeatable way
  without forcing a GenServer or DynamicSupervisor decision
- evaluation contracts, scoring helpers, and regression metrics that reuse the
  same workflow substrate rather than living in an unrelated framework
- a documented boundary between "process-agnostic operational tooling" and
  "full runtime adapters"

## Why This Phase Matters

Phase 6 answered "how do workflows own agent state and signals?"

Phase 7 needs to answer "how do we inspect, replay, and compare those workflows
as engineering artifacts?"

This is where RunicAI should turn Runic's explicit dataflow into a practical
advantage:

1. execution should be inspectable as typed transitions, not opaque logs
2. stochastic leaves should be captured at effect boundaries, not hand-waved
3. evaluations should be workflow-native folds over datasets, not ad hoc
   benchmark scripts
4. both recipe tracks should become operable through one coherent harness story
5. runtime topology should remain a secondary concern until Phase 8

The category-theoretic and deterministic-dataflow framing matters here.
What we want is not "more logging."
We want a faithful projection from workflow execution into typed events and
repeatable trajectories.
The leaves may still be stochastic, but the composition, control decisions,
join structure, and metric aggregation should remain explicit and inspectable.

In practical terms:

- trace capture should preserve causal structure, not just timestamps
- evaluation metrics should be deterministic folds over case results
- long-running evaluations should surface intermediate score state through
  `Runic.accumulator`, not only a terminal `Runic.reduce`
- process wrappers should be optional shells around the substrate, not the
  substrate itself

## The Core Design Choice: Harnesses First, Runtime Adapters Later

The biggest architectural question in this phase is how much "runtime" to build
now.

There are three broad options:

1. Add traces and evaluation contracts only, and leave all interaction surfaces
   for Phase 8.
   This keeps Phase 7 narrow, but it leaves testing and evaluation awkward
   because users still need bespoke code to drive multi-turn state across both
   recipe tracks.
2. Build supervised GenServer or `Runic.Runner`-backed session processes now.
   This solves interactivity, but it collapses the Phase 7 and Phase 8
   boundaries and makes early operability depend on one runtime topology.
3. Introduce a process-agnostic harness layer now, with in-memory drivers for
   both recipe tracks, and reserve supervised or durable adapters for Phase 8.

Recommendation for Phase 7:

- Define `RunicAI.Harness.*` as an operational wrapper, not as the primary
  public ontology.
- Make the harness contract process-agnostic and in-memory first.
- Provide one driver for external-state turn-processor recipes and one for
  integrated stateful recipes.
- Ensure the harness surface is the seam that future Phase 8 GenServer or
  `Runic.Runner` adapters can wrap.
- Keep trace capture, replay, and evaluation built on top of this harness
  contract rather than binding them directly to a future runtime process model.

This preserves the roadmap's rule:

```text
Runic workflows and typed contracts remain primary
optional ergonomic wrappers remain secondary
```

## Phase 7 Versus Phase 8 Boundary

The clean split should be:

### Phase 7 should own

- semantic trace events and trajectory artifacts
- redaction and capture policy as plain data
- in-memory harness/session contracts for both recipe tracks
- deterministic doubles for LLM, tool, retrieval, review, and wait flows
- replay adapters that substitute recorded effect outputs
- evaluation dataset, scoring, and metric contracts
- workflow-native evaluation recipes and reference reports
- optional `:telemetry` bridging and callback sinks layered on the trace model

### Phase 8 should own

- supervised session servers and `DynamicSupervisor` topology
- durable `Runic.Runner` adapters and persistence store integration
- background job, distributed queue, and scheduler adapters
- remote worker, sandbox, command-execution, and external runtime bridges
- candidate serving, promotion, and side-by-side runtime rollout machinery
- optimization hooks that attach to the trace/eval substrate but do not define it

The key rule is:

```text
Phase 7 defines the control plane and artifacts
Phase 8 defines long-lived process topologies and durable executors
```

## Operability Composition Model

Phase 7 should make observability, replay, and evaluation readable as a chain
of explicit transformations:

```text
input or signal
  -> Harness.Session + Harness.Policy
  -> recipe-specific driver
  -> Workflow transition(s)
  -> Trace.Event[]
  -> Trajectory
  -> Snapshot + outputs/emissions
  -> Evaluation.Result
  -> running metrics accumulator
  -> report / regression comparison
```

The turn-processor path should be explicit:

```text
Harness.Session(snapshot: Agent.State, recipe: turn_processor_recipe) + user input
  -> build or reuse workflow recipe
  -> react until quiescence under policy
  -> new Agent.State + TurnResult + ContinueDecision + Trace.Event[]
  -> Harness.Session'
```

The integrated path should be equally explicit:

```text
Harness.Session(snapshot: RuntimeState, recipe: integrated_recipe) + Integrated.Signal
  -> drive workflow until quiescence under policy
  -> RuntimeState' + Emission[] + Trace.Event[]
  -> Harness.Session'
```

Evaluation should compile down to the same substrate:

```text
Evaluation.Case[]
  -> Runic.map(case_runner)
  -> Evaluation.Result[]
  -> Runic.accumulator(running_metrics)
  -> final regression report
```

That last line matters.
For evaluations we want running scoreboards and partial reports while cases are
still being processed, so the default aggregation primitive should be
`Runic.accumulator`, not a terminal-only `Runic.reduce`.

## Design Principles

### 1. Treat traces as typed values, not log strings

Trace events should be normalized structs with stable kinds, correlation data,
measurements, and redaction-aware payload slots.

### 2. Observe semantic transitions, not just component noise

The important events are turn materialization, LLM request/result, tool
planning/execution, guard decisions, waits, resumes, child execution, and final
emissions.
Low-level component output capture is useful, but it should be normalized into
semantic events.

### 3. Keep the harness layer secondary to the recipes

The harness exists to drive and observe workflows.
It should not become a replacement ontology for `Agent.State`,
`Integrated.Signal`, or any other existing contract family.

### 4. Prefer in-memory, process-agnostic drivers in Phase 7

The first implementation target is deterministic, local, repeatable execution.
GenServers and durable runners belong in Phase 8 unless a narrow helper is
clearly required.

### 5. Capture stochastic boundaries explicitly

Replay needs effect-boundary artifacts.
LLM requests/results, tool call inputs/results, retrieval queries/results, and
review/wait decisions should be recorded as typed trajectory steps.

### 6. Preserve causal identity across parallel branches

Do not rely on wall-clock ordering as the canonical trajectory shape.
Trace events need stable identifiers, parent references, and logical sequence
numbers so replay and diffing do not become timing-dependent.

### 7. Make metrics deterministic folds over trajectories

Latency, cost, tool counts, review counts, and quality scores should be derived
from trajectories and typed outputs through explicit reducers.

### 8. Use one observability vocabulary across both recipe tracks

The turn-processor and integrated lanes may differ in control flow, but the
trace vocabulary for LLM calls, tool calls, waits, reviews, and outcomes should
be shared.

### 9. Keep payload capture configurable and redactable

Traces should support full payload capture for tests and replay, summarized
capture for general observability, and redaction hooks for sensitive content.

### 10. Let evaluations be workflows too

A benchmark or regression run should be expressible as Runic composition, not
as a separate one-off script framework.

## Recommended Contract Layering For Phase 7

### Layer 1: Semantic traces and effect capture

This is the shared observability vocabulary:

- `RunicAI.Trace.Event`
- `RunicAI.Trace.Trajectory`
- `RunicAI.Trace.CapturePolicy`
- `RunicAI.Trace.Sink`

### Layer 2: Process-agnostic harnessing

This is the common control surface for both recipe tracks:

- `RunicAI.Harness.Policy`
- `RunicAI.Harness.Session`
- `RunicAI.Harness.Driver`
- `RunicAI.Harness.TurnProcessor`
- `RunicAI.Harness.Integrated`

### Layer 3: Deterministic testing helpers

These are the fixture and replay seams:

- `RunicAI.Testing.ScriptedLLM`
- `RunicAI.Testing.ScriptedToolExecutor`
- `RunicAI.Testing.ScriptedRetrieval`
- `RunicAI.Testing.TraceAssertions`
- `RunicAI.Testing.Replay`

### Layer 4: Evaluation contracts and reducers

These let users run workflow-native benchmarks:

- `RunicAI.Evaluation.Case`
- `RunicAI.Evaluation.Expectation`
- `RunicAI.Evaluation.Result`
- `RunicAI.Evaluation.Run`
- `RunicAI.Evaluation.Metric`
- `RunicAI.Recipes.EvaluationHarness`

## Recommended Public Contracts

The Phase 7 public surface should stay small but deliberate.

### `RunicAI.Trace.Event`

Canonical semantic event emitted during workflow execution.

Recommended fields:

- `id`
- `trace_id`
- `parent_id`
- `sequence`
- `recipe`
- `component`
- `agent_id`
- `conversation_id`
- `kind`
- `status`
- `input`
- `output`
- `measurements`
- `metadata`
- `observed_at`

Representative `kind` values:

- `:turn_started`
- `:turn_completed`
- `:llm_request`
- `:llm_result`
- `:tool_plan`
- `:tool_call`
- `:tool_result`
- `:guard_decision`
- `:review_requested`
- `:review_resolved`
- `:wait_registered`
- `:resume_applied`
- `:child_assignment`
- `:child_result`
- `:emission`
- `:workflow_quiesced`
- `:workflow_failed`

### `RunicAI.Trace.CapturePolicy`

Controls how much data is captured and how it is transformed.

Recommended fields:

- `mode`
  `:summary | :full | :replay`
- `include_raw_payloads`
- `redactor`
- `include_measurements`
- `include_component_outputs`
- `max_payload_bytes`
- `metadata`

### `RunicAI.Trace.Trajectory`

Replayable artifact for one harness-driven execution.

Recommended fields:

- `id`
- `recipe`
- `session_kind`
  `:turn_processor | :integrated`
- `events`
- `started_at`
- `completed_at`
- `status`
- `final_snapshot`
- `outputs`
- `metadata`

The trajectory should be able to back:

- post-run debugging
- deterministic replay
- regression comparison
- manual verification reports

### `RunicAI.Trace.Sink`

Behaviour for handling emitted trace events.

Recommended callbacks:

- `emit(event, context)`
- `flush(context)`

Reference implementations should include:

- in-memory collector
- logger sink
- `:telemetry` bridge

### `RunicAI.Harness.Policy`

Policy data for driving a session.

Recommended fields:

- `max_reactions`
- `max_turns`
- `max_wall_time_ms`
- `stop_on`
  for example `[:final, :review, :wait, :error]`
- `capture_policy`
- `sink`
- `run_context`
- `async`
- `metadata`

This is where the useful lessons from the libbit wrapper belong, but as plain
data rather than as one application-specific runtime shell.

### `RunicAI.Harness.Session`

Mutable-in-practice but explicit session artifact used by harnesses.

Recommended fields:

- `id`
- `kind`
  `:turn_processor | :integrated`
- `recipe`
- `driver`
- `snapshot`
- `status`
- `outputs`
- `trajectory`
- `measurements`
- `metadata`

The session should remain serializable and process-agnostic.
A Phase 8 GenServer or durable runner should be able to wrap this contract
rather than replace it.

### `RunicAI.Harness.Driver`

Behaviour that separates the common harness surface from recipe-specific
execution details.

Recommended callbacks:

- `new_session(recipe, opts)`
- `submit(session, input_or_signal)`
- `advance(session, policy)`
- `drain(session, policy)`
- `snapshot(session)`
- `outputs(session)`

`TurnProcessor` and `Integrated` drivers should implement this behaviour.

### `RunicAI.Evaluation.Case`

One benchmark or regression case.

Recommended fields:

- `id`
- `input`
- `expected`
- `metadata`
- `tags`

### `RunicAI.Evaluation.Expectation`

Typed scoring or assertion target for a case.

Recommended fields:

- `kind`
- `target`
- `tolerance`
- `weight`
- `metadata`

Representative `kind` values:

- `:exact_text`
- `:contains_text`
- `:tool_called`
- `:tool_not_called`
- `:review_required`
- `:wait_required`
- `:custom`

### `RunicAI.Evaluation.Result`

One case result after running the harness and scoring it.

Recommended fields:

- `case_id`
- `status`
- `session`
- `outputs`
- `trajectory`
- `scores`
- `metrics`
- `failures`
- `metadata`

### `RunicAI.Evaluation.Metric`

Definition of one derived metric or score reducer.

Recommended fields:

- `name`
- `kind`
  `:quality | :latency | :cost | :safety | :custom`
- `extractor`
- `accumulator`
- `metadata`

The accumulator should be the key field here.
We want metrics to be incrementally updated after each case so large eval runs
surface intermediate state and can be inspected while still in flight.

### `RunicAI.Evaluation.Run`

Aggregate artifact for one benchmark batch.

Recommended fields:

- `id`
- `recipe`
- `policy`
- `cases`
- `results`
- `aggregate`
- `started_at`
- `completed_at`
- `metadata`

## Recommended Module And File Layout

```text
lib/runic_ai/
  trace/
    capture_policy.ex
    event.ex
    sink.ex
    sinks/
      in_memory.ex
      logger.ex
      telemetry.ex
    trajectory.ex
  harness/
    driver.ex
    policy.ex
    session.ex
    turn_processor.ex
    integrated.ex
  testing/
    replay.ex
    scripted_llm.ex
    scripted_retrieval.ex
    scripted_tool_executor.ex
    trace_assertions.ex
  evaluation/
    case.ex
    expectation.ex
    metric.ex
    result.ex
    run.ex
  recipes/
    evaluation_harness.ex

test/runic_ai/
  trace/
  harness/
  testing/
  evaluation/
  recipes/evaluation_harness_test.exs
```

## Recommended Substrate Shape

The implementation should use a mix of harness-local orchestration and
Runic-native aggregation:

1. harness drivers perform the session advancement loop
2. instrumentation normalizes workflow reactions into `Trace.Event`
3. trajectories collect those events into one replayable artifact
4. evaluation recipes use `Runic.map` to execute cases
5. evaluation metrics use `Runic.accumulator` to emit running score state
6. final reports are materialized from the latest accumulator state

That split is important.
The harness is responsible for "drive until quiescent under policy."
Runic composition remains responsible for batch evaluation, deterministic fan-in
of results, and metric accumulation.

## Implementation Workstreams

### Workstream 1 - Freeze The Semantic Trace And Capture Contracts

Land the observability vocabulary before building harnesses or evaluators.

- Define `RunicAI.Trace.Event`, `CapturePolicy`, `Trajectory`, and `Sink`.
- Freeze the semantic event taxonomy for turns, tools, guards, waits, reviews,
  child delegation, and final emissions.
- Decide what correlation fields are mandatory:
  `trace_id`, `sequence`, `parent_id`, `recipe`, `component`, and optional
  `agent_id` / `conversation_id`.
- Define redaction and summary rules so trace capture can safely support both
  tests and production-like debugging.
- Decide which component outputs are observed directly and which are emitted as
  normalized semantic events.

### Workstream 2 - Build Trace Capture, Collection, And Replay

Once the contracts are stable, make them operational.

- Add a harness-friendly trace collector that can receive semantic events and
  build a `Trajectory`.
- Add reference sinks:
  in-memory collector, logger sink, and `:telemetry` bridge.
- Capture effect-boundary request/result artifacts for LLM, tool, retrieval,
  and review/wait flows.
- Add replay helpers that turn a recorded trajectory into deterministic test
  doubles for those effect boundaries.
- Ensure replay can be scoped:
  full replay, partial replay of selected boundaries, or mixed replay/live mode.

### Workstream 3 - Expand Deterministic Testing Helpers

Make the library materially easier to test without live providers.

- Keep `RunicAI.LLM.TestClient`, but add scripted multi-step response support.
- Add scripted tool executor and retrieval helpers that can model success,
  failure, retry, review, and wait outcomes.
- Add trace assertions for common expectations:
  tool called, guard triggered, wait registered, review requested, emission
  produced, no extra LLM round, and similar invariants.
- Add test helpers for comparing trajectories while ignoring volatile fields
  like timestamps and generated ids.
- Make the helpers work across both recipe tracks.

### Workstream 4 - Add Process-Agnostic Harnesses For Both Recipe Tracks

This is the critical bridge between "headless workflows" and "operable
sessions."

- Define `Harness.Policy`, `Session`, and `Driver`.
- Implement `Harness.TurnProcessor`:
  it should own the latest `Agent.State`, drive a turn-processor recipe for one
  input, apply continuation policy, and update the session snapshot.
- Implement `Harness.Integrated`:
  it should own the current workflow or runtime snapshot, submit
  `Integrated.Signal`, drive the workflow to quiescence, and collect emissions.
- Make both drivers emit the same trace vocabulary and return the same high-
  level session artifact.
- Keep the implementation in-memory and synchronous by default.

The key deliverable here is not a server.
It is a stable control surface that future Phase 8 runtime adapters can wrap.

### Workstream 5 - Add Workflow-Native Evaluation Patterns And Metrics

Build the evaluation lane on the same substrate rather than outside it.

- Define `Evaluation.Case`, `Expectation`, `Result`, `Metric`, and `Run`.
- Implement a reference evaluation recipe that maps over a case dataset,
  invokes a harness-backed case runner, scores each result, and accumulates
  running metrics.
- Start with metrics that are cheap and defensible:
  completion rate, tool-call rate, review rate, wait rate, latency, usage, and
  cost estimates from captured usage data.
- Add expectation helpers for text matching, tool behavior, and control-flow
  assertions.
- Add baseline comparison support so one recipe or prompt variant can be
  compared against another without coupling that machinery to runtime serving.

### Workstream 6 - Documentation, Manual Verification, And Reference Reports

The phase should land with a clear pattern users can follow.

- Write docs explaining the trace vocabulary and harness choice.
- Write docs explaining when to use a process-agnostic harness versus waiting
  for a Phase 8 runtime adapter.
- Publish at least one evaluation harness example over a real recipe.
- Produce a manual verification report with explicit expectations, real provider
  runs, observed traces, outputs, and findings.
- Ensure the report covers both:
  one turn-processor recipe and one integrated stateful recipe.

## Recommended Implementation Sequence

1. Freeze `RunicAI.Trace.*` contracts first.
2. Land trace capture and replay seams second.
3. Expand deterministic test doubles and trace assertions third.
4. Add `RunicAI.Harness.*` drivers fourth.
5. Build `RunicAI.Evaluation.*` contracts and the reference evaluation recipe
   fifth.
6. Finish with manual verification, docs, and regression examples.

## Recommended Early Decisions

These decisions are worth making before implementation starts so the phase does
not sprawl.

1. Use `RunicAI.Trace.*`, `RunicAI.Harness.*`, `RunicAI.Testing.*`, and
   `RunicAI.Evaluation.*` as the main namespaces.
   This keeps the concerns legible and avoids hiding observability inside
   ad hoc recipe opts.
2. Make semantic trace events the source of truth.
   Logger output and `:telemetry` should be adapters over that model, not
   substitutes for it.
3. Treat the harness as a process-agnostic session wrapper.
   It may later be hosted by a GenServer or `Runic.Runner`, but Phase 7 should
   not require that.
4. Keep one harness control surface across both recipe tracks.
   The drivers can differ internally, but `submit`, `advance`, `drain`,
   `snapshot`, and `outputs` should mean the same thing.
5. Default evaluation aggregation to `Runic.accumulator`.
   Running metrics are more useful than terminal-only batch summaries.
6. Keep replay centered on effect boundaries.
   Replaying raw component outputs without capturing LLM/tool/retrieval
   boundaries will not be sufficient for realistic debugging.
7. Require at least one provider-backed manual verification run for each recipe
   family.
   This phase is specifically about observability and evaluation quality, so
   live manual evidence matters.

## Verification Plan

Phase 7 should be considered complete only when the following verification work
is done.

- [ ] Contract tests for `Trace.Event`, `CapturePolicy`, `Trajectory`,
      `Harness.Policy`, `Harness.Session`, `Evaluation.Case`, `Evaluation.Result`,
      and `Evaluation.Run`.
- [ ] Trace normalization tests covering chat, tool, guard, wait, review,
      resume, decomposition, and integrated emission flows.
- [ ] Redaction tests proving sensitive fields can be summarized or removed
      without breaking trace structure.
- [ ] Replay tests proving recorded trajectories can drive deterministic LLM,
      tool, and retrieval substitutes.
- [ ] Harness tests for turn-processor recipes covering repeated tool rounds,
      stop conditions, and trace capture.
- [ ] Harness tests for integrated recipes covering signal submission,
      quiescence, waits, reviews, resumes, and multi-agent emissions.
- [ ] Evaluation recipe tests covering running metric accumulation and case-level
      scoring.
- [ ] Baseline comparison tests covering a changed prompt or policy candidate.
- [ ] At least one provider-backed manual verification report covering:
      expectations before the run, real inputs, outputs, traces, observed
      behavior, and findings.
- [ ] Documentation updates explaining the Phase 7 versus Phase 8 boundary.

## Out Of Scope For This Phase

Keep these out of Phase 7 so the operability substrate lands coherently.

- No mandatory GenServer, `DynamicSupervisor`, or durable runner topology.
- No required `Runic.Runner` store or persistence integration.
- No distributed queue, scheduler, or background-job adapter.
- No remote command execution or sandbox execution adapter layer.
- No self-optimizing serving runtime or automated promotion pipeline.
- No requirement that all observability flow through `:telemetry` instead of
  typed trace artifacts.
- No attempt to make the harness replace the recipe APIs as the primary way to
  use RunicAI.

## Exit Criteria

Phase 7 is complete when all of the following are true.

- [ ] RunicAI has a stable structured trace model covering the major workflow
      transitions across both recipe tracks.
- [ ] Users can drive either recipe family through a process-agnostic harness
      and collect typed outputs plus trajectories.
- [ ] Replayable trajectories exist for realistic debugging of stochastic
      boundaries.
- [ ] Deterministic testing helpers cover LLM, tool, retrieval, and control
      flows without requiring process-heavy machinery.
- [ ] Workflow-native evaluation recipes can execute datasets and surface
      running regression metrics through `Runic.accumulator`.
- [ ] The docs make the Phase 7 versus Phase 8 boundary obvious:
      harnesses and artifacts now, supervised runtime adapters later.
- [ ] A manual verification report demonstrates that the substrate is useful on
      real provider-backed runs and surfaces actionable findings.
