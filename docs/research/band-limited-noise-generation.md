# Band-limited pink noise filter approach — algorithm research

Resolves [Choose band-limited pink noise filter approach](https://github.com/vk0eppel/SoundCheck/issues/13) on the SoundCheck V2 map.

## The 5 presets, as a filter-design problem

Unlike the sibling ticket #14 (1/3-octave noise, resolved in `docs/research/one-third-octave-noise-generation.md`), this ticket's ranges are **not constant-Q**. Expressed in octaves-of-bandwidth:

| Preset | Shape | Bandwidth |
|---|---|---|
| 0–200Hz | lowpass (no real lower edge) | — |
| 200Hz–1kHz | bandpass | ~2.3 octaves |
| 1k–20kHz | bandpass (effectively highpass — the pink source's own top end already reaches toward Nyquist) | ~4.3 octaves |
| 7k–20kHz | highpass | ~1.5 octaves |
| manual range | anything, including narrow ranges | arbitrary |

A single second-order RBJ bandpass biquad — #14's answer — is parameterized by *one* bandwidth number tied to a *fixed* Q (per the RBJ cookbook's `1/Q = 2*sinh(ln2/2 * BW * w0/sin(w0))`, [Audio-EQ-Cookbook](https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt)). Force-fitting a single bandpass section across bandwidths ranging from "no lower edge at all" to "4+ octaves wide" would mean either an enormous Q spread (producing a very different edge steepness at each preset, with the widest presets barely attenuating anything near their nominal edges) or accepting that the "filter" does almost nothing for the wide presets — neither is the right shape for what these presets are actually asking for, which is a *lowpass* for 0–200Hz, two *highpasses* of different width for the top-end presets, and a *lowpass+highpass pair* for the one genuinely bandpass-shaped preset (200Hz–1kHz). This ticket is a genuinely different filter-design problem from #14, not a re-parameterization of the same one.

## Candidate topologies

**Single bandpass biquad (the #14 approach), reused as-is.** Rejected for the reason above: it's the wrong shape for 4 of the 5 presets, which are lowpass/highpass, not bandpass, in the sense that matters (one edge is at or past the source's own natural band limit).

**Cascaded RBJ highpass/lowpass biquad sections, one section (or a small cascade) per edge, Butterworth-aligned.** The [RBJ Audio-EQ-Cookbook](https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt) gives direct second-order lowpass and highpass biquads:

```
w0 = 2*pi*f0/Fs
alpha = sin(w0)/(2*Q)

# Lowpass:
b0 =  (1 - cos(w0))/2
b1 =   1 - cos(w0)
b2 =  (1 - cos(w0))/2
a0 =   1 + alpha
a1 =  -2*cos(w0)
a2 =   1 - alpha

# Highpass:
b0 =  (1 + cos(w0))/2
b1 = -(1 + cos(w0))
b2 =  (1 + cos(w0))/2
a0 =   1 + alpha
a1 =  -2*cos(w0)
a2 =   1 - alpha
```

A single section at `Q = 1/√2 ≈ 0.7071` is a maximally-flat (Butterworth) 2nd-order section, 12dB/octave. Cascading two identical-cutoff sections with different, specific Q values per section — instead of two identical Q=0.7071 sections — produces a true 4th-order (24dB/octave) Butterworth response, because a single N-th-order Butterworth polynomial factors into N/2 second-order sections each with its own Q, not N/2 copies of the same section. The standard per-section Q values (from the Butterworth pole angles `θ_k = (2k-1)π/(2n)`, `Q_k = 1/(2cos θ_k)`) are well known in filter-cascade design practice:

- 2nd order (1 section): Q = 0.70711
- 4th order (2 sections): Q = 0.54120, 1.30656
- 6th order (3 sections): Q = 0.51764, 0.70711, 1.93185
- 8th order (4 sections): Q = 0.50980, 0.60134, 0.89998, 2.56292

This factoring is standard cascaded-biquad filter design practice, covered in general IIR filter design references such as [EarLevel Engineering's "Cascading filters"](https://www.earlevel.com/main/2016/09/29/cascading-filters/) and discussed at length in the DSP forum threads collected around ["4th order Butterworth filter Q"](https://www.diyaudio.com/community/threads/4th-order-butterworth-filter-q.176992/) — every section shares the same `f0`, only `Q` differs per section, and each section is still a plain RBJ lowpass or highpass biquad. A bandpass preset (200Hz–1kHz) is simply a highpass cascade at the low edge in series with a lowpass cascade at the high edge, run back-to-back in the same per-sample loop.

**Higher-order alignments: Butterworth vs. Chebyshev vs. Bessel.** All three are standard analog-prototype families that map onto the same cascaded-biquad structure, differing only in the per-section `Q` (and, for Chebyshev, unequal per-section cutoff scaling) used to hit the poles of a different characteristic polynomial:

- **Butterworth** (maximally flat magnitude in the passband, monotonic rolloff, no ripple in either band) is the standard "no surprises" choice absent a specific reason to deviate.
- **Chebyshev** trades passband ripple (Type I) or stopband ripple (Type II) for a steeper transition at the same order — explicitly the "excessive passband ripple" artifact the issue asks to avoid, for no benefit that matters here: SoundCheck isn't chasing the steepest possible skirt at a fixed order, it's chasing a clean, unsurprising edge.
- **Bessel** optimizes for a maximally-flat *group delay* (linear phase, minimal step-response overshoot/ringing) at the cost of a much gentler knee for the same order — the right choice when a filter must pass sharp transients without ringing (e.g. a crossover carrying music, or a filter in the signal path of a percussive test tone). Noise is stationary and has no discrete transients to preserve the shape of; there is no "step" whose overshoot a listener could hear in continuous pink noise the way they would in a snare hit. Bessel's entire value proposition doesn't apply to a noise generator, and its shallower knee at a given order is a straight cost with no corresponding audible benefit here.

Butterworth is therefore the correct alignment for all 5 presets: no passband ripple, monotonic rolloff, and "ringing" in the classical step-response sense isn't a meaningful risk for a continuous stochastic signal — the only ringing-adjacent artifact worth worrying about at all is coefficient-swap discontinuity (see below), which is a state-handling concern, not a filter-alignment one.

**A note on Linkwitz-Riley.** LR crossovers are literally cascaded-Butterworth sections too (an LR4 is two cascaded 2nd-order Butterworth sections, [Wikipedia: Linkwitz–Riley filter](https://en.wikipedia.org/wiki/Linkwitz%E2%80%93Riley_filter); [Rane: Linkwitz-Riley Crossovers: A Primer](https://www.ranecommercial.com/legacy/note160.html)) — but LR's entire reason to exist is that a complementary lowpass and highpass path are summed back together acoustically (woofer + tweeter output arriving at a microphone/ear), and plain even-order Butterworth crossovers produce a +3dB bump at the crossover frequency when summed that way, which LR's −6dB-at-cutoff alignment corrects. SoundCheck never sums a lowpass path and a highpass path back together — each preset is a single serial chain (pink noise → one or two filter sections in series) producing one output signal, not two complementary outputs recombined. LR's defining property is irrelevant here; it's a "false friend" search result worth naming explicitly so a future implementer doesn't reach for it by pattern-matching "cascaded Butterworth" without checking whether the summing concern actually applies (it doesn't).

## Filter order per preset

REW's own signal generator — a real, widely used tool solving the same "generate filtered noise for driver/room testing" problem — documents exactly this cascaded-Butterworth-pair approach: "The filters are Butterworth high pass and low pass with a choice of filter order from 2nd (12 dB/octave) to 8th (48 dB/octave)" for octave/1/3-octave/custom-band random noise, with custom bands allowing arbitrary user-set low/high cutoffs subject to a minimum-bandwidth floor ([Room EQ Wizard — Signal Generator help](https://www.roomeqwizard.com/help/help_en-GB/html/siggen.html)). This is strong external validation that "cascade Butterworth HP/LP biquad sections, pick an order" is the standard, practical answer among tools built for the same purpose as SoundCheck, not an invented approach.

Applying that per preset:

- **0–200Hz**: lowpass-only cascade at 200Hz. No lower edge to build at all — the "highpass" side of the general framework (below) is simply skipped.
- **200Hz–1kHz**: highpass cascade at 200Hz in series with a lowpass cascade at 1kHz. At ~2.3 octaves this is comfortably wide enough that even a modest order (2nd–4th) leaves a broad, flat middle with the skirts only affecting the outer edges.
- **1k–20kHz**: highpass-only cascade at 1kHz. At 44.1/48kHz sample rates the pink source's own spectrum already tapers out approaching Nyquist, so a high-side lowpass section would do almost nothing meaningful here — the honest characterization in the issue ("arguably just a highpass") holds up under this framework, and the general "skip the missing edge" rule (see below) produces exactly that.
- **7k–20kHz**: highpass-only cascade at 7kHz. At ~1.5 octaves this is the narrowest fixed preset, so it benefits the most from a somewhat higher order (e.g. 4th, 24dB/octave) to make the edge unambiguous to the ear — a 2nd-order 12dB/octave knee is audibly gentle relative to a 1.5-octave-wide passband.
- **manual range**: reuse the identical cascade framework with runtime-supplied cutoffs; see below for the practical implications of that being fully dynamic rather than one of 4 fixed choices.

There's no strong reason to give different presets different orders as a hard rule — a single fixed order (2nd or 4th) applied uniformly via the shared cascade framework is simpler to implement, verify, and reason about than per-preset order tuning, and REW's own default behavior (a user-selectable order applied uniformly across all its band types) supports treating order as one knob on a shared mechanism rather than a per-preset decision. A 4th-order (two-section, 24dB/octave) cascade is a reasonable default: audibly firmer than 2nd-order at the narrower presets (7k–20kHz, and narrow manual ranges) without introducing the ripple/complexity of 6th/8th order, and cheap enough (see Cost, below) that there's no real pressure to go lower for CPU reasons. If a future pass wants steeper or gentler skirts, it's a matter of adding/removing sections from the same cascade — not a redesign.

## A unified two-edge framework (this is where #13 and #14 actually share code)

Every one of the 5 presets, plus the general reusable building block, is an instance of the same shape: **an optional highpass cascade at a low edge, in series with an optional lowpass cascade at a high edge**, where "optional" means the edge is skipped entirely if it doesn't apply (0–200Hz has no low edge; 1k–20kHz and 7k–20kHz have no meaningful high edge below Nyquist). Concretely:

```
struct EdgeFilter {
    var lowEdgeHz: Double?   // nil = no highpass section (e.g. the 0-200Hz preset)
    var highEdgeHz: Double?  // nil = no lowpass section (e.g. the 7k-20kHz preset)
    var order: Int           // sections per edge = order / 2
}
```

— built from the same RBJ `biquad(type: .lowpass/.highpass, f0, Q, sampleRate) -> (b0,b1,b2,a1,a2)` coefficient function #14 already needs for its bandpass sections (RBJ's cookbook derives lowpass, highpass, *and* bandpass from the same `w0`/`alpha` machinery, differing only in the `b` numerator terms — one function with a `FilterType` parameter covers all three). The Direct Form II biquad *state* struct and its per-sample apply step are identical regardless of which coefficients are loaded into it; only the coefficient-computation call differs between #13 (highpass and/or lowpass, Butterworth `Q` table, per edge) and #14 (bandpass, fixed `Q≈4.32`, per ISO band). This is the concrete answer to the "should these tickets share an implementation" question #14's writeup left open: yes, at the level of the biquad coefficient function and the Direct Form II state/apply code — not at the level of "one filter graph serves both," since #13 needs 1–2 sections *per edge* (0, 1, or 2 edges active) while #14 needs exactly 1 bandpass section per band. A `Biquad` type with a `.lowpass`/`.highpass`/`.bandpass` coefficient constructor, used by two independent call sites (a fixed-Q single-section site for #14, a two-edge Butterworth-cascade site for #13), is the natural shape — not a shared "band-limited noise" abstraction that tries to parameterize both problems through one knob set.

## Numerical concerns at low cutoffs

The 0–200Hz lowpass edge itself is unremarkable — 200Hz at 44.1/48kHz gives `w0` nowhere near the extreme low-frequency regime #14's doc flagged for its 20Hz band. But the **manual range's low edge is user-specified and could go arbitrarily low** (e.g. a user dialing in 20Hz or lower as a custom highpass edge) — at that point the exact same concern #14 documented applies unchanged: `alpha` shrinks toward zero, pole radius (`a2/a0`) sits extremely close to the unit circle, the section remains numerically stable in double precision but has a long settling time (time constant on the order of `1/(π · bandwidth)`, i.e. on the order of 100ms+ for a sub-25Hz edge) — worth the same UX note #14 carries forward (brief settle period after dialing in a very low manual cutoff), not a stability blocker. Denormal decay during quiet passages is the same known, cheap-to-mitigate concern as any biquad-based generator in this codebase (flush-to-zero or a vanishing DC bias).

## Cost

Each RBJ biquad section (Direct Form II) costs 4 multiplies + 4 adds per sample, a fixed cost independent of `f0`/`Q`. A 4th-order edge is 2 sections (~8 mults/8 adds); the worst case in this ticket — a 4th-order bandpass preset (200Hz–1kHz), 2 edges × 2 sections — is 4 sections total, ~16 mults/16 adds per sample, layered on top of the existing 7-operation Kellett pink filter (`SoundCheck/SignalRenderCore.swift`, `PinkNoiseGenerator.nextSample`). That's comfortably inside real-time audio budget at any common sample rate — dozens of scalar flops per sample is negligible next to the render callback's actual per-buffer budget (e.g. ~10ms of headroom for a 512-sample buffer at 48kHz).

Coefficient *computation* (as opposed to per-sample application) costs a handful of trig calls (`sin`, `cos` per edge, per section if per-section `f0` scaling were ever needed — though the Butterworth cascade above reuses one shared `f0` per edge, varying only `Q` per section, so it's `sin`+`cos` once per edge regardless of order) — trivial, and, as in #14, only needs to happen on a parameter change event, not per sample, so it doesn't touch the real-time hot path's steady-state cost.

The one place this differs meaningfully from #14: the **4 fixed presets** only need coefficients computed on a signal-type/preset switch (rare, discrete, already gated behind the ADR 0003 full-stop-on-switch behavior — no continuity to preserve across the switch at all). The **manual range**, however, is presumably driven by a live-updating UI control (a slider or a pair of numeric fields with live feedback), which could fire many update events per second while being dragged. The per-update trig cost itself is irrelevant (microseconds), but **swapping a running filter's coefficients while its internal state (`b1`/`b2`/etc.) still holds energy from the old coefficients is what actually risks an audible click or discontinuity** — not a CPU problem, a signal-continuity problem. The practical mitigation, consistent with general audio-DSP practice, is to debounce/coalesce manual-range coefficient updates to the UI's settle point (e.g. on drag-release or after a short idle gap, the same kind of debounce many parameter-smoothing designs use) rather than recomputing and hot-swapping on every intermediate drag frame — this is a UI-thread event-coalescing concern, not a real-time-thread cost concern, so it doesn't need to touch `SignalRenderCore.render()`'s per-sample loop at all, only how often `updateParameters` is called from the UI side.

## Recommendation

Cascade RBJ highpass/lowpass biquad sections — Butterworth-aligned (no ripple, monotonic rolloff, alignment doesn't matter for step response since noise has no transients to preserve) — filtering the existing `PinkNoiseGenerator` output, with each preset expressed as **an optional highpass edge and/or an optional lowpass edge**, either of which is entirely skipped when the preset doesn't need it:

- 0–200Hz → lowpass edge only, at 200Hz.
- 200Hz–1kHz → highpass edge at 200Hz + lowpass edge at 1kHz.
- 1k–20kHz → highpass edge only, at 1kHz (the high side is already near the source's natural top end).
- 7k–20kHz → highpass edge only, at 7kHz.
- manual range → same framework, arbitrary low/high, coefficients recomputed on parameter change and debounced against rapid UI-driven updates.

A single RBJ bandpass biquad (#14's answer) is the wrong topology for 4 of these 5 shapes and is explicitly rejected. A default order of 4 (two cascaded sections per active edge, Butterworth `Q = 0.54120, 1.30656`) is a reasonable uniform starting point across all presets — audibly firm enough at the narrowest preset (7k–20kHz) without ripple, and cheap enough in the worst case (a 4-section bandpass preset, ~16 mults/16 adds per sample) to leave enormous real-time headroom. This shares its actual implementation with #14 at the level of one RBJ biquad coefficient function (parameterized by filter type: lowpass/highpass/bandpass) and one Direct Form II state/apply routine — not at the level of a single shared "band-limiting" abstraction, since the two tickets compose that shared building block differently (a fixed-Q single bandpass section per ISO band for #14; a variable-count cascade of highpass and/or lowpass sections per preset edge for #13). The one implementation note worth carrying forward: debounce manual-range coefficient recomputation against live UI drag events to avoid coefficient-swap discontinuities, and expect a ~100ms+ settle time if a user dials the manual range's low edge down toward 20Hz, for the same numerically-stable-but-slow-to-settle reason #14 found at its lowest ISO band.

## Level compensation (post-implementation addendum)

Shipping the filter cascade above surfaced a follow-on correctness issue: the presets are unity-gain *within* their passband, but say nothing about how much of the source pink noise's total energy that passband actually contains. Pink noise's PSD is 1/f — equal energy per octave — so narrowing from the app's full 20Hz–20kHz span (≈9.97 octaves) down to, say, the 7k–20kHz preset (≈1.5 octaves) discards most of the signal's energy. Without compensation, `levelDbfs` described the pre-filter amplitude scale factor, not the actual (much quieter) filtered output — a "-20dBFS" 7k–20kHz preset measured many dB quieter in RMS than "-20dBFS" full-range pink noise, even though both used the identical `levelDbfs` gain multiplier.

The fix (`BandLimitedFilterChain.levelCompensationGain`, computed once in `init`) applies a makeup gain of `sqrt(fullRangeOctaveSpan / bandOctaveSpan)` — the amplitude-domain form of the power ratio implied by equal-energy-per-octave — so a preset's RMS at a given `levelDbfs` matches what full-range pink noise's RMS would be at that same setting. `bandOctaveSpan` is derived from `BandLimitedPreset.edges`, using the app's own fixed 20Hz floor when there's no highpass edge (0–200Hz) and its 20kHz ceiling when there's no lowpass edge (1k–20kHz, 7k–20kHz) — the same bounds used everywhere else in the app (frequency field, `ThirdOctaveBands`). This is deliberately an analytic, closed-form gain rather than a runtime RMS-measurement/calibration pass or an adaptive AGC — consistent with this codebase's existing preference for real-time-safe, deterministic per-parameter-change computation (see "Cost," above) over anything that measures and adapts at runtime.

**Known limitation, not fixed as part of this change:** Kellett's pink noise generator isn't peak-normalized or clipped anywhere in the render path, so this makeup gain (up to roughly +14.8dB for the narrowest cases) makes narrowband presets' transient peaks approach/exceed full scale sooner than before at high `levelDbfs` settings. This is a pre-existing headroom characteristic the compensation makes more noticeable, not a new problem introduced by it — worth knowing if a future pass adds output limiting/clipping protection.

## Effective-noise-bandwidth calibration (second post-implementation addendum)

The `sqrt(fullRangeOctaveSpan / bandOctaveSpan)` closed form above assumes an ideal brick-wall passband between the nominal edges. Measuring the *actual* filtered RMS against full-range — once the test harness was fixed to actually render noise rather than a fallback sine — showed that assumption costs up to ~±2.4dB per band, worst at the spectrum edges (the 0–200Hz preset ran ~+1.4dB, and the 1/3-octave edge bands worse still). It ignores the real Butterworth skirts and passband shape, bilinear frequency warping near DC/Nyquist, and the fact that "full range" is really the generator's ~DC–Nyquist span (sample-rate-dependent), not a fixed 20Hz–20kHz.

The closed form is now replaced by `noiseBandMakeupGain` (`SoundCheck/SignalRenderCore.swift`), shared by `BandLimitedFilterChain` and `ThirdOctaveFilterChain`. It derives the makeup gain from the *realized* cascade's effective noise bandwidth: `sqrt( ∫S(f)df / ∫S(f)·|H(f)|²df )`, where `|H(f)|²` is the cascade's true power response (`Biquad.magnitudeSquared`) and `S(f)` is the noise PSD — flat for white, the actual Kellett filter response for pink (`kellettPinkResponseSquared`, which plateaus toward DC so the low-end reference energy is finite and correct, where ideal 1/f would diverge). Evaluated once per filter build on a dense log-frequency grid up to the real Nyquist, so it's inherently frequency- and sample-rate-aware. Full-range (no sections) returns exactly 1, so the full-range absolute-level constants (`pinkLevelCompensationGain`, `noiseFullScaleReferenceGain`) are untouched. This holds every preset within ≤1dB of full-range across 44.1/48/96kHz (verified by `filteredPinkModesMatchFullRangeRMSAtTheSameLevel`/`filteredWhiteModesMatchFullRangeRMSAtTheSameLevel`, tightened from the former ±3dB), replacing `fullRangeOctaveSpan` and the per-shape ratio branches entirely.

## Sources

- [Cookbook formulae for audio EQ biquad filter coefficients (RBJ Audio-EQ-Cookbook)](https://webaudio.github.io/Audio-EQ-Cookbook/Audio-EQ-Cookbook.txt)
- [Room EQ Wizard — Signal Generator help (Butterworth HP/LP filtered noise, selectable 2nd–8th order, custom bands)](https://www.roomeqwizard.com/help/help_en-GB/html/siggen.html)
- [EarLevel Engineering — Cascading filters (per-section Q values for higher-order Butterworth cascades)](https://www.earlevel.com/main/2016/09/29/cascading-filters/)
- [diyAudio — 4th order Butterworth filter Q (community derivation/confirmation of the 0.5412/1.3066 per-section Q values)](https://www.diyaudio.com/community/threads/4th-order-butterworth-filter-q.176992/)
- [Wikipedia — Linkwitz–Riley filter (cascaded-Butterworth construction and why it exists for crossover summing, not relevant to this ticket's serial-chain use case)](https://en.wikipedia.org/wiki/Linkwitz%E2%80%93Riley_filter)
- [Rane Commercial — Linkwitz-Riley Crossovers: A Primer](https://www.ranecommercial.com/legacy/note160.html)
- `docs/research/pink-white-noise-generation.md` (sibling doc — Kellett pink noise generator this design filters)
- `docs/research/one-third-octave-noise-generation.md` (sibling doc for #14 — the constant-Q bandpass case this ticket's non-constant-Q cascade case is compared against, and where the code-reuse question originated)
- `SoundCheck/SignalRenderCore.swift` (the render-block architecture and existing `PinkNoiseGenerator` this design filters)
