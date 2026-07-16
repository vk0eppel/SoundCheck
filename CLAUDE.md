# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

Build and test via `xcodebuild` (scheme `SoundCheck`, targets `SoundCheck`, `SoundCheckTests`, `SoundCheckUITests`):

```
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' build
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' test
```

To run a single test, filter with `-only-testing`:

```
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' test -only-testing:SoundCheckTests/SoundCheckTests/discoversAtLeastOneOutputDevice
```

The project uses `PBXFileSystemSynchronizedRootGroup` (Xcode 16+ synchronized folders) — new files dropped into `SoundCheck/`, `SoundCheckTests/`, or `SoundCheckUITests/` are picked up automatically, no `project.pbxproj` edits needed.

The Xcode project's `SUPPORTED_PLATFORMS` includes iOS/visionOS from the template default, but the app is designed macOS-first (see below) — iOS portability is a deferred, unscoped concern. Anything gated behind Core Audio's `AudioObject`/HAL APIs is macOS-only and wrapped in `#if os(macOS)`.

## Documentation to read first

- `docs/v1-spec.md` — the spec of record: signal types, screen layout, every control's exact behavior, the audio engine architecture, and a running decisions log. Read this before changing UI or audio behavior.
- `CONTEXT.md` — domain glossary (currently: Channel, Muted-by-default).
- `docs/adr/` — architecture decision records; check these before "fixing" something that looks odd, it may be deliberate.
- `docs/research/` — research writeups backing specific technical choices (e.g. pink noise algorithm selection).

## Planning workflow

