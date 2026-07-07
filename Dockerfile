# llm-wiki RIG controller image.
#
# Two phases in one container:
#   1. Deterministic: reconcile.sh downloads source, runs emitters, pushes RIG
#   2. Interpretive:  pi.dev agent (GLM-5.2 via ZAI) transforms RIG into docs

# --- Stage 1: Go toolchain ---
FROM golang:1.24-bookworm AS go-base

# --- Stage 2: Final image ---
FROM python:3.12-slim-bookworm

# System tools + kubectl + Node.js
ARG KUBECTL_VERSION=v1.36.1
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git openssh-client jq gnupg xz-utils \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Go (for emit-go.sh)
COPY --from=go-base /usr/local/go /usr/local/go
ENV GOPATH="/go"
ENV PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
RUN mkdir -p "${GOPATH}"

# Zig (for emit-zig.sh)
ARG ZIG_VERSION=0.14.1
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /usr/local \
    && ln -s /usr/local/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

# pi.dev harness + LikeC4
RUN npm install -g @earendil-works/pi-coding-agent likec4

# Emitter scripts + reconcile + agent logic + CI monitor
COPY deploy/scripts/reconcile.sh         /usr/local/bin/reconcile.sh
COPY deploy/scripts/agent-sync.sh        /usr/local/bin/agent-sync.sh
COPY deploy/scripts/ci-monitor.sh        /usr/local/bin/ci-monitor.sh
COPY deploy/scripts/event-subscriber.py  /usr/local/bin/event-subscriber.py
COPY .github/actions/repo-map/emit-rig.sh /emitters/emit-rig.sh
COPY .github/actions/repo-map/emit-rig.py /emitters/emit-rig.py
COPY schemas/repo-map.schema.yaml        /schema/repo-map.schema.yaml
COPY scripts/arch/validate-rig.py        /usr/local/bin/validate-rig.py

# The llm-wiki skill (for the pi agent to follow)
COPY skill/SKILL.md                      /skills/wiki/SKILL.md

RUN chmod +x /usr/local/bin/reconcile.sh /usr/local/bin/agent-sync.sh /usr/local/bin/ci-monitor.sh /emitters/emit-rig.sh

ENTRYPOINT ["/usr/local/bin/reconcile.sh"]
