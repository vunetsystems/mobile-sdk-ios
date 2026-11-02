#if canImport(UIKit)
import SwiftUI
import UIKit

extension View {
    /// Added by `@VuTrack` to `Toggle` / `Picker` / `Stepper`. SwiftUI never labels the UIKit control it renders
    /// (a Toggle's `UISwitch` has no `accessibilityLabel`, even with `.accessibilityLabel(...)`), so the SDK names
    /// its span `UISwitch`. This finds that control under the view's frame and sets its `accessibilityLabel`,
    /// which the SDK reads first. VoiceOver is unaffected: it reads SwiftUI's own elements, not this control.
    public func vuTrackControlLabel(_ label: String) -> some View {
        background(VuControlLabeler(label: label))
    }
}

private struct VuControlLabeler: UIViewRepresentable {
    let label: String
    func makeUIView(context: Context) -> VuControlLabelProbe { VuControlLabelProbe() }
    func updateUIView(_ view: VuControlLabelProbe, context: Context) {
        guard view.label != label else { return }
        view.label = label
        view.setNeedsLayout()
    }
}

final class VuControlLabelProbe: UIView {
    var label = ""
    /// The control found last time. While it is still on screen, under this view and carrying the label, a layout
    /// pass costs a few comparisons instead of a view-tree search.
    private weak var control: UIControl?
    private var isScheduled = false

    /// View-tree searches run so far (tests check that layout and scrolling do not trigger new ones).
    nonisolated(unsafe) static var searchCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { nil }

    // The control is laid out in the same pass as this background, so the check runs after it, once per run loop.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isScheduled, window != nil, !label.isEmpty, !isStillLabeled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isScheduled = false
            apply()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    private var isStillLabeled: Bool {
        guard let control, control.window === window, control.accessibilityLabel == label else { return false }
        return covers(control)
    }

    private func covers(_ control: UIControl) -> Bool {
        let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: self)
        return bounds.contains(center)
    }

    private func apply() {
        guard window != nil, !label.isEmpty, !isStillLabeled else { return }
        Self.searchCount += 1
        // SwiftUI places this background and the control's host view side by side, so the control is within a few
        // levels of a nearby ancestor; the search never walks the whole window.
        var ancestor = superview
        for _ in 0..<4 {
            guard let root = ancestor else { break }
            if let found = Self.firstControl(in: root, depth: 4, where: covers) {
                control = found
                if found.accessibilityLabel != label { found.accessibilityLabel = label }
                return
            }
            ancestor = root.superview
        }
    }

    private static func firstControl(in view: UIView, depth: Int, where matches: (UIControl) -> Bool) -> UIControl? {
        for sub in view.subviews where !(sub is VuControlLabelProbe) {
            if let control = sub as? UIControl, isLabelable(control) {
                if matches(control) { return control }
                continue
            }
            if depth > 0, let found = firstControl(in: sub, depth: depth - 1, where: matches) { return found }
        }
        return nil
    }

    private static func isLabelable(_ control: UIControl) -> Bool {
        if control is UISwitch || control is UIStepper || control is UISegmentedControl { return true }
        // A menu Picker: a button whose menu opens on tap. `showsMenuAsPrimaryAction` is iOS 14+.
        guard #available(iOS 14.0, *) else { return false }
        return (control as? UIButton)?.showsMenuAsPrimaryAction == true
    }
}
#endif
