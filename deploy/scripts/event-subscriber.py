#!/usr/bin/env python3
"""event-subscriber.py — Dapr pub/sub consumer for wiki documentation events.

Always-on Deployment that subscribes to the ``wiki.docs.updated`` topic
(published by reconcile.sh after every successful documentation sync). For each
event it records a Kubernetes Event on the source WikiMap CR, making
documentation activity observable via ``kubectl get events`` and
``kubectl describe wikimap <name>``.

This is the first concrete consumer of the event bus — step 1 of the move from
cron-batch to event-driven operation. It proves the Dapr pub/sub path
end-to-end and gives operators a visible audit trail. Redis pub/sub is
fire-and-forget (no retention), so the subscriber must be always-online; that is
why it runs as a Deployment, not inside the scale-to-zero controller ScaledJob.

Dapr discovers the subscription via ``GET /dapr/subscribe`` and delivers events
to the declared route. Standard library only — no pip dependencies.
"""
import http.server
import json
import os
import ssl
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

LISTEN_ADDR = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("PORT", "8080"))
NAMESPACE = os.environ.get("NAMESPACE", "llm-wiki")
PUBSUB_NAME = os.environ.get("DAPR_PUBSUB", "pubsub")
TOPIC = "wiki.docs.updated"
K8S_API = "https://kubernetes.default.svc"

SA_TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

SUBSCRIPTIONS = [
    {
        "pubsubname": PUBSUB_NAME,
        "topic": TOPIC,
        "route": "/events",
    }
]


def log(msg: str) -> None:
    print(f"[event-subscriber] {datetime.now(timezone.utc).isoformat()} {msg}", flush=True)


def _k8s_ctx():
    ctx = ssl.create_default_context(cafile=SA_CA)
    return ctx


def k8s_request(method, path, body=None):
    """Call the in-cluster Kubernetes API with the mounted service-account token."""
    with open(SA_TOKEN) as f:
        token = f.read().strip()
    url = f"{K8S_API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=_k8s_ctx(), timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def get_wikimap_uid(project):
    status, body = k8s_request(
        "GET", f"/apis/llm-wiki.dev/v1alpha1/namespaces/{NAMESPACE}/wikimaps/{project}"
    )
    if status == 200:
        try:
            return json.loads(body).get("metadata", {}).get("uid", "")
        except Exception:  # noqa: BLE001
            return ""
    return ""


def record_k8s_event(project, data):
    """Create a Kubernetes Event on the source WikiMap CR."""
    components = data.get("components", "?")
    revision = data.get("revision", "?")
    workflow = data.get("workflow", "?")
    involved = {
        "apiVersion": "llm-wiki.dev/v1alpha1",
        "kind": "WikiMap",
        "name": project,
        "namespace": NAMESPACE,
    }
    uid = get_wikimap_uid(project)
    if uid:
        involved["uid"] = uid
    name = f"docs-sync-{project}-{int(time.time() * 1000)}"[:253]
    event = {
        "apiVersion": "v1",
        "kind": "Event",
        "metadata": {
            "name": name,
            "namespace": NAMESPACE,
            "labels": {"app.kubernetes.io/name": "wiki-event-subscriber"},
        },
        "involvedObject": involved,
        "reason": "DocsSynced",
        "message": (
            f"documentation synced (workflow={workflow}, "
            f"components={components}, revision={revision})"
        ),
        "type": "Normal",
        "source": {"component": "wiki-event-subscriber"},
        "lastTimestamp": datetime.now(timezone.utc).isoformat(),
    }
    status, body = k8s_request(
        "POST", f"/api/v1/namespaces/{NAMESPACE}/events", event
    )
    if status in (200, 201, 202):
        log(
            f"recorded K8s Event 'DocsSynced' on WikiMap/{project} "
            f"({components} components)"
        )
    else:
        log(f"WARN: could not record K8s Event (status={status}): {body[:300]}")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/dapr/subscribe":
            self._send(200, SUBSCRIPTIONS)
        elif self.path == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not found"})

    def do_HEAD(self):
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {})

    def do_POST(self):
        if self.path != "/events":
            self._send(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode() or "{}")
        except Exception:  # noqa: BLE001
            payload = {}
        # Dapr wraps published data in a cloudevent envelope {data: {...}};
        # accept both that and a raw payload.
        data = payload.get("data", payload) if isinstance(payload, dict) else {}
        project = data.get("project", "unknown")
        log(f"event received: project={project} data={json.dumps(data)[:300]}")
        try:
            record_k8s_event(project, data)
        except Exception as e:  # noqa: BLE001
            log(f"WARN: handler error: {e}")
        # Always 200: recording an event is idempotent side-effect; redelivery
        # would at worst create a duplicate Event, so never ask Dapr to retry.
        self._send(200, {"status": "recorded"})

    def log_message(self, fmt, *args):  # noqa: A003
        pass  # silence default access log


def main():
    log(f"starting on {LISTEN_ADDR}:{LISTEN_PORT} (namespace={NAMESPACE})")
    log(f"subscribed to pubsub={PUBSUB_NAME} topic={TOPIC} -> /events")
    httpd = http.server.ThreadingHTTPServer((LISTEN_ADDR, LISTEN_PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
