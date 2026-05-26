# Sandbox Serverless Mesh Implementation Plan

Status: implementation plan / architecture direction

Date: 2026-05-25

## Purpose

The first RunicAI sandbox pass focused on local agents safely executing code:
structured requests/results, review gates, trace events, Workbench settings,
and an extractable `RunicSandbox` package with in-process, Docker, gVisor-shape,
and remote-provider surfaces.

This note expands the question into an actionable RunicSandbox implementation
plan:

- what needs to be installed locally to implement and test a vmsan + KVM
  backend;
- whether Sprites, built on Fly Machines, should become a first-class stateful
  remote sandbox adapter;
- how the same sandbox library can grow toward Libbit's workspace isolation,
  serverless sidecar, durable workflow, and cloud workspace use cases without
  turning into a pile of provider-specific glue.
- how to phase the work so Codex/RALPH/OODA loops can iteratively implement,
  verify, review, and adjust without jumping into Libbit implementation yet.

## Executive Summary

Recommendation:

1. Make `RunicSandbox` the center of gravity. All new contracts and backend
   adapters should land in `packages/runic_sandbox`; RunicAI should consume
   them through its existing tool, review, trace, Workbench, and RLM surfaces.
   Libbit should remain a design constraint and later consumer, not an edit
   target for this plan.
2. Add `RunicSandbox.Backends.Vmsan` as the next local microVM adapter, behind
   capability probes that fail clearly when KVM, vmsan, nftables, Firecracker,
   jailer, agent binaries, kernels, or rootfs images are missing.
3. Add session-level contracts before trying to model Sprites or vmsan
   snapshots in ad hoc fields. The missing abstraction is not another
   `ExecutionRequest` option; it is a stateful sandbox session with files,
   checkpoints, services, proxies, leases, capability metadata, and lifecycle
   events.
4. Add `RunicSandbox.Backends.Sprites` after the session contract exists.
   Sprites maps more naturally than raw Fly Machines to "workspace-like sandbox
   with exec, files, checkpoints, services, proxy, and hibernation."
5. Keep low latency explicit. Use a tiered strategy: in-process DSL runtimes for
   tiny deterministic work, Docker for cheap local polyglot execution, vmsan
   warm microVMs for hard local isolation, and Sprites for hosted stateful
   workspace sessions.
6. Keep the package boundary provider-neutral. `RunicSandbox` should expose
   capabilities such as `exec`, `filesystem`, `checkpoint`, `service`,
   `proxy`, `network_policy`, `volume`, `lease`, and `pool`. It should not make
   "Sprite", "Fly Machine", "Firecracker", or "Docker container" the app-facing
   abstraction.

The architectural shape should become:

```text
RunicAI / Libbit tools and workflows
  -> app-specific policy, review, trace, workspace binding
  -> RunicSandbox session + execution contracts
  -> backend adapters: JustBash, Lua, Docker, gVisor, vmsan, Sprites, Fly Machines
  -> provider APIs / CLIs / local runtimes
```

## Success Criteria

The implementation is successful when:

- [ ] RunicSandbox can execute arbitrary polyglot code through at least one
      low-latency local backend and one hard-isolation local backend.
- [x] vmsan status reports are truthful and actionable on this machine, including
      missing asset diagnostics from `vmsan doctor`.
- [ ] vmsan can run Bash plus at least two non-Bash runtimes from a configured
      image or rootfs path.
- [ ] Stateful sessions support file persistence across exec calls.
- [ ] Checkpoints can be created and restored on at least one backend.
- [ ] Services and proxies are modeled as structured contracts, even before all
      backends implement them.
- [ ] RunicAI `execute_code` and RLM script nodes can select Docker, vmsan, or
      Sprites by capability profile without provider-specific tool code.
- [ ] Workbench/status/report output shows backend, isolation, state model,
      transport, policy, health, and known limitations.
- [ ] Libbit-facing requirements are represented as contracts, tests, and docs,
      without editing the Libbit repo in this implementation cycle.

## Local vmsan + KVM Readiness

### Current machine check

Observed on this machine:

```text
OS: Linux boops 6.17.0-29-generic x86_64 Ubuntu 24.04 lineage
CPU virtualization flag: svm present
Docker: installed
npm: installed
vmsan: installed at /home/doops/.asdf/shims/vmsan
vmsan version: 0.3.0
firecracker: not installed
jailer: not installed
/dev/kvm: present, owned by root:kvm, ACL grants doops rw
kvm module: loaded
kvm_amd module: loaded
KVM acceleration: can be used
user groups: doops, sudo, docker, others; access currently via /dev/kvm ACL
npm vmsan package: 0.3.0 available
```

This means the machine is now suitable for KVM-backed testing. The remaining
vmsan blockers are runtime asset and networking setup, not firmware.

Current `vmsan doctor --json` summary:

```text
passed: 5
failed: 8
passes: KVM, TUN device, default interface, host firewall, jailer filesystem
failures: disk space check, nftables kernel support, Firecracker, Jailer,
  Agent, vmsan-nftables, Kernel image, Rootfs image
```

Implementation implication: Phase 0 must make doctor output part of
RunicSandbox health reporting before attempting a live vmsan exec. A good
backend should report these missing assets as structured unavailable diagnostics
instead of crashing during `exec/2`.

### What needs to be installed or enabled

Minimum local setup for vmsan-backed testing:

1. Enable virtualization in firmware if it is disabled.
   - AMD: SVM / AMD-V.
   - Intel: VT-x.
2. Install KVM host packages:

   ```sh
   sudo apt update
   sudo apt install -y qemu-kvm cpu-checker
   ```

   Direct Firecracker work may additionally need:

   ```sh
   sudo apt install -y iproute2 iptables e2fsprogs qemu-utils
   ```

3. Load the KVM module:

   ```sh
   sudo modprobe kvm
   sudo modprobe kvm_amd
   ```

   Use `kvm_intel` instead of `kvm_amd` on Intel hosts.

4. Ensure `/dev/kvm` exists and the user can access it:

   ```sh
   ls -l /dev/kvm
   sudo usermod -aG kvm "$USER"
   ```

   Then log out and back in, or start a new login session.

5. Install vmsan:

   ```sh
   npm install -g vmsan
   ```

6. Verify:

   ```sh
   kvm-ok
   vmsan --version
   vmsan --help
   ```

Potential blocker: if this host is itself inside an environment without nested
virtualization, the CPU may advertise virtualization flags while `/dev/kvm`
still cannot be used. In that case vmsan testing needs host-level nested KVM
enabled, a different Linux host, or a remote machine that exposes KVM.

~~Earlier host-specific blocker: `journalctl -k -b` reported
`SVM disabled (by BIOS) in MSR_VM_CR`, and `sudo modprobe kvm_amd` failed with
`Operation not supported`. On this bare-metal host (`systemd-detect-virt`
reported `none`), the next step was firmware setup, not more Linux packages.~~

Fixed: SVM is now enabled in BIOS, `kvm_amd` loads, `/dev/kvm` exists, and
`kvm-ok` reports that KVM acceleration can be used.

### How to integrate vmsan safely

The vmsan adapter should be a CLI adapter first, not a direct Firecracker
backend.

Expected adapter shape:

```elixir
RunicSandbox.Backends.Vmsan
```

Capabilities to map:

| RunicSandbox capability | vmsan command/API shape |
| --- | --- |
| provision session | create VM from image |
| exec command | exec with JSON result |
| upload file | upload |
| download file | download |
| checkpoint | snapshot |
| reset | restore snapshot or rebuild |
| network policy | vmsan network options |
| status | CLI presence, KVM readiness, image cache readiness |

Current CLI observations:

- `vmsan exec --help` is available without root and supports `--workdir`,
  repeated `--env`, `--sudo`, and interactive/TTY flags.
- `vmsan network --help` exposes `--network-policy=allow-all|deny-all|custom`,
  allowed domains, allowed CIDRs, and denied CIDRs.
- `vmsan create --help` and `vmsan snapshot --help` currently require root,
  so the adapter must model privileged operations explicitly instead of hiding
  them inside `exec/2`.
- `vmsan doctor --json` is the right first integration point because it reports
  partial installation state without trying to create a VM.

The important implementation constraint is that vmsan output should be treated
as provider data and normalized into `RunicSandbox.ExecutionResult`,
`RunicSandbox.Instance`, and future `SessionEvent` structs. The rest of RunicAI
and Libbit should not parse vmsan JSON directly.

## Sprites Evaluation

Sprites is a high-level sandbox API built on Fly Machines. It is more
application-oriented than Fly Machines and maps well to stateful agent
sandboxes.

* Note: current local testing uses the Sprites CLI and token env. The
  RunicSandbox adapter defaults to `SPRITES_TOKEN`; profiles can override
  `token_env` for environments still using `SPRITE_TOKEN`.

Public docs describe these relevant surfaces:

- SDK examples create a client, create a sandbox, run commands, and then close
  the sandbox.
- Sandboxes can execute commands and shell commands.
- Filesystem APIs support reading, writing, listing, deleting, and making
  directories.
- Checkpoints capture sandbox state and support restore/branch-style workflows.
- Services and proxy APIs expose running processes inside the sandbox.
- Network policy can restrict outbound access.

This is exactly the set of operations missing from the current `exec/2`-first
RunicSandbox contract.

### Fit for RunicAI

Sprites is useful for RunicAI, but not as the default local workbench backend.

Good fits:

- optional cloud sandbox preset;
- stateful coding sessions when local Docker/KVM is unavailable;
- shared examples for session/checkpoint semantics;
- remote browser/service demos once proxy support is modeled.

