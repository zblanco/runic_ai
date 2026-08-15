# Coding Harness And Tools Implementation Plan

Status: foundation implementation verified; remaining full-agent work explicit

Date: 2026-04-25

Last verified: 2026-04-26

Depends on:

- `.docs/002-workflow-native-agent-roadmap.md`
- `.docs/005-phase-2-tool-calling-and-capability-execution-implementation-plan.md`
- `.docs/006-phase-3-controls-guards-and-operator-interaction-implementation-plan.md`
- `.docs/012-phase-6-stateful-integrated-agent-recipes-implementation-plan.md`
- `.docs/015-phase-8-advanced-runtime-adapters-and-optimization-hooks-implementation-plan.md`

References:

- `.docs/022-coding-agent-capabilities-investigation.md`
- `.docs/023-rlm-coding-agent-investigation.md`
- `.docs/020-runic-rlm-architecture-explainer.md`

## Goal

Build the shared local coding substrate that both a standard coding agent and
an RLM coding agent can use.

This plan intentionally avoids choosing the final agent strategy. It provides
the common workspace, tool, command, patch, process, trace, persistence, and
model-access foundations that both strategies need.

The phase is successful when RunicAI has a clear answer to:

"How can a RunicAI workflow safely inspect and change a local workspace, run
bounded commands, persist session evidence, and expose all of that through typed
tool contracts that ordinary agent recipes and RLM-generated workflows can both
reuse?"

## Relationship To Other Plans

This is the shared substrate.

```text
024 common coding harness and tools
  -> 025 standard coding agent
  -> 026 RLM coding agent
```

The standard coding agent should not implement its own file, shell, patch, git,
or persistence logic. The RLM coding agent should not implement a separate tool
runtime either. Both should consume this layer.

## Scope

### In Scope

- Workspace root and path policy.
- Structured read/list/search tools.
- Patch-first editing.
- Command execution through direct argv and optional shell backends.
- Background process management.
- Git read tools and guarded mutating git actions.
- Language task profiles for common local workflows.
- Trace artifacts and redaction.
- Optional durable local persistence.
- Codex-integrated local auth/model-access bridge for testing.

### Out Of Scope

- A full coding agent loop.
- RLM workflow proposal generation.
- Provider-specific hosted shell semantics as the only implementation.
- Unbounded shell access by default.
- GitHub PR automation beyond local git primitives.

## Proposed Namespace

```text
lib/runic_ai/coding/
  workspace.ex
  path_policy.ex
  file_artifact.ex
  patch.ex
  patch_result.ex
  command.ex
  command_result.ex
  command_policy.ex
  command_runner.ex
  process_registry.ex
  profile.ex
  tools.ex
  tool_registry.ex
  trace_redactor.ex
  persistence.ex
  persistence/sqlite.ex
  codex/exec_client.ex
  codex/event_normalizer.ex
```

The namespace can start internal if we want to avoid committing to a public API
too soon.

## Decisions Integrated On 2026-04-26

- `RunicAI.Coding` is the accepted namespace for the experimental coding
  substrate.
- Literal search prefers `rg` when available and falls back to the Elixir
  implementation.
- Command classifications use the accepted defaults:
  `:read_only`, `:writes_workspace`, `:writes_outside_workspace`, `:network`,
  `:destructive`, and `:unknown`.
- `:just_bash` is an optional `:dev`/`:test` dependency and an additional
  command backend; it does not replace argv execution or the guarded host shell.
- In-memory persistence is the first-class development path for artifact refs
  and trace-like event capture.
- The generic profile intentionally has no default commands for now.
- Coding trace event kinds are `:coding_file_read`, `:coding_search`,
  `:coding_patch`, `:coding_command`, and `:coding_process`.
- `:exqlite` is an optional `:dev`/`:test` dependency. The SQLite adapter is
  available for artifacts and generic coding events, while the fuller session
  schema remains deferred.
- Codex is optional and treated as a local subscription-backed execution bridge,
  not as a required testing dependency.
