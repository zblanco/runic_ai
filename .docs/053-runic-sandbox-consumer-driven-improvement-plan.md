# Runic Sandbox Consumer-Driven Improvement Plan

Status: active

Date: 2026-05-30

## Purpose

The streaming/attach dogfood pass proved that `runic_sandbox` now has the
right public shape for long-running process containment, but the Ariston sync
notes show where the next useful substrate work should go. The target consumer
is not an abstract sandbox benchmark. It is a real workflow loop:

```text
planner detects missing capability
  -> generate a leaf component or adapter
  -> prove it inside an isolated sandbox
  -> stream proof evidence into the host trace
  -> promote only after policy, tests, and review pass
```

RunicAI needs this for generated Runic components. Ariston needs the same
boundary for CLI-in-sandbox containment and its generate-at-leaf workflow
drafting loop. The improvement plan below keeps those two consumers aligned so
`runic_sandbox` evolves around concrete adoption pressure instead of adding
backend features in isolation.

Related docs and external consumers:

- `.docs/052-runic-sandbox-streaming-and-mcp-dogfood-plan.md`
- `.docs/051-sandbox-agent-exposure-and-rlm-repl-plan.md`
- `.docs/036-runic-native-dynamic-workflow-generation-refactor-plan.md`
- `.docs/055-tensorlake-sandbox-reference-takeaways.md`
- `.docs/ariston-sandbox-sync-2.md`
- Ariston PR #790: CLI-in-sandbox output-streaming containment bridge
- Ariston PR #778: `runic_sandbox` pin to Zack's attach/streaming push
- Ariston PR #771: section-6 streaming/attach and MCP-boundary spec
- Ariston PR #769: high-level sandbox containment memo

## Delivered Capabilities

- Explicit attach readiness metadata across backends, including
  `attach_mode`, live-vs-terminal streaming, stdin support, stderr separation,
  PTY support, restricted-egress support, MCP-boundary support, and default
  sandbox cwd.
- A clear split between true live attach streams and terminal attach adapters,
  so Docker can advertise live stdin-capable attach while JustBash, Lua, Vmsan,
  Sprites, and Remote/Fly stay honest as one-shot terminal adapters.
- Consumer-neutral attach event bridge semantics for ordered stdout/stderr
  chunks, terminal reconciliation, backend-failure precedence, missing-terminal
  failures, byte/chunk counts, and attach/session metadata.
- RunicAI generated-component proof execution on top of `runic_sandbox`, with
  sandbox-only source/test materialization, attach summary evidence, cleanup
  reporting, and verified-vs-draft component status.
- Proof-gated generated-component promotion flow in RunicAI, including
  coordinator entry point, promotion decision record, repair context, and
  workflow composition only after sandbox proof passes.
- Restricted-network policy shape that distinguishes deny-all restricted mode
  from scoped egress allow-list intent and fails closed when a backend cannot
  enforce requested scoped egress.
- MCP-boundary policy metadata for `host_forward`, `unix_socket`, and
  `egress_allowlist` intent, with fail-closed behavior when the selected
  backend cannot provide the requested boundary.
- Managed active-attach lifecycle tracking, including active attach metadata,
  pool release/reset guards, idempotent close behavior, stream finalization,
  and leak diagnostics.
- Provider dogfood and certification across Docker, Vmsan, Sprites, and
  Remote/Fly, preserving terminal-vs-live truth and recording provider
  transport evidence.
- Sprites portability fixes for default cwd metadata, request-file
  materialization, binary file writes, and multiplexed stdout/stderr frame
  decoding.
- Vmsan CLI hardening around command separators, forced cleanup, workspace
  preparation, sudo handling, and zero-leftover VM cleanup checks.
- Session authority hardening under concurrent callers, with an atomic
  first-use authority-secret initializer and a concurrent-open regression test.

## Consumer Use Cases

### RunicAI Generated Component Promotion

RunicAI should let a coordinator generate a new leaf only when the existing
component catalog is insufficient. That generated leaf must be treated as
untrusted until a sandbox proof produces durable evidence:

- source files or inline code generated in a sandbox workspace;
- compile, unit-test, smoke-test, or contract-test output;
- structured input/output contract validation;
- stdout/stderr event trace;
- artifact references and provenance;
- explicit promotion decision.

This path does not require full provider CLI containment on day one. It does
require reliable sandbox sessions, attach-shaped streaming, bounded network
policy, file/artifact capture, and clear readiness metadata.

### Ariston CLI-In-Sandbox Containment

Ariston already wired the consumer side at `HarnessAdapter.run/3`. When
`:sandbox_backend` is supplied, Ariston opens a `RunicSandbox` session, gates on
streaming capability, calls `RunicSandbox.attach`, reconstructs the provider
CLI's NDJSON stream from `:stdout_chunk` events, and emits the same harness
events as the host path.

The remaining Ariston blocker is stronger than RunicAI's first promotion loop:
the contained process is a long-lived agent CLI that needs live stdio and a
scoped MCP/model boundary. That makes Ariston a useful early adopter for the
same substrate while also pushing the harder interactive and network pieces.

## Current Baseline

Already present locally:

- `RunicSandbox.AttachHandle`
- `RunicSandbox.attach/3`
- `RunicSandbox.write_stdin/3`
- `RunicSandbox.close_attach/2`
- optional backend callbacks for attach, stdin, and close
- `Capabilities.streaming?`
- `SessionEvent` chunk types:
  - `:stdout_chunk`
  - `:stderr_chunk`
  - `:stdin_ack`
- Docker live `Port` attach with stdin support
- terminal attach adapters for backends that only expose one-shot execution
- backend health and session capability metadata

Known limitations:

- `Policy.network == :restricted` now distinguishes deny-all from scoped
  allow-list intent, but Docker and Vmsan still do not enforce scoped egress.
- `Capabilities.streaming?` means "can produce the attach event model", not
  "is live while the process runs".
- Docker currently folds stderr into stdout because the implementation uses the
  Docker CLI through an Erlang port.
- Sprites, Remote/Fly, Vmsan, JustBash, and Lua can expose attach-shaped events
  but are terminal adapters today.
- MCP-over-boundary has first-class metadata, but no enforced transport has
  been selected yet.
