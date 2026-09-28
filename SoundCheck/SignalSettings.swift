//
//  SignalSettings.swift
//  SoundCheck
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import Foundation
import Observation

/// Owns the "apply everywhere" responsibility for every parameter that must land in both
/// the live render core and persisted settings — see issue #31. Each stored property's
/// `didSet` pushes into `renderCore.updateParameters` and (where the value is persisted)
/// `settingsStore.update`, so a call site only ever assigns one property instead of
/// hand-writing both destinations. `ContentView` binds to these via `@Bindable`.
///
/// Explicitly out of scope, per the same issue: `selectedDeviceUID`, `selectDeviceIfNeeded()`,
/// `handleDeviceListChanged()` stay on `ContentView` — they're hardware-bound (real
/// `AVAudioEngine`/Core Audio device rebuild) and can't be meaningfully unit-tested regardless
/// of where the code lives.
@MainActor
@Observable
final class SignalSettings {
    private let renderCore: SignalRenderCore
    private let settingsStore: SettingsStore

    // Tracked via `deviceDidChange(to:)` rather than owned outright — `channels`' didSet
    // needs to know which device UID to persist under, but device selection itself is out
    // of scope (see the type's doc comment).
    private var currentDeviceUID: String?

    var signalType: GeneratorKind {
        didSet {
            guard signalType != oldValue else { return }
            // ADR 0003: signal-type switch forces a full stop, not a crossfade.
            isRunning = false
            renderCore.updateParameters {
                $0.generatorKind = signalType
                $0.running = false
            }
            settingsStore.update { $0.signalType = signalType }
        }
    }

    var isRunning: Bool {
        didSet {
            guard isRunning != oldValue else { return }
            renderCore.updateParameters { $0.running = isRunning }
        }
    }

    var frequencyHz: Double {
        didSet {
            guard frequencyHz != oldValue else { return }
            renderCore.updateParameters { $0.frequencyHz = frequencyHz }
            settingsStore.update { $0.frequencyHz = frequencyHz }
        }
    }

    var levelDbfs: Double {
        didSet {
            guard levelDbfs != oldValue else { return }
            renderCore.updateParameters { $0.levelDbfs = levelDbfs }
            settingsStore.update { $0.levelDbfs = levelDbfs }
        }
    }

    var pinkNoiseMode: NoiseMode {
        didSet {
            guard pinkNoiseMode != oldValue else { return }
            renderCore.updateParameters { $0.pinkNoiseMode = pinkNoiseMode }
            settingsStore.update { $0.pinkNoiseMode = pinkNoiseMode }
        }
    }

    // Not in issue #31's original property list (written before White gained its own noise
    // modes) but symmetrical with `pinkNoiseMode` now that it has — see docs/spec.md's "Addendum:
    // White noise modes".
    var whiteNoiseMode: NoiseMode {
        didSet {
            guard whiteNoiseMode != oldValue else { return }
            renderCore.updateParameters { $0.whiteNoiseMode = whiteNoiseMode }
            settingsStore.update { $0.whiteNoiseMode = whiteNoiseMode }
        }
    }

    var sweepDurationSeconds: Double {
        didSet {
            guard sweepDurationSeconds != oldValue else { return }
            renderCore.updateParameters { $0.sweepDurationSeconds = sweepDurationSeconds }
            settingsStore.update { $0.sweepDurationSeconds = sweepDurationSeconds }
        }
    }

    var clickIntervalSeconds: Double {
        didSet {
            guard clickIntervalSeconds != oldValue else { return }
            renderCore.updateParameters { $0.clickIntervalSeconds = clickIntervalSeconds }
            settingsStore.update { $0.clickIntervalSeconds = clickIntervalSeconds }
        }
    }

    var channels: [Channel] {
        didSet {
            guard channels != oldValue else { return }
            renderCore.updateParameters {
                $0.channelMuted = channels.map(\.muted)
                $0.channelPhaseReversed = channels.map(\.phaseReversed)
            }
            if let currentDeviceUID {
                settingsStore.update { $0.channelStatesByDeviceUID[currentDeviceUID] = channels }
            }
        }
    }

    /// Seeds every owned property from `settingsStore.snapshot` and immediately pushes that
    /// same snapshot into `renderCore` — replacing `ContentView.onAppear`'s manual field-by-field
    /// unpack. `renderCore`/`settingsStore` are injected, not created, matching
    /// `AudioEngineController`/`SettingsStore`'s existing pattern.
    init(renderCore: SignalRenderCore, settingsStore: SettingsStore) {
        self.renderCore = renderCore
        self.settingsStore = settingsStore

        let snapshot = settingsStore.snapshot
        signalType = snapshot.signalType
        isRunning = false
        frequencyHz = snapshot.frequencyHz
        levelDbfs = snapshot.levelDbfs
        pinkNoiseMode = snapshot.pinkNoiseMode
        whiteNoiseMode = snapshot.whiteNoiseMode
        sweepDurationSeconds = snapshot.sweepDurationSeconds
        clickIntervalSeconds = snapshot.clickIntervalSeconds
        channels = []

        renderCore.updateParameters {
            $0.generatorKind = snapshot.signalType
            $0.frequencyHz = snapshot.frequencyHz
            $0.levelDbfs = snapshot.levelDbfs
            $0.pinkNoiseMode = snapshot.pinkNoiseMode
            $0.whiteNoiseMode = snapshot.whiteNoiseMode
            $0.sweepDurationSeconds = snapshot.sweepDurationSeconds
            $0.clickIntervalSeconds = snapshot.clickIntervalSeconds
        }
    }

    /// `ContentView` calls this whenever `selectedDeviceUID` changes, so `channels`' didSet
    /// persists under the right device UID without `SignalSettings` owning device selection
    /// itself.
    func deviceDidChange(to uid: String?) {
        currentDeviceUID = uid
    }
}
