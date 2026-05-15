# Hermes-Style Agent Tool Surface

Status: design note / implementation proposal

Date: 2026-05-13

## Goal

Map the standard Hermes Agent tool surface onto RunicAI's existing workflow,
tool, persistence, and interface layers, then identify the missing pieces needed
to expose the same broad capability classes to the main RunicAI agents:

- `standard`
- `assistant`
- `rlm`

The target is not a Hermes clone. The useful lesson is the operator model:
tools are grouped into named toolsets, enabled per platform/session/task, and
configurable at runtime without changing the agent implementation.

Hermes docs checked for this note:

- <https://hermes-agent.nousresearch.com/docs/user-guide/features/tools/>
- <https://hermes-agent.nousresearch.com/docs/reference/tools-reference>
- <https://hermes-agent.nousresearch.com/docs/reference/toolsets-reference>
- <https://nousresearch-hermes-agent.mintlify.app/reference/configuration-options>

## Hermes Reference Surface

Hermes groups tools into core and composite toolsets. The relevant standard
surface for RunicAI is:

| Capability | Hermes examples | RunicAI translation |
| --- | --- | --- |
| Web | `web_search`, `web_extract` | Explicit search/extract tools with citations and durable source records. ReqLLM provider-native web search can complement this, but it is not a replacement for deterministic source extraction. |
| Browser | `browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_scroll`, `browser_console`, `browser_vision` | Optional browser-automation toolset backed by a supervised browser session, accessibility snapshots, console capture, screenshots, and vision analysis. This is different from the RunicAI web workbench UI. |
| Terminal and files | `terminal`, `process`, `read_file`, `write_file`, `patch`, `search_files` | Mostly present in `RunicAI.Coding.Tools`; needs a generic toolset resolver so all agents can consume the same registry. |
| Media | `vision_analyze`, `image_generate`, `text_to_speech`, `video_analyze` | Back with ReqLLM media APIs and workspace artifact storage. RunicAI's LLM facade currently exposes text/object/stream, while ReqLLM already has image, speech, transcription, OCR, and multimodal content support. |
| Agent orchestration | `todo`, `clarify`, `execute_code`, `delegate_task`, kanban tools | Mostly present as internal RunicAI workflow/decomposition primitives, but not yet exposed as a uniform model-visible orchestration toolset. |
| Memory and recall | `memory`, `session_search`, skills, memory providers | Partially present through context graph memory, `Memory.Store`, `RecallMemory`, `WriteMemory`, SQLite events, and FTS-backed event search. Needs model-visible memory/session-recall tools. |

Hermes also treats toolsets as a runtime configuration surface: CLI flags,
platform presets, interactive enable/disable, custom toolsets, plugin toolsets,
and dynamic MCP toolsets all feed the same availability model. That maps well to
RunicAI because `SelectTools` already selects visible tools per turn.

## Current RunicAI Fit

RunicAI already has the right low-level shape:

- `RunicAI.Tool.Definition` is the canonical model-visible and executable tool
  definition.
- `RunicAI.Tool.Registry` stores validated tool definitions.
- `RunicAI.Tool.Selection`, `RunicAI.Steps.SelectTools`, and
  `RunicAI.Steps.AttachVisibleTools` select and attach visible tools per turn.
- `RunicAI.Recipes.IntegratedToolAgent` owns the turn loop, tool calls,
  guarded execution, review, waits, and resumes.
- `RunicAI.Terminal.AgentRunner` already routes `standard`, `assistant`, and
  `rlm` through one CLI/workbench execution boundary.
- `RunicAI.Workbench` already persists launch metadata, terminal events, tool
  calls, reviews, artifacts, scorecards, and session snapshots.

The gap is not the existence of a tool abstraction. The gap is a first-class
capability profile that can merge existing and future registries, apply runtime
policy, and make the resolved profile visible to every agent and interface.

## Proposed Capability Profile

