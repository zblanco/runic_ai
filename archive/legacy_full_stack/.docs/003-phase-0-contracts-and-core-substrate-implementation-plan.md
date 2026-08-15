# Phase 0 Implementation Plan: Contracts And Core Substrate

Status: implemented

Date: 2026-04-14

Depends on:
- `.docs/001-poc-llm-components.md`
- `.docs/002-workflow-native-agent-roadmap.md`

## Goal

Turn the current POC into a stable substrate for the rest of RunicAI by
introducing library-owned contracts, clear adapter seams, and predictable
component I/O shapes.

Phase 0 is successful when later phases can be built mostly by composing
existing contracts rather than inventing new ad hoc maps and provider-specific
shapes at every feature boundary.

Current note:

- All in-scope Phase 0 work below has been implemented and verified with tests.
- The only plausible follow-up in this phase would be normalizing the streaming
  and object-generation façades further if we want them to mirror the text
  generation envelope even more strictly.

## Why This Phase Matters

Right now the codebase proves the basic idea, but most of the surface still
composes through raw maps and `ReqLLM.Context`. That is good enough for a POC
and not yet good enough for a growing library.

The maintainable shape we want is:

1. RunicAI owns the values that flow through most of the graph.
2. adapters translate those values to and from external libraries.
3. Runic components transform one known value shape into another.
4. recipes assemble those transforms into workflows.

That keeps composition legible and lets future phases add tools, memory,
multi-agent workflows, and control gates without smearing provider details
through the whole library.

## Design Principles

### 1. Own the contracts that compose

Use RunicAI structs and typespecs for the values most components exchange.
External types such as `ReqLLM.Context` should sit at the adapter edge rather
than becoming the library's implicit internal language.

### 2. Make each component a simple shape transformation

A component should ideally do one main thing:

- normalize input
- assemble a request
- invoke an effect
- reduce state
- interpret an outcome

Avoid components that both decide and perform unrelated work.

### 3. Keep control flow explicit at the boundary

Normal values should travel as structs. Non-local control flow should travel as
tagged outcomes that pattern match cleanly:

```elixir
{:ok, value}
{:retry, %RunicAI.Error{}}
{:error, %RunicAI.Error{}}
{:wait, %RunicAI.Wait{}}
{:review, %RunicAI.ReviewRequest{}}
```

This keeps reducers and rules simple while leaving room for future phases.

### 4. Separate pure domain values from effect requests

Conversation state, messages, and prompt bundles are domain values.
LLM requests and LLM results are effect boundary values.
Runic steps can compose both, but they should not blur them.

### 5. Prefer small domain namespaces over generic "types" buckets

Do not create a grab-bag module like `RunicAI.Types` that becomes a dumping
ground. Use domain-shaped modules such as `RunicAI.Message`,
`RunicAI.Conversation.State`, and `RunicAI.LLM.Request`.

### 6. Preserve convenience where it does not damage the model

We can keep small convenience wrappers such as `RunicAI.LLM.generate_text/3`,
but the canonical substrate should be typed request/result values rather than
anonymous maps.

## Contract Layering Model

This phase should establish the following layers.

### Layer 1: Core value contracts

These are the nouns that most of the graph speaks.

- `RunicAI.Message`
- `RunicAI.Prompt`
- `RunicAI.Conversation.State`
- `RunicAI.Metadata` or normalized metadata conventions

### Layer 2: Effect boundary contracts

These describe calls into external capabilities and the values that come back.

- `RunicAI.LLM.Request`
- `RunicAI.LLM.Result`
- `RunicAI.Error`
- `RunicAI.Wait`
- `RunicAI.ReviewRequest`

### Layer 3: Adapter contracts

These convert library-owned values to provider-owned values and back.

- `RunicAI.LLM`
- `RunicAI.LLM.ReqLLMClient`
- internal conversion helpers between `RunicAI.Prompt` and `ReqLLM.Context`

### Layer 4: Component contracts

These are Runic constructors that consume and produce the layer 1 and layer 2
values in predictable ways.

