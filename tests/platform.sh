#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  printf '%s\n' \
    'Usage: bash tests/platform.sh [--static|--runtime|--help]' \
    'Default --static validates local manifests, pins, scripts and readiness fixtures.' \
    '--runtime performs bounded, read-only platform and Gateway readiness checks.' \
    'Readiness alone is not application, metrics or log acceptance.'
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 64
fi
case "${1:---static}" in
  --help) usage; exit 0 ;;
  --static) ;;
  --runtime)
    if [[ "${KUBE_CONTEXT:-kind-mts-engineer}" != kind-mts-engineer ]]; then
      printf '%s\n' 'platform: KUBE_CONTEXT must be kind-mts-engineer.' >&2
      exit 64
    fi
    # shellcheck source=../scripts/lib/common.sh
    source "$REPO_ROOT/scripts/lib/common.sh"
    wait_platform
    wait_gateway
    printf '%s\n' 'platform: current platform and Gateway readiness checks passed; traffic acceptance is separate.'
    exit 0
    ;;
  *) usage >&2; exit 64 ;;
esac

for tool in bash python3 kubectl openssl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'platform: required static-check tool is missing: %s\n' "$tool" >&2
    exit 1
  fi
done
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  printf '%s\n' 'platform: Python PyYAML is required for static manifest checks.' >&2
  exit 1
fi

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find "$REPO_ROOT/scripts" -type f -name '*.sh' -print0)
bash -n "${BASH_SOURCE[0]}"

python3 - "$REPO_ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

import yaml

root = Path(sys.argv[1])


def require(condition, message):
    if not condition:
        raise SystemExit(f"platform: {message}")


def run(argv, **kwargs):
    try:
        return subprocess.run(argv, text=True, capture_output=True, timeout=30, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"platform: local check failed or exceeded 30 seconds: {error}")


def documents(path):
    try:
        result = [entry for entry in yaml.safe_load_all(path.read_text()) if entry is not None]
    except (OSError, yaml.YAMLError) as error:
        raise SystemExit(f"platform: cannot parse {path.relative_to(root)}: {error}")
    require(all(isinstance(entry, dict) for entry in result), f"non-object YAML document in {path.relative_to(root)}")
    return result


pins = {}
for line in (root / "config/versions.env").read_text().splitlines():
    fields = shlex.split(line, comments=True)
    if not fields:
        continue
    require(len(fields) == 1 and "=" in fields[0], "versions.env must contain simple KEY=value pins")
    key, value = fields[0].split("=", 1)
    require(key not in pins and re.fullmatch(r"[A-Z][A-Z0-9_]*", key), f"invalid/duplicate pin: {key}")
    pins[key] = value
for key, value in pins.items():
    if key.endswith("_IMAGE") and key != "FLUENTD_IMAGE":
        require(re.fullmatch(r"[^\s]+:[^\s:@]+@sha256:[0-9a-f]{64}", value), f"upstream image must have a version tag and SHA256 digest: {key}")
        require(not re.search(r":(?:latest|main|master|dev|nightly)(?:@|$)", value), f"moving image tag is forbidden: {key}")
recipe_prefix = f'mts-engineer/fluentd:{pins["FLUENTD_VERSION"]}-loki{pins["FLUENTD_LOKI_PLUGIN_VERSION"]}-r'
require(re.fullmatch(re.escape(recipe_prefix) + r"[1-9][0-9]*", pins["FLUENTD_IMAGE"]), "Fluentd local recipe tag disagrees with runtime/plugin pins")

yaml_paths = sorted(set((root / "kind").rglob("*.yaml")) | set((root / "kubernetes/platform").rglob("*.yaml")) | set((root / "kubernetes/vendor").rglob("*.yaml")) | {root / "kubernetes/kustomization.yaml"})
for path in yaml_paths:
    require(path.is_file(), f"required YAML file is missing: {path.relative_to(root)}")
    require(b"\r" not in path.read_bytes(), f"expected LF line endings: {path.relative_to(root)}")
    documents(path)

cluster = documents(root / "kind/cluster.yaml")
require(len(cluster) == 1, "kind definition must contain exactly one cluster")
cluster = cluster[0]
require(cluster.get("kind") == "Cluster" and cluster.get("name") == "mts-engineer", "kind cluster identity differs from required identity")
require(cluster.get("apiVersion") == "kind.x-k8s.io/v1alpha4", "unexpected kind config API")
require(cluster.get("nodes") == [{"role": "control-plane", "image": pins["KIND_NODE_IMAGE"]}], "kind definition must use one control-plane with the exact node image pin")
require(pins["KUBERNETES_VERSION"] in pins["KIND_NODE_IMAGE"], "node version and image pins disagree")

