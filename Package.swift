// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUv3TestHost",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "auv3-test", targets: ["auv3-test"]),
        .library(name: "AUv3TestKit", targets: ["AUv3TestKit"]),
    ],
    targets: [
        // Apple frameworks only (AVFoundation, AudioToolbox, AppKit/UIKit): nothing to install.
        // The checks, for macOS and iOS alike. The iOS runner app that uses them is in
        // iOSRunner/AUv3TestRunner.swiftpm, driven by auv3-test-ios.
        .target(name: "AUv3TestKit", path: "Sources/AUv3TestKit"),
        // The Mac command line.
        .executableTarget(name: "auv3-test", dependencies: ["AUv3TestKit"], path: "Sources/auv3-test"),
        // Unit tests.
        .testTarget(name: "auv3-testTests", dependencies: ["AUv3TestKit"], path: "Tests/auv3-testTests"),
    ],
    swiftLanguageModes: [.v5]
)
