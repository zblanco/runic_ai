# Owl And Bunt CLI Terminal Presentation Enhancement Plan

Status: Owl/Bunt renderer slice implemented; source-diagram Mermaid-to-terminal
mmdflux tooling implemented for the standard agent with Markdown,
Livebook/Kino, and bounded directory discovery; runtime graph presenter and
review rewrite mapping implemented; live blocks and large model/terminal
artifact separation remain deferred

Last verified: 2026-05-02 (`mix compile --warnings-as-errors`; `mix test`;
`git diff --check`; focused `mix test test/runic_ai/terminal
test/runic_ai/coding/tools_test.exs`). Earlier 2026-05-01 manual verification
covered `mix deps.get`, `mix runic_ai.agent --help`, and focused
Mermaid/mmdflux standard-agent smokes, including Livebook/Kino diagram
extraction and final-report diagram rendering.

Last re-evaluated: 2026-05-02 after interactive source-diagram rendering smokes
against guide and Livebook Mermaid content.

Date: 2026-05-01

Motivated by:

- `.docs/029-minimum-compelling-cli-terminal-interface-exploration.md`
- `.docs/030-minimum-compelling-cli-terminal-interface-implementation-plan.md`
- `.docs/DESIGN.md`
- The current `mix runic_ai.agent` implementation in `lib/runic_ai/terminal`.

External references:

- Owl v0.13.0: https://hex.pm/packages/owl and https://hexdocs.pm/owl
- Bunt v1.0.0: https://hex.pm/packages/bunt and https://hexdocs.pm/bunt/Bunt.html
- mmdflux: https://github.com/kevinswiber/mmdflux and https://docs.rs/mmdflux

## Context

Option A from `.docs/030` is implemented: `mix runic_ai.agent` parses a
developer objective, runs the standard, RLM, or assistant agent route, emits
normalized `RunicAI.Terminal.Event` values, renders a plain text timeline, and
can export JSONL.

The next pragmatic step is Option B from `.docs/029`: keep the same Mix task,
runner modules, event contract, and JSONL trace shape, but replace the plain
terminal surface with a more legible Owl/Bunt presentation layer.

The old OTP concern from `.docs/029` is no longer the deciding constraint in
this checkout. Local verification on 2026-05-01 shows Elixir 1.19.5 on OTP 28.
That makes TermUI viable as a separate plan, but Owl remains the smaller
near-term enhancement because it does not require an alternate-screen
application architecture.

## Goal

Make the existing CLI feel like a real developer tool without changing how
agents run.

The enhanced CLI should improve scanning, review prompts, progress feedback,
graph summaries, final evidence, and color semantics while preserving:

- the existing `mix runic_ai.agent` command path,
- current plain text and JSONL output,
- testable renderer boundaries,
- non-interactive and CI-friendly behavior,
- the framework-neutral `RunicAI.Terminal.Event` contract.

## Default Style For This Iteration

This implementation should use the Runic palette from `.docs/DESIGN.md` as the
default terminal style now, not wait for the later TermUI work. The Owl/Bunt CLI
is the right place to tune the first real version of the color language because
it has a smaller rendering surface than the full TUI.

Defaults for this iteration:

- Theme: `runic`
- Renderer: `auto`, resolving to Owl for local interactive terminals and text
  for CI/non-TTY output
- Color: `auto`, respecting `NO_COLOR`, with `always` and `never` overrides
- Text: beige/khaki normal text
- Primary active/focus color: aqua/aquamarine mint-cyan
- Tool/evidence accents: gold/goldenrod/bronze
- Review/HITL accents: fuchsia/hotpink/magenta
- RLM accents: dark magenta/purple
- Success/warning/error: springgreen, orange, orangered/red

The first implementation should keep color token definitions centralized in
`RunicAI.Terminal.Theme` so this CLI can tune the defaults before TermUI consumes
the same semantic decisions.

## Non-Goals

- Do not introduce a full alternate-screen TUI in this plan.
- Do not move agent control flow into Owl callbacks or Bunt formatting code.
- Do not require color, Unicode, or a live terminal for JSONL export or tests.
- Do not make mmdflux or a Rust toolchain mandatory for the base CLI.
- Do not rework standard-agent or RLM execution semantics unless an existing
  terminal event is missing essential data.

