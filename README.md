# Vunet v0.0.24-rc.1 — pre-built XCFrameworks

XCFrameworks for iOS (device + simulator):

- `Vunet.xcframework` (**dynamic**, self-contained)
- `VunetSDWebImage.xcframework` (**static** — links into your app; resolves against `Vunet.framework`)

## Compiler compatibility

Built **with** library evolution, so the frameworks ship a stable `.swiftinterface`
and are **portable across Xcode versions** — consumable by any Xcode at or newer
than the build toolchain (Xcode 26.5). No per-Xcode rebuild
needed.

## Integration

Add as a remote Swift package (Xcode ▸ File ▸ Add Package Dependencies, or in a
`Package.swift`):

```swift
.package(url: "https://github.com/vunetsystems/mobile-sdk-ios.git", exact: "0.0.24-rc.1")
```

then add the `Vunet` product. SwiftPM fetches the prebuilt
`.xcframework.zip` from this version's GitHub Release. The wrapper bundles the
SDK's internal bootstrap sources — you do not add OpenTelemetry or other embedded
dependencies yourself.

For SDWebImage image-load instrumentation, also add `VunetSDWebImage` and
set `OTHER_LDFLAGS = -ObjC` on your app target (its hooks auto-install via an
ObjC `+load` that is otherwise dead-stripped).

## SwiftUI tap labels: `@VuTrack`

Add the `VuTrack` product, `import VuTrack`, and put `@VuTrack` on each SwiftUI view. It needs **Xcode 27.1 or
later** (Swift 6.4); on an older Xcode it stops the build with its own error, and the rest of the SDK still works.
The macro is compiled from source by your Xcode, which asks you once to **Trust & Enable** it (command-line builds:
pass `-skipMacroValidation`). CocoaPods cannot ship Swift macros, so the pod does not include `@VuTrack`.

- **Tag every view at once:** in Xcode, right-click your project in the navigator and choose
  **VuTrackTag**, then allow it to write to your sources. In a Swift package, from a terminal:
  `swift package --allow-writing-to-package-directory vutrack-tag [--target <name>]`. It adds `@VuTrack` and
  `import VuTrack` where they are missing; review the diff and commit it.
- **Warn about untagged views:** add the `VuTrackLint` build-tool plugin to your app target (Build Phases ▸ Run
  Build Tool Plug-ins). It only reads your sources (command-line builds: pass `-skipPackagePluginValidation`).

## Caveat: don't import OpenTelemetry directly

`Vunet.framework` embeds OpenTelemetry and is the single owner of its global
state. `VunetSDWebImage` is static and shares that one copy (it does not embed
its own). If your **app** also imports OpenTelemetry directly, you'll get a second
copy with separate global state — drive telemetry through `VuTelemetryClient` /
`VuSpan` APIs instead.

## Slices

| Slice | Architectures |
|-------|---------------|
| iOS Device | arm64 |
| iOS Simulator | arm64, x86_64 |
