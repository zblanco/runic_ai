FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    build-essential \
    ca-certificates \
    curl \
    elixir \
    erlang-dev \
    git \
    jq \
    lua5.4 \
    nodejs \
    npm \
    python3 \
    python3-pip \
    ripgrep \
    sqlite3 \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["bash"]
