//
//  AudioDeviceCatalog.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 16/07/2026.
//

#if os(macOS)
import CoreAudio
import Foundation
import Observation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannelCount: Int
}

/// Live catalog of Core Audio output devices, kept up to date as devices are
/// hot-plugged or removed.
@MainActor
@Observable
final class AudioDeviceCatalog {
    private(set) var devices: [AudioDeviceInfo] = []

    // Only ever touched on the main thread (init, deinit, and the listener block itself,
    // which Core Audio invokes on DispatchQueue.main) — deinit runs nonisolated, so these
    // can't be plain MainActor-isolated stored properties.
    @ObservationIgnored
    nonisolated(unsafe) private var listenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    nonisolated(unsafe) private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        refresh()
        startListening()
    }

    deinit {
        if let listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, listenerBlock
            )
        }
    }

    func refresh() {
        devices = Self.fetchOutputDevices()
    }

    private func startListening() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &devicesAddress, DispatchQueue.main, block
        )
    }

    // MARK: - Static Core Audio queries, usable independently of the catalog

    nonisolated static func fetchOutputDevices() -> [AudioDeviceInfo] {
        guard let deviceIDs = allDeviceIDs() else { return [] }
        return deviceIDs.compactMap { deviceID in
            let channelCount = outputChannelCount(for: deviceID)
            guard channelCount > 0, let uid = deviceUID(for: deviceID) else { return nil }
            let name = deviceName(for: deviceID) ?? uid
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name, outputChannelCount: channelCount)
        }
    }

    nonisolated static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return 0
        }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate) == noErr else {
            return nil
        }
        return sampleRate
    }

    nonisolated static func bitDepth(for deviceID: AudioDeviceID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &format) == noErr else {
            return nil
        }
        return Int(format.mBitsPerChannel)
    }

    nonisolated private static func allDeviceIDs() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }
        return deviceIDs
    }

    nonisolated private static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        cfStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    nonisolated private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        cfStringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    nonisolated private static func cfStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
