// swift-tools-version: 6.1
// Vunet v0.0.22 — pre-built binary package. See README.md.
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
        .binaryTarget(name: "Vunet", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.22/Vunet.xcframework.zip", checksum: "87bbdf756e196f820a7dc5178ff6a7d323e8189444d6ab57e347e6106d209c49"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "VunetDeps", path: "Deps"),
        .binaryTarget(name: "VunetSDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.22/VunetSDWebImage.xcframework.zip", checksum: "a0148c227625a486bd9227905c57776ab14e466e277873aa62a1bfc828d7d27b"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "VunetSDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .binaryTarget(name: "VuSourceInstrumenter", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.22/VuSourceInstrumenter.artifactbundle.zip", checksum: "dba426f627b15f76cafd78ad192f025988bd0e70c805fc554468c4c61b614feb"),
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
