# Runic Sandbox Streaming And MCP Dogfood Plan

## Context

The `runic_sandbox` memo from the Ariston section-6 work is useful feedback for RunicAI because it
pushes on the same gap we have not dog-fooded hard yet: the package has solid one-shot execution,
stateful sessions, service/proxy/checkpoint contracts, and live-lane smoke coverage, but the current
agent-facing path still treats sandbox execution mostly as terminal command capture.

For full agent containment, the missing layer is not another one-shot tool. It is an interactive
process contract:

- start a long-lived command inside an opened session;
- stream stdout/stderr as `SessionEvent` chunks while it runs;
- write stdin while it runs;
- close/cancel the attached process independently from closing the session;
- keep MCP/tool callbacks reachable through a scoped boundary instead of general network egress.

## Implemented Contract Scaffolding

The local package now has the substrate for backend-neutral attach:

- `RunicSandbox.AttachHandle` as the provider-neutral handle for an attached process.
- Optional `RunicSandbox.Backend` callbacks:
  - `attach_session/3`
  - `write_stdin/3`
  - `close_attach/2`
- `RunicSandbox.attach/3`, `RunicSandbox.write_stdin/3`, and `RunicSandbox.close_attach/2` facade
  functions.
- `Capabilities.streaming?`, defaulting to `false`, reported in session capabilities and backend
  health metadata.
- `SessionEvent` chunk event types:
  - `:stdout_chunk`
  - `:stderr_chunk`
  - optional `:stdin_ack`

This keeps the package honest: consumers can feature-detect streaming, unsupported backends fail
closed, and each backend has a shared target contract.

## Backend Results

| Backend | Attach mode | Stdin after attach | Dogfood result |
| --- | --- | --- | --- |
| `:docker` / `:gvisor` | Live `Port` stream over `docker run -i` | Supported through `RunicSandbox.write_stdin/3` | Live local smoke passed with `streaming_live?: true`, `:stdout_chunk`, and `:exec_finished` |
| `:just_bash` | Terminal attach adapter over existing `exec/3` | Not supported after execution | Test smoke passed with `streaming_live?: false` |
| `:lua` | Terminal attach adapter over existing `exec/3` | Not supported after execution | Conditional test smoke passes when optional `:lua` is available |
| `:vmsan` | Terminal attach adapter over `vmsan exec` | Not supported after execution | Mocked CLI test passed; live host is unavailable because Firecracker/jailer/images plus nftables kernel support are missing |
| `:sprites` | Terminal attach adapter over HTTP exec | Not supported after execution | Mocked API test passed; live Sprites smoke passed with `cwd: "/home/sprite"` |
| `:remote` | Terminal attach adapter over Fly machine exec | Not supported after execution | Fake provider executable test passed; live Fly smoke passed against existing `libbit` machine `148e2d02f1d348` |

The distinction between `streaming?` and `streaming_live?` matters:

- `session.capabilities.streaming?` means the backend can produce the attach event model.
- `handle.metadata.streaming_live?` means the chunks are produced while the process is actually
  running, not adapted from a terminal result.

Docker currently merges container stderr into stdout chunks because the local implementation uses an
Erlang port over the Docker CLI. Provider-native transports that expose stdout/stderr separately
should emit distinct `:stdout_chunk` and `:stderr_chunk` events.

## Remaining Dogfood Sequence

1. **NDJSON bridge smoke.** Add a small harness that consumes stdout chunks, reconstructs
   line-delimited JSON, and records the same terminal events the existing coding/workbench path
   expects.
2. **Restricted MCP egress.** Make `Policy.network == :restricted` mean more than `--network none`.
   Start with an explicit single-host allow-list in policy metadata for the host MCP endpoint, then
   test that unrelated egress remains denied.
3. **Provider-native live streams.** Promote Sprites WebSocket exec and future Vmsan/Fly streaming
   control channels from terminal adapters to `streaming_live?: true` handles when those transports
   are available.
4. **Manager lifecycle.** Decide whether an attached process should mark a pooled session `:busy`
   while the event stream is active.

## Consumer Integration Rule

RunicAI core should consume this through `packages/runic_sandbox`, not by duplicating backend logic.
The higher layers should only know:

- whether `session.capabilities.streaming?` is true;
- how to call `RunicSandbox.attach/3`;
- how to bridge `SessionEvent` chunks into RunicAI terminal/coding events;
- how to surface unsupported streaming as an explicit capability/preflight result.

That preserves the package boundary while making the sandbox layer visible to agents through the
normal tool, capability, trace-event, and workbench surfaces.

## Open Questions

- Should `AttachHandle.events` remain an enumerable field, or should the package also expose a
  demand-driven `next_event/2` callback for stronger back-pressure? The enumerable shape worked for
  tests and direct smokes.
- Should stdin acknowledgements be required for all interactive backends, or optional metadata for
  transports that can report them cheaply?
- Should the first MCP bridge be policy metadata under `Policy.network == :restricted`, or a separate
  reverse-proxy/service primitive that also works for microVM backends?
- Should attached-process lifecycle affect pooled session state (`:busy`) in the manager immediately,
  or only once the first real backend supports attach?

## Validation

Validated:

- `mix test` from `packages/runic_sandbox`
- `mix test test/runic_ai/coding/standard_agent_test.exs test/runic_ai/assistant/rlm_blueprint_test.exs test/runic_ai/rlm/sandbox_eval_task_test.exs`
- Direct Docker attach smoke with local `runic-ai/sandbox:elixir-python-node`
- Direct Sprites attach smoke with ephemeral sprite and `cwd: "/home/sprite"`
- Direct Fly remote attach smoke against existing `libbit` machine `148e2d02f1d348`
- Vmsan status probe: executable present, but live execution unavailable because local Firecracker,
  jailer, agent, nftables helper, kernel image, rootfs image, and nftables kernel support
  requirements are missing.

## Vmsan Host Setup Notes

Current host state from `vmsan doctor --json`:

- Passing: KVM, TUN device, disk space, default interface, host firewall, jailer filesystem.
- Missing: nftables kernel support, Firecracker binary, jailer binary, vmsan agent,
  `vmsan-nftables`, kernel image, and rootfs image.

The upstream vmsan installer is the intended path for Firecracker, jailer, kernel, and rootfs:

```bash
curl -fsSL https://vmsan.dev/install | bash
```

The docs say this populates `~/.vmsan/` with `bin/firecracker`, `bin/jailer`, `kernels/vmlinux-6.1`,
and `rootfs/ubuntu-24.04.ext4`. The agent is separate when developing locally:

```bash
cd agent
make install
```

Then verify:

```bash
vmsan doctor --json
mix runic_sandbox.doctor --format json
```

If VM creation fails after assets are installed, use the adapter's explicit sudo path:

```elixir
backend_options: %{sudo?: true, executable: "/home/doops/.asdf/shims/vmsan"}
```

The remaining unknown on this host is the `nftables kernel support not available` failure. The
installer may not fix that if the running kernel lacks the required module/configuration; after
installing assets, rerun doctor before attempting the RunicSandbox vmsan attach smoke.

Root-level package test invocation currently does not load `packages/runic_sandbox/test/support`
because the root project owns the active `test_helper`. Use package-local validation for package
tests unless that root test-support loading shape is intentionally changed.