- `RunicAI.Steps.PromptBuilder`
- `RunicAI.Steps.LLMGenerate`
- `RunicAI.Steps.TextToConversation`
- `RunicAI.Conversation`

### Layer 5: Recipe contracts

These are small reference workflows proving the layers fit together.

- basic chat workflow
- contract validation examples

## Recommended Public Contracts

These should be the minimum Phase 0 contract set.

### `RunicAI.Message`

Purpose: the canonical message value passed around the library.

Suggested fields:

- `:role` - `:system | :user | :assistant | :tool`
- `:content` - normalized text content
- `:name` - optional speaker or tool name
- `:metadata` - optional small map for provenance and future extensions

Notes:

- [x] Use a struct with `@enforce_keys` for role and content.
- [x] Add a smart constructor that validates allowed roles.
- [x] Keep content simple in Phase 0; do not over-design multimodal support yet.

### `RunicAI.Prompt`

Purpose: provider-neutral model input assembled from messages and static
instructions.

Suggested fields:

- `:messages` - ordered `RunicAI.Message` list
- `:metadata` - optional prompt metadata

Notes:

- [x] Keep this intentionally small in Phase 0.
- [x] Let future phases extend prompt assembly with retrieved context and memory
      by producing more `RunicAI.Message` values rather than replacing the whole
      prompt model.

### `RunicAI.Conversation.State`

Purpose: immutable state reduced across turns.

Suggested fields:

- `:messages` - ordered `RunicAI.Message` list
- `:turns` - non-negative integer
- `:status` - `:running | :completed | :halted`
- `:last_assistant_message` - optional `RunicAI.Message`
- `:assigns` - optional map for recipe-local state

Notes:

- [x] Keep this as a durable reducer state, not as a bag of every future agent
      concern.
- [x] Later phases can wrap or extend it rather than mutate its meaning.

### `RunicAI.LLM.Request`

Purpose: canonical input to the LLM facade and LLM step.

Suggested fields:

- `:model`
- `:prompt` - `RunicAI.Prompt`
- `:opts` - provider-neutral or provider-pass-through keyword opts
- `:metadata` - trace-friendly request metadata

Notes:

- [x] This becomes the main contract for component composition.
- [x] Convenience wrappers can still accept `model, prompt, opts` and normalize
      into this struct.

### `RunicAI.LLM.Result`

Purpose: canonical output from the LLM facade.

Suggested fields:

- `:message` - normalized assistant `RunicAI.Message`
- `:finish_reason` - atom or normalized string
- `:usage` - optional token/cost data
- `:raw` - provider-native response for debugging
- `:metadata` - adapter metadata

Notes:

- [x] The adapter should normalize the provider result once so every caller does
      not repeat provider-specific extraction logic.
- [x] Keep `:raw` for observability and debugging, but do not make business
      logic depend on it.

### `RunicAI.Error`

Purpose: normalized failure payload for retryable and terminal errors.

Suggested fields:

- `:kind` - broad category such as `:validation`, `:provider`, `:timeout`
- `:message` - human-readable summary
- `:details` - optional machine-readable data
- `:source` - component or adapter origin
- `:retryable?` - boolean

Notes:

- [x] Use this in tagged outcomes rather than returning arbitrary terms from
      public components.

## Outcome Convention

The library should standardize its public result envelope in Phase 0.

- [x] Use tagged tuples for outer control flow.
- [x] Use structs for payloads.
- [x] Reserve `{:ok, value}` for normal success.
- [x] Reserve `{:retry, %RunicAI.Error{retryable?: true}}` for retryable
      failures.
- [x] Reserve `{:error, %RunicAI.Error{}}` for terminal failures.
- [x] Reserve `{:wait, %RunicAI.Wait{}}` and `{:review, %RunicAI.ReviewRequest{}}`
      now even if the first recipes do not yet emit them.
- [ ] Do not return naked provider structs or naked error atoms from public
      component boundaries.

## Proposed Module And File Layout

```text
lib/runic_ai/
  error.ex
  message.ex
  prompt.ex
  wait.ex
  review_request.ex
  conversation/
    state.ex
  llm/
    request.ex
    result.ex
    req_llm_client.ex
  steps/
    llm_generate.ex
    prompt_builder.ex
    text_to_conversation.ex
  conversation.ex
```

