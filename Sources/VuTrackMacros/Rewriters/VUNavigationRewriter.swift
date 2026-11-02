// Copied verbatim from Tools/VUSourceInstrumenterCore/VUNavigationRewriter.swift on feature/instrumentor-production-hardening (fa6d6f8).
import SwiftSyntax
import SwiftParser
import Foundation

// MARK: - VUNavigationRewriter

/// SyntaxRewriter that instruments SwiftUI navigation declarations.
///
/// Rewrites (every one is idempotent and compile-safe: a shape with no matching SDK API is left byte-identical):
///
/// 1. `NavigationStack { }` / `NavigationStack(path: $p) { }`
///    -> `TrackedNavigationStack([path: $p, ]rootScreenName: "...") { }`.
///    `NavigationStack(root:)` / `(path:root:)` are left alone (the SDK init takes `rootScreenName` before `root`).
/// 2. `.sheet/.fullScreenCover/.popover/.alert(isPresented:)` -> chains `.trackModal(isPresented:screenName:kind:)`
///    once per modifier (skipped when the sheet content names itself with `.trackScreen`).
/// 3. `NavigationSplitView(columnVisibility: $v) { } detail: { }` -> `TrackedNavigationSplitView(..., sidebarName:)`.
///    Other shapes (no `columnVisibility:`, `content:` column, extra args) are left alone: the SDK type has no such init,
///    and the 3-column SDK type is iOS 17 only.
/// 4. `TabView(selection: $t)` -> chains `.trackTabSelection($t, tabNames: [...])` with tags taken ONLY from the
///    TabView's direct children.
/// 5. `NavigationLink(destination:){ }` / `("T", destination:)` / `("T") { }` -> `TrackedNavigationLink`;
///    `NavigationLink(value:)` is left alone: the coordinator reports the push it triggers, and a tap gesture on it
///    stops the push inside a `List`/`Form` row.
/// 6. `.navigationDestination(for:|isPresented:|item:)` and `.sheet/.fullScreenCover/.popover(item:)` -> the content's
///    root view gets `.vuTrackDestination()` (`isModal: true` for the modals): the SDK names the screen after that
///    view's type at low priority, so a `.trackScreen` inside the view, which this body cannot see, still wins.
///
/// Not instrumented (no SDK tracker): `.confirmationDialog`, `alert(item:)` / `alert(presenting:)`.
///
/// Idempotency: chained modifiers are detected by scanning the whole modifier chain around the construct (both the
/// receiver side and the modifiers applied after it), so hand-written trackers are recognised as well. A
/// `// VU:skip` comment before a construct (or before the `.modifier(` for modals) suppresses it.
final class VUNavigationRewriter: SyntaxRewriter {

    // MARK: - Counters

    private(set) var navigationStackCount = 0
    private(set) var splitViewCount = 0
    private(set) var modalCount = 0
    private(set) var tabViewCount = 0
    private(set) var navigationLinkCount = 0
    private(set) var destinationCount = 0

    var injectedCount: Int {
        navigationStackCount + splitViewCount + modalCount + tabViewCount + navigationLinkCount + destinationCount
    }

    // MARK: - Context

    /// Fallback enclosing type name (first struct/class in the file), used only outside any type declaration.
    var enclosingTypeName: String = ""

