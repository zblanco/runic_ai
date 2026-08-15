# RunicAI Core Agent Guide

RunicAI Core is a process-agnostic library of portable AI contracts, effect
adapters, and explicit Runic components. It must not own product persistence,
web or terminal UI, application supervision, sandboxing, or host-specific agent
lifecycle.

## Commands

- `mix test`
- `mix test test/path/to/test.exs`
- `mix compile --warnings-as-errors`
- `mix format`

## Rules

- Components are Runic-native and explicitly named.
- Collection work lowers to native `Runic.map` and `Runic.reduce`.
- Public specifications have canonical JSON-safe encodings.
- Executable bindings, callbacks, secrets, PIDs, and provider-native responses
  do not belong in persisted specifications.
- The library starts no processes and registers no global names.
- RunicAI must never depend on Libbit. Libbit is a downstream dog-food consumer.
- Archive code is reference-only and must not be imported by new source.
- One module per file.
- Never create atoms from external strings.
- Run `mix format` and the relevant tests for every vertical slice.
