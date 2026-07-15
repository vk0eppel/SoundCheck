# SoundCheck — V1 Spec

Signal generator utility for sound engineers, techs, and hifi enthusiasts testing speakers/sound systems. Not an audio analyser — playback only, no capture/analysis.

Platform: macOS first, iOS portability considered but not designed for yet.

## Roadmap

- **V1 (this doc):** Sine, pink noise, white noise + full UI chrome (on/off, frequency field, level field, device picker, per-channel mute/phase, sample rate/bit depth display).
- **V2:** Band-limited pink noise (0-200Hz / 200Hz-1kHz / 1k-20kHz / 7k-20kHz / manual range), 1/3-octave pink noise (31 standard ISO 266 bands, filtered or directly generated), sine sweeps, square wave.

## V1 signal types

| Signal | Parameters |
|---|---|
| Sine wave | Frequency (Hz), Level (dBFS) |
| Pink noise | Level (dBFS) — full-band 20Hz-20kHz |
| White noise | Level (dBFS) — full-band 20Hz-20kHz |

## Screen layout

```
┌─────────────────────────────────────────────┐
│  [ SINE | PINK | WHITE ]   ← signal selector │
│                                               │
│              ┌───────────┐                   │
│              │  ON/OFF   │  ← big toggle      │
│              └───────────┘                   │
│                                               │
│  Frequency:  [ 1000 ] Hz   ◀ prev  next ▶     │  (sine only)
│                                               │
│  Level:      [ -20 ] dBFS   [-] [+]           │
│                                               │
│  Output Device:  [ MOTU 8A ▾ ]                │
│  Ch 1: [Mute] [Ø]     Ch 2: [Mute] [Ø]  ...   │  ← per output channel
│                                               │
│  48.0 kHz / 24-bit          ← read-only, live │
└─────────────────────────────────────────────┘
```

## Controls

### Window
Fixed-size utility panel, not resizable. Optional user-toggleable "always on top" (off by default) so the panel can stay visible while working elsewhere in the room.

### Signal type selector
Segmented control, 3 states (Sine / Pink / White), all options visible at once. Switching while playing **fully stops output** (drops to OFF) — for safety, to avoid unwanted noise from an in-flight transition. The user must press ON again to hear the newly selected signal. See [ADR 0003](adr/0003-signal-switch-forces-stop.md).

### Big On/Off switch
- Spacebar toggles globally, except while a text field is actively being edited.
- Linear ~15ms gain ramp on start/stop (applied inside the render block) to avoid clicks — matters since users are driving real speakers. Same ramp is used for the forced stop triggered by a signal-type switch.
- State is shown via **both** color and an explicit text label ("ON"/"OFF") — never color alone. Running state uses red/amber (signals "hot"), not green, since this is the state where something is actively happening, not a "safe" state.

### Frequency field (sine only)
- Range 20Hz-20kHz, free text entry, default 1000Hz.
- Whole Hz only — typed input is rounded to the nearest integer Hz on commit. (Internal oscillator still uses full float precision; this is a display/entry rule only.) Exception: the 1/3-octave band at 31.5Hz displays as "31.5Hz", not rounded to 32 — it's the fixed ISO 266 standard label, not a typed value.
- Left/Right arrow keys step to prev/next 1/3-octave value from the canonical ISO 266 31-band list — not prev/next Hz.
- Typed free-text values don't snap to the 1/3-octave grid; arrows are the only thing that snaps.
- Clamp to range on commit, reject non-numeric input.

### Level field
- Range: -99 dBFS to 0 dBFS.
- Default -20 dBFS.
- Up/Down arrows and [-]/[+] buttons step by 1dB (whole numbers only).
- Free-text entry accepts decimal dB values (e.g. "-18.5") for precise level matching — decimals are only reachable by typing, not by stepping.

### Output device picker
- Enumerate Core Audio output devices live; update on hot-plug/removal via device-change listener (not a one-time query at launch).
- If the selected device is disconnected while playing: auto-stop and show an alert. Never silently reroute to system default.

