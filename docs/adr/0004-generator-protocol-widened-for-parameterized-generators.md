# SignalGenerator protocol widened to carry full parameters, plus a reset hook

Decided while grilling [sine sweep behavior](https://github.com/vk0eppel/SoundCheck/issues/15) on the V2 map.

V1's `SignalGenerator` protocol (`SoundCheck/SignalRenderCore.swift`) is narrow: `func nextSample(frequencyHz: Double, sampleRate: Double) -> Double`. Sine, Kellett pink noise, and white noise all fit this exactly, since none of them need anything beyond the current frequency and sample rate to produce their next sample.

Sine sweep breaks that assumption: it needs the sweep's configured duration to compute its own instantaneous frequency from elapsed time, and `frequencyHz` is meaningless to it (the sweep generates its own frequency rather than being told one). Rather than adding a one-off `durationSeconds` parameter to the protocol now and repeating that per new generator-specific need later — square wave's duty cycle (grilled separately in issue #16) is expected to need the same kind of extra data — the protocol is widened to pass the generator the full `RenderParameters` snapshot instead of cherry-picked fields. Sine/Pink/White ignore the fields they don't use; Sweep reads `durationSeconds` from it.

A second addition: `SignalGenerator` gains a `reset()` method, called by `render()` at the same instant it already detects `rampGain == 0` (the point established by the fix for the signal-switch audible-blip bug, where the previous generator has fully silenced and it's safe to adopt a newly selected one). Sine/Pink/White implement `reset()` as a no-op; Sweep uses it to zero its elapsed-time counter, so every ON press starts the sweep fresh from 20Hz rather than resuming from wherever it last stopped.

Both changes are additive to the shape ADR 0002 established (one persistent render callback, one swappable generator reference, no allocation/locking in the per-sample hot path) — they don't change any of that, they just give the generator behind the swap more context to work with.