vendor = root / "kubernetes/vendor/envoy-gateway" / pins["ENVOY_GATEWAY_VERSION"]
install = vendor / "base/install.yaml"
require(hashlib.sha256(install.read_bytes()).hexdigest() == pins["ENVOY_GATEWAY_INSTALL_SHA256"], "vendored installer SHA256 differs from versions.env")
require(pins["ENVOY_GATEWAY_INSTALL_URL"] == f'https://github.com/envoyproxy/gateway/releases/download/{pins["ENVOY_GATEWAY_VERSION"]}/install.yaml', "installer source/version pins disagree")
source_metadata = dict(line.split("=", 1) for line in (vendor / "source.env").read_text().splitlines() if line and not line.startswith("#"))
require(source_metadata == {"VERSION": pins["ENVOY_GATEWAY_VERSION"], "SOURCE_URL": pins["ENVOY_GATEWAY_INSTALL_URL"], "SHA256": pins["ENVOY_GATEWAY_INSTALL_SHA256"]}, "vendor source metadata disagrees with versions.env")
require((vendor / "install.sha256").read_text().split() == [pins["ENVOY_GATEWAY_INSTALL_SHA256"], "base/install.yaml"], "vendor checksum file disagrees with versions.env or installer path")
upstream = documents(install)
gateway_crds = [entry for entry in upstream if entry.get("kind") == "CustomResourceDefinition" and entry.get("spec", {}).get("group") == "gateway.networking.k8s.io"]
require(gateway_crds, "vendored installer does not contain Gateway API CRDs")
for crd in gateway_crds:
    require(crd.get("metadata", {}).get("annotations", {}).get("gateway.networking.k8s.io/bundle-version") == pins["GATEWAY_API_VERSION"], f'Gateway API bundle version mismatch: {crd.get("metadata", {}).get("name")}')

composition = documents(root / "kubernetes/kustomization.yaml")
require(len(composition) == 1 and composition[0].get("kind") == "Kustomization", "root must be one Kustomization")
resources = composition[0].get("resources", [])
require(isinstance(resources, list) and len(resources) == 3 and {item.removeprefix("./").rstrip("/") for item in resources} == {"platform", "gateway", "observability"}, "root composition must include platform, gateway, observability exactly once, without the app base or upstream installer")
require("namespace" not in composition[0], "root must preserve the declared resource namespaces")

# Every build below is local: kustomize does not contact Kubernetes. No plugins,
# Helm execution, remote resources or apply commands are enabled by this test.
def build(relative):
    result = run(["kubectl", "--context", "kind-mts-engineer", "kustomize", str(root / relative)], cwd="/tmp", env={**os.environ, "KUBECONFIG": "/dev/null"})
    require(result.returncode == 0, f"local kustomize build failed for {relative}: {result.stderr.strip()}")
    return [entry for entry in yaml.safe_load_all(result.stdout) if entry is not None]


platform = build("kubernetes/platform")
namespaces = [entry for entry in platform if entry.get("kind") == "Namespace"]
require(len(namespaces) == 3 and {entry.get("metadata", {}).get("name") for entry in namespaces} == {"envoy-gateway-system", "mts-app", "mts-observability"}, "platform must own exactly the three required namespaces")
for namespace in namespaces:
    require(namespace["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") == "mts-engineer-hack", "project namespace lacks the ownership label")

local_phases = [vendor / phase for phase in ("crds", "prerequisites", "certgen", "controller")]
phase_objects = []
for phase in local_phases:
    require((phase / "kustomization.yaml").is_file(), f"missing installation phase: {phase.name}")
    phase_objects.extend(build(phase.relative_to(root)))
phase_identities = [(entry.get("apiVersion"), entry.get("kind"), entry.get("metadata", {}).get("namespace"), entry.get("metadata", {}).get("name")) for entry in phase_objects + platform]
require(len(phase_identities) == len(set(phase_identities)), "upstream phases and platform contain duplicate resources")
require(sum(entry.get("kind") == "CustomResourceDefinition" for entry in phase_objects) == sum(entry.get("kind") == "CustomResourceDefinition" for entry in upstream), "installation phases lost or duplicated upstream CRDs")

pod_templates = [entry["spec"]["template"]["spec"] for entry in phase_objects if entry.get("kind") in {"Deployment", "Job"}]
require(any(entry.get("kind") == "Deployment" and entry.get("metadata", {}).get("name") == "envoy-gateway" for entry in phase_objects), "local phases lack the Envoy Gateway controller Deployment")
require(any(entry.get("kind") == "Job" for entry in phase_objects), "local phases lack certgen Job")
for spec in pod_templates:
    for container in spec.get("initContainers", []) + spec.get("containers", []):
        require(container.get("image") == pins["ENVOY_GATEWAY_IMAGE"], f'controller/certgen image differs from pin: {container.get("name")}')

