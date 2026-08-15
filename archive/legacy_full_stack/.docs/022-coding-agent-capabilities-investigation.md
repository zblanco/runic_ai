# Coding Agent Capabilities Investigation

This note investigates a possible RunicAI coding-agent layer: a local workflow
that can inspect and change a workspace, run commands, persist useful state, and
optionally route model work through Codex-managed local auth when that is useful
for subscription-backed testing.

The short version: RunicAI already has most of the agent loop primitives. The
new work should concentrate on a coding-tool registry, execution backends,
workspace safety policy, durable session storage, and one or more runner
interfaces that make the workflow pleasant to operate locally.

## Potential Target Experience

A developer should be able to start a local RunicAI coding session in a project:

```bash
mix runic_ai.code --cwd .
```

Then the agent can:

- Read project instructions such as `AGENTS.md`.
- Search files and symbols.
- Read targeted file ranges.
- Edit through structured patches.
- Run tests, formatters, compilers, and small diagnostic commands.
- Keep a trace of decisions, commands, outputs, approvals, and file changes.
- Pause for approval before risky filesystem, shell, network, git, or secret
  touching operations (HITL).
- Resume a prior session with its context, logs, and pending work intact.

The first milestone does not need to be a general autonomous development
environment. A narrow, reliable local coding workflow is enough:

1. User gives an engineering task.
2. Workflow builds context from repo state and instructions.
3. Model proposes either an answer or tool calls.
4. Guard checks the proposed tool calls.
5. Harness executes allowed tools and reports observations.
6. Workflow repeats until it emits a final answer, wait, or review request.

## Current RunicAI Fit

RunicAI is already shaped well for this:

- `RunicAI.Tool.Definition`, `Selection`, `ExecutionPlan`, `CallResult`, and
  `Observation` provide the visible tool contract.
- `RunicAI.Steps.PlanToolExecution`, `ExecuteToolCalls`, and
  `ExecuteToolCallsControlled` already normalize tool execution.
- `RunicAI.Control.GuardDecision`, `ReviewRequest`, `Wait`, retry policies, and
  budget policies already cover the human-in-the-loop and safety gates a coding
  agent needs.
- `RunicAI.Recipes.IntegratedToolAgent` already supports workflow-owned
  multi-turn sessions with tool calls, review, waits, and scoped resumes.
- `RunicAI.Harness.Integrated`, `Runtime.SessionSpec`, runtime backends,
  schedulers, and trace sinks already give us the process boundary.
- `RunicAI.Tool.Adapters.Command` can run a fixed OS command without a shell,
  and `ExternalWorker` can delegate to application-owned worker processes.

So the proposal is additive: create a coding-agent profile and tool/runtime
modules that plug into the existing integrated recipe family.

## Tool Surface

Codex-like coding work uses a few distinct classes of tools. These should be
small, typed, and policy-aware rather than one giant "do anything" tool.

| Category | Useful tools | Notes |
| --- | --- | --- |
| Workspace discovery | `pwd`, `list_dir`, `find_files`, `repo_map`, `file_info` | Prefer structured Elixir filesystem APIs and `rg --files` style behavior. |
| Text search | `search_text`, `search_regex`, `search_symbols` | Back with `ripgrep` where available. Include output caps and match context. |
| Reading | `read_file`, `read_range`, `read_many`, `read_image_metadata` | Range reads keep prompts small and reduce accidental secret exposure. |
| Editing | `apply_patch`, `write_file`, `append_file`, `move_path`, `delete_path` | Make `apply_patch` the default. Direct writes/deletes should be guarded. |
| Shell | `run_command`, `run_shell`, `start_process`, `process_poll`, `process_log`, `process_kill`, `process_write` | Separate non-shell argv execution from shell execution. Shell and background processes need stronger policy. |
| Language tasks | `run_tests`, `run_formatter`, `run_linter`, `compile_project` | Profiles can know Mix, npm, cargo, etc. These are safer than arbitrary shell. |
| Git | `git_status`, `git_diff`, `git_log`, `git_show`, `git_branch`, `git_commit`, `git_restore` | Mutating git actions should require review unless explicitly preapproved. |
| Persistence | `remember`, `recall`, `session_search`, `sqlite_query` | Use small curated memory for always-on facts and SQLite/FTS for larger recall. |
| Web and docs | `web_search`, `fetch_url`, `fetch_docs` | Optional, network-gated, and not needed for the minimal local agent. |
| Delegation | `spawn_coding_agent`, `ask_codex`, `run_subworkflow` | Useful after the core loop is stable. `RunnerWorkflow` and `ExternalWorker` already point this way. |

