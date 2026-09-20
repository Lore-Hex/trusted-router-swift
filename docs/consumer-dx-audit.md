# Consumer DX audit

Worktree changes only; no commit or publication. No runtime dependencies or SDK behavior changes. Swift source changes are documentation, plus moving two existing identifier lint suppressions onto their declarations so DocC comments stay attached.

## Release artifact

SwiftPM Git dependencies fetch a repository; they do not support a package-file inclusion list. The clean release deliverable is now the source ZIP built by `scripts/build-artifact.py:10` and uploaded by `.github/workflows/ci.yml:33`. No claim is made that a Git clone or GitHub's automatic source archive omits development files. `README.md:33` explains the distinction.

| Inventory | Before | After |
| --- | ---: | ---: |
| Library Swift sources | 36 | 36 |
| Package.swift and README | 2 | 2 |
| LICENSE and package-metadata.json | 0 | 2 |
| Tests and fixtures | 36 | 0 |
| Scripts | 4 | 0 |
| CI files | 3 | 0 |
| Other repository files, including worktree .git pointer | 7 | 0 |
| **Total files** | **88** | **40** |

Exact listings: [before](artifact-before.txt), [after](artifact-after.txt). The before listing came from `swift package --disable-sandbox archive-source --output /tmp/tr-before.zip` before edits. The after listing came from `python3 scripts/build-artifact.py /tmp/trusted-router-swift2-dx/TrustedRouter.zip`, followed by reading the ZIP central directory. The independent expected inventory is `scripts/artifact-files.txt:1`; `scripts/test-consumer-dx.py:21` builds a new ZIP and asserts its complete file list. The packager deliberately copies the entire Sources tree so accidental source-tree files are detected, rather than silently filtered from the test.

`Package.swift:29` includes the XCTest target only when its directory is present, using a path relative to the manifest itself. An extracted release therefore declares only the library target and product; a repository checkout retains the existing tests and fixture resources. The consumer test checks the decoded manifest for product, target, dependency, tools-version, and platform invariants at `scripts/test-consumer-dx.py:41`.

## Metadata diff

| Field | Before | After / location |
| --- | --- | --- |
| Description | README prose only | Structured description, `package-metadata.json:2` |
| License | README says Apache 2.0; no license file | Full Apache 2.0 text, `LICENSE:1`; URL and SPDX identifier, `package-metadata.json:3,17` |
| Repository | Installation URL only | `repositoryURLs`, `package-metadata.json:5` |
| Homepage | README hyperlink only | `homepageURL`, `package-metadata.json:8` |
| Documentation | No structured URL | README documentation URL, `package-metadata.json:9` |
| Keywords/topics | Absent | swift, trustedrouter, llm, streaming, attestation, `package-metadata.json:10` |
| Minimum tools version | Swift 5.9 | Preserved, `Package.swift:1`; explained in `README.md:29` |
| Platforms | macOS 13, iOS/tvOS 16, watchOS 9 | Preserved, `Package.swift:8`; asserted from the release manifest |
| Products / dependencies | One library / no dependencies | Preserved, `Package.swift:14,19`; no test-only dependency in release |

Description, licenseURL, readmeURL, and repositoryURLs follow [Swift registry release metadata](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0391-package-registry-publish.md). Homepage, documentation URL, keywords, and SPDX license are explicitly documented metadata extensions, not new PackageDescription API fields or remotely configured GitHub topics. The test rejects omission of any of these eight metadata fields (`scripts/test-consumer-dx.py:30`).

## Editor documentation and examples

Added 438 DocC comment lines: 435 source declarations on macOS and three fallback declarations for platforms without Network.framework. The compiler-derived macOS symbol graph contains **528 source declarations, zero undocumented**. The original graph lacked 415 comments plus 20 declarations that only inherited protocol documentation. The final gate disables inherited documentation and excludes compiler-synthesized members with no source declaration. It covers enum cases and nested members, not just lines containing `public` (`scripts/check-public-docs.py:13`). macOS CI fails above zero (`.github/workflows/ci.yml:23`).

The external consumer imports the compiled module and checks its symbol graph, exercising the `.swiftmodule` / `.swiftdoc` consumer artifacts. Every Swift fence from README and `docs/**/*.md` is extracted verbatim. Five ordinary examples become executable snippets targets in the scratch package; the installation manifest is evaluated separately. All six are also independently type-checked/evaluated by `scripts/check-examples.py:14`. There are no Swift fences in docs at present.

