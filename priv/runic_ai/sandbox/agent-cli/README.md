# RunicAI Agent CLI Sandbox

This image is for long-lived sandbox sessions that run contained agent CLIs
while keeping model credentials on the host.

Default endpoint environment:

- `RUNIC_MCP_URL=http://host.docker.internal:4000`
- `RUNIC_MODEL_PROXY_URL=http://host.docker.internal:4100`

Profiles should override those values through Docker `--env` arguments when
ports differ. The image does not contain API keys and assumes restricted egress:
the sandbox should reach only the host-side MCP endpoint and model proxy entries
allowed by the sandbox profile.

Optional CLI installation hooks:

- `AGENT_CLI_NPM_PACKAGES` installs global npm packages during image build.
- `AGENT_CLI_APT_PACKAGES` installs extra apt packages during image build.

For example:

```bash
docker build \
  -f priv/runic_ai/sandbox/agent-cli/Dockerfile \
  -t runic-ai/sandbox-agent-cli:latest \
  --build-arg 'AGENT_CLI_NPM_PACKAGES=@openai/codex @anthropic-ai/claude-code' \
  .
```

The Gemini CLI path is intentionally deferred. If Gemini rejects a
non-HTTPS base URL, the model proxy will need a TLS-presenting endpoint or a
loopback-compatible sidecar path.
