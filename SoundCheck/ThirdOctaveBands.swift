//
//  ThirdOctaveBands.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 15/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import Foundation

/// The 31 ISO 266 preferred 1/3-octave center frequencies, 20Hz-20kHz.
/// Shared by the frequency field's prev/next stepping and (V2) the 1/3-octave band selector.
enum ThirdOctaveBands {
    static let centerFrequenciesHz: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
        200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
        2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000,
        20000,
    ]

    /// Steps to the previous or next band relative to `frequencyHz`, by index rather than by
    /// re-testing the threshold, so repeated calls at an exact band value still move.
    static func step(from frequencyHz: Double, direction: Int) -> Double {
        let nearestIndex = centerFrequenciesHz.indices.min {
            abs(centerFrequenciesHz[$0] - frequencyHz) < abs(centerFrequenciesHz[$1] - frequencyHz)
        } ?? 0
        let newIndex = min(max(nearestIndex + direction, 0), centerFrequenciesHz.count - 1)
        return centerFrequenciesHz[newIndex]
    }
}