Poor fits:

- default local-first experience;
- fully offline development;
- minimal dependency smoke tests;
- avoiding provider account setup.

RunicAI should support Sprites as `backend: :sprites` or `backend: :remote,
provider: :sprites`, but the local Docker/vmsan path remains the default
developer story.

### Fit for Libbit

Sprites is a strong fit for Libbit.

Libbit workspaces are not just local repositories. They can become deployed,
stateful, multi-tenant runtime cells where users and agents run durable workflows
and entire small applications. Sprites gives Libbit a hosted sandbox session
shape that already includes:

- persistent filesystem state;
- wake/hibernate economics;
- checkpoint/restore;
- command execution;
- service processes;
- proxy access;
- network policy.

That is closer to "workspace runtime island" than a plain `fly machine exec`.

### Adapter Decision

Use a dedicated adapter:

```elixir
RunicSandbox.Backends.Sprites
```

Do not hide it under the existing Fly Machines remote adapter. Fly Machines are
infrastructure primitives. Sprites is a stateful sandbox product API. They share
substrate but should not share the same adapter surface.

The adapter should normalize Sprites into these package-level concepts:

- `Session`
- `ExecutionRequest`
- `ExecutionResult`
- `FileRef`
- `Checkpoint`
- `Service`
- `Proxy`
- `NetworkPolicy`
- `SessionEvent`

## Other Sandbox And Serverless Systems To Track

This area is moving quickly. The goal is not to chase every provider, but to
watch which capability shapes become common.

| System | Useful signal | Adapter posture |
| --- | --- | --- |
| vmsan | Local Firecracker microVM CLI with JSON-oriented automation. | Implement next for local KVM. |
| Sprites | Hosted stateful sandbox API on Fly Machines with files, exec, checkpoints, services, proxy. | Implement as first remote stateful session adapter. |
| Fly Machines | Mature remote VM primitive, already present in Libbit. | Keep as infra/runtime substrate and lower-level remote adapter. |
| CubeSandbox | Tencent Cloud sandbox runtime for secure agent/runtime workloads. | Research architecture; adapter only if self-hosted/API shape fits. |
| E2B | Popular agent code-interpreter sandbox API. | Track for ecosystem expectations and possible adapter. |
| Daytona | Workspace/sandbox API for developer-agent environments. | Track for workspace lifecycle semantics. |
| Modal Sandboxes | Programmatic cloud sandboxes adjacent to serverless compute. | Track for pool, lifecycle, and data-mount semantics. |
| Freestyle | Serverless/preview deployment for agent-generated apps. | Track for "agent builds a service, gets a URL" workflows. |
| Docker/gVisor/Kata | Practical local/self-hosted container isolation ladder. | Keep Docker/gVisor in base package; maybe Kata later. |
| Raw Firecracker | Maximum control, highest burden. | Defer until vmsan/Sprites/Fly prove insufficient. |

The X and You.com links from the prompt are useful discovery seeds, but the
durable architecture should cite provider docs, source repos, and local evidence
instead of social posts.

## Libbit As A Consumer

Libbit already has a lot of the target shape:

- `Core.Infrastructure.Provider` defines workspace/runtime/storage lifecycle.
- `Core.Infrastructure.Providers.Fly` and `Core.Infrastructure.Fly.Machines`
  already model Fly Apps, Machines, Volumes, Secrets, Tokens, lifecycle, and
  exec.
- `Core.Runtime.WorkspaceRunner` hosts durable Runic workflows per workspace.
- Workspace-local SQLite and RocksDB layers give Libbit durable read models,
  event stores, journals, and projections.
- Built-in agent planning already names Linux CLI sandbox/VM execution as a
  desired workspace tool family.
- Existing Libbit docs already separate Fly Machines, Docker/Kubernetes, and
  Firecracker as provider tracks.

The missing piece is a capability layer between Libbit tools/workflows and
provider adapters. Libbit's old `Core.Infrastructure.Provider` is infra-centric:
provision workspace, provision runtime, exec runtime. That remains valuable, but
it is not expressive enough for stateful agent sandboxes.

### Libbit Needs More Than RunicAI's Local Sandbox

RunicAI needs:

- run bounded code;
- return stdout/stderr/status/artifacts/diagnostics;
- avoid mutating the host unexpectedly;
- expose review/traces in a local workbench.

Libbit also needs:

- per-workspace runtime identity;
- durable workspace filesystem state;
- workspace-local embedded databases;
- service processes;
- HTTP/TCP proxying;
- checkpoints and branches;
- long-lived workflow applications;
- event and projection integration;
- cloud deployment and local development parity;
- multi-agent access to the same runtime with policy and leases.

If `RunicSandbox` only grows by adding fields to `ExecutionRequest`, it will
become confused. The right move is to add session-level contracts.

## Proposed RunicSandbox Contract Growth

### Keep The Existing Execution Contract

The current contract remains useful:

```elixir
RunicSandbox.exec(%{
  sandbox: :local_code,
  runtime: :python,
  mode: :script,
  source: "...",
  files: %{},
  network: :disabled
}, profile: [...])
```

This should stay the high-level "run bounded code" path.

### Add Session-Level APIs

Add explicit session lifecycle:

```elixir
{:ok, session} = RunicSandbox.open_session(:workspace_dev, spec)
{:ok, result} = RunicSandbox.exec(session, request)
{:ok, checkpoint} = RunicSandbox.checkpoint(session, name: :before_migration)
:ok = RunicSandbox.restore(session, checkpoint.id)
:ok = RunicSandbox.close_session(session)
```

Suggested contracts:

```elixir
%RunicSandbox.Session{
  id: "...",
  sandbox: :workspace_dev,
  backend: :sprites,
  isolation_level: :remote_microvm,
  state: :ready,
  workspace_ref: %{app: :libbit, workspace_id: "..."},
  capabilities: MapSet.t(),
  policy: %RunicSandbox.Policy{},
  metadata: %{}
}

%RunicSandbox.Checkpoint{
  id: "...",
  session_id: "...",
  kind: :filesystem | :full_vm | :provider_checkpoint,
  created_at: DateTime.t(),
  size_bytes: non_neg_integer() | nil,
  metadata: %{}
}

%RunicSandbox.Service{
  id: "...",
  session_id: "...",
  name: "phoenix",
  command: ["mix", "phx.server"],
  ports: [%{container: 4000, protocol: :tcp}],
  state: :starting | :running | :failed | :stopped,
  metadata: %{}
}

%RunicSandbox.Proxy{
  id: "...",
  session_id: "...",
  service_id: "...",
  url: "https://...",
  expires_at: DateTime.t() | nil,
  policy: %{public?: false, auth: :token}
}
```

### Add Filesystem APIs

Needed for Sprites, vmsan, Libbit workspace imports, and remote machine
adapters:

```elixir
RunicSandbox.write_file(session, path, iodata, opts)
RunicSandbox.read_file(session, path, opts)
RunicSandbox.list_files(session, path, opts)
RunicSandbox.delete_file(session, path, opts)
RunicSandbox.upload(session, host_path_or_artifact, sandbox_path, opts)
RunicSandbox.download(session, sandbox_path, opts)
```

Results should be structured and artifact-friendly:

```elixir
%RunicSandbox.FileRef{
  path: "/workspace/app/lib/foo.ex",
  kind: :file,
  size_bytes: 1234,
  checksum: "sha256:...",
  artifact_ref: "sandbox://..."
}
```

### Add Capability Introspection

Backends should declare what they can do:

```elixir
%RunicSandbox.Capabilities{
  exec?: true,
  files?: true,
  checkpoints?: true,
  restore?: true,
  services?: true,
  proxy?: true,
  network_policy?: true,
  volumes?: true,
  snapshots?: true,
  hibernate?: true,
  persistent_identity?: true
}
```

This avoids pretending Docker copy-in, vmsan snapshots, Sprites checkpoints, and
Fly volume state are the same thing.

### Add Leases

Libbit especially needs concurrency control. A workspace may have multiple
agents and workflows trying to use the same sandbox.

Add a lease concept:

```elixir
{:ok, lease} = RunicSandbox.acquire(session, owner: {:workflow_run, run_id})
:ok = RunicSandbox.release(lease)
```

Leases should record:

- owner;
- acquired_at;
- expires_at;
- mode: `:read`, `:write`, `:exclusive`;
- policy escalation reason.

RunicAI can mostly ignore this at first. Libbit cannot.

## Backend Taxonomy

Use three orthogonal dimensions instead of one overloaded `backend` label:

| Dimension | Examples | Why it matters |
| --- | --- | --- |
| Isolation boundary | in-process, container, gVisor, microVM, remote microVM | Security and review wording. |
| State model | one-shot, persistent workspace, checkpointable session, volume-backed service | User expectations and cleanup semantics. |
| Transport model | direct function, CLI, Docker exec, SSH, WebSocket, HTTP API, provider SDK | Adapter complexity and observability. |

Backend presets can still be simple:

```elixir
backend: :vmsan
backend: :sprites
backend: :docker
```

But results and health reports should expose all three dimensions.

## Boundary Design

### What belongs in RunicSandbox

- portable contracts;
- backend behaviours;
- lifecycle manager;
- capability/health reports;
- request/result/session/checkpoint/service/proxy structs;
- small CLI/API adapters that can be optional or split packages;
- no RunicAI- or Libbit-specific persistence assumptions.

### What belongs in RunicAI

