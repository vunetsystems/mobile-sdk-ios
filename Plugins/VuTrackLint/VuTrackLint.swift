import Foundation
import PackagePlugin

/// Build-tool plugin: warns about SwiftUI views that have no `@VuTrack`.
/// Read-only by construction: SwiftPM/Xcode run plugin commands in a sandbox that cannot write to the
/// package or project sources; the only file written is a stamp in the plugin's own work directory.
@main
struct VuTrackLint: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let files = (target as? SourceModuleTarget)?.sourceFiles(withSuffix: "swift").map(\.url) ?? []
        return try [command(tool: context.tool(named: "vutrack-tool").url, files: files, workDir: context.pluginWorkDirectoryURL)]
    }
}

func command(tool: URL, files: [URL], workDir: URL) -> Command {
    let stamp = workDir.appendingPathComponent("vutrack-check.stamp")
    return .buildCommand(
        displayName: "VuTrack: check SwiftUI views are tagged",
        executable: tool,
        arguments: ["check"] + files.map(\.path) + ["--stamp", stamp.path],
        inputFiles: files,
        outputFiles: [stamp]
    )
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension VuTrackLint: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let files = target.inputFiles.filter { $0.type == .source && $0.url.pathExtension == "swift" }.map(\.url)
        return try [command(tool: context.tool(named: "vutrack-tool").url, files: files, workDir: context.pluginWorkDirectoryURL)]
    }
}
#endif
