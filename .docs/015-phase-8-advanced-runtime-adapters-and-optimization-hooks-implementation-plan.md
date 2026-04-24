# Phase 8 Implementation Plan: Advanced Runtime Adapters And Optimization Hooks

Status: draft implementation plan

Date: 2026-04-22

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/003-phase-0-contracts-and-core-substrate-implementation-plan.md`
- `.docs/004-phase-1-conversational-loop-kernel-implementation-plan.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`
- `.docs/009-phase-5-multi-agent-and-decomposition-workflows-implementation-plan.md`
- `.docs/012-phase-6-stateful-integrated-agent-recipes-implementation-plan.md`
- `.docs/014-phase-7-observability-testing-and-evaluation-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/010-react-vs-rlm-for-workflow-native-agent-composition.md`
- `.docs/013-phase-6-manual-verification-report.md`
- `/home/doops/wrk/libbit/apps/core/lib/core/agents/runic_agent_loop.ex`
- `/home/doops/wrk/libbit/apps/core/lib/core/events/runner_events.ex`
- `/home/doops/wrk/libbit/apps/core/lib/core/workflows/runner_session.ex`
- [lib/runic_ai/harness/turn_processor.ex](/home/doops/wrk/runic_ai/lib/runic_ai/harness/turn_processor.ex:1)
- [lib/runic_ai/harness/integrated.ex](/home/doops/wrk/runic_ai/lib/runic_ai/harness/integrated.ex:1)
- [lib/runic_ai/trace/builder.ex](/home/doops/wrk/runic_ai/lib/runic_ai/trace/builder.ex:1)
- [lib/runic_ai/recipes/evaluation_harness.ex](/home/doops/wrk/runic_ai/lib/runic_ai/recipes/evaluation_harness.ex:1)

## Runic References

- Local quick reference: [AGENTS.md](/home/doops/wrk/runic_ai/AGENTS.md)
- Official Runic HexDocs overview:
  `https://hexdocs.pm/runic/Runic.html`
- Official Runic runner docs:
  `Runic.Runner`, `Runic.Runner.start_workflow/4`,
  `Runic.Runner.run/4`, `Runic.Runner.get_results/3`,
  `Runic.Runner.Store.ETS`
- Official Runic process orchestration docs:
  `Runic.Workflow.ProcessManager`
- Tidewave lookup keys:
  `Runic.Runner`, `Runic.Runner.start_workflow/4`,
  `Runic.Runner.run/4`, `Runic.Runner.get_results/3`,
  `Runic.Runner.Store.ETS`, `Runic.Workflow.ProcessManager`,
  `Runic.state_of/1`

## Goal

Build the runtime layer promised in the roadmap so RunicAI workflows can be
supervised, addressed, persisted, resumed, scheduled, adapted to real
execution environments, and experimentally versioned without turning process
topology into the library's primary abstraction.

Phase 8 is successful when RunicAI has a clear answer to:

"How do I run these recipes as long-lived OTP services, send them inputs,
observe outputs incrementally, persist or resume them with `Runic.Runner`,
adapt tools to real runtime environments, and attach candidate or optimization
machinery without making the runtime shell more important than the typed
workflow contracts?"

## Current Starting Point

Phase 7 leaves the library in a strong place:

- two stabilized recipe families:
  `RunicAI.Recipes.ChatAgentKernel`,
  `RunicAI.Recipes.ConversationalToolAgent`,
  `RunicAI.Recipes.GuardedOperatorToolAgent`,
  `RunicAI.Recipes.MemoryAwareToolAgent`,
  `RunicAI.Recipes.IntegratedAgentKernel`,
  `RunicAI.Recipes.IntegratedChatAgent`,
  `RunicAI.Recipes.IntegratedToolAgent`
- one coherent operability layer:
  `RunicAI.Trace.*`, `RunicAI.Harness.*`, `RunicAI.Testing.*`,
  `RunicAI.Evaluation.*`
- a canonical headless session artifact:
  `RunicAI.Harness.Session`
- a canonical execution policy carrier:
  `RunicAI.Harness.Policy`