## Package Fit

### Owl

Owl is the main dependency for the CLI enhancement. Current docs describe it as
a command-line UI toolkit with `Owl.Data`, `Owl.IO`, `Owl.Box`, `Owl.Table`,
`Owl.ProgressBar`, `Owl.Spinner`, and `Owl.LiveScreen`.

Useful surfaces for RunicAI:

- `Owl.Data.tag/2`, `truncate/2`, `add_prefix/2`, and `length/1` for
  width-aware styled text.
- `Owl.Box.new/2` for compact headers, review prompts, and final reports.
- `Owl.Table.new/2` for scorecards, changed files, tools used, and RLM node
  summaries.
- `Owl.IO.confirm/1`, `input/1`, `select/2`, and `open_in_editor/2` for
  review decisions and rewrite flows.
- `Owl.Spinner` and `Owl.ProgressBar` for long-running RLM stages and
  verification runs.
- `Owl.LiveScreen` for live status blocks while still printing the event
  timeline above dynamic blocks.

### Bunt

Bunt is optional but attractive for semantic 256-color names. Its docs describe
256-color ANSI output, `Bunt.ANSI` as an `IO.ANSI`-style interface, and
user-defined color aliases. It also ships with named colors that map well to
the Runic theme, including `:beige`, `:gold`, `:goldenrod`, `:aqua`,
`:aquamarine`, `:springgreen`, `:fuchsia`, `:orange`, and `:orangered`.

Use Bunt only behind `RunicAI.Terminal.Theme`. Owl should remain the primary
rendering surface. If Bunt integration creates impedance with Owl tags, keep
Bunt out of the first implementation and encode the palette with Owl-compatible
ANSI sequences first.

### mmdflux

mmdflux can render Mermaid to terminal text, SVG, and MMDS JSON, with a Rust
CLI/library and a high-level API around `render_diagram`, `detect_diagram`, and
`validate_diagram`.

For this plan, treat mmdflux as an optional graph renderer:

1. Start with current text adjacency lists.
2. Add a `RunicAI.Terminal.Mermaid` data adapter that can produce Mermaid from
   normalized RLM graph data.
3. Add a shell-out adapter only when a `mmdflux` binary is present.
4. Consider a minimal Rust NIF wrapper later, ideally in an optional namespace
   or dependency path, so the base CLI does not require Rust.

Follow-up implementation note: the standard coding agent now has interim
read-only `extract_diagrams` and `render_mermaid` tools for developer prompts
such as "render the Mermaid diagram from this guide using MMDFLUX." These tools
are intentionally separate from the future terminal `GraphPresenter`:
`extract_diagrams` lists Mermaid candidates from raw `.mmd` files, Markdown
Mermaid fences, and Livebook `Kino.Mermaid.new("""...""")` calls while marking
dynamic `Kino.Mermaid.new(expression)` calls as non-renderable;
`render_mermaid` selects by index or nearby/fuzzy query text, accepts inline
Mermaid source, shells out to `mmdflux` only when the binary is present, and
returns a structured `:pass`, `:fail`, or `:blocked` observation without
mutating the workspace. The terminal presenter recognizes successful mmdflux
tool observations and prints the rendered diagram block even in collapsed mode
so "render this diagram" requests produce visible terminal output. Standard-agent
summaries also carry bounded rendered diagrams into the final report; the Owl
renderer appends them after the boxed summary to preserve terminal line art.
Search result line previews are also bounded so generated one-line docs
artifacts cannot inflate the next LLM request before the agent reaches the
diagram tools.

## Graph Rendering Re-Evaluation

The graph-rendering iteration changed the shape of the remaining work. The
original Phase 5 treated mmdflux mostly as an optional terminal graph renderer.
The live smokes showed two distinct needs:

1. Developer source-diagram tooling.
   A developer asks the standard agent to find, extract, render, and discuss
   Mermaid diagrams already present in guides, README files, and Livebooks.
   This is now useful enough to keep as a first-class read-only coding tool
   surface: `extract_diagrams` plus `render_mermaid`.

