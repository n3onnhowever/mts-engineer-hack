#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
MODE=runtime
TIMEOUT=180

usage() {
  cat <<'USAGE'
Usage: tests/gateway-app.sh [--static | --runtime] [--timeout SECONDS]

--static   Render the two bases and check YAML, pins, interfaces, configuration
           checksum and rejection of stale/mismatched Gateway status. No cluster
           access or application requests. Requires kubectl, Python 3 and PyYAML.
--runtime  Default: wait for current Gateway/route/listener conditions, discover
           exactly one labeled proxy Service, then assert root, missing-file and
           wrong-host responses through the existing Gateway forward.
--timeout  Runtime readiness deadline, 1..600 seconds (default: 180).
--help     Show this help.

Runtime requires KUBE_CONTEXT=kind-mts-engineer,
GATEWAY_BASE_URL=http://127.0.0.1:8080, RUN_ID=mts-<UTC timestamp>-<random hex>,
and EVIDENCE_DIR underneath the repository's ignored .local/ directory.
scripts/verify.sh starts the proxy Service port-80 forward; this test never starts
a forward, applies resources or changes kubeconfig. Loki delivery is tested by tests/observability.sh.
USAGE
}

while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --static) MODE=static; shift ;;
    --runtime) MODE=runtime; shift ;;
    --timeout)
      if (($# < 2)) || [[ ! "$2" =~ ^[0-9]{1,3}$ ]]; then
        printf 'gateway-app: --timeout requires 1..600 seconds\n' >&2; exit 64
      fi
      TIMEOUT=$((10#$2))
      if ((TIMEOUT < 1 || TIMEOUT > 600)); then
        printf 'gateway-app: --timeout requires 1..600 seconds\n' >&2; exit 64
      fi
      shift 2 ;;
    *) printf 'gateway-app: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

python3 - "$ROOT" "$MODE" "$TIMEOUT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(sys.argv[1])
MODE = sys.argv[2]
TIMEOUT = int(sys.argv[3])
GROUP = "gateway.networking.k8s.io"
CONTROLLER = "gateway.envoyproxy.io/gatewayclass-controller"
LABEL = "app.kubernetes.io/name"
PART = "app.kubernetes.io/part-of"
PROXY_LABELS = {
    "gateway.envoyproxy.io/owning-gateway-namespace": "mts-app",
    "gateway.envoyproxy.io/owning-gateway-name": "mts-gateway",
}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def conditions(items, generation, types, owner):
    for kind in types:
        found = [c for c in items if c.get("type") == kind]
        require(len(found) == 1, f"{owner}: missing/duplicate {kind}")
        c = found[0]
        require(c.get("status") == "True" and c.get("observedGeneration") == generation,
                f"{owner}: {kind} is false, unknown or stale")


def ready(snapshot):
    gc, gw, route, services = snapshot
    for obj, kind, name, namespace in (
        (gc, "GatewayClass", "mts-envoy", None),
        (gw, "Gateway", "mts-gateway", "mts-app"),
        (route, "HTTPRoute", "nginx-demo", "mts-app"),
    ):
        meta = obj["metadata"]
        require(obj.get("kind") == kind and meta.get("name") == name
                and meta.get("namespace") == namespace, f"unexpected {kind} identity")
        require(isinstance(meta.get("generation"), int) and meta["generation"] > 0,
                f"{kind}: missing generation")
    require(gc["spec"]["controllerName"] == CONTROLLER, "wrong GatewayClass controller")
    require(gw["spec"]["gatewayClassName"] == "mts-envoy", "wrong Gateway class")
    require(gw["spec"].get("infrastructure", {}).get("parametersRef") == {
        "group": "gateway.envoyproxy.io", "kind": "EnvoyProxy", "name": "mts-proxy",
    }, "Gateway EnvoyProxy reference mismatch")
    declared_listeners = gw["spec"].get("listeners", [])
    require(len(declared_listeners) == 1, "expected exactly one declared listener")
    declared = declared_listeners[0]
    require(all(declared.get(k) == v for k, v in {
        "name": "http", "protocol": "HTTP", "port": 80, "hostname": "mts.local",
    }.items()) and declared.get("allowedRoutes", {}).get("namespaces", {}).get("from") == "Same",
            "Gateway listener interface mismatch")
    require(route["spec"]["hostnames"] == ["mts.local"], "wrong route hostname")
    refs = route["spec"].get("parentRefs", [])
    require(len(refs) == 1 and refs[0].get("name") == "mts-gateway"
            and refs[0].get("sectionName") == "http" and refs[0].get("namespace", "mts-app") == "mts-app"
            and refs[0].get("group", GROUP) == GROUP and refs[0].get("kind", "Gateway") == "Gateway"
            and refs[0].get("port", 80) == 80, "HTTPRoute parent interface mismatch")
    rules = route["spec"].get("rules", [])
    require(len(rules) == 1 and rules[0].get("matches") == [{"path": {"type": "PathPrefix", "value": "/"}}]
            and not rules[0].get("filters"), "HTTPRoute path/filter mismatch")
    backends = rules[0].get("backendRefs", [])
    require(len(backends) == 1 and backends[0].get("name") == "nginx-demo"
            and backends[0].get("port") == 80 and backends[0].get("weight", 1) == 1
            and backends[0].get("group", "") == "" and backends[0].get("kind", "Service") == "Service"
            and backends[0].get("namespace", "mts-app") == "mts-app" and not backends[0].get("filters"),
            "HTTPRoute backend interface mismatch")
    conditions(gc.get("status", {}).get("conditions", []), gc["metadata"]["generation"],
               ["Accepted"], "GatewayClass")
    generation = gw["metadata"]["generation"]
    status = gw.get("status", {})
    conditions(status.get("conditions", []), generation, ["Accepted", "Programmed"], "Gateway")
    listeners = [v for v in status.get("listeners", []) if v.get("name") == "http"]
    require(len(listeners) == 1, "missing/duplicate http listener status")
    listener = listeners[0]
    conditions(listener.get("conditions", []), generation,
               ["Accepted", "Programmed", "ResolvedRefs"], "http listener")
    require(listener.get("attachedRoutes", 0) >= 1, "http listener has no attached route")
    require(any(k.get("group", GROUP) == GROUP and k.get("kind") == "HTTPRoute"
                for k in listener.get("supportedKinds", [])), "HTTPRoute not supported by listener")
    parents = []
    for parent in route.get("status", {}).get("parents", []):
        ref = parent.get("parentRef", {})
        if (parent.get("controllerName") == CONTROLLER and ref.get("name") == "mts-gateway"
                and ref.get("namespace", "mts-app") == "mts-app"
                and ref.get("group", GROUP) == GROUP and ref.get("kind", "Gateway") == "Gateway"
                and ref.get("sectionName") == "http" and ref.get("port", 80) == 80):
            parents.append(parent)
    require(len(parents) == 1, "missing/duplicate status for the correct parent/controller")
    conditions(parents[0].get("conditions", []), route["metadata"]["generation"],
               ["Accepted", "ResolvedRefs"], "HTTPRoute parent")
    proxies = services.get("items", [])
    require(len(proxies) == 1, f"expected one labeled proxy Service, got {len(proxies)}")
    proxy = proxies[0]
    require(proxy["metadata"].get("namespace") == "envoy-gateway-system",
            "proxy Service is outside the default controller namespace")
    require(all(proxy["metadata"].get("labels", {}).get(k) == v for k, v in PROXY_LABELS.items()),
            "proxy Service owning-Gateway labels mismatch")
    require(proxy["spec"].get("type") == "ClusterIP", "proxy Service must be ClusterIP")
    require(len([p for p in proxy["spec"]["ports"]
                 if p.get("port") == 80 and p.get("protocol", "TCP") == "TCP"]) == 1,
            "proxy Service must expose exactly one TCP port 80")
    return proxy["metadata"]["name"]


def static():
    import yaml

    class UniqueLoader(yaml.SafeLoader):
        pass

    def mapping(loader, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            require(key not in result, f"duplicate YAML key: {key}")
            result[key] = loader.construct_object(value_node, deep=deep)
        return result

    UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
    require(b"\r" not in (ROOT / "tests/gateway-app.sh").read_bytes(), "CRLF in gateway-app.sh")
    resources = []
    for scope in ("app", "gateway"):
        directory = ROOT / "kubernetes" / scope
        for file in directory.glob("*.yaml"):
            require(b"\r" not in file.read_bytes(), f"CRLF in {file.name}")
            list(yaml.load_all(file.read_text(), Loader=UniqueLoader))
        rendered = subprocess.check_output(["kubectl", "kustomize", str(directory)], text=True)
        resources.extend(yaml.load_all(rendered, Loader=UniqueLoader))
    expected = {
        ("ConfigMap", "nginx-demo-config"), ("Deployment", "nginx-demo"),
        ("Service", "nginx-demo"), ("ServiceAccount", "nginx-demo"),
        ("GatewayClass", "mts-envoy"), ("Gateway", "mts-gateway"),
        ("HTTPRoute", "nginx-demo"), ("EnvoyProxy", "mts-proxy"),
    }
    objects = {(r["kind"], r["metadata"]["name"]): r for r in resources}
    require(len(resources) == len(objects) and set(objects) == expected,
            "missing, duplicate or extra resources in the two bases")
    for (kind, _), obj in objects.items():
        require(obj["metadata"].get("labels", {}).get(PART) == "mts-engineer-hack",
                f"{kind}: project label missing")
        require(obj["metadata"].get("namespace") == (None if kind == "GatewayClass" else "mts-app"),
                f"{kind}: namespace mismatch")
        api = ("apps/v1" if kind == "Deployment" else
               GROUP + "/v1" if kind in ("GatewayClass", "Gateway", "HTTPRoute") else
               "gateway.envoyproxy.io/v1alpha1" if kind == "EnvoyProxy" else "v1")
        require(obj["apiVersion"] == api, f"{kind}: API version mismatch")
    pins = dict(line.strip().split("=", 1) for line in (ROOT / "config/versions.env").read_text().splitlines()
                if line.strip() and not line.startswith("#"))
    deployment = objects["Deployment", "nginx-demo"]
    template = deployment["spec"]["template"]
    pod = template["spec"]
    require(deployment["spec"]["replicas"] == 1, "app replica mismatch")
    require(deployment["spec"]["selector"]["matchLabels"] == {LABEL: "nginx-demo"},
            "Deployment selector mismatch")
    require(template["metadata"]["labels"][LABEL] == "nginx-demo", "pod selector label mismatch")
    require(pod["serviceAccountName"] == "nginx-demo" and pod["automountServiceAccountToken"] is False,
            "app must not have API credentials")
    require(objects["ServiceAccount", "nginx-demo"]["automountServiceAccountToken"] is False,
            "ServiceAccount must not mount API credentials")
    require(pod["securityContext"]["fsGroup"] == 2000, "shared-log fsGroup mismatch")
    require(len(pod["containers"]) == 1 and pod["containers"][0]["name"] == "nginx",
            "app base must contain only Nginx")
    nginx = pod["containers"][0]
    require(nginx["image"] == pins["NGINX_IMAGE"], "Nginx image pin mismatch")
    require(nginx["command"] == ["nginx"] and nginx["args"] == ["-g", "daemon off;"],
            "Nginx must start the committed configuration directly")
    require(nginx["ports"] == [{"name": "http", "containerPort": 8080, "protocol": "TCP"}],
            "Nginx port mismatch")
    require(nginx["securityContext"]["runAsGroup"] == 2000
            and nginx["securityContext"]["runAsNonRoot"] is True, "log writer permission mismatch")
    for probe in ("readinessProbe", "livenessProbe"):
        require(nginx[probe]["httpGet"] == {"path": "/healthz", "port": "http"}, f"{probe} mismatch")
        require(nginx[probe]["timeoutSeconds"] > 0 and nginx[probe]["failureThreshold"] > 0,
                f"{probe} must be bounded")
    for bound in ("requests", "limits"):
        require(all(nginx["resources"][bound].get(k) for k in ("cpu", "memory")),
                f"missing resource {bound}")
    volumes = {v["name"]: v for v in pod["volumes"]}
    mounts = {v["name"]: v for v in nginx["volumeMounts"]}
    require("emptyDir" in volumes["app-logs"] and mounts["app-logs"]["mountPath"] == "/var/log/nginx"
            and not mounts["app-logs"].get("readOnly", False), "shared log volume mismatch")
    require(volumes["nginx-config"]["configMap"]["name"] == "nginx-demo-config"
            and mounts["nginx-config"]["mountPath"] == "/etc/nginx/nginx.conf"
            and mounts["nginx-config"]["readOnly"] is True, "configuration mount mismatch")
    require(all("hostPath" not in v for v in volumes.values()), "hostPath is forbidden")
    service = objects["Service", "nginx-demo"]["spec"]
    require(service["type"] == "ClusterIP" and service["selector"] == {LABEL: "nginx-demo"},
            "app Service selector/type mismatch")
    require(service["ports"] == [{"name": "http", "port": 80, "targetPort": "http", "protocol": "TCP"}],
            "app Service ports mismatch")
    config = objects["ConfigMap", "nginx-demo-config"]["data"]["nginx.conf"]
    checksum = hashlib.sha256(config.encode()).hexdigest()
    require(template["metadata"]["annotations"].get("checksum/nginx-config") == checksum,
            "refresh pod-template checksum/nginx-config after editing ConfigMap data.nginx.conf")
    for directive in ("listen 8080;", "server_name mts.local;", "default_type text/plain;",
                      "error_log /var/log/nginx/error.log error;", "log_not_found on;",
                      "access_log /var/log/nginx/access.json mts_json;", "log_format mts_json escape=json"):
        require(directive in config, f"missing Nginx directive: {directive}")
    for path in ("/", "/healthz"):
        require(re.search(r"location\s*=\s*" + re.escape(path)
                          + r'\s*\{[^}]*return 200 "MTS Engineer Hack: OK\\n";', config),
                f"{path}: response must contain exactly the trailing LF")
    fields = {"timestamp": "$time_iso8601", "request_id": "$http_x_mts_request_id",
              "method": "$request_method", "path": "$uri", "status": "$status", "host": "$host"}
    log_format = re.search(r"log_format mts_json escape=json\s+(.*?);", config, re.S).group(1)
    log_json = "".join(re.findall(r"'([^']*)'", log_format))
    # Substitution checks valid JSON and integer status, including escaped input.
    for key, value in fields.items():
        replacement = "200" if key == "status" else json.dumps('quoted"\\value')[1:-1]
        log_json = log_json.replace(value, replacement)
    parsed = json.loads(log_json)
    require(set(parsed) == set(fields) and parsed["status"] == 200, "access JSON fields/types mismatch")
    require("buffer=" not in config and "flush=" not in config, "access log must be unbuffered")
    require(not re.search(r"\b(try_files|error_page|proxy_intercept_errors)\b", config),
            "missing-file errors must use native static handling")
    error_location = re.search(r"location /error/\s*\{([^}]*)\}", config, re.S)
    require(error_location is not None and "return" not in error_location.group(1)
            and "root /usr/share/nginx/html;" in config, "missing-file handler mismatch")
    gc = objects["GatewayClass", "mts-envoy"]
    gw = objects["Gateway", "mts-gateway"]
    route = objects["HTTPRoute", "nginx-demo"]
    proxy = objects["EnvoyProxy", "mts-proxy"]["spec"]
    require(gc["spec"] == {"controllerName": CONTROLLER}, "GatewayClass mismatch")
    require(gw["spec"] == {
        "gatewayClassName": "mts-envoy",
        "infrastructure": {"parametersRef": {"group": "gateway.envoyproxy.io", "kind": "EnvoyProxy", "name": "mts-proxy"}},
        "listeners": [{"name": "http", "protocol": "HTTP", "port": 80, "hostname": "mts.local",
                       "allowedRoutes": {"namespaces": {"from": "Same"}}}],
    }, "Gateway listener/infrastructure mismatch")
    require(route["spec"] == {
        "hostnames": ["mts.local"], "parentRefs": [{"name": "mts-gateway", "sectionName": "http"}],
        "rules": [{"matches": [{"path": {"type": "PathPrefix", "value": "/"}}],
                   "backendRefs": [{"name": "nginx-demo", "port": 80, "weight": 1}]}],
    }, "HTTPRoute match/backend mismatch")
    provider = proxy["provider"]
    require(provider["type"] == "Kubernetes" and provider["kubernetes"]["envoyService"]["type"] == "ClusterIP",
            "Envoy proxy Service mismatch")
    envoy = provider["kubernetes"]["envoyDeployment"]
    require(envoy["replicas"] == 1 and envoy["container"]["image"] == pins["ENVOY_PROXY_IMAGE"],
            "Envoy proxy image/replicas mismatch")
    require(not proxy.get("mergeGateways", False), "merged gateways are forbidden")
    status_regressions(gc, gw, route)
    print("gateway-app static: 8 resources; pins, interfaces, log config/checksum and status regressions passed")


def status_regressions(gc, gw, route):
    def true_conditions(types):
        return [{"type": kind, "status": "True", "observedGeneration": 2} for kind in types]
    gc, gw, route = copy.deepcopy((gc, gw, route))
    for obj in (gc, gw, route):
        obj["metadata"]["generation"] = 2
    gc["status"] = {"conditions": true_conditions(["Accepted"])}
    gw["status"] = {"conditions": true_conditions(["Accepted", "Programmed"]), "listeners": [{
        "name": "http", "attachedRoutes": 1, "supportedKinds": [{"group": GROUP, "kind": "HTTPRoute"}],
        "conditions": true_conditions(["Accepted", "Programmed", "ResolvedRefs"])}]}
    route["status"] = {"parents": [{"parentRef": {"name": "mts-gateway", "sectionName": "http"},
                                     "controllerName": CONTROLLER,
                                     "conditions": true_conditions(["Accepted", "ResolvedRefs"])}]}
    service = {"metadata": {"name": "generated-proxy", "namespace": "envoy-gateway-system", "labels": PROXY_LABELS},
               "spec": {"type": "ClusterIP", "ports": [{"port": 80, "protocol": "TCP"}]}}
    good = (gc, gw, route, {"items": [service]})
    require(ready(good) == "generated-proxy", "valid Gateway fixture rejected")
    mutations = [
        lambda s: s[0]["status"]["conditions"][0].update(observedGeneration=1),
        lambda s: s[1]["status"]["conditions"][1].update(status="False"),
        lambda s: s[1]["status"]["listeners"][0]["conditions"][0].update(observedGeneration=1),
        lambda s: s[1]["status"]["listeners"][0].update(attachedRoutes=0),
        lambda s: s[2]["status"]["parents"][0].update(controllerName="other-controller"),
        lambda s: s[2]["status"]["parents"][0]["parentRef"].update(namespace="other"),
        lambda s: s[2]["status"]["parents"][0]["parentRef"].update(sectionName="other"),
        lambda s: s[2]["status"]["parents"][0]["conditions"][1].update(observedGeneration=1),
        lambda s: s[2]["spec"]["rules"][0]["backendRefs"][0].update(port=8080),
        lambda s: s[1]["spec"]["listeners"][0].update(hostname="other.invalid"),
        lambda s: s[3]["items"].append(copy.deepcopy(service)),
        lambda s: s[3]["items"][0]["metadata"].update(namespace="mts-app"),
        lambda s: s[3]["items"][0]["spec"]["ports"][0].update(port=8080),
    ]
    for mutate in mutations:
        bad = copy.deepcopy(good)
        mutate(bad)
        try:
            ready(bad)
        except ValueError:
            continue
        raise ValueError("unsafe Gateway status fixture accepted")


def runtime():
    require(os.environ.get("KUBE_CONTEXT") == "kind-mts-engineer", "KUBE_CONTEXT must be kind-mts-engineer")
    require(os.environ.get("GATEWAY_BASE_URL") == "http://127.0.0.1:8080",
            "GATEWAY_BASE_URL must be http://127.0.0.1:8080 (scripts/verify.sh proxy forward)")
    run_id = os.environ.get("RUN_ID", "")
    require(re.fullmatch(r"mts-[A-Za-z0-9-]+-[0-9a-f]+", run_id), "missing/unsafe RUN_ID")
    evidence_value = os.environ.get("EVIDENCE_DIR", "")
    require(evidence_value, "EVIDENCE_DIR is required")
    evidence = Path(evidence_value)
    evidence = (evidence if evidence.is_absolute() else ROOT / evidence).resolve()
    require(evidence.is_relative_to((ROOT / ".local").resolve()) and evidence != (ROOT / ".local").resolve(),
            "EVIDENCE_DIR must be underneath repository .local/")
    evidence = evidence / "gateway-app"
    evidence.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + TIMEOUT
    commands = [
        ("gatewayclass", ["gatewayclass", "mts-envoy"]),
        ("gateway", ["gateway", "mts-gateway", "-n", "mts-app"]),
        ("httproute", ["httproute", "nginx-demo", "-n", "mts-app"]),
        ("proxy-services", ["services", "-n", "envoy-gateway-system", "-l",
                            ",".join(k + "=" + v for k, v in PROXY_LABELS.items())]),
    ]
    while True:
        try:
            snapshot = []
            for name, args in commands:
                remaining = deadline - time.monotonic()
                require(remaining > 0, "readiness deadline reached")
                result = subprocess.run(["kubectl", "--context", "kind-mts-engineer", "--request-timeout=5s",
                                         "get", *args, "-o", "json"], capture_output=True, text=True,
                                        timeout=min(6, remaining))
                (evidence / (name + ".json")).write_text(result.stdout)
                (evidence / (name + ".stderr")).write_text(result.stderr)
                require(result.returncode == 0, f"cannot read {name}; see local evidence")
                snapshot.append(json.loads(result.stdout))
            proxy_name = ready(snapshot)
            break
        except (ValueError, KeyError, subprocess.TimeoutExpired) as error:
            (evidence / "readiness.txt").write_text(str(error) + "\n")
            remaining = deadline - time.monotonic()
            require(remaining > 0, f"Gateway readiness timed out: {error}")
            time.sleep(min(2, remaining))

    def request(name, path, host, request_id):
        result = subprocess.run([
            "curl", "--silent", "--show-error", "--noproxy", "*", "--connect-timeout", "2", "--max-time", "10",
            "--request", "GET", "--header", "Host: " + host, "--header", "X-MTS-Request-ID: " + request_id,
            "--dump-header", str(evidence / (name + ".headers")), "--output", str(evidence / (name + ".body")),
            "--write-out", "%{http_code}", os.environ["GATEWAY_BASE_URL"] + path,
        ], capture_output=True, text=True, timeout=12)
        (evidence / (name + ".status")).write_text(result.stdout + "\n")
        (evidence / (name + ".stderr")).write_text(result.stderr)
        require(result.returncode == 0, f"{name}: Gateway request failed; see local evidence")
        return result.stdout

    require(request("root", "/", "mts.local", run_id + "-access") == "200", "GET /: expected HTTP 200")
    require((evidence / "root.body").read_bytes() == b"MTS Engineer Hack: OK\n", "GET /: response bytes mismatch")
    headers = (evidence / "root.headers").read_text().splitlines()
    content_types = [h.split(":", 1)[1].strip().lower() for h in headers if h.lower().startswith("content-type:")]
    require(content_types == ["text/plain"], "GET /: expected Content-Type text/plain")
    require(request("missing-file", "/error/" + run_id + "-error", "mts.local", run_id + "-error") == "404",
            "missing static file: expected HTTP 404 through Gateway")
    require(request("wrong-host", "/", "wrong.invalid", run_id + "-wrong-host") == "404",
            "unmatched hostname: expected Gateway HTTP 404")
    print(f"gateway-app runtime: proxy={proxy_name}:80; current conditions; root=200 exact; missing-file=404; wrong-host=404")


try:
    static() if MODE == "static" else runtime()
except (ValueError, KeyError, OSError, ImportError, subprocess.SubprocessError) as error:
    print(f"gateway-app: {error}", file=sys.stderr)
    sys.exit(1)
PY
