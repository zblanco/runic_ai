# Workbench Streaming Agent Output Adaptation Plan

Status: implemented through the Phase 5 common-event contract; expanded timeline UI remains follow-up

## Goal

Adapt the Libbit chat-agent streaming pattern into RunicAI built-in agents so
Workbench conversations can show assistant progress while an LLM call is still
running, without breaking the normal Runic workflow contract where later steps
receive the complete generated text after the stream resolves.

The core shape is:

1. An LLM step consumes a provider stream and emits normalized presentation
   chunks as side effects.
2. The same step accumulates those chunks and returns the complete
   `RunicAI.LLM.Result` when the stream finishes.
3. Downstream workflow steps stay eager and unchanged: they receive the full
   result only after stream completion.
4. The Workbench receives persisted stream events under a stable message id and
   reloads a single growing assistant message for the active session.

## Implementation Result

Implemented in this patch:

- `RunicAI.LLM.Streaming` streams provider chunks through a side-channel sink,
  coalesces small chunks, returns a normal `RunicAI.LLM.Result`, and preserves
  eager fallback behavior for unsupported or scripted clients.
- `RunicAI.Persistence.HarnessProjection` now projects chunk events into one
  accumulating `AgentMessage` keyed by stable stream/message identity while
  preserving individual `AgentMessageChunk` rows.
- `RunicAI.Terminal.Event` now normalizes LLM stream stages into terminal
  `:chunk` and completion `:message` events.
- `RunicAI.Steps.GenerateTurn`, `RunicAI.Steps.LLMGenerate`,
  `RunicAI.Terminal.StandardRunner`, `RunicAI.RLM.ComponentRuntime`,
  `RunicAI.RLM.Components.LLMMap`, and
  `RunicAI.RLM.Components.HierarchicalReduce` now pass stream sinks and stable
  message metadata through the built-in agent LLM paths.
- `RunicAI.Event` is now the shared runtime/client event contract for stream
  stages, RLM/workflow stages, and explicit workflow presentation effects.
- `RunicAI.Terminal.Event` now adapts the common event contract for terminal
  clients instead of owning the shared runtime/web abstraction.
- `RunicAI.Workbench.record_event/1` accepts common events directly, broadcasts
  common `{:workbench, :event, event}` messages, and keeps terminal-event
  broadcasts as compatibility shims.
- `RunicAIWeb.WorkbenchLive` refreshes from the common event broadcast instead
  of consuming terminal events as its primary notification.
- Verification: `mix test` passes with 590 tests, 0 failures, 2 skipped.

## Libbit Pattern

Libbit has two related patterns worth adapting.

### Direct streamed turns

`Core.Chat.Strategies.Direct.stream_assistant_turn/2` returns a turn map with:

- `message_id`
- `llm_id`
- `stream`, a normalized lazy stream of `{:content, text}`,
  `{:thinking, chunk}`, `{:tool_call, chunk}`, and `{:meta, chunk}` tuples
- `finish_reason`, a thunk that reads the completed stream response finish
  reason

`Core.Chat.TurnDriver.emit_turn/3` consumes that stream, writes chunks through
`Core.Chat.stream_message/5`, and only after enumeration marks the message
complete through `complete_assistant_message/4` or `notify_stream_end/2`.

That is the important split: presentation starts as soon as chunks arrive, but
the caller still has a normal completed assistant turn once stream enumeration
finishes.

### Workflow-emitted presentation effects

Libbit's managed-agent path adds a second layer for stateful Runic workflows.

`Core.Agents.RunicConversationWorkflow` adds an
`:emit_conversation_effects` step to the workflow graph. That step builds
assistant-message effects for intermediate and terminal workflow states:

- `plan`
- `progress`
- `analysis`
- `tool_calls`
- `final`
- `error`

Those effects carry stable presentation metadata:

- `request_context_id`
- `presentation_group_id`
- `message_kind`
- `workflow_iteration`
- `source_step`
- `transient`
- `supersedes_message_id`

`Core.Chat.ConversationPresentationBridge` subscribes while the workflow runs,
persists pending effects as workflow outputs appear, and returns the terminal
assistant effect to the outer chat driver. `ManagedAgentWorkflow` marks a turn
as `already_persisted?` when the workflow effect has already written the visible
assistant message, so the outer `TurnDriver` does not duplicate it.

