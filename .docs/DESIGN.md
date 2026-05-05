# RunicAI Terminal Design Guide

Status: draft

Date: 2026-05-01

Scope: terminal presentation for `mix runic_ai.agent`, the Owl/Bunt enhanced
CLI, and the future TermUI or ExRatatui TUI.

This is an internal design guide for UX and visual decisions. It should evolve
with implementation. Public docs should copy from this only when the behavior is
implemented and stable.

## Design Intent

RunicAI should feel like a professional developer tool with a cool magical
undertone. The theme is dark, compact, legible, and evidence-oriented. The
magical flavor comes from color, rhythm, and selective symbols, not from noisy
decoration.

Primary mood:

- dark terminal surface,
- beige/bronze/gold text warmth,
- mint/cyan primary action and focus,
- restrained purple/magenta accents for review and RLM,
- clear red/yellow/green operational status colors,
- high contrast without neon overload.

Terminals do not provide reliable application-controlled transparency. Treat
"semi transparent dark background" as a host terminal preference. RunicAI may
set dark surfaces for TUI panels, but the app should also look correct on a
user-configured translucent terminal background.

## Product Principles

- Developer density first: show what is happening, what changed, and what is
  blocked.
- Evidence over theater: final reports and verification results matter more
  than dramatic animation.
- Color is semantic: do not color arbitrary nouns differently from run to run.
- Motion is functional: spinners indicate active work; progress bars indicate
  known totals.
- Plain output is still a first-class surface for CI, logs, and JSONL.
- Every color-coded state must also have text or shape.
- ASCII fallback is mandatory. Unicode box drawing and symbolic glyphs are an
  enhancement, not a requirement.
- Keep terminal modules presentation-only. They should not decide agent logic.

## Palette

Truecolor palette for TermUI and capable terminals:

| Token | Hex | Use |
| --- | --- | --- |
| `bg` | `#0B0D10` | default dark terminal surface |
| `surface` | `#13110E` | panels, header, status bar |
| `surface_elevated` | `#1D1812` | active panel or modal background |
| `border` | `#5C4A32` | quiet bronze borders |
| `text` | `#E7D6B7` | primary beige text |
| `text_soft` | `#C7B28A` | normal secondary text |
| `muted` | `#7C6D58` | metadata, timestamps, inactive chrome |
| `primary` | `#62F5D4` | primary action, focus, active cursor |
| `primary_soft` | `#A6FFE9` | subtle glow text and selected labels |
| `gold` | `#F3C65F` | important tool/evidence accents |
| `bronze` | `#B77A35` | borders, tool metadata, inactive accents |
| `purple` | `#A78BFA` | RLM planning and workflow accents |
| `magenta` | `#FF5CCB` | review/HITL and rewrite accents |
| `success` | `#66E889` | success, objective satisfied, approved |
| `warning` | `#F6A94D` | warnings, partial evidence, risk |
| `error` | `#FF5C73` | errors, denied actions, failed checks |
| `info` | `#6BB6FF` | neutral info and links |

Bunt-compatible named colors to try before numeric 256-color fallbacks:

| Token | Bunt name |
| --- | --- |
| `text` | `:beige` |
| `text_soft` | `:khaki` |
| `muted` | `:dimgray` |
| `primary` | `:aqua` or `:aquamarine` |
| `primary_soft` | `:lightcyan` |
| `gold` | `:gold` |
| `bronze` | `:goldenrod` or `:chocolate` |
| `purple` | `:darkmagenta` |
| `magenta` | `:fuchsia` or `:hotpink` |
| `success` | `:springgreen` |
| `warning` | `:orange` |
| `error` | `:orangered` or `:red` |
| `info` | `:deepskyblue` or `:steelblue` |

Plain theme:

- no ANSI color,
- ASCII borders,
- status words in uppercase,
- stable spacing and indentation,
- no animated live blocks.

## Semantic Mapping

| State or Kind | Token | Notes |
| --- | --- | --- |
| active/running | `primary` | use sparingly for the current phase |
| pending | `muted` | lower contrast |
| ok/success | `success` | objective satisfied, command passed |
| review/HITL | `magenta` | risky action needs user decision |
| waiting | `warning` | blocked on external input or time |
| blocked | `warning` | not failed, but cannot continue |
| error | `error` | failed command, exception, invalid state |
| tool call | `gold` | commands, file operations, visible tools |
| verification | `success` or `warning` | pass/fail/partial decides exact token |
| RLM plan | `purple` | proposal, validation, compile, graph |
| repair | `warning` | repair loops and retry decisions |
| final summary | `text` with `gold` labels | evidence should be calm and readable |

## Typography

Recommended terminal fonts:

- JetBrains Mono
- IBM Plex Mono
- Berkeley Mono
- SF Mono
- Fira Code without relying on ligatures

Font assumptions:

- monospaced,
- Unicode width may vary by terminal,
- do not depend on ligatures,
- do not use tiny labels that require a specific font to distinguish.

Text scale in terminal output is simulated through hierarchy:

- uppercase status for major state,
- bold or bright only for selected/current content,
- indentation for grouping,
- tables for structured comparisons,
- boxes only for top-level header, modal review prompts, and final reports.

## Layout And Spacing

CLI:

- Header box: 1 line title, then compact key/value rows.
- Event rows: one row per event by default.
- Expanded detail: indented under the event it belongs to.
- Final report: table or box, never nested inside another box.
- Use one blank line before major sections, not between every event.

TUI:

- Status bar is one row when possible.
- Composer is always visible at the bottom unless a modal is active.
- The default local harness view is chat-first: user turns, assistant outputs,
  HITL prompts, tool activity, artifacts, and final status should be visible
  without opening a diagnostic pane.
