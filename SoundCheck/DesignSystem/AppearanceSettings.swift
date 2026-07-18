//
//  AppearanceSettings.swift
//  SoundCheck
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.
//
//  Owns the manual Appearance Mode toggle: a plain @Observable holder,
//  separate from the audio/settings types since this is UI-chrome state,
//  not audio or persisted-parameter state. `ContentView` derives the
//  injected Theme from this; the footer's Appearance picker writes to it.
//
//  Persisted across launches: a visible toggle that silently forgets itself
//  on relaunch reads as broken. Mirrors FreqTrace's own AppearanceSettings
//  (docs/adr/0005-shared-design-tokens-with-freqtrace.md).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppearanceSettings {
    private static let defaultsKey = "SoundCheck.appearanceMode"

    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        mode = UserDefaults.standard.string(forKey: Self.defaultsKey)
            .flatMap { AppearanceMode(rawValue: $0) } ?? .default
    }
}
