# Migration from legacy RunicAI

Version `0.2.0-alpha.1` is intentionally incompatible with the archived
full-stack application.

Keep application concerns in the consuming host:

| Legacy area | New disposition |
| --- | --- |
| Phoenix, LiveView, browser automation, CLI, TUI | host application |
| SQLite/Ecto, runtime sessions, global runner | host persistence and runtime |
| Workbench and dynamic workflow revisions | host semantic-definition system |
| coding agents, sandbox, RLM, optimizers, evaluations | archived experiment or separate package |
| provider messages and responses | `Message`, `Prompt`, `LLM.Request`, `LLM.Result` |
| executable tool definitions | inert `Tool.Spec` plus ephemeral `Tool.Binding` |
| implicit retry/review/wait behavior | explicit control contracts and host policy |

Migration should proceed one boundary at a time:

1. translate stored schemas into `Contract.Value` and component ports;
2. normalize model calls through owned request/result values;
3. split persisted tool descriptions from host bindings;
4. adopt controls at durable admission/effect boundaries;
5. replace opaque loop helpers with visible components or host-owned topology.

Do not copy the archived dynamic workflow IR into Core. Consumers that need
versioned definitions should store an engine-neutral semantic definition and
compile it to native Runic topology for each pinned artifact.
