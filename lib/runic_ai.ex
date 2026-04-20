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
  `RunicAI.Tool.*` and the reference
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
