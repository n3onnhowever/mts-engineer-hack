#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/forward.sh"

help() {
  printf '%s\n' 'Usage: bash scripts/verify.sh [--prometheus-port N] [--loki-port N] [--help]' \
    'Run platform, Gateway, metrics and fresh Fluentd/Loki acceptance against an existing deployment.' \
    'Gateway uses fixed port 8080. Defaults: Prometheus 9090, Loki 3100. Ports must be distinct and free.' \
    'Owns temporary loopback forwards; evidence is saved under ignored .local/verify/.'
}
gateway_port=8080 prometheus_port=9090 loki_port=3100
if [[ $# -eq 1 && $1 == --help ]]; then help; exit 0; fi
while (( $# )); do
  case $1 in
    --prometheus-port|--loki-port)
      [[ $# -ge 2 ]] || usage_error "Missing value for $1."
      value=$(port_value "$1" "$2")
      case $1 in
        --prometheus-port) prometheus_port=$value ;;
        --loki-port) loki_port=$value ;;
      esac
      shift 2 ;;
    *) usage_error "Unsupported argument: $1." ;;
  esac
done
[[ $gateway_port != "$prometheus_port" && $gateway_port != "$loki_port" && $prometheus_port != "$loki_port" ]] \
  || usage_error 'Forward ports must be distinct.'
for component in platform gateway-app observability; do
  [[ -f $REPO_ROOT/tests/$component.sh ]] || die "Missing integration component: tests/$component.sh"
done
preflight
available_ports "$gateway_port" "$prometheus_port" "$loki_port"
RUN_ID="mts-$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
EVIDENCE_DIR="$REPO_ROOT/.local/verify/$RUN_ID"
mkdir -p "$EVIDENCE_DIR"
export RUN_ID EVIDENCE_DIR
export GATEWAY_BASE_URL="http://127.0.0.1:$gateway_port"
export PROMETHEUS_BASE_URL="http://127.0.0.1:$prometheus_port"
export LOKI_BASE_URL="http://127.0.0.1:$loki_port"

bash "$REPO_ROOT/tests/platform.sh" --runtime
poll 'exactly one Gateway proxy Service' proxy_service
proxy=$(proxy_service)
start_forward envoy-gateway-system "$proxy" "$gateway_port" 80
start_forward mts-observability prometheus "$prometheus_port" 9090
start_forward mts-observability loki "$loki_port" 3100
poll 'Prometheus HTTP readiness' http_ready "$PROMETHEUS_BASE_URL/-/ready"
poll 'Loki HTTP readiness' http_ready "$LOKI_BASE_URL/ready"
forwards_alive
# Component scripts receive fixed URLs and fresh IDs and must not start any forwards.
# Separate request IDs prevent buffered routing-test logs from satisfying the observability suite's
# later fresh-ingestion assertions; keep each component's evidence distinct.
mkdir -p "$EVIDENCE_DIR/gateway-app"
RUN_ID="${RUN_ID}-b" EVIDENCE_DIR="$EVIDENCE_DIR/gateway-app" bash "$REPO_ROOT/tests/gateway-app.sh"
forwards_alive
bash "$REPO_ROOT/tests/observability.sh"
forwards_alive
printf 'Acceptance passed: %s; evidence: %s\n' "$RUN_ID" "$EVIDENCE_DIR"