- RunicAI now has a proof-first generated-component promotion flow; durable
  proof persistence remains a future hardening step.

## Implementation Slice Ledger

This plan should be delivered in small substrate slices. Each slice must update
this ledger before implementation, land focused package tests, run package-local
validation, run live smokes when the relevant backend is available, and record
the result back into this document.

| Slice | Scope | Deliverables | Acceptance criteria | Validation | Status |
| --- | --- | --- | --- | --- | --- |
| 1. Attach readiness metadata | Make attach capability shape explicit without changing backend behavior. | `Capabilities.attach_mode/1`; helper predicates for live streaming, terminal adapters, stdin, stderr separation, MCP boundary, restricted egress, and PTY; backend/session metadata populated for current adapters. | Consumers can distinguish `:none`, `:terminal_adapter`, and `:live_stream`; terminal adapters are not mistaken for interactive hosting; Docker reports live stdin support; health/session capability maps carry the same effective metadata. | `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs`; `mix runic_sandbox.doctor --format json`; live Docker/Vmsan smokes when local providers are available. | Completed 2026-05-30 |
| 2. Event bridge semantics | Normalize attach event consumption before RunicAI builds generated-component proof logs. | Consumer-neutral event bridge that summarizes chunks, terminal status, missing terminal failure, backend-failure precedence, counts, and metadata. | One bridge covers success, failure, success-then-backend-failure, missing terminal, stdout/stderr ordering, and cleanup. | Focused bridge tests plus Docker/Vmsan terminal-output smoke. | Completed 2026-05-30 |
| 3. Generated-component proof runner | Prove generated leaf code through sandbox sessions before full CLI containment. | RunicAI proof structs/runner, sandbox-only source materialization, proof artifact summary, terminal-adapter support. | A generated Bash/Elixir leaf can be proven without writing source to the host tree; failure captures stdout/stderr and terminal status. | Focused RunicAI tests plus JustBash/Docker/Vmsan smoke. | Completed 2026-05-30 |
| 4. Restricted-network contract | Make `Policy.network == :restricted` carry explicit allow/deny intent. | Policy metadata validation, effective readiness reporting, fail-closed unsupported behavior for enforceable allow-lists. | Allow-list requests never silently degrade to broad egress or deny-all; consumers can require restricted egress support before execution. | Policy tests plus Docker deny-all and unsupported-allow-list checks. | Completed 2026-05-30 |
| 5. MCP boundary metadata | Describe MCP reachability independently from transport. | Profile/policy metadata for `:host_forward`, `:unix_socket`, or `:egress_allowlist`; health/readiness support flags. | Ariston and RunicAI can fail closed when MCP boundary support is absent. | Metadata tests plus local endpoint smoke once a transport is selected. | Completed 2026-05-30 |
| 6. Active attach lifecycle | Make long-running attached processes visible to session management. | Active attach metadata/state, idempotent close semantics, leak diagnostics. | A session with an active attach is not reused concurrently; stream termination releases resources. | Manager/session tests plus Docker live attach smoke. | Completed 2026-05-30 |
| 7. Provider attach certification | Prove provider-backed attach behavior under real credentials and promote only native live streams. | Real-provider smoke matrix for Remote/Fly and Sprites, explicit terminal-vs-live metadata, provider transport evidence, and follow-up criteria for native stream promotion. | Provider-backed terminal adapters stay `streaming_live?: false`; `streaming_live?: true` is used only for a proven native live stream with live chunks/stdin; unsupported stdin fails consistently. | Package tests plus live Fly/Sprites smokes when credentials are present. | Completed 2026-05-30 |
| 8. RunicAI promotion integration | Wire generated-component proof into the iterative promotion flow above the sandbox package. | Coordinator-facing proof invocation, promotion decision record, repair-loop evidence, and trace/read-model event surface. | Generated leaves are not composable/promotable until sandbox proof passes; failed proofs preserve attach evidence and can drive a repair turn. | Focused RunicAI tests plus Docker/Sprites proof smokes. | Completed 2026-05-30 |
| 9. Completion audit and hardening | Audit the accumulated slices against the original objective and package boundary before declaring the goal complete. | Requirement-by-requirement checklist, broad validation set, docs consistency pass, and any final small fixes. | All explicitly requested sandbox/interface priorities are proven by current tests, live smokes, and plan evidence; remaining work is clearly out-of-scope future roadmap. | Full relevant test matrix plus current provider/resource cleanup checks. | Completed 2026-05-30 |

### Slice 1 Notes

Slice 1 is intentionally additive. It must not change `attach/3` behavior or
require every backend to support live attach. The goal is to make the existing
truth machine-readable:

- Docker/GVisor: `attach_mode: :live_stream`, `stdin_supported?: true`,
  `stderr_separate?: false` for the current Docker CLI transport.
- JustBash/Lua/Sprites/Remote/Vmsan: `attach_mode: :terminal_adapter`,
  `stdin_supported?: false`, `terminal_result_adapter?: true`.
- Backends with no attach callback: `attach_mode: :none`.
- `Capabilities.streaming?` remains broad compatibility metadata for now, but
  new consumers should use `Capabilities.attach_mode/1` and helper predicates.

Slice 1 implementation result:

- Added `RunicSandbox.Capabilities.attach_mode/1`,
  `attach_supported?/1`, `streaming_live?/1`,
  `terminal_result_adapter?/1`, `stdin_supported?/1`,
  `stdin_close_supported?/1`, `stderr_separate?/1`,
  `mcp_boundary_supported?/1`, `restricted_egress_supported?/1`, and
  `pty_supported?/1`.
- Added `RunicSandbox.Capabilities.attach_metadata/2` so backends can populate
  a consistent metadata shape while still carrying provider-specific fields.
- Populated attach metadata for current adapters:
  - Docker/GVisor: `:live_stream`, stdin supported, stderr not separate under
    the current Docker CLI port transport.
  - JustBash/Lua/Sprites/Remote/Vmsan: `:terminal_adapter`, stdin unsupported.
