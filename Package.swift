// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ebb",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanCore", targets: ["ScanCore"]),
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
        .target(
            name: "EbbCLI",
            dependencies: [
                "ScanCore",
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
            name: "EbbCLITests",
            dependencies: ["EbbCLI"]
        ),
    ]
)
