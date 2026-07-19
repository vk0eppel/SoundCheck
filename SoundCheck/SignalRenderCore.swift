//
//  SignalRenderCore.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 16/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import Foundation
import os

// MARK: - Generators

/// Widened per ADR 0004 to receive the full parameter snapshot (not just frequency/sample
/// rate) so generators with extra configuration — Sweep's duration, Pink's noise mode —
/// can read what they need without the signature changing again per generator. `reset()`
/// is a lifecycle hook `render()` calls once a generator has fully silenced (see
/// `SignalRenderCore.render()`), for generators that need to restart from a fixed state
/// (e.g. Sweep's elapsed-time counter) rather than free-running across stop/start like
/// Sine's phase does; most generators don't need it, hence the no-op default below.
protocol SignalGenerator: AnyObject {
    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double
    func reset()
}

extension SignalGenerator {
    func reset() {}
}

final class SineGenerator: SignalGenerator {
    private var phase: Double = 0

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        let sample = sin(phase)
        phase += 2 * .pi * parameters.frequencyHz / sampleRate
        if phase > 2 * .pi { phase -= 2 * .pi }
        return sample
    }
}

/// A fixed-50%-duty-cycle square wave, band-limited via PolyBLEP polynomial correction
/// applied in a narrow window around each of its two discontinuities per cycle (rising at
/// phase 0, falling at phase 0.5) — a naive `sign()`-based square aliases at generation
/// time (its infinite odd-harmonic series folds harmonics above Nyquist back into the
/// audible range), which no filter applied afterward can undo. See docs/v1-spec.md's "V2
/// addendum: square wave" for why PolyBLEP was chosen over additive synthesis or
/// oversampling. Implements `SignalGenerator` in its narrowest form (frequency + sample
/// rate only, default no-op `reset()`) — per ADR 0004's note, the protocol's widening
/// anticipated square wave needing a duty-cycle parameter, but duty cycle ended up fixed,
/// so this generator doesn't end up exercising that widened surface.
final class SquareGenerator: SignalGenerator {
    private var phase: Double = 0 // normalized to [0, 1), unlike SineGenerator's [0, 2π) phase

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        let dt = parameters.frequencyHz / sampleRate
        var sample = phase < 0.5 ? 1.0 : -1.0
        sample += Self.polyBLEP(phase, dt)
        sample -= Self.polyBLEP((phase + 0.5).truncatingRemainder(dividingBy: 1), dt)

        phase += dt
        if phase >= 1 { phase -= 1 }

        return sample
    }

    /// Välimäki & Huovilainen's polynomial band-limited step: a 2nd-order polynomial
    /// approximation of the ideal band-limited step, non-zero only within one sample
    /// period's width (`dt`) of a discontinuity at `t == 0`.
    private static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        } else if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }
}

/// A continuous logarithmic sweep across the app's fixed 20Hz-20kHz range — see
/// docs/v1-spec.md's "V2 addendum: sine sweep". `elapsedSamples` is audio-thread-only
/// state tracking position within the configured `sweepDurationSeconds`; instantaneous
/// frequency is `20 * (20000/20)^t` where `t` is elapsed time normalized by duration.
/// Reaching `t = 1.0` wraps instantly back to `t = 0` (an abrupt frequency drop, not a
/// waveform discontinuity -- phase itself free-runs continuously across the wrap, exactly
/// as it does across a normal Sine's steady state). `reset()` zeroes `elapsedSamples` so
/// every fresh ON press restarts from 20Hz rather than resuming mid-sweep, per ADR 0004.
final class SweepGenerator: SignalGenerator {
    private static let startHz: Double = 20
    private static let endHz: Double = 20000

    private var elapsedSamples: Double = 0
    private var phase: Double = 0

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        let totalSamples = max(parameters.sweepDurationSeconds, 0.001) * sampleRate
        let t = elapsedSamples / totalSamples
        let instantaneousFrequencyHz = Self.startHz * pow(Self.endHz / Self.startHz, t)

