# llm-wiki RIG controller image.
#
# Two phases in one container:
#   1. Deterministic: reconcile.sh downloads source, runs emitters, pushes RIG
#   2. Interpretive:  pi.dev agent (GLM-5.2 via ZAI) transforms RIG into docs
#
# Languages: Go (for emit-go.sh). Add toolchains as WikiMap CRs require them.

# --- Stage 1: Go toolchain ---
FROM golang:1.24-bookworm AS go-base

# --- Stage 2: Node.js + pi harness ---
FROM node:22-bookworm-slim AS node-base
RUN npm install -g @earendil-works/pi-coding-agent

# --- Stage 3: Final image ---
FROM python:3.12-slim-bookworm

# System tools + kubectl
ARG KUBECTL_VERSION=v1.36.1
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git openssh-client jq \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Go (for emit-go.sh)
COPY --from=go-base /usr/local/go /usr/local/go
ENV GOPATH="/go"
ENV PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
RUN mkdir -p "${GOPATH}"

# Node.js + pi (for the LLM agent step)
COPY --from=node-base /usr/local/bin/node /usr/local/bin/node
COPY --from=node-base /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/.bin/pi /usr/local/bin/pi \
    && ln -sf /usr/local/lib/node_modules/.bin/pi /usr/local/bin/pi-coding-agent

# LikeC4 (for gen mermaid in the agent step)
RUN npm install -g likec4 2>/dev/null || true

# Emitter scripts + reconcile + agent logic
COPY deploy/scripts/reconcile.sh         /usr/local/bin/reconcile.sh
COPY deploy/scripts/agent-sync.sh        /usr/local/bin/agent-sync.sh
COPY .github/actions/repo-map/emit-go.sh /emitters/emit-go.sh
COPY schemas/repo-map.schema.yaml        /schema/repo-map.schema.yaml
COPY scripts/arch/validate-rig.py        /usr/local/bin/validate-rig.py

# The llm-wiki skill (for the pi agent to follow)
COPY skill/SKILL.md                      /skills/wiki/SKILL.md

RUN chmod +x /usr/local/bin/reconcile.sh /usr/local/bin/agent-sync.sh /emitters/emit-go.sh

ENTRYPOINT ["/usr/local/bin/reconcile.sh"]