- model-visible tool definitions;
- review gates;
- Workbench settings;
- trace and terminal event mapping;
- local developer defaults.

### What belongs in Libbit

- mapping workspace ids to sandbox sessions;
- workspace-local persistence of sandbox metadata;
- policy rules for users/agents/workflows;
- integration with `WorkspaceRunner`, journal, event store, projections, and
  workspace tools;
- cloud provisioning defaults;
- tenant quotas and billing/usage boundaries.

## Libbit Integration Sketch

Libbit should introduce a capability layer above `Core.Infrastructure.Provider`:

```text
Core.Agents / Workspace tools / durable workflows
  -> Core.Platform.SandboxSessions
  -> RunicSandbox
  -> backend adapter
  -> Fly Machines / Sprites / vmsan / Docker / Firecracker
```

Potential Libbit modules:

```elixir
Core.Platform.SandboxSessions
Core.Platform.SandboxPolicy
Core.Platform.SandboxLease
Core.Platform.SandboxEvents
Core.Platform.SandboxArtifacts
Core.Platform.SandboxProviders.RunicSandbox
```

Libbit's existing `Core.Infrastructure.Provider` should remain responsible for
workspace infrastructure. `Core.Platform.SandboxSessions` should be responsible
for sandbox intent and stateful agent/workflow usage.

That split keeps these questions separate:

- "Do we need a Fly App, volume, token, or machine?"
- "Does this agent need a writable checkpointable workspace sandbox?"
- "Can this workflow run mutate the service sandbox right now?"
- "What artifacts/checkpoints/proxies should the user review?"

## Implementation Plan

The implementation center is `packages/runic_sandbox`. RunicAI integration is in
scope because it validates the library through real tool/workbench/RLM usage.
Libbit implementation is out of scope for this pass; Libbit appears only as a
consumer model and contract pressure test.

Each phase should end with:

- a focused implementation diff;
- unit tests for new contracts and adapter normalization;
- one realistic manual smoke when the backend can run locally or with
  credentials;
- `mix compile --warnings-as-errors`;
- package tests under `packages/runic_sandbox`;
- a short completion note appended to this document;
- an architecture/code review by a separate subagent before the next phase.

### Phase 0: Preflight, Asset Discovery, And Harnesses

Goal: make the machine and provider readiness visible as structured data before
adding new behavior.

Deliverables:

- [x] Add `RunicSandbox.HostProbe` or equivalent helper that reports:
      OS, architecture, virtualization flags, `/dev/kvm`, ACL/group access,
      loaded KVM modules, Docker runtime inventory, vmsan executable/version,
      sprite executable/version/auth, and required provider env vars.
- [x] Add a `RunicSandbox.BackendHealth` struct if the existing health maps are
      becoming too loose.
- [x] Extend `RunicSandbox.Reports.health_matrix/1` to include:
      `transport_model`, `state_model`, `capabilities`, `missing_requirements`,
      and `next_action`.
- [x] Add a `mix runic_sandbox.doctor` task that prints text and JSON.
- [x] Parse `vmsan doctor --json` into structured diagnostics.
- [x] Parse `sprite --help`/auth readiness without exposing `SPRITE_TOKEN`.
- [x] Record current known machine state:
      KVM available; vmsan installed; vmsan runtime assets missing; sprite CLI
      available; `SPRITE_TOKEN` set.

Validation:

- [x] Unit tests for host probe normalization with fixture command outputs.
- [x] Unit tests for vmsan doctor JSON parsing, including missing Firecracker,
      jailer, agent, nftables, kernel, and rootfs diagnostics.
- [x] Unit tests proving secrets/env values are redacted.
- [x] Manual: `mix runic_sandbox.doctor --format json`.
- [x] Manual: doctor output correctly says vmsan is installed but unavailable
      for execution until assets are installed.

Parallelization:

- Subagent A can build the host-probe/parser tests.
- Subagent B can design the `BackendHealth`/report shape.
- Subagent C can review the health contract for provider leakage and security
  wording.

Exit gate:

- [x] No backend implementation may assume vmsan is ready just because `vmsan` is on
  `PATH`. It must use health capabilities.
- [x] Supervised execution and direct execution use the same profile
      authorization path for runtime, network, persistence, enabled profiles,
      and isolation policy.
- [x] Contract parsing avoids creating atoms from agent/user-provided strings.
- [x] Health summaries distinguish host availability, configuration, and
      execution readiness.
- [x] Docker one-shot workspaces are cleaned up after successful executions,
      failing executions, and file-preparation errors.
- [x] Remote/Fly execution defaults to explicit env-token credentials instead
      of ambient CLI auth; `credential_policy: :none` is not executable; broad
      health, report, snapshot, and result surfaces do not include provider app
      or machine identifiers.

Phase 0 evidence on 2026-05-25:

```sh
cd packages/runic_sandbox
mix test
mix compile --warnings-as-errors
mix runic_sandbox.doctor --format json
mix runic_sandbox.report --format json
mix run -e 'profile = RunicSandbox.Profile.new!(name: :local_code, backend: :docker, runtimes: [:bash], network: :disabled, image: "runic-ai/sandbox:elixir-python-node"); IO.inspect(RunicSandbox.exec([sandbox: :local_code, runtime: :bash, source: "printf docker-smoke", network: :disabled], profile: profile))'
cd ../..
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs test/runic_ai/coding/tools_test.exs
mix runic_sandbox.validate_standalone
git diff --check
```

Results:

```text
11 tests, 0 failures
compile --warnings-as-errors: passed
doctor: /dev/kvm exists and is readable/writable; vmsan 0.3.0 installed;
doctor: vmsan unavailable because disk_space, nftables_kernel, firecracker,
  jailer, vmsan_agent, vmsan_nftables, kernel_image, and rootfs_image are
  missing/failing;
doctor: sprite CLI available and SPRITE_TOKEN present, token value redacted.
report: just_bash, lua, and docker are execution-ready; gvisor is not ready
  because runsc is unavailable; remote_fly is not ready because provider config
  and auth are missing for the report fixture; health rows do not expose
  provider_config.
RunicAI focused tests: 61 tests, 0 failures.
standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
Docker real smoke: pass, stdout "docker-smoke", duration 285 ms.
Docker failing-command cleanup smoke: status fail, exit 42, tmp
  runic_sandbox directory count unchanged.
git diff --check: passed.
```

Senior review gate:

- Review finding: supervised execution bypassed direct-path profile
  authorization. Resolved by adding `RunicSandbox.authorize_request/2` and
  calling it from both direct execution and `RunicSandbox.Manager`.
- Review finding: contract modules created atoms from user-controlled strings.
  Resolved by using explicit enum normalization for known fields and
  existing-atom conversion only for config-time atom identifiers.
- Review finding: Docker workspaces were only cleaned up on the happy path.
  Resolved by wrapping one-shot workspace execution in an `after` cleanup path
  and cleaning one-shot directories when file preparation fails after partial
  writes.
- Review finding: remote execution could silently rely on ambient Fly CLI auth
  and returned provider configuration in result metadata. Resolved by adding an
  explicit credential policy defaulting to `:env_token`, making `:none`
  non-executable, surfacing missing auth as a requirement, and removing provider
  config from broad status/report/snapshot/result metadata.
- Review finding: backend health conflated host availability with execution
  readiness. Resolved by adding `host_available?`, `configured?`, and
  `exec_ready?` to backend health summaries and by treating missing Docker
  images as execution blockers.
- Remaining medium design item: split or rename the current Fly-specific
  `:remote` adapter when Phase 5 introduces Sprites/Fly lifecycle support.
  Until then it remains a local health/exec shim behind provider metadata, not
  a general remote runtime contract.

### Phase 1: Session Contract Foundation

Goal: add the stable stateful-session layer before vmsan snapshots or Sprites
force provider-specific abstractions into `ExecutionRequest`.

Deliverables:

- [x] Add structs:
      `RunicSandbox.Session`, `Capabilities`, `FileRef`, `Checkpoint`,
      `Service`, `Proxy`, `Lease`, and `SessionEvent`.
- [x] Add backend behaviour callbacks with default unsupported responses:
      `open_session/2`, `close_session/2`, `exec_session/3`,
      `write_file/4`, `read_file/3`, `list_files/3`, `delete_file/3`,
      `checkpoint/3`, `restore/3`, `start_service/3`, `stop_service/3`,
      `list_services/2`, `open_proxy/3`, `close_proxy/2`,
      `acquire_lease/3`, and `release_lease/2`.
- [x] Add public facade functions while preserving existing `exec/2`:

  ```elixir
  RunicSandbox.open_session(:local_code, spec, opts)
  RunicSandbox.exec(session, request, opts)
  RunicSandbox.write_file(session, path, contents, opts)
  RunicSandbox.checkpoint(session, opts)
  RunicSandbox.restore(session, checkpoint, opts)
  RunicSandbox.close_session(session, opts)
  ```

- [x] Add a fake backend used only for contract tests.
- [x] Add compatibility adapters so JustBash/Lua continue to work as one-shot
      backends with truthful `capabilities.exec? == true` and
      `capabilities.checkpoints? == false`.
- [x] Add session metadata fields for:
      `isolation_level`, `state_model`, `transport_model`,
      `persistent_identity?`, `workspace_ref`, `policy`, and a signed authority
      snapshot.

Validation:

- [x] Unit tests for struct validation and unsupported capability responses.
- [x] Contract tests proving every backend health report includes capability
      metadata.
- [x] Backward compatibility: current `RunicSandbox.exec/2` tests still pass.
- [x] `mix runic_sandbox.validate_standalone` still passes.