Add a thin capability layer over `Tool.Registry`, not a parallel tool runtime.
The shape can stay small:

```elixir
%RunicAI.Agent.CapabilityProfile{
  toolsets: [:file, :git, :patch, :terminal, :process, :web, :browser, :media, :memory, :delegation],
  disabled_tools: MapSet.new(["run_command"]),
  config: %{
    terminal: %{backend: :local_argv, shell?: false, timeout_ms: 120_000},
    web: %{provider: :configured, max_results: 5},
    browser: %{backend: :local_chrome, inactivity_timeout_ms: 120_000},
    memory: %{session_search?: true, store: :sqlite}
  },
  policy: %{
    approval: :ask,
    write_policy: :docs_only,
    network: :disabled_by_default
  }
}
```

The resolver should produce:

- a merged `%RunicAI.Tool.Registry{}`;
- a visible tool list for the current turn;
- executor configuration captured in closures or metadata;
- policy metadata for guards, review, persistence, and UI display;
- a resolved profile snapshot persisted with the session/run.

The important rule: enabled toolsets should configure which
`Tool.Definition`s are visible. They should not bypass `RunicAI.Tool.Executor`,
guard policies, review requests, or terminal-event projection.

## Capability Matrix

| Toolset | Current status | Next surfacing work |
| --- | --- | --- |
| `file` | Implemented for coding agents: `list_dir`, `find_files`, `read_file`, `read_range`, `read_many`, `search_text`, `search_regex`. | Register as a named `file` toolset and allow `assistant`/`rlm` to receive the same registry when enabled. |
| `patch` | Implemented as `apply_patch` with workspace policy and review metadata. | Split from generic file tools so read-only sessions can enable file reads without writes. |
| `git` | Implemented read tools: `git_status`, `git_diff`, `git_log`, `git_show`, `git_branch`. | Keep read-only by default. Add mutating git actions only behind explicit review and probably a separate `git_write` toolset. |
| `terminal` | Implemented as bounded `run_command`, profile tasks, and command policy. Shell access is already opt-in at the policy layer. | Add capability config for backend, shell enablement, env allowlist, timeout, network intent, and output caps. |
| `process` | Implemented when a `ProcessRegistry` is supplied: start, poll, log, write, kill. | Make registry ownership explicit in runtime/session setup, and surface background process cards in web/TUI. |
| `memory` | Context-memory steps and `Memory.Store` exist. | Add `memory_write` and `memory_recall` tools that call the existing steps/store contracts. |
| `session_search` | SQLite terminal-event FTS and query helpers exist. | Add a model-visible `session_search` tool that searches prior sessions/events and returns summarized, cited results. |
| `web` | ReqLLM supports provider-native web-search options; RunicAI does not expose deterministic `web_search`/`web_extract` tools yet. | Add explicit web tools with provider adapters, markdown extraction, source refs, and citations. |
| `browser` | No model-callable browser automation toolset yet. The Phoenix workbench is an operator UI, not an agent browser. | Add a supervised browser session adapter with navigate/snapshot/click/type/scroll/console/screenshot/vision tools. |
| `media` | ReqLLM has image generation, speech, transcription, OCR, image content parts, and multimodal prompts. RunicAI's facade currently covers text/object/stream. | Add `RunicAI.Media` wrappers and tool definitions for vision, image generation, transcription, speech, and OCR, storing outputs as artifacts. |
| `delegation` | Decomposition roles, child assignments, workflow-backed delegates, and subagent persistence schemas exist. | Add `delegate_task` as a tool that launches restricted child sessions/workflows and returns only final summaries plus artifact refs. |
| `clarify` | Existing `ReviewRequest`, `Wait`, and browser HITL bridge cover the runtime shape. | Add a model-visible `clarify` tool that emits a wait/review request rather than fabricating a question inside ordinary assistant text. |
| `todo` | Planning exists in agent state/blueprints, but no durable per-session todo tool exists. | Add a lightweight todo state in session metadata or context graph if it improves longer runs. Keep it distinct from workflow execution state. |
| `code_execution` | Terminal/profile tools and RLM component execution cover most needs. | Defer a Hermes-style `execute_code` tool. If needed, back it with Docker/JustBash/local policy rather than arbitrary in-process code execution. |