configmaps = [entry for entry in phase_objects if entry.get("kind") == "ConfigMap" and entry.get("metadata", {}).get("name") == "envoy-gateway-config"]
require(configmaps, "local phases lack envoy-gateway-config")
for configmap in configmaps:
    configuration = "\n".join(configmap.get("data", {}).values())
    require("shutdownManager" in configuration and pins["ENVOY_GATEWAY_IMAGE"] in configuration, "controller config must explicitly pin shutdownManager to ENVOY_GATEWAY_IMAGE")
    parsed_config = yaml.safe_load(configmap["data"]["envoy-gateway.yaml"])
    require(parsed_config.get("provider", {}).get("kubernetes", {}).get("shutdownManager", {}).get("image") == pins["ENVOY_GATEWAY_IMAGE"], "shutdownManager image override must use the correct Envoy Gateway configuration field")
    config_sha = hashlib.sha256(configmap["data"]["envoy-gateway.yaml"].encode()).hexdigest()
    controller_deployments = [entry for entry in phase_objects if entry.get("kind") == "Deployment" and entry.get("metadata", {}).get("name") == "envoy-gateway"]
    require(all(entry["spec"]["template"].get("metadata", {}).get("annotations", {}).get("checksum/config") == config_sha for entry in controller_deployments), "controller pod template configuration checksum is stale")
for job in (entry for entry in phase_objects if entry.get("kind") == "Job"):
    require(isinstance(job.get("spec", {}).get("activeDeadlineSeconds"), int) and 0 < job["spec"]["activeDeadlineSeconds"] <= 180, "certgen Job must have a bounded active deadline")
    require("ttlSecondsAfterFinished" not in job["spec"], "certgen completion must persist for idempotent reruns")

required_bases = [root / "kubernetes" / part / "kustomization.yaml" for part in ("gateway", "observability", "app")]
if all(path.is_file() for path in required_bases):
    integrated = build("kubernetes")
    identities = [(entry.get("apiVersion"), entry.get("kind"), entry.get("metadata", {}).get("namespace"), entry.get("metadata", {}).get("name")) for entry in integrated]
    require(len(identities) == len(set(identities)), "integrated root contains duplicate resources")
    require(sum(entry.get("kind") == "Deployment" and entry.get("metadata", {}).get("name") == "nginx-demo" for entry in integrated) == 1, "integrated root must include nginx-demo exactly once")
    require(not any(entry.get("kind") == "CustomResourceDefinition" or entry.get("metadata", {}).get("name") == "envoy-gateway" for entry in integrated), "upstream installation leaked into final application phase")
    print("platform: integrated root kustomize build passed.")
else:
    missing = ", ".join(str(path.relative_to(root)) for path in required_bases if not path.is_file())
    print(f"platform: integrated root build SKIPPED; required bases absent: {missing}")

print(f"platform: {len(yaml_paths)} YAML files, pinned installer, namespaces and local phases passed.")

# Sentinel executables make help/error paths fail if they attempt even a
# read-only external operation, before any credentials or cluster are consulted.
with tempfile.TemporaryDirectory(prefix="mts-platform-static-") as directory:
    scratch = Path(directory)
    sentinel = scratch / "external-command-called"
    for name in ("kubectl", "kind", "docker", "curl"):
        stub = scratch / name
        stub.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$0 $*" >> "$PLATFORM_SENTINEL"\nexit 97\n')
        stub.chmod(0o755)
    env = {**os.environ, "PATH": f'{scratch}:{os.environ["PATH"]}', "PLATFORM_SENTINEL": str(sentinel), "KUBECONFIG": "/dev/null", "KUBE_CONTEXT": "kind-mts-engineer"}
    argument_cases = []
    for name in ("bootstrap", "deploy", "destroy", "verify"):
        for args, expected in ((["--help"], 0), (["--unknown"], 64), (["--help", "--unknown"], 64)):
            argument_cases.append((root / f"scripts/{name}.sh", args, expected))
    for option in ("--prometheus-port", "--loki-port"):
        for value in ("0", "65536", "-1", "abc", "1.5", "", "999999999999999999999999999999999999999"):
            argument_cases.append((root / "scripts/verify.sh", [option, value], 64))
        argument_cases.append((root / "scripts/verify.sh", [option], 64))
    for args in (["--gateway-port", "8080"], ["--prometheus-port", "8080"], ["--loki-port", "8080"], ["--loki-port", "9090"], ["--prometheus-port", "3100"], ["--prometheus-port", "1234", "--loki-port", "1234"]):
        argument_cases.append((root / "scripts/verify.sh", args, 64))
    for args, expected in ((["--help"], 0), (["--unknown"], 64), (["--static", "--runtime"], 64)):
        argument_cases.append((root / "tests/platform.sh", args, expected))
    for path, args, expected in argument_cases:
        result = run(["bash", str(path), *args], cwd=directory, env=env)
        require(result.returncode == expected, f'{path.relative_to(root)} {args!r}: expected exit {expected}, got {result.returncode}: {result.stderr.strip()}')
        require(not sentinel.exists(), f'{path.relative_to(root)} {args!r} invoked an external command')
    bad_context = run(["bash", str(root / "tests/platform.sh"), "--runtime"], cwd=directory, env={**env, "KUBE_CONTEXT": "other-cluster"})
    require(bad_context.returncode == 64 and not sentinel.exists(), "runtime test must reject other contexts before external commands")
    print(f"platform: {len(argument_cases) + 1} help/invalid argument cases passed without external commands.")

