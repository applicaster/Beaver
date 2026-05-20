// swift-tools-version: 6.0
import PackageDescription

// The Xcode project at the repo root is the primary build path.
// This Package.swift exists so `swift test` can run the core/store/
// decoder logic headlessly in CI without booting an Xcode build.

let package = Package(
    name: "Beaver",
    platforms: [
        // macOS app deployment is 26 (set in the Xcode target). SPM
        // doesn't yet have a `.v26` enum value, so we use the highest
        // available here. SPM builds only the headless core anyway.
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "BeaverCore",
            targets: ["BeaverCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BeaverCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Beaver",
            exclude: [
                "BeaverApp.swift",           // SwiftUI App entry, app-target only
                "AppEnvironment.swift",      // depends on app-target lifecycle
                "Features",                  // SwiftUI views, app-target only
                "Assets.xcassets",           // Xcode resource bundle
                "Beaver.entitlements",       // app entitlements
            ]
        ),
        .testTarget(
            name: "BeaverCoreTests",
            dependencies: ["BeaverCore"],
            path: "BeaverTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