Notes:

- [x] Keep domain structs in domain-oriented modules.
- [x] Avoid a generic `contracts/` or `types/` bucket unless the namespace
      pressure becomes real later.
- [x] Add only the Phase 0 contracts now; do not pre-create empty future modules.

## Implementation Workstreams

### Workstream 1 - Freeze The Contract Model

Outcome: the public nouns and outcomes are explicit before component refactors
begin.

- [x] Write and agree the final field lists and typespecs for:
      `RunicAI.Message`, `RunicAI.Prompt`, `RunicAI.Conversation.State`,
      `RunicAI.LLM.Request`, `RunicAI.LLM.Result`, `RunicAI.Error`,
      `RunicAI.Wait`, and `RunicAI.ReviewRequest`.
- [x] Decide which values must be structs and which can remain tagged tuples.
- [x] Decide the metadata convention for all contracts:
      either a plain map named `:metadata` everywhere or a narrower per-struct
      convention. Prefer consistency over cleverness.
- [x] Decide which current POC input maps become transitional compatibility
      shapes and which can be removed immediately.
- [x] Document the contract invariants directly in module docs and typespecs.

### Workstream 2 - Implement Core Value Contracts

Outcome: the library owns the main values that flow through the graph.

- [x] Add `RunicAI.Message` with constructor and validation helpers.
- [x] Add `RunicAI.Prompt` with constructor helpers from message lists.
- [x] Add `RunicAI.Conversation.State` with constructors and reducer-friendly
      append helpers.
- [x] Add `RunicAI.Error`, `RunicAI.Wait`, and `RunicAI.ReviewRequest`.
- [x] Add `RunicAI.LLM.Request` and `RunicAI.LLM.Result`.
- [x] Add small helper functions for shape normalization where they reduce
      repeated code, but stop short of building a giant utility module.

### Workstream 3 - Isolate The ReqLLM Adapter Boundary

Outcome: provider-specific translation becomes a single seam instead of a
cross-cutting concern.

- [x] Refactor `RunicAI.LLM` so the canonical path accepts normalized request
      values and returns normalized result values.
- [x] Keep convenience wrappers for current usage patterns if they are cheap to
      support and make examples easier to read.
- [x] Move all `ReqLLM.Context` construction and response extraction into the
      adapter layer.
- [x] Ensure `RunicAI.LLM.ReqLLMClient` is responsible for translating:
      `RunicAI.Prompt -> ReqLLM.Context -> ReqLLM.Response -> RunicAI.LLM.Result`.
- [x] Keep provider-native response data only in `RunicAI.LLM.Result.raw`.

### Workstream 4 - Refactor Existing Components To The New Contracts

Outcome: current components compose through library-owned shapes.

- [x] Refactor `RunicAI.Steps.PromptBuilder` to produce `RunicAI.Prompt`.
- [x] Refactor `RunicAI.Steps.TextToConversation` to produce normalized
      `RunicAI.Message` lists.
      Parsing conversation text into messages should remain separate from
      reducing those messages into `RunicAI.Conversation.State`.
- [x] Refactor `RunicAI.Conversation` to reduce `RunicAI.Conversation.State`
      rather than a raw map with embedded `ReqLLM.Context`.
- [x] Refactor `RunicAI.Steps.LLMGenerate` to consume `RunicAI.LLM.Request`
      or normalize directly into it before calling the facade.
- [x] Ensure existing component names can stay stable even if their internal
      contracts change.
- [x] Add compatibility normalization only at the edges, not inside every
      branch of component logic.

### Workstream 5 - Validation And Error Semantics

Outcome: contract mistakes fail early and predictably.

- [x] Add constructor-level validation for required fields and invalid roles.
- [x] Add component boundary validation where a bad input shape would otherwise
      fail deep inside a provider call.
- [x] Normalize public failures into `RunicAI.Error`.
- [x] Decide when invalid input should raise versus return `{:error, ...}`.
      The default should be: constructors validate eagerly; runtime steps return
      tagged outcomes.
