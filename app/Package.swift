// swift-tools-version:6.2
// Supermole.app: a one-window macOS front end that drives the installed `mo`
// CLI. scripts/build_installer_dmg.sh builds it per architecture, checks each
// slice's minimum macOS and assembles the app bundle around the executable.
// The app needs macOS 26 for Liquid Glass; `mo` itself still runs on macOS 12.
import PackageDescription

let package = Package(
    name: "Supermole",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Supermole", targets: ["Supermole"]),
    ],
    targets: [
        // Everything that talks to `mo` and parses its output, kept free of
        // SwiftUI so `swift test` covers it.
        .target(name: "SupermoleCore"),
        .executableTarget(name: "Supermole", dependencies: ["SupermoleCore"]),
        .testTarget(
            name: "SupermoleCoreTests",
            dependencies: ["SupermoleCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