- Minimal terminal verification uses `mix runic_ai.coding.smoke`.

## Contract Principles

- Tool outputs should be structured maps or structs, not raw strings only.
- Every filesystem operation must resolve through a workspace root and
  `PathPolicy`.
- Mutating operations should prefer patch-style edits and return changed paths,
  before/after hashes, and diagnostics.
- Commands should be explicit argv by default; shell is an opt-in backend.
- All tool calls should be compatible with `RunicAI.Tool.Definition`.
- All risky actions should be compatible with `GuardDecision`,
  `ReviewRequest`, and budget policy.
- Large outputs should become artifacts with previews, not prompt-sized blobs.
- Persistence should be optional behind a behaviour.

## Phase 0: Contract And Surface Design

Deliverables:

- [x] Define `RunicAI.Coding.Workspace` struct with root, metadata, profile, and
      optional persistence handle.
- [x] Define `RunicAI.Coding.PathPolicy` with root jail, symlink policy,
      hidden-file policy, max file size, and allowed write roots.
- [x] Define `FileArtifact`, `Patch`, `PatchResult`, `Command`,
      `CommandResult`, and `ProcessHandle` contracts.
- [x] Define `RunicAI.Coding.Profile` for language/project-specific tool
      defaults.
- [x] Define `RunicAI.Coding.Tools.default_registry/1` that returns
      `RunicAI.Tool.Definition` values.
- [x] Decide which modules are public immediately and which remain internal.

Validation:

- [x] Add contract tests for struct construction and validation failures.
- [x] Add docs/examples showing how the registry plugs into
      `IntegratedToolAgent`.

## Phase 1: Workspace Read, List, And Search Tools

Deliverables:

- [x] Implement `list_dir` with stable ordering, metadata, hidden-file controls,
      and output limits.
- [x] Implement `find_files` with ignore rules and max result caps.
- [x] Implement `read_file` with binary detection, max bytes, and hash output.
- [x] Implement `read_range` by line range.
- [x] Implement `read_many` with per-file and total output caps.
- [x] Implement `search_text` backed by Elixir APIs first and `rg` when
      available.
- [x] Implement `search_regex` with match context and result limits.
- [x] Normalize all read/search results into model-visible previews plus
      optional artifact refs.

Validation:

- [x] Unit test path traversal rejection.
- [x] Unit test symlink escape rejection or configured handling.
- [x] Unit test hidden file behavior.
- [x] Unit test output caps and binary detection.
- [x] Add integration tests using a temporary Mix project fixture.

## Phase 2: Patch-First Editing

Deliverables:

- [x] Implement `apply_patch` as the default write mechanism.
- [x] Support create, update, move, and delete patch operations.
- [x] Validate expected file hashes when provided.
- [x] Reject paths outside the workspace root.
- [x] Reject hidden credential-like files unless policy allows them.
- [x] Return changed paths, operation summaries, diagnostics, and before/after
      hashes.
- [x] Add optional dry-run mode.
- [x] Add model-visible failure diagnostics designed for repair.

Validation:

- [x] Unit test successful create/update/delete/move patches.
- [x] Unit test patch failure diagnostics.
- [x] Unit test root jail enforcement.
- [x] Unit test hash mismatch handling.
- [x] Add a replay fixture where a fake LLM emits a bad patch, receives
      diagnostics, and emits a corrected patch.

## Phase 3: Command And Process Execution

Deliverables:

- [x] Implement direct argv `run_command` using `System.cmd/3`.
- [x] Add command policy with cwd, timeout, env allowlist, output cap,
      network metadata, and mutability classification.
- [x] Add guarded shell backend as opt-in.
- [x] Evaluate `just_bash` as an optional sandbox backend for in-memory shell
      demos and tests.
- [x] Implement `start_process`, `process_poll`, `process_log`,
      `process_write`, and `process_kill`.
- [ ] Store recent process output and full log artifacts separately.
- [x] Normalize command status into pass, fail, timeout, killed, or blocked.

Validation:

- [x] Unit test command policy validation.
- [x] Unit test timeout behavior.
- [x] Unit test output truncation and artifact preservation.
- [x] Unit test background process lifecycle.
- [x] Add tests proving shell backend is disabled unless explicitly enabled.

## Phase 4: Git And Language Profiles

Deliverables:

- [x] Implement read-only git tools: `git_status`, `git_diff`, `git_log`,
      `git_show`, and `git_branch`.
- [ ] Implement guarded mutating git tool definitions only after review policy
      is available: `git_commit`, `git_restore`, branch operations.
- [x] Add Mix profile detection from `mix.exs`.
- [x] Keep the generic profile intentionally commandless until we need safe
      cross-language defaults.
- [x] Add Mix-specific defaults for `mix compile`, `mix test`, and
      `mix format`.
- [x] Leave npm/cargo/python profiles as follow-up unless needed immediately.

Validation:

- [x] Unit test git read tools against a temporary repo.
- [x] Unit test language profile detection.
- [x] Integration test Mix compile/test/format commands through the command
      runner.

## Phase 5: Trace, Artifacts, And Redaction

Deliverables:

- [x] Define coding trace event metadata for file reads, searches, patches,
      commands, and process logs.
- [x] Add artifact storage abstraction for large logs, diffs, and read outputs.
- [x] Add redaction pass for secret-looking env values, tokens, keys, and
      credential filenames.
- [x] Ensure model-visible observations can differ from full trace payloads.
- [x] Add capture policy metadata compatible with existing trace sinks.

Validation:

- [x] Unit test redaction patterns.
- [x] Unit test artifact previews and full payload lookup.
- [x] Add trace assertions for a read -> patch -> test sequence.

## Phase 6: Optional SQLite Persistence

Deliverables:

- [x] Define `RunicAI.Coding.Persistence` behaviour.
- [x] Add optional SQLite implementation if dependency choice is approved.
- [ ] Add the full normalized SQLite session store for sessions, turns, tool
      calls, command observations, patch summaries, approvals, waits, and
      process logs.
- [x] Add FTS indexes for generic coding event observations.
- [x] Keep schema migration isolated from core package startup.

Validation:

- [x] Unit test persistence behaviour with an in-memory fake.
- [x] Integration test SQLite artifact/event save/load if SQLite dependency is
      added.
- [x] Add migration tests or schema version tests.

## Phase 7: Codex-Managed Local Auth Bridge

Deliverables:

- [x] Add `RunicAI.Coding.Codex.ExecClient` wrapper around `codex exec --json`.
- [x] Treat Codex primarily as local subscription-backed access for testing, not
      as the default planner.
- [x] Do not read or copy Codex credential files.
- [x] Normalize JSONL events into trace events and final result contracts.
- [x] Add policy controls for sandbox mode, approval mode, cwd, and max runtime.
- [x] Keep this optional and disabled by default.

Validation:

- [x] Unit test JSONL event normalization with fixtures.
- [x] Integration test skipped by default when Codex CLI is unavailable.
- [x] Document expected local auth assumptions without exposing secrets.

## Phase 8: Harness CLI Shell

Deliverables:

- [x] Add a minimal local harness entrypoint or script for exercising tools.
- [x] Support session id, cwd, profile, and tool registry selection.
- [x] Print command summaries, patch summaries, and final observations.
- [ ] Print approval requests once the full review-gated CLI exists.
- [x] Keep this small until the standard agent plan decides the full CLI shape.

Validation:

- [x] Smoke test the harness against this repo with read-only tools.
- [x] Smoke test patch dry-run and command execution.

## Done Criteria

- [x] Both standard and RLM coding plans can depend on this substrate without
      reimplementing workspace or command logic.
- [x] `mix test` passes.
- [x] Docs/examples show how to construct a tool registry.
- [x] Risky tools are disabled or review-gated by default.
- [x] The substrate works with fake LLMs and scripted tool tests.
- [x] Live `gpt-5.4-mini` smoke test passes when explicitly enabled.