        let sample = sin(phase)
        phase += 2 * .pi * instantaneousFrequencyHz / sampleRate
        if phase > 2 * .pi { phase -= 2 * .pi }

        elapsedSamples += 1
        if elapsedSamples >= totalSamples {
            elapsedSamples -= totalSamples
        }

        return sample
    }

    func reset() {
        elapsedSamples = 0
    }
}

/// Owns "rebuild the band-limited/1/3-octave filter when `NoiseMode` changes, else reuse"
/// and "dispatch the raw sample through whichever filter (or none) is currently active" —
/// the ~25-line pattern `PinkNoiseGenerator` and `WhiteNoiseGenerator` used to each implement
/// separately, identical but for `NoiseSpectralShape` and White's extra per-band
/// compensation gain. Real-time-safe: filters are only rebuilt on an actual mode change,
/// never per sample, the same guarantee the two generators already provided individually.
struct NoiseModeFilter {
    private let shape: NoiseSpectralShape
    private let thirdOctaveCompensationGain: (Double) -> Double

    private var currentMode: NoiseMode = .fullRange
    private var bandLimitedFilter: BandLimitedFilterChain?
    private var thirdOctaveFilter: ThirdOctaveFilterChain?
    // Computed once when `.thirdOctave` is (re)adopted, not per sample -- Pink passes a
    // closure returning its fixed `thirdOctaveLevelCompensationGain` constant; White's is a
    // function of centerHz, so it can't be a simple constant and must be cached here instead.
    private var cachedThirdOctaveCompensationGain: Double = 1

    /// `thirdOctaveCompensationGain` computes the per-band makeup gain applied after
    /// `ThirdOctaveFilterChain`, given the band's center Hz — Pink passes
    /// `{ _ in thirdOctaveLevelCompensationGain }` (its fixed constant), White passes
    /// `whiteThirdOctaveLevelCompensationGain(centerHz:)` directly (a function of center Hz,
    /// since White's flat PSD needs different per-band math than Pink's 1/f one).
    init(shape: NoiseSpectralShape, thirdOctaveCompensationGain: @escaping (Double) -> Double) {
        self.shape = shape
        self.thirdOctaveCompensationGain = thirdOctaveCompensationGain
    }

    mutating func process(_ sample: Double, mode: NoiseMode, sampleRate: Double) -> Double {
        if mode != currentMode {
            currentMode = mode
            switch mode {
            case .fullRange:
                bandLimitedFilter = nil
                thirdOctaveFilter = nil
            case .bandLimited(let preset):
                bandLimitedFilter = BandLimitedFilterChain(preset: preset, sampleRate: sampleRate, shape: shape)
                thirdOctaveFilter = nil
            case .thirdOctave(let bandIndex):
                let centerHz = ThirdOctaveBands.centerFrequenciesHz[bandIndex]
                thirdOctaveFilter = ThirdOctaveFilterChain(centerHz: centerHz, sampleRate: sampleRate)
                cachedThirdOctaveCompensationGain = thirdOctaveCompensationGain(centerHz)
                bandLimitedFilter = nil
            }
        }

        switch currentMode {
        case .fullRange:
            return sample
        case .bandLimited:
            return bandLimitedFilter?.process(sample) ?? sample
        case .thirdOctave:
            return (thirdOctaveFilter?.process(sample) ?? sample) * cachedThirdOctaveCompensationGain
        }
    }
}

/// xorshift64* — fast, non-cryptographic, real-time-safe. Not SystemRandomNumberGenerator,
/// which draws from OS entropy per call and isn't real-time-safe. See docs/research/pink-white-noise-generation.md.
/// Carries the same three sub-modes Pink noise does (see docs/research/white-noise-band-limiting.md
/// for why White's level-compensation math has to differ from Pink's), rebuilt only when the
/// mode actually changes, via the shared `NoiseModeFilter`.
final class WhiteNoiseGenerator: SignalGenerator {
    private var state: UInt64
    private var noiseModeFilter = NoiseModeFilter(
        shape: .whiteFlat, thirdOctaveCompensationGain: whiteThirdOctaveLevelCompensationGain(centerHz:))

