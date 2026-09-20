#!/usr/bin/env python3
"""Count undocumented compiler-visible public symbols, including enum cases."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def check(modules, scratch):
    target = json.loads(subprocess.check_output(['swift', '-print-target-info']))['target']['triple']
    command = ['swift', 'symbolgraph-extract', '-module-name', 'TrustedRouter',
               '-I', str(modules), '-target', target, '-minimum-access-level', 'public',
               '-skip-synthesized-members', '-skip-inherited-docs', '-module-cache-path', os.environ.get('CLANG_MODULE_CACHE_PATH', str(scratch / 'cache')),
               '-output-dir', str(scratch)]
    if sys.platform == 'darwin':
        command += ['-sdk', subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()]
    subprocess.run(command, check=True)
    symbols = json.loads((scratch / 'TrustedRouter.symbols.json').read_text())['symbols']
    # Synthesized conformances have no source declaration to document.
    declared = [symbol for symbol in symbols if 'location' in symbol]
    missing = [symbol for symbol in declared if not any(
        line['text'].strip() for line in symbol.get('docComment', {}).get('lines', []))]
    for symbol in missing:
        print('UNDOCUMENTED ' + '.'.join(symbol['pathComponents']))
    print(f'Public documentation: {len(declared)} declarations, {len(missing)} undocumented')
    if missing:
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tr-docs-') as tmp:
        check(args.modules.resolve(), Path(tmp))
