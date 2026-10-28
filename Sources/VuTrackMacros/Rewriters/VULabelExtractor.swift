// Copied verbatim from Tools/VUSourceInstrumenterCore/VULabelExtractor.swift on feature/instrumentor-production-hardening (fa6d6f8).
import Foundation
import SwiftSyntax

/// Extracts the most meaningful human-readable label string from a
/// SwiftUI Button call's syntax tree.
///
/// Handles all Button call patterns:
///   Button("Title") { action }
///   Button("Title", action: { })
///   Button(action: { }) { Text("Title") }
///   Button { action } label: { Text("Title") }
///   Button { action } label: { HStack { Image(...); Text("Title") } }
enum VULabelExtractor {

    // MARK: - Public API

    /// Returns the best label string for this Button call, or nil if
    /// no suitable text is found (icon-only buttons, dynamic labels).
    static func extract(from call: FunctionCallExprSyntax) -> String? {
        let debug = ProcessInfo.processInfo.environment["VU_DEBUG"] != nil

        if debug {
            print("[VULabelExtractor.extract] ——— Starting extraction ———")
            print("[VULabelExtractor.extract] args.count=\(call.arguments.count)")
            print("[VULabelExtractor.extract] trailing=\(call.trailingClosure != nil)")
            print("[VULabelExtractor.extract] additionalTrailing=\(call.additionalTrailingClosures.count)")
        }

        // Strategy 1 — String literal as first positional argument
        // Covers: Button("Submit") { } and Button("Submit", action: { })
        if let title = extractTitleArgument(from: call) {
            if debug { print("[VULabelExtractor.extract] ✓ Strategy 1: Found title='\(title)'") }
            return title
        }
        if debug { print("[VULabelExtractor.extract] ✗ Strategy 1: No title argument") }

        // Strategy 2 — label: { } named argument containing Text literals
        // Covers: Button(action: { }) { Text("Submit") }
        //         Button { action } label: { Text("Submit") }
        if let labelClosure = findLabelClosure(in: call) {
            if debug { print("[VULabelExtractor.extract] ✓ Strategy 2: Found label closure") }
            let texts = collectTextLiterals(from: Syntax(labelClosure))
            if debug { print("[VULabelExtractor.extract] Strategy 2: Text literals found: \(texts)") }
            if let best = selectBest(from: texts) {
                if debug { print("[VULabelExtractor.extract] ✓ Strategy 2: Selected text='\(best)'") }
                return best
            }
        } else {
            if debug { print("[VULabelExtractor.extract] ✗ Strategy 2: No label closure found") }
        }

        // Strategy 3 — trailing closure containing Text literals
        // Covers: Button { Text("Submit") } (single trailing, no action arg)
        // NOTE: In the common Button(action:label:) pattern, the trailing
        // closure is the label. In Button { action } label: { label }, the
        // trailing closure is the action — Strategy 2 handles that case.
        if let trailing = call.trailingClosure {
            if debug { print("[VULabelExtractor.extract] Trying Strategy 3: trailing closure") }
            let texts = collectTextLiterals(from: Syntax(trailing))
            if debug { print("[VULabelExtractor.extract] Strategy 3: Text literals: \(texts)") }
            if let best = selectBest(from: texts) {
                if debug { print("[VULabelExtractor.extract] ✓ Strategy 3: Found text='\(best)'") }
                return best
            }
        }

        // Strategy 4 — custom wrapper with title:/label: + action:
        if let customStatic = extractStaticFromCustomWrapper(call) {
            if debug { print("[VULabelExtractor.extract] ✓ Strategy 4: Custom wrapper='\(customStatic)'") }
            return customStatic
        }

        // Strategy 5 — Image(systemName:) in label closure (icon-only buttons)
        // Runs after Strategies 1-4 to catch buttons whose label contains only
        // an Image (no Text views), e.g. eye/toggle, close, refresh icons.
        if let labelClosure = findLabelClosure(in: call) {
            if debug { print("[VULabelExtractor.extract] Strategy 5: Checking label closure for Image") }
            if let imageLabel = extractImageLabel(labelClosure) {
                if debug { print("[VULabelExtractor.extract] ✓ Strategy 5: Image label='\(imageLabel)'") }
                return imageLabel
            } else {
                if debug { print("[VULabelExtractor.extract] ✗ Strategy 5: No image label found in closure") }
            }
        } else {
            if debug { print("[VULabelExtractor.extract] ✗ Strategy 5: No label closure for image check") }
        }

        // No text found — icon-only or fully dynamic label
        if debug { print("[VULabelExtractor.extract] ✗ ALL STRATEGIES FAILED") }
        return nil
    }

    /// Returns a dynamic label expression (e.g. `title`) when no static
    /// string literal can be extracted. This enables instrumentation for
    /// reusable wrappers like `BFSIButton(title: ..., action: ...)`.
    static func extractDynamicExpression(from call: FunctionCallExprSyntax) -> String? {

        // Strategy 0 — custom wrapper with title:/label: + action:
        if let customDynamic = extractDynamicFromCustomWrapper(call) {
            return customDynamic
        }

        // Strategy 1 — dynamic first positional argument
        if let expr = extractDynamicTitleArgument(from: call) {
            return expr
        }

        // Strategy 2 — dynamic Text(...) argument inside label closure
        if let labelClosure = findLabelClosure(in: call) {
            let exprs = collectTextArgumentExpressions(from: Syntax(labelClosure))
            if let best = selectBestExpression(from: exprs) {
                return best
            }
        }

        // Strategy 3 — trailing closure fallback
        if let trailing = call.trailingClosure {
            let exprs = collectTextArgumentExpressions(from: Syntax(trailing))
            if let best = selectBestExpression(from: exprs) {
                return best
            }
        }

        return nil
    }

