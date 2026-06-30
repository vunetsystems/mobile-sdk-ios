# vuTelemetry v0.0.2 — pre-built XCFrameworks

Self-contained **dynamic** XCFrameworks for iOS (device + simulator):

- `vuTelemetry.xcframework`
- `vuTelemetrySDWebImage.xcframework`

## Compiler compatibility

Built **with** library evolution, so the frameworks ship a stable `.swiftinterface`
and are **portable across Xcode versions** — consumable by any Xcode at or newer
than the build toolchain (Xcode 26.5). No per-Xcode rebuild
needed.

## Integration

Add as a remote Swift package (Xcode ▸ File ▸ Add Package Dependencies, or in a
`Package.swift`):

```swift
.package(url: "https://github.com/vunetsystems/mobile-sdk-ios.git", from: "0.0.2")
```

then add the `vuTelemetry` product. SwiftPM fetches the prebuilt
`.xcframework.zip` from this version's GitHub Release. The wrapper bundles the
SDK's internal bootstrap sources — you do not add OpenTelemetry or other embedded
dependencies yourself.

For SDWebImage image-load instrumentation, also add `vuTelemetrySDWebImage` and
set `OTHER_LDFLAGS = -ObjC` on your app target (its hooks auto-install via an
ObjC `+load` that is otherwise dead-stripped).

## SwiftUI instrumentation plugins

The wrapper ships **source** build-tool and command plugins (SPM does not support
binary plugin products):

- `VUInstrumentationPlugin` — compile-time SwiftUI Button instrumentation for SPM targets
- `VUInstrumentationCommand` — `swift package vu-instrument` for Xcode projects

Both depend on a prebuilt `VUSourceInstrumenter` macOS tool (artifact bundle —
consumers do **not** compile swift-syntax or XcodeProj). Add the plugin products
to your app or package target in Xcode.

For **Xcode .xcodeproj** projects, prefer the command plugin:

```bash
swift package --package-path /path/to/vuTelemetry vu-instrument install --project YourApp.xcodeproj
```

The prebuilt tool binary lives inside `VUSourceInstrumenter.artifactbundle` for
run-script build phases that need direct access.

## Caveat: don't import OpenTelemetry directly

Each framework embeds its own copy of OpenTelemetry. If your **app** also imports
OpenTelemetry directly, you'll get a second copy with separate global state.
Drive telemetry through `VuTelemetryClient` / `VuSpan` APIs instead.

## Slices

| Slice | Architectures |
|-------|---------------|
| iOS Device | arm64 |
| iOS Simulator | arm64, x86_64 |
