# Recipes

Recipes return native Runic workflows and never start a runner.

## Chat turn

`RunicAI.Recipe.ChatTurn.new/2` performs one explicit generation. The host
constructs an `LLM.Request`, supplies a client, plans the workflow, and chooses
how to retain the result.

## Tool turn

`RunicAI.Recipe.ToolTurn.new/3` exposes four named stages:

```text
generate -> plan_tool_calls -> execute_tool_calls(map)
                                 -> collect_tool_results(reduce)
```

The host supplies a resolver that maps an inert tool name to an executable
`Tool.Binding`. Each model-requested call is visible to the Runic scheduler;
fan-out is not hidden inside a step-local task pool.

## Guarded tool turn

`RunicAI.Recipe.GuardedToolTurn.new/5` charges a `Control.Budget` and asks a
host guard to allow, deny, or request review before invoking each effect. A
review produces an inert `Control.Suspension` value. The host persists that
value and decides how and when a later run resumes; Core owns no review server.

Recipes are examples of topology, not mandatory agent abstractions. A durable
host may compose the same components into its own semantic definition and
runner lifecycle.
