#!/usr/bin/env python3
"""Read the config digest from a Docker save archive without extracting it."""
import hashlib
import json
import sys
import tarfile


def config_digest(archive, image, recipe):
    with tarfile.open(archive) as saved:
        manifests = json.load(saved.extractfile("manifest.json"))
        if len(manifests) != 1:
            raise ValueError("expected exactly one exported image")
        manifest = manifests[0]
        tags = [tag.removeprefix("docker.io/") for tag in manifest.get("RepoTags", [])]
        if image.removeprefix("docker.io/") not in tags:
            raise ValueError("exported image tag does not match")
        config_bytes = saved.extractfile(manifest["Config"]).read()
        config = json.loads(config_bytes)
        if config.get("os") != "linux" or config.get("architecture") != "amd64":
            raise ValueError("exported image must be linux/amd64")
        labels = config.get("config", {}).get("Labels", {})
        if labels.get("mts-engineer-hack.fluentd-recipe-sha256") != recipe:
            raise ValueError("exported image recipe label does not match")
        return "sha256:" + hashlib.sha256(config_bytes).hexdigest()


def main(argv):
    if argv == ["--help"]:
        print("Usage: image_identity.py ARCHIVE IMAGE RECIPE_SHA256")
        return 0
    if len(argv) != 3:
        print("Usage: image_identity.py ARCHIVE IMAGE RECIPE_SHA256", file=sys.stderr)
        return 64
    try:
        print(config_digest(*argv))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, tarfile.TarError) as error:
        print(f"Invalid exported image: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