| Example | Before coverage | After coverage / source |
| --- | --- | --- |
| Installation manifest | None | Full manifest evaluated, `README.md:11` |
| Models, chat, streaming | None | Verbatim executable target + type check, `README.md:47` |
| Fusion | None; assumed existing client | Self-contained import/client, `README.md:111` |
| Provider privacy | None; assumed existing client | Self-contained import/client, `README.md:134` |
| Receipt verification | None; undeclared inputs | Function with typed captured inputs, `README.md:182` |
| OAuth | None; assumed `self` presentation provider | Optional presentation provider omitted; platform conditional, `README.md:260` |

The snippet executables are compiled and linked but do not execute real service requests. The separate Smoke target makes exactly one real HTTP call to a local fake server.

| CLI command × option | Before | After |
| --- | --- | --- |
| Not applicable: the SDK has no CLI or executable product | 0 commands, 0 options | 0 commands, 0 options; no CLI behavior changes |

The Python files under scripts are development checks, excluded from the release artifact.

## Scratch consumer commands and result

Reproduce from the repository with `CLANG_MODULE_CACHE_PATH=/tmp/tr-dx-module-cache python3 scripts/test-consumer-dx.py -v`. The test creates a fresh directory using Python's `TemporaryDirectory` outside the repo, builds the release ZIP, extracts it, and writes a SwiftPM consumer depending on `../artifact/TrustedRouter`. It does not depend on this working tree. Its single build compiles the library, Smoke, and all five ordinary snippets.

Exact commands from the successful local run (the temporary directory and server are cleaned up afterward):

1. `swift build --disable-sandbox --package-path /var/folders/th/1hvz8frd3p551wg24zytym940000gn/T/tr-consumer-q1nes0bx/consumer`
2. `swift package --disable-sandbox --package-path /var/folders/th/1hvz8frd3p551wg24zytym940000gn/T/tr-consumer-q1nes0bx/artifact/TrustedRouter dump-package`
3. `/var/folders/th/1hvz8frd3p551wg24zytym940000gn/T/tr-consumer-q1nes0bx/consumer/.build/debug/Smoke http://127.0.0.1:58027/v1`
4. `python3 scripts/check-public-docs.py --modules /var/folders/th/1hvz8frd3p551wg24zytym940000gn/T/tr-consumer-q1nes0bx/consumer/.build/debug/Modules`
5. `python3 scripts/check-examples.py --modules /var/folders/th/1hvz8frd3p551wg24zytym940000gn/T/tr-consumer-q1nes0bx/consumer/.build/debug/Modules`

Result: **3 Python release tests passed in 60.408 seconds**; build and link succeeded; Smoke printed `fake-model`; the fake server observed exactly `GET /v1/models` with `Authorization: Bearer fake-consumer-key`; imported documentation had zero missing comments; all six examples passed. The fake server binds 127.0.0.1 successfully on this host.

## Fails-without-fix evidence

`CLANG_MODULE_CACHE_PATH=/tmp/tr-dx-module-cache python3 scripts/consumer-mutation-check.py --scratch-path /tmp/tr-dx-build`: **23/23 killed**, original bytes restored, final library rebuilt and public documentation checked again. The script starts with passing baselines and requires the expected diagnostic, so an unrelated compile/infrastructure failure does not count as a kill.

| Mutation | Guard rejecting it | Result |
| --- | --- | --- |
| Add Sources/TrustedRouter/accidental-scratch.txt | Actual ZIP file-list assertion | Killed |
| Remove description | Required artifact metadata | Killed |
| Remove licenseURL | Required artifact metadata | Killed |
| Remove readmeURL | Required artifact metadata | Killed |
| Remove repositoryURLs | Required artifact metadata | Killed |
| Remove homepageURL | Required artifact metadata | Killed |
| Remove documentationURL | Required artifact metadata | Killed |
| Remove keywords | Required artifact metadata | Killed |
| Remove license | Required artifact metadata | Killed |
| Replace README client.models() with nonexistentExampleMethod() | Compile extracted README fence | Killed |
| Remove every Swift example | Nonempty example inventory | Killed |
| Remove ModelInfo DocC comment and rebuild | Compiler symbol graph reports UNDOCUMENTED ModelInfo | Killed |
| Add runtime dependency | Release manifest assertion | Killed |
| Add product | Release manifest assertion | Killed |
| Add target | Release manifest assertion | Killed |
| Add target dependency | Release manifest assertion | Killed |
| Change library target to executable | Release manifest assertion | Killed |
| Change tools minimum to 5.8 | Release manifest assertion | Killed |
| Remove platform minimums | Release manifest assertion | Killed |
| Wrong model output | Consumer result assertion | Killed |
| Wrong request path | Consumer wire assertion | Killed |
| Wrong authorization | Consumer wire assertion | Killed |
| Missing wire call | Consumer wire-count assertion | Killed |

