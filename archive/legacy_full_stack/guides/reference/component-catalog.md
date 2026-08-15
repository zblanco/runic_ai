# Component Catalog

## Core

- `RunicAI.Message` - canonical message values.
- `RunicAI.Prompt` - provider-neutral prompt bundles.
- `RunicAI.Conversation` and `RunicAI.Conversation.State` - conversation
  accumulation.
- `RunicAI.LLM`, `RunicAI.LLM.Request`, `RunicAI.LLM.Result` - model boundary.
- `RunicAI.Error` - normalized error values.

## Agent Turns

- `RunicAI.Agent.State` - durable caller-owned agent state.
- `RunicAI.Agent.TurnRequest` - one turn input.
- `RunicAI.Agent.TurnResult` - one interpreted model result.
- `RunicAI.Agent.ContinueDecision` - continue, stop, halt, or wait decision.

## Steps And Rules

- `RunicAI.Steps.*` - named Runic steps for prompt assembly, model calls, tool
  planning, context handling, decomposition, integrated routing, and RLM work.
- `RunicAI.Rules.*` - Runic rules for continuation, budgets, and guarded
  action routing.

## Tools

- `RunicAI.Tool.Definition` - tool description and executor.
- `RunicAI.Tool.Registry` - validated tool collection.
- `RunicAI.Tool.Selection` - visible tools for a turn.
- `RunicAI.Tool.ExecutionPlan` and `RunicAI.Tool.BatchResult` - planned and
  executed tool batches.
- `RunicAI.Tool.Observation` - model-ready observation messages.
- `RunicAI.Tool.Adapters.*` - command, external worker, and runner workflow
  adapters.

## Context, Memory, Retrieval

- `RunicAI.Context.*` - refs, nodes, graph, state, focus, bundles, pressure,
  compaction, handoff, lineage, thread store, and horizon policy.
- `RunicAI.Memory.*` - memory entries, queries, stores, and read results.
- `RunicAI.Retrieval.*` - retrieval documents, queries, providers, and results.

## Decomposition And Integrated State

- `RunicAI.Decomposition.*` - roles, tasks, task plans, assignments, results,
  join policies, and evaluations.
- `RunicAI.Candidate.*` - candidate specs, registries, assignment, and
  selection policy.
- `RunicAI.Integrated.*` - workflow-owned session state, signals, emissions,
  pending work, and runtime state.

## Operability

- `RunicAI.Trace.*` - semantic events, capture policy, trajectories, and sinks.
- `RunicAI.Harness.*` - process-agnostic drivers and session snapshots.
- `RunicAI.Testing.*` - scripted doubles, replay, retrieval, and assertions.
- `RunicAI.Evaluation.*` - cases, expectations, metrics, results, and runs.
- `RunicAI.Runtime.*` - supervised sessions, handles, backends, schedulers, and
  runner integration.

## Recipes

- `RunicAI.Recipes.ChatAgentKernel`
- `RunicAI.Recipes.ConversationalToolAgent`
- `RunicAI.Recipes.GuardedOperatorToolAgent`
- `RunicAI.Recipes.SummaryBackedChatAgent`
- `RunicAI.Recipes.MemoryAwareToolAgent`
- `RunicAI.Recipes.HandoffContextBuilder`
- `RunicAI.Recipes.PlannerExecutorWorkflow`
- `RunicAI.Recipes.ParallelResearchSynthesizer`
- `RunicAI.Recipes.ReviewerEditorJury`
- `RunicAI.Recipes.IntegratedAgentKernel`
- `RunicAI.Recipes.IntegratedChatAgent`
- `RunicAI.Recipes.IntegratedToolAgent`
- `RunicAI.Recipes.EvaluationHarness`
- `RunicAI.Recipes.RLMSummarizer`
