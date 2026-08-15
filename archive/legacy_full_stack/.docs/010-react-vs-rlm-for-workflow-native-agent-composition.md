# Research Note: ReAct, Recursive Language Models, And Workflow-Native Agent Composition

Status: working note

Date: 2026-04-19

Depends on:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`

References:
- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/007-phase-4-context-engineering-memory-and-retrieval-boundaries-implementation-plan.md`
- `https://arxiv.org/abs/2210.03629`
- `https://arxiv.org/abs/2305.10601`
- `https://proceedings.mlr.press/v235/kim24y.html`
- `https://arxiv.org/abs/2305.14325`
- `https://arxiv.org/abs/2306.05685`
- `https://arxiv.org/abs/2404.18796`
- `https://arxiv.org/abs/2510.11967`
- `https://arxiv.org/abs/2510.24699`
- `https://arxiv.org/abs/2512.24601`
- `https://arxiv.org/abs/2603.20105`

## Goal

Compare the ReAct agent model with Recursive Language Models (RLMs), identify
the salient differences that matter for RunicAI, and record how those ideas
should shape the roadmap for workflow-native decomposition, multi-agent
coordination, and later long-context execution work.

## Short Thesis

ReAct and RLMs solve different layers of the problem.

- ReAct is a local reasoning-and-acting loop over the current working context.
- RLM is a broader recursive inference paradigm that externalizes the prompt
  into an environment and lets the model programmatically decompose work and
  invoke itself over scoped slices.

Inference for RunicAI:

- ReAct-like loops belong inside child recipes and agent kernels.
- Phase 5 should add the typed parent/child delegation and join layer above
  those kernels.
- A later RLM-oriented lane can then plug into those contracts rather than
  replacing them.

## Source Highlights

From the ReAct paper:

- The paper frames ReAct as an interleaving of reasoning traces and task
  actions so the model can both reason and interact with external sources.
- Its core execution picture is still one ongoing trajectory whose history
  remains in the active context window.

From the RLM paper:

- The paper explicitly treats the prompt as part of an external environment
  rather than placing the full prompt in the root model context.
- The model writes code that examines, decomposes, and recursively calls itself
  over snippets of the prompt.
- Only small metadata about execution output is fed back into the root history,
  so the root model is pushed to manage large state symbolically rather than by
  keeping everything in-window.

Inference for RunicAI:
the deepest distinction is not "single agent versus multi-agent."
It is "verbalized linear control inside one transcript" versus "programmatic
recursive control over externalized state."

## Salient Comparison

| Dimension | ReAct | RLM | RunicAI implication |
| --- | --- | --- | --- |
| Core unit of execution | One interleaved thought-action-observation loop | A recursive scaffold around a base LM | ReAct fits child recipes; RLM is a later execution model |
| Prompt placement | The working transcript stays in the active context | The prompt is externalized into an environment handle | Phase 4 and Phase 5 should keep context and handoff explicit as data |
| Delegation form | Usually verbalized actions or tool calls | Programmatic recursive self-calls over slices | Phase 5 should model child invocation as typed workflow data |
| Context growth behavior | History tends to accumulate in one thread | Root context stays small while work is pushed into sub-calls and environment state | Phase 5 should scope child context aggressively and reuse handoff artifacts |
| Output construction | Final answer is normally verbalized in the root loop | Final answer can be built symbolically and returned from environment state | Child results in RunicAI should carry structured artifacts, not only reply text |
| Tool use | Central and explicit | Can exist, but is secondary to recursive decomposition and symbolic state handling | Tools stay important, but Phase 5 should not reduce every child to tool use |
| Search / branching | Usually linear unless extra scaffolding is added | Recursion is a first-class part of the paradigm | Runic fan-out and join should become first-class public contracts |
| Verifiability | Better than pure CoT, but still mostly prompt-driven | Stronger separation between control code and neural calls, especially in lambda-RLM follow-ups | Keep the workflow skeleton typed and deterministic around stochastic leaves |

## What ReAct Gives RunicAI

ReAct remains highly relevant.
It is still a strong answer to "what should one child do once it has its own
goal, tools, and context?"

The ReAct paper's main contribution for RunicAI is the local loop shape:

```text
context
  -> reason
  -> act
  -> observe
  -> reason again
  -> final answer or next action
```

RunicAI already has a natural home for that:

- Phase 1 conversational turn generation
- Phase 2 tool calling and execution
- Phase 3 guards, waits, and reviews
- Phase 4 context assembly and handoff

Inference for RunicAI:
ReAct should remain the default inner control policy for many child recipes, but
it should stop being the outermost orchestration model once decomposition
enters the picture.

## What RLM Gives RunicAI

RLM contributes a different insight.