- Validation:
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs` passed:
    `42 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix runic_sandbox.doctor --format json`
    reported expected metadata:
    Docker/GVisor as `live_stream`; JustBash/Lua/Vmsan/Sprites/Remote as
    `terminal_adapter`.
  - Live Docker attach smoke reported `attach_mode: :live_stream`,
    `streaming_live?: true`, `stdin_supported?: true`, and event types
    `[:exec_started, :stdout_chunk, :exec_finished]`.
  - Live Vmsan attach smoke reported `attach_mode: :terminal_adapter`,
    `streaming_live?: false`, `stdin_supported?: false`, and event types
    `[:exec_started, :stdout_chunk, :exec_finished]`.
  - `vmsan list --json` was empty after cleanup.

Next slice: implement the shared event bridge semantics so RunicAI generated
component proof logs and Ariston-style consumers do not each have to re-create
terminal reconciliation.

### Slice 2 Notes

Slice 2 should stay consumer-neutral and package-local. It should not introduce
RunicAI trace event structs or Ariston harness event structs. The bridge should
produce a normalized summary that downstream consumers can map into their own
event surfaces.

Required bridge semantics:

- preserve stdout/stderr chunk order and combined output order;
- track byte counts and chunk counts per stream;
- preserve the last terminal `:exec_finished` payload for inspection;
- synthesize a failure summary if the stream ends without `:exec_finished`;
- allow a backend failure terminal to override an earlier success terminal;
- dedupe repeated success terminals by keeping the first success summary stable;
- carry attach/session/backend metadata into the summary.

Slice 2 implementation result:

- Added `RunicSandbox.AttachBridge.summarize/2`, a consumer-neutral summary
  bridge for attach handles and event streams.
- The bridge now reports:
  - `stdout`, `stderr`, and `combined` output;
  - ordered chunk metadata with stream, byte count, event id, event timestamp,
    and event metadata;
  - per-stream chunk counts and byte counts;
  - effective terminal status and exit status;
  - terminal count and last terminal payload;
  - synthetic missing-terminal failure state;
  - attach/session/backend metadata copied from the handle or options.
- Terminal semantics:
  - missing `:exec_finished` produces a synthetic `:fail` terminal with
    `reason: :missing_exec_finished`;
  - backend failure terminals override earlier success terminals;
  - repeated success terminals keep the first success as the effective terminal
    while preserving the raw last terminal for inspection.
- Validation:
  - `cd packages/runic_sandbox && mix format
    lib/runic_sandbox/sandbox/attach_bridge.ex test/runic_sandbox_test.exs`
    completed.
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs`
    passed: `46 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix test` passed:
    `46 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix runic_sandbox.doctor --format json`
    reported Docker, Vmsan, and Sprites available; Fly remote remained
    unavailable because app and machine id provider config were not supplied.
  - Live Docker bridge smoke passed with summary `status: :pass`,
    `stdout: "docker-bridge"`, `terminal_count: 1`,
    `missing_terminal?: false`, `attach_mode: :live_stream`,
    `streaming_live?: true`, and `stdin_supported?: true`.
  - Live Vmsan bridge smoke passed with summary `status: :pass`,
    `stdout: "vmsan-bridge\n"`, `terminal_count: 1`,
    `missing_terminal?: false`, `attach_mode: :terminal_adapter`,
    `streaming_live?: false`, and `stdin_supported?: false`.
  - `/home/doops/bin/runic-vmsan list --json` reported `count: 0` after
    cleanup.

Next slice: build the generated-component proof runner on top of the attach
readiness metadata and `AttachBridge` summary shape, starting with terminal
adapter support before requiring live stdin.

### Slice 3 Notes

Slice 3 should add the first RunicAI consumer on top of the substrate rather
than expanding sandbox backends. It should keep generated code untrusted and
materialize source/test files only through sandbox request files or session
files. The initial runner should support terminal adapters because JustBash,
Vmsan, Sprites, and Fly all expose terminal attach today.

Required proof-runner semantics:

- accept a `GeneratedComponent` contract plus proposed source/test files;
- derive or accept a verification command without asking for host writes;
- open a `RunicSandbox` session and require attach support through
  `Capabilities.attach_mode/1`;
- call `RunicSandbox.attach/3` with sandbox-local files and summarize the handle
  through `RunicSandbox.AttachBridge`;
- update the component as `:verified` only when the attach summary passes;
- keep failed proofs as draft components with stdout/stderr/terminal evidence;
- record attach mode, live-vs-terminal behavior, backend, isolation, file
  artifacts, command, and cleanup status in the proof result.

Slice 3 implementation result:

- Added `RunicAI.Sandbox.GeneratedComponentProof.run/2`.
- The proof runner:
  - accepts a `GeneratedComponent` plus source/test file specs;
  - derives a verification command from `verification.commands` or accepts
    `:test_command`;
  - opens a `RunicSandbox` session and fails closed if attach is unsupported;
  - materializes generated source/test files through sandbox request files;
  - executes verification through `RunicSandbox.attach/3`;
  - summarizes attach events with `RunicSandbox.AttachBridge`;
  - marks the component `:verified` only on a passing attach summary;
  - keeps failed components in `:draft` with terminal evidence;
  - records source/test artifact summaries, attach mode, backend, isolation,
    live-vs-terminal metadata, and cleanup status.
- Default cwd behavior now reflects observed backend semantics:
  - JustBash uses `"."` so relative request files resolve in the virtual shell.
  - Container and VM backends use `"/workspace"`.
- Validation:
  - `mix format lib/runic_ai/sandbox/generated_component_proof.ex
    test/runic_ai/sandbox/generated_component_proof_test.exs
    .docs/053-runic-sandbox-consumer-driven-improvement-plan.md` completed.
  - `mix test test/runic_ai/sandbox/generated_component_proof_test.exs`
    passed: `4 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox` passed: `35 tests, 0 failures`.
  - `mix test` passed: `931 tests, 0 failures, 2 skipped`.
  - Live Docker proof smoke passed with `status: :verified`,
    `component_status: :verified`, `attach_status: :pass`,
    `stdout: "proof-ok\n"`, `attach_mode: :live_stream`,
    `streaming_live?: true`, and cleanup
    `%{attach_closed?: true, session_closed?: true}`.
  - Live Vmsan proof smoke passed with `status: :verified`,
    `component_status: :verified`, `attach_status: :pass`,
    `stdout: "proof-ok\n"`, `attach_mode: :terminal_adapter`,
    `streaming_live?: false`, and cleanup
    `%{attach_closed?: true, session_closed?: true}`.
  - `/home/doops/bin/runic-vmsan list --json` reported `count: 0` after
    cleanup.

