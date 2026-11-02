// Copied verbatim from Tools/VUSourceInstrumenterCore/VUDatePickerRewriter.swift on feature/instrumentor-production-hardening (fa6d6f8).
// VUDeclaredTypeScanner, defined at the end of that file, lives in VUDeclaredTypeScanner.swift here.
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftParser
import Foundation

/// SyntaxRewriter that visits FunctionCallExprSyntax nodes,
/// identifies SwiftUI DatePicker and MultiDatePicker calls,
/// extracts their configuration and bindings, and appends
/// the corresponding Vunet instrumented view modifiers.
///
/// Only SwiftUI's own `DatePicker` / `MultiDatePicker` are touched (bare or `SwiftUI.`-qualified; a file that
/// declares its own type with that name is skipped). The selection binding is re-used verbatim for the modifier, so
/// it must be a side-effect-free path (`$date`, `$vm.date`, `vm.$date`, `Binding(get:set:)`); anything else is left
/// untouched. `MultiDatePicker` makes no guess about Set-vs-Range selection: the SDK overloads
/// `instrumentedMultiDatePicker(selection:)` are resolved by the compiler from the binding type.
final class VUDatePickerRewriter: SyntaxRewriter {

    // MARK: - Counters

    private(set) var datePickerCount = 0
    private(set) var multiDatePickerCount = 0

    var injectedCount: Int {
        datePickerCount + multiDatePickerCount
    }

    // MARK: - Visitor

    /// Names of types this file declares itself; a local `DatePicker` shadows SwiftUI's.
    private var shadowedNames: Set<String> = []

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        shadowedNames = VUDeclaredTypeScanner.declaredTypeNames(in: node)
        return super.visit(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        // Idempotency / parent checks need the original node (rewritten nodes are detached from the tree).
        let alreadyInstrumented = isAlreadyInstrumented(node)
        let usedAsTypedValue = isTypedBindingInitializer(node)
        // Recurse first (bottom-up) so nested patterns are processed before outer ones
        let visited = super.visit(node)
        guard let call = visited.as(FunctionCallExprSyntax.self) else {
            return visited
        }

        guard let callee = swiftUICalleeName(call), !shadowedNames.contains(callee),
              !alreadyInstrumented, !usedAsTypedValue else {
            return ExprSyntax(call)
        }

        switch callee {
        case "DatePicker":
            return rewriteDatePicker(call)
        case "MultiDatePicker":
            return rewriteMultiDatePicker(call)
        default:
            return ExprSyntax(call)
        }
    }

    // MARK: - DatePicker Rewriting (Single Selection)

    private func rewriteDatePicker(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        // Must have a side-effect-free selection binding argument (re-used verbatim by the modifier)
        guard let selectionArg = call.arguments.first(where: { $0.label?.text == "selection" }),
              isStableBindingExpr(selectionArg.expression) else {
            return ExprSyntax(call)
        }

        let selectionExpr = selectionArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateFormat = inferDateFormat(from: call)
        let bounds = extractRangeBounds(from: call)

        var configArgs: [String] = []
        configArgs.append("dateFormat: \"\(dateFormat)\"")
        if let minExpr = bounds.minExpr, isSimpleDateExpr(minExpr) {
            configArgs.append("minDate: \(minExpr)")
        }
        if let maxExpr = bounds.maxExpr, isSimpleDateExpr(maxExpr) {
            configArgs.append("maxDate: \(maxExpr)")
        }
        
        let rawLabel = VULabelExtractor.extract(from: call)
        let labelStr = toSnakeCase(rawLabel ?? selectionExpr)
        configArgs.append("label: \"\(labelStr)\"")

        let configExpr = "DatePickerInstrumentationConfig(\(configArgs.joined(separator: ", ")))"
        let modifierCall = ".instrumentedDatePicker(selection: \(selectionExpr), config: \(configExpr))"

        let wrappedSource = "(__placeholder__)\(modifierCall)"
        let tempSource = Parser.parse(source: wrappedSource)
        guard let chainedExpr = tempSource.statements.first?.item.as(ExprSyntax.self),
              let chainedCall = chainedExpr.as(FunctionCallExprSyntax.self),
              let memberAccess = chainedCall.calledExpression.as(MemberAccessExprSyntax.self) else {
            return ExprSyntax(call)
        }

        let newChained = chainedCall
            .with(\.calledExpression, ExprSyntax(
                memberAccess.with(\.base, ExprSyntax(call))
            ))

        datePickerCount += 1
        return ExprSyntax(newChained)
    }