This is broader than token streaming, but it is the same architectural move:
Runic workflows keep producing normal data, while presentation side effects
make progress visible earlier.

### Libbit persistence and LiveView projection

Libbit persists stream chunks under a stable message id. The workspace chat
projector either inserts the first streamed message or appends later chunks to
the existing row.

For non-content channels, such as thinking and tool calls, the projector stores
a primary placeholder message and accumulates text in `secondary_channels`.
When `MessageStreamEnded` arrives, it flips `stream_complete` to `true`.

The LiveView then reloads grouped presentation entries. Compact mode hides
superseded progress, expanded mode shows the full timeline, and secondary
channels can show an active streaming indicator while `stream_complete` is
false.

## RunicAI Current State

RunicAI already has many of the pieces, but they are not joined through the
built-in agent LLM paths yet.

### Existing useful substrate

- `RunicAI.LLM.stream_text/3` exists and delegates to ReqLLM.
- `RunicAI.LLM.TestClient.stream_response/1` can produce deterministic chunked
  test streams.
- `RunicAI.Terminal.Event` already includes `:chunk`.
- `RunicAI.Persistence.Schemas.AgentMessage` already has `stream_complete`,
  `transient`, `presentation_group_id`, `source_step`, and `workflow_node`.
- `RunicAI.Persistence.Schemas.AgentMessageChunk` already stores per-message
  chunks.
- `RunicAI.Terminal.StreamBuffer` already models a stable in-memory stream for
  the TUI.
- `RunicAI.Terminal.ExRatatui.Commands.record_stream_update/3` already records
  `:chunk` events while a stream is incomplete and a final `:message` event on
  completion or failure.
- `RunicAI.Workbench.record_terminal_event/1` persists an event and broadcasts
  it to the global and session topics.
- `RunicAIWeb.WorkbenchLive` reloads `Workbench.session_snapshot/1` on session
  events, with a short refresh debounce.

### Original gaps

Before this implementation, the built-in agent LLM paths were eager:

- `RunicAI.Steps.GenerateTurn.generate/2` calls `LLM.generate_text/1`.
- `RunicAI.Steps.LLMGenerate.new/1` calls `LLM.generate_text/1`.
- `RunicAI.RLM.Components.LLMMap` calls `LLM.generate_text/3`.
- `RunicAI.RLM.Components.HierarchicalReduce` calls `LLM.generate_text/3`.
- Standard, assistant, and RLM runners mostly emit stage/result events, not
  token-level LLM stream events.

The Workbench projection also needed a correction before agent streaming was
useful. `RunicAI.Persistence.HarnessProjection.project_event_kind!/2` handled
`kind: "chunk"` by inserting an `AgentMessage` with id `"message:#{event.id}"`.
That meant multiple chunks for one stream became multiple read-model messages
instead of one growing assistant message.

## Target Design

### Shared stream collector

Add a shared helper, likely under `RunicAI.LLM`, with a shape like:

```elixir
RunicAI.LLM.Streaming.generate_text(model, prompt, opts)
```

The helper should:

- call `LLM.stream_text/3` when streaming is enabled and a stream sink is
  present;
- fall back to `LLM.generate_text/3` when streaming is disabled or unsupported;
- normalize provider chunks into content, thinking, tool call, and metadata
  events;
- coalesce tiny token chunks before persistence, using a byte/count/time window;
- emit `:chunk` events with a stable `stream_id` and `message_id`;
- accumulate content chunks in memory;
- emit one completion event with the same stream identity;
- return `{:ok, %RunicAI.LLM.Result{}}`, `{:retry, error}`, or
  `{:error, error}` in the same shape expected by existing callers.

This preserves the Runic semantics: the component blocks until its own LLM call
has finished, then returns the complete value to downstream graph nodes. Only
the presentation side channel is incremental.

Stream event data should include:

- `run_id`
- `session_id`
- `stream_id`
- `message_id`
- `role`
- `message_kind`
- `content`
- `chunk`
- `channel`
- `sequence`
- `source_step`
- `workflow_node`
- `transient`
- `presentation_group_id`
- `request_context_id`