Feature work was planned on GitHub Issues using the [wayfinder skill](https://github.com/vk0eppel/SoundCheck/issues/1) convention: a map issue (labeled `wayfinder:map`) indexes child ticket issues (`wayfinder:research`/`wayfinder:prototype`/`wayfinder:grilling`/`wayfinder:task`), with native GitHub sub-issue and blocking relationships expressing the dependency graph. The V1 map is closed (destination reached). The [V2 map](https://github.com/vk0eppel/SoundCheck/issues/12) (band-limited noise, 1/3-octave noise, sweeps, square wave) is in progress: band-limited and 1/3-octave pink noise are done and shipped as Pink sub-modes; sine sweep and square wave are still being built out (see the map for current ticket status). Use this convention again for V3 or any other non-trivial effort.

## Architecture

SoundCheck is a signal generator, not an analyser — it only ever produces audio, never captures or measures it. V1 is complete and fully wired end-to-end (no mock state remains anywhere). Four architectural decisions shape the audio engine, each with an ADR:

- **No third-party DSP/audio library.** All generators are hand-written `AVAudioSourceNode` render blocks (`docs/adr/0002-custom-render-blocks-no-dsp-library.md`).
- **Signal-type switch forces a full stop**, not a crossfade — changing signal type while running drops output to OFF; the user must press ON again (`docs/adr/0003-signal-switch-forces-stop.md`). This means the render graph only ever needs one live generator at a time.
- **Every output channel defaults to muted, including channel 1**, on launch and on every device switch — a deliberate safety default since the signal is routed to every channel of the device simultaneously (`docs/adr/0001-all-channels-muted-by-default.md`).
- **`SignalGenerator` is widened to carry full parameters, plus a `reset()` hook** — added in V2 so generators needing more than frequency/sample rate (Sweep's duration, Pink's noise mode) don't force another protocol change each time (`docs/adr/0004-generator-protocol-widened-for-parameterized-generators.md`).

Per `docs/v1-spec.md`'s "Audio engine architecture" section: one persistent `AVAudioSourceNode` whose render block delegates to an atomically-swappable generator reference; UI-thread parameter changes (frequency, level, mute/phase, on/off, generator swap) cross into the render block via a plain struct guarded by `OSAllocatedUnfairLock`, not a third-party atomics package; per-channel mute/phase is applied as a final per-channel pass inside the same render block; output device binding stays inside `AVAudioEngine`, overriding the output node's underlying `AudioUnit`'s `kAudioOutputUnitProperty_CurrentDevice` rather than dropping to a raw `AUHAL` unit.

Key source files:

- `SoundCheck/ContentView.swift` — the app screen: signal selector, on/off, frequency/level fields, device picker, per-channel mute/phase row, format readout, all wired to live state. Also holds the visual-design pieces: `Color.soundCheckAmber` (the one signature accent), `PanelSection` (titled panel grouping), and `SolidToggleStyle` (high-contrast toggle style for Mute/Ø) — see `docs/v1-spec.md`'s "Visual design" section before changing any of this screen's appearance. V2 added Pink's mode sub-selector (Full-range/Band-limited/1/3-Octave, `PinkNoiseModeFamily`) directly under the on/off switch, and unified the frequency-field slot so it's shared between Sine's frequency and Pink 1/3-Octave's band stepper — see `docs/v1-spec.md`'s "V2 addendum: pink noise modes".
- `SoundCheck/SignalRenderCore.swift` — the generators (sine, Kellett pink noise, white noise via a fast xorshift64 PRNG), the `OSAllocatedUnfairLock`-guarded `RenderParameters`, the start/stop ramp, and per-channel mute/phase — a pure unit, independently unit-tested without any live audio device. V2 added `PinkNoiseMode` (full-range/band-limited/1/3-octave, the latter two backed by `BandLimitedFilterChain`/a bandpass `Biquad` respectively), applied inside `PinkNoiseGenerator` and rebuilt only when the mode actually changes, never per sample.
- `SoundCheck/Biquad.swift` — the shared RBJ-cookbook biquad filter (Direct Form II: lowpass/highpass/bandpass), used by both of V2's noise filtering modes. Coefficient computation happens only in `init`; `process()` is pure per-sample arithmetic, safe for the real-time render path.
- `SoundCheck/AudioEngineController.swift` (macOS-only) — wraps `SignalRenderCore` in a real `AVAudioSourceNode`/`AVAudioEngine`, rebuilding the node on device switch (channel count/sample rate can differ per device) and binding output via the `AudioUnit` device override.
- `SoundCheck/AudioDeviceCatalog.swift` (macOS-only) — `@Observable` live catalog of Core Audio output devices (UID, name, output channel count) via an `AudioObjectPropertyListenerBlock` on `kAudioHardwarePropertyDevices`; also exposes per-device `nominalSampleRate(for:)` and `bitDepth(for:)` lookups.
- `SoundCheck/SettingsStore.swift` — persists the last signal type, frequency, level, device, per-channel mute/phase, and (V2) Pink noise mode as one JSON-encoded snapshot in `UserDefaults`, keyed by device UID.
- `SoundCheck/ThirdOctaveBands.swift` — the canonical 31-band ISO 266 1/3-octave frequency list (20Hz–20kHz), used by the frequency field's prev/next stepping and (V2) by Pink's 1/3-octave band stepper. The 31.5Hz band keeps its decimal label as a deliberate, narrow exception to the app's otherwise whole-Hz-only display rule.

Swift concurrency note: `AudioDeviceCatalog` is `@MainActor` + `@Observable`, but its Core Audio listener state (`listenerBlock`, `devicesAddress`) is `@ObservationIgnored nonisolated(unsafe)` because `deinit` runs nonisolated and needs to remove the property listener; its static Core Audio query functions (`fetchOutputDevices()`, `outputChannelCount(for:)`, etc.) are `nonisolated` since they touch no actor-isolated state and need to be callable from tests without hopping to the main actor. `SignalRenderCore` follows the same pattern: its generator instances and ramp state are `nonisolated(unsafe)` since they're only ever touched from the single real-time render callback.

UI gotcha worth knowing before touching button styling: a `.buttonStyle(.plain)` button whose `.background()`/`.overlay()` are applied outside the label is only tappable where the label's actual glyphs render, not across the visible background — needs an explicit `.contentShape(Rectangle())` on the label to fix, and this is easy to miss since it looks correct until you actually click it.
