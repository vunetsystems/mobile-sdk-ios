import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@VuTrack` on a view struct, or on an extension of one (`extension X: View { var body ... }`, or a plain
/// `extension X { var header: some View ... }`): tags each computed property and function that has something to
/// track with `@VuTrackBody("<Type>")`.
///
/// Only bodies the rewriters actually change are tagged. The compiler does not check API availability inside a body
/// macro's expansion (swiftlang/swift#89936: an iOS 17-only call in an iOS 16 app compiles without error), so every
/// body left untouched keeps that check.
///
/// Requires Swift 6.4 for computed properties (`var body`). Swift 6.3 rejects a body macro on a property
/// (`'body' macro cannot be attached to property`), on its `get` accessor, and an accessor macro that replaces an
/// existing getter, so there the macro reports an error on each property it would rewrite instead of tagging it.
/// Functions are tagged on every toolchain.
public struct VuTrackMacro: MemberAttributeMacro {
    /// The plugin is compiled by the same toolchain that expands it, so this is the consumer's compiler.
    #if compiler(>=6.4)
    static let propertyBodiesSupported = true
    #else
    static let propertyBodiesSupported = false
    #endif

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        attributes(attachedTo: declaration, for: member, propertyBodiesSupported: propertyBodiesSupported, in: context)
    }

    static func attributes(
        attachedTo declaration: some DeclGroupSyntax,
        for member: some DeclSyntaxProtocol,
        propertyBodiesSupported: Bool,
        in context: some MacroExpansionContext
    ) -> [AttributeSyntax] {
        let type = declaration.as(StructDeclSyntax.self)?.name.text
            ?? declaration.as(ExtensionDeclSyntax.self)?.extendedType.trimmedDescription
        guard let type else { return [] }
        let property = member.as(VariableDeclSyntax.self)
        let isComputedVar = property?.bindings.first?.accessorBlock != nil
        let isFunc = member.is(FunctionDeclSyntax.self)
        guard isComputedVar || isFunc, let body = Self.statements(of: member),
              VuTrackBodyMacro.rewrite(body, screen: type).description != body.description else { return [] }
        if let property, !propertyBodiesSupported {
            let name = property.bindings.first?.pattern.trimmedDescription ?? "property"
            context.diagnose(Diagnostic(node: property.bindingSpecifier, message: PropertyBodyNeedsSwift64(name: name)))
            return []
        }
        return ["@VuTrackBody(\(literal: type))"]
    }

    /// A function's body, or a computed property's getter (`var x: T { ... }` or `var x: T { get { ... } }`).
    static func statements(of member: some DeclSyntaxProtocol) -> CodeBlockItemListSyntax? {
        if let function = member.as(FunctionDeclSyntax.self) { return function.body?.statements }
        switch member.as(VariableDeclSyntax.self)?.bindings.first?.accessorBlock?.accessors {
        case .getter(let items)?: return items
        case .accessors(let list)?: return list.first { $0.accessorSpecifier.tokenKind == .keyword(.get) }?.body?.statements
        case nil: return nil
        }
    }
}

/// The error `@VuTrack` reports on a computed property it would rewrite when the compiler is older than Swift 6.4.
struct PropertyBodyNeedsSwift64: DiagnosticMessage {
    let name: String
    var message: String {
        "@VuTrack needs Swift 6.4 or later to track computed property '\(name)': Swift 6.3 cannot attach a body macro "
            + "to a property. Build with a Swift 6.4 toolchain, or remove @VuTrack from this type."
    }
    var diagnosticID: MessageID { MessageID(domain: "VuTrack", id: "propertyBodyNeedsSwift64") }
    var severity: DiagnosticSeverity { .error }
}

/// `@VuTrackBody("Screen")`: rewrites the attached body in memory only (source files are never touched):
///  1. Buttons (`VUButtonRewriter`): each press registers its label with `VuButtonPressRegistry`; the SDK's
///     window-level tap tracker then emits the `ui.interaction` span with that label.
///  2. Navigation (`VUNavigationRewriter`): NavigationStack / sheets / alerts / split views / links / `TabView(selection:)`.
///  2b. Date pickers (`VUDatePickerRewriter`) and gestures (`VUGestureRewriter`: long press, drag, magnification,
///      rotation, double tap); plain `.onTapGesture` via `TapGestureRewriter`.
///  3. `Tab("Title") { content }`: each tab switch reports a root-screen change (`TabScreenRewriter`).
///  4. Buttons left without a label (icon-only, computed text) register `"Button"`: the SDK drops a SwiftUI tap with
///     no registered press, so without this they would not be reported at all. Never on secure-entry screens.
///  5. `Toggle` / `Picker` / `Stepper` with fixed text get `.vuTrackControlLabel("...")` (`ControlLabelRewriter`).
///     The SDK still emits their spans at runtime; this only names them, so nothing is double-counted.
public struct VuTrackBodyMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let body = declaration.body else { return [] }
        let screen = node.arguments?.as(LabeledExprListSyntax.self)?.first?.expression
            .as(StringLiteralExprSyntax.self)?.representedLiteralValue ?? "Unknown"
        return Array(rewrite(body.statements, screen: screen))
    }

    /// The whole rewrite, also run by `VuTrackMacro` to decide whether a body needs this macro at all.
    static func rewrite(_ body: CodeBlockItemListSyntax, screen: String) -> CodeBlockItemListSyntax {
        let fileName = screen + ".swift" // feeds the secure-screen check (PinEntryView, OtpView, ...)

        let buttons = VUButtonRewriter()
        buttons.fileName = fileName
        let navigation = VUNavigationRewriter()
        navigation.enclosingTypeName = screen

        var statements = buttons.rewrite(body)
        statements = navigation.rewrite(statements)
        statements = VUDatePickerRewriter().rewrite(statements)
        statements = VUGestureRewriter().rewrite(statements)
        statements = TapGestureRewriter(fileName: fileName).rewrite(statements)
        statements = TabScreenRewriter(screen: screen).rewrite(statements)
        statements = UnlabeledButtonRewriter(fileName: fileName).rewrite(statements)
        statements = ControlLabelRewriter(fileName: fileName).rewrite(statements)
        return statements.cast(CodeBlockItemListSyntax.self)
    }
}

/// `.onTapGesture { ... }` / `.onTapGesture(count: n) { ... }` -> `.instrumentedTap(count: n, label: "...") { ... }`,
/// the SDK modifier with the same signature. `VUGestureRewriter` covers double-tap `TapGesture`s but not this. The
/// label is fixed text or an SF Symbol name from the tapped view (`VUGestureLabelExtractor`); without one the SDK
/// falls back to the screen name. Skipped on secure-entry screens, for hand-tracked closures and for the
/// location-taking variant (`.onTapGesture(coordinateSpace:) { location in }`).
final class TapGestureRewriter: SyntaxRewriter {
    let fileName: String
    init(fileName: String) { self.fileName = fileName }

    override func visit(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        let visited = super.visit(call).cast(FunctionCallExprSyntax.self)
        guard let member = visited.calledExpression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "onTapGesture", let receiver = member.base,
              visited.arguments.allSatisfy({ ["count", "perform"].contains($0.label?.text ?? "") }),
              visited.additionalTrailingClosures.isEmpty,
              !VUManualTrackingDetector.containsManualTracking(visited.arguments),
              !(visited.trailingClosure.map { VUManualTrackingDetector.containsManualTracking($0) } ?? false),
              visited.trailingClosure?.signature == nil,
              !call.leadingTrivia.description.contains("VU:skip"),
              !VUButtonRewriter.isSecureEntryContext(call, fileName: fileName) else {
            return ExprSyntax(visited)
        }
        var args = Array(visited.arguments)
        if let label = VUGestureLabelExtractor.extract(from: receiver), !VUButtonRewriter.isValueLikeLabel(label) {
            let at = args.firstIndex { $0.label?.text == "perform" } ?? args.count
            args.insert(LabeledExprSyntax(label: "label", expression: ExprSyntax("\(literal: label)")), at: at)
        }
        let list = LabeledExprListSyntax(args.enumerated().map { i, arg in
            arg.with(\.trailingComma, i < args.count - 1 ? .commaToken(trailingTrivia: .space) : nil)
        })
        return ExprSyntax(visited
            .with(\.calledExpression, ExprSyntax(member.with(\.declName, DeclReferenceExprSyntax(baseName: .identifier("instrumentedTap")))))
            .with(\.arguments, list)
            .with(\.leftParen, visited.leftParen ?? .leftParenToken())
            .with(\.rightParen, visited.rightParen ?? .rightParenToken()))
    }
}

/// `Tab("Accounts", systemImage: ...) { AccountsView() }` ->
/// `{ AccountsView().onAppear { VuTrackTabs.didAppear("AccountsScreen") } }`.
/// A `TabView` without a `selection:` binding has nothing for `.trackTabSelection` to observe, and a macro cannot add
/// state, so each tab reports its own appearance (one `ui.navigation` span per switch, see `VuTrackTabs`).
/// The name follows `VUNavigationRewriter`'s rule (`AccountsView` -> `AccountsScreen`) so it matches the
/// `TrackedNavigationStack` root inside the tab; otherwise the literal tab title. No runtime value is reported.
/// The older style is handled the same way: `HomeView().tabItem { Label("Home", ...) }` ->
/// `HomeView().onAppear { ... "HomeScreen" ... }.tabItem { ... }`.
/// Each `TabView` is its own group (`VuTrackTabs` keeps the current tab per group), so a tab bar nested inside a
/// tab reports its own switches and never reads as a switch of the outer bar.
final class TabScreenRewriter: SyntaxRewriter {
    let screen: String
    init(screen: String) { self.screen = screen }

    override func visit(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        let original = call
        let call = super.visit(call).cast(FunctionCallExprSyntax.self)
        // No "already instrumented" check on the description: a nested TabView's own tabs sit inside the outer tab's
        // content, so it would wrongly skip the outer tab. The macro expands each body once.
        guard !Self.isInsideSelectionTabView(original) else { return ExprSyntax(call) }

        // Tab("Title", ...) { content }
        if call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Tab",
           let title = call.arguments.first(where: { $0.label == nil })?.expression
            .as(StringLiteralExprSyntax.self)?.representedLiteralValue, !title.isEmpty,
           let content = call.trailingClosure {
            let items = Array(content.statements)
            let single = items.count == 1 ? items.first?.item.as(ExprSyntax.self) : nil
            let view: ExprSyntax = single.map { "\($0.trimmed)" }
                ?? "Group { \(CodeBlockItemListSyntax(items.map { $0.trimmed })) }"
            let tracked = Self.reportingAppearance(view, screen: Self.screenName(of: single, title: title), group: group(of: original))
            return ExprSyntax(call.with(\.trailingClosure, content.with(\.statements, [CodeBlockItemSyntax(item: .expr(tracked))])))
        }

        // content.tabItem { Label("Title", ...) }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           member.declName.baseName.text == "tabItem", let content = member.base,
           let item = call.trailingClosure, let title = Syntax(item).firstTabTitle {
            let tracked = Self.reportingAppearance(content.trimmed, screen: Self.screenName(of: content, title: title), group: group(of: original))
            return ExprSyntax(call.with(\.calledExpression, ExprSyntax(member.with(\.base, tracked))))
        }
        return ExprSyntax(call)
    }

    /// The enclosing `TabView`, named by the declaring view and its position in the expanded body (stable per build).
    func group(of node: some SyntaxProtocol) -> String {
        var current = Syntax(node).parent
        while let ancestor = current {
            if let call = ancestor.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "TabView" {
                return "\(screen)#\(call.positionAfterSkippingLeadingTrivia.utf8Offset)"
            }
            current = ancestor.parent
        }
        return screen
    }

    /// A `TabView(selection:)` is tracked by VUNavigationRewriter's `.trackTabSelection`; reporting its tabs here too
    /// would count every switch twice and mix its tabs into `VuTrackTabs`' app-wide current tab.
    static func isInsideSelectionTabView(_ node: some SyntaxProtocol) -> Bool {
        var current = Syntax(node).parent
        while let ancestor = current {
            if let call = ancestor.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "TabView" {
                return call.arguments.contains { $0.label?.text == "selection" }
            }
            current = ancestor.parent
        }
        return false
    }

    /// `AccountsView()` -> `AccountsScreen` (VUNavigationRewriter's rule); anything else -> the tab title.
    static func screenName(of content: ExprSyntax?, title: String) -> String {
        let type = content?.as(FunctionCallExprSyntax.self)?.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        return type.flatMap {
            $0.hasSuffix("View") && $0.count > 4 && !swiftUIViewTypes.contains($0) ? String($0.dropLast(4)) + "Screen" : nil
        } ?? title
    }

    /// SwiftUI's own `...View` types: a tab whose content is one of these (a nested `TabView`) is named by its title.
    static let swiftUIViewTypes: Set<String> = [
        "TabView", "ScrollView", "NavigationView", "NavigationSplitView", "ProgressView", "ContentUnavailableView",
        "AnyView", "EmptyView", "EquatableView", "ControlGroupView",
    ]

    /// `VuTrackTabs` reports the switch from the previous tab, preferring a name the tab's content set itself.
    static func reportingAppearance(_ view: ExprSyntax, screen: String, group: String) -> ExprSyntax {
        "\(view).onAppear { VuTrackTabs.didAppear(\(literal: screen), group: \(literal: group)) }"
    }
}

extension Syntax {
    /// First literal title of a `Label("...")` or `Text("...")` in this subtree (a `.tabItem` content).
    var firstTabTitle: String? {
        if let call = self.as(FunctionCallExprSyntax.self),
           let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text, name == "Label" || name == "Text",
           let s = call.arguments.first?.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue, !s.isEmpty {
            return s
        }
        for child in children(viewMode: .sourceAccurate) {
            if let s = child.firstTabTitle { return s }
        }
        return nil
    }
}

/// Instruments plain `Button`s that `VUButtonRewriter` left alone. It skips any action that mentions the SDK, which
/// also drops buttons that only read `Vunet.sessionId` or call `Vunet.recordError`; those get their resolved label
/// here. Labels go through the same extractor and privacy checks; when none is safe, the generic `"Button"`.
final class UnlabeledButtonRewriter: SyntaxRewriter {
    let fileName: String
    init(fileName: String) { self.fileName = fileName }

    /// Calls that already report this tap by hand; the button is left alone so the event is not doubled.
    static let trackingCalls: Set<String> = ["registerPress", "recordClickEvent", "recordEvent"]

    override func visit(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        let visited = super.visit(call).cast(FunctionCallExprSyntax.self)
        guard visited.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Button",
              !Self.reportsTap(visited),
              !call.leadingTrivia.description.contains("VU:skip"),
              !VUButtonRewriter.isSecureEntryContext(call, fileName: fileName) else {
            return ExprSyntax(visited)
        }
        let register = Self.register(for: call)
        var args = visited.arguments
        if let i = args.firstIndex(where: { $0.label?.text == "action" }) {
            let action = args[i].expression
            if let closure = action.as(ClosureExprSyntax.self) {
                args[i].expression = ExprSyntax(Self.prefix(closure, with: register))
            } else if action.is(DeclReferenceExprSyntax.self) || action.is(MemberAccessExprSyntax.self) {
                args[i].expression = "{ \(register)\(action.trimmed)() }" // SwiftUI.Button's action is () -> Void
            } else {
                return ExprSyntax(visited)
            }
            return ExprSyntax(visited.with(\.arguments, args))
        }
        if let trailing = visited.trailingClosure {
            return ExprSyntax(visited.with(\.trailingClosure, Self.prefix(trailing, with: register)))
        }
        return ExprSyntax(visited)
    }

    static func prefix(_ closure: ClosureExprSyntax, with item: CodeBlockItemSyntax) -> ClosureExprSyntax {
        closure.with(\.statements, CodeBlockItemListSyntax([item] + Array(closure.statements)))
    }

    /// The resolved label when it passes VUButtonRewriter's privacy checks, else `"Button"`. `call` must be the
    /// original node: the extractor walks its parents for loop-bound names (`ForEach { row in ... Text(row) }`).
    static func register(for call: FunctionCallExprSyntax) -> CodeBlockItemSyntax {
        switch VULabelExtractor.resolveButtonLabel(for: call) {
        case .literal(let label)? where !VUButtonRewriter.isValueLikeLabel(label):
            return "VuButtonPressRegistry.shared.registerPress(label: \(literal: label)); "
        case .expression(let expr)? where !VUButtonRewriter.isValueLikeExpression(expr) && !VUButtonRewriter.containsSecureWord(expr):
            return "VuButtonPressRegistry.shared.registerPress(label: String(describing: \(raw: expr))); "
        default:
            return "VuButtonPressRegistry.shared.registerPress(label: \"Button\"); "
        }
    }

    /// True when the action (the `action:` argument, else the trailing closure) already calls a tracking API.
    static func reportsTap(_ call: FunctionCallExprSyntax) -> Bool {
        let action: Syntax? = call.arguments.first(where: { $0.label?.text == "action" }).map { Syntax($0.expression) }
            ?? call.trailingClosure.map(Syntax.init)
        return action?.tokens(viewMode: .sourceAccurate).contains {
            if case .identifier(let name) = $0.tokenKind { return trackingCalls.contains(name) }
            return false
        } ?? false
    }
}

/// `Toggle("Wi-Fi", isOn: $on)` -> `Toggle("Wi-Fi", isOn: $on).vuTrackControlLabel("Wi-Fi")`; likewise `Picker` and
/// `Stepper`, and a `Text("...")` label closure. SwiftUI never labels the UIKit control it renders, so without this
/// the SDK names the span `UISwitch` (or, for a menu picker, the selected option, which can be user data).
/// Fixed text only: an interpolated or computed title is skipped, as are secure-entry screens and `VU:skip`.
final class ControlLabelRewriter: SyntaxRewriter {
    let fileName: String
    init(fileName: String) { self.fileName = fileName }

    static let controls: Set<String> = ["Toggle", "Picker", "Stepper"]

    override func visit(_ call: FunctionCallExprSyntax) -> ExprSyntax {
        let visited = super.visit(call).cast(FunctionCallExprSyntax.self)
        guard let name = visited.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
              Self.controls.contains(name),
              let label = Self.label(of: visited), !VUButtonRewriter.isValueLikeLabel(label),
              !Self.isLabeled(call),
              !call.leadingTrivia.description.contains("VU:skip"),
              !VUButtonRewriter.isSecureEntryContext(call, fileName: fileName) else {
            return ExprSyntax(visited)
        }
        return "\(visited.trimmed).vuTrackControlLabel(\(literal: label))"
    }

    /// The title argument (`Toggle("Wi-Fi", ...)`), else the first `Text("...")` in the label closure.
    static func label(of call: FunctionCallExprSyntax) -> String? {
        if let title = call.arguments.first(where: { $0.label == nil })?.expression.as(StringLiteralExprSyntax.self) {
            return title.representedLiteralValue // nil when interpolated
        }
        let closure = call.arguments.first(where: { $0.label?.text == "label" })?.expression.as(ClosureExprSyntax.self)
            ?? (call.arguments.contains { $0.label == nil } ? nil : call.trailingClosure)
        let text = closure.flatMap { Syntax($0).firstTabTitle }
        // A Picker's trailing closure is its options, never its label.
        return call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "Picker"
            && closure == call.trailingClosure ? nil : text
    }

    /// Already followed by a hand-written `.vuTrackControlLabel(...)`.
    static func isLabeled(_ call: FunctionCallExprSyntax) -> Bool {
        call.parent?.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "vuTrackControlLabel"
    }
}

@main
struct VuTrackPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [VuTrackMacro.self, VuTrackBodyMacro.self]
}
