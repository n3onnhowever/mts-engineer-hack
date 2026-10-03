#!/usr/bin/env bash
set -euo pipefail

# Library paths work from any caller directory. No kubeconfig state is changed.
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/config/versions.env"
if [[ ${KUBE_CONTEXT:-kind-mts-engineer} != kind-mts-engineer ]]; then
  printf '%s\n' 'ERROR: KUBE_CONTEXT must be kind-mts-engineer.' >&2
  exit 64
fi
export KUBE_CONTEXT=kind-mts-engineer
readonly REPO_ROOT KUBE_CONTEXT
readonly CLUSTER_NAME=mts-engineer
readonly WAIT_SECONDS=300
readonly PROXY_SELECTOR='gateway.envoyproxy.io/owning-gateway-namespace=mts-app,gateway.envoyproxy.io/owning-gateway-name=mts-gateway'

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'ERROR: %s Use --help.\n' "$*" >&2; exit 64; }
no_arguments() {
  if [[ $# -eq 1 && $1 == --help ]]; then help; exit 0; fi
  [[ $# -eq 0 ]] || usage_error 'Unsupported arguments.'
}
require_tools() {
  local tool
  for tool in "$@"; do command -v "$tool" >/dev/null || die "Required tool missing: $tool"; done
}
kube() { kubectl --context kind-mts-engineer --request-timeout=30s "$@"; }
check() { python3 "$REPO_ROOT/scripts/lib/readiness.py" "$@"; }

preflight() {
  require_tools kubectl kind docker curl python3 timeout sha256sum flock openssl
  [[ $(uname -s) == Linux ]] || die 'Run Linux tooling in WSL Ubuntu-24.04.'
  # shellcheck source=/etc/os-release
  source /etc/os-release
  [[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Expected Ubuntu 24.04 (WSL Ubuntu-24.04).'
  [[ $(kind version) == "kind $KIND_VERSION "* ]] || die "kind must be $KIND_VERSION."
  local client clusters nodes image runtime endpoint ports metadata
  client=$(kube version --client -o json)
  python3 -c 'import json,sys; d=json.load(sys.stdin)["clientVersion"]; sys.exit(0 if d["gitVersion"]==sys.argv[1] and d["platform"]=="linux/amd64" else 1)' "$KUBECTL_VERSION" <<<"$client" \
    || die "kubectl must be $KUBECTL_VERSION for linux/amd64."
  runtime=$(timeout 30s docker info --format '{{.OSType}}/{{.Architecture}}') || die 'Docker engine is unavailable.'
  [[ $runtime == linux/x86_64 || $runtime == linux/amd64 ]] || die 'Docker must run Linux amd64 containers.'
  clusters=$(timeout 30s kind get clusters) || die 'Cannot list kind clusters.'
  grep -Fxq "$CLUSTER_NAME" <<<"$clusters" || die 'Existing kind cluster mts-engineer is absent; no cluster was created.'
  nodes=$(timeout 30s kind get nodes --name "$CLUSTER_NAME") || die 'Cannot inspect kind nodes.'
  [[ $nodes == mts-engineer-control-plane ]] || die 'Expected exactly one kind node: mts-engineer-control-plane.'
  image=$(timeout 30s docker inspect mts-engineer-control-plane --format '{{.Config.Image}}')
  [[ $image == "$KIND_NODE_IMAGE" ]] || die 'Existing node image differs from KIND_NODE_IMAGE; refusing reuse.'
  metadata=$(timeout 30s docker inspect mts-engineer-control-plane --format '{{json .}}')
  python3 -c 'import json,sys; d=json.load(sys.stdin); l=d["Config"]["Labels"]; sys.exit(0 if d["State"]["Running"] and l.get("io.x-k8s.kind.cluster")=="mts-engineer" and l.get("io.x-k8s.kind.role")=="control-plane" else 1)' <<<"$metadata" \
    || die 'Docker node identity/state does not match the expected kind cluster.'
  endpoint=$(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  ports=$(timeout 30s docker inspect mts-engineer-control-plane --format '{{json .NetworkSettings.Ports}}')
  python3 -c 'import json,sys,urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); ports=json.load(sys.stdin).get("6443/tcp") or []; sys.exit(0 if u.scheme=="https" and u.hostname in ("localhost","127.0.0.1","::1") and any(str(u.port)==p["HostPort"] for p in ports) else 1)' "$endpoint" <<<"$ports" \
    || die 'Context API endpoint does not match the existing kind node port.'
  kube version -o json | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["serverVersion"]["gitVersion"]==sys.argv[1] else 1)' "$KUBERNETES_VERSION" \
    || die "Server must be $KUBERNETES_VERSION."
  [[ $(kube get --raw=/readyz) == ok ]] || die 'Kubernetes API is not ready.'
  kube get nodes -o json | check nodes "$KUBERNETES_VERSION" || die 'Existing node does not match the version and identity requirements or is not Ready.'
}

# Bounded polling with diagnostic output only on final failure.
poll() {
  local description=$1; shift
  local deadline=$((SECONDS + WAIT_SECONDS))
  local detail
  detail=$(mktemp "$REPO_ROOT/.local/poll.XXXXXX")
  until "$@" >"$detail" 2>&1; do
    if (( SECONDS >= deadline )); then
      cat "$detail" >&2; rm -f -- "$detail"
      die "Timed out after ${WAIT_SECONDS}s: $description"
    fi
    sleep 2
  done
  rm -f -- "$detail"
}
condition_ready() { local mode=$1; shift; kube get "$@" -o json | check "$mode"; }
wait_gateway() {
  mkdir -p "$REPO_ROOT/.local"
  poll 'GatewayClass Accepted at current generation' condition_ready gatewayclass gatewayclass mts-envoy
  poll 'Gateway and HTTP listener ready at current generation' condition_ready gateway gateway mts-gateway -n mts-app
  poll 'HTTPRoute accepted/resolved for mts-gateway at current generation' condition_ready httproute httproute nginx-demo -n mts-app
}
wait_deployment() { kube rollout status deployment/"$2" -n "$1" --timeout="${WAIT_SECONDS}s" --request-timeout="$((WAIT_SECONDS + 30))s"; }
wait_platform() {
  kube get nodes -o json | check nodes "$KUBERNETES_VERSION"
  wait_deployment envoy-gateway-system envoy-gateway
  wait_deployment mts-app nginx-demo
  wait_deployment mts-observability loki
  wait_deployment mts-observability prometheus
}
proxy_service() {
  kube get services -n envoy-gateway-system -l "$PROXY_SELECTOR" -o json | check proxy-services
}
lock_mutation() {
  mkdir -p "$REPO_ROOT/.local"
  exec 9>"$REPO_ROOT/.local/deploy.lock"
  flock -n 9 || die 'Another deploy/destroy is in progress in this repository.'
}

# No remote reads: Kustomize is bundled in the pinned kubectl client.
render() {
  local directory=$1 output=$2; shift 2
  kube kustomize "$directory" | python3 "$REPO_ROOT/scripts/lib/manifests.py" render "$@" >"$output"
}
apply_file() { kube apply --server-side --field-manager=mts-engineer-platform -f "$1"; }
