import Foundation
import PackagePlugin

/// Command plugin: runs `vutrack-tool tag` on the app's own sources, so a customer who adds the package in Xcode can
/// tag every SwiftUI view without a clone of this repo or a `swift` on PATH.
/// Xcode: right-click the project ▸ VuTrackTag.
/// Terminal (Swift packages): `swift package --allow-writing-to-package-directory vutrack-tag [--target <name>]`.
/// With no target chosen it tags every target; each run asks for permission to write to the source files.
@main
struct VuTrackTag: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        var extractor = ArgumentExtractor(arguments)
        let names = Set(extractor.extractOption(named: "target"))
        let paths = context.package.targets
            .compactMap { $0 as? SourceModuleTarget }
            .filter { $0.kind != .test && (names.isEmpty || names.contains($0.name)) }
            .map(\.directoryURL.path)
        try runTag(tool: context.tool(named: "vutrack-tool").url, paths: paths)
    }
}

func runTag(tool: URL, paths: [String]) throws {
    guard !paths.isEmpty else {
        Diagnostics.warning("VuTrack: no Swift sources to tag in the chosen targets")
        return
    }
    let process = Process()
    process.executableURL = tool
    process.arguments = ["tag"] + paths
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        Diagnostics.error("vutrack-tool tag failed with exit code \(process.terminationStatus)")
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension VuTrackTag: XcodeCommandPlugin {
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
        var extractor = ArgumentExtractor(arguments)
        let names = Set(extractor.extractOption(named: "target"))
        // One run over every chosen file: a view's `View` conformance may be declared in another file.
        let paths = context.xcodeProject.targets
            .filter { names.isEmpty || names.contains($0.displayName) }
            .flatMap { $0.inputFiles.filter { $0.type == .source && $0.url.pathExtension == "swift" }.map(\.url.path) }
        try runTag(tool: context.tool(named: "vutrack-tool").url, paths: paths)
    }
}
#endif