    // MARK: - MultiDatePicker Rewriting (Multiple/Range Selection)

    private func rewriteMultiDatePicker(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        guard let selectionArg = call.arguments.first(where: { $0.label?.text == "selection" }),
              isStableBindingExpr(selectionArg.expression) else {
            return ExprSyntax(call)
        }

        let selectionExpr = selectionArg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLabel = VULabelExtractor.extract(from: call)
        let labelStr = toSnakeCase(rawLabel ?? selectionExpr)

        // No mode / blocked-dates guessing: the SDK exposes `Binding<Set<DateComponents>>` and
        // `Binding<Range<Date>>` overloads that the compiler picks from the binding's type.
        let configExpr = "DatePickerInstrumentationConfig(label: \"\(labelStr)\")"
        let modifierCall = ".instrumentedMultiDatePicker(selection: \(selectionExpr), config: \(configExpr))"

        let wrappedSource = "(__placeholder__)\(modifierCall)"
        let tempSource = Parser.parse(source: wrappedSource)
        guard let chainedExpr = tempSource.statements.first?.item.as(ExprSyntax.self),
              let chainedCall = chainedExpr.as(FunctionCallExprSyntax.self),
              let memberAccess = chainedCall.calledExpression.as(MemberAccessExprSyntax.self) else {
            return ExprSyntax(call)
        }

        let newChained = chainedCall
            .with(\.calledExpression, ExprSyntax(
                memberAccess.with(\.base, ExprSyntax(call))
            ))

        multiDatePickerCount += 1
        return ExprSyntax(newChained)
    }

    // MARK: - Heuristics & Parsing Helpers

    /// `DatePicker` / `SwiftUI.DatePicker` -> "DatePicker"; any other callee (`Foo.DatePicker`, `x.datePicker`) -> nil.
    private func swiftUICalleeName(_ call: FunctionCallExprSyntax) -> String? {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return ref.baseName.text
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "SwiftUI" {
            return member.declName.baseName.text
        }
        return nil
    }

    /// True when `node` is already the direct base of `.instrumentedDatePicker` / `.instrumentedMultiDatePicker`.
    /// Looks through `.datePickerStyle(...)`-style modifiers is intentionally not done: the modifier is always
    /// appended directly to the picker call by this tool.
    private func isAlreadyInstrumented(_ node: FunctionCallExprSyntax) -> Bool {
        // The existing modifier is rarely the very next call: `DatePicker(...).font(..).tint(..)
        // .instrumentedDatePicker(...)`. Walk the whole modifier chain above the picker.
        var current: Syntax = Syntax(node)
        while let member = current.parent?.as(MemberAccessExprSyntax.self), member.base?.id == current.id {
            let name = member.declName.baseName.text
            if name == "instrumentedDatePicker" || name == "instrumentedMultiDatePicker" { return true }
            guard let outer = member.parent?.as(FunctionCallExprSyntax.self),
                  outer.calledExpression.id == member.id else { return false }
            current = Syntax(outer)
        }
        return false
    }

    /// `let p: DatePicker<Text> = DatePicker(...)` would stop type-checking once the call returns `some View`.
    private func isTypedBindingInitializer(_ node: FunctionCallExprSyntax) -> Bool {
        guard let initializer = node.parent?.as(InitializerClauseSyntax.self),
              let binding = initializer.parent?.as(PatternBindingSyntax.self) else { return false }
        return binding.typeAnnotation != nil
    }