    private static func extractStaticFromCustomWrapper(_ call: FunctionCallExprSyntax) -> String? {
        let hasActionArg = call.arguments.contains { $0.label?.text == "action" }
        guard hasActionArg else { return nil }

        for arg in call.arguments {
            let argLabel = arg.label?.text
            guard argLabel == "title" || argLabel == "label" else { continue }

            if let stringLiteral = arg.expression.as(StringLiteralExprSyntax.self) {
                let text = extractString(from: stringLiteral)
                if !text.isEmpty && !isSFSymbolLike(text) {
                    return text
                }
            }
        }

        return nil
    }

    private static func extractDynamicFromCustomWrapper(_ call: FunctionCallExprSyntax) -> String? {
        let hasActionArg = call.arguments.contains { $0.label?.text == "action" }
        guard hasActionArg else { return nil }

        for arg in call.arguments {
            let argLabel = arg.label?.text
            guard argLabel == "title" || argLabel == "label" else { continue }

            if arg.expression.as(StringLiteralExprSyntax.self) != nil {
                continue
            }

            let exprText = arg.expression.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !exprText.isEmpty {
                return exprText
            }
        }

        return nil
    }

    // MARK: - Strategy implementations

    /// Extracts a string literal from the first positional argument.
    /// Button("Submit") { } → "Submit"
    private static func extractTitleArgument(
        from call: FunctionCallExprSyntax
    ) -> String? {
        guard let firstArg = call.arguments.first else { return nil }

        // Accept unlabeled first argument or argument with no meaningful label
        let label = firstArg.label?.text
        guard label == nil || label == "_" || label == "title" else {
            return nil
        }

        guard let stringLiteral = firstArg.expression
            .as(StringLiteralExprSyntax.self) else {
            return nil
        }

        let text = extractString(from: stringLiteral)
        guard !text.isEmpty, !isSFSymbolLike(text) else { return nil }
        return text
    }

    private static func extractDynamicTitleArgument(
        from call: FunctionCallExprSyntax
    ) -> String? {
        guard let firstArg = call.arguments.first else { return nil }

        let label = firstArg.label?.text
        guard label == nil || label == "_" || label == "title" else {
            return nil
        }

        // Static literals are handled by extractTitleArgument; this path is for dynamic expressions only.
        if firstArg.expression.as(StringLiteralExprSyntax.self) != nil {
            return nil
        }

        let expr = firstArg.expression.description
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return expr.isEmpty ? nil : expr
    }

    /// Finds the closure associated with the `label:` parameter.
    /// Handles all three Button initialization patterns:
    ///   1. Button(action: {}) { label }          - action arg + trailing label
    ///   2. Button(action: {}, label: {})         - explicit label arg
    ///   3. Button { action } label: { label }    - multiple trailing closures
    private static func findLabelClosure(
        in call: FunctionCallExprSyntax
    ) -> ClosureExprSyntax? {
        let debug = ProcessInfo.processInfo.environment["VU_DEBUG"] != nil

        if debug {
            print("[VULabelExtractor.findLabelClosure] ——— Finding label closure ———")
            print("[VULabelExtractor.findLabelClosure] args=\(call.arguments.count) trailing=\(call.trailingClosure != nil) additionalTrailing=\(call.additionalTrailingClosures.count)")
        }

        // Pattern 3: Multiple trailing closures without arguments
        // Button { action } label: { label }
        // Detect by: no arguments + both trailing and additional closures present
        if call.arguments.isEmpty {
            if let _ = call.trailingClosure, !call.additionalTrailingClosures.isEmpty {
                if debug { print("[VULabelExtractor.findLabelClosure] Pattern 3: Checking additionalTrailingClosures") }
                for atc in call.additionalTrailingClosures {
                    if debug { print("[VULabelExtractor.findLabelClosure] Pattern 3:   Found labeled closure: '\(atc.label.text)'") }
                    if atc.label.text == "label" {
                        if debug { print("[VULabelExtractor.findLabelClosure] ✓ Pattern 3: Found label closure!") }
                        return atc.closure
                    }
                }
            }
        }

        // Pattern 1: Check labeled arguments Button(action: {}) { label content }
        // The trailing closure in this form is the label.
        // Distinguish by checking if there is an `action:` argument.
        let hasActionArg = call.arguments.contains {
            $0.label?.text == "action"
        }
        if debug { print("[VULabelExtractor.findLabelClosure] Pattern 1: hasActionArg=\(hasActionArg)") }
        if hasActionArg, let trailing = call.trailingClosure {
            if debug { print("[VULabelExtractor.findLabelClosure] ✓ Pattern 1: Using trailing as label") }
            return trailing
        }

        // Pattern 2: Check explicit label: argument
        // Button(action: { ... }, label: { ... })
        if debug { print("[VULabelExtractor.findLabelClosure] Pattern 2: Checking explicit label: argument") }
        for arg in call.arguments {
            if arg.label?.text == "label",
               let closure = arg.expression.as(ClosureExprSyntax.self) {
                if debug { print("[VULabelExtractor.findLabelClosure] ✓ Pattern 2: Found explicit label: argument") }
                return closure
            }
        }

        // Fallback: Multiple trailing closures with some arguments present
        // (e.g., Button(someArg: value) { action } label: { label })
        if debug { print("[VULabelExtractor.findLabelClosure] Fallback: Checking additionalTrailingClosures") }
        for trailing in call.additionalTrailingClosures {
            if debug { print("[VULabelExtractor.findLabelClosure] Fallback:   Found labeled closure: '\(trailing.label.text)'") }
            if trailing.label.text == "label" {
                if debug { print("[VULabelExtractor.findLabelClosure] ✓ Fallback: Found label closure!") }
                return trailing.closure
            }
        }

        if debug { print("[VULabelExtractor.findLabelClosure] ✗ No label closure found") }
        return nil
    }

