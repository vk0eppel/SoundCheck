# White noise band-limiting — level compensation derivation

Resolves the level-compensation half of [Add White noise's render-core support](https://github.com/vk0eppel/SoundCheck/issues/37).

## Why Pink's compensation formula doesn't carry over

White noise (`.pink`'s sibling `GeneratorKind`) gained the same three sub-modes Pink noise already had — Full-range, Band-limited, 1/3-Octave — reusing `BandLimitedFilterChain`/`ThirdOctaveFilterChain` as-is, since both are plain `Biquad` cascades with no assumption about the input signal's spectral shape baked into their topology (see `docs/research/band-limited-noise-generation.md` and `docs/research/one-third-octave-noise-generation.md`).

Level compensation is a different story. Pink's existing makeup-gain formulas (`BandLimitedFilterChain.levelCompensationGain`, `thirdOctaveLevelCompensationGain`) are both derived from Pink's 1/f power spectral density — equal energy per *octave* — so a band's energy fraction of full-range is `log2(highHz/lowHz) / fullRangeOctaveSpan`. White noise's PSD is flat — equal energy per *Hz* (linear frequency), not per octave — so its energy fraction of full-range is instead `(highHz - lowHz) / fullRangeBandwidthHz`. Reusing Pink's octave-span formula on White would apply the wrong makeup gain, and not by a small margin: a preset like 7k–20kHz is a large fraction of White's linear-Hz energy (~65%) but a much smaller fraction of an octave-log scale (~1.5 of ~10 octaves, ~15%), so the octave-span formula would badly *under*-boost it; conversely 0–200Hz is a tiny linear-Hz fraction but a comparatively larger octave fraction, so the octave-span formula would badly *over*-boost it.

## The derivation

**Band-limited.** RMS² of a flat-PSD signal scales linearly with bandwidth in Hz. The makeup gain that restores full-range RMS at the same `levelDbfs` is the amplitude-domain (square-root) form of that power ratio:

```
whiteLevelCompensationGain = sqrt(fullRangeBandwidthHz / bandWidthHz)
```

where `bandWidthHz = highHz - lowHz`, using the app's fixed 20Hz/20kHz bounds when a preset has no highpass/lowpass edge — the same convention `BandLimitedFilterChain` already uses for Pink. `fullRangeBandwidthHz = 20000 - 20 = 19980`, the linear-Hz analog of `fullRangeOctaveSpan`.

Implemented as a second branch inside `BandLimitedFilterChain.init`, selected by a new `NoiseSpectralShape` parameter (`.pinkOneOverF` / `.whiteFlat`) — not a separate filter-chain type, since the topology is identical and only the compensation-gain formula differs.

**1/3-Octave.** Pink's `thirdOctaveLevelCompensationGain` is a single fixed constant because every ISO 266 1/3-octave band is, by construction, exactly 1/3 octave wide — a fixed fraction regardless of center frequency. A band's width in **Hz**, however, is *not* constant across bands: `bandwidthHz = centerHz * (2^(1/6) - 2^(-1/6))` (the difference between the band's upper and lower edges, `centerHz * 2^(1/6)` and `centerHz / 2^(1/6)`) scales with `centerHz` — a low band (e.g. 31.5Hz) is only a few Hz wide, a high band (e.g. 16kHz) is thousands of Hz wide. So White's 1/3-octave compensation can't be one constant; it's computed per band:

```
whiteThirdOctaveLevelCompensationGain(centerHz) = sqrt(fullRangeBandwidthHz / (centerHz * (2^(1/6) - 2^(-1/6))))
```

Applied at `WhiteNoiseGenerator.nextSample`'s call site the same way Pink applies its fixed constant — `ThirdOctaveFilterChain` itself carries no compensation for either color, consistent with its existing shape.

## Validation

Both formulas were validated empirically against `filteredWhiteModesMatchFullRangeRMSAtTheSameLevel` (`SoundCheckTests.swift`) — the White counterpart of Pink's `filteredPinkModesMatchFullRangeRMSAtTheSameLevel`, asserting every band-limited preset and a sample of 1/3-octave bands measure within ±3dB of full-range White's RMS at a fixed `levelDbfs`. Both formulas passed on first implementation, no tuning needed.

`pinkLevelCompensationGain` (the Kellett-generator-specific empirical makeup gain that calibrates Pink's raw RMS to match White's) is unrelated to this derivation and required no changes — it addresses Kellett's construction, not band-limiting, and White's own full-range RMS is already the reference that gain calibrates against.

## Superseded by the effective-noise-bandwidth integral (post-implementation addendum)

The two closed forms above (`.whiteFlat`'s `sqrt(fullRangeBandwidthHz / bandwidthHz)` and `whiteThirdOctaveLevelCompensationGain`) were correct in their nominal-brick-wall model but, like Pink's octave-span form, left up to ~1.5dB of real per-band error at the spectrum edges once measured against actual filtered RMS across sample rates (the 20Hz 1/3-octave band was the worst). They're now replaced by the shared `noiseBandMakeupGain` — see the "Effective-noise-bandwidth calibration" addendum in `band-limited-noise-generation.md` for the derivation. For white, the integral simply uses a flat PSD (`S=1`, so the log-grid weight is `∝ f`); no separate white formula remains. `fullRangeBandwidthHz` and `whiteThirdOctaveLevelCompensationGain` are deleted. The validation tolerance tightened from ±3dB to ≤1dB, now checked at 44.1/48/96kHz.

## Sources

- `docs/research/band-limited-noise-generation.md` (Pink's band-limited filter topology and its "Level compensation" addendum, the octave-span formula this doc departs from)
- `docs/research/one-third-octave-noise-generation.md` (Pink's 1/3-octave filter topology)
- `SoundCheck/SignalRenderCore.swift` (`BandLimitedFilterChain`, `ThirdOctaveFilterChain`, `WhiteNoiseGenerator`)
