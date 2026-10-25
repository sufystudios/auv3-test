// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AUv3TestHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "auv3-test", targets: ["auv3-test"]),
    ],
    targets: [
        // Apple frameworks only (AVFoundation, AudioToolbox, AppKit): nothing to install.
        .executableTarget(name: "auv3-test", path: "Sources/auv3-test"),
    ],
    swiftLanguageModes: [.v5]
)