    init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
        state = seed
    }

    /// The pure PRNG draw, with no mode dispatch — used directly by `PinkNoiseGenerator`'s
    /// internal white-noise source, which must stay unaffected by
    /// `RenderParameters.whiteNoiseMode` regardless of its value (Pink and White are
    /// independent signal types; a setting that only means something while White is the
    /// active generator must not silently reshape Pink's tone too).
    fileprivate func rawSample() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        let unitInterval = Double(state >> 11) * (1.0 / Double(1 << 53))
        return unitInterval * 2 - 1
    }

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        let whiteSample = rawSample()
        return noiseModeFilter.process(whiteSample, mode: parameters.whiteNoiseMode, sampleRate: sampleRate)
    }
}

/// Paul Kellett's refined ("instrumentation grade") pink noise filter, ~0.05dB accurate
/// above 9.2Hz. See docs/research/pink-white-noise-generation.md for why this was chosen
/// over Voss-McCartney.
final class PinkNoiseGenerator: SignalGenerator {
    private let white: WhiteNoiseGenerator
    private var b0: Double = 0
    private var b1: Double = 0
    private var b2: Double = 0
    private var b3: Double = 0
    private var b4: Double = 0
    private var b5: Double = 0
    private var b6: Double = 0

    // Rebuilt only when `pinkNoiseMode` actually changes (never per sample) — see
    // docs/research/band-limited-noise-generation.md and
    // docs/research/one-third-octave-noise-generation.md.
    private var noiseModeFilter = NoiseModeFilter(
        shape: .pinkOneOverF, thirdOctaveCompensationGain: { _ in thirdOctaveLevelCompensationGain })

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        white = WhiteNoiseGenerator(seed: seed)
    }

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        // Raw draw only, no mode dispatch -- Pink's internal white-noise source must stay
        // unaffected by `RenderParameters.whiteNoiseMode` (see `WhiteNoiseGenerator.rawSample`).
        let whiteSample = white.rawSample()
        b0 = 0.99886 * b0 + whiteSample * 0.0555179
        b1 = 0.99332 * b1 + whiteSample * 0.0750759
        b2 = 0.96900 * b2 + whiteSample * 0.1538520
        b3 = 0.86650 * b3 + whiteSample * 0.3104856
        b4 = 0.55000 * b4 + whiteSample * 0.5329522
        b5 = -0.7616 * b5 - whiteSample * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + whiteSample * 0.5362) * 0.11 * pinkLevelCompensationGain
        b6 = whiteSample * 0.115926

        return noiseModeFilter.process(pink, mode: parameters.pinkNoiseMode, sampleRate: sampleRate)
    }
}

// MARK: - Parameters

enum GeneratorKind: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    // Declaration order drives the signal-type picker (via `allCases`); raw values key
    // Codable persistence, so this order is presentation-only and safe to change.
    case sine = "SINE"
    case square = "SQUARE"
    case pink = "PINK"
    case white = "WHITE"
    case sweep = "SWEEP"

    var id: String { rawValue }
}

/// A sub-mode shared by both noise-color generators (Pink and White), not a `GeneratorKind`
/// of its own — band-limited and 1/3-octave noise are still "Pink" or "White," just
/// spectrally shaped. `RenderParameters`/`SettingsSnapshot` carry one field per color
/// (`pinkNoiseMode`, `whiteNoiseMode`) so each color's selection persists independently.
enum NoiseMode: Equatable, Sendable, Codable {
    case fullRange
    case bandLimited(BandLimitedPreset)
    case thirdOctave(bandIndex: Int)
}

extension NoiseMode {
    /// The UI-facing, picker-friendly projection of `NoiseMode` — `.bandLimited`/
    /// `.thirdOctave` carry associated data, so `NoiseMode` itself can't be
    /// `CaseIterable`/segmented-picker-friendly. `ContentView`'s `NoiseModeDraft` bridges
    /// between this and the real `NoiseMode`.
    enum Family: String, CaseIterable, Identifiable {
        case fullRange = "FULL-RANGE"
        case bandLimited = "BAND-LIMITED"
        case thirdOctave = "1/3-OCTAVE"

