// swift-tools-version: 5.9

import PackageDescription
import Foundation

let package = Package(
    name: "TrustedRouter",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "TrustedRouter",
            targets: ["TrustedRouter"]),
    ],
    dependencies: [
        // No dependencies, pure swift (we use URLSession and CryptoKit)
    ],
    targets: [
        .target(
            name: "TrustedRouter",
            dependencies: []),
    ]
)

// Release archives contain only the library. Repository checkouts also expose tests.
if FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Tests/TrustedRouterTests").path) {
    package.targets.append(
        .testTarget(
            name: "TrustedRouterTests",
            dependencies: ["TrustedRouter"],
            resources: [
                .copy("Fixtures/receipts"),
                .copy("Fixtures/auth-wire-fixtures.json")
            ])
    )
}
