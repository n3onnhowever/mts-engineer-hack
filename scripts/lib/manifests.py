#!/usr/bin/env python3
"""Render deterministic declarations; never contact Kubernetes or a registry."""
import hashlib
import json
from pathlib import Path
import sys

import yaml

ROOT = Path(__file__).resolve().parents[2]
PINS = dict(line.split("=", 1) for line in (ROOT / "config/versions.env").read_text().splitlines()
            if line and not line.startswith("#"))
ANNOTATION = "mts-engineer-hack/config-sha256"
JOB_ANNOTATION = "mts-engineer-hack/job-sha256"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def documents():
    result = []
    for doc in yaml.safe_load_all(sys.stdin):
        if doc:
            if not isinstance(doc, dict):
                raise ValueError("manifest document must be an object")
            if doc.get("kind") == "List" and not isinstance(doc.get("items"), list):
                raise ValueError("manifest List must contain an items array")
            result.extend(doc["items"] if doc.get("kind") == "List" else [doc])
    if not result or not all(isinstance(x, dict) for x in result):
        raise ValueError("manifest must contain resource objects")
    identities = [(x["apiVersion"], x["kind"], x.get("metadata", {}).get("namespace", ""),
                   x["metadata"]["name"]) for x in result]
    if len(identities) != len(set(identities)):
        raise ValueError("duplicate rendered resource identity")
    return result


def config_refs(pod):
    names = {v["configMap"]["name"] for v in pod.get("volumes", []) if "configMap" in v}
    for volume in pod.get("volumes", []):
        for source in volume.get("projected", {}).get("sources", []):
            if "configMap" in source:
                names.add(source["configMap"]["name"])
    for container in pod.get("containers", []) + pod.get("initContainers", []):
        for env in container.get("env", []):
            ref = env.get("valueFrom", {}).get("configMapKeyRef")
            if ref:
                names.add(ref["name"])
        for env in container.get("envFrom", []):
            if "configMapRef" in env:
                names.add(env["configMapRef"]["name"])
    return sorted(names)


def check_images(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "image" and isinstance(item, str):
                if item not in {v for k, v in PINS.items() if k.endswith("_IMAGE")}:
                    raise ValueError(f"image is not in config/versions.env: {item}")
            else:
                check_images(item)
    elif isinstance(value, list):
        for item in value:
            check_images(item)


def render(items, extra_configs=()):
    configs = {(x["metadata"].get("namespace", "default"), x["metadata"]["name"]): x
               for x in [*extra_configs, *items] if x["kind"] == "ConfigMap"}
    for obj in items:
        kind = obj["kind"]
        if kind == "Secret":
            raise ValueError("Secret values must be generated in-cluster, never rendered from this repository")
        if kind != "CustomResourceDefinition":
            check_images(obj)
        if kind == "ConfigMap" and obj["metadata"]["name"] == "envoy-gateway-config":
            settings = yaml.safe_load(obj["data"]["envoy-gateway.yaml"])
            manager = settings["provider"]["kubernetes"]["shutdownManager"]
            if manager.get("image") != PINS["ENVOY_GATEWAY_IMAGE"]:
                raise ValueError("shutdown-manager image must equal ENVOY_GATEWAY_IMAGE")
        if kind == "Deployment":
            template = obj["spec"]["template"]
            namespace = obj["metadata"].get("namespace", "default")
            referenced = []
            for name in config_refs(template["spec"]):
                config = configs.get((namespace, name))
                if config is None:
                    raise ValueError(f"Deployment {namespace}/{obj['metadata']['name']} references missing ConfigMap {name}")
                referenced.append({"name": name, "data": config.get("data", {}),
                                   "binaryData": config.get("binaryData", {})})
            if referenced:
                template.setdefault("metadata", {}).setdefault("annotations", {})[ANNOTATION] = digest(referenced)
        elif kind == "Job":
            obj["metadata"].setdefault("annotations", {})[JOB_ANNOTATION] = digest(obj["spec"])
    return items


def cleanup(items):
    # Explicit allowlist prevents root namespace manifests or upstream resources
    # from being removed, even if composition later grows.
    allowed = {
        ("GatewayClass", "", "mts-envoy"),
        ("Gateway", "mts-app", "mts-gateway"),
        ("EnvoyProxy", "mts-app", "mts-proxy"),
        ("HTTPRoute", "mts-app", "nginx-demo"),
        ("Deployment", "mts-app", "nginx-demo"),
        ("Service", "mts-app", "nginx-demo"),
        ("ServiceAccount", "mts-app", "nginx-demo"),
        ("ConfigMap", "mts-app", "nginx-demo-config"),
        ("ConfigMap", "mts-app", "fluentd-config"),
        *((kind, "mts-observability", name) for kind in ("Deployment", "Service") for name in ("prometheus", "loki")),
        *(("ConfigMap", "mts-observability", name) for name in ("prometheus-config", "loki-config")),
    }
    result = []
    for obj in items:
        identity = (obj["kind"], obj["metadata"].get("namespace", ""), obj["metadata"]["name"])
        if obj["kind"] == "Namespace":
            continue
        if identity not in allowed:
            raise ValueError(f"cleanup refuses resource outside project allowlist: {identity}")
        if obj["metadata"].get("labels", {}).get("app.kubernetes.io/part-of") != "mts-engineer-hack":
            raise ValueError(f"cleanup refuses resource without project label: {identity}")
        result.append({"apiVersion": obj["apiVersion"], "kind": obj["kind"], "metadata": obj["metadata"]})
    return result


def main():
    if sys.argv[1:] == ["--help"]:
        print("Usage: manifests.py render [config-context.json]|cleanup|names KIND < manifest.yaml")
        return 0
    args = sys.argv[1:]
    if args not in (["render"], ["cleanup"]) and not (len(args) == 2 and args[0] in ("names", "render")):
        print("Usage: manifests.py render [config-context.json]|cleanup|names KIND < manifest.yaml", file=sys.stderr)
        return 64
    try:
        items = documents()
        if args[0] == "names":
            print("\n".join(x["metadata"]["name"] for x in items if x["kind"] == args[1]))
        else:
            extra = json.loads(Path(args[1]).read_text())["items"] if len(args) == 2 else []
            items = render(items, extra) if args[0] == "render" else cleanup(items)
            print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=2, sort_keys=True))
        return 0
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError) as exc:
        print(f"Invalid local manifest: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
