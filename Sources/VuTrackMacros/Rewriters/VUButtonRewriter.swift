// Copied verbatim from Tools/VUSourceInstrumenterCore/VUButtonRewriter.swift on feature/instrumentor-production-hardening (fa6d6f8).
import SwiftSyntax
import SwiftSyntaxBuilder
import Foundation

/// SyntaxRewriter that visits FunctionCallExprSyntax nodes,
/// identifies SwiftUI Button calls, extracts their label text,
/// and injects a registration call directly into the Button's action closure.
final class VUButtonRewriter: SyntaxRewriter {

    /// Count of buttons successfully instrumented in this file.
    private(set) var instrumentedCount = 0
    private(set) var injectedCount = 0

    /// Name of the file being rewritten; a secure-entry looking name (`PinEntryView.swift`) opts the whole file out.
    var fileName: String = ""

    /// Default built-in button wrappers that are always recognized.
    private static let defaultButtonWrappers: Set<String> = [
        "Button",
        "BFSIButton",
        "CardActionRow",
    ]

    /// Known button wrappers (defaults + custom from config).
    private let knownButtonWrappers: Set<String>

    /// Every call name treated as a button (built-ins plus `VuCustomButtonWrappers`), for the command's pre-filter.
    var wrapperNames: Set<String> { knownButtonWrappers }

    // MARK: - Initialization

    init(customWrappers: Set<String>? = nil) {
        // Start with defaults
        var wrappers = Self.defaultButtonWrappers
        
        // Add custom wrappers if provided
        if let custom = customWrappers {
            wrappers.formUnion(custom)
        }
        
        self.knownButtonWrappers = wrappers
    }

    /// Initializes with button wrappers loaded from Info.plist.
    /// Looks for "VuCustomButtonWrappers" array key in Info.plist (e.g., in project or derived sources root).
    /// Format in Info.plist:
    /// ```
    /// <key>VuCustomButtonWrappers</key>
    /// <array>
    ///   <string>CustomButton</string>
    ///   <string>MyButton</string>
    /// </array>
    /// ```
    init?(infoPlistPath: String) {
        guard let plist = Self.loadInfoPlist(infoPlistPath) else {
            // Fallback to defaults if plist doesn't exist
            self.knownButtonWrappers = Self.defaultButtonWrappers
            return
        }
        
        var wrappers = Self.defaultButtonWrappers
        if let customWrappers = plist["VuCustomButtonWrappers"] as? [String] {
            print("[VUButtonRewriter] Loaded \(customWrappers.count) custom button wrappers from Info.plist")
            print("[VUButtonRewriter] Custom wrappers: \(customWrappers.joined(separator: ", "))")
            wrappers.formUnion(customWrappers)
        }
        self.knownButtonWrappers = wrappers
    }

    // MARK: - Configuration Loading

    private static func loadInfoPlist(_ path: String) -> [String: Any]? {
        let fm = FileManager.default
        
        // If path is a directory, look for Info.plist inside
        var infoPlistPath = path
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            infoPlistPath = (path as NSString).appendingPathComponent("Info.plist")
        }
        
        guard fm.fileExists(atPath: infoPlistPath) else {
            return nil
        }

