# 039 Design Handoff For Tidewave

Status: active handoff

Date: 2026-05-06

Audience: Tidewave or another browser-integrated LiveView agent continuing
`.docs/039-phoenix-liveview-local-agent-workbench-plan.md`.

## Current Goal

Continue the Phoenix LiveView local agent workbench implementation after the
first major visual-system pass. The immediate product target is still plan 039:
a local, SQLite-backed RunicAI browser workbench for sessions, chat, HITL
review, tool activity, artifacts, traces, and workflow inspection.

The latest definition of done for the visual pass was: the existing localhost
interface should visually resemble the exported prototype screenshot from
`.docs/design_refs/index.html`.

## Design Sources

Use these in order:

1. `DESIGN.md` at the repo root. This is now the active web design system.
2. `.docs/design_refs/index.html`. This is the exported HTML/CSS prototype.
3. `.docs/039-phoenix-liveview-local-agent-workbench-plan.md`. This is the
   canonical implementation plan and checklist.
4. `.docs/DESIGN-deprecated.md` only for older terminal/TUI context.

If the Open Design MCP is available, the relevant project is `runic_ai_alt`.
During the previous pass, the Open Design daemon was not reachable at
`127.0.0.1:17456`, so implementation used the checked-in prototype export.

## Files Changed In The Visual Pass

- `DESIGN.md`
  - New root design guide for web UI work.
  - Defines the OKLCH palette, typography, shell layout, component rules, and
    backlog from the prototype.
- `assets/css/app.css`
  - Reworked as the Tailwind v4 configuration and shared design-token surface.
  - Added root CSS variables, Tailwind theme mappings, frosted shell helpers,
    chat/composer/review surfaces, scrollbars, and markdown styling.
- `lib/runic_ai_web/live/workbench_live.ex`
  - Replaced the prior utilitarian shell with the prototype structure:
    frosted left sidebar, topbar pills, chat/plan tabs, chat-first center pane,
    persistent composer, and right inspector tabs.
  - Kept the existing SQLite-backed data path through `RunicAI.Workbench`.
  - Added visual review card shells, activity cards, plan steps, trace records,
    log table, artifact placeholders, and details panel.
- `.docs/039-phoenix-liveview-local-agent-workbench-plan.md`
  - Updated to point web design work at `DESIGN.md` and the prototype export.
  - Marked the visual shell work complete.
  - Recorded remaining Phase 2 and Phase 3 work.

## Verified State

Commands that passed after the design pass:

```sh
mix compile --warnings-as-errors
mix assets.build
mix test test/runic_ai_web/workbench_live_test.exs
mix test
```

Full test result at the time of handoff:

```text
535 tests, 0 failures, 2 skipped
```

Browser checks against the already-running `http://localhost:4000` server:

- desktop viewport around `1792x1079`;
- narrow viewport around mobile width;
- no browser console errors or warnings;
- no horizontal overflow in either checked viewport;
- assets loaded with HTTP 200.

Reference screenshots from that check:

- `/tmp/runicai-workbench-redesign.png`
- `/tmp/runicai-workbench-redesign-mobile.png`

These screenshots are temporary local artifacts, not durable docs.

## Current LiveView Shape

`RunicAIWeb.WorkbenchLive` currently uses:

- `mount/3` for stable assigns, defaults, form shape, health, subscriptions,
  debug modes, workspace tab, and inspector tab;
- `handle_params/3` to select the requested session and hydrate the snapshot;
- `handle_event/3` for new objective submission, debug mode/kind changes, and
  visual tab switching;
- `handle_info/2` for PubSub invalidations from terminal events;
- `RunicAI.Workbench.recent_sessions/1` and
  `RunicAI.Workbench.session_snapshot/1` as the read-model boundary.

Keep that split. New server-side effects belong in `handle_event/3`, but
session messages, events, tool calls, runs, review decisions, and artifacts
should remain backed by persisted RunicAI query/read-model APIs, not
LiveView-only state.

## Important Caveats

The current design pass intentionally made UI-level progress before completing
all backing features.

- The review card is visual only. The approve, rewrite, deny, and stop buttons
  are disabled until durable review handlers are implemented.
- The Plan tab is a lightweight projection from the current session snapshot,
  not a real workflow graph or generated plan view yet.
- The inspector Artifacts tab is populated from existing tool call and workflow
  run projections. It is not yet a real artifact/file-change provenance view.
- The composer launches a new objective. It does not yet support follow-up
  continuity into the selected session.
- The inspector collapse button is visual only.
- Saved views and left-nav destinations are visual placeholders until routes or
  filters are added.

Do not treat these as regressions. They are the intended next implementation
targets.

## Recommended Next Slice

Start with Phase 3 review functionality because it is the most important
operator flow shown in the prototype.

1. Inspect the current persistence/read-model modules for review request and
   decision support:
   - `RunicAI.Persistence.Queries`
   - `RunicAI.Persistence.HarnessProjection`
   - `RunicAI.Persistence.Schemas.ReviewRequest`
   - `RunicAI.ReviewDecision`
   - `RunicAI.Coding.ReviewGate`
   - `RunicAI.Workbench`
2. Add a `RunicAI.Workbench` API for pending review requests and persisted
   decisions if one does not already exist.
3. Wire LiveView `handle_event/3` actions for:
   - approve once;
   - deny;
   - rewrite instruction;
   - stop session.
4. Make each handler persist the decision before runtime continuation.
5. Replace the disabled review buttons with real controls only after the
   durable write path exists.
6. Add focused LiveView and persistence tests for approve, deny, rewrite, and
   stop.
7. Use Tidewave/browser checks to exercise a real pending-review session and
   verify that the card remains visible after refresh.

After review handlers, move to:

- follow-up composer continuity;
- real artifact/file-change rows and provenance;
- inspector collapse and persisted client tab state;
- review queue saved view/page;
- query-param backed debug filters;
- Mermaid graph rendering for workflow-heavy runs.

## Browser QA Checklist

For each UI slice, verify through the running browser, not only tests:

- page renders at `http://localhost:4000`;
- no console errors;
- no horizontal overflow at desktop and narrow widths;
- sidebar, center pane, composer, and inspector do not overlap;
- long titles and paths truncate cleanly;
- selected session survives refresh;
- persisted messages/events reload from SQLite;
- LiveView events do not require hidden browser-only state to reconstruct the
  page.

## Working Assumptions

- This is in-flight development. Breaking changes are acceptable when they
  simplify the current app.
- Keep the Phoenix graft in this repo unless the user explicitly revisits that
  decision.
- Keep local development on `localhost:4000` for Tidewave compatibility.
- Keep `assets/css/app.css` focused on Tailwind setup, tokens, shared shell
  primitives, and markdown styling.
- Prefer class-first HEEx and small function components for component-specific
  UI.
- Use Phoenix's built-in Heroicons path through `<.icon>`.
- Avoid broad custom CSS unless it belongs to the shared design scheme.
