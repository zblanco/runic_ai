FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
  RUNIC_AGENT_HOME=/opt/runic-ai/agents \
  RUNIC_MCP_URL=http://host.docker.internal:4000 \
  RUNIC_MODEL_PROXY_URL=http://host.docker.internal:4100 \
  NPM_CONFIG_UPDATE_NOTIFIER=false

ARG AGENT_CLI_APT_PACKAGES=""
ARG AGENT_CLI_NPM_PACKAGES=""

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    elixir \
    erlang-dev \
    git \
    iproute2 \
    jq \
    lua5.4 \
    netcat-openbsd \
    nodejs \
    npm \
    openssh-client \
    procps \
    python3 \
    python3-pip \
    ripgrep \
    sqlite3 \
  && if [ -n "$AGENT_CLI_APT_PACKAGES" ]; then apt-get install -y --no-install-recommends $AGENT_CLI_APT_PACKAGES; fi \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN mkdir -p \
    "$RUNIC_AGENT_HOME/bin" \
    "$RUNIC_AGENT_HOME/instructions" \
    "$RUNIC_AGENT_HOME/skills" \
    /workspace

COPY priv/runic_ai/sandbox/agent-cli/README.md "$RUNIC_AGENT_HOME/README.md"
COPY priv/runic_ai/sandbox/agent-cli/runic-agent-cli-check /usr/local/bin/runic-agent-cli-check

RUN chmod 0755 /usr/local/bin/runic-agent-cli-check \
  && if [ -n "$AGENT_CLI_NPM_PACKAGES" ]; then npm install -g $AGENT_CLI_NPM_PACKAGES; fi

WORKDIR /workspace

CMD ["bash"]
