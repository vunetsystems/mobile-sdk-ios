import Foundation
import SwiftParser
import SwiftSyntax

// vutrack-tool tag  <dir|file>...            one-time setup: add `@VuTrack` (+ `import VuTrack`) to every SwiftUI view
// vutrack-tool untag <dir|file>...          removal: delete every `@VuTrack` and `import VuTrack` (reverses `tag`)
// vutrack-tool check <file>... [--stamp f]   read-only: warn about SwiftUI views without `@VuTrack` (used by the build plugin)
//
// A view is skipped by both commands when its doc/leading comment contains `vutrack:ignore`.

struct UntaggedView {
    let name: String
    let line: Int
    let column: Int
    let offset: Int   // UTF-8 offset of the declaration's first token (where `@VuTrack` goes)
}

func conformsToView(_ clause: InheritanceClauseSyntax?) -> Bool {
    clause?.inheritedTypes.contains {
        let t = $0.type.trimmedDescription
        return t == "View" || t == "SwiftUI.View"
    } ?? false
}

/// `Outer.Inner` -> `Inner`, so an extension of a nested type matches the struct's own name.
func simpleName(_ type: String) -> String { String(type.split(separator: ".").last ?? Substring(type)) }

/// Pass 1: every type that is a SwiftUI view, whether the conformance is on the struct or in an extension
/// (possibly in another file).
final class ViewTypeCollector: SyntaxVisitor {
    var names: Set<String> = []
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if conformsToView(node.inheritanceClause) { names.insert(node.name.text) }
        return .visitChildren
    }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        if conformsToView(node.inheritanceClause) { names.insert(simpleName(node.extendedType.trimmedDescription)) }
        return .visitChildren
    }
}

/// Pass 2: declarations of those types that hold view code and have no `@VuTrack`:
/// the struct itself, and any extension of it that has a computed property or function.
final class ViewFinder: SyntaxVisitor {
    let converter: SourceLocationConverter
    let viewTypes: Set<String>
    var untagged: [UntaggedView] = []

    init(file: SourceFileSyntax, path: String, viewTypes: Set<String>) {
        converter = SourceLocationConverter(fileName: path, tree: file)
        self.viewTypes = viewTypes
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if viewTypes.contains(node.name.text) { consider(node, name: node.name.text, attributes: node.attributes) }
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = simpleName(node.extendedType.trimmedDescription)
        let hasCode = node.memberBlock.members.contains {
            $0.decl.is(FunctionDeclSyntax.self) || $0.decl.as(VariableDeclSyntax.self)?.bindings.first?.accessorBlock != nil
        }
        if viewTypes.contains(name) && hasCode { consider(node, name: "extension \(name)", attributes: node.attributes) }
        return .visitChildren
    }

    private func consider(_ node: some SyntaxProtocol, name: String, attributes: AttributeListSyntax) {
        let tagged = attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "VuTrack" }
        guard !tagged, !node.leadingTrivia.description.contains("vutrack:ignore") else { return }
        let pos = node.positionAfterSkippingLeadingTrivia
        let loc = converter.location(for: pos)
        untagged.append(UntaggedView(name: name, line: loc.line, column: loc.column, offset: pos.utf8Offset))
    }
}

func parse(_ path: String) -> SourceFileSyntax? {
    (try? String(contentsOfFile: path, encoding: .utf8)).map { Parser.parse(source: $0) }
}

func viewTypes(in paths: [String]) -> Set<String> {
    let collector = ViewTypeCollector(viewMode: .sourceAccurate)
    for path in paths { if let file = parse(path) { collector.walk(file) } }
    return collector.names
}

func untaggedViews(in path: String, viewTypes: Set<String>) -> (SourceFileSyntax, [UntaggedView])? {
    guard let file = parse(path) else { return nil }
    let finder = ViewFinder(file: file, path: path, viewTypes: viewTypes)
    finder.walk(file)
    return (file, finder.untagged)
}

func swiftFiles(_ roots: [String]) -> [String] {
    roots.flatMap { root -> [String] in
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return root.hasSuffix(".swift") ? [root] : [] }
        let skip: Set<String> = [".build", "DerivedData", "Pods", ".git", "Tests"]
        let walker = FileManager.default.enumerator(atPath: root)
        var out: [String] = []
        while let rel = walker?.nextObject() as? String {
            if rel.split(separator: "/").contains(where: { skip.contains(String($0)) }) { continue }
            if rel.hasSuffix(".swift") { out.append((root as NSString).appendingPathComponent(rel)) }
        }
        return out.sorted()
    }
}

