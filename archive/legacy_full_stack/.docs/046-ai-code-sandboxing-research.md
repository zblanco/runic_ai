# AI Code Sandboxing Research

Status: research note / implementation direction

Date: 2026-05-22

Scope: arbitrary code execution for RunicAI local coding agents, WebUI-driven
agent workflows, and a potential extractable Elixir sandbox orchestration
library.

## Goal

Define the sandboxing direction for RunicAI now that the local workbench,
runtime sessions, durable traces, capability profiles, and coding-agent tool
substrate are becoming the main product surface.

The missing capability is not another predefined component. It is a standard
way for agents and workflows to execute arbitrary code while preserving the
RunicAI contract model:

- inputs, outputs, diagnostics, artifacts, and policy are structured data;
- dangerous execution is reviewable and observable;
- execution can be stateless or stateful;
- different runtimes can be selected by capability profile;
- backends can range from in-process DSL sandboxes to containers, gVisor,
  Firecracker/KVM microVMs, remote microVM services, and future runtimes.

The target shape should be extractable as an independent Elixir library that can be easily configured into a supervision tree / application.ex:

```elixir
children = [
  {RunicSandbox,
   sandboxes: [
     local_code: [
       backend: :docker,
       image: "runic-ai/sandbox:elixir-python-node",
       pool: [warm: 1, max: 4],
       network: :disabled,
       workspace: [mode: :copy_in, persist?: true]
     ]
   ]}
]
```

RunicAI would then consume that library through ordinary tool definitions,
Runic components, capability profiles, review gates, trace events, and
Workbench settings.

## Prior RunicAI Context

The `.docs` search points to a consistent prior intention: RunicAI should
separate host workspace policy from command execution, keep risky execution
behind explicit contracts, and make runtime capabilities visible through the
same agent/tool surface used by the terminal and web workbench.

### Coding Substrate

`.docs/024-coding-harness-and-tools-implementation-plan.md` established the
shared coding substrate:

> "How can a RunicAI workflow safely inspect and change a local workspace, run
> bounded commands, persist session evidence, and expose all of that through
> typed tool contracts that ordinary agent recipes and RLM-generated workflows
> can both reuse?"

The same plan accepted these decisions:

- `RunicAI.Coding` is the experimental coding substrate namespace.
- Commands default to explicit argv execution.
- Shell is opt-in.
- `just_bash` is an optional dev/test backend, not a replacement for guarded
  host commands.
- Filesystem operations resolve through a workspace root and `PathPolicy`.
- Risky actions must remain compatible with `GuardDecision`, `ReviewRequest`,
  and budget policy.

Current code matches that intent:

- `RunicAI.Coding.Command` supports `:argv`, `:shell`, and `:just_bash`
  backends.
- `RunicAI.Coding.CommandPolicy` controls cwd, timeout, output caps, env
  allowlists, allowed/blocked commands, shell enablement, and just_bash
  enablement.
- `RunicAI.Coding.CommandRunner` executes `System.cmd/3` for argv/shell and
  calls `JustBash` when the optional dependency is loaded.
- `RunicAI.Coding.ProcessRegistry` owns background process lifecycle.
- `RunicAI.Coding.Tools` exposes the coding tools through
  `RunicAI.Tool.Definition`.

This is a policy-gated command runner, not a full arbitrary-code sandbox.

### Runtime Adapters

`.docs/015-phase-8-advanced-runtime-adapters-and-optimization-hooks-implementation-plan.md`
already named the right lane:

> "adapters can execute local commands, sandboxed commands, child workflows,
> background jobs, or remote workers"

That argues for a sandbox adapter under the existing tool lane, with outcomes
normalized into `CallResult`, `Wait`, retry, halt, artifacts, and events.

### Run Context And Secrets

`.docs/036-runic-native-dynamic-workflow-generation-refactor-plan.md` moved
workspace, model, client, write policy, event sink, and run id into Runic
`run_context` instead of capturing those handles in closures. It also notes
that runtime context is not serialized in Runic's event log, which is correct
for secrets, clients, and workspace handles.

Sandbox execution should follow that pattern. The sandbox handle, secret proxy,
workspace transfer strategy, and backend client belong in runtime context or a
supervised process, while the workflow graph records only stable capability and
execution facts.

### Web Workbench

`.docs/039-phoenix-liveview-local-agent-workbench-plan.md` is explicit that the
local web product will execute commands, read/write files, call LLM providers,
and store traces. It says the app must not assume local means safe. Required
defaults include localhost binding, tokenized local URLs, secret redaction,
visible destructive approvals, and preservation of path-policy and
command-policy decisions.

Sandboxing should therefore surface in the WebUI as configuration, health,
policy, and audit state:

- selected sandbox backend and isolation level;
- enabled runtimes such as Elixir, Bash, Lua, Python, Node, and future images;
- network and filesystem policy;
- warm pool status;
- per-session sandbox workspace;
- command/code execution history;
- files imported/exported between host workspace and sandbox;
- review decisions that changed sandbox policy.

### Capability Profiles

`.docs/043-hermes-style-agent-tool-surface.md` identified `code_execution` as
deferred and said that if added, it should be a distinct toolset with clear
sandbox policy. It also proposed capability profiles as the layer that merges
toolsets, policy, runtime config, and WebUI/CLI launch controls.

That remains the right public surface. `code_execution` should compile into
ordinary tools/components, not bypass `RunicAI.Tool.Executor`, guard policies,
review requests, events, artifacts, or SQLite read models.

## Current RunicAI Baseline

RunicAI already has enough substrate to add sandboxing without inventing a
separate agent loop:

| Existing surface | Role in sandboxing |
| --- | --- |
| `RunicAI.Coding.Workspace` / `PathPolicy` | Host workspace boundary and safe path resolution. |
| `RunicAI.Coding.CommandPolicy` | Existing command policy vocabulary; should be generalized or wrapped for sandbox requests. |
| `RunicAI.Coding.CommandResult` | A useful starting result shape for stdout/stderr/status/duration/artifact refs. |
| `RunicAI.Coding.ProcessRegistry` | Reference for long-running process lifecycle, but host-port based; sandbox processes should live behind backend handles. |
| `RunicAI.Tool.Definition` / `Tool.Registry` | Model-visible execution surface. |
| `RunicAI.Tool.Adapters.ExternalWorker` | Existing generic callback boundary for non-local execution. |
| `RunicAI.Runtime.SessionSpec` | Natural place to attach sandbox backend metadata and session resources. |
| `RunicAI.Event` / `RunicAI.Workbench.record_event/1` | Common event path for streaming status and persisted observability. |
| `RunicAI.RLM.ComponentRuntime` and component catalog | RLM lane can call sandbox-backed component leaves through shared contracts. |

The current gap is that `run_command` executes on the host with policy. A
sandboxed code runtime needs a separate workspace, process boundary, execution
API, and backend lifecycle.

## External Research Summary

### Firecracker And KVM MicroVMs

