// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ebb",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
        .library(name: "EbbClean", targets: ["EbbClean"]),
        .executable(name: "ebb", targets: ["ebb"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ScanCore",
            // Compiled into the binary so `ebb` is a single file to install.
            resources: [.embedInCode("Categories/categories.json")]
        ),
        // Moving to Trash, the clean log and putting back. Kept out of
        // ScanCore so that ScanCore stays read-only.
        .target(
            name: "EbbClean",
            dependencies: ["ScanCore"]
        ),
        .target(
            name: "EbbCLI",
            dependencies: [
                "ScanCore",
                "EbbClean",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ebb",
            dependencies: ["EbbCLI"]
        ),
        .testTarget(
            name: "ScanCoreTests",
            dependencies: ["ScanCore"]
        ),
        .testTarget(
            name: "EbbCleanTests",
            dependencies: ["EbbClean"]
        ),
        .testTarget(
            name: "EbbCLITests",
            dependencies: ["EbbCLI"]
        ),
    ]
)
