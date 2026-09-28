//
//  AudioEngineController.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 16/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

#if os(macOS)
import AVFoundation
import CoreAudio
import Observation
import os

/// Wraps `SignalRenderCore` in a real `AVAudioSourceNode`/`AVAudioEngine` graph and binds
/// output to a specific Core Audio device, per the architecture in docs/spec.md: stays
/// inside AVAudioEngine, overriding the output node's AudioUnit's current-device property.
@MainActor
@Observable
final class AudioEngineController {
    let renderCore = SignalRenderCore()

    private(set) var lastStartError: String?

    /// Rebuilt from scratch on every device switch. `AVAudioEngine`'s `outputNode` caches the
    /// stream format it negotiated with the *first* device it bound to, and reusing one engine
    /// across a switch to a device with a different sample rate (e.g. built-in 44.1kHz -> a
    /// BlackHole/aggregate virtual device at 48kHz) leaves that stale format in place -> the
    /// source-node connection silently mismatches and no audio reaches the new device. A fresh
    /// engine per switch guarantees the graph binds to the newly-selected device's real format.
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    /// The desired output state: the engine is only run while this is true. Keeping a
    /// (possibly high-channel-count, virtual) device's CoreAudio HAL IO loop spinning while
    /// output is OFF was the idle-CPU cost (~37% on a 64/112-channel virtual device) — the
    /// engine's continuous per-channel HAL work, not our synthesis. Stored so `selectDevice`
    /// (a device switch) knows whether to start the freshly-built engine.
    private var shouldRun = false

    /// A stop scheduled slightly after output goes OFF (see `setRunning`), cancellable if ON
    /// is pressed again first.
    private var pendingStop: Task<Void, Never>?

    private let log = Logger(subsystem: "com.soundcheck", category: "AudioEngineController")

    /// Starts or stops the engine to match `running`. The `AudioUnit` device override set in
    /// `selectDevice` persists across start/stop on the same engine (we only rebuild the engine
    /// on a *device switch*, not on a run toggle), so no re-bind is needed here.
    func setRunning(_ running: Bool) {
        shouldRun = running
        pendingStop?.cancel()
        pendingStop = nil
        if running {
            startEngineIfNeeded()
        } else {
            // Delay the actual stop past the render core's ~15ms fade-out ramp so its tail
            // isn't truncated into an audible click. Cancelled above if ON is pressed again
            // first. Runs on the main actor (this type is @MainActor).
            pendingStop = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self?.engine.stop()
            }
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            lastStartError = nil
        } catch {
            log.error("engine.start() failed: \(error.localizedDescription, privacy: .public)")
            lastStartError = error.localizedDescription
        }
    }

    func selectDevice(_ device: AudioDeviceInfo) {
        engine.stop()

        // Fresh engine so no stale output format survives from the previously-bound device.
        engine = AVAudioEngine()

        guard setCoreAudioOutputDevice(device.id) else {
            log.error("Failed to bind output device \(device.name, privacy: .public) (id \(device.id))")
            lastStartError = "Could not select \(device.name) as the output device."
            return
        }

        // Bind the render graph to the device's *actual* negotiated output format, not a
        // hand-built format at the device's nominal sample rate. On a virtual/aggregate device
        // the two can differ (rate or channel count); connecting a source node straight to
        // `outputNode` inserts no sample-rate converter, so any mismatch renders as silence.
        rebuildSourceNode(preferredChannelCount: device.outputChannelCount, deviceID: device.id)

        // Only run the freshly-built engine if output is currently ON. On launch / a device
        // switch while OFF, the device stays bound and the source node ready, but the engine
        // (and the CoreAudio HAL IO loop it drives) stays stopped — see `shouldRun`.
        if shouldRun {
            startEngineIfNeeded()
        }
    }

    /// Dismisses a surfaced bind/start failure (the UI alert's cancel action).
    func clearLastStartError() {
        lastStartError = nil
    }

    private func rebuildSourceNode(preferredChannelCount: Int, deviceID: AudioDeviceID) {
        if let existing = sourceNode {
            engine.detach(existing)
            sourceNode = nil
        }

        // The format the engine's output node negotiated with the now-bound device — the source
        // must render at exactly this rate/channel-count for the direct connection to carry audio.
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let format: AVAudioFormat?
        if outputFormat.sampleRate > 0, outputFormat.channelCount > 0 {
            format = outputFormat
        } else {
            // Fall back to a constructed standard format if the output node hasn't reported one yet.
            let sampleRate = AudioDeviceCatalog.nominalSampleRate(for: deviceID) ?? 48000
            format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: AVAudioChannelCount(max(preferredChannelCount, 1)))
        }
        guard let format, format.channelCount > 0 else {
            log.error("No usable output format; source node not built")
            return
        }
        log.debug("Binding source node at \(format.sampleRate)Hz x \(format.channelCount)ch (device reports \(preferredChannelCount)ch)")

        let renderCore = self.renderCore
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            renderCore.render(frameCount: Int(frameCount), channelCount: buffers.count, sampleRate: format.sampleRate) { channel in
                Self.floatBuffer(forChannel: channel, in: buffers, frameCount: Int(frameCount))
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
        sourceNode = node
    }

    /// Converts one channel's `AudioBuffer` entry into a typed sample buffer for
    /// `SignalRenderCore.render` — pure and allocation-free, so (unlike the
    /// `AVAudioSourceNode` render closure it's called from) it's unit-testable with a
    /// hand-built `AudioBufferList`, without needing a real audio engine. `nonisolated`
    /// since it touches no actor-isolated state, matching `AudioDeviceCatalog`'s static
    /// query functions. Force-unwraps `mData`: in valid `AVAudioSourceNode` usage with a
    /// properly configured `AVAudioFormat`, every channel's buffer is always backed by
    /// real storage.
    nonisolated static func floatBuffer(
        forChannel channel: Int, in buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int
    ) -> UnsafeMutableBufferPointer<Float> {
        let raw = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
        return UnsafeMutableBufferPointer(start: raw, count: frameCount)
    }

    private func setCoreAudioOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.outputNode.audioUnit else { return false }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
}
#endif
