# RunicSandbox

Structured sandbox execution contracts and pluggable backends for agent and
workflow code execution.

This package is currently developed inside the RunicAI repository while the
public API and backend boundary stabilize.

## Preparing Backend Images And Dependencies

Sandbox profiles describe execution policy and workspace shape. They do not
install language runtimes, CLIs, package managers, or provider-specific tools
for you. Prepare those in the image or microVM used by the selected backend.

### Docker And GVisor

Docker and GVisor profiles use `backend_options.image` or the top-level
`image:` profile option. The default RunicAI images live under
`priv/runic_ai/sandbox/` in the parent repository.

For contained agent CLI sessions:

- Use `runic-ai/sandbox-agent-cli:latest` or a derived image.
- Keep model provider credentials on the host and route model traffic through a
  host-side proxy allowed by restricted egress.
- Include full `python3`, not `python3-minimal`; the restricted-egress proxy
  imports Python stdlib modules such as `json`.
- Prefer a non-root runtime user. The RunicAI agent CLI image uses uid/gid
  `10001`; Docker managed workspaces are prepared so that copied stateful
  workspaces remain writable by that user.
- Install extra OS packages with `AGENT_CLI_APT_PACKAGES` and global npm CLIs
  with `AGENT_CLI_NPM_PACKAGES`, or create a project-specific derived
  Dockerfile.

Example:

```bash
docker build \
  -f priv/runic_ai/sandbox/agent-cli/Dockerfile \
  -t runic-ai/sandbox-agent-cli:latest \
  --build-arg 'AGENT_CLI_NPM_PACKAGES=@openai/codex @anthropic-ai/claude-code' \
  .
```

For stateful Docker sessions, `workspace.host_root` is copy-seeded into the
managed `/workspace` before the container starts. Missing or non-directory
`host_root` values fail closed before `docker run`. This is intentionally not a
host bind/writeback mode; use explicit artifact or tool flows for host writes
until Docker `:bind` semantics are designed and reviewed.

### Vmsan

Vmsan profiles expect the VM image or base environment to already contain the
runtimes and CLIs used by the sandboxed workload. Use Vmsan image/build tooling
or a pre-provisioning step to install language runtimes, package managers,
agent CLIs, `git`, `rg`, `jq`, and any project libraries the session needs.

Keep the same boundary as Docker:

- Model credentials stay on the host or in a provider-managed control plane, not
  in the sandbox image.
- If a sidecar or proxy is used inside the VM, include its runtime dependencies
  explicitly. A Python sidecar should use full `python3` with stdlib support.
- Document any VM snapshot assumptions separately from filesystem-only
  checkpoints; process memory, open sockets, and running services are
  backend-specific preservation claims.