        do {
            guard let data = fm.contents(atPath: infoPlistPath) else {
                print("[VUButtonRewriter] Could not read Info.plist at \(infoPlistPath)")
                return nil
            }
            
            if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                return plist
            }
        } catch {
            print("[VUButtonRewriter] Failed to parse Info.plist: \(error)")
        }
        
        return nil
    }

    // MARK: - Visitor

    /// Types this file declares itself. A file-local `Button` is not SwiftUI's, so plain `Button(...)` calls are left
    /// alone. (Same-file detection only: a `Button` declared in another file of the module is not seen.)
    private var shadowedNames: Set<String> = []

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        shadowedNames = VUDeclaredTypeScanner.declaredTypeNames(in: node)
        return super.visit(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        // Gate 1: Check if this is a SwiftUI Button call
        guard isButtonCall(node) else {
            return super.visit(node)
        }

        // Recurse first to process any nested button expressions inside this node (e.g. nested in closures)
        let visited = super.visit(node)
        guard let call = visited.as(FunctionCallExprSyntax.self) else {
            return visited
        }

        // Gate 2: opt-out marker and idempotency / manual-instrumentation safeguard.
        // Inspections use the ORIGINAL node (`node`): the visited copy has no parent chain (needed for modifier
        // lookup) and may already contain rewritten nested buttons.
        if node.leadingTrivia.description.contains("VU:skip") {
            return ExprSyntax(call)
        }
        if hasInstrumentedAction(node) {
            return ExprSyntax(call)
        }

        // Gate 3: privacy. Never label a button of a secure-entry screen (OTP / PIN / passcode / keypad), whatever
        // its label resolves to: the label would be the entered value.
        if Self.isSecureEntryContext(node, fileName: fileName) {
            return ExprSyntax(call)
        }

        // Gate 4: build the registerPress statement from the resolved label.
        let registerCallStr: String
        switch VULabelExtractor.resolveButtonLabel(for: node) {
        case .literal(let labelText)?:
            // A digit or a single character is almost always a keypad / value key, not an action name.
            if Self.isValueLikeLabel(labelText) { return ExprSyntax(call) }
            registerCallStr = "VuButtonPressRegistry.shared.registerPress(label: \"\(Self.escape(labelText))\"); "
        case .expression(let expr)?:
            if Self.isValueLikeExpression(expr) || Self.containsSecureWord(expr) { return ExprSyntax(call) }
            registerCallStr = "VuButtonPressRegistry.shared.registerPress(label: String(describing: \(expr))); "
        case nil:
            if ProcessInfo.processInfo.environment["VU_DEBUG"] != nil {
                let callStr = call.description.prefix(150).replacingOccurrences(of: "\n", with: " ")
                print("[VUButtonRewriter] Skipped: no static/dynamic label found for: \(callStr)")
            }
            return ExprSyntax(call)
        }

        // Rewrite the action block/closure of this Button call
        let result = rewriteButtonAction(call, registerCallStr: registerCallStr)
        guard result.description != call.description else {
            return ExprSyntax(call)
        }

        instrumentedCount += 1
        injectedCount += 1
        return ExprSyntax(result)
    }

    // MARK: - Privacy helpers

    /// Words that mark a secure-entry type / file / identifier. Matched as whole camelCase / snake_case words, so
    /// `PinEntryView` and `otp_field` match but `Spinner` / `shopping` do not.
    static let secureWords: Set<String> = ["otp", "pin", "pins", "passcode", "password", "passwords", "mpin", "keypad", "passcodes"]

    static func words(in identifier: String) -> [String] {
        var words: [String] = []
        var current = ""
        let chars = Array(identifier)
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()); current = "" }
                continue
            }
            let startsNewWord = ch.isUppercase && !current.isEmpty
                && (!(chars[i - 1].isUppercase) || (i + 1 < chars.count && chars[i + 1].isLowercase))
            if startsNewWord { words.append(current.lowercased()); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
    }

    static func containsSecureWord(_ identifier: String) -> Bool {
        words(in: identifier).contains { secureWords.contains($0) }
    }

    /// True when the file name, an enclosing type, or an enclosing named declaration (func / property) looks like
    /// secure entry.
    static func isSecureEntryContext(_ node: some SyntaxProtocol, fileName: String) -> Bool {
        if containsSecureWord((fileName as NSString).deletingPathExtension) { return true }
        var current = Syntax(node).parent
        while let ancestor = current {
            if let d = ancestor.as(StructDeclSyntax.self), containsSecureWord(d.name.text) { return true }
            if let d = ancestor.as(ClassDeclSyntax.self), containsSecureWord(d.name.text) { return true }
            if let d = ancestor.as(EnumDeclSyntax.self), containsSecureWord(d.name.text) { return true }
            if let d = ancestor.as(ExtensionDeclSyntax.self), containsSecureWord(d.extendedType.trimmedDescription) { return true }
            if let d = ancestor.as(FunctionDeclSyntax.self), containsSecureWord(d.name.text) { return true }
            if let d = ancestor.as(PatternBindingSyntax.self),
               let id = d.pattern.as(IdentifierPatternSyntax.self), containsSecureWord(id.identifier.text) { return true }
            current = ancestor.parent
        }
        return false
    }

    /// Purely numeric (digits, separators, signs) or a single character: a value key, not an action name.
    static func isValueLikeLabel(_ label: String) -> Bool {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= 1 { return true }
        return t.allSatisfy { $0.isNumber || ".,:-+%/ ".contains($0) }
    }

    /// A dynamic label that is itself a numeric / single-character literal.
    static func isValueLikeExpression(_ expr: String) -> Bool {
        let t = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            let inner = String(t.dropFirst().dropLast())
            return !inner.contains("\\(") && isValueLikeLabel(inner)
        }
        return Double(t) != nil
    }

    // MARK: - Helpers

    private static func escape(_ label: String) -> String {
        label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True for `Button` / `SwiftUI.Button` and names configured in `VuCustomButtonWrappers` (or the built-in list).
    private func isKnownWrapper(_ call: FunctionCallExprSyntax) -> Bool {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            if ref.baseName.text == "Button", shadowedNames.contains("Button") { return false }
            return knownButtonWrappers.contains(ref.baseName.text)
        }
        if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
           memberAccess.declName.baseName.text == "Button",
           let baseRef = memberAccess.base?.as(DeclReferenceExprSyntax.self),
           baseRef.baseName.text == "SwiftUI" {
            return true
        }
        return false
    }

    private func isPlainSwiftUIButton(_ call: FunctionCallExprSyntax) -> Bool {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) { return ref.baseName.text == "Button" }
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self) { return m.declName.baseName.text == "Button" }
        return false
    }

    /// Returns true if this function call is a SwiftUI Button initializer, a configured/known wrapper, or (structural
    /// fallback) a call with a CLOSURE `action:` argument plus a `title:`/`label:` argument.
    /// The fallback deliberately requires a closure so that UIKit APIs such as
    /// `UIBarButtonItem(title:, style:, target:, action: #selector(...))` are never treated as SwiftUI wrappers.
    private func isButtonCall(_ call: FunctionCallExprSyntax) -> Bool {
        if isKnownWrapper(call) { return true }

        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self), ref.baseName.text == "Button",
           shadowedNames.contains("Button") { return false }
        guard let action = call.arguments.first(where: { $0.label?.text == "action" }),
              action.expression.is(ClosureExprSyntax.self) else { return false }
        let argLabels = Set(call.arguments.compactMap { $0.label?.text })
        return argLabels.contains("title") || argLabels.contains("label")
    }

    /// Names/members that mean the action already reports the tap through the SDK (manual instrumentation or a
    /// previous run of this tool). Instrumenting on top would emit a second span / duplicate registration.
    private static let sdkTypeNames: Set<String> = [
        "Vunet", "VuButtonPressRegistry", "VUButtonPressRegistry", "VuTelemetry", "vuTelemetry",
    ]
    private static let sdkMemberNames: Set<String> = [
        "registerPress", "recordClickEvent", "recordEvent", "recordError",
    ]

    /// True when the action closure (or trailing closure) already calls an SDK API such as
    /// `Vunet.recordClickEvent` / `VuButtonPressRegistry.shared.registerPress`.
    private func hasInstrumentedAction(_ call: FunctionCallExprSyntax) -> Bool {
        guard let action = actionNode(of: call) else { return false }
        final class Finder: SyntaxVisitor {
            var found = false
            override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
                let n = node.baseName.text
                if VUButtonRewriter.sdkTypeNames.contains(n) || VUButtonRewriter.sdkMemberNames.contains(n) {
                    found = true
                }
                return .visitChildren
            }
        }
        let finder = Finder(viewMode: .sourceAccurate)
        finder.walk(action)
        return finder.found
    }

    /// The syntax of the button's action: the `action:` argument expression, else the primary trailing closure.
    private func actionNode(of call: FunctionCallExprSyntax) -> Syntax? {
        if let arg = call.arguments.first(where: { $0.label?.text == "action" }) { return Syntax(arg.expression) }
        if let trailing = call.trailingClosure { return Syntax(trailing) }
        return nil
    }

    /// A plain reference to a function/method: `save`, `self.save`, `vm.save`. No call, no implicit member, no
    /// argument labels (`save(_:)`), no optional chaining.
    private func isSimpleReference(_ expr: ExprSyntax) -> Bool {
        if let ref = expr.as(DeclReferenceExprSyntax.self) { return ref.argumentNames == nil && !ref.baseName.text.hasPrefix("$") }
        if let m = expr.as(MemberAccessExprSyntax.self), let base = m.base, m.declName.argumentNames == nil {
            return isSimpleReference(base)
        }
        return false
    }

    private func prepending(_ registerCallStr: String, to closure: ClosureExprSyntax) -> ClosureExprSyntax {
        var modified = closure
        var statements = Array(modified.statements)
        var inserted = CodeBlockItemSyntax(stringLiteral: registerCallStr)
        // `{ // tap` / `{ [vm] in // tap`: a line comment ends the line, so the statement must start on a new one or
        // it would be swallowed by the comment (and re-added on every run).
        let opener: Trivia = closure.signature?.trailingTrivia ?? closure.leftBrace.trailingTrivia
        if opener.contains(where: { if case .lineComment = $0 { return true }; if case .docLineComment = $0 { return true }; return false }) {
            inserted = inserted.with(\.leadingTrivia, .newline)
        }
        statements.insert(inserted, at: 0)
        modified.statements = CodeBlockItemListSyntax(statements)
        return modified
    }

    /// Rewrites the Button's action argument or trailing closure to inject the registration call.
    /// Anything that is not a recognised shape is returned unchanged.
    private func rewriteButtonAction(_ call: FunctionCallExprSyntax, registerCallStr: String) -> FunctionCallExprSyntax {
        var newArgs = Array(call.arguments)

        // `action:` argument present
        if let actionIndex = newArgs.firstIndex(where: { $0.label?.text == "action" }) {
            let originalArg = newArgs[actionIndex]
            let originalExpr = originalArg.expression

            let newExpr: ExprSyntax
            if let closure = originalExpr.as(ClosureExprSyntax.self) {
                newExpr = ExprSyntax(prepending(registerCallStr, to: closure))
            } else if isPlainSwiftUIButton(call), isSimpleReference(originalExpr) {
                // SwiftUI.Button's action is `() -> Void` (non-throwing, non-async), so `ref()` is valid exactly
                // when the original `action: ref` was. Wrappers have unknown action types, so they are skipped.
                let core = originalExpr.with(\.leadingTrivia, []).with(\.trailingTrivia, [])
                newExpr = ExprSyntax(stringLiteral: "{ \(registerCallStr)\(core.description)() }")
                    .with(\.leadingTrivia, originalExpr.leadingTrivia)
                    .with(\.trailingTrivia, originalExpr.trailingTrivia)
            } else {
                return call
            }

            // Mutate only the expression so the label, colon AND trailing comma are preserved (B2).
            newArgs[actionIndex] = originalArg.with(\.expression, newExpr)
            return call.with(\.arguments, LabeledExprListSyntax(newArgs))
        }

        // No `action:` argument: the primary trailing closure is the action.
        if let trailingClosure = call.trailingClosure {
            return call.with(\.trailingClosure, prepending(registerCallStr, to: trailingClosure))
        }

        return call
    }
}