checker = root / "scripts/lib/readiness.py"
controller = "gateway.envoyproxy.io/gatewayclass-controller"
current = 7


def conditions(*names):
    return [{"type": name, "status": "True", "observedGeneration": current} for name in names]


class_ok = {"kind": "GatewayClass", "metadata": {"name": "mts-envoy", "generation": current}, "spec": {"controllerName": controller}, "status": {"conditions": conditions("Accepted")}}
gateway_ok = {"kind": "Gateway", "metadata": {"namespace": "mts-app", "name": "mts-gateway", "generation": current}, "status": {"conditions": conditions("Accepted", "Programmed"), "listeners": [{"name": "http", "attachedRoutes": 1, "conditions": conditions("Accepted", "Programmed", "ResolvedRefs")}]}}
route_ok = {"kind": "HTTPRoute", "metadata": {"namespace": "mts-app", "name": "nginx-demo", "generation": current}, "status": {"parents": [{"controllerName": controller, "parentRef": {"name": "mts-gateway", "sectionName": "http"}, "conditions": conditions("Accepted", "ResolvedRefs")}]}}
node_ok = {"kind": "List", "items": [{"kind": "Node", "metadata": {"name": "mts-engineer-control-plane", "labels": {"node-role.kubernetes.io/control-plane": ""}}, "status": {"conditions": conditions("Ready"), "nodeInfo": {"kubeletVersion": pins["KUBERNETES_VERSION"], "operatingSystem": "linux", "architecture": "amd64"}}}]}
service_ok = {"kind": "List", "items": [{"kind": "Service", "metadata": {"name": "envoy-mts-gateway-example", "namespace": "envoy-gateway-system", "labels": {"gateway.envoyproxy.io/owning-gateway-namespace": "mts-app", "gateway.envoyproxy.io/owning-gateway-name": "mts-gateway"}}, "spec": {"type": "ClusterIP", "clusterIP": "10.96.0.10", "ports": [{"name": "http", "port": 80, "targetPort": 10080, "protocol": "TCP"}]}}]}
fixtures = 0


def check(mode, fixture, expected=0, stdout=""):
    global fixtures
    argv = [sys.executable, str(checker), mode]
    if mode == "nodes":
        argv.append(pins["KUBERNETES_VERSION"])
    result = run(argv, input=json.dumps(fixture))
    require(result.returncode == expected, f'readiness {mode}: expected exit {expected}, got {result.returncode}: {result.stderr.strip()}')
    if expected == 0:
        require(result.stdout == stdout, f"unexpected readiness {mode} success output")
    else:
        require(result.stdout == "" and result.stderr, f"readiness {mode} failure must emit a diagnostic without success output")
    fixtures += 1


def reject(mode, fixture, path, value):
    altered = copy.deepcopy(fixture)
    target = altered
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    check(mode, altered, 1)


for mode, fixture, stdout in (("gatewayclass", class_ok, ""), ("gateway", gateway_ok, ""), ("httproute", route_ok, ""), ("nodes", node_ok, ""), ("proxy-services", service_ok, "envoy-mts-gateway-example\n")):
    check(mode, fixture, stdout=stdout)
    check(mode, {}, 1)
    check(mode, [], 1)

for mode, fixture in (("gatewayclass", class_ok), ("gateway", gateway_ok), ("httproute", route_ok)):
    for invalid in (0, True, "7", None):
        reject(mode, fixture, ["metadata", "generation"], invalid)
    reject(mode, fixture, ["metadata", "deletionTimestamp"], "2026-01-01T00:00:00Z")
    reject(mode, fixture, ["metadata", "name"], "unrelated")

for mode, fixture, path in (("gatewayclass", class_ok, ["status", "conditions"]), ("gateway", gateway_ok, ["status", "conditions"]), ("gateway", gateway_ok, ["status", "listeners", 0, "conditions"]), ("httproute", route_ok, ["status", "parents", 0, "conditions"])):
    target = fixture
    for key in path:
        target = target[key]
    for index in range(len(target)):
        reject(mode, fixture, [*path, index, "observedGeneration"], current - 1)
        reject(mode, fixture, [*path, index, "observedGeneration"], str(current))
        reject(mode, fixture, [*path, index, "status"], "False")
    reject(mode, fixture, path, target + [copy.deepcopy(target[0])])
    reject(mode, fixture, path, target[1:])

reject("gatewayclass", class_ok, ["spec", "controllerName"], "other-controller")
reject("gateway", gateway_ok, ["status", "listeners", 0, "name"], "other-listener")
for invalid in (0, True, "1"):
    reject("gateway", gateway_ok, ["status", "listeners", 0, "attachedRoutes"], invalid)
reject("gateway", gateway_ok, ["status", "listeners"], gateway_ok["status"]["listeners"] * 2)
for key, value in (("name", "other-gateway"), ("sectionName", "https"), ("namespace", "other-namespace"), ("kind", "Service"), ("group", "example.invalid")):
    reject("httproute", route_ok, ["status", "parents", 0, "parentRef", key], value)