2. Runtime graph presentation.
   RunicAI should render generated Runic/RLM workflow data as adjacency text,
   Mermaid source, or mmdflux output. This is still the future
   `RunicAI.Terminal.GraphPresenter` track and should consume normalized graph
   data, not source files.

Lessons from the smokes:

- File-scoped extraction is reliable, but directory-level prompts currently
  tempt the model into broad `list_dir` / `search_text` exploration. Add a
  bounded project diagram inventory route before relying on open-ended search
  for source diagrams.
- Follow-up prompts in interactive mode need better target carryover. A prompt
  like "now render the Mermaid diagrams" should reuse the previous diagram file
  or candidate set when one exists, rather than restarting discovery from `.`.
- Rendered ANSI diagrams are terminal artifacts. They should be visible in tool
  logs and final reports, but model-facing observations should stay concise or
  artifact-backed for large diagrams so line art does not become prompt bloat.
- Owl boxes are appropriate for final-report metadata and prose. Wide mmdflux
  line art should stay outside boxed key/value reports or inside a dedicated
  preformatted block.
- Dynamic `Kino.Mermaid.new(expression)` calls should remain listed but
  non-renderable by default. Evaluating notebook code just to render diagrams
  needs a separate explicit safety plan.

Plan adjustment: finish the source-diagram tooling hardening before building the
runtime `GraphPresenter`. Then reuse the same rendering/output discipline for
runtime workflow graphs.

## Proposed Command Shape

Keep the existing command as the stable entry point:

```sh
mix runic_ai.agent "summarize this repo" --agent standard --cwd .
mix runic_ai.agent "plan a safe refactor" --agent rlm --cwd . --renderer owl
mix runic_ai.agent --interactive --agent standard --renderer owl
mix runic_ai.agent "inspect a plan" --jsonl tmp/trace.jsonl --renderer text
```

Add narrowly scoped presentation options:

- `--renderer auto|text|owl`
- `--color auto|always|never`
- `--theme runic|plain`
- `--progress auto|off`
- `--unicode auto|always|never`
- `--graph text|mermaid|mmdflux`

Defaults:

- `--renderer owl` when stdout is a terminal and Owl is available.
- `--renderer text` when stdout is not a terminal, `TERM=dumb`, or `CI=true`.
- `--color auto`, respecting `NO_COLOR` and Elixir ANSI support.
- `--unicode auto`, with ASCII fallback for boxes, bullets, and graph lines.
- `--graph text` until mmdflux support is proven.

## Architecture

Preserve the current runner pipeline:

```text
Mix.Tasks.RunicAi.Agent
  -> RunicAI.Terminal.CliOptions
  -> RunicAI.Terminal.AgentRunner
  -> StandardRunner | RLMRunner | AssistantRunner
  -> RunicAI.Terminal.Event
  -> renderer + JSONL sink
```

Add renderer selection at the `AgentRunner` boundary:

```text
lib/runic_ai/terminal/
  renderer.ex
  theme.ex
  owl_presenter.ex
  owl_live_session.ex
  graph_presenter.ex
```

Responsibilities:

- `RunicAI.Terminal.Renderer` defines the small callback surface:
  `start/1`, `render_header/1`, `render_event/2`, `render_review_prompt/2`,
  `render_final_report/2`, and `stop/1`.
- `RunicAI.Terminal.EventPresenter` remains the existing plain text renderer.
- `RunicAI.Terminal.OwlPresenter` returns `Owl.Data.t()` for headers, event
  rows, review prompts, tables, and final reports.
- `RunicAI.Terminal.OwlLiveSession` owns optional `Owl.LiveScreen`, spinner,
  and progress block lifecycle.
- `RunicAI.Terminal.Theme` maps semantic tokens to Owl/Bunt/TermUI-friendly
  values.
- `RunicAI.Terminal.GraphPresenter` renders current adjacency text first, then
  Mermaid/mmdflux when enabled.

Keep the JSONL sink independent of renderer selection.

## Phase 0: Dependency And Compatibility Spike

