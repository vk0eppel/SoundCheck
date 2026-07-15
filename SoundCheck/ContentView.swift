//
//  ContentView.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 15/07/2026.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum SignalType: String, CaseIterable, Identifiable, Codable {
    case sine = "SINE"
    case pink = "PINK"
    case white = "WHITE"

    var id: String { rawValue }

    var generatorKind: GeneratorKind {
        switch self {
        case .sine: .sine
        case .pink: .pink
        case .white: .white
        }
    }
}

struct ChannelState: Equatable {
    var muted = true
    var phaseReversed = false
}

#if os(macOS)
struct ContentView: View {
    @State private var deviceCatalog = AudioDeviceCatalog()
    @State private var engineController = AudioEngineController()
    @State private var settingsStore = SettingsStore()

    @State private var signalType: SignalType = .sine
    @State private var isRunning = false
    @State private var alwaysOnTop = false
    @State private var frequencyHz: Double = 1000
    @State private var levelDbfs: Double = -20
    @State private var selectedDeviceUID: String?
    @State private var channels: [ChannelState] = []
    @State private var showsDeviceDisconnectedAlert = false

    var body: some View {
        VStack(spacing: 20) {
            Picker("", selection: $signalType) {
                ForEach(SignalType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: signalType) { _, newValue in
                // ADR 0003: signal-type switch forces a full stop, not a crossfade.
                isRunning = false
                engineController.renderCore.updateParameters {
                    $0.generatorKind = newValue.generatorKind
                    $0.running = false
                }
                settingsStore.update { $0.signalType = newValue }
            }

            onOffButton

            if signalType == .sine {
                frequencyControl
            }

            levelControl

            devicePicker

            channelRow

            HStack {
                Text(formatReadout)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            let snapshot = settingsStore.snapshot
            signalType = snapshot.signalType
            frequencyHz = snapshot.frequencyHz
            levelDbfs = snapshot.levelDbfs
            engineController.renderCore.updateParameters {
                $0.generatorKind = snapshot.signalType.generatorKind
                $0.frequencyHz = snapshot.frequencyHz
                $0.levelDbfs = snapshot.levelDbfs
            }

            if let savedUID = snapshot.selectedDeviceUID, deviceCatalog.devices.contains(where: { $0.uid == savedUID }) {
                selectedDeviceUID = savedUID
            } else {
                selectedDeviceUID = deviceCatalog.devices.first?.uid
            }
            selectDeviceIfNeeded()
        }
        .onChange(of: selectedDeviceUID) { _, newValue in
            selectDeviceIfNeeded()
            settingsStore.update { $0.selectedDeviceUID = newValue }
        }
        .onChange(of: deviceCatalog.devices) { _, _ in handleDeviceListChanged() }
        .onChange(of: frequencyHz) { _, newValue in
            engineController.renderCore.updateParameters { $0.frequencyHz = newValue }
            settingsStore.update { $0.frequencyHz = newValue }
        }
        .onChange(of: levelDbfs) { _, newValue in
            engineController.renderCore.updateParameters { $0.levelDbfs = newValue }
            settingsStore.update { $0.levelDbfs = newValue }
        }
        .onChange(of: channels) { _, newValue in
            engineController.renderCore.updateParameters {
                $0.channelMuted = newValue.map(\.muted)
                $0.channelPhaseReversed = newValue.map(\.phaseReversed)
            }
            if let selectedDeviceUID {
                settingsStore.update {
                    $0.channelStatesByDeviceUID[selectedDeviceUID] = newValue.map {
                        PersistedChannelState(muted: $0.muted, phaseReversed: $0.phaseReversed)
                    }
                }
            }
        }
        .background(WindowAccessor(alwaysOnTop: alwaysOnTop))
        .alert("Output Device Disconnected", isPresented: $showsDeviceDisconnectedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The selected output device was disconnected. Playback has been stopped.")
        }
    }

    private var onOffButton: some View {
        Button {
            isRunning.toggle()
            engineController.renderCore.updateParameters { $0.running = isRunning }
        } label: {
            Text(isRunning ? "ON" : "OFF")
                .font(.title.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .background(isRunning ? Color.red : Color.secondary.opacity(0.25))
        .foregroundStyle(isRunning ? .white : .primary)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .keyboardShortcut(.space, modifiers: [])
    }

    private var frequencyControl: some View {
        HStack {
            Text("Frequency")
            Button {
                stepFrequency(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            TextField("Hz", value: $frequencyHz, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                .frame(width: 80)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onChange(of: frequencyHz) { _, newValue in
                    frequencyHz = min(max(newValue, 20), 20000)
                }
            Text("Hz")

            Button {
                stepFrequency(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var levelControl: some View {
        HStack {
            Text("Level")
            Button {
                adjustLevel(-1)
            } label: {
                Image(systemName: "minus")
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            TextField("dBFS", value: $levelDbfs, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 70)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onChange(of: levelDbfs) { _, newValue in
                    levelDbfs = min(max(newValue, -99), 0)
                }
            Text("dBFS")

            Button {
                adjustLevel(1)
            } label: {
                Image(systemName: "plus")
            }
            .keyboardShortcut(.upArrow, modifiers: [])
        }
    }

    private var devicePicker: some View {
        Picker("Output Device", selection: $selectedDeviceUID) {
            ForEach(deviceCatalog.devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
        .pickerStyle(.menu)
    }

    private var channelRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(channels.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text("Ch \(index + 1)")
                            .font(.caption)
                        Toggle(isOn: $channels[index].muted) {
                            Text("Mute")
                        }
                        .toggleStyle(.button)
                        .tint(.red)

                        Toggle(isOn: $channels[index].phaseReversed) {
                            Text("Ø")
                        }
                        .toggleStyle(.button)
                        .tint(.orange)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(height: 100)
    }

    private var selectedDevice: AudioDeviceInfo? {
        deviceCatalog.devices.first { $0.uid == selectedDeviceUID }
    }

    private var formatReadout: String {
        guard let device = selectedDevice,
            let sampleRate = AudioDeviceCatalog.nominalSampleRate(for: device.id),
            let bitDepth = AudioDeviceCatalog.bitDepth(for: device.id)
        else { return "—" }
        return String(format: "%.1f kHz / %d-bit", sampleRate / 1000, bitDepth)
    }

    private func stepFrequency(_ direction: Int) {
        frequencyHz = ThirdOctaveBands.step(from: frequencyHz, direction: direction)
    }

    private func adjustLevel(_ direction: Int) {
        levelDbfs = min(max(levelDbfs + Double(direction), -99), 0)
    }

    private func selectDeviceIfNeeded() {
        guard let device = selectedDevice else { return }
        engineController.selectDevice(device)
        // Restores this device's saved channel states, or all-muted if none are saved yet
        // or the channel count no longer matches (ADR 0001) — SettingsStore already
        // applies that fallback.
        let savedStates = settingsStore.channelStates(forDeviceUID: device.uid, channelCount: device.outputChannelCount)
        channels = savedStates.map { ChannelState(muted: $0.muted, phaseReversed: $0.phaseReversed) }
    }

    private func handleDeviceListChanged() {
        guard let selectedDeviceUID, !deviceCatalog.devices.contains(where: { $0.uid == selectedDeviceUID }) else {
            return
        }
        if isRunning {
            isRunning = false
            engineController.renderCore.updateParameters { $0.running = false }
            showsDeviceDisconnectedAlert = true
        }
        self.selectedDeviceUID = nil
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView) }
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}
#else
struct ContentView: View {
    var body: some View {
        Text("SoundCheck is macOS-only for now.")
            .padding()
    }
}
#endif

#Preview {
    ContentView()
}