        var id: String { rawValue }
    }

    var family: Family {
        switch self {
        case .fullRange: .fullRange
        case .bandLimited: .bandLimited
        case .thirdOctave: .thirdOctave
        }
    }
}

/// The 5 band-limited presets (#22), each an optional highpass edge and/or optional
/// lowpass edge — see docs/research/band-limited-noise-generation.md's "unified two-edge
/// framework." `nil` means that edge is skipped entirely (e.g. 0-200Hz has no lower edge).
enum BandLimitedPreset: Equatable, Sendable, Codable {
    case preset0to200Hz
    case preset200HzTo1kHz
    case preset1kTo20kHz
    case preset7kTo20kHz
    case manual(lowHz: Double, highHz: Double)

    var edges: (highpassHz: Double?, lowpassHz: Double?) {
        switch self {
        case .preset0to200Hz: (nil, 200)
        case .preset200HzTo1kHz: (200, 1000)
        case .preset1kTo20kHz: (1000, nil)
        case .preset7kTo20kHz: (7000, nil)
        case .manual(let lowHz, let highHz): (lowHz, highHz)
        }
    }
}

extension BandLimitedPreset {
    /// The UI-facing, picker-friendly projection of `BandLimitedPreset` — `.manual` carries
    /// its own low/high values separately, for the same reason `NoiseMode.Family` exists.
    enum Selection: String, CaseIterable, Identifiable {
        case preset0to200Hz = "0–200Hz"
        case preset200HzTo1kHz = "200Hz–1kHz"
        case preset1kTo20kHz = "1kHz–20kHz"
        case preset7kTo20kHz = "7kHz–20kHz"
        case manual = "MANUAL"

        var id: String { rawValue }
    }

    var selection: Selection {
        switch self {
        case .preset0to200Hz: .preset0to200Hz
        case .preset200HzTo1kHz: .preset200HzTo1kHz
        case .preset1kTo20kHz: .preset1kTo20kHz
        case .preset7kTo20kHz: .preset7kTo20kHz
        case .manual: .manual
        }
    }
}

/// Which noise color a `BandLimitedFilterChain` is shaping — its power spectral density
/// determines how RMS scales with bandwidth, so it determines which level-compensation
/// formula is correct. See docs/research/white-noise-band-limiting.md.
enum NoiseSpectralShape {
    /// Pink noise's PSD is 1/f — equal energy per octave.
    case pinkOneOverF
    /// White noise's PSD is flat — equal energy per Hz (linear frequency).
    case whiteFlat
}

/// Cascades `Biquad` sections realizing a `BandLimitedPreset`'s optional highpass and/or
/// lowpass edge, each edge a 4th-order (2-section) Butterworth cascade — the standard
/// per-section Q values from docs/research/band-limited-noise-generation.md. Also applies
/// `levelCompensationGain` so a narrowed band's RMS matches full-range noise's RMS at
/// the same `levelDbfs` — the formula depends on `shape` (see `NoiseSpectralShape` and the
/// comment on `fullRangeOctaveSpan` below for why Pink and White need different math).
struct BandLimitedFilterChain {
    private static let butterworth4thOrderQs: [Double] = [0.54120, 1.30656]

    private var sections: [Biquad] = []
    private let levelCompensationGain: Double