/// Inserts `@VuTrack` before each untagged view and `import VuTrack` after the last top-level import.
func tag(_ path: String, viewTypes: Set<String>) throws -> Int {
    guard let (file, views) = untaggedViews(in: path, viewTypes: viewTypes), !views.isEmpty else { return 0 }
    var bytes = Array(file.description.utf8)

    // Bottom-up so earlier offsets stay valid.
    for view in views.sorted(by: { $0.offset > $1.offset }) {
        var lineStart = view.offset
        while lineStart > 0 && bytes[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
        let indent = bytes[lineStart..<view.offset]
        bytes.insert(contentsOf: Array("@VuTrack\n".utf8) + indent, at: view.offset)
    }

    let imports = file.statements.compactMap { $0.item.as(ImportDeclSyntax.self) }
    if !imports.contains(where: { $0.path.trimmedDescription == "VuTrack" }) {
        let at = imports.last.map { $0.endPositionBeforeTrailingTrivia.utf8Offset } ?? 0
        let text = imports.isEmpty ? "import VuTrack\n" : "\nimport VuTrack"
        bytes.insert(contentsOf: Array(text.utf8), at: at)
    }

    let tmp = path + ".vutrack-tmp"
    try Data(bytes).write(to: URL(fileURLWithPath: tmp))
    _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    return views.count
}

/// Removes each `@VuTrack` attribute (with the line break and indent after it) and each `import VuTrack` line,
/// leaving every other byte as it was, so `untag` after `tag` restores the original file exactly.
func untag(_ path: String) throws -> Int {
    guard let file = parse(path) else { return 0 }
    final class Finder: SyntaxVisitor {
        var ranges: [Range<Int>] = []
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes; super.init(viewMode: .sourceAccurate) }

        override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
            guard node.attributeName.trimmedDescription == "VuTrack" else { return .skipChildren }
            var end = node.endPositionBeforeTrailingTrivia.utf8Offset
            while end < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\t")].contains(bytes[end]) { end += 1 }
            if end < bytes.count, bytes[end] == UInt8(ascii: "\n") {
                end += 1
                while end < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\t")].contains(bytes[end]) { end += 1 }
            }
            ranges.append(node.positionAfterSkippingLeadingTrivia.utf8Offset..<end)
            return .skipChildren
        }

        override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.path.trimmedDescription == "VuTrack" else { return .skipChildren }
            var start = node.positionAfterSkippingLeadingTrivia.utf8Offset
            while start > 0, bytes[start - 1] != UInt8(ascii: "\n") { start -= 1 }
            var end = node.endPositionBeforeTrailingTrivia.utf8Offset
            while end < bytes.count, bytes[end] != UInt8(ascii: "\n") { end += 1 }
            ranges.append(start..<min(end + 1, bytes.count))
            return .skipChildren
        }
    }
    var bytes = Array(file.description.utf8)
    let finder = Finder(bytes)
    finder.walk(file)
    guard !finder.ranges.isEmpty else { return 0 }
    for range in finder.ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) { bytes.removeSubrange(range) }

    let tmp = path + ".vutrack-tmp"
    try Data(bytes).write(to: URL(fileURLWithPath: tmp))
    _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    return finder.ranges.count
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["tag", "untag", "check"].contains(command) else {
    FileHandle.standardError.write(Data("usage: vutrack-tool tag|untag <dir|file>... | vutrack-tool check <file>... [--stamp <file>]\n".utf8))
    exit(64)
}
args.removeFirst()
var stamp: String?
if let i = args.firstIndex(of: "--stamp"), i + 1 < args.count {
    stamp = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

// Pass 1 over all files first: a type's View conformance may be declared in a different file.
let files = swiftFiles(args)
let types = viewTypes(in: files)

switch command {
case "tag":
    var total = 0
    for path in files {
        let n = try tag(path, viewTypes: types)
        if n > 0 { print("tagged \(n) view(s) in \(path)") }
        total += n
    }
    print("vutrack: tagged \(total) view(s). Review the diff and commit it.")

case "untag":
    var total = 0
    for path in files {
        let n = try untag(path)
        if n > 0 { print("removed \(n) line(s) in \(path)") }
        total += n
    }
    print("""
        vutrack: removed \(total) @VuTrack / import VuTrack line(s). Review the diff and commit it.
        To finish: remove the VuTrack product (and the VuTrackLint plugin, if added) from your target in Xcode.
        A file that used Vunet APIs only through `import VuTrack` now needs `import Vunet`; the build will say which.
        """)

default: // check: never writes to source files
    var total = 0
    for path in files {
        for v in untaggedViews(in: path, viewTypes: types)?.1 ?? [] {
            print("\(path):\(v.line):\(v.column): warning: [VuTrack] SwiftUI view '\(v.name)' has no @VuTrack, so its taps are not tracked. Add @VuTrack, run the VuTrackTag plugin (or 'swift package vutrack-tag'), or mark it '// vutrack:ignore'.")
            total += 1
        }
    }
    if let stamp { try "\(total)\n".write(toFile: stamp, atomically: true, encoding: .utf8) }
}
