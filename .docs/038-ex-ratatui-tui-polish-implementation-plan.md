# ExRatatui TUI Rendering And Interaction Polish Plan

Status: implemented core polish slice; deferred manual and secondary polish noted below

Date: 2026-05-03

Motivated by:

- `.docs/035-ex-ratatui-coding-agent-terminal-interface-alternate-plan.md`
- `.docs/035-termui-coding-agent-terminal-interface-implementation-plan.md`
- `.docs/034-owl-bunt-cli-terminal-presentation-enhancement-plan.md`
- `.docs/037-sqlite-backed-agent-workflow-durability-proposal.md`
- `.docs/DESIGN.md`
- `guides/TUI_CHEATSHEET.md`
- the current `RunicAI.Terminal.ExRatatui.*` implementation
- the existing `RunicAI.Terminal.GraphPresenter` Mermaid and MMDFlux support

## Goal

Polish the ExRatatui local harness so the default chat view feels like a real
agentic terminal conversation surface, not a plain event dump. The immediate
surface area is:

- Mermaid rendering through MMDFlux, reusing the CLI graph presenter path;
- Markdown rendering for assistant messages, final answers, summaries, repair
  prompts, review prompts, and selected details;
- code syntax highlighting for fenced blocks, diffs, shell commands, and
  tool outputs;
- streaming assistant outputs into the conversation pane when the underlying
  content source can produce incremental chunks;
- slash-command completion and suggestions.

This work should keep the existing TUI split:

- chat view is the primary operator surface;
- debug view remains the durable workflow/run inspection workbench;
- SQLite remains the source of truth for persisted conversation, run, workflow,
  and trace data;
- terminal modules stay presentation-oriented and do not decide agent logic.

## Current Baseline

The current ExRatatui TUI already has:

- a chat-first view with conversation, agent activity, captured logs, and
  composer;
- a debug view with runs, timelines, details, managed workflows, evals, and
  workflow graph panes;
- SQLite-backed hydration through persistence query helpers;
- slash-command parsing through `RunicAI.Terminal.ExRatatui.SlashCommands`;
- graph mode flags for `text`, `mermaid`, and `mmdflux`;
- `RunicAI.Terminal.GraphPresenter` support for text adjacency, Mermaid source,
  and MMDFlux terminal text output;
- captured Logger output in a logs pane rather than raw terminal writes.

Gaps:

- conversation messages are rendered as wrapped plain paragraphs;
- Markdown and code fences are not treated as first-class content blocks;
- Mermaid graph artifacts are displayed as metadata previews instead of
  rendered content;
- `mmdflux` work would currently be too easy to trigger in a render path unless
  explicitly moved to async commands and cache state;
- agent final outputs are projected after completion, but provider/text chunks
  are not streamed into the chat pane;
- slash commands are discoverable through `/help`, but there is no tab
  completion, predictive command list, or contextual argument suggestion.

## Design Principles

- Normalize content once, render many ways. Conversation, detail, review, and
  graph panes should consume stable rendered-content structs rather than
  reparsing raw strings in each view.
- Do expensive rendering outside the view path. MMDFlux, syntax lexing, graph
  conversion, and large Markdown parsing should run in commands or bounded
  caches, never inside pure widget construction.
- Persist before display. Stream chunks, final messages, graph artifacts, review
  decisions, and tool output should be written through durable events/messages
  first when they are part of the run history.
- Degrade cleanly. Missing `mmdflux`, unsupported syntax languages, narrow
  terminals, `NO_COLOR`, and ASCII/plain themes should still produce readable
  text.
- Separate streamable and non-streamable content. Tool result summaries, final
  text, and assistant summaries may stream. Scorecards, graph artifacts, review
  requests, durable facts, and many structured tool outputs usually arrive as
  complete records.
- Keep the TUI framework-neutral seam. The renderer should be reusable by the
  ExRatatui view now and by a future TermUI, web, or Livebook view later.

## Proposed Architecture

Add a small rendering and interaction layer under the TUI namespace, with any
framework-neutral pieces placed under `RunicAI.Terminal` when useful.

```text
RunicAI.Persistence agent_messages / terminal_events / artifacts
  -> PersistenceView
  -> Terminal.RenderedContent
  -> Terminal.MarkdownBlocks
  -> Terminal.Syntax
  -> Terminal.GraphPresenter
  -> ExRatatui.RenderCache
  -> ExRatatui.Views.Conversation / Details / WorkflowGraph / ReviewModal
```

