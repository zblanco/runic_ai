# Hermes-Style Agent Tool Surface

Status: design note / implementation proposal

Date: 2026-05-13

Updated: 2026-05-22 to fold in the local Workbench direction that standard,
assistant, and RLM default sessions should be able to see richer local
computing capabilities, while unsafe command/code execution routes through
review/HITL instead of being hidden from the session entirely.

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
- <https://hermes-agent.nousresearch.com/docs/user-guide/features/browser>
- <https://hermes-agent.nousresearch.com/docs/reference/tools-reference>
- <https://hermes-agent.nousresearch.com/docs/reference/toolsets-reference>
- <https://nousresearch-hermes-agent.mintlify.app/reference/configuration-options>
- <https://github.com/vercel-labs/agent-browser>
- <https://raw.githubusercontent.com/NousResearch/hermes-agent/main/package.json>
- <https://raw.githubusercontent.com/NousResearch/hermes-agent/main/plugins/browser/browserbase/provider.py>
- <https://raw.githubusercontent.com/NousResearch/hermes-agent/main/plugins/browser/browser_use/provider.py>
- <https://raw.githubusercontent.com/NousResearch/hermes-agent/main/plugins/browser/firecrawl/provider.py>
- <https://raw.githubusercontent.com/NousResearch/hermes-agent/main/tools/browser_supervisor.py>

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
  toolsets: [
    :file,
    :git,
    :patch,
    :terminal,
    :process,
    :code_execution,
    :computing,
    :web,
    :browser,
    :media,
    :memory,
    :delegation
  ],
  disabled_tools: MapSet.new([]),
  config: %{
    terminal: %{
      backend: :local_argv,
      shell?: true,
      shell_review: :always,
      allowed_commands: ["git", "mix"],
      timeout_ms: 120_000
    },
    code_execution: %{
      backends: [:just_bash],
      runtimes: [:bash],
      review: :unsafe_actions
    },
    computing: %{components: [:enum, :stream, :string, :json, :file, :calendar, :io]},
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

Default Workbench visibility should prefer "available but gated" over
"unavailable." When a local user asks the index page at `http://localhost:4000/`
to inspect, edit, run tests, run a CLI command, or execute a script, the default
agent session should have a visible path to attempt that operation. The policy
layer should decide whether the operation can run immediately, needs browser
review, needs rewritten arguments, or is blocked.

For this purpose, a visible tool can still be policy-gated. For example,
`run_command`, shell-backed command execution, `execute_code`, `apply_patch`,
`process_write`, `process_kill`, and future sandbox exports should appear in
the resolved capability snapshot, but calls with unsafe classification should
produce a durable `ReviewRequest` before execution.

## Capability Matrix

| Toolset | Current status | Next surfacing work |
| --- | --- | --- |
| `file` | Implemented for coding agents: `list_dir`, `find_files`, `read_file`, `read_range`, `read_many`, `search_text`, `search_regex`. | Register as a named `file` toolset and allow `assistant`/`rlm` to receive the same registry when enabled. |
| `patch` | Implemented as `apply_patch` with workspace policy and review metadata. | Split from generic file tools so read-only sessions can enable file reads without writes. |
| `git` | Implemented read tools: `git_status`, `git_diff`, `git_log`, `git_show`, `git_branch`. | Keep read-only by default. Add mutating git actions only behind explicit review and probably a separate `git_write` toolset. |
| `terminal` | Implemented as bounded `run_command`, profile tasks, and command policy. Shell access is already opt-in at the policy layer. | Add capability config for backend, shell enablement, env allowlist, timeout, network intent, and output caps. |
| `process` | Implemented when a `ProcessRegistry` is supplied: start, poll, log, write, kill. | Make registry ownership explicit in runtime/session setup, and surface background process cards in web/TUI. |
| `code_execution` | Partially present: `just_bash` backend exists, RLM coding has `:script` nodes, assistant has safe generated function blueprints, and `.docs/046` sketches a sandbox library direction. | Promote to an explicit toolset with `execute_code`, `sandbox_status`, and backend metadata. Start with `just_bash` and host-policy-gated commands; evolve toward container/microVM backends. |
| `computing` | Partially present as assistant/RLM deterministic function blueprints and ad hoc components such as `record_map`, `record_group`, `tabular_parser`, `blueprint_transform`, and `blueprint_reduce`. | Add a broader safe standard-library component/tool layer for Enum/Stream/String/JSON/File/IO/Calendar/time/math/data-shaping tasks. |
| `memory` | Context-memory steps and `Memory.Store` exist. | Add `memory_write` and `memory_recall` tools that call the existing steps/store contracts. |
| `session_search` | SQLite terminal-event FTS and query helpers exist. | Add a model-visible `session_search` tool that searches prior sessions/events and returns summarized, cited results. |
| `web` | ReqLLM supports provider-native web-search options; RunicAI does not expose deterministic `web_search`/`web_extract` tools yet. | Add explicit web tools with provider adapters, markdown extraction, source refs, and citations. |
| `browser` | No model-callable browser automation toolset yet. The Phoenix workbench is an operator UI, not an agent browser. | Add a supervised browser session adapter with navigate/snapshot/click/type/scroll/console/screenshot/vision tools. |
| `media` | ReqLLM has image generation, speech, transcription, OCR, image content parts, and multimodal prompts. RunicAI's facade currently covers text/object/stream. | Add `RunicAI.Media` wrappers and tool definitions for vision, image generation, transcription, speech, and OCR, storing outputs as artifacts. |
| `delegation` | Decomposition roles, child assignments, workflow-backed delegates, and subagent persistence schemas exist. | Add `delegate_task` as a tool that launches restricted child sessions/workflows and returns only final summaries plus artifact refs. |
| `clarify` | Existing `ReviewRequest`, `Wait`, and browser HITL bridge cover the runtime shape. | Add a model-visible `clarify` tool that emits a wait/review request rather than fabricating a question inside ordinary assistant text. |
| `todo` | Planning exists in agent state/blueprints, but no durable per-session todo tool exists. | Add a lightweight todo state in session metadata or context graph if it improves longer runs. Keep it distinct from workflow execution state. |

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
- shell execution is visible in Workbench profiles but requires review by
  default;
- profile commands are preferred over arbitrary shell when they satisfy the
  objective;
- long-running commands use `ProcessRegistry`;
- risky operations emit `ReviewRequest`s and persist terminal/tool events.

### Default Workbench command posture

The first Workbench implementation should make these capabilities available to
all three default agents through the resolved profile:

- `standard`: visible coding registry plus profile commands, `run_command`,
  patching, and process tools when a process registry is available.
- `assistant`: assistant component catalog plus selected `Tool.Definition`
  leaves for file/git/patch/terminal/code execution and safe computing
  components.
- `rlm`: proposal node kinds and validators should allow tool, command,
  script, edit, and child-agent nodes when the resolved profile includes those
  toolsets.

The review layer, not agent identity, should be the primary safety boundary:

- `read_file`, `search_text`, and read-only git can run without review under
  normal workspace policy.
- `compile_project`, `run_tests`, and profile verification commands may run
  under `approval: safe` when they match the active project profile.
- `run_formatter`, `apply_patch`, `run_command`, shell commands,
  `start_process`, `process_write`, `process_kill`, and `execute_code` should
  generate review unless the user has explicitly approved an equivalent
  pattern.
- `just_bash` should be marked as an in-process virtual runtime, useful for
  safe demos and small scripts, not as a hard security boundary.
- future container/microVM code execution should still generate review when it
  requests network, host mounts, host export, or credential access.

This keeps the local index-page experience practical: "run the tests", "write
a small script to inspect this JSON", "try this CLI command", and "patch that
file" should all be reachable from default sessions, with browser HITL pausing
the run before unsafe effects.

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

### Hermes Browser Backend Context

Hermes is useful here because its browser feature separates model-visible tool
verbs from the concrete browser backend. The implementation lesson for RunicAI
is to define a backend behaviour and keep the tool surface stable.

Hermes exposes browser tools such as `browser_navigate`, `browser_snapshot`,
`browser_click`, `browser_type`, `browser_press`, `browser_scroll`,
`browser_get_images`, `browser_console`, `browser_cdp`, `browser_dialog`, and
browser-backed screenshot/vision flows. The Hermes toolset reference also
bundles `web_search` with the browser toolset as a fallback path when direct
browser navigation is not the right retrieval mechanism.

Current Hermes browser-use options observed from docs/source:

- Local default: `agent-browser`, a Node-launched native Rust CLI used by
  Hermes through its package dependency. It drives Chrome/Chromium-style browser
  sessions and returns compact accessibility snapshots with element refs.
- Local attached browser: Chrome-family browsers launched with a remote
  debugging port, then connected through CDP. This includes Chrome, Chromium,
  Brave, and Edge. Hermes also documents WSL2 using `chrome-devtools-mcp` as
  the bridge when the browser lives on the Windows host.
- Local anti-detection browser: Camoufox/Camofox can be run as a local service
  and reached through the browser provider configuration.
- Remote Browserbase: cloud browser sessions created with Browserbase API keys,
  project ids, optional proxies/stealth/keepalive configuration, and a returned
  CDP connection URL.
- Remote Browser Use: cloud browser sessions created with Browser Use API keys
  or Nous Tool Gateway credentials, again reduced to a browser connection URL
  for Hermes' low-level browser tools.
- Remote Firecrawl browser mode: browser sessions created through Firecrawl's
  API with TTL/configuration and then used as another backend.
- CDP escape hatch: Hermes includes raw CDP access plus a browser supervisor
  that watches page/runtime/target events for console, dialog, frame, and
  browser-state changes.

RunicAI should not import Hermes' provider layout directly. For Phase 7, use
this as backend selection context:

```elixir
%{
  toolset: :browser,
  backend: :agent_browser | :cdp | :browserbase | :browser_use | :firecrawl,
  launch: %{headless: true, executable: nil, cdp_url: nil},
  policy: %{allowed_domains: [], blocked_domains: [], network: :enabled},
  recording: %{screenshots: false, video: false, console: true},
  inactivity_timeout_ms: 120_000
}
```

The first RunicAI implementation should prefer either `:agent_browser` or
`:cdp` locally. `:agent_browser` gives us a Hermes-like CLI boundary and compact
accessibility refs. Direct `:cdp` gives us fewer dependencies and easier
Elixir-native supervision, but we would need to implement snapshot/ref
normalization ourselves. Browserbase, Browser Use, and Firecrawl should fit
behind the same backend behaviour later and should not change the model-visible
tools.

`browser_vision` should be an orchestration tool, not a browser-backend feature:
capture a screenshot through the selected browser backend, persist the image as
an artifact when enabled, then route analysis through `RunicAI.Media`.

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

Promote this from deferred to an explicit Workbench-local capability, but keep
it policy-gated.

Hermes uses code execution to batch tool calls through Python RPC. In RunicAI,
the better shape is a common execution contract with several backends:

- `:just_bash` for low-latency virtual Bash demos and tests;
- `:local_argv` / `:local_shell` for host commands under `CommandPolicy` and
  HITL;
- `:docker` / `:podman` as the first practical multi-language sandbox backend;
- future `:gvisor`, `:firecracker`, or remote microVM backends as described in
  `.docs/046-ai-code-sandboxing-research.md`.

Initial tool definitions:

- `execute_code`: run code through a selected runtime/backend.
- `sandbox_status`: report configured backends, runtimes, health, isolation
  level, and policy.
- `sandbox_command`: run argv inside a configured sandbox workspace.
- `sandbox_export`: export changed sandbox files as artifacts or reviewed
  patches.

Initial components:

- `RunicAI.RLM.Components.CodeEval`
- `RunicAI.RLM.Components.ScriptMap`
- `RunicAI.RLM.Components.SandboxCommand`

Initial policy:

- visible in default Workbench profiles;
- disabled in non-local/headless profiles unless explicitly configured;
- `just_bash` execution can be approved as safe only for small bounded scripts
  with no network/host side effects;
- host shell, arbitrary argv, sandbox network, host export, and long-running
  processes require review by default;
- every result records backend, isolation level, cwd, network policy, changed
  files, artifacts, duration, and output truncation metadata.

The first implementation can reuse `RunicAI.Coding.CommandRunner` and
`RunicAI.Coding.CommandResult` for result shape, but `execute_code` should not
be permanently folded into `run_command`. Code execution should become a
sidecar/sandbox contract that RunicAI consumes through tools/components.

## Safe Computing Components

Hermes users lean on tools that let the agent do small bits of computation,
data cleanup, transformation, and local automation without a full shell. RunicAI
should add a general-purpose `computing` toolset/component layer that wraps
safe Elixir standard-library patterns as data-driven components.

The goal is not to expose arbitrary Elixir evaluation. The goal is to give
assistant/RLM workflow drafting a broader set of deterministic building blocks
before it reaches for LLM calls, shell, or sandboxed code.

### Enum, Stream, And Collection Components

Useful component/tool shapes:

- `collection_map`: apply an allowlisted transform or generated function
  blueprint to each item.
- `collection_filter`: filter records by predicate descriptors.
- `collection_group`: group by path/key/function.
- `collection_sort`: sort records by key, direction, and nil policy.
- `collection_dedupe`: dedupe by key/path/hash.
- `collection_reduce`: count, sum, min, max, join, merge maps, merge lists.
- `collection_window`: chunk, sliding window, sample, take/drop.

Implementation should use `Enum` for materialized bounded data and `Stream`
only when the source and sink are both bounded by policy. Stream components
must still report item counts, caps, and truncation.

### String And Text Components

Useful components:

- `string_split`, `string_join`, `string_replace`, `string_trim`;
- `regex_extract` and `regex_replace` with timeout/size guards;
- `text_chunk` by bytes, lines, paragraphs, headings, or tokens estimate;
- `text_diff_summary` for compact before/after previews;
- `template_render` with allowlisted variables and no code execution.

These give the assistant a deterministic path for common cleanup work:
normalizing logs, extracting IDs, building summaries from structured data, and
preparing prompt slices.

### JSON, Maps, And Structured Data Components

Useful components:

- `json_parse`, `json_encode`, `json_query`;
- `map_get`, `map_put`, `map_pick`, `map_drop`, `map_merge`;
- `schema_validate` with JSON-schema-like or existing `ValueContract`
  descriptors;
- `records_from_jsonl`, `records_to_jsonl`;
- `table_from_csv`, `table_to_csv`.

These should compose with existing `tabular_parser`, `record_map`, and
`record_group`, not replace them.

### File, IO, And Artifact Components

Useful components:

- `artifact_read`, `artifact_write`, `artifact_transform`;
- `file_manifest`: bounded directory manifest with hashes/metadata;
- `file_copy_to_artifact`: copy selected workspace files into durable
  artifacts;
- `file_render_preview`: markdown/code/data preview with caps;
- `io_capture`: normalize stdout/stderr/stdin-like data from command/code
  results.

Direct filesystem access must still go through `Workspace` and `PathPolicy`.
Writes to workspace files should prefer `apply_patch` or `artifact_writer`
with review.

### Calendar, Time, And Scheduling Components

Useful components:

- `time_now`: local/UTC timestamp with timezone metadata;
- `time_parse`: parse ISO/date/time strings and report failures;
- `time_shift`: add/subtract durations;
- `time_range`: build bounded ranges;
- `calendar_compare`: compare dates/deadlines;
- `deadline_plan`: derive due/overdue/upcoming labels from current time.

These are useful for personal-assistant tasks without needing external calendar
connectors.

### Math, Scoring, And Ranking Components

Useful components:

- `score_records`: apply weighted criteria to records;
- `rank_records`: rank with deterministic tie handling;
- `bucket_records`: classify into labels by thresholds;
- `aggregate_metrics`: count/sum/average/min/max over numeric fields;
- `normalize_scores`: min-max or fixed-scale normalization.

These can support reviews, triage, personal task prioritization, and eval
reports without an LLM doing arithmetic in text.

### Component Policy

The `computing` layer should reuse assistant generated-function tiers:

- Tier 0: named built-in operations only.
- Tier 1: restricted expression tree interpreted by RunicAI.
- Tier 2: future reviewed code/sandbox execution.

Default assistant/RLM generation should prefer Tier 0/Tier 1 computing
components before proposing `execute_code` or shell commands. If a computing
component cannot express the operation, the repair loop can escalate to
`execute_code` and explain why review is needed.

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
  --profile local-workbench \
  --toolsets file,git,patch,terminal,code_execution,computing,memory \
  --tool-config web.provider=tavily \
  --tool-config memory.session_search=true \
  --tool-config terminal.shell_review=always
```

Suggested flags:

- `--toolsets a,b,c`
- `--disable-tool name`
- `--tool-config key=value`
- `--profile safe|coding-read|coding-patch|coding-verify|local-workbench|research|full-local`
- `--allow-tool name` as an explicit per-run override for otherwise disabled
  tools.

Keep existing `--mode read_only|patch|verify` as a high-confidence shortcut for
coding runs. It can expand into a capability profile internally.

### Web UI

The browser composer currently exposes agent, mode, model, and approval. Add an
advanced run drawer with:

- profile preset;
- toolset toggles;
- per-tool disabled list;
- terminal/backend settings;
- code execution backend/runtime settings;
- safe computing component families;
- web provider/domain settings;
- browser enablement and recording settings;
- memory/session-search enablement;
- media model/output settings;
- resolved launch profile preview.

Every run page should show the resolved capability snapshot:

- enabled toolsets;
- disabled tools;
- gated-but-visible tools;
- write policy;
- approval mode;
- network/browser/media status;
- command/code backend and isolation level;
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

For Workbench runs, the standard agent should include `run_command` and process
tools in the resolved registry when the profile includes `terminal`/`process`,
even if those calls require review. This avoids the current mismatch where
profile wrappers are visible but arbitrary local commands are not reachable from
the default session.

### Assistant Agent

The assistant RLM path should receive the same resolved capability profile and
include allowed toolsets/components in blueprint proposal prompts. The compiler
and validator should reject generated tool leaves that are not allowed by the
profile, returning normal repair-loop diagnostics.

For example, if browser is disabled and the generated blueprint tries to use
`browser_navigate`, validation should fail with a repairable "toolset disabled"
diagnostic instead of crashing or silently ignoring the tool.

Assistant blueprints should gain two execution routes:

1. native component route for `computing`, source, map/reduce, report,
   artifact, memory, and scorecard work;
2. tool-leaf route for file/git/patch/terminal/code execution tools resolved
   from the capability profile.

Unsafe tool leaves should not be silently omitted. They should compile to
reviewable execution requests so the WebUI can pause, show the exact command or
code, and resume with approve/deny/rewrite.

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

The RLM coding validator should stop treating command/script/edit as globally
disabled defaults. It should derive that decision from the resolved profile:

- `terminal` enables `:command` nodes, with allowed command lists and review
  policy from the profile.
- `code_execution` enables `:script`/future `:code_eval` nodes, with backend
  constraints from the profile.
- `patch` enables `:edit` nodes.
- `computing` enables safe deterministic transform nodes.

When the profile says the toolset is visible but gated, validation should accept
the node and execution should emit review before side effects.

## Presets

Start with presets that reflect existing behavior:

| Preset | Toolsets | Intended use |
| --- | --- | --- |
| `safe` | `file:read`, `web`, `memory:recall`, `media:vision/image_generate` | Read-only research and media generation. No terminal, patch, or delegation. |
| `coding-read` | `file`, `git`, `memory:recall` | Repo explanation, review, triage. |
| `coding-patch` | `file`, `git`, `patch`, `memory:recall` | Edit-capable runs without broad terminal access. |
| `coding-verify` | `file`, `git`, `patch`, `terminal:profile`, `process`, `memory:recall` | Current standard-agent verify behavior. |
| `local-workbench` | `file`, `git`, `patch`, `terminal`, `process`, `code_execution:just_bash`, `computing`, `memory:recall`, `session_search` | Default local WebUI profile: powerful local computing, with command/code/edit side effects review-gated. |
| `research` | `web`, `browser`, `media:vision`, `memory:recall`, `file:read` | External research with optional browser automation. |
| `full-local` | all local toolsets except destructive git/write-outside-workspace | Explicit advanced mode with review gates. |

The default should stay conservative per interface:

- CLI `standard`: current mode-derived coding profile.
- CLI `assistant`: `coding-verify` unless overridden, matching current local
  assistant expectations.
- Web workbench: `local-workbench` with `approval: safe` or `ask` depending on
  operator choice. File/git/profile commands can run under safe policy; shell,
  broad CLI, code execution, patch/export, process mutation, browser, web,
  media, and network escalation are visible but review-gated until explicitly
  approved or enabled.

## Implementation Plan

### Phase 1: Capability Resolver Over Existing Tools

- [x] Add `RunicAI.Agent.CapabilityProfile` or equivalent data contract.
- [x] Add a resolver that maps presets/toolsets/disabled tools/config into a
      merged `%RunicAI.Tool.Registry{}` and visible tool list.
- [x] Register existing coding tools under explicit toolsets:
      `file`, `git`, `patch`, `terminal`, `process`, `profile`, `verify`.
- [x] Add `local-workbench` as the default WebUI profile with visible but
      review-gated terminal, patch, process, code execution, and computing
      toolsets.
- [x] Represent "visible but gated" separately from "disabled" in the resolved
      profile.
- [x] Persist resolved capability metadata in run/session launch events.
- [x] Keep existing CLI mode behavior unchanged unless `--profile` or
      `--toolsets` is supplied.
- [x] Intentionally move the WebUI default from the narrower implicit
      `coding-verify` shape to `local-workbench` once browser review for gated
      tools is working.

Validation:

- [x] Unit tests cover preset expansion, disabled tools, unknown toolsets, and
      unknown tools.
- [x] Unit tests cover gated-visible tools producing review requirements rather
      than disappearing from the profile.
- [x] Existing standard-agent tests pass without behavior drift.

### Phase 2: Command, Code Execution, And Edit Surfacing

- [x] Expose `run_command` to the standard Workbench profile with review-gated
      shell/unsafe argv policy.
- [x] Teach assistant workflows to compile capability-profile tool leaves for
      file/git/patch/terminal/code execution tools.
- [x] Teach RLM coding validation to derive command/script/edit allowance from
      capability profiles instead of fixed default disablement.
- [x] Add `execute_code` and `sandbox_status` backed initially by `just_bash`
      and existing command-result/result-artifact contracts.
- [x] Record command/code backend metadata, isolation level, cwd, network
      policy, output caps, and changed artifact refs in terminal/tool events.

Validation:

- [x] From the WebUI index page, an assistant request can propose a shell/CLI
      command and pause for browser review before execution.
- [ ] From the WebUI index page, an RLM coding request can propose command or
      script nodes when the profile includes terminal/code execution.
- [x] Deny/rewrite/approve paths work for `run_command`, `execute_code`, and
      `apply_patch`.

Validation note, 2026-05-22: deterministic tests now cover capability-profile
tool leaves, RLM command/script/edit validation, Workbench launch profile
persistence, and deny/rewrite/approve execution paths. The live WebUI RLM
model-smoke check remains open.

Validation note, 2026-05-22 browser pass: a default `/` assistant launch asking
to run `printf runic_ai_hitl_printf_allowed_v2` now routes the explicit local
command objective into the standard harness, forces tool use, persists a
canonical browser review request, and resumes from browser approval. The
approved `project_command` executes as argv, returns
`runic_ai_hitl_printf_allowed_v2`, and records `hitl_approved?` metadata. The
command allowlist remains the no-HITL fast path; user approval can authorize a
specific non-allowlisted command for the reviewed run.

### Phase 3: CLI And Web Runtime Surfacing

- [x] Add CLI parsing for `--toolsets`, `--disable-tool`, `--tool-config`, and
      `--profile`.
- [x] Add web advanced run controls for profile/toolset selection.
- [x] Show resolved capability profile on the run page.
- [x] Persist `capability_profile_updated` events for runtime changes.
- [x] Show gated tools and pending review reason in the run inspector.

Validation:

- [x] CLI parser tests cover new flags and existing `--mode` shortcuts.
- [x] Web LiveView tests cover submitting runs with toolsets and disabled tools.

### Phase 4: Safe Computing Components

- [x] Add Tier 0/Tier 1 computing component catalog entries for collection,
      string, JSON/map, artifact/file, time/calendar, and scoring/ranking
      operations.
- [x] Add model-facing manifest text so assistant/RLM planning prefers safe
      computing components before shell/code execution.
- [x] Wire safe computing components into assistant component runtime.
- [x] Allow RLM coding workflows to use computing nodes for bounded deterministic
      transforms.

Validation:

- [x] Assistant workflow can parse JSON, group records, rank records, and
      compose a report without shell/code execution.
- [ ] RLM workflow can use deterministic transforms and repair invalid
      component parameters.
- [x] Tier 2/source-code requests are rejected or escalated to `execute_code`
      review.

### Phase 5: Memory And Session Recall Tools

- [x] Add `memory_write`, `memory_recall`, and `session_search` tool
      definitions.
- [x] Wire `session_search` to SQLite/FTS query helpers and compact summaries.
- [x] Add memory tool visibility to standard, assistant, and RLM profiles.

Validation:

- [ ] A multi-turn run can recall a prior persisted decision without restating
      it in the prompt.
- [x] Search results include session/run/source refs.

Validation note, 2026-05-22: deterministic tests now cover assistant safe
compute workflows, coding RLM computing nodes, capability-profile visibility
for standard/assistant/RLM, local memory write/recall, and SQLite FTS-backed
session search with session/run/source refs. The RLM computing validation still
needs a focused repair-loop case for invalid component parameters, and the
remaining memory item requires a live multi-turn agent session to prove
end-user recall behavior through the UI.

### Phase 6: Web And Media Toolsets

- [x] Add explicit `web_search` and `web_extract` tools with provider adapters.
- [x] Add `RunicAI.Media` wrappers around ReqLLM image, speech, transcription,
      OCR, and vision prompt support.
- [x] Persist extracted web sources and media outputs as artifacts.

Validation:

- [x] Web search/extract smoke records source artifacts and citations.
- [x] Media tool tests use fake clients; optional live smoke remains
      credential-gated.

Validation note, 2026-05-22: deterministic tests cover static-provider
`web_search`/`web_extract`, source refs, and persisted source artifacts. Media
tests cover fake-client image generation, speech generation, transcription,
OCR, and vision analysis with persisted binary/text artifacts. No live
credentialed media smoke was run in this implementation pass.

### Phase 7: Browser Automation Toolset

- [x] Add a supervised browser session process.
- [x] Add navigate/snapshot/click/type/scroll/console/screenshot tools.
- [x] Add `browser_vision` by composing browser screenshots with media vision.
- [x] Add browser backend/domain/recording config to capability profiles.
- [x] Define a browser backend behaviour with at least local `:agent_browser`
      or direct `:cdp` support first, leaving Browserbase, Browser Use, and
      Firecrawl as later backend adapters behind the same interface.
- [x] Normalize browser observations into compact accessibility snapshots,
      console events, screenshot artifacts, and stable element refs independent
      of backend.

Validation:

- [x] Browser tool tests use a local fixture page.
- [x] Backend adapter tests use a fake browser backend; optional local browser
      smoke remains gated on Chrome/Chromium or `agent-browser` availability.
- [x] Workbench distinguishes "agent browser" tool activity from the workbench
      UI itself.

Validation note, 2026-05-22: `RunicAI.Browser.Session` now supervises a
backend process boundary, `RunicAI.Browser.Backends.Fake` validates the fixture
contract, and `RunicAI.Browser.Backends.AgentBrowser` provides the first local
`agent-browser` CLI adapter when the executable is available. Browser tool tests
cover navigate, snapshot refs, click, console, screenshot artifact persistence,
and screenshot-to-media `browser_vision`. No live local browser smoke was run
because validation stayed deterministic.

### Phase 8: Delegation And Clarification Tools

- [x] Add `clarify` as a model-visible wait/review tool.
- [x] Add `delegate_task` over child `Runtime.SessionSpec` or decomposition
      assignments with restricted child capability profiles.
- [x] Persist parent/child links through `subagent_runs` and terminal events.
- [x] Render child runs in CLI/TUI/web as linked lanes, not prompt-stuffed text.

Validation:

- [x] Parent run delegates two read-only child tasks and receives compact final
      summaries.
- [x] Child intermediate tool calls are persisted but not injected wholesale
      into the parent context.

Validation note, 2026-05-22: tests cover `clarify` returning a typed
`RunicAI.Wait`, `delegate_task` returning compact child summaries, and SQLite
projection into `subagent_runs` through terminal events. The current
implementation supports caller-supplied child runners and records compact final
results; it does not yet launch fully independent live child sessions by
default.

## Open Decisions

- Should `web_search` be a pure provider adapter, or should provider-native
  ReqLLM search be one selectable backend?
- Should the first local browser backend be `agent-browser` for Hermes-like
  accessibility snapshots, direct CDP for fewer moving pieces, or both with one
  adapter marked experimental?
- Should `memory_write` allow direct model writes by default, or require user
  approval for durable memory changes?
- Should `toolsets` be stored in application config for defaults, or only in
  per-run/session metadata initially?
- How much runtime mutation should be allowed mid-run versus on the next turn?
- Should `local-workbench` be the global WebUI default, or should the first-run
  setup ask the user to choose between `coding-verify` and `local-workbench`?
- Should approved command/code patterns be remembered per session only, per
  workspace, or never remembered?
- Which safe computing components should be model-visible tools versus
  assistant/RLM-only components?

## Bottom Line

RunicAI already has the core substrate for terminal/files, tool selection,
guarded execution, persistence, memory contracts, decomposition, and interface
launch controls. The highest-leverage next move is a small capability-profile
layer that makes those powers explicit and configurable across all agents.
For the local Workbench, that layer should expose powerful file, edit,
terminal, process, code-execution, and safe-computing capabilities by default,
then rely on review/HITL and backend policy to control unsafe effects.

After that, web, browser, media, memory/session-search, and delegation can land
as ordinary toolsets. Each new capability should compile down to
`Tool.Definition`, safe component specs, existing guard/review policy, terminal
events, artifacts, and SQLite read models rather than creating special-purpose
agent loops.
