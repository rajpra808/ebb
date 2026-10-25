// swift-tools-version:5.10
import Foundation
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
            resources: [.process("Categories/categories.json")]
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
            dependencies: ["ScanCore"],
            swiftSettings: testingSettings.swift,
            linkerSettings: testingSettings.linker
        ),
        .testTarget(
            name: "EbbCLITests",
            dependencies: ["EbbCLI"],
            swiftSettings: testingSettings.swift,
            linkerSettings: testingSettings.linker
        ),
    ]
)

// MARK: - swift-testing on Command Line Tools

/// Xcode puts swift-testing on the default search path. The standalone
/// Command Line Tools ship it too, but in a folder the compiler doesn't look
/// in, so `import Testing` fails. When the active developer directory is the
/// CLT, point the compiler and linker at it. With Xcode (or on Linux) this
/// adds nothing.
var testingSettings: (swift: [SwiftSetting], linker: [LinkerSetting]) {
    #if os(macOS)
    let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
        ?? ""
    let frameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
    guard developerDir.hasPrefix("/Library/Developer/CommandLineTools"),
          FileManager.default.fileExists(atPath: frameworks + "/Testing.framework")
    else { return ([], []) }
    return (
        [.unsafeFlags(["-F", frameworks])],
        [.unsafeFlags(["-F", frameworks, "-Xlinker", "-rpath", "-Xlinker", frameworks])]
    )
    #else
    return ([], [])
    #endif
}
