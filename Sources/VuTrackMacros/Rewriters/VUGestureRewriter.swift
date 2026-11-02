// Copied verbatim from Tools/VUSourceInstrumenterCore/VUGestureRewriter.swift on feature/instrumentor-production-hardening (fa6d6f8).
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftParser
import Foundation

/// SyntaxRewriter that visits `FunctionCallExprSyntax` nodes and rewrites raw
/// SwiftUI gesture usage to the `instrumentedXXX` modifiers added under
/// `Sources/vuTelemetry/UserInteraction/SwiftUI/Gestures/`.
///
/// Pass 4 in `VUInstrumentCommand.rewriteAll`, run after Button / Navigation /
/// DatePicker. Handles five of the six new gesture types:
///
/// 1. **Long Press** — `.onLongPressGesture(...)` is signature-compatible with
///    `.instrumentedLongPress(...)`, so this is a pure rename + `label:` insertion.
///    No closure relocation needed.
/// 2. **Drag** — `.gesture(DragGesture(...).onChanged{}.onEnded{})` is structurally
///    rewritten to `.instrumentedDrag(...)`, splicing the captured closures and
///    constructor args into the new call.
/// 3. **Magnification / Rotation** — same chain-rewrite shape as Drag, via
///    `MagnificationGesture(...)` / `RotationGesture(...)`.
/// 4. **Double Tap** — `.gesture(TapGesture(count: 2).onEnded { ... })` is rewritten
///    to `.instrumentedDoubleTap(label:) { ... }`, splicing the `onEnded` closure
///    body into the trailing `perform` closure (both `() -> Void`). Plain
///    `TapGesture()`/`TapGesture(count: 1)` (single tap) is left untouched.
///
/// **Swipe is intentionally not handled here** — there is no native `SwipeGesture`
/// and no reliable source pattern that distinguishes "drag" from "swipe" intent.
/// `instrumentedSwipe(...)` remains manual-only.
///
/// **Combinator restriction**: `.gesture(...)` chains using `.simultaneously`,
/// `.sequenced`, `.exclusively`, `.updating`, or any combinator other than
/// `.onChanged`/`.onEnded` are left untouched — `VUGestureChainParser` returns
/// `nil` for these and this rewriter skips them (optionally logging via
/// `VU_DEBUG`, matching `VUButtonRewriter`'s skip-logging convention).
///
/// **Idempotency**: each rewrite *replaces* the matched call with a differently
/// named call (`onLongPressGesture` → `instrumentedLongPress`, `gesture` →
/// `instrumentedDrag`/`instrumentedMagnification`/`instrumentedRotation`/`instrumentedDoubleTap`).
/// Re-running on an already-rewritten file is a true no-op: the old member names
/// no longer appear, so nothing matches.
final class VUGestureRewriter: SyntaxRewriter {

    // MARK: - Counters

    private(set) var longPressCount = 0
    private(set) var dragCount = 0
    private(set) var magnificationCount = 0
    private(set) var rotationCount = 0
    private(set) var doubleTapCount = 0

    var injectedCount: Int {
        longPressCount + dragCount + magnificationCount + rotationCount + doubleTapCount
    }

    private let debug = ProcessInfo.processInfo.environment["VU_DEBUG"] != nil

    // MARK: - Visitor

    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
        // Recurse first (bottom-up) so nested gesture chains are processed
        // before outer ones.
        let visited = super.visit(node)
        guard let call = visited.as(FunctionCallExprSyntax.self) else {
            return visited
        }