Candidate modules:

- `RunicAI.Terminal.RenderedContent`: framework-neutral content block structs
  and normalization from messages/events/artifacts.
- `RunicAI.Terminal.MarkdownBlocks`: conservative Markdown block parsing for
  paragraphs, headings, lists, blockquotes, code fences, tables, and Mermaid
  fences.
- `RunicAI.Terminal.Syntax`: code and diff tokenization with a plain fallback.
  Start with high-value languages and diff highlighting; add a dependency such
  as Makeup only after a small proof that token output maps cleanly to terminal
  spans.
- `RunicAI.Terminal.StreamBuffer`: append/finalize stream fragments by
  `run_id`, `message_id`, `stream_id`, and `content_kind`.
- `RunicAI.Terminal.ExRatatui.RenderCache`: bounded cache for rendered Markdown
  blocks, highlighted code, graph render results, and measured row heights.
- `RunicAI.Terminal.ExRatatui.CommandSuggestions`: slash-command and argument
  suggestion state.
- `RunicAI.Terminal.ExRatatui.Views.Content`: ExRatatui widget conversion from
  rendered content blocks to paragraphs, Markdown widgets, lists, and spans.

The cache should be keyed by enough input to avoid stale output:

```text
{content_hash, renderer, theme, graph_mode, width, color_mode, unicode_mode}
```

## Content Model

Use explicit content block kinds so the TUI can decide how to render and scroll
without guessing from raw strings every frame.

Initial block kinds:

- `:markdown`
- `:paragraph`
- `:heading`
- `:list`
- `:blockquote`
- `:code`
- `:diff`
- `:table`
- `:mermaid`
- `:mmdflux`
- `:tool_call`
- `:tool_result`
- `:review_request`
- `:scorecard`
- `:artifact`
- `:error`
- `:log`
- `:stream_placeholder`

Each block should carry:

- `id`
- `source_id` such as message id, event id, artifact id, or stream id
- `kind`
- `text`
- `language`
- `status`
- `metadata`
- `stream_complete?`
- `height_hint`
- `rendered_at`

The durable data stays in SQLite. These blocks are only bounded UI projections.

## Streaming Contract

Streaming should be modeled as incremental updates to a content item, not as
unbounded ad hoc text appended to the screen.

Required behavior:

- A stream starts with a durable event or message containing a stable
  `message_id` or `stream_id`.
- Chunks append to the matching stream buffer and update the selected
  conversation pane without stealing focus from the composer.
- Completion flips `stream_complete?` and records final content in
  `agent_messages`.
- Failed streams render the partial content plus a visible failed/incomplete
  marker.
- Non-streamable records still insert as complete blocks.

Streamable candidates:

- direct assistant responses;
- final answers;
- generated summaries;
- repair prompts and repair results;
- long command output when captured as progressive chunks;
- LLM map/reduce summaries when the runtime emits chunk events.

Non-streamable or usually complete records:

- scorecards;
- review requests;
- managed workflow rows;
- graph artifacts;
- persisted facts;
- most tool result structs;
- export summaries.

Implementation should support streaming when the runner/provider path emits
chunks, but it should not require every backend to use token streaming. Codex
local bridge and some tool paths can continue to emit complete messages.

## Mermaid And MMDFlux Rendering

Use `RunicAI.Terminal.GraphPresenter` as the shared presentation boundary.

Deliverables:

- [x] Render persisted graph artifacts in the workflow graph pane using
      `GraphPresenter.render/2`, not metadata previews.
- [x] Detect Mermaid fenced blocks in assistant Markdown and render them as
      graph blocks when `/graph mmdflux` is active.
- [x] Keep `/graph text|mermaid|mmdflux` as the mode switch.
- [x] Move MMDFlux execution into an async command, with render-cache results
      delivered back to the model.
- [x] Show Mermaid source when mode is `mermaid`.
- [x] Show MMDFlux terminal output when mode is `mmdflux` and the executable is
      available.
- [x] Show a compact blocked fallback with Mermaid source when `mmdflux` is not
      on `PATH`.
- [x] Apply timeouts, output truncation, and UTF-8 safe truncation consistently
      with the existing CLI presenter.
- [x] Avoid rerunning MMDFlux on every render tick, resize, or focus movement.

Validation:

- [x] Unit test graph artifact normalization into text, Mermaid, and MMDFlux
      modes.
