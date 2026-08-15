# Standard Coding Agent

`RunicAI.Coding.Agent` is the standard local coding-agent recipe. It runs on top
of `RunicAI.Recipes.IntegratedToolAgent` and the `RunicAI.Coding` harness, so
the agent loop stays workflow-owned while filesystem, patch, git, command,
review, trace, and persistence behavior stay in composable modules.

## Modes

```elixir
workspace = RunicAI.Coding.Workspace.new!(root: File.cwd!())

workflow =
  RunicAI.Coding.Agent.verify(workspace, "Fix the failing focused test.",
    model: "openai:gpt-5.4-mini"
  )

RunicAI.Coding.Agent.summary(workflow)
```

Modes select the visible tool set:

- `:read_only` exposes directory, file, search, and git-read tools.
- `:patch` adds `apply_patch`.
- `:verify` adds Mix-oriented compile, test, formatter, and linter tools.

The default command policy disables shell and `just_bash` execution for the
standard agent. Verification mode allows `git` and `mix`; read and patch modes
allow `git`.

## Named Recipes

Named recipes are available through `RunicAI.Coding.RecipeRegistry` and direct
recipe modules:

- `/explain-repo`: read-only repository explanation.
- `/review`: diff-focused read-only review.
- `/triage-bug`: read/search/git investigation without edits.
- `/write-tests`: test-focused patch and verification workflow.
- `/fix-ci`: command-output-driven repair workflow.

```elixir
RunicAI.Coding.Agent.run(workspace, "/review current diff",
  command: :review,
  model: "openai:gpt-5.4-mini"
)
```

For conservative automatic routing, pass `auto_recipe?: true`, or provide
`recipe_classifier: fn task -> :fix_ci end` for deterministic application or
test routing.

## Review Gates

The default coding review gate pauses before broad or risky operations:

- shell, `just_bash`, process-write, process-kill, and generic command tools
- mutating git commands when requested through a command tool
- formatter writes
- patch deletes and moves
- patches touching hidden or credential-like paths
- patches over the configured operation or byte budget

Review requests use the existing `RunicAI.ReviewRequest` contract and include
the exact tool call, command, path, or patch details. Use
`RunicAI.Coding.Review.allow/1`, `deny/1`, `rewrite/2`, or `final_stop/1` to
resume.

## Sessions

`RunicAI.Coding.Session` adapts the standard agent to the runtime session
contract and supports snapshot persistence through `RunicAI.Coding.Persistence`.

```elixir
session =
  RunicAI.Coding.Session.new(workspace,
    mode: :verify,
    model: "openai:gpt-5.4-mini"
  )
  |> RunicAI.Coding.Session.submit(%{
    agent_id: "coding",
    user: "Fix the failing test."
  })

snapshot = RunicAI.Coding.Session.snapshot(session)
```

Use `RunicAI.Coding.Session.spec/2` when starting through
`RunicAI.Runtime.SessionSpec`.

## Codex Local Bridge

Codex CLI routing is opt-in:

```elixir
RunicAI.Coding.Agent.verify(workspace, "Explain this failure.",
  client: :codex,
  codex_opts: [sandbox_mode: :workspace_write]
)
```

This path calls the local `codex exec --json` bridge and does not read Codex
credential files. ReqLLM remains the default client path.

## Evaluation

`RunicAI.Coding.Evals.cases/1` provides deterministic fixtures for read-only QA,
patch repair, test writing, and review-gate behavior. The fixtures run through
`RunicAI.Recipes.EvaluationHarness` and support scripted LLM clients.

## Manual Smoke Checklist

Before relying on a live model in a real project, run one smoke for each path:

- Read: ask for a module explanation and verify cited files exist.
- Edit: make a small patch-only change and inspect the changed-file summary.
- Verify: run one focused failing test, repair it, and rerun the focused test.
- Review: request a delete, hidden-file write, formatter write, or shell command
  and confirm a review request includes exact details.
- Resume: approve or rewrite the review request and confirm the session resumes
  with trace events and changed-file evidence intact.