    // MARK: - Text literal collection

    /// Recursively collects all string literals that appear as the
    /// content argument of a Text(...) call within a syntax subtree.
    ///
    /// We specifically look for Text("literal") patterns rather than
    /// collecting ALL string literals in the closure, to avoid capturing
    /// systemName: "globe" Image arguments, color names, identifiers, etc.
    static func collectTextLiterals(from node: Syntax) -> [String] {
        var results: [String] = []

        // Check if this node is a Text("...") function call
        if let call = node.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Text",
           let firstArg = call.arguments.first,
           let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self) {
            let text = extractString(from: stringLiteral)
            if !text.isEmpty {
                results.append(text)
            }
        }

        // Recurse into all children
        for child in node.children(viewMode: .sourceAccurate) {
            results += collectTextLiterals(from: child)
        }

        return results
    }

    /// Recursively collects argument expressions used by Text(...)
    /// where the first argument is not a string literal.
    private static func collectTextArgumentExpressions(from node: Syntax) -> [String] {
        var results: [String] = []

        if let call = node.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Text",
           let firstArg = call.arguments.first,
           firstArg.expression.as(StringLiteralExprSyntax.self) == nil {
            let expr = firstArg.expression.description
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !expr.isEmpty {
                results.append(expr)
            }
        }

        for child in node.children(viewMode: .sourceAccurate) {
            results += collectTextArgumentExpressions(from: child)
        }

        return results
    }

    // MARK: - String extraction

    /// Extracts the raw string value from a StringLiteralExprSyntax,
    /// handling both simple ("text") and interpolated ("\(expr)") literals.
    /// For interpolated strings, returns the static prefix if meaningful,
    /// otherwise returns empty string (interpolated = dynamic = skip).
    private static func extractString(from literal: StringLiteralExprSyntax) -> String {
        var result = ""
        for segment in literal.segments {
            switch segment {
            case .stringSegment(let seg):
                result += seg.content.text
            case .expressionSegment:
                // Dynamic interpolation — this label is not statically known
                // Return what we have so far; caller will score it
                // If result is empty at this point, the whole string is dynamic
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Candidate selection

    /// Selects the most meaningful string from a list of candidates.
    /// Scoring: multi-word strings > strings with uppercase > URL-like > longer
    /// SF Symbol-like strings (single lowercase word) are filtered out first.
    static func selectBest(from candidates: [String]) -> String? {
        let filtered = candidates.filter { !isSFSymbolLike($0) }
        let pool = filtered.isEmpty ? candidates : filtered
        return pool.first
    }

    private static func selectBestExpression(from candidates: [String]) -> String? {
        let pool = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Prefer simple identifiers/member access over heavier expressions.
        if let simple = pool.first(where: { isSimpleExpression($0) }) {
            return simple
        }
        return pool.first
    }

    private static func isSimpleExpression(_ text: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        return !text.isEmpty && text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func score(_ text: String) -> Int {
        var s = 0
        if text.contains(" ")                              { s += 100 } // multi-word
        if text.contains(where: { $0.isUppercase })        { s +=  50 } // proper label
        if text.contains("/") || text.contains(".")        { s +=  30 } // endpoint/path
        if text.contains(where: { $0.isNumber })           { s +=  10 } // version/id
        s += min(text.count, 40)                                        // length bonus
        return s
    }

    /// Returns true for strings that look like SF Symbol names:
    /// single lowercase token, no spaces, under 40 chars.
    /// Examples: "globe", "bolt.fill", "arrow.right.circle"
    static func isSFSymbolLike(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return true }
        // SF Symbol names never contain spaces and are always lowercase
        // Real button labels almost always have spaces or uppercase
        return !t.contains(" ") && t == t.lowercased() && t.count < 40
    }

    // MARK: - Image label extraction (Strategy 5)

    /// Walks a label closure looking for `Image(systemName:)` calls.
    /// Handles plain `StringLiteralExprSyntax` and `TernaryExprSyntax` values.
    /// For a ternary `condition ? "eye.fill" : "eye.slash.fill"`, the **then**
    /// branch drives the final human-readable label; the else branch is ignored.
    /// Returns `nil` when no `Image(systemName:)` call exists in the closure.
    static func extractImageLabel(_ closure: ClosureExprSyntax) -> String? {
        return extractImageLabel(from: Syntax(closure))
    }

    /// Same as `extractImageLabel(_:ClosureExprSyntax)` but operates on any
    /// syntax subtree (e.g. an arbitrary view-modifier-chain receiver), not
    /// just a label closure.
    static func extractImageLabel(from node: Syntax) -> String? {
        let debug = ProcessInfo.processInfo.environment["VU_DEBUG"] != nil

        var candidates: [(thenName: String, elseName: String?)] = []

        if debug { print("[VULabelExtractor.extractImageLabel] Starting image extraction") }
        collectImageSystemNames(from: node, into: &candidates)

        if debug { print("[VULabelExtractor.extractImageLabel] Found \(candidates.count) image symbol(s)") }

        guard let first = candidates.first else {
            if debug { print("[VULabelExtractor.extractImageLabel] ✗ No image symbols found") }
            return nil
        }

        // Ternary path: map only the first (then) branch through the symbol map.
        // The else branch is diagnostic context and is omitted from the label.
        let primarySymbol = first.thenName
        let label = symbolLabel(for: primarySymbol)
        if debug { print("[VULabelExtractor.extractImageLabel] ✓ Mapped '\(primarySymbol)' → '\(label)'") }
        return label
    }

    /// Recursively walks `node` and appends (thenName, elseName?) tuples for
    /// every `Image(systemName:)` call found.
    private static func collectImageSystemNames(
        from node: Syntax,
        into results: inout [(thenName: String, elseName: String?)]
    ) {
        let debug = ProcessInfo.processInfo.environment["VU_DEBUG"] != nil

        if let call = node.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "Image",
           let systemNameArg = call.arguments.first(where: { $0.label?.text == "systemName" }) {

            if debug { print("[VULabelExtractor.collectImageSystemNames] Found Image(systemName:)") }

            let expr = systemNameArg.expression

            if let stringLit = expr.as(StringLiteralExprSyntax.self) {
                // Plain string: Image(systemName: "eye.fill")
                let name = extractString(from: stringLit)
                if debug { print("[VULabelExtractor.collectImageSystemNames]   Plain string: '\(name)'") }
                if !name.isEmpty && isSFSymbolLike(name) {
                    results.append((thenName: name, elseName: nil))
                    if debug { print("[VULabelExtractor.collectImageSystemNames]   ✓ Added: \(name)") }
                }
            } else if let ternary = expr.as(TernaryExprSyntax.self) {
                // Ternary: Image(systemName: condition ? "eye.fill" : "eye.slash.fill")
                if debug { print("[VULabelExtractor.collectImageSystemNames]   Ternary expression") }
                var thenStr: String? = nil
                var elseStr: String? = nil

                if let lit = ternary.thenExpression.as(StringLiteralExprSyntax.self) {
                    let s = extractString(from: lit)
                    if debug { print("[VULabelExtractor.collectImageSystemNames]     Then: '\(s)'") }
                    if !s.isEmpty && isSFSymbolLike(s) { thenStr = s }
                }
                if let lit = ternary.elseExpression.as(StringLiteralExprSyntax.self) {
                    let s = extractString(from: lit)
                    if debug { print("[VULabelExtractor.collectImageSystemNames]     Else: '\(s)'") }
                    if !s.isEmpty && isSFSymbolLike(s) { elseStr = s }
                }

                if let t = thenStr {
                    results.append((thenName: t, elseName: elseStr))
                    if debug { print("[VULabelExtractor.collectImageSystemNames]   ✓ Added: \(t) / \(elseStr ?? "nil")") }
                }
            } else {
                // Fallback: The expression might be wrapped or parsed differently.
                // Try to extract string literals by recursive walk of this expression.
                if debug {
                    print("[VULabelExtractor.collectImageSystemNames]   expr type: \(type(of: expr))")
                    print("[VULabelExtractor.collectImageSystemNames]   Attempting fallback string extraction...")
                }

                // Collect all string literals from this expression subtree
                var stringLiterals: [String] = []
                collectStringsFromExpression(from: Syntax(expr), into: &stringLiterals)

                if debug { print("[VULabelExtractor.collectImageSystemNames]   Fallback found \(stringLiterals.count) strings: \(stringLiterals)") }

                // Use first two string literals as then/else pair
                if stringLiterals.count >= 1 {
                    let first = stringLiterals[0]
                    if isSFSymbolLike(first) {
                        let second = stringLiterals.count >= 2 ? stringLiterals[1] : nil
                        results.append((thenName: first, elseName: second))
                        if debug { print("[VULabelExtractor.collectImageSystemNames]   ✓ Fallback added: \(first) / \(second ?? "nil")") }
                    }
                }
            }
        }

        for child in node.children(viewMode: .sourceAccurate) {
            collectImageSystemNames(from: child, into: &results)
        }
    }

    /// Fallback: Recursively collects all string literal values from an expression.
    /// Used when the expression structure doesn't match expected ternary or literal types.
    private static func collectStringsFromExpression(
        from node: Syntax,
        into results: inout [String]
    ) {
        if let stringLit = node.as(StringLiteralExprSyntax.self) {
            let s = extractString(from: stringLit)
            if !s.isEmpty {
                results.append(s)
                return  // Don't recurse further into string literals
            }
        }

        for child in node.children(viewMode: .sourceAccurate) {
            collectStringsFromExpression(from: child, into: &results)
        }
    }

    // MARK: - SF Symbol → human-readable label

    /// Curated map of common SF Symbol names to concise action labels.
    private static let sfSymbolMap: [String: String] = [
        // Visibility
        "eye":                                    "Show",
        "eye.fill":                               "Show",
        "eye.slash":                              "Hide",
        "eye.slash.fill":                         "Hide",
        // Edit / CRUD
        "pencil":                                 "Edit",
        "pencil.circle":                          "Edit",
        "pencil.circle.fill":                     "Edit",
        "trash":                                  "Delete",
        "trash.fill":                             "Delete",
        "plus":                                   "Add",
        "plus.circle":                            "Add",
        "plus.circle.fill":                       "Add",
        "minus":                                  "Remove",
        "minus.circle":                           "Remove",
        "minus.circle.fill":                      "Remove",
        "xmark":                                  "Close",
        "xmark.circle":                           "Close",
        "xmark.circle.fill":                      "Close",
        "checkmark":                              "Confirm",
        "checkmark.circle":                       "Confirm",
        "checkmark.circle.fill":                  "Confirm",
        // Navigation / Direction
        "arrow.clockwise":                        "Refresh",
        "arrow.clockwise.fill":                   "Refresh",
        "arrow.counterclockwise":                 "Undo",
        "arrow.left":                             "Back",
        "arrow.right":                            "Forward",
        "arrow.up":                               "Up",
        "arrow.down":                             "Down",
        "arrow.left.arrow.right":                 "Transfer",
        "arrow.up.arrow.down":                    "Sort",
        // Search / Info
        "magnifyingglass":                        "Search",
        "magnifyingglass.circle":                 "Search",
        "magnifyingglass.circle.fill":            "Search",
        "info":                                   "Info",
        "info.circle":                            "Info",
        "info.circle.fill":                       "Info",
        "questionmark":                           "Help",
        "questionmark.circle":                    "Help",
        "questionmark.circle.fill":               "Help",
        "exclamationmark":                        "Alert",
        "exclamationmark.circle":                 "Alert",
        "exclamationmark.circle.fill":            "Alert",
        // Notifications / Settings
        "bell":                                   "Notifications",
        "bell.fill":                              "Notifications",
        "bell.badge":                             "Notifications",
        "bell.badge.fill":                        "Notifications",
        "gear":                                   "Settings",
        "gearshape":                              "Settings",
        "gearshape.fill":                         "Settings",
        // Favourites / Social
        "heart":                                  "Favorite",
        "heart.fill":                             "Favorite",
        "star":                                   "Favorite",
        "star.fill":                              "Favorite",
        "bookmark":                               "Bookmark",
        "bookmark.fill":                          "Bookmark",
        "square.and.arrow.up":                    "Share",
        "square.and.arrow.up.fill":               "Share",
        // User / Profile
        "person":                                 "Profile",
        "person.fill":                            "Profile",
        "person.circle":                          "Profile",
        "person.circle.fill":                     "Profile",
        // Home / Commerce
        "house":                                  "Home",
        "house.fill":                             "Home",
        "cart":                                   "Cart",
        "cart.fill":                              "Cart",
        "creditcard":                             "Payment",
        "creditcard.fill":                        "Payment",
        "banknote":                               "Money",
        "banknote.fill":                          "Money",
        "percent":                                "Percentage",
        // Documents / Files
        "doc":                                    "Document",
        "doc.fill":                               "Document",
        "doc.text":                               "Document",
        "doc.text.fill":                          "Document",
        // Media / Camera
        "camera":                                 "Camera",
        "camera.fill":                            "Camera",
        "photo":                                  "Photo",
        "photo.fill":                             "Photo",
        "play":                                   "Play",
        "play.fill":                              "Play",
        "pause":                                  "Pause",
        "pause.fill":                             "Pause",
        "stop":                                   "Stop",
        "stop.fill":                              "Stop",
        "forward":                                "Forward",
        "forward.fill":                           "Forward",
        "backward":                               "Backward",
        "backward.fill":                          "Backward",
        "mic":                                    "Microphone",
        "mic.fill":                               "Microphone",
        "video":                                  "Video",
        "video.fill":                             "Video",
        // Communication
        "phone":                                  "Call",
        "phone.fill":                             "Call",
        "envelope":                               "Email",
        "envelope.fill":                          "Email",
        "message":                                "Message",
        "message.fill":                           "Message",
        // Security / Location
        "lock":                                   "Lock",
        "lock.fill":                              "Lock",
        "lock.open":                              "Unlock",
        "lock.open.fill":                         "Unlock",
        "shield":                                 "Insurance",
        "shield.fill":                            "Insurance",
        "location":                               "Location",
        "location.fill":                          "Location",
        "map":                                    "Map",
        "map.fill":                               "Map",
        // Finance / Analytics
        "chart.bar":                              "Chart",
        "chart.bar.fill":                         "Chart",
        "chart.line.uptrend.xyaxis":              "Portfolio",
        "building.columns":                       "Bank",
        "building.columns.fill":                  "Bank",
        "gift":                                   "Gift",
        "gift.fill":                              "Gift",
        // Categories
        "airplane":                               "Travel",
        "fork.knife":                             "Food",
        "bolt":                                   "Utilities",
        "bolt.fill":                              "Utilities",
        "arrow.down.circle":                      "Income",
        "arrow.down.circle.fill":                 "Income",
        // List / Filter
        "list.bullet":                            "List",
        "list.dash":                              "List",
        "slider.horizontal.3":                    "Filter",
        "line.3.horizontal.decrease.circle":      "Filter",
        "line.3.horizontal.decrease.circle.fill": "Filter",
    ]

    /// Returns a human-readable label for an SF Symbol name.
    /// Looks up `sfSymbolMap` first; falls back to dot-split / suffix-strip
    /// capitalisation when no entry exists.
    /// Example fallback: `"arrow.clockwise.fill"` → `"Arrow Clockwise"`
    private static func symbolLabel(for name: String) -> String {
        if let mapped = sfSymbolMap[name] {
            return mapped
        }
        // Fallback: split on ".", drop common decorative suffixes, capitalise.
        let suffixesToDrop: Set<String> = ["fill", "circle", "slash", "badge", "outline"]
        let parts = name.split(separator: ".").map(String.init)
        let meaningful = parts.filter { !suffixesToDrop.contains($0) }
        let joined = meaningful.map { $0.capitalized }.joined(separator: " ")
        return joined.isEmpty ? name.capitalized : joined
    }
}

// MARK: - Button label resolution (used by VUButtonRewriter)

/// The label the button rewriter will pass to `registerPress(label:)`.
enum VUButtonLabel: Equatable {
    /// A compile-time string literal (not yet escaped).
    case literal(String)
    /// A side-effect-free expression that is valid at the action-closure insertion point.
    case expression(String)
}

extension VULabelExtractor {

    /// Resolves the label for a Button (or Button wrapper) call. Resolution order, first hit wins:
    ///
    /// 1. `.accessibilityIdentifier("literal")` applied to the Button call (modifier chain) or inside its label closure.
    /// 2. `.accessibilityLabel("literal")` in the same two places.
    /// 3. The title argument as a literal: first positional `"Title"` / `LocalizedStringKey("Title")`,
    ///    `title:` / `label:` literal of a wrapper that also has `action:`. Must contain a letter
    ///    (currency glyphs, digits and punctuation are not labels).
    /// 4. The first `Text("literal")` in the label closure that contains a letter, preferring
    ///    non-symbol-like strings. Only the label closure is searched, never the action closure.
    /// 5. A dynamic expression: non-literal title argument, wrapper `title:`/`label:` argument, or `Text(expr)` in the
    ///    label closure. Only accepted if it is side-effect free (names, member paths, literals, operators,
    ///    ternaries; no calls or closures), is not an implicit member (`.save`), uses no `$0`-style names, and
    ///    references nothing declared inside the label closure (closure params, loop variables, local lets), since
    ///    those are out of scope in the action closure.
    /// 6. `Image(systemName:)` mapped to a human label; decorative chevrons are used only if nothing else exists.
    ///
    /// Returns nil when nothing safe is found (the button is then left untouched).
    ///
    /// - Parameter call: should be the node as it appears in the original tree (so its parent chain is available
    ///   for modifier lookup).
    static func resolveButtonLabel(for call: FunctionCallExprSyntax) -> VUButtonLabel? {
        let labelClosure = findLabelClosure(in: call)
        let modifiers = accessibilityValues(for: call, labelClosure: labelClosure)

        if let id = modifiers.identifier { return .literal(id) }
        if let label = modifiers.label { return .literal(label) }

        if let title = literalTitle(from: call) { return .literal(title) }

        if let closure = labelClosure {
            let texts = collectTextLiterals(from: Syntax(closure)).filter(hasLetter)
            if let best = texts.first(where: { !isSFSymbolLike($0) }) ?? texts.first {
                return .literal(best)
            }
        }

        // Names bound by an enclosing closure / `for` loop (e.g. `ForEach(keys) { key in Button { } label: { Text(key) } }`).
        // They are out of scope for the action closure's value semantics AND are per-item data (a keypad digit, an
        // account number), so a label built from them is never emitted.
        let outerBound = enclosingBoundNames(of: call)

        if let expr = dynamicTitleExpression(from: call, excluding: outerBound) { return .expression(expr) }

        if let closure = labelClosure {
            let bound = boundNames(in: Syntax(closure)).union(outerBound)
            let textExprs = textExpressionNodes(in: Syntax(closure))
            for expr in textExprs where isEnumeratedLabelExpression(expr, excluding: bound) {
                return .expression(expr.trimmedDescription)
            }
            // The visible text is computed (a non-literal expression we cannot safely re-evaluate, e.g. a toggle's
            // `Text(open ? "Hide" : "Show \(n)")`). The icon next to it describes the glyph, not the button, so do not
            // fall back to it: emit no label and let the SDK derive it at tap time.
            if !textExprs.isEmpty { return nil }
            // A state-dependent glyph (`Image(systemName: hidden ? "eye.slash" : "eye")`) names the current state, not
            // the button, so a static label derived from one branch would be wrong half the time.
            if hasStateDependentIcon(closure) { return nil }
            if let image = extractImageLabel(closure) { return .literal(image) }
        }
        return nil
    }

    private static func hasStateDependentIcon(_ closure: ClosureExprSyntax) -> Bool {
        var candidates: [(thenName: String, elseName: String?)] = []
        collectImageSystemNames(from: Syntax(closure), into: &candidates)
        guard let first = candidates.first, let other = first.elseName else { return false }
        return other != first.thenName
    }

    /// Names bound by closures and `for` loops enclosing `node` (closure parameters, shorthand parameters, loop
    /// patterns). `node` must come from the original tree so its parent chain is available.
    static func enclosingBoundNames(of node: some SyntaxProtocol) -> Set<String> {
        var names = Set<String>()
        var current: Syntax? = Syntax(node).parent
        var child: Syntax = Syntax(node)
        while let ancestor = current {
            if let closure = ancestor.as(ClosureExprSyntax.self), let signature = closure.signature {
                names.formUnion(boundNames(in: Syntax(signature)))
            } else if let loop = ancestor.as(ForStmtSyntax.self), loop.body.id == child.id {
                names.formUnion(boundNames(in: Syntax(loop.pattern)))
            }
            child = ancestor
            current = ancestor.parent
        }
        return names
    }

    // MARK: Helpers

    static func hasLetter(_ text: String) -> Bool {
        text.contains { $0.isLetter }
    }

    private static func isFullyStatic(_ literal: StringLiteralExprSyntax) -> Bool {
        !literal.segments.contains { if case .expressionSegment = $0 { return true } else { return false } }
    }

    private static func staticLiteral(_ expr: ExprSyntax) -> String? {
        guard let lit = expr.as(StringLiteralExprSyntax.self), isFullyStatic(lit) else { return nil }
        let text = extractString(from: lit)
        return text.isEmpty ? nil : text
    }

    /// `"x"` -> x, `LocalizedStringKey("x")` -> x, `Text("x")` is not unwrapped.
    private static func titleLiteral(_ expr: ExprSyntax) -> String? {
        if let s = staticLiteral(expr) { return s }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "LocalizedStringKey",
           call.arguments.count == 1, let first = call.arguments.first, first.label == nil {
            return staticLiteral(first.expression)
        }
        return nil
    }

    private static func literalTitle(from call: FunctionCallExprSyntax) -> String? {
        if let first = call.arguments.first, first.label == nil || first.label?.text == "title",
           let t = titleLiteral(first.expression), hasLetter(t) {
            return t
        }
        if call.arguments.contains(where: { $0.label?.text == "action" }) {
            for arg in call.arguments where arg.label?.text == "title" || arg.label?.text == "label" {
                if let t = titleLiteral(arg.expression), hasLetter(t) { return t }
            }
        }
        return nil
    }

    private static func dynamicTitleExpression(from call: FunctionCallExprSyntax, excluding bound: Set<String>) -> String? {
        if let first = call.arguments.first, first.label == nil || first.label?.text == "title",
           titleLiteral(first.expression) == nil,
           first.expression.as(StringLiteralExprSyntax.self) == nil,
           isEnumeratedLabelExpression(first.expression, excluding: bound) {
            return first.expression.trimmedDescription
        }
        if call.arguments.contains(where: { $0.label?.text == "action" }) {
            for arg in call.arguments where arg.label?.text == "title" || arg.label?.text == "label" {
                if arg.expression.is(ClosureExprSyntax.self) { continue }
                if titleLiteral(arg.expression) != nil || arg.expression.is(StringLiteralExprSyntax.self) { continue }
                if isEnumeratedLabelExpression(arg.expression, excluding: bound) { return arg.expression.trimmedDescription }
            }
        }
        return nil
    }

    /// First arguments of `Text(...)` calls in `node` that are not string literals.
    private static func textExpressionNodes(in node: Syntax) -> [ExprSyntax] {
        var out: [ExprSyntax] = []
        if let call = node.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self), ref.baseName.text == "Text",
           let first = call.arguments.first, first.expression.as(StringLiteralExprSyntax.self) == nil {
            out.append(first.expression)
        }
        for child in node.children(viewMode: .sourceAccurate) { out += textExpressionNodes(in: child) }
        return out
    }

    // MARK: Accessibility modifiers

    private static func accessibilityValues(
        for call: FunctionCallExprSyntax, labelClosure: ClosureExprSyntax?
    ) -> (identifier: String?, label: String?) {
        var identifier: String?
        var label: String?
        func take(_ name: String, _ call: FunctionCallExprSyntax) {
            guard let arg = call.arguments.first, arg.label == nil, let s = staticLiteral(arg.expression) else { return }
            if name == "accessibilityIdentifier", identifier == nil { identifier = s }
            if name == "accessibilityLabel", label == nil { label = s }
        }
        // Modifier chain: Button {...}.accessibilityIdentifier("x")
        var current: Syntax = Syntax(call)
        while let member = current.parent?.as(MemberAccessExprSyntax.self),
              member.base?.id == current.id,
              let outer = member.parent?.as(FunctionCallExprSyntax.self),
              outer.calledExpression.id == member.id {
            take(member.declName.baseName.text, outer)
            current = Syntax(outer)
        }
        // Inside the label closure.
        if let closure = labelClosure {
            final class V: SyntaxVisitor {
                var found: [(String, FunctionCallExprSyntax)] = []
                override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
                    if let m = node.calledExpression.as(MemberAccessExprSyntax.self) {
                        let n = m.declName.baseName.text
                        if n == "accessibilityIdentifier" || n == "accessibilityLabel" { found.append((n, node)) }
                    }
                    return .visitChildren
                }
            }
            let v = V(viewMode: .sourceAccurate)
            v.walk(closure)
            for (n, c) in v.found { take(n, c) }
        }
        return (identifier, label)
    }

    // MARK: Scope / safety analysis

    /// Names declared anywhere inside `node` (closure params, shorthand params, let/var/for/case bindings).
    private static func boundNames(in node: Syntax) -> Set<String> {
        final class V: SyntaxVisitor {
            var names = Set<String>()
            override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
                names.insert(node.identifier.text); return .visitChildren
            }
            override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
                names.insert(node.firstName.text)
                if let s = node.secondName { names.insert(s.text) }
                return .visitChildren
            }
            override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
                names.insert(node.name.text); return .visitChildren
            }
        }
        let v = V(viewMode: .sourceAccurate)
        v.walk(node)
        return v.names
    }

    /// Privacy gate for dynamic labels. A label that reads state or a property (`accountNumber`, `vm.balanceText`,
    /// `"Hi \(name)"`) can carry what the user typed or an account value, so it is never exported. The only dynamic
    /// shape accepted is a ternary chain whose every RESULT is a fixed string literal with no interpolation
    /// (`open ? "Hide" : "Show"`): the label is one of a closed set of developer-written names.
    static func isEnumeratedLabelExpression(_ expr: ExprSyntax, excluding bound: Set<String>) -> Bool {
        if let t = expr.as(TernaryExprSyntax.self) {
            return isSafeLabelExpression(t.condition, excluding: bound)
                && isEnumeratedResult(t.thenExpression, excluding: bound)
                && isEnumeratedResult(t.elseExpression, excluding: bound)
        }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return isEnumeratedLabelExpression(only.expression, excluding: bound)
        }
        guard let seq = expr.as(SequenceExprSyntax.self) else { return false }
        // Split on the ternary operators: [cond, ?: then, cond, ?: then, ..., result].
        var sawTernary = false
        var segment: [ExprSyntax] = []
        for el in seq.elements {
            if let t = el.as(UnresolvedTernaryExprSyntax.self) {
                guard !segment.isEmpty,
                      segment.allSatisfy({ $0.is(BinaryOperatorExprSyntax.self) || isSafeLabelExpression($0, excluding: bound) }),
                      isEnumeratedResult(t.thenExpression, excluding: bound) else { return false }
                sawTernary = true
                segment = []
            } else {
                segment.append(el)
            }
        }
        // The tail after the last ternary is the final result: exactly one fixed literal.
        guard sawTernary, segment.count == 1, let last = segment.first else { return false }
        return isEnumeratedResult(last, excluding: bound)
    }

    private static func isEnumeratedResult(_ expr: ExprSyntax, excluding bound: Set<String>) -> Bool {
        if let lit = expr.as(StringLiteralExprSyntax.self) { return isFullyStatic(lit) }
        return isEnumeratedLabelExpression(expr, excluding: bound)
    }

    /// True when `expr` may be re-evaluated inside the action closure: pure, in scope, type-inferrable.
    static func isSafeLabelExpression(_ expr: ExprSyntax, excluding bound: Set<String>) -> Bool {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = ref.baseName.text
            return ref.argumentNames == nil && !name.hasPrefix("$") && !bound.contains(name)
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            guard let base = member.base, member.declName.argumentNames == nil else { return false }
            return isSafeLabelExpression(base, excluding: bound)
        }
        if let lit = expr.as(StringLiteralExprSyntax.self) {
            for seg in lit.segments {
                if case .expressionSegment(let e) = seg {
                    for a in e.expressions where !isSafeLabelExpression(a.expression, excluding: bound) { return false }
                }
            }
            return true
        }
        if expr.is(IntegerLiteralExprSyntax.self) || expr.is(FloatLiteralExprSyntax.self)
            || expr.is(BooleanLiteralExprSyntax.self) || expr.is(NilLiteralExprSyntax.self) { return true }
        if let seq = expr.as(SequenceExprSyntax.self) {
            for el in seq.elements {
                if el.is(BinaryOperatorExprSyntax.self) { continue }
                if let t = el.as(UnresolvedTernaryExprSyntax.self) {
                    if !isSafeLabelExpression(t.thenExpression, excluding: bound) { return false }
                    continue
                }
                if !isSafeLabelExpression(el, excluding: bound) { return false }
            }
            return true
        }
        if let t = expr.as(TernaryExprSyntax.self) {
            return isSafeLabelExpression(t.condition, excluding: bound)
                && isSafeLabelExpression(t.thenExpression, excluding: bound)
                && isSafeLabelExpression(t.elseExpression, excluding: bound)
        }
        if let f = expr.as(ForceUnwrapExprSyntax.self) { return isSafeLabelExpression(f.expression, excluding: bound) }
        if let o = expr.as(OptionalChainingExprSyntax.self) { return isSafeLabelExpression(o.expression, excluding: bound) }
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first {
            return isSafeLabelExpression(only.expression, excluding: bound)
        }
        return false
    }
}
