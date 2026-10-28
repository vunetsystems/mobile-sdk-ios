// Re-exported so the code `@VuTrack` generates (`VuButtonPressRegistry.shared.registerPress(label:)`) resolves in
// files that only `import VuTrack`.
@_exported import Vunet

/// Tag a SwiftUI view struct, or an extension of one. Every `Button` inside its computed properties and functions
/// reports its label on press. The rewrite happens in the compiler; source files are never edited.
///
/// Add it to every view at once with the `VuTrackTag` command plugin (Xcode: right-click the project ▸ VuTrackTag),
/// and turn on the `VuTrackLint` build plugin to get a warning for views that are missing it.
@attached(memberAttribute)
public macro VuTrack() = #externalMacro(module: "VuTrackMacros", type: "VuTrackMacro")

@attached(body)
public macro VuTrackBody(_ screen: String) = #externalMacro(module: "VuTrackMacros", type: "VuTrackBodyMacro")