Next slice: make the restricted-network contract explicit and fail-closed so
generated-component proofing and Ariston CLI containment can require scoped
egress without silent deny-all or broad-network fallback.

### Slice 4 Notes

Slice 4 should not attempt a full egress proxy implementation. The first useful
move is to make restricted policy intent explicit and impossible to silently
misinterpret.

Required restricted-network semantics:

- `Policy.network == :restricted` with no allow-list means deny-all restricted
  networking and remains valid for local backends.
- `Policy.network == :restricted` with `metadata.egress_allowlist` means scoped
  egress intent and must be normalized into a stable shape.
- Allow-list entries must validate `scheme`, `host`, `port`, and optional
  `purpose` without atomizing arbitrary user strings.
- Backends that cannot enforce scoped egress must return an explicit unsupported
  policy error before execution or attach.
- Health/session capability metadata must let consumers distinguish
  `network_policy?: true` from `restricted_egress_supported?: true`.
- Docker/Vmsan may continue supporting deny-all restricted mode, but must not
  treat allow-list restricted mode as equivalent to `--network none`.

Slice 4 implementation result:

- Added restricted-network helpers to `RunicSandbox.Policy`:
  - `egress_allowlist/1`
  - `restricted_egress_requested?/1`
  - `deny_by_default?/1`
  - `effective_network/1`
- `Policy.new/1` now normalizes restricted metadata:
  - `metadata.egress_allowlist` is a stable list of maps with string `scheme`,
    string `host`, integer `port`, and optional string `purpose`;
  - `purpose: :mcp` normalizes to `"mcp"` without atomizing arbitrary user
    input;
  - restricted policies default to `deny_by_default?: true`;
  - restricted deny-all policies normalize to an empty allow-list;
  - non-restricted policies reject non-empty allow-lists.
- `RunicSandbox.authorize_request/2` and direct `open_session/3` now fail
  closed when a profile requests scoped restricted egress and the selected
  backend cannot enforce it.
- Session request authorization also rejects scoped restricted egress if a
  session handle carries such a policy without matching support.
- Docker and Vmsan remain explicit deny-all adapters for
  `network: :restricted` without an allow-list; their capability metadata still
  reports `restricted_egress_supported?: false`.
- Validation:
  - `mix format packages/runic_sandbox/lib/runic_sandbox/sandbox/policy.ex
    packages/runic_sandbox/lib/runic_sandbox.ex
    packages/runic_sandbox/test/runic_sandbox_test.exs` completed.
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs`
    passed: `47 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix test` passed:
    `47 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox/generated_component_proof_test.exs`
    passed: `4 tests, 0 failures`.
  - Live Docker deny-all restricted smoke passed with `status: :pass`,
    `stdout: "docker-restricted-deny-all"`, `attach_mode: :live_stream`,
    `restricted_egress_supported?: false`, and effective policy
    `%{mode: :restricted, deny_by_default?: true, egress_allowlist: [],
    restricted_egress?: false}`.
  - Live Docker scoped allow-list smoke failed closed before session open with
    `sandbox restricted egress allow-list is not supported by backend`,
    `backend: :docker`, and `restricted_egress_supported?: false`.
  - Live Vmsan deny-all restricted smoke passed with `status: :pass`,
    `stdout: "vmsan-restricted-deny-all\n"`,
    `attach_mode: :terminal_adapter`,
    `restricted_egress_supported?: false`, and effective policy
    `%{mode: :restricted, deny_by_default?: true, egress_allowlist: [],
    restricted_egress?: false}`.
  - Live Vmsan scoped allow-list smoke failed closed before VM creation with
    `sandbox restricted egress allow-list is not supported by backend`,
    `backend: :vmsan`, and `restricted_egress_supported?: false`.
  - `/home/doops/bin/runic-vmsan list --json` reported `count: 0` after
    cleanup.

Next slice: add MCP boundary metadata so consumers can state whether MCP is
expected over a host forward, Unix socket, or restricted-egress allow-list, and
fail closed when the selected backend cannot provide that boundary.

### Slice 5 Notes

Slice 5 should define MCP boundary intent without choosing the final transport
implementation. Like restricted egress, the first useful behavior is explicit
metadata plus fail-closed readiness.

Required MCP-boundary semantics:

- `Policy.metadata.mcp_boundary` describes a requested MCP boundary.
- Supported boundary transports are `:host_forward`, `:unix_socket`, and
  `:egress_allowlist`, normalized without atomizing arbitrary user strings.
- `:host_forward` requires a host and port.
- `:unix_socket` requires a socket path.
- `:egress_allowlist` requires restricted networking with a non-empty egress
  allow-list.
- Backends that cannot provide the requested boundary must return an explicit
  unsupported policy error before execution or attach.
- Capability metadata remains the readiness surface:
  `mcp_boundary_supported?: false` is different from `network_policy?: true`.

Slice 5 implementation result:

- Added MCP boundary helpers to `RunicSandbox.Policy`:
  - `mcp_boundary/1`
  - `mcp_boundary_requested?/1`
- `Policy.new/1` now normalizes `metadata.mcp_boundary` and top-level
  `mcp_boundary`.
- Supported normalized boundary shapes:
  - `%{transport: "host_forward", host: "127.0.0.1", port: 4567}`
  - `%{transport: "unix_socket", path: "/tmp/runic-mcp.sock"}`
  - `%{transport: "egress_allowlist", purpose: "mcp"}`
- Validation:
  - `host_forward` requires host and port;
  - `unix_socket` requires path;
  - `egress_allowlist` requires `network: :restricted` plus a non-empty
    `egress_allowlist`;
  - atom inputs such as `transport: :host_forward` normalize through existing
    atoms only and arbitrary user strings are not atomized.
- `RunicSandbox.authorize_request/2`, direct `open_session/3`, and session
  request authorization now fail closed when an MCP boundary is requested but
  the selected backend/session does not report MCP boundary support.
- Current backend capability metadata still reports
  `mcp_boundary_supported?: false`; this slice makes that absence enforceable
  instead of advisory.
- Validation:
  - `mix format packages/runic_sandbox/lib/runic_sandbox/sandbox/policy.ex
    packages/runic_sandbox/lib/runic_sandbox.ex
    packages/runic_sandbox/test/runic_sandbox_test.exs` completed.
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs`
    passed: `48 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix test` passed:
    `48 tests, 0 failures`.
  - Live Docker MCP boundary smoke failed closed before session open with
    `sandbox MCP boundary is not supported by backend`, `backend: :docker`,
    and `mcp_boundary_supported?: false`.
  - Live Vmsan MCP boundary smoke failed closed before VM creation with
    `sandbox MCP boundary is not supported by backend`, `backend: :vmsan`,
    and `mcp_boundary_supported?: false`.
  - `/home/doops/bin/runic-vmsan list --json` reported `count: 0` after
    cleanup.