Parallelization:

- Subagent A can implement structs and validation.
- Subagent B can update backend behaviour and fake backend tests.
- Subagent C can review API naming for leaky provider concepts.

Exit gate:

- [x] A caller can distinguish one-shot exec, persistent workspace session,
  checkpointable session, service-capable session, and proxy-capable session
  without knowing the backend provider.
- [x] Public session operations verify a facade-issued authority snapshot before
      trusting policy, capabilities, lifecycle state, or embedded backend
      identity.
- [x] Session close revokes the facade-issued authority record so a previously
      ready handle cannot be reused after close.
- [x] Session operations reject non-ready sessions before dispatching to
      backend callbacks.
- [x] `open_session/3` uses the same enabled/isolation policy gate for direct
      and supervised profiles.

Phase 1 evidence on 2026-05-25:

```sh
cd packages/runic_sandbox
mix test
mix compile --warnings-as-errors
mix runic_sandbox.report --format json
mix run -e 'profile = RunicSandbox.Profile.new!(name: :local_code, backend: :docker, runtimes: [:bash], network: :disabled, image: "runic-ai/sandbox:elixir-python-node"); {:ok, session} = RunicSandbox.open_session(:local_code, [], profile: profile); IO.inspect({session.backend, session.state_model, session.capabilities.exec?, session.capabilities.session_files?, session.capabilities.inline_files?}); IO.inspect(RunicSandbox.exec(session, runtime: :bash, source: "printf session-docker-smoke")); forged = put_in(session.policy.network, :host); IO.inspect(RunicSandbox.exec(forged, runtime: :bash, source: "printf forged", network: :host)); IO.inspect(RunicSandbox.close_session(session))'
mix run -e 'profile = RunicSandbox.Profile.new!(name: :local_code, backend: :just_bash, runtimes: [:bash], network: :disabled); {:ok, session} = RunicSandbox.open_session(:local_code, [], profile: profile); IO.inspect({session.backend, session.state_model, session.capabilities.exec?, session.capabilities.checkpoints?}); IO.inspect(RunicSandbox.exec(session, runtime: :bash, source: "echo session-just-bash-smoke")); IO.inspect(RunicSandbox.checkpoint(session)); IO.inspect(RunicSandbox.close_session(session))'
cd ../..
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs test/runic_ai/coding/tools_test.exs
mix runic_sandbox.validate_standalone
git diff --check
```

Results:

```text
RunicSandbox package tests: 18 tests, 0 failures.
Package compile --warnings-as-errors: passed.
RunicAI focused tests: 61 tests, 0 failures.
Standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
Report health rows expose capability metadata for just_bash, lua, docker,
  gvisor, and remote_fly; remote_fly state_model is `persistent_workspace`,
  not a provider-specific state model.
Docker session smoke: session tuple {:docker, :one_shot, true, false, true};
  mutating the session policy caused
  `sandbox session authority snapshot does not match the handle`; execution
  passed with stdout "session-docker-smoke"; close_session returned :ok; a
  post-close exec returned `sandbox session authority is not active`.
JustBash session smoke: session tuple {:just_bash, :one_shot, true, false};
  execution passed with stdout "session-just-bash-smoke\n"; checkpoint returned
  a structured unsupported error; close_session returned :ok.
git diff --check: passed.
```

Senior review gate:

- Review finding: public session operations trusted caller-supplied `%Session{}`
  fields as policy authority. Resolved by adding a facade-issued signed
  authority snapshot to sessions returned from `RunicSandbox.open_session/3`
  and verifying it before dispatching public session operations. The signing
  path is not exported as `Session.reseal/1` or `SessionAuthority.seal/1`.
- Review finding: closing a session did not invalidate an existing ready
  handle. Resolved by storing active authority records in an internal registry
  and revoking the record on `close_session/2`; post-close reuse fails before
  backend dispatch.
- Review finding: `open_session/3` bypassed supervised profiles and isolation
  policy. Resolved by routing `server:` through `RunicSandbox.Manager` and
  applying enabled/isolation checks before opening direct or supervised
  sessions.
- Review finding: lifecycle state was not enforced. Resolved by rejecting
  non-ready sessions before execution, file, checkpoint, service, proxy, and
  lease operations.
- Review finding: proxy and lease handles were not self-routing. Resolved by
  requiring backend identity in `RunicSandbox.Proxy` and `RunicSandbox.Lease`
  and using it in `close_proxy/2` and `release_lease/2`.
- Review finding: file capability semantics conflated inline request files with
  session filesystem APIs. Resolved by adding `inline_files?`, `artifacts?`,
  and `session_files?`; Docker now reports inline files/artifacts but not
  session file APIs until Phase 2 implements them.
- Review finding: backend health used a provider-specific state model for
  remote. Resolved by normalizing the health summary state model to
  `:persistent_workspace`.
- Remaining medium design item: runtime identity is still atom-based for
  existing compatibility. Before exposing user-defined runtime IDs beyond
  configured profiles, add an explicit runtime registry or binary runtime-id
  contract.

### Phase 2: Docker Session Baseline

Goal: prove the new session layer against the existing Docker backend before
vmsan or Sprites add more moving parts.

Deliverables:

- [x] Map existing Docker persistent workspace support to `open_session/2` and
      `close_session/2`.
- [x] Implement Docker `exec_session/3` with multi-runtime support already used
      by one-shot Docker.
- [x] Implement Docker filesystem APIs against the managed workspace directory.
- [x] Implement Docker checkpoint as filesystem snapshot/copy, clearly marked
      as `kind: :filesystem`, not VM snapshot.
- [x] Implement Docker restore from filesystem checkpoint.
- [x] Add no-op/unsupported service and proxy responses with explicit
      diagnostics unless Docker service support is deliberately added in a later
      phase.

Validation:

- [x] Unit/integration test: write file, exec, read file across the same
      session.
- [x] Integration test: checkpoint, mutate, restore, verify prior contents.
- [x] Integration test: Python, Node, Elixir, Lua, and Bash execute in a Docker
      session when the default image exists.
- [x] Manual: `mix runic_ai.sandbox.image --no-build` still passes.
- [x] Manual: the `RunicAI.Sandbox` compatibility facade can target the Docker
      session path.
- [x] Manual: a RunicAI `execute_code` profile can select the Docker backend.
      Holding a persistent session handle inside `execute_code` remains Phase 4
      capability-profile integration work.

Parallelization:

- Subagent A can implement filesystem/session semantics.
- Subagent B can implement checkpoint/restore.
- Subagent C can review cleanup, temp-dir lifetime, and host-write safety.

Exit gate:

- [x] The session API is proven on the least surprising stateful backend before
  stronger isolation adapters are added.

Phase 2 evidence on 2026-05-25:

```sh
cd packages/runic_sandbox
mix test
mix compile --warnings-as-errors
cd ../..
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs test/runic_ai/coding/tools_test.exs
mix runic_sandbox.validate_standalone
mix runic_sandbox.report --format json
mix runic_ai.sandbox.image --no-build
git diff --check
```

Results:

```text
RunicSandbox package tests: 23 tests, 0 failures.
Package compile --warnings-as-errors: passed.
RunicAI focused tests: 143 tests, 0 failures.
Root compile --warnings-as-errors: passed.
Standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
Sandbox report: Docker is available with `capabilities.session_files? == true`
  and `capabilities.checkpoints? == true`; gVisor remains unavailable because
  the Docker `runsc` runtime is not registered.
Image smoke: bash, python, node, elixir, and lua returned ok in
  `runic-ai/sandbox:elixir-python-node`.
Docker session smoke through `RunicSandbox`: open session, Python exec,
  read file, checkpoint, mutate, restore, post-restore read, close, and
  post-close authority rejection all behaved as expected.
Docker session smoke through `RunicAI.Sandbox`: facade open_session,
  write_file, exec, checkpoint, restore, read_file, and close all passed.
RunicAI execute_code smoke: Python code executed through the Docker backend
  with `sandbox_backend: :docker` and `isolation_level: :container`.
Hostile Docker smoke: symlink reads are rejected, symlink-created container
  artifacts are not surfaced, forged session metadata is rejected by the
  session authority snapshot, forged filesystem checkpoints are rejected, and
  post-close handles remain inactive. Path-shaped checkpoint ids are sanitized
  before host paths are created and do not remove escaped sentinel directories.
  Path-shaped session ids are also sanitized before host checkpoint paths are
  created.
git diff --check: passed.
```

Implementation notes:

- Docker sessions coerce the profile to `stateful?: true` and
  `workspace.persist?: true` for the managed session lifetime while preserving
  one-shot Docker execution semantics for `RunicSandbox.exec/2`.
- Docker filesystem APIs operate only inside the managed workspace root and
  reject paths that escape that root.
- Docker checkpoints are explicit filesystem snapshots. They do not claim VM or
  microVM snapshot semantics, which keeps the provider-neutral checkpoint
  contract honest for future vmsan, Firecracker, and Sprites adapters.
- `RunicAI.Sandbox` now delegates the new session API as a compatibility facade;
  newer RunicAI code may still call `RunicSandbox` directly when that is clearer.
- Restored sessions returned by `RunicSandbox.restore/3` are sealed and
  registered by the public facade before callers receive them.
- The session authority snapshot now includes `session.metadata`, because the
  Docker backend uses metadata for managed workspace identity.
- Docker host-side file handling uses `File.lstat/1` style checks and rejects
  symlink-bearing paths before host reads, writes, deletes, checkpoint copies,
  artifact previews, and restore copies.
