#!/usr/bin/env python3
"""Prove each boundary lint rule rejects its defect; never execute probe code."""
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
PROBE = ROOT / "Sources/TrustedRouter/BoundaryLintProbe.swift"
PROBES = {
    "force_unwrapping": 'let boundaryValue = Optional("external")!',
    "force_cast": 'let boundaryValue = (7 as Any) as! String',
    "force_try": 'let boundaryValue = try! JSONDecoder().decode(String.self, from: Data())',
    "implicitly_unwrapped_optional": 'var boundaryValue: String!',
    "raw_response_header_lookup": 'func boundaryProbe(_ response: HTTPURLResponse) -> Any? { response.allHeaderFields["X-ID"] }',
    "cast_string_default": 'func boundaryProbe(_ value: Any) -> String { value as? String ?? "" }',
    "swallowed_json_decoding": 'let boundaryValue = try? JSONDecoder().decode(String.self, from: Data())',
    "empty_object_fallback": 'func boundaryProbe(_ value: Any) -> [String: Any] { (value as? [String: Any]) ?? [:] }',
}


def lint():
    return subprocess.run(
        [os.environ.get("SWIFTLINT", "swiftlint"), "lint", "--strict", "--no-cache", "--quiet", "--reporter", "json"],
        cwd=ROOT, capture_output=True, text=True, check=False,
    )


def main():
    started = time.monotonic()
    if PROBE.exists():
        raise SystemExit(f"refusing to overwrite {PROBE}")
    baseline = lint()
    if baseline.returncode:
        raise SystemExit("static baseline failed:\n" + baseline.stdout + baseline.stderr)
    try:
        for rule, source in PROBES.items():
            PROBE.write_text("import Foundation\n\n" + source + "\n")
            result = lint()
            findings = json.loads(result.stdout)
            if result.returncode == 0 or not any(item["rule_id"] == rule for item in findings):
                raise SystemExit(f"SURVIVED: {rule}\n{result.stdout}\n{result.stderr}")
            print(f"KILLED {rule}", flush=True)
    finally:
        PROBE.unlink(missing_ok=True)
        print(f"Static mutation wall time: {time.monotonic() - started:.2f}s", flush=True)


if __name__ == "__main__":
    main()
