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

Feature work is planned on GitHub Issues using the [wayfinder skill](https://github.com/vk0eppel/SoundCheck/issues/1) convention: a single map issue (labeled `wayfinder:map`) indexes child ticket issues (`wayfinder:research`/`wayfinder:prototype`/`wayfinder:grilling`/`wayfinder:task`), with native GitHub sub-issue and blocking relationships expressing the dependency graph. Check the open map issue for current decisions and the frontier of open work before starting something non-trivial.

## Architecture

SoundCheck is a signal generator, not an analyser — it only ever produces audio, never captures or measures it. Three architectural decisions shape everything else, each with an ADR:

- **No third-party DSP/audio library.** All generators are hand-written `AVAudioSourceNode` render blocks (`docs/adr/0002-custom-render-blocks-no-dsp-library.md`).
- **Signal-type switch forces a full stop**, not a crossfade — changing signal type while running drops output to OFF; the user must press ON again (`docs/adr/0003-signal-switch-forces-stop.md`). This means the render graph only ever needs one live generator at a time.
- **Every output channel defaults to muted, including channel 1**, on launch and on every device switch — a deliberate safety default since the signal is routed to every channel of the device simultaneously (`docs/adr/0001-all-channels-muted-by-default.md`).

Per `docs/v1-spec.md`'s "Audio engine architecture" section, the intended render graph (not yet fully wired into the UI) is: one persistent `AVAudioSourceNode` whose render block delegates to an atomically-swappable generator reference; UI-thread parameter changes (frequency, level, mute/phase, on/off, generator swap) cross into the render block via a plain struct guarded by `OSAllocatedUnfairLock`, not a third-party atomics package; per-channel mute/phase is applied as a final per-channel pass inside the same render block; output device binding stays inside `AVAudioEngine`, overriding the output node's underlying `AudioUnit`'s `kAudioOutputUnitProperty_CurrentDevice` rather than dropping to a raw `AUHAL` unit.

Key source files:

- `SoundCheck/ContentView.swift` — the V1 screen shell (signal selector, on/off, frequency/level fields, device picker, per-channel mute/phase row, format readout). Currently wired to local `@State` with mock data (a placeholder device list, a placeholder frequency step list) — not yet connected to the real audio engine or `AudioDeviceCatalog`.
- `SoundCheck/ThirdOctaveBands.swift` — the canonical 31-band ISO 266 1/3-octave frequency list (20Hz–20kHz), used by the frequency field's prev/next stepping. The 31.5Hz band keeps its decimal label as a deliberate, narrow exception to the app's otherwise whole-Hz-only display rule.
- `SoundCheck/AudioDeviceCatalog.swift` (macOS-only) — `@Observable` live catalog of Core Audio output devices (UID, name, output channel count), updated via an `AudioObjectPropertyListenerBlock` on `kAudioHardwarePropertyDevices` for hot-plug/removal; also exposes per-device `nominalSampleRate(for:)` and `bitDepth(for:)` lookups. Not yet wired into `ContentView`.

Swift concurrency note: `AudioDeviceCatalog` is `@MainActor` + `@Observable`, but its Core Audio listener state (`listenerBlock`, `devicesAddress`) is `@ObservationIgnored nonisolated(unsafe)` because `deinit` runs nonisolated and needs to remove the property listener; its static Core Audio query functions (`fetchOutputDevices()`, `outputChannelCount(for:)`, etc.) are `nonisolated` since they touch no actor-isolated state and need to be callable from tests without hopping to the main actor.
