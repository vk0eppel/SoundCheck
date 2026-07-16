//
//  SettingsStore.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 16/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import Foundation
import Observation

struct PersistedChannelState: Codable, Equatable {
    var muted: Bool
    var phaseReversed: Bool

    /// Every channel defaults to muted, per ADR 0001.
    static let defaultState = PersistedChannelState(muted: true, phaseReversed: false)
}

struct SettingsSnapshot: Codable, Equatable {
    var signalType: SignalType = .sine
    var frequencyHz: Double = 1000
    var levelDbfs: Double = -20
    var selectedDeviceUID: String?
    var channelStatesByDeviceUID: [String: [PersistedChannelState]] = [:]
    var pinkNoiseMode: PinkNoiseMode = .fullRange
    var sweepDurationSeconds: Double = 10
}

/// Persists SoundCheck's last-used settings across launches, per docs/v1-spec.md's
/// "Persistence" section. Device selection and per-channel mute/phase are keyed by
/// device UID (not index or name), so they survive the device list reordering.
@MainActor
@Observable
final class SettingsStore {
    private(set) var snapshot: SettingsSnapshot

    private let defaults: UserDefaults
    private let storageKey = "com.soundcheck.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(SettingsSnapshot.self, from: data)
        {
            self.snapshot = decoded
        } else {
            self.snapshot = SettingsSnapshot()
        }
    }

    func update(_ mutate: (inout SettingsSnapshot) -> Void) {
        mutate(&snapshot)
        save()
    }

    /// Channel states for the given device, muted-by-default (ADR 0001) if none are saved
    /// yet or the saved count doesn't match the device's current channel count.
    func channelStates(forDeviceUID uid: String, channelCount: Int) -> [PersistedChannelState] {
        if let saved = snapshot.channelStatesByDeviceUID[uid], saved.count == channelCount {
            return saved
        }
        return Array(repeating: .defaultState, count: channelCount)
    }

    /// Channel states to apply on a device switch: preserves saved phase-reverse state, but
    /// always forces mute on — ADR 0001 requires every channel muted "on every device switch,"
    /// not just for previously-unseen devices, so a previously-unmuted channel must not come
    /// back unmuted just because its device was seen before.
    func channelStatesForDeviceSwitch(forDeviceUID uid: String, channelCount: Int) -> [PersistedChannelState] {
        channelStates(forDeviceUID: uid, channelCount: channelCount).map {
            PersistedChannelState(muted: true, phaseReversed: $0.phaseReversed)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