### Stable stream identity

Use deterministic ids so chunk upserts are idempotent and refresh-safe.

Recommended shapes:

- standard final turn: `assistant:#{session_id}:turn:#{turn_index || event_id}`
- RLM component map item:
  `assistant:#{run_id}:#{component_id}:item:#{index}`
- RLM reduce group:
  `assistant:#{run_id}:#{component_id}:group:#{index}`
- RLM final reduce:
  `assistant:#{run_id}:#{component_id}:final`
- assistant direct/workflow output:
  `assistant:#{run_id}:#{source_step || "workflow_output"}`

The exact strings can change during implementation, but the invariant should
not: every chunk and completion event for one visible stream must share the same
message identity.

### Projection behavior

Update `RunicAI.Persistence.HarnessProjection` so `kind: "chunk"` behaves like
Libbit's projector:

1. Derive `message_id` from event data, in this order:
   `message_id`, `stream_message_id`, `stream_id`, then fallback to event id.
2. Upsert one `AgentMessage` for that stable id.
3. Append content chunks to the existing `AgentMessage.content`.
4. Insert each chunk into `AgentMessageChunk` with a stable sequence.
5. Keep `stream_complete: false` for in-progress chunks.
6. On the completion event with the same message id, mark
   `stream_complete: true` and set the final content to the accumulated text or
   complete content from the event.
7. Preserve `transient` and `message_kind` from event data rather than forcing
   every stream to the generic `"stream"` kind.

The initial Workbench does not need a new transport. Once the projection keeps
one growing row per stream, existing PubSub broadcasts plus snapshot refreshes
can show visible progress.

### Workbench presentation

For the first pass, keep the UI modest:

- render the growing assistant message in the current conversation list;
- show a small streaming state when `stream_complete == false`;
- keep transient intermediate RLM streams visible only while there is no better
  final message, following the existing `visible_chat_messages/1` behavior.

Later, borrow the Libbit grouping model more fully:

- use `presentation_group_id` for a whole assistant turn or workflow node group;
- use `message_kind` for `plan`, `progress`, `analysis`, `tool_calls`,
  `stream`, `workflow_output`, `final`, and `error`;
- let compact mode hide superseded transient progress;
- let expanded mode show the full stream/progress timeline.

## Implementation Sequence

### Phase 1: Fix stream projection first

- [x] Add a focused persistence test that records two `:chunk` events with the
  same `stream_id` and asserts there is one `AgentMessage` whose content is the
  concatenated stream.
- [x] Assert both chunks are present in `AgentMessageChunk`.
- [x] Record a completion event for the same stream and assert the same message
  is marked `stream_complete: true`.
- [x] Update `HarnessProjection` to derive stable message ids from event data.
- [x] Update `insert_message!/6` or add a stream-specific upsert path that can
  append content instead of replacing by event id.
- [x] Keep existing final message and transient workflow-output tests passing.

This phase makes Workbench streaming possible even before built-in agents emit
real provider chunks.

### Phase 2: Add the shared LLM streaming collector

- [x] Add `RunicAI.LLM.Streaming` or an equivalent shared module.
- [x] Normalize ReqLLM `StreamChunk` shapes for content, thinking, tool calls,
  and metadata.
- [x] Emit chunk events through a `stream_sink` or `event_sink` option.
- [x] Accumulate assistant content and return a normal `RunicAI.LLM.Result`.
- [x] Add tests with `RunicAI.LLM.TestClient.stream_response/1`.
- [x] Add fallback coverage for unsupported streaming clients.

The helper is the adaptation point for the Libbit direct-turn contract.

### Phase 3: Wire standard agent turns

- [x] Thread a stream/event sink into the standard agent turn request or runtime
  context.
- [x] Update `RunicAI.Steps.GenerateTurn.generate/2` to call the streaming
  helper when the sink is present.
- [x] Keep the returned result shape unchanged for `InterpretTurn`.
- [x] Add a focused standard-agent test proving chunks are emitted before the
  final result and the final result still feeds the normal turn pipeline.

This gives the Workbench the earliest user-visible win.

### Phase 4: Wire assistant and RLM workflow components