- Docker filesystem checkpoints include backend-private authority metadata so a
  caller cannot forge an arbitrary `/tmp` checkpoint path and restore it into a
  live session.
- Docker filesystem checkpoint ids are sanitized before path construction so a
  caller cannot shape the host checkpoint root or make checkpoint creation call
  `rm_rf` outside the intended namespace.
- Docker session ids are sanitized before host checkpoint path construction for
  the same reason; public session identity remains unchanged, but filesystem
  path segments are backend-controlled.
- `RunicAI.Coding.Tools.execute_code/4` converts `RunicSandbox.Error` into
  `RunicAI.Error` before building blocked `CommandResult` values.
- Capability and RLM sandbox profile config no longer force Docker-selected
  profiles to `:in_process_virtual`; backend default isolation is preserved
  unless an explicit `isolation_level` is configured.
- The `execute_code` tool definition metadata is derived from configured
  sandbox opts, so Docker-backed capability profiles advertise `:docker` and
  `:container` instead of the default JustBash metadata.

Senior review gate:

- Review finding: Docker workspace symlinks could escape the sandbox during
  host-side artifact/file handling. Resolved by rejecting symlink-bearing paths
  and walking/listing only `lstat`-regular files and directories.
- Review finding: Docker trusted unsigned `session.metadata[:workspace_root]`.
  Resolved by adding `session.metadata` to the signed session authority
  snapshot and adding a forged-metadata regression.
- Review finding: `execute_code` crashed on `%RunicSandbox.Error{}`. Resolved
  by converting sandbox errors at the RunicAI tool boundary before calling
  `CommandResult.blocked/3`.
- Review finding: Docker filesystem checkpoints could be forged under `/tmp`.
  Resolved by adding backend-private checkpoint authority and restore
  validation.
- Review finding: Docker selected through capability config reported the wrong
  isolation level. Resolved by preserving backend default isolation and moving
  explicit `isolation_minimum` into profile policy.
- Re-review finding: Docker checkpoint creation accepted path-shaped
  `spec[:id]`. Resolved by sanitizing checkpoint ids before constructing host
  checkpoint paths and adding a sentinel regression.
- Final review finding: path-shaped session ids could still shape Docker
  checkpoint host paths. Resolved by sanitizing session ids before constructing
  checkpoint path segments and adding a sentinel regression.
- Re-review finding: Docker-backed code execution still exposed misleading
  tool/capability metadata. Resolved by deriving `execute_code` tool metadata
  from the effective sandbox opts and by removing the default
  `isolation_minimum` value from merged code-execution config.

### Phase 3: vmsan Local MicroVM Backend

Goal: implement low-latency local microVM execution through vmsan without owning
raw Firecracker lifecycle directly.

Current host note on 2026-05-25:

- `vmsan --version` reports `0.3.0`.
- `vmsan doctor --json` reports `/dev/kvm` and `/dev/net/tun` passing.
- The same doctor run still fails seven requirements:
  `nftables_kernel`, `firecracker`, `jailer`, `vmsan_agent`,
  `vmsan_nftables`, `kernel_image`, and `rootfs_image`.
- Therefore Phase 3 can implement CLI wrapping, parser behavior, unavailable
  diagnostics, and non-VM tests immediately, but real VM create/exec/upload/
  download/checkpoint smoke must remain gated until those assets are installed.

Deliverables:

- [x] Add `RunicSandbox.Backends.Vmsan`.
- [x] Add a small vmsan CLI wrapper module with argv-only command construction.
- [x] Support `status/1` via host probe plus `vmsan doctor --json`.
- [x] Support `open_session/2` via `vmsan create --json` once assets are
      installed.
- [x] Support `exec_session/3` via `vmsan exec`.
- [x] Support `write_file`/`upload` via `vmsan upload`.
- [x] Support `read_file`/`download` via `vmsan download`.
- [x] Support network policy via `vmsan network --network-policy`.
- [x] Support checkpoint/restore via `vmsan snapshot` if the CLI exposes stable
      create/restore/list semantics.
- [x] Add structured unavailable diagnostics for missing:
      Firecracker, jailer, agent, nftables helper, kernel image, rootfs image,
      `/dev/net/tun`, `/dev/kvm`, or root privileges when required.
- [x] Decide whether vmsan operations must run through `sudo env "PATH=$PATH"`
      and encode that as explicit profile config, not hidden magic.

Validation:

- [x] Unit tests for command argv construction.
- [x] Unit tests for JSON event parsing and error normalization.
- [x] Unit tests for missing asset diagnostics from current machine fixture.
- [x] Manual: `vmsan doctor --json` reported through
      `mix runic_sandbox.doctor`.
- [ ] Manual once assets exist: create session, upload a file, execute Bash,
      execute at least two non-Bash runtimes, download an artifact, destroy
      session.
- [ ] Manual if supported: deny-all network policy blocks egress; allowlist
      policy permits one domain.
- [ ] Manual if supported: checkpoint, mutate filesystem, restore, verify.

Parallelization:

- Subagent A can implement CLI wrapper and parser.
- Subagent B can implement backend callbacks.
- Subagent C can prepare manual smoke scripts and fixture outputs.
- Subagent D can review privilege boundaries and cleanup failure modes.

Exit gate:

- [x] RunicSandbox can truthfully report vmsan unavailable on partial installs.
- [x] Mocked healthy lifecycle covers create, upload, exec, snapshot, privileged
  cleanup, and transfer-root cleanup.
- [ ] Real healthy-host VM smoke proves RunicSandbox can run code once vmsan
  doctor passes on this machine.

Phase 3 evidence on 2026-05-25:

```sh
cd packages/runic_sandbox
mix test
mix compile --warnings-as-errors
cd ../..
mix compile --warnings-as-errors
mix test test/runic_ai/coding/tools_test.exs test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/sandbox_test.exs
mix run -e 'profile = RunicSandbox.Profile.new!(name: :local_code, backend: :vmsan, runtimes: [:bash], network: :disabled); IO.inspect(RunicSandbox.status(profile: profile), limit: :infinity); IO.inspect(RunicSandbox.open_session(:local_code, [], profile: profile), limit: :infinity)'
mix runic_sandbox.report --format json
mix runic_sandbox.doctor --format json
mix runic_sandbox.validate_standalone
git diff --check
```

Results:

```text
RunicSandbox package tests: 27 tests, 0 failures.
Package compile --warnings-as-errors: passed.
RunicAI focused tests: 46 tests, 0 failures.
Root compile --warnings-as-errors: passed.
Standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
vmsan status smoke: reports backend `:vmsan`, isolation `:microvm`,
  transport `:local_microvm`, state model `:checkpointable`, session files and
  checkpoints supported, and security boundary true.
vmsan unavailable execution smoke: `RunicSandbox.open_session/3` returns a
  structured validation error instead of attempting VM creation while doctor is
  failing.
Current host doctor: `/dev/kvm`, `/dev/net/tun`, disk space, default interface,
  host firewall, and jailer filesystem pass; `nftables_kernel`, `firecracker`,
  `jailer`, `vmsan_agent`, `vmsan_nftables`, `kernel_image`, and `rootfs_image`
  remain missing.
Report/doctor output includes the vmsan backend row and missing requirements.
git diff --check: passed.
```

Implementation notes:

- `:vmsan` is now a valid RunicSandbox backend with default isolation
  `:microvm`.
- `RunicSandbox.VmsanCLI` owns argv construction and parses the trailing
  JSON event emitted by `vmsan --json`, keeping stream output separate from
  command metadata.
- `RunicSandbox.Backends.Vmsan` maps RunicSandbox sessions to vmsan VM ids and
  supports create, exec, upload, download, network-policy argv construction,
  snapshot create, and remove through the CLI wrapper.
- vmsan `sudo` is explicit profile/backend configuration (`sudo?: true`) and is
  not ambient magic. The CLI wrapper then uses non-interactive
  `sudo -n env "PATH=$PATH" vmsan ...` for lifecycle operations that need it.
- One-shot vmsan execution now creates a VM instead of fabricating a session
  from a health-only instance, uploads inline request files before execution,
  applies the request timeout to the CLI call, and cleans up the VM and
  transfer directory after success or failure.
- Relative inline request files are mapped under the request working directory
  before upload. A provider-neutral `files: %{"in.txt" => "..."}` request with
  `cwd: "/workspace"` therefore lands at `/workspace/in.txt` inside the VM.
- Session file transfers use per-session, randomly suffixed, 0700 host transfer
  directories; transfer paths reject lexical escapes and symlink-shaped paths.
- Unsupported request features are fail-closed instead of silently ignored:
  non-empty `stdin` currently returns a structured validation error until the
  CLI contract for stdin is explicit.
- Real VM execution remains gated until doctor is healthy on this host.

Review findings resolved in Phase 3:

- Critical: vmsan one-shot execution provisioned only a health-derived instance
  and then attempted `vmsan exec` against a VM id that had never been created.
  Resolved by making one-shot `exec/3` open a real vmsan session, execute, and
  close it.
- High: vmsan execution silently ignored inline files and request timeouts.
  Resolved by uploading request files through the session file path before exec
  and by passing `request.timeout_ms` into the vmsan CLI wrapper.
- High: host transfer paths used predictable temp roots without symlink
  hardening or cleanup. Resolved by per-session transfer roots, symlink checks,
  regular-file checks for downloads, and cleanup on close.
