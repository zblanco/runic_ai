# RunicAI Core

RunicAI Core is a process-agnostic library of AI-domain contracts, injected
effect adapters, small Runic components, and transparent workflow recipes. It
lets an application compose LLM and tool work without adopting another agent
runtime.

Core owns portable values and component boundaries. The host owns persistence,
tenancy, authorization, secrets, supervision, runners, journals, and UI. The
library has no application callback and starts no processes.

```elixir
request = RunicAI.LLM.Request.new!("openai:gpt-5", "Summarize this")

workflow =
  RunicAI.Recipe.ChatTurn.new(RunicAI.LLM.ReqLLMClient)
  |> Runic.Workflow.plan_eagerly(request)
  |> Runic.Workflow.react_until_satisfied()
```

Public durable values use explicit JSON-safe `encode/1` and `decode/1` forms.
Executable clients, tool functions, and trace sinks are supplied separately by
the host and are never embedded in persisted specifications.

The small public component set includes LLM generation, tool execution, and
deterministic retrieved-context assembly. Hosts compose these with ordinary
`Runic.Workflow` APIs; RunicAI does not model a workflow builder inside a step.

## Guides

- [Contracts and mental model](guides/contracts.md)
- [Recipes](guides/recipes.md)
- [Host integration](guides/host-integration.md)
- [Migration from legacy RunicAI](guides/migration.md)

## Legacy archive

The previous full-stack RunicAI application is preserved on
`archive/full-stack-legacy-2026-08-15` and under
`archive/legacy_full_stack/` on the rewrite branch. It remains research
material and is excluded from compilation and package files.

Libbit is the first downstream dog-food consumer. During incubation it uses a
sibling path dependency; production consumers should use an exact prerelease
Git SHA or released package version.
