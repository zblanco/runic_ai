defmodule RunicAI do
  @moduledoc """
  A toolbox of AI components built on Runic workflows and ReqLLM.

  RunicAI provides reusable building blocks for constructing AI agent loops,
  LLM workflow steps, error-handling control flow, scheduling policies,
  fallback patterns, and more — all composed as Runic workflow graphs.

  RunicAI owns the contracts that move through those workflows: normalized
  messages, prompts, conversation state, and LLM request/result values. Provider
  details are kept behind adapter boundaries wherever practical.

  Phase 1 also adds a conversational kernel layer under `RunicAI.Agent.*` plus
  the reference `RunicAI.Recipes.ChatAgentKernel` workflow for stateful
  assistant turns.

  Phase 2 extends that kernel with typed tool-calling contracts under
  `RunicAI.Tool.*`, including semantic recipe-level
  `RunicAI.Tool.RequirementPolicy`, and the reference
  `RunicAI.Recipes.ConversationalToolAgent` workflow for model -> tool ->
  model loops.

  Phase 3 adds a control layer under `RunicAI.Control.*` plus typed
  `RunicAI.ReviewRequest`, `RunicAI.ReviewDecision`, `RunicAI.Wait`, and
  `RunicAI.ResumeSignal` contracts. The reference
  `RunicAI.Recipes.GuardedOperatorToolAgent` recipe shows how to compose
  budgets, guards, review pauses, waits, retries, and fallbacks around the
  conversational tool kernel without giving up Runic's explicit dataflow model.

  Phase 4 adds a context-engineering layer under `RunicAI.Context.*`, typed
  memory contracts under `RunicAI.Memory.*`, and backend-neutral retrieval
  contracts under `RunicAI.Retrieval.*`. The reference
  `RunicAI.Recipes.SummaryBackedChatAgent`,
  `RunicAI.Recipes.MemoryAwareToolAgent`, and
  `RunicAI.Recipes.HandoffContextBuilder` workflows show how to keep transcript
  truth, derived context state, memory recall, retrieval inputs, compaction,
  and thread handoff as explicit typed workflow values rather than hidden prompt
  truncation.

  Phase 5 adds a decomposition layer under `RunicAI.Decomposition.*` plus the
  `RunicAI.Steps.PlanChildTasks`, `RunicAI.Steps.BuildChildAssignments`,
  `RunicAI.Steps.ExecuteChildAssignments`, `RunicAI.Steps.ReduceChildResults`,
  and `RunicAI.Steps.JudgeCandidates` components. The reference
  `RunicAI.Recipes.PlannerExecutorWorkflow`,
  `RunicAI.Recipes.ParallelResearchSynthesizer`, and
  `RunicAI.Recipes.ReviewerEditorJury` workflows show how to model parent-child
  delegation, scoped inheritance, parallel child execution, deterministic join
  policies, and jury-style evaluation as typed Runic dataflow rather than
  bespoke orchestration.

  Phase 6 adds a workflow-owned integrated runtime layer under
  `RunicAI.Integrated.*`. `RunicAI.Integrated.RuntimeState` is the
  authoritative multi-agent reducer state, keyed by `agent_id`, with
  per-lane `RunicAI.Integrated.SessionState`, typed
  `RunicAI.Integrated.Signal` input envelopes, `RunicAI.Integrated.PendingWork`
  pause metadata, and `RunicAI.Integrated.Emission` output envelopes. The
  reference `RunicAI.Recipes.IntegratedAgentKernel`,
  `RunicAI.Recipes.IntegratedChatAgent`, and
  `RunicAI.Recipes.IntegratedToolAgent` workflows show how to keep one or many
  agent lanes inside a Runic workflow using `Runic.accumulator` plus
  `state_of/1`-driven routing while still reusing the earlier turn, tool,
  budget, review, and wait contracts.

  Phase 7 adds an operability layer under `RunicAI.Trace.*`,
  `RunicAI.Harness.*`, `RunicAI.Testing.*`, and `RunicAI.Evaluation.*`.
  `RunicAI.Trace.Event`, `RunicAI.Trace.CapturePolicy`, and
  `RunicAI.Trace.Trajectory` provide a typed semantic trace and replay artifact
  across both recipe families. `RunicAI.Harness.TurnProcessor` and
  `RunicAI.Harness.Integrated` provide process-agnostic in-memory drivers for
  external-state and workflow-owned recipes. `RunicAI.Testing.*` adds scripted
  doubles plus replay helpers derived from captured trajectories, and
  `RunicAI.Recipes.EvaluationHarness` turns fixture cases into
  accumulator-backed running metrics and evaluation reports without forcing one
  OTP runtime model into the core library.

  Phase 8 adds a production-facing runtime layer under `RunicAI.Runtime.*`.
  `RunicAI.Runtime.SessionSpec`, `RunicAI.Runtime.Handle`, and the generic
  `RunicAI.Runtime.SessionServer` let applications supervise and address
  long-lived harness sessions while preserving `RunicAI.Harness.Session` as the
  canonical snapshot. Runtime backends provide in-memory execution plus
  `Runic.Runner`-backed execution for both external-state and integrated recipe
  families, scheduler adapters deliver explicit `RunicAI.Wait` wakes, and
  `RunicAI.Tool.ExecutionAdapter`, `RunicAI.Candidate.*`,
  `RunicAI.Context.HorizonPolicy`, and `RunicAI.Optimization.*` add the
  extension points for real execution environments, candidate routing, and
  observational optimization.

  ## LLM Access

  Use `RunicAI.LLM` for all LLM interactions. Its canonical path composes
  `RunicAI.LLM.Request` into `RunicAI.LLM.Result`, while convenience wrappers
  remain available for direct use:

      {:ok, request} =
        RunicAI.LLM.Request.new("anthropic:claude-haiku-4-5", "Hello")

      RunicAI.LLM.generate_text(request)

  ## Getting Started

  All components are standard Runic constructs. Remember to:

      require Runic
      alias Runic.Workflow

  Then compose AI workflows using the components provided by this library.
  """
end
