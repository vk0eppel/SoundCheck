//
//  SoundCheckTests.swift
//  SoundCheckTests
//
//  Created by Victor Koeppel on 15/07/2026.
//

import Foundation
import Testing
@testable import SoundCheck

struct SoundCheckTests {

#if os(macOS)
    @Test func discoversAtLeastOneOutputDevice() async throws {
        let devices = AudioDeviceCatalog.fetchOutputDevices()
        #expect(!devices.isEmpty)
        #expect(devices.allSatisfy { !$0.uid.isEmpty && $0.outputChannelCount > 0 })
    }
#endif

    @MainActor
    @Test func settingsSurviveARelaunch() async throws {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = SettingsStore(defaults: defaults)
        firstLaunch.update {
            $0.signalType = .pink
            $0.frequencyHz = 630
            $0.levelDbfs = -12.5
            $0.selectedDeviceUID = "device-uid-1"
            $0.channelStatesByDeviceUID["device-uid-1"] = [
                PersistedChannelState(muted: false, phaseReversed: true),
                PersistedChannelState(muted: true, phaseReversed: false),
            ]
        }

        let secondLaunch = SettingsStore(defaults: defaults)
        #expect(secondLaunch.snapshot == firstLaunch.snapshot)
        #expect(secondLaunch.snapshot.signalType == .pink)
        #expect(secondLaunch.snapshot.selectedDeviceUID == "device-uid-1")
    }

    @MainActor
    @Test func unknownDeviceChannelsDefaultToMuted() async throws {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        let states = store.channelStates(forDeviceUID: "never-seen-before", channelCount: 4)

        #expect(states.count == 4)
        #expect(states.allSatisfy { $0 == .defaultState })
    }

}
