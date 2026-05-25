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

The target shape should be extractable as an independent Elixir library:

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

RunicAI can initially keep this internal under `RunicAI.Sandbox` while the
contracts settle, then extract the library once two real backends exist.

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

- [ ] Define `Sandbox.Profile`, `Sandbox.Policy`, `ExecutionRequest`, and
      `ExecutionResult` structs.
- [ ] Define `isolation_level` values:
      `:in_process`, `:wasi`, `:namespace`, `:container`, `:gvisor`,
      `:microvm`, `:remote_microvm`.
- [ ] Decide whether the initial module namespace is `RunicAI.Sandbox` or a
      sibling package spike.
- [ ] Add a small local feature flag so code execution remains disabled by
      default.

Validation:

- [ ] Unit tests for request/result validation.
- [ ] Unit tests proving isolation-level metadata is required for every backend
      result.

### Phase 1: Internal JustBash And Lua Backends

- [ ] Wrap current optional `JustBash` usage behind the sandbox backend
      behaviour.
- [ ] Add a Lua/Luerl backend spike for small transform functions.
- [ ] Return the same `ExecutionResult` shape from both.
- [ ] Mark both as `isolation_level: :in_process`.

Validation:

- [ ] Scripted tests for stdout/stderr/status/timeouts.
- [ ] Tests proving these backends are not advertised as arbitrary binary
      execution.

### Phase 2: Local Container Backend

- [ ] Add Docker backend using CLI first, with command construction kept
      argv-only.
- [ ] Support stateless one-shot execution.
- [ ] Support stateful per-session containers.
- [ ] Build a default multi-runtime image for Elixir, Bash, Lua, Python, Node,
      git, rg, jq, sqlite, and common build tools.
- [ ] Capture changed files as artifacts before any host export.

Validation:

- [ ] Run Elixir, Python, Node, Lua, and Bash smoke requests.
- [ ] Prove network disabled blocks egress.
- [ ] Prove host workspace writes require explicit export/patch flow.

### Phase 3: RunicAI Toolset And Workbench Surfacing

- [ ] Add `code_execution` capability profile config.
- [ ] Add `sandbox_status` and `execute_code` tool definitions.
- [ ] Add Workbench settings for backend, runtimes, network, state mode, and
      warm pool.
- [ ] Persist sandbox execution events and backend metadata.
- [ ] Add review gates for policy escalation, network enablement, and host
      export.

Validation:

- [ ] LiveView tests for submitting a run with code execution disabled/enabled.
- [ ] Agent smoke where syntax/runtime errors return repairable diagnostics.

### Phase 4: Hardened Backends

- [ ] Add gVisor/runsc container backend detection.
- [ ] Evaluate SmolVM or vmsan as a local microVM adapter before implementing
      raw Firecracker.
- [ ] Add direct Firecracker/KVM backend only if wrappers are insufficient.
- [ ] Add Fly Sprites or Machines as an optional remote microVM backend.

Validation:

- [ ] Backend health matrix for Linux, macOS, and Windows/WSL.
- [ ] Latency report for cold start, warm exec, reset, and snapshot/restore.
- [ ] Security posture report listing actual backend boundaries and known
      limitations.

### Phase 5: Extraction

- [ ] Split stable sandbox contracts into an independent Elixir package.
- [ ] Keep RunicAI-specific tool definitions, WebUI, persistence, and RLM
      components in RunicAI.
- [ ] Publish adapters as optional dependencies where possible.

Validation:

- [ ] Use the library from RunicAI through public child specs only.
- [ ] Use the library in a tiny standalone Mix project.

## Initial Recommendation

Start with an internal `RunicAI.Sandbox` contract and two backends:

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

## Open Questions

- Should the first stateful sandbox be per RunicAI session, per agent, or per
  workflow run?
  * Answer: Stateful sandboxes should primarily exist per workbench / RunicAI session - if the app is running a sandbox should exist if configured. Per agent/workflow run will depend on that agent's config but will default to the common sandbox so low latency pre-warmed benefits apply.
- Should the first container backend copy the workspace into the sandbox, bind
  mount read-only, or support both with different policy labels?
- How should package caches be shared without leaking credentials or letting
  sandbox code mutate trusted host cache state?
- Should sandboxed code be allowed to call back into RunicAI tools, or should
  it only receive input files/stdin and return output files/stdout?
- Should exported sandbox changes always become patch artifacts, or can a
  trusted local profile apply them directly after review?
- Which backend health checks should block a run versus merely downgrade the
  selected capability profile?

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