## Terminal And Files

The shared coding substrate is the strongest existing match. Today
`RunicAI.Coding.Tools.default_registry/2` builds one registry containing:

- workspace reads and searches;
- diagram extraction/rendering helpers;
- source assertions and changed-file inventory;
- patch application;
- bounded command execution;
- git read tools;
- project-profile tasks such as compile, test, format, lint, runtime smoke;
- optional background process tools.

`RunicAI.Coding.Recipe` already acts like a small toolset selector for the
standard agent:

- `read_only`: file and git reads;
- `patch`: read tools plus patching;
- `verify`: read, patch, and verification/profile commands.

The next step is to make those groupings explicit capability toolsets so the
same selection model can be used by `assistant` and `rlm`, not only by
`standard`.

Safety defaults should remain conservative:

- path access goes through `Workspace` and `PathPolicy`;
- writes prefer `apply_patch`;
- shell execution stays opt-in;
- profile commands are preferred over arbitrary shell;
- long-running commands use `ProcessRegistry`;
- risky operations emit `ReviewRequest`s and persist terminal/tool events.

## Web

RunicAI should support two related but distinct web paths:

1. Provider-native model search through ReqLLM options. This is useful when a
   provider can ground a generated answer itself.
2. Explicit `web_search` and `web_extract` tools. These are needed when the
   workflow must inspect source URLs, persist provenance, retry extraction, and
   feed deterministic evidence into later components.

The explicit toolset should return structured source records:

```elixir
%{
  title: "...",
  url: "...",
  snippet: "...",
  provider: :tavily,
  fetched_at: DateTime.utc_now(),
  artifact_ref: "artifact:web:..."
}
```

`web_extract` should normalize HTML/PDF content into capped markdown slices and
store the full extracted artifact when persistence is enabled. This gives RLM
workflows the same source-discovery/materialization pattern they already use
for local files.

## Browser Automation

Browser automation should be optional and stateful per run/session. A practical
RunicAI browser toolset would include:

- `browser_navigate`
- `browser_snapshot`
- `browser_click`
- `browser_type`
- `browser_press`
- `browser_scroll`
- `browser_console`
- `browser_get_images`
- `browser_screenshot`
- `browser_vision`

Implementation notes:

- Use a supervised browser session process with inactivity timeout.
- Prefer accessibility snapshots for normal operation.
- Store screenshots/videos as artifacts only when explicitly enabled.
- Make domain/network policy visible in the resolved capability profile.
- Route `browser_vision` through the media toolset so vision provider choice is
  not hard-coded into the browser adapter.
- In the web UI, label this as "agent browser" to avoid confusion with the
  local Phoenix workbench browser.

This should not be enabled in the default local coding profile. It belongs in
research/browser profiles or explicit user-selected toolsets.

## Media

ReqLLM already has enough media substrate to build RunicAI media tools:

- `ReqLLM.generate_image/3`;
- `ReqLLM.speak/3`;
- `ReqLLM.transcribe/3`;
- `ReqLLM.ocr/3`;
- multimodal `ReqLLM.Context` messages and image content parts.

RunicAI should add wrappers before exposing them as agent tools:

```text
RunicAI.Media
RunicAI.Media.Artifact
RunicAI.Media.Tools
RunicAI.Media.Policy
```

Initial tool definitions:

- `vision_analyze`: analyze a workspace image, URL, screenshot artifact, or
  binary artifact with a vision-capable model.
- `image_generate`: generate an image from a prompt and persist the image/URL as
  a RunicAI artifact.