The first twelve mutations change files used by the real checks. The seven manifest mutations alter a decoded manifest obtained from an actual extracted artifact. The final four mutate the captured result supplied to the same assertion used by the live smoke test. These assertion-level negative controls are not claims that SDK runtime behavior was changed. There are no new runtime guards or CLI tests.

Wave 1 static mutation command: `DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib python3 scripts/static-gate-check.py`: **8/8 killed** (force_unwrapping, force_cast, force_try, implicitly_unwrapped_optional, raw_response_header_lookup, cast_string_default, swallowed_json_decoding, empty_object_fallback). Wave 1 behavioral mutation patterns: `scripts/mutation-check.sh --validate-patterns`: **18/18 valid**, not behavioral kills.

## Verification limits and CI

- Library builds and all consumer snippets compile/link locally. `swiftc -frontend -parse Tests/TrustedRouterTests/*.swift` passed as a syntax check only.
- `DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib swiftlint --strict --no-cache`: passed with zero violations in 36 source files. The requested command without `--no-cache` also finds zero violations but exits 1 because this sandbox cannot write SwiftLint's user cache. Disabling that cache gives an exit-0 strict check; static mutation checks already use `--no-cache`. CI retains ordinary `swiftlint --strict` on its writable runner.
- **XCTest tests were not executed locally.** `swift test --disable-sandbox --scratch-path /tmp/tr-dx-build` fails to compile with `no such module 'XCTest'`. The entire XCTest target cannot be compile-checked on this installation; parsing does not replace type checking.
- The full Wave 1 behavioral mutation command also requires XCTest; its local baseline is blocked, not green. This was confirmed with `PATH="/tmp/tr-dx-bin:$PATH" CLANG_MODULE_CACHE_PATH=/tmp/tr-dx-module-cache scripts/mutation-check.sh`, adding `--disable-sandbox --scratch-path /tmp/tr-dx-build` to its `swift test` calls via the temporary wrapper; the baseline failed with `no such module 'XCTest'` before any behavioral mutation ran. CI retains both macOS and Linux XCTest jobs and the full boundary mutation gate. Do not interpret 18 valid patterns as 18 locally killed mutations.
- SDK conformance: **25/25 passed, 0 skipped**, using the unchanged shared harness with a temporary Swift wrapper that adds `--disable-sandbox` to `swift run`; ordinary invocation hit the local nested SwiftPM sandbox. The adapter made real TLS loopback calls; this result is not sandbox-blocked.
- `git diff --check` passed. No commits, runtime dependencies, registry publication, or remote metadata changes.

CI runs build, public DocC coverage, artifact/consumer/snippet tests, consumer mutations, XCTest, Wave 1 behavioral mutations, and then builds/uploads the release ZIP (`.github/workflows/ci.yml:21`). The existing conformance workflow remains the required CI gate.

Exact successful conformance invocation: `PATH="/tmp/tr-dx-bin:$PATH" CLANG_MODULE_CACHE_PATH=/tmp/tr-dx-module-cache UV_CACHE_DIR=/tmp/tr-dx-uv-cache PYTHONUNBUFFERED=1 uv run --project ../../trusted-router-sdk-conformance tr-conformance --sdk swift --sdk-root swift="$PWD" --json-report /tmp/trusted-router-swift2-dx/conformance.json`. The local wrapper forwards `run` and `build` to `/Library/Developer/CommandLineTools/usr/bin/swift` with `--disable-sandbox`; other commands are forwarded unchanged. No shared harness sources were edited. This disables only SwiftPM's inner manifest sandbox. The standard CI conformance workflow needs no wrapper.

Successful run logs are under `/tmp/trusted-router-swift2-dx/`: `consumer.log`, `mutations.log`, `conformance.log`, and `conformance.json`. The report deliberately distinguishes passing Python release tests from unavailable XCTest execution.

Every changed diff hunk is indexed with repository-relative file:line coordinates in [consumer-dx-change-locations.txt](consumer-dx-change-locations.txt); new files are indexed at line 1. The exact archive inventories above are recorded evidence, while `scripts/artifact-files.txt` is the independently maintained test expectation.
