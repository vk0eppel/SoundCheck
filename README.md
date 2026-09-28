# SoundCheck

A signal generator utility for macOS, to help sound engineers, audio technicians and audiophiles test sound recording and reproduction equipment. Generates test signals only — SoundCheck is not an audio analyser and never captures or measures audio.

## Status

Signal types: sine, square, pink noise, white noise, and a logarithmic sine sweep. Pink and White each offer full-range, band-limited (presets or a manual range), and 1/3-octave (31 ISO 266 bands) modes. All of them are wired end-to-end to a real `AVAudioEngine` graph, with live Core Audio device enumeration, per-channel mute/phase, a live sample rate/bit depth display, and persisted settings. See [`docs/spec.md`](docs/spec.md) for the complete spec.

## Requirements

- **macOS 14 (Sonoma) or later**
- **Any Mac — Apple Silicon or Intel.** Releases ship as a universal binary.
- An audio output device (built-in speakers, headphones, USB interface, etc.). SoundCheck plays test signals only — it never records, so no microphone access is needed.

## Install

1. Download the latest `SoundCheck-vX.Y.Z.zip` from the [**Releases**](https://github.com/vk0eppel/SoundCheck/releases/latest) page.
2. Double-click the `.zip` to unpack `SoundCheck.app`, then drag it into your **Applications** folder.
3. **First launch.** The app is signed for development but **not notarized by Apple**, so macOS Gatekeeper blocks it the first time. To open it anyway:
   - **Right-click** (or Control-click) `SoundCheck.app` → **Open**, then click **Open** in the dialog. macOS remembers your choice, so later launches are ordinary double-clicks.
   - If no **Open** button appears, clear the quarantine flag in Terminal and try again:
     ```
     xattr -dr com.apple.quarantine /Applications/SoundCheck.app
     ```

> **Heads up:** because these builds use an Apple *Development* certificate and aren't notarized, some Macs may refuse to open the app at all rather than just warn. If the steps above don't work, [build from source](#building-and-testing) instead — a notarized, friction-free build is future work.

## Running

1. Launch SoundCheck and pick your **Output Device**.
2. Choose a signal type (**sine**, **square**, **pink**, **white**, or **sweep**), set its frequency, noise mode, or sweep duration as applicable, set the level, and flip the generator **On**.
3. Use the per-channel **mute / phase** controls to send the signal where you need it.

## Building and testing

```
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' build
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' test
```

Or open `SoundCheck.xcodeproj` in Xcode and use Cmd-R / Cmd-U. Requires Xcode (SwiftUI + AVAudioEngine + Core Audio); iOS portability is considered but not designed for yet.

## Documentation

- [`docs/spec.md`](docs/spec.md) — the feature spec: signal types, screen layout, control behaviors, audio engine architecture, and the full decisions log.
- [`CONTEXT.md`](CONTEXT.md) — domain glossary.
- [`docs/adr/`](docs/adr) — architecture decision records.
- [`docs/research/`](docs/research) — research writeups backing specific technical decisions.

## Roadmap

Feature work is planned on [GitHub Issues](https://github.com/vk0eppel/SoundCheck/issues).

Out of scope: any audio analysis, metering, or capture.

## License

GPLv3 — see [`LICENSE`](LICENSE).
