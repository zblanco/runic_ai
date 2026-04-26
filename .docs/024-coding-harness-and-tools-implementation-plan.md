# Coding Harness And Tools Implementation Plan

Status: draft implementation plan

Date: 2026-04-25

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
- Codex-managed local auth/model-access bridge for testing.

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

- [ ] Define `RunicAI.Coding.Workspace` struct with root, metadata, profile, and
      optional persistence handle.
- [ ] Define `RunicAI.Coding.PathPolicy` with root jail, symlink policy,
      hidden-file policy, max file size, and allowed write roots.
- [ ] Define `FileArtifact`, `Patch`, `PatchResult`, `Command`,
      `CommandResult`, and `ProcessHandle` contracts.
- [ ] Define `RunicAI.Coding.Profile` for language/project-specific tool
      defaults.
- [ ] Define `RunicAI.Coding.Tools.default_registry/1` that returns
      `RunicAI.Tool.Definition` values.
- [ ] Decide which modules are public immediately and which remain internal.

Validation:

- [ ] Add contract tests for struct construction and validation failures.
- [ ] Add docs/examples showing how the registry plugs into
      `IntegratedToolAgent`.

## Phase 1: Workspace Read, List, And Search Tools

Deliverables:

- [ ] Implement `list_dir` with stable ordering, metadata, hidden-file controls,
      and output limits.
- [ ] Implement `find_files` with ignore rules and max result caps.
- [ ] Implement `read_file` with binary detection, max bytes, and hash output.
- [ ] Implement `read_range` by line range.
- [ ] Implement `read_many` with per-file and total output caps.
- [ ] Implement `search_text` backed by Elixir APIs first and `rg` when
      available.
- [ ] Implement `search_regex` with match context and result limits.
- [ ] Normalize all read/search results into model-visible previews plus
      optional artifact refs.

Validation:

- [ ] Unit test path traversal rejection.
- [ ] Unit test symlink escape rejection or configured handling.
- [ ] Unit test hidden file behavior.
- [ ] Unit test output caps and binary detection.
- [ ] Add integration tests using a temporary Mix project fixture.

## Phase 2: Patch-First Editing

Deliverables:

- [ ] Implement `apply_patch` as the default write mechanism.
- [ ] Support create, update, move, and delete patch operations.
- [ ] Validate expected file hashes when provided.
- [ ] Reject paths outside the workspace root.
- [ ] Reject hidden credential-like files unless policy allows them.
- [ ] Return changed paths, operation summaries, diagnostics, and before/after
      hashes.
- [ ] Add optional dry-run mode.
- [ ] Add model-visible failure diagnostics designed for repair.

Validation:

- [ ] Unit test successful create/update/delete/move patches.
- [ ] Unit test patch failure diagnostics.
- [ ] Unit test root jail enforcement.
- [ ] Unit test hash mismatch handling.
- [ ] Add a replay fixture where a fake LLM emits a bad patch, receives
      diagnostics, and emits a corrected patch.

## Phase 3: Command And Process Execution

Deliverables:

- [ ] Implement direct argv `run_command` using `System.cmd/3`.
- [ ] Add command policy with cwd, timeout, env allowlist, output cap,
      network metadata, and mutability classification.
- [ ] Add guarded shell backend as opt-in.
- [ ] Evaluate `just_bash` as an optional sandbox backend for in-memory shell
      demos and tests.
- [ ] Implement `start_process`, `process_poll`, `process_log`,
      `process_write`, and `process_kill`.
- [ ] Store recent process output and full log artifacts separately.
- [ ] Normalize command status into pass, fail, timeout, killed, or blocked.

Validation:

- [ ] Unit test command policy validation.
- [ ] Unit test timeout behavior.
- [ ] Unit test output truncation and artifact preservation.
- [ ] Unit test background process lifecycle.
- [ ] Add tests proving shell backend is disabled unless explicitly enabled.

## Phase 4: Git And Language Profiles

Deliverables:

- [ ] Implement read-only git tools: `git_status`, `git_diff`, `git_log`,
      `git_show`, and `git_branch`.
- [ ] Implement guarded mutating git tool definitions only after review policy
      is available: `git_commit`, `git_restore`, branch operations.
- [ ] Add Mix profile detection from `mix.exs`.
- [ ] Add generic command profile for `compile_project`, `run_tests`,
      `run_formatter`, and `run_linter`.
- [ ] Add Mix-specific defaults for `mix compile`, `mix test`, and
      `mix format`.
- [ ] Leave npm/cargo/python profiles as follow-up unless needed immediately.

Validation:

- [ ] Unit test git read tools against a temporary repo.
- [ ] Unit test language profile detection.
- [ ] Integration test Mix compile/test/format commands through the command
      runner.

## Phase 5: Trace, Artifacts, And Redaction

Deliverables:

- [ ] Define coding trace event metadata for file reads, searches, patches,
      commands, and process logs.
- [ ] Add artifact storage abstraction for large logs, diffs, and read outputs.
- [ ] Add redaction pass for secret-looking env values, tokens, keys, and
      credential filenames.
- [ ] Ensure model-visible observations can differ from full trace payloads.
- [ ] Add capture policy metadata compatible with existing trace sinks.

Validation:

- [ ] Unit test redaction patterns.
- [ ] Unit test artifact previews and full payload lookup.
- [ ] Add trace assertions for a read -> patch -> test sequence.

## Phase 6: Optional SQLite Persistence

Deliverables:

- [ ] Define `RunicAI.Coding.Persistence` behaviour.
- [ ] Add optional SQLite implementation if dependency choice is approved.
- [ ] Store sessions, turns, tool calls, command observations, patch summaries,
      artifacts, approvals, waits, and process logs.
- [ ] Add FTS indexes for session search over summaries and observations.
- [ ] Keep schema migration isolated from core package startup.

Validation:

- [ ] Unit test persistence behaviour with an in-memory fake.
- [ ] Integration test SQLite session save/load if SQLite dependency is added.
- [ ] Add migration tests or schema version tests.

## Phase 7: Codex-Managed Local Auth Bridge

Deliverables:

- [ ] Add `RunicAI.Coding.Codex.ExecClient` wrapper around `codex exec --json`.
- [ ] Treat Codex primarily as local subscription-backed access for testing, not
      as the default planner.
- [ ] Do not read or copy Codex credential files.
- [ ] Normalize JSONL events into trace events and final result contracts.
- [ ] Add policy controls for sandbox mode, approval mode, cwd, and max runtime.
- [ ] Keep this optional and disabled by default.

Validation:

- [ ] Unit test JSONL event normalization with fixtures.
- [ ] Integration test skipped by default when Codex CLI is unavailable.
- [ ] Document expected local auth assumptions without exposing secrets.

## Phase 8: Harness CLI Shell

Deliverables:

- [ ] Add a minimal local harness entrypoint or script for exercising tools.
- [ ] Support session id, cwd, profile, and tool registry selection.
- [ ] Print approval requests, command summaries, patch summaries, and final
      observations.
- [ ] Keep this small until the standard agent plan decides the full CLI shape.

Validation:

- [ ] Smoke test the harness against this repo with read-only tools.
- [ ] Smoke test patch dry-run and command execution.

## Done Criteria

- [ ] Both standard and RLM coding plans can depend on this substrate without
      reimplementing workspace or command logic.
- [ ] `mix test` passes.
- [ ] Docs/examples show how to construct a tool registry.
- [ ] Risky tools are disabled or review-gated by default.
- [ ] The substrate works with fake LLMs and scripted tool tests.

