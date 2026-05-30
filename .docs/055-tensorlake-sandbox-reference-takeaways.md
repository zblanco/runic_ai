# Tensorlake Sandbox Reference Takeaways

Status: proposed

Date: 2026-05-30

## Purpose

Tensorlake's sandbox documentation is a useful external reference because it
targets the same broad problem space as `runic_sandbox`: isolated execution for
agents, streaming process output, long-lived sessions, CLI-agent workspaces,
files, snapshots, images, permissions, and network controls.

The important caveat is scope. Tensorlake is a managed remote infrastructure
platform with an API gateway, authenticated proxy, image registry, hosted
MicroVM fleet, cloud lifecycle control plane, and orchestration runtime.
`runic_sandbox` is a library substrate used by RunicAI and other local or
provider-backed consumers. We should borrow contract shapes and readiness
language, not recreate a cloud product inside the package.

This document compares the useful Tensorlake patterns against the current
RunicAI / `runic_sandbox` direction in:

- `.docs/052-runic-sandbox-streaming-and-mcp-dogfood-plan.md`
- `.docs/053-runic-sandbox-consumer-driven-improvement-plan.md`
- `.docs/054-runic-ai-generated-component-promotion-plan.md`

## Sources Reviewed

- [Tensorlake Sandboxes Overview](https://docs.tensorlake.ai/sandboxes/introduction)
- [Tensorlake documentation index](https://docs.tensorlake.ai/llms.txt)
- [Execute Commands](https://docs.tensorlake.ai/sandboxes/commands)
- [Process Management](https://docs.tensorlake.ai/sandboxes/processes)
- [SSH and PTY Sessions](https://docs.tensorlake.ai/sandboxes/pty-sessions)
- [Networking](https://docs.tensorlake.ai/sandboxes/networking)
- [Lifecycle](https://docs.tensorlake.ai/sandboxes/lifecycle)
- [File Operations](https://docs.tensorlake.ai/sandboxes/file-operations)
- [Snapshots](https://docs.tensorlake.ai/sandboxes/snapshots)
- [Sandbox Images](https://docs.tensorlake.ai/sandboxes/images)
- [Environment Variables](https://docs.tensorlake.ai/sandboxes/environment-variables)
- [Local Tunnels](https://docs.tensorlake.ai/sandboxes/tunnels)
- [Tool Calls](https://docs.tensorlake.ai/sandboxes/tool-calls)
- [Orchestration + Sandboxes](https://docs.tensorlake.ai/applications/sandboxes)
- [Agent Skills](https://docs.tensorlake.ai/agent-skills)
- [Skills in Sandboxes](https://docs.tensorlake.ai/sandboxes/skills-in-sandboxes)

## Executive Takeaways

Tensorlake's strongest reusable ideas for us are:

- split command execution, managed background processes, and PTY sessions into
  distinct contracts;
- make process output followable in real time, with separate stdout/stderr
  access and a terminal EOF/exit signal;
- expose stdin, signal, kill, close-stdin, disconnect, reconnect, and resize as
  lifecycle operations, not incidental handle metadata;
- separate "agent in sandbox" from "sandbox as tool" as first-class integration
  patterns;
- make network policy explicit with deny-by-default plus allow-list and deny-list
  concepts;
- distinguish suspend/resume from reusable snapshots;
- treat images as reusable environment definitions, but keep image build and
  registry semantics out of the core sandbox execution API;
- bake agent instructions/skills into sandbox images when the target is a
  contained CLI agent.

The strongest non-fit ideas are:

- hosted proxy domains, public ingress, authenticated user-port routing, and
  cloud API key auth;
- a full image registry or image-builder control plane;
- SSH remote development as a core library feature;
- managed autoscaling, organization/project scoping, billing, compliance, and
  dashboard-level operations;
- memory snapshot support as a required baseline across local Docker, Fly,
  Sprites, Vmsan, and in-process adapters.

## Tensorlake Mental Model

Tensorlake models sandboxes as managed MicroVMs that can be created on demand,
named, suspended, resumed, snapshotted, restored, reached through a proxy, and
driven through SDK, CLI, HTTP, SSH, WebSocket PTY, and process APIs. Its docs
also place sandboxes inside a larger orchestration platform: functions,
durable execution, parallel subagents, map/reduce, autoscaling, secrets, and
observability.

For RunicAI, the analogous split is:

```text
RunicAI / Runic
  -> workflow orchestration, generated component lifecycle, trace events,
     promotion policy, model-visible tools, operator surfaces

runic_sandbox
  -> backend-neutral execution/session/process/file/network contracts

specific backends
  -> Docker, GVisor, Vmsan, Sprites, Fly/Remote, Lua, JustBash implementation
     details
```

The package should therefore provide the common vocabulary and safe dispatch
surface. It should not become Tensorlake's control plane.

## Feature Comparison

| Area | Tensorlake shape | Current RunicAI / runic_sandbox shape | Takeaway |
| --- | --- | --- | --- |
| Isolation substrate | Hosted MicroVMs backed by Firecracker/CloudHypervisor. | Backend-neutral library adapters: Docker/GVisor, Vmsan, Sprites, Fly/Remote, JustBash, Lua. | Keep backend-neutral. Do not assume MicroVM everywhere, but expose isolation level honestly. |
| Lifecycle | Ephemeral vs named sandboxes; states for pending/running/snapshotting/suspending/suspended/terminated. | `Session`, `Instance`, `Manager`, leases, checkpoints, backend health. | Add clearer lifecycle/readiness states for active attach and pooled sessions. |
| One-shot command | `run` / `exec` with stdout/stderr, env, working dir, timeout. | `RunicSandbox.exec/2`, `exec_session/3`, `ExecutionRequest`, `ExecutionResult`. | Mostly aligned. Keep improving stdout/stderr separation and env/workdir coverage by backend. |
| Streaming command output | Follow process output via line events and EOF; stdout/stderr/combined output endpoints. | `AttachHandle.events` with `:stdout_chunk`, `:stderr_chunk`, `:exec_finished`; Docker live, others terminal-adapted. | Adopt a normalized event bridge and explicit EOF/terminal semantics. |
| Background processes | Start, list, follow output, signal, kill, write stdin, close stdin. | Attach starts a process-like handle, but no generic process registry/list/signal contract yet. | Add a process lifecycle contract separate from command-result execution. |
| PTY sessions | Separate PTY API with rows/cols, resize, disconnect, reconnect, kill, WebSocket frames. | Attach is byte/event oriented, not PTY-specific. | Add optional PTY capability later. Do not overload attach with terminal UI semantics. |
| Stdin | Process `stdin_mode: pipe`; write stdin and close stdin. PTY send input separately. | `write_stdin/3`; terminal adapters return unsupported. | Add `stdin_supported?`, `stdin_close_supported?`, and maybe `close_stdin/2`. |
| Signals/cancel | POSIX signal and kill APIs. | `close_attach/2`; backend-specific cancellation not fully expressed. | Add `signal_attach/3` or process signal support for live backends. |
| File operations | Proxy file API plus CLI copy/read/write/list/delete. | File/session/artifact APIs exist in `runic_sandbox`. | Existing package direction is right; make proof artifacts first-class in RunicAI. |
| Snapshots | Filesystem snapshots and memory snapshots; suspend/resume are distinct. | Checkpoints exist; Vmsan may provide stronger VM-level semantics later. | Keep `Checkpoint` generic. Add checkpoint type/effective capability metadata. |
| Images | Registered project-scoped images built from Dockerfile or SDK image DSL. | RunicAI has local image task; Docker backend takes image names; Vmsan assets are local. | Adopt image contract docs/profiles, not a registry/build platform. |
| Skills / CLI agents | Agent skill files can be baked into images for Claude Code, Codex, ADK, Cursor, etc. | Agent images are still an open item for Ariston-style containment. | Very relevant: define image contents and skill/instruction paths for contained CLI agents. |
| Network outbound | Default internet on; can disable, allow explicit destinations, or deny specific destinations. | `Policy.network` has `:disabled`, `:host`, `:restricted`; restricted is not yet a real allow-list locally. | Highest-priority adoption: explicit allow-list metadata and fail-closed readiness. |
| Ingress | Public/authenticated proxy hostnames and exposed ports. | Services/proxies exist, but no public hosted gateway. | Do not copy public ingress. Use local proxy/tunnel abstractions only where needed. |
| Local tunnels | Authenticated WebSocket tunnel from local port to sandbox port. | Proxy/service APIs exist; MCP-over-boundary undecided. | Borrow the "private tunnel" concept for MCP/local service bridging, not the hosted proxy. |
| Secrets/env | Secrets at sandbox creation; command and PTY scoped env. | Env appears in execution requests; secret policy is not central yet. | Add scoped env/secret intent to profiles and generated proof policy. |
| Orchestration patterns | Agent-in-sandbox vs sandbox-as-tool. | RunicAI can support both; generated component proof starts as sandbox-as-tool. | Make both modes explicit in RunicAI docs and capability profiles. |
| Observability | Hosted traces/logging/progress in Orchestrate. | RunicAI owns trace/terminal/workbench events. | Keep observability in RunicAI, fed by `runic_sandbox` events. |

## Adopt Into `runic_sandbox`

### 1. Process Contract Above Attach

Tensorlake's process API is clearer than treating every live command as only an
attach handle. `runic_sandbox` should keep `attach` as the streaming surface,
but add a process vocabulary that can be reported in capabilities and used by
live backends:

```elixir
%{
  process: %{
    pid: "...",
    status: :running | :exited | :signaled | :killed | :lost,
    stdin_writable?: true,
    stdout_mode: :capture | :stream | :discard,
    stderr_mode: :capture | :stream | :discard,
    started_at: DateTime.t(),
    ended_at: DateTime.t() | nil
  }
}
```

Near-term additions:

- `Capabilities.attach_mode/1`;
- `Capabilities.stdin_supported?/1`;
- `Capabilities.signal_supported?/1`;
- `Capabilities.process_list_supported?/1`;
- optional backend callbacks for `signal_attach/3`, `close_stdin/2`, and
  eventually `list_processes/2`.

This would help Ariston because a contained provider CLI is a long-running
process, not just a command result. It helps RunicAI because generated proof
runs can start terminal-adapted but graduate to live process proof without
changing consumer shape.

### 2. Event Stream Normalization

Tensorlake documents a practical stream model: output events plus EOF, with
separate stdout/stderr and combined-output access. `runic_sandbox` already has
`SessionEvent` chunks and terminal events, but consumers need a consistent
bridge.

Recommended contract:

- every stream has one `:exec_started`;
- chunks carry `stream`, `chunk`, byte count, and optional sequence;
- terminal status is `:exec_finished`;
- stream exhaustion without terminal status is a synthetic failure;
- backend failure can override an earlier CLI success;
- terminal adapters must report `streaming_live?: false`.

This should be consumed by RunicAI's generated-component proof log and is
compatible with Ariston's `SandboxBackendBridge`.

### 3. Explicit Network Policy

Tensorlake makes a useful distinction:

- internet enabled or disabled;
- explicit outbound allow-list;
- explicit outbound deny-list;
- inbound exposure is separate from outbound control.

For `runic_sandbox`, this maps to:

```elixir
%RunicSandbox.Policy{
  network: :restricted,
  metadata: %{
    allow_out: [
      %{host: "127.0.0.1", port: 4567, purpose: :mcp}
    ],
    deny_out: [],
    deny_by_default?: true
  }
}
```

Do not silently map requested allow-list policy to `--network none`. If a
backend cannot enforce it, health/readiness should say so and execution should
fail closed for profiles that require it.

### 4. PTY As Optional Capability

PTY sessions are useful for human terminals, browser terminal UIs, and some CLI
agents, but they are not the same as stdout/stderr process streaming. A PTY
collapses streams and adds terminal dimensions, resize, reconnect, and raw
terminal bytes.

Recommendation:

- do not change `AttachHandle` into a PTY handle;
- add optional `pty_supported?` and a later `create_pty/3` contract;
- require rows/cols/resize/disconnect/reconnect semantics only for backends
  that claim PTY support;
- keep Ariston's provider CLI containment on process attach first unless the
  provider CLI truly requires terminal behavior.

### 5. Private Boundary/Tunnel Concept For MCP

Tensorlake's local tunnels are platform-specific, but the concept is useful:
create an authenticated/private byte path to a service inside or outside the
sandbox without making a public port.

For our case, the direction is usually inverse: a process inside the sandbox
needs to reach a host MCP endpoint or tool service. The contract should describe
the boundary, not the transport:

```elixir
%{
  boundary: :mcp,
  mode: :host_forward | :unix_socket | :egress_allowlist,
  endpoint: "http://127.0.0.1:4567/mcp",
  exposed_to_sandbox_as: "http://mcp.boundary.local",
  public?: false
}
```

This is a better fit than importing Tensorlake's public proxy model.

### 6. Image Profiles, Not Image Registry

Tensorlake's image system is a managed build/registration service. The useful
part for us is the shape of reusable environment definitions:

- base image;
- packages and runtimes;
- working directory;
- command entrypoints;
- baked skills/instructions;
- resource defaults;
- whether services/systemd are expected.

RunicAI should define image profiles for:

- generated component proof;
- contained coding agent;
- contained Ariston-style provider CLI;
- browser/computer-use experiments only when needed.

`runic_sandbox` should accept image identifiers and report image metadata. It
should not own an image registry.

## Adopt Into RunicAI

### 1. Keep Both Integration Patterns

Tensorlake's "agent in sandbox" vs "sandbox as tool" split maps cleanly:

| Pattern | RunicAI meaning | First use |
| --- | --- | --- |
| Sandbox as tool | Host coordinator opens sandbox sessions for generated code proof. | Generated component promotion. |
| Agent in sandbox | Agent CLI or REPL runs inside the boundary and calls back through MCP/tools. | Later interactive containment and Ariston-style harnesses. |

RunicAI should start with "sandbox as tool" for generated leaf proof. It is
safer and does not block on full MCP-over-boundary. "Agent in sandbox" should
require live attach, stdin, restricted egress, and MCP boundary support.

### 2. Component Promotion Uses Process Evidence

Generated component proof should store process-like evidence:

- command and args;
- working directory;
- env scope;
- backend/session/attach ids;
- stdout/stderr chunk refs;
- exit status or signal;
- timeout/cancel reason;
- network policy used;
- artifacts and file diffs.

This keeps the proof log comparable across Docker, Vmsan, Sprites, Fly, Lua,
and JustBash.

### 3. Agent Images Should Bake Instructions

Tensorlake's skill-in-image docs are directly relevant. For contained CLI
agents, RunicAI should define image contents including:

- the agent CLI binary or package;
- git and common build tools;
- language runtimes;
- repo checkout/workspace path conventions;
- `AGENTS.md`, `SKILL.md`, or provider-specific instruction paths;
- minimal auth bootstrap;
- MCP endpoint configuration surface.

This should live in RunicAI image/profile docs and build tasks, with
`runic_sandbox` only receiving the selected image/profile.

### 4. Env Scope Matters

Tensorlake distinguishes command-scoped and PTY-scoped env. RunicAI should do
the same in generated component proof policy:

- command env for one compile/test/proof command;
- session env for repeated proof commands inside one sandbox;
- PTY env only for interactive terminal sessions;
- secrets should be explicit and redacted in trace output.

## Do Not Adopt

Do not adopt these Tensorlake platform features into `runic_sandbox`:

- hosted sandbox proxy domain;
- public unauthenticated ingress;
- account/project/org auth model;
- cloud image registry;
- serverless function deployment;
- autoscaling and queuing;
- dashboard/compliance/product operations;
- SSH key management as a package feature;
- memory snapshots as a universal baseline;
- remote IDE support as a core API.

Some of these may appear in a future product built on top of RunicAI, but they
are not `runic_sandbox` responsibilities.

## Recommended Changes To Existing Plans

### Update `.docs/053`

Add or emphasize:

- a process contract layer above `AttachHandle`;
- `close_stdin/2` and signal/kill semantics for live backends;
- explicit `allow_out` / `deny_out` metadata under `Policy.network:
  :restricted`;
- optional PTY capability as a separate future contract;
- image profile docs for contained CLI agents.

### Update `.docs/054`

Add or emphasize:

- generated proof should store process evidence, not just execution result
  summaries;
- command/session/PTY scoped env should be distinct;
- sandbox-as-tool is the first generated-component promotion lane;
- agent-in-sandbox is a later lane gated on live attach and MCP boundary;
- contained CLI agent images should bake `AGENTS.md` / skill files into
  provider-specific discovery paths.

## Revised Priority Backlog

1. Add attach/process capability helpers:
   - `attach_mode`;
   - `stdin_supported?`;
   - `stdin_close_supported?`;
   - `signal_supported?`;
   - `stderr_separate?`;
   - `pty_supported?`.
2. Add shared event bridge semantics:
   - chunk order;
   - stdout/stderr/combined view;
   - EOF/terminal reconciliation;
   - synthetic missing-terminal failure;
   - backend-failure precedence.
3. Add restricted network metadata:
   - `allow_out`;
   - `deny_out`;
   - `deny_by_default?`;
   - backend support/readiness reporting.
4. Add live process lifecycle operations:
   - close stdin;
   - signal;
   - kill;
   - active process state in session manager metadata.
5. Define RunicAI image profiles:
   - generated proof image;
   - contained agent CLI image;
   - Ariston-compatible provider CLI image shape.
6. Define optional PTY contract after process attach stabilizes.
7. Define MCP boundary as a private service/tunnel/allow-list contract, not as
   hosted public ingress.

## Practical Fit Summary

Tensorlake is a good north-star for product ergonomics. Its SDK surface makes
the core execution concepts easy to name: sandbox lifecycle, command execution,
process management, PTY sessions, files, snapshots, images, network policy, and
agent integration patterns.

For `runic_sandbox`, the right move is to make those concepts backend-neutral
and capability-gated. For RunicAI, the right move is to consume them in the
generated-component promotion flow first, then graduate to full contained CLI
agents once restricted networking and MCP-over-boundary are real.