The tools Codex exposes to this environment map closely to the same set:

- Shell command execution with streaming or polled output.
- Stdin writes to an existing command session.
- Structured patch application for file creation, update, move, and delete.
- File discovery and reading through ordinary shell utilities such as `rg`,
  `sed`, `ls`, and `git`.
- Image/file inspection where useful.
- Web search and GitHub tools when the task asks for external context.
- Plan updates and subagent delegation as orchestration capabilities.

RunicAI does not need to copy that exact implementation. It should expose the
same practical powers through typed `Tool.Definition` contracts and execution
adapters.

## Command Execution Strategy

Use a layered command model:

1. **Structured tools first.** `read_file`, `search_text`, and `apply_patch`
   should cover most coding operations without shelling out.
2. **Direct argv execution.** For known commands, use `System.cmd/3` without a
   shell. This matches the existing `RunicAI.Tool.Adapters.Command` direction.
3. **Shell execution.** Provide a `run_shell` tool only when the workflow profile
   enables it. It should have cwd restrictions, timeout, output caps, env
   allowlists, network policy metadata, and a guard evaluator.
4. **Background processes.** Add a small process supervisor/registry for dev
   servers, watchers, and long test runs. Observations should include a stable
   process id, command, status, recent output, and log handle.
5. **Sandbox backends.** Let applications choose local, Docker, SSH, or simulated
   shell backends. Hermes is a useful inspiration here: it documents local,
   Docker, SSH, Singularity, Modal, and Daytona terminal backends, with process
   management and persistent containers.

For a package-level default, start conservative:

- `:local_argv` enabled for curated commands.
- `:local_shell` disabled unless opted in.
- `:docker` or `:ssh` as recommended backends for broader command autonomy.
- `:just_bash` for safe evals, demos, and untrusted shell-like tasks that do not
  need real filesystem mutation.

## JustBash Fit

`just_bash` is attractive for a sandboxed shell profile because it runs a
bash-like interpreter against an in-memory virtual filesystem. Its docs describe
no real filesystem access by default, no network access by default, optional
HTTPS allowlists, and execution limits for runaway scripts. Custom commands are
trusted host-side extensions, so they need the same scrutiny as any other tool.

Practical uses:

- Safe unit tests for shell-tool planning.
- Sandboxed data wrangling tasks.
- Teaching/eval workflows where the model should manipulate virtual files.
- A "dry run shell" before allowing a real command.

Limits:

- It is not a drop-in replacement for local development commands like
  `mix test`, `npm install`, or `git diff`.
- To edit the real repo, we would need either explicit sync in/out of the
  virtual filesystem or trusted custom commands, which moves safety back into
  our adapter layer.

So `just_bash` is best as one backend, not the only command story.

## Editing Strategy

Prefer a first-class patch tool over exposing raw writes:

- Input: structured patch text or operation list, target cwd, and optional
  expected file hash.
- Policy: reject paths outside workspace root, symlinks that escape the root,
  hidden credential files unless explicitly allowed, and oversized changes.
- Execution: apply atomically when possible, return changed files and failure
  diagnostics.
- Trace: store before/after hashes and a compact diff summary.

OpenAI's current API docs describe an `apply_patch` tool for GPT-5.1 workflows
where the model emits patch operations, the application applies them locally,
and then reports `apply_patch_call_output` results. A RunicAI implementation can
mirror that shape while staying provider-neutral.

## Model And Codex Integration

There are several viable paths. They can coexist.

### ReqLLM API Key Path

This is the known baseline. Keep using `RunicAI.LLM` and ReqLLM with provider
model strings and ordinary tool/function calling. This is provider-neutral and
easy to test with function clients.

Best for:

- Library-default examples.
- Provider-neutral coding agents.
- Tests, evals, and non-OpenAI deployments.

Missing piece:

- If we want OpenAI Responses-specific built-in tools such as `shell` or
  `apply_patch`, ReqLLM may not expose those exact event types. We may need a
  dedicated `RunicAI.LLM.OpenAIResponsesClient` or a narrower coding-model
  client behaviour that can return model items, tool calls, and streaming events.

### OpenAI Responses Path

OpenAI's current docs position the Responses API as the future direction for
agentic apps and document the `shell` and `apply_patch` tools there. The shell
tool can run in OpenAI-managed hosted containers or in a local runtime hosted by
the application, and the docs explicitly warn to sandbox commands, log activity,
and avoid interactive command assumptions.

Best for:

- GPT-5.1 coding workflows with native shell/apply-patch semantics.
- Hosted shell experiments.
- A closer match to OpenAI's current agent tooling.

Missing piece:

- A RunicAI client adapter that can translate Responses items into
  `RunicAI.Tool.CallRequest` and `Tool.Observation` values, or a parallel
  Responses-native step family.

### Codex CLI Bridge

Codex can be invoked non-interactively with `codex exec`. Official docs say
`codex exec` streams progress to stderr and final output to stdout, supports
JSON Lines events, can use explicit sandbox/approval settings, and defaults to a
read-only sandbox. For CI, the docs recommend API key auth; `CODEX_API_KEY` is
only supported for `codex exec`.

This gives RunicAI a pragmatic bridge:

- optional `codex_exec`/`codex_client` adapter: send a bounded prompt to
  `codex exec --json` when subscription-backed local access is desired.
- Parse JSONL events into a `RunicAI.Trace.Trajectory`.
- Treat Codex primarily as an auth/model-access path for local testing; using
  it as a specialist subagent remains optional.
- Allow ChatGPT-managed local auth by letting Codex reuse its own cached login.

Best for:

- Using a user's Codex CLI subscription in a local trusted environment.
- Testing RunicAI coding workflows without also paying per-token API costs.
- Dogfooding with minimal OpenAI API client work.

Risks:

- Codex becomes an external black-box worker unless we capture and normalize its
  JSONL event stream.
- Auth and sandbox policy live partly in Codex config, so the RunicAI harness
  must display and record the effective command.
- Avoid reading or managing `~/.codex/auth.json` directly. Official docs treat
  it like a password. Let the Codex CLI/SDK own credential refresh.

### Codex SDK Bridge

OpenAI documents a TypeScript Codex SDK for programmatically controlling local
Codex agents, and notes that it is more comprehensive and flexible than
non-interactive mode. A RunicAI integration could run a small Node worker over a
Port or JSON-RPC and use `ExternalWorker` as the adapter boundary. The main
interest is local Codex-auth-backed execution; long-lived subagent sessions are
secondary.

Best for:

- Richer continuation and thread control.
- Reusing Codex-managed local auth from a RunicAI harness.
- Internal tools where Node as a sidecar is acceptable.

Missing piece:

- A small supervised sidecar protocol and a stable Elixir wrapper.

## Authentication Direction

Support two explicit modes:

- `:api_key`: use ReqLLM/OpenAI API keys. This should be the default for
  automation and CI because keys are easier to provision, rotate, and scope.
- `:codex_cli`: use the installed Codex CLI or SDK and whatever auth it already
  owns. This is the route for ChatGPT subscription access.

Do not build a custom OAuth flow in RunicAI at first. Codex supports Sign in
with ChatGPT and API key auth; the CLI/IDE cache credentials locally and refresh
ChatGPT tokens during active use. RunicAI should call Codex as an executable or
sidecar, not scrape tokens or copy secrets.

Configuration sketch:

```elixir
[
  model_client: :req_llm,
  model: "openai:gpt-5.1-codex-mini",
  codex: [
    enabled?: true,
    bin: "codex",
    auth: :cli_cached,
    sandbox: "workspace-write",
    approval_policy: "on-request",
    json?: true
  ]
]
```

## Persistence

A feature-rich coding agent needs more than in-memory state. There are three
different persistence layers worth separating.

### Runtime Session Store

