// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpotAMSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "MusicProviders", targets: ["MusicProviders"]),
        .executable(name: "SpotAMSync", targets: ["SpotAMSync"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SyncCore", dependencies: ["CSQLite"]),
        .target(name: "MusicProviders", dependencies: ["SyncCore"]),
        .executableTarget(name: "SpotAMSync", dependencies: ["SyncCore", "MusicProviders"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
        .testTarget(name: "MusicProvidersTests", dependencies: ["MusicProviders", "SyncCore"])
    ],
    swiftLanguageModes: [.v5]
)
