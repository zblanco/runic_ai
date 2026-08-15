# Host integration

The host supplies every stateful or effectful facility:

- an `LLM.Client` implementation or arity-two function;
- a resolver from a `Tool.Call` name and execution context to `Tool.Binding`;
- an optional `Retrieval.Provider`;
- an optional `TraceSink`;
- Runic runner, journal, persistence, supervision, policy, tenancy, and UI.

The safe durable boundary is:

```text
decode and validate owned request
  -> resolve ephemeral bindings in the host workspace
  -> execute a Runic component or recipe
  -> encode result, outcome, trace, or suspension
  -> persist/project in the host
```

A tool specification may be stored and semantically hashed. Its binding may
not. Bindings should be recreated from host-authoritative workspace records,
authorization, secrets, and implementation registries for each admitted run.

RunicAI does not guarantee durable or exactly-once effects. A durable host must
pin its semantic definition and component catalog, enforce replay policy, and
use its journal to decide whether an effect is new, replayed, fenced, or needs
operator review.

The package test `RunicAI.HostFixtureTest` is an executable minimal consumer. It
provides its own supervised store, scripted LLM client, tool binding, Runic
execution call, persistence projection, and presentation projection without
modifying or starting RunicAI infrastructure.