- typed pause and resume contracts:
  `RunicAI.Wait`, `RunicAI.ReviewRequest`,
  `RunicAI.ResumeSignal`, `RunicAI.ReviewDecision`
- replayable trajectories and accumulator-backed evaluations

What is still missing is the production-facing runtime layer above that
substrate:

- supervised session processes and discovery
- a public way to operate agents interactively through OTP instead of only
  headless harness calls
- `Runic.Runner`-backed backends for durable execution and store integration
- scheduler adapters for `Wait.until` and wake delivery
- runtime execution adapters behind the existing tool contract
- long-horizon context persistence and selective restore/expansion
- candidate selection and version hooks for serving and comparison
- optimization hooks that consume traces and evaluation runs without mutating
  the runtime semantics

## Why This Phase Matters

Phase 7 answered "how do I inspect, replay, test, and evaluate the workflows?"

Phase 8 needs to answer "how do I actually operate those workflows as
long-lived services?"

This phase is where the deterministic dataflow story has to survive contact
with OTP:

1. workflows still define the state transition semantics
2. the runtime shell only manages time, addressing, persistence, delivery, and
   supervision
3. headless harness execution and supervised runtime execution should converge
   on the same `Harness.Session` snapshots and `Trace.Trajectory` artifacts
4. external execution environments should remain tool adapters, not secret
   control paths
5. candidate selection and optimization should observe and compare workflows,
   not rewrite them from inside the serving loop

In categorical terms, the workflow remains the typed transition relation.
The GenServer or Runner layer is only the carrier of repeated interaction over
time.
If Phase 8 is done correctly, the runtime is an interpreter around the same
typed morphisms that Phase 1 through Phase 7 already established, not a second
agent system with different rules.

## The Core Design Choice: Harness-Centric Runtime Adapters

The central architectural question in Phase 8 is where the public runtime
surface should live.

There are three broad options:

1. Write one bespoke GenServer per recipe family.
   This gives immediate ergonomics, but it duplicates transition logic,
   fragments behavior across process modules, and weakens the value of the
   shared Phase 7 harness contracts.
2. Expose `Runic.Runner` directly as the main public runtime API.
   This uses a strong existing primitive, but it leaks runner ids, store
   concerns, workflow lifecycle details, and recipe-track differences straight
   into user space.
3. Keep `RunicAI.Harness.*` as the primary operational semantics, and build
   Phase 8 runtime adapters on top of it.
   This means session servers, supervisors, runner backends, and schedulers all
   preserve one canonical snapshot and trace story.

Recommendation for Phase 8:

- Keep `RunicAI.Harness.Session` as the canonical session snapshot artifact.
- Keep `RunicAI.Harness.Policy` as the canonical operational policy artifact.
- Add `RunicAI.Runtime.*` as the OTP and `Runic.Runner` wrapper layer.
- Make `RunicAI.Runtime.SessionServer` generic over recipe and backend rather
  than recipe-specific.
- Make backends responsible for how a given recipe track maps onto
  in-memory execution or `Runic.Runner`, while the public process surface stays
  stable.

This preserves the architectural stack:

```text
typed workflow contracts
  -> Phase 7 harness semantics
  -> Phase 8 runtime process adapters
```

Not:

```text
GenServer shell
  -> bespoke hidden loop logic
  -> workflows as implementation detail
```

## Why Two Runner Strategies Are Required

Phase 8 should not pretend the two recipe families map to `Runic.Runner` in
the same way.

### External-state turn-processor recipes

For:

- `ChatAgentKernel`
- `ConversationalToolAgent`
- `GuardedOperatorToolAgent`
- `MemoryAwareToolAgent`

the durable continuity lives in `Harness.Session.snapshot`, which is typically
an `Agent.State`.

That means a Runner-backed backend for this family should use `Runic.Runner`
as managed execution infrastructure for each advancement, but not as the
authoritative long-lived state container.

The canonical shape is:

