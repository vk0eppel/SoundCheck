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

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        white = WhiteNoiseGenerator(seed: seed)
    }

    /// #22/#23 will filter here based on `parameters.pinkNoiseMode` (a band-limited
    /// Biquad cascade / a 1/3-octave Biquad bandpass, respectively). Neither mode applies
    /// any filtering yet, so pink noise stays bit-identical to V1 regardless of the
    /// selected mode.
    func nextSample(parameters: RenderParameters, sampleRate: Double) -> Double {
        let whiteSample = white.nextSample(parameters: parameters, sampleRate: sampleRate)
        b0 = 0.99886 * b0 + whiteSample * 0.0555179
        b1 = 0.99332 * b1 + whiteSample * 0.0750759
        b2 = 0.96900 * b2 + whiteSample * 0.1538520
        b3 = 0.86650 * b3 + whiteSample * 0.3104856
        b4 = 0.55000 * b4 + whiteSample * 0.5329522
        b5 = -0.7616 * b5 - whiteSample * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + whiteSample * 0.5362
        b6 = whiteSample * 0.115926
        return pink * 0.11
    }
}

// MARK: - Parameters

enum GeneratorKind: Equatable, Sendable {
    case sine
    case pink
    case white
}

/// A sub-mode of the Pink generator, not a `GeneratorKind` of its own — band-limited and
/// 1/3-octave noise are both still "Pink," just spectrally shaped. `.bandLimited` and
/// `.thirdOctave` carry no configuration yet; #22 and #23 respectively will add it
/// (e.g. `case bandLimited(BandLimitedPreset)`) once they give each mode real filtering.
enum PinkNoiseMode: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
    case fullRange = "FULL-RANGE"
    case bandLimited = "BAND-LIMITED"
    case thirdOctave = "1/3-OCTAVE"

    var id: String { rawValue }
}

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
