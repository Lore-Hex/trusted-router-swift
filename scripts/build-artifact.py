#!/usr/bin/env python3
"""Build the SwiftPM release source ZIP from the working tree, never git HEAD."""
import argparse
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def build(output):
    # Copy the entire source set: the independent listing test rejects stray files.
    files = [ROOT / name for name in ('Package.swift', 'LICENSE', 'README.md', 'package-metadata.json')]
    files += sorted(path for path in (ROOT / 'Sources').rglob('*') if path.is_file())
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, 'TrustedRouter/' + path.relative_to(ROOT).as_posix())
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    print(build(parser.parse_args().output))
