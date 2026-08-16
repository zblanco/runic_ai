# Changelog

## 0.2.0-alpha.2 - 2026-08-16

- Add `RunicAI.Component.ContextAssemble`, a pure Runic component exposing the
  existing provenance-, sensitivity-, and size-aware context assembly boundary.
- Verify direct execution and native Runic composition produce the same owned
  prompt and selected context window.

## 0.2.0-alpha.1 - 2026-08-15

- Reset the package boundary around portable contracts and Runic components.
- Preserve the former full-stack application under `archive/legacy_full_stack/`.
- Add canonical value, port, component, message, prompt, error, LLM, tool,
  context, control, outcome, and trace wire contracts.
- Add injected ReqLLM, tool binding, retrieval, and trace adapter boundaries.
- Add explicit LLM generation and tool execution components.
- Add chat-turn, tool-turn, and guarded-tool-turn recipes, with tool fan-out and
  collection represented by native Runic map/reduce components.
- Remove product runtime, persistence, UI, TUI, sandbox, coding, RLM, and
  dynamic-workflow systems from the compiled and published package.
