// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyOpenCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "MyOpenCleaner", targets: ["MyOpenCleaner"]),
    ],
    targets: [
        // All scanning / cleaning logic. No UI, fully testable against temp folders.
        .target(name: "SweepCore", path: "Sources/SweepCore"),
        .executableTarget(name: "MyOpenCleaner", dependencies: ["SweepCore"], path: "Sources/MyOpenCleaner"),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"], path: "Tests/SweepCoreTests"),
        // The battery code lives in the app target (ported from Bettary), so it is tested through it.
        .testTarget(name: "MyOpenCleanerTests", dependencies: ["MyOpenCleaner"], path: "Tests/MyOpenCleanerTests"),
    ]
)