```text
SessionServer state
  -> Harness.Session(snapshot: Agent.State)
  -> backend builds workflow for one advancement
  -> Runner executes that workflow
  -> backend projects results back into Harness.Session'
```

### Integrated workflow-owned recipes

For:

- `IntegratedAgentKernel`
- `IntegratedChatAgent`
- `IntegratedToolAgent`

the durable continuity already lives inside the workflow as
`RunicAI.Integrated.RuntimeState`.

That means a Runner-backed backend for this family should map more directly to
one long-lived runner workflow id per runtime session.

The canonical shape is:

```text
SessionServer state
  -> runner_name + workflow_id
  -> Runner.start_workflow once
  -> Runner.run for each signal
  -> backend projects latest RuntimeState/emissions into Harness.Session'
```

This distinction is essential.
If we blur it, we either force external-state recipes into a fake long-lived
workflow model they do not need, or we fail to exploit the natural fit between
integrated recipes and `Runic.Runner`.

## Phase 8 Versus Phase 7 And Phase 9 Boundary

The clean split should be:

### Phase 7 owns

- traces, replay, harness sessions, deterministic doubles, and evaluations
- process-agnostic control-plane artifacts
- headless execution surfaces for both recipe tracks

### Phase 8 owns

- GenServers and `DynamicSupervisor` topology
- `Runic.Runner` backends and store ownership patterns
- scheduler adapters for wait and wake handling
- runtime-facing execution adapters behind the tool contract
- long-horizon context persistence and restore/expansion hooks
- candidate selection and version routing hooks
- optimization hooks layered on top of trace and evaluation artifacts

### Phase 9 owns

- RLM execution mode
- prompt-as-environment and recursive long-context execution
- recursive execution combinators and externalized context environments

The important nuance is that Phase 8 may add long-horizon context persistence,
lineage, and selective restore, but it should not jump ahead into Phase 9's
RLM-style execution mode.

## Runtime Composition Model

Phase 8 should make runtime operation readable as a composition of adapters
around the existing harness semantics.

### In-memory supervised path

```text
Runtime.SessionSpec
  -> Runtime.SessionServer
  -> Runtime.Backends.InMemory
  -> Harness.Driver
  -> Workflow transition(s)
  -> Harness.Session'
  -> Trace.Event[] / outputs / subscriber notifications
```

### Runner-backed external-state path

```text
Runtime.SessionSpec(recipe: turn_processor_recipe)
  -> Runtime.SessionServer
  -> Runtime.Backends.RunnerTurnProcessor
  -> Harness.Session(snapshot: Agent.State)
  -> Runner.start_workflow / Runner.run / Runner.get_results
  -> projected Harness.Session'
  -> Trace.Event[] / outputs / subscriber notifications
```

### Runner-backed integrated path

```text
Runtime.SessionSpec(recipe: integrated_recipe)
  -> Runtime.SessionServer
  -> Runtime.Backends.RunnerIntegrated
  -> runner workflow_id
  -> Runner.start_workflow once
  -> Runner.run(signal)
  -> projected Harness.Session(snapshot: RuntimeState)'
  -> Trace.Event[] / emissions / subscriber notifications
```

### Wait scheduling path

```text
Wait.until / resume_key
  -> Runtime.Scheduler
  -> wake submission at the right time
  -> SessionServer submit
  -> backend advance
```

### Candidate and optimization path

```text
Runtime.SessionSpec + Candidate.SelectionPolicy
  -> chosen Candidate.Spec
  -> session execution
  -> Trace.Trajectory + Evaluation.Run
  -> Optimization.Hook
  -> Suggestion / comparison artifact
```

## Design Principles

### 1. Keep the harness snapshot canonical

`RunicAI.Harness.Session` should remain the public snapshot artifact returned by
runtime processes.
Do not introduce a second incompatible session-state struct for the process
layer.

### 2. Use one generic session server

Write one generic `Runtime.SessionServer` parameterized by recipe, backend, and
policy rather than a separate GenServer per recipe family.

### 3. Let backends absorb recipe-track differences

Turn-processor and integrated recipes differ in how they map to `Runic.Runner`.
That difference belongs in backend modules, not in the public process API.

