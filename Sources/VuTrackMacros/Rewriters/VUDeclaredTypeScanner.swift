import SwiftSyntax

// Copied verbatim from Tools/VUSourceInstrumenterCore/VUDatePickerRewriter.swift on feature/instrumentor-production-hardening (fa6d6f8).
/// Collects the names of types (struct/class/enum/actor/typealias/protocol) declared anywhere in a source file, so
/// rewriters can tell SwiftUI's `DatePicker`/`AsyncImage` apart from a local type of the same name.
enum VUDeclaredTypeScanner {
    static func declaredTypeNames(in file: SourceFileSyntax) -> Set<String> {
        final class Collector: SyntaxVisitor {
            var names: Set<String> = []
            override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
            override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
            override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
            override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
            override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
            override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
        }
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(file)
        return collector.names
    }

    /// Names of functions declared anywhere in the file (a local `func sheet(...)` shadows the SwiftUI modifier).
    static func declaredFunctionNames(in file: SourceFileSyntax) -> Set<String> {
        final class Collector: SyntaxVisitor {
            var names: Set<String> = []
            override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { names.insert(node.name.text); return .visitChildren }
        }
        let collector = Collector(viewMode: .sourceAccurate)
        collector.walk(file)
        return collector.names
    }
}
