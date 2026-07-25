//
//  SoundCheckTests.swift
//  SoundCheckTests
//
//  Created by Victor Koeppel on 15/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import CoreAudio
import Foundation
import Testing
@testable import SoundCheck

/// Shared by `steadyStateGain` so it can probe either a single `Biquad` or a
/// `BandLimitedFilterChain` with the same test helper.
private protocol SampleFilter {
    mutating func process(_ x: Double) -> Double
}
extension Biquad: SampleFilter {}
extension BandLimitedFilterChain: SampleFilter {}
extension ThirdOctaveFilterChain: SampleFilter {}

struct SoundCheckTests {

#if os(macOS)
    @Test func discoversAtLeastOneOutputDevice() async throws {
        let devices = AudioDeviceCatalog.fetchOutputDevices()
        #expect(!devices.isEmpty)
        #expect(devices.allSatisfy { !$0.uid.isEmpty && $0.outputChannelCount > 0 })
    }

    @Test func floatBufferConvertsAudioBufferListEntryToATypedWritableBuffer() async throws {
        let frameCount = 4
        var samples = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeMutableBufferPointer { samplesPointer in
            var audioBuffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(samplesPointer.baseAddress)
            )
            withUnsafeMutablePointer(to: &audioBuffer) { audioBufferPointer in
                var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBufferPointer.pointee)
                withUnsafeMutablePointer(to: &bufferList) { listPointer in
                    let buffers = UnsafeMutableAudioBufferListPointer(listPointer)
                    let result = AudioEngineController.floatBuffer(forChannel: 0, in: buffers, frameCount: frameCount)
                    #expect(result.count == frameCount)
                    result[2] = 42
                }
            }
        }
        #expect(samples[2] == 42)
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
            $0.pinkNoiseMode = .bandLimited(.preset200HzTo1kHz)
            $0.channelStatesByDeviceUID["device-uid-1"] = [
                Channel(muted: false, phaseReversed: true),
                Channel(muted: true, phaseReversed: false),
            ]
        }

        let secondLaunch = SettingsStore(defaults: defaults)
        #expect(secondLaunch.snapshot == firstLaunch.snapshot)
        #expect(secondLaunch.snapshot.signalType == .pink)
        #expect(secondLaunch.snapshot.selectedDeviceUID == "device-uid-1")
        #expect(secondLaunch.snapshot.pinkNoiseMode == .bandLimited(.preset200HzTo1kHz))
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

    @MainActor
    @Test func switchingToAPreviouslyUsedDeviceStillMutesAllChannels() async throws {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.channelStatesByDeviceUID["device-uid-1"] = [
                Channel(muted: false, phaseReversed: true),
                Channel(muted: false, phaseReversed: false),
            ]
        }

        // ADR 0001: every channel is forced muted on every device switch, even switching
        // back to a device whose saved state had a channel left unmuted -- only
        // phase-reverse is restored from what was saved.
        let states = store.channelStatesForDeviceSwitch(forDeviceUID: "device-uid-1", channelCount: 2)

        #expect(states.allSatisfy { $0.muted })
        #expect(states.map(\.phaseReversed) == [true, false])
    }

    @MainActor
    private func makeSignalSettings() throws -> (
        settings: SignalSettings, renderCore: SignalRenderCore, store: SettingsStore, suiteName: String
    ) {
        let suiteName = "SignalSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = SettingsStore(defaults: defaults)
        let renderCore = SignalRenderCore()
        let settings = SignalSettings(renderCore: renderCore, settingsStore: store)
        return (settings, renderCore, store, suiteName)
    }

    @MainActor
    @Test func signalSettingsSeedsRenderCoreFromExistingSnapshotOnInit() async throws {
        let suiteName = "SignalSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.update {
            $0.signalType = .pink
            $0.frequencyHz = 630
            $0.levelDbfs = -12.5
            $0.pinkNoiseMode = .bandLimited(.preset200HzTo1kHz)
            $0.sweepDurationSeconds = 5
        }

        let renderCore = SignalRenderCore()
        let settings = SignalSettings(renderCore: renderCore, settingsStore: store)

        #expect(settings.signalType == .pink)
        #expect(settings.frequencyHz == 630)
        #expect(settings.levelDbfs == -12.5)
        #expect(settings.pinkNoiseMode == .bandLimited(.preset200HzTo1kHz))
        #expect(settings.sweepDurationSeconds == 5)
        #expect(renderCore.parameters.generatorKind == .pink)
        #expect(renderCore.parameters.frequencyHz == 630)
        #expect(renderCore.parameters.levelDbfs == -12.5)
        #expect(renderCore.parameters.pinkNoiseMode == .bandLimited(.preset200HzTo1kHz))
        #expect(renderCore.parameters.sweepDurationSeconds == 5)
    }

    @MainActor
    @Test func signalSettingsFrequencyLevelAndDurationLandInBothStores() async throws {
        let (settings, renderCore, store, suiteName) = try makeSignalSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        settings.frequencyHz = 250
        settings.levelDbfs = -6
        settings.sweepDurationSeconds = 20

        #expect(renderCore.parameters.frequencyHz == 250)
        #expect(store.snapshot.frequencyHz == 250)
        #expect(renderCore.parameters.levelDbfs == -6)
        #expect(store.snapshot.levelDbfs == -6)
        #expect(renderCore.parameters.sweepDurationSeconds == 20)
        #expect(store.snapshot.sweepDurationSeconds == 20)
    }

    @MainActor
    @Test func signalSettingsNoiseModesLandInBothStores() async throws {
        let (settings, renderCore, store, suiteName) = try makeSignalSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        settings.pinkNoiseMode = .thirdOctave(bandIndex: 10)
        settings.whiteNoiseMode = .bandLimited(.preset1kTo20kHz)

        #expect(renderCore.parameters.pinkNoiseMode == .thirdOctave(bandIndex: 10))
        #expect(store.snapshot.pinkNoiseMode == .thirdOctave(bandIndex: 10))
        #expect(renderCore.parameters.whiteNoiseMode == .bandLimited(.preset1kTo20kHz))
        #expect(store.snapshot.whiteNoiseMode == .bandLimited(.preset1kTo20kHz))
    }

    @MainActor
    @Test func signalSettingsChannelsPersistUnderTheTrackedDeviceUID() async throws {
        let (settings, renderCore, store, suiteName) = try makeSignalSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        settings.deviceDidChange(to: "device-uid-1")
        settings.channels = [Channel(muted: false, phaseReversed: true), Channel(muted: true, phaseReversed: false)]

        #expect(renderCore.parameters.channelMuted == [false, true])
        #expect(renderCore.parameters.channelPhaseReversed == [true, false])
        #expect(
            store.snapshot.channelStatesByDeviceUID["device-uid-1"] == [
                Channel(muted: false, phaseReversed: true),
                Channel(muted: true, phaseReversed: false),
            ])
    }

    @MainActor
    @Test func signalSettingsIsRunningOnlyUpdatesRenderCoreNotPersistedSettings() async throws {
        let (settings, renderCore, store, suiteName) = try makeSignalSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let snapshotBefore = store.snapshot

        settings.isRunning = true

        #expect(renderCore.parameters.running == true)
        #expect(store.snapshot == snapshotBefore)
    }

    @MainActor
    @Test func signalSettingsSignalTypeSwitchForcesStopPerADR0003() async throws {
        let (settings, renderCore, store, suiteName) = try makeSignalSettings()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        settings.isRunning = true

        settings.signalType = .square

        #expect(settings.isRunning == false)
        #expect(renderCore.parameters.running == false)
        #expect(renderCore.parameters.generatorKind == .square)
        #expect(store.snapshot.signalType == .square)
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

    @Test func signalSwitchDoesNotAudiblyStartNewGeneratorWhileRampingDown() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        core.updateParameters {
            $0.generatorKind = .sine
            $0.frequencyHz = 1000
            $0.levelDbfs = 0
            $0.running = true
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }

        // Let the sine ramp fully up to steady state first.
        let rampFrames = Int(0.015 * sampleRate) + 1
        _ = Self.renderToArrays(core, frameCount: rampFrames + 100, channelCount: 1, sampleRate: sampleRate)

        // Simulate a signal-type switch: generatorKind changes and running drops to
        // false in the same parameter update, exactly as ContentView does on a
        // signal-type change (see docs/adr/0003-signal-switch-forces-stop.md).
        core.updateParameters {
            $0.generatorKind = .white
            $0.running = false
        }

        // Render only a few frames into the ~15ms ramp-down. The still-decaying
        // signal should be the *old* generator (sine), not the newly-selected one
        // (white noise) — otherwise you briefly hear the start of the new signal
        // fading out instead of the old one.
        let channels = Self.renderToArrays(core, frameCount: 20, channelCount: 1, sampleRate: sampleRate)
        let samples = channels[0]

        let maxDelta = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(maxDelta < 0.3)
    }

    @Test func signalSwitchedWhileOffIsAdoptedOnTheFirstOn() async throws {
        // Regression (see SignalRenderCore.render's frame-loop adoption): the audio engine
        // is stopped whenever output is OFF, so render() isn't called then — a generator
        // switch made while OFF must be adopted on the *first* ON, not only after a full
        // OFF/ON cycle. Previously the first ON rendered the previously-active generator
        // (.sine on launch) because the frame-loop adoption ran *after* the ramp step had
        // already lifted rampGain off 0, so the `rampGain == 0` check missed the first frame.
        let core = SignalRenderCore()
        let sampleRate = 48000.0

        // Exactly the launch state: a fresh core defaults generatorKind to .sine with
        // rampGain == 0 and activeGeneratorKind == .sine (never rendered). Switch to white
        // noise while still OFF, as selecting White does, without any priming render.
        core.updateParameters {
            $0.generatorKind = .white
            $0.levelDbfs = 0
            $0.running = false
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }

        // First ON, straight through renderToArrays (no renderSteadyState priming).
        core.updateParameters { $0.running = true }
        let rampFrames = Int(0.015 * sampleRate) + 1
        let channels = Self.renderToArrays(core, frameCount: rampFrames + 200, channelCount: 1, sampleRate: sampleRate)
        let steady = Array(channels[0].suffix(200))

        // White noise makes large sample-to-sample jumps; the buggy output (a smooth 1kHz
        // sine) has max |Δ| ≈ 0.14 at full scale. A large max delta confirms the white
        // generator — not the stale sine default — is what plays on the first ON.
        let maxDelta = zip(steady, steady.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(maxDelta > 0.3)
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

    @Test func channelBufferIsLookedUpOncePerChannelNotOncePerFrame() async throws {
        let core = SignalRenderCore()
        core.updateParameters {
            $0.generatorKind = .sine
            $0.frequencyHz = 1000
            $0.levelDbfs = 0
            $0.running = true
            $0.channelMuted = [false, false, false]
            $0.channelPhaseReversed = [false, false, false]
        }

        let sampleRate = 48000.0
        let frameCount = 512
        let channelCount = 3
        let buffers = (0..<channelCount).map { _ in UnsafeMutableBufferPointer<Float>.allocate(capacity: frameCount) }
        defer { buffers.forEach { $0.deallocate() } }
        buffers.forEach { $0.initialize(repeating: 0) }

        var lookupCount = 0
        core.render(frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate) { channel in
            lookupCount += 1
            return buffers[channel]
        }

        #expect(lookupCount == channelCount)
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

    @Test func sweepGeneratorFollowsLogarithmicCurve() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        let duration = 2.0
        core.updateParameters {
            $0.generatorKind = .sweep
            $0.sweepDurationSeconds = duration
            $0.levelDbfs = 0
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }
        // Adopting a newly-selected generatorKind only happens inside `render()`, at the
        // instant it observes `rampGain == 0` — exactly like ContentView's real sequencing
        // (signal type is set while `running` is still false; only a later, separate ON
        // press flips `running`). Render one silent frame first so `.sweep` is actually
        // adopted before flipping `running`, matching that real sequencing.
        _ = Self.renderToArrays(core, frameCount: 1, channelCount: 1, sampleRate: sampleRate)
        core.updateParameters { $0.running = true }

        let totalSamples = Int(duration * sampleRate)
        let channels = Self.renderToArrays(core, frameCount: totalSamples, channelCount: 1, sampleRate: sampleRate)
        let samples = channels[0]

        func expectedHz(atSampleIndex index: Int) -> Double {
            let t = Double(index) / Double(totalSamples)
            return 20 * pow(1000, t)
        }

        // Start, mid, and (just before wrap) end of the configured duration — the
        // instantaneous frequency should approximate `20 * (20000/20)^t` throughout.
        for index in [3000, totalSamples / 2, totalSamples - 200] {
            let expected = expectedHz(atSampleIndex: index)
            let measured = Self.measuredFrequencyHz(centeredAt: index, expectedHz: expected, samples: samples, sampleRate: sampleRate)
            #expect(!measured.isNaN, "no zero crossings found near sample \(index)")
            #expect(abs(measured - expected) / expected < 0.25)
        }
    }

    @Test func sweepWrapsInstantlyBackTo20HzAfterOneFullDuration() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        let duration = 1.0
        core.updateParameters {
            $0.generatorKind = .sweep
            $0.sweepDurationSeconds = duration
            $0.levelDbfs = 0
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }
        // See `sweepGeneratorFollowsLogarithmicCurve` for why this precedes flipping `running`.
        _ = Self.renderToArrays(core, frameCount: 1, channelCount: 1, sampleRate: sampleRate)
        core.updateParameters { $0.running = true }

        let totalSamples = Int(duration * sampleRate)
        let channels = Self.renderToArrays(core, frameCount: totalSamples + 10000, channelCount: 1, sampleRate: sampleRate)
        let samples = channels[0]

        // Just after the wrap point, frequency should have jumped straight back down to
        // ~20Hz, not continued climbing toward/past 20kHz. Measured one-sided (forward
        // only) from the wrap, using the second post-wrap cycle (skipping the first,
        // transitional one spanning the instant frequency jump) so the estimate reflects
        // the fresh-post-wrap frequency rather than blending in pre-wrap high-frequency
        // content the way a centered window would.
        var crossingIndices: [Int] = []
        var i = totalSamples
        while crossingIndices.count < 3 && i < samples.count - 1 {
            if samples[i] <= 0 && samples[i + 1] > 0 {
                crossingIndices.append(i)
            }
            i += 1
        }
        #expect(crossingIndices.count == 3, "expected 3 zero crossings shortly after the wrap")
        let secondCycleSamples = Double(crossingIndices[2] - crossingIndices[1])
        let measured = sampleRate / secondCycleSamples
        #expect(measured < 40)
    }

    @Test func sweepRestartsFrom20HzAfterAFullStopAndRestart() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        core.updateParameters {
            $0.generatorKind = .sweep
            $0.sweepDurationSeconds = 5
            $0.levelDbfs = 0
            $0.running = true
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }

        // Run well into the sweep, away from a duration boundary, so frequency has
        // climbed well past 20Hz before stopping.
        _ = Self.renderToArrays(core, frameCount: Int(2.5 * sampleRate), channelCount: 1, sampleRate: sampleRate)

        // Stop and let the ramp fully silence -- this is the point `reset()` fires
        // (see `SignalRenderCore.render`'s `rampGain == 0` check), zeroing the sweep's
        // elapsed-sample counter.
        core.updateParameters { $0.running = false }
        _ = Self.renderToArrays(core, frameCount: Int(0.05 * sampleRate), channelCount: 1, sampleRate: sampleRate)

        core.updateParameters { $0.running = true }
        let channels = Self.renderToArrays(core, frameCount: 20000, channelCount: 1, sampleRate: sampleRate)
        let samples = channels[0]

        // Shortly after restart, frequency should be back near 20Hz, not resuming from
        // wherever the sweep had reached before the stop.
        let measured = Self.measuredFrequencyHz(centeredAt: 8000, expectedHz: 20, samples: samples, sampleRate: sampleRate)
        #expect(!measured.isNaN)
        #expect(measured < 40)
    }

    @Test func squareWaveHasApproximatelyFiftyPercentDutyCycle() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        core.updateParameters {
            $0.generatorKind = .square
            $0.frequencyHz = 1000
            $0.levelDbfs = 0
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }
        // Adopting a newly-selected generatorKind only happens inside `render()`, at the
        // instant it observes `rampGain == 0` -- see `sweepGeneratorFollowsLogarithmicCurve`
        // for why this silent frame must precede flipping `running`.
        _ = Self.renderToArrays(core, frameCount: 1, channelCount: 1, sampleRate: sampleRate)
        core.updateParameters { $0.running = true }

        let rampFrames = Int(0.02 * sampleRate)
        let channels = Self.renderToArrays(core, frameCount: rampFrames + 48000, channelCount: 1, sampleRate: sampleRate)
        let settled = channels[0].suffix(48000)

        // A fixed 50% duty cycle spends equal time at +1 and -1, so the mean should sit
        // close to zero -- PolyBLEP's edge correction is symmetric (adds near the rising
        // edge, subtracts near the falling edge) so it doesn't skew this.
        let mean = settled.reduce(Float(0), +) / Float(settled.count)
        #expect(abs(mean) < 0.01)
    }

    @Test func squareWaveAmplitudeStaysWithinLevelBounds() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        core.updateParameters {
            $0.generatorKind = .square
            $0.frequencyHz = 1000
            $0.levelDbfs = -6
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }
        // See `sweepGeneratorFollowsLogarithmicCurve` for why this precedes flipping `running`.
        _ = Self.renderToArrays(core, frameCount: 1, channelCount: 1, sampleRate: sampleRate)
        core.updateParameters { $0.running = true }

        let rampFrames = Int(0.02 * sampleRate)
        let channels = Self.renderToArrays(core, frameCount: rampFrames + 4800, channelCount: 1, sampleRate: sampleRate)
        let settled = channels[0].suffix(4800)

        let levelLinear = Float(pow(10, -6.0 / 20))
        #expect(settled.allSatisfy { abs($0) <= levelLinear + 0.001 })
    }

    @Test func polyBLEPSmoothsEdgesComparedToANaiveSquareAtHighFrequency() async throws {
        let core = SignalRenderCore()
        let sampleRate = 48000.0
        let frequency = 16000.0
        core.updateParameters {
            $0.generatorKind = .square
            $0.frequencyHz = frequency
            $0.levelDbfs = 0
            $0.channelMuted = [false]
            $0.channelPhaseReversed = [false]
        }
        // See `sweepGeneratorFollowsLogarithmicCurve` for why this precedes flipping `running`.
        _ = Self.renderToArrays(core, frameCount: 1, channelCount: 1, sampleRate: sampleRate)
        core.updateParameters { $0.running = true }

        let rampFrames = Int(0.02 * sampleRate)
        let channels = Self.renderToArrays(core, frameCount: rampFrames + 4800, channelCount: 1, sampleRate: sampleRate)
        let bandLimited = channels[0].suffix(4800).map(Double.init)

        // A naive sign()-based square at the same frequency, computed inline (not via
        // SquareGenerator) -- the aliased reference PolyBLEP is meant to improve on.
        var naivePhase = 0.0
        let dt = frequency / sampleRate
        var naive: [Double] = []
        for _ in 0..<bandLimited.count {
            naive.append(naivePhase < 0.5 ? 1 : -1)
            naivePhase += dt
            if naivePhase >= 1 { naivePhase -= 1 }
        }

        // "Smoother transitions" measured as total squared second-difference (curvature) --
        // a naive square's instantaneous jumps have far higher curvature at each edge than
        // PolyBLEP's polynomial-corrected ones.
        func roughness(_ samples: [Double]) -> Double {
            var total = 0.0
            for i in 1..<(samples.count - 1) {
                let secondDifference = samples[i + 1] - 2 * samples[i] + samples[i - 1]
                total += secondDifference * secondDifference
            }
            return total
        }

        #expect(roughness(bandLimited) < roughness(naive))
    }

    @Test func bandLimitedFilterChainRealizesEachPresetsEdges() async throws {
        let sampleRate = 48000.0

        func gain(_ preset: BandLimitedPreset, probeHz: Double) -> Double {
            Self.steadyStateGain(
                BandLimitedFilterChain(preset: preset, sampleRate: sampleRate, shape: .pinkOneOverF),
                probeFrequencyHz: probeHz, sampleRate: sampleRate
            )
        }

        // 0-200Hz: lowpass-only -- passes low, attenuates well above the edge.
        #expect(gain(.preset0to200Hz, probeHz: 100) > 0.8)
        #expect(gain(.preset0to200Hz, probeHz: 5000) < 0.1)

        // 200Hz-1kHz: highpass+lowpass -- passes mid, attenuates both outer sides.
        #expect(gain(.preset200HzTo1kHz, probeHz: 500) > 0.8)
        #expect(gain(.preset200HzTo1kHz, probeHz: 50) < 0.1)
        #expect(gain(.preset200HzTo1kHz, probeHz: 10000) < 0.1)

        // 1k-20kHz: highpass-only -- attenuates low, passes high.
        #expect(gain(.preset1kTo20kHz, probeHz: 100) < 0.1)
        #expect(gain(.preset1kTo20kHz, probeHz: 5000) > 0.8)

        // 7k-20kHz: highpass-only, narrower -- attenuates low, passes high.
        #expect(gain(.preset7kTo20kHz, probeHz: 500) < 0.1)
        #expect(gain(.preset7kTo20kHz, probeHz: 15000) > 0.8)

        // Manual range behaves like any other two-edge preset.
        #expect(gain(.manual(lowHz: 2000, highHz: 4000), probeHz: 3000) > 0.8)
        #expect(gain(.manual(lowHz: 2000, highHz: 4000), probeHz: 200) < 0.1)
    }

    @Test func thirdOctaveFilterChainRealizesConfiguredBand() async throws {
        let sampleRate = 48000.0

        // Bands chosen so probe frequencies several octaves either side stay well under
        // this sample rate's Nyquist limit -- a probe above Nyquist would alias back into
        // the passband and give a spurious "not attenuated" result.
        for centerHz in [100.0, 630.0, 2000.0] {
            func gain(_ probeHz: Double) -> Double {
                Self.steadyStateGain(
                    ThirdOctaveFilterChain(centerHz: centerHz, sampleRate: sampleRate, shape: .pinkOneOverF),
                    probeFrequencyHz: probeHz, sampleRate: sampleRate
                )
            }

            // `ThirdOctaveFilterChain.process` now bakes in its `noiseBandMakeupGain` (a single
            // frequency-independent scalar), so gains are measured *relative to* the center's,
            // which isolates the filter's shape from that scalar. Well attenuated (<-26dB, i.e.
            // ratio < 0.05) two octaves either side of center.
            let center = gain(centerHz)
            #expect(center > 0)
            #expect(gain(centerHz / 4) / center < 0.05)
            #expect(gain(centerHz * 4) / center < 0.05)
        }
    }

    /// Kellett's raw pink noise construction has a much higher crest factor than White's
    /// uniform distribution, so without `pinkLevelCompensationGain` its RMS (perceived
    /// loudness) measured far below White's at the same `levelDbfs` -- audibly "not as loud
    /// as the rest." Verifies the makeup gain brings full-range Pink's RMS in line with
    /// White's at a fixed Level.
    @Test func fullRangePinkRMSMatchesWhiteRMSAtTheSameLevel() async throws {
        let sampleRate = 48000.0
        let frameCount = 96000
        let levelDbfs = -12.0

        func rms(generatorKind: GeneratorKind) -> Double {
            let core = SignalRenderCore()
            core.updateParameters {
                $0.generatorKind = generatorKind
                $0.levelDbfs = levelDbfs
                $0.running = true
                $0.pinkNoiseMode = .fullRange
                $0.channelMuted = [false]
                $0.channelPhaseReversed = [false]
            }
            let channels = Self.renderSteadyState(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)
            let settled = channels[0].suffix(frameCount - Int(0.5 * sampleRate))
            let meanSquare = settled.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(settled.count)
            return meanSquare.squareRoot()
        }

        let whiteRMS = rms(generatorKind: .white)
        let pinkRMS = rms(generatorKind: .pink)

        #expect(abs(20 * log10(pinkRMS / whiteRMS)) < 1)
    }

    /// `noiseFullScaleReferenceGain` lifts broadband noise RMS up to a full-scale *sine*'s RMS,
    /// so an AES17 analyzer (0 dBFS == full-scale sine) reads the `Level` setting for noise the
    /// same way it does for Sine -- e.g. Pink/White at -20 read ~-20dBFS, not ~-22. Verifies both
    /// full-range noise generators' RMS lands within a fraction of a dB of a full-scale sine's RMS
    /// at the same Level (here Level 0), which is exactly the AES17 "reads the setting" condition.
    @Test func fullRangeNoiseRMSMatchesFullScaleSineRMS() async throws {
        let sampleRate = 48000.0
        let frameCount = 96000
        let levelDbfs = 0.0

        func rms(generatorKind: GeneratorKind) -> Double {
            let core = SignalRenderCore()
            core.updateParameters {
                $0.generatorKind = generatorKind
                $0.frequencyHz = 1000
                $0.levelDbfs = levelDbfs
                $0.running = true
                $0.pinkNoiseMode = .fullRange
                $0.whiteNoiseMode = .fullRange
                $0.channelMuted = [false]
                $0.channelPhaseReversed = [false]
            }
            let channels = Self.renderSteadyState(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)
            let settled = channels[0].suffix(frameCount - Int(0.5 * sampleRate))
            let meanSquare = settled.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(settled.count)
            return meanSquare.squareRoot()
        }

        let sineRMS = rms(generatorKind: .sine)
        let whiteRMS = rms(generatorKind: .white)
        let pinkRMS = rms(generatorKind: .pink)

        #expect(abs(20 * log10(whiteRMS / sineRMS)) < 0.3)
        #expect(abs(20 * log10(pinkRMS / sineRMS)) < 0.3)
    }

    /// Every band-limited preset and a spread of 1/3-octave bands must read the same Level as
    /// full-range noise (which itself reads a full-scale sine via `noiseFullScaleReferenceGain`),
    /// for *both* noise colors and across sample rates. The makeup gain comes from each realized
    /// filter's effective noise bandwidth (`noiseBandMakeupGain`) — frequency- and
    /// sample-rate-aware — so this asserts ≤1dB at 44.1/48/96kHz, including the 20Hz and 20kHz
    /// edge bands (indices 0 and 30), which the old nominal-width formulas missed by >2dB. A long
    /// averaging window (4s measured after a 2s settle) keeps the narrow low-frequency bands' RMS
    /// estimate stable; the generators are fixed-seeded, so results are reproducible.
    private func assertFilteredModesMatchFullRange(kind: GeneratorKind) {
        let presets: [BandLimitedPreset] = [
            .preset0to200Hz, .preset200HzTo1kHz, .preset1kTo20kHz, .preset7kTo20kHz,
            .manual(lowHz: 2000, highHz: 4000),
        ]
        let bandIndices = [0, 5, 10, 17, 25, 30]   // 20Hz … 20kHz — edge bands included

        for sampleRate in [44100.0, 48000.0, 96000.0] {
            let frameCount = Int(6 * sampleRate)
            func rms(_ mode: NoiseMode) -> Double {
                let core = SignalRenderCore()
                core.updateParameters {
                    $0.generatorKind = kind
                    $0.levelDbfs = -12
                    $0.running = false
                    $0.pinkNoiseMode = mode
                    $0.whiteNoiseMode = mode
                    $0.channelMuted = [false]
                    $0.channelPhaseReversed = [false]
                }
                let channels = Self.renderSteadyState(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)
                let settled = channels[0].suffix(frameCount - Int(2.0 * sampleRate))
                let meanSquare = settled.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(settled.count)
                return meanSquare.squareRoot()
            }

            let fullRangeRMS = rms(.fullRange)
            func dbRatio(_ mode: NoiseMode) -> Double { 20 * log10(rms(mode) / fullRangeRMS) }

            for preset in presets {
                #expect(abs(dbRatio(.bandLimited(preset))) < 1, "\(kind) band-limited \(preset) @ \(sampleRate)Hz")
            }
            for bandIndex in bandIndices {
                #expect(abs(dbRatio(.thirdOctave(bandIndex: bandIndex))) < 1, "\(kind) 1/3-oct band \(bandIndex) @ \(sampleRate)Hz")
            }
        }
    }

    @Test func filteredPinkModesMatchFullRangeRMSAtTheSameLevel() async throws {
        assertFilteredModesMatchFullRange(kind: .pink)
    }

    @Test func filteredWhiteModesMatchFullRangeRMSAtTheSameLevel() async throws {
        assertFilteredModesMatchFullRange(kind: .white)
    }

    /// `PinkNoiseGenerator` holds its own internal `WhiteNoiseGenerator` to drive its Kellett
    /// filter cascade with raw white noise. Regression guard for the bug that split would
    /// otherwise introduce: Pink's output must stay identical regardless of
    /// `RenderParameters.whiteNoiseMode`'s value, since that parameter only means something
    /// while White is the *active* generator.
    @Test func pinkToneIsUnaffectedByWhiteNoiseMode() async throws {
        let sampleRate = 48000.0
        let frameCount = 9600
        let levelDbfs = -12.0

        func pinkSamples(whiteNoiseMode: NoiseMode) -> [Float] {
            let core = SignalRenderCore()
            core.updateParameters {
                $0.generatorKind = .pink
                $0.levelDbfs = levelDbfs
                $0.running = true
                $0.whiteNoiseMode = whiteNoiseMode
                $0.channelMuted = [false]
                $0.channelPhaseReversed = [false]
            }
            return Self.renderSteadyState(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)[0]
        }

        let withFullRangeWhite = pinkSamples(whiteNoiseMode: .fullRange)
        let withBandLimitedWhite = pinkSamples(whiteNoiseMode: .bandLimited(.preset7kTo20kHz))
        let withThirdOctaveWhite = pinkSamples(whiteNoiseMode: .thirdOctave(bandIndex: 5))

        // Both `PinkNoiseGenerator` instances above are freshly constructed with the same
        // fixed seed (see `PinkNoiseGenerator.init`'s default), so their internal white
        // source produces an identical raw sample sequence -- Pink's output should be
        // byte-for-byte identical regardless of `whiteNoiseMode`.
        #expect(withFullRangeWhite == withBandLimitedWhite)
        #expect(withFullRangeWhite == withThirdOctaveWhite)
    }

    @Test func noiseModeDraftRoundTripsEveryMode() async throws {
        let modes: [NoiseMode] = [
            .fullRange,
            .bandLimited(.preset0to200Hz),
            .bandLimited(.preset200HzTo1kHz),
            .bandLimited(.preset1kTo20kHz),
            .bandLimited(.preset7kTo20kHz),
            .bandLimited(.manual(lowHz: 250, highHz: 3500)),
            .thirdOctave(bandIndex: 17),
        ]

        for mode in modes {
            let draft = NoiseModeDraft(resolving: mode)
            #expect(draft.resolved == mode)
        }
    }

    @Test func commitManualLowClampsToTwentyHzFloor() async throws {
        var draft = NoiseModeDraft()
        draft.manualHighHz = 1000
        let committed = draft.commitManualLow(5)
        #expect(committed == 20)
        #expect(draft.manualLowHz == 20)
    }

    @Test func commitManualLowClampsBelowCurrentHigh() async throws {
        var draft = NoiseModeDraft()
        draft.manualHighHz = 500
        let committed = draft.commitManualLow(499)
        #expect(committed == 499)
        #expect(draft.manualLowHz == 499)

        let clamped = draft.commitManualLow(600)
        #expect(clamped == 499) // manualHighHz - 1
        #expect(draft.manualLowHz == 499)
    }

    @Test func commitManualHighClampsToTwentyKHzCeiling() async throws {
        var draft = NoiseModeDraft()
        draft.manualLowHz = 200
        let committed = draft.commitManualHigh(25000)
        #expect(committed == 20000)
        #expect(draft.manualHighHz == 20000)
    }

    @Test func commitManualHighClampsAboveCurrentLow() async throws {
        var draft = NoiseModeDraft()
        draft.manualLowHz = 500
        let clamped = draft.commitManualHigh(100)
        #expect(clamped == 501) // manualLowHz + 1
        #expect(draft.manualHighHz == 501)
    }

    /// Documents the intended (not buggy) commit-on-blur behavior: committing Low clamps
    /// against whatever High was last *committed*, not an uncommitted edit still sitting in
    /// High's own draft `@State` — the two fields only ever exchange state at commit time,
    /// per `NoiseModeDraft`'s own doc comment on why per-keystroke drafts stay outside it.
    @Test func commitManualLowClampsAgainstLastCommittedHighNotAnUncommittedEdit() async throws {
        var draft = NoiseModeDraft()
        draft.manualHighHz = 1000

        // Simulates: the user types a new High (300) but hasn't committed it yet (still in
        // ContentView's manualHighHzDraft @State, never reaches the draft), then commits Low.
        let committedLow = draft.commitManualLow(950)

        #expect(committedLow == 950) // clamps against the still-committed 1000, not 300
        #expect(draft.manualLowHz == 950)
    }

    /// Resolves the follow-on question the scenario above raises: once Low has committed
    /// against the stale High, what happens when the user's still-pending High edit finally
    /// commits? It clamps against the *now-current* Low (950, not the original 1000) — so a
    /// typed 300 silently becomes 951, since 300 no longer clears `manualLowHz + 1`. This is
    /// the expected consequence of commit-on-blur with two independently-committed fields,
    /// not a data-loss bug: no crash, no corrupted persisted state, and the same clamp rule
    /// that already governs every other commit. It is a real UX surprise worth documenting
    /// here rather than fixing — swapping to a "commit both together" model would reintroduce
    /// the per-keystroke filter-coefficient rebuild this design deliberately avoids (see
    /// `NoiseModeDraft`'s own doc comment).
    @Test func commitManualHighAfterAStaleLowClampCascadesIntoFurtherClamping() async throws {
        var draft = NoiseModeDraft()
        draft.manualHighHz = 1000
        _ = draft.commitManualLow(950) // clamps against stale High, as above

        let committedHigh = draft.commitManualHigh(300) // the pending edit finally commits

        #expect(committedHigh == 951) // manualLowHz(950) + 1, not the typed 300
        #expect(draft.manualHighHz == 951)
    }

    @Test func commitThirdOctaveBandClampsThenSnapsToNearestBand() async throws {
        var draft = NoiseModeDraft()
        let snapped = draft.commitThirdOctaveBand(fromTypedHz: 990)
        #expect(snapped == 1000)
        #expect(ThirdOctaveBands.centerFrequenciesHz[draft.thirdOctaveBandIndex] == 1000)
    }

    @Test func commitThirdOctaveBandClampsOutOfRangeValuesFirst() async throws {
        var draft = NoiseModeDraft()
        let snappedLow = draft.commitThirdOctaveBand(fromTypedHz: 5)
        #expect(snappedLow == ThirdOctaveBands.centerFrequenciesHz.first)

        let snappedHigh = draft.commitThirdOctaveBand(fromTypedHz: 30000)
        #expect(snappedHigh == ThirdOctaveBands.centerFrequenciesHz.last)
    }

    @Test func steppedThirdOctaveBandMovesToAdjacentBands() async throws {
        var draft = NoiseModeDraft()
        draft.thirdOctaveBandIndex = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: 1000)!

        let next = draft.steppedThirdOctaveBand(direction: 1)
        #expect(next == ThirdOctaveBands.centerFrequenciesHz[draft.thirdOctaveBandIndex])
        #expect(draft.thirdOctaveBandIndex == ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: 1000)! + 1)

        let previous = draft.steppedThirdOctaveBand(direction: -1)
        #expect(previous == 1000)
        #expect(draft.thirdOctaveBandIndex == ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: 1000))
    }

    @Test func steppedThirdOctaveBandStaysPutAtTableEdges() async throws {
        var draft = NoiseModeDraft()
        draft.thirdOctaveBandIndex = 0
        let steppedDown = draft.steppedThirdOctaveBand(direction: -1)
        #expect(steppedDown == ThirdOctaveBands.centerFrequenciesHz.first)
        #expect(draft.thirdOctaveBandIndex == 0)

        draft.thirdOctaveBandIndex = ThirdOctaveBands.centerFrequenciesHz.count - 1
        let steppedUp = draft.steppedThirdOctaveBand(direction: 1)
        #expect(steppedUp == ThirdOctaveBands.centerFrequenciesHz.last)
        #expect(draft.thirdOctaveBandIndex == ThirdOctaveBands.centerFrequenciesHz.count - 1)
    }

    @MainActor
    @Test func pinkNoiseModeAssociatedValuesSurviveARelaunch() async throws {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manualStore = SettingsStore(defaults: defaults)
        manualStore.update { $0.pinkNoiseMode = .bandLimited(.manual(lowHz: 250, highHz: 3500)) }
        #expect(SettingsStore(defaults: defaults).snapshot.pinkNoiseMode == .bandLimited(.manual(lowHz: 250, highHz: 3500)))

        let thirdOctaveStore = SettingsStore(defaults: defaults)
        thirdOctaveStore.update { $0.pinkNoiseMode = .thirdOctave(bandIndex: 17) }
        #expect(SettingsStore(defaults: defaults).snapshot.pinkNoiseMode == .thirdOctave(bandIndex: 17))
    }

    @MainActor
    @Test func whiteNoiseModeAssociatedValuesSurviveARelaunch() async throws {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manualStore = SettingsStore(defaults: defaults)
        manualStore.update { $0.whiteNoiseMode = .bandLimited(.manual(lowHz: 250, highHz: 3500)) }
        #expect(SettingsStore(defaults: defaults).snapshot.whiteNoiseMode == .bandLimited(.manual(lowHz: 250, highHz: 3500)))

        let thirdOctaveStore = SettingsStore(defaults: defaults)
        thirdOctaveStore.update { $0.whiteNoiseMode = .thirdOctave(bandIndex: 17) }
        #expect(SettingsStore(defaults: defaults).snapshot.whiteNoiseMode == .thirdOctave(bandIndex: 17))

        // Pink's and White's mode selections persist independently, not sharing one field.
        #expect(SettingsStore(defaults: defaults).snapshot.pinkNoiseMode == .fullRange)
    }

    @Test func biquadLowpassPassesBelowAndAttenuatesAboveCutoff() async throws {
        let sampleRate = 48000.0
        let cutoffHz = 1000.0

        let passGain = Self.steadyStateGain(
            Biquad(type: .lowpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 100, sampleRate: sampleRate
        )
        let stopGain = Self.steadyStateGain(
            Biquad(type: .lowpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 8000, sampleRate: sampleRate
        )

        #expect(passGain > 0.9)
        #expect(stopGain < 0.2)
    }

    @Test func biquadHighpassAttenuatesBelowAndPassesAboveCutoff() async throws {
        let sampleRate = 48000.0
        let cutoffHz = 1000.0

        let stopGain = Self.steadyStateGain(
            Biquad(type: .highpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 100, sampleRate: sampleRate
        )
        let passGain = Self.steadyStateGain(
            Biquad(type: .highpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 8000, sampleRate: sampleRate
        )

        #expect(stopGain < 0.2)
        #expect(passGain > 0.9)
    }

    @Test func biquadBandpassPassesAtCenterAndAttenuatesFarOutside() async throws {
        let sampleRate = 48000.0
        let centerHz = 1000.0
        let thirdOctaveQ = 4.318

        func gain(at probeHz: Double) -> Double {
            Self.steadyStateGain(
                Biquad(type: .bandpass, f0: centerHz, q: thirdOctaveQ, sampleRate: sampleRate),
                probeFrequencyHz: probeHz, sampleRate: sampleRate
            )
        }

        #expect(abs(gain(at: centerHz) - 1) < 0.05)
        #expect(gain(at: centerHz / 8) < 0.1)
        #expect(gain(at: centerHz * 8) < 0.1)
    }

    @Test func biquadRemainsStableAtLowCutoffRelativeToSampleRate() async throws {
        let sampleRate = 44100.0
        var biquad = Biquad(type: .highpass, f0: 20, q: 0.7071, sampleRate: sampleRate)

        var maxAbsOutput = 0.0
        for n in 0..<Int(sampleRate * 2) {
            let x = sin(2 * Double.pi * 20 * Double(n) / sampleRate)
            let y = biquad.process(x)
            #expect(y.isFinite)
            maxAbsOutput = max(maxAbsOutput, abs(y))
        }
        #expect(maxAbsOutput < 10)
    }

    /// Feeds a sine probe through a copy of `filter` (a `Biquad` or `BandLimitedFilterChain`)
    /// and returns the steady-state output/input RMS ratio, skipping enough initial samples
    /// for the filter to settle.
    private static func steadyStateGain<Filter: SampleFilter>(
        _ filter: Filter, probeFrequencyHz: Double, sampleRate: Double
    ) -> Double {
        var filter = filter
        let totalSamples = 8192
        let settleSamples = 4096

        var inputSumSquares = 0.0
        var outputSumSquares = 0.0
        for n in 0..<totalSamples {
            let x = sin(2 * Double.pi * probeFrequencyHz * Double(n) / sampleRate)
            let y = filter.process(x)
            if n >= settleSamples {
                inputSumSquares += x * x
                outputSumSquares += y * y
            }
        }

        let inputRMS = (inputSumSquares / Double(totalSamples - settleSamples)).squareRoot()
        let outputRMS = (outputSumSquares / Double(totalSamples - settleSamples)).squareRoot()
        return outputRMS / inputRMS
    }

    /// Estimates instantaneous frequency from positive-going zero-crossing spacing in a
    /// window around `centerIndex`, sized to a few periods of `expectedHz` so the sweep's
    /// continuously-changing frequency stays locally near-constant across the window.
    private static func measuredFrequencyHz(
        centeredAt centerIndex: Int, expectedHz: Double, samples: [Float], sampleRate: Double
    ) -> Double {
        let periodSamples = sampleRate / expectedHz
        let radius = max(Int(periodSamples * 3), 50)
        let lower = max(0, centerIndex - radius)
        let upper = min(samples.count - 2, centerIndex + radius)
        guard lower < upper else { return .nan }

        var crossingIndices: [Int] = []
        for i in lower...upper where samples[i] <= 0 && samples[i + 1] > 0 {
            crossingIndices.append(i)
        }
        guard crossingIndices.count >= 2 else { return .nan }

        let intervals = zip(crossingIndices, crossingIndices.dropFirst()).map { Double($1 - $0) }
        let meanInterval = intervals.reduce(0, +) / Double(intervals.count)
        return sampleRate / meanInterval
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

    /// Renders steady-state output for the generator already configured on `core`, priming with a
    /// short `running == false` block before ramping up. This originally worked around a render-loop
    /// bug (the generator swap was adopted *after* the per-frame ramp step, so a fresh core's first
    /// ON stayed stuck on its `.sine` default); that bug is now fixed — `render()` adopts before the
    /// ramp step, so `renderToArrays` alone renders the configured generator on the first ON (see
    /// `signalSwitchedWhileOffIsAdoptedOnTheFirstOn`). The priming block is now belt-and-suspenders
    /// and harmless; existing non-sine tests keep using it, new ones may render straight through.
    private static func renderSteadyState(
        _ core: SignalRenderCore, frameCount: Int, channelCount: Int, sampleRate: Double
    ) -> [[Float]] {
        core.updateParameters { $0.running = false }
        _ = renderToArrays(core, frameCount: 64, channelCount: channelCount, sampleRate: sampleRate)
        core.updateParameters { $0.running = true }
        return renderToArrays(core, frameCount: frameCount, channelCount: channelCount, sampleRate: sampleRate)
    }

}