reject("httproute", route_ok, ["status", "parents", 0, "controllerName"], "other-controller")
reject("httproute", route_ok, ["status", "parents"], route_ok["status"]["parents"] * 2)

for key, value in (("kubeletVersion", "v0.0.0"), ("operatingSystem", "windows"), ("architecture", "arm64")):
    reject("nodes", node_ok, ["items", 0, "status", "nodeInfo", key], value)
reject("nodes", node_ok, ["items", 0, "status", "conditions", 0, "status"], "False")
reject("nodes", node_ok, ["items", 0, "metadata", "labels"], {})
reject("nodes", node_ok, ["items", 0, "metadata", "name"], "other-control-plane")

for mode, fixture in (("nodes", node_ok), ("proxy-services", service_ok)):
    reject(mode, fixture, ["items"], [])
    reject(mode, fixture, ["items"], fixture["items"] * 2)
    reject(mode, fixture, ["items", 0, "metadata", "deletionTimestamp"], "2026-01-01T00:00:00Z")
reject("proxy-services", service_ok, ["items", 0, "metadata", "namespace"], "mts-app")
reject("proxy-services", service_ok, ["items", 0, "metadata", "name"], "bad/name")
for key, value in (("gateway.envoyproxy.io/owning-gateway-namespace", "wrong"), ("gateway.envoyproxy.io/owning-gateway-name", "wrong")):
    reject("proxy-services", service_ok, ["items", 0, "metadata", "labels", key], value)
for key, value in (("type", "LoadBalancer"), ("clusterIP", "None"), ("clusterIP", ""), ("ports", [{"port": 8080}]), ("ports", [{"port": 80, "protocol": "UDP"}]), ("ports", [{"port": 80}, {"port": 80}])):
    reject("proxy-services", service_ok, ["items", 0, "spec", key], value)

for args, expected in ((["--help"], 0), ([], 64), (["unknown"], 64), (["nodes"], 64), (["nodes", "latest"], 64), (["gateway", "extra"], 64)):
    result = run([sys.executable, str(checker), *args], input="{}")
    require(result.returncode == expected, f"readiness argument handling failed for {args!r}")
for invalid_json in ("", "not-json", "{"):
    result = run([sys.executable, str(checker), "gateway"], input=invalid_json)
    require(result.returncode == 1 and "Traceback" not in result.stderr, "readiness malformed JSON must fail clearly")
print(f"platform: {fixtures} readiness fixtures and checker argument/JSON errors passed.")

manifest_helper = root / "scripts/lib/manifests.py"
ownership = {"app.kubernetes.io/part-of": "mts-engineer-hack"}
config = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": "mts-app", "name": "nginx-demo-config", "labels": ownership}, "data": {"nginx.conf": "worker_processes 1;\n"}}
deployment = {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"namespace": "mts-app", "name": "nginx-demo", "labels": ownership}, "spec": {"template": {"spec": {"containers": [{"name": "nginx", "image": pins["NGINX_IMAGE"]}], "volumes": [{"name": "config", "configMap": {"name": "nginx-demo-config"}}]}}}}
job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"namespace": "envoy-gateway-system", "name": "envoy-gateway-certgen"}, "spec": {"activeDeadlineSeconds": 180, "template": {"spec": {"restartPolicy": "Never", "containers": [{"name": "certgen", "image": pins["ENVOY_GATEWAY_IMAGE"]}]}}}}


