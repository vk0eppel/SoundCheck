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

/// Wraps `SignalRenderCore` in a real `AVAudioSourceNode`/`AVAudioEngine` graph and binds
/// output to a specific Core Audio device, per the architecture in docs/v1-spec.md: stays
/// inside AVAudioEngine, overriding the output node's AudioUnit's current-device property.
@MainActor
@Observable
final class AudioEngineController {
    let renderCore = SignalRenderCore()

    private(set) var lastStartError: String?

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    func selectDevice(_ device: AudioDeviceInfo) {
        engine.stop()

        guard setCoreAudioOutputDevice(device.id) else {
            lastStartError = "Could not select \(device.name) as the output device."
            return
        }

        let sampleRate = AudioDeviceCatalog.nominalSampleRate(for: device.id) ?? 48000
        rebuildSourceNode(channelCount: device.outputChannelCount, sampleRate: sampleRate)

        do {
            try engine.start()
            lastStartError = nil
        } catch {
            lastStartError = error.localizedDescription
        }
    }

    private func rebuildSourceNode(channelCount: Int, sampleRate: Double) {
        if let existing = sourceNode {
            engine.detach(existing)
            sourceNode = nil
        }
        guard channelCount > 0,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channelCount))
        else { return }

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