- High: sudo/root boundaries were incomplete and could hang on password
  prompts. Resolved by persisting lifecycle sudo/executable choices on the
  session and using `sudo -n`.
- Medium: nonzero vmsan exits with trailing JSON could be misclassified as
  success. Resolved by treating nonzero status as an error unless the CLI
  returned a structured provider error.
- Medium: Phase 3 evidence overstated real healthy-host coverage. Resolved by
  splitting the exit gate into current-host unavailable reporting, mocked
  healthy lifecycle coverage, and a still-open real VM smoke once assets exist.
- Re-review finding: relative inline file keys uploaded to `/` instead of the
  request working directory, which blocked honest Phase 4 `execute_code` parity.
  Resolved by mapping relative request file paths under `request.cwd` and adding
  a regression that uses `files: %{"in.txt" => "hello"}` with code reading from
  `/workspace/in.txt`.
- Re-review finding: one-shot cleanup failures were discarded after successful
  execution. Resolved by returning a structured cleanup failure containing both
  the successful execution result and cleanup error.
- Re-review finding: VM cleanup after create-success/session-build-failure was
  not guarded. Resolved by removing the VM if session construction fails after
  `vmsan create` succeeds.
- Final re-review finding: inline request file paths still allowed guest
  workdir escapes through `..` and absolute guest writes. Resolved by treating
  inline request files as cwd-relative only, rejecting absolute keys and any
  path that expands outside `request.cwd`.
- Final Phase 3 review: no remaining Critical, High, or Medium findings in the
  focused vmsan slice. Phase 3 is exit-ready for implementation purposes, with
  the real VM smoke still correctly gated on a healthy vmsan host.

### Phase 4: RunicAI Capability Profile Integration

Goal: make vmsan and session-backed execution selectable through ordinary
RunicAI surfaces.

Deliverables:

- [x] Extend capability profile sandbox config to include:
      `state_model`, `transport_model`, `session: :one_shot | :workspace |
      :run`, `checkpoint_policy`, and `service_policy`.
- [x] Ensure `execute_code` can choose Docker, vmsan, or Sprites by profile
      without backend-specific tool definitions.
- [x] Ensure RLM script nodes use the same profile resolution path.
- [x] Extend review details for:
      microVM execution, persistent sessions, checkpoint restore, network
      policy changes, service start, proxy open, and host export.
- [x] Extend trace events with session id, checkpoint id, service/proxy ids, and
      capability metadata.
- [ ] Extend Workbench settings/status to show session health and vmsan doctor
      diagnostics.

Validation:

- [x] Capability resolver tests for Docker session, vmsan, and Sprites profile
      shapes.
- [x] Tools tests for backend/profile selection and review metadata.
- [x] Trace event tests for session/checkpoint fields.
- [x] RLM workflow compiler test for script node sandbox metadata.
- [ ] Workbench tests for health/status rendering.
- [ ] Manual: RunicAI tool smoke through vmsan when healthy; otherwise verify
      blocked diagnostic is visible and repairable.

Parallelization:

- Subagent A can update capability/profile tests.
- Subagent B can update tools/review/trace.
- Subagent C can update Workbench status.
- Subagent D can do senior review for user-facing policy clarity.

Exit gate:

- Agents can request code execution through existing RunicAI tool paths and get
  a truthful result whether the selected backend runs, blocks, or is
  unavailable.

Phase 4 slice evidence on 2026-05-25:

```sh
mix format packages/runic_sandbox/lib/runic_sandbox.ex packages/runic_sandbox/lib/runic_sandbox/sandbox/manager.ex packages/runic_sandbox/lib/runic_sandbox/sandbox/backends/vmsan.ex lib/runic_ai/agent/capability_resolver.ex lib/runic_ai/coding/rlm/workflow_compiler.ex lib/runic_ai/coding/tools.ex lib/runic_ai/agent/tool_execution.ex lib/runic_ai/coding/review_gate.ex test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs
mix test test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs
mix test test/runic_ai/coding/tools_test.exs test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/sandbox_test.exs test/runic_ai/coding/rlm_agent_test.exs
mix compile --warnings-as-errors
cd packages/runic_sandbox && mix test && mix compile --warnings-as-errors
git diff --check
```

Results:

```text
Capability/tools focused tests: 38 tests, 0 failures.
RunicAI focused sandbox/RLM tests: 120 tests, 0 failures.
Root compile --warnings-as-errors: passed.
RunicSandbox package tests: 27 tests, 0 failures on isolated rerun.
RunicSandbox package compile --warnings-as-errors: passed.
git diff --check: passed.
```

Implementation notes:

- Capability profile `code_execution` config now carries state/session fields
  through `sandbox_opts.profile.metadata` instead of adding backend-specific
  RunicAI tool definitions.
- RLM script nodes use the same code-execution profile mapping, including
  flattened backend options for Docker/vmsan/Sprites-style adapters.
- `execute_code` tool metadata, command-result metadata, and sandbox trace
  event metadata expose backend, isolation, state model, transport model,
  session mode, checkpoint policy, and service policy.
- Review requests include sandbox capability metadata so human review can
  distinguish in-process execution, containers, local microVMs, remote
  microVM/service actors, checkpoint actions, proxy/service ids, and network
  policy escalation.
- RunicSandbox status now includes profile metadata so Workbench/status surfaces
  have a stable place to render session and state-shape configuration.

Review findings resolved in Phase 4:

- High: invalid configured sandbox backends could fall back to `:just_bash`,
  weakening the selected isolation boundary. Resolved by preserving unknown
  backend/runtime values and validating generated sandbox profiles before
  building the capability registry.
- High: blocked/unavailable `execute_code` results dropped sandbox capability
  metadata. Resolved by allowing `CommandResult.blocked/3` to receive metadata
  and by attaching sandbox capability metadata to blocked command results and
  blocked trace output.
- Re-review finding: invalid sandbox profile validation returned
  `%RunicSandbox.Error{}` through a RunicAI resolver boundary, causing
  `resolve!/2` to crash with `CaseClauseError`. Resolved by normalizing
  sandbox validation errors into `%RunicAI.Error{}` and adding `resolve!/2`
  coverage.
- Final Phase 4 review: no remaining Critical, High, or Medium findings in the
  capability-profile integration slice.

### Phase 5: Sprites Remote Stateful Adapter

Goal: implement a hosted stateful sandbox backend that exercises files,
checkpoints, services, and proxies.

Deliverables:

- [x] Add `RunicSandbox.Backends.Sprites`.
- [x] Add profile config:
      `provider: :sprites`, `token_env: "SPRITES_TOKEN"`, `organization`,
      `sprite`, `image` or template if supported, timeout, hibernate policy.
- [x] Support status without leaking token values.
- [x] Support `open_session/2` by using existing sprite selection or creating a
      new named sprite according to profile policy.
- [x] Support `exec_session/3` through the Sprites HTTP exec API.
- [x] Support filesystem read/write/list/delete through the Sprites HTTP
      filesystem API.
- [x] Support checkpoint/restore through `sprite checkpoint create` and
      `sprite restore`.
- [x] Support service create/list/stop through the Sprites HTTP services API.
- [x] Support proxy metadata through `sprite proxy` and `sprite url` where
      feasible.
- [x] Add API/CLI boundary tests with fixtures rather than requiring live
      credentials in CI.
- [ ] Add live smokes guarded by `RUNIC_SANDBOX_SPRITES_SMOKE=1`.

Validation:

- [x] Unit tests for API output parsing.
- [x] Unit tests for token redaction.
- [ ] Live smoke: create/use sprite, exec command, write/read file path if CLI
      supports it directly or through shell, checkpoint, restore, destroy or
      leave according to cleanup policy.
- [ ] Live smoke: service/proxy if supported in the current CLI/API.
- [x] Report task includes Sprites status and next actions.

Phase 5 slice evidence on 2026-05-25:

```sh
cd packages/runic_sandbox && mix test && mix compile --warnings-as-errors
mix compile --warnings-as-errors
mix test test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/sandbox_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/workbench_test.exs
mix run -e 'profile = RunicSandbox.Profile.new!(name: :sprites_code, backend: :sprites, runtimes: [:bash], network: :restricted, backend_options: %{sprite: "runic-test"}); IO.inspect(RunicSandbox.status(profile: profile), limit: :infinity); IO.inspect(RunicSandbox.open_session(:sprites_code, [], profile: profile), limit: :infinity)'
mix runic_sandbox.report --format json
mix runic_sandbox.validate_standalone
git diff --check
```

Results:

```text
RunicSandbox package tests: 30 tests, 0 failures.
RunicSandbox package compile --warnings-as-errors: passed.
RunicAI focused sandbox/RLM/Workbench tests: 146 tests, 0 failures.
Root compile --warnings-as-errors: passed.
Sprites status smoke without SPRITES_TOKEN: reports unavailable with
  token_value redacted, token_env shown as SPRITES_TOKEN, backend
  remote_microvm, state_model service_actor, session files/checkpoints/services
  and proxy capabilities true.
Sprites open_session smoke without SPRITES_TOKEN: returns structured validation
  error with token_value redacted.
Report output includes Sprites backend rows and missing auth requirement.
Standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
git diff --check: passed.
```

Review findings resolved in Phase 5:

- Review finding: direct one-shot `RunicSandbox.exec/2` did not pass adapter
  opts into Sprites, so injected requesters/env and Sprites create policies were
  only honored by explicit sessions. Resolved by using a sealed session-backed
  one-shot path for Sprites and preserving adapter opts through direct
  provision/exec.
