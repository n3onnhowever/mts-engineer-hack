#!/usr/bin/env python3
"""Check current Kubernetes readiness from kubectl JSON without making API calls."""

import ipaddress
import json
import re
import sys


CONTROLLER = "gateway.envoyproxy.io/gatewayclass-controller"
USAGE = (
    "usage: readiness.py gatewayclass|gateway|httproute|proxy-services\n"
    "       readiness.py nodes <exact-kubernetes-version>\n"
    "Read a Kubernetes object (or List for nodes/services) as JSON on stdin."
)


class NotReady(Exception):
    """The input is invalid or does not yet satisfy the platform requirements."""


def require(condition, message):
    if not condition:
        raise NotReady(message)


def mapping(value, label):
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def sequence(value, label):
    require(isinstance(value, list), f"{label} must be an array")
    return value


def named(resource, kind, name, namespace=None):
    require(resource.get("kind") == kind, f"expected {kind}")
    metadata = mapping(resource.get("metadata"), "metadata")
    require(metadata.get("name") == name, f"expected {kind}/{name}")
    if namespace is not None:
        require(metadata.get("namespace") == namespace, f"expected namespace {namespace}")
    require(not metadata.get("deletionTimestamp"), f"{kind}/{name} is terminating")
    return metadata


def generation(metadata):
    value = metadata.get("generation")
    require(type(value) is int and value > 0, "metadata.generation must be a positive integer")
    return value


def conditions_ready(conditions, required, observed_generation=None):
    entries = sequence(conditions, "conditions")
    for entry in entries:
        mapping(entry, "condition")
    for name in required:
        matches = [entry for entry in entries if entry.get("type") == name]
        require(len(matches) == 1, f"expected exactly one {name} condition")
        condition = matches[0]
        require(condition.get("status") == "True", f"{name} is not True")
        if observed_generation is not None:
            value = condition.get("observedGeneration")
            require(
                type(value) is int and value == observed_generation,
                f"{name} does not observe generation {observed_generation}",
            )


def gatewayclass(resource):
    metadata = named(resource, "GatewayClass", "mts-envoy")
    spec = mapping(resource.get("spec"), "spec")
    require(spec.get("controllerName") == CONTROLLER, "GatewayClass controller does not match")
    status = mapping(resource.get("status"), "status")
    conditions_ready(status.get("conditions"), ("Accepted",), generation(metadata))


def gateway(resource):
    metadata = named(resource, "Gateway", "mts-gateway", "mts-app")
    current = generation(metadata)
    status = mapping(resource.get("status"), "status")
    conditions_ready(status.get("conditions"), ("Accepted", "Programmed"), current)
    listeners = sequence(status.get("listeners"), "status.listeners")
    matches = []
    for entry in listeners:
        listener = mapping(entry, "listener")
        if listener.get("name") == "http":
            matches.append(listener)
    require(len(matches) == 1, "expected exactly one http listener status")
    listener = matches[0]
    conditions_ready(listener.get("conditions"), ("Accepted", "Programmed", "ResolvedRefs"), current)
    attached = listener.get("attachedRoutes")
    require(type(attached) is int and attached >= 1, "http listener has no attached route")


def httproute(resource):
    metadata = named(resource, "HTTPRoute", "nginx-demo", "mts-app")
    status = mapping(resource.get("status"), "status")
    parents = sequence(status.get("parents"), "status.parents")
    matches = []
    for entry in parents:
        parent = mapping(entry, "parent status")
        ref = mapping(parent.get("parentRef"), "parentRef")
        if (
            parent.get("controllerName") == CONTROLLER
            and ref.get("name") == "mts-gateway"
            and ref.get("namespace", "mts-app") == "mts-app"
            and ref.get("group", "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
            and ref.get("kind", "Gateway") == "Gateway"
            and ref.get("sectionName") == "http"
        ):
            matches.append(parent)
    require(len(matches) == 1, "expected exactly one mts-gateway/http parent for the Envoy controller")
    conditions_ready(matches[0].get("conditions"), ("Accepted", "ResolvedRefs"), generation(metadata))


def single_item(resource, label):
    items = sequence(resource.get("items"), "items")
    require(len(items) == 1, f"expected exactly one {label}; found {len(items)}")
    return mapping(items[0], label)


def nodes(resource, version):
    node = single_item(resource, "node")
    metadata = named(node, "Node", "mts-engineer-control-plane")
    labels = mapping(metadata.get("labels"), "node labels")
    require("node-role.kubernetes.io/control-plane" in labels, "node is not a control-plane node")
    status = mapping(node.get("status"), "node status")
    info = mapping(status.get("nodeInfo"), "nodeInfo")
    require(info.get("kubeletVersion") == version, f"node kubelet version must be {version}")
    require(info.get("operatingSystem") == "linux", "node operating system must be linux")
    require(info.get("architecture") == "amd64", "node architecture must be amd64")
    conditions_ready(status.get("conditions"), ("Ready",))


def proxy_services(resource):
    service = single_item(resource, "proxy Service")
    metadata = mapping(service.get("metadata"), "Service metadata")
    name = metadata.get("name")
    require(
        isinstance(name, str)
        and len(name) <= 63
        and re.fullmatch(r"[a-z0-9](?:[-a-z0-9]*[a-z0-9])?", name),
        "invalid proxy Service name",
    )
    named(service, "Service", name, "envoy-gateway-system")
    labels = mapping(metadata.get("labels"), "Service labels")
    require(
        labels.get("gateway.envoyproxy.io/owning-gateway-namespace") == "mts-app",
        "proxy Service owning namespace does not match",
    )
    require(
        labels.get("gateway.envoyproxy.io/owning-gateway-name") == "mts-gateway",
        "proxy Service owning Gateway does not match",
    )
    spec = mapping(service.get("spec"), "Service spec")
    require(spec.get("type") == "ClusterIP", "proxy Service type must be ClusterIP")
    cluster_ip = spec.get("clusterIP")
    require(isinstance(cluster_ip, str), "proxy Service has no allocated cluster IP")
    try:
        ipaddress.ip_address(cluster_ip)
    except ValueError:
        raise NotReady("proxy Service has no allocated cluster IP") from None
    ports = sequence(spec.get("ports"), "Service ports")
    matches = []
    for entry in ports:
        port = mapping(entry, "Service port")
        if port.get("port") == 80:
            matches.append(port)
    require(
        len(matches) == 1 and matches[0].get("protocol", "TCP") == "TCP",
        "proxy Service must expose TCP port 80 exactly once",
    )
    print(name)


def main(argv):
    checkers = {
        "gatewayclass": gatewayclass,
        "gateway": gateway,
        "httproute": httproute,
        "proxy-services": proxy_services,
    }
    if argv == ["--help"]:
        print(USAGE)
        return 0
    if len(argv) == 2 and argv[0] == "nodes" and re.fullmatch(r"v\d+\.\d+\.\d+", argv[1]):
        checker = lambda resource: nodes(resource, argv[1])
    elif len(argv) == 1 and argv[0] in checkers:
        checker = checkers[argv[0]]
    else:
        print(USAGE, file=sys.stderr)
        return 64
    try:
        resource = mapping(json.load(sys.stdin), "input")
        checker(resource)
    except (json.JSONDecodeError, UnicodeDecodeError):
        print("readiness: input is not valid JSON", file=sys.stderr)
        return 1
    except NotReady as error:
        print(f"readiness: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
