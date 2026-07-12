// swift-tools-version: 6.1
// vuTelemetry v0.0.8 — pre-built binary package. See README.md.
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
        .binaryTarget(name: "vuTelemetry", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.8/vuTelemetry.xcframework.zip", checksum: "41a26c8e3df1817d8e5fedd920205de94a7990bd6718044cd39446e12915e280"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "vuTelemetryDeps", path: "Deps"),
        .binaryTarget(name: "vuTelemetrySDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.8/vuTelemetrySDWebImage.xcframework.zip", checksum: "9b960b059b614219f8d4f9db5f86b36e4f6fa0b137e2b6e7fb0ed9055ae19cbd"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "vuTelemetrySDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .binaryTarget(name: "VUSourceInstrumenter", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.8/VUSourceInstrumenter.artifactbundle.zip", checksum: "2ce32cbf1f770d235441242ca1f3f0c9b885537be72c9be1b1360bed96e0b577"),
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
