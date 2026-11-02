import SwiftUI

/// Runtime half of `@VuTrack`'s tab rule: the macro adds `.onAppear { VuTrackTabs.didAppear("XScreen", group:) }` to
/// each tab's content of a `TabView` that has no `selection:` binding (so `.trackTabSelection` has nothing to observe).
@MainActor
public enum VuTrackTabs {
    /// Current tab per `TabView` (the macro names each one), so nested tab bars are tracked independently.
    private static var current: [String: String] = [:]

    /// Reports one `ui.navigation` per tab switch within `group`, from its previous tab to this one, using the macro's
    /// names only. Reading `Vunet.currentScreenName` instead is unreliable here: a tab's inner navigation stack updates
    /// it a moment after appearing, so the next tab would see the previous tab's late name.
    public static func didAppear(_ name: String, group: String = "") {
        let previous = current[group]
        current[group] = name
        // First tab of a group (app launch, or a nested bar shown for the first time) is no switch; nor is a tab
        // re-appearing when the user comes back to the outer tab that holds it.
        guard let previous, previous != name else { return }
        Vunet.rootScreenDidChange(from: previous, to: name)
    }
}
