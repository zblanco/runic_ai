# TUI Cheatsheet

Run the local RunicAI workbench:

```bash
mix runic_ai.tui
```

By default the TUI uses the current directory as `--cwd`, starts in assistant
mode, starts a fresh conversation thread for that TUI session, and stores local
harness data in `.runic_ai/runs.db`.

## Start

```bash
mix runic_ai.tui --cwd /path/to/project
mix runic_ai.tui --cwd /path/to/project --model openai:gpt-5.4-mini
mix runic_ai.tui --run RUN_ID
mix runic_ai.tui --session-id THREAD_ID
mix runic_ai.tui --persistence memory
```

Useful startup flags:

- `--agent assistant|standard|rlm`
- `--mode read_only|patch|verify`
- `--approve ask|safe|never`
- `--sqlite PATH`
- `--theme runic|plain`
- `--graph text|mermaid|mmdflux`

## Conversations

Type a normal prompt in the composer and press `Enter`.

That starts a new durable agent run inside the current conversation thread and
projects the user request plus assistant output into that thread. The thread id
is stable for the TUI session, so follow-up prompts can refer to earlier
assistant messages. Use `/new` for a fresh thread, or `/switch` / `--run` /
`--session-id` to resume prior work.

Assistant messages render as Markdown in the conversation pane, including code
fences. Mermaid fences and persisted workflow graph artifacts follow the current
graph mode: `text`, `mermaid`, or `mmdflux`.

The conversation pane scrolls independently from the rest of the chat view. It
shows a scrollbar and a title status such as `tail`, `top`, or `N rows back`.

## Views

Chat view is the default. It has a compact status row, a compact activity
summary row, one full-width conversation pane, and the composer at the bottom.
Use debug view for detailed activity, logs, traces, and persisted records.

Debug view exposes the durable run data:

- runs
- timeline events
- runnable/node details
- tool calls
- captured Logger output
- artifacts
- scorecards
- repair attempts
- review requests
- managed workflows
- eval cohorts
- workflow graph

Press `F2` or use `/chat` and `/debug` to switch views.

## Keys

- `Enter` submits the composer or slash command.
- `/` enters slash mode when the composer is empty.
- `Esc` cancels slash mode / clears the slash input.
- `Tab` moves focus forward outside slash mode.
- `Shift-Tab` moves focus backward outside slash mode.
- `Tab` completes the selected slash suggestion in slash mode.
- `Shift-Tab` moves backward through slash suggestions in slash mode.
- `PgUp` / `PgDn` scrolls the chat conversation by larger row jumps.
- `Up` / `Down` scrolls the conversation when that pane is focused.
- `Up` / `Down` navigates submitted prompt history when the composer is focused.
- `Up` / `Down` moves the selected row in other focused panes.
- `Home` / `End` jumps the focused conversation pane to top or tail.
- Mouse wheel scrolls the chat conversation in chat view.
- `F2` toggles chat/debug view.
- `Ctrl-S` stops the current active run marker.
- `Ctrl-Q` or `Ctrl-C` exits.

Plain letters type into the composer; they are not global shortcuts.

## Slash Commands

- `/help` shows the command list.
- `/chat` switches to chat view.
- `/debug` switches to debug view.
- `/new` starts a fresh named conversation thread for subsequent submissions.
- `/switch RUN_OR_THREAD` selects an existing run/thread.
- `/rename TITLE` renames the selected durable run.
- `/runs [query]` focuses the run picker.
- `/search TERM` searches persisted terminal events.
- `/find TERM` searches the current conversation.
- `/source TERM` aliases `/search TERM`.
- `/next [user|assistant|tool|review|error|final]` jumps in the conversation.
- `/prev [user|assistant|tool|review|error|final]` jumps backward.
- `/errors` filters timeline events with `error` or `blocked` status.
- `/reviews` focuses review/debug details.
- `/tools [name]` focuses tool/debug details.
- `/artifacts` focuses artifact/debug details.
- `/scorecard` focuses scorecard/debug details.
- `/repairs` focuses repair/debug details.
- `/logs [level|source:TERM|clear]` filters captured logs in debug/detail views.
- `/prompt` opens the redacted prompt/context inspector in the detail pane.
- `/managed [status]` loads managed workflow rows, optionally by status.
- `/start [workflow_key]` creates a pending managed workflow run.
- `/resume [workflow_key]` requests resume for a managed workflow.
- `/export [path]` exports the selected run as JSONL.
- `/eval [objective_status]` loads eval cohort rows.
- `/graph text|mermaid|mmdflux` changes graph rendering mode.
- `/retry` or `/regenerate` retries the last user turn.
- `/edit` copies the last user turn back into the composer.
- `/watch` follows the active conversation tail.
- `/pause` pauses follow mode.
- `/stop` stops the current active run marker.
- `/quit` exits.

Slash mode shows contextual suggestions above the composer. Command names,
graph modes, log levels, managed workflow keys, run ids, tool names, and common
status values can be completed with `Tab`.

## Persistence

SQLite is the normal local harness path. The default database is:

```text
.runic_ai/runs.db
```

Use `--persistence memory` for disposable local testing, or
`--persistence none` when you only want the live UI and no durable run data.

When `NO_COLOR` is set, the TUI defaults to `--theme plain` unless an explicit
`--theme` is provided.

The TUI reads the same durable projections used by `mix runic_ai.agent` and
`mix runic_ai.runs`: messages, terminal events, runnable events, tool calls,
artifacts, scorecards, repairs, managed workflows, and eval records.

Streamable assistant output is shown progressively when the active runner emits
chunks. Structured records such as scorecards, review requests, graph artifacts,
and managed workflow rows still appear as complete records.

## Review And Writes

`--approve ask` is the conservative default. `--approve safe` auto-approves
low-risk review requests, and `--approve never` denies review-gated work.

Assistant workflow artifact writes go through review when the terminal runner
supplies a review decider. Read-only filesystem access can inspect paths outside
the current project for local harness work; writes remain gated by workspace
write policy and review behavior.

## Current Caveats

- `/stop` marks the TUI run inactive; it is not a general process kill for every
  backend shape.
- Review decisions are durable in the model, but the modal decision key path is
  still settling. Prefer startup `--approve` policy for now.
- MMDFlux graph rendering requires the `mmdflux` executable on `PATH`; otherwise
  the TUI falls back to readable Mermaid source.