### Per-channel mute / phase reverse
- Channel count driven by the selected device's actual output channel count, not fixed at 2.
- The signal is routed to every channel of the device. **Every channel defaults to muted — including channel 1** — on launch and on every device switch, so nothing plays until the user explicitly unmutes the channel(s) they intend to test. See [ADR 0001](adr/0001-all-channels-muted-by-default.md).
- Mute and Ø (phase) are independent per-channel toggles.
- Layout must handle devices with many channels (8+) gracefully: a horizontally-scrolling row within a fixed-height area (not wrapping to multiple rows), so window height stays constant regardless of the connected device's channel count.

### Sample rate / bit depth display
- Read-only, reflects the selected device's current nominal sample rate and stream format. Updates live if the format changes externally (e.g. via Audio MIDI Setup while SoundCheck is running).

## Audio engine architecture

- **No third-party DSP library.** Generators are hand-written `AVAudioSourceNode` render blocks. See [ADR 0002](adr/0002-custom-render-blocks-no-dsp-library.md).
- **One persistent source node.** A single `AVAudioSourceNode` is attached to the engine; its render block delegates to an atomically-swappable generator reference. Only one generator is ever live — no multi-node mixing, since signal-type switch forces a full stop first (ADR 0003) rather than crossfading.
- **Cross-thread parameter passing.** UI-driven changes (frequency, level, mute/phase, on/off, generator swap) are written to a plain parameter struct guarded by `OSAllocatedUnfairLock`. The render block takes the same lock to snapshot parameters at the top of each call — brief, uncontended, real-time-safe; no third-party atomics package.
- **Per-channel mute/phase** is applied as a final per-channel pass inside the same render block (multiply each channel's samples by 0 if muted, ±1 for phase), not via a separate downstream node.
- **Device binding.** Stays inside `AVAudioEngine`: the output node's underlying `AudioUnit` has its `kAudioOutputUnitProperty_CurrentDevice` overridden to target the user-selected Core Audio device, rather than bypassing `AVAudioEngine` for a raw `AUHAL` unit.

## Persistence
Remember last signal type, frequency, level, device, and per-channel mute/phase across launches. Key device selection by device UID (not index), so it survives device list reordering.

## Decisions log

| Question | Decision |
|---|---|
| Signal switch while playing | **Superseded** — now forces full stop to OFF, see [ADR 0003](adr/0003-signal-switch-forces-stop.md) |
| Level step size | 1dB |
| Level floor | -99 dBFS |
| Device disconnect while playing | Auto-stop + alert |
| Settings persistence | Remembered across launches, keyed by device UID |
| Window sizing | Fixed-size utility panel, not resizable |
| Always on top | User-toggleable, off by default |
| On/off state indication | Color (red/amber when running) + explicit text label, never color alone |
| Signal type selector style | Segmented control, all options visible |
| Frequency field precision | Whole Hz only (display/entry); internal oscillator stays float |
| Level field precision | Whole dB via arrows/buttons; decimals allowed via free-text entry |
| Many-channel layout | Horizontal scroll within fixed-height row, not wrapping |
| Channel mute default | All channels muted by default, including channel 1 — see [ADR 0001](adr/0001-all-channels-muted-by-default.md) |
| DSP library vs custom | Custom `AVAudioSourceNode` render blocks, no third-party library — see [ADR 0002](adr/0002-custom-render-blocks-no-dsp-library.md) |
| Render graph topology | One persistent source node, swappable generator reference — no multi-node mixing |
| UI-to-audio-thread parameter passing | Plain struct guarded by `OSAllocatedUnfairLock` |
| Start/stop ramp curve/duration | Linear, ~15ms, inside the render block |
| Per-channel mute/phase application point | Inside the same render block, final per-channel pass |
| Output device binding | `AVAudioEngine` output node, `AudioUnit` `kAudioOutputUnitProperty_CurrentDevice` override |

## Out of scope for V1
Band-limited noise, 1/3-octave noise, sweeps, square wave, any analysis/metering, any recording/capture.