    private var typeStack: [String] = []
    private var currentTypeName: String { typeStack.last ?? enclosingTypeName }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { typeStack.removeLast() }
        return super.visit(node)
    }
    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { typeStack.removeLast() }
        return super.visit(node)
    }
    override func visit(_ node: ActorDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { typeStack.removeLast() }
        return super.visit(node)
    }
    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        typeStack.append(node.name.text); defer { typeStack.removeLast() }
        return super.visit(node)
    }
    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        typeStack.append(node.extendedType.trimmedDescription); defer { typeStack.removeLast() }
        return super.visit(node)
    }

    // MARK: - Visitor

    /// Types and functions this file declares itself. A file-local `NavigationStack` / `TabView` / `sheet(...)` is not
    /// SwiftUI's, so it is left alone. (Same-file detection only: a declaration in another file of the module is not seen.)
    private var shadowedTypes: Set<String> = []
    private var shadowedFunctions: Set<String> = []

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        shadowedTypes = VUDeclaredTypeScanner.declaredTypeNames(in: node)
        shadowedFunctions = VUDeclaredTypeScanner.declaredFunctionNames(in: node)
        return super.visit(node)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        // Recurse first (bottom-up) so nested patterns are processed before outer ones.
        let visited = super.visit(node)
        guard let call = visited.as(FunctionCallExprSyntax.self) else { return visited }

        if let ctor = constructorName(call) {
            if shadowedTypes.contains(ctor) { return ExprSyntax(call) }
            switch ctor {
            case "NavigationStack":     return rewriteNavigationStack(call)
            case "NavigationSplitView": return rewriteNavigationSplitView(call)
            case "TabView":             return rewriteTabView(call, original: node)
            case "NavigationLink":      return rewriteNavigationLink(call)
            default:                    return ExprSyntax(call)
            }
        }
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self),
           shadowedFunctions.contains(m.declName.baseName.text) { return ExprSyntax(call) }
        if modifierName(call) == "navigationDestination" { return rewriteNavigationDestination(call) }
        return rewriteModalModifier(call, original: node)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - NavigationStack
    // ─────────────────────────────────────────────────────────────

    private func rewriteNavigationStack(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        guard isPlainCallee(call) else { return ExprSyntax(call) }
        if hasSkipComment(call.leadingTrivia) { return ExprSyntax(call) }

        // SDK inits: (rootScreenName:root:), (path:rootScreenName:root:). Anything else (`root:` label, extra args,
        // no trailing closure) has no matching init.
        let labels = call.arguments.map { $0.label?.text }
        guard call.trailingClosure != nil, call.additionalTrailingClosures.isEmpty else { return ExprSyntax(call) }

        let rootName = escapedLiteral(synthesizeRootScreenName())
        let argsSource: String
        if labels.isEmpty {
            argsSource = "rootScreenName: \"\(rootName)\""
        } else if labels == ["path"], let pathExpr = call.arguments.first?.expression.trimmedDescription {
            argsSource = "path: \(pathExpr), rootScreenName: \"\(rootName)\""
        } else {
            return ExprSyntax(call)
        }

        let tempSource = Parser.parse(source: "TrackedNavigationStack(\(argsSource)) {}")
        guard let tempCall = tempSource.statements.first?.item.as(ExprSyntax.self)?.as(FunctionCallExprSyntax.self) else {
            return ExprSyntax(call)
        }
        let rewritten = call
            .with(\.calledExpression, tempCall.calledExpression)
            .with(\.leftParen, tempCall.leftParen)
            .with(\.arguments, tempCall.arguments)
            .with(\.rightParen, tempCall.rightParen)
            .with(\.leadingTrivia, call.leadingTrivia)
        navigationStackCount += 1
        return ExprSyntax(rewritten)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - NavigationSplitView
    // ─────────────────────────────────────────────────────────────

    private func rewriteNavigationSplitView(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        guard isPlainCallee(call) else { return ExprSyntax(call) }
        if hasSkipComment(call.leadingTrivia) { return ExprSyntax(call) }

        // Only the 2-column `(columnVisibility:) { sidebar } detail: { detail }` form has a matching SDK init.
        guard call.arguments.count == 1,
              call.arguments.first?.label?.text == "columnVisibility",
              let visibility = call.arguments.first?.expression.trimmedDescription,
              call.trailingClosure != nil,
              call.additionalTrailingClosures.count == 1,
              call.additionalTrailingClosures.first?.label.text == "detail" else {
            return ExprSyntax(call)
        }

        let sidebarName = currentTypeName.isEmpty ? "Sidebar" : "\(currentTypeName)Sidebar"
        let tempSource = Parser.parse(source:
            "TrackedNavigationSplitView(columnVisibility: \(visibility), sidebarName: \"\(escapedLiteral(sidebarName))\") {}")
        guard let tempCall = tempSource.statements.first?.item.as(ExprSyntax.self)?.as(FunctionCallExprSyntax.self) else {
            return ExprSyntax(call)
        }
        let rewritten = call
            .with(\.calledExpression, tempCall.calledExpression)
            .with(\.leftParen, tempCall.leftParen)
            .with(\.arguments, tempCall.arguments)
            .with(\.rightParen, tempCall.rightParen)
            .with(\.leadingTrivia, call.leadingTrivia)
        splitViewCount += 1
        return ExprSyntax(rewritten)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - NavigationLink
    // ─────────────────────────────────────────────────────────────
    //
    //   NavigationLink(destination: X) { L }    -> TrackedNavigationLink(destination: X) { L }
    //   NavigationLink("T", destination: X)     -> TrackedNavigationLink("T", destination: X)
    //   NavigationLink("T") { X }               -> TrackedNavigationLink("T") { X }
    //   everything else (value:, label:, isActive:, tag/selection, closure destination, `label:` trailing closure) -> untouched
    // ─────────────────────────────────────────────────────────────

    private func rewriteNavigationLink(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        guard let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return ExprSyntax(call) }
        if hasSkipComment(call.leadingTrivia) { return ExprSyntax(call) }

        let labels = call.arguments.map { $0.label?.text }

        // `NavigationLink(value:)`: the push is reported by the coordinator; nothing to add here.
        if labels.contains("value") { return ExprSyntax(call) }

        guard call.additionalTrailingClosures.isEmpty else { return ExprSyntax(call) }
        let hasTrailing = call.trailingClosure != nil
        let destinationIsClosure = call.arguments.contains { $0.expression.is(ClosureExprSyntax.self) }
        guard !destinationIsClosure else { return ExprSyntax(call) }

        let supported: Bool
        switch labels {
        case ["destination"]:      supported = hasTrailing          // (destination:) { label }
        case [nil, "destination"]: supported = !hasTrailing         // ("T", destination:)
        case [nil]:                supported = hasTrailing          // ("T") { destination }
        default:                   supported = false
        }
        guard supported else { return ExprSyntax(call) }

        let renamed = ref.with(\.baseName, ref.baseName.with(\.tokenKind, .identifier("TrackedNavigationLink")))
        navigationLinkCount += 1
        return ExprSyntax(call.with(\.calledExpression, ExprSyntax(renamed)))
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - TabView -> .trackTabSelection
    // ─────────────────────────────────────────────────────────────

    private func rewriteTabView(_ call: FunctionCallExprSyntax, original: FunctionCallExprSyntax) -> ExprSyntax {
        guard isPlainCallee(call) else { return ExprSyntax(call) }
        guard let selectionArg = call.arguments.first(where: { $0.label?.text == "selection" }) else {
            return ExprSyntax(call)
        }
        if hasSkipComment(call.leadingTrivia) { return ExprSyntax(call) }

        // Idempotency / hand-written tracker anywhere in the modifier chain (before or after the TabView call).
        if modifierChain(around: original).contains(where: { modifierName($0) == "trackTabSelection" }) {
            return ExprSyntax(call)
        }

        let selectionExpr = selectionArg.expression.trimmedDescription
        let entries = harvestTabEntries(from: call)

        let text: String
        if entries.isEmpty {
            // Can't statically resolve tabs: omit tabNames, the SDK falls back to String(describing:) at runtime.
            text = ".trackTabSelection(\(selectionExpr))"
        } else {
            let dict = entries.map { "\($0.key): \"\($0.name)\"" }.joined(separator: ", ")
            text = ".trackTabSelection(\(selectionExpr), tabNames: [\(dict)])"
        }

        guard let chained = chain(call, modifier: text, separator: separatorForConstructor(call)) else {
            return ExprSyntax(call)
        }
        tabViewCount += 1
        return chained
    }

    private struct TabEntry { let key: String; let name: String }

    /// Collects `(tag, name)` pairs from the TabView's DIRECT children only (statements of its content closure).
    /// Tags inside nested closures (ForEach rows, Pickers, ...) are out of scope and never touched. Tags that are not
    /// plain literals / type-rooted members, and keys that occur more than once (duplicate dictionary keys trap at
    /// runtime), are dropped.
    private func harvestTabEntries(from call: FunctionCallExprSyntax) -> [TabEntry] {
        var closure = call.trailingClosure
        if closure == nil {
            closure = call.arguments.first(where: { $0.label?.text == "content" })?.expression.as(ClosureExprSyntax.self)
        }
        guard let body = closure else { return [] }

        var raw: [TabEntry] = []
        for stmt in body.statements {
            guard case .expr(let expr) = stmt.item, let entry = tabEntry(from: expr) else { continue }
            raw.append(entry)
        }
        var seen: [String: Int] = [:]
        for e in raw { seen[normalized(e.key), default: 0] += 1 }
        return raw.filter { seen[normalized($0.key)] == 1 }
    }

    private func tabEntry(from expr: ExprSyntax) -> TabEntry? {
        var cur: ExprSyntax = expr
        var tagExpr: ExprSyntax?
        var label: String?
        while let c = cur.as(FunctionCallExprSyntax.self) {
            if let m = c.calledExpression.as(MemberAccessExprSyntax.self) {
                let name = m.declName.baseName.text
                if name == "tag", c.arguments.count == 1, tagExpr == nil {
                    tagExpr = c.arguments.first?.expression
                } else if name == "tabItem", label == nil {
                    // Only the tabItem's own closure / arguments, never its receiver (which holds the tab content).
                    var parts: [Syntax] = c.arguments.map { Syntax($0.expression) }
                    if let t = c.trailingClosure { parts.append(Syntax(t)) }
                    label = parts.lazy.compactMap { TabLabelFinder.firstLabel(in: $0) }.first
                }
                guard let base = m.base else { break }
                cur = base
            } else if let r = c.calledExpression.as(DeclReferenceExprSyntax.self), r.baseName.text == "Tab",
                      let value = c.arguments.first(where: { $0.label?.text == "value" }) {
                // iOS 18 `Tab("Home", systemImage:, value: .home) { }`
                if tagExpr == nil { tagExpr = value.expression }
                if label == nil, let first = c.arguments.first, first.label == nil,
                   let s = first.expression.as(StringLiteralExprSyntax.self) {
                    label = simpleLiteralText(s)
                }
                break
            } else {
                break
            }
        }
        guard let tag = tagExpr, let key = staticTagKey(tag) else { return nil }
        let name = label.flatMap { $0.isEmpty ? nil : $0 } ?? tagExprToScreenName(key)
        return TabEntry(key: key, name: name)
    }

    /// A tag that can be written as a dictionary key at the TabView call site: integer / simple string literal,
    /// implicit member (`.home`) or a type-rooted member path (`AppTab.home`).
    private func staticTagKey(_ expr: ExprSyntax) -> String? {
        if expr.is(IntegerLiteralExprSyntax.self) { return expr.trimmedDescription }
        if let s = expr.as(StringLiteralExprSyntax.self), simpleLiteralText(s) != nil { return expr.trimmedDescription }
        if let m = expr.as(MemberAccessExprSyntax.self) {
            if m.base == nil { return expr.trimmedDescription }
            if isTypeRooted(expr) { return expr.trimmedDescription }
        }
        return nil
    }

    /// `Type.member(.member)*` where the root identifier starts with an uppercase letter.
    private func isTypeRooted(_ expr: ExprSyntax) -> Bool {
        if let r = expr.as(DeclReferenceExprSyntax.self) { return r.baseName.text.first?.isUppercase ?? false }
        if let m = expr.as(MemberAccessExprSyntax.self), let base = m.base { return isTypeRooted(base) }
        return false
    }

    /// Converts a tag expression (already validated by `staticTagKey`) to a screen name.
    /// - `Tab.home` -> "HomeTab", `0` -> "Tab0", `"search"` -> "SearchTab"
    private func tagExprToScreenName(_ expr: String) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        if Int(trimmed) != nil { return "Tab\(trimmed)" }
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            let inner = String(trimmed.dropFirst().dropLast())   // raw source text, already escaped
            return inner.prefix(1).uppercased() + inner.dropFirst() + "Tab"
        }
        let last = trimmed.components(separatedBy: ".").last ?? trimmed
        return last.prefix(1).uppercased() + last.dropFirst() + "Tab"
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Modal chaining (.sheet, .fullScreenCover, .popover, .alert)
    // ─────────────────────────────────────────────────────────────

    private func rewriteModalModifier(_ call: FunctionCallExprSyntax, original: FunctionCallExprSyntax) -> ExprSyntax {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base != nil else {
            return ExprSyntax(call)
        }
        let method = member.declName.baseName.text
        guard ["sheet", "fullScreenCover", "popover", "alert"].contains(method) else { return ExprSyntax(call) }

        // Only the `isPresented:` forms have a matching SDK tracker; `item:` forms are named through their content.
        guard let bindingArg = call.arguments.first(where: { $0.label?.text == "isPresented" }) else {
            if method != "alert", call.arguments.contains(where: { $0.label?.text == "item" }) {
                return rewriteItemModal(call, member: member)
            }
            return ExprSyntax(call)
        }
        if hasSkipComment(member.period.leadingTrivia) { return ExprSyntax(call) }

        let binding = bindingArg.expression.trimmedDescription
        // `.constant(...)` never changes, nothing to track.
        if binding.hasPrefix(".constant(") || binding.hasPrefix("Binding.constant(") { return ExprSyntax(call) }

        // Idempotency: any trackModal for the same binding anywhere in this modifier chain (before or after).
        let key = normalized(binding)
        for other in modifierChain(around: original) where modifierName(other) == "trackModal" {
            if let arg = other.arguments.first(where: { $0.label?.text == "isPresented" }),
               normalized(arg.expression.trimmedDescription) == key {
                return ExprSyntax(call)
            }
        }

        // Never compete with a screen name the content declares itself (e.g. persistent login sheets).
        if contentDeclaresScreen(call) { return ExprSyntax(call) }

        let screenName = escapedLiteral(synthesizeModalScreenName(kind: method, bindingExpr: binding))
        let text = ".trackModal(isPresented: \(binding), screenName: \"\(screenName)\", kind: .\(method))"
        guard let chained = chain(call, modifier: text, separator: lineSeparator(from: member.period.leadingTrivia)) else {
            return ExprSyntax(call)
        }
        modalCount += 1
        return chained
    }

    /// True if one of the modal's closures (content / actions) applies `.trackScreen(...)`.
    private func contentDeclaresScreen(_ call: FunctionCallExprSyntax) -> Bool {
        var closures: [ClosureExprSyntax] = []
        if let t = call.trailingClosure { closures.append(t) }
        closures += call.additionalTrailingClosures.map { $0.closure }
        closures += call.arguments.compactMap { $0.expression.as(ClosureExprSyntax.self) }
        return closures.contains { $0.description.contains("trackScreen(") }
    }

    /// Screen name: derived from a simple binding path ("$showSettings" -> "SettingsSheet"); if that is not
    /// meaningful (complex `Binding(get:set:)`, or only "sheetPresented"), falls back to "<EnclosingType><Kind>".
    private func synthesizeModalScreenName(kind: String, bindingExpr: String) -> String {
        let suffix: String
        switch kind {
        case "alert":           suffix = "Alert"
        case "sheet":           suffix = "Sheet"
        case "fullScreenCover": suffix = "FullScreen"
        case "popover":         suffix = "Popover"
        default:                suffix = "Modal"
        }
        let fallback = "\(currentTypeName)\(suffix)"

        guard isSimpleBindingPath(bindingExpr) else { return fallback }
        var name = bindingExpr
        if name.hasPrefix("$") { name.removeFirst() }
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }

        name = stripWords(name, prefixes: ["showing", "show", "is", "presenting", "present", "displaying", "display"], suffixes: [])
        name = stripWords(name, prefixes: [], suffixes: ["Presented", "Presenting", "Showing", "Shown", "Visible", "Displayed"])

        let degenerate = ["", "sheet", "alert", "popover", "fullscreencover", "cover", "modal", "dialog"]
        if degenerate.contains(name.lowercased()) { return fallback }

        let capitalized = name.prefix(1).uppercased() + name.dropFirst()
        return capitalized.hasSuffix(suffix) ? capitalized : "\(capitalized)\(suffix)"
    }

    /// Repeatedly strips camelCase word prefixes/suffixes (the next/previous character must start a new word).
    private func stripWords(_ input: String, prefixes: [String], suffixes: [String]) -> String {
        var s = input
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.count > p.count && s.lowercased().hasPrefix(p) {
                let next = s[s.index(s.startIndex, offsetBy: p.count)]
                if next.isUppercase || next.isNumber {
                    s = String(s.dropFirst(p.count)); changed = true; break
                }
            }
            for x in suffixes where s.count > x.count && s.hasSuffix(x) {
                s = String(s.dropLast(x.count)); changed = true; break
            }
        }
        return s
    }

    private func isSimpleBindingPath(_ s: String) -> Bool {
        var body = Substring(s)
        if body.hasPrefix("$") { body = body.dropFirst() }
        guard !body.isEmpty else { return false }
        for part in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard let f = part.first, f.isLetter || f == "_",
                  part.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        return true
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Destinations (.navigationDestination, .sheet/.fullScreenCover/.popover(item:))
    // ─────────────────────────────────────────────────────────────
    //
    //   .navigationDestination(for: T.self) { v in Dest(v) }  -> Dest(v).vuTrackDestination()
    //   .sheet(item: $i) { v in Dest(v).padding() }           -> Dest(v).vuTrackDestination(isModal: true).padding()
    //   `if` / `switch` bodies are handled branch by branch.
    // ─────────────────────────────────────────────────────────────

    private func rewriteNavigationDestination(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base != nil,
              ["for", "isPresented", "item"].contains(call.arguments.first?.label?.text ?? ""),
              !hasSkipComment(member.period.leadingTrivia) else { return ExprSyntax(call) }
        return rewritingContent(of: call, closureLabel: "destination", isModal: false)
    }

    private func rewriteItemModal(_ call: FunctionCallExprSyntax, member: MemberAccessExprSyntax) -> ExprSyntax {
        if hasSkipComment(member.period.leadingTrivia) || contentDeclaresScreen(call) { return ExprSyntax(call) }
        return rewritingContent(of: call, closureLabel: "content", isModal: true)
    }

    /// Attaches `.vuTrackDestination` inside the content closure: the trailing closure, else the `closureLabel:` argument.
    private func rewritingContent(of call: FunctionCallExprSyntax, closureLabel: String, isModal: Bool) -> ExprSyntax {
        let attach: (ExprSyntax) -> ExprSyntax? = { self.attachingDestination(to: $0, isModal: isModal) }
        if let closure = call.trailingClosure, call.additionalTrailingClosures.isEmpty {
            guard let items = transformViewBuilder(closure.statements, attach: attach) else { return ExprSyntax(call) }
            destinationCount += 1
            return ExprSyntax(call.with(\.trailingClosure, closure.with(\.statements, items)))
        }
        var args = Array(call.arguments)
        guard call.trailingClosure == nil,
              let i = args.firstIndex(where: { $0.label?.text == closureLabel }),
              let closure = args[i].expression.as(ClosureExprSyntax.self),
              let items = transformViewBuilder(closure.statements, attach: attach) else { return ExprSyntax(call) }
        args[i] = args[i].with(\.expression, ExprSyntax(closure.with(\.statements, items)))
        destinationCount += 1
        return ExprSyntax(call.with(\.arguments, LabeledExprListSyntax(args)))
    }

    /// `.vuTrackDestination` chained right after the ROOT constructor of a view expression, so the SDK sees that view's
    /// type. Nil (leave alone) for `// VU:skip`, content that already names itself, a root that is not a type
    /// constructor (`x.view`, `makeView()`) and SwiftUI's own views (`VStack`, `Text`, ...: no screen name in them).
    private func attachingDestination(to expr: ExprSyntax, isModal: Bool) -> ExprSyntax? {
        let text = expr.description
        if hasSkipComment(expr.leadingTrivia) || text.contains("trackScreen(") || text.contains("vuTrackDestination(") {
            return nil
        }
        guard let root = rootConstructor(expr),
              shadowedTypes.contains(root) || !Self.builtinViewTypes.contains(root) else { return nil }
        return chainingAfterRoot(expr, modifier: isModal ? ".vuTrackDestination(isModal: true)" : ".vuTrackDestination()",
                                 separator: nil)
    }

    private func chainingAfterRoot(_ expr: ExprSyntax, modifier: String, separator: Trivia?) -> ExprSyntax? {
        guard let call = expr.as(FunctionCallExprSyntax.self) else { return nil }
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self), !isQualifiedConstructor(m) {
            guard let base = m.base,
                  let newBase = chainingAfterRoot(base, modifier: modifier,
                                                  separator: lineSeparator(from: m.period.leadingTrivia)) else { return nil }
            return ExprSyntax(call.with(\.calledExpression, ExprSyntax(m.with(\.base, newBase))))
        }
        return chain(call, modifier: modifier, separator: separator ?? separatorForConstructor(call))
    }

    /// `Module.Type(...)`: a member access whose name is a type and whose base is a type path.
    private func isQualifiedConstructor(_ m: MemberAccessExprSyntax) -> Bool {
        guard let base = m.base, m.declName.baseName.text.first?.isUppercase == true else { return false }
        return isTypeRooted(base)
    }

    /// The type name of the constructor at the bottom of a modifier chain: `Foo(...)`, `Foo<T>(...)`, `Mod.Foo(...)`,
    /// each possibly followed by `.modifier(...)` calls. Nil for anything else (`x.view`, `.init()`, `makeView()`).
    private func rootConstructor(_ expr: ExprSyntax) -> String? {
        var cur = expr
        while let call = cur.as(FunctionCallExprSyntax.self) {
            let callee = call.calledExpression
            if let m = callee.as(MemberAccessExprSyntax.self) {
                guard let base = m.base else { return nil }
                if isQualifiedConstructor(m) { return m.declName.baseName.text }
                cur = base
                continue
            }
            let ref = callee.as(DeclReferenceExprSyntax.self)
                ?? callee.as(GenericSpecializationExprSyntax.self)?.expression.as(DeclReferenceExprSyntax.self)
            guard let name = ref?.baseName.text, name.first?.isUppercase == true else { return nil }
            return name
        }
        return nil
    }

    /// The expression of a code-block item. `if` / `switch` in statement position parse as an expression STATEMENT, so
    /// both shapes are unwrapped; `replace` puts a new expression back in the same shape (trivia preserved).
    private func expression(of item: CodeBlockItemSyntax) -> (expr: ExprSyntax, replace: (ExprSyntax) -> CodeBlockItemSyntax)? {
        switch item.item {
        case .expr(let e):
            return (e, { item.with(\.item, .expr($0)) })
        case .stmt(let s):
            guard let es = s.as(ExpressionStmtSyntax.self) else { return nil }
            return (es.expression, { item.with(\.item, .stmt(StmtSyntax(es.with(\.expression, $0)))) })
        default:
            return nil
        }
    }

    /// Applies `attach` to the single view expression of a ViewBuilder body; `if` / `switch` bodies are handled branch by
    /// branch (a branch that is not a single eligible expression is left as is). Nil when nothing changed.
    private func transformViewBuilder(_ items: CodeBlockItemListSyntax,
                                      attach: (ExprSyntax) -> ExprSyntax?) -> CodeBlockItemListSyntax? {
        guard items.count == 1, let item = items.first, let (e, replace) = expression(of: item) else { return nil }
        if let ifExpr = e.as(IfExprSyntax.self) {
            guard let new = transformIf(ifExpr, attach: attach) else { return nil }
            return CodeBlockItemListSyntax([replace(ExprSyntax(new))])
        }
        if let sw = e.as(SwitchExprSyntax.self) {
            var changed = false
            let cases = SwitchCaseListSyntax(sw.cases.map { element -> SwitchCaseListSyntax.Element in
                guard case .switchCase(let c) = element,
                      let branch = transformViewBuilder(c.statements, attach: attach) else { return element }
                changed = true
                return .switchCase(c.with(\.statements, branch))
            })
            guard changed else { return nil }
            return CodeBlockItemListSyntax([replace(ExprSyntax(sw.with(\.cases, cases)))])
        }
        guard let new = attach(e) else { return nil }
        return CodeBlockItemListSyntax([replace(new)])
    }

    private func transformIf(_ node: IfExprSyntax, attach: (ExprSyntax) -> ExprSyntax?) -> IfExprSyntax? {
        var result = node
        var changed = false
        if let items = transformViewBuilder(node.body.statements, attach: attach) {
            result = result.with(\.body, node.body.with(\.statements, items)); changed = true
        }
        switch node.elseBody {
        case .codeBlock(let block):
            if let items = transformViewBuilder(block.statements, attach: attach) {
                result = result.with(\.elseBody, .codeBlock(block.with(\.statements, items))); changed = true
            }
        case .ifExpr(let inner):
            if let new = transformIf(inner, attach: attach) {
                result = result.with(\.elseBody, .ifExpr(new)); changed = true
            }
        case nil:
            break
        }
        return changed ? result : nil
    }

    /// SwiftUI's own views: a destination rooted in one of these has no type worth naming a screen after.
    static let builtinViewTypes: Set<String> = [
        "Text", "Image", "Label", "Button", "Link", "Toggle", "Slider", "Stepper", "Picker", "DatePicker", "MultiDatePicker",
        "TextField", "SecureField", "TextEditor", "Menu", "ProgressView", "Gauge", "ColorPicker", "ShareLink", "PhotosPicker",
        "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "Grid", "GridRow", "Group",
        "List", "Form", "ScrollView", "ScrollViewReader", "ForEach", "Section", "GroupBox", "DisclosureGroup", "OutlineGroup",
        "Spacer", "Divider", "EmptyView", "AnyView", "TupleView", "Color", "Rectangle", "RoundedRectangle", "Circle",
        "Ellipse", "Capsule", "UnevenRoundedRectangle", "Path", "Canvas", "GeometryReader", "ViewThatFits", "TimelineView",
        "TabView", "NavigationStack", "NavigationView", "NavigationSplitView", "NavigationLink", "TrackedNavigationStack",
        "TrackedNavigationLink", "TrackedNavigationSplitView", "AsyncImage", "VuAsyncImage", "ContentUnavailableView",
        "Table", "Self", "Any", "Optional", "Binding", "State", "Environment", "UIViewControllerRepresentable",
    ]

    // ─────────────────────────────────────────────────────────────
    // MARK: - Chain helpers
    // ─────────────────────────────────────────────────────────────

    /// The OTHER modifier calls of the chain `node` belongs to: modifiers applied after it (outwards) and the
    /// receiver chain before it. Uses the ORIGINAL node, which still knows its parents.
    private func modifierChain(around node: FunctionCallExprSyntax) -> [FunctionCallExprSyntax] {
        var result: [FunctionCallExprSyntax] = []

        // Outwards: node.modifier(...)
        var cur = Syntax(node)
        while let member = cur.parent?.as(MemberAccessExprSyntax.self),
              member.base?.id == cur.id,
              let outer = member.parent?.as(FunctionCallExprSyntax.self),
              outer.calledExpression.id == member.id {
            result.append(outer)
            cur = Syntax(outer)
        }

        // Inwards: receiver.modifier(...)
        var expr: ExprSyntax = node.calledExpression
        while let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            if let inner = base.as(FunctionCallExprSyntax.self) {
                result.append(inner)
                expr = inner.calledExpression
            } else {
                break
            }
        }
        return result
    }

    private func modifierName(_ call: FunctionCallExprSyntax) -> String? {
        call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    /// `(base).modifier(...)` with `base` substituted in; the base's trailing trivia (e.g. `// comment`) moves to the end.
    private func chain(_ base: FunctionCallExprSyntax, modifier: String, separator: Trivia) -> ExprSyntax? {
        let temp = Parser.parse(source: "(__placeholder__)\(modifier)")
        guard let chainedCall = temp.statements.first?.item.as(ExprSyntax.self)?.as(FunctionCallExprSyntax.self),
              let member = chainedCall.calledExpression.as(MemberAccessExprSyntax.self),
              !temp.hasError else { return nil }
        let trailing = base.trailingTrivia
        let newMember = member
            .with(\.base, ExprSyntax(base.with(\.trailingTrivia, [])))
            .with(\.period, member.period.with(\.leadingTrivia, separator))
        return ExprSyntax(chainedCall.with(\.calledExpression, ExprSyntax(newMember)).with(\.trailingTrivia, trailing))
    }

    /// Newline + indentation of the line `trivia` ends on, or empty when the modifier sits on the same line.
    private func lineSeparator(from trivia: Trivia) -> Trivia {
        var sawNewline = false
        var indent: [TriviaPiece] = []
        for piece in trivia {
            switch piece {
            case .newlines, .carriageReturns, .carriageReturnLineFeeds:
                sawNewline = true; indent = []
            case .spaces, .tabs:
                indent.append(piece)
            default:
                break
            }
        }
        return sawNewline ? Trivia(pieces: [.newlines(1)] + indent) : []
    }

    /// For constructors (TabView / NavigationLink): modifier on its own line when the call spans multiple lines.
    private func separatorForConstructor(_ call: FunctionCallExprSyntax) -> Trivia {
        call.trimmedDescription.contains("\n") ? lineSeparator(from: call.leadingTrivia) : []
    }

    private func isPlainCallee(_ call: FunctionCallExprSyntax) -> Bool {
        call.calledExpression.is(DeclReferenceExprSyntax.self)
    }

    /// `Foo(...)` or `SwiftUI.Foo(...)` -> "Foo". Nil for modifier calls (`x.foo(...)`) and other expressions.
    private func constructorName(_ call: FunctionCallExprSyntax) -> String? {
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           let base = member.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "SwiftUI" {
            return member.declName.baseName.text
        }
        return nil
    }

    private func hasSkipComment(_ trivia: Trivia) -> Bool {
        for piece in trivia {
            switch piece {
            case .lineComment(let t) where t.contains("VU:skip"): return true
            case .blockComment(let t) where t.contains("VU:skip"): return true
            default: break
            }
        }
        return false
    }

    private func normalized(_ s: String) -> String { s.filter { !$0.isWhitespace } }

    /// Contents of a plain, single-line, interpolation-free string literal (raw source text), else nil.
    private func simpleLiteralText(_ lit: StringLiteralExprSyntax) -> String? {
        guard lit.openingPounds == nil, lit.openingQuote.tokenKind == .stringQuote else { return nil }
        var out = ""
        for seg in lit.segments {
            guard let s = seg.as(StringSegmentSyntax.self) else { return nil }
            out += s.content.text
        }
        return out.contains("\n") ? nil : out
    }

    /// Escapes text for use between the quotes of a single-line Swift string literal.
    static func swiftStringLiteralContents(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    private func escapedLiteral(_ s: String) -> String { Self.swiftStringLiteralContents(s) }

    /// Synthesizes `rootScreenName` from the enclosing type.
    /// - `CardsView` -> `"CardsScreen"`, `LoginPanel` -> `"LoginPanel"`
    private func synthesizeRootScreenName() -> String {
        let type = currentTypeName
        guard !type.isEmpty else { return "Screen" }
        if type.hasSuffix("View") {
            let base = String(type.dropLast("View".count))
            return base.isEmpty ? type : "\(base)Screen"
        }
        return type
    }
}

// MARK: - Tab label finder

/// Finds the first plain string literal passed to `Label(...)` / `Text(...)` inside a `.tabItem { }` call.
private final class TabLabelFinder: SyntaxVisitor {
    private var found: String?

    static func firstLabel(in node: Syntax) -> String? {
        let finder = TabLabelFinder(viewMode: .sourceAccurate)
        finder.walk(node)
        return finder.found
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard found == nil else { return .skipChildren }
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Label" || ref.baseName.text == "Text",
           let first = node.arguments.first, first.label == nil,
           let lit = first.expression.as(StringLiteralExprSyntax.self),
           lit.openingPounds == nil, lit.openingQuote.tokenKind == .stringQuote {
            var out = ""
            var ok = true
            for seg in lit.segments {
                if let s = seg.as(StringSegmentSyntax.self) { out += s.content.text } else { ok = false; break }
            }
            if ok, !out.contains("\n") { found = out; return .skipChildren }
        }
        return .visitChildren
    }
}

// MARK: - Enclosing Type Scanner

/// Finds the first struct/class declaration in a source file (fallback for code outside any type).
final class EnclosingTypeScanner: SyntaxVisitor {

    private(set) var firstName: String = ""

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if firstName.isEmpty {
            firstName = node.name.text
        }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if firstName.isEmpty {
            firstName = node.name.text
        }
        return .skipChildren
    }
}