- [x] Add pattern-match-friendly helpers only where they clarify common checks.

### Workstream 6 - Reference Workflow And Example Surface

Outcome: there is one clear proof that the substrate is enough to build on.

- [x] Build a small reference chat workflow using:
      `PromptBuilder -> LLMGenerate -> Conversation accumulator -> stop rule`.
- [x] Ensure the reference workflow composes entirely through RunicAI contracts
      except at the adapter boundary.
- [x] Add one example showing function-based client injection and one showing
      module-based client injection.
- [x] Update README examples so they reflect the new substrate rather than the
      older Mox/app-config framing.
- [x] Update or replace `.docs/001-poc-llm-components.md` references where the
      plan materially changes the canonical API.

### Workstream 7 - Test Matrix

Outcome: the substrate is safe to extend in later phases.

- [x] Add unit tests for all new contract constructors and validators.
- [x] Add adapter tests for `RunicAI.Prompt <-> ReqLLM.Context` translation.
- [x] Add adapter tests for provider response normalization into
      `RunicAI.LLM.Result`.
- [x] Update existing component tests so they assert the new contracts rather
      than raw maps or raw `ReqLLM.Context` where possible.
- [x] Add regression tests for convenience wrappers to ensure ergonomics remain.
- [x] Add one end-to-end test for the reference chat workflow.

## Recommended Implementation Sequence

Implement the phase in this order so the refactor stays controlled.

- [x] Step 1: define the contract modules and outcome convention first.
- [x] Step 2: update the LLM facade and ReqLLM adapter second.
- [x] Step 3: refactor component modules onto the new contracts third.
- [x] Step 4: update the reference workflow and docs fourth.
- [x] Step 5: finish with the compatibility pass and test cleanup.

## Recommended Early Decisions

These should be treated as the default direction unless implementation reveals a
real contradiction.

- [x] Make `RunicAI.Steps.TextToConversation` output normalized
      `RunicAI.Message` lists by default.
      Parsing text into messages is one transformation; reducing messages into
      conversation state is a different transformation and should stay separate.
- [x] Keep `RunicAI.LLM.generate_text/3` as a public convenience wrapper over a
      request-struct path.
      The canonical substrate should be `RunicAI.LLM.Request -> RunicAI.LLM.Result`,
      but the wrapper keeps examples and direct usage ergonomic.
- [x] Treat `RunicAI.Conversation.State.messages` as the single canonical source
      of history.
      `RunicAI.Prompt` should be assembled from that history rather than holding
      a second competing canonical form.
- [x] Keep `RunicAI.Prompt` intentionally thin in Phase 0.
      Future context sections can be added later, but a minimal prompt contract
      will compose more cleanly today.
- [x] Use plain Elixir structs, `@enforce_keys`, typespecs, and constructors.
      Do not introduce a new dependency for struct helpers in this phase unless
      the code becomes materially worse without it.

## Acceptance Criteria

Phase 0 is complete when all of the following are true.

- [x] RunicAI-owned contracts exist for the main values exchanged between core
      components.
- [x] The canonical LLM path no longer requires callers to reason directly about
      `ReqLLM.Context` or raw `ReqLLM.Response`.
- [x] Existing core components compose using the new contracts.
- [x] Public outcomes are normalized and pattern-matchable.
- [x] The README and Phase 0 docs show the new substrate rather than the old POC
      shape.
- [x] The reference chat workflow passes its tests using the new contracts.

## Explicitly Out Of Scope

Keep these out of Phase 0 so the substrate can settle before the feature surface
widens.

- [ ] Tool calling
- [ ] Retrieval and RAG
- [ ] Long-term memory
- [ ] Multi-agent orchestration
- [ ] Review gates, waits, and retries beyond placeholder contracts
- [ ] Sandbox execution
- [ ] Optimization or evaluator frameworks

## Notes For The Follow-On Phase

If Phase 0 lands well, Phase 1 should be able to focus mostly on conversation
kernel behavior rather than contract invention. That is the real payoff here:
future plans should mostly talk about composing and reducing values that already
exist.