Stores the canonical `RunicAI.Harness.Session` snapshot, workflow outputs,
pending waits/reviews, and trace trajectory. This could be:

- `Runic.Runner` storage where available.
- A new `RunicAI.Runtime.Backends.SQLite` for package-local durable sessions.

Useful tables:

- `sessions`: id, profile, cwd, status, current snapshot, created/updated.
- `turns`: session id, input, final output, usage, status.
- `events`: trace event JSON, monotonic order, capture policy/redactions.
- `tool_calls`: name, args hash, status, output preview, full artifact ref.
- `approvals`: guard request, decision, actor, timestamp.
- `waits`: wake condition, scheduler metadata, resume payload.

### Workspace State Store

Stores repo-oriented information:

- Workspace roots and path policies.
- Last known git status/diff summaries.
- File hash snapshots before and after edits.
- Background process registry and logs.
- Command allow/deny decisions by profile.

This store helps the harness reason about "what changed since the last turn?"
without rereading the whole repo.

### Agent Scratch Database

Hermes has an open issue proposing a per-agent private SQLite database tool
inspired by Gobii: each agent gets a queryable data workspace and a `sqlite_query`
tool. That direction is especially compelling for RunicAI because it is a clean
contract:

- Tool: `sqlite_query(query, params?, mode?)`.
- Scope: per user, project, agent, or session.
- Guardrails: statement classifier, transaction wrapper, timeout, row/output
  limits, blocked pragmas/attachments, readonly mode, and review for destructive
  operations.
- Context: schema-summary injection or a separate `sqlite_schema` tool.
- Maintenance: `VACUUM`, `PRAGMA optimize`, max database size, export/import.

This should not replace curated memory. It is a structured working table space
for research findings, benchmark results, todo state, inventories, and reports.

For Elixir dependencies:

- `exqlite` is the lower-level SQLite option.
- `ecto_sqlite3` is attractive if we want schemas, migrations, and Repo
  conventions.

For a library, start with an adapter behaviour and an optional SQLite
implementation so downstream applications can choose their persistence stack.

## Memory And Search

Use a two-tier model:

- Curated memory: small, explicit facts about the project, user preferences,
  and tool lessons. This maps to `RunicAI.Memory.Store`.
- Session search: SQLite FTS over trace events, prompts, final answers, and
  tool summaries. This is for "what did we try last week?" recall.

Hermes uses compact prompt-injected memory plus SQLite FTS5 session search. That
split is worth copying conceptually: always-on memory stays small, while large
history is searched on demand.

## Proposed Modules

Suggested namespace:

```text
lib/runic_ai/coding/
  agent.ex
  profile.ex
  workspace.ex
  path_policy.ex
  command_policy.ex
  process_registry.ex
  tools.ex
  persistence.ex
  persistence/sqlite.ex
  llm/openai_responses_client.ex
  codex/exec_worker.ex
  codex/sdk_worker.ex
```

Key behaviours:

```elixir
defmodule RunicAI.Coding.Workspace do
  @callback root(term()) :: Path.t()
  @callback read_file(term(), Path.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback apply_patch(term(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
end

defmodule RunicAI.Coding.CommandRunner do
  @callback run(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback start(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback poll(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback kill(term(), keyword()) :: {:ok, term()} | {:error, term()}
end

defmodule RunicAI.Coding.Persistence do
  @callback load_session(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback save_session(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback append_event(term(), keyword()) :: {:ok, term()} | {:error, term()}
end
```

`RunicAI.Coding.Agent.new/1` can wrap `IntegratedToolAgent.new/1` with a default
coding registry:

```elixir
RunicAI.Coding.Agent.new(
  cwd: ".",
  model: "openai:gpt-5.1-codex-mini",
  client: RunicAI.LLM.ReqLLMClient,
  tools: :default,
  command_backend: :local_argv,
  persistence: {RunicAI.Coding.Persistence.SQLite, path: ".runic_ai/agent.db"}
)
```

## Runner Harness

The workflow graph is not enough by itself. A good coding agent needs a local
runner harness with:

- CLI entrypoint and optional TUI.
- Incremental streaming of model text, tool calls, command output, approvals,
  and diffs.
