// Copied verbatim from Tools/VUSourceInstrumenterCore/VUGestureLabelExtractor.swift on feature/instrumentor-production-hardening (fa6d6f8).
import Foundation
import SwiftSyntax

/// Infers a human-readable `label:` argument for gesture instrumentation by
/// inspecting the *receiver* expression a gesture modifier is attached to
/// (e.g. the `Text("Delete")` in `Text("Delete").gesture(...)`).
///
/// Gestures attach to arbitrary views (not just typed controls with
/// `title:`/`label:` arguments like Button), so this reuses
/// `VULabelExtractor`'s lower-level primitives — `collectTextLiterals` and
/// `extractImageLabel` — directly against the receiver subtree rather than a
/// call's argument list.
enum VUGestureLabelExtractor {

    /// Returns the best label string for `receiver`, or `nil` if no suitable
    /// text is found (e.g. `Color`, `Rectangle`, custom shapes with no
    /// `Text`/`Image(systemName:)`).
    ///
    /// `label:` is only ever an *additive* argument in the rewriter — `nil`
    /// here means the rewritten call simply omits `label:`, and
    /// `GestureSpanFactory` falls back to `screenName` at runtime.
    static func extract(from receiver: ExprSyntax) -> String? {
        // Strategy 1 — Text("...") literal anywhere in the receiver subtree.
        let texts = VULabelExtractor.collectTextLiterals(from: Syntax(receiver))
        if let best = VULabelExtractor.selectBest(from: texts) {
            return best
        }

        // Strategy 2 — Image(systemName:) → human-readable label, anywhere in
        // the receiver subtree (mirrors Button's icon-only Strategy 5).
        if let imageLabel = VULabelExtractor.extractImageLabel(from: Syntax(receiver)) {
            return imageLabel
        }

        return nil
    }
}
