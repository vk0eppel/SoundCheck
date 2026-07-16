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

/// xorshift64* — fast, non-cryptographic, real-time-safe. Not SystemRandomNumberGenerator,
/// which draws from OS entropy per call and isn't real-time-safe. See docs/research/pink-white-noise-generation.md.
final class WhiteNoiseGenerator: SignalGenerator {
    private var state: UInt64

    init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
        state = seed
    }

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        let unitInterval = Double(state >> 11) * (1.0 / Double(1 << 53))
        return unitInterval * 2 - 1
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
    private var currentMode: PinkNoiseMode = .fullRange
    private var bandLimitedFilter: BandLimitedFilterChain?
    private var thirdOctaveFilter: ThirdOctaveFilterChain?

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        white = WhiteNoiseGenerator(seed: seed)
    }

    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        if parameters.pinkNoiseMode != currentMode {
            currentMode = parameters.pinkNoiseMode
            switch currentMode {
            case .fullRange:
                bandLimitedFilter = nil
                thirdOctaveFilter = nil
            case .bandLimited(let preset):
                bandLimitedFilter = BandLimitedFilterChain(preset: preset, sampleRate: sampleRate)
                thirdOctaveFilter = nil
            case .thirdOctave(let bandIndex):
                let centerHz = ThirdOctaveBands.centerFrequenciesHz[bandIndex]
                thirdOctaveFilter = ThirdOctaveFilterChain(centerHz: centerHz, sampleRate: sampleRate)
                bandLimitedFilter = nil
            }
        }

        let whiteSample = white.nextSample(parameters: parameters, sampleRate: sampleRate)
        b0 = 0.99886 * b0 + whiteSample * 0.0555179
        b1 = 0.99332 * b1 + whiteSample * 0.0750759
        b2 = 0.96900 * b2 + whiteSample * 0.1538520
        b3 = 0.86650 * b3 + whiteSample * 0.3104856
        b4 = 0.55000 * b4 + whiteSample * 0.5329522
        b5 = -0.7616 * b5 - whiteSample * 0.0168980
        let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + whiteSample * 0.5362) * 0.11 * pinkLevelCompensationGain
        b6 = whiteSample * 0.115926

        switch currentMode {
        case .fullRange:
            return pink
        case .bandLimited:
            return bandLimitedFilter?.process(pink) ?? pink
        case .thirdOctave:
            return (thirdOctaveFilter?.process(pink) ?? pink) * thirdOctaveLevelCompensationGain
        }
    }
}

// MARK: - Parameters

enum GeneratorKind: Equatable, Sendable {
    case sine
    case pink
    case white
}

/// A sub-mode of the Pink generator, not a `GeneratorKind` of its own — band-limited and
/// 1/3-octave noise are both still "Pink," just spectrally shaped.
enum PinkNoiseMode: Equatable, Sendable, Codable {
    case fullRange
    case bandLimited(BandLimitedPreset)
    case thirdOctave(bandIndex: Int)
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

/// Cascades `Biquad` sections realizing a `BandLimitedPreset`'s optional highpass and/or
/// lowpass edge, each edge a 4th-order (2-section) Butterworth cascade — the standard
/// per-section Q values from docs/research/band-limited-noise-generation.md. Also applies
/// `levelCompensationGain` so a narrowed band's RMS matches full-range pink noise's RMS at
/// the same `levelDbfs` — see the comment on `fullRangeOctaveSpan` below for why.
struct BandLimitedFilterChain {
    private static let butterworth4thOrderQs: [Double] = [0.54120, 1.30656]

    private var sections: [Biquad] = []
    private let levelCompensationGain: Double

    init(preset: BandLimitedPreset, sampleRate: Double) {
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
        let octaveSpan = log2(highHz / lowHz)
        levelCompensationGain = octaveSpan > 0 ? (fullRangeOctaveSpan / octaveSpan).squareRoot() : 1
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

struct RenderParameters: Equatable, Sendable {
    var generatorKind: GeneratorKind = .sine
    var frequencyHz: Double = 1000
    var levelDbfs: Double = -20
    var running: Bool = false
    var channelMuted: [Bool] = []
    var channelPhaseReversed: [Bool] = []
    var pinkNoiseMode: PinkNoiseMode = .fullRange
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
    nonisolated(unsafe) private let sineGenerator = SineGenerator()
    nonisolated(unsafe) private let pinkGenerator = PinkNoiseGenerator()
    nonisolated(unsafe) private let whiteGenerator = WhiteNoiseGenerator()
    nonisolated(unsafe) private var rampGain: Double = 0
    // Only adopted from `RenderParameters.generatorKind` once `rampGain` reaches silence —
    // otherwise a signal-type switch mid-ramp would audibly fade out the *new* generator
    // instead of the old one, since the switch and the stop-triggering `running = false`
    // land in the same parameter update.
    nonisolated(unsafe) private var activeGeneratorKind: GeneratorKind = .sine

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
                let muted = channel < currentParameters.channelMuted.count ? currentParameters.channelMuted[channel] : true
                let phaseReversed = channel < currentParameters.channelPhaseReversed.count
                    && currentParameters.channelPhaseReversed[channel]
                channelBuffer(channel)[frame] = Float(muted ? 0 : (phaseReversed ? -sample : sample))
            }
        }
    }

    private func generator(for kind: GeneratorKind) -> SignalGenerator {
        switch kind {
        case .sine: sineGenerator
        case .pink: pinkGenerator
        case .white: whiteGenerator
        }
    }

    private static func linearGain(fromDbfs dbfs: Double) -> Double {
        pow(10, dbfs / 20)
    }
}