def manifest_check(mode, items, expected=0):
    result = run([sys.executable, str(manifest_helper), mode], input=json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
    require(result.returncode == expected, f"manifest {mode}: expected {expected}, got {result.returncode}: {result.stderr.strip()}")
    if expected:
        require(result.stderr and "Traceback" not in result.stderr and not result.stdout, "invalid manifest must fail with a clear diagnostic")
        return None
    return json.loads(result.stdout)["items"]


annotation = "mts-engineer-hack/config-sha256"
rendered = manifest_check("render", [config, deployment])
baseline_hash = rendered[1]["spec"]["template"]["metadata"]["annotations"][annotation]
require(re.fullmatch(r"[0-9a-f]{64}", baseline_hash), "rollout config hash must be SHA256")
require(manifest_check("render", rendered) == rendered, "render must be idempotent")
reordered = manifest_check("render", [deployment, config])
require(reordered[0]["spec"]["template"]["metadata"]["annotations"][annotation] == baseline_hash, "config hash must not depend on manifest order")
changed_config = copy.deepcopy(config)
changed_config["data"]["nginx.conf"] = "worker_processes 2;\n"
changed = manifest_check("render", [changed_config, deployment])
require(changed[1]["spec"]["template"]["metadata"]["annotations"][annotation] != baseline_hash, "config changes must trigger a different pod template hash")
config_other_namespace = copy.deepcopy(config)
config_other_namespace["metadata"]["namespace"] = "mts-observability"
manifest_check("render", [config_other_namespace, deployment], 1)
manifest_check("render", [deployment], 1)
manifest_check("render", [config, config, deployment], 1)
bad_image = copy.deepcopy(deployment)
bad_image["spec"]["template"]["spec"]["containers"][0]["image"] = "nginx:latest"
manifest_check("render", [config, bad_image], 1)
manifest_check("render", [{"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "forbidden"}}], 1)
job_rendered = manifest_check("render", [job])
require(manifest_check("render", job_rendered) == job_rendered, "Job recipe hash must be idempotent")
modified_job = copy.deepcopy(job)
modified_job["spec"]["activeDeadlineSeconds"] = 120
modified_job_rendered = manifest_check("render", [modified_job])
require(job_rendered[0]["metadata"]["annotations"]["mts-engineer-hack/job-sha256"] != modified_job_rendered[0]["metadata"]["annotations"]["mts-engineer-hack/job-sha256"], "Job spec changes must update its recipe hash")
namespace = {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "mts-app", "labels": ownership}}
cleaned = manifest_check("cleanup", [namespace, config, deployment])
require(len(cleaned) == 2 and all(entry["kind"] != "Namespace" and "spec" not in entry and "data" not in entry for entry in cleaned), "cleanup must preserve namespaces and produce deletion identities only")
manifest_check("cleanup", [job], 1)
unowned = copy.deepcopy(config)
unowned["metadata"]["labels"] = {}
manifest_check("cleanup", [unowned], 1)
unknown = copy.deepcopy(config)
unknown["metadata"]["name"] = "not-project-owned"
manifest_check("cleanup", [unknown], 1)
print("platform: deterministic config/Job hashes, pinned images and cleanup allowlist fixtures passed.")

# Docker Desktop may expose an OCI index from inspect; CRI image IDs identify
# config bytes. Exercise the exported-config identity and mismatch failures.
import importlib.util
import io
import tarfile
sys.dont_write_bytecode = True
image_helper = root / "scripts/lib/image_identity.py"
module_spec = importlib.util.spec_from_file_location("image_identity", image_helper)
image_module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(image_module)
with tempfile.TemporaryDirectory(prefix="mts-image-static-") as directory:
    archive = Path(directory) / "image.tar"
    image = pins["FLUENTD_IMAGE"]
    recipe = "a" * 64
    config_bytes = json.dumps({"os": "linux", "architecture": "amd64", "config": {
        "Labels": {"mts-engineer-hack.fluentd-recipe-sha256": recipe}}}).encode()
    def export_fixture(manifests, data=config_bytes):
        with tarfile.open(archive, "w") as saved:
            for name, value in (("manifest.json", json.dumps(manifests).encode()), ("config.json", data)):
                info = tarfile.TarInfo(name)
                info.size = len(value)
                saved.addfile(info, io.BytesIO(value))
    manifest = {"Config": "config.json", "RepoTags": ["docker.io/" + image]}
    export_fixture([manifest])
    require(image_module.config_digest(archive, image, recipe) == "sha256:" + hashlib.sha256(config_bytes).hexdigest(), "exported config digest differs from CRI identity")
    for manifests, tag, expected_recipe, data in (
        ([manifest, manifest], image, recipe, config_bytes),
        ([manifest], "wrong:tag", recipe, config_bytes),
        ([manifest], image, "b" * 64, config_bytes),
        ([manifest], image, recipe, config_bytes.replace(b"amd64", b"arm64")),
    ):
        export_fixture(manifests, data)
        try:
            image_module.config_digest(archive, tag, expected_recipe)
        except ValueError:
            pass
        else:
            require(False, "invalid exported image identity accepted")
print("platform: exported image config identity and tag/recipe/platform mismatch fixtures passed.")

certificate_helper = root / "scripts/lib/certificates.py"
for args, expected in ((["--help"], 0), (["--unknown"], 64), (["--help", "extra"], 64)):
    result = run([sys.executable, str(certificate_helper), *args], input="{}")
    require(result.returncode == expected, f"certificate helper argument handling failed: {args!r}")
for kind in ("List", "SecretList"):
    result = run([sys.executable, str(certificate_helper)], input=json.dumps({"kind": kind, "items": []}))
    require(result.returncode == 0 and result.stdout == "fresh\n", "empty certgen Secret set must identify a fresh installation")
for bad_state in ({}, [], {"kind": "List", "items": None}, {"kind": "List", "items": [{}]}, {"kind": "List", "items": [{"kind": "ConfigMap"}] * 4}):
    result = run([sys.executable, str(certificate_helper)], input=json.dumps(bad_state))
    require(result.returncode == 1 and result.stderr and "Traceback" not in result.stderr and not result.stdout, "partial/malformed certgen Secret state must fail clearly")
result = run([sys.executable, str(certificate_helper)], input="invalid-json")
require(result.returncode == 1 and "Traceback" not in result.stderr, "certificate helper must reject malformed JSON")
print("platform: certificate helper arguments and fresh/invalid/partial Secret-state fixtures passed.")

secret_state_harness = r'''
set -euo pipefail
REPO_ROOT=$1
source "$REPO_ROOT/scripts/lib/install.sh"
kube() {
  if [[ $1 == get && $2 == namespace ]]; then
    [[ $SECRET_FIXTURE != namespace-api-error ]] || return 1
    printf 'namespace/envoy-gateway-system\n'
  elif [[ $1 == get && $2 == secrets ]]; then
    case $SECRET_FIXTURE in
      absent) return 0 ;;
      api-error) return 1 ;;
      malformed) printf 'invalid-json\n' ;;
    esac
  else
    return 97
  fi
}
certificates_state
'''
for fixture, expected in (("absent", 0), ("api-error", 1), ("namespace-api-error", 1), ("malformed", 1)):
    result = run(["bash", "-c", secret_state_harness, "secret-state", str(root)], env={**os.environ, "SECRET_FIXTURE": fixture})
    require(result.returncode == expected, f"named Secret lookup {fixture} returned the wrong state")
    require(result.stdout == ("fresh\n" if fixture == "absent" else ""), f"named Secret lookup {fixture} reported unsafe success")
print("platform: empty named Secret lookup, API failure and malformed-response fixtures passed.")

# Exercise the real immutable-Job decision function with shell doubles. Every
# cluster-facing helper is replaced before install_certificates is invoked.
# Fixture state is local metadata only; no certificate/key material is created.
lifecycle_harness = r'''
set -euo pipefail
REPO_ROOT=$1
DEPLOY_DIR=$SCENARIO_DIR
source "$REPO_ROOT/scripts/lib/install.sh"
die() { printf 'mock lifecycle failure: %s\n' "$*" >&2; exit 1; }
certificates_state() {
  local calls state
  calls=$(<"$SCENARIO_DIR/state-calls")
  printf '%s\n' "$((calls + 1))" >"$SCENARIO_DIR/state-calls"
  if [[ $calls == 0 ]]; then state=$INITIAL_STATE; else state=$FINAL_STATE; fi
  [[ $state != invalid ]] || return 1
  printf '%s\n' "$state"
}
webhook_matches_ca() {
  local calls matches
  calls=$(<"$SCENARIO_DIR/webhook-calls")
  printf '%s\n' "$((calls + 1))" >"$SCENARIO_DIR/webhook-calls"
  if [[ $calls == 0 ]]; then matches=$INITIAL_WEBHOOK; else matches=$FINAL_WEBHOOK; fi
  [[ $matches == true ]]
}
kube() {
  case "$*" in
    "get job $CERTGEN_JOB -n envoy-gateway-system --ignore-not-found -o json")
      printf 'get-job\n' >>"$SCENARIO_DIR/actions"
      printf '%s' "$EXISTING_JOB"
      ;;
    "delete job $CERTGEN_JOB -n envoy-gateway-system --wait=true --timeout=60s --request-timeout=90s")
      printf 'delete-job\n' >>"$SCENARIO_DIR/actions"
      ;;
    *) die "unexpected kube invocation: $*" ;;
  esac
}
apply_file() {
  [[ $1 == "$DEPLOY_DIR/certgen.json" ]] || die 'unexpected apply path'
  printf 'apply-job\n' >>"$SCENARIO_DIR/actions"
}
job_complete() { [[ $COMPLETE_AFTER_POLL == true ]]; }
poll() {
  [[ $# == 2 && $2 == job_complete ]] || die 'unexpected poll target'
  printf 'poll\n' >>"$SCENARIO_DIR/actions"
  "$2"
}
# Reject accidental bypasses of the shell doubles, including future refactors.
kubectl() { die 'direct kubectl is forbidden in lifecycle fixtures'; }
kind() { die 'kind is forbidden in lifecycle fixtures'; }
docker() { die 'docker is forbidden in lifecycle fixtures'; }
install_certificates
'''
complete_job = {"metadata": {"annotations": {"mts-engineer-hack/job-sha256": "desired-recipe"}}, "status": {"conditions": [{"type": "Complete", "status": "True"}]}}
running_job = copy.deepcopy(complete_job)
running_job["status"] = {"active": 1}
failed_job = copy.deepcopy(complete_job)
failed_job["status"]["conditions"] = [{"type": "Failed", "status": "True"}]
changed_job = copy.deepcopy(complete_job)
changed_job["metadata"]["annotations"]["mts-engineer-hack/job-sha256"] = "old-recipe"
cases = [
    ("reuse-complete", complete_job, "ready", "ready", "true", "true", "true", 0, ["get-job", "poll"]),
    ("wait-in-progress", running_job, "fresh", "ready", "true", "true", "true", 0, ["get-job", "poll"]),
    ("replace-failed", failed_job, "fresh", "ready", "true", "true", "true", 0, ["get-job", "delete-job", "apply-job", "poll"]),
    ("replace-changed-recipe", changed_job, "ready", "ready", "true", "true", "true", 0, ["get-job", "delete-job", "apply-job", "poll"]),
    ("replace-complete-without-secrets", complete_job, "fresh", "ready", "true", "true", "true", 0, ["get-job", "delete-job", "apply-job", "poll"]),
    ("create-new", None, "fresh", "ready", "true", "true", "true", 0, ["get-job", "apply-job", "poll"]),
    ("create-job-with-existing-secrets", None, "ready", "ready", "true", "true", "true", 0, ["get-job", "apply-job", "poll"]),
    ("reject-partial-secrets", complete_job, "invalid", "ready", "true", "true", "true", 1, []),
    ("replace-webhook-mismatch", complete_job, "ready", "ready", "false", "true", "true", 0, ["get-job", "delete-job", "apply-job", "poll"]),
    ("reject-missing-final-secrets", None, "fresh", "fresh", "true", "true", "true", 1, ["get-job", "apply-job", "poll"]),
    ("reject-final-webhook-mismatch", None, "fresh", "ready", "false", "false", "true", 1, ["get-job", "apply-job", "poll"]),
    ("propagate-poll-failure", running_job, "fresh", "ready", "true", "true", "false", 1, ["get-job", "poll"]),
]
with tempfile.TemporaryDirectory(prefix="mts-certgen-static-") as directory:
    for name, existing, initial, final, initial_webhook, final_webhook, completes, expected, actions in cases:
        scenario = Path(directory) / name
        scenario.mkdir()
        (scenario / "certgen.json").write_text(json.dumps({"items": [{"metadata": {"annotations": {"mts-engineer-hack/job-sha256": "desired-recipe"}}}]}))
        for counter in ("state-calls", "webhook-calls"):
            (scenario / counter).write_text("0\n")
        (scenario / "actions").write_text("")
        environment = {**os.environ, "SCENARIO_DIR": str(scenario), "INITIAL_STATE": initial, "FINAL_STATE": final, "INITIAL_WEBHOOK": initial_webhook, "FINAL_WEBHOOK": final_webhook, "COMPLETE_AFTER_POLL": completes, "EXISTING_JOB": json.dumps(existing) if existing else ""}
        result = run(["bash", "-c", lifecycle_harness, "certgen-lifecycle", str(root)], cwd=directory, env=environment)
        require(result.returncode == expected, f"certgen lifecycle {name}: expected exit {expected}, got {result.returncode}: {result.stderr.strip()}")
        require((scenario / "actions").read_text().splitlines() == actions, f"certgen lifecycle {name}: unexpected mutation/reuse sequence")
        if expected:
            require("Certificate job ready" not in result.stdout, f"certgen lifecycle {name}: failure reported success")
print(f"platform: {len(cases)} mocked certgen Job lifecycle cases passed without cluster calls.")

# Real local child processes verify trap behavior, without opening sockets or
# contacting Kubernetes. An unrelated process must survive both cleanup paths.
forward_harness = r'''
set -euo pipefail
die() { printf 'mock forward failure: %s\n' "$*" >&2; exit 1; }
source "$1/scripts/lib/forward.sh"
python3 -c "$2" "$FORWARD_DIR/child-ready" &
PF_PIDS+=("$!")
for ((attempt=0; attempt<100; attempt++)); do
  [[ -f $FORWARD_DIR/child-ready ]] && break
  sleep 0.02
done
[[ -f $FORWARD_DIR/child-ready ]] || die 'local fixture child did not start'
forwards_alive
exit "$FORWARD_EXIT"
'''
unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    with tempfile.TemporaryDirectory(prefix="mts-forward-static-") as directory:
        for label, ignores_term, exit_status in (("normal", False, 23), ("stubborn", True, 0)):
            scenario = Path(directory) / label
            scenario.mkdir()
            child_code = "import os,signal,sys,time; from pathlib import Path; "
            if ignores_term:
                child_code += "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            child_code += "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)"
            environment = {**os.environ, "FORWARD_DIR": str(scenario), "FORWARD_EXIT": str(exit_status)}
            owned_gone = False
            try:
                started = time.monotonic()
                result = run(["bash", "-c", forward_harness, "forward-lifecycle", str(root), child_code], cwd=directory, env=environment)
                duration = time.monotonic() - started
                require(result.returncode == exit_status, f"forward cleanup {label} did not preserve exit status: {result.stderr.strip()}")
                owned_pid = int((scenario / "child-ready").read_text())
                try:
                    os.kill(owned_pid, 0)
                except ProcessLookupError:
                    owned_gone = True
                else:
                    require(False, f"forward cleanup {label} left its owned child running")
                require(unrelated.poll() is None, f"forward cleanup {label} signalled an unrelated process")
                require(duration < 12, f"forward cleanup {label} exceeded its bounded shutdown allowance")
            finally:
                marker = scenario / "child-ready"
                if marker.is_file() and not owned_gone:
                    try:
                        os.kill(int(marker.read_text()), 9)
                    except ProcessLookupError:
                        pass
finally:
    unrelated.terminate()
    unrelated.wait(timeout=5)
print("platform: owned-forward traps preserved exit status, bounded shutdown and unrelated processes.")
PY

printf '%s\n' 'platform: static checks passed; live deployment and acceptance were not run.'