- [x] Headless TUI test that `/graph mmdflux` queues async render work and then
      displays cached output.
- [x] Test missing `mmdflux` fallback.
- [ ] Manual smoke with a Mermaid graph from `guides/mental-model.md`.
- [ ] Manual smoke with a persisted assistant/RLM workflow graph artifact.

## Markdown Rendering

Use ExRatatui's Markdown widget where it fits, but keep a RunicAI content-block
normalizer in front of it so special blocks can be handled consistently.

Deliverables:

- [x] Render assistant final output and direct responses as Markdown in the
      conversation pane.
- [x] Render selected details, repair prompts, review explanations, and final
      summaries as Markdown where appropriate.
- [x] Support headings, lists, code fences, tables, blockquotes, links, and
      horizontal rules well enough for typical agent output.
- [x] Treat raw HTML as inert text.
- [x] Detect Mermaid code fences and hand them to graph rendering.
- [x] Preserve plain text layout for logs, command output, and preformatted
      tool output.
- [x] Cache parsed Markdown by content hash and width.
- [x] Keep copy/export surfaces backed by original text, not lossy rendered
      widgets.

Validation:

- [x] Unit tests for Markdown block parsing, including fenced code and Mermaid.
- [x] Headless snapshots for assistant Markdown at 80x24, 100x30, and wide
      terminals.
- [x] Plain theme and `NO_COLOR` snapshot.
- [ ] Manual smoke with a direct creative response, a report-style answer, and
      a tool-heavy coding answer.

## Code Syntax Highlighting

Syntax highlighting should help scanability without making terminal output
fragile. Diff highlighting and shell/code fence readability matter more than
perfect language coverage.

Deliverables:

- [x] Detect fenced code language from Markdown.
- [x] Highlight unified diffs with added, removed, hunk, path, and context
      styles.
- [x] Highlight shell snippets enough to distinguish command, option, string,
      variable, comment, and prompt.
- [x] Highlight Elixir and JSON as first-class languages.
- [x] Add generic fallback highlighting for unknown languages.
- [x] Render command output as preformatted text without applying misleading
      language highlighting unless a language is known.
- [x] Decide whether to add Makeup or keep a lightweight internal highlighter
      after a focused proof.
- [x] Keep all styles mapped through `RunicAI.Terminal.ExRatatui.Theme`.

Validation:

- [x] Unit tests for diff, shell, Elixir, JSON, and unknown code blocks.
- [x] Headless snapshots for code fences in conversation and details panes.
- [ ] Manual smoke with a generated patch preview and a verification output.

## Conversation Streaming

The chat pane should update progressively for streamable assistant content,
while still rendering complete records for structured workflow output.

Deliverables:

- [x] Add stream-buffer state to the model with bounded memory and durable
      identifiers.
- [x] Extend event bridge/projection handling for chunk events and message
      completion.
- [x] Insert a visible in-progress assistant message when the first stream
      chunk arrives.
- [x] Auto-follow the latest streaming message only when the user has not
      scrolled away.
- [x] Preserve selection and composer input while chunks arrive.
- [x] Finalize the message on `stream_complete` and reload from SQLite so live
      and postmortem paths converge.
- [x] Mark interrupted or failed streams visibly.
- [x] Keep non-streamable outputs as complete inserted blocks.

Validation:

- [x] Unit tests for append, finalize, interrupt, and error stream-buffer
      transitions.
- [x] Headless TUI test that injected chunks update the conversation pane.
- [x] Headless test that user scroll position disables auto-follow.
- [ ] Manual smoke with a provider/client path that supports `stream_text/3`.
- [ ] Manual smoke with a non-streaming Codex/local response to confirm the
      fallback path still works.

## Slash Completion And Suggestions

Slash commands should be discoverable without leaving the composer.

Deliverables:

- [x] Add a suggestion model for command names, aliases, argument completions,
      descriptions, and preview text.
- [x] Show a small suggestions pane above the composer while in slash mode.
- [x] Use `Tab` and `Shift-Tab` for completion movement while slash mode is
      active.
- [x] Keep normal focus movement on `Tab` outside slash mode.
- [x] Complete command names from `SlashCommands.names/0`.
- [x] Complete graph modes for `/graph`.
- [x] Complete status values for `/managed` and `/eval`.
- [x] Complete recent run ids/objective snippets for `/runs`.
- [x] Complete tool names from persisted tool-call history for `/tools`.
- [x] Complete workflow keys from managed workflow rows for `/start` and
      `/resume`.
