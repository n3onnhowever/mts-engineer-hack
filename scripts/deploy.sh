#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/fluentd.sh"
source "$REPO_ROOT/scripts/lib/install.sh"

help() {
  printf '%s\n' 'Usage: bash scripts/deploy.sh [--help]' \
    'Build/load Fluentd and deploy local pinned declarations to the existing kind-mts-engineer cluster.' \
    'Phases: namespaces, CRDs, prerequisites, certgen, controller, application/telemetry/routing.' \
    'Bounded readiness checks; repeatable ConfigMap and local-image rollouts.' \
    'Requires Python PyYAML. Never creates a cluster or downloads installation manifests.'
}
no_arguments "$@"
preflight
python3 -c 'import yaml' || die 'Python PyYAML is required (Ubuntu package python3-yaml).'
lock_mutation
DEPLOY_DIR=$(mktemp -d "$REPO_ROOT/.local/deploy.XXXXXX")
vendor="$REPO_ROOT/kubernetes/vendor/envoy-gateway/$ENVOY_GATEWAY_VERSION"
printf '%s  %s\n' "$ENVOY_GATEWAY_INSTALL_SHA256" "$vendor/base/install.yaml" | sha256sum --check --status \
  || die 'Vendored Envoy Gateway installer checksum differs from config/versions.env.'
# Complete all local rendering/validation before the first cluster mutation.
render "$REPO_ROOT/kubernetes/platform" "$DEPLOY_DIR/namespaces.json"
render "$vendor/crds" "$DEPLOY_DIR/crds.json"
render "$vendor/prerequisites" "$DEPLOY_DIR/prerequisites.json"
render "$vendor/certgen" "$DEPLOY_DIR/certgen.json"
render "$vendor/controller" "$DEPLOY_DIR/controller.json" "$DEPLOY_DIR/prerequisites.json"
render "$REPO_ROOT/kubernetes" "$DEPLOY_DIR/application.json"
certificates_state >/dev/null
build_load_fluentd
apply_file "$DEPLOY_DIR/namespaces.json"
apply_file "$DEPLOY_DIR/crds.json"
mapfile -t crds < <(python3 "$REPO_ROOT/scripts/lib/manifests.py" names CustomResourceDefinition <"$DEPLOY_DIR/crds.json")
[[ ${#crds[@]} -gt 0 ]] || die 'CRD phase rendered no CRDs.'
crd_resources=()
for crd in "${crds[@]}"; do crd_resources+=("customresourcedefinition/$crd"); done
kube wait --for=condition=Established --timeout="${WAIT_SECONDS}s" --request-timeout="$((WAIT_SECONDS + 30))s" "${crd_resources[@]}"
apply_file "$DEPLOY_DIR/prerequisites.json"
install_certificates
apply_file "$DEPLOY_DIR/controller.json"
wait_deployment envoy-gateway-system envoy-gateway
apply_file "$DEPLOY_DIR/application.json"
wait_platform
wait_gateway
poll 'exactly one Gateway proxy Service' proxy_service
printf 'Deployment ready; run bash scripts/verify.sh for traffic/query acceptance. Local artifacts: %s\n' "$DEPLOY_DIR"
