#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/common.sh"

help() {
  printf '%s\n' 'Usage: bash scripts/destroy.sh [--help]' \
    'Delete only allowlisted project app, routing and telemetry resources.' \
    'Preserve the kind cluster, namespaces, upstream CRDs/controller/certificates and unrelated resources.' \
    'Wait for controller-managed proxy cleanup. There is no cluster-delete option.'
}
no_arguments "$@"
preflight
python3 -c 'import yaml' || die 'Python PyYAML is required (Ubuntu package python3-yaml).'
lock_mutation
cleanup_dir=$(mktemp -d "$REPO_ROOT/.local/destroy.XXXXXX")
render "$REPO_ROOT/kubernetes" "$cleanup_dir/rendered.json"
python3 "$REPO_ROOT/scripts/lib/manifests.py" cleanup <"$cleanup_dir/rendered.json" >"$cleanup_dir/resources.json"
# Delete each exact identity only if the live object is still project-owned.
# Missing CRDs/namespaces on an untouched cluster are harmless.
python3 - "$cleanup_dir/resources.json" "$KUBE_CONTEXT" <<'PY'
import json, subprocess, sys
items = json.load(open(sys.argv[1]))["items"]
# Routes before Gateway, Gateway before GatewayClass; keep its controller alive.
priority = {"HTTPRoute": 0, "Gateway": 1, "GatewayClass": 3}
for obj in sorted(items, key=lambda x: priority.get(x["kind"], 2)):
    meta = obj["metadata"]
    api = obj["apiVersion"].split("/")
    resource = obj["kind"].lower() + ("." + api[0] if len(api) == 2 else "")
    cmd = ["kubectl", "--context", sys.argv[2], "--request-timeout=30s"]
    if meta.get("namespace"):
        cmd += ["--namespace", meta["namespace"]]
    found = subprocess.run(cmd + ["get", resource, meta["name"], "--ignore-not-found", "-o", "json"], capture_output=True, text=True)
    if found.returncode:
        if "the server doesn't have a resource type" in found.stderr:
            continue
        sys.exit(f"Cleanup inspection failed for {resource}/{meta['name']}: {found.stderr.strip()}")
    if not found.stdout.strip():
        continue
    live = json.loads(found.stdout)
    if live["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "mts-engineer-hack":
        sys.exit(f"Refusing to delete unowned {resource}/{meta['name']}")
    subprocess.run(cmd + ["delete", resource, meta["name"], "--ignore-not-found", "--wait=true", "--timeout=120s", "--request-timeout=150s"], check=True)
PY
proxy_removed() {
  kube get deployments,services -n envoy-gateway-system -l "$PROXY_SELECTOR" -o json \
    | python3 -c 'import json,sys; sys.exit(0 if not json.load(sys.stdin)["items"] else 1)'
}
poll 'controller-managed proxy removal' proxy_removed
printf '%s\n' 'Project resources removed. Existing kind cluster, namespaces and upstream platform preserved.'