Next slice: represent active attach lifecycle in session management so pooled
or persistent sessions cannot be reused while an attach stream is still open.

### Slice 6 Notes

Slice 6 should make active attach ownership visible to the manager. Direct
session attach remains valid for unmanaged/local use, but sessions checked out
from a manager need a managed attach path so pooled sessions are not returned to
idle while an interactive process is still attached.

Required active-attach semantics:

- `RunicSandbox.attach/3` accepts `server: manager` and records the returned
  handle as active against the managed session.
- `RunicSandbox.close_attach/2` accepts `server: manager` and removes the active
  attach record after backend close.
- `release_session/2` and reset/checkin paths reject sessions with active
  attaches.
- `close_session/2` may clean up active attaches explicitly before closing the
  session.
- Manager status includes active attach metadata so leaks are diagnosable.
- Closing an already-removed managed attach is idempotent enough for cleanup
  paths.

Slice 6 implementation result:

- Added a managed attach path for `RunicSandbox.attach/3` with `server:
  manager`.
- Kept the backend attach open in the caller process, then registered the
  returned handle with the manager. This matters for Docker because Erlang port
  output is delivered to the process that opened the port; opening the port
  inside the manager caused live Docker output to arrive as unhandled GenServer
  messages.
- Added active attach tracking to manager session entries and exposed
  `active_attach_count` plus sanitized `active_attaches` in `RunicSandbox.status/1`.
- Added release/reset guards so managed sessions with active attaches are not
  returned to the pool or reset concurrently.
- Added managed stream finalization: when a returned handle's event stream
  terminates, the manager removes the active attach record and calls backend
  close. Explicit `close_attach/2` with `server: manager` remains idempotent.
- Added `close_session/2` cleanup for any still-active managed attaches before
  closing the session.
- Validation:
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs` passed:
    `50 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix test` passed:
    `50 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox/generated_component_proof_test.exs`
    passed: `4 tests, 0 failures`.
  - Live managed Docker attach smoke passed with:
    `active_before_stream: 1`,
    `blocked_release_message: "sandbox session has active attaches"`,
    `event_types: [:exec_started, :stdout_chunk, :exec_finished]`,
    `stdout: "managed-docker"`,
    `terminal_status: :pass`,
    `files_changed: ["attach.txt"]`,
    `active_after_stream: 0`,
    `release_result: :ok`,
    `lifecycle_after_release: :idle`,
    and `close_result: :ok`.

Next slice: promote provider-native live streaming only where the backend can
actually support live attach/stdin semantics. Keep terminal adapters explicit
for Sprites, Remote/Fly, Vmsan, JustBash, and Lua until a provider-native stream
transport is proven.

### Slice 7 Notes

Slice 7 should not upgrade a provider to `:live_stream` based on an HTTP or CLI
terminal result adapter. It should first certify the current provider-backed
behavior under real credentials, then record the exact evidence needed before a
backend may claim live streaming.

Required provider-certification semantics:

- Remote/Fly attach through `fly machine exec --json` remains
  `attach_mode: :terminal_adapter`, `streaming_live?: false`,
  `stdin_supported?: false`, and `provider_transport: :fly_machine_exec`.
- Sprites HTTP exec attach remains `attach_mode: :terminal_adapter`,
  `streaming_live?: false`, `stdin_supported?: false`, and
  `provider_transport: :sprites_http_exec`.
- `write_stdin/3` on terminal adapters fails with the shared terminal-adapter
  error after execution.
- A provider can move to `attach_mode: :live_stream` only when a native
  transport yields chunks while the process is running and accepts stdin while
  the process is active.
- The smoke matrix should record which real providers were available, skipped,
  or failed, without leaking credentials.

Slice 7 implementation result:

- Certified live Remote/Fly attach against the existing `libbit` Fly Machine:
  - health reported available;
  - `attach_mode: :terminal_adapter`;
  - `streaming_live?: false`;
  - `stdin_supported?: false`;
  - `provider_transport: :fly_machine_exec`;
  - attach summary passed with `stdout: "remote-fly-ok"`;
  - `write_stdin/3` returned
    `terminal attach result does not accept stdin after execution`.
- Certified live Sprites attach with an ephemeral sprite and request files:
  - health reported available;
  - session/capability default cwd reported `"/home/sprite"`;
  - `attach_mode: :terminal_adapter`;
  - `streaming_live?: false`;
  - `stdin_supported?: false`;
  - `provider_transport: :sprites_http_exec`;
  - attach summary passed with `stdout: "sprites-cert"`;
  - `write_stdin/3` returned
    `terminal attach result does not accept stdin after execution`;
  - session cleanup returned `:ok`.
- Live Sprites dogfood found and fixed three provider-portability issues:
  - Sprites sessions now advertise `default_cwd: "/home/sprite"` in session
    metadata and capability metadata.
  - `RunicSandbox` session request normalization now applies a session default
    cwd only when callers omit `cwd`/`sandbox_cwd`, so higher-level consumers do
    not need backend-name conditionals for provider work directories.
  - Sprites request-file materialization now validates relative request files
    against the effective cwd but sends relative `path` plus `workingDir` to the
    provider API.
  - Sprites `fs/write` now sends raw file bytes as
    `application/octet-stream`, matching the [Sprites filesystem API](https://sprites.dev/api/sprites/filesystem).
  - Sprites binary exec output now decodes multiple stdout/stderr frames before
    the terminal exit frame instead of leaking raw stream marker bytes into
    stdout.
- RunicAI's generated-component proof runner now consumes session/capability
  default cwd metadata before falling back to `"/workspace"`.
- Validation:
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs` passed:
    `51 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix test` passed:
    `51 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox/generated_component_proof_test.exs`
    passed: `5 tests, 0 failures`.

