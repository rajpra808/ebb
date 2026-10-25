// swift-tools-version:5.10
import PackageDescription

// The macOS app. It's its own package so the CLI and ScanCore keep building
// on Linux; it uses the root package for scanning and cleaning.
let package = Package(
    name: "EbbApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Ebb", path: ".."),
    ],
    targets: [
        // State and presentation logic, without views, so it can be tested.
        .target(
            name: "EbbAppKit",
            dependencies: [
                .product(name: "ScanCore", package: "Ebb"),
                .product(name: "EbbClean", package: "Ebb"),
            ]
        ),
        .executableTarget(
            name: "EbbApp",
            dependencies: [
                "EbbAppKit",
                .product(name: "ScanCore", package: "Ebb"),
                .product(name: "EbbClean", package: "Ebb"),
            ]
        ),
        .testTarget(
            name: "EbbAppKitTests",
            dependencies: ["EbbAppKit"]
        ),
    ]
)
