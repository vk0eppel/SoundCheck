//
//  DesignTokens.swift
//  SoundCheck
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.
//
//  Colors are stored as hex strings (not SwiftUI Color) so they can be
//  asserted against exactly in unit tests, and converted to Color at the
//  view layer. Values are shared verbatim with the sibling FreqTrace
//  project so the analyzer (FreqTrace) and generator (SoundCheck) read as
//  one console -- see docs/adr/0005-shared-design-tokens-with-freqtrace.md.
//  Light mode is a deliberately higher-contrast redesign, not an inversion
//  of Dark.
//

import Foundation

// nonisolated: pure value type, matching the app's Swift 6 isolation opt-out convention.
nonisolated enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark = "Dark"
    case light = "Light"

    static let `default`: AppearanceMode = .dark

    var id: String { rawValue }
}

// nonisolated: pure value type.
nonisolated struct ColorTokens {
    let bg: String
    let surface: String
    let surfaceRaised: String
    let border: String
    let borderSoft: String
    let text: String
    let textDim: String
    let textFaint: String
    let accent: String
    let accentDim: String
    let danger: String
    let warn: String
}

// nonisolated: pure value type.
nonisolated enum DesignTokens {
    static let dark = ColorTokens(
        bg: "#0b0d10",
        surface: "#14171b",
        surfaceRaised: "#1b1f24",
        border: "#262b31",
        borderSoft: "#1e2227",
        text: "#e8ecef",
        textDim: "#8b939c",
        textFaint: "#7a8189",
        accent: "#ffb84d",
        accentDim: "#8a6a3a",
        danger: "#ff5a5a",
        warn: "#ffcf5c"
    )

    static let light = ColorTokens(
        bg: "#f4f5f6",
        surface: "#ffffff",
        surfaceRaised: "#f7f8f9",
        border: "#d7dbdf",
        borderSoft: "#e3e6e9",
        text: "#14171b",
        textDim: "#565d66",
        textFaint: "#5c6167",
        accent: "#8f4d00",
        accentDim: "#e0b378",
        danger: "#c62f2f",
        warn: "#6e4e00"
    )

    static func tokens(for mode: AppearanceMode) -> ColorTokens {
        switch mode {
        case .dark: dark
        case .light: light
        }
    }
}
