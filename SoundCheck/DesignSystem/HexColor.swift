//
//  HexColor.swift
//  SoundCheck
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.
//
//  Shared hex-string -> RGB parsing, kept as a plain value type with no
//  SwiftUI dependency. Ported verbatim from the sibling FreqTrace project so
//  the two companion apps share one design-token vocabulary (see
//  docs/adr/0005-shared-design-tokens-with-freqtrace.md).
//

import Foundation

// nonisolated: pure value type, matching the app's Swift 6 isolation opt-out convention.
nonisolated enum HexColor {
    /// Parses a "#rrggbb" or "rrggbb" string into normalized [0,1] RGB
    /// components. A malformed token is a build-time bug, not a runtime
    /// condition to degrade gracefully from -- fails loudly.
    static func rgb(_ hex: String) -> SIMD3<Float> {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.removeAll { $0 == "#" }
        var value: UInt64 = 0
        precondition(
            sanitized.count == 6 && Scanner(string: sanitized).scanHexInt64(&value),
            "Invalid hex color: \"\(hex)\""
        )
        let r = Float((value >> 16) & 0xFF) / 255
        let g = Float((value >> 8) & 0xFF) / 255
        let b = Float(value & 0xFF) / 255
        return SIMD3(r, g, b)
    }
}
