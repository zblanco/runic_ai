# Long-Lived Multi-Agent Session Sandbox Plan

Status: in progress

Date: 2026-05-31

Goal feature objective: `long lived multi agent session sandbox use cases`

## Purpose

RunicAI and Ariston both need a sandbox substrate that can host more than a
single bounded command. The target shape is a reusable Linux environment that can
stay warm, host multiple language runtimes and CLI tools, run long-lived
processes, stream process output, accept stdin, expose private host boundaries
for MCP/model traffic, and support multiple agent connections without putting
model credentials or broad internet access inside the sandbox.

The near-term trigger is Ariston's feedback:

- Docker restricted egress for MCP is the right transport.
- A second `host.docker.internal:<port>` allow-list entry is needed for a
  host-side model proxy with `purpose: :model`.
- No external hosts or broad HTTPS should be allowed from the container.
- Claude and Codex can use plain HTTP to `host.docker.internal`; Gemini may
  later require TLS or loopback-compatible presentation.
- Interactive long-lived process hosting and an agent-CLI image remain the gates
  for a full interactive turn.

The broader RunicAI target is the same substrate for dynamic workflow agents:
keep a dev sandbox warm for iterative generation/promotion work, keep an
execution sandbox for workflow proof/runs, and eventually let Runic promise
scheduling execute many runnable steps inside one sandbox VM/container without
paying a host I/O round-trip between every intermediate runnable.

## Reference Inputs

Local plans and current implementation:

- `.docs/052-runic-sandbox-streaming-and-mcp-dogfood-plan.md`
- `.docs/053-runic-sandbox-consumer-driven-improvement-plan.md`
- `.docs/054-runic-ai-generated-component-promotion-plan.md`
- `.docs/055-tensorlake-sandbox-reference-takeaways.md`
- `packages/runic_sandbox/lib/runic_sandbox.ex`
- `packages/runic_sandbox/lib/runic_sandbox/sandbox/manager.ex`
- `packages/runic_sandbox/lib/runic_sandbox/sandbox/backends/docker.ex`
- `packages/runic_sandbox/lib/runic_sandbox/sandbox/backends/vmsan.ex`
- `lib/runic_ai/coding/sandbox_session_registry.ex`
- `lib/runic_ai/coding/process_registry.ex`

External references reviewed for this plan:

- [Runic Execution Strategies](https://hexdocs.pm/runic/execution-strategies.html):
  promises group runnables into sequential or parallel dispatch units; a
  sequential promise executes a chain in one task with local workflow state
  updates, and a parallel promise groups independent runnables into one dispatch
  slot.
- [Tensorlake Sandbox Lifecycle](https://docs.tensorlake.ai/sandboxes/lifecycle):
  distinguishes pending/running/snapshotting/suspending/suspended states,
  named resumable sandboxes, and reusable snapshots.
- [Tensorlake PTY Sessions](https://docs.tensorlake.ai/sandboxes/pty-sessions):
  keeps PTY sessions separate from command execution and includes create, attach,
  input, resize, reconnect, and kill semantics.
- [Modal warm sandbox pool example](https://modal.com/docs/examples/sandbox_pool):
  uses a queue of healthy warm sandboxes to reduce setup latency when sandboxes
  need dependency downloads, code checkout, tests, or service warm-up before use.
- [Modal sandbox command execution](https://frontend.modal.com/docs/guide/sandbox-spawn):
  returns process handles with stdout, stderr, stdin, wait, and streaming output.
- [Modal sandbox snapshots](https://modal.com/docs/guide/sandbox-snapshots):
  separates filesystem snapshots from memory snapshots and calls out important
  process/TCP limitations.
- [Modal sandbox files](https://modal.com/docs/guide/sandbox-files):
  shows volume-backed persistence and explicit sync patterns for long-running
  sandboxes.
- [E2B process list API](https://e2b.dev/docs/api-reference/process/list):
  treats process management as an authenticated API against a running sandbox.

## Current Baseline

Implemented today:

- `RunicSandbox.Manager` supports configured profiles, warm session pool count,
  max pool size, acquire/release, close/reset, idle reaping, owner monitoring,
  leases, active attach tracking, and status reporting.
- `RunicSandbox.Backend` already has future-facing callbacks for sessions,
  attach/stdin, files, checkpoints, services, proxies, and leases.
- `RunicSandbox.Session` can report `:one_shot`, `:persistent_workspace`,
  `:checkpointable`, or `:service_actor` state models.
- Docker can open a persistent workspace session, attach to a live `docker run
  -i` command, write stdin to that command, enforce narrow restricted egress for
  `host.docker.internal:<port>` MCP/model entries, and clean up per-execution
  egress sidecars/networks.
- Vmsan can open a real VM-backed session, execute commands against the same VM
  id, prepare `/workspace`, and checkpoint/restore via vmsan snapshots.
- RunicAI has `SandboxSessionRegistry` to keep signed session handles out of
  model-visible state and expose opaque ids to tools.
- RunicAI has a host-local `ProcessRegistry`, but it is not sandbox-backed.

Known gaps:

- Docker sessions are not long-lived container hosts yet. The session preserves a
  host workspace, but each `exec_session` and `attach_session` starts a fresh
  `docker run --rm`.
- Docker, Vmsan, Sprites, and Remote/Fly do not expose a shared process lifecycle
  API: start/list/follow/write stdin/close stdin/signal/kill/wait.
- Vmsan, Sprites, and Remote/Fly are currently terminal attach adapters rather
  than live stdin-capable streams.
- `services?` and `proxy?` are scaffolded in the backend contract but not real
  for Docker/Vmsan yet.
- The sandbox image is a generic runtime image, not an agent-CLI image with
  Claude/Codex/Gemini entrypoints, baked instructions, and host-only model/MCP
  boundary defaults.
- Runic promise scheduling is not yet connected to sandbox affinity, so batched
  runnables cannot be guaranteed to execute inside one warmed sandbox without
  host round-trips.

## Design Principles

- Treat long-lived sandboxes as a capability tier, not a universal promise. It
  does not make sense for `:just_bash` or `:lua` to pretend they are stateful
  Linux hosts.
- Keep `runic_sandbox` backend-neutral. The package should define lifecycle,
  process, PTY, service, file, checkpoint, and network contracts; individual
  backends provide honest capability maps.
- Separate persistent workspace from persistent process host. A backend can
  preserve files without preserving PID namespaces, running services, open stdin,
  or TCP state.
- Split process streams and PTY sessions. Process APIs preserve stdout/stderr
  and structured terminal status. PTY APIs collapse streams and add terminal
  dimensions, resize, reconnect, and raw terminal bytes.
- Keep network policy narrow and explicit. MCP and model traffic should use
  host-only allow-list entries. Model credentials stay on the host model proxy.
- Prefer warm pools and snapshots for latency, but surface TTL, idle timeout,
  cleanup, and snapshot limitations honestly.
- Make dev and execution sandbox roles explicit. Iterative generation/promotion
  work should not accidentally share mutable state with deterministic workflow
  execution unless the caller asks for that.
- Preserve future Runic promise execution. The design must allow a sequential or
  parallel promise to run inside one sandbox allocation without changing the
  scheduler contract later.

## Capability Tiers

| Tier | Meaning | Expected backends |
| --- | --- | --- |
| `:one_shot_exec` | Runs bounded commands only; no durable sandbox identity. | `:just_bash`, `:lua` |
| `:persistent_workspace` | Session identity and files persist, but processes are per command. | Current Docker session shape |
| `:persistent_process_host` | A real VM/container/machine stays running and can host multiple processes. | Target Docker, Vmsan, Sprites, Remote/Fly |
| `:live_process_stream` | Process handles stream output while running and accept stdin where supported. | Target Docker first, then provider-native backends |
| `:pty_host` | Interactive terminal sessions with resize/disconnect/reconnect. | Optional later tier |
| `:snapshot_resumable` | Checkpoints can restore filesystem and possibly process/memory state. | Vmsan/Sprites/Fly where provider supports it; Docker filesystem checkpoint initially |

Each backend must report both the tier and the concrete operations it supports.
Consumers should gate behavior on operations, not on backend names.

## RALPH/OODA Delivery Loop

Use the `/goal` objective as the outer loop and run every slice through the same
iteration:

### Observe

Collect the current backend capability map, live smoke evidence, consumer
feedback, latency numbers, resource leaks, failing tests, and any mismatch
between advertised capability and behavior.

### Orient

Classify the backend and use case:

- one-shot command, persistent workspace, process host, PTY host, or snapshot
  restore;
- dev sandbox, execution sandbox, or provider CLI sandbox;
- trusted host process, untrusted generated code, or contained agent CLI;
- no network, restricted MCP/model boundary, private service proxy, or explicit
  host network;
- sequential promise, parallel promise, long-running service, or human/agent
  terminal session.

### Decide

Choose the smallest next move:

- unblock a consumer with a narrow compatibility patch;
- add contract shape without changing backend behavior;
- implement one backend fully before generalizing;
- expose a capability as unsupported rather than emulating it incorrectly;
- defer PTY/snapshot/memory semantics until process hosting is solid.

### Act

Land a focused slice with tests, update this checklist, run package-local
validation, run live backend smokes where available, and record any capability
truth changes in docs and health metadata.

RALPH mnemonic for this plan:

```text
Ready -> Allocate -> Launch -> Process -> Harvest
```

- Ready: backend health and capability truth are current.
- Allocate: acquire the right sandbox role from a warm pool.
- Launch: start or connect to the long-lived VM/container/machine.
- Process: run commands, services, CLI agents, process streams, or PTYs.
- Harvest: collect artifacts, snapshots, logs, metrics, and cleanup evidence.

## Target Architecture

```text
RunicAI agent/workflow layer
  -> tool registry, OODA loop, generated component proof, run_context

Runic Runner
  -> schedulers, promises, dispatch policies, sandbox affinity metadata

runic_sandbox control plane
  -> manager, warm pools, sessions, process handles, PTY handles,
     services/proxies, checkpoints, policy/capability truth

backend adapters
  -> Docker/GVisor, Vmsan, Sprites, Fly Machines/Remote,
     limited adapters such as JustBash/Lua

sandbox image/runtime
  -> runtimes, agent CLIs, sidecar/process supervisor, MCP/model boundary config
```

The preferred implementation pattern for full Linux backends is a small
sandbox-resident control sidecar, even if each backend reaches it differently.
The sidecar should provide a stable in-sandbox process API:

- start command/process with argv, cwd, env, timeout, stdin mode, stdout/stderr
  modes, and optional PTY request;
- stream stdout/stderr or PTY frames;
- write stdin and close stdin;
- signal/kill/wait;
- list processes and inspect status;
- start/list/stop named services;
- report readiness and resource usage;
- expose a local-only management endpoint reachable only through the backend
  control channel, not public internet.

Docker can start with `docker exec` against a persistent container and graduate
to the sidecar. Vmsan/Sprites/Fly may need the sidecar earlier if provider exec
does not expose live stdin/stdout semantics.

## Sandbox Roles

Default roles when long-lived hosting is enabled:

- `:dev` sandbox:
  - optimized for iterative generation, dependency installation, repair loops,
    debugging, and component promotion;
  - warm pool default `warm: 1`, `max: configurable`;
  - can retain workspace state between turns;
  - can checkpoint before risky actions;
  - may run long-lived dev servers or agent CLI processes.
- `:execution` sandbox:
  - optimized for deterministic workflow execution/proof;
  - starts from a clean image or selected checkpoint;
  - can run Runic promise batches and workflow leaves;
  - should default to stricter reset/checkpoint policy than dev;
  - may share image/cache layers with dev but should not share mutable runtime
    state unless explicitly configured.

Suggested profile shape:

```elixir
[
  local_dev: [
    backend: :docker,
    role: :dev,
    stateful?: true,
    runtimes: [:bash, :python, :node, :elixir],
    network: :restricted,
    egress_allowlist: [
      %{scheme: "http", host: "host.docker.internal", port: 4000, purpose: :mcp},
      %{scheme: "http", host: "host.docker.internal", port: 4100, purpose: :model}
    ],
    pool: [warm: 1, max: 4, idle_ttl_ms: 300_000, reset_on_checkin?: false]
  ],
  workflow_execution: [
    backend: :docker,
    role: :execution,
    stateful?: true,
    runtimes: [:bash, :python, :node, :elixir],
    network: :restricted,
    egress_allowlist: [
      %{scheme: "http", host: "host.docker.internal", port: 4000, purpose: :mcp},
      %{scheme: "http", host: "host.docker.internal", port: 4100, purpose: :model}
    ],
    pool: [warm: 1, max: 8, reset_on_checkin?: true, checkpoint_on_checkout?: true]
  ]
]
```

## Runic Promise Compatibility

Runic's execution strategies already define the conceptual unit we need:
sequential and parallel promises group multiple runnables into one dispatch. This
plan should preserve a future `SandboxPromiseExecutor` or sandbox-aware scheduler
policy with these properties:

- a promise can request sandbox affinity, such as `{sandbox_role, sandbox_id}` or
  a profile name;
- all runnables in one sequential promise execute through one acquired sandbox
  session;
- intermediate outputs can remain inside sandbox-local files or sidecar memory
  when the workflow contract allows it;
- only boundary outputs, artifacts, telemetry, and final runnable results cross
  back to the host;
- parallel promises can run independent runnables inside one sandbox process pool
  when resource policy allows it, or fan out across a pool when isolation is more
  important than I/O savings;
- failure semantics stay aligned with Runic promises: sequential promises can
  partially commit earlier successful runnables, while parallel promises collect
  per-runnable success/failure.

Near term, do not replace Runic schedulers. Add metadata and contracts so this
future executor can be implemented without changing sandbox session APIs again.

### Sandbox Affinity Design

The future scheduler integration should treat a Runic promise as the sandbox
allocation boundary. The request can live in `run_context` first, with an
equivalent `SchedulerPolicy` metadata shape later when we want policy-level
planning:

```elixir
%{
  sandbox_affinity: %{
    promise_id: "promise:compile-and-proof",
    role: :execution,
    sandbox: :agent_cli_execution,
    sharing: :sequential_promise,
    acquire: %{mode: :checkout, lease: "promise:compile-and-proof"},
    cleanup: %{success: :release, failure: :checkpoint_and_release},
    artifact_root: "/workspace/.runic/promises/compile-and-proof",
    boundary_outputs: [:final_result, :manifest, :telemetry]
  }
}
```

The same map can be supplied globally under `run_context._global` or per
runnable/node. Per-node affinity wins over global affinity. A scheduler policy
can later copy this shape into policy metadata without changing
`RunicSandbox.Session`, process handles, or the RunicAI model-visible tool
contracts.

Promise acquisition flow:

- At promise dispatch start, the executor resolves `role` to a configured
  sandbox profile, usually `:agent_cli_dev` for iterative promotion work or
  `:agent_cli_execution` for workflow execution/proof.
- The executor calls `RunicSandbox.acquire_session/3` or the
  `open_sandbox_session` tool with `role` and `purpose: :promise`.
- The acquired session id and any RunicAI opaque registry id are stored in the
  promise-local run context, not in model text.
- Sequential promise runnables execute against the same session. Parallel
  promises either share one session process pool when the policy says
  `sharing: :parallel_pool`, or fan out across multiple execution-role sessions
  when isolation is preferred.
- On successful completion, the executor releases the session. On failure it
  follows the cleanup policy: checkpoint and release for diagnosable execution
  failures, reset and release for unsafe execution sessions, or close for
  corrupted/unhealthy sessions.

Intermediate data should avoid host round-trips by default. Runnables can pass
`sandbox://<session-id>/<path>` or `artifact://promise/<promise-id>/<name>`
references through workflow facts when the next runnable has the same affinity.
Only boundary outputs cross back to the host: final values, artifact manifests,
logs, metrics, checkpoint refs, and selected file previews. The manifest should
record checkpoint kind/preservation metadata so a resumed promise knows whether
it is restoring files only, VM memory, or provider-dependent state.

Failure behavior follows Runic promise semantics. A sequential promise may have
already committed earlier runnable outputs inside the sandbox; failed cleanup
must surface as a failed promise with cleanup diagnostics. A parallel promise
collects per-runnable failures, then applies one cleanup action for the sandbox
allocation. In all cases, active process handles block release until the
executor waits, kills, or marks them intentionally detached.

Fake executor test shape for the implementation slice:

- Build a two-runnable sequential promise with matching sandbox affinity.
- Use a fake sandbox controller that records acquire, exec, artifact write,
  checkpoint, and release calls.
- Assert both runnables receive the same session id, intermediate facts remain
  sandbox-local, and cleanup runs exactly once.
- Add a failure case proving the configured cleanup policy is used and active
  processes are killed before release.

## Implementation Slice Ledger

Each slice should update this ledger before and after implementation.

| Slice | Scope | Deliverables | Acceptance criteria | Validation | Status |
| --- | --- | --- | --- | --- | --- |
| 0. Goal + audit baseline | Make the target explicit and freeze current truth. | This plan doc; current backend matrix; known gaps; `/goal` objective started. | Team can tell which features are implemented, deferred, or backend-limited. | Doc review; no code validation. | Completed 2026-05-31 |
| 1. Ariston model egress unblock | Add `purpose: :model` for Docker restricted egress while keeping host-only scope. | Docker allow-list validation accepts `purpose in ["mcp", "model"]`; policy tests; docs/examples for MCP + model proxy entries. | Container can reach only configured `host.docker.internal:<mcp-port>` and `<model-port>`; external hosts and unlisted ports remain denied. | `cd packages/runic_sandbox && mix test`; live Docker allow/deny smoke for both ports. | Completed 2026-05-31 |
| 2. Capability taxonomy | Separate persistent workspace from persistent process host in capability metadata. | New capability metadata keys/helpers; backend health reports role/tier; tests for all current backends. | Docker no longer looks like a full process host just because it has a persistent workspace; Vmsan reports VM-backed process-host potential separately from live-stream limitations. | Focused capability tests; package tests. | Completed 2026-05-31 |
| 3. Process contract | Add backend-neutral process lifecycle above attach. | `ProcessHandle` or equivalent in `runic_sandbox`; callbacks for start/list/follow/write_stdin/close_stdin/signal/kill/wait; event bridge updates. | Consumers can manage a process without confusing it with a terminal result; unsupported backends fail closed. | Contract tests with fake backend; JustBash/Lua unsupported tests. | Completed 2026-05-31 |
| 4. Docker persistent container host | Make Docker sessions use a long-lived container when the profile asks for process hosting. | Session launch creates a named persistent container; `exec_session` uses `docker exec`; process start/attach uses `docker exec -i` or sidecar; close removes container and egress resources. | Multiple commands share PID namespace/filesystem while session is open; warm pool avoids repeated container startup; no stale containers/networks after close. | Package tests; live Docker session smoke; cleanup leak check. | Completed 2026-05-31 |
| 5. Docker services and private proxy | Implement service/proxy APIs for Docker sessions. | Start/list/stop service inside persistent container; open/close host-visible local proxy; restricted ingress defaults. | A dev server started in a sandbox can be reached through an explicit proxy and cannot expose arbitrary public ports. | Live Docker HTTP service smoke; proxy cleanup smoke. | Completed 2026-05-31 |
| 6. Agent CLI image | Build an image profile for contained Claude/Codex first, Gemini later. | Image/Dockerfile profile with runtimes, git/rg/jq/sqlite/build tools, Claude/Codex CLI installation hooks or placeholders, baked instructions/skills, entrypoint conventions, MCP/model proxy env defaults. | A contained CLI can run without model credentials in the sandbox and can call only host MCP/model proxy endpoints. | Image build task; offline CLI presence smoke; Ariston-compatible env smoke. | Completed 2026-05-31 |
| 7. Vmsan live process path | Move Vmsan from terminal adapter toward live process hosting. | Decide provider-native live channel vs sidecar; implement process start/stream/stdin where feasible; keep terminal adapter truth for unsupported operations. | Vmsan session can host a long-running command and accept stdin, or explicitly reports the missing live capability with a tracked provider blocker. | Vmsan package tests with fake runner; live local Vmsan smoke when host is ready. | Completed 2026-05-31 |
| 8. Sprites/Fly process certification | Prove provider-backed long-lived process hosting or document limits. | Provider adapter capability audit; native streaming/stdin implementation or sidecar plan; service/proxy mapping; credential and cleanup notes. | Sprites/Fly either satisfy the process-host contract or report precise capability gaps. | Provider fake tests; live smokes when credentials/resources are available. | Completed 2026-05-31 |
| 9. RunicAI sandbox tools | Expose process-host operations through model-visible tools safely. | Tool definitions for sandbox process start/list/log/write/kill, service/proxy, dev/execution sandbox roles; review gates; prompt guidance. | Agents can use opaque sandbox session/process ids without signed authority leakage. | Focused `RunicAI.Coding.Tools` tests; terminal/workbench smoke. | Completed 2026-05-31 |
| 10. Warm pool policy | Make warm reuse explicit and measurable. | Pool readiness probes, checkout latency metrics, role-aware defaults, reset/checkpoint policies, idle TTL, abandoned owner cleanup, capacity errors. | Warm checkout is faster than cold launch and pool reuse never crosses unsafe role/session boundaries. | Manager tests; live Docker timing smoke; leak checks. | Completed 2026-05-31 |
| 11. Snapshot and resume semantics | Distinguish filesystem snapshots, VM snapshots, suspend/resume, and process-memory snapshots. | Checkpoint metadata types; restore behavior docs; process/TCP limitations; backend-specific support matrix. | Consumers know whether restoring preserves only files, VM memory, running processes, or nothing. | Backend contract tests; Vmsan snapshot smoke; Docker filesystem checkpoint smoke. | Completed 2026-05-31 |
| 12. Sandbox promise design spike | Prepare Runic promise execution inside one sandbox without implementing the full executor yet. | Design note/API sketch for sandbox affinity in scheduler policies or run context; proof-of-concept fake executor test if cheap. | No current scheduler change is required, but future implementation path is clear. | Design review; optional focused tests. | Completed 2026-05-31 |
| 13. End-to-end dogfood | Prove the full target with real scenarios. | Ariston CLI-in-sandbox smoke; RunicAI dev/execution sandbox workflow; generated artifact promotion using dev sandbox and execution sandbox; cleanup report. | A full interactive turn can run with host-only MCP/model traffic and no broad internet from the sandbox. | Live Docker dogfood, capability report, package tests, cleanup check. | Completed 2026-05-31 |

## Slice Details

### Slice 1: Ariston Model Egress Unblock

This is the smallest immediate compatibility patch.

Deliverables:

- [x] Update Docker restricted-egress validation to accept `purpose: "model"` in
      addition to `"mcp"`.
- [x] Keep `host == "host.docker.internal"` and `scheme in ["http", "tcp"]` for
      the first patch.
- [x] Add policy tests showing two entries are preserved:
      `%{purpose: "mcp", port: 4000}` and `%{purpose: "model", port: model_port}`.
- [x] Add Docker live smoke coverage where two local host ports are allowed and
      one unrelated host/public target is denied.
- [x] Document that model credentials belong on the host proxy, not in the
      sandbox.

Non-goals:

- [x] No public internet egress.
- [x] No HTTPS proxying for Gemini yet.
- [x] No named alias beyond `host.docker.internal`.

Validation:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1099`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1846`
- [x] `cd packages/runic_sandbox && mix test`

### Slice 2: Capability Taxonomy

The current `persistent_identity?` flag is useful but too broad. It conflates
session identity, workspace persistence, and process-host lifetime.

Deliverables:

- [x] Add capability metadata for `state_tier`, `process_host?`,
      `workspace_persistent?`, `live_process_stream?`, `pty_supported?`,
      `service_host?`, and `snapshot_modes`.
- [x] Preserve existing fields for compatibility.
- [x] Update health/status outputs for Docker, GVisor, Vmsan, Sprites, Remote,
      JustBash, and Lua.
- [x] Add tests proving limited backends stay honest.

Acceptance criteria:

- [x] Docker current state reports persistent workspace but not persistent
      container process host until Slice 4 lands.
- [x] Vmsan reports VM-backed session identity and checkpoint support, while
      still reporting terminal-adapted attach until Slice 7 lands.
- [x] JustBash/Lua remain one-shot or terminal-adapter only.

Validation:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:709`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1315`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1597 test/runic_sandbox_test.exs:2488`
- [x] `cd packages/runic_sandbox && mix test`

### Slice 3: Process Contract

Attach remains the streaming event primitive, but process management needs a
named lifecycle contract.

Proposed process operations:

- `start_process(session, spec, opts)`
- `list_processes(session, opts)`
- `process_status(session, process_id, opts)`
- `process_events(process_handle, opts)` or reuse attach bridge explicitly
- `write_process_stdin(process_handle, input, opts)`
- `close_process_stdin(process_handle, opts)`
- `signal_process(process_handle, signal, opts)`
- `kill_process(process_handle, opts)`
- `wait_process(process_handle, opts)`

Deliverables:

- [x] Add structs for process handle/status with backend/session/process ids.
- [x] Add optional backend callbacks and facade functions.
- [x] Define event ordering and terminal semantics.
- [x] Bridge existing `AttachHandle` to process handles where possible.
- [x] Add fake backend coverage for the full lifecycle.

Validation:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:709 test/runic_sandbox_test.exs:999 test/runic_sandbox_test.exs:1067`
- [x] `cd packages/runic_sandbox && mix test`

### Slice 4: Docker Persistent Container Host

Docker should become the first full local process-host implementation.

Implementation sketch:

- `open_session/3` with `process_host?: true` creates a named container with:
  - configured image;
  - persistent bind-mounted workspace;
  - restricted egress network/proxy resources for the lifetime of the session or
    per process, depending on cleanup safety;
  - a sleep/sidecar entrypoint that keeps the container alive.
- `exec_session/3` uses `docker exec` against that container.
- process APIs use `docker exec -i` initially, then sidecar endpoints if needed
  for robust list/signal/stdin-close semantics.
- `close_session/2` removes the container and all owned resources.

Deliverables:

- [x] Profile/backend option to request persistent container hosting.
- [x] Session metadata stores container name/id and owned resources.
- [x] `exec_session` uses the persistent container when present.
- [x] Process start/list/status/write/kill are supported at least for command
      processes.
- [x] Active process handles prevent unsafe checkin/reset.
- [x] Cleanup handles success, failure, timeout, owner death, and manager
      termination.

Acceptance criteria:

- [x] Command A writes a file and a process started in the same session updates
      the shared workspace; command B sees the same files.
- [x] A warm checkout reuses an existing ready container instead of cold-starting.
- [x] Closing the session removes the container and egress resources.

Validation:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1739`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1809 test/runic_sandbox_test.exs:1855 test/runic_sandbox_test.exs:1886`
- [x] `docker ps -a --filter 'name=runic-sandbox' --format '{{.Names}}'`
- [x] `docker network ls --filter 'name=runic-sandbox' --format '{{.Name}}'`
- [x] `cd packages/runic_sandbox && mix test`

### Slice 5: Services And Proxies

Services are long-running processes with names, readiness, and optional host
proxies.

Deliverables:

- [x] Implement Docker `start_service/3`, `list_services/2`, `stop_service/3`.
- [x] Implement `open_proxy/3` and `close_proxy/2` for local host access to an
      explicit sandbox service port.
- [x] Add readiness probe support to service specs.
- [x] Keep inbound exposure private/local by default.

Acceptance criteria:

- [x] Start a Python/Node HTTP server in a Docker session.
- [x] Open a proxy and fetch it from the host.
- [x] Stop the service and verify the proxy closes.
- [x] Session close cleans service and proxy resources.

Validation:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1926`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1739 test/runic_sandbox_test.exs:1809 test/runic_sandbox_test.exs:1855 test/runic_sandbox_test.exs:1886 test/runic_sandbox_test.exs:1926`
- [x] `cd packages/runic_sandbox && mix test`
- [x] `docker ps -a --filter 'name=runic-sandbox' --format '{{.Names}}'`
- [x] `docker network ls --filter 'name=runic-sandbox' --format '{{.Name}}'`

Notes:

- The first Docker proxy implementation is a localhost-only HTTP bridge through
  `docker exec`. Raw TCP proxying can be added later if consumers need non-HTTP
  service protocols.

### Slice 6: Agent CLI Image

The image should make contained CLI agents practical without moving secrets into
the sandbox.

Deliverables:

- [x] Define image profile(s), such as `runic-ai/sandbox-agent-cli`.
- [x] Include base runtimes and tools: bash, git, curl, jq, rg, sqlite, Python,
      Node/npm, Elixir/Erlang, build tools.
- [x] Add install hooks or documented build args for Claude/Codex CLIs.
- [x] Add image paths for instructions/skills, such as `/opt/runic-ai/agents`.
- [x] Add default env names for MCP/model endpoints without secrets:
      `RUNIC_MCP_URL`, `RUNIC_MODEL_PROXY_URL`.
- [x] Add no default internet egress assumption to image docs.
- [x] Add Gemini follow-up note: TLS or loopback-compatible endpoint may be
      needed later.

Acceptance criteria:

- [x] Image builds locally.
- [x] A container can execute Claude/Codex command discovery without credentials
      baked in.
- [x] A contained process can reach host MCP/model proxy only through allow-list
      entries.

Implementation notes:

- `priv/runic_ai/sandbox/agent-cli/Dockerfile` defines
  `runic-ai/sandbox-agent-cli:latest` with the generic runtime stack plus
  `/opt/runic-ai/agents`.
- `RunicSandbox.ConsumerProfiles.agent_cli_dev/1` and
  `agent_cli_execution/1` define the dev/execution split. The dev profile keeps
  a warm reusable sandbox; the execution profile resets on checkin while keeping
  a warm replacement available.
- `backend_options.environment` is passed through Docker run/session args so
  consumers can override `RUNIC_MCP_URL` and `RUNIC_MODEL_PROXY_URL` without
  baking secrets or ports into the image.
- `mix runic_ai.sandbox.image --variant agent-cli` builds and smokes the image.

Verification:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:462`
- [x] `mix test test/runic_ai/sandbox_image_test.exs`
- [x] `cd packages/runic_sandbox && mix test`
- [x] `mix runic_ai.sandbox.image --variant agent-cli`
- [x] `docker ps -a --filter 'name=runic-sandbox' --format '{{.Names}}'`
- [x] `docker network ls --filter 'name=runic-sandbox' --format '{{.Name}}'`

### Slice 7: Vmsan Live Process Path

Vmsan is already a real VM session, so the gap is live process control.

Decision points:

- provider-native live exec/stream/stdin if vmsan exposes it;
- sandbox-resident sidecar reachable through the vmsan control path;
- terminal adapter remains the fallback, but must stay marked as non-live.

Deliverables:

- [x] Audit vmsan CLI capabilities for live streaming/stdin/signal/list.
- [x] Decide sidecar vs provider-native implementation.
- [x] Implement the process contract where feasible.
- [x] Keep unsupported operations explicit.
- [x] Add live smoke scripts gated on host readiness.

Acceptance criteria:

- [x] Either Vmsan satisfies the live process contract or the missing provider
      capability is precisely documented with failing/skip-gated tests.

Implementation notes:

- Vmsan 0.3.0 exposes `vmsan exec --interactive`; the first process path uses
  that provider-native transport instead of introducing a sidecar.
- `RunicSandbox.Backends.Vmsan.start_process/3` starts an interactive exec,
  streams process events, accepts stdin, and records an in-VM pidfile.
- `list_processes/2`, `process_status/3`, and `signal_process/3` use normal
  `vmsan exec` control commands against the same VM.
- Existing attach remains a terminal-result adapter because it still runs
  synchronous `vmsan exec` and cannot accept stdin after completion.
- `scripts/vmsan_process_smoke.exs` is gated: it skips with diagnostics when
  the host lacks passwordless sudo or other Vmsan readiness requirements.

Verification:

- [x] `vmsan exec --help`
- [x] `vmsan connect --help`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:2362`
- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:2503`
- [x] `cd packages/runic_sandbox && mix test`
- [x] `mix test test/runic_ai/sandbox_image_test.exs`
- [x] `cd packages/runic_sandbox && mix run scripts/vmsan_process_smoke.exs`
      skipped on this host because `vmsan create` requires passwordless sudo.

### Slice 8: Sprites/Fly Process Certification

Provider-backed full Linux environments should be usable when their provider API
can host real processes.

Deliverables:

- [x] Audit Sprites and Fly/Machines APIs for live exec, stdin, process list,
      service ports, suspend/resume, and snapshots.
- [x] Implement native capability where available.
- [x] Use sidecar where native API is too thin but a private control channel is
      practical.
- [x] Add provider-specific health metadata and live smoke gating.

Acceptance criteria:

- [x] Provider backends either pass the same process-host contract tests as
      Docker or expose a documented limited capability state.

Implementation notes:

- Sprites is a certified process host. The API provides WebSocket exec sessions
  that persist across disconnects, stdin/stdout/stderr/exit framing, session
  listing, attach, kill, port notifications, services, proxy, and checkpoints.
- `RunicSandbox.Backends.Sprites.start_process/3` now opens a native
  `:sprites_websocket_exec` process transport. The default adapter shells out to
  `websocat`; host apps can inject `:websocket_open` for a first-class
  WebSocket client.
- Sprites process operations now cover event streaming, stdin writes, stdin EOF,
  list/status, kill, and wait. HTTP POST exec remains a terminal-result adapter
  for one-shot attach.
- Fly Machines is certified limited in this package. The Fly/Machines API has
  exec, ps, signal, suspend, wait, and lifecycle endpoints, but the current
  `:remote` backend only wraps `fly machine exec` as a terminal adapter and does
  not yet own a Fly Machines API client or live process stream.

Provider references:

- Sprites exec docs: `https://sprites.dev/api/sprites/exec`
- Sprites API categories: `https://docs.sprites.dev/api/dev-latest/`
- Fly Machines API overview: `https://docs.machines.dev/`

Verification:

- [x] `cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs:1624 test/runic_sandbox_test.exs:2901`
- [x] `cd packages/runic_sandbox && mix test`
- [x] `mix test test/runic_ai/sandbox_image_test.exs`
- [x] `cd packages/runic_sandbox && mix run scripts/sprites_process_smoke.exs`
      skipped on this host because `SPRITES_SMOKE_SPRITE` is not configured.
- [x] `cd packages/runic_sandbox && mix run scripts/vmsan_process_smoke.exs`
      skipped on this host because `vmsan create` requires passwordless sudo.
- [x] `docker ps -a --filter 'name=runic-sandbox' --format '{{.Names}}'`
- [x] `docker network ls --filter 'name=runic-sandbox' --format '{{.Name}}'`

### Slice 9: RunicAI Sandbox Tools

Once the package can manage processes, model-visible tools should expose them
through opaque ids and review gates.

Deliverables:

- [x] Add tools for sandbox process start/list/status/log/write/kill/wait.
- [x] Add tools for dev/execution sandbox acquisition and release.
- [x] Add tools for service/proxy management.
- [x] Preserve signed `RunicSandbox.Session` and backend handles inside
      `SandboxSessionRegistry`.
- [x] Add prompt guidance for when to use dev vs execution sandbox.
- [x] Add review-gate coverage for mutating/process/service operations.

Implementation notes:

- `SandboxSessionRegistry` now stores private sandbox process handles behind
  RunicAI-owned `sandbox_process_*` ids, matching the existing managed session
  and proxy authority boundary.
- The model-visible tool surface includes `start_sandbox_process`,
  `list_sandbox_processes`, `sandbox_process_status`,
  `sandbox_process_events`, `write_sandbox_process`,
  `close_sandbox_process_stdin`, `signal_sandbox_process`,
  `kill_sandbox_process`, and `wait_sandbox_process`.
- `open_sandbox_session` accepts optional `role` and `purpose` fields so a
  caller can distinguish dev and execution sandboxes without exposing backend
  authority data.
- Process and service mutators are review-gated; read/status/event tools are
  read-only from the review-policy perspective.

Acceptance criteria:

- [x] An agent can start a contained CLI, stream logs, send stdin, and kill it
      using only opaque ids.
- [x] Tool output summarizes evidence instead of flooding the model context.

### Slice 10: Warm Pool Policy

Warm pools should be a first-class latency and safety mechanism, not an accident
of manager internals.

Deliverables:

- [x] Add readiness probes for warm sessions.
- [x] Measure cold open vs warm checkout latency.
- [x] Add role-aware pool defaults for `:dev` and `:execution`.
- [x] Add pool status fields for ready/busy/stale/unhealthy sessions.
- [x] Add policy for reset/checkpoint on checkin/checkout.
- [x] Add abandoned owner and idle cleanup smokes.

Implementation notes:

- `RunicSandbox.Manager.status/2` now reports `pool_status` with ready, busy,
  stale, unhealthy, total, warm, max, and available capacity counts.
- Session status entries include `readiness`, idle/checkout age,
  `checkout_source`, `last_checkout_latency_ms`, and checkout checkpoint
  evidence.
- Checkout records whether a session came from the warm pool or a cold open;
  execution-role reset-on-checkin tests prove the old session identity is not
  reused.
- `checkpoint_on_checkout?` now creates a checkpoint when the backend supports
  checkpoints and records an explicit skipped/unsupported marker otherwise.

Acceptance criteria:

- [x] Warm checkout avoids cold launch for Docker persistent containers.
- [x] Unsafe state is not reused across execution role checkouts.

### Slice 11: Snapshot And Resume Semantics

Snapshots must not overclaim process preservation.

Deliverables:

- [x] Add checkpoint metadata `kind` values for filesystem, VM, memory, provider,
      and suspended-session states.
- [x] Add backend support matrix for what restore preserves.
- [x] Add docs warning that open TCP connections and background processes may not
      survive filesystem-only snapshots.
- [x] Add Vmsan snapshot smoke.
- [x] Add Docker filesystem checkpoint smoke.

Implementation notes:

- `RunicSandbox.Checkpoint` now exposes `kinds/0`, `kind/1`, `preserves/1`,
  `preserves?/2`, and `support_matrix/0` for filesystem, microVM snapshot,
  memory snapshot, provider checkpoint, and suspended-session semantics.
- Docker checkpoints are explicitly `kind: :filesystem`; they preserve files
  only and do not claim process memory, running services, or TCP connections.
- Vmsan checkpoints are `kind: :microvm_snapshot`; they preserve VM filesystem
  and memory state, while external network connections remain unsafe to assume.
- Sprites checkpoints are `kind: :provider_checkpoint`; process memory and
  running service preservation are marked provider-dependent rather than
  guaranteed.
- Added gated live smoke scripts:
  `scripts/docker_checkpoint_smoke.exs` and `scripts/vmsan_snapshot_smoke.exs`.

Acceptance criteria:

- [x] A consumer can ask whether a checkpoint preserves files only, process memory
      too, or running service state.

### Slice 12: Sandbox Promise Design Spike

This keeps the Runic scheduling path open without blocking process-host work.

Deliverables:

- [x] Add a design note or section update describing sandbox affinity in
      `run_context` and/or `SchedulerPolicy`.
- [x] Define how a promise acquires/releases a sandbox role.
- [x] Define how intermediate files/artifacts are addressed.
- [x] Define failure and cleanup behavior.
- [x] Add a fake executor test if the design becomes concrete enough.

Implementation notes:

- Added a concrete `sandbox_affinity` map shape for `run_context._global`,
  per-node run context, and future `SchedulerPolicy` metadata.
- Promise acquisition uses dev/execution roles and `purpose: :promise` while
  keeping signed sandbox authority in the manager/registry.
- Intermediate data can remain as `sandbox://...` or `artifact://promise/...`
  refs until a boundary output is required.
- The fake executor test shape is specified for the implementation slice rather
  than added now; no scheduler behavior changes are required for this spike.

Acceptance criteria:

- [x] The team can implement a sandbox-aware executor later without changing the
      process/session contract again.

### Slice 13: End-To-End Dogfood

The goal is not complete until the full use case runs.

Deliverables:

- [x] Ariston-compatible contained CLI smoke:
      MCP at `host.docker.internal:4000`, model proxy at configured model port,
      no external egress.
- [x] Dev/execution sandbox promotion smoke:
      generate an artifact in the dev sandbox, copy the boundary output into an
      execution sandbox, prove it there, then verify execution state is reset on
      checkin.
- [x] Long-lived process smoke:
      start the contained CLI, send stdin, observe host MCP/model callbacks, and
      clean up the process/session resources.
- [x] Warm pool smoke:
      demonstrate faster warm checkout and no leaked containers/resources.
- [x] Capability report:
      Docker/GVisor, Vmsan, Sprites, Fly/Remote, JustBash, Lua.

Acceptance criteria:

- [x] A full interactive turn is possible in Docker with host-only MCP/model
      traffic.
- [x] Backends that cannot satisfy the full target report limited capability
      instead of pretending to support it.

Implementation notes:

- Added `packages/runic_sandbox/scripts/agent_cli_dogfood_smoke.exs`.
  The script starts an agent CLI Docker sandbox pair with dev and execution
  roles, injects `RUNIC_MCP_URL` and `RUNIC_MODEL_PROXY_URL`, drives an
  interactive stdin turn, verifies host MCP/model callbacks, verifies public
  egress denial, proves dev-to-execution artifact promotion, verifies
  reset-on-checkin for execution sandboxes, checks warm checkout evidence, and
  asserts no `runic-sandbox` Docker containers or networks leak.
- Added `packages/runic_sandbox/scripts/capability_report.exs` to emit a
  backend-by-backend report for process-host capability, service-host
  capability, snapshot modes, expected full-process-host status, and limited
  capability reasons.
- Exact Ariston default `host.docker.internal:4000` is supported by the profile
  and script, but this development host already has a local BEAM process bound
  to `127.0.0.1:4000`, so the default run skips with `host port 4000 is already
  in use`. The live proof used `RUNIC_SANDBOX_MCP_PORT=4001` with the same
  host-only route shape.
- The dogfood script uses a workspace log written by the contained process for
  the end-to-end proof. Package tests still cover `process_events/2` streaming;
  the smoke keeps its failure mode focused on the Ariston transport and warm
  session behavior.

Validation:

- [x] `cd packages/runic_sandbox && RUNIC_SANDBOX_MCP_PORT=4001 mix run scripts/agent_cli_dogfood_smoke.exs`
- [x] `cd packages/runic_sandbox && mix run scripts/agent_cli_dogfood_smoke.exs`
      skips on this host because port `4000` is already in use.
- [x] `cd packages/runic_sandbox && mix run scripts/capability_report.exs`
- [x] `cd packages/runic_sandbox && mix test`
- [x] `mix compile`
- [x] `git diff --check`
- [x] Docker cleanup checks:
      `docker ps -a --filter 'name=runic-sandbox' --format '{{.Names}}'` and
      `docker network ls --filter 'name=runic-sandbox' --format '{{.Name}}'`
      both returned empty output.

## Backend Target Matrix

| Backend | Target state | Limited behavior |
| --- | --- | --- |
| Docker | Full local persistent process host, services/proxies, restricted MCP/model egress, warm pool. | Implemented and dogfooded locally. |
| GVisor | Same API as Docker with gVisor runtime truth and any runtime-specific limits. | Capability report marks unavailable on this host because `runsc` is missing. |
| Vmsan | VM-backed process host with checkpoints and live process streaming if provider/sidecar supports it. | Implemented in package contract; live smoke skips on this host because `vmsan create` requires passwordless sudo. |
| Sprites | Provider-backed persistent process host where API supports live control. | Implemented against provider exec transport; live smoke requires configured Sprites credentials/resource. |
| Remote/Fly Machines | Provider-backed persistent process host with machine lifecycle and service ports. | Current `:remote` adapter is certified limited until native/sidecar live process control lands. |
| JustBash | One-shot host-local command backend for tests and limited local convenience. | No process-host claim. |
| Lua | In-process execution backend for deterministic small snippets. | No process-host claim. |

## Open Questions

- Should Docker restricted egress sidecars be per session for persistent
  containers or per process for tighter cleanup and policy changes?
- Is a sandbox-resident sidecar worth making mandatory for full process-host
  certification, or should Docker first ship with `docker exec` and add sidecar
  only when process list/stdin-close/signal semantics require it?
- Should process APIs reuse `AttachHandle` or introduce a separate
  `ProcessHandle` that can create one or more attach/follow streams?
- How should a model-visible agent select dev vs execution sandbox by default?
- Should Runic promise sandbox affinity live in `run_context`, scheduler policy,
  runner opts, or a sandbox-aware executor?
- How much provider-specific suspend/resume should be normalized before we have
  at least one full local backend complete?
- For Gemini, should the model proxy eventually terminate TLS inside the host
  proxy, inside the sandbox sidecar, or through a loopback presentation trick?

## Completion Definition

This goal can be marked complete when:

- [x] Docker supports a warm, long-lived process-host session with restricted
      MCP/model egress and agent-CLI image smoke coverage.
- [x] `runic_sandbox` exposes process lifecycle APIs with honest capability maps.
- [x] RunicAI tools can operate on sandbox sessions/processes through opaque ids.
- [x] Dev and execution sandbox roles are documented and usable.
- [x] At least one full interactive CLI-in-sandbox turn is proven with no broad
      internet egress and no credentials inside the sandbox.
- [x] Vmsan/Sprites/Fly have either passed the process-host contract or have
      precise, tested limited-capability reporting.
- [x] The Runic promise scheduling compatibility path is documented well enough
      to implement without revisiting the session/process API.