The paper's key move is to treat long prompts as external environment state and
to let the model programmatically recurse over scoped slices of that state
instead of trying to keep the whole story inside one growing transcript.

The RLM paper highlights three design choices that matter here:

1. the prompt should be given a symbolic handle rather than copied wholesale
   into root context
2. the system should support symbolic recursion, not only verbalized sub-calls
3. long outputs and intermediate values should be built in external state, not
   only autoregressively in the root transcript

Inference for RunicAI:

- Phase 4 already moved in this direction by separating transcript truth,
  derived context state, and handoff artifacts.
- Phase 5 should continue that move by turning child invocation into typed
  assignment data plus normalized result envelopes.
- A later RLM-style lane could then treat `Context.Bundle`, handoff artifacts,
  files, or other large inputs as external objects that specialized recipes
  inspect programmatically.

## Why This Matters For Phase 5

Without this distinction, it is easy to accidentally design Phase 5 as
"ReAct, but with more personalities."

That would miss the deeper point.

What Phase 5 really needs is:

1. a parent/child contract layer
2. typed scoped context transfer
3. normalized child result semantics
4. explicit fan-out and fan-in operators
5. role specialization as data

Those are useful whether the child itself runs a ReAct-style tool loop, a judge
workflow, or a narrower one-shot LLM step.

Inference for RunicAI:
Phase 5 should primarily import the decomposition lesson from RLM, not the raw
runtime mechanics of an RLM scaffold.

## What Phase 5 Should Borrow Now

These ideas are worth importing immediately into the RunicAI design:

### 1. Child invocation should be programmatic data, not just a prompt convention

This is the main bridge from ReAct toward RLM thinking.
The parent should produce typed child tasks and assignments, not only strings
that ask the model to "pretend" to delegate.

### 2. Context transfer should be scoped and explicit

Phase 4's `HandoffArtifact` and `Context.Bundle` are already the right
building blocks.
Children should receive a narrow seed, not a blind copy of the full parent
thread.

### 3. Child outputs should be structured artifacts

A child may return a synthesis, a review, a score, a patch plan, a wait, or a
handoff.
That should be modeled as structured result data instead of collapsing every
child branch back into plain assistant text.

### 4. Fan-out and fan-in should be first-class

RLM makes recursion central.
RunicAI should make parent planning, child execution, and result reduction
central.
That means typed task plans, staged groups, and deterministic join policies.

### 5. Control outcomes must survive delegation boundaries

If a child needs human approval or must wait for an external signal, that
should bubble out as a typed result.
This is a major advantage of the existing RunicAI control layer.

### 6. A child can be smaller than a full agent

RLMs do not require every recursive step to be a richly stateful "agent."
Likewise, RunicAI should allow simple child workflows, judges, reducers, or
one-shot LLM steps under the same delegation surface.

## What Should Wait For A Later RLM Lane

These ideas are important, but they should not become hard Phase 5 scope:

### 1. A persistent REPL as a new mandatory runtime

The RLM paper uses a persistent REPL and generated control code.
That is powerful, but it would be too large a conceptual jump for the first
decomposition substrate.

### 2. Open-ended code generation as the library's main orchestration language

Inference for RunicAI:
the library should first stabilize typed public contracts for delegation,
joining, and control.
Only after that should it consider exposing a more open recursive execution
surface.

### 3. Native recursive model training assumptions

The RLM paper also explores post-training a natively recursive model.
That is interesting, but it is clearly outside the immediate library design
problem.

## Why lambda-RLM Is Especially Relevant

The lambda-RLM paper is unusually relevant to RunicAI because it sharpens the
RLM idea in a direction that looks much more like Runic:

- typed functional runtime
- pre-verified combinators
- explicit control flow
- formal guarantees on termination and cost

Inference for RunicAI:
if there is eventually an "RLM lane" in this project, it should probably look
closer to lambda-RLM than to a raw free-form REPL scaffold.

That suggests a future direction where RunicAI exposes a small typed algebra of
decomposition operators such as:

- partition
- map over tasks
- reduce results
- score candidates
- select winner
- debate then judge
- hand off or continue

This fits the project's stated preference for dataflow, inspectable control,
and category-theory-friendly composition much better than handing arbitrary
Python to the model as a core public API.

## Related Patterns Worth Keeping In View

Several nearby papers help place Phase 5 in a wider design space:

- Tree of Thoughts extends beyond linear left-to-right reasoning into branching
  search and self-evaluation.
  Inference for RunicAI: this supports explicit staged branching and reduction
  recipes.
- LLMCompiler separates planning, dispatch, and execution for parallel function
  calling.
  Inference for RunicAI: Phase 5 should separate child task planning from child
  execution and join.
