//
//  SoundCheckTests.swift
//  SoundCheckTests
//
//  Created by Victor Koeppel on 15/07/2026.
//

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

}
