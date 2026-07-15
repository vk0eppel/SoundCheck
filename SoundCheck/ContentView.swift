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

enum SignalType: String, CaseIterable, Identifiable {
    case sine = "SINE"
    case pink = "PINK"
    case white = "WHITE"

    var id: String { rawValue }
}

struct ChannelState {
    var muted = true
    var phaseReversed = false
}

private let mockDevices: [(name: String, channelCount: Int)] = [
    ("MOTU 8A", 8),
    ("Built-in Output", 2),
    ("Universal Audio Apollo", 4),
]

private let mockFrequencySteps: [Int] = [
    200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000,
]

struct ContentView: View {
    @State private var signalType: SignalType = .sine
    @State private var isRunning = false
    @State private var alwaysOnTop = false
    @State private var frequencyHz = 1000
    @State private var levelDbfs: Double = -20
    @State private var selectedDeviceIndex = 0
    @State private var channels: [ChannelState] = Array(repeating: ChannelState(), count: 8)

    var body: some View {
        VStack(spacing: 20) {
            Picker("", selection: $signalType) {
                ForEach(SignalType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            onOffButton

            if signalType == .sine {
                frequencyControl
            }

            levelControl

            devicePicker

            channelRow

            HStack {
                Text("48.0 kHz / 24-bit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                #if os(macOS)
                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                #endif
            }
        }
        .padding(24)
        .frame(width: 420)
        .onChange(of: selectedDeviceIndex) { _, _ in resetChannelsToMuted() }
        .onAppear { resetChannelsToMuted() }
        #if os(macOS)
        .background(WindowAccessor(alwaysOnTop: alwaysOnTop))
        #endif
    }

    private var onOffButton: some View {
        Button {
            isRunning.toggle()
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

            TextField("Hz", value: $frequencyHz, format: .number)
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
        Picker("Output Device", selection: $selectedDeviceIndex) {
            ForEach(mockDevices.indices, id: \.self) { index in
                Text(mockDevices[index].name).tag(index)
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

    private func stepFrequency(_ direction: Int) {
        guard let currentIndex = mockFrequencySteps.lastIndex(where: { $0 <= frequencyHz }) else { return }
        let newIndex = min(max(currentIndex + direction, 0), mockFrequencySteps.count - 1)
        frequencyHz = mockFrequencySteps[newIndex]
    }

    private func adjustLevel(_ direction: Int) {
        levelDbfs = min(max(levelDbfs + Double(direction), -99), 0)
    }

    private func resetChannelsToMuted() {
        channels = Array(repeating: ChannelState(), count: mockDevices[selectedDeviceIndex].channelCount)
    }
}

#if os(macOS)
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
#endif

#Preview {
    ContentView()
}
