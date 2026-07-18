//
//  Theme.swift
//  SoundCheck
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.
//
//  Converts DesignTokens (hex strings, unit-testable) into SwiftUI Colors,
//  and exposes them via the environment so every view reads from one place.
//  Ported from the sibling FreqTrace project (see
//  docs/adr/0005-shared-design-tokens-with-freqtrace.md).
//

import SwiftUI

extension Color {
    init(hex: String) {
        let rgb = HexColor.rgb(hex)
        self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}

struct Theme {
    let mode: AppearanceMode

    // Stored, not computed: a Theme is only constructed on an appearance-mode
    // change, so parsing each hex string once here keeps it off the hot body
    // path (every view reads these on every body evaluation).
    let bg: Color
    let surface: Color
    let surfaceRaised: Color
    let border: Color
    let borderSoft: Color
    let text: Color
    let textDim: Color
    let textFaint: Color
    let accent: Color
    let accentDim: Color
    let danger: Color
    let warn: Color

    init(mode: AppearanceMode) {
        self.mode = mode
        let tokens = DesignTokens.tokens(for: mode)
        self.bg = Color(hex: tokens.bg)
        self.surface = Color(hex: tokens.surface)
        self.surfaceRaised = Color(hex: tokens.surfaceRaised)
        self.border = Color(hex: tokens.border)
        self.borderSoft = Color(hex: tokens.borderSoft)
        self.text = Color(hex: tokens.text)
        self.textDim = Color(hex: tokens.textDim)
        self.textFaint = Color(hex: tokens.textFaint)
        self.accent = Color(hex: tokens.accent)
        self.accentDim = Color(hex: tokens.accentDim)
        self.danger = Color(hex: tokens.danger)
        self.warn = Color(hex: tokens.warn)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(mode: .default)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
