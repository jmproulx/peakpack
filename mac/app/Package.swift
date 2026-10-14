// swift-tools-version:5.9
// PEAK (Modded) for Mac: the friend-facing front end (MacPort Track D).
// Built only on GitHub Actions macOS runners (.github/workflows/mac-app.yml) by scripts/build_app.sh,
// which wraps the SwiftPM executable into "PEAK (Modded).app". MIT licence (mac/LICENSE).
import PackageDescription

let package = Package(
    name: "PeakModded",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "PEAK Modded", targets: ["PeakModded"]),
        .library(name: "PeakModdedCore", targets: ["PeakModdedCore"]),
    ],
    targets: [
        // Pure logic: pins, hashes, signatures, downloads, state, Steam log/appinfo parsing, setup plan.
        // Foundation + CryptoKit only, so all of it is unit-tested in CI without a GUI session.
        .target(
            name: "PeakModdedCore",
            path: "Sources/PeakModdedCore"
        ),
        // The app: AppKit lifecycle, SwiftUI views, services that run Wine/PeakPack/Steam steps.
        .executableTarget(
            name: "PeakModded",
            dependencies: ["PeakModdedCore"],
            path: "Sources/PeakModded"
        ),
        .testTarget(
            name: "PeakModdedCoreTests",
            dependencies: ["PeakModdedCore"],
            path: "Tests/PeakModdedCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
