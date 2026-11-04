// swift-tools-version: 5.9
// auv3-test's iOS runner: an app package (no Xcode project), so it opens straight in
// Xcode or Swift Playgrounds, and `auv3-test-ios` can build it from the command line.
// It runs the same checks as the Mac command line, from AUv3TestKit in the parent package.
//
// Signing for a real iPhone or iPad needs your team: set DEVELOPMENT_TEAM in the
// environment (auv3-test-ios does). AUV3_RUNNER_BUNDLE_ID overrides the bundle ID.
import PackageDescription
import AppleProductTypes

let environment = Context.environment

let package = Package(
    name: "AUv3TestRunner",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "AUv3TestRunner",
            targets: ["AUv3TestRunner"],
            bundleIdentifier: environment["AUV3_RUNNER_BUNDLE_ID"] ?? "io.github.sufystudios.auv3-test-runner",
            teamIdentifier: environment["DEVELOPMENT_TEAM"] ?? "",
            displayVersion: "0.3.0",
            bundleVersion: "1",
            accentColor: .presetColor(.green),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad])),
            ],
            additionalInfoPlistContentFilePath: "Info.plist"
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AUv3TestRunner",
            dependencies: [.product(name: "AUv3TestKit", package: "AUv3TestHost")],
            path: "Sources"
        ),
    ]
)
