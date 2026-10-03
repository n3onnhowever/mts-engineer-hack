#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/common.sh"

help() {
  printf '%s\n' 'Usage: bash scripts/bootstrap.sh [--help]' \
    'Read-only preflight and validation of the existing mts-engineer cluster.' \
    'Requires pinned kind/kubectl, Linux Docker and a matching Ready node.' \
    'An absent or incompatible cluster fails; this project never creates or deletes it.'
}
no_arguments "$@"
preflight
printf '%s\n' "Platform preflight passed: $KUBE_CONTEXT ($KUBERNETES_VERSION); existing cluster reused."
