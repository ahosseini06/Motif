// swift-tools-version:6.0
import PackageDescription

// Swift 5 language mode: AVFoundation / Vision / SceneKit types are not Sendable-annotated enough
// for strict concurrency to be worth the friction yet.
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Motif",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MotifKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: settings
        ),
        .executableTarget(name: "motif-cli", dependencies: ["MotifKit"], swiftSettings: settings),
        .executableTarget(name: "MotifApp", dependencies: ["MotifKit"], swiftSettings: settings),
    ]
)
