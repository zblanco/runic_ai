# mmdflux Rust NIF Feasibility Note

Date: 2026-05-02

## Current Decision

Keep `mmdflux` as an optional CLI executable for the Owl/Bunt terminal
iteration. Do not add Rustler or a native extension to the main dependency graph
yet.

## Why

- The terminal graph use case is presentation-only. A missing graph renderer
  should degrade to Mermaid source or adjacency text, not block agent execution.
- Shelling out keeps the Elixir dependency graph simple and keeps Hex
  installation independent of a Rust toolchain.
- The current wrapper can enforce bounded input, bounded runtime, bounded
  output, and explicit color handling without changing runtime agent semantics.
- A Rust NIF would need release packaging, cross-platform build coverage, crash
  isolation decisions, and scheduler safety review before it belongs in the
  default application.

## NIF Shape If We Revisit It

A minimal NIF should expose one pure function:

```elixir
RunicAI.Terminal.MermaidRenderer.render(source, opts)
```

Expected options:

- `format: :text`
- `color: :auto | :always | :never`
- `max_output_bytes: pos_integer`
- `timeout_ms: pos_integer`

Expected result:

```elixir
{:ok, %{status: :pass, rendered: binary(), truncated?: boolean()}}
{:ok, %{status: :fail | :blocked, warning: binary(), rendered: binary() | nil}}
```

The NIF must never raise for invalid Mermaid, missing renderer support, or
rendering failures. Those are graph-rendering warnings.

## Acceptance Bar Before Adding Rustler

- The optional CLI path has proven useful in repeated real terminal sessions.
- We have tests for large diagrams, invalid diagrams, timeout behavior, and
  color-disabled output.
- CI covers Linux and at least one non-Linux target or we provide a clean
  no-NIF fallback.
- The NIF is isolated behind the same `GraphPresenter`/renderer boundary used
  by the shell wrapper.
