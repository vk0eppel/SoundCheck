# SoundCheck — V1 Spec

Signal generator utility for sound engineers, techs, and hifi enthusiasts testing speakers/sound systems. Not an audio analyser — playback only, no capture/analysis.

Platform: macOS first, iOS portability considered but not designed for yet.

## Roadmap

- **V1 (this doc):** Sine, pink noise, white noise + full UI chrome (on/off, frequency field, level field, device picker, per-channel mute/phase, sample rate/bit depth display).
- **V2:** Band-limited pink noise (0-200Hz / 200Hz-1kHz / 1k-20kHz / 7k-20kHz / manual range, **done** — see "V2 addendum: pink noise modes"), 1/3-octave pink noise (31 standard ISO 266 bands, **done** — same addendum), sine sweeps (in progress — see "V2 addendum: sine sweep"), square wave (not started — see "V2 addendum: square wave").

## V1 signal types

| Signal | Parameters |
|---|---|
| Sine wave | Frequency (Hz), Level (dBFS) |
| Pink noise | Level (dBFS) — full-band 20Hz-20kHz |
| White noise | Level (dBFS) — full-band 20Hz-20kHz |

## Screen layout

```
┌─────────────────────────────────────────────┐
│ GENERATOR                                    │
│  [ SINE | PINK | WHITE ]   ← signal selector │
│              ┌───────────┐                   │
│              │ ● ON/OFF  │  ← big toggle      │
│              └───────────┘                   │
│  Frequency:  [ 1000 ] Hz        ◀ ▶           │  (sine only; space reserved when hidden)
│  Level:      [ -20 ] dBFS        [+]          │
│                                    [-]         │
├───────────────────────────────────────────────┤
│ OUTPUT                                        │
│  Output Device:  [ MOTU 8A ▾ ]                │
│  CH1 [Mute][Ø]  CH2 [Mute][Ø]  ...  ← scroll  │
├───────────────────────────────────────────────┤
│  48.0 kHz / 24-bit          [ ] Always on Top │
└─────────────────────────────────────────────┘
```

GENERATOR and OUTPUT are titled panel groupings (tracked all-caps labels, subtle background fill) — not decoration, they separate "what's being generated" from "where it's going." Frequency's prev/next chevrons and Level's +/- both sit to the right of their value, ordered to match their keyboard shortcuts: chevrons left-then-right (matching ←/→), +/- stacked with + on top (matching ↑/↓ — up increases). All four stepper buttons share one explicit size so they read as one control family. See "Visual design" below for the full rationale.

## Controls

### Window
Fixed-size utility panel, not resizable. Optional user-toggleable "always on top" (off by default) so the panel can stay visible while working elsewhere in the room.

### Signal type selector
Segmented control, 3 states (Sine / Pink / White), all options visible at once. Switching while playing **fully stops output** (drops to OFF) — for safety, to avoid unwanted noise from an in-flight transition. The user must press ON again to hear the newly selected signal. See [ADR 0003](adr/0003-signal-switch-forces-stop.md).

### Big On/Off switch
- Spacebar toggles globally, except while a text field is actively being edited.
- On launch, no field is pre-focused — otherwise AppKit's default first-responder behavior auto-focuses the frequency field (the first key-capable control), silently swallowing the very first spacebar press as a typed space instead of starting the generator. `WindowAccessor` explicitly resigns focus to the window's content view once, right after the window is created.

### In-app shortcut help
No separate help view, button, or menu item. Every control that has a keyboard shortcut (on/off, frequency prev/next, level +/-) carries a native `.help()` tooltip stating its shortcut, shown on hover — the standard macOS mechanism, discoverable exactly where the shortcut applies, with no added UI chrome.
- Linear ~15ms gain ramp on start/stop (applied inside the render block) to avoid clicks — matters since users are driving real speakers. Same ramp is used for the forced stop triggered by a signal-type switch.
- State is shown via **both** color and an explicit text label ("ON"/"OFF") — never color alone. Running state uses red/amber (signals "hot"), not green, since this is the state where something is actively happening, not a "safe" state.

