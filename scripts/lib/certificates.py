#!/usr/bin/env python3
"""Validate the certgen Secret set without exposing certificate or key material."""

import base64
import binascii
import datetime
import json
import os
import shutil
import subprocess
import sys
import threading


NAMESPACE = "envoy-gateway-system"
TLS_NAMES = ("envoy-gateway", "envoy", "envoy-rate-limit")
HMAC_NAME = "envoy-oidc-hmac"
USAGE = (
    "usage: certificates.py [--help]\n"
    "Read the four Envoy Gateway certgen Secrets as Kubernetes List JSON on stdin.\n"
    "Print fresh for no Secrets or ready for a complete, valid set. Requires openssl."
)


class InvalidState(Exception):
    """Existing certificate state cannot safely be reused."""


def require(condition, message):
    if not condition:
        raise InvalidState(message)


def openssl_run(executable, arguments, data, capture=False, pass_fds=()):
    try:
        result = subprocess.run(
            [executable, *arguments],
            input=data,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            pass_fds=pass_fds,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise InvalidState("openssl check failed or exceeded its 10-second timeout") from None
    require(result.returncode == 0, "openssl rejected certificate or key material")
    return result.stdout if capture else None


def verify_chain(executable, certificate, ca):
    # A writer thread permits CA bundles larger than a pipe buffer without
    # blocking before OpenSSL starts. Only the read descriptor reaches the child.
    try:
        read_fd, write_fd = os.pipe()
    except OSError:
        raise InvalidState("cannot open the in-memory CA pipe") from None
    write_errors = []

    def write_ca():
        try:
            with os.fdopen(write_fd, "wb") as pipe:
                pipe.write(ca)
        except OSError:
            write_errors.append(True)

    writer = threading.Thread(target=write_ca, daemon=True)
    writer.start()
    try:
        openssl_run(
            executable,
            [
                "verify", "-CAfile", f"/proc/self/fd/{read_fd}",
                "-no-CApath", "-no-CAstore", "-check_ss_sig",
            ],
            certificate,
            pass_fds=(read_fd,),
        )
    finally:
        os.close(read_fd)
        writer.join(timeout=1)
    require(not writer.is_alive() and not write_errors, "in-memory CA pipe failed")


def certificate_valid(executable, certificate):
    openssl_run(executable, ["x509", "-checkend", "86400", "-noout"], certificate)
    # -checkend tests expiry only, so reject certificates not yet valid as well.
    start = openssl_run(executable, ["x509", "-startdate", "-noout"], certificate, capture=True)
    try:
        require(start.startswith(b"notBefore="), "openssl returned an invalid certificate start date")
        date = start.removeprefix(b"notBefore=").decode("ascii").strip()
        begins = datetime.datetime.strptime(date, "%b %d %H:%M:%S %Y GMT")
        begins = begins.replace(tzinfo=datetime.timezone.utc)
    except (UnicodeDecodeError, ValueError):
        raise InvalidState("openssl returned an invalid certificate start date") from None
    require(begins <= datetime.datetime.now(datetime.timezone.utc), "certificate is not yet valid")


def decoded_data(secret, keys):
    data = secret.get("data")
    require(isinstance(data, dict), "Secret data must be an object")
    values = {}
    for key in keys:
        encoded = data.get(key)
        require(isinstance(encoded, str) and encoded, "Secret is missing required nonempty data")
        try:
            value = base64.b64decode(encoded, validate=True)
        except (binascii.Error, ValueError):
            raise InvalidState("Secret data is not valid base64") from None
        require(value, "Secret contains empty decoded data")
        values[key] = value
    return values


def check_state(resource, executable):
    require(isinstance(resource, dict), "input must be a Kubernetes List object")
    require(resource.get("kind") in ("List", "SecretList"), "input must be a Kubernetes List")
    items = resource.get("items")
    require(isinstance(items, list), "List items must be an array")
    if not items:
        return "fresh"
    require(len(items) == 4, "partial certgen Secret set; expected all four Secrets or none")
    secrets = {}
    expected_names = set(TLS_NAMES) | {HMAC_NAME}
    for item in items:
        require(isinstance(item, dict) and item.get("kind") == "Secret", "List contains a non-Secret item")
        metadata = item.get("metadata")
        require(isinstance(metadata, dict), "Secret metadata must be an object")
        name = metadata.get("name")
        require(isinstance(name, str) and name in expected_names, "unexpected certgen Secret name")
        require(name not in secrets, "duplicate certgen Secret")
        require(metadata.get("namespace") == NAMESPACE, "certgen Secret namespace does not match")
        require(not metadata.get("deletionTimestamp"), "certgen Secret is terminating")
        secrets[name] = item
    require(set(secrets) == expected_names, "partial certgen Secret set")
    require(secrets[HMAC_NAME].get("type") == "Opaque", "OIDC HMAC Secret must have type Opaque")
    decoded_data(secrets[HMAC_NAME], ("hmac-secret",))
    expected_ca = None
    for name in TLS_NAMES:
        secret = secrets[name]
        require(secret.get("type") == "kubernetes.io/tls", "TLS Secret has the wrong type")
        data = decoded_data(secret, ("ca.crt", "tls.crt", "tls.key"))
        if expected_ca is None:
            expected_ca = data["ca.crt"]
            certificate_valid(executable, expected_ca)
        else:
            require(data["ca.crt"] == expected_ca, "TLS Secrets contain different CA certificates")
        certificate_valid(executable, data["tls.crt"])
        verify_chain(executable, data["tls.crt"], expected_ca)
        certificate_key = openssl_run(
            executable, ["x509", "-pubkey", "-noout"], data["tls.crt"], capture=True
        )
        private_key = openssl_run(
            executable, ["pkey", "-pubout", "-passin", "pass:"], data["tls.key"], capture=True
        )
        require(certificate_key == private_key, "TLS certificate and private key do not match")
    return "ready"


def main(argv):
    if argv == ["--help"]:
        print(USAGE)
        return 0
    if argv:
        print(USAGE, file=sys.stderr)
        return 64
    executable = shutil.which("openssl")
    if executable is None:
        print("certificates: openssl is required", file=sys.stderr)
        return 1
    try:
        state = check_state(json.load(sys.stdin), executable)
    except (json.JSONDecodeError, UnicodeDecodeError):
        print("certificates: input is not valid JSON", file=sys.stderr)
        return 1
    except InvalidState as error:
        print(f"certificates: {error}", file=sys.stderr)
        return 1
    print(state)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
