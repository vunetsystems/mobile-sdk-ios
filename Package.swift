// swift-tools-version: 6.1
// Vunet v0.0.23 — pre-built binary package. See README.md.
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
        .binaryTarget(name: "Vunet", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.23/Vunet.xcframework.zip", checksum: "990340b482efe852f76f967dad0366a87f95ca0977b84c69ea745a01f9203745"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "VunetDeps", path: "Deps"),
        .binaryTarget(name: "VunetSDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.23/VunetSDWebImage.xcframework.zip", checksum: "6ba62868a13cb32354aaba96781524c1d8654872d1a830eff84b0a0804ae5dea"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "VunetSDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .binaryTarget(name: "VuSourceInstrumenter", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.23/VuSourceInstrumenter.artifactbundle.zip", checksum: "864f18e6a724bb1a6851d6e94e6e949f297b7b7d46018574be896a05fe90b0c1"),
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
