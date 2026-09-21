// swift-tools-version: 6.1
// vuTelemetry v0.0.19 — pre-built binary package. See README.md.
// Built WITH library evolution: portable .swiftinterface, consumable by any Xcode >= Xcode 26.5.
import PackageDescription

let package = Package(
    name: "vuTelemetry",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(name: "vuTelemetry", targets: ["vuTelemetry", "VuTelemetryBootstrap", "vuTelemetryDeps"]),
        .library(name: "vuTelemetrySDWebImage", targets: ["vuTelemetrySDWebImage", "VUSDWebImageBootstrap", "vuTelemetrySDWebImageDeps", "vuTelemetry", "VuTelemetryBootstrap", "vuTelemetryDeps"]),
        .plugin(name: "VUInstrumentationPlugin", targets: ["VUInstrumentationPlugin"]),
        .plugin(name: "VUInstrumentationCommand", targets: ["VUInstrumentationCommand"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", exact: "5.21.7"),
    ],
    targets: [
        .binaryTarget(name: "vuTelemetry", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.19/vuTelemetry.xcframework.zip", checksum: "51a82f1ab0a69ce4f8fd9e534f6f2d2a3f831c2445a4e6b3d4d78bd497d204cf"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "vuTelemetryDeps", path: "Deps"),
        .binaryTarget(name: "vuTelemetrySDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.19/vuTelemetrySDWebImage.xcframework.zip", checksum: "4a044bc2d2b1c6fb94f94c12ffb29f511d4c3f6e98b73ecccc987b2b44eac761"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "vuTelemetrySDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .binaryTarget(name: "VUSourceInstrumenter", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.19/VUSourceInstrumenter.artifactbundle.zip", checksum: "700373a1b081e7e209321fa4afd7cdc22bc40ef812f7871ec569aa8d5d6fc319"),
        .plugin(
            name: "VUInstrumentationPlugin",
            capability: .buildTool(),
            dependencies: ["VUSourceInstrumenter"],
            path: "Plugins/VUInstrumentationPlugin"
        ),
        .plugin(
            name: "VUInstrumentationCommand",
            capability: .command(
                intent: .custom(
                    verb: "vu-instrument",
                    description: "Install, verify, or uninstall vuTelemetry SwiftUI instrumentation phases"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Injects and manages Xcode build phases for SwiftUI instrumentation"
                    )
                ]
            ),
            dependencies: ["VUSourceInstrumenter"],
            path: "Plugins/VUInstrumentationCommand"
        ),
    ]
)
