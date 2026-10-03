#!/usr/bin/env python3
"""Validate the fixed resource contract; image contents are built by the runtime task."""
import json
import re
import sys
from pathlib import Path


def validate(directory):
    manifest = json.loads((directory / "runtime.json").read_text())
    if type(manifest) is not dict:
        raise ValueError("Invalid manifest")
    if type(manifest.get("formatVersion")) is not int or manifest.get("formatVersion") != 1:
        raise ValueError("Unsupported runtime formatVersion")
    memory = manifest.get("memoryMiB")
    if type(memory) is not int or not 128 <= memory <= 2048:
        raise ValueError("Invalid memoryMiB")
    for key in ("kernel", "initramfs", "systemDisk", "userDiskSeed"):
        name = manifest.get(key)
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name in (".", ".."):
            raise ValueError(f"Invalid resource name for {key}")
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Missing or invalid resource for {key}")
    return manifest


if __name__ == "__main__":
    try:
        manifest = validate(Path(sys.argv[1]))
    except (OSError, ValueError, IndexError):
        sys.exit("Invalid or incomplete runtime resources")
    if "--list" in sys.argv[2:]:
        print("runtime.json")
        for key in ("kernel", "initramfs", "systemDisk", "userDiskSeed"):
            print(manifest[key])
    else:
        print("Runtime resource contract validated")