- [x] Consider path completion only after command completion is stable, and
      keep it read-only unless an explicit write/review flow is active.
- [x] Show unknown-command errors inline without exiting slash mode.

Validation:

- [x] Unit tests for prefix matching, ranking, aliases, and contextual argument
      suggestions.
- [x] Headless key tests for `/he<Tab>`, `/graph <Tab>`, and
      `/tools <prefix><Tab>`.
- [ ] Manual smoke for command discovery and correction after a typo.

## Additional Expected Agent Harness TUI Enhancements

These are not all required before the first polish slice ships, but they are
the kinds of features an agent harness TUI should grow toward.

### Conversation And Thread Management

- `/new` to start a fresh thread without restarting the TUI.
- `/switch RUN_OR_THREAD` to jump to an existing conversation.
- `/rename TITLE` for human-readable run/thread labels.
- `/fork` to continue from a previous conversation with a new run id.
- `/retry` and `/regenerate` for selected assistant outputs.
- `/edit` for editing and resubmitting the last user turn with a new run id.

### Navigation, Search, And Selection

- Conversation search that highlights matches in the current pane.
- Jump commands for next/previous user turn, tool call, review, error, and
  final answer.
- Bookmark or pin important events/messages for postmortem review.
- Follow mode for active runs, with explicit pause when the user scrolls away.
- Scrollbars or position indicators for long panes.

### Tool, Patch, And HITL Surfaces

- Expandable tool-call cards in the chat view.
- Diff/patch preview with syntax highlighting and risk labels.
- Review modal actions that map cleanly to approve, deny, rewrite, stop, and
  request-more-evidence.
- Read-only command output viewer with exit status, cwd, elapsed time, and
  captured stderr/stdout.
- Clear policy badges for read-only, write-gated, destructive, network, and
  external-process actions.

### Artifacts And Attachments

- Artifact browser for files, reports, graph artifacts, exports, and generated
  summaries.
- Open selected artifact in a read-only preview pane.
- Copy/export selected message, code block, graph source, or run evidence.
- Optional OSC52 clipboard support behind a setting, with plain export as the
  default fallback.
- Add context/file attachments from the composer through an explicit command
  flow, not implicit filesystem guessing.

### Prompt, Model, And Cost Observability

- Prompt/context inspector for selected runs, with secrets redacted.
- Model/client/status line with token usage, duration, and retry count.
- Cost or usage estimates when provider metadata is available.
- Compare selected run against a previous run with the same objective.
- Show active limits: max turns, max runtime, approval mode, workspace mode, and
  concurrency settings.

### Background Work And Notifications

- Background run list with status, latest evidence, and review-needed badge.
- Notifications for completed runs, review requests, failed checks, and blocked
  workflows.
- `/watch` mode for following a selected managed workflow or background run.
- `/pause` and `/resume` controls once runtime support is first-class.

### Safety, Accessibility, And Resilience

- High-contrast theme.
- Reduced-motion mode.
- Better narrow-screen layouts with explicit pane collapse rules.
- Plain ASCII snapshots for key screens.
- Terminal restore checks for startup errors, crashes, and backend failures.
- Render budget metrics for long conversations and large durable timelines.
- Log pane filters by level and source.

## Implementation Phases

### Phase 0: Content Boundary And Baseline Snapshots

Deliverables:

- [x] Add rendered-content structs and conversion from persisted messages,
      events, artifacts, and logs.
- [x] Add ExRatatui content view helpers that render current plain paragraphs
      through the new boundary.
- [x] Add baseline snapshots for current chat and debug panes.
- [x] Add a render-cache data structure with size limits and explicit keys.

Validation:

- [x] `mix format`
- [x] `mix compile --warnings-as-errors`
- [x] focused content-boundary unit tests
- [x] focused ExRatatui headless snapshots

### Phase 1: Markdown And Code Blocks

Deliverables:

- [x] Implement Markdown block normalization.
- [x] Render Markdown in conversation, details, and review modal surfaces.
- [x] Implement code and diff highlighting.
- [x] Add theme tokens for Markdown/code syntax roles.

Validation:

- [x] Markdown and syntax unit tests.
- [x] Headless snapshots at narrow and wide sizes.
- [ ] Manual TUI smoke with Markdown-rich assistant output.

### Phase 2: Graph Rendering

Deliverables:

- [x] Render persisted workflow graph artifacts through `GraphPresenter`.
- [x] Render Mermaid fenced blocks from Markdown.
- [x] Add async MMDFlux render commands and cache invalidation.
- [x] Preserve source fallback for blocked or failed MMDFlux renders.

Validation:

- [x] Graph presenter integration tests.
- [x] Headless graph pane tests.
- [ ] Manual MMDFlux smoke.

### Phase 3: Streaming Conversation Output

Deliverables:

- [x] Add stream buffer and message chunk handling.
- [x] Wire live terminal events or future stream events into the buffer.
- [x] Persist chunk/final state before display when part of run history.
- [x] Auto-follow only when appropriate.

Validation:

- [x] Stream buffer unit tests.
- [x] Headless injected-chunk tests.
- [ ] Manual streaming and non-streaming run smokes.

### Phase 4: Slash Completion

Deliverables:

- [x] Add suggestions model and suggestions pane.
- [x] Add command-name and contextual argument completion.
- [x] Update key handling so `Tab` completes in slash mode and moves focus
      outside slash mode.
- [x] Update `guides/TUI_CHEATSHEET.md`.

Validation:

- [x] Slash suggestion unit tests.
- [x] Headless key interaction tests.
- [ ] Manual command-discovery smoke.

### Phase 5: Agent Harness Polish

Deliverables:

- [x] Add `/new`, `/switch`, and `/rename` thread commands.
- [x] Add conversation search and jump commands.
- [x] Add expanded tool-call and diff preview cards.
- [x] Add log level/source filters.
- [x] Add prompt/context inspector with redaction.
- [x] Add background run notifications and follow mode.

Validation:

- [x] Focused unit and headless tests for each command.
- [ ] Manual multi-run TUI smoke.
- [ ] Manual review-gated and tool-heavy smoke.

## Definition Of Done

- [x] User-facing assistant responses render Markdown cleanly in the chat pane.
- [x] Code fences and diffs are readable and semantically colored.
- [x] Mermaid diagrams and persisted workflow graphs can render through
      MMDFlux when available and degrade to source when not.
- [x] Streamable outputs update the chat pane progressively without breaking
      composer input or selection.
- [x] Non-streamable records still appear as complete structured blocks.
- [x] Slash commands have tab completion and contextual suggestions.
- [x] The guide documents new commands and key behavior.
- [x] Narrow, wide, plain, and color TUI snapshots stay coherent.
- [x] Full verification passes:
      `mix format`, `mix compile --warnings-as-errors`,
      `mix test test/runic_ai/terminal test/runic_ai/persistence`, and
      `mix test`.

## Implementation Notes

Implemented on 2026-05-03.

- Added framework-neutral content primitives:
  `RunicAI.Terminal.RenderedContent`, `MarkdownBlocks`, `Syntax`, and
  `StreamBuffer`.
- Added ExRatatui presentation helpers:
  `RenderCache`, `CommandSuggestions`, `Views.Content`, and
  `Views.Suggestions`.
- Conversation messages now render through the content boundary. Assistant
  output uses ExRatatui's Markdown widget for normal Markdown/code fences, while
  Mermaid fences are split out and rendered through `GraphPresenter`.
- Workflow graph artifacts now render through `GraphPresenter` in
  text/Mermaid/MMDFlux modes. MMDFlux execution is queued through reducer
  commands and cached by source/mode/theme so views do not shell out.
- Live stream info messages update a bounded in-memory stream buffer and are
  written through terminal events when a persistence store is attached.
- Slash mode now has contextual suggestions and Tab completion for command
  names, graph modes, managed/eval statuses, run ids, tool names, and managed
  workflow keys.
- Added thread/navigation commands: `/new`, `/switch`, `/rename`, `/find`,
  `/next`, `/prev`, `/retry`, `/regenerate`, `/edit`, `/watch`, and `/pause`.
- Updated `guides/TUI_CHEATSHEET.md` for Markdown, graph modes, streaming,
  thread commands, and slash completion.

Remaining-polish pass on 2026-05-04:

- Added cached Markdown block preparation keyed by content hash, width, theme,
  color, and unicode mode, while keeping views on cached/fallback projections.
- Escaped raw HTML outside fenced code before sending assistant Markdown to the
  ExRatatui Markdown widget.
- Converted detail and review modal surfaces to Markdown, with prompt/context
  inspection and redaction for secret-like keys and token-like strings.
