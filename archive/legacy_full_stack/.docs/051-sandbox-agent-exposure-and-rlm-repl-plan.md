# Sandbox Agent Exposure And RLM REPL Plan

Status: implemented through Phase 8; full live-agent/backend hardening remains

Date: 2026-05-25

## Purpose

RunicSandbox now gives RunicAI a backend-neutral way to run code with structured
inputs, outputs, diagnostics, artifacts, policy, trace events, and capability
metadata. The next product question is not whether code can run. It is whether
the built-in agents can reliably use sandboxed execution as a first-class way to
solve work.

This plan covers:

- exposing sandbox execution to standard, assistant, and coding/RLM agents;
- adding Runic components and model-visible tools for stateless and stateful
  sandbox use;
- using the Recursive Language Models paper as a design prompt for persistent
  sandbox REPL components;
- simplifying the current "RLM Agent" story from a brittle dynamic workflow
  coordinator into a workflow-building loop that can safely write, test, run,
  and compose arbitrary code;
- preserving RunicAI contracts around structured data, reviewability,
  observability, capability profiles, and durable traces.

Related docs:

- `.docs/046-ai-code-sandboxing-research.md`
- `.docs/050-sandbox-serverless-mesh-and-libbit-consumer-next-steps.md`
- `.docs/043-hermes-style-agent-tool-surface.md`
- `.docs/031-general-purpose-dynamic-rlm-workflow-generation-implementation-plan.md`
- `.docs/036-runic-native-dynamic-workflow-generation-refactor-plan.md`
- `.docs/049-rlm-objective-loop-and-opslogic-capability-plan.md`
- [Recursive Language Models](https://arxiv.org/pdf/2512.24601)
- [lambda-RLM](https://github.com/lambda-calculus-LLM/lambda-RLM)
- [Recursive by Design](https://theharness.blog/blog/recursive-by-design/)

## Executive Summary

The sandbox package is present, and RunicAI has an initial integration path:
`execute_code`, `sandbox_status`, capability-profile configuration, review
metadata, trace events, Workbench settings, and RLM script-node execution.

The original exposure gaps have been implemented through the phase work below:

- standard coding recipes can expose `execute_code` and `sandbox_status`
  through explicit sandboxed recipes and capability profiles;
- assistant and generated RLM workflows have explicit sandbox component catalog
  entries in addition to capability-profile-visible `tool_leaf` execution;
- session, checkpoint, file, service, and proxy operations are model-visible
  through tool/component contracts backed by the `RunicSandbox` package
  boundary;
- the coding "RLM Agent" is now treated as one strategy in a broader
  coordinator family: direct standard-agent loops, Lambda-style decomposition,
  constrained subagents, sandbox REPL, generated sandbox components, and
  optional host-edit workflows.

Recommendation:

1. Treat sandbox execution as a capability family, not one hidden tool.
2. Add explicit sandbox recipes and prompt guidance so agents know when to use
   `run_command` versus `execute_code`.
3. Add Runic sandbox components with typed contracts for exec, sessions,
   files, checkpoints, services, proxies, and artifacts.
4. Treat "RLM" as a family of large-context decomposition patterns:
   Lambda-style typed decomposition, classic REPL-style recursion, subagent
   delegation, generated sandbox components, and multi-agent workflows.
5. Add a persistent REPL component family where large context, intermediate
   variables, generated code, and sub-agent/model calls live in a stateful
   sandbox environment.
6. Let coordinators generate sandbox-backed Runic components, test them in
   isolation, and compose them into workflows instead of forcing every task
   through a fragile bespoke proposal graph.

## Current Exposure Audit

### Already Available

- [x] `RunicAI.Coding.Tools.default_registry/2` registers code-execution tools.
- [x] `execute_code` calls `RunicSandbox.exec/2` and converts the result into a
      `RunicAI.Coding.CommandResult`.
- [x] `sandbox_status` describes configured sandbox backends and isolation
      metadata.
- [x] Capability profiles know the `:code_execution` toolset.
- [x] Capability profiles can carry backend, runtime, network, pool, workspace,
      metadata, and sandbox policy configuration.
- [x] `RunicAI.Agent.ToolExecution` treats `execute_code` as reviewable and
      includes sandbox details in review requests.
- [x] Coding RLM `:script` nodes can route to `execute_code` when script
      execution is allowed.
- [x] Assistant/RLM component runtime can execute model-authored `tool_leaf`
      nodes through capability-profile-visible tools.
- [x] Sandbox trace events carry session, checkpoint, service, proxy, and
      capability metadata slots.

### Resolved By This Plan

- [x] Default standard-agent recipes expose `execute_code`.
- [x] Prompting clearly tells agents when to prefer sandbox execution.
- [x] Workbench agent launch presets expose sandboxed recipes directly.
- [x] Session lifecycle is model-visible.
- [x] Checkpoints and restore are model-visible.
- [x] Sandbox file IO is model-visible.
- [x] Sandbox service/proxy operations are model-visible.
- [x] RLM/assistant component catalog has explicit stateless sandbox components.
- [x] Generated code can be promoted into reusable Runic components with input
      and output contracts.
- [x] The coordinator can keep a persistent REPL state and ask the model to
      operate over variables instead of repeatedly stuffing observations into
      prompt history.

## Research: RLM Flavors And Large-Context Decomposition

Sources:

- [Recursive Language Models](https://arxiv.org/pdf/2512.24601), Alex L.
  Zhang, Tim Kraska, Omar Khattab, arXiv:2512.24601v3, 2026-05-11.
- [lambda-RLM](https://github.com/lambda-calculus-LLM/lambda-RLM), a typed
  recursive long-context reasoning implementation and reference implementation.
- [Recursive by Design](https://theharness.blog/blog/recursive-by-design/), a
  practitioner write-up on open REPL RLMs, Lambda-RLM, benchmarking, and harness
  design.

The Recursive Language Models paper's core idea is that long prompts should
live in an external environment, not inside the model context window. The RLM
initializes a persistent REPL with the prompt stored as a variable, lets the
model write code against that variable, allows model calls from inside that
code, and only feeds bounded metadata and observations back into the root loop.

The useful design lessons for RunicAI are:

1. A real RLM needs a symbolic environment.
   The model should manipulate handles such as `context`, `workspace`,
   `artifacts`, `trace`, and `buffers` without copying all of their contents
   into the root prompt.
2. Recursion should be programmable.
   The environment should expose `llm_query/1` for simple subcalls and
   `rlm_query/2` or `delegate/2` for complex subproblems that deserve their own
   loop.
3. Observations should be bounded.
   REPL stdout, file previews, artifact summaries, and subcall results should
   be summarized before returning to the model turn.
4. Intermediate outputs should live outside model history.
   Variables, files, SQLite tables, JSONL buffers, and checkpoints are better
   long-horizon state than ever-growing chat transcripts.
5. Final answers should be structured.
   The paper uses explicit final tags and final variables. RunicAI should avoid
   brittle string tags where possible and instead expose `final_result` as a
   structured REPL variable or component output contract.
6. Cost controls matter.
   The paper notes that naive sequential subcalls are slow and that models may
   overuse subcalls. RunicAI should make batching, fan-out limits, budgets,
   timeout policy, and async execution first-class.

This maps well to RunicAI because Runic already gives us typed components,
RunicSandbox gives us isolated execution state, and capability profiles give us
policy. The missing layer is a stateful REPL component that combines them.

Lambda-RLM is a different but complementary RLM flavor. It argues against
open-ended generated recursion as the default and instead uses a typed
functional runtime with pre-verified operators such as `SPLIT`, `MAP`,
`FILTER`, `REDUCE`, `CONCAT`, and `CROSS`. The model is used on bounded leaf
subproblems while deterministic symbolic operators handle recursive structure
and composition. The reference implementation makes the split concrete:
initialize a REPL-like environment where the prompt/context lives outside the
model window, perform a small task-detection step, compute an explicit plan
with branching factor, leaf chunk size, recursion depth, composition operator,
and cost estimate, then execute a pre-verified combinator chain. That shape is
more important to RunicAI than the exact Python code: decomposition should be
typed data that can be validated, traced, budgeted, and replayed.

The Harness article gives the practical engineering lesson: agent architecture
is harness design. A REPL gives power but can be hard to predict. Lambda-style
decomposition can be better when the task structure is known because the plan,
cost, and call count can be estimated before execution. Domain feedback,
rubrics, trajectory capture, and section-by-section review are part of the
system, not optional evaluation afterthoughts. The article's strongest point
for RunicAI is that many "RLM" tasks are not inherently open-ended reasoning
loops. Report generation, extraction, codebase summarization, benchmark
comparison, and many workflow-planning tasks already contain a latent structure:
sections, files, artifacts, dependencies, schemas, and review contracts. The
coordinator should compute that structure when it can, not ask a model to
rediscover it through a long REPL transcript.

The lambda-RLM repository makes this concrete enough for RunicAI planning: it
keeps the familiar RLM comparison target but moves the preferred lane toward a
typed runtime with pre-verified operators and bounded leaf model calls. Its
published claim is not just "recursion helps"; it is that the recursive control
surface should be deterministic when the task can be expressed as split, map,
filter, reduce, cross, review, and generate. That is a close match for Runic
workflows: the workflow graph is the typed control program, while the model is
used where judgment, extraction, synthesis, or repair is actually needed.

The original RLM paper remains valuable for the opposite class of work. When
the decomposition is unknown, when the model must inspect a complex artifact,
or when the task is best discovered by writing code against a symbolic external
context, an open REPL loop is the right abstraction. The important RunicAI
adjustment is that this REPL should run inside RunicSandbox with structured
variables, bounded observations, explicit budgets, review gates, and trace
events. It should not be an opaque shell transcript bolted onto an agent loop.
The RLM difference from ordinary "agent with tools" is that code inside the
environment can programmatically loop over context handles and invoke bounded
subqueries. RunicAI should expose that power deliberately through mediated
`llm_query`, `rlm_query`, and `delegate` functions rather than by giving every
agent arbitrary host execution.

For RunicAI, the conclusion is that there should not be one "RLM mode." The
coordinator should choose among several strategies:

| Strategy | Best fit | Risk |
| --- | --- | --- |
| Lambda-style typed workflow | Large context with clear split/map/reduce/review/generate shape. | Too rigid if the task structure is genuinely unknown. |
| Classic REPL RLM | Exploratory analysis, uncertain decomposition, code-heavy context operations. | More expensive, less predictable, can drift without budgets and reviews. |
| Subagent delegation | Work that can be partitioned by role, file set, topic, or review responsibility. | Coordination overhead and inconsistent local conclusions. |
| Generated sandbox component | Repeated transformation, parser, analyzer, scorer, or data-processing step. | Requires contract, tests, and promotion policy. |
| Multi-agent workflow | Complex work needing planner/executor/reviewer/jury or map/reduce/review loops. | Harder observability and failure attribution unless traces are explicit. |
| Direct sandbox execution | Small generated-code experiment, polyglot runtime probe, isolated data transform. | Can become unstructured one-off scripting if not promoted when repeated. |

The large-context pattern underneath all of these is context delegation. The
root coordinator should own the objective, policy, budget, and final answer
contract, but it should not try to carry the whole problem in one prompt. It
should delegate narrower context slices to one of three execution substrates:

1. deterministic workflow components when the slice operation is known;
2. subagents when the slice needs role-specific judgment, local tools, or
   independent investigation;
3. sandbox REPL/code when the slice is easier to inspect, index, transform, or
   summarize programmatically.

This means RunicAI should treat "RLM" as an execution-strategy family, not a
single agent implementation:

- `direct_standard_agent`: best for narrow local edits, questions, or shell-like
  verification that does not need large-context decomposition.
- `lambda_workflow`: best for known large-context structure where the plan can
  be computed as typed split/map/filter/reduce/review/generate data.
- `subagent_delegation`: best when slices need separate prompts, tool scopes,
  roles, or independent investigations.
- `sandbox_repl`: best when the model needs a symbolic environment and
  programmatic subcalls over external state.
- `generated_sandbox_component`: best when the solution is really a reusable
  parser, scorer, analyzer, transformer, or service.
- `host_edit_workflow`: best only after evidence shows that materialized host
  changes are the required output.

The coordinator should not start by generating an entire workflow graph and
then try to compile or repair it. That is too high entropy. It should first
classify the problem shape, choose an execution strategy, gather runtime
evidence through that strategy, and only synthesize a larger workflow when the
pieces have been proven.

This reframes the current coordinator work:

- The coordinator is a router and evidence accumulator first.
- Lambda-style workflows are the default for known large-context structure.
- Subagent delegation is the default for separable human-like work packets.
- REPL RLM is an escalation lane for exploratory symbolic context work.
- Generated sandbox components are promoted only after contract and test
  evidence.
- Host edit workflows are the final materialization lane, not the first way to
  think.

### Lambda-RLM-Inspired Coordinator Implications

The important Lambda-RLM lesson for RunicAI is not that every large-context
task should become a lambda-calculus interpreter. It is that the coordinator
should separate control structure from leaf judgment whenever the task shape is
known. The model should not be asked to rediscover split/map/reduce/report
control flow inside a long transcript if RunicAI can compute that structure as
typed workflow data.

That gives the coordinator a clearer job:

1. classify the task shape and context shape;
2. choose the smallest sufficient execution strategy;
3. give each strategy typed inputs, budget, policy, and output contracts;
4. run an evidence-producing slice before widening the plan;
5. reduce, review, and materialize results only after the leaf work is proven.

The coordinator should therefore support several RLM-adjacent execution
patterns, each with a stable interface:

| Pattern | Coordinator interface | Implementation primitive |
| --- | --- | --- |
| Direct agent loop | objective + visible tools + stop criteria | existing standard/coding agent |
| Lambda workflow | context refs + typed operators + estimates | Runic workflow over Lambda aliases |
| Subagent delegation | assignment specs + context slices + schemas | standard agents with constrained prompts/tools |
| Classic REPL RLM | symbolic variables + environment functions + budgets | sandbox session with mediated subcalls |
| Generated component | contract + source + tests + promotion policy | sandbox code artifact wrapped as Runic component |
| Multi-agent workflow | topology + roles + reducers + reviewers | Runic graph coordinating assignments/results |

This makes "RLM" a strategy family rather than an agent personality. A
Lambda-style run is recursive because the workflow recursively decomposes
context into bounded leaf calls. A classic REPL run is recursive because code
inside a symbolic environment can issue mediated `llm_query` or `rlm_query`
subcalls. A subagent workflow is recursive because each assignment can itself
route to one of the same strategies under a smaller budget. These should share
contracts and traces, but they should not share one brittle prompt that asks a
model to invent all control flow up front.

The practical design rule is: compute structure when structure is visible;
delegate when work is separable; use REPL only when the decomposition must be
discovered by interacting with the context; generate sandbox components when a
leaf operation is really code.

### Lambda-RLM Lineage And Runic's Coordinator

Runic's current coordinator idea came from the same family as Lambda-RLM: use a
library of composable operations to work on slices of a problem that are too
large or too varied for one prompt loop. That lineage matters because it gives
the coordinator a more realistic contract than "invent a full workflow graph
from scratch." The coordinator should be allowed to compose known operators,
delegate to narrower agents, run bounded REPL exploration, and ask for
generated sandbox components as separate strategies.

The problem with the current proposal -> compile -> repair loop is not that
dynamic workflows are wrong. It is that the root model is being asked to solve
several hard problems at once:

- decide which context should be visible;
- decide whether the problem is a Lambda-style decomposition, subagent fan-out,
  REPL exploration, generated-code task, or direct host edit;
- invent the workflow topology;
- choose component parameters and contracts;
- predict execution behavior before observing any leaf result;
- repair schema, graph, and semantic mistakes through another high-entropy
  prompt.

Lambda-RLM's useful correction is to move as much of that control problem as
possible into typed, inspectable runtime data. For RunicAI, that means the
coordinator first emits a strategy decision and small executable slice, not a
maximal graph. The slice can be:

- a Lambda plan over `split`, `map`, `filter`, `reduce`, `review`, and
  `generate`;
- a list of subagent assignments with scoped context refs and output schemas;
- a sandbox REPL state with symbolic variables and mediated `llm_query` /
  `delegate` functions;
- a generated component build request with contract, tests, promotion policy,
  and sandbox profile;
- a direct standard-agent or host-edit lane when the task is truly local.

This also changes how repair should work. If the first strategy fails for
structural reasons, the coordinator should usually change strategies instead
of asking for another graph-shaped repair. Examples:

- Lambda plan has poor coverage -> add targeted leaf extraction or subagent
  review, not a whole new graph.
- Subagents disagree -> run reducer/reviewer or escalate one slice to REPL, not
  re-run all assignments.
- REPL transcript drifts -> checkpoint, summarize state, route to Lambda or
  generated component once the operation is understood.
- Generated component tests fail -> repair the component contract/source/tests
  inside sandbox; if repeated, demote to direct sandbox execution or subagent
  investigation.
- Host-edit workflow lacks evidence -> route back to sandbox verification or
  direct standard-agent investigation before patching.

The implementation implication is that the coordinator needs a durable
strategy-decision record before workflow compilation. It should record:

- problem shape and context shape;
- selected strategy and fallback strategy;
- context refs, artifact refs, and any intentionally hidden context;
- expected fan-out, model calls, sandbox calls, and review pauses;
- parent strategy, remaining budget, and depth when nested;
- the exact evidence that caused escalation, demotion, or promotion.

That makes the Runic coordinator closer to a harness for recursive context
delegation than a single "RLM agent." It can still compile Runic workflows, but
workflow compilation becomes one lane in a larger OODA loop rather than the
first and only move.

## Terminology Correction

`RunicAI.Coding.RLM.Agent` should be treated as a dynamic workflow coordinator,
not as one canonical RLM implementation. It currently proposes, validates,
compiles, executes, repairs, and scores workflow attempts. That is a useful OODA
loop, but the current problem -> proposed workflow -> compile-or-repair path is
too hard to be the default strategy because:

- the root model does not operate over a persistent symbolic context variable;
- generated code cannot freely loop over external context while calling
  submodels from inside the environment;
- intermediate variables and final outputs are not the primary state surface;
- workflow proposal failures often happen before the system gets useful runtime
  evidence;
- the coordinator is forced to invent too much structure before seeing whether
  smaller leaf operations work.

The near-term goal is not to rename everything. The goal is to add a
strategy router and let the existing coordinator use simpler proven primitives:
typed Lambda-style decomposition, subagent delegation, REPL exploration,
generated sandbox components, and explicit multi-agent workflows.

## Target Architecture

```text
User objective
  -> Coordinator / standard agent / assistant planner
  -> strategy router:
       lambda workflow | repl | subagents | generated component | direct tools
  -> capability profile selects sandbox/runtime/model/tool visibility
  -> Runic components and tools:
       sandbox_status
       execute_code
       sandbox_session
       sandbox_repl
       lambda_split/map/reduce/review
       sandbox_component_builder
       delegate_subagent
       sandbox_service_smoke
       llm_query / rlm_query / delegate
  -> RunicSandbox session:
       files, variables, artifacts, checkpoints, services, proxies
  -> backend:
       just_bash, lua, docker, vmsan, sprites, future runtimes
  -> structured results:
       outputs, diagnostics, artifacts, traces, review records, final_result
```

Important boundary rule: RunicAI agents and generated workflows should depend on
RunicAI/RunicSandbox contracts, not Docker, vmsan, Sprites, or provider-specific
commands. Provider details belong in sandbox profiles and backend adapters.

## Coordinator Strategy Router

The coordinator should choose the least powerful strategy that can plausibly
solve the task.

Decision order:

1. Use a direct standard-agent loop when the task is local, narrow, and likely
   needs file edits or normal project commands.
2. Use Lambda-style typed decomposition when the task is mostly large-context
   reading, extraction, summarization, scoring, comparison, or report
   generation.
3. Use subagent delegation when the task naturally partitions by file,
   component, topic, reviewer role, or independent investigation lane.
4. Use a generated sandbox component when a repeated transformation or analyzer
   would be clearer as tested code than as repeated prompting.
5. Use a classic REPL RLM when the decomposition is uncertain and the model
   needs to programmatically inspect, slice, query, and transform external
   context. The REPL lane should still expose typed environment functions,
   bounded observations, and mediated subcalls rather than a raw shell contract.
6. Use host commands and direct patches only when sandbox/tool evidence says the
   workspace itself must be changed or verified.

The router can start rule-based. It should expose the selected strategy,
reasoning, budgets, and fallback strategy in trace metadata so evaluations can
show when the routing choice was wrong.

The router should also be re-entrant. A subagent, REPL subquery, generated
component build, or Lambda leaf can request a smaller nested route, but the
parent coordinator owns the aggregate budget and depth limit. This preserves
the recursive benefit without allowing unbounded autonomous fan-out. The
initial router should reject nested routing when it cannot attach:

- a parent run id;
- a reduced context slice or artifact ref;
- a role/objective string;
- an output schema or review rubric;
- remaining call, token, execution-time, and sandbox budgets;
- a maximum recursion depth.

Router outputs should be durable enough to benchmark. Every routed run should
record:

- selected strategy and fallback strategy;
- parent strategy and depth when the run is nested;
- objective classification and reasons;
- expected leaf/subagent/sandbox call counts;
- planned context bytes/tokens and fan-out;
- actual calls, retries, elapsed time, and review failures;
- whether the run escalated to a more powerful strategy.

## Tool And Recipe Exposure Plan

### Recipes

Add explicit recipes instead of silently widening every default mode.

- [x] `:sandboxed_verify`
      - visible tools: verify recipe tools plus `execute_code`,
        `sandbox_status`;
      - intended for safe polyglot experiments, generated snippets, and
        dependency/runtime probes;
      - default network: disabled;
      - review: required for non-ephemeral workspaces, network, services, or
        host-adjacent policies.
- [x] `:polyglot_experiment`
      - visible tools: read/search, `execute_code`, `sandbox_status`,
        artifact tools;
      - no host patching by default;
      - suited for "try a parser", "write a script", "analyze data", "generate
        a small utility".
- [x] `:stateful_sandbox_workspace`
      - visible tools: read/search, sandbox session/file/checkpoint/service
        tools, `execute_code`;
      - intended for longer-lived workspaces and remote backends such as
        Sprites;
      - all service/proxy/network operations gated.
- [x] `:component_builder`
      - visible tools: read/search, sandbox exec/session/file tools,
        apply_patch, tests, formatter;
      - intended for agents that generate reusable Runic components or
        sandbox-backed function modules.

### Prompt Guidance

Add a sandbox section to standard, assistant, and generated RLM prompts:

- [x] Explain that `run_command` is for project-native host commands such as
      `mix test`, `git`, and local build tools.
- [x] Explain that `execute_code` is for arbitrary generated code, polyglot
      experiments, untrusted snippets, isolated runtime probes, and code that
      should not mutate the host workspace.
- [x] Include the active sandbox profile: backend, isolation, runtimes, network,
      state model, persistence, session policy, and review policy.
- [x] Tell agents to prefer deterministic safe computing components first,
      sandbox execution second, and host shell only when the task specifically
      requires host/project interaction.
- [x] Tell agents to summarize sandbox artifacts and diagnostics, not paste
      large stdout blobs into final answers.

### Model-Visible Tools

Expose only the small stateless pair broadly at first:

- [x] `sandbox_status`
- [x] `execute_code`

Then add stateful tools behind explicit recipes/capability profiles:

- [x] `open_sandbox_session`
- [x] `close_sandbox_session`
- [x] `sandbox_exec`
- [x] `sandbox_write_file`
- [x] `sandbox_read_file`
- [x] `sandbox_list_files`
- [x] `checkpoint_sandbox`
- [x] `restore_sandbox`
- [x] `start_sandbox_service`
- [x] `open_sandbox_proxy`
- [x] `close_sandbox_proxy`

Each tool should return structured data and include trace metadata for
`session_id`, `checkpoint_id`, `service_id`, `proxy_id`, `backend`,
`isolation_level`, `network`, `runtime`, and artifact references.

## Runic Component Plan

Add explicit components so workflows do not need to call model-visible tools for
every internal operation.

### Stateless Components

- [x] `RunicAI.Sandbox.Components.Status`
      - input: optional backend/profile selector;
      - output: backend health, capabilities, diagnostics.
- [x] `RunicAI.Sandbox.Components.Execute`
      - input: runtime, code, files, timeout, output cap, policy;
      - output: command-like result plus sandbox metadata and artifacts.
- [x] `RunicAI.Sandbox.Components.ArtifactMaterializer`
      - input: artifact refs and materialization policy;
      - output: bounded previews or host workspace writes behind policy.

### Stateful Components

- [x] `RunicAI.Sandbox.Components.OpenSession`
- [x] `RunicAI.Sandbox.Components.ExecInSession`
- [x] `RunicAI.Sandbox.Components.WriteFile`
- [x] `RunicAI.Sandbox.Components.ReadFile`
- [x] `RunicAI.Sandbox.Components.Checkpoint`
- [x] `RunicAI.Sandbox.Components.Restore`
- [x] `RunicAI.Sandbox.Components.CloseSession`

### Service Components

- [x] `RunicAI.Sandbox.Components.StartService`
- [x] `RunicAI.Sandbox.Components.OpenProxy`
- [x] `RunicAI.Sandbox.Components.ServiceSmoke`
- [x] `RunicAI.Sandbox.Components.StopService`

### Higher-Level Components

- [x] `RunicAI.Sandbox.Components.WithSession`
      - saga/process-manager shaped wrapper around open, run, checkpoint,
        close;
      - guarantees cleanup;
      - records checkpoint refs and artifacts.
- [x] `RunicAI.Sandbox.Components.BuildComponent`
      - turns generated code plus schema metadata into a reusable component
        spec.
- [x] `RunicAI.Sandbox.Components.VerifyComponent`
      - runs component tests in sandbox before a generated component can be used
        by a workflow.

## Lambda-Style Workflow Components

RunicAI already has the beginnings of a Lambda-RLM-shaped substrate:
`SourceSplitter`, `SourceMaterializer`, `LLMMap`, `HierarchicalReduce`,
`RecordMap`, `RecordGroup`, `ReportComposer`, `ObjectiveScorecard`, and safe
computing components. The next step is to make this substrate explicit enough
for the coordinator to choose it as a strategy.

### Lambda Contract

```elixir
%RunicAI.RLM.LambdaPlan{
  id: "lambda_plan_...",
  objective: "extract risks and mitigation actions",
  context_refs: ["artifact://workspace/context.jsonl"],
  operators: [
    %{op: :split, by: :semantic_chunk, target_tokens: 4_000},
    %{op: :map, component: :llm_extract, schema: :risk_record},
    %{op: :filter, predicate: :has_evidence},
    %{op: :reduce, reducer: :merge_records},
    %{op: :review, checks: [:coverage, :specificity, :provenance]},
    %{op: :generate, component: :report_composer}
  ],
  budgets: %{max_leaf_calls: 40, max_depth: 3, max_concurrency: 8},
  estimates: %{leaf_calls: 24, max_tokens: 96_000}
}
```

The plan should be executable without the model inventing control flow during
execution. The model can help infer extraction fields, write prompts, or design
review rubrics, but the recursive structure itself is typed data.

The first RunicAI Lambda plan should mirror the lambda-RLM separation without
copying its implementation wholesale:

1. `detect`: classify the objective and input structure with deterministic
   heuristics first and an optional one-call model classifier later.
2. `plan`: compute split strategy, fan-out, leaf budget, max depth, operator
   sequence, and estimated call count without running leaf calls.
3. `execute`: run known operators through existing Runic components where
   possible, with leaf model calls and safe-compute steps constrained by the
   plan.
4. `review`: verify schema, provenance, coverage, specificity, and dependency
   alignment before generation.
5. `generate`: compose the final output from reviewed intermediate records,
   preserving trace links back to source slices.

Unlike a pure lambda-RLM implementation, RunicAI should support more than text
documents. Context refs may be files, persisted artifacts, sandbox files,
trace ranges, Workbench selections, database query outputs, or future Libbit
workspace graph slices. The Lambda contract therefore needs provenance and
materialization fields, not just `prompt :: string`.

### Lambda Components

- [x] `RunicAI.RLM.Components.Lambda.Plan`
      - computes objective type, input shape, split strategy, depth, estimated
        calls, and budgets.
- [x] `RunicAI.RLM.Components.Lambda.Split`
      - partitions context into bounded slices with provenance.
- [x] `RunicAI.RLM.Components.Lambda.Map`
      - runs bounded leaf model calls or deterministic safe-compute functions.
- [x] `RunicAI.RLM.Components.Lambda.Filter`
      - removes empty, duplicate, low-confidence, or non-provenanced records.
- [x] `RunicAI.RLM.Components.Lambda.Reduce`
      - merges records, summaries, judgements, or generated artifacts.
- [x] `RunicAI.RLM.Components.Lambda.Cross`
      - compares sections, files, specs, or candidate outputs pairwise.
- [x] `RunicAI.RLM.Components.Lambda.Review`
      - checks coverage, specificity, consistency, provenance, and schema
        alignment before generation.
- [x] `RunicAI.RLM.Components.Lambda.Generate`
      - assembles final outputs from reviewed intermediate records.

Implementation note: do not create bespoke modules until the existing generic
components are insufficient. The first pass should wire Lambda aliases and
contracts over `SourceSplitter`, `SourceMaterializer`, `LLMMap`,
`HierarchicalReduce`, `RecordMap`, `RecordGroup`, `ReportComposer`,
`ObjectiveScorecard`, and the sandbox safe-compute components. New modules are
justified when the Lambda contract needs plan validation, provenance tracking,
call-count accounting, or operator-specific review semantics that the generic
components cannot express cleanly.

### Lambda Evaluation

- [x] Record planned call count and actual call count.
- [x] Record planned token estimate and actual token usage when providers
      expose it.
- [x] Store per-slice extraction/review/generation traces.
- [x] Add a deterministic fixture where the plan catches a missing section or
      provenance gap before final generation.

## RLM-Inspired REPL Components

### REPL Contract

Add a persistent REPL abstraction on top of `RunicSandbox.Session`.

```elixir
%RunicAI.RLM.REPL.State{
  id: "repl_...",
  sandbox_session_id: "sandbox_...",
  runtime: :python,
  context_ref: "artifact://...",
  variables: %{
    "context" => %{kind: :external_ref, ref: "artifact://context.jsonl"},
    "buffers" => %{kind: :sandbox_variable, name: "buffers"},
    "final_result" => nil
  },
  budgets: %{llm_calls: 20, rlm_calls: 3, exec_ms: 120_000},
  observations: [],
  checkpoints: []
}
```

The REPL is not just a terminal. It is a structured environment with these
available functions:

- `peek(ref_or_variable, opts)` for bounded previews;
- `read_slice(ref_or_variable, range)` for explicit slicing;
- `write_artifact(name, data, metadata)` for durable outputs;
- `llm_query(prompt_or_messages, opts)` for simple model calls;
- `rlm_query(context, query, opts)` for recursive subproblems;
- `delegate(role, task, opts)` for RunicAI subagents;
- `checkpoint(label)` for state snapshots;
- `set_final(value)` or `final_result = value` for completion.

### REPL Components

- [x] `RunicAI.RLM.Components.REPL.Start`
      - creates a sandbox session and loads context handles.
- [x] `RunicAI.RLM.Components.REPL.ExecuteTurn`
      - runs one model-authored code block in the sandbox REPL.
- [x] `RunicAI.RLM.Components.REPL.Observe`
      - returns bounded stdout, variable summaries, artifact refs, and errors.
- [x] `RunicAI.RLM.Components.REPL.Subquery`
      - implements `llm_query` with batching, budget, and trace records.
- [x] `RunicAI.RLM.Components.REPL.RecursiveSubquery`
      - implements `rlm_query` by spawning another REPL loop or falling back to
        `llm_query` at max depth.
- [x] `RunicAI.RLM.Components.REPL.Finalize`
      - extracts `final_result`, validates it against the expected schema, and
        emits the answer/artifacts.

### REPL Loop Shape

```text
Start REPL
  -> root model sees objective + environment metadata
  -> model emits code block or structured action
  -> ExecuteTurn in sandbox
  -> Observe bounded state
  -> continue until final_result, budget stop, review stop, or failure
  -> Finalize structured output
```

This is the part that moves RunicAI closer to the paper's RLM idea. The root
model does not need the entire workspace, trace, context, or generated data in
its prompt. It gets handles, summaries, and bounded observations while the
sandbox contains the working state.

The REPL lane should be treated as an escalation strategy, not the default for
every large-context problem. If a task has an obvious split/map/reduce/review
shape, use the Lambda-style lane first. Use the REPL when the model needs to
write exploratory code, inspect unknown data structures, build temporary
indices, or discover a decomposition interactively.

## Generated Code As Runic Components

Sandboxing lets us stop treating arbitrary code as only a diagnostic tool. It
can become a way to synthesize workflow components.

### Component Spec

```elixir
%RunicAI.Sandbox.GeneratedComponent{
  id: "component_parse_invoice_lines",
  language: :python,
  runtime: :python,
  source_ref: "artifact://generated/parse_invoice_lines.py",
  entrypoint: "parse_invoice_lines",
  input_schema: %{type: :object},
  output_schema: %{type: :object},
  sandbox_profile: :local_code,
  policy: %{network: :disabled, filesystem: :sandbox_only},
  tests_ref: "artifact://generated/parse_invoice_lines_test.py",
  verification: %{status: :passed, command_result_ref: "..."}
}
```

### Lifecycle

- [x] Agent proposes a component contract before code.
- [x] Agent writes code and tests into a sandbox session.
- [x] Sandbox runs tests and reports structured diagnostics.
- [x] Agent repairs until tests and contract checks pass.
- [x] Component is either:
      - kept as an ephemeral workflow component;
      - materialized into the host repo behind review;
      - stored as a durable artifact for future sessions.
- [x] Coordinator composes verified generated components into a Runic workflow.

This gives the coordinator a better primitive than "invent a workflow graph in
one shot." It can generate small components, verify them, and compose them.

## Agent And Subagent Extensions

### Standard Agent

- [x] Add `:sandboxed_verify` and `:polyglot_experiment` recipes.
- [x] Add prompt section for sandbox selection.
- [x] Add tests proving `execute_code` is visible only when recipe/profile
      allows it.
- [x] Add repair-loop fixture where bad sandbox code produces diagnostics and
      the agent fixes the code.

### Assistant Agent

- [x] Surface sandbox component catalog in blueprint prompts.
- [x] Allow assistant blueprints to choose `sandbox_execute`,
      `sandbox_repl_turn`, and `sandbox_component_builder`.
- [x] Ensure `tool_leaf` sandbox calls require active capability visibility.
- [x] Add assistant smoke where a generated sandbox component parses a large
      input artifact and writes a structured report.

### Coding RLM Coordinator

- [x] Add a strategy-router stage before workflow proposal:
      - direct standard agent;
      - Lambda-style typed workflow;
      - subagent delegation;
      - generated sandbox component;
      - classic REPL;
      - host-edit workflow.
- [x] Add nested-route assignment contracts so a coordinator can delegate a
      context slice to:
      - a normal standard-agent loop;
      - a role-prompted subagent with constrained tools;
      - a Lambda workflow over a subset of sources;
      - a sandbox REPL with symbolic context variables;
      - a generated component build/verify loop.
- [x] Record router decisions as first-class trace events before any generated
      workflow proposal:
      - selected strategy;
      - fallback strategy;
      - parent strategy and recursion depth;
      - input/context shape;
      - planned call counts;
      - escalation conditions.
- [x] Add Lambda proposal nodes:
      - `lambda_plan`
      - `lambda_split`
      - `lambda_map`
      - `lambda_filter`
      - `lambda_reduce`
      - `lambda_cross`
      - `lambda_review`
      - `lambda_generate`
- [x] Add REPL proposal nodes:
      - `repl_start`
      - `repl_turn`
      - `repl_observe`
      - `repl_subquery`
      - `repl_finalize`
- [x] Add generated component proposal nodes:
      - `component_contract`
      - `component_generate`
      - `component_test`
      - `component_use`
- [x] Prefer Lambda nodes for structured large-context tasks.
- [x] Prefer direct subagent delegation when the coordinator can define a
      narrow role, context slice, output contract, and review step without
      needing new generated workflow code.
- [x] Prefer REPL/component nodes for broad ambiguous tasks instead of direct
      script/edit/gate plans.
- [x] Prefer subagent delegation when slices require separate prompts, tools,
      or review roles.
- [x] Let REPL turns call `delegate`, `llm_query`, or `rlm_query` only through
      mediated RunicAI functions that enforce budgets and trace subcalls.
- [x] Let workflow nodes launch constrained agents through the same assignment
      contract instead of requiring the root model to generate bespoke
      coordination code.
- [x] Preserve the current OODA loop as coordinator policy, not as the sole
      execution model.

### Subagents

Add role presets that receive narrow sandbox capability subsets:

- [x] `sandbox_runner`
      - can run `execute_code`, read sandbox outputs, and report diagnostics;
      - cannot patch host files.
- [x] `component_builder`
      - can create and test sandbox-backed components;
      - can propose host materialization behind review.
- [x] `service_smoke_agent`
      - can start sandbox services, open proxies, smoke endpoints, and collect
        logs;
      - all proxy/network activity gated.
- [x] `sandbox_reviewer`
      - inspects code, diagnostics, artifacts, checkpoints, and policy metadata
        before promotion.
- [x] `recursive_researcher`
      - uses REPL context slicing plus `llm_query`/`rlm_query` for large
        document or codebase reasoning.

## Review, Policy, And Observability

### Review Gates

- [x] Auto-allow `sandbox_status`.
- [x] Allow `execute_code` without HITL only for configured low-risk profiles:
      ephemeral workspace, network disabled, approved runtime, output cap,
      timeout cap.
- [x] Require review for:
      - host networking;
      - restricted-but-external networking;
      - persistent workspace mutation;
      - service/proxy creation;
      - checkpoint restore over existing state;
      - secret injection;
      - host materialization of sandbox artifacts;
      - generated component promotion into the repo.

### Trace Events

- [x] Add lifecycle events:
      - `sandbox_session_opened`
      - `sandbox_session_closed`
      - `sandbox_checkpoint_created`
      - `sandbox_restored`
      - `sandbox_service_started`
      - `sandbox_proxy_opened`
      - `repl_turn_started`
      - `repl_turn_completed`
      - `repl_subquery_started`
      - `repl_subquery_completed`
      - `generated_component_verified`
- [x] Store bounded summaries in normal traces.
- [x] Store full stdout/files only as artifacts under capture policy.
- [x] Include capability profile snapshots in run metadata.

### Workbench

- [x] Add visible sandbox capability summary to agent launch settings.
- [x] Add recipe presets for sandboxed verify and stateful sandbox workspace.
- [x] Render sandbox sessions, checkpoints, services, proxies, and artifacts in
      the run detail view.
- [x] Show REPL variables and observations as structured state, not chat text.
- [x] Make artifact promotion an explicit review action.



### Phase 0: Exposure Baseline

Goal: document and test what is already exposed.

- [x] Add focused tests for current `execute_code` visibility under:
      - default verify recipe;
      - `profile: :local_workbench`;
      - `toolsets: [:code_execution]`;
      - disabled tool override.
- [x] Add a capability snapshot test showing sandbox metadata in visible tools.
- [x] Add a Workbench configuration smoke for `code_execution.enabled`.
- [x] Update docs or ExDoc for `execute_code` and `sandbox_status`.

Evidence:

- `test/runic_ai/coding/standard_agent_test.exs` covers default verify hiding
  `execute_code`/`sandbox_status` and explicit local-workbench
  `:code_execution` exposure.
- `test/runic_ai/agent/capability_resolver_test.exs` covers explicit
  `:code_execution`, feature-flag enablement, disabling `execute_code`, review
  metadata, and sandbox backend/runtime/state metadata snapshots.
- `test/runic_ai/workbench_test.exs` covers browser launch persistence of
  `code_execution.enabled`, sandbox backend/runtime/network/stateful/pool
  config, and visible `execute_code`/`sandbox_status` capability metadata.
- `lib/runic_ai/coding/tools.ex` module docs now describe `execute_code/4` and
  `sandbox_status/2` as explicit capability/recipe-gated sandbox tools.
- Validation on 2026-05-25:
  `mix test test/runic_ai/coding/standard_agent_test.exs test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/workbench_test.exs`
  -> 54 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/coding/tools_test.exs` -> 26 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `git diff --check` passed for the touched Phase 0
  files.

Parallelizable: yes. One agent can test standard-agent visibility while another
tests Workbench/capability snapshots.

### Phase 1: Recipes And Prompting

Goal: make stateless sandbox execution intentionally usable.

- [x] Add `:sandboxed_verify`.
- [x] Add `:polyglot_experiment`.
- [x] Add prompt sandbox guidance.
- [x] Add tests that recipe prompts include sandbox profile summaries.
- [x] Add fake-LLM standard-agent tests where the model chooses `execute_code`
      for generated code and `run_command` for project commands.
- [x] Manual smoke: run standard agent with sandboxed recipe against a small
      Python/Node/Elixir snippet task.

Evidence:

- `lib/runic_ai/coding/recipe.ex` adds explicit `:sandboxed_verify` and
  `:polyglot_experiment` recipes. Default `:verify` still does not expose
  `execute_code` or `sandbox_status`.
- `lib/runic_ai/coding/recipe_registry.ex` exposes `/sandboxed-verify` and
  `/polyglot-experiment`.
- `lib/runic_ai/coding/prompt.ex` emits sandbox guidance only when
  `execute_code` or `sandbox_status` is visible, including backend, runtimes,
  network, statefulness, workspace, and review summary.
- `test/runic_ai/coding/standard_agent_test.exs` covers recipe visibility,
  sandbox profile prompt summary, `execute_code` selection through
  `:sandboxed_verify`, and `run_command` selection through the explicit
  local-workbench capability profile.
- `test/runic_ai/coding/standard_agent_remaining_test.exs` covers the named
  recipe registry additions.
- Validation on 2026-05-25:
  `mix test test/runic_ai/coding/standard_agent_test.exs test/runic_ai/coding/standard_agent_remaining_test.exs`
  -> 33 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/workbench_test.exs test/runic_ai/coding/tools_test.exs`
  -> 66 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Manual smoke on 2026-05-25:
  `MIX_ENV=test mix run -e '<standard agent sandboxed_verify Python Docker smoke>'`
  used `runic-ai/sandbox:elixir-python-node` and returned
  `%{reply: "python sandbox smoke complete", tools_used: ["execute_code"],
  sandbox_visible?: true}`.
- Full validation on 2026-05-25: `mix test` ran 813 tests with 2 failures and
  2 skipped. Reproduced failures:
  `test/runic_ai/coding/rlm_objective_loop_test.exs:1091` returned
  `implementation_result.decision.action == :stop_failed`; and
  `test/runic_ai/rlm/robustness_test.exs:141` returned deterministic status
  affected by optional OpsLogic smoke checks skipped by unset
  `RUN_OPSLOGIC_POSTGRES_SMOKE` and `RUN_OPSLOGIC_BROWSER_SMOKE`. These are
  outside the Phase 1 recipe/prompt surface but keep whole-repo validation
  incomplete.

Parallelizable: partially. Prompt and recipe changes should be owned by one
agent; tests can be added by another after the shape lands.

### Phase 2: Runic Sandbox Component Catalog

Goal: expose sandboxing as components, not only tools.

- [x] Add stateless `Status` and `Execute` component catalog/runtime entries.
- [x] Add `ArtifactMaterializer` component.
- [x] Add stateful session/file/checkpoint components.
- [x] Add service/proxy components behind capability checks.
- [x] Add component catalog entries for assistant/RLM prompts.
- [x] Add component runtime dispatch tests.
- [x] Manual smoke: assistant blueprint uses `sandbox_execute` to transform an
      artifact and write a report.

Evidence:

- `lib/runic_ai/rlm/component_catalog.ex` now exposes `:sandbox_status` and
  `:sandbox_execute` as side-effect components with normal `:tool_result`
  contracts, and `:artifact_materializer` as a read-only
  `:materialized_slices` component.
- `lib/runic_ai/rlm/components/artifact_materializer.ex` materializes
  persisted artifact refs and inline sandbox artifact previews with byte/count
  caps, without writing to the host workspace.
- `lib/runic_ai/assistant/rlm/component_blueprint.ex` accepts both stateless
  sandbox component types and `:artifact_materializer` through the shared
  component type list.
- `lib/runic_ai/assistant/rlm/blueprint_validator.ex` rejects sandbox
  components when the active capability profile does not expose
  `sandbox_status` or `execute_code`.
- `lib/runic_ai/rlm/component_runtime.ex` dispatches both components through
  `RunicAI.Agent.ToolExecution`, preserving capability visibility and review
  behavior instead of bypassing the tool substrate.
- `test/runic_ai/assistant/rlm_blueprint_test.exs` covers capability-profile
  validation and reviewed `sandbox_execute` runtime execution.
- `test/runic_ai/assistant/rlm_blueprint_graph_test.exs` continues to cover the
  catalog manifest and Runic component compilation for every component type.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs`
  -> 31 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_components_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs`
  -> 53 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs`
  -> 39 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_components_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs`
  -> 92 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `git diff --check` passed for the current
  worktree.
- Manual smoke on 2026-05-25:
  `MIX_ENV=test mix run -e '<assistant sandbox_execute -> report_composer -> artifact_writer smoke>'`
  returned
  `%{status: :written, path: "reports/sandbox-component-smoke.md", contains_alpha?: true}`.
- Statefulness review on 2026-05-25: `RunicSandbox` already exposes
  `open_session`, `exec(session, ...)`, file IO, checkpoint/restore, services,
  proxies, and leases. The next RunicAI slice should add model-visible
  stateful sandbox tools plus review request metadata first, then expose
  equivalent assistant/RLM components through that same boundary. Implementing
  session/file/checkpoint components directly in `ComponentRuntime` would
  bypass the tool/review contract that Phase 0 and Phase 1 established.
- `lib/runic_ai/coding/sandbox_session_registry.ex` now owns signed
  `RunicSandbox.Session` handles in a long-lived process and exposes opaque
  model-visible session ids for later tool calls.
- `lib/runic_ai/coding/tools.ex` now registers stateful sandbox tools when a
  sandbox session registry is available: `open_sandbox_session`,
  `sandbox_exec`, `sandbox_write_file`, `sandbox_read_file`,
  `sandbox_list_files`, `checkpoint_sandbox`, `restore_sandbox`, and
  `close_sandbox_session`.
- `lib/runic_ai/agent/tool_execution.ex` adds review metadata for mutating
  stateful sandbox tools, including session id, path, checkpoint ref, code
  preview, network, and sandbox capability snapshot.
- `lib/runic_ai/coding/review_gate.ex` treats stateful sandbox mutation,
  execution, checkpoint, and restore operations as reviewed coding actions,
  while allowing bounded read/list/close operations.
- `lib/runic_ai/application.ex` supervises a default
  `RunicAI.Coding.SandboxSessionRegistry` for Workbench/runtime use.
- `lib/runic_ai/rlm/component_catalog.ex`,
  `lib/runic_ai/assistant/rlm/component_blueprint.ex`,
  `lib/runic_ai/assistant/rlm/blueprint_validator.ex`, and
  `lib/runic_ai/rlm/component_runtime.ex` expose stateful sandbox assistant/RLM
  components that dispatch through the model-visible tool boundary:
  `:sandbox_open_session`, `:sandbox_session_exec`, `:sandbox_write_file`,
  `:sandbox_read_file`, `:sandbox_list_files`, `:sandbox_checkpoint`,
  `:sandbox_restore`, and `:sandbox_close_session`.
- The same component/tool boundary now exposes service and proxy lifecycle
  operations: `start_sandbox_service`, `stop_sandbox_service`,
  `list_sandbox_services`, `open_sandbox_proxy`, `close_sandbox_proxy`, and
  assistant/RLM component types `:sandbox_start_service`,
  `:sandbox_stop_service`, `:sandbox_list_services`, `:sandbox_open_proxy`,
  and `:sandbox_close_proxy`.
- `test/runic_ai/coding/tools_test.exs` covers opening a managed sandbox
  session, executing code in it, closing it, and rejecting stale session ids.
- `test/runic_ai/agent/capability_resolver_test.exs` covers visibility,
  gating, and review metadata for stateful sandbox tools and service/proxy
  tools under the `:code_execution` toolset.
- `test/runic_ai/assistant/rlm_blueprint_test.exs` covers stateful sandbox
  component validation, service/proxy component validation, and reviewed
  component runtime execution through open -> exec -> close.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/agent/capability_resolver_test.exs`
  -> 73 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_components_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/agent/capability_resolver_test.exs`
  -> 95 tests, 0 failures.
- Validation on 2026-05-25 after service/proxy exposure:
  `mix test test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs`
  -> 73 tests, 0 failures.
- Validation on 2026-05-25 after service/proxy exposure:
  `mix test test/runic_ai/assistant/rlm_components_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/agent/capability_resolver_test.exs`
  -> 95 tests, 0 failures.
- Manual smoke on 2026-05-25:
  `MIX_ENV=test mix run -e '<assistant sandbox_open_session -> sandbox_session_exec -> sandbox_close_session smoke>'`
  returned
  `%{output: %{id: "sandbox_session_...", status: :closed}, exec_stdout: "stateful-component\n"}`.

Parallelizable: yes, by component family. Keep shared contract structs in one
small PR first.

### Phase 3: Strategy Router And Lambda Components

Goal: make large-context decomposition explicit and less brittle before adding
open-ended REPL power.

- [x] Add a coordinator strategy-router module with rule-based routing.
- [x] Emit router decision metadata: selected strategy, confidence, budget, and
      fallback.
- [x] Add router fixtures for:
      - known split/map/reduce/report tasks -> Lambda-style workflow;
      - file/topic/role partition tasks -> subagent delegation;
      - unknown artifact exploration -> sandbox REPL;
      - repeated parser/analyzer/scorer tasks -> generated sandbox component;
      - narrow project mutation tasks -> direct standard-agent or host-edit
        workflow.
- [x] Keep model-assisted routing optional and schema-validated; the first
      router should be deterministic enough to debug.
- [x] Add Lambda plan data structures and validation.
- [x] Add explicit Lambda objective/input-shape detection fields:
      task type, source kind, decomposition reason, optional model classifier
      result, and deterministic fallback reason.
- [x] Add Lambda component catalog entries for split/map/filter/reduce/cross/
      review/generate.
- [x] Reuse existing generic RLM components where possible before adding new
      modules.
- [x] Add context-slice contracts that preserve provenance, token/byte bounds,
      expected output schema, and merge/review policy.
- [x] Add plan estimates before execution:
      leaf calls, review calls, reduce calls, max depth, max concurrency,
      expected sandbox executions, and escalation fallback.
- [x] Add tests for planned versus actual call counts on a deterministic
      fixture.
- [x] Manual smoke: run a large-context summarize/extract/report task through a
      Lambda-style workflow without asking the model to invent a graph.

Evidence:

- `lib/runic_ai/rlm/strategy_router.ex` adds a deterministic, inspectable
  router that returns selected strategy, confidence, fallback strategy,
  reasons, budgets, and trace-friendly metadata.
- The first router keeps model-assisted routing disabled and records
  `deterministic?: true` / `model_assisted?: false` so future evaluation can
  compare deterministic and model-classified routing.
- Research update on 2026-05-25 after reviewing Lambda-RLM and "Recursive by
  Design": Phase 3 should prioritize typed Lambda plan contracts before open
  REPL execution. The practical target is a Runic-native equivalent of
  "structure decides decomposition": detect input shape, compute fan-out,
  budgets, depth, and operator sequence up front, then run bounded leaf model
  calls or sandbox computations through existing components.
- `lib/runic_ai/rlm/lambda_plan.ex` adds `RunicAI.RLM.LambdaPlan`, a validated
  Lambda-style plan envelope that records objective, task kind, source refs,
  operator sequence, context contracts, policy, cost estimate, detection
  metadata, budgets, estimates, fallback strategy, and the underlying
  deterministic `RunicAI.RLM.Plan`.
- `lib/runic_ai/rlm/context_slice_contract.ex` adds
  `RunicAI.RLM.ContextSliceContract`, preserving external source refs,
  provenance, source kind, token/byte bounds, expected output schema,
  merge policy, review policy, and metadata without copying context into the
  root prompt.
- `RunicAI.RLM.lambda_plan/4` now builds a Lambda plan through the existing
  deterministic planner, so this phase reuses `Plan`, `PlanNode`, `Policy`,
  `CostEstimate`, and `EnvironmentRef` instead of creating a parallel planning
  substrate.
- The Lambda contract normalizes known string values for operators,
  source kinds, and fallback strategies through fixed allowlists, avoiding
  `String.to_atom/1` on model or JSON-shaped input.
- `test/runic_ai/rlm/planning_test.exs` covers Lambda plan wrapping,
  pre-execution estimates, default detection metadata, context-slice contracts,
  string-key normalization, and invalid operator/budget rejection.
- `lib/runic_ai/rlm/component_catalog.ex`,
  `lib/runic_ai/assistant/rlm/component_blueprint.ex`, and
  `lib/runic_ai/rlm/value_contract.ex` now expose Lambda component catalog
  entries for `:lambda_plan`, `:lambda_split`, `:lambda_map`,
  `:lambda_filter`, `:lambda_reduce`, `:lambda_cross`, `:lambda_review`, and
  `:lambda_generate`.
- The Lambda catalog entries intentionally reuse existing value contracts and
  execution shapes: planning emits `:lambda_plan`, splitting uses
  `:source_slices`, leaf work uses map-shaped `:llm_items`, reductions use the
  existing reduce shape, review emits `:scorecard`, and generation emits
  `:report`. No bespoke runtime modules were added in this slice.
- `RunicAI.RLM.LambdaPlan.call_accounting/2` compares planned leaf/reduce/
  review/sandbox execution estimates with actual metrics, returning planned
  counts, actual counts, deltas, and `matched?`.
- `lib/runic_ai/rlm/workflow_metrics.ex` now has metric slots for
  `lambda_map_calls`, `lambda_reduce_calls`, and `lambda_review_calls`, so
  future Lambda runtime execution can report actual call counts through the
  same metrics surface.
- `lib/runic_ai/rlm/component_runtime.ex` now aliases Lambda runtime nodes to
  the existing generic component modules where that boundary is clean:
  `:lambda_split` -> `SourceSplitter`, `:lambda_map` -> `LLMMap`,
  `:lambda_reduce` -> `HierarchicalReduce`, `:lambda_cross` ->
  `DocumentCompare`, `:lambda_review` -> `ObjectiveScorecard`, and
  `:lambda_generate` -> `ReportComposer`.
- `lib/runic_ai/assistant/rlm/blueprint_graph.ex` accepts `:lambda_split` as a
  valid parent for `:source_materializer`, preserving the same materialization
  guard while allowing Lambda-shaped source splitting.
- `test/runic_ai/assistant/rlm_blueprint_graph_test.exs` includes a manual
  integration-style smoke where a static Lambda-shaped workflow runs
  `lambda_split -> source_materializer -> lambda_map -> lambda_reduce ->
  lambda_generate` against a real workspace file with a fake LLM client,
  produces a report, records Lambda map/reduce metrics, and verifies
  `LambdaPlan.call_accounting/2`.
- `test/runic_ai/rlm/strategy_router_test.exs` covers the planned router
  fixtures:
  Lambda-style workflow for known large-context extraction/reporting;
  subagent delegation for partitionable file-group investigations; sandbox REPL
  for unknown exploratory artifacts; generated sandbox component for repeated
  parsers/scorers; and host/direct lanes for narrow local tasks.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/strategy_router_test.exs` -> 6 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/agent/capability_resolver_test.exs`
  -> 79 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/planning_test.exs` -> 7 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs`
  -> 13 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs`
  -> 30 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_graph_test.exs` -> 17 tests,
  0 failures.
- Validation on 2026-05-25 after Lambda runtime aliases:
  `mix test test/runic_ai/assistant/rlm_blueprint_graph_test.exs` -> 18 tests,
  0 failures.
- Validation on 2026-05-25 after Lambda runtime aliases:
  `mix test test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs`
  -> 31 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `git diff --check` passed for the current
  worktree.

Parallelizable: partially. Router and plan structs should land first. Component
catalog/test work can be split after that.

### Phase 4: Persistent Sandbox REPL

Goal: add the RLM-inspired environment.

- [x] Define `RunicAI.RLM.REPL.State`.
- [x] Define REPL environment functions: `peek`, `read_slice`,
      `write_artifact`, `llm_query`, `rlm_query`, `delegate`, `checkpoint`,
      `set_final`.
- [x] Implement Python REPL first on top of `RunicSandbox.Session`.
- [x] Keep Elixir and Node REPLs as follow-up runtimes unless a task needs them
      earlier.
- [x] Add budget and batching controls for `llm_query` and `rlm_query`.
- [x] Add bounded observation summaries.
- [x] Add final-result schema validation.
- [x] Manual smoke: answer a question over a large local text artifact by
      chunking inside the sandbox REPL and aggregating subquery results.

Evidence:

- `lib/runic_ai/rlm/repl/state.ex` adds `RunicAI.RLM.REPL.State`, a validated
  state contract carrying opaque sandbox session id, runtime, context ref,
  variables, bounded observations, budgets, mediated environment functions,
  checkpoints, final result, and metadata.
- `lib/runic_ai/rlm/repl/environment_function.ex` adds
  `RunicAI.RLM.REPL.EnvironmentFunction` descriptors for the mediated REPL
  functions: `peek`, `read_slice`, `write_artifact`, `llm_query`, `rlm_query`,
  `delegate`, `checkpoint`, and `set_final`.
- The REPL contract keeps signed sandbox authority out of model-visible state:
  it stores the opaque session id managed by `SandboxSessionRegistry`, not a
  `RunicSandbox.Session` handle.
- The REPL function descriptors normalize known string kinds through fixed
  allowlists and avoid `String.to_atom/1` on model/JSON-shaped input.
- `test/runic_ai/rlm/repl_state_test.exs` covers default function descriptors,
  runtime normalization, variables, observations, checkpoints, final result,
  and invalid runtime/function-kind rejection.
- `lib/runic_ai/rlm/repl/python_runtime.ex` adds the first executable REPL
  runtime. It executes one Python turn through `SandboxSessionRegistry.exec/4`,
  injects mediated environment stubs, parses a structured
  `__RUNIC_REPL_FINAL__` marker, records bounded stdout/stderr observations,
  and validates optional final-result schemas.
- `read_slice` now works over RunicAI-injected REPL variables inside the Python
  turn. This lets sandbox code chunk large context variables without arbitrary
  host filesystem access. It supports integer offset/length calls and
  map-shaped ranges with `offset`/`start`, `length`, or `end`.
- Elixir and Node REPL runtimes remain intentionally unimplemented in this
  phase; the runtime dispatch currently rejects non-Python REPL states.
- `RunicAI.RLM.REPL.State.consume_budget/3`,
  `RunicAI.RLM.REPL.State.validate_batch/3`, and
  `RunicAI.RLM.REPL.State.budget_status/2` add query-budget and batch-size
  controls for future mediated `llm_query` and `rlm_query` calls.
- `test/support/repl_fake_sandbox_registry.ex` provides a focused managed
  sandbox registry double for REPL runtime tests without exposing raw sandbox
  handles.
- `test/runic_ai/rlm/repl_state_test.exs` covers one Python turn, bounded
  observation summaries, final-result schema rejection, and llm/rlm budget and
  batch-size enforcement.
- `test/runic_ai/rlm/repl_state_test.exs` also covers `read_slice` over an
  injected context variable and executes the generated Python wrapper with the
  local Python interpreter when one is available.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/repl_state_test.exs` -> 7 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/repl_state_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs`
  -> 38 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `git diff --check` passed for the current
  worktree.
- Full-suite validation on 2026-05-25:
  `mix test` -> 836 tests, 2 failures, 2 skipped. The remaining failures are
  the pre-existing OpsLogic objective-loop/optional-smoke failures:
  `test/runic_ai/coding/rlm_objective_loop_test.exs:1091` and
  `test/runic_ai/rlm/robustness_test.exs:141`.
- Full-suite validation also found two regressions during this phase and both
  were fixed: `SandboxSessionRegistry.close_session/3` now handles stale
  sandbox authority as an idempotent close instead of crashing, and streaming
  command execution now lets the port collector own timeout handling so partial
  output is preserved under load.
- Regression validation on 2026-05-25:
  `mix test test/runic_ai/coding/command_test.exs:69 test/runic_ai/assistant/rlm_blueprint_test.exs:279`
  -> 2 tests, 0 failures.
- Manual Python Docker smoke on 2026-05-25:
  `MIX_ENV=test mix run -e '<open docker sandbox session -> PythonRuntime.execute_turn -> close session>'`
  used `runic-ai/sandbox:elixir-python-node` and returned
  `%{final: %{"answer" => %{"alpha" => 2, "beta" => 1, "gamma" => 1}, "summary" => "counted local text"}, session_backend: :docker}`.
  This proved the Python REPL turn works against a real sandbox session before
  the larger chunking smoke was added.
- Manual large-artifact Docker smoke on 2026-05-25:
  `MIX_ENV=test mix run -e '<open docker sandbox session -> inject 240-section text context -> PythonRuntime.execute_turn with read_slice chunking -> close session>'`
  used `runic-ai/sandbox:elixir-python-node` and returned
  `%{backend: :docker, session_status: :closed, final: %{"answer" => %{"chunk_count" => 26, "control_mentions" => 12, "risk_mentions" => 13}, "subquery_results" => [...]}, observation: %{status: :pass, exit_status: 0, isolation_level: :container, truncated?: false}}`.
  This closes the Phase 4 manual smoke for sandbox-local chunking and
  aggregation over a large injected context artifact. The next REPL gap is
  still true mediated `llm_query`/`rlm_query` callbacks from sandbox code.

Parallelizable: partially. State/contracts and Python runtime should be
serialized. Observation rendering, budget tests, and prompt integration can be
parallelized.

### Phase 5: Subagent Delegation Workflows

Goal: make delegation a first-class coordinator strategy instead of only an
escape hatch.

- [x] Define subagent assignment specs with role, prompt, tools, context slice,
      budget, and expected output schema.
- [x] Add nested routing metadata: parent run id, parent strategy, depth,
      remaining budgets, and fallback strategy.
- [x] Add context slicers for file sets, repo areas, document sections,
      artifact partitions, and review roles.
- [x] Add map-style delegation over context slices.
- [x] Add reduce/review steps for subagent outputs.
- [x] Add a standard-agent delegation adapter that can run existing agent loops
      with a specialized prompt and constrained visible tools.
- [x] Add a workflow delegation adapter that can launch a Lambda workflow or
      generated-component build for a context slice.
- [x] Add a REPL delegation adapter only after the parent assignment has an
      explicit symbolic context handle, depth limit, and subquery budget.
- [x] Add conflict and confidence metadata so reducers can distinguish
      agreement, disagreement, missing evidence, and unsupported claims.
- [x] Add tests where separate subagents inspect different file groups and a
      reviewer reconciles conflicts.
- [x] Manual smoke: coordinator partitions a codebase investigation into
      focused standard-agent loops and reduces the result.

Evidence:

- `lib/runic_ai/rlm/subagent_assignment.ex` adds
  `RunicAI.RLM.SubagentAssignment`, a data-only delegation contract for
  constrained nested work. It captures role, objective, optional prompt,
  selected strategy, agent kind, context slice, capability profile, visible
  tools, budgets, output schema, review policy, parent metadata, and freeform
  metadata.
- The assignment contract normalizes strategy and agent-kind strings through
  fixed allowlists, avoiding `String.to_atom/1` on model/JSON-shaped input.
- Parent metadata records `run_id`, parent `strategy`, recursion `depth`,
  `fallback`, and `remaining_budgets` so nested delegation can remain
  parent-budgeted and traceable.
- The contract accepts existing `RunicAI.RLM.ContextSliceContract` values,
  preserving source refs, provenance, byte/token bounds, and review/merge
  policy rather than copying broad context into child prompts.
- `test/runic_ai/rlm/subagent_assignment_test.exs` covers constrained
  assignments with context slices, visible tools, budgets, output schemas,
  review policy, parent strategy/depth/fallback metadata, default workflow
  agent kind for Lambda assignments, and invalid strategy/tool/budget/depth
  rejection.
- `lib/runic_ai/rlm/context_slicer.ex` adds `RunicAI.RLM.ContextSlicer`, a
  planning helper that creates assignment-ready `ContextSliceContract` values
  for file sets, repo areas, document sections, artifact partitions, and review
  roles.
- The context slicer reuses `RunicAI.RLM.Components.SourceSplitter` for
  workspace files/directories and records provenance, line spans, source ids,
  byte budgets, source family, and optional bounded previews without copying
  full source text into the root coordinator prompt.
- Review-role slicing creates structured role-specific slices over existing
  context contracts, preserving the original source slice in provenance while
  attaching role review policy and expected output schema.
- `test/runic_ai/rlm/context_slicer_test.exs` covers file-set contracts, repo
  area directory expansion, markdown document-section slicing, artifact
  grouping by kind, review-role fan-out over source slices, and direct use of a
  review-role slice in `RunicAI.RLM.SubagentAssignment`. It also verifies that
  invalid slicer contract options return `RunicAI.Error` values instead of
  raising out of the planning boundary.
- `lib/runic_ai/rlm/delegation_mapper.ex` adds
  `RunicAI.RLM.DelegationMapper`, a map-style planning helper that fans out
  validated context slices into constrained `SubagentAssignment` values. It
  renders objective/prompt templates with slice id, slice index, source kind,
  source ref, and review role placeholders while preserving parent metadata,
  capability profile, visible tools, budgets, output schema, and review policy.
- `test/runic_ai/rlm/delegation_mapper_test.exs` covers assignment fan-out
  over file context slices, review-role metadata becoming the assignment role,
  context budgets carrying through into assignment budgets, template rendering,
  and invalid required template/strategy rejection.
- `lib/runic_ai/rlm/subagent_reducer.ex` adds
  `RunicAI.RLM.SubagentReducer`, a reducer/reviewer for claim-shaped subagent
  outputs. It normalizes child `RunicAI.Decomposition.Result` values, extracts
  claims, records evidence refs, confidence, role, source slice id,
  missing-info flags, unsupported flags, explicit conflicts, agreement groups,
  incomplete child results, and aggregate confidence metadata.
- The reducer returns `:accepted`, `:review`, or `:failed` status so the parent
  coordinator can distinguish clean agreement from conflicts, missing evidence,
  unsupported claims, low-confidence outputs, cancelled children, and failed
  children before synthesis or materialization.
- `test/runic_ai/rlm/subagent_reducer_test.exs` covers supported agreement,
  confidence aggregation, explicit conflict detection, unsupported claims,
  missing-info claims, role/source-slice propagation, incomplete/cancelled child
  tracking, failed child status, and invalid child result rejection.
- `lib/runic_ai/rlm/delegation_adapters/standard_agent.ex` adds a standard
  delegation adapter that executes `SubagentAssignment` values through the
  existing `RunicAI.Coding.Tools.delegate_task/4` boundary. The adapter passes
  objective, profile, visible tools, output schema, review policy, parent
  routing metadata, and context-slice metadata to the child runner, then
  normalizes the delegate response into a `RunicAI.Decomposition.Result` with
  claim-shaped output for the reducer.
- The default adapter runner can invoke the existing standard coding agent with
  read-only mode and constrained visible tools; tests inject a runner to avoid
  live LLM calls while still exercising the delegate boundary.
- `test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs` covers
  constrained standard-agent delegation args, profile/tool propagation,
  parent/context metadata propagation, conversion to reducer-compatible child
  results, reducer acceptance of the child result, failed delegate status
  propagation, and rejection of non-standard assignment kinds.
- The standard-agent delegation path now preserves structured `claims` returned
  by delegated runners through `RunicAI.Coding.Tools.delegate_task/4`, while
  still retaining the previous summary/source-ref fallback. Delegate args also
  include context-slice metadata so child runners can make decisions from the
  assigned slice without broadening their prompt context.
- `lib/runic_ai/rlm/delegation_adapters/workflow.ex` adds a workflow
  delegation adapter for `SubagentAssignment` values with `:lambda_workflow`
  and `:generated_sandbox_component` strategies. Lambda assignments are
  converted into validated `RunicAI.RLM.LambdaPlan` values over the assignment
  context slice, while generated-component assignments run through either an
  injected workflow runner or a supplied assistant/RLM workflow blueprint.
- The workflow adapter passes constrained workspace, context slice,
  capability profile, visible tools, budgets, parent metadata, and adapter
  opts to injected runners. It normalizes workflow outputs into
  `RunicAI.Decomposition.Result` child results with claim-shaped output so the
  existing subagent reducer can review workflow, agent, and generated-component
  children through one result contract.
- Lambda workflow assignment fallback metadata is sanitized before it is passed
  into `LambdaPlan`: router strategies that are valid assignment fallbacks but
  invalid Lambda fallback strategies fall back to `:subagent_delegation`
  instead of causing an avoidable planning failure.
- `test/runic_ai/rlm/workflow_delegation_adapter_test.exs` covers Lambda
  assignment conversion into a validated plan, operator metadata propagation,
  reducer-compatible child results, generated-component execution through an
  injected runner, constrained runner context propagation, invalid non-workflow
  rejection, and missing runner/blueprint validation errors.
- `lib/runic_ai/rlm/delegation_adapters/repl.ex` adds a gated REPL delegation
  adapter for `:sandbox_repl` workflow assignments. It requires an existing
  sandbox session id, explicit symbolic context handle, recursion depth limit,
  recursive subquery budget, sandbox-session registry, and code body before it
  will call the Python REPL runtime.
- The REPL adapter creates or validates `RunicAI.RLM.REPL.State`, carries the
  assignment context slice under the symbolic handle, records REPL budgets,
  enforces parent depth below the declared limit, and rejects supplied REPL
  state whose sandbox session or context handle does not match the assignment
  gates.
- REPL turn outputs are normalized into `RunicAI.Decomposition.Result` child
  results with claim-shaped output. Successful sandbox observations become
  completed child results; non-zero/error observations become failed child
  results with the bounded observation in metadata for reducer/reviewer use.
- `test/runic_ai/rlm/repl_delegation_adapter_test.exs` covers gated Python
  runtime execution through the fake sandbox-session registry, symbolic
  context propagation into runtime source, reducer-compatible final-result
  claims, missing symbolic-context gate rejection, depth-limit rejection, and
  failed sandbox-turn child-result propagation.
- `lib/runic_ai/rlm/repl/python_runtime.ex` now preserves JSON `null` for
  `nil` variable values instead of serializing them as the string `"nil"`,
  which keeps sandbox-visible context variables closer to their structured
  RunicAI contract shape.
- `test/runic_ai/rlm/subagent_delegation_workflow_test.exs` covers the Phase 5
  map-run-reduce path across separate file slices: context slicing, assignment
  mapping, constrained standard-agent delegation, structured claim propagation,
  reducer conflict detection, role propagation, and source-slice provenance.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/subagent_assignment_test.exs` -> 3 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/context_slicer_test.exs` -> 6 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/delegation_mapper_test.exs` -> 3 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/subagent_reducer_test.exs` -> 4 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs` ->
  3 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/workflow_delegation_adapter_test.exs` -> 4
  tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/repl_delegation_adapter_test.exs` -> 4 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/repl_delegation_adapter_test.exs test/runic_ai/rlm/repl_state_test.exs`
  -> 11 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/subagent_delegation_workflow_test.exs` -> 1
  test, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/subagent_delegation_workflow_test.exs test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs test/runic_ai/coding/tools_test.exs`
  -> 31 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/subagent_delegation_workflow_test.exs test/runic_ai/rlm/repl_delegation_adapter_test.exs test/runic_ai/rlm/workflow_delegation_adapter_test.exs test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs test/runic_ai/rlm/subagent_reducer_test.exs test/runic_ai/rlm/delegation_mapper_test.exs test/runic_ai/rlm/context_slicer_test.exs test/runic_ai/rlm/subagent_assignment_test.exs test/runic_ai/rlm/repl_state_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/coding/tools_test.exs`
  -> 93 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `git diff --check` passed for the current
  worktree.
- Manual smoke on 2026-05-25:
  `mix run -e '<create temp workspace -> ContextSlicer.file_set(["lib/api.ex", "lib/worker.ex"]) -> DelegationMapper.map_slices -> StandardAgent.run with constrained fake runner -> SubagentReducer.reduce>'`
  returned `%{assignments: 2, reducer_status: :review, summary: %{claim_count: 2, conflict_count: 1, unsupported_count: 0, incomplete_count: 0}, conflicts: [%{claim_id: "api-sync", target_claim_id: "worker-async"}]}`.
  This closes the Phase 5 manual smoke for partitioned codebase investigation
  using focused standard-agent delegation and reducer reconciliation.

Parallelizable: yes after assignment/output contracts are stable.

### Phase 6: Generated Component Builder

Goal: let agents synthesize code into verified workflow components.

- [x] Define `RunicAI.Sandbox.GeneratedComponent`.
- [x] Add component contract proposal prompt.
- [x] Add sandbox writer/tester/repair loop for generated code.
- [x] Add output parsing and schema validation.
- [x] Add artifact promotion policy.
- [x] Add coordinator support for composing generated components into workflows.
- [x] Manual smoke: generate a CSV/JSON parser component, test it in sandbox,
      then use it in a Runic workflow.

Parallelizable: yes after the generated component struct and verification
contract land.

Evidence:

- `lib/runic_ai/sandbox/generated_component.ex` adds
  `RunicAI.Sandbox.GeneratedComponent`, a backend-neutral contract for code
  generated and verified inside a sandbox. It records id, name, language,
  runtime, entrypoint, capability/sandbox profiles, source artifacts, test
  artifacts, value interface, verification evidence, promotion status,
  provenance, metadata, and optional assistant/RLM component blueprint wrapper
  metadata.
- The generated-component contract uses fixed allowlists for language and
  promotion status, normalizes string inputs without `String.to_atom/1`, and
  keeps promotion separate from generation: a component is promotable only
  after passing verification and retaining source artifacts.
- `GeneratedComponent.to_component_blueprint/2` wraps promotable components as
  `:sandbox_execute` assistant component blueprints with generated-component
  metadata and source/test artifact refs, giving later phases a concrete bridge
  from sandbox-created code into Runic workflows.
- `test/runic_ai/sandbox/generated_component_test.exs` covers string-input
  normalization, verification/promotability checks, blueprint wrapping,
  rejection before verification/source artifacts exist, and invalid enum or
  artifact shapes.
- `lib/runic_ai/sandbox/generated_component_proposal_prompt.ex` adds
  `RunicAI.Sandbox.GeneratedComponentProposalPrompt`, a contract-only prompt
  and schema helper for generated sandbox components. The prompt asks for one
  `GeneratedComponent`-compatible JSON object, explicitly forbids source code,
  tests, shell commands, workflow blueprints, host writes, and promotion, and
  defaults to network-disabled, sandbox-only, review-gated policy metadata.
- The proposal prompt exposes a manifest with allowed languages, promotion
  statuses, default sandbox/capability profiles, required contract sections,
  and default policy. `shape_example/2` returns a draft component contract with
  interface, verification plan, acceptance checks, provenance, and risk fields;
  `contract_from_proposal/1` validates model-shaped output through
  `RunicAI.Sandbox.GeneratedComponent`.
- `test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs` covers
  manifest defaults, prompt scope and policy wording, generated shape examples
  validating as draft component contracts, provenance JSON-safety, and repair
  prompt diagnostics scoped to contract repair rather than code generation.
- `lib/runic_ai/sandbox/generated_component_builder.ex` adds
  `RunicAI.Sandbox.GeneratedComponentBuilder`, a callback-driven sandbox
  writer/tester/repair harness for generated component code. It takes an
  accepted `GeneratedComponent` contract plus caller-supplied source/test file
  contents, writes them through `RunicAI.Coding.SandboxSessionRegistry`, runs
  the contract test command in the sandbox with network disabled, records
  bounded diagnostics, and marks the component `:verified` only after a passing
  sandbox test.
- The builder deliberately does not generate code itself. Repair is supplied
  through an explicit `repair_fun` callback and bounded by
  `:max_repair_attempts`, so LLM/code generation, sandbox execution, and
  promotion remain separate observable phases.
- `test/support/generated_component_fake_sandbox_registry.ex` provides a
  focused fake registry for builder tests, matching the existing model-visible
  sandbox-session call boundary without using raw sandbox backend handles.
- `test/runic_ai/sandbox/generated_component_builder_test.exs` covers
  source/test file writes, passing verification, command execution with network
  disabled, repair callback retry, exhausted repair failure, draft status after
  failed tests, diagnostics capture, and validation of required registry,
  session id, and test command.
- `lib/runic_ai/sandbox/generated_component_output.ex` adds
  `RunicAI.Sandbox.GeneratedComponentOutput`, a generated-component output
  parser and interface validator. It can parse JSON, text, direct values, or
  sandbox execution stdout, then checks required declared outputs and simple
  value types from the component interface without creating atoms from model
  shaped keys.
- `test/runic_ai/sandbox/generated_component_output_test.exs` covers JSON
  stdout parsing, execution-result parsing, single direct output values,
  missing required outputs, records/list type mismatches, and strict JSON parse
  errors.
- `lib/runic_ai/sandbox/generated_component_promotion_policy.ex` adds
  `RunicAI.Sandbox.GeneratedComponentPromotionPolicy`, a promotion decision
  layer that distinguishes ephemeral use, durable artifact storage, and host
  repository materialization. It rejects unverified/incomplete components,
  allows ephemeral use of promotable verified components, allows durable
  artifact promotion without host writes, and always requires human review for
  host repo materialization.
- The promotion policy forces review on sandbox policy escalation metadata such
  as network or filesystem expansion, emits a typed `RunicAI.ReviewRequest`
  for review paths, and applies only approved matching `RunicAI.ReviewDecision`
  values before marking a component promoted.
- `test/runic_ai/sandbox/generated_component_promotion_policy_test.exs` covers
  ephemeral decisions, durable artifact promotion, host materialization review
  requirements, approved review promotion, rejection of failed/incomplete
  components, and policy-escalation review.
- `lib/runic_ai/sandbox/generated_component_workflow.ex` adds
  `RunicAI.Sandbox.GeneratedComponentWorkflow`, a data-only bridge from
  verified generated components to assistant workflow blueprints. It refuses
  unverified components, wraps promotable components as `:sandbox_execute`
  nodes, appends an `:objective_scorecard`, preserves declared input/output
  ports from the generated component interface, and records workflow policy
  metadata requiring verified source artifacts with sandbox networking
  disabled.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` now accepts
  `:generated_component` or `:generated_components` options and routes them
  through `GeneratedComponentWorkflow.compose/3`, giving the coordinator a
  direct non-LLM path for composing already verified sandbox-generated code
  into an executable Runic workflow blueprint.
- `RunicAI.RLM.ComponentRuntime` now filters generated-component metadata out
  of the model-visible `execute_code`/`sandbox_exec` argument payload. The
  generated-component contract metadata remains on the blueprint for trace and
  review, while only tool-schema-valid fields such as runtime, code, files,
  network, timeout, and output caps reach the sandbox tool call.
- `test/runic_ai/sandbox/generated_component_workflow_test.exs` covers
  accepted composition, rejection before verification, chained multi-component
  composition, coordinator routing without an LLM proposal call, capability
  profile rejection, and compiled Runic workflow execution of a generated
  component through the sandbox runtime.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_test.exs` -> 4 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs`
  -> 4 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs`
  -> 12 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_output_test.exs test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs`
  -> 17 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_promotion_policy_test.exs test/runic_ai/sandbox/generated_component_output_test.exs test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs`
  -> 22 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_promotion_policy_test.exs test/runic_ai/sandbox/generated_component_output_test.exs test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs test/runic_ai/rlm/subagent_delegation_workflow_test.exs test/runic_ai/rlm/repl_delegation_adapter_test.exs test/runic_ai/rlm/workflow_delegation_adapter_test.exs test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs test/runic_ai/rlm/subagent_reducer_test.exs test/runic_ai/rlm/delegation_mapper_test.exs test/runic_ai/rlm/context_slicer_test.exs test/runic_ai/rlm/subagent_assignment_test.exs test/runic_ai/rlm/repl_state_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/coding/review_gate_test.exs`
  -> 118 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_workflow_test.exs` -> 6
  tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_workflow_test.exs test/runic_ai/sandbox/generated_component_promotion_policy_test.exs test/runic_ai/sandbox/generated_component_output_test.exs test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs test/runic_ai/rlm/subagent_delegation_workflow_test.exs test/runic_ai/rlm/repl_delegation_adapter_test.exs test/runic_ai/rlm/workflow_delegation_adapter_test.exs test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs test/runic_ai/rlm/subagent_reducer_test.exs test/runic_ai/rlm/delegation_mapper_test.exs test/runic_ai/rlm/context_slicer_test.exs test/runic_ai/rlm/subagent_assignment_test.exs test/runic_ai/rlm/repl_state_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/coding/review_gate_test.exs`
  -> 139 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Manual smoke on 2026-05-25:
  `mix run -e '<verified bash GeneratedComponent -> GeneratedComponentWorkflow.compose -> WorkflowCompiler.run with reviewed sandbox_execute>'`
  returned `%{component_types: [:sandbox_execute, :objective_scorecard], sandbox_backend: :just_bash, parser_output: "{\"rows\":[{\"name\":\"apple\",\"qty\":2},{\"name\":\"pear\",\"qty\":3}],\"format\":\"csv\"}\n", scorecard_status: :objective_incomplete}`.
  This verifies the generated-component composition path through a real compiled
  Runic workflow and reviewed sandbox execution. The scorecard remained
  incomplete because this smoke did not materialize or score a durable final
  artifact; the generated parser component itself executed successfully in the
  sandbox and returned structured JSON rows.
- Validation on 2026-05-25: `git diff --check` passed for the current
  worktree.

### Phase 7: Coordinator Simplification

Goal: make the coding/RLM lane more reliable by using fewer brittle proposal
node types and more runtime evidence.

- [x] Add a planner preference for:
      - safe computing component;
      - Lambda-style workflow;
      - subagent delegation;
      - sandbox generated component;
      - REPL loop;
      - host command/edit only when required.
- [x] Replace "propose complete workflow graph first" with:
      - classify task shape;
      - choose the least-powerful strategy;
      - run a small evidence-producing slice;
      - expand only after the slice passes validation/review.
- [x] Make full workflow synthesis an optional promotion step. The coordinator
      may keep a run as direct delegation, Lambda workflow, REPL loop, or
      generated-component execution when those are sufficient.
- [x] Add fallback from invalid workflow proposals to:
      - direct subagent delegation;
      - Lambda-style decomposition;
      - REPL exploration.
- [x] Add a "repair by changing strategy" path. If compile-or-repair fails
      twice for the same shape, the coordinator should route to a simpler
      strategy rather than asking the model for another graph-shaped repair.
- [x] Let the coordinator ask a `component_builder` subagent for a verified
      component instead of directly generating a whole workflow.
- [x] Add reducer contracts for multi-agent workflows: map outputs must include
      claim, evidence refs, confidence, missing-info flags, and reviewer notes.
- [x] Add scorecards that judge component contract, verification evidence, and
      final objective satisfaction separately.
- [x] Manual smoke: broad coding task where the coordinator builds and uses at
      least one sandbox-generated component.

Parallelizable: limited. This phase touches coordinator behavior and should be
reviewed as one coherent change set.

Evidence:

- `RunicAI.RLM.StrategyRouter` is now exposed through
  `RunicAI.Assistant.RLM.Coordinator.route/3`, so assistant coordination can
  make deterministic, trace-friendly strategy decisions before asking an LLM to
  synthesize a whole graph. Router decisions now retain workspace metadata for
  every strategy, not only the direct-agent path.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` supports
  `proposal_strategy: :routed`, `:evidence_first`, `:least_powerful`, or
  `strategy_router?: true`. In routed/evidence-first mode the coordinator
  classifies the objective, records `blueprint.metadata.strategy_route`,
  disables dynamic graph proposal for the first slice, and returns a
  conservative existing blueprint shape. This gives the RLM lane an opt-in path
  for "route first, gather evidence, expand later" without changing the default
  dynamic proposal path yet.
- The coordinator default is now evidence-first rather than full-graph
  generation first. Explicit `proposal_strategy: :dynamic`, `:full_graph`, or
  `:generated_blueprint` preserves the old model-generated workflow proposal
  path for callers and tests that specifically need dynamic graph synthesis.
  Curated recipes still win before the default router because they are
  deterministic, least-powerful evidence slices for known local shapes.
- Full workflow synthesis is therefore an explicit promotion/escape path rather
  than the normal first move. Dynamic-planner tests now opt into
  `proposal_strategy: :dynamic`, while default coordinator tests assert that
  the LLM planner is not called before the first routed evidence slice.
- Routed mode currently maps direct-agent, sandbox-REPL, and host-edit tasks to
  a direct-response evidence slice; Lambda/subagent tasks to the existing
  split-map-reduce blueprint shape; and generated-component tasks to the
  existing parse/normalize/report shape unless a verified generated component
  is supplied through the Phase 6 composition path.
- `test/runic_ai/assistant/rlm_blueprint_test.exs` covers routed mode skipping
  the LLM blueprint-generation client, preserving strategy/fallback/budget
  metadata, exposing deterministic coordinator routing decisions, and the
  `:evidence_first` alias for least-powerful planning. It also covers the new
  default evidence-first behavior and the explicit `:dynamic` path for model
  generated workflow blueprints.
- `RunicAI.Assistant.RLM.Coordinator` now has a strategy-change repair path.
  When callers report `repair_attempts >= max_same_shape_repairs` (default 2)
  or explicitly pass `strategy_change_repair?: true`, invalid generated
  blueprint proposals stop cycling through another same-shape repair prompt and
  instead route to the strategy router's fallback strategy. The fallback
  blueprint records `:strategy_change_repair`, original strategy metadata,
  `:rerouted_to`, and the structured repair failure.
- This first repair reroute is intentionally conservative: it uses existing
  assistant blueprint shapes for the fallback strategy, so REPL/subagent/Lambda
  reroutes become observable and testable before deeper coordinator execution
  modes are made default.
- `RunicAI.RLM.SubagentReducer` now normalizes `:reviewer_notes`/`:notes` onto
  each reduced claim alongside claim text, evidence refs, confidence,
  missing-info flags, unsupported flags, conflicts, role, and source slice id.
  This completes the reducer-side contract needed for multi-agent map/reduce
  review.
- `lib/runic_ai/sandbox/generated_component_scorecard.ex` adds
  `RunicAI.Sandbox.GeneratedComponentScorecard`, a generated-component
  scorecard that separately reports component contract status, verification
  evidence status, final objective status from an optional downstream
  objective scorecard, residual risks, artifact counts, promotion status, and
  `promotable?`.
- `test/runic_ai/sandbox/generated_component_scorecard_test.exs` covers
  passing contract/verification with incomplete final objective status,
  incomplete contracts versus failed verification, and validation before
  scoring.
- `test/runic_ai/rlm/subagent_reducer_test.exs` now asserts reviewer notes are
  retained in normalized reducer claims.
- `RunicAI.Assistant.RLM.Coordinator.component_builder_assignment/3` adds an
  explicit coordinator-owned way to ask a `component_builder` workflow subagent
  for a verified generated component. The assignment is data-only, uses
  strategy `:generated_sandbox_component`, defaults to the explicit
  `:local_workbench` capability profile, exposes only sandbox session/file/exec
  tools to that child assignment, records route metadata, and requires contract
  first, tests, disabled network, and review before any host materialization.
- `RunicAI.RLM.DelegationAdapters.Workflow` already executes
  generated-component workflow assignments through an injected runner or
  supplied blueprint; tests now prove coordinator-produced component-builder
  assignments are valid inputs to that adapter.
- `test/runic_ai/assistant/rlm_blueprint_test.exs` covers the coordinator
  component-builder assignment shape, budgets, output schema, review policy,
  route metadata, and prompt constraints.
- `test/runic_ai/rlm/workflow_delegation_adapter_test.exs` covers running a
  coordinator-produced component-builder assignment through the workflow
  delegation adapter with an injected runner.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/rlm/workflow_delegation_adapter_test.exs test/runic_ai/rlm/subagent_assignment_test.exs`
  -> 27 tests, 0 failures.
- Manual smoke on 2026-05-25:
  `mix run -e '<Coordinator.component_builder_assignment -> WorkflowDelegationAdapter runner returns verified GeneratedComponent -> GeneratedComponentWorkflow.compose -> WorkflowCompiler.run with reviewed sandbox_execute>'`
  returned `%{assignment_strategy: :generated_sandbox_component, assignment_tools: ["open_sandbox_session", "sandbox_write_file", "sandbox_exec", "sandbox_read_file", "sandbox_list_files", "close_sandbox_session"], build_kind: :generated_component_build, workflow_components: [:sandbox_execute, :objective_scorecard], parser_output: "{\"rows\":[{\"name\":\"apple\",\"qty\":2},{\"name\":\"pear\",\"qty\":3}],\"format\":\"csv\"}\n", sandbox_backend: :just_bash}`.
  This verifies the coordinator can ask a component-builder workflow subagent
  for a verified component contract, then compose and execute that component
  through the reviewed sandbox workflow path. The smoke uses an injected build
  runner for the child assignment and real `just_bash` sandbox execution for
  the generated component.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_scorecard_test.exs test/runic_ai/rlm/subagent_reducer_test.exs`
  -> 7 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/rlm/strategy_router_test.exs`
  -> 26 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_agent_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs`
  -> 61 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_scorecard_test.exs test/runic_ai/sandbox/generated_component_workflow_test.exs test/runic_ai/sandbox/generated_component_promotion_policy_test.exs test/runic_ai/sandbox/generated_component_output_test.exs test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs test/runic_ai/rlm/subagent_delegation_workflow_test.exs test/runic_ai/rlm/repl_delegation_adapter_test.exs test/runic_ai/rlm/workflow_delegation_adapter_test.exs test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs test/runic_ai/rlm/subagent_reducer_test.exs test/runic_ai/rlm/delegation_mapper_test.exs test/runic_ai/rlm/context_slicer_test.exs test/runic_ai/rlm/subagent_assignment_test.exs test/runic_ai/rlm/repl_state_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/coding/review_gate_test.exs`
  -> 148 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/sandbox/generated_component_scorecard_test.exs test/runic_ai/sandbox/generated_component_workflow_test.exs test/runic_ai/sandbox/generated_component_promotion_policy_test.exs test/runic_ai/sandbox/generated_component_output_test.exs test/runic_ai/sandbox/generated_component_builder_test.exs test/runic_ai/sandbox/generated_component_proposal_prompt_test.exs test/runic_ai/sandbox/generated_component_test.exs test/runic_ai/rlm/subagent_delegation_workflow_test.exs test/runic_ai/rlm/repl_delegation_adapter_test.exs test/runic_ai/rlm/workflow_delegation_adapter_test.exs test/runic_ai/rlm/standard_agent_delegation_adapter_test.exs test/runic_ai/rlm/subagent_reducer_test.exs test/runic_ai/rlm/delegation_mapper_test.exs test/runic_ai/rlm/context_slicer_test.exs test/runic_ai/rlm/subagent_assignment_test.exs test/runic_ai/rlm/repl_state_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/assistant/rlm_blueprint_graph_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/assistant/rlm_agent_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/coding/review_gate_test.exs`
  -> 171 tests, 0 failures.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `git diff --check` passed.
- Full-suite validation on 2026-05-25: `mix test` -> 903 tests, 3 failures,
  2 skipped. The failing assertions were:
  `test/runic_ai/agent/capability_resolver_test.exs:281` expecting unsupported
  `start_service` but receiving a sandbox authority snapshot mismatch,
  `test/runic_ai/coding/rlm_objective_loop_test.exs:1091` where an OpsLogic
  implementation follow-up stopped as `:stop_failed`, and
  `test/runic_ai/rlm/robustness_test.exs:141` where the OpsLogic approval
  scenario remained non-passing with optional smoke checks skipped. The Phase 7
  targeted assistant/sandbox/RLM suites above cover the coordinator default
  change and passed.

### Phase 8: Evaluation And Hardening

Goal: know whether this actually improves task completion.

- [x] Add deterministic fixtures for:
      - bad sandbox code repair;
      - Lambda-style split/map/reduce/review over large context;
      - subagent map/reduce over multiple file groups;
      - large-context REPL chunking;
      - generated component promotion denied by review;
      - service smoke through sandbox proxy;
      - checkpoint/restore after a failed attempt.
- [x] Add strategy-family comparison fixtures where the same objective can run
      through multiple harnesses:
      - direct standard-agent verify;
      - current dynamic workflow coordinator;
      - Lambda-style typed plan;
      - subagent delegation with reducer/reviewer;
      - sandbox REPL with symbolic context variables;
      - generated sandbox component with contract/tests/promotion policy.
- [x] For each comparison fixture, persist:
      - router decision and fallback;
      - planned model calls, sandbox calls, fan-out, and cost estimate;
      - actual model calls, sandbox calls, retries, review pauses, and latency;
      - context bytes/tokens read by root versus leaf workers;
      - final artifact quality score and reviewer notes;
      - whether the run changed strategies after failure.
- [x] Add Lambda-RLM-shaped fixtures where structure is known before execution:
      - template/report generation from source bundles;
      - codebase risk inventory by file group;
      - extraction plus review where missing provenance forces targeted
        re-extraction;
      - deterministic call-count estimation before the first model call.
- [x] Add open REPL fixtures where structure is intentionally not known before
      execution:
      - inspect a large symbolic context and discover relevant slices;
      - write small helper code to index/search/transform context;
      - issue mediated `llm_query` or `delegate` subcalls under a depth/call
        budget;
      - checkpoint, summarize, and resume after a failed exploration turn.
- [x] Add live/manual lanes for:
      - Docker local polyglot;
      - vmsan if host assets are ready;
      - Sprites if credentials are configured;
      - no-network offline behavior.
- [x] Compare standard verify, current RLM coordinator, Lambda-style
      coordinator, subagent delegation, and REPL-backed coordinator on the same
      tasks.
- [x] Track:
      - success rate;
      - model calls;
      - sandbox exec count;
      - latency;
      - planned versus actual call count;
      - review pauses;
      - artifact quality;
      - host mutations avoided.

Parallelizable: yes. Evaluation lanes can be split by backend and scenario.

Phase 8 evidence starting 2026-05-25:

- `lib/runic_ai/rlm/sandbox_evaluation_fixtures.ex` adds
  `RunicAI.RLM.SandboxEvaluationFixtures`, a data-only deterministic fixture
  catalog for Phase 8. It defines fixtures for bad sandbox-code repair,
  Lambda-style report generation, subagent file-group review, unknown-schema
  REPL exploration, generated-component promotion denial, sandbox proxy service
  smoke, checkpoint/restore after failure, and a strategy-family comparison
  scenario.
- The fixtures are built from current contracts instead of a parallel schema:
  `RunicAI.RLM.StrategyRouter`, `RunicAI.RLM.LambdaPlan`,
  `RunicAI.RLM.SubagentAssignment`, `RunicAI.RLM.REPL.State`, and
  `RunicAI.Sandbox.GeneratedComponentPromotionPolicy`.
- `RunicAI.RLM.SandboxEvaluationFixtures.comparison_records/2` emits
  deterministic comparison records with router decision, selected harness,
  planned metrics, actual metrics, deltas, quality score/status, strategy-change
  flag, review notes, and artifact refs. The metric envelope now includes
  success, model calls, sandbox calls, fan-out, retries, review pauses, latency,
  host mutations avoided, planned cost estimate, root/leaf context bytes, and
  root/leaf context tokens.
- `RunicAI.RLM.SandboxEvaluationFixtures.evaluation_run/2` turns a fixture into
  a `RunicAI.Evaluation.Run` with one `RunicAI.Evaluation.Case` and
  `RunicAI.Evaluation.Result` per harness. Results carry the comparison record
  in outputs/metadata, metrics carry planned/actual/delta values, and aggregate
  totals report success rate, quality, model calls, sandbox calls, retries,
  review pauses, latency, strategy changes, context read volume, cost estimate,
  and host mutations avoided.
- `RunicAI.RLM.SandboxEvaluationFixtures.write_evaluation_artifacts!/3` writes
  both JSON and Markdown artifacts for a scenario. This completes deterministic
  fixture artifact persistence; full live-agent/backend comparison runs remain
  a later hardening lane.
- `mix runic_ai.rlm.sandbox_eval` exposes the deterministic fixture report
  writer as a repeatable command. It supports `--list`, repeatable
  `--scenario`, `--output-dir`, and `--basename`, normalizes hyphenated
  scenario ids for CLI use, defaults to the strategy-family fixture, and
  suffixes explicit basenames for multi-scenario runs so reports are not
  overwritten.
- `RunicAI.RLM.SandboxLiveLanes` adds live/manual preflight lanes for Docker
  polyglot, vmsan microVM, Sprites stateful remote microVM, and no-network
  offline behavior. The report records host/provider checks,
  ready/pass/skipped/blocked status, smoke execution state, backend metadata,
  and manual commands.
  vmsan and Sprites execution remain manual-gated; `--execute-live-lanes`
  currently runs the safe local Docker and no-network lanes when their
  prerequisites are present.
- `mix runic_ai.rlm.sandbox_eval --live-lanes` writes the live/manual preflight
  report, and `--execute-live-lanes` enables safe smoke execution. The command
  also supports `--docker-image`, `--sprites-token-env`, `--output-dir`, and
  `--basename` for host-specific/manual runs.
- `RunicAI.RLM.SandboxStrategyComparison` adds the same-task comparison runner
  for the core five Phase 8 strategy families: direct standard-agent verify,
  current dynamic workflow coordinator, Lambda workflow, subagent delegation,
  and sandbox REPL. It verifies all lanes share the same scenario/objective
  hash, executes a safe local no-network sandbox smoke per lane, merges those
  observations back into `RunicAI.Evaluation.Run`, and ranks the best harness
  by quality/call cost. Generated sandbox component comparison remains
  available as an opt-in lane with `include_generated_component?: true`.
- `mix runic_ai.rlm.sandbox_eval --compare-strategies` writes the same-task
  comparison report. It supports `--comparison-harness` for explicit lane
  selection, `--include-generated-component` for the sixth generated-component
  lane, and `--no-execute-comparison` for plan-only artifact generation.
- The Lambda-shaped fixture set now includes `lambda_report_generation`,
  `lambda_codebase_risk_inventory`, and `lambda_provenance_reextract`.
  `lambda_codebase_risk_inventory` models a known codebase inventory structure
  with four context contracts, eight planned leaf calls, one reduce/review
  pass, and deterministic root/leaf context token accounting.
  `lambda_provenance_reextract` models a review failure caused by missing
  provenance and a targeted re-extraction pass with one planned retry.
- The open REPL fixture set now includes `repl_unknown_schema` and
  `repl_context_discovery`. `repl_context_discovery` carries a symbolic
  workspace context ref, helper code path, discovered slice variables,
  mediated delegate usage, sandbox execution budgets, checkpoints, and resume
  metadata.
- The strategy-family comparison fixture covers the same objective through
  direct standard agent, current dynamic workflow coordinator, Lambda workflow,
  subagent delegation, sandbox REPL, and generated sandbox component harnesses.
  It is the fixture-level comparison contract consumed by the same-task
  comparison runner; full live-agent execution remains a later hardening lane.
- `test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs` covers scenario ids,
  deterministic router decisions, Lambda call accounting, constrained subagent
  assignments, REPL symbolic context/budgets/checkpoints, generated-component
  promotion denial through rejected review, multi-harness comparison records,
  strategy-change tracking, Lambda codebase/provenance fixture shapes, open
  REPL context-discovery shape, and JSON/Markdown artifact writing.
- `test/runic_ai/rlm/sandbox_eval_task_test.exs` covers task option parsing,
  live-lane option parsing, fixture listing, report writing, hyphenated
  scenario id normalization, and multi-scenario basename suffixing.
- `test/runic_ai/rlm/sandbox_live_lanes_test.exs` covers injected live-lane
  preflight probes, ready/skipped status calculation, safe smoke summaries, and
  JSON/Markdown report writing without requiring Docker, KVM, vmsan, or Sprites
  credentials during unit tests.
- `test/runic_ai/rlm/sandbox_strategy_comparison_test.exs` covers same-task
  comparison execution with injected sandbox smokes, optional generated
  component inclusion, plan-only comparison mode, best-harness ranking, and
  JSON/Markdown report writing.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs` -> 10
  tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/rlm/subagent_assignment_test.exs test/runic_ai/rlm/repl_state_test.exs test/runic_ai/sandbox/generated_component_promotion_policy_test.exs test/runic_ai/recipes/evaluation_harness_test.exs`
  -> 38 tests, 0 failures.
- Validation on 2026-05-26:
  `mix test test/runic_ai/rlm/sandbox_live_lanes_test.exs test/runic_ai/rlm/sandbox_eval_task_test.exs`
  -> 9 tests, 0 failures.
- Validation on 2026-05-26:
  `mix test test/runic_ai/rlm/sandbox_strategy_comparison_test.exs test/runic_ai/rlm/sandbox_eval_task_test.exs`
  -> 11 tests, 0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/sandbox_eval_task_test.exs` -> 5 tests,
  0 failures.
- Validation on 2026-05-25:
  `mix test test/runic_ai/rlm/sandbox_eval_task_test.exs test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/recipes/evaluation_harness_test.exs`
  -> 30 tests, 0 failures.
- Validation on 2026-05-26:
  `mix test test/runic_ai/rlm/sandbox_live_lanes_test.exs test/runic_ai/rlm/sandbox_eval_task_test.exs test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/recipes/evaluation_harness_test.exs`
  -> 34 tests, 0 failures.
- Validation on 2026-05-26:
  `mix test test/runic_ai/rlm/sandbox_strategy_comparison_test.exs test/runic_ai/rlm/sandbox_live_lanes_test.exs test/runic_ai/rlm/sandbox_eval_task_test.exs test/runic_ai/rlm/sandbox_evaluation_fixtures_test.exs test/runic_ai/rlm/strategy_router_test.exs test/runic_ai/rlm/planning_test.exs test/runic_ai/recipes/evaluation_harness_test.exs`
  -> 39 tests, 0 failures.
- Validation on 2026-05-26: `mix compile --warnings-as-errors` passed.
- Validation on 2026-05-25: `mix compile --warnings-as-errors` passed.
- Manual command smoke on 2026-05-25:
  `mix runic_ai.rlm.sandbox_eval --scenario strategy_family_report --output-dir tmp/rlm_sandbox_eval/reports --basename strategy-family-phase8`
  wrote `tmp/rlm_sandbox_eval/reports/strategy-family-phase8.json` and
  `tmp/rlm_sandbox_eval/reports/strategy-family-phase8.md`. The Markdown
  report recorded router strategy `lambda_workflow`, fallback
  `subagent_delegation`, six harness rows, four passing fixture harnesses, two
  failing fixture harnesses, 24 model calls, 10 sandbox calls, three review
  pauses, and zero strategy changes.
- Manual command smoke on 2026-05-25:
  `mix runic_ai.rlm.sandbox_eval --scenario lambda-codebase-risk-inventory --scenario repl-context-discovery --output-dir tmp/rlm_sandbox_eval/reports --basename phase8-expanded`
  wrote distinct JSON/Markdown report pairs for
  `lambda_codebase_risk_inventory` and `repl_context_discovery`. JSON
  inspection confirmed router strategy `lambda_workflow`, 10 planned model
  calls, and 24,000 leaf context tokens for the Lambda fixture, plus router
  strategy `sandbox_repl`, seven sandbox calls, and 92,000 leaf context bytes
  for the REPL fixture.
- Manual live-lane smoke on 2026-05-26:
  `mix runic_ai.rlm.sandbox_eval --live-lanes --execute-live-lanes --output-dir tmp/rlm_sandbox_eval/reports --basename live-lanes-phase8`
  wrote `tmp/rlm_sandbox_eval/reports/live-lanes-phase8.json` and
  `tmp/rlm_sandbox_eval/reports/live-lanes-phase8.md`. The host report showed
  two ready/passing lanes and zero blocked lanes: Docker polyglot passed
  bash/python/node/elixir/lua smoke execution in the configured sandbox image,
  and the no-network offline just-bash lane passed. vmsan was skipped because
  the host has `vmsan` 0.3.0 and `/dev/kvm`, but RunicSandbox health is not
  exec-ready yet due missing Firecracker, jailer, vmsan agent,
  `vmsan-nftables`, kernel/rootfs images, and nftables kernel support. Sprites
  was skipped because `SPRITES_TOKEN` is not configured.
- Sprites live-lane validation on 2026-05-26:
  `mix runic_ai.rlm.sandbox_eval --live-lanes --execute-live-lanes --output-dir tmp/rlm_sandbox_eval/reports --basename sprites-req-live-lanes`
  wrote `tmp/rlm_sandbox_eval/reports/sprites-req-live-lanes.json` and
  `tmp/rlm_sandbox_eval/reports/sprites-req-live-lanes.md`. The report showed
  `sprites_stateful` as ready and executed with status `:pass`, provider
  isolation `:remote_microvm`, state model `:service_actor`, stateful metadata,
  and a redacted `SPRITES_TOKEN` health payload. The live smoke used an
  ephemeral sprite, executed `printf sprites-live-ok`, and cleaned it up through
  the Sprites lifecycle. This also hardened the adapter to use `Req` as its
  default HTTP client and decode Sprites HTTP exec binary stream frames.
- Manual same-task strategy comparison on 2026-05-26:
  `mix runic_ai.rlm.sandbox_eval --compare-strategies --output-dir tmp/rlm_sandbox_eval/reports --basename strategy-compare-phase8`
  wrote `tmp/rlm_sandbox_eval/reports/strategy-compare-phase8.json` and
  `tmp/rlm_sandbox_eval/reports/strategy-compare-phase8.md`. The report
  compared the same `strategy_family_report` objective across direct standard
  agent, current dynamic workflow coordinator, Lambda workflow, subagent
  delegation, and sandbox REPL. It verified the same scenario/objective hash for
  all five lanes, executed five local no-network `just_bash` sandbox smokes with
  zero local smoke failures, and ranked `lambda_workflow` as the best harness.
  Fixture-quality outcomes were three passing lanes and two failing lanes:
  Lambda, subagent, and REPL passed; direct standard-agent verify failed from
  narrow root context; the current dynamic workflow coordinator failed from
  extra graph-repair cost.
- Session-authority hardening on 2026-05-26: `RunicSandbox.SessionRegistry` now
  starts unlinked from arbitrary callers, and signed session authority uses
  deterministic term encoding for snapshots and metadata hashes. This removed
  the intermittent full-suite sandbox authority mismatch seen under async test
  load.
- Validation on 2026-05-26:
  `mix test test/runic_ai/agent/capability_resolver_test.exs:281 test/runic_ai/assistant/rlm_blueprint_test.exs:279 test/runic_ai/rlm/sandbox_strategy_comparison_test.exs test/runic_ai/rlm/sandbox_eval_task_test.exs`
  -> 13 tests, 0 failures.
- OpsLogic deterministic-check hardening on 2026-05-26: optional env-gated
  smoke checks remain visible as `:skipped` evidence, but they no longer force
  the aggregate deterministic status to `:review` when all required checks pass.
  The aggregate now reports `required_skipped` and `optional_skipped` counts so
  hard gates can distinguish missing required evidence from explicitly optional
  smoke lanes.
- Validation on 2026-05-26:
  `mix test test/runic_ai/rlm/robustness_test.exs:80 test/runic_ai/rlm/robustness_test.exs:141 test/runic_ai/rlm/robustness_test.exs:1007 test/runic_ai/rlm/robustness_test.exs:1051 test/runic_ai/coding/rlm_objective_loop_test.exs:1091 --seed 123544`
  -> 4 tests, 0 failures.
- Validation on 2026-05-26:
  `mix test test/runic_ai/rlm/robustness_test.exs test/runic_ai/coding/rlm_objective_loop_test.exs`
  -> 59 tests, 0 failures.
- Compile validation on 2026-05-26:
  `mix compile --warnings-as-errors` -> passed.
- Full-suite validation on 2026-05-26: `mix test` -> 927 tests, 0 failures,
  2 skipped.

## Suggested Codex Goal Prompt

Use this once the plan is accepted:

```text
/goal Implement .docs/051-sandbox-agent-exposure-and-rlm-repl-plan.md in a
RALPH/OODA loop. Work phase by phase. For each phase: inspect the current code,
make the smallest coherent implementation slice, add focused tests, run targeted
and relevant full validation, perform a senior-engineer review pass, update the
checklist in the doc with exact evidence, then plan the next slice. Preserve the
RunicSandbox package boundary, keep Libbit as a future consumer only, and do not
broaden default agent powers without explicit recipes, capability profiles, and
review gates. Treat RLM as a family of strategies: direct standard-agent loops,
Lambda-style typed decomposition, subagent delegation, classic REPL recursion,
generated sandbox components, and host-edit workflows. Start with the least
powerful strategy that can solve the task, and record router decisions so
evaluation can compare strategy quality. Do not force the coordinator through a
problem -> full workflow proposal -> compile-or-repair path when direct
delegation, Lambda-style decomposition, a bounded REPL loop, or a generated
sandbox component would produce useful runtime evidence with less entropy.
Implement nested delegation with parent-owned budgets, depth limits, output
contracts, and traceable reducers. Preserve the Lambda-RLM-inspired separation
between deterministic control structure and model leaf judgment: compute
split/map/reduce/review structure when it is visible, delegate separable work
to constrained subagents, use sandbox REPL only when the decomposition must be
discovered by interacting with symbolic external state, and promote repeated
leaf operations into tested generated sandbox components. For every slice,
record planned versus actual model calls, sandbox calls, fan-out, latency,
review pauses, strategy changes, and artifact quality so the next OODA turn can
choose between direct agent, Lambda workflow, subagent workflow, REPL, and
generated-component lanes from evidence rather than preference.
```

## Open Questions

- Should `:sandboxed_verify` become the default Workbench verify recipe, or
  should it stay opt-in until more live evaluations pass?
- Should the first REPL runtime be Python because the RLM paper uses Python, or
  Elixir because RunicAI workflows are Elixir-native?
- Should Lambda-style workflows become the default for assistant large-context
  tasks before the open REPL lane exists?
- Should the strategy router be purely deterministic at first, or should the
  model classify problem shape with a validated schema?
- What is the maximum nested delegation depth for local developer workflows,
  and should cloud/serverless consumers such as Libbit get a different default?
- Which subagent assignment shapes should be first-class recipes versus
  dynamically generated role prompts?
- How much of `llm_query` should be callable from sandbox code versus mediated
  through an out-of-process bridge owned by RunicAI?
- Should generated components be materialized as Elixir modules, sandboxed
  source artifacts, or both?
- What is the minimum stable artifact format that lets a future Libbit consumer
  reuse the same sandbox-generated component contract?

## Implementation Status

The original first slice is complete and is covered by Phase 1 evidence above:

- [x] Add `:sandboxed_verify` recipe.
- [x] Add prompt guidance for `run_command` versus `execute_code`.
- [x] Add tests proving visibility and prompt text.
- [x] Add one fake-LLM standard-agent test where sandbox diagnostics drive a
      repair.
- [x] Run targeted standard-agent/capability/tool tests.
- [x] Run `mix compile --warnings-as-errors`.

The plan is now implemented through Phase 8. Remaining work is hardening, not a
missing planned phase:

- run full live-agent comparisons once model/provider credentials and stable
  smoke workspaces are available;
- make vmsan exec-ready by installing Firecracker/jailer/agent/images and
  resolving nftables support;
- expand Sprites stateful comparison lanes beyond the live smoke into longer
  service/checkpoint/proxy scenarios;
- revisit whether `:sandboxed_verify` should become the default Workbench
  verify recipe after more live evaluations pass.