    init(preset: BandLimitedPreset, sampleRate: Double, shape: NoiseSpectralShape) {
        let edges = preset.edges
        if let highpassHz = edges.highpassHz {
            sections += Self.butterworth4thOrderQs.map {
                Biquad(type: .highpass, f0: highpassHz, q: $0, sampleRate: sampleRate)
            }
        }
        if let lowpassHz = edges.lowpassHz {
            sections += Self.butterworth4thOrderQs.map {
                Biquad(type: .lowpass, f0: lowpassHz, q: $0, sampleRate: sampleRate)
            }
        }

        // No highpass edge (0-200Hz) floors at the app's own 20Hz bound; no lowpass edge
        // (1k-20kHz/7k-20kHz) ceils at its 20kHz bound -- the same fixed range used
        // everywhere else (frequency field, ThirdOctaveBands).
        let lowHz = edges.highpassHz ?? 20
        let highHz = edges.lowpassHz ?? 20000
        switch shape {
        case .pinkOneOverF:
            let octaveSpan = log2(highHz / lowHz)
            levelCompensationGain = octaveSpan > 0 ? (fullRangeOctaveSpan / octaveSpan).squareRoot() : 1
        case .whiteFlat:
            let bandwidthHz = highHz - lowHz
            levelCompensationGain = bandwidthHz > 0 ? (fullRangeBandwidthHz / bandwidthHz).squareRoot() : 1
        }
    }

    mutating func process(_ x: Double) -> Double {
        var y = x
        for index in sections.indices {
            y = sections[index].process(y)
        }
        return y * levelCompensationGain
    }
}

/// Cascades a highpass edge at `centerHz / 2^(1/6)` and a lowpass edge at `centerHz * 2^(1/6)`
/// -- the standard ISO 266 1/3-octave band boundaries -- each a 16th-order (8-section)
/// Butterworth cascade, replacing an earlier single fixed-Q bandpass `Biquad` design. See
/// docs/research/one-third-octave-noise-generation.md's "Two-edge Butterworth cascade"
/// addendum for why: naive identical-bandpass-section cascading didn't scale slope cleanly,
/// while this two-edge shape (same topology `BandLimitedFilterChain` already uses, just at
/// the ISO 1/3-octave edges instead of a preset's edges) measured a consistent ~-0.2dB center
/// dip and steeper skirts than an 8th-order version of the same shape.
struct ThirdOctaveFilterChain {
    private static let butterworth16thOrderQs: [Double] = [
        0.50242, 0.52250, 0.56694, 0.64682, 0.78815, 1.06068, 1.72245, 5.10115,
    ]

    private var sections: [Biquad] = []

    init(centerHz: Double, sampleRate: Double) {
        let lowEdge = centerHz / pow(2, 1.0 / 6.0)
        let highEdge = centerHz * pow(2, 1.0 / 6.0)
        sections = Self.butterworth16thOrderQs.map {
            Biquad(type: .highpass, f0: lowEdge, q: $0, sampleRate: sampleRate)
        }
        sections += Self.butterworth16thOrderQs.map {
            Biquad(type: .lowpass, f0: highEdge, q: $0, sampleRate: sampleRate)
        }
    }

    mutating func process(_ x: Double) -> Double {
        var y = x
        for index in sections.indices {
            y = sections[index].process(y)
        }
        return y
    }
}

/// Kellett's `0.11` scaling constant was chosen to keep pink noise's *peak* roughly bounded
/// for a full-scale white noise input, not to match its RMS (perceived loudness) to Sine's
/// or White's at the same `levelDbfs` -- pink noise's higher crest factor means its raw
/// output measures ~9.5dB quieter in RMS than White noise at the same nominal level, audibly
/// so. Unlike `fullRangeOctaveSpan`'s ratio, there's no closed-form expression for Kellett's
/// IIR construction's output RMS, so this is an empirically-measured makeup gain (RMS of 20M
/// samples of the exact `PinkNoiseGenerator` recurrence, calibrated to match
/// `WhiteNoiseGenerator`'s theoretical uniform-distribution RMS of `1/sqrt(3)`) -- the same
/// empirical-constant approach Kellett's own coefficients already use. Applied to the raw
/// `pink` sample before mode-filtering, so it uniformly lifts `.fullRange`, `.bandLimited`,
/// and `.thirdOctave` together, preserving the relative levels the compensation gains above
/// establish between Pink's sub-modes. See docs/research/pink-white-noise-generation.md.
let pinkLevelCompensationGain = 2.98

