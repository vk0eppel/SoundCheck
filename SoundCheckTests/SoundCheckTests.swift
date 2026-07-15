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

    @Test func rampsGainInGradually() async throws {
        let core = SignalRenderCore()
        core.updateParameters {
            $0.generatorKind = .white
            $0.levelDbfs = 0
            $0.running = true
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }

        let sampleRate = 48000.0
        let channels = Self.renderToArrays(core, frameCount: 4800, channelCount: 1, sampleRate: sampleRate)
        let samples = channels[0]

        let earlyMagnitude = samples.prefix(10).reduce(Float(0)) { $0 + abs($1) } / 10
        let lateMagnitude = samples.suffix(200).reduce(Float(0)) { $0 + abs($1) } / 200

        #expect(earlyMagnitude < lateMagnitude * 0.5)
        #expect(lateMagnitude > 0.1)
    }

    @Test func perChannelMuteAndPhaseApplyCorrectly() async throws {
        let core = SignalRenderCore()
        core.updateParameters {
            $0.generatorKind = .sine
            $0.frequencyHz = 1000
            $0.levelDbfs = 0
            $0.running = true
            $0.channelMuted = [false, true, false]
            $0.channelPhaseReversed = [false, false, true]
        }

        let sampleRate = 48000.0
        let rampFrames = Int(0.02 * sampleRate)
        let channels = Self.renderToArrays(core, frameCount: rampFrames + 100, channelCount: 3, sampleRate: sampleRate)

        let normal = Array(channels[0].suffix(100))
        let muted = Array(channels[1].suffix(100))
        let reversed = Array(channels[2].suffix(100))

        #expect(muted.allSatisfy { $0 == 0 })
        for (unmutedSample, reversedSample) in zip(normal, reversed) {
            #expect(abs(unmutedSample + reversedSample) < 0.0001)
        }
        #expect(normal.contains { abs($0) > 0.01 })
    }

    @Test func levelControlsAmplitudeInDbfs() async throws {
        let sampleRate = 48000.0
        let frameCount = 4800

        func rms(atLevelDbfs dbfs: Double) -> Float {
            let core = SignalRenderCore()
            core.updateParameters {
                $0.generatorKind = .sine
                $0.frequencyHz = 1000
                $0.levelDbfs = dbfs
                $0.running = true
                $0.channelMuted = [false]
                $0.channelPhaseReversed = [false]
            }
            let channels = Self.renderToArrays(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)
            let settled = channels[0].suffix(frameCount - Int(0.02 * sampleRate))
            let meanSquare = settled.reduce(Float(0)) { $0 + $1 * $1 } / Float(settled.count)
            return meanSquare.squareRoot()
        }

        let fullScaleRMS = rms(atLevelDbfs: 0)
        let minus20RMS = rms(atLevelDbfs: -20)
        let actualRatio = minus20RMS / fullScaleRMS

        #expect(abs(actualRatio - 0.1) < 0.01)
    }

    private static func renderToArrays(
        _ core: SignalRenderCore, frameCount: Int, channelCount: Int, sampleRate: Double
    ) -> [[Float]] {
        let buffers = (0..<channelCount).map { _ in UnsafeMutableBufferPointer<Float>.allocate(capacity: frameCount) }
        defer { buffers.forEach { $0.deallocate() } }
        buffers.forEach { $0.initialize(repeating: 0) }

        core.render(frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate) { channel in
            buffers[channel]
        }

        return buffers.map { Array($0) }
    }

}