Firecracker is the strongest local Linux isolation candidate when the machine
has KVM. Its README says the VMM uses Linux KVM to create microVMs and uses a
minimalist device model to reduce memory footprint and attack surface while
improving startup time and utilization
(<https://github.com/firecracker-microvm/firecracker>). The jailer adds chroot,
cgroup, and related host-side containment around the Firecracker process
(<https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md>).

Fit for RunicAI:

- strong boundary for arbitrary Elixir/Python/Node/Bash package-manager work;
- good long-term self-hosted Linux backend;
- likely needs warm pools, snapshots, or long-lived session sandboxes to keep
  agent latency acceptable;
- orchestration complexity is real: rootfs/image management, TAP networking,
  cgroups, jailer setup, kernel/rootfs builds, file transfer, snapshot/restore,
  and cleanup after crashes.

Limitations:

- Firecracker is Linux/KVM centered. It is not the default portable local story
  for macOS and Windows developers.
- A direct Firecracker backend is probably not Phase 1 unless a wrapper project
  is adopted first.

### SmolVM, vmsan, Mentat, And Similar MicroVM Wrappers

Several newer projects are trying to make microVMs feel like Docker:

- SmolVM describes disposable computers for agents, millisecond boot, stateful
  files, support for Linux and macOS installs, and agent-framework integrations
  (<https://github.com/CelestoAI/SmolVM>).
- vmsan wraps Firecracker with a CLI, JSON output, WebSocket PTY, file sync,
  network policies, and OCI image support (<https://vmsan.dev/>).
- Mentat presents a private workload platform with Firecracker, namespace
  sandboxes, Docker, static binaries, and a small daemonless Linux namespace
  runtime (<https://www.getmentat.run/>).

Fit for RunicAI:

- useful research targets for backend shape;
- possible adapters if the CLI/API stabilizes;
- good evidence that developers want local-first microVM ergonomics.

Risk:

- these projects are young;
- APIs, licensing, and operational assumptions may drift;
- RunicAI should not bake one young CLI into core. Put them behind backend
  behaviours.

### gVisor

gVisor is an open-source Linux-compatible sandbox that works with existing
container tooling. Its docs frame it as isolation for user-uploaded,
LLM-generated, or third-party code and describe syscall interception plus
Linux isolation around the sandbox itself (<https://gvisor.dev/>).

Fit for RunicAI:

- excellent intermediate backend for Docker/containerd users who can install
  `runsc`;
- lower orchestration burden than raw microVMs;
- container-like startup and image reuse;
- good defense-in-depth when the user has Docker but wants more than vanilla
  shared-kernel containers.

Limitations:

- still Linux/container-runtime oriented;
- not the same boundary as a separate guest kernel;
- local setup is more specialized than Docker/Podman.

### Kata Containers

Kata Containers adds a lightweight VM layer under container workloads. Its
design docs say it creates a second isolation layer using hardware
virtualization, launches lightweight VMs, and uses KVM as the underlying Linux
hardware virtualization interface (<https://github.com/kata-containers/kata-containers>).

Fit for RunicAI:

- strong Kubernetes/containerd story;
- good production backend if RunicAI later runs in cluster environments.

Limitations:

- too much machinery for the first local developer library target;
- better as a future adapter than the default local path.

### Docker And Podman

Docker/Podman are the practical baseline because many developers already have
one of them installed. They give fast startup, OCI image reuse, language
runtime availability, and an obvious "single workspace with many languages"
model.

Fit for RunicAI:

- best Phase 1 backend for broad local availability;
- easy to build a `runic-ai/sandbox` image with Elixir, Erlang, Python, Node,
  Lua, Bash, git, ripgrep, jq, sqlite, and build tools;
- supports stateful long-lived session containers and stateless one-shot jobs;
- works on macOS/Windows through Docker Desktop, Colima, Lima, or Podman
  Machine.

Security posture:

- useful isolation, but not a strong boundary for hostile arbitrary code;
- containers share the host kernel;
- should be labeled as `isolation_level: :container`, not hidden behind a
  generic "safe sandbox" name.

### Bubblewrap, Landlock, Seccomp, nsjail-Style Namespace Sandboxes

Bubblewrap is a low-level unprivileged sandbox used by Flatpak. Its README
emphasizes that the level of protection depends entirely on the arguments used,
and lists mount, user, IPC, PID, network, UTS namespaces, plus seccomp filters
as available controls (<https://github.com/containers/bubblewrap>).

Fit for RunicAI:

- extremely low startup latency on Linux;
- useful as a hardening layer for short host commands or package install
  scripts;
- good backend for trusted local convenience when container engines are absent.

Limitations:

- Linux-specific;
- easy to misconfigure;
- less appropriate as the main answer for arbitrary multi-language agent code;
- every mount/socket/env decision is security-sensitive.

### Wasm/WASI And Wasmtime

Wasmtime is a WebAssembly, WASI, and Component Model runtime designed to run
outside the browser; it is configurable for CPU and memory and focused on
security (<https://docs.wasmtime.dev/introduction.html>). Its security docs
describe WASI filesystem access as capability based: programs only access the
files and directories they are given (<https://docs.wasmtime.dev/security.html>).

Fit for RunicAI:

- excellent for plugin-like user code, deterministic transforms, small
  higher-order functions, and audited component execution;
- strong candidate for "safe function passed to map" where input/output is JSON
  and capabilities are explicit;
- better than containers for tiny pure compute steps if users can compile to
  Wasm.

Limitations:

- not a general "run any project in any programming language" backend;
- package-manager workflows, native extensions, shells, and existing repos are
  awkward unless the workload was designed for WASI.

### just_bash

RunicAI already has optional `:just_bash` dev/test support. The Hex package is
described as a simulated bash environment with a virtual filesystem for safe
command execution (<https://hex.pm/packages/just_bash>). The upstream
just-bash project describes a TypeScript bash interpreter with an in-memory
filesystem for AI agents, optional Python/JS/SQLite support, and a Vercel
Sandbox-compatible API for development/testing before swapping to a real VM
(<https://justbash.dev/>).

Fit for RunicAI:

- keep as a low-latency fake shell for tests, in-memory demos, read-only
  knowledge-base exploration, and safe deterministic examples;
- useful as a `SandboxBackend` with `isolation_level: :in_process` and
  backend metadata showing virtual filesystem semantics;
- should not be described as a full arbitrary-code security boundary.

### tv-labs/lua / Luerl

`tv-labs/lua` is an ergonomic Elixir interface to Luerl. It supports
compile-time validation via `~LUA`, compile-time chunking to avoid runtime
parsing cost, API exposure through `deflua`, and private state that remains
unavailable to Lua code (<https://github.com/tv-labs/lua>).

Fit for RunicAI:

- strong option for embedded policy-controlled scripting;
- good for user-defined functions, scoring rules, small transforms, routing
  logic, and workflow-local DSLs;
- can complement Runic components where a developer wants to pass code as data.

Limitations:

- not a general arbitrary-language sandbox;
- BEAM-level resource controls and API exposure need careful treatment;
- should be a language runtime backend, not the whole sandbox story.

### Fly.io Sprites And Machines

Fly Sprites are marketed as hardware-isolated, stateful Linux environments for
arbitrary code, with checkpoint/restore and simple command execution APIs
(<https://sprites.dev/>). Fly's agent sandbox article frames sandboxes as
isolated runtimes for testing agent behavior, repeated simulations, logging,
rollback, constrained permissions, and observable execution
(<https://fly.io/learn/agent-sandbox/>). The Machines API exposes lifecycle
operations such as create, start, stop, suspend, wait, metadata, and lease
(<https://fly.io/docs/machines/api/machines-resource>).

Fit for RunicAI:

- good optional remote backend when the user wants hardware isolation without
  local KVM setup;
- useful for high-concurrency evals and remote workbench scenarios;
- Sprites line up well with stateful per-agent "workspace computer" semantics.

Limitations:

- not local-first;
- requires account, tokens, network, cost, and remote data transfer decisions;
- should be an optional backend, not a core assumption.

### E2B, Daytona, Kilntainers, Vercel Sandbox, And Community Signals

E2B's code-interpreter SDK is Python/JS/TS oriented and describes cloud
sandboxes for AI-generated code with a simple create/run-code API
(<https://github.com/e2b-dev/code-interpreter>). Daytona positions itself as
open-source secure and elastic infrastructure for AI-generated code
(<https://github.com/daytonaio/daytona>). Kilntainers is an MCP server with
Docker/Podman, Modal, E2B, and WASM backends, creating one isolated sandbox per
MCP connection (<https://mcp.so/server/kilntainers/Kiln-AI>).

Recent X discussion is directionally useful rather than authoritative:

- a cto.new thread says they ran AI code agents on custom Firecracker microVMs
  for more than 18 months, but wanted to hand off sandbox infrastructure as the
  market matured (<https://x.com/ctodotnew/status/2017271423782494590>);
- an Arlan thread describes using just-bash for a client-side in-memory docs
  filesystem because it avoids containers, VMs, warm pools, and server compute
  for that narrow workload (<https://x.com/arlanr/status/2041215978957389908>).

The lesson for RunicAI is to expose backend truth. A single interface is good.
Pretending every backend has the same isolation, latency, persistence, and
network posture is not.

## Backend Taxonomy

| Backend class | Examples | Local availability | Latency posture | Isolation posture | Best use |
| --- | --- | --- | --- | --- | --- |
| In-process virtual runtime | `just_bash`, Lua/Luerl | High | Very low | Process/library boundary | Tests, demos, trusted transforms, deterministic map functions. |
| Wasm/WASI | Wasmtime | Medium | Very low to low | Wasm sandbox + explicit capabilities | Plugin-like functions and portable compute. |
| Namespace sandbox | bubblewrap, Landlock/seccomp, nsjail | Linux only | Very low | Kernel namespaces/seccomp; config-sensitive | Hardened local commands when VM/container is too heavy. |
| Container | Docker, Podman | High | Low | Shared kernel | Default practical local multi-language workspace. |
| Sandboxed container | gVisor | Medium | Low to medium | Userspace kernel / syscall interception | Better local/container defense-in-depth. |
| VM-backed container | Kata | Medium in clusters | Medium | Hardware virtualization | Cluster production and Kubernetes lanes. |
| Local microVM | Firecracker/KVM, SmolVM, vmsan | Linux strong; macOS emerging via wrappers | Medium unless pooled/snapshotted | Separate guest kernel / hardware virtualization | Serious arbitrary code execution. |
| Remote microVM | Fly Sprites/Machines, E2B, Vercel Sandbox | Account/API required | Network-dependent; often fast when warm | Provider-owned VM isolation | Optional strong backend and scale-out evals. |

## Recommended Direction

Build the abstraction around a sandbox workspace, not around a language.

The central object should be a supervised sandbox instance that can expose many
execution capabilities:

```elixir
%RunicSandbox.Instance{
  id: "sbx_...",
  backend: :docker,
  isolation_level: :container,
  state: :ready,
  capabilities: [
    {:language, :elixir, version: "1.19"},
    {:language, :python, version: "3.13"},
    {:language, :node, version: "22"},
    {:language, :lua},
    {:command, "bash"},
    {:command, "mix"},
    {:filesystem, :workspace},
    {:network, :disabled}
  ],
  workspace: %{
    mode: :stateful,
    mount: "/workspace",
    host_root: "/home/doops/wrk/runic_ai",
    import_strategy: :copy_in
  }
}
```

Then expose code execution as narrow request types:

```elixir
%RunicSandbox.ExecutionRequest{
  sandbox: :local_code,
  runtime: :elixir,
  mode: :script,
  source: "IO.puts(Jason.encode!(input))",
  argv: [],
  stdin: Jason.encode!(input),
  cwd: "/workspace",
  timeout_ms: 30_000,
  max_output_bytes: 65_536,
  network: :disabled,
  persist_changes?: true,
  metadata: %{run_id: run_id, workflow_node: :score_candidate}
}
```

And return structured results:

```elixir
%RunicSandbox.ExecutionResult{
  status: :pass,
  stdout: "...",
  stderr: "",
  exit_status: 0,
  duration_ms: 143,
  files_changed: [],
  artifacts: [],
  backend: :docker,
  isolation_level: :container,
  diagnostics: [],
  resource_usage: %{cpu_ms: 91, memory_peak_bytes: 128_000_000}
}
```

### Backend Behaviour

An extractable library should define a small backend behaviour:

```elixir
@callback start_link(keyword()) :: GenServer.on_start()
@callback provision(profile :: map(), opts :: keyword()) ::
            {:ok, instance :: map()} | {:error, term()}
@callback exec(instance :: map(), request :: map(), opts :: keyword()) ::
            {:ok, result :: map()} | {:error, term()}
@callback upload(instance :: map(), files :: list(), opts :: keyword()) ::
            {:ok, refs :: list()} | {:error, term()}
@callback download(instance :: map(), paths :: list(), opts :: keyword()) ::
            {:ok, files :: list()} | {:error, term()}
@callback snapshot(instance :: map(), opts :: keyword()) ::
            {:ok, snapshot :: map()} | {:error, term()}
@callback reset(instance :: map(), opts :: keyword()) :: :ok | {:error, term()}
@callback destroy(instance :: map(), opts :: keyword()) :: :ok | {:error, term()}
@callback health(opts :: keyword()) :: {:ok, map()} | {:error, term()}
```

Potential modules:

```text
lib/runic_sandbox/
  application.ex
  backend.ex
  manager.ex
  pool.ex
  instance.ex
  profile.ex
  capability.ex
  execution_request.ex
  execution_result.ex
  workspace.ex
  policy.ex
  artifact.ex
  event.ex
  backends/
    just_bash.ex
    lua.ex
    wasmtime.ex
    docker.ex
    podman.ex
    gvisor.ex
    firecracker.ex
    fly_sprites.ex
    e2b.ex
```

RunicAI should consume the extracted `RunicSandbox` package through ordinary
tools, capability profiles, review gates, traces, and Workbench settings. The
only RunicAI-local sandbox module should be a compatibility facade or product
integration layer.

## RunicAI Integration Shape

### Capability Profile

Add a `code_execution` toolset with explicit backend truth:

```elixir
%RunicAI.Agent.CapabilityProfile{
  toolsets: [:file, :git, :patch, :terminal, :process, :code_execution],
  config: %{
    code_execution: %{
      sandbox: :local_code,
      default_backend: :docker,
      allowed_runtimes: [:elixir, :bash, :lua, :python, :node],
      isolation_minimum: :container,
      network: :disabled,
      stateful?: true,
      review: :ask_on_policy_change
    }
  }
}
```

The profile resolver should persist the resolved sandbox settings with the run
launch metadata, just like toolsets and write policy.

### Tools

Add model-visible tools only after the backend contract exists:

- `execute_code`: run source or a named file through a selected runtime.
- `sandbox_command`: run argv inside the sandbox workspace.
- `sandbox_upload`: import selected host files/artifacts.
- `sandbox_download`: export files as artifacts or apply an approved patch.
- `sandbox_reset`: reset to template or last snapshot.
- `sandbox_status`: report backend health, capabilities, and current state.

The default visible surface should probably start with `execute_code` and
`sandbox_status`. File transfer should remain system-driven or review-gated
until the UX is clear.

### RLM Components

Add component specs that call the same sandbox service:

- `RunicAI.RLM.Components.CodeEval`
- `RunicAI.RLM.Components.SandboxCommand`
- `RunicAI.RLM.Components.ScriptMap`

These should accept ordinary input facts, encode them as JSON or files, run the
sandbox request, and return typed facts or diagnostics. Repair loops should see
normal execution errors such as syntax errors, missing modules, timeout,
network blocked, resource limit exceeded, and sandbox unavailable.

### WebUI

Workbench should expose:

- backend preset: `none`, `just_bash`, `docker`, `docker+gvisor`,
  `firecracker`, `fly_sprites`, `custom`;
- runtime checklist: Elixir, Bash, Lua, Python, Node, other image;
- isolation label and warning text;
- network policy;
- stateful/stateless mode;
- warm pool size;
- workspace import/export mode;
- current sandbox health and last error;
- per-run sandbox events and artifacts.

The UI should show whether execution happened on the host, in a container, in a
microVM, or in a remote provider. This should be visible in run history and
debug views because it materially changes the trust model.

## Security Model

Non-negotiable defaults:

- no host secrets mounted into sandboxes;
- no network by default;
- no host `$HOME`, SSH agent, Docker socket, cloud credentials, or package
  manager auth by default;
- workspace import is explicit and bounded by `PathPolicy`;
- export back to host is an artifact or patch requiring normal review;
- backend isolation level is recorded on every result;
- audit logs are written outside the sandbox and cannot be modified by sandbox
  code;
- policy changes during a run produce visible review/resume events;
- resource limits include wall time, output bytes, memory, CPU, process count,
  and filesystem size where the backend supports them;
- stderr/stdout are capped and full output becomes an artifact.

Important distinction:

```text
policy-gated host command != sandboxed arbitrary code
container sandbox != microVM sandbox
in-process interpreter != security boundary
remote sandbox != local-first execution
```

RunicAI should encode those distinctions as data, not as prose hidden in docs.

## Latency Strategy

Low latency comes from tiering:

1. Use `just_bash`, Lua, or Wasm for tiny deterministic code where those
   runtimes are semantically enough.
2. Keep one warm local container for the active workbench session.
3. Add gVisor/runsc as a hardened local container option.
4. Add a long-lived local microVM session or snapshot/restore backend for
   stronger isolation.
5. Use remote microVM providers for scale-out evals or when local setup is not
   available.

The default local developer experience should optimize for:

- one warm stateful sandbox per active agent session;
- explicit reset/snapshot checkpoints;
- copy-in/copy-out by default instead of direct host mounts;
- optional bind mounts only for trusted local workflows;
- backend health checks before starting a run.

## Proposed Phases

### Phase 0: Contract Research And Spike

- [x] Define `Sandbox.Profile`, `Sandbox.Policy`, `ExecutionRequest`, and
      `ExecutionResult` structs.
- [x] Define `isolation_level` values:
      `:in_process`, `:in_process_virtual`, `:wasi`, `:namespace`,
      `:container`, `:gvisor`, `:microvm`, `:remote_microvm`.
- [x] Decide whether the stable namespace is a RunicAI-local module or a
      sibling package spike. The stable contract is `RunicSandbox`; RunicAI keeps
      only product integrations and a compatibility facade.
- [x] Add a small local feature flag so code execution remains disabled by
      default.

Validation:

- [x] Unit tests for request/result validation.
- [x] Unit tests proving isolation-level metadata is required for every backend
      result.

### Phase 1: Internal JustBash And Lua Backends

- [x] Wrap current optional `JustBash` usage behind the sandbox backend
      behaviour.
- [x] Add a Lua/Luerl backend spike for small transform functions.
- [x] Return the same `ExecutionResult` shape from the JustBash backend.
- [x] Mark JustBash as `isolation_level: :in_process_virtual` and
      `security_boundary?: false`.

Validation:

- [x] Scripted tests for JustBash stdout/status through the sandbox facade.
- [x] Tests proving JustBash is not advertised as a hard security boundary.
- [x] Timeout-focused backend tests.
- [x] Lua backend tests.

### Phase 2: Local Container Backend

- [x] Add Docker backend using CLI first, with command construction kept
      argv-only.
- [x] Support stateless one-shot execution.
- [x] Support stateful per-session Docker workspaces under supervised profiles.
- [x] Build a default multi-runtime image for Elixir, Bash, Lua, Python, Node,
      git, rg, jq, sqlite, and common build tools.
- [x] Capture changed files as artifacts before any host export.

Validation:

- [x] Run Elixir, Python, Node, Lua, and Bash smoke requests.
- [x] Prove network disabled blocks egress.
- [x] Prove host workspace writes require explicit export/patch flow.

### Phase 3: RunicAI Toolset And Workbench Surfacing

- [x] Add `code_execution` capability profile config.
- [x] Add `sandbox_status` and `execute_code` tool definitions.
- [x] Add Workbench settings for backend, runtime, network, and state mode.
- [x] Add Workbench warm pool controls.
- [x] Emit sandbox started/completed trace events with backend, isolation,
      network, artifact, and policy metadata.
- [x] Persist sandbox execution events and backend metadata through the
      terminal event bridge.
- [x] Add dedicated sandbox read-model grouping in Workbench details/artifacts.
- [x] Add review gates for policy escalation, network enablement, and host
      export.

Validation:

- [x] LiveView tests for submitting a run with configured code execution.
- [x] Agent smoke where syntax/runtime errors return repairable diagnostics.

### Phase 4: Hardened Backends

- [x] Add gVisor/runsc container backend detection.
- [x] Evaluate SmolVM or vmsan as a local microVM adapter before implementing
      raw Firecracker.
- [x] Defer direct Firecracker/KVM backend until wrappers prove insufficient.
- [x] Add Fly Sprites or Machines as an optional remote microVM backend.

Validation:

- [x] Backend health matrix for Linux, macOS, and Windows/WSL.
- [x] Latency report for cold start, warm exec, reset, and snapshot/restore.
- [x] Security posture report listing actual backend boundaries and known
      limitations.

### Phase 5: Extraction

- [x] Split stable sandbox contracts into an independent Elixir package.
  - [x] Add the extraction-facing `RunicSandbox` facade and child spec.
  - [x] Move the stable contracts and backend adapters into
        `packages/runic_sandbox`.
- [x] Keep RunicAI-specific tool definitions, WebUI, persistence, and RLM
      components in RunicAI.
- [x] Publish adapters as optional dependencies where possible.
  - [x] Keep Lua and JustBash runtime dependencies optional in the local package.
  - [x] Record which adapters stay in the base package and which should split
        into future provider/microVM packages.

Validation:

- [x] Use the library-shaped facade from RunicAI through a public child spec.
- [x] Use the library-shaped facade in a tiny standalone Mix project.

## Initial Recommendation

Start with the `RunicSandbox` contract and two backends:

1. `:just_bash` as the low-latency in-process virtual shell for tests and
   deterministic demos.
2. `:docker` or `:podman` as the practical local multi-language execution
   backend.

Do not lead with raw Firecracker. Instead, design the contract so Firecracker
is a backend, then evaluate SmolVM/vmsan-style wrappers and gVisor as the next
step. This gets RunicAI to a usable local code-execution workbench quickly
while preserving the path to stronger microVM isolation.

The most important architectural decision is to keep sandbox execution as a
supervised sidecar capability with explicit backend metadata, not a special
case inside `CommandRunner` and not generated Elixir modules inside the BEAM.

## Implementation Progress

### 2026-05-25 Slice

Implemented the first contract slice under `RunicSandbox`, initially wired
through a RunicAI compatibility facade:

- `RunicSandbox` facade and child spec, suitable for application
  supervision-tree configuration.
- `RunicSandbox.Manager` GenServer for named sandbox profiles.
- `RunicSandbox.Backend` behaviour.
- `RunicSandbox.Profile`, `Policy`, `Workspace`, `Instance`,
  `ExecutionRequest`, and `ExecutionResult` structs.
- `RunicSandbox.Backends.JustBash` as the first backend.
- `RunicAI.Application` now starts `{RunicSandbox,
  Application.get_env(:runic_ai, :sandbox, [])}`.
- `RunicAI.Coding.Tools.execute_code/4` now calls the sandbox facade instead
  of directly constructing a `:just_bash` command.
- `RunicAI.Coding.Tools.sandbox_status/2` now reports through
  `RunicSandbox.status/1`.
- `RunicAI.Agent.CapabilityResolver` passes `code_execution` tool config into
  sandbox profile options.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147
mix run -e 'Application.ensure_all_started(:runic_ai); ...'
```

Manual integration result from the supervised application child:

```text
status=available backend=just_bash
result=pass stdout=app-supervised-sandbox isolation=in_process_virtual
```

This completes the Phase 0 contract spike and the JustBash half of Phase 1.
It does not complete Lua, Docker/Podman, persistent sandbox workspaces,
Workbench settings, durable sandbox event persistence, or hardened backends.

Full-suite note:

```text
mix test
787 tests, 3 failures, 2 skipped
```

The sandbox/tool-leaf failure found during the first full-suite run was fixed
by returning JSON-safe `sandbox_status` maps. The remaining failures after the
fix were:

- `test/runic_ai/coding/command_test.exs:69`, streaming command timeout did
  not preserve partial output in that full-suite run, though the same test
  passed when rerun directly.
- `test/runic_ai/coding/rlm_objective_loop_test.exs:1091`, OpsLogic follow-up
  stopped with `:stop_failed` instead of completing.
- `test/runic_ai/rlm/robustness_test.exs:141`, OpsLogic optional smoke checks
  were skipped and the scenario expected `:pass`.

### 2026-05-25 Docker Slice

Implemented the first local container backend:

- `RunicSandbox.Backends.Docker` implements the shared backend behaviour.
- The backend uses explicit `docker run` argv, `--pull never`, `--rm`,
  `--network none` for disabled network policy, and a temporary copy-in
  workspace mounted at `/workspace`.
- `RunicSandbox` can dispatch `backend: :docker` profiles.
- Profile config now accepts top-level `image:` and carries backend options
  into instance metadata.
- Docker status reports `isolation_level: :container`,
  `security_boundary?: true`, configured image, and local image availability.
- Created or modified files in the temporary Docker workspace are captured as
  `files_changed` entries plus `sandbox://...` artifacts before cleanup.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147
```

Focused result:

```text
14 tests, 0 failures
```

Manual integration used an existing local Docker image with `/bin/sh` because
the default `runic-ai/sandbox:elixir-python-node` image does not exist yet.
The tool-level smoke exercised `RunicAI.Coding.Tools.execute_code/4` through a
Docker sandbox profile:

```text
status=available backend=docker image=registry.fly.io/zblanco/fly-pg-pgvector:latest
result=pass backend=docker isolation=container output=hello-docker-tool
```

Network-disabled validation checked container interfaces:

```text
interfaces=lo status=pass network=disabled
```

Host-export validation wrote a file inside `/workspace`, captured it as a
sandbox artifact, and confirmed no file appeared in the host workspace:

```text
status=pass stdout=container-only
files_changed=[%{path: "docker_sandbox_host_leak.txt", kind: :created, ...}]
artifacts=[%{ref: "sandbox://docker_sandbox_host_leak.txt", preview: "container-only\n", ...}]
host_leak=absent
```

This completes the stateless Docker CLI backend shape. At this point it did
not yet complete the default multi-runtime image, stateful container pools, or
multi-language container smoke coverage.

### 2026-05-25 Default Image Slice

Added the default local sandbox image artifact and build/smoke entrypoint:

- `priv/runic_ai/sandbox/Dockerfile` builds
  `runic-ai/sandbox:elixir-python-node` from Ubuntu 24.04.
- The image installs Bash, Elixir/Erlang, Python, Node/npm, Lua, git, ripgrep,
  jq, sqlite3, CA certificates, and build tools.
- `mix runic_ai.sandbox.image` builds the image and then smokes each runtime
  through `RunicSandbox.exec/2` with `backend: :docker`.
- `mix.exs` now includes `priv/runic_ai` in package files so the image
  definition is part of the deliverable.

Validation completed:

```sh
mix runic_ai.sandbox.image
mix runic_ai.sandbox.image --no-build
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147
```

Runtime smoke result after building the image:

```text
bash: bash-ok
python: python-ok
node: node-ok
elixir: elixir-ok
lua: lua-ok
```

Focused tests remained green:

```text
14 tests, 0 failures
```

This completes the default local image and multi-language smoke part of Phase
2. The remaining container/runtime gap is warm container pooling; current
statefulness is implemented as a supervised persistent Docker workspace, not a
long-lived container process.

### 2026-05-25 Stateful Docker Workspace Slice

Added supervised stateful Docker workspace support:

- Docker profiles with `stateful?: true` or
  `workspace: [persist?: true]` receive a managed temporary workspace root.
- `RunicSandbox.Manager` reuses the provisioned instance for the named
  sandbox profile, so later executions see files created by earlier
  executions.
- Direct unsupervised `RunicSandbox.exec/2` calls still use isolated
  one-shot workspaces unless a supervised server is supplied.
- `destroy/2` removes the managed workspace root.

Validation completed:

```sh
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147
mix run --no-start -e '... stateful docker workspace smoke ...'
```

Focused result:

```text
15 tests, 0 failures
```

Manual stateful smoke result:

```text
first=pass changes=1 second=pass stdout=manual-state
```

This proves stateful execution through a supervised sandbox profile while
preserving one-shot isolation for direct Docker profile calls. It does not yet
implement warm long-lived container pools.

### 2026-05-25 Trace Event Slice

Added sandbox observability through the existing RunicAI trace surface:

- `RunicAI.Coding.TraceEvent.sandbox/3` creates sandbox trace events.
- `RunicAI.Coding.Tools.execute_code/4` now emits
  `:coding_sandbox_started` and `:coding_sandbox_completed` events when an
  `event_sink` is supplied.
- Started events include the selected sandbox, runtime, network policy,
  workspace-relative input file paths, code byte count, bounded code preview,
  and summarized sandbox profile options.
- Completed events include status, backend, isolation level, duration, exit
  status, diagnostics, resource usage, changed files, and artifact refs without
  embedding full artifact contents.
- `RunicAI.Terminal.Event.from_trace_event/2` now gives sandbox trace events a
  tool-phase presentation shape, so terminal/TUI/Workbench subscribers see
  sandbox activity through the same event bridge as commands and browser tools.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147 \
  test/runic_ai/coding/trace_event_test.exs \
  test/runic_ai/terminal/event_test.exs
mix run --no-start -e '... execute_code with event_sink ...'
```

Focused result:

```text
32 tests, 0 failures
```

Manual event smoke:

```text
result=pass output=trace-smoke
event=coding_sandbox_started status=running sandbox=local_code runtime=bash backend=
event=coding_sandbox_completed status=pass sandbox=local_code runtime=bash backend=just_bash
```

This completes the initial trace-event side of Phase 3. The remaining Phase 3
work is explicit Workbench settings, durable SQLite/read-model surfacing for
sandbox events and metadata, and review gates for sandbox policy escalation,
network enablement, and host export.

### 2026-05-25 Workbench And Review Gate Slice

Added the first operator-facing Phase 3 controls and review metadata:

- `execute_code` now normalizes sandbox network policy values at the tool
  boundary, so direct `"host"` / `"restricted"` requests become structured
  sandbox policy instead of invalid request maps.
- `RunicAI.Coding.ReviewGate` now classifies `execute_code` separately from
  generic risky tools. Review details include sandbox name, backend, runtime,
  network policy, timeout/output caps, sandbox cwd, state/export indicators,
  input file summaries, bounded code preview, code byte count, and policy
  escalation labels.
- `RunicAI.Agent.ToolExecution` includes the same bounded sandbox summary in
  browser review requests for assistant/RLM tool execution paths that do not
  pass through the standard coding pre-tool guard.
- `RunicAI.Workbench.health/0` now includes supervised sandbox status.
- Workbench launch settings now expose sandbox backend, runtime, network, and
  stateless/stateful mode plus warm/max pool counts, and merge those controls
  into `code_execution` capability profile config.
- Workbench session details show the active sandbox backend/runtime/network
  from the resolved capability profile.
- Capability resolution accepts CLI/workbench string runtime lists such as
  `"python,node"` when building sandbox profile options.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/coding/review_gate_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/coding/tools_test.exs:512 \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai_web/workbench_live_test.exs
mix runic_ai.sandbox.image --no-build
```

Focused result:

```text
31 tests, 0 failures (22 excluded)
bash: bash-ok
python: python-ok
node: node-ok
elixir: elixir-ok
lua: lua-ok
```

Full-suite regression result after this slice:

```text
mix test
794 tests, 3 failures, 2 skipped
```

The remaining failures match the pre-existing non-sandbox lanes observed
earlier in this implementation loop: streaming command timeout partial output,
OpsLogic objective-loop completion, and optional OpsLogic smoke expectations.

Manual integration smokes through the running application:

```text
execute_code pass manual-sandbox network=:host
sandbox syntax status=fail exit=2 output=bash: syntax error: Expected 'then'
sandbox backend="docker" runtimes="python,node" network="restricted"
sandbox_health: status=:available backend=:just_bash network=:disabled
```

The `mix run` manual smokes also emitted a local Phoenix file-watcher warning
because the machine had reached its inotify watch limit. The commands still
completed successfully. Remaining Phase 3 work is a full agent repair smoke
for runtime/syntax errors.

### 2026-05-25 Lua Backend Slice

Added the optional in-process Lua backend:

- Added optional dev/test dependency `:lua, "~> 0.4"`, which brings the
  tv-labs Lua wrapper over Luerl.
- Added `RunicSandbox.Backends.Lua` behind the existing sandbox backend
  behaviour.
- Lua execution runs in a separate BEAM task with `ExecutionRequest.timeout_ms`
  enforced by `Task.yield/2` and `Task.shutdown/2`.
- Lua backend results use the same `ExecutionResult` contract and truthfully
  report `backend: :lua`, `isolation_level: :in_process`, and
  `security_boundary?: false`.
- `RunicSandbox.Profile` now defaults runtimes by backend, so `backend:
  :lua` defaults to `runtimes: [:lua]`.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/coding/tools_test.exs:512 \
  test/runic_ai/coding/review_gate_test.exs \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147 \
  test/runic_ai/coding/trace_event_test.exs \
  test/runic_ai/terminal/event_test.exs \
  test/runic_ai_web/debug_live_test.exs:79 \
  test/runic_ai_web/workbench_live_test.exs
```

Focused result:

```text
58 tests, 0 failures (39 excluded)
```

Manual integration smokes:

```text
lua pass 42 isolation=in_process boundary=false
lua-timeout timeout lua execution timed out
```

### 2026-05-25 Sandbox Read Model Slice

Added Workbench read-model support for persisted sandbox execution records:

- `RunicAI.Terminal.Event.from_trace_event/2` now persists trace inputs as
  JSON-safe terminal event data, allowing sandbox request metadata to survive
  the trace-to-terminal bridge.
- `RunicAI.Workbench.session_snapshot/1` now derives
  `sandbox_executions` from durable terminal events whose phase/trace kind
  identifies sandbox activity.
- Sandbox execution views expose status, sandbox, runtime, network, backend,
  isolation level, duration, exit status, output byte count, changed files,
  artifact summaries, and diagnostics.
- Workbench metrics now include `sandbox_executions`.
- The Workbench trace inspector shows a compact sandbox execution group above
  the general trace list, and session details include the sandbox execution
  count.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs \
  test/runic_ai/workbench_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/coding/tools_test.exs:512 \
  test/runic_ai/coding/review_gate_test.exs \
  test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/assistant/rlm_blueprint_test.exs:147 \
  test/runic_ai/coding/trace_event_test.exs \
  test/runic_ai/terminal/event_test.exs \
  test/runic_ai_web/debug_live_test.exs:79 \
  test/runic_ai_web/workbench_live_test.exs
```

Focused result:

```text
84 tests, 0 failures (39 excluded)
```

### 2026-05-25 Code Execution Feature Flag Slice

Added default-off capability gating for sandbox code execution:

- Capability presets can still describe the `:code_execution` lane, but
  `CapabilityResolver` removes it unless the run explicitly enables it.
- Enabling paths are:
  - explicit `toolsets: [:code_execution]` / `--toolsets code-execution`;
  - `enable_code_execution?: true` or `code_execution_enabled?: true`;
  - `tool_config.code_execution.enabled=true`;
  - app sandbox config `enable_code_execution?: true` or
    `code_execution_enabled?: true`.
- Default `:local_workbench` no longer exposes `execute_code` or
  `sandbox_status` without that explicit enablement.
- Workbench submissions that choose `code-execution` in toolsets still merge
  backend/runtime/network/state/pool settings into the resolved capability
  profile.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/coding/standard_agent_test.exs:77 \
  test/runic_ai/assistant/rlm_blueprint_test.exs \
  test/runic_ai/coding/rlm_agent_test.exs:2135 \
  test/runic_ai_web/workbench_live_test.exs:135 \
  test/runic_ai/sandbox_test.exs \
  test/runic_ai/workbench_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/coding/tools_test.exs:512 \
  test/runic_ai/coding/review_gate_test.exs \
  test/runic_ai/coding/trace_event_test.exs \
  test/runic_ai/terminal/event_test.exs \
  test/runic_ai_web/debug_live_test.exs:79
```

Focused result:

```text
81 tests, 0 failures (126 excluded)
```

### 2026-05-25 Agent Repair Smoke Slice

Added a standard-agent smoke for repairable sandbox diagnostics:

- The agent starts with `:local_workbench` plus explicit
  `toolsets: [:code_execution]`, preserving the default-off feature flag while
  exercising the enabled code-execution lane.
- First tool call runs invalid Bash through `execute_code`.
- The resulting tool observation includes the sandbox syntax error.
- The next model turn reacts to that diagnostic and runs corrected code through
  `execute_code`.
- The agent finishes with a repair summary, proving sandbox runtime errors can
  flow through ordinary tool observations and drive a follow-up repair turn.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/agent/capability_resolver_test.exs \
  test/runic_ai/coding/standard_agent_test.exs:77 \
  test/runic_ai/coding/standard_agent_test.exs:102 \
  test/runic_ai/assistant/rlm_blueprint_test.exs \
  test/runic_ai/coding/rlm_agent_test.exs:2135 \
  test/runic_ai_web/workbench_live_test.exs:135 \
  test/runic_ai/sandbox_test.exs \
  test/runic_ai/workbench_test.exs \
  test/runic_ai/coding/tools_test.exs:465 \
  test/runic_ai/coding/tools_test.exs:512 \
  test/runic_ai/coding/review_gate_test.exs \
  test/runic_ai/coding/trace_event_test.exs \
  test/runic_ai/terminal/event_test.exs \
  test/runic_ai_web/debug_live_test.exs:79
```

Focused result:

```text
82 tests, 0 failures (126 excluded)
```

### 2026-05-25 gVisor Detection Slice

Added the first hardened-backend adapter surface:

- `backend: :gvisor` profiles now dispatch through the container backend
  substrate.
- gVisor status reports `name: :gvisor`, `isolation_level: :gvisor`,
  `security_boundary?: true`, and `container_runtime: "runsc"`.
- Health detection distinguishes Docker daemon availability, generic `runsc`
  binary/runtime visibility, and Docker's registered `runsc` runtime because
  `docker run --runtime runsc` requires the Docker runtime registration.
- When Docker's `runsc` runtime is registered, the same workspace, artifact,
  network-policy, timeout, and runtime dispatch path can execute with
  `--runtime runsc`.
- When the host cannot execute gVisor containers, `Sandbox.status/1` still
  returns structured unavailable health diagnostics instead of crashing.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs
```

Focused result:

```text
9 tests, 0 failures
```

Manual integration on this Linux host:

```text
backend=gvisor status=unavailable isolation=gvisor docker=true runsc=false docker_runsc=false runtime=runsc
diagnostics: [%{message: "Docker runsc runtime is unavailable"}]
```

Attempting execution against the unavailable gVisor backend returns the same
structured preflight details:

```text
error=gvisor container runtime is not available for sandbox execution
details: %{
  backend: :gvisor,
  container_runtime: "runsc",
  docker_available?: true,
  docker_runsc_runtime_available?: false,
  runsc_available?: false
}
```

The manual `mix run` invocations also emitted the existing local Phoenix file
watcher warning about the host inotify watch limit. The sandbox status and
execution preflight checks still completed successfully.

### 2026-05-25 MicroVM Adapter Evaluation Slice

Evaluated the current wrapper options before adding a raw Firecracker/KVM
backend:

| Candidate | Current shape | Fit for RunicAI contract | Decision |
| --- | --- | --- | --- |
| `vmsan` | Firecracker CLI with `create`, `exec`, `upload`, `download`, `snapshot`, network policy, OCI image boot, and `--json` output. | Good first local microVM adapter because it maps directly to `provision`, `exec`, `upload`, `download`, `snapshot`, `reset`, and structured diagnostics. | Prefer as the first local microVM implementation candidate. |
| `SmolVM` | Open-source agent sandbox with Firecracker on Linux, QEMU on macOS, Python SDK, CLI, browser/computer-use surface, snapshots, file sharing, and coding-agent helpers. | Strong candidate for richer agent-computer sessions, but the Python SDK and broader browser/GUI surface make it a larger adapter than the narrow code-execution contract needs first. | Track as a second local/desktop adapter after the core sandbox contract stabilizes. |
| Raw Firecracker | Direct VMM integration. | Maximum control, but RunicAI would own jailer setup, rootfs/image lifecycle, networking, exec transport, file sync, snapshot semantics, and host compatibility. | Defer until a wrapper cannot preserve required policy/trace/workspace semantics. |

Recommendation:

- Add `RunicSandbox.Backends.Vmsan` next as an optional CLI adapter, not a
  direct Firecracker backend.
- Treat `vmsan --json` as the integration boundary and normalize its output
  into the existing `ExecutionResult`, `Instance`, and health maps.
- Keep `backend: :firecracker` reserved for a future direct adapter; use
  `backend: :remote` or a future `:fly` backend for hosted microVM services.
- Require the same default-off code-execution gate, review metadata, and
  terminal trace events before exposing microVM execution in Workbench presets.

Primary-source refresh on 2026-05-25:

- SmolVM README describes disposable AI-agent sandboxes, hardware isolation,
  network controls, snapshots, file sharing, and benchmarks across Firecracker
  on Linux and QEMU on macOS:
  <https://github.com/CelestoAI/SmolVM>
- vmsan docs describe Firecracker-backed microVMs with CLI commands for create,
  exec, upload/download, snapshots, network policy, OCI image boot, and JSON
  output:
  <https://vmsan.dev/>
- Fly's agent-sandbox article describes Sprites as hardware-isolated VM
  sandboxes with checkpoint/restore semantics:
  <https://fly.io/learn/agent-sandbox/>
- Fly Machines API remains the stable documented REST surface for creating,
  waiting on, starting, stopping, suspending, deleting, leasing, and inspecting
  remote Machines:
  <https://fly.io/docs/machines/api/machines-resource/>

### 2026-05-25 Remote MicroVM Backend Slice

Added the first optional remote microVM backend surface:

- `RunicSandbox.Backends.Remote` implements the shared backend behaviour.
- `backend: :remote` now dispatches through the sandbox facade.
- The first provider shape is `provider: :fly_machines`, targeting existing
  Fly Machines through the local `fly` or `flyctl` executable.
- Health reporting is local and configuration-only: it does not contact Fly,
  and it does not expose tokens.
- Health reports `isolation_level: :remote_microvm`,
  `security_boundary?: true`, provider config, CLI availability, auth env
  presence, and structured diagnostics.
- Execution is wired for already-provisioned Machines through
  `fly machine exec --json`; it only runs when the CLI, app, and `machine_id`
  are configured.
- Inline file upload/download and snapshot transport remain explicit
  follow-up work instead of being hidden behind best-effort command strings.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs
```

Focused result:

```text
10 tests, 0 failures
```

Manual integration on this host used a deliberately missing Fly executable to
verify unavailable health and execution preflight:

```text
backend=remote status=unavailable isolation=remote_microvm provider=fly_machines configured=true fly_cli=false auth=false
provider_config: %{
  image: nil,
  app: "runic-sandbox-test",
  region: nil,
  machine_id: "machine-test-id",
  token_env: "RUNIC_AI_MISSING_FLY_TOKEN",
  executable: nil
}
diagnostics: [%{message: "fly or flyctl executable is unavailable"}]
error=remote sandbox provider is not available for execution
```

The manual `mix run` command also emitted the existing local Phoenix file
watcher warning about the host inotify watch limit. The remote backend status
and preflight checks still completed successfully.

This completes the Phase 4 backend-direction items. The remaining Phase 4
validation work is cross-platform health evidence, latency reporting, and a
security posture report.

### 2026-05-25 Extraction Facade Slice

Added the first Phase 5 extraction boundary:

- `RunicSandbox` is now a top-level facade with the target `child_spec/1`,
  `start_link/1`, `exec/2`, `status/1`, `provision/1`, and
  `exec_with_instance/2` API.
- `RunicAI.Application` starts `{RunicSandbox, sandbox_opts}` while preserving
  the existing sandbox process name for current Workbench and tool
  integrations.
- A supervised test now starts `{RunicSandbox, sandboxes: [...]}` directly and
  executes through `RunicSandbox.exec/2`, matching the future standalone
  library configuration shape.
- The implementation modules now live under `packages/runic_sandbox`; the
  RunicAI-local module is a compatibility shim.

Validation completed:

```sh
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs
mix runic_sandbox.validate_standalone
```

Focused result:

```text
37 tests, 0 failures
```

### 2026-05-25 Standalone Mix Project Validation Slice

Added a standalone validation entrypoint:

- `mix runic_sandbox.validate_standalone` creates a temporary Mix project with a
  path dependency on this checkout and a direct `:just_bash` dependency.
- The generated project uses isolated temp `deps` and `_build` directories,
  does not start `RunicAI.Application`, and starts its own supervisor with
  `{RunicSandbox, sandboxes: [...]}`.
- The smoke script calls `RunicSandbox.status/1` and `RunicSandbox.exec/2`
  through the public facade and verifies `:just_bash`,
  `:in_process_virtual`, and the expected stdout.
- The temporary project is removed by default; `--keep` can preserve it for
  debugging.

Validation completed:

```sh
mix format lib/mix/tasks/runic_sandbox.validate_standalone.ex
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs
mix runic_sandbox.validate_standalone
```

Focused result:

```text
37 tests, 0 failures
```

Standalone result:

```text
standalone status=ok backend=just_bash isolation=in_process_virtual
RunicSandbox standalone smoke passed in /tmp/runic_sandbox_standalone_4866
```

Important extraction evidence:

- The facade and child-spec shape work from a separate Mix project.
- The first standalone validation used the monolithic `:runic_ai` path
  dependency, which proved the facade but also proved the dependency graph was
  too heavy until the package split.
- The validation rerun also exposed and fixed a stale stateful Docker workspace
  collision across BEAM runs by adding the current system time to the generated
  stateful workspace path.

### 2026-05-25 Independent Package Split Slice

Moved the stable sandbox substrate into a local independent package:

- `packages/runic_sandbox` is now a standalone Mix project with app
  `:runic_sandbox`.
- The package owns `RunicSandbox`, `RunicSandbox.Error`, profile/policy/
  workspace/request/result/instance contracts, the manager, backend behaviour,
  and the JustBash, Lua, Docker/gVisor, and remote Fly Machines adapters.
- Package dependencies are limited to `:jason` plus optional backend
  dependencies `:just_bash` and `:lua`.
- RunicAI now depends on `{:runic_sandbox, path: "packages/runic_sandbox"}`.
- `RunicAI.Sandbox` is reduced to a compatibility facade over `RunicSandbox`.
- RunicAI product code still owns tool definitions, Workbench health/read
  models, review gates, trace events, terminal persistence, capability-profile
  resolution, and the default Docker image build task.
- The standalone validation task now depends on `packages/runic_sandbox`
  directly instead of the monolithic RunicAI app.

Validation completed:

```sh
cd packages/runic_sandbox && mix test
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs
mix runic_sandbox.validate_standalone
```

Package result:

```text
3 tests, 0 failures
```

RunicAI focused result:

```text
37 tests, 0 failures
```

Standalone package result:

```text
standalone status=ok backend=just_bash isolation=in_process_virtual
RunicSandbox standalone smoke passed in /tmp/runic_sandbox_standalone_9
```

This completes the main Phase 5 package split. The adapter publication strategy
is captured in the backend report slice below.

### 2026-05-25 Backend Report Slice

Added executable package-level validation reports:

- `RunicSandbox.Reports.health_matrix/1` returns structured backend health for
  JustBash, Lua, Docker, gVisor, and the remote Fly Machines provider shape.
- `RunicSandbox.Reports.latency_report/1` measures status, provision, and exec
  latency for executable local profiles.
- `RunicSandbox.Reports.security_posture/0` lists actual backend boundaries,
  known limitations, and publication strategy.
- `mix runic_sandbox.report` prints the report as text or JSON.
- The report includes platform notes for Linux, macOS, Windows/WSL, and remote
  providers. The current live run is Linux evidence; macOS and Windows/WSL rows
  are explicit compatibility expectations until CI or real hosts run the task.

Validation completed:

```sh
cd packages/runic_sandbox && mix test
cd packages/runic_sandbox && mix runic_sandbox.report --format json
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs
```

Package result:

```text
4 tests, 0 failures
```

RunicAI focused result:

```text
37 tests, 0 failures
```

Live Linux backend health summary:

| Backend | Status | Isolation | Notes |
| --- | --- | --- | --- |
| `just_bash` | `available` | `in_process_virtual` | Not a security boundary. |
| `lua` | `available` | `in_process` | Not a security boundary. |
| `docker` | `available` | `container` | Default image available locally. |
| `gvisor` | `unavailable` | `gvisor` | Docker exists, but Docker `runsc` runtime is unavailable. |
| `remote` | `unavailable` | `remote_microvm` | Fly CLI exists, but app and machine id are not configured. |

Latency sample from the live Linux run:

| Backend | Status check | Provision | Cold exec | Warm exec | Snapshot | Reset |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `just_bash` | 4 us | 653 us | 18,288 us | 78 us | 0 us | 0 us |
| `lua` | 5 us | 9 us | 33,252 us | 176 us | 1 us | 0 us |

Security posture and adapter publication decision:

- `just_bash` and `lua` remain in the base package behind optional
  dependencies.
- Docker and gVisor stay in the base package because they use the Docker CLI
  and require no Elixir dependency.
- Fly-specific lifecycle beyond local health and `fly machine exec` should
  become `runic_sandbox_fly` once credential policy, machine lifecycle, and
  Sprites support grow.
- vmsan and direct Firecracker should be separate adapter packages if/when
  implemented, because they own local microVM lifecycle and host requirements.

### 2026-05-25 Completion Audit

Final local validation after the package split, report task, and documentation
cleanup:

```sh
cd packages/runic_sandbox && mix test
mix compile --warnings-as-errors
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs
mix test test/runic_ai/sandbox_test.exs test/runic_ai/workbench_test.exs \
  test/runic_ai/coding/tools_test.exs \
  test/runic_ai/coding/rlm_agent_test.exs \
  test/runic_ai/agent/capability_resolver_test.exs
cd packages/runic_sandbox && mix runic_sandbox.report --format json
mix runic_sandbox.validate_standalone
mix test
```

Passing focused results:

```text
packages/runic_sandbox: 4 tests, 0 failures
RunicAI focused sandbox/workbench tests: 37 tests, 0 failures
RunicAI sandbox/tool/RLM integration tests: 142 tests, 0 failures
standalone status=ok backend=just_bash isolation=in_process_virtual
RunicSandbox standalone smoke passed in /tmp/runic_sandbox_standalone_11138
```

The RLM `:script` node path now routes through `Tools.execute_code/4`, which
means Runic workflow nodes use the same sandbox request/result contract, review
path, and sandbox trace events as ordinary model-visible tools. `execute_code`
also accepts the non-Bash runtimes carried by sandbox profiles, with Lua covered
by an in-process focused test and Docker multi-runtime coverage supplied by the
image smoke task.

Full-suite result:

```text
802 tests, 3 failures, 2 skipped
```

The remaining full-suite failures are not in the sandbox implementation path:

- `test/runic_ai/coding/command_test.exs:69` intermittently loses partial output
  on a streaming command timeout.
- `test/runic_ai/coding/rlm_objective_loop_test.exs:1091` still stops the
  OpsLogic implementation follow-up with `:stop_failed`.
- `test/runic_ai/rlm/robustness_test.exs:141` still expects `:pass` even when
  optional OpsLogic DB/browser smoke checks are skipped by missing environment
  flags.

## Resolved Decisions

- Should the first stateful sandbox be per RunicAI session, per agent, or per
  workflow run?
  * Answer: Stateful sandboxes should primarily exist per workbench / RunicAI
    session. If the app is running a sandbox should exist when configured. Per
    agent or workflow-run sandboxes depend on that agent's config, but the
    default should be the common sandbox so pre-warmed latency benefits apply.
- Should the first container backend copy the workspace into the sandbox, bind
  mount read-only, or support both with different policy labels?
  * Answer: Default to `workspace: [mode: :copy_in]`. Bind mounts should be a
    separate explicit workspace mode with review metadata because the host
    exposure and mutation story is different. Host writes should surface as
    `files_changed` and `sandbox://...` artifacts first.
- How should package caches be shared without leaking credentials or letting
  sandbox code mutate trusted host cache state?
  * Answer: Do not mount trusted host package caches by default. Any cache
    sharing should be through sandbox-owned cache volumes or remote-provider
    cache policies with no credentials, explicit review metadata, and clear
    reset semantics.
- Should sandboxed code be allowed to call back into RunicAI tools, or should
  it only receive input files/stdin and return output files/stdout?
  * Answer: The sandbox contract should be data-only: input files/stdin/source
    in, stdout/stderr/files/artifacts/diagnostics out. Tool callbacks should
    stay in the agent/tool layer outside the sandbox so review gates and traces
    remain observable.
- Should exported sandbox changes always become patch artifacts, or can a
  trusted local profile apply them directly after review?
  * Answer: Default to patch/artifact export. A trusted direct-apply profile can
    be added later, but it must be an explicit policy escalation and review
    reason rather than a backend default.
- Which backend health checks should block a run versus merely downgrade the
  selected capability profile?
  * Answer: If a run explicitly selects a backend, unavailable health blocks
    execution with structured diagnostics. Downgrade is only allowed when the
    capability profile declares an ordered fallback list; the trace must record
    both requested and selected backend truth.

## Sources

- Firecracker README:
  <https://github.com/firecracker-microvm/firecracker>
- Firecracker jailer docs:
  <https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md>
- gVisor:
  <https://gvisor.dev/>
- Kata Containers virtualization design:
  <https://github.com/kata-containers/kata-containers/blob/main/docs/design/virtualization.md>
- Bubblewrap:
  <https://github.com/containers/bubblewrap>
- Wasmtime introduction:
  <https://docs.wasmtime.dev/introduction.html>
- Wasmtime security:
  <https://docs.wasmtime.dev/security.html>
- just_bash Hex package:
  <https://hex.pm/packages/just_bash>
- just-bash project docs:
  <https://justbash.dev/>
- tv-labs/lua:
  <https://github.com/tv-labs/lua>
- Fly Sprites:
  <https://sprites.dev/>
- Fly agent sandbox article:
  <https://fly.io/learn/agent-sandbox/>
- Fly Machines API:
  <https://fly.io/docs/machines/api/machines-resource>
- E2B code interpreter:
  <https://github.com/e2b-dev/code-interpreter>
- Daytona:
  <https://github.com/daytonaio/daytona>
- Kilntainers:
  <https://mcp.so/server/kilntainers/Kiln-AI>
- SmolVM:
  <https://github.com/CelestoAI/SmolVM>
- vmsan:
  <https://vmsan.dev/>
- Mentat:
  <https://www.getmentat.run/>
- cto.new X thread:
  <https://x.com/ctodotnew/status/2017271423782494590>
- Arlan just-bash X thread:
  <https://x.com/arlanr/status/2041215978957389908>