- Added `/logs [level|source:TERM|clear]` and `/prompt`, with log-level
  suggestions and filtered log display.
- Stream completion now persists and reloads from SQLite; failed and
  interrupted streams render visible partial-content markers.
- Added headless coverage for narrow/wide/plain snapshots, scrollback
  auto-follow suppression, missing MMDFlux fallback, async `/graph mmdflux`
  render queuing, and prompt/review redaction.

Deferred from this slice:

- Manual provider-backed streaming smoke and manual MMDFlux smoke.
- Manual command-discovery, multi-run, review-gated, and tool-heavy TUI smokes.

QA follow-up on 2026-05-04:

- Investigated the completed RLM TUI run
  `rlm:tui:HI7SBV3XTI:4:0259d2b9` in `.runic_ai/runs.db`.
  The durable conversation had only the user objective and an assistant
  `summary` row with `status: ok`; the final RLM episode output was present in
  terminal events but was not projected as a chat-visible assistant message.
- Fixed the RLM terminal runner to honor the TUI-provided `run_id` while
  preserving the stable `session_id`, so user messages, live RLM stages, final
  result events, and final summaries converge on the same workflow run.
- Added a coding-RLM final output event so completed RLM episode results project
  as non-transient assistant `workflow_output` messages in SQLite and render in
  the conversation pane.
- Added regression coverage for terminal event normalization, SQLite
  projection, and the ExRatatui `Commands.start_agent_run/2` path.
- Ran focused terminal/persistence tests, `mix compile --warnings-as-errors`,
  `mix test test/runic_ai/terminal test/runic_ai/persistence`, and full
  `mix test`.
- Manual/headless smoke results:
  - RLM TUI submission with a fake backend persisted a user objective plus a
    Markdown assistant `workflow_output`; the conversation widget contained the
    final output.
  - `guides/mental-model.md` produced three Mermaid blocks; the first block
    rendered through installed `mmdflux` with `status=pass`.

Remaining QA recommendations:

- Add an explicit replay/backfill command for older terminal events that
  contain RLM episode output but predate the chat-visible final-output event.
  The 2026-05-04 observed run remains a historical example unless re-run or
  backfilled.
- Add a warning state in the conversation pane when a completed run has a user
  objective and only assistant summary rows, so projection gaps are obvious.
- Tighten coding-RLM proposal/tool selection for prompts that reference
  sibling repositories under `~/wrk`; the observed prompt stayed inside
  `/home/doops/wrk/runic_ai` and the reducer reported file content rather than
  a synthesized three-repo summary.
- Still run provider-backed streaming and review-gated/tool-heavy manual
  smokes before calling the TUI polish pass fully QA-complete.

Formatting follow-up on 2026-05-04:

- A subsequent RLM TUI run projected an assistant `workflow_output`, but the
  content rendered as an inline inspected Elixir map with escaped newlines. The
  source was the coding RLM `:report` reducer falling back to `inspect/1` for
  structured tool outputs such as `read_many` file collections.
- Fixed the reducer to format known structured outputs as Markdown:
  file collections become file sections with fenced content, directory entries
  and search matches become readable lists, command outputs become stdout/stderr
  sections, and unknown maps fall back to fenced pretty inspection.
- Updated the terminal RLM final-output extraction to apply the report
  formatter when an episode returns structured map output directly.
- Added regression coverage for reducer Markdown formatting and structured RLM
  final-output event normalization.
- Validation passed: `mix format`, focused RLM/terminal/persistence/workbench
  tests, `mix compile --warnings-as-errors`, the expanded focused terminal /
  persistence / coding RLM test set, and full `mix test`.

Scroll/height follow-up on 2026-05-04:

- The latest completed RLM TUI run persisted a complete assistant
  `workflow_output` message, including the expected tail content. The apparent
  cutoff was isolated to the conversation widget presentation layer rather than
  LLM token limits or SQLite truncation.
- Fixed inline Mermaid graph cache keys so conversation message blocks fetch
  the same rendered MMDFlux output queued by `RenderCache.graph_sources/1`.
- Updated conversation row budgeting to measure the actual ExRatatui widget
  text used for the row, including cached multi-line graph output, instead of
  estimating from the raw message text only.
- Raised the per-message row cap from 1,200 to 10,000 rows so ordinary long
  assistant outputs are scrollable while still bounding widget-list height.
- Added regression coverage for a cached 40-line inline graph rendering in the
  conversation pane, including tail scroll math.
