# RunicAI Web Design Guide

Status: active

Date: 2026-05-06

Scope: Phoenix/LiveView local workbench UI, shared web design tokens, and
browser-facing RunicAI product surfaces. The older `.docs/DESIGN.md` remains
historical guidance for terminal and TUI surfaces.

Reference artifact: `.docs/design_refs/index.html`.

## Design Intent

RunicAI should feel like a local developer workbench for agent execution,
review, observability, and artifacts. The interface is dark, dense, calm, and
evidence-oriented. The runic tone comes from warm display typography, bronze
and gold accents, subtle glass surfaces, and selective symbols, not from
decorative noise.

Primary qualities:

- chat-first center pane for active session operation;
- durable SQLite-backed session history visible in the left rail;
- right inspector for trace, logs, artifacts, and details;
- persistent composer for launching or continuing local work;
- compact, work-focused labels with explicit status text;
- dark frosted surfaces over a quiet grid and glow background.

## Palette

Use OKLCH tokens in `assets/css/app.css` and expose them through Tailwind theme
colors.

| Token | Value | Use |
| --- | --- | --- |
| `bg` | `oklch(11% 0.026 282)` | main app background |
| `bg_deep` | `oklch(7% 0.018 282)` | body/base page background |
| `surface` | `oklch(16% 0.026 282)` | sidebar and inspector glass |
| `surface_2` | `oklch(20% 0.03 282)` | active controls, composer, raised rows |
| `surface_3` | `oklch(25% 0.034 282)` | stronger active states |
| `text` | `oklch(91% 0.025 82)` | primary content |
| `text_soft` | `oklch(73% 0.03 82)` | secondary readable text |
| `muted` | `oklch(56% 0.035 78)` | timestamps, labels, inactive chrome |
| `border` | `oklch(42% 0.065 65)` | bronze outlines and section rules |
| `border_soft` | `oklch(28% 0.04 67)` | quiet dividers |
| `primary` | `oklch(72% 0.14 164)` | running state, focus, primary status |
| `gold` | `oklch(77% 0.13 78)` | tool, evidence, send, brand accents |
| `bronze` | `oklch(58% 0.12 68)` | paths, metadata, inactive accents |
| `purple` | `oklch(64% 0.14 304)` | workflows, RLM, planning |
| `magenta` | `oklch(70% 0.18 333)` | review and rewrite states |
| `success` | `oklch(72% 0.14 150)` | passed, completed, approved |
| `warning` | `oklch(78% 0.15 74)` | waiting, review, partial evidence |
| `error` | `oklch(68% 0.17 24)` | failed, denied, destructive risk |
| `info` | `oklch(72% 0.12 235)` | neutral links and reference metadata |

## Typography

- UI font: `Inter`, falling back to system sans.
- Display font: `Iowan Old Style`, `Charter`, `Palatino Linotype`, `Georgia`.
- Monospace font: `JetBrains Mono`, `IBM Plex Mono`, system monospace.
- Use display type for product name, main session title, and inspector title.
- Use monospace for session IDs, timestamps, model names, status metadata, and
  debug tables.
- Keep letter spacing at `0`. Use uppercase labels sparingly for metadata.

## Shell Layout

Desktop layout:

- left sidebar: fixed session navigation and saved views;
- center pane: topbar, tabs, session content, persistent composer;
- right inspector: selected trace/log/artifact/details context;
- shell padding: `18px`;
- shell gap: `18px`;
- sidebar width: about `304px`;
- inspector width: about `410px`;
- main center minimum width: about `680px`.

Responsive behavior:

- below wide desktop, keep sidebar and center pane and let inspector become a
  fixed overlay when needed;
- below tablet width, hide sidebar and inspector and keep chat/composer usable;
- never let model names, paths, or long titles force horizontal overflow.

## Core Components

### Sidebar

- Brand block with compact mark, product name, and `local agent workbench`.
- Workspace section with current workspace path.
- Navigation rows for Session Workbench, Runs & Artifacts, Agents, Logs &
  Traces, and Local Settings.
- Recent sessions with status dot, title, agent/status metadata, and time.
- Saved views for Needs Review, Recent Artifacts, and Failed Checks.
- Footer health rows for runtime, SQLite, and local bind.

### Topbar

- Eyebrow: `Session <short id> - <status or approval state>`.
- Main title: selected session title or local workbench fallback.
- Pills for agent/status, model, SQLite source, and debug density.

### Session Tabs

- Inline segmented control above the chat surface.
- Initial tabs: Chat and Plan.
- Chat tab shows message count.
- Plan tab shows current lifecycle state or waiting review.

### Chat

- Single continuous glass panel with message rows separated by quiet dividers.
- User/objective messages use stronger primary text.
- Assistant messages include role mark, role label, timestamp, and message kind.
- Markdown content renders compactly with code, tables, lists, and blockquotes
  styled by the shared markdown rules.

### Activity Cards

- Three-column cards inside assistant messages for read, trace, next,
  verification, tools, or artifact summaries.
- Each card has an uppercase label, short strong title, and monospace detail.

### Review Card

- Amber/bronze bordered card embedded in chat.
- Shows action, command or tool preview, risk, path/context, and durable state.
- Actions: Approve once, Rewrite instruction, Deny, Stop session.
- Until handlers exist, disabled controls may be rendered as visible backlog.

### Composer

- Persistent footer with frosted shell.
- Large objective textarea.
- Right-side compact controls for agent, approval, mode, model, and send.
- Browser-visible controls should map to the real LiveView submit payload.

### Inspector

- Header with title and selected session/event context.
- Tabs: Trace, Logs, Artifacts, Details.
- Trace tab renders append-only record cards from persisted terminal events.
- Logs tab renders a dense table from the selected debug projection.
- Artifacts tab uses current tool calls and runs until artifact rows are wired.
- Details tab shows session, workspace, model, approval, database, and counts.

## Implementation Rules

- `DESIGN.md` is the default web design source. `.docs/DESIGN.md` is now
  terminal/TUI history unless a task explicitly targets terminal surfaces.
- Keep `assets/css/app.css` focused on Tailwind setup, theme tokens, fonts,
  shell primitives, scrollbars, and shared markdown styling.
- Prefer HEEx and Tailwind classes for component-specific styling.
- Use Phoenix's built-in Heroicons path through `<.icon>` for normal icons.
- Keep pages backed by durable RunicAI query/read-model APIs. Browser state may
  control visual tabs, but session messages, events, tools, runs, review
  decisions, and artifacts must come from SQLite-backed projections.
- Do not add marketing copy to the primary workbench. Show the user's sessions,
  runs, decisions, evidence, and controls directly.
- Cards are for repeated messages, activity items, artifacts, records, and
  modals. Avoid nesting cards inside cards except for meaningful embedded
  review/activity blocks inside a message.

## Feature Backlog From Prototype

- Shell collapse and restore for the right inspector.
- Client-side session and inspector tab persistence.
- First-class Plan tab with lifecycle steps and workflow graph preview.
- HITL review cards backed by persisted review requests and decisions.
- Review queue page and saved view.
- Artifact rows with real file/diff/provenance data.
- Logs, traces, and event filters backed by query params.
- Mermaid graph rendering with dark theme.
- Local settings and health pages.