- `transcribe_audio`: transcribe a workspace or uploaded audio artifact.
- `text_to_speech`: generate audio and persist it as an artifact.
- `ocr_document`: convert image/PDF/document bytes to markdown and page assets.

The media tools should not read arbitrary files directly. They should reuse
workspace path policy and artifact refs so prompts receive previews and stable
handles, not unbounded binary blobs.

## Agent Orchestration

RunicAI has orchestration primitives, but they are mostly workflow-internal:

- `RunicAI.Decomposition.TaskPlan`
- `RunicAI.Decomposition.Registry`
- `RunicAI.Decomposition.Role`
- `RunicAI.Steps.ExecuteChildAssignments`
- `RunicAI.Runtime.start_session/1`
- `RunicAI.Persistence.Schemas.SubagentRun`
- `RunicAI.Persistence.ManagedWorkflows`

Expose these as tools carefully:

### `delegate_task`

`delegate_task` should create one or more child assignments with restricted
capability profiles. The child gets its own run/session/toolset, while the
parent receives only:

- final summary;
- status;
- changed artifact refs;
- source refs;
- compact error/review/wait state.

Child intermediate tool output should stay in the child session and read model.
The web/TUI can show the child lane separately.

### `clarify`

`clarify` should create a `Wait` or `ReviewRequest` and pause the workflow. The
terminal asks inline; the web workbench uses the durable browser review/decision
bridge.

### `todo`

`todo` can start as a simple session-context tool:

- read current todo list;
- merge/update todo items;
- mark item status.

It should not become the workflow scheduler. The scheduler remains Runic
workflow state; todos are operator/model planning state.

### `execute_code`

Defer by default. Hermes uses this to batch tool calls through Python RPC. In
RunicAI, the more natural equivalent is a child Runic workflow or a sandboxed
command backend. If a code-execution tool is added, it should be a distinct
toolset with clear sandbox policy.

## Memory And Recall

RunicAI should preserve its existing direction: durable workspace/session events
are the source of truth, and memory is derived state with provenance.

Existing substrate:

- `RunicAI.Context.State` and graph refs;
- `RunicAI.Memory.Entry`, `Query`, `ReadResult`, and `Store`;
- `RunicAI.Steps.WriteMemory`;
- `RunicAI.Steps.RecallMemory`;
- SQLite sessions, messages, terminal events, workflow runs, tool calls,
  artifacts, scorecards, reviews, and FTS-backed event search.

Needed tools:

- `memory_write`: save an explicit user/environment/project fact through
  `Memory.Store` and/or context graph.
- `memory_recall`: recall typed memory entries for the current focus.
- `session_search`: search prior persisted sessions/events and return compact
  cited summaries.
- `context_snapshot`: expose current context pressure, selected refs, memory
  counts, and source refs for debugging.

Useful lifecycle hooks can be modeled as normal Runic workflows or terminal
events:

- prefetch before a turn;
- sync-turn after messages/tool outputs;
- on session end;
- before compaction;
- on memory write;
- on delegation.

Do not adopt Hermes-style `MEMORY.md` and `USER.md` as the primary store. A
file-backed adapter can be useful, but RunicAI should keep SQLite/read-model
evidence and context graph lineage as the default.

## Interface Configuration

### CLI

Existing `mix runic_ai.agent` options already cover:

- agent choice;
- model/client;
- mode;
- input/output paths;
- generated-function tier;
- write policy;
- approval policy;
- persistence;
- renderer/theme;
- graph rendering;
- concurrency/runtime limits.

Add capability flags in a small first pass:

```sh
mix runic_ai.agent "objective" \
  --agent assistant \
  --toolsets file,git,web,memory \
  --disable-tool run_command \
  --tool-config web.provider=tavily \
  --tool-config memory.session_search=true
```

Suggested flags:

- `--toolsets a,b,c`
- `--disable-tool name`
- `--tool-config key=value`
- `--profile safe|coding-read|coding-patch|coding-verify|research|full-local`

Keep existing `--mode read_only|patch|verify` as a high-confidence shortcut for
coding runs. It can expand into a capability profile internally.

### Web UI

The browser composer currently exposes agent, mode, model, and approval. Add an
advanced run drawer with:

- profile preset;
- toolset toggles;
- per-tool disabled list;
- terminal/backend settings;
- web provider/domain settings;
- browser enablement and recording settings;
- memory/session-search enablement;
- media model/output settings;
- resolved launch profile preview.

Every run page should show the resolved capability snapshot:

- enabled toolsets;
- disabled tools;
- write policy;
- approval mode;
- network/browser/media status;
- persistence mode;
- child-agent/delegation limits.

For active sessions, runtime changes should be explicit:

- apply on next turn for ordinary tool visibility changes;
- require a resume/review decision for changes that unblock a paused action;
- persist a `capability_profile_updated` event.

## Main Agent Integration

### Standard Agent

This is the easiest integration path. Replace direct calls to
`RunicAI.Coding.Tools.default_registry/2` plus recipe-visible tools with:

```text
Coding recipe + CapabilityProfile -> Tool.Registry + visible_tools + policy
```

The initial behavior can be identical to today. The resolver just makes the
implicit profile explicit and extensible.

### Assistant Agent

The assistant RLM path should receive the same resolved capability profile and
include allowed toolsets/components in blueprint proposal prompts. The compiler
and validator should reject generated tool leaves that are not allowed by the
profile, returning normal repair-loop diagnostics.

For example, if browser is disabled and the generated blueprint tries to use
`browser_navigate`, validation should fail with a repairable "toolset disabled"
diagnostic instead of crashing or silently ignoring the tool.

### RLM Coding Agent

The coding RLM environment should keep `source_discovery`,
`source_splitter`, and `source_materializer` as preferred local-file paths, but
action nodes should call the same capability registry for patch, terminal,
media, web, memory, and delegation operations.

Blueprint validation should include:

- tool exists;
- toolset is enabled;
- policy allows the operation;
- required backend/store/session resource exists;
- output can be persisted or represented as an artifact/ref.

## Presets

Start with presets that reflect existing behavior:

| Preset | Toolsets | Intended use |
| --- | --- | --- |
| `safe` | `file:read`, `web`, `memory:recall`, `media:vision/image_generate` | Read-only research and media generation. No terminal, patch, or delegation. |
| `coding-read` | `file`, `git`, `memory:recall` | Repo explanation, review, triage. |
| `coding-patch` | `file`, `git`, `patch`, `memory:recall` | Edit-capable runs without broad terminal access. |
| `coding-verify` | `file`, `git`, `patch`, `terminal:profile`, `process`, `memory:recall` | Current standard-agent verify behavior. |
| `research` | `web`, `browser`, `media:vision`, `memory:recall`, `file:read` | External research with optional browser automation. |
| `full-local` | all local toolsets except destructive git/write-outside-workspace | Explicit advanced mode with review gates. |

The default should stay conservative per interface:

- CLI `standard`: current mode-derived coding profile.
- CLI `assistant`: `coding-verify` unless overridden, matching current local
  assistant expectations.
- Web workbench: `coding-verify` with `approval: safe` or `ask` depending on
  operator choice, but browser/web/media disabled until explicitly enabled.

## Implementation Plan

### Phase 1: Capability Resolver Over Existing Tools

- [ ] Add `RunicAI.Agent.CapabilityProfile` or equivalent data contract.
- [ ] Add a resolver that maps presets/toolsets/disabled tools/config into a
      merged `%RunicAI.Tool.Registry{}` and visible tool list.
- [ ] Register existing coding tools under explicit toolsets:
      `file`, `git`, `patch`, `terminal`, `process`, `profile`, `verify`.
