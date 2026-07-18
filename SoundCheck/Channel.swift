//
//  Channel.swift
//  SoundCheck
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import Foundation

/// One output Channel's mute/phase-reverse state (see `CONTEXT.md`'s "Channel" glossary
/// entry) — the one shape both `ContentView`'s live UI state and `SettingsStore`'s
/// persistence use. `RenderParameters.channelMuted`/`channelPhaseReversed` stay as two
/// parallel `Bool` arrays instead of `[Channel]`: that shape is a deliberate real-time-safety
/// adapter (no per-callback allocation on the audio render thread, per ADR 0002), not
/// accidental duplication of this type.
struct Channel: Codable, Equatable {
    var muted = true
    var phaseReversed = false

    /// Every channel defaults to muted, per ADR 0001.
    static let defaultState = Channel(muted: true, phaseReversed: false)
}
