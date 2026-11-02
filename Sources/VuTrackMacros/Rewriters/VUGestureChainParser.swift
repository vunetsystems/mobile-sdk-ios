// Copied verbatim from Tools/VUSourceInstrumenterCore/VUGestureChainParser.swift on feature/instrumentor-production-hardening (fa6d6f8).
import Foundation
import SwiftSyntax

/// Shared helper that parses a `.gesture(<RootGesture>(...).onChanged{}.onEnded{})`
/// chain into its constructor arguments and `onChanged`/`onEnded` closures.
///
/// Used by `VUGestureRewriter` for Drag, Magnification, and Rotation — all three
/// share the same `<RootGesture>(...)`  →  `.onChanged { }`  →  `.onEnded { }`
/// shape, differing only in the constructor name and its argument labels.
///
/// Returns `nil` (parse failure) when the chain contains any other combinator
/// (`.simultaneously`, `.sequenced`, `.exclusively`, `.updating`, etc.) or
/// doesn't terminate in a call to `rootGestureName` — these chains are too
/// structurally varied to rewrite safely and are left untouched by the caller.
enum VUGestureChainParser {

    struct ParsedChain {
        /// Constructor argument expressions, keyed by parameter label
        /// (e.g. `"minimumDistance"`, `"coordinateSpace"`, `"minimumScaleDelta"`).
        var constructorArgs: [String: ExprSyntax] = [:]
        var onChanged: ClosureExprSyntax?
        var onEnded: ClosureExprSyntax?
        /// Number of root-constructor arguments without a label (e.g. `DragGesture(10)`); the
        /// rewriters treat any such argument as "not statically understood" and skip.
        var unlabeledConstructorArgCount = 0
    }

    /// Parses `expr`, expecting it to be a chain rooted at a call to
    /// `rootGestureName` (e.g. `"DragGesture"`) with zero or more
    /// `.onChanged { }` / `.onEnded { }` calls layered on top, in either order.
    static func parse(rootGestureName: String, expr: ExprSyntax) -> ParsedChain? {
        var current = expr
        var chain = ParsedChain()

        while true {
            guard let call = current.as(FunctionCallExprSyntax.self) else {
                return nil
            }

            if let memberAccess = call.calledExpression.as(MemberAccessExprSyntax.self) {
                let methodName = memberAccess.declName.baseName.text
                guard let base = memberAccess.base else { return nil }

                switch methodName {
                case "onChanged":
                    guard chain.onChanged == nil, let closure = closureArgument(of: call) else { return nil }
                    chain.onChanged = closure
                    current = base
                    continue
                case "onEnded":
                    guard chain.onEnded == nil, let closure = closureArgument(of: call) else { return nil }
                    chain.onEnded = closure
                    current = base
                    continue
                default:
                    // .simultaneously / .sequenced / .exclusively / .updating / etc. —
                    // too structurally varied to rewrite safely.
                    return nil
                }
            }

            // Root constructor call: DragGesture(...) / MagnificationGesture(...) / RotationGesture(...)
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
               ref.baseName.text == rootGestureName {
                // A trailing closure on the root constructor is not a valid gesture initializer shape.
                guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else { return nil }
                for arg in call.arguments {
                    if let label = arg.label?.text {
                        // Duplicate labels cannot compile; refuse rather than pick one.
                        guard chain.constructorArgs[label] == nil else { return nil }
                        chain.constructorArgs[label] = arg.expression
                    } else {
                        chain.unlabeledConstructorArgCount += 1
                    }
                }
                return chain
            }

            return nil
        }
    }

    /// The handler closure of an `.onChanged`/`.onEnded` call, only when the call has exactly one
    /// closure literal and nothing else: `.onEnded { }` or `.onEnded({ })`. A function reference
    /// (`.onEnded(handler)`), a labeled argument or extra arguments are not understood -> `nil`.
    private static func closureArgument(of call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
        guard call.additionalTrailingClosures.isEmpty else { return nil }
        if let trailing = call.trailingClosure {
            return call.arguments.isEmpty ? trailing : nil
        }
        guard call.arguments.count == 1,
              let first = call.arguments.first,
              first.label == nil,
              let closure = first.expression.as(ClosureExprSyntax.self) else { return nil }
        return closure
    }
}

/// Detects hand-written Vunet tracking inside a syntax subtree. The instrumenter must not wrap a
/// gesture whose handler already records its own event (e.g. vuPay's `SwipeToConfirmButton`
/// calls `Vunet.recordClickEvent` in `onEnded`), otherwise every interaction is emitted twice.
enum VUManualTrackingDetector {

    /// True when any identifier token in `node` is `Vunet`, `recordClickEvent`, a `Vu<Upper>...`
    /// symbol (VuToggle, VuAsyncImage, ...) or an `instrumented...` modifier.
    static func containsManualTracking<S: SyntaxProtocol>(_ node: S) -> Bool {
        for token in node.tokens(viewMode: .sourceAccurate) {
            guard case .identifier(let name) = token.tokenKind else { continue }
            if isTrackingIdentifier(name) { return true }
        }
        return false
    }

    static func isTrackingIdentifier(_ name: String) -> Bool {
        if name == "Vunet" || name == "recordClickEvent" { return true }
        if name.hasPrefix("instrumented") { return true }
        if name.hasPrefix("Vu"), let third = name.dropFirst(2).first, third.isUppercase { return true }
        return false
    }
}