- [ ] Persist resolved capability metadata in run/session launch events.
- [ ] Keep current default behavior unchanged.

Validation:

- [ ] Unit tests cover preset expansion, disabled tools, unknown toolsets, and
      unknown tools.
- [ ] Existing standard-agent tests pass without behavior drift.

### Phase 2: CLI And Web Runtime Surfacing

- [ ] Add CLI parsing for `--toolsets`, `--disable-tool`, `--tool-config`, and
      `--profile`.
- [ ] Add web advanced run controls for profile/toolset selection.
- [ ] Show resolved capability profile on the run page.
- [ ] Persist `capability_profile_updated` events for runtime changes.

Validation:

- [ ] CLI parser tests cover new flags and existing `--mode` shortcuts.
- [ ] Web LiveView tests cover submitting runs with toolsets and disabled tools.

### Phase 3: Memory And Session Recall Tools

- [ ] Add `memory_write`, `memory_recall`, and `session_search` tool
      definitions.
- [ ] Wire `session_search` to SQLite/FTS query helpers and compact summaries.
- [ ] Add memory tool visibility to standard, assistant, and RLM profiles.

Validation:

- [ ] A multi-turn run can recall a prior persisted decision without restating
      it in the prompt.
- [ ] Search results include session/run/source refs.

### Phase 4: Web And Media Toolsets

- [ ] Add explicit `web_search` and `web_extract` tools with provider adapters.
- [ ] Add `RunicAI.Media` wrappers around ReqLLM image, speech, transcription,
      OCR, and vision prompt support.
- [ ] Persist extracted web sources and media outputs as artifacts.

Validation:

- [ ] Web search/extract smoke records source artifacts and citations.
- [ ] Media tool tests use fake clients plus at least one optional live smoke
      when credentials are available.

### Phase 5: Browser Automation Toolset

- [ ] Add a supervised browser session process.
- [ ] Add navigate/snapshot/click/type/scroll/console/screenshot tools.
- [ ] Add `browser_vision` by composing browser screenshots with media vision.
- [ ] Add browser backend/domain/recording config to capability profiles.

Validation:

- [ ] Browser tool tests use a local fixture page.
- [ ] Workbench distinguishes "agent browser" tool activity from the workbench
      UI itself.

### Phase 6: Delegation And Clarification Tools

- [ ] Add `clarify` as a model-visible wait/review tool.
- [ ] Add `delegate_task` over child `Runtime.SessionSpec` or decomposition
      assignments with restricted child capability profiles.
- [ ] Persist parent/child links through `subagent_runs` and terminal events.
- [ ] Render child runs in CLI/TUI/web as linked lanes, not prompt-stuffed text.

Validation:

- [ ] Parent run delegates two read-only child tasks and receives compact final
      summaries.
- [ ] Child intermediate tool calls are persisted but not injected wholesale
      into the parent context.

## Open Decisions

- Should `web_search` be a pure provider adapter, or should provider-native
  ReqLLM search be one selectable backend?
- Should browser automation use Playwright, Chrome DevTools Protocol directly,
  or an MCP/browser-use style adapter?
- Should `memory_write` allow direct model writes by default, or require user
  approval for durable memory changes?
- Should `toolsets` be stored in application config for defaults, or only in
  per-run/session metadata initially?
- How much runtime mutation should be allowed mid-run versus on the next turn?

## Bottom Line

RunicAI already has the core substrate for terminal/files, tool selection,
guarded execution, persistence, memory contracts, decomposition, and interface
launch controls. The highest-leverage next move is a small capability-profile
layer that makes those powers explicit and configurable across all agents.

After that, web, browser, media, memory/session-search, and delegation can land
as ordinary toolsets. Each new capability should compile down to
`Tool.Definition`, existing guard/review policy, terminal events, artifacts, and
SQLite read models rather than creating special-purpose agent loops.
