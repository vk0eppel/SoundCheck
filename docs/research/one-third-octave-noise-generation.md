# 1/3-octave noise generation — algorithm research

Resolves [Choose 1/3-octave noise generation approach](https://github.com/vk0eppel/SoundCheck/issues/14) on the SoundCheck V2 map.

## The 31 ISO 266 bands, as a filter-design problem

`SoundCheck/ThirdOctaveBands.swift` lists the 31 preferred center frequencies from 20Hz to 20kHz. Each band is constant-**percentage** (constant-Q), not constant-bandwidth: per [ANSI/ASA S1.11-2014/Part 1 (IEC 61260-1:2014)](https://webstore.ansi.org/standards/asa/asaansis111partiec612602014), "the extent of the pass-band region of a filter's relative attenuation characteristic is a constant percentage of the exact mid-band frequency for all filters of a given bandwidth," with the octave ratio fixed at `10^(3/10) ≈ 1.99526` and ten 1/3-octave bands per decade (`10^(1/10) ≈ 1.258925` per step). In Q terms — since a 1/3-octave-wide bandpass has a fixed bandwidth-in-octaves (1/3) regardless of center frequency — this converts to a **fixed Q of roughly 4.32** at every one of the 31 bands (derivation below). That single fact is what makes both candidates in this ticket look more alike than the issue's framing suggests.

## Candidate 1: bandpass-filter a wideband pink source

Feed the existing Kellett pink noise generator (`SoundCheck/SignalRenderCore.swift`, `PinkNoiseGenerator`) through a per-band bandpass biquad, recomputing coefficients when the selected band changes.

**Filter topology.** The [RBJ Audio-EQ-Cookbook](https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt) gives closed-form biquad coefficients for a bandpass filter parameterized directly by bandwidth in octaves, which is exactly the shape of this problem (one bandwidth — 1/3 octave — swept across 31 center frequencies), rather than by Q, which would require converting "1/3 octave" to Q once and holding it fixed:

```
w0 = 2*pi*f0/Fs
alpha = sin(w0) * sinh( ln(2)/2 * BW * w0/sin(w0) )

# constant 0dB peak gain variant:
b0 =  alpha
b1 =  0
b2 = -alpha
a0 =  1 + alpha
a1 = -2*cos(w0)
a2 =  1 - alpha
```

The cookbook also gives the exact Q/bandwidth relationship: `1/Q = 2*sinh(ln(2)/2 * BW * w0/sin(w0))`. For `BW = 1/3` and `w0` small relative to `Fs` (true for most of the 31 bands well below Nyquist), `w0/sin(w0) → 1`, so `1/Q ≈ 2*sinh(ln(2)/6) ≈ 0.2314`, i.e. **Q ≈ 4.32** — constant across the whole band set, confirming the "constant-Q" framing in the issue and matching the standard's own definition of 1/3-octave bandwidth. Near the top bands (16kHz, 20kHz at 44.1kHz — `w0` approaching a meaningful fraction of Nyquist), `w0/sin(w0)` grows above 1 and the bilinear transform's frequency warping requires a correspondingly larger `alpha` to hold the same 1/3-octave bandwidth in Hz; the cookbook formula already accounts for this automatically, it isn't a special case to hand-code.

**Cost.** A single biquad section (direct form II) is 4 multiplies + 4 adds per sample plus one input scale — a fixed, small operation count independent of frequency or Q, layered on top of the existing 7-operation Kellett pink filter. Recomputing `w0`/`alpha`/the five coefficients on a band change is 2 trig calls (`sin`, `cos`) plus one `sinh` — trivial and done once per band switch, not per sample, so it doesn't touch the real-time hot path's per-sample cost at all.

**Band-edge accuracy.** A single second-order bandpass section has a fairly gentle skirt (12dB/octave rolloff outside the passband, per the standard biquad transfer function's two-pole/two-zero response) — it will not meet the actual stopband-rejection templates that [IEC 61260-1](https://webstore.ansi.org/standards/asa/asaansis111partiec612602014) specifies for *measurement* filters (Class 0/1/2 templates define minimum attenuation at multiple points outside the passband, meant to bound how much energy from adjacent bands leaks into a measurement). But SoundCheck is a **generator**, not an analyser: nothing here is being legally/metrologically certified against that template, and the real design goal is "this sounds like noise localized to the selected band, useful for exciting a driver or crossover region in isolation" — a much looser bar than analysis-grade skirt rejection. If sharper skirts are ever wanted, cascading 2–4 identical bandpass sections (each recentered/requantized identically) tightens the passband/stopband transition at a linear cost in operations — a straightforward future refinement, not a blocker to shipping a single-section version first.

**Numerical stability at low frequencies.** At the 20Hz band (44.1kHz sample rate), `w0 ≈ 0.00285` rad, giving `alpha ≈ sin(w0)/(2*4.32) ≈ 0.00033`, so `a2 = 1 - alpha ≈ 0.99967` and `a0 = 1 + alpha ≈ 1.00033` — pole radius extremely close to the unit circle. This is numerically stable in double precision (nowhere near the ~1e-16 precision floor), but it does mean a **long settling time**: the 20Hz band's 3dB bandwidth is only ~4.6Hz (center/Q), so the filter's time constant is on the order of 1/(π·4.6Hz) ≈ 70ms, meaning a band switch at 20Hz needs on the order of 100–200ms before the output amplitude has settled to steady-state — worth surfacing as a UX note (a brief ramp/settle period after switching to a very low band) but not a stability problem. Separately, because bandpass output naturally decays toward (but never exactly reaches) zero between transients, the state variables can decay into denormal float range during quiet passages; per general audio-DSP practice this is usually handled by flushing denormals (either via a compiler/runtime flag or by injecting a vanishingly small DC bias) to avoid the well-documented CPU-spike behavior denormal arithmetic causes on x86/ARM FPUs — a small, known mitigation, not a design risk.

## Candidate 2: synthesize each band directly

The issue poses this as synthesizing band-limited noise "sized to the band's bandwidth" without a separate wideband-source-plus-filter step. Investigating what this would concretely mean turns up two possibilities:

1. **White noise through a single bandpass filter tuned to the band's center/bandwidth, no pink-shaping stage.** This is not a different technique from Candidate 1 — it's the *same* RBJ bandpass biquad, just fed white noise instead of Kellett-pink noise. Whether the source feeding the filter is white or pink only changes the spectral tilt *within* the passband (over a 23%-wide band, pink's 3dB/octave tilt is a fraction of a dB of difference edge-to-edge — small enough that either input is a defensible choice, and pink is more consistent with SoundCheck's existing spectral vocabulary). This collapses "candidate 2" into "candidate 1 with a different noise-color input," not a genuinely separate architecture.
2. **Inverse-FFT synthesis of a defined magnitude spectrum** (construct a spectrum with energy only in the target band, phase-randomize, IFFT, overlap-add) — a real, distinct technique used in some offline noise-synthesis tools. But it is fundamentally **block-based**: it requires accumulating a window of samples, transforming, and emitting a block, which means added latency (at least one FFT window's worth) and a fixed per-block allocation for the FFT working buffers and overlap-add tail. That directly conflicts with this codebase's render-block constraint (ADR 0002, `SignalRenderCore.render()`): the hot path must be per-sample, allocation-free, and lock-free, with parameters crossing in once per callback via the `OSAllocatedUnfairLock`-guarded snapshot — not via a block-oriented transform stage. Additive/summed-sinusoid synthesis (many oscillators spaced across the band) is real-time-feasible in principle but requires enough oscillators to sound like noise rather than a chord, which is a much larger per-sample operation count than a single biquad for equivalent perceptual density, and doesn't reuse anything from the existing generator.

No primary source surfaced describing a real-time, sample-by-sample IFFT-based *noise generator* running inside a fixed-size real-time audio callback — every IFFT-noise reference found describes block/offline processing, consistent with the reasoning above. Real commercial 1/3-octave-noise tools bear this out: [Room EQ Wizard's Signal Generator](https://www.roomeqwizard.com/help/help_en-GB/html/siggen.html) documents its octave/1/3-octave noise options as **Butterworth high-pass and low-pass filtering of full-range pink or white noise**, with a selectable filter order from 2nd (12dB/octave) to 8th (48dB/octave) — i.e. exactly Candidate 1's approach (filter a wideband noise source), just using a cascaded HP+LP Butterworth pair instead of a single bandpass biquad, presumably because REW lets the user dial in sharper skirts as an explicit tradeoff against CPU cost. This is strong evidence that "filter a wideband source" is the standard, practical answer in tools with the same goal as SoundCheck (generate a plausible band-limited test signal, not certify a metrology-grade filter).

## Recommendation: Candidate 1 — bandpass-filter the existing pink noise generator with a single RBJ biquad section, reused per band by recomputing coefficients

The investigation collapses the two candidates into one real design: a bandpass biquad fed by the existing `PinkNoiseGenerator`, with coefficients recomputed (not the whole DSP graph rebuilt) whenever the selected band changes — cheaply, since it's 31 fixed center frequencies and one fixed bandwidth (1/3 octave, Q≈4.32), so the coefficient set could even be precomputed once for all 31 bands at each supported sample rate and looked up rather than recomputed with trig calls on every switch, if that's ever worth the added state.

This fits every constraint that matters here:
- **Render-block architecture (ADR 0002):** a biquad section is per-sample, allocation-free, branch-free arithmetic on scalar `Double` state — it slots directly after the existing pink generator's output in the same `render()` loop, and coefficient updates only need to happen on the (rare, UI-triggered) band-change event, not per sample.
- **Reuse with issue #13 (band-limited noise for the 5 fixed presets):** that ticket's presets (0–200Hz, 200Hz–1kHz, 1k–20kHz, 7k–20kHz, manual range) are wideband, non-constant-Q ranges, so they don't share the *same* Q — but they can share the *same bandpass biquad implementation* (RBJ cookbook coefficient formulas, computed from arbitrary center-frequency+bandwidth pairs rather than fixed Q), and likely the same "filter the pink generator's output" building block. If #13 lands first, this ticket's 1/3-octave feature is a thin wrapper around it: convert the selected ISO band's center + 1/3-octave bandwidth into the same center/BW parameterization #13 already uses, rather than inventing a parallel filter path.
- **Band-edge accuracy vs. the actual goal:** a single bandpass section won't meet IEC 61260's measurement-grade skirt-rejection template, but nothing in SoundCheck's signal-generator role calls for that — the bar is "sounds correctly localized to the selected 1/3-octave band for driver/crossover testing," which one section clears; a cascade of sections is a documented, cheap escape hatch if a future spec pass decides tighter skirts are worth it.
- **CPU cost:** a fixed ~4 multiply-adds per sample on top of the existing 7-operation pink filter, with per-band coefficient recomputation being 2 trig calls done once per switch, not per sample.

The one implementation note worth carrying into the ticket that resolves this: settle time at the lowest bands (20–25Hz) will be on the order of 100–200ms due to the narrow absolute bandwidth there, and quiet-signal denormal decay should get the same flush-to-zero treatment any biquad-based generator needs — neither changes the recommendation, both are just things the implementer should know going in.

## Sources

- [Cookbook formulae for audio EQ biquad filter coefficients (RBJ Audio-EQ-Cookbook)](https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt)
- [ANSI/ASA S1.11-2014/Part 1/IEC 61260-1:2014 — Electroacoustics: Octave-band and Fractional-octave-band Filters, Part 1: Specifications](https://webstore.ansi.org/standards/asa/asaansis111partiec612602014)
- [OIML R130 — Octave-band and one-third-octave-band filters](https://www.oiml.org/en/files/pdf_r/r130-e01.pdf)
- [Room EQ Wizard — Signal Generator help (octave/1/3-octave filtered noise via Butterworth HP/LP)](https://www.roomeqwizard.com/help/help_en-GB/html/siggen.html)
- [Sound-au.com — State Variable Filters (SVF stability/tuning characteristics, for context on why a direct RBJ biquad rather than a naive Chamberlin SVF was considered)](https://sound-au.com/articles/state-variable.htm)
- `docs/research/pink-white-noise-generation.md` (sibling doc — Kellett pink noise generator this design filters)
- `SoundCheck/ThirdOctaveBands.swift` (the 31 ISO 266 band list this design filters against)