### 4. Preserve trace and evaluation semantics

Runtime processes should emit the same semantic trace events and evaluation
artifacts as headless harness runs.
There should not be a second runtime-only observability taxonomy.

### 5. Keep execution adapters behind the tool contract

Command execution, sandboxing, jobs, and external workers should show up as
tool executor adapters.
They should not become hidden side channels around the tool lane.

### 6. Make wait scheduling explicit

`Wait.until` remains a typed value.
Phase 8 adds scheduler adapters that deliver wake signals.
It should not introduce hidden sleeps or ad hoc timers embedded in recipe code.

### 7. Keep candidate selection explicit at session start

A runtime session should know which candidate recipe or prompt policy it is
using.
It should not silently switch candidates mid-session.

### 8. Keep optimization hooks observational by default

Optimization hooks should consume trajectories and evaluation results and emit
suggestions or derived artifacts.
They should not mutate the live runtime loop implicitly.

### 9. Extend Phase 4 context contracts rather than replacing them

Long-horizon context support should reuse `Context.Graph`, `Context.Node`,
`Context.HandoffArtifact`, `Memory.Store`, and retrieval contracts.
Do not create a separate runtime-only memory ontology.

### 10. Make zero-config and durable modes both first-class

`Runic.Runner.Store.ETS` should support a zero-config in-memory path, while
custom runner stores and external schedulers should support durable
application-owned deployments.

## Recommended Public Contract Layering For Phase 8

### Layer 1: Existing primary contracts

These remain the actual agent semantics.

- `RunicAI.Agent.*`
- `RunicAI.Tool.*`
- `RunicAI.Control.*`
- `RunicAI.Context.*`
- `RunicAI.Memory.*`
- `RunicAI.Retrieval.*`
- `RunicAI.Decomposition.*`
- `RunicAI.Integrated.*`
- `RunicAI.Trace.*`
- `RunicAI.Harness.*`
- `RunicAI.Evaluation.*`

### Layer 2: Runtime session contracts

These define how a long-lived runtime session is addressed and configured.

Recommended new modules:

- `RunicAI.Runtime.SessionSpec`
  - recipe module
  - recipe opts
  - driver kind or inferred driver
  - backend selection
  - runner name and store configuration
  - scheduler selection
  - candidate selection
  - policy and metadata
- `RunicAI.Runtime.Backend`
  - backend behaviour for `init`, `submit`, `advance`, `drain`, `snapshot`,
    `outputs`, `shutdown`
- `RunicAI.Runtime.Handle`
  - stable runtime session reference with server name, session id, backend
    metadata, and optional runner workflow id

Important non-goal:

- do not create a second public turn/state/review/wait vocabulary here

### Layer 3: Runtime execution adapters

These stay behind the tool contract.

Recommended new modules:

- `RunicAI.Tool.ExecutionAdapter`
- `RunicAI.Tool.Adapters.Command`
- `RunicAI.Tool.Adapters.RunnerWorkflow`
- `RunicAI.Tool.Adapters.ExternalWorker`
- optionally `RunicAI.Tool.Adapters.Task`

The key normalization rule should be:

```text
adapter-specific execution outcome
  -> existing CallResult / Wait / ContinueDecision-compatible control path
```

Not:

```text
adapter-specific public result ontology
```

### Layer 4: Long-horizon context extensions

These extend the Phase 4 context model without jumping to Phase 9.

Recommended new modules:

- `RunicAI.Context.HorizonPolicy`
- `RunicAI.Context.RestorePlan`
- `RunicAI.Context.LineageSnapshot`
- `RunicAI.Context.ThreadStore` or similar persistence adapter

These should describe:

- what gets checkpointed from a long-lived session
- how context graphs are persisted across session boundaries
- how selective re-expansion or restore happens before the next turn

### Layer 5: Candidate and optimization contracts

These are observational and routing-oriented, not self-modifying.

Recommended new modules:

- `RunicAI.Candidate.Spec`
- `RunicAI.Candidate.Registry`
- `RunicAI.Candidate.SelectionPolicy`
- `RunicAI.Candidate.Assignment`
- `RunicAI.Optimization.Hook`
- `RunicAI.Optimization.Suggestion`
- `RunicAI.Optimization.Objective`

## Recommended Runtime API Surface

The runtime surface should feel like a thin operational wrapper around the
Phase 7 harness.

Recommended top-level functions:

- `RunicAI.Runtime.start_session/1`
- `RunicAI.Runtime.start_session_link/1`
- `RunicAI.Runtime.submit/2`
- `RunicAI.Runtime.advance/2`
- `RunicAI.Runtime.drain/2`
- `RunicAI.Runtime.snapshot/1`
- `RunicAI.Runtime.outputs/1`
- `RunicAI.Runtime.trajectory/1`
- `RunicAI.Runtime.subscribe/1`
- `RunicAI.Runtime.unsubscribe/1`
- `RunicAI.Runtime.stop/1`
- `RunicAI.Runtime.whereis/1`

The return values should prefer:

- `Harness.Session` snapshots
- `Trace.Trajectory`
- emitted outputs or emissions
- stable runtime handles

The API should not require callers to manipulate raw runner workflow ids unless
they explicitly opt into lower-level integrations.

## Recommended Module Map

### Runtime process layer

- `lib/runic_ai/runtime.ex`
- `lib/runic_ai/runtime/session_spec.ex`
- `lib/runic_ai/runtime/handle.ex`
- `lib/runic_ai/runtime/backend.ex`
- `lib/runic_ai/runtime/session_server.ex`
- `lib/runic_ai/runtime/session_supervisor.ex`
- `lib/runic_ai/runtime/registry.ex`
- `lib/runic_ai/runtime/scheduler.ex`
- `lib/runic_ai/runtime/schedulers/local_timer.ex`
- `lib/runic_ai/runtime/schedulers/noop.ex`

### Runtime backends

- `lib/runic_ai/runtime/backends/in_memory.ex`
- `lib/runic_ai/runtime/backends/runner_integrated.ex`
- `lib/runic_ai/runtime/backends/runner_turn_processor.ex`

### Tool execution adapters

- `lib/runic_ai/tool/execution_adapter.ex`
- `lib/runic_ai/tool/adapters/command.ex`
- `lib/runic_ai/tool/adapters/runner_workflow.ex`
- `lib/runic_ai/tool/adapters/external_worker.ex`
- optionally `lib/runic_ai/tool/adapters/task.ex`

### Long-horizon context extensions

- `lib/runic_ai/context/horizon_policy.ex`
- `lib/runic_ai/context/restore_plan.ex`
- `lib/runic_ai/context/lineage_snapshot.ex`
- `lib/runic_ai/context/thread_store.ex`

### Candidate and optimization layer

- `lib/runic_ai/candidate/spec.ex`
- `lib/runic_ai/candidate/registry.ex`
- `lib/runic_ai/candidate/selection_policy.ex`
- `lib/runic_ai/candidate/assignment.ex`
- `lib/runic_ai/optimization/hook.ex`
- `lib/runic_ai/optimization/suggestion.ex`
- `lib/runic_ai/optimization/objective.ex`

## Sequenced Implementation Slices

Phase 8 should be implemented in slices that preserve usability after each
milestone.

### Slice 1: Supervised session servers over the Phase 7 harness

Deliver:

- `Runtime.SessionSpec`
- `Runtime.Handle`
- `Runtime.SessionServer`
- `Runtime.SessionSupervisor`
- `Runtime.Registry`
- `Runtime.Backends.InMemory`
- `Runtime` facade API

Behavior:

- starts supervised sessions from a recipe plus policy
- stores the latest `Harness.Session` in GenServer state
- allows `submit`, `advance`, `drain`, `snapshot`, `outputs`, and `stop`
- optionally subscribes callers to trace events and snapshot updates

Recommendation:

- implement this slice first
- do not wait for `Runic.Runner` integration before giving users an OTP way to
  operate sessions

