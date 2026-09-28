// swift-tools-version: 6.1
// Vunet v0.0.21 — pre-built binary package. See README.md.
// Built WITH library evolution: portable .swiftinterface, consumable by any Xcode >= Xcode 26.5.
import PackageDescription

let package = Package(
    name: "Vunet",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(name: "Vunet", targets: ["Vunet", "VuTelemetryBootstrap", "VunetDeps"]),
        .library(name: "VunetSDWebImage", targets: ["VunetSDWebImage", "VUSDWebImageBootstrap", "VunetSDWebImageDeps", "Vunet", "VuTelemetryBootstrap", "VunetDeps"]),
        .plugin(name: "VuInstrumentationPlugin", targets: ["VuInstrumentationPlugin"]),
        .plugin(name: "VuInstrumentationCommand", targets: ["VuInstrumentationCommand"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", exact: "5.21.7"),
    ],
    targets: [
        .binaryTarget(name: "Vunet", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.21/Vunet.xcframework.zip", checksum: "9001e6c445c33bcbe1c3662df4fc5c50cbeab7d48ec5ca474ee0e9d81999d6e8"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "VunetDeps", path: "Deps"),
        .binaryTarget(name: "VunetSDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.21/VunetSDWebImage.xcframework.zip", checksum: "83801c42662dcf7aead1f3b859c995766d7c72197a9f5def28b4633262d37060"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "VunetSDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .binaryTarget(name: "VuSourceInstrumenter", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.21/VuSourceInstrumenter.artifactbundle.zip", checksum: "afc04047bc788e37c3a7d1bc9a5250c6efa2e88c41c5f0d2e7ecbb9d47d01fff"),
        .plugin(
            name: "VuInstrumentationPlugin",
            capability: .buildTool(),
            dependencies: ["VuSourceInstrumenter"],
            path: "Plugins/VUInstrumentationPlugin"
        ),
        .plugin(
            name: "VuInstrumentationCommand",
            capability: .command(
                intent: .custom(
                    verb: "vu-instrument",
                    description: "Install, verify, or uninstall Vunet SwiftUI instrumentation phases"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Injects and manages Xcode build phases for SwiftUI instrumentation"
                    )
                ]
            ),
            dependencies: ["VuSourceInstrumenter"],
            path: "Plugins/VUInstrumentationCommand"
        ),
    ]
)
