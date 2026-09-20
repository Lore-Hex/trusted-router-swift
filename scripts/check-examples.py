#!/usr/bin/env python3
"""Extract every Swift fence verbatim and compile it against the built library."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def check(modules, scratch):
    count = 0
    for path in [ROOT / 'README.md', *sorted((ROOT / 'docs').rglob('*.md'))]:
        for match in re.finditer(r'^```([^\n]*)\n(.*?)^```\s*$', path.read_text(), re.M | re.S):
            language, code = match.groups()
            if language.strip() != 'swift':
                continue
            count += 1
            line = path.read_text()[:match.start()].count('\n') + 1
            print(f'Compile {path.relative_to(ROOT)}:{line}', flush=True)
            destination = scratch / f'example-{count}'
            destination.mkdir(exist_ok=True)
            source = destination / ('Package.swift' if code.startswith('// swift-tools-version:') else 'main.swift')
            source.write_text(code)
            if source.name == 'Package.swift':
                command = ['swift', 'package', '--disable-sandbox', '--package-path', str(destination), 'dump-package']
            else:
                command = ['swiftc', '-typecheck', '-I', str(modules), '-module-cache-path',
                           os.environ.get('CLANG_MODULE_CACHE_PATH', str(scratch / 'module-cache')), str(source)]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    if not count:
        raise SystemExit('No Swift examples found')
    print(f'Compiled {count} verbatim Swift examples')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tr-examples-') as tmp:
        check(args.modules.resolve(), Path(tmp))
