#!/usr/bin/env bash
set -euo pipefail

# Source after common.sh. Only PIDs created by this process are ever signalled.
PF_PIDS=()
stop_forwards() {
  local status=$? pid deadline=$((SECONDS + 5))
  trap - EXIT INT TERM
  for pid in "${PF_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  done
  for pid in "${PF_PIDS[@]}"; do
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
  done
  exit "$status"
}
trap stop_forwards EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

port_value() {
  [[ $2 =~ ^[0-9]{1,5}$ ]] || usage_error "$1 requires an integer port (1..65535)."
  local number=$((10#$2))
  (( number >= 1 && number <= 65535 )) || usage_error "$1 requires a port in 1..65535."
  printf '%s' "$number"
}
available_ports() {
  python3 - "$@" <<'PY'
import socket, sys
sockets = []
try:
    for value in sys.argv[1:]:
        sock = socket.socket()
        sockets.append(sock)
        sock.bind(("127.0.0.1", int(value)))
except OSError as exc:
    print(f"ERROR: requested loopback port unavailable: {exc}", file=sys.stderr)
    sys.exit(1)
finally:
    for sock in sockets:
        sock.close()
PY
}
start_forward() {
  local namespace=$1 service=$2 local_port=$3 remote_port=$4
  local log="$EVIDENCE_DIR/forward-$local_port.log" pid deadline=$((SECONDS + 60))
  : >"$log"
  kubectl --context kind-mts-engineer --request-timeout=0 -n "$namespace" port-forward \
    --address=127.0.0.1 --pod-running-timeout=60s "service/$service" "$local_port:$remote_port" >"$log" 2>&1 &
  pid=$!
  PF_PIDS+=("$pid")
  until grep -q "^Forwarding from 127.0.0.1:$local_port -> " "$log"; do
    kill -0 "$pid" 2>/dev/null || die "Forward to $namespace/$service failed; see $log"
    (( SECONDS < deadline )) || die "Forward to $namespace/$service timed out; see $log"
    sleep 0.2
  done
  kill -0 "$pid" 2>/dev/null || die "Forward to $namespace/$service exited; see $log"
}
forwards_alive() {
  local pid
  for pid in "${PF_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null || die "Owned port-forward process $pid exited."; done
}
http_ready() { forwards_alive; curl --fail --silent --show-error --connect-timeout 2 --max-time 5 "$1" >/dev/null; }
