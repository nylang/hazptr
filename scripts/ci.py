#!/usr/bin/env python3
# Copyright (c) 2026 tangxiangjiang
# SPDX-License-Identifier: MIT
"""Check an independent source package against explicitly selected SDK inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--mode", choices=("all", "tests", "consumer"), default="all")
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    compiler = args.compiler.resolve(strict=True)
    sdk = args.sdk_root.resolve(strict=True)
    out = args.out_dir.resolve()
    if out == package or package in out.parents or args.jobs < 1:
        parser.error("use positive jobs and a new output directory outside the package")
    out.mkdir(parents=True, exist_ok=False)
    inputs = out / "inputs"
    inputs.mkdir()
    (inputs / "tmp").mkdir()
    workspace = inputs / "workspace.yaml"
    workspace.write_text(f"version: 1\npackages:\n  hazptr: {package / 'package.yaml'}\n")
    env = dict(os.environ, NYRA_SDK_ROOT=str(sdk), TMPDIR=str(inputs / "tmp"))
    base = [str(compiler), "--workspace", str(workspace)]
    report = {
        "mode": args.mode,
        "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(),
        "steps": [],
        "status": "failed",
    }
    products: list[Path] = []

    def run(name: str, argv: list[str], rejection: bool = False) -> None:
        completed = subprocess.run(argv, cwd=package, env=env, capture_output=True,
                                   text=True, timeout=300)
        log = completed.stdout + completed.stderr
        (out / f"{name}.log").write_text(log[-16384:])
        ok = (completed.returncode != 0 and "NY5006" in log and "copy" in log.lower()
              if rejection else completed.returncode == 0)
        report["steps"].append({"name": name, "argv": argv, "exit": completed.returncode,
                                "passed": ok, "expected_copy_rejection": rejection})
        if not ok:
            raise RuntimeError(f"{name} failed: {log[-2048:]}")

    try:
        if args.mode in ("all", "tests"):
            for level in (0, 2):
                objects = out / f"units-o{level}"
                products.append(objects)
                run(f"units-o{level}", base + ["test", str(package), f"-O{level}",
                    "--jobs", str(args.jobs), "--out-dir", str(objects),
                    "--report", str(out / f"units-o{level}.json")])

        if args.mode in ("all", "consumer"):
            consumer = inputs / "consumer"
            consumer.mkdir()
            (consumer / "package.yaml").write_text(
                "name: hazptr_consumer\nversion: 0.0.0\n"
                "dependencies:\n  hazptr:\n    workspace: true\n")
            entry = consumer / "main.ny"
            entry.write_text((package / "tests/data/consumer.ny.in").read_text())
            for level in (0, 2):
                objects = out / f"consumer-o{level}"
                products.append(objects)
                binary = objects / "program"
                run(f"consumer-build-o{level}", base + ["build", str(entry), f"-O{level}",
                    "--link", "--jobs", str(args.jobs), "--out-dir", str(objects), "-o", str(binary)])
                run(f"consumer-run-o{level}", [str(binary)])

            # Compile through the public face: linear protection/retirement objects
            # must not become copyable merely because the definitions are imported.
            for name in ("holder", "source", "retirement"):
                entry.write_text((package / f"tests/data/reject_copy_{name}.ny.in").read_text())
                run(f"reject-copy-{name}", base + ["check", str(entry)], rejection=True)

        report["status"] = "passed"
        return 0
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        for path in products + [inputs]:
            if path.exists():
                shutil.rmtree(path)


if __name__ == "__main__":
    raise SystemExit(main())
