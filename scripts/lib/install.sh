#!/usr/bin/env bash
set -euo pipefail

readonly CERTGEN_JOB=eg-gateway-helm-certgen
readonly TOPOLOGY_WEBHOOK=envoy-gateway-topology-injector.envoy-gateway-system

certificates_state() {
  local namespace secrets
  namespace=$(kube get namespace envoy-gateway-system --ignore-not-found -o name) || return 1
  if [[ -z $namespace ]]; then printf 'fresh\n'; return 0; fi
  secrets=$(kube get secrets envoy-gateway envoy envoy-rate-limit envoy-oidc-hmac \
    -n envoy-gateway-system --ignore-not-found -o json) || return 1
  # kubectl emits no JSON when every explicitly named Secret is absent.
  # A successful empty result is fresh; API errors and partial sets still fail.
  if [[ -z $secrets ]]; then printf 'fresh\n'; return 0; fi
  python3 "$REPO_ROOT/scripts/lib/certificates.py" <<<"$secrets"
}
webhook_matches_ca() {
  # Only the public CA is passed to Python; key material never reaches files.
  local ca
  ca=$(kube get secret envoy-gateway -n envoy-gateway-system -o jsonpath='{.data.ca\.crt}')
  kube get mutatingwebhookconfiguration "$TOPOLOGY_WEBHOOK" -o json | python3 -c \
    'import json,sys; w=json.load(sys.stdin).get("webhooks",[]); sys.exit(0 if w and sys.argv[1] and all(x.get("clientConfig",{}).get("caBundle")==sys.argv[1] for x in w) else 1)' "$ca"
}
job_complete() {
  kube get job "$CERTGEN_JOB" -n envoy-gateway-system -o json | python3 -c \
    'import json,sys; d=json.load(sys.stdin); c=d.get("status",{}).get("conditions",[]); sys.exit(0 if any(x.get("type")=="Complete" and x.get("status")=="True" for x in c) else 1)'
}
install_certificates() {
  local state existing desired_digest action
  state=$(certificates_state) || die 'Invalid/partial Envoy Gateway certificates; no automatic CA repair is safe.'
  desired_digest=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["items"][0]["metadata"]["annotations"]["mts-engineer-hack/job-sha256"])' <"$DEPLOY_DIR/certgen.json")
  existing=$(kube get job "$CERTGEN_JOB" -n envoy-gateway-system --ignore-not-found -o json)
  action=create
  if [[ -n $existing ]]; then
    action=$(python3 -c '
import json,sys
d=json.load(sys.stdin)
same=d["metadata"].get("annotations",{}).get("mts-engineer-hack/job-sha256")==sys.argv[1]
c=d.get("status",{}).get("conditions",[])
complete=any(x.get("type")=="Complete" and x.get("status")=="True" for x in c)
failed=any(x.get("type") in ("Failed","FailureTarget") and x.get("status")=="True" for x in c)
print("replace" if not same or failed or (complete and sys.argv[2]=="fresh") else "reuse" if complete else "wait")
' "$desired_digest" "$state" <<<"$existing")
    if [[ $action == reuse ]] && ! webhook_matches_ca; then action=replace; fi
  fi
  if [[ $action == replace ]]; then
    # Job templates are immutable. Only this exact upstream job is replaced;
    # generated Secrets are never deleted or committed by these scripts.
    kube delete job "$CERTGEN_JOB" -n envoy-gateway-system --wait=true --timeout=60s --request-timeout=90s
    action=create
  fi
  if [[ $action == create ]]; then apply_file "$DEPLOY_DIR/certgen.json"; fi
  poll 'Envoy Gateway certgen Job completion' job_complete
  [[ $(certificates_state) == ready ]] || die 'Certgen completed without a valid complete Secret set.'
  webhook_matches_ca || die 'Certgen completed but topology webhook CA does not match.'
  printf 'Certificate job ready (%s).\n' "$action"
}
