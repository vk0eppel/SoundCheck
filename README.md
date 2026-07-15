# SoundCheck

A signal generator utility for macOS, for sound engineers, techs, and hifi enthusiasts testing speakers and sound systems. Generates test signals only — SoundCheck is not an audio analyser and never captures or measures audio.

## Status

V1 is in progress: sine wave, pink noise, and white noise generators, with the full UI chrome (on/off, frequency field, level field, output device picker, per-channel mute/phase, live sample rate/bit depth display). See [`docs/v1-spec.md`](docs/v1-spec.md) for the complete spec, and the [SoundCheck V1 map](https://github.com/vk0eppel/SoundCheck/issues/1) for what's built vs. still open.

## Requirements

- macOS, Xcode (SwiftUI + AVAudioEngine + Core Audio). iOS portability is considered but not designed for yet.

## Building and testing

```
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' build
xcodebuild -project SoundCheck.xcodeproj -scheme SoundCheck -destination 'platform=macOS' test
```

Or open `SoundCheck.xcodeproj` in Xcode and use Cmd-R / Cmd-U.

## Documentation

- [`docs/v1-spec.md`](docs/v1-spec.md) — the V1 feature spec: signal types, screen layout, control behaviors, audio engine architecture, and the full decisions log.
- [`CONTEXT.md`](CONTEXT.md) — domain glossary.
- [`docs/adr/`](docs/adr) — architecture decision records.
- [`docs/research/`](docs/research) — research writeups backing specific technical decisions.

## Roadmap

- **V1:** sine, pink noise, white noise.
- **V2:** band-limited pink noise, 1/3-octave pink noise (31 standard ISO 266 bands), sine sweeps, square wave.

Out of scope: any audio analysis, metering, or capture.