- Approval prompts that display the exact command, cwd, env exposure, file
  targets, and risk reason.
- Session resume, interrupt, and redirect.
- Background process management.
- Artifact storage for large logs and diffs.
- Redaction policy for secrets in traces and model-visible observations.
- Repo context assembly: `AGENTS.md`, git status, current branch, root files,
  language/package detectors, and prior session summary.
- Eval/replay support using existing `RunicAI.Testing.Replay` and scripted
  doubles.

This harness can live outside the pure workflow components and use
`RunicAI.Runtime.SessionSpec` to run sessions in memory, through Runic Runner,
or through SQLite.

## Safety Baseline

Minimum default policy:

- Workspace root jail for all filesystem tools.
- Refuse path traversal and symlink escapes.
- Read output caps and binary detection.
- Write operations require patch-style operations and changed-file summaries.
- Shell disabled by default; curated commands enabled by profile.
- Timeouts on all command and tool calls.
- Env allowlist for commands; never pass the whole parent environment by
  default.
- Network disabled unless a profile enables it.
- Git mutating operations require review.
- Destructive path operations require review and explicit target display.
- Secret-looking content is redacted in traces and model-visible observations.

## Phased Plan

### Phase 1: Local Structured Coding Tools

- Implement workspace read/list/search tools.
- Implement structured `apply_patch`.
- Add a coding registry and `RunicAI.Coding.Agent` wrapper around
  `IntegratedToolAgent`.
- Add focused tests with fake LLM responses and scripted tools.

### Phase 2: Commands And Processes

- Add direct argv command runner and language command profiles for Mix projects.
- Add guarded shell backend.
- Add background process registry and polling tools.
- Capture command events into traces.

### Phase 3: Persistence

- Add a SQLite runtime backend or trace/session sink.
- Add FTS session search over prior turns and tool summaries.
- Add `sqlite_query` scratch database tool behind strong guardrails.

### Phase 4: Codex Bridge

- Add `RunicAI.Coding.Codex.ExecWorker` around `codex exec --json`.
- Normalize Codex JSONL into trace events and observations.
- Keep Codex auth delegated to Codex itself.

### Phase 5: Rich Harness

- Add a CLI/TUI with streaming, approvals, session resume, and process control.
- Add Docker/SSH command backends.
- Add recipe guides and Livebooks.
- Add eval fixtures for common coding-agent tasks.

## Open Questions

- Should the package include a CLI, or should the CLI live in a sibling package
  such as `runic_ai_coding`?
- Should `apply_patch` be a provider-neutral RunicAI tool, an OpenAI
  Responses-native tool bridge, or both?
- Should SQLite be an optional dependency to keep the core package lean?
- How much shell power should the default coding profile expose?
- Can Codex subscription-backed access become a practical model/client adapter,
  even if Codex itself remains an agent harness rather than a raw LLM endpoint?
- What is the right durable store contract if Runic Runner persistence matures
  alongside this work?

## External References Checked

- [Hermes Agent README](https://github.com/NousResearch/hermes-agent)
- [Hermes tools and terminal backends](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools)
- [Hermes persistent memory and session search](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory)
- [Hermes architecture](https://hermes-agent.nousresearch.com/docs/developer-guide/architecture)
- [Hermes SQLite database tool proposal](https://github.com/NousResearch/hermes-agent/issues/485)
- [just_bash on Hex](https://hex.pm/packages/just_bash)
- [JustBash docs](https://hexdocs.pm/just_bash/JustBash.html)
- [OpenAI Codex CLI](https://developers.openai.com/codex/cli)
- [OpenAI Codex non-interactive mode](https://developers.openai.com/codex/noninteractive)
- [OpenAI Codex SDK](https://developers.openai.com/codex/sdk)
- [OpenAI Codex authentication](https://developers.openai.com/codex/auth)
- [OpenAI Responses migration guide](https://developers.openai.com/api/docs/guides/migrate-to-responses)
- [OpenAI shell tool](https://developers.openai.com/api/docs/guides/tools-shell)
- [OpenAI apply_patch tool](https://developers.openai.com/api/docs/guides/tools-apply-patch)