/// Pink noise's PSD is 1/f -- equal energy per octave -- so narrowing from the app's full
/// 20Hz-20kHz span down to a smaller band discards most of the signal's energy. Without
/// compensation, `levelDbfs` would describe the pre-filter amplitude, not the actual
/// (much quieter) filtered output. `fullRangeOctaveSpan` is the reference span used by both
/// `BandLimitedFilterChain` and `thirdOctaveLevelCompensationGain` below to compute a makeup
/// gain that restores the RMS a full-range signal would have at the same `levelDbfs`. See
/// docs/research/band-limited-noise-generation.md and
/// docs/research/one-third-octave-noise-generation.md.
let fullRangeOctaveSpan = log2(20000.0 / 20.0)

/// 1/3-octave is always exactly 1/3-octave wide, so unlike `BandLimitedFilterChain`'s
/// per-preset span, this compensation gain is a single fixed constant.
let thirdOctaveLevelCompensationGain = (fullRangeOctaveSpan / (1.0 / 3.0)).squareRoot()

/// White noise's PSD is flat -- equal energy per Hz, not per octave -- so its RMS² scales
/// linearly with bandwidth in Hz, unlike Pink's octave-span scaling. `fullRangeBandwidthHz`
/// is the linear-Hz analog of `fullRangeOctaveSpan`, used by `BandLimitedFilterChain`'s
/// `.whiteFlat` shape and by `whiteThirdOctaveLevelCompensationGain` below. See
/// docs/research/white-noise-band-limiting.md.
let fullRangeBandwidthHz = 20000.0 - 20.0

/// Unlike Pink's fixed-fraction 1/3-octave band (always exactly 1/3 octave wide, hence a
/// single `thirdOctaveLevelCompensationGain` constant), a 1/3-octave band's width in Hz
/// varies with its center frequency (roughly constant *percentage* bandwidth, so low bands
/// are narrow in Hz and high bands are wide) -- so White's compensation has to be computed
/// per band rather than as one constant. See docs/research/white-noise-band-limiting.md.
func whiteThirdOctaveLevelCompensationGain(centerHz: Double) -> Double {
    let bandwidthHz = centerHz * (pow(2, 1.0 / 6.0) - pow(2, -1.0 / 6.0))
    return bandwidthHz > 0 ? (fullRangeBandwidthHz / bandwidthHz).squareRoot() : 1
}

struct RenderParameters: Equatable, Sendable {
    var generatorKind: GeneratorKind = .sine
    var frequencyHz: Double = 1000
    var levelDbfs: Double = -20
    var running: Bool = false
    var channelMuted: [Bool] = []
    var channelPhaseReversed: [Bool] = []
    var pinkNoiseMode: NoiseMode = .fullRange
    var whiteNoiseMode: NoiseMode = .fullRange
    var sweepDurationSeconds: Double = 10
}

// MARK: - Render core

/// The real-time-safe heart of SoundCheck: generators, the start/stop ramp, and
/// per-channel mute/phase, decoupled from AVAudioEngine so it's independently testable.
/// #9 wraps `render` in an actual `AVAudioSourceNode`'s render block.
final class SignalRenderCore: @unchecked Sendable {
    private static let rampDurationSeconds: Double = 0.015

    private let parametersLock = OSAllocatedUnfairLock(initialState: RenderParameters())

    // Audio-thread-only state: only ever touched inside `render`, which per the architecture
    // decided in #2 is called from a single real-time render callback, never concurrently.
    // The five generators are `let` bindings to types the compiler already infers as
    // `Sendable` (each is a `final class` with no non-Sendable stored state), so — unlike
    // the `var`s below, which are mutated from `render` and still need it — they don't need
    // `nonisolated(unsafe)`.
    private let sineGenerator = SineGenerator()
    private let pinkGenerator = PinkNoiseGenerator()
    private let whiteGenerator = WhiteNoiseGenerator()
    private let sweepGenerator = SweepGenerator()
    private let squareGenerator = SquareGenerator()
    nonisolated(unsafe) private var rampGain: Double = 0
    // Only adopted from `RenderParameters.generatorKind` once `rampGain` reaches silence —
    // otherwise a signal-type switch mid-ramp would audibly fade out the *new* generator
    // instead of the old one, since the switch and the stop-triggering `running = false`
    // land in the same parameter update.
    nonisolated(unsafe) private var activeGeneratorKind: GeneratorKind = .sine

