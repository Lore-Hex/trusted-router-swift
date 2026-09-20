#!/usr/bin/env python3
"""Prove each consumer gate rejects defects; always restore working-tree bytes."""
import argparse
from contextlib import contextmanager
import copy
import importlib.util
import json
import re
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, expected=None):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if expected is None:
        if result.returncode:
            raise SystemExit('BASELINE/BUILD FAILED:\n' + result.stdout + result.stderr)
    elif result.returncode == 0 or expected not in result.stdout + result.stderr:
        raise SystemExit('SURVIVED or infrastructure failure:\n' + result.stdout + result.stderr)
    return result.stdout


@contextmanager
def changed(path, contents):
    original = path.read_bytes()
    try:
        path.write_bytes(contents)
        yield
    finally:
        path.write_bytes(original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scratch-path', type=Path, required=True)
    args = parser.parse_args()
    build = ['swift', 'build', '--disable-sandbox', '--scratch-path', str(args.scratch_path)]
    run(build)
    bindir = run(build + ['--show-bin-path']).strip().splitlines()[-1]
    modules = str(Path(bindir) / 'Modules')
    listing = ['python3', 'scripts/test-consumer-dx.py', 'ConsumerDXTests.test_artifact_listing']
    metadata = ['python3', 'scripts/test-consumer-dx.py', 'ConsumerDXTests.test_metadata']
    examples = ['python3', 'scripts/check-examples.py', '--modules', modules]
    docs = ['python3', 'scripts/check-public-docs.py', '--modules', modules]
    for command in (listing, metadata, examples, docs):
        run(command)

    stray = ROOT / 'Sources/TrustedRouter/accidental-scratch.txt'
    if stray.exists():
        raise SystemExit(f'Refusing to overwrite {stray}')
    try:
        stray.write_text('This must never ship.\n')
        run(listing, 'Release archive file list changed')
        print('KILLED artifact-stray-file', flush=True)
    finally:
        stray.unlink()

    path = ROOT / 'package-metadata.json'
    original = json.loads(path.read_text())
    for field in original:
        mutated = dict(original)
        del mutated[field]
        with changed(path, json.dumps(mutated).encode()):
            run(metadata, 'Missing release metadata')
        print(f'KILLED metadata-missing-{field}', flush=True)

    path = ROOT / 'README.md'
    with changed(path, path.read_bytes().replace(b'client.models()', b'client.nonexistentExampleMethod()', 1)):
        run(examples, 'nonexistentExampleMethod')
    print('KILLED broken-readme-example', flush=True)
    without_examples = re.sub(r'^```swift\n.*?^```\s*$', '', path.read_text(), flags=re.M | re.S)
    with changed(path, without_examples.encode()):
        run(examples, 'No Swift examples found')
    print('KILLED missing-examples', flush=True)

    path = ROOT / 'Sources/TrustedRouter/Models/Models.swift'
    marker = b'/// Model identity, context limits, and routing capabilities.\n'
    if path.read_bytes().count(marker) != 1:
        raise SystemExit('Stale documentation mutation')
    try:
        with changed(path, path.read_bytes().replace(marker, b'', 1)):
            run(build)
            run(docs, 'UNDOCUMENTED ModelInfo')
            print('KILLED missing-public-doc-comment', flush=True)
    finally:
        run(build)
    run(docs)

    # Exercise every manifest invariant against an actual decoded release manifest.
    spec = importlib.util.spec_from_file_location('consumer', ROOT / 'scripts/test-consumer-dx.py')
    consumer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(consumer)
    with tempfile.TemporaryDirectory(prefix='tr-manifest-mutation-') as tmp:
        import zipfile
        archive = consumer.artifact.build(Path(tmp) / 'release.zip')
        with zipfile.ZipFile(archive) as zipped:
            zipped.extractall(tmp)
        manifest = json.loads(run(['swift', 'package', '--disable-sandbox', '--package-path',
                                  str(Path(tmp) / 'TrustedRouter'), 'dump-package']))
        consumer.check_manifest(manifest)
        mutations = {
            'runtime-dependency': ('dependencies', ['unexpected']),
            'extra-product': ('products', manifest['products'] + [manifest['products'][0]]),
            'extra-target': ('targets', manifest['targets'] + [manifest['targets'][0]]),
            'target-dependency': ('targets', [dict(manifest['targets'][0], dependencies=['test-only'])]),
            'executable-target': ('targets', [dict(manifest['targets'][0], type='executable')]),
            'tools-minimum': ('toolsVersion', {'_version': '5.8.0'}),
            'platform-minimum': ('platforms', []),
        }
        for name, (key, value) in mutations.items():
            mutant = copy.deepcopy(manifest)
            mutant[key] = value
            try:
                consumer.check_manifest(mutant)
            except AssertionError:
                print(f'KILLED manifest-{name}', flush=True)
            else:
                raise SystemExit(f'SURVIVED manifest-{name}')
    for name, output, requests in (
        ('model-output', 'wrong-model', [('/v1/models', 'Bearer fake-consumer-key')]),
        ('wire-path', 'fake-model', [('/wrong', 'Bearer fake-consumer-key')]),
        ('wire-auth', 'fake-model', [('/v1/models', 'Bearer wrong-key')]),
        ('wire-count', 'fake-model', []),
    ):
        try:
            consumer.check_smoke(output, requests)
        except AssertionError:
            print(f'KILLED smoke-{name}', flush=True)
        else:
            raise SystemExit(f'SURVIVED smoke-{name}')
    print('Consumer mutations restored; all gates rejected their defects', flush=True)


if __name__ == '__main__':
    main()