    /// A binding expression that can be written twice (picker + modifier) without changing behaviour: a
    /// `$name` / member path (optionally `self.`-prefixed, e.g. `$vm.date`, `vm.$date`) or `Binding(get:set:)` built
    /// only from closures. Function calls, subscripts and `.constant(...)` are rejected.
    private func isStableBindingExpr(_ expr: ExprSyntax) -> Bool {
        if expr.is(DeclReferenceExprSyntax.self) { return true }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard let base = member.base else { return false }
            return isStableBindingExpr(base)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Binding",
           call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
           !call.arguments.isEmpty,
           call.arguments.allSatisfy({ $0.expression.is(ClosureExprSyntax.self) }) {
            return true
        }
        return false
    }

    /// A bound that can be copied into the config without extra evaluation side effects.
    private func isSimpleDateExpr(_ expr: String) -> Bool {
        let parsed = Parser.parse(source: expr)
        guard let item = parsed.statements.first?.item.as(ExprSyntax.self), parsed.statements.count == 1 else { return false }
        if item.is(DeclReferenceExprSyntax.self) { return true }
        if let member = item.as(MemberAccessExprSyntax.self) { return isStableBindingExpr(ExprSyntax(member)) || member.base == nil }
        if let call = item.as(FunctionCallExprSyntax.self),
           call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Date",
           call.arguments.isEmpty, call.trailingClosure == nil { return true }
        return false
    }

    private func inferDateFormat(from call: FunctionCallExprSyntax) -> String {
        guard let arg = call.arguments.first(where: { $0.label?.text == "displayedComponents" }) else {
            return "yyyy-MM-dd"
        }
        let val = arg.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
        // Use contains so both `.date` and `[.date]` (array literal form) are handled.
        let hasDate = val.contains(".date")
        let hasTime = val.contains(".hourAndMinute")
        if hasDate && hasTime { return "yyyy-MM-dd HH:mm" }
        if hasTime { return "HH:mm" }
        return "yyyy-MM-dd"
    }

    private func extractRangeBounds(from call: FunctionCallExprSyntax) -> (minExpr: String?, maxExpr: String?) {
        guard let arg = call.arguments.first(where: { $0.label?.text == "in" }) else {
            return (nil, nil)
        }

        let expr = arg.expression

        // Closed/Half-Open Range: minDate...maxDate or minDate..<maxDate
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elements = Array(seq.elements)
            if elements.count == 3,
               let opExpr = elements[1].as(BinaryOperatorExprSyntax.self) {
                let opText = opExpr.operator.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if opText == "..." || opText == "..<" {
                    let minStr = elements[0].description.trimmingCharacters(in: .whitespacesAndNewlines)
                    let maxStr = elements[2].description.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (minStr, maxStr)
                }
            }
        }

        // Postfix Range: minDate...
        if let postfix = expr.as(PostfixOperatorExprSyntax.self) {
            let opText = postfix.operator.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if opText == "..." {
                let minStr = postfix.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return (minStr, nil)
            }
        }

        // Prefix Range: ...maxDate or ..<maxDate
        if let prefix = expr.as(PrefixOperatorExprSyntax.self) {
            let opText = prefix.operator.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if opText == "..." || opText == "..<" {
                let maxStr = prefix.expression.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return (nil, maxStr)
            }
        }

        return (nil, nil)
    }

    private func toSnakeCase(_ str: String) -> String {
        var result = ""
        var lastWasUnderscore = false
        for char in str.trimmingCharacters(in: .whitespacesAndNewlines) {
            if char.isLetter || char.isNumber {
                if char.isUppercase {
                    if !result.isEmpty && !lastWasUnderscore {
                        result += "_"
                    }
                    result += char.lowercased()
                } else {
                    result += String(char)
                }
                lastWasUnderscore = false
            } else if char == " " || char == "-" || char == "_" || char == "$" {
                if !result.isEmpty && !lastWasUnderscore {
                    result += "_"
                    lastWasUnderscore = true
                }
            }
        }
        if result.hasSuffix("_") {
            result = String(result.dropLast())
        }
        if result.hasPrefix("_") {
            result = String(result.dropFirst())
        }
        return result
    }
}