### Slice 2: Runner-backed session backends

Deliver:

- `Runtime.Backends.RunnerIntegrated`
- `Runtime.Backends.RunnerTurnProcessor`
- runner configuration in `SessionSpec`
- explicit runner store ownership docs and child-spec patterns

Behavior:

- integrated backend maps one runtime session to one runner workflow id
- turn-processor backend uses runner-managed execution to compute each
  advancement and then projects the result back into the canonical
  `Harness.Session`
- both backends return equivalent session snapshots and trajectories to the
  in-memory backend as closely as practical

Important rule:

- `Runic.Runner` is a backend and durability primitive here, not the primary
  public API

### Slice 3: Wait scheduling and wake delivery

Deliver:

- `Runtime.Scheduler`
- `Runtime.Schedulers.LocalTimer`
- one durable scheduler adapter boundary
- runtime integration for `Wait.until`

Behavior:

- if a session outputs a `Wait` with `until`, the scheduler owns wake delivery
- local mode may use `Process.send_after`
- durable mode should support application-owned schedulers or queued wake jobs

Do not:

- sleep inside workflow code
- embed opaque timer state in recipe contracts

### Slice 4: Runtime execution adapters under the tool lane

Deliver:

- tool execution adapter behaviour
- command runner adapter
- runner-workflow adapter
- external worker adapter

Behavior:

- tool definitions remain the visible capability surface
- adapters can execute local commands, sandboxed commands, child workflows,
  background jobs, or remote workers
- adapter outcomes are normalized into existing `CallResult`, `Wait`, retry,
  or halt paths

The first reference adapter should likely be:

- `Tool.Adapters.RunnerWorkflow`

because it proves that one workflow can safely invoke another workflow as a
typed capability without inventing a second orchestration model.

### Slice 5: Long-horizon context runtime extensions

Deliver:

- durable context checkpoints tied to session lifecycle
- selective restore and expansion policies
- persistent lineage snapshots over existing context graphs

Behavior:

- long-running sessions can checkpoint context state across process restarts or
  explicit parking
- restore plans decide what to materialize back into the active window
- selective re-expansion remains explicit policy, not implicit hidden prompt
  growth

Boundary:

- do not introduce prompt-as-environment or recursive RLM execution here

### Slice 6: Candidate selection and optimization hooks

Deliver:

- candidate registry and selection policy
- assignment of a candidate to a runtime session at start
- side-by-side evaluation and comparison hook points
- optimization hook behaviour consuming trajectories or evaluation runs

Behavior:

- serving can choose among recipe candidates explicitly
- evaluation can compare candidates using Phase 7 artifacts
- optimization hooks emit suggestions or comparison outputs rather than
  mutating sessions inline

Recommended default posture:

- selection is explicit
- promotion is external
- live sessions do not self-upgrade

### Slice 7: Opinionated bundles and LiveBook examples

Deliver:

- one runner-backed integrated-session example
- one runner-backed turn-processor session example
- one workflow-as-tool adapter example
- one candidate evaluation example
- one LiveBook per major runtime pattern

## Recommended Reference Runtime Stories

Phase 8 should prove itself with a few concrete stories rather than a broad
API dump.

### Story 1: Runner-backed integrated tool session

Start a supervised session for `IntegratedToolAgent`, submit a user turn,
observe a wait or review pause, wake or resume it later, and confirm the same
runner workflow id preserves the integrated runtime state.

### Story 2: Supervised external-state guarded session

Start a supervised session for `GuardedOperatorToolAgent`, submit a user turn,
receive a review or wait pause, resume it, and verify that the process-owned
`Harness.Session` snapshot advances correctly while the recipe itself remains
external-state.

### Story 3: Workflow as tool adapter

Define a tool whose executor invokes a child workflow through a runtime
adapter, returning ordinary tool observations back into the parent tool lane.

### Story 4: Candidate side-by-side comparison

Start two candidate sessions or run them through `EvaluationHarness`, compare
their trajectories and scores, and produce a stable promotion recommendation
without modifying live serving sessions.

