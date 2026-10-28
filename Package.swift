// swift-tools-version: 6.1
// Vunet v0.0.24-rc.1 — pre-built binary package. See README.md.
// Built WITH library evolution: portable .swiftinterface, consumable by any Xcode >= Xcode 26.5.
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Vunet",
    platforms: [.iOS(.v13), .macOS(.v12)],
    products: [
        .library(name: "Vunet", targets: ["Vunet", "VuTelemetryBootstrap", "VunetDeps"]),
        .library(name: "VunetSDWebImage", targets: ["VunetSDWebImage", "VUSDWebImageBootstrap", "VunetSDWebImageDeps", "Vunet", "VuTelemetryBootstrap", "VunetDeps"]),
        .library(name: "VuTrack", targets: ["VuTrack", "Vunet", "VuTelemetryBootstrap", "VunetDeps"]),
        .executable(name: "vutrack-tool", targets: ["vutrack-tool"]),
        .plugin(name: "VuTrackLint", targets: ["VuTrackLint"]),
        .plugin(name: "VuTrackTag", targets: ["VuTrackTag"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", "604.0.0"..<"605.0.0"),
        .package(url: "https://github.com/SDWebImage/SDWebImage.git", exact: "5.21.7"),
    ],
    targets: [
        .binaryTarget(name: "Vunet", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.24-rc.1/Vunet.xcframework.zip", checksum: "c2571c27edf9b167ee38854ebaa1eb6f389cc4c7f803e9267debfd17f8792c2e"),
        .target(name: "VuTelemetryBootstrap", path: "Bootstrap/VuTelemetryBootstrap", publicHeadersPath: "."),
        .target(name: "VunetDeps", path: "Deps"),
        .binaryTarget(name: "VunetSDWebImage", url: "https://github.com/vunetsystems/mobile-sdk-ios/releases/download/v0.0.24-rc.1/VunetSDWebImage.xcframework.zip", checksum: "74514fba9366d4bae5c2097f682469139e5e62057a160754eef4e2798250cd87"),
        .target(name: "VUSDWebImageBootstrap", path: "Bootstrap/VUSDWebImageBootstrap", publicHeadersPath: "include"),
        .target(name: "VunetSDWebImageDeps", dependencies: [
            .product(name: "SDWebImage", package: "SDWebImage"),
        ], path: "DepsSDWI"),
        .macro(name: "VuTrackMacros", dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"), .product(name: "SwiftSyntaxMacros", package: "swift-syntax"), .product(name: "SwiftDiagnostics", package: "swift-syntax"), .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"), .product(name: "SwiftParser", package: "swift-syntax"), .product(name: "SwiftCompilerPlugin", package: "swift-syntax")], path: "Sources/VuTrackMacros"),
        .target(name: "VuTrack", dependencies: ["VuTelemetryBootstrap", "VunetDeps", "Vunet", "VuTrackMacros"], path: "Sources/VuTrack"),
        .executableTarget(name: "vutrack-tool", dependencies: [.product(name: "SwiftSyntax", package: "swift-syntax"), .product(name: "SwiftParser", package: "swift-syntax")], path: "Sources/VuTrackTool"),
        .plugin(name: "VuTrackLint", capability: .buildTool(), dependencies: ["vutrack-tool"], path: "Plugins/VuTrackLint"),
        .plugin(name: "VuTrackTag", capability: .command(intent: .custom(verb: "vutrack-tag", description: "Add @VuTrack and import VuTrack to every SwiftUI view"), permissions: [.writeToPackageDirectory(reason: "Adds @VuTrack and import VuTrack to your SwiftUI views")]), dependencies: ["vutrack-tool"], path: "Plugins/VuTrackTag"),
    ]
)