Deliverables:

- [x] Add `{:owl, "~> 0.13"}` to `mix.exs`.
- [x] Add `{:bunt, "~> 1.0"}` to `mix.exs` for the first Runic default style
      pass.
- [x] Verify `mix deps.get`, `mix compile --warnings-as-errors`, and
      `mix test test/runic_ai/terminal`.
- [x] Add a tiny `RunicAI.Terminal.OwlSmoke` module or test helper that renders
      a tagged line, table, box, prompt label, and non-live spinner-free status.
      Implemented as focused `OwlPresenter` and `Theme` tests rather than a
      runtime module.
- [x] Verify output with ANSI disabled, `NO_COLOR=1`, and non-TTY capture.
- [x] Document any Owl/Bunt incompatibilities in this plan. Current notes:
      final-report prose uses boxes instead of nested Owl tables because long
      markdown replies can create visual row drift; live screen/spinner support
      remains deferred until the static renderer and event stream are stable.

Validation:

- [x] Unit test that renderer selection falls back to text in non-TTY mode.
- [x] Unit test that `--color never` removes ANSI sequences.
- [x] Unit test that `--unicode never` renders ASCII-safe borders and graph
      markers.

## Phase 1: Semantic Theme Tokens

Deliverables:

- [x] Add `RunicAI.Terminal.Theme`.
- [x] Encode semantic tokens from `.docs/DESIGN.md`:
      `:text`, `:muted`, `:heading`, `:primary`, `:focus`, `:success`,
      `:warning`, `:error`, `:review`, `:rlm`, `:tool`, `:verification`,
      `:border`, `:surface`, and `:dim`.
- [x] Provide conversion helpers for:
      `owl_tag(token)`, `ansi_fragment(token)`, `plain(token)`, and a data-only
      `style_attrs(token)` map future TermUI modules can consume.
- [x] Keep color decisions out of `EventPresenter`, `OwlPresenter`, and future
      TermUI modules.
- [x] Add a theme fixture test that proves every event kind and status maps to
      a semantic token.

Validation:

- [x] Unit test token lookup for runic and plain themes.
- [x] Unit test `NO_COLOR` and `--color never` behavior.
- [x] Unit test unknown token failure messages.

## Phase 2: Owl Event Timeline Renderer

Deliverables:

- [x] Add `RunicAI.Terminal.OwlPresenter.render_header/1`.
- [x] Render the header as a compact box with session id, workspace, agent,
      model/client, mode, detail, approval policy, and JSONL path.
- [x] Render event timeline lines with stable columns:
      time, status glyph/fallback, kind/phase, title, and detail preview.
- [x] Use color by semantics, not by arbitrary event text:
      review is magenta/purple, tools are gold/bronze, verification is green or
      warning, errors are red, active work is primary mint/cyan.
- [x] Use Owl width-aware truncation for long titles, commands, paths, and
      model text.
- [x] Keep collapsed and expanded detail behavior equivalent to current text
      renderer.
- [x] Add renderer selection to `CliOptions` and `AgentRunner`.

Validation:

- [x] Unit test event rendering with ANSI disabled.
- [x] Unit test representative event kinds:
      `:status`, `:message`, `:tool`, `:hitl`, `:rlm_plan`, `:rlm_node`,
      `:verification`, `:repair`, `:error`, and `:summary`.
- [x] Compare one standard fixture rendered by text and Owl to ensure no data is
      lost.

## Phase 3: Owl Review And Rewrite Prompts

Deliverables:

- [x] Replace the current plain `[a] approve [d] deny [s] final stop` prompt
      with an Owl review box when `--renderer owl`.
- [x] Use `Owl.IO.select/2` or `Owl.IO.confirm/1` for approve, deny, and final
      stop decisions.
- [x] Add rewrite support using `Owl.IO.open_in_editor/2` when
      `ELIXIR_EDITOR` is available.
- [x] Keep plain stdin prompt behavior for non-TTY and text renderer paths.
- [x] Make blocked non-interactive review decisions render a clear, styled
      blocked event before exiting.

Validation:

- [x] Unit test decision mapping without invoking real stdin.
- [x] Unit test rewrite text handoff at the review boundary.
- [ ] Manual smoke a review-gated scripted standard-agent run.

## Phase 4: Final Reports, Tables, And Progress Blocks

Deliverables:

- [x] Render final reports as boxed key/value sections with wrapped multiline
      values. Avoid nested Owl tables for final reports because long markdown
      replies can contain continuation lines that table rendering treats as
      separate rows.
- [ ] Render RLM proposal and execution summaries as compact tables before any
      diagram renderer is enabled.
- [ ] Add optional `Owl.LiveScreen` status blocks:
      current phase, current tool, elapsed time, review status, and RLM stage.
- [ ] Use `Owl.Spinner` for unknown-duration phases:
      LLM request, RLM proposal, validation, compile, verification, and repair.
- [ ] Use `Owl.ProgressBar` only when total work is known, such as RLM node
      count or fixture-backed scripted stages.
- [ ] Ensure live blocks flush and stop cleanly on success, error, timeout, and
      user interruption.
- [x] If live blocks are too much for this first style iteration, keep them as
      the next enhancement after the static Owl/Bunt renderer is stable.

Validation:

- [ ] Unit test table data generation separately from terminal rendering.
- [ ] Unit test live-session lifecycle with a fake live screen adapter.
- [ ] Manual smoke a standard one-shot and RLM one-shot with live blocks
      enabled.

## Phase 5: Graph Rendering And mmdflux Optional Adapter

Deliverables:

- [x] Add interim read-only standard-agent tools, `extract_diagrams` and
      `render_mermaid`, for Mermaid fenced blocks, Livebook/Kino literal
      diagrams, nearby query text selection, and inline Mermaid source. This
      covers practical developer requests before the terminal graph presenter
      exists.
- [x] Add `RunicAI.Terminal.GraphPresenter` with pure graph data input.
- [x] Keep current adjacency list as the default graph renderer.
- [x] Add Mermaid generation for normalized dependency graphs, including RLM
      proposed workflows and assistant/RLM graph-shaped proposal data.
- [ ] Extend Mermaid generation to compiled workflow data that lacks normalized
      nodes and to a standard-agent OODA phase summary.
- [x] Add `--graph mermaid` to print Mermaid source in expanded mode.
- [x] Add `--graph mmdflux` only when the `mmdflux` binary is found.
- [x] Shell out with a narrow command wrapper for the interim tool:
      `mmdflux --format text --color auto|always|off`, temporary `.mmd` input
      outside the workspace, and structured blocked output when the binary is
      missing.
- [x] Surface successful interim `mmdflux` tool observations in the terminal
      event stream so collapsed output shows the rendered ANSI diagram instead
      of only an inspected tool-result map.
- [x] Carry bounded `render_mermaid` observations into the standard-agent final
      report, with Owl rendering diagrams outside the summary box to avoid
      wrapping and alignment drift.
- [x] Add a bounded project diagram inventory path, either as `find_diagrams`
      or a directory mode for `extract_diagrams`. It should scan only relevant
      Markdown, Livebook, `.mmd`, and `.mermaid` files; respect ignore lists;
      cap candidate counts and previews; and avoid generated `doc/dist` blobs.
- [x] Add interactive target carryover for source diagrams so follow-up prompts
      can reuse the previous diagram file/candidate set instead of restarting
      discovery from the workspace root.
- [ ] Split terminal-facing rendered diagram artifacts from model-facing tool
      observations when output is large. The model should receive status,
      source metadata, and a short preview or artifact reference; the terminal
      renderer can still print the full bounded diagram.
- [x] Add the final terminal graph-presenter wrapper with bounded timeout,
      bounded output, and explicit color handling through either `NO_COLOR=1`
      or `--color always` based on the RunicAI color mode.
- [x] Record mmdflux failures as graph-rendering warnings, not agent failures.
- [x] Write a separate NIF feasibility note before adding Rustler or a native
      extension to the main dependency graph.

Validation:

- [x] Unit test Mermaid generation with deterministic graph fixtures.
- [x] Unit test the interim `render_mermaid` wrapper with a Mermaid fenced
      markdown fixture, accepting `:blocked` when the binary is unavailable.