### Frequency field (sine only)
- Range 20Hz-20kHz, free text entry, default 1000Hz.
- Whole Hz only — typed input is rounded to the nearest integer Hz on commit. (Internal oscillator still uses full float precision; this is a display/entry rule only.) Exception: the 1/3-octave band at 31.5Hz displays as "31.5Hz", not rounded to 32 — it's the fixed ISO 266 standard label, not a typed value.
- Left/Right arrow keys step to prev/next 1/3-octave value from the canonical ISO 266 31-band list — not prev/next Hz.
- Typed free-text values don't snap to the 1/3-octave grid; arrows are the only thing that snaps.
- Clamp to range on commit, reject non-numeric input.
- Prev/next chevron buttons sit together to the right of the value, left-then-right, matching the left-arrow/right-arrow shortcuts. Reserved (hidden + disabled, not removed) when the signal type isn't sine, so the fixed-size GENERATOR panel never reflows on signal-type switch. This reserved slot is shared with Pink's 1/3-Octave band stepper (V2) and Sweep's duration field (V2) — see "V2 addendum: pink noise modes" and "V2 addendum: sine sweep".

### Level field
- Range: -99 dBFS to 0 dBFS.
- Default -20 dBFS.
- Up/Down arrows and [+]/[-] buttons step by 1dB (whole numbers only).
- Free-text entry accepts decimal dB values (e.g. "-18.5") for precise level matching — decimals are only reachable by typing, not by stepping.
- +/- buttons sit stacked to the right of the value, + above -, matching the up-arrow/down-arrow shortcuts (up increases, physically on top).

### Output device picker
- Enumerate Core Audio output devices live; update on hot-plug/removal via device-change listener (not a one-time query at launch).
- If the selected device is disconnected while playing: auto-stop and show an alert. Never silently reroute to system default.

### Per-channel mute / phase reverse
- Channel count driven by the selected device's actual output channel count, not fixed at 2.
- The signal is routed to every channel of the device. **Every channel defaults to muted — including channel 1** — on launch and on every device switch, so nothing plays until the user explicitly unmutes the channel(s) they intend to test. See [ADR 0001](adr/0001-all-channels-muted-by-default.md).
- Mute and Ø (phase) are independent per-channel toggles.
- Layout must handle devices with many channels (8+) gracefully: a horizontally-scrolling row within a fixed-height area (not wrapping to multiple rows), so window height stays constant regardless of the connected device's channel count.
- Both toggles use a solid-fill style (bold white text on a solid color background when engaged, dim outline when not) rather than a light system tint — engaged/disengaged must be unmistakable at a glance for a routing control this safety-relevant.

### Sample rate / bit depth display
- Read-only, reflects the selected device's current nominal sample rate and stream format. Updates live if the format changes externally (e.g. via Audio MIDI Setup while SoundCheck is running).

## Visual design

The screen has a deliberate "precision instrument, not settings pane" identity, built after the initial functional shell already existed (see the "Give the V1 screen a real visual identity" commit). It respects the existing "follow system appearance automatically" decision below — no forced dark theme — so the identity comes from typography, proportion, and one accent color rather than overriding light/dark.

- **One signature accent** (`Color.soundCheckAmber`, a warning-lamp amber): reused consistently for the running-state LED/background, the selected signal-type tab, and the engaged Ø toggle. Never used for anything else, so it stays meaningful. Mute stays red — a distinct, universally-understood "danger/silence" color — so the two per-channel toggles read as different kinds of control, not just two amber-ish buttons.
- **Monospaced tabular digits** (`.fontDesign(.monospaced)`) on the frequency field, level field, and the sample-rate/bit-depth readout — the standard instrumentation convention so numbers don't visually jitter as they change.
- **Two titled panel groupings** (`PanelSection`, a reusable titled container with a subtle background fill): GENERATOR and OUTPUT, with tracked all-caps labels evoking panel silkscreening — structural, not decorative, since it separates "what's being generated" from "where it's going."
- **`SolidToggleStyle`**: a custom `ToggleStyle` used for Mute and Ø, filling solid + bold white text when on, dim outline when off, instead of the much-subtler default `.toggleStyle(.button)` + `.tint()` combination.
- Buttons whose only visible content is an icon (the ON/OFF button, the frequency chevrons, the level +/-) need an explicit `.contentShape(Rectangle())` on their label — otherwise `.buttonStyle(.plain)` only makes the icon glyph itself tappable, not the surrounding background/padding, which is not obvious from the rendered appearance and needs a visual click-target check, not just a build, to catch.