Next slice: connect the generated-component proof runner to RunicAI's
iterative generation/promotion flow so sandbox proof evidence becomes the
promotion gate rather than a standalone utility.

### Slice 8 Notes

Slice 8 should stay above `packages/runic_sandbox`. The sandbox package has
already provided proof execution, attach summaries, and backend truth. RunicAI
now needs a coordinator-facing seam that turns a generated component proposal
into either:

- a verified/promoted generated component plus a composed workflow; or
- a rejected/repairable proposal with sandbox proof evidence.

Required promotion-flow semantics:

- Accept a draft `GeneratedComponent` plus source/test files and proof options.
- Run `GeneratedComponentProof.run/2` before any workflow composition.
- Evaluate `GeneratedComponentPromotionPolicy` against the proof-updated
  component.
- Compose `GeneratedComponentWorkflow` only when the proof passed and the
  promotion decision allows use without pending review.
- Preserve failed proof evidence, promotion decision details, and a repair
  context in the result.
- Emit neutral event maps for trace/read-model consumers, including proposal,
  proof, promotion decision, and workflow composition outcomes.
- Expose a coordinator option path so callers can request proof-backed
  generated-component composition without bypassing the sandbox proof gate.

Slice 8 implementation result:

- Added `RunicAI.Sandbox.GeneratedComponentPromotionFlow.run/2`, a
  proof-first orchestration seam above `packages/runic_sandbox`.
- The flow now:
  - accepts draft generated components plus source/test files;
  - runs `GeneratedComponentProof.run/2` before any workflow composition;
  - evaluates `GeneratedComponentPromotionPolicy`;
  - composes `GeneratedComponentWorkflow` only when proof passed and promotion
    does not require pending review;
  - returns failed proof evidence as `repair_context`;
  - emits neutral event maps for proposal, proof, promotion decision, and flow
    completion.
- `RunicAI.Assistant.RLM.Coordinator.propose/3` now accepts
  `generated_component_proposal:` as the proof-gated option path. The existing
  `generated_component:` / `generated_components:` paths remain composition-only
  for already-verified components.