        guard let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self),
              let receiver = memberAccess.base else {
            return ExprSyntax(call)
        }

        switch memberAccess.declName.baseName.text {
        case "onLongPressGesture":
            return rewriteLongPress(call: call, memberAccess: memberAccess, receiver: receiver)
        case "gesture":
            return rewriteGestureModifier(call: call, memberAccess: memberAccess, receiver: receiver)
        default:
            return ExprSyntax(call)
        }
    }

    // MARK: - Long Press

    /// Rewrites `.onLongPressGesture(...)` to `.instrumentedLongPress(...)`.
    ///
    /// The argument list is rebuilt structurally (never by joining source text) from the
    /// understood labels only: `minimumDuration`, `maximumDistance`, `perform`, and the press-state
    /// callback which is spelled `pressing:` (legacy API) or `onPressingChanged:` (current API);
    /// `instrumentedLongPress` only knows `onPressingChanged:`. The unlabeled trailing closure is
    /// `perform`, an additional `onPressingChanged:` trailing closure is the press callback.
    /// Anything else (unknown label, duplicate, no `perform`, hand-written Vunet tracking in a
    /// closure) leaves the call untouched.
    private func rewriteLongPress(
        call: FunctionCallExprSyntax,
        memberAccess: MemberAccessExprSyntax,
        receiver: ExprSyntax
    ) -> ExprSyntax {
        if VUManualTrackingDetector.containsManualTracking(call.arguments)
            || call.trailingClosure.map({ VUManualTrackingDetector.containsManualTracking($0) }) == true
            || VUManualTrackingDetector.containsManualTracking(call.additionalTrailingClosures) {
            skipLog("long press handler already tracks with Vunet", call)
            return ExprSyntax(call)
        }

        var minimumDuration: String?
        var maximumDistance: String?
        var perform: String?
        var performIsTrailing = false
        var pressing: String?

        func text(_ node: some SyntaxProtocol) -> String {
            node.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for arg in call.arguments {
            guard let argLabel = arg.label?.text else { return ExprSyntax(call) }
            switch argLabel {
            case "minimumDuration":
                guard minimumDuration == nil else { return ExprSyntax(call) }
                minimumDuration = text(arg.expression)
            case "maximumDistance":
                guard maximumDistance == nil else { return ExprSyntax(call) }
                maximumDistance = text(arg.expression)
            case "perform":
                guard perform == nil else { return ExprSyntax(call) }
                perform = text(arg.expression)
            case "pressing", "onPressingChanged":
                guard pressing == nil else { return ExprSyntax(call) }
                pressing = text(arg.expression)
            default:
                return ExprSyntax(call)
            }
        }
        if let trailing = call.trailingClosure {
            // The unlabeled trailing closure is `perform`; if `perform:` was also written the
            // call shape is not one we understand.
            guard perform == nil else { return ExprSyntax(call) }
            perform = text(trailing)
            performIsTrailing = true
        }
        for extra in call.additionalTrailingClosures {
            guard extra.label.text == "onPressingChanged" || extra.label.text == "pressing" || extra.label.text == "perform",
                  extra.label.text != "perform" || perform == nil,
                  extra.label.text == "perform" || pressing == nil else { return ExprSyntax(call) }
            if extra.label.text == "perform" {
                perform = text(extra.closure)
            } else {
                pressing = text(extra.closure)
            }
            performIsTrailing = false
        }
        guard let performText = perform else { return ExprSyntax(call) }

        // Declaration order of instrumentedLongPress: minimumDuration, maximumDistance, label, ..., perform, onPressingChanged.
        var args: [String] = []
        if let minimumDuration { args.append("minimumDuration: \(minimumDuration)") }
        if let maximumDistance { args.append("maximumDistance: \(maximumDistance)") }
        if let label = VUGestureLabelExtractor.extract(from: receiver) {
            args.append("label: \"\(escapeStringLiteral(label))\"")
        }
        var trailing = ""
        if performIsTrailing && pressing == nil {
            trailing = " " + performText
        } else {
            args.append("perform: \(performText)")
            if let pressing { args.append("onPressingChanged: \(pressing)") }
        }

        let newSource = "(__placeholder__).instrumentedLongPress(\(args.joined(separator: ", ")))\(trailing)"
        guard let rewritten = splice(newSource: newSource, receiver: receiver, originalMemberAccess: memberAccess, fallback: call) else {
            return ExprSyntax(call)
        }

        longPressCount += 1
        return rewritten
    }

    // MARK: - .gesture(...) chain rewrites (Drag / Magnification / Rotation)

    private func rewriteGestureModifier(
        call: FunctionCallExprSyntax,
        memberAccess: MemberAccessExprSyntax,
        receiver: ExprSyntax
    ) -> ExprSyntax {
        guard call.arguments.count == 1,
              let argExpr = call.arguments.first?.expression,
              call.trailingClosure == nil else {
            return ExprSyntax(call)
        }

        if let parsed = VUGestureChainParser.parse(rootGestureName: "DragGesture", expr: argExpr) {
            return rewriteChain(
                call: call,
                memberAccess: memberAccess,
                receiver: receiver,
                parsed: parsed,
                newModifierName: "instrumentedDrag",
                // Order matches instrumentedDrag's declaration order: coordinateSpace before minimumDistance.
                constructorArgMapping: [
                    (source: "coordinateSpace", target: "coordinateSpace"),
                    (source: "minimumDistance", target: "minimumDistance")
                ]
            ) { [weak self] in self?.dragCount += 1 }
        }

        if let parsed = VUGestureChainParser.parse(rootGestureName: "MagnificationGesture", expr: argExpr) {
            return rewriteChain(
                call: call,
                memberAccess: memberAccess,
                receiver: receiver,
                parsed: parsed,
                newModifierName: "instrumentedMagnification",
                constructorArgMapping: [
                    (source: "minimumScaleDelta", target: "minimumScaleDelta")
                ]
            ) { [weak self] in self?.magnificationCount += 1 }
        }

        if let parsed = VUGestureChainParser.parse(rootGestureName: "RotationGesture", expr: argExpr) {
            return rewriteChain(
                call: call,
                memberAccess: memberAccess,
                receiver: receiver,
                parsed: parsed,
                newModifierName: "instrumentedRotation",
                constructorArgMapping: [
                    (source: "minimumAngleDelta", target: "minimumAngleDelta")
                ]
            ) { [weak self] in self?.rotationCount += 1 }
        }

        if let parsed = VUGestureChainParser.parse(rootGestureName: "TapGesture", expr: argExpr),
           parsed.onChanged == nil,
           parsed.onEnded != nil,
           isIntegerLiteral(parsed.constructorArgs["count"], equalTo: 2) {
            return rewriteDoubleTap(call: call, memberAccess: memberAccess, receiver: receiver, parsed: parsed)
        }

        if debug {
            let argDesc = argExpr.description
            let knownGestures = ["DragGesture(", "MagnificationGesture(", "RotationGesture(", "TapGesture("]
            if knownGestures.contains(where: argDesc.contains) {
                let preview = argDesc.prefix(150).replacingOccurrences(of: "\n", with: " ")
                print("[VUGestureRewriter] Skipped (combinator chain or multiple combined gestures): \(preview)")
            }
        }

        return ExprSyntax(call)
    }

    // MARK: - Double Tap (`.gesture(TapGesture(count: 2).onEnded { ... })`)

    /// Rewrites `.gesture(TapGesture(count: 2).onEnded { ... })` to
    /// `.instrumentedDoubleTap(label:) { ... }`.
    ///
    /// `TapGesture.onEnded` is `(()) -> Void`, `instrumentedDoubleTap`'s `perform` is `() -> Void`.
    /// A closure with no parameter list is passed through. A closure that declares the (always
    /// `Void`) value parameter (`_ in`, `value in`, `(_) in`, `() in`) has that parameter removed
    /// when the body never uses it (named parameter or `$0`); if it is used the call is skipped.
    private func rewriteDoubleTap(
        call: FunctionCallExprSyntax,
        memberAccess: MemberAccessExprSyntax,
        receiver: ExprSyntax,
        parsed: VUGestureChainParser.ParsedChain
    ) -> ExprSyntax {
        guard let onEnded = parsed.onEnded,
              parsed.unlabeledConstructorArgCount == 0,
              Set(parsed.constructorArgs.keys) == ["count"] else { return ExprSyntax(call) }

        if VUManualTrackingDetector.containsManualTracking(onEnded) {
            skipLog("double tap handler already tracks with Vunet", call)
            return ExprSyntax(call)
        }
        guard let perform = closureWithoutVoidParameter(onEnded) else {
            skipLog("double tap closure uses its value parameter", call)
            return ExprSyntax(call)
        }

        var args: [String] = []
        if let label = VUGestureLabelExtractor.extract(from: receiver) {
            args.append("label: \"\(escapeStringLiteral(label))\"")
        }

        let performDesc = perform.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSource = "(__placeholder__).instrumentedDoubleTap(\(args.joined(separator: ", "))) \(performDesc)"

        guard let rewritten = splice(newSource: newSource, receiver: receiver, originalMemberAccess: memberAccess, fallback: call) else {
            return ExprSyntax(call)
        }

        doubleTapCount += 1
        return rewritten
    }

    /// Returns `closure` adapted to `() -> Void`, or `nil` if it cannot be adapted safely.
    private func closureWithoutVoidParameter(_ closure: ClosureExprSyntax) -> ClosureExprSyntax? {
        // `$0` / `$1` anywhere in the body means the value is consumed.
        let bodyTokens = closure.statements.tokens(viewMode: .sourceAccurate)
        if bodyTokens.contains(where: { $0.text.hasPrefix("$") && $0.text.dropFirst().allSatisfy(\.isNumber) && $0.text.count > 1 }) {
            return nil
        }
        guard let signature = closure.signature else { return closure }
        // Return clauses / effects (`async`, `throws`) would be left dangling or change the type.
        guard signature.returnClause == nil, signature.effectSpecifiers == nil else { return nil }

        var paramNames: [String] = []
        switch signature.parameterClause {
        case .none:
            break
        case .simpleInput(let list):
            paramNames = list.map { $0.name.text }
        case .parameterClause(let clause):
            // `(_ v: Void)` / `(v)` / `()`; secondary names are what the body sees.
            paramNames = clause.parameters.map { ($0.secondName ?? $0.firstName).text }
        }
        guard paramNames.count <= 1 else { return nil }
        if let name = paramNames.first, name != "_" {
            let used = closure.statements.tokens(viewMode: .sourceAccurate).contains { $0.text == name }
            if used { return nil }
        }

        var newSignature = signature.with(\.parameterClause, nil)
        if newSignature.attributes.isEmpty && newSignature.capture == nil {
            return closure.with(\.signature, nil)
        }
        // Keep `[weak self] in` / `@MainActor in` with exactly one space before `in`.
        newSignature = newSignature.with(\.inKeyword, newSignature.inKeyword.with(\.leadingTrivia, []))
        if let capture = newSignature.capture {
            newSignature = newSignature.with(\.capture, capture.with(\.trailingTrivia, .space))
        }
        return closure.with(\.signature, newSignature)
    }

    /// Rewrites `.gesture(<RootGesture>(...).onChanged{}.onEnded{})` to
    /// `.instrumentedXXX(label:, <constructor args>, onChanged:, onEnded:)`,
    /// preserving the receiver and the original `.` token's leading trivia
    /// (indentation/line breaks).
    private func rewriteChain(
        call: FunctionCallExprSyntax,
        memberAccess: MemberAccessExprSyntax,
        receiver: ExprSyntax,
        parsed: VUGestureChainParser.ParsedChain,
        newModifierName: String,
        constructorArgMapping: [(source: String, target: String)],
        onSuccess: () -> Void
    ) -> ExprSyntax {
        // Only constructor shapes we fully understand: every argument labeled with a known label.
        guard parsed.unlabeledConstructorArgCount == 0,
              Set(parsed.constructorArgs.keys).isSubset(of: Set(constructorArgMapping.map { $0.source })) else {
            skipLog("unsupported gesture constructor arguments", call)
            return ExprSyntax(call)
        }
        // `DragGesture(coordinateSpace:)` is typed `CoordinateSpace` in `instrumentedDrag`; iOS 17
        // `.scrollView`, `NamedCoordinateSpace` values and arbitrary expressions do not fit.
        if let space = parsed.constructorArgs["coordinateSpace"], !isPlainCoordinateSpace(space) {
            skipLog("coordinateSpace is not .local/.global/.named(_)", call)
            return ExprSyntax(call)
        }
        // A handler that already records its own event must not be wrapped (double events).
        for closure in [parsed.onChanged, parsed.onEnded] {
            if let closure, VUManualTrackingDetector.containsManualTracking(closure) {
                skipLog("gesture handler already tracks with Vunet", call)
                return ExprSyntax(call)
            }
        }

        var args: [String] = []

        if let label = VUGestureLabelExtractor.extract(from: receiver) {
            args.append("label: \"\(escapeStringLiteral(label))\"")
        }

        // Iterated in the order declared by the caller, matching instrumentedXXX's
        // parameter declaration order.
        for (sourceLabel, targetLabel) in constructorArgMapping {
            if let expr = parsed.constructorArgs[sourceLabel] {
                let exprDesc = expr.description.trimmingCharacters(in: .whitespacesAndNewlines)
                args.append("\(targetLabel): \(exprDesc)")
            }
        }

        if let onChanged = parsed.onChanged {
            args.append("onChanged: \(onChanged.description.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let onEnded = parsed.onEnded {
            args.append("onEnded: \(onEnded.description.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let newSource = "(__placeholder__).\(newModifierName)(\(args.joined(separator: ", ")))"

        guard let rewritten = splice(newSource: newSource, receiver: receiver, originalMemberAccess: memberAccess, fallback: call) else {
            return ExprSyntax(call)
        }

        onSuccess()
        return rewritten
    }

    // MARK: - Helpers

    private func skipLog(_ reason: String, _ call: FunctionCallExprSyntax) {
        guard debug else { return }
        let preview = call.description.prefix(150).replacingOccurrences(of: "\n", with: " ")
        print("[VUGestureRewriter] Skipped (\(reason)): \(preview)")
    }

    /// `.local`, `.global`, `.named(x)` (optionally `CoordinateSpace.`-qualified).
    private func isPlainCoordinateSpace(_ expr: ExprSyntax) -> Bool {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard isCoordinateSpaceBase(member.base) else { return false }
            return ["local", "global"].contains(member.declName.baseName.text)
        }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self),
           isCoordinateSpaceBase(member.base),
           member.declName.baseName.text == "named",
           call.arguments.count == 1, call.trailingClosure == nil {
            return true
        }
        return false
    }

    private func isCoordinateSpaceBase(_ base: ExprSyntax?) -> Bool {
        guard let base else { return true }
        return base.as(DeclReferenceExprSyntax.self)?.baseName.text == "CoordinateSpace"
    }

    /// Parses `newSource` (of the form `(__placeholder__).newModifier(...)<trailing closures>`),
    /// substitutes `receiver` for the placeholder base, and carries over the
    /// original `.` token's leading trivia so the rewritten call keeps its
    /// original line/indentation.
    private func splice(
        newSource: String,
        receiver: ExprSyntax,
        originalMemberAccess: MemberAccessExprSyntax,
        fallback: FunctionCallExprSyntax
    ) -> ExprSyntax? {
        let tempSource = Parser.parse(source: newSource)
        guard let chainedExpr = tempSource.statements.first?.item.as(ExprSyntax.self),
              let chainedCall = chainedExpr.as(FunctionCallExprSyntax.self),
              let chainedMember = chainedCall.calledExpression.as(MemberAccessExprSyntax.self) else {
            return nil
        }

        let newMember = chainedMember
            .with(\.base, receiver)
            .with(\.period, chainedMember.period.with(\.leadingTrivia, originalMemberAccess.period.leadingTrivia))

        let newChained = chainedCall.with(\.calledExpression, ExprSyntax(newMember))
        return ExprSyntax(newChained)
    }

    /// Returns the source text of `call`'s trailing closure(s) (single
    /// trailing closure plus any additional labeled trailing closures),
    /// or an empty string if none.
    private func trailingClosuresSource(of call: FunctionCallExprSyntax) -> String {
        var result = ""
        if let trailing = call.trailingClosure {
            result += " " + trailing.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !call.additionalTrailingClosures.isEmpty {
            result += " " + call.additionalTrailingClosures.description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func escapeStringLiteral(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Returns `true` if `expr` is an integer literal whose digits equal `value`
    /// (e.g. `2`, `0x2`, `2_0` all match `value: 2`). `nil` never matches.
    private func isIntegerLiteral(_ expr: ExprSyntax?, equalTo value: Int) -> Bool {
        guard let literal = expr?.as(IntegerLiteralExprSyntax.self) else { return false }
        let digits = literal.literal.text.replacingOccurrences(of: "_", with: "")
        if let parsed = Int(digits) { return parsed == value }
        if digits.hasPrefix("0x"), let parsed = Int(digits.dropFirst(2), radix: 16) { return parsed == value }
        return false
    }
}