## Audio engine architecture

- **No third-party DSP library.** Generators are hand-written `AVAudioSourceNode` render blocks. See [ADR 0002](adr/0002-custom-render-blocks-no-dsp-library.md).
- **One persistent source node.** A single `AVAudioSourceNode` is attached to the engine; its render block delegates to an atomically-swappable generator reference. Only one generator is ever live — no multi-node mixing, since signal-type switch forces a full stop first (ADR 0003) rather than crossfading.
- **Cross-thread parameter passing.** UI-driven changes (frequency, level, mute/phase, on/off, generator swap) are written to a plain parameter struct guarded by `OSAllocatedUnfairLock`. The render block takes the same lock to snapshot parameters at the top of each call — brief, uncontended, real-time-safe; no third-party atomics package.
- **Per-channel mute/phase** is applied as a final per-channel pass inside the same render block (multiply each channel's samples by 0 if muted, ±1 for phase), not via a separate downstream node.
- **Device binding.** Stays inside `AVAudioEngine`: the output node's underlying `AudioUnit` has its `kAudioOutputUnitProperty_CurrentDevice` overridden to target the user-selected Core Audio device, rather than bypassing `AVAudioEngine` for a raw `AUHAL` unit.

`SignalRenderCore` implements the generators, ramp, and per-channel routing as a pure, AVAudioEngine-independent unit (sine via a phase accumulator; pink noise via Paul Kellett's refined filter over a fast xorshift64 PRNG; white noise via the same PRNG directly). It's deliberately decoupled from `AVAudioSourceNode` so it's unit-testable without a live audio device.

`AudioEngineController` (macOS-only) wraps `SignalRenderCore` in a real `AVAudioSourceNode`, rebuilding the node whenever the selected device's channel count or sample rate changes (a device switch requires detach/reattach, not just a format tweak), and binds the engine's output to the selected device via the `AudioUnit` override described above. `ContentView` wires every control to it: the signal selector forces `running = false` on change (ADR 0003) before swapping the generator kind; frequency/level/mute/phase push straight into `SignalRenderCore`'s parameters; the device picker uses `AudioDeviceCatalog`'s live list; losing the selected device (detected via the catalog's list changing) auto-stops and shows a SwiftUI `.alert`, then clears the selection rather than silently falling back to another device.

## Persistence
Remember last signal type, frequency, level, device, and per-channel mute/phase across launches. Key device selection by device UID (not index), so it survives device list reordering.

Implemented as `SettingsStore`: a single JSON-encoded `SettingsSnapshot` under one `UserDefaults` key. Per-channel mute/phase is stored as `[deviceUID: [PersistedChannelState]]`, so switching back to a previously used device restores its exact channel states; an unrecognized device UID or a channel count mismatch (device swapped for a different one) falls back to all-muted, per [ADR 0001](adr/0001-all-channels-muted-by-default.md), rather than reusing stale state that doesn't match the new device's layout.

`ContentView` loads the snapshot once on `onAppear` (falling back to the first available device if the saved device UID is no longer present) and pushes every subsequent change — signal type, frequency, level, selected device, per-channel mute/phase — straight back into `SettingsStore` via its own `onChange` handlers, so persistence needs no separate save action. This closes out V1: every control is wired to a live audio engine, a real device layer, and now persisted settings.

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
| Visual identity | "Precision instrument" direction: one amber signature accent, monospaced numeric readouts, titled panel groupings — see "Visual design" |
| Frequency control reflow on signal-type switch | Space always reserved (hidden + disabled, not removed) so the fixed-size window never reflows |
| Stepper button placement | Grouped to the right of the value, ordered to match their keyboard shortcut direction (chevrons left-then-right, +/- stacked with + on top) |
| Mute/phase toggle contrast | Custom `SolidToggleStyle` (solid fill + white text when on) — the default `.toggleStyle(.button)` tint was too subtle for a safety-relevant control |

## Out of scope for V1
Band-limited noise, 1/3-octave noise, sweeps, square wave, any analysis/metering, any recording/capture.

## V2 addendum: pink noise modes

Implemented via [issue #17](https://github.com/vk0eppel/SoundCheck/issues/17) and its child tickets on the V2 map, resolving that map's one open product question: band-limited and 1/3-octave noise are **sub-modes of the existing Pink signal type**, not new top-level signal-selector entries (5 fixed presets + 31 ISO bands as top-level segments would have overwhelmed the segmented signal-type selector).

- **Mode selector:** a second segmented control — Full-range / Band-limited / 1/3-Octave — sits directly under the on/off switch, visible only when Pink is selected (reserved/hidden otherwise, same "always reserve, never remove" principle as the frequency field). Switching mode while Pink is running and playing applies live and does **not** force a full stop — only a signal-*type* switch does that (ADR 0003 is unchanged; mode is a parameter of Pink, not a different signal).
- **Band-limited:** a preset picker (0–200Hz, 200Hz–1kHz, 1k–20kHz, 7k–20kHz, or Manual) sits directly under the mode selector. Manual reveals two numeric fields (low/high Hz, 20Hz–20kHz bounds, low < high enforced) using the same text-field style as Frequency/Level — but unlike those fields, manual-range edits only commit on Return or on losing focus (blur), not per keystroke, to avoid audibly hot-swapping a running filter's coefficients while typing. Each preset is realized as an optional highpass edge and/or optional lowpass edge (0–200Hz = lowpass-only; 200Hz–1kHz = highpass+lowpass; 1k–20kHz and 7k–20kHz = highpass-only), each edge a 4th-order (2-section) Butterworth `Biquad` cascade.
- **1/3-Octave:** reuses the exact same reserved slot the Sine frequency field occupies (just above Level) — a band value with prev/next chevrons, stepped via the same `ThirdOctaveBands.step(from:direction:)` used for Sine, displaying via the same whole-Hz rule (31.5Hz keeps its decimal exception). Realized as a single fixed-Q (~4.32) bandpass `Biquad`.
- **Persistence:** the selected mode, band-limited preset (including a manual range), and 1/3-octave band index all persist across relaunch, same global (not per-device) treatment as frequency/level.
- **Architecture:** `PinkNoiseGenerator` reads `RenderParameters.pinkNoiseMode` and rebuilds its filter chain only when the mode actually changes (never per sample) — see `docs/research/band-limited-noise-generation.md` and `docs/research/one-third-octave-noise-generation.md` for why a single shared `Biquad` type is reused by both modes rather than a single "band-limiting" abstraction. `PinkNoiseMode` carries associated values (`.bandLimited(BandLimitedPreset)`, `.thirdOctave(bandIndex:)`), which meant it couldn't stay `CaseIterable`/segmented-picker-friendly on its own — `ContentView` tracks separate UI-facing state (`PinkNoiseModeFamily`, `BandLimitedPresetSelection`) and composes/decomposes the real `PinkNoiseMode` via computed properties.

## V2 addendum: sine sweep

Decided via a grilling session on [issue #15](https://github.com/vk0eppel/SoundCheck/issues/15) on the V2 map.

- **Curve:** logarithmic only — no linear mode, no user-selectable curve. A log sweep spends equal time per octave rather than per Hz, which is both the standard choice for acoustic test sweeps and the right fit for a tool whose job is checking a speaker's response across the audible range.
- **Range:** fixed at the app's existing 20Hz–20kHz bounds — no configurable start/end frequency.
- **Duration control:** a free numeric field in seconds (same interaction pattern as the level field — arrow/button stepping by whole seconds, free-text entry for decimals), range 1–60s, default 10s. Occupies the same reserved slot the frequency field uses today (hidden/disabled for Sine/Pink/White, visible/enabled for Sweep) — see "Frequency control reflow on signal-type switch" in the Decisions log, now generalized to "signal-type-specific control slot" rather than sine-only.
- **Playback:** continuous loop (low→high, then instantly repeats) until the user presses OFF — no one-shot mode, no direction option (always low→high). Keeps the same on/off mental model as every other signal type: ON means sound continues until explicitly turned OFF.
- **Loop wrap-point:** instant jump back to 20Hz, no fade/mute around the wrap. Sweeping only changes frequency, not amplitude, so there's no waveform discontinuity to guard against — the abrupt pitch drop is the expected, self-evident sound of the sweep restarting.
- **No live frequency readout** during the sweep — a continuously-updating numeric display would need to refresh far faster than any other readout in the app and isn't actionable mid-sweep.
- **OFF then ON:** always restarts fresh from 20Hz. Sweep position is not preserved across a stop — it's pure audio-thread-only ephemeral state (no `SettingsStore` interaction), reset via the generator's new `reset()` hook (see [ADR 0004](adr/0004-generator-protocol-widened-for-parameterized-generators.md)) at the same instant the render block already detects `rampGain == 0`.
- **Architecture:** the `SignalGenerator` protocol widened to receive the full parameter snapshot (not just frequency/sample rate) so Sweep can read its configured duration, and gained a `reset()` lifecycle method — see [ADR 0004](adr/0004-generator-protocol-widened-for-parameterized-generators.md).

## V2 addendum: square wave

Decided via a grilling session on [issue #16](https://github.com/vk0eppel/SoundCheck/issues/16) on the V2 map.

- **Duty cycle:** fixed 50% — no adjustable duty cycle control. "Square wave," not a general pulse-wave generator.
- **Anti-aliasing:** band-limited at generation time via **PolyBLEP** (polynomial band-limited step correction applied in a narrow window around each of the waveform's two discontinuities per cycle). A naive `sign(sin(phase))` square wave's infinite odd-harmonic series aliases at the moment it's sampled — harmonics above Nyquist fold back into the audible range as wrong frequencies baked into the discrete signal, which a filter applied afterward cannot undo. This is why the RBJ biquad filters from the band-limited-noise research (`docs/research/band-limited-noise-generation.md`) don't apply here: those shape an already-generated noise signal's spectral envelope, a different problem from preventing aliasing during generation of a deterministic waveform. Additive/Fourier synthesis (summing harmonics up to Nyquist) is exactly band-limited but too costly at low fundamentals (1000+ harmonics per sample at 20Hz); oversample+filter+decimate works but adds disproportionate complexity (resampling stage, filter design, latency) for a single test waveform. PolyBLEP is O(1) per sample, fits the existing phase-accumulator style `SineGenerator` already uses, and is the standard real-time technique for this (Välimäki & Huovilainen's antialiasing-oscillator work).
- **UI:** Frequency and Level fields behave for Square exactly as they do for Sine (same 20Hz–20kHz range, same whole-Hz display rule, same 1/3-octave arrow-stepping). The reserved signal-type-specific slot (frequency for Sine, duration for Sweep) stays hidden/disabled for Square, the same treatment Pink/White already get. No new UI surface.
- **Architecture:** implements `SignalGenerator` in its narrowest form — frequency + sample rate only, no-op `reset()` — the same shape as `SineGenerator`. Note: [ADR 0004](adr/0004-generator-protocol-widened-for-parameterized-generators.md)'s protocol widening partly anticipated square wave needing the fuller parameter access for an adjustable duty cycle; since duty cycle ended up fixed, square wave doesn't end up exercising that widened surface. The widening was still the right call on Sweep's own merits — this is a note so the gap between "anticipated" and "actual" doesn't read as an oversight later, not a reason to revisit either decision.
