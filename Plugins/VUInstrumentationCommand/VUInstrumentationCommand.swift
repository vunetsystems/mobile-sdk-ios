import Foundation
import PackagePlugin

@main
struct VUInstrumentationCommand: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let invocation = try Invocation.parse(arguments: arguments)
        let tool = try context.tool(named: "VUSourceInstrumenter")

        guard let projectPath = invocation.projectPath else {
            Diagnostics.error("Missing --project <path>. Example: --project /path/to/YourApp.xcodeproj")
            throw PluginError.invalidArguments
        }

        let result = try runTool(toolPath: tool.url.path, invocation: invocation, projectPath: projectPath)
        emitDiagnostics(result)

        guard result.exitCode == 0 else {
            throw PluginError.toolFailed(code: result.exitCode)
        }
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension VUInstrumentationCommand: XcodeCommandPlugin {
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
        let invocation = try Invocation.parse(arguments: arguments)
        let tool = try context.tool(named: "VUSourceInstrumenter")

        // Xcode passes the active project context when command is launched from the navigator.
        // directoryURL is the containing folder; the .xcodeproj lives at <dir>/<displayName>.xcodeproj
        let xcodeProjPath = context.xcodeProject.directoryURL
            .appendingPathComponent("\(context.xcodeProject.displayName).xcodeproj").path
        let projectPath = invocation.projectPath ?? xcodeProjPath

        let result = try runTool(toolPath: tool.url.path, invocation: invocation, projectPath: projectPath)
        emitDiagnostics(result)

        guard result.exitCode == 0 else {
            throw PluginError.toolFailed(code: result.exitCode)
        }
    }
}
#endif

private struct Invocation {
    enum Action: String {
        case install
        case verify
        case uninstall
    }

    let action: Action
    let projectPath: String?
    let targetName: String?

    static func parse(arguments: [String]) throws -> Invocation {
        var args = arguments
        var action: Action = .install

        if let first = args.first, let parsed = Action(rawValue: first) {
            action = parsed
            args.removeFirst()
        }

        var projectPath: String?
        var targetName: String?
        var i = 0

        while i < args.count {
            let token = args[i]
            switch token {
            case "--project":
                i += 1
                guard i < args.count else { throw PluginError.invalidArguments }
                projectPath = args[i]
            case "--target":
                i += 1
                guard i < args.count else { throw PluginError.invalidArguments }
                targetName = args[i]
            default:
                throw PluginError.invalidArguments
            }
            i += 1
        }

        return Invocation(action: action, projectPath: projectPath, targetName: targetName)
    }
}

private struct ToolResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private enum PluginError: LocalizedError {
    case invalidArguments
    case toolFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Invalid arguments. Usage: [install|verify|uninstall] [--project <path>] [--target <name>]"
        case .toolFailed(let code):
            return "VUSourceInstrumenter exited with status \(code)."
        }
    }
}

private func runTool(toolPath: String, invocation: Invocation, projectPath: String) throws -> ToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: toolPath)

    var toolArguments = [invocation.action.rawValue, "--project", projectPath]
    if let targetName = invocation.targetName, !targetName.isEmpty {
        toolArguments.append(contentsOf: ["--target", targetName])
    }
    process.arguments = toolArguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    return ToolResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func emitDiagnostics(_ result: ToolResult) {
    let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stdout.isEmpty {
        Diagnostics.remark(stdout)
    }

    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stderr.isEmpty {
        Diagnostics.warning(stderr)
    }
}
