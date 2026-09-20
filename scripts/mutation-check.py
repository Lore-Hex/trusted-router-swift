#!/usr/bin/env python3
"""Run recorded, one-at-a-time mutations. Restoration never uses git."""
import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "scripts/mutations.json"


def restore(saved):
    index = saved / "index.json"
    if index.exists():
        for relative, snapshot in json.loads(index.read_text()).items():
            (ROOT / relative).write_bytes((saved / snapshot).read_bytes())


def run_test(test):
    result = subprocess.run(
        ["swift", "test", "--filter", test], cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
    )
    return result.returncode, result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--saved", type=Path)
    parser.add_argument("--restore", type=Path)
    parser.add_argument("--validate-patterns", action="store_true")
    args = parser.parse_args()
    if args.restore:
        restore(args.restore)
        return
    started = time.monotonic()
    mutations = json.loads(MANIFEST.read_text())
    originals = {item["file"]: (ROOT / item["file"]).read_bytes() for item in mutations}
    # Validate EVERY pattern before changing anything; count != 1 is always fatal.
    for item in mutations:
        count = originals[item["file"]].count(item["before"].encode())
        if count != 1:
            raise SystemExit(f"STALE {item['name']}: expected one match, got {count}")
    if args.validate_patterns:
        print(f"Validated {len(mutations)} mutation patterns; XCTest NOT executed")
        print(f"Pattern validation wall time: {time.monotonic() - started:.2f}s")
        return
    index = {}
    for number, (relative, original) in enumerate(originals.items()):
        snapshot = f"{number}.original"
        (args.saved / snapshot).write_bytes(original)
        index[relative] = snapshot
    (args.saved / "index.json").write_text(json.dumps(index))

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    checked = set()
    try:
        for item in mutations:
            test = item["test"]
            method = test.split("/")[-1]
            if test not in checked:
                status, output = run_test(test)
                if status or method not in output or not re.search(r"Executed [1-9]\d* tests?", output):
                    raise SystemExit(f"BASELINE FAILED or test not discovered: {test}\n{output}")
                checked.add(test)
            path = ROOT / item["file"]
            original = originals[item["file"]]
            mutation_started = time.monotonic()
            try:
                path.write_bytes(original.replace(item["before"].encode(), item["after"].encode(), 1))
                status, output = run_test(test)
            finally:
                path.write_bytes(original)
            if status == 0:
                raise SystemExit(f"SURVIVED {item['name']} ({test})\n{output}")
            if "Build complete!" not in output or method not in output or not (
                "failed" in output or "unexpected signal" in output
            ):
                raise SystemExit(f"INVALID mutation (build/infrastructure failure): {item['name']}\n{output}")
            print(f"KILLED {item['name']} ({time.monotonic() - mutation_started:.2f}s)", flush=True)
    finally:
        for relative, original in originals.items():
            (ROOT / relative).write_bytes(original)
        print(f"Mutation wall time: {time.monotonic() - started:.2f}s", flush=True)


if __name__ == "__main__":
    main()
