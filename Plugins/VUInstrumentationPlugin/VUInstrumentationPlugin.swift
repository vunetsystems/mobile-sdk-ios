import PackagePlugin

/// Plugin that automatically instruments SwiftUI Button views at compile time.
/// 
/// For each Swift source file in the target:
/// 1. Runs VuSourceInstrumenter to analyze Button calls
/// 2. Generates a +VuTracked.swift extension file with button metadata
/// 3. Both files compile together — zero conflicts
///
/// **Note**: This is a BuildToolPlugin for Swift Package Manager.
/// For Xcode projects (.xcodeproj), add a Build Phase Run Script instead.
/// See README.md for setup instructions.
@main
struct VuInstrumentationPlugin: BuildToolPlugin {

    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else {
            return []
        }

        let tool = try context.tool(named: "VuSourceInstrumenter")
        var commands: [Command] = []
        let targetRoot = target.directoryURL.path + "/"

        for sourceFile in target.sourceFiles(withSuffix: ".swift") {
            let url = sourceFile.url
            let relativePath = url.path.hasPrefix(targetRoot)
                ? String(url.path.dropFirst(targetRoot.count))
                : url.lastPathComponent
            let sanitizedPath = relativePath
                .replacingOccurrences(of: "/", with: "__")
                .replacingOccurrences(of: ".swift", with: "")

            // Output names include relative path to avoid collisions across folders.
            let outputURL = context.pluginWorkDirectoryURL
                .appendingPathComponent("\(sanitizedPath)+VuTracked.swift")

            commands.append(
                .buildCommand(
                    displayName: "VUInstrument: \(relativePath)",
                    executable: tool.url,
                    arguments: [
                        "--input",  url.path,
                        "--output", outputURL.path
                    ],
                    inputFiles:  [url],
                    outputFiles: [outputURL]
                )
            )
        }
        return commands
    }
}