- Review finding: host readiness checked `SPRITE_TOKEN` while the adapter
  defaulted to `SPRITES_TOKEN`. Resolved by aligning host probe diagnostics and
  status metadata on `SPRITES_TOKEN`, with profile-level overrides still
  supported by the adapter.
- Review finding: malformed provider exit status strings could raise during
  Sprites exec parsing. Resolved by returning a structured RunicSandbox
  validation error for invalid provider status values.
- Final Phase 5 review: no remaining Critical, High, or Medium findings in the
  Sprites adapter slice.

Implementation notes:

- The base Sprites adapter uses the documented HTTP API for create/get/delete
  sprite, non-TTY exec, filesystem read/write/list/delete, checkpoints,
  restore, and services.
- WebSocket exec/proxy streaming is intentionally represented as session/proxy
  metadata in this base adapter. A future split adapter can own persistent
  streaming transports.
- Live API calls are behind normal profile configuration and token env policy;
  tests use an injectable requester and do not require live credentials.
- The adapter supports `create_policy: :use_existing | :verify_existing |
  :create | :create_if_missing | :ephemeral`; ephemeral sessions delete the
  sprite on close.
- Inline request files are cwd-relative and reject absolute paths or `..`
  escapes before upload, matching the vmsan request-file policy.
- The default token env is `SPRITES_TOKEN`, matching the Sprites quick-start
  export. Profiles can override `token_env` for environments using
  `SPRITE_TOKEN`.

Parallelization:

- Subagent A can implement config/status/redaction.
- Subagent B can implement exec/checkpoint.
- Subagent C can implement proxy/service modeling.
- Subagent D can review remote-provider credential and cleanup policy.

Exit gate:

- Sprites is usable as a stateful remote RunicSandbox session without embedding
  Sprites-specific assumptions in RunicAI tools.

### Phase 6: Low-Latency Pooling And Session Lifecycle

Goal: make the powerful backends feel usable for agents by avoiding cold-start
cost on every tool call.

Deliverables:

- [x] Add pool configuration:
      `warm`, `max`, `idle_ttl_ms`, `checkout_timeout_ms`, `reset_on_checkin?`,
      `checkpoint_on_checkout?`, `backend_affinity`.
- [x] Add session checkout/checkin APIs or manager internals:
      `acquire_session/2`, `release_session/2`, and `reset_session/2`.
- [x] Add per-session leases for Libbit-style multi-agent/workflow concurrency.
- [x] Add cleanup/reaper process for crashed or abandoned sessions.
- [x] Add latency report rows for:
      cold open, warm checkout, exec, checkpoint, restore, reset, close.
- [ ] Add failure policy:
      destroy dirty session, restore baseline checkpoint, or quarantine for
      inspection.

Validation:

- [x] Manager tests for max pool size and checkout timeout.
- [x] Dirty session reset tests.
- [x] Latency report before/after warm pool.
- [x] Manual: just_bash warm-session loop through the supervised facade.
- [x] Manual: Docker warm-session loop with repeated execs.

Phase 6 slice evidence on 2026-05-25:

```sh
cd packages/runic_sandbox && mix test && mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/workbench_test.exs
mix compile --warnings-as-errors
mix run -e 'name = :runic_pool_smoke; {:ok, _} = RunicSandbox.start_link(name: name, sandboxes: [local_code: [backend: :just_bash, runtimes: [:bash], pool: [warm: 1, max: 1], network: :disabled]]); {:ok, before_status} = RunicSandbox.status(server: name); {:ok, session} = RunicSandbox.acquire_session(:local_code, [], server: name); {:ok, lease} = RunicSandbox.acquire_lease(session, "workspace", server: name); conflict = RunicSandbox.acquire_lease(session, "workspace", server: name); release_blocked = RunicSandbox.release_session(session, server: name); :ok = RunicSandbox.release_lease(lease, server: name); exhausted = RunicSandbox.acquire_session(:local_code, [], server: name); :ok = RunicSandbox.release_session(session, server: name); {:ok, after_status} = RunicSandbox.status(server: name); IO.inspect(%{before: before_status.sandboxes.local_code.sessions, acquired: session.id, lease: lease.id, conflict: conflict, release_blocked: release_blocked, exhausted: exhausted, after: after_status.sandboxes.local_code.sessions}, limit: :infinity)'
mix runic_sandbox.validate_standalone
git diff --check
mix run -e 'name = :runic_docker_pool_smoke; {:ok, _} = RunicSandbox.start_link(name: name, sandboxes: [local_code: [backend: :docker, image: "runic-ai/sandbox:elixir-python-node", runtimes: [:bash], pool: [warm: 1, max: 1], network: :disabled, workspace: [mode: :copy_in, persist?: true]]]); {:ok, status0} = RunicSandbox.status(server: name); {:ok, session} = RunicSandbox.acquire_session(:local_code, [], server: name); {:ok, first} = RunicSandbox.exec(session, runtime: :bash, source: "printf first > /workspace/warm.txt && cat /workspace/warm.txt"); :ok = RunicSandbox.release_session(session, server: name); {:ok, session2} = RunicSandbox.acquire_session(:local_code, [], server: name); {:ok, second} = RunicSandbox.exec(session2, runtime: :bash, source: "cat /workspace/warm.txt && printf :second"); :ok = RunicSandbox.close_session(session2, server: name); {:ok, status1} = RunicSandbox.status(server: name); IO.inspect(%{initial_sessions: status0.sandboxes.local_code.sessions, reused?: session.id == session2.id, first: first.stdout, second: second.stdout, final_sessions: status1.sandboxes.local_code.sessions}, limit: :infinity)'
```

Results:

```text
RunicSandbox package tests: 37 tests, 0 failures.
RunicSandbox package compile --warnings-as-errors: passed.
RunicAI focused sandbox/RLM/Workbench tests: 146 tests, 0 failures.
Root compile --warnings-as-errors: passed.
Manual supervised pool smoke: managed open_session reused the preopened session,
  second open hit a retryable pool-exhausted error at max: 1, manager lease
  conflicts were retryable, active leases blocked close_session, close_session
  removed the managed entry after lease release, and a later open succeeded.
Standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
Report output includes session_open/session_exec/session_checkpoint/
  session_restore/session_close latency fields.
Docker warm-session smoke: passed; warm Docker session was reused across
  repeated execs and persisted /workspace/warm.txt between checkouts.
git diff --check: passed.
```

Implementation notes:

- `RunicSandbox.Profile.pool` now carries the richer lifecycle shape while
  preserving default `warm: 0, max: 1` behavior.
- `RunicSandbox.acquire_session/3`, `release_session/2`, and
  `reset_session/2` route to supervised pool semantics when `server:` is
  supplied and fall back to direct session operations otherwise.
- Supervised `exec` now checks out a managed session, runs through the normal
  signed session path, and checks the session back into the pool.
- Manager-level leases are provider-neutral and intended for workspace/resource
  coordination. They deliberately do not require backend-native lease support.
- Idle cleanup now runs synchronously on status/acquire/release, on manager
  shutdown, and through a manager reaper loop when any profile has a finite
  `idle_ttl_ms`.
- Checked-out sessions are owned by the caller process. The manager monitors the
  owner and closes the checked-out session, releases capacity, and drops managed
  leases if that process exits before release/close.

Review findings resolved in Phase 6:

- Review finding: supervised `open_session/3` bypassed pool `max` and
  `close_session/2` did not route `server:` sessions back through the manager.
  Resolved by making managed `open_session` use the same checkout path as
  `acquire_session` and adding manager-aware `close_session(server:)` that
  validates, closes, revokes, and removes the managed entry.
- Review finding: reset-on-checkin could leave a closed session entry in manager
  state if replacement open failed. Resolved by deleting the closed entry before
  replacement open and returning the updated manager state with the error.
- Intermediate Phase 6 review cleared the first pooling/session lifecycle fixes.
- Final review follow-up: abandoned checked-out sessions originally were not
  reaped, and the reaper regression used a fixed sleep. Resolved by adding
  owner process monitors for checked-out sessions and replacing the timing test
  with a deadline poll.
- Final Phase 6 review: no remaining Critical, High, or Medium findings in the
  pooling/session lifecycle slice.

Parallelization:

- Subagent A can implement manager/pool semantics.
- Subagent B can implement reports/metrics.
- Subagent C can stress cleanup and failure modes.

Exit gate:

- Agents get low-latency repeat execution without sacrificing reviewable state
  transitions and cleanup semantics.

### Phase 7: Libbit Contract Readiness, No Libbit Code Changes

Goal: prove the package API is ready for Libbit without touching
`/home/doops/wrk/libbit`.

Deliverables:

- [x] Add a `RunicSandbox.ConsumerProfiles.libbit_workspace/1` example or a
      docs-only example showing how Libbit would configure:
      per-workspace session, checkpoint-on-risky-action, service/proxy support,
      leases, and workspace metadata.
- [x] Add a fake "Libbit-like" contract test inside RunicSandbox that models:
      workspace id, workflow run id, agent id, exclusive lease, checkpoint,
      exec, artifact export, and restore.
- [x] Add integration docs mapping:
      `Core.Platform.SandboxSessions -> RunicSandbox -> provider backend`.
- [x] Add explicit "not implemented in Libbit yet" notes and open questions.

Validation:

- [x] Contract test passes without Libbit dependency.
- [x] Docs name the exact future Libbit touchpoints but make no edits there.
- [ ] Senior architecture review confirms the API does not force Libbit to
      depend on RunicAI product modules.

Phase 7 slice evidence on 2026-05-25:

```sh
cd packages/runic_sandbox && mix test test/runic_sandbox_test.exs
cd packages/runic_sandbox && mix test && mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/agent/capability_resolver_test.exs test/runic_ai/coding/tools_test.exs test/runic_ai/coding/rlm_agent_test.exs test/runic_ai/workbench_test.exs
mix compile --warnings-as-errors
mix runic_sandbox.validate_standalone
git diff --check
```

Results:

```text
RunicSandbox focused and full package tests: 36 tests, 0 failures.
RunicSandbox package compile --warnings-as-errors: passed.
RunicAI focused sandbox/RLM/Workbench tests: 146 tests, 0 failures.
Root compile --warnings-as-errors: passed.
Standalone package smoke: passed, with existing just_bash optional runner
  warnings from the dependency.
git diff --check: passed.
```

Implementation notes:

- Added `RunicSandbox.ConsumerProfiles.libbit_workspace/1` as a package-level
  example helper. It returns ordinary `{name, config}` sandbox supervision
  config, not a RunicAI product module dependency.
- The Libbit-shaped profile carries `workspace_id`, `workflow_run_id`,
  `agent_id`, persistent workspace metadata, checkpoint-on-risky-action policy,
  pool defaults, and provider backend options. It defaults to `:sprites` but can
  be generated for `:docker` or future backends.
- Added a fake Libbit-like contract test in RunicSandbox using only
  RunicSandbox primitives: workspace metadata, exclusive lease, checkpoint,
  exec, artifact file export, restore, service, proxy, lease release, and close.
- Default Sprites identity for Libbit profiles is collision-resistant:
  `libbit_workspace/1` derives provider identity from a readable workspace slug
  plus a stable hash of tenant id and raw workspace id. Callers can still
  override `:sprite` explicitly.

Future Libbit mapping, with no Libbit repo edits in this phase:

```text
Core.Platform.SandboxSessions
  owns workspace/session lifecycle policy
  -> calls RunicSandbox.start_link/1 or per-workspace RunicSandbox managers
  -> configures RunicSandbox.ConsumerProfiles.libbit_workspace/1
  -> checks out sessions with RunicSandbox.acquire_session/3
  -> coordinates workspace resources with RunicSandbox.acquire_lease/3
  -> checkpoints before risky actions with RunicSandbox.checkpoint/3
  -> executes actor/workflow code with RunicSandbox.exec/3
  -> exposes services/proxies with RunicSandbox.start_service/3 and open_proxy/3
  -> restores or resets with RunicSandbox.restore/3 or reset_session/2
  -> releases with RunicSandbox.release_lease/2 and release_session/2
provider backend
  can be :sprites, :docker, :vmsan, :remote, or a later Fly/Firecracker adapter
```

Not implemented in Libbit yet:

- No Libbit modules are changed in this phase.
- `Core.Platform.SandboxSessions` is a proposed touchpoint name based on the
  current Libbit architecture notes, not an implemented RunicSandbox adapter.
- Libbit still needs to choose tenancy boundaries, workspace naming, credential
  ownership, checkpoint retention, and whether app services are per-workspace,
  per-workflow, or per-actor.
- A timed reaper, durable manager state, and cloud provider quota handling
  remain future RunicSandbox hardening work before Libbit should rely on this
  for production cloud workspace hosting.

Review findings resolved in Phase 7:

- Review finding: default Libbit/Sprites provider identity used lossy workspace
  slugging, so distinct workspace ids could attach to the same persistent remote
  sprite. Resolved by adding a stable hash of tenant id and raw workspace id to
  the generated provider identity and a regression assertion for colliding
  slugs.
- Final Phase 7 review: no remaining Critical, High, or Medium findings in the
  Libbit-readiness contract slice.

Parallelization:

- Subagent A can write the contract test.
- Subagent B can write the integration mapping.
- Subagent C can review against Libbit `.docs` and provider modules.

Exit gate:

- The package has a credible path for Libbit workspace isolation, durable
  workflow apps, actor/service runtimes, and cloud/local parity without
  compromising RunicAI's simpler local-agent UX.

## Review Loop And Operating Model

Use a RALPH/OODA loop for every phase:

1. **Read**: inspect current code, backend docs, host readiness, and previous
   phase evidence.
2. **Assess**: state the exact contract gap and the smallest deliverable that
   closes it.
3. **List**: update the phase checklist in this doc with current status.
4. **Plan**: name files/modules/tests to touch and backend smoke to run.
5. **Handle**: implement the phase.
6. **Observe**: run unit tests, compile, package tests, and one real smoke when
   feasible.
7. **Orient**: summarize failures, update diagnostics, and decide whether the
   next step is fix, fallback, or phase advancement.
8. **Decide**: request/perform senior review before continuing.
9. **Act**: apply review fixes, then mark the checklist item complete.

The senior review subagent should wear a skeptical architecture/engineering hat
and focus on:

- leaky abstractions;
- hidden provider assumptions;
- unsafe privilege handling;
- missing cleanup paths;
- unclear state semantics;
- tests that mock away the important risk;
- confusing RunicAI vs RunicSandbox vs Libbit boundaries.

## Suggested Codex Goal

Use this as the next iterative implementation goal:

```text
/goal Implement the RunicSandbox serverless sandbox expansion plan from
.docs/050-sandbox-serverless-mesh-and-libbit-consumer-next-steps.md.

Work in iterative RALPH/OODA phases. Keep the implementation centered on
packages/runic_sandbox and RunicAI consumer integration. Do not edit the Libbit
repo; use Libbit only as a contract and architecture pressure test.

For each phase:
- read the current doc checklist and relevant code before editing;
- implement the smallest coherent deliverable;
- validate with package tests, RunicAI focused tests, warnings-as-errors
  compile, and a real manual smoke when the backend is available;
- update the doc checklist and evidence notes;
- run or request a senior architect/engineer review pass before advancing;
- preserve provider-neutral contracts and avoid leaking vmsan, Sprites, Fly, or
  Docker semantics into RunicAI tools or future Libbit-facing APIs.

Initial target:
1. Phase 0 host/provider doctor and health-reporting improvements.
2. Phase 1 session contract foundation.
3. Phase 2 Docker session baseline.
4. Phase 3 vmsan backend once doctor reports the required assets are installed.
5. Phase 4 RunicAI capability profile integration.
6. Phase 5 Sprites adapter.
7. Phase 6 pooling and lifecycle.
8. Phase 7 Libbit contract readiness without Libbit code changes.
```

## Design Risks

### Risk: leaky abstraction

Avoid method names like `create_machine`, `sprite_checkpoint`, or
`firecracker_snapshot` in app-facing contracts. Provider-specific semantics
belong in adapter metadata and capability maps.

### Risk: over-generalizing too early

Do not design a universal cloud platform abstraction. Design the narrow session
operations that RunicAI and Libbit actually need, then let adapters expose
capability maps for everything else.

### Risk: hidden persistence semantics

The user must be able to tell whether data lives in:

- an in-memory interpreter;
- a copied temp directory;
- a Docker managed workspace;
- a vmsan microVM disk;
- a Sprite checkpoint;
- a Fly volume;
- a Libbit workspace database.

Every result should surface this as structured metadata.

### Risk: sidecars become the model

Sidecar/proxy systems are useful for Libbit service runtimes, but they should be
one transport model. The root model is a sandbox session with capabilities.

### Risk: local and cloud diverge

Libbit needs cloud-local parity for developer trust. The target should be:

- Docker for cheap local dev;
- vmsan for high-isolation local dev;
- Sprites/Fly Machines for hosted stateful workspace execution;
- all behind the same session contracts.

## Interface Boundary Rule

`RunicSandbox` should answer:

> What isolated runtime session exists, what can it do, what did it execute,
> what state changed, and what policy governed it?

RunicAI should answer:

> Which local agent tool or workflow node asked for execution, what review was
> required, and how should the user see the trace?

Libbit should answer:

> Which workspace, tenant, agent, workflow, component, event stream, and durable
> application state owns this runtime session?

Keeping those questions separate is the difference between a reusable sandbox
library and a provider-specific execution subsystem.

## Source Notes

- RunicAI sandbox baseline: `.docs/046-ai-code-sandboxing-research.md`
- Libbit workspace sandbox baseline:
  `/home/doops/wrk/libbit/.docs/workspace-sandbox-and-graph-memory-architecture-exploration.md`
- Libbit Firecracker local provider plan:
  `/home/doops/wrk/libbit/.docs/firecracker_local_provider_plan.md`
- Libbit container infrastructure provider plan:
  `/home/doops/wrk/libbit/.docs/container_infrastructure_providers_plan.md`
- Libbit Fly API implementation plan:
  `/home/doops/wrk/libbit/.docs/fly_api_implementation_plan.md`
- Libbit built-in agent sandbox tool direction:
  `/home/doops/wrk/libbit/.docs/builtin-agent-phase6-rollout-followup-plan.md`
- vmsan docs: <https://vmsan.dev/>
- Sprites API docs: <https://docs.sprites.dev/api/>
- Fly Machines API docs:
  <https://fly.io/docs/machines/api/machines-resource/>
- CubeSandbox repo: <https://github.com/TencentCloud/CubeSandbox>
- Firecracker repo: <https://github.com/firecracker-microvm/firecracker>
- E2B docs: <https://e2b.dev/docs>
- Daytona sandbox docs: <https://www.daytona.io/docs/en/sandboxes/>
- Modal sandboxes docs: <https://modal.com/docs/guide/sandboxes>
