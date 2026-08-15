# Contracts and mental model

RunicAI has five intentionally separate layers:

1. owned values such as `Message`, `Prompt`, and `LLM.Result`;
2. inert specifications such as `Tool.Spec` and `Contract.Component`;
3. host bindings such as an LLM client, tool executor, retrieval provider, or
   trace sink;
4. small Runic components that cross one effect or transform one value;
5. recipes that expose composition as named Runic topology.

Values that cross persistence or process boundaries have a canonical JSON-safe
wire form. Use `encode/1` before persistence and `decode/1` when admitting data
back into execution. Contract semantic hashes are calculated from canonical
JSON, so map ordering does not affect identity.

Never persist a `Tool.Binding`, anonymous function, PID, provider response, or
native Runic graph as authority. Persist the inert specification or semantic
definition and let the host resolve bindings and compile topology for a run.

`RunicAI.Outcome` supplies a stable control envelope for progress, retry,
failure, wait, review, cancellation, and completion. Tagged tuples remain the
ordinary effect API; the envelope is useful at durable host boundaries.

Context references carry provenance and sensitivity labels.
`RunicAI.Context.Assembler` filters them against a host-provided policy and a
deterministic character bound before appending a model-visible system message.
Retrieval itself remains behind `RunicAI.Retrieval.Provider`; Core owns no index.
