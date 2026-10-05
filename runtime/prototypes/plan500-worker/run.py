#!/usr/bin/env python3
"""Throwaway macOS probe; all generated files stay in ignored build/."""
import argparse
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[2]
OUTPUT = REPO / "build/prototypes/plan500-worker"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, env=None, timeout=180):
    with (OUTPUT / log).open("w") as stream:
        result = subprocess.run(command, cwd=REPO, env=env, stdout=stream,
                                stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}); see build log {log}")


def dependencies(kind, directory, install):
    inputs = SOURCE / kind
    if install:
        directory.mkdir(parents=True, exist_ok=True)
        for name in ("package.json", "package-lock.json"):
            shutil.copyfile(inputs / name, directory / name)
        run(["npm", "ci", "--prefix", str(directory), "--ignore-scripts",
             "--no-audit", "--no-fund"], kind + "-install-private.log", timeout=600)
    if not (directory / "node_modules/.package-lock.json").is_file():
        raise RuntimeError("Dependencies missing; rerun with --install (isolated build directories only)")
    if digest(directory / "package-lock.json") != digest(inputs / "package-lock.json"):
        raise RuntimeError(f"Lock mismatch for {kind}; use --install instead of unverified packages")


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="npm ci fixed dependencies into build only")
    parser.add_argument("--unadapted", action="store_true", help="negative control without Zod/schema adaptations")
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in ("checkpoint.json", "webkit-safe.json", "run-safe.json", "gate-safe.json", "pack-safe.json"):
        (OUTPUT / name).unlink(missing_ok=True)
    # Reuse the known test tree read-only, or install a separate prototype tree.
    isolated = OUTPUT / "harness-dependencies"
    harness = isolated if args.install or (isolated / "node_modules/.package-lock.json").is_file() else REPO / "build/test-dependencies/harness"
    dependencies("harness-dependencies", harness, args.install)
    dependencies("dependencies", OUTPUT / "dependencies", args.install)
    env = os.environ.copy()
    env["PLAN500_HARNESS_ROOT"] = str(harness)
    env["DSH_HOME"] = str(OUTPUT / "scratch-dsh-home")
    # No HOME override or user profile/token access.
    with (OUTPUT / "composed-web.yml").open("w") as config, (OUTPUT / "config-private.log").open("w") as errors:
        subprocess.run(["node", str(harness / "node_modules/@deepseek-ai/dsh/lib/bin.js"),
                        "--profile", "web", "--dump-config"], cwd=REPO, env=env,
                       stdout=config, stderr=errors, timeout=60, check=True)
    pack = ["node", str(SOURCE / "pack.mjs")]
    if not args.unadapted:
        pack += ["--zod-cjs", "--webkit-schemas"]
    run(pack, "pack-private.log", env=env)
    run(["node", str(SOURCE / "prepare-web.mjs")], "prepare-private.log")
    run(["node", str(SOURCE / "gate-probe.mjs")], "gate-private.log")
    run(["xcrun", "swiftc", "-module-cache-path", str(OUTPUT / "swift-module-cache"),
         str(SOURCE / "webkit-probe.swift"), "-o", str(OUTPUT / "webkit-probe")], "swift-private.log")
    handler = functools.partial(QuietHandler, directory=str(OUTPUT / "web"))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with (OUTPUT / "webkit-private.log").open("w") as log:
            result = subprocess.run([str(OUTPUT / "webkit-probe"),
                                     f"http://127.0.0.1:{server.server_port}/index.html", str(OUTPUT)],
                                    cwd=REPO, stdout=log, stderr=subprocess.STDOUT, timeout=210)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    if not (OUTPUT / "webkit-safe.json").exists():
        raise RuntimeError("WebKit exited without a receipt; do not reuse a previous success")
    worker = json.loads((OUTPUT / "webkit-safe.json").read_text())
    gate = json.loads((OUTPUT / "gate-safe.json").read_text())
    receipt = {"passed": result.returncode == 0 and worker["passed"] and gate["passed"],
               "unadapted": args.unadapted, "worker": worker, "gate": gate,
               "image": json.loads((OUTPUT / "pack-safe.json").read_text()),
               "sourceSha256": {p.name: digest(p) for p in SOURCE.iterdir() if p.is_file()},
               "lockSha256": {kind: digest(SOURCE / kind / "package-lock.json")
                              for kind in ("harness-dependencies", "dependencies")}}
    (OUTPUT / "run-safe.json").write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"passed": receipt["passed"], "unadapted": args.unadapted,
                      "workerChecks": len(worker["checks"]), "gateChecks": len(gate["checks"]),
                      "receipt": "build/prototypes/plan500-worker/run-safe.json"}))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
