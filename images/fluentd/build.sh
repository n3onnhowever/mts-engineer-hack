#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
case "${1:-}" in
  --help) printf 'Usage: images/fluentd/build.sh\nBuild the pinned local image; does not load or deploy it.\n'; exit 0 ;;
  '') [[ $# == 0 ]] || exit 64 ;;
  *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
esac
source "$ROOT/config/versions.env"
exec docker build --tag "$FLUENTD_IMAGE" \
  --build-arg "FLUENTD_BASE_IMAGE=$FLUENTD_BASE_IMAGE" \
  --build-arg "FLUENTD_VERSION=$FLUENTD_VERSION" \
  --build-arg "FLUENTD_GEM_SHA256=$FLUENTD_GEM_SHA256" \
  --build-arg "FLUENTD_LOKI_PLUGIN_VERSION=$FLUENTD_LOKI_PLUGIN_VERSION" \
  --build-arg "FLUENTD_LOKI_PLUGIN_GEM_SHA256=$FLUENTD_LOKI_PLUGIN_GEM_SHA256" \
  "$ROOT/images/fluentd"