    // Reused across `render` calls (only reallocated when `channelCount` itself changes,
    // e.g. a device switch) so hoisting the per-channel lookups out of the frame loop
    // doesn't introduce a per-callback heap allocation on the real-time render thread.
    nonisolated(unsafe) private var channelBufferScratch: [UnsafeMutableBufferPointer<Float>] = []
    nonisolated(unsafe) private var channelMutedScratch: [Bool] = []
    nonisolated(unsafe) private var channelPhaseReversedScratch: [Bool] = []

    var parameters: RenderParameters {
        parametersLock.withLock { $0 }
    }

    func updateParameters(_ mutate: (inout RenderParameters) -> Void) {
        parametersLock.withLock { mutate(&$0) }
    }

    /// Real-time-safe: call only from the audio render thread. `channelBuffer` must return
    /// a buffer of at least `frameCount` samples for the given channel index.
    func render(
        frameCount: Int, channelCount: Int, sampleRate: Double,
        channelBuffer: (Int) -> UnsafeMutableBufferPointer<Float>
    ) {
        let currentParameters = parametersLock.withLock { $0 }
        let levelLinear = Self.linearGain(fromDbfs: currentParameters.levelDbfs)
        let rampStep = 1.0 / (Self.rampDurationSeconds * sampleRate)

        // Precomputed once per channel per callback, not once per frame per channel — see
        // #11. `channelBuffer` is only contractually required to return a buffer of at
        // least `frameCount` samples for the channel, not to be called once per frame.
        // Written into the reused scratch arrays in place (no per-callback allocation).
        if channelBufferScratch.count != channelCount {
            channelBufferScratch = Array(repeating: UnsafeMutableBufferPointer<Float>(start: nil, count: 0), count: channelCount)
            channelMutedScratch = Array(repeating: false, count: channelCount)
            channelPhaseReversedScratch = Array(repeating: false, count: channelCount)
        }
        for channel in 0..<channelCount {
            channelBufferScratch[channel] = channelBuffer(channel)
            channelMutedScratch[channel] = channel < currentParameters.channelMuted.count
                ? currentParameters.channelMuted[channel] : true
            channelPhaseReversedScratch[channel] = channel < currentParameters.channelPhaseReversed.count
                && currentParameters.channelPhaseReversed[channel]
        }

        for frame in 0..<frameCount {
            let targetGain: Double = currentParameters.running ? 1 : 0
            if rampGain < targetGain {
                rampGain = min(rampGain + rampStep, targetGain)
            } else if rampGain > targetGain {
                rampGain = max(rampGain - rampStep, targetGain)
            }

            if rampGain == 0 {
                activeGeneratorKind = currentParameters.generatorKind
                generator(for: activeGeneratorKind).reset()
            }

            let generator = self.generator(for: activeGeneratorKind)
            let sample = generator.nextSample(parameters: currentParameters, sampleRate: sampleRate)
                * levelLinear * rampGain

            for channel in 0..<channelCount {
                let muted = channelMutedScratch[channel]
                let phaseReversed = channelPhaseReversedScratch[channel]
                channelBufferScratch[channel][frame] = Float(muted ? 0 : (phaseReversed ? -sample : sample))
            }
        }
    }

    private func generator(for kind: GeneratorKind) -> SignalGenerator {
        switch kind {
        case .sine: sineGenerator
        case .pink: pinkGenerator
        case .white: whiteGenerator
        case .sweep: sweepGenerator
        case .square: squareGenerator
        }
    }

    private static func linearGain(fromDbfs dbfs: Double) -> Double {
        pow(10, dbfs / 20)
    }
}