- Validation:
  - `mix test test/runic_ai/sandbox/generated_component_promotion_flow_test.exs`
    passed: `4 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox` passed:
    `40 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
    passed: `61 tests, 0 failures`.
  - Live Docker promotion-flow smoke passed with `status: :ready`,
    `component_status: :verified`, `proof_status: :verified`,
    `attach_status: :pass`, `stdout: "docker-flow-ok"`,
    `attach_mode: :live_stream`, `streaming_live?: true`, workflow composition,
    proof event maps, and cleanup
    `%{attach_closed?: true, session_closed?: true}`.
  - Live Sprites promotion-flow smoke passed with `status: :ready`,
    `component_status: :verified`, `proof_status: :verified`,
    `attach_status: :pass`, `stdout: "sprites-flow-ok"`,
    `attach_mode: :terminal_adapter`, `streaming_live?: false`, workflow
    composition, proof event maps, and cleanup
    `%{attach_closed?: true, session_closed?: true}`.

Next slice: perform a completion audit across the full slice ledger, reconcile
any stale docs, and run the broad validation matrix before deciding whether the
active goal is complete.

### Slice 9 Notes

Slice 9 is the completion audit for the active goal. It should not introduce a
new feature unless the audit finds a small correctness gap that blocks the
original objective.

Audit checklist:

- [x] The plan document is concrete enough to drive implementation: every delivered
  slice has scope, deliverables, acceptance criteria, validation commands or
  smoke paths, results, and next-step decisions.
- [x] `packages/runic_sandbox` remains the provider/backend boundary for Docker,
  Vmsan, Remote/Fly, Sprites, JustBash, and Lua behavior.
- [x] Attach readiness is machine-readable through capability helpers and backend
  metadata.
- [x] Terminal adapters and live streams are distinguishable; no provider-backed
  terminal adapter is promoted to live streaming without native evidence.
- [x] Shared attach event bridge semantics cover ordered chunks, terminal
  reconciliation, missing terminal, failure precedence, counts, and metadata.
- [x] Restricted-network scoped-egress intent is explicit, validated, and fails
  closed when unsupported.
- [x] MCP boundary intent is explicit, validated, and fails closed when unsupported.
- [x] Managed active attach lifecycle prevents pooled session reuse until stream
  termination or explicit cleanup.
- [x] RunicAI generated-component proof and promotion flow consumes the substrate
  without duplicating backend-specific provider logic.
- [x] Current tests, live smokes, and resource cleanup checks prove the above.

Slice 9 implementation result:

- Reconciled the plan's known-limitations language with the current state:
  RunicAI now has a proof-first generated-component promotion flow; durable
  proof persistence remains future hardening.
- Hardened the coordinator promotion seam so nested `proof_opts` and
  `workflow_opts` are forwarded into `GeneratedComponentPromotionFlow.run/2`.
  This lets callers use the promotion flow without flattening proof and
  workflow options into the top-level coordinator option list.
- Full-suite validation exposed a real authority-initialization race:
  concurrent first-time sandbox session opens could initialize
  `RunicSandbox`'s session-authority secret more than once, invalidating an
  already-sealed handle under async tests or concurrent callers.
- Fixed the authority race by serializing first secret creation behind a local
  global lock and added a concurrent-open regression test in the
  `runic_sandbox` package.
- Validation:
  - `mix format --check-formatted` passed.
  - `cd packages/runic_sandbox && mix format --check-formatted` passed.
  - `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs`
    passed: `52 tests, 0 failures`.
  - `cd packages/runic_sandbox && mix test` passed:
    `52 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox/generated_component_promotion_flow_test.exs`
    passed: `4 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox` passed:
    `40 tests, 0 failures`.
  - `mix test test/runic_ai/sandbox test/runic_ai/assistant/rlm_blueprint_test.exs`
    passed: `61 tests, 0 failures`.
  - `mix test --seed 112628` passed:
    `936 tests, 0 failures, 2 skipped`. This is the seed that previously
    reproduced the session-authority race.
  - `mix compile` passed.
  - `git diff --check` passed.
  - `cd packages/runic_sandbox && mix runic_sandbox.doctor --format json`
    reported Docker, Vmsan, Sprites, JustBash, and Lua available on this host;
    Remote/Fly was unavailable in the generic doctor profile because the app
    and machine id were not supplied, while the earlier Slice 7 Fly smoke used
    explicit provider config and passed.
  - `docker ps --filter 'name=runic-sandbox-attach-' --format '{{.Names}}'`
    returned no containers.
  - `/home/doops/bin/runic-vmsan list --json` returned `count: 0`.

Completion decision: the active goal is complete. The remaining items in
Improvement Themes are future backend upgrades, not blockers for the current
streaming/attach model: real scoped-egress enforcement, a selected MCP
transport, provider-native live streams for Remote/Sprites, and durable proof
persistence/workbench presentation.

## Improvement Themes

### 1. Make Restricted Networking Real

Goal: `Policy.network == :restricted` should mean scoped egress, not "same as
disabled".

Proposed policy metadata:

```elixir
%RunicSandbox.Policy{
  network: :restricted,
  metadata: %{
    egress_allowlist: [
      %{scheme: "http", host: "127.0.0.1", port: 4567, purpose: :mcp},
      %{scheme: "https", host: "api.anthropic.com", port: 443, purpose: :model}
    ],
    deny_by_default?: true
  }
}
```

Initial delivery should be conservative:

- validate and normalize allow-list entries in `Policy`;
- expose effective network policy in health/session metadata;
- make Docker either enforce the allow-list or return an explicit unsupported
  error when `:restricted` includes allow-list metadata it cannot honor;
- keep `:disabled` and `:host` behavior unchanged;
- add tests proving that `:restricted` no longer silently degrades to
  `--network none` when allow-list entries are requested.

Backend-specific path:

- Docker: first implement an explicit unsupported/readiness failure for
  allow-list metadata, then add a real implementation through a generated
  network namespace/proxy sidecar or host-bound forwarder.
- Vmsan: map policy metadata to `vmsan` network options once the host is
  healthy enough for live smoke tests.
- Remote/Sprites: treat provider-managed network as policy metadata plus
  provider readiness, not as local enforcement.

Acceptance criteria:

- health/readiness can distinguish `restricted_supported?: true` from
  `network_policy?: true`;
- `:restricted` with no allow-list remains valid for deny-all profiles;
- `:restricted` with allow-list never silently permits broad egress;
- `:restricted` with allow-list never silently collapses to deny-all for a
  consumer that explicitly requested scoped egress.

### 2. Promote Attach Readiness Above A Boolean

Goal: consumers should be able to ask for the exact attach shape they require.

`Capabilities.streaming?` is too coarse for Ariston and for RunicAI promotion
proofs. Add capability metadata or helper predicates for:

- `attach_supported?`
- `streaming_live?`
- `stdin_supported?`
- `stderr_separate?`
- `terminal_result_adapter?`
- `mcp_boundary_supported?`
- `restricted_egress_supported?`

The struct can remain stable if these start under `Capabilities.metadata`, but
RunicAI should expose typed helper functions so consumers do not match raw
maps.

Example:

```elixir
RunicSandbox.Capabilities.attach_mode(capabilities)
#=> :none | :terminal_adapter | :live_stream
```

Acceptance criteria:

- Ariston-style readiness can require `:live_stream` and fail closed before
  opening the CLI path.
- RunicAI generated-component proofs can accept `:terminal_adapter` for early
  compile/test proofs and upgrade to `:live_stream` when needed.
- backend health reports include both advertised and effective attach mode.

### 3. Standardize Event Bridge Semantics

Goal: `SessionEvent` streams should be easy to consume without each app
rewriting terminal reconciliation.

Add a small bridge module in `runic_sandbox` or `runic_ai` that can:

- consume `AttachHandle.events(handle)`;
- preserve ordered stdout/stderr chunks;
- reconstruct line-delimited JSON when requested;
- enforce at most one success terminal event;
- allow backend failure to override an earlier CLI success;
- synthesize a failure if the stream ends without `:exec_finished`;
- include byte counts, chunk counts, duration, backend, session, attach id, and
  live-vs-terminal metadata.

This is directly informed by Ariston PR #790, where duplicate terminal events,
readiness gating, session cleanup, and backend-failure precedence all became
real review issues.

Acceptance criteria:

- RunicAI can consume sandbox attach output through one module for terminal
  events, trace events, and generated-component proof logs.
- tests cover success, failure, success-then-backend-failure, missing terminal,
  stdout/stderr chunk ordering, and stream cleanup.
- Ariston can either keep its bridge or converge on the shared semantics without
  losing its provider-specific NDJSON reconstruction.

### 4. Separate Terminal Adapters From Live Streams

Goal: terminal adapters should remain useful, but they must not be confused
with interactive hosting.

Keep terminal adapters for:

- generated component compile/test proof;
- one-shot smoke tests;
- provider backends that only expose final command output;
- CI environments where Docker/Firecracker live attach is unavailable.

Require live streams for:

- contained provider CLI turns;
- stdin-driven protocols;
- MCP-over-stdio or MCP-over-boundary workflows;
- interactive REPL sessions.

Acceptance criteria:

- `RunicSandbox.attach/3` handle metadata always includes `streaming_live?`;
- health/readiness can request terminal or live attach explicitly;
- docs and test names use "terminal attach adapter" for adapted one-shot
  backends;
- no consumer treats `Capabilities.streaming?` alone as proof of interactive
  containment.

### 5. Add MCP-Over-Boundary As A Contract

Goal: define MCP reachability independently from whichever backend implements
it first.

Candidate contract:

```elixir
%{
  mcp_boundary: %{
    mode: :egress_allowlist | :host_forward | :unix_socket | :unsupported,
    endpoint: "http://127.0.0.1:4567/mcp",
    allowlist_ref: "mcp",
    auth: :inherited_subscription,
    metadata: %{}
  }
}
```

Delivery order:

1. Add profile/policy metadata and validation for MCP boundary intent.
2. Expose MCP boundary support in backend health.
3. Implement the simplest local Docker route:
   - host-bound MCP HTTP endpoint plus restricted egress/forwarder; or
   - mounted unix socket if that is easier to enforce locally.
4. Keep provider CLI images out of the core contract. Images are consumers of
   this contract, not the contract itself.

Acceptance criteria:

- a consumer can fail closed when MCP boundary support is absent;
- policy describes what endpoint the sandbox can reach and why;
- unrelated network remains denied for restricted profiles;
- the same metadata can describe Ariston's MCP endpoint and RunicAI's local
  generated-component proof services.

### 6. Represent Active Attach Lifecycle

Goal: pooled sessions should know when an attached process owns the session.

Add lifecycle state for active attachments:

- attach started;
- attach active;
- stdin closed;
- attach closing;
- attach finished;
- attach errored/cancelled.

This can start as manager/session metadata before becoming a larger state
machine change.

Acceptance criteria:

- a pooled session with an active attach is not leased to another execution;
- `close_attach/2` and session close are idempotent;
- event stream termination closes backend resources;
- leaked attach handles appear in diagnostics or health reports.

### 7. Make Backend-Specific Improvements Incremental

Backend priorities:

| Backend | Near-term improvement | Consumer benefit |
| --- | --- | --- |
| Docker | restricted-network behavior, stderr demux if possible, live attach cleanup, image contract docs | Ariston CLI containment, RunicAI local proof loop |
| Vmsan | host setup validation, network metadata mapping, live attach smoke once Firecracker assets exist | stronger isolation for promoted component proof |
| Remote/Fly | keep terminal adapter honest; investigate provider-native streaming/control channel | realistic remote proof and remote agent containment |
| Sprites | promote WebSocket exec, if available, from terminal adapter to live stream | browser/remote sandbox early adopter path |
| JustBash/Lua | remain fast terminal adapters with explicit non-live metadata | deterministic tests and CI fallback |

## RunicAI Integration Plan

RunicAI should consume these substrate improvements through a generated
component promotion flow rather than waiting for full agent CLI containment.

Phase A: proof runner

- add a generated-component proof runner that opens a sandbox session, writes
  generated files or inline code, runs compile/test commands, and records a
  proof artifact;
- allow `attach_mode: :terminal_adapter` for compile/test proof;
- require `network: :disabled` by default;
- require explicit `network: :restricted` plus allow-list metadata for any
  dependency/model/MCP access.

Phase B: event bridge

- add a RunicAI bridge from `RunicSandbox.SessionEvent` to existing terminal
  and trace event surfaces;
- preserve backend/session/attach ids in event metadata;
- include proof summaries in generated-component promotion decisions.

Phase C: promotion ratchet

- model component state as:

```text
draft -> sandbox_proven -> review_approved -> catalog_available
```

- store contract, generated source, sandbox proof, test command, artifacts, and
  promotion metadata together;
- prevent generated code from becoming a normal component until the proof and
  review gates pass.

Phase D: interactive containment

- only require `attach_mode: :live_stream`, stdin support, and MCP boundary
  support when the component proof loop needs an interactive REPL or contained
  agent CLI;
- use the same substrate that Ariston needs for CLI-in-sandbox containment.

## Delivery Order

1. **Capability/readiness tightening.**
   Add attach-mode helpers and effective health metadata. This is small,
   testable, and protects consumers from over-reading `streaming?`.
2. **Shared event bridge semantics.**
   Implement terminal reconciliation once and use it in RunicAI proof logs.
3. **RunicAI generated-component proof runner.**
   Use terminal adapters first so the promotion flow can be dog-fooded before
   MCP is solved.
4. **Restricted networking contract.**
   Add policy metadata, validation, readiness behavior, and explicit unsupported
   errors before attempting backend-specific enforcement.
5. **Docker restricted egress / MCP boundary first cut.**
   Implement one local route that can satisfy Ariston's contained CLI and
   RunicAI's future interactive REPL.
6. **Backend promotion.**
   Upgrade Sprites/Remote/Vmsan from terminal adapters to live streams only when
   provider-native control channels are available and tested.

## Validation Matrix

| Slice | Unit tests | Local smoke | Consumer smoke |
| --- | --- | --- | --- |
| attach-mode helpers | capability normalization and predicates | `mix runic_sandbox.doctor` metadata | RunicAI readiness output |
| event bridge | chunk/terminal/failure cases | Docker attach emits bridged terminal events | generated-component proof log |
| proof runner | fake backend and terminal adapters | JustBash/Lua/Docker compile-test proof | dynamic component promotion dry run |
| restricted policy | metadata validation and unsupported cases | Docker deny-all and allow-list checks | MCP endpoint reachable, unrelated egress denied |
| MCP boundary | profile metadata and readiness | local endpoint round trip from container | Ariston-style CLI bridge smoke |
| live backend upgrades | backend-specific attach tests | provider-native stream smoke | stdin/long-lived process smoke |

## Open Decisions

- Should allow-list entries live directly in `Policy.metadata`, or should
  `Policy` grow typed fields such as `egress_allowlist`?
- Should the shared event bridge live in `runic_sandbox` as consumer-neutral
  utilities, or in `runic_ai` as the first concrete consumer?
- Should `Capabilities.streaming?` remain broad, or should it be deprecated in
  favor of explicit `attach_mode`?
- Should the first MCP boundary use host HTTP forwarding or a unix socket bind?
- Should generated-component proof artifacts become part of the RunicAI durable
  run database immediately, or start as trace artifacts and graduate later?

## Non-Goals

- Do not make generated code host-executable as a shortcut.
- Do not make `:restricted` mean broad network with best-effort filtering.
- Do not require full provider CLI containment before RunicAI can prove
  generated leaf components.
- Do not duplicate backend-specific Docker/Vmsan/Sprites logic in RunicAI.
- Do not require Ariston to adopt RunicAI's component promotion model; the
  shared contract is `runic_sandbox`, not RunicAI internals.
