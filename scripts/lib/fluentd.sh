#!/usr/bin/env bash
set -euo pipefail

build_load_fluentd() {
  local recipe old_recipe image_id loaded_id
  [[ -f $REPO_ROOT/images/fluentd/Dockerfile ]] || die 'Fluentd image recipe is missing: images/fluentd/Dockerfile'
  recipe=$(python3 - "$REPO_ROOT" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for file in sorted((root / "images/fluentd").rglob("*")):
    if file.is_file():
        digest.update(file.relative_to(root).as_posix().encode() + b"\0" + file.read_bytes() + b"\0")
for line in (root / "config/versions.env").read_text().splitlines():
    if line.startswith("FLUENTD_"):
        digest.update(line.encode() + b"\n")
print(digest.hexdigest())
PY
)
  old_recipe=$(docker image inspect "$FLUENTD_IMAGE" --format '{{index .Config.Labels "mts-engineer-hack.fluentd-recipe-sha256"}}' 2>/dev/null || true)
  if [[ -n $old_recipe && $old_recipe != '<no value>' && $old_recipe != "$recipe" ]]; then
    die 'Fluentd recipe changed under an existing tag; revise FLUENTD_IMAGE in the version lock and its consumers.'
  fi
  # Rebuild unlabeled local tags to establish recipe provenance and verify
  # the loaded image identity before rollout.
  timeout 900s docker build --platform linux/amd64 --tag "$FLUENTD_IMAGE" \
    --label "mts-engineer-hack.fluentd-recipe-sha256=$recipe" \
    --build-arg "FLUENTD_BASE_IMAGE=$FLUENTD_BASE_IMAGE" \
    --build-arg "FLUENTD_VERSION=$FLUENTD_VERSION" \
    --build-arg "FLUENTD_GEM_SHA256=$FLUENTD_GEM_SHA256" \
    --build-arg "FLUENTD_LOKI_PLUGIN_VERSION=$FLUENTD_LOKI_PLUGIN_VERSION" \
    --build-arg "FLUENTD_LOKI_PLUGIN_GEM_SHA256=$FLUENTD_LOKI_PLUGIN_GEM_SHA256" \
    "$REPO_ROOT/images/fluentd" >"$DEPLOY_DIR/fluentd-build.log" 2>&1 \
    || die "Fluentd build failed or timed out; see $DEPLOY_DIR/fluentd-build.log"
  # Docker's containerd image store reports a manifest/index ID from inspect,
  # whereas CRI reports the config digest. Hash the exported config bytes so
  # both Docker image stores are compared against the same immutable identity.
  timeout 180s docker image save --output "$DEPLOY_DIR/fluentd-image.tar" "$FLUENTD_IMAGE" \
    || die 'Fluentd image export failed or timed out.'
  image_id=$(python3 "$REPO_ROOT/scripts/lib/image_identity.py" "$DEPLOY_DIR/fluentd-image.tar" "$FLUENTD_IMAGE" "$recipe")
  rm -f -- "$DEPLOY_DIR/fluentd-image.tar"
  [[ $image_id =~ ^sha256:[0-9a-f]{64}$ ]] || die 'Invalid built Fluentd image ID.'
  timeout 300s kind load docker-image "$FLUENTD_IMAGE" --name mts-engineer >"$DEPLOY_DIR/fluentd-load.log" 2>&1 \
    || die "Fluentd image load failed or timed out; see $DEPLOY_DIR/fluentd-load.log"
  loaded_id=$(timeout 30s docker exec mts-engineer-control-plane crictl inspecti "$FLUENTD_IMAGE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"]["id"])')
  [[ $loaded_id == "$image_id" ]] || die 'Loaded Fluentd image ID differs from the locally built image.'
  # Add the verified config-image digest to the declaration before apply. This
  # deliberately rolls an existing pod when a same-recipe rebuild changes bytes.
  python3 - "$DEPLOY_DIR/application.json" "$FLUENTD_IMAGE" "$image_id" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
apps = [x for x in document["items"] if x["kind"] == "Deployment" and x["metadata"].get("namespace") == "mts-app" and x["metadata"]["name"] == "nginx-demo"]
assert len(apps) == 1, "expected one nginx-demo Deployment"
template = apps[0]["spec"]["template"]
sidecars = [c for c in template["spec"]["containers"] if c["name"] == "fluentd"]
assert len(sidecars) == 1 and sidecars[0]["image"] == sys.argv[2] and sidecars[0]["imagePullPolicy"] == "Never", "Fluentd image/policy mismatch"
template.setdefault("metadata", {}).setdefault("annotations", {})["mts-engineer-hack/fluentd-image-id"] = sys.argv[3]
path.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n")
PY
  printf 'Fluentd built and loaded: %s (%s)\n' "$FLUENTD_IMAGE" "$image_id"
}
