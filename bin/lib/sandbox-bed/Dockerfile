# SPDX-License-Identifier: MIT
# The sandbox bed's image (bin/sandbox-bed): what the sandbox's image provides, as
# plans/private/sandbox.md "Provided by the image" lists it, so bin/sandbox-setup meets
# here what it meets there and installs the rest itself (Rust, Node 24, Maven, the CDC
# jars, vim, shellcheck). x86_64, as the sandbox is (--platform linux/amd64); arm64
# for bin/sandbox-bed up --native. Not the sandbox: its network is the laptop's, and
# no `ip` or iptables, as there.
FROM ubuntu:24.04

ARG NODE_VERSION=22.21.1
ARG UV_VERSION=0.9.10

# PostgreSQL 16, Java 21, Python 3.12, the build basics, and gluon-kube's isolation
# tools (bwrap, unshare, nsenter).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl git gcc libc6-dev make xz-utils python3 \
      postgresql-16 openjdk-21-jdk-headless bubblewrap util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/lib/postgresql/16/bin/initdb /usr/lib/postgresql/16/bin/pg_ctl \
      /usr/lib/postgresql/16/bin/postgres /usr/local/bin/

# Node 22 with its npm 10 (the image's node; setup adds Node 24 beside it).
ARG TARGETARCH
RUN arch="$([ "$TARGETARCH" = arm64 ] && echo arm64 || echo x64)" \
 && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1

# The two users' layout: the session runs as model; /home/claude/.local/bin is on the
# PATH and writable, where uv lives and setup puts its wrappers.
RUN useradd -m -s /bin/bash model \
 && install -d -o model -g model /home/claude /home/claude/.local /home/claude/.local/bin /workspace
ENV PATH=/home/claude/.local/bin:$PATH \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python

# uv, and Python 3.13 under /opt/uv-python; uv can't download Pythons in the sandbox.
RUN curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" \
      | env UV_INSTALL_DIR=/home/claude/.local/bin UV_NO_MODIFY_PATH=1 sh \
 && /home/claude/.local/bin/uv python install 3.13 \
 && chown -R model:model /home/claude
ENV UV_PYTHON_DOWNLOADS=never

USER model
WORKDIR /workspace
CMD ["sleep", "infinity"]