- Timeline, run picker, graph, scorecard, and eval panes belong to the debug
  workbench view. They are first-class for inspection, but not the default
  answer surface.
- Detail/evidence pane should show selected event context in debug mode.
- Graph pane appears for RLM and workflow-heavy runs, not every standard run.
- Avoid nested framed panels. Split panes and top-level modals are enough.
- Query-backed TUI workbenches should keep SQLite as the durable source of
  truth and hold only bounded visible projections in app state.
- For ExRatatui, prefer `WidgetList` for long timelines, `Table` for run and
  eval cohorts, `Textarea` for the objective composer, and `Popup` only for
  review/HITL.
- Remote ExRatatui transport is a local-development/admin spike only. It must
  stay opt-in, require explicit auth configuration, and keep per-client UI state
  isolated while reading from the shared SQLite store.

Padding:

- CLI boxes: horizontal padding 1 or 2, vertical padding 0 or 1.
- Tables: padding 1 when width allows, 0 at narrow widths.
- TUI panels: 1 column internal padding for readable panes.
- Compact rows should keep timestamps and status aligned.

Width rules:

- Target 80 columns as the minimum useful width.
- Optimize for 100 to 140 columns when available.
- Truncate long paths from the left when the filename matters.
- Truncate long commands from the right after preserving command name.
- Never let model names, paths, or commands force layout overflow.

## Symbols And Unicode

Unicode mode may use:

- box drawing for top-level boxes and tables,
- check/cross/warning glyphs for statuses,
- spinner frames from Owl,
- Mermaid/mmdflux terminal graph output,
- small runic-like symbols only as optional accents.

ASCII fallback must use:

- `+`, `-`, `|` for boxes,
- `OK`, `ERR`, `WARN`, `WAIT`, `REVIEW` for states,
- `->` for graph edges,
- `*` or `-` for bullets,
- no reliance on color.

Do not use decorative symbols in high-volume event rows. The timeline should
scan quickly.

## Motion

Acceptable:

- spinner for active unknown-duration work,
- progress bar for known totals,
- live status text for current phase,
- smooth differential rendering in TermUI.

Avoid:

- blinking text,
- rapid color cycling,
- animated decoration unrelated to current work,
- progress bars with fake percentages.

Recommended spinner cadence: 80 to 120 ms. Slower is acceptable over SSH or
when terminal rendering is expensive.

## Components

### Header

Shows:

- product name,
- session id,
- workspace,
- agent,
- model/client,
- mode,
- approval policy,
- renderer,
- JSONL path when present.

### Timeline

One event row should answer:

- when did it happen,
- what kind of event is it,
- is it running/ok/waiting/review/error,
- what is the short title,
- is there a concise detail preview.

### Review Prompt

Shows:

- action requiring review,
- reason,
- tool/path/command preview,
- risk summary,
- available decisions,
- rewrite path when supported.

Review prompts should feel serious but not alarming unless the risk is high.

### RLM Graph

Show two graph concepts separately:

- proposal graph: intended generated workflow,
- execution graph: materialized Runic workflow and observed progress.

Do not mix proposed nodes and executed nodes without clear labeling.

### Evidence Report

Shows:

- objective status,
- changed files,
- verification observations,
- tool summary,
- repair count,
- residual risks,
- final response or artifact path.

Evidence should be calm, compact, and easy to copy into an issue or PR.

## Accessibility And Fallbacks

Required:

- respect `NO_COLOR`,
- provide `--color never`,
- provide `--unicode never`,
- support non-TTY output through plain renderer,
- avoid color-only status,
- avoid blinking,
- keep ASCII fallback snapshots in tests,
- keep JSONL trace independent of visual renderer.

Nice to have:

- high-contrast theme variant,
- reduced-motion option,
- width diagnostics in debug mode.

## Copy Style

Use short, concrete labels:

- `Tool call`
- `Verification passed`
- `Review required`
- `RLM proposal accepted`
- `Repair attempt`
- `Objective incomplete`

Avoid vague labels:

- `Doing magic`
- `Thinking hard`
- `Something happened`
- `Workflow stuff`

Terminal copy should describe state and evidence, not explain how the UI works.

## Decision Log

| Date | Decision |
| --- | --- |
| 2026-05-01 | Keep plain text output as a first-class renderer for CI and logs. |
| 2026-05-01 | Use Owl as the near-term CLI enhancement, not a replacement runtime. |
| 2026-05-01 | Treat Bunt as optional semantic color support behind `RunicAI.Terminal.Theme`. |
| 2026-05-01 | Treat TermUI as a separate TUI surface over `RunicAI.Terminal.Event`. |
| 2026-05-01 | Treat mmdflux as optional graph rendering; do not require Rust for the base CLI. |
| 2026-05-03 | Treat local harness commands and TUIs as SQLite-backed by default; in-memory/no-storage modes are explicit opt-outs. |
| 2026-05-03 | Spike ExRatatui as a Rust-rendered alternate TUI over the same persistence and terminal event model. |
| 2026-05-03 | Use globally unique durable run/event IDs for CLI harness persistence; BEAM-local counters are not acceptable for SQLite-backed local history. |
| 2026-05-03 | Keep ExRatatui SSH disabled by default and require explicit password/auth configuration for local development. |

## Open Questions

- Should Owl be the default renderer for local TTY usage after the first spike,
  or should users opt in with `--renderer owl` for one release?
- Is Bunt necessary once Owl and TermUI theme support are wired, or should
  `RunicAI.Terminal.Theme` encode truecolor and ANSI fallbacks directly?
- Should mmdflux integration start as a shell-out wrapper, a Rust NIF, or both
  behind separate options?
- How much runic symbolism is useful before it hurts scanability?
