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
            $0.pinkNoiseMode = .bandLimited
            $0.channelStatesByDeviceUID["device-uid-1"] = [
                PersistedChannelState(muted: false, phaseReversed: true),
                PersistedChannelState(muted: true, phaseReversed: false),
            ]
        }

        let secondLaunch = SettingsStore(defaults: defaults)
        #expect(secondLaunch.snapshot == firstLaunch.snapshot)
        #expect(secondLaunch.snapshot.signalType == .pink)
        #expect(secondLaunch.snapshot.selectedDeviceUID == "device-uid-1")
        #expect(secondLaunch.snapshot.pinkNoiseMode == .bandLimited)
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

    @Test func pinkNoiseModeDoesNotYetAlterOutput() async throws {
        let sampleRate = 48000.0
        let frameCount = 4800

        func render(mode: PinkNoiseMode) -> [Float] {
            let core = SignalRenderCore()
            core.updateParameters {
                $0.generatorKind = .pink
                $0.levelDbfs = 0
                $0.running = true
                $0.channelMuted = [false]
                $0.channelPhaseReversed = [false]
                $0.pinkNoiseMode = mode
            }
            return Self.renderToArrays(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)[0]
        }

        // No mode filters yet (that's #22/#23's job) -- every mode must render
        // bit-identically to .fullRange, i.e. unchanged from today's V1 pink noise.
        let fullRange = render(mode: .fullRange)
        #expect(render(mode: .bandLimited) == fullRange)
        #expect(render(mode: .thirdOctave) == fullRange)
    }

    @Test func biquadLowpassPassesBelowAndAttenuatesAboveCutoff() async throws {
        let sampleRate = 48000.0
        let cutoffHz = 1000.0

        let passGain = Self.steadyStateGain(
            biquad: Biquad(type: .lowpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 100, sampleRate: sampleRate
        )
        let stopGain = Self.steadyStateGain(
            biquad: Biquad(type: .lowpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 8000, sampleRate: sampleRate
        )

        #expect(passGain > 0.9)
        #expect(stopGain < 0.2)
    }

    @Test func biquadHighpassAttenuatesBelowAndPassesAboveCutoff() async throws {
        let sampleRate = 48000.0
        let cutoffHz = 1000.0

        let stopGain = Self.steadyStateGain(
            biquad: Biquad(type: .highpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
            probeFrequencyHz: 100, sampleRate: sampleRate
        )
        let passGain = Self.steadyStateGain(
            biquad: Biquad(type: .highpass, f0: cutoffHz, q: 0.7071, sampleRate: sampleRate),
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
                biquad: Biquad(type: .bandpass, f0: centerHz, q: thirdOctaveQ, sampleRate: sampleRate),
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

    /// Feeds a sine probe through a copy of `biquad` and returns the steady-state
    /// output/input RMS ratio, skipping enough initial samples for the filter to settle.
    private static func steadyStateGain(biquad: Biquad, probeFrequencyHz: Double, sampleRate: Double) -> Double {
        var biquad = biquad
        let totalSamples = 8192
        let settleSamples = 4096

        var inputSumSquares = 0.0
        var outputSumSquares = 0.0
        for n in 0..<totalSamples {
            let x = sin(2 * Double.pi * probeFrequencyHz * Double(n) / sampleRate)
            let y = biquad.process(x)
            if n >= settleSamples {
                inputSumSquares += x * x
                outputSumSquares += y * y
            }
        }

        let inputRMS = (inputSumSquares / Double(totalSamples - settleSamples)).squareRoot()
        let outputRMS = (outputSumSquares / Double(totalSamples - settleSamples)).squareRoot()
        return outputRMS / inputRMS
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
