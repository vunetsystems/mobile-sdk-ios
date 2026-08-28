// swift-tools-version: 6.1
// vuTelemetry v0.0.14 — pre-built binary package. See README.md.
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
        .binaryTarget(name: "vuTelemetry", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.14/vuTelemetry.xcframework.zip", checksum: "2a3687468676a18e842a3afe9c20b58e9fada512811fa9bd04b86ddfc78af613"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "vuTelemetryDeps", path: "Deps"),
        .binaryTarget(name: "vuTelemetrySDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.14/vuTelemetrySDWebImage.xcframework.zip", checksum: "afae9d71632bc2ad2daa90b33fff8df65a8554ddb81c871afe070088c79a9447"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "vuTelemetrySDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .binaryTarget(name: "VUSourceInstrumenter", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.14/VUSourceInstrumenter.artifactbundle.zip", checksum: "f7c72c7e7d9805bff54fcb866df815cf3dc6bc505012f2cfdc5893807e71c341"),
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