- [x] Extend `RunicAI.RLM.ComponentRuntime.llm_component_opts/2` with stream
  metadata from the base context and runtime opts.
- [x] Update `RunicAI.RLM.Components.LLMMap.map_item/5` to stream each item
  when a sink is present, using stable item stream ids.
- [x] Update `RunicAI.RLM.Components.HierarchicalReduce` group and final
  reductions to stream with stable group/final stream ids.
- [x] Add shared event support for stream stages and keep
  `RunicAI.Terminal.Event` as a client adapter for terminal renderers.
- [x] Decide which RLM streams are visible final content and which are
  transient analysis/progress.
- [x] Add tests for parallel `LLMMap` streaming so interleaved chunks remain
  attached to the right message.

This is where assistant, RLM, and generated workflow nodes start feeling alive
in the Workbench.

### Phase 5: Add workflow presentation effects

The shared abstraction should not be `RunicAI.Terminal.Event`. The TUI, CLI,
and WebUI are all clients of the same runtime core, so the WebUI should not
consume "terminal" events as its primary contract. The better layering is:

1. Define a common runtime/client event contract in core RunicAI.
2. Let runtime, workflow, and LLM streaming paths emit or normalize into that
   common contract.
3. Let client layers such as CLI, TUI, and WebUI consume the common contract
   directly or wrap/translate it into presentation-specific events.
4. Keep the existing terminal event schema and APIs as compatibility adapters
   while the common event contract becomes the abstraction owner.

- [x] Introduce a RunicAI equivalent of Libbit's workflow presentation effects
  for durable non-token progress: plan started, node started, tool requested,
  analysis update, final answer, error.
- [x] Define a common event vocabulary that terminal, TUI, and web clients can
  consume or wrap without depending on `RunicAI.Terminal.Event`.
- [x] Keep `RunicAI.Terminal.Event` as a client adapter around the common event
  contract, not as the shared runtime/web abstraction.
- [x] Use `transient`, `presentation_group_id`, and `message_kind` consistently
  so `visible_chat_messages/1` can hide intermediate noise after a final answer
  exists.
- [ ] Add a Workbench expanded timeline view only after the compact view is
  useful and stable.

The common-event part of this phase is complete. The expanded timeline remains
intentionally deferred until the compact chat/progress surface has more runtime
use behind it.

## Agent-Specific Notes

### Standard

Primary seam: `RunicAI.Steps.GenerateTurn`.

The standard agent should stream the final assistant turn directly. Since the
normal downstream path still needs a complete `LLM.Result`, this is the cleanest
first integration and closest to Libbit's direct turn driver.

### RLM

Primary seams:

- `RunicAI.RLM.Components.LLMMap`
- `RunicAI.RLM.Components.HierarchicalReduce`
- `RunicAI.RLM.ComponentRuntime`
- `RunicAI.Terminal.Event.from_rlm_stage/2`

RLM needs more care because multiple map items can stream concurrently. The
stream id must include component id and item index, and chunk ordering should be
per stream, not global.

### Assistant

Primary seams:

- assistant RLM execution through `WorkflowCompiler` and `WorkflowExecutor`
- workflow component execution via `ComponentRuntime`
- final result projection through `Event.from_rlm_result/2`

The assistant should benefit from the RLM component streaming first. Later, the
blueprint generation and repair loops can also use the same collector if their
LLM calls are long enough to matter in the Workbench.

## Risks And Decisions

- ReqLLM stream chunk shapes should be verified against current provider
  structs before coding the normalizer.
- Persisting every token can create heavy SQLite and PubSub churn. Coalesce
  chunks before writing.
- Parallel RLM streams need per-stream sequence numbers.
- Transient streamed content must not leak back into future prompt history
  after a final answer exists.
- Completion and failure events must be idempotent so refreshes, retries, or
  duplicate broadcasts do not duplicate visible content.
- The common event contract should remain the runtime/client boundary; terminal
  and Workbench-specific event shapes should stay adapters around that contract.

## Follow-Up

The remaining product/UI step is an expanded Workbench timeline that presents
the common event stream with grouping, filtering, and transient-progress
controls. The core runtime and persistence pieces are now in place for that
view to consume without depending on terminal-specific event abstractions.