## Runic Component Types Used In Phase 8

Phase 8 is mostly about wrapping and operating the already-existing workflow
graphs, but a few Runic primitives matter directly.

### Primary use

- `Runic.Runner`
  for supervision, persistence, workflow lifecycle, and managed execution
- existing recipe internals:
  `Runic.accumulator`, `Runic.rule`, `Runic.step`, `Runic.state_of/1`

### Secondary use

- `Runic.Workflow.ProcessManager`
  can be a good fit for coordination workflows such as external worker job
  orchestration, durable wake scheduling, or candidate rollout coordination,
  but it should remain a workflow-level coordination tool, not the primary
  representation of a runtime session

## Testing And Verification Strategy

Phase 8 needs both contract tests and realistic runtime verification.

### Unit and contract tests

- `Runtime.SessionSpec` validation
- backend behaviour conformance tests
- scheduler adapter tests
- candidate policy validation tests
- optimization hook contract tests

### Backend parity tests

For the same input sequence:

- `InMemory` backend and `RunnerIntegrated` backend should converge on the same
  final `Harness.Session` for integrated recipes
- `InMemory` backend and `RunnerTurnProcessor` backend should converge on the
  same final `Harness.Session` for external-state recipes

The parity tests should compare:

- session snapshot
- outputs or emissions
- important trace-event kinds
- waits, reviews, resumes, and wakes

### Supervision tests

- session server restart behavior
- `DynamicSupervisor` child lifecycle
- registry lookup and duplicate-session protection
- runner store ownership and zero-config ETS startup

### Tool adapter tests

- command execution success and failure
- runner-workflow tool invocation
- deferred external worker path normalized back into wait or resume flow

### Candidate and optimization tests

- deterministic candidate assignment
- side-by-side comparison wiring
- optimization hooks consuming `Trace.Trajectory` and `Evaluation.Run`

### Manual integration verification

Write a Phase 8 manual report after implementation using real LLM calls and
real supervised runtime flows.

The report should include:

- a runner-backed integrated agent session
- a supervised external-state guarded session
- a scheduled wake flow
- one runtime adapter flow
- one candidate comparison or optimization-hook flow

Recommended future doc name:

- `.docs/016-phase-8-manual-runtime-verification-report.md`

## Open Questions To Resolve During Implementation

### 1. How much subscription surface should be public?

Recommendation:

- keep it small
- support session snapshot updates, trace events, and outputs/emissions
- do not invent a large event bus before concrete user needs emerge

### 2. Should runtime sessions mirror every trace event into GenServer mailbox traffic?

Recommendation:

- no by default
- prefer explicit subscribers and reusable trace sinks

### 3. Should the runtime expose recipe-specific convenience servers?

Recommendation:

- not initially
- start with one generic session server
- add thin convenience wrappers only if they remove real repeated boilerplate

### 4. Should candidate selection happen per turn?

Recommendation:

- no
- assign one candidate per session
- compare candidates across sessions or evaluation runs

### 5. Should optimization hooks ever mutate live sessions automatically?

Recommendation:

- not in the initial Phase 8 design
- emit suggestions, comparisons, and derived artifacts first

## Non-Goals

Phase 8 should explicitly not do the following:

- replace the Phase 7 headless harness as the canonical control plane
- make raw `Runic.Runner` ids the main user-facing API
- create one bespoke GenServer per recipe module
- invent a second runtime-only state ontology for turns, tools, waits, or
  reviews
- jump ahead into Phase 9 RLM execution mode
- make optimization self-modifying by default

## Expected Outcome

When Phase 8 lands, RunicAI should support three coherent operating modes over
the same recipes and contracts:

1. headless deterministic harness execution for testing, replay, and eval
2. supervised in-memory session execution for local apps and interactive
   systems
3. runner-backed durable execution for long-lived integrated and external-state
   agent services

That is the right next step after Phase 7.
It preserves the deterministic workflow substrate, gives users real OTP and
runner ergonomics, and creates a clean seam for advanced execution, candidate
serving, and optimization layers without making those layers the center of the
library.
