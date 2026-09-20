#!/usr/bin/env python3
"""Release tests run without XCTest: artifact inventory, metadata, and consumer."""
import importlib.util
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('artifact', ROOT / 'scripts/build-artifact.py')
artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(artifact)


class ConsumerDXTests(unittest.TestCase):
    def test_artifact_listing(self):
        with tempfile.TemporaryDirectory(prefix='tr-artifact-') as tmp:
            archive = artifact.build(Path(tmp) / 'TrustedRouter.zip')
            with zipfile.ZipFile(archive) as zipped:
                actual = sorted(zipped.namelist())
            expected = sorted('TrustedRouter/' + name for name in
                              (ROOT / 'scripts/artifact-files.txt').read_text().splitlines())
            self.assertEqual(actual, expected, 'Release archive file list changed')

    def test_metadata(self):
        metadata = json.loads((ROOT / 'package-metadata.json').read_text())
        required = ('description', 'licenseURL', 'repositoryURLs', 'homepageURL',
                    'documentationURL', 'keywords', 'license', 'readmeURL')
        self.assertTrue(all(metadata.get(key) for key in required), 'Missing release metadata')

    def test_scratch_consumer(self):
        with tempfile.TemporaryDirectory(prefix='tr-consumer-') as tmp:
            scratch_consumer(Path(tmp))


def check_manifest(manifest):
    expected_product = [{'name': 'TrustedRouter', 'targets': ['TrustedRouter'],
                         'type': {'library': ['automatic']}}]
    expected_platforms = {'macos': '13.0', 'ios': '16.0', 'tvos': '16.0', 'watchos': '9.0'}
    actual_platforms = {p['platformName']: p['version'] for p in manifest['platforms']}
    actual_products = [{key: product[key] for key in ('name', 'targets', 'type')}
                       for product in manifest['products']]
    if (manifest['dependencies'] or actual_products != expected_product
            or [(t['name'], t['type'], t['dependencies']) for t in manifest['targets']]
            != [('TrustedRouter', 'regular', [])]
            or manifest['toolsVersion']['_version'] != '5.9.0'
            or actual_platforms != expected_platforms):
        raise AssertionError('Artifact must expose only the dependency-free library with declared minimums')


def check_smoke(output, requests):
    if output.strip() != 'fake-model' or requests != [('/v1/models', 'Bearer fake-consumer-key')]:
        raise AssertionError(f'Consumer call failed: {output!r}, {requests!r}')


def scratch_consumer(tmp):
    archive = artifact.build(tmp / 'TrustedRouter.zip')
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(tmp / 'artifact')
    package = tmp / 'artifact/TrustedRouter'
    consumer = tmp / 'consumer'
    sources = consumer / 'Sources/Smoke'
    sources.mkdir(parents=True)
    (consumer / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Consumer", platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../artifact/TrustedRouter")],
    targets: [.executableTarget(name: "Smoke", dependencies: [
        .product(name: "TrustedRouter", package: "TrustedRouter")
    ])]
)
''')
    (sources / 'main.swift').write_text('''import Foundation
import TrustedRouter

let client = try TrustedRouter(options: .init(
    apiKey: "fake-consumer-key", controlBaseURL: CommandLine.arguments[1],
    maxRetries: 0, telemetry: false
))
let models: DataList<ModelInfo> = try await client.models()
print(models.data.map(\\.id).joined(separator: ","))
''')
    # Every ordinary fence is also an executable snippets target compiled verbatim
    # in the consumer's single SwiftPM build. Manifest fences are checked separately.
    extra_targets = []
    for path in [ROOT / 'README.md', *sorted((ROOT / 'docs').rglob('*.md'))]:
        for code in re.findall(r'^```swift\n(.*?)^```\s*$', path.read_text(), re.M | re.S):
            if code.startswith('// swift-tools-version:'):
                continue
            name = f'Example{len(extra_targets) + 1}'
            destination = consumer / 'Sources' / name
            destination.mkdir()
            (destination / 'main.swift').write_text(code)
            extra_targets.append(f'.executableTarget(name: "{name}", dependencies: '
                                 '[.product(name: "TrustedRouter", package: "TrustedRouter")])')
    manifest_path = consumer / 'Package.swift'
    manifest_path.write_text(manifest_path.read_text().replace(
        '    ])]\n)', '    ])' + ''.join(',\n    ' + t for t in extra_targets) + ']\n)'))

    def run(command):
        print('+ ' + ' '.join(map(str, command)), flush=True)
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise AssertionError(f'Command failed ({result.returncode}):\n{result.stdout}\n{result.stderr}')
        print(result.stdout, end='', flush=True)
        return result.stdout
    # Exactly one build; the executable below is the result of this build.
    run(['swift', 'build', '--disable-sandbox', '--package-path', str(consumer)])
    manifest = json.loads(run(['swift', 'package', '--disable-sandbox', '--package-path',
                               str(package), 'dump-package']))
    check_manifest(manifest)
    requests = []

    class FakeServer(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append((self.path, self.headers.get('Authorization')))
            body = b'{"data":[{"id":"fake-model"}]}'
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), FakeServer)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        output = run([str(consumer / '.build/debug/Smoke'), f'http://127.0.0.1:{server.server_port}/v1'])
        check_smoke(output, requests)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    modules = consumer / '.build/debug/Modules'
    run(['python3', str(ROOT / 'scripts/check-public-docs.py'), '--modules', str(modules)])
    run(['python3', str(ROOT / 'scripts/check-examples.py'), '--modules', str(modules)])
    print('Scratch consumer: built artifact, typed call, fake server, docs, examples PASS', flush=True)


if __name__ == '__main__':
    unittest.main()
