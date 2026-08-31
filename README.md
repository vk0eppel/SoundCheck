# SoundCheck

A signal generator utility for macOS, to help sound engineers, audio technicians and audiophiles test sound recording and reproduction equipment. Generates test signals only — SoundCheck is not an audio analyser and never captures or measures audio.

## Status

V1 is built: sine wave, pink noise, and white noise generators, with the full UI chrome (on/off, frequency field, level field, output device picker, per-channel mute/phase, live sample rate/bit depth display) wired end-to-end to a real `AVAudioEngine` graph, live Core Audio device enumeration, and persisted settings. See [`docs/v1-spec.md`](docs/v1-spec.md) for the complete spec and the [SoundCheck V1 map](https://github.com/vk0eppel/SoundCheck/issues/1) (closed) for how it was built.

V2 is in progress on the [V2 map](https://github.com/vk0eppel/SoundCheck/issues/12). Done so far: band-limited pink noise (5 presets + manual range) and 1/3-octave pink noise (31 ISO 266 bands), both live as sub-modes of the Pink signal type. Sine sweep and square wave are still being built out — see the map for current status.

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
2. Choose a signal type (**sine**, **pink**, or **white**), set the frequency (sine) and level, and flip the generator **On**.
3. Use the per-channel **mute / phase** controls to send the signal where you need it.

## Building and testing

```
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' build
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' test
```

Or open `SoundCheck.xcodeproj` in Xcode and use Cmd-R / Cmd-U. Requires Xcode (SwiftUI + AVAudioEngine + Core Audio); iOS portability is considered but not designed for yet.

## Documentation

- [`docs/v1-spec.md`](docs/v1-spec.md) — the V1 feature spec: signal types, screen layout, control behaviors, audio engine architecture, and the full decisions log.
- [`CONTEXT.md`](CONTEXT.md) — domain glossary.
- [`docs/adr/`](docs/adr) — architecture decision records.
- [`docs/research/`](docs/research) — research writeups backing specific technical decisions.

## Roadmap

- **V1:** sine, pink noise, white noise. Done.
- **V2:** band-limited pink noise (done), 1/3-octave pink noise (31 standard ISO 266 bands, done), sine sweeps (in progress), square wave (not started).

Out of scope: any audio analysis, metering, or capture.

## License

GPLv3 — see [`LICENSE`](LICENSE).