- Multiagent Debate shows that multiple model instances can improve reasoning
  and factuality through bounded discussion.
  Inference for RunicAI: debate should be a recipe over the same child-task and
  join contracts, not a separate runtime.
- LLM-as-a-Judge is useful but comes with known biases.
  Inference for RunicAI: keep judges typed and inspectable.
- Judges vs Juries suggests diverse panels of smaller models can outperform a
  single large judge while reducing some bias.
  Inference for RunicAI: jury or panel recipes should be first-class in Phase 5.
- Context Folding and AgentFold reinforce the idea that long-horizon agent work
  needs explicit branch/return context management rather than one ever-growing
  transcript.
  Inference for RunicAI: this connects Phase 4 and Phase 5 tightly.

## Recommended Roadmap Framing

The most coherent framing for RunicAI looks like this:

1. Phases 1 through 4 establish the single-thread kernel:
   turn loop, tools, controls, context, memory, and handoff.
2. Phase 5 adds a typed decomposition and delegation substrate:
   roles, tasks, assignments, results, and join policies.
3. Phase 6 adds more integrated stateful recipes:
   long-lived workflow-owned state, if desired.
4. A later advanced lane can explore RLM or lambda-RLM inspired execution
   adapters:
   externalized prompt state, recursive child invocation, and possibly typed
   recursive combinators.

Inference for RunicAI:
RLM should be thought of as a future execution strategy or recipe family that
reuses the Phase 5 contracts, not as a reason to skip the Phase 5 contract
layer.

## Relevant Papers And Why They Matter

- ReAct: Synergizing Reasoning and Acting in Language Models
  (`2210.03629`, submitted 2022-10-06, revised 2023-03-10)
  `https://arxiv.org/abs/2210.03629`
  Why it matters: the canonical local reason-act-observe loop and a useful
  baseline for child recipe behavior.

- Tree of Thoughts: Deliberate Problem Solving with Large Language Models
  (`2305.10601`, submitted 2023-05-17, revised 2023-12-03)
  `https://arxiv.org/abs/2305.10601`
  Why it matters: explicit branching, self-evaluation, and search over thought
  states.

- An LLM Compiler for Parallel Function Calling
  (ICML 2024 / PMLR 235)
  `https://proceedings.mlr.press/v235/kim24y.html`
  Why it matters: planning, dispatch, and parallel execution as separate stages
  with measurable latency and cost gains over ReAct.

- Improving Factuality and Reasoning in Language Models through Multiagent
  Debate (`2305.14325`, submitted 2023-05-23)
  `https://arxiv.org/abs/2305.14325`
  Why it matters: bounded multi-agent discussion as a reusable recipe pattern.

- Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena
  (`2306.05685`, submitted 2023-06-09, revised 2023-12-24)
  `https://arxiv.org/abs/2306.05685`
  Why it matters: model judges can be useful and scalable, but their biases
  should be kept visible.

- Replacing Judges with Juries: Evaluating LLM Generations with a Panel of
  Diverse Models (`2404.18796`, submitted 2024-04-29, revised 2024-05-01)
  `https://arxiv.org/abs/2404.18796`
  Why it matters: diverse panels can outperform one large opaque judge and cost
  less.

- Scaling Long-Horizon LLM Agent via Context-Folding
  (`2510.11967`, submitted 2025-10-13)
  `https://arxiv.org/abs/2510.11967`
  Why it matters: branch/return context management on long-horizon agent tasks.

- AgentFold: Long-Horizon Web Agents with Proactive Context Management
  (`2510.24699`, submitted 2025-10-28)
  `https://arxiv.org/abs/2510.24699`
  Why it matters: proactive multi-scale context shaping instead of raw history
  accumulation.

- Recursive Language Models
  (`2512.24601`, submitted 2025-12-31, revised 2026-01-28)
  `https://arxiv.org/abs/2512.24601`
  Why it matters: externalized prompt state, symbolic recursion, and
  programmatic self-delegation over long-context inputs.

- The Y-Combinator for LLMs: Solving Long-Context Rot with lambda-Calculus
  (`2603.20105`, submitted 2026-03-20)
  `https://arxiv.org/abs/2603.20105`
  Why it matters: typed functional recursive control that aligns strongly with
  RunicAI's design instincts.

## Working Conclusion

ReAct should remain the answer to "how does one agent-like child reason and
act?"

Phase 5 should answer a different question:
"how do multiple specialized children get planned, scoped, run, and rejoined as
typed workflow values?"

RLM then becomes a later, stronger answer to a third question:
"how should very long-horizon work externalize context and recurse over it
programmatically?"

That separation is healthy for the roadmap.
It lets RunicAI land a clean workflow-native decomposition substrate now, while
leaving the door open for a future RLM or lambda-RLM inspired execution lane
that plugs into the same contracts instead of blowing them up.
