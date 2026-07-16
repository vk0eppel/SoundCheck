//
//  Biquad.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 16/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import Foundation

/// Second-order IIR filter (RBJ Audio-EQ-Cookbook coefficients, Direct Form II), shared by
/// the band-limited noise cascade (#22) and the 1/3-octave noise bandpass (#23). Coefficient
/// computation happens once in `init`, never in `process`, which is the only part that runs
/// per sample in the real-time render path.
/// See docs/research/band-limited-noise-generation.md and docs/research/one-third-octave-noise-generation.md.
struct Biquad {
    enum FilterType {
        case lowpass
        case highpass
        case bandpass
    }

    private let b0: Double
    private let b1: Double
    private let b2: Double
    private let a1: Double
    private let a2: Double

    // Direct Form II state: one delay line, not separate input/output histories.
    private var w1: Double = 0
    private var w2: Double = 0

    init(type: FilterType, f0: Double, q: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2 * q)

        let rawB0: Double
        let rawB1: Double
        let rawB2: Double
        switch type {
        case .lowpass:
            rawB0 = (1 - cosw0) / 2
            rawB1 = 1 - cosw0
            rawB2 = (1 - cosw0) / 2
        case .highpass:
            rawB0 = (1 + cosw0) / 2
            rawB1 = -(1 + cosw0)
            rawB2 = (1 + cosw0) / 2
        case .bandpass:
            // Constant 0dB peak gain variant.
            rawB0 = alpha
            rawB1 = 0
            rawB2 = -alpha
        }

        let a0 = 1 + alpha
        b0 = rawB0 / a0
        b1 = rawB1 / a0
        b2 = rawB2 / a0
        a1 = (-2 * cosw0) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let w0 = x - a1 * w1 - a2 * w2
        let y = b0 * w0 + b1 * w1 + b2 * w2
        w2 = w1
        w1 = w0
        return y
    }
}
