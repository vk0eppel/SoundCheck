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
                PersistedChannelState(muted: false, phaseReversed: true),
                PersistedChannelState(muted: true, phaseReversed: false),
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
                PersistedChannelState(muted: false, phaseReversed: true),
                PersistedChannelState(muted: false, phaseReversed: false),
            ]
        }

        // ADR 0001: every channel is forced muted on every device switch, even switching
        // back to a device whose saved state had a channel left unmuted -- only
        // phase-reverse is restored from what was saved.
        let states = store.channelStatesForDeviceSwitch(forDeviceUID: "device-uid-1", channelCount: 2)

        #expect(states.allSatisfy { $0.muted })
        #expect(states.map(\.phaseReversed) == [true, false])
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
                BandLimitedFilterChain(preset: preset, sampleRate: sampleRate),
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
                    ThirdOctaveFilterChain(centerHz: centerHz, sampleRate: sampleRate),
                    probeFrequencyHz: probeHz, sampleRate: sampleRate
                )
            }

            // Center measures a modest, expected dip (~-0.2dB) from the two edges'
            // transition bands slightly overlapping this close together -- not the exact
            // unity gain the earlier single-bandpass-biquad design gave, but close.
            #expect(abs(gain(centerHz) - 1) < 0.05)
            // Well attenuated two octaves either side of center.
            #expect(gain(centerHz / 4) < 0.05)
            #expect(gain(centerHz * 4) < 0.05)
        }
    }

    /// Pink noise is equal-energy-per-octave, so without a makeup gain, band-limited/
    /// 1/3-octave modes would measure many dB quieter than full-range pink at the same
    /// `levelDbfs` -- the config value would describe the pre-filter amplitude, not the
    /// actual output. Verifies the compensation gain in `BandLimitedFilterChain` and
    /// `thirdOctaveLevelCompensationGain` keeps measured RMS close to full-range's at a
    /// fixed Level. A real biquad's finite transition-band roll-off (not brick-wall) means
    /// this can't match exactly, hence the generous tolerance.
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
            let channels = Self.renderToArrays(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)
            let settled = channels[0].suffix(frameCount - Int(0.5 * sampleRate))
            let meanSquare = settled.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(settled.count)
            return meanSquare.squareRoot()
        }

        let whiteRMS = rms(generatorKind: .white)
        let pinkRMS = rms(generatorKind: .pink)

        #expect(abs(20 * log10(pinkRMS / whiteRMS)) < 1)
    }

    @Test func filteredPinkModesMatchFullRangeRMSAtTheSameLevel() async throws {
        let sampleRate = 48000.0
        let frameCount = 96000
        let levelDbfs = -12.0

        func rms(mode: PinkNoiseMode) -> Double {
            let core = SignalRenderCore()
            core.updateParameters {
                $0.generatorKind = .pink
                $0.levelDbfs = levelDbfs
                $0.running = true
                $0.pinkNoiseMode = mode
                $0.channelMuted = [false]
                $0.channelPhaseReversed = [false]
            }
            let channels = Self.renderToArrays(core, frameCount: frameCount, channelCount: 1, sampleRate: sampleRate)
            let settled = channels[0].suffix(frameCount - Int(0.5 * sampleRate))
            let meanSquare = settled.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(settled.count)
            return meanSquare.squareRoot()
        }

        let fullRangeRMS = rms(mode: .fullRange)
        func dbRatio(_ mode: PinkNoiseMode) -> Double { 20 * log10(rms(mode: mode) / fullRangeRMS) }

        let presets: [BandLimitedPreset] = [
            .preset0to200Hz, .preset200HzTo1kHz, .preset1kTo20kHz, .preset7kTo20kHz,
            .manual(lowHz: 2000, highHz: 4000),
        ]
        for preset in presets {
            #expect(abs(dbRatio(.bandLimited(preset))) < 3)
        }

        for bandIndex in [5, 17, 25] {
            #expect(abs(dbRatio(.thirdOctave(bandIndex: bandIndex))) < 3)
        }
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

}