- [x] Unit test nearby query text selection for Mermaid fenced blocks.
- [x] Unit test Livebook `Kino.Mermaid.new("""...""")` extraction, loose query
      selection, and rendering through the interim tools.
- [x] Unit test dynamic `Kino.Mermaid.new(expression)` candidates are listed but
      not rendered by default.
- [x] Unit test bounded `search_text` previews for generated one-line docs
      artifacts.
- [x] Unit test the coding review gate allows `extract_diagrams` and
      `render_mermaid` as safe read-only visualization tools.
- [x] Unit test standard-agent summaries and final report renderers include
      rendered Mermaid diagrams.
- [x] Unit test project-level diagram inventory ignores generated docs and
      caps candidate previews.
- [x] Unit test interactive follow-up context can render the previously
      extracted source diagrams without broad workspace discovery.
- [ ] Unit test large rendered diagrams are summarized for the model while
      remaining available to terminal/final-report rendering.
- [x] Manual smoke with a real `mmdflux` binary:
      `mix runic_ai.agent "Can you render me a mermaid diagram using MMDFLUX from the guides/mental-model.md document in this project?" --agent standard --cwd . --renderer text --detail collapsed --mode read_only --max-turns 6 --approve never`
- [x] Manual smoke with a real `mmdflux` binary and nearby query text:
      `mix runic_ai.agent "Get the general agent shape diagram from livebooks/chat-agent-kernel.livemd in this project and render it using MMDFlux" --agent standard --cwd . --renderer text --detail collapsed --mode read_only --max-turns 6 --approve never`
- [x] Manual smoke with a real `mmdflux` binary and Livebook/Kino diagram
      extraction:
      `mix runic_ai.agent "Now let's do the same and render a mermaid graph from the livebooks/rlm-coding-agent.livemd notebook that describes RLM agents (use mmdflux tool)" --agent standard --cwd . --renderer text --detail collapsed --mode read_only --max-turns 6 --approve never`

## Phase 6: Documentation And Verification

Deliverables:

- [x] Update `Mix.Tasks.RunicAi.Agent` docs with renderer, color, progress,
      Unicode, and graph options.
- [x] Add examples for text fallback, Owl default, JSONL export, review prompt,
      and RLM graph output.
- [x] Update `.docs/030` checklist or status line to point at this follow-on
      enhancement plan rather than treating Owl as deferred indefinitely.
- [ ] Capture a short manual verification report under `.docs` or `tmp` if a
      live model smoke is used.

Validation:

- [x] `mix format`
- [x] `mix compile --warnings-as-errors`
- [x] `mix test test/runic_ai/terminal`
- [x] `mix test`
- [x] Manual: `mix runic_ai.agent --help`
- [x] Manual: standard agent rendered the Mermaid diagram from
      `guides/mental-model.md` through `render_mermaid` and `mmdflux`.
- [x] Manual: standard agent rendered the "general agent shape" Mermaid diagram
      from `livebooks/chat-agent-kernel.livemd` through `render_mermaid` query
      selection and `mmdflux`.
- [ ] Manual: `mix runic_ai.agent "summarize this repo's terminal harness" --agent standard --cwd . --renderer owl --detail collapsed`
- [ ] Manual: `mix runic_ai.agent "plan a small docs-only change" --agent rlm --cwd . --renderer owl --graph text`

## Implementation Order

1. Add Owl and renderer selection without changing behavior.
2. Add theme tokens and color fallback rules.
3. Add Owl event/header/final-report rendering.
4. Add Owl review prompt and rewrite support.
5. Harden source-diagram tooling: project diagram inventory, interactive target
   carryover, and artifact-backed rendered output.
6. Add live status blocks and progress spinners.
7. Add runtime graph presenter and optional mmdflux adapter over normalized
   graph data.
8. Update docs and manual verification.

The key constraint is that the enhanced CLI must remain a renderer over
`RunicAI.Terminal.Event`. If a desired display cannot be built from current
events, add missing event data at the source normalization boundary instead of
letting Owl inspect runtime structs directly.
