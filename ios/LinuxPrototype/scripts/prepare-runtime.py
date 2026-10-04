#!/usr/bin/env python3
"""Throwaway staging tool for the pinned official ios-tci-arm64 sysroot.

Usage: python3 scripts/prepare-runtime.py /path/to/sysroot-iOS-TCI-arm64
Does not download, redistribute, or certify component license compliance.
"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

sysroot = Path(sys.argv[1]).resolve()
frameworks = sysroot / "Frameworks"
destination = Path(__file__).resolve().parents[1] / ".runtime"
pending = ["qemu-aarch64-softmmu"]
selected = set()
while pending:
    name = pending.pop()
    if name in selected:
        continue
    binary = frameworks / f"{name}.framework" / name
    if not binary.is_file():
        raise SystemExit(f"Missing dependency: {binary}")
    selected.add(name)
    for line in subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith(("/usr/lib/", "/System/")):
            continue
        match = re.fullmatch(r"@rpath/([^/]+)\.framework/\1", dependency)
        if not match:
            raise SystemExit(f"Unresolved import (requires upstream fixup): {dependency}")
        pending.append(match.group(1))

qemu = frameworks / "qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
exports = subprocess.check_output(["nm", "-gU", str(qemu)], text=True)
for symbol in ("_qemu_init", "_qemu_main_loop", "_qemu_cleanup"):
    if not re.search(rf"\b{symbol}$", exports, re.M):
        raise SystemExit(f"Missing entry point: {symbol}")
platform = subprocess.check_output(["xcrun", "vtool", "-show-build", str(qemu)], text=True)
if not re.search(r"platform\s+IOS\b", platform):
    raise SystemExit("QEMU is not a device iOS binary")

destination.mkdir(exist_ok=True)
output = destination / "Frameworks"
if output.exists():
    shutil.rmtree(output)  # Generated scratch staging, never the source sysroot.
output.mkdir()
records = []
for name in sorted(selected):
    source = frameworks / f"{name}.framework"
    shutil.copytree(source, output / source.name, symlinks=True)
    binary = source / name
    records.append({"framework": source.name, "binaryBytes": binary.stat().st_size,
                    "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()})
firmware = sysroot / "share/qemu"
if firmware.exists():
    target = destination / "qemu"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(firmware, target, symlinks=True)
(destination / "frameworks.json").write_text(json.dumps({
    "utmSource": "7eadb056ae0f91d979059544d0ddcd2d5a40be92",
    "qemuSource": "v10.0.12-utm",
    "expectedArtifactId": 10845528675,
    "warning": "Caller must verify artifact provenance. Static dependency closure does not cover optional dlopen libraries or establish license compliance.",
    "platformInspection": platform,
    "frameworks": records,
}, indent=2) + "\n")
print(f"Staged {len(selected)} framework(s); source/digest inventory stays in ignored .runtime/frameworks.json")
