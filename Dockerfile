# llm-wiki RIG controller image.
#
# Contains the tools needed to run language-specific RIG emitters, validate
# the output, and push to wiki repos. Designed to run as a CronJob controller
# that reconciles WikiMap CRs.
#
# Languages are layered. Only include what's needed for the mapped projects.
# Add new language toolchains as WikiMap CRs require them.

FROM golang:1.24-bookworm AS go-base

FROM python:3.12-slim-bookworm

# --- System tools + kubectl ---
ARG KUBECTL_VERSION=v1.36.1
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git openssh-client jq \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Go (for emit-go.sh) ---
COPY --from=go-base /usr/local/go /usr/local/go
ENV GOPATH="/go"
ENV PATH="/usr/local/go/bin:${GOPATH}/bin:${PATH}"
RUN mkdir -p "${GOPATH}"

# --- Emitter scripts + reconcile logic ---
COPY deploy/scripts/reconcile.sh        /usr/local/bin/reconcile.sh
COPY .github/actions/repo-map/emit-go.sh  /emitters/emit-go.sh
COPY schemas/repo-map.schema.yaml        /schema/repo-map.schema.yaml
COPY scripts/arch/validate-rig.py        /usr/local/bin/validate-rig.py

RUN chmod +x /usr/local/bin/reconcile.sh /emitters/emit-go.sh

# --- Entrypoint ---
# The deploy key is mounted at /deploy-key/sshkey by the CronJob.
ENTRYPOINT ["/usr/local/bin/reconcile.sh"]
