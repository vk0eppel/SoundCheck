# Pink/white noise generation — algorithm research

Resolves [Choose pink/white noise generation algorithm](https://github.com/vk0eppel/SoundCheck/issues/3) on the SoundCheck V1 map.

## White noise

Trivial: each output sample is an independent uniform random value scaled to the target level. The only real decision is the PRNG. `SystemRandomNumberGenerator` draws from the OS entropy pool per call, which is unnecessary overhead and not guaranteed real-time-safe inside an `AVAudioSourceNode` render block. Recommendation: a small, fast, non-cryptographic PRNG (e.g. xorshift), seeded once and held as mutable state inside the generator — self-contained, allocation-free, audio-thread-only state (never touched by the UI thread, so it needs no synchronization beyond what the render block already provides).

## Pink noise — two candidates compared

**Voss-McCartney** (stochastic, additive):
- Constant computational cost per sample regardless of octave range (McCartney: "the number of octaves you use has no effect on the computational cost") — only one row of a small array updates each sample, selected via a trailing-zero-count on an incrementing counter.
- State: an array of random values (one per octave, typically 5–16 elements) plus a counter.
- Accuracy: ripple of ~1–2dB up to Fs/8, ~4dB near Fs/5, with a deep null at Nyquist. [(Spectrum analysis)](https://www.firstpr.com.au/dsp/pink-noise/allan-2/spectrum2.html)

**Paul Kellett's refined method** (IIR, weighted sum of first-order filters applied to white noise):
- 7 filter states (`b1`–`b7`), each updated by one multiply-accumulate per sample, output is the sum of all states plus a scaled white-noise term — a fixed 7 operations/sample, no branching, no special CPU instructions.
- State: 7 scalar `Double`s, negligible memory.
- Accuracy: the "instrumentation grade" variant is accurate to **within ±0.05dB above 9.2Hz** (at 44.1kHz); an "economy" variant trades down to ±0.5dB for less state if ever needed. [(Filter coefficients and detail)](https://www.dsprelated.com/showcode/216.php), [(musicdsp.org writeup)](https://www.musicdsp.org/en/latest/Filters/76-pink-noise-filter.html)

## Recommendation: Paul Kellett's refined ("instrumentation grade") method

Both are streaming, per-sample, allocation-free algorithms, so both fit the existing render-block architecture (ADR 0002) equally well — this isn't a fit-vs-doesn't-fit decision like FFT-based pre-rendering would have been. The deciding factor is **accuracy**: Kellett's ±0.05dB is roughly two orders of magnitude tighter than Voss-McCartney's 1–4dB ripple, and SoundCheck's whole purpose is being a trustworthy reference signal for testing real speakers — a few dB of ripple in the "pink" spectrum is exactly the kind of inaccuracy a sound engineer using this tool would notice and lose confidence in. Kellett's fixed 7-operations-per-sample cost with plain scalar state is also simpler to implement correctly and verify than Voss-McCartney's counter/trailing-zero-count indexing scheme, with no meaningful CPU cost difference at audio sample rates.

## Level compensation (post-implementation addendum)

Kellett's `0.11` output scaling constant was chosen (in the original algorithm) to keep pink noise's *peak* roughly bounded for a full-scale white noise input — it says nothing about matching pink's RMS (the thing perceived loudness actually tracks) to Sine's or White's at the same `levelDbfs`. In practice, pink noise's higher crest factor (~13dB, vs. ~4.8dB for White's uniform distribution) meant its raw output measured **~9.5dB quieter in RMS than White noise** at the same nominal Level — audible as "Pink noise isn't as loud as the rest," even though both use the identical `levelDbfs` gain multiplier.

`pinkLevelCompensationGain` (`SoundCheck/SignalRenderCore.swift`) corrects this: an empirically-measured makeup gain (≈2.98, +9.5dB) applied to the raw Kellett output before any mode-filtering, calibrated so Pink's RMS matches White's theoretical uniform-distribution RMS (`1/sqrt(3)`) at the same `levelDbfs`. Unlike `docs/research/band-limited-noise-generation.md`'s octave-span compensation, there's no closed-form expression for Kellett's IIR recurrence's output RMS, so this constant was derived the same way Kellett's own filter coefficients were — empirically, here via a 20-million-sample simulation of the exact generator recurrence. Applied upstream of the mode-filter branches, it uniformly lifts `.fullRange`, `.bandLimited`, and `.thirdOctave` together, so it composes cleanly with (rather than needing to be re-derived alongside) the per-mode compensation gains documented in the other two research docs.

**Same known limitation as the per-mode compensation gains:** this raises pink noise's transient peaks closer to full scale at high `levelDbfs` settings, on top of an already-uncompensated (non-peak-normalized) generator. Flagged, not fixed, as part of this change — see the "Level compensation" addenda in the other two research docs for the same caveat in more detail.

## Sources

- [Pink Noise Generator - DSP Code Snippet](https://www.dsprelated.com/showcode/216.php)
- [DSP Generation of Pink Noise - First Principles](https://www.firstpr.com.au/dsp/pink-noise/)
- [The Spectrum Produced by the Voss-McCartney Pink Noise Generator](https://www.firstpr.com.au/dsp/pink-noise/allan-2/spectrum2.html)
- [Pink noise filter — Musicdsp.org documentation](https://www.musicdsp.org/en/latest/Filters/76-pink-noise-filter.html)
- [Improved Pink Noise Generator Algorithm](https://www.ridgerat-tech.us/pink/newpink.htm)
