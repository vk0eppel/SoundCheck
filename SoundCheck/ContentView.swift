//
//  ContentView.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 15/07/2026.
//
//
//  Copyright (C) 2026 Victor Koeppel
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Full license text: see LICENSE in the repository root.

import SwiftUI
#if os(macOS)
import AppKit
#endif

enum SignalType: String, CaseIterable, Identifiable, Codable {
    case sine = "SINE"
    case pink = "PINK"
    case white = "WHITE"
    case sweep = "SWEEP"

    var id: String { rawValue }

    var generatorKind: GeneratorKind {
        switch self {
        case .sine: .sine
        case .pink: .pink
        case .white: .white
        case .sweep: .sweep
        }
    }
}

/// Which of Pink's three sub-modes is active — the UI-facing counterpart to
/// `PinkNoiseMode`, which can't itself be `CaseIterable`/segmented-picker-friendly once
/// `.bandLimited`/`.thirdOctave` carry associated data.
private enum PinkNoiseModeFamily: String, CaseIterable, Identifiable {
    case fullRange = "FULL-RANGE"
    case bandLimited = "BAND-LIMITED"
    case thirdOctave = "1/3-OCTAVE"

    var id: String { rawValue }
}

/// The UI-facing counterpart to `BandLimitedPreset`, for the same reason as
/// `PinkNoiseModeFamily` — `.manual` carries the actual low/high values separately.
private enum BandLimitedPresetSelection: String, CaseIterable, Identifiable {
    case preset0to200Hz = "0–200Hz"
    case preset200HzTo1kHz = "200Hz–1kHz"
    case preset1kTo20kHz = "1kHz–20kHz"
    case preset7kTo20kHz = "7kHz–20kHz"
    case manual = "MANUAL"

    var id: String { rawValue }
}

/// Identifies which manual-range field currently has focus, so losing focus (blur) can be
/// distinguished from moving between the two fields — see `manualRangeFields`.
private enum ManualRangeField: Hashable {
    case low
    case high
}

struct ChannelState: Equatable {
    var muted = true
    var phaseReversed = false
}

/// SoundCheck's one signature accent — a warning-lamp amber, used only for the running
/// state and its echoes (the phase toggle, the LED). Everything else stays semantic
/// system color so light/dark appearance keeps following the system automatically.
extension Color {
    static let soundCheckAmber = Color(red: 0.90, green: 0.58, blue: 0.10)
}

/// A titled grouping, evoking a labeled zone on an instrument's front panel — not
/// decoration: it separates "what's being generated" from "where it's going."
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Solid fill + bold high-contrast text when on, dim outline when off — engaged/disengaged
/// must be unmistakable at a glance for channel routing, the same "never color alone, and
/// make the state obvious" language the ON/OFF button already uses.
private struct SolidToggleStyle: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(configuration.isOn ? color : Color.clear)
        .foregroundStyle(configuration.isOn ? .white : .secondary)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(configuration.isOn ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
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
    @State private var pinkNoiseModeFamily: PinkNoiseModeFamily = .fullRange
    @State private var bandLimitedPresetSelection: BandLimitedPresetSelection = .preset0to200Hz
    // Committed values -- these, not the drafts below, feed `bandLimitedPreset`/
    // `pinkNoiseMode` and so the render core. Kept separate from the text fields' live
    // typing so a filter-coefficient rebuild only happens on commit (blur/Return), not per
    // keystroke -- per docs/research/band-limited-noise-generation.md's Cost section,
    // hot-swapping a running filter's coefficients on every intermediate drag/keystroke
    // frame risks an audible discontinuity.
    @State private var manualLowHz: Double = 200
    @State private var manualHighHz: Double = 1000
    @State private var manualLowHzDraft: Double = 200
    @State private var manualHighHzDraft: Double = 1000
    @FocusState private var manualRangeFieldFocus: ManualRangeField?
    @State private var thirdOctaveBandIndex: Int = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: 1000) ?? 0
    // Draft for the shared Frequency field's TextField when it's driving 1/3-octave Pink
    // rather than Sine -- kept separate from `frequencyHz` (Sine's own persisted value) so
    // typing a band value here can't clobber Sine's saved frequency, and committed
    // (blur/Return) rather than live for the same filter-coefficient-hot-swap reason as
    // `manualLowHz`/`manualHighHz` above.
    @State private var thirdOctaveHzDraft: Double = 1000
    @FocusState private var thirdOctaveFieldFocused: Bool
    @State private var sweepDurationSeconds: Double = 10
    @State private var selectedDeviceUID: String?
    @State private var channels: [ChannelState] = []
    @State private var showsDeviceDisconnectedAlert = false

    var body: some View {
        VStack(spacing: 16) {
            PanelSection(title: "GENERATOR") {
                VStack(spacing: 16) {
                    Picker("", selection: $signalType) {
                        ForEach(SignalType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(.soundCheckAmber)
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

                    // Reserved even when not applicable (not conditionally removed) so the
                    // fixed-size window doesn't reflow when switching signal type or Pink
                    // sub-mode. Pink's mode selector sits right under on/off.
                    pinkNoiseModeControl
                        .opacity(signalType == .pink ? 1 : 0)
                        .disabled(signalType != .pink)

                    // One shared slot, not three parallel reserved rows: Sine's frequency
                    // field, Pink 1/3-Octave's band field, and Pink Band-limited's "Range"
                    // picker all render in the exact same spot (via `frequencyOrRangeControl`
                    // switching content), so "the frequency-like control" is literally the
                    // same control, not three near-duplicates stacked invisibly on top of
                    // each other.
                    frequencyOrRangeControl
                        .opacity(frequencyOrRangeControlVisible ? 1 : 0)
                        .disabled(!frequencyOrRangeControlVisible)

                    // Band-limited's manual low/high fields get their own reserved slot right
                    // below, since they need to appear alongside the Range picker above (not
                    // instead of it) when Manual is selected.
                    manualRangeFields
                        .opacity(signalType == .pink && pinkNoiseModeFamily == .bandLimited && bandLimitedPresetSelection == .manual ? 1 : 0)
                        .disabled(!(signalType == .pink && pinkNoiseModeFamily == .bandLimited && bandLimitedPresetSelection == .manual))

                    levelControl
                }
            }

            PanelSection(title: "OUTPUT") {
                VStack(spacing: 16) {
                    devicePicker
                    channelRow
                }
            }

            HStack {
                Text(formatReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            let snapshot = settingsStore.snapshot
            signalType = snapshot.signalType
            frequencyHz = snapshot.frequencyHz
            levelDbfs = snapshot.levelDbfs
            applyLoadedPinkNoiseMode(snapshot.pinkNoiseMode)
            sweepDurationSeconds = snapshot.sweepDurationSeconds
            engineController.renderCore.updateParameters {
                $0.generatorKind = snapshot.signalType.generatorKind
                $0.frequencyHz = snapshot.frequencyHz
                $0.levelDbfs = snapshot.levelDbfs
                $0.pinkNoiseMode = snapshot.pinkNoiseMode
                $0.sweepDurationSeconds = snapshot.sweepDurationSeconds
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
        .onChange(of: pinkNoiseMode) { _, newValue in
            // Applies live, same as frequency/level — only a signal-*type* switch
            // forces a full stop (ADR 0003), not a change within Pink's sub-modes.
            engineController.renderCore.updateParameters { $0.pinkNoiseMode = newValue }
            settingsStore.update { $0.pinkNoiseMode = newValue }
        }
        .onChange(of: sweepDurationSeconds) { _, newValue in
            engineController.renderCore.updateParameters { $0.sweepDurationSeconds = newValue }
            settingsStore.update { $0.sweepDurationSeconds = newValue }
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
            HStack(spacing: 10) {
                Circle()
                    .fill(isRunning ? Color.soundCheckAmber : Color.black.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .shadow(color: isRunning ? .soundCheckAmber : .clear, radius: 6)
                Text(isRunning ? "ON" : "OFF")
                    .font(.title2.weight(.bold))
                    .tracking(3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isRunning ? Color.soundCheckAmber.opacity(0.22) : Color.secondary.opacity(0.15))
        .foregroundStyle(isRunning ? Color.soundCheckAmber : .primary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isRunning ? Color.soundCheckAmber.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop the signal (Space)")
    }

    /// The one shared slot for Sine's frequency field, Pink 1/3-Octave's band field, and
    /// Pink Band-limited's "Range" picker — only one of the three is ever mounted at a time,
    /// in the exact same VStack position, rather than three parallel reserved rows.
    @ViewBuilder
    private var frequencyOrRangeControl: some View {
        if signalType == .pink && pinkNoiseModeFamily == .bandLimited {
            rangeControl
        } else if signalType == .pink && pinkNoiseModeFamily == .thirdOctave {
            thirdOctaveFrequencyControl
        } else if signalType == .sweep {
            durationControl
        } else {
            frequencyControl
        }
    }

    private var frequencyOrRangeControlVisible: Bool {
        switch signalType {
        case .sine: true
        case .pink: pinkNoiseModeFamily == .bandLimited || pinkNoiseModeFamily == .thirdOctave
        case .white: false
        case .sweep: true
        }
    }

    private var frequencyControl: some View {
        HStack {
            Text("Frequency")

            TextField("Hz", value: $frequencyHz, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                .font(.system(.body, design: .monospaced))
                .frame(width: 80)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onChange(of: frequencyHz) { _, newValue in
                    frequencyHz = min(max(newValue, 20), 20000)
                }
            Text("Hz")
                .foregroundStyle(.secondary)

            // Left/right, matching the left-arrow/right-arrow keyboard shortcuts below.
            HStack(spacing: 4) {
                Button {
                    stepFrequency(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous 1/3-octave band (←)")

                Button {
                    stepFrequency(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next 1/3-octave band (→)")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Same visual structure as `frequencyControl` (same label, TextField style, "Hz"
    /// suffix, chevrons) but bound to `thirdOctaveHzDraft`/`thirdOctaveBandIndex` instead of
    /// `frequencyHz`, so typing a band value here can't overwrite Sine's saved frequency.
    /// Typed values commit (and snap to the nearest ISO 266 band) on Return/blur, matching
    /// `manualRangeFields`' commit-not-live pattern, since a live per-keystroke commit would
    /// rebuild the bandpass filter's coefficients on every intermediate keystroke.
    private var thirdOctaveFrequencyControl: some View {
        HStack {
            Text("Frequency")

            TextField("Hz", value: $thirdOctaveHzDraft, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                .font(.system(.body, design: .monospaced))
                .frame(width: 80)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($thirdOctaveFieldFocused)
                .onSubmit { commitThirdOctaveDraft() }
            Text("Hz")
                .foregroundStyle(.secondary)

            // Left/right, matching the left-arrow/right-arrow keyboard shortcuts below.
            HStack(spacing: 4) {
                Button {
                    stepThirdOctaveBand(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous 1/3-octave band (←)")

                Button {
                    stepThirdOctaveBand(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next 1/3-octave band (→)")
            }
            .buttonStyle(.bordered)
        }
        .onChange(of: thirdOctaveFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused { commitThirdOctaveDraft() }
        }
        .onChange(of: thirdOctaveBandIndex) { _, newValue in
            thirdOctaveHzDraft = ThirdOctaveBands.centerFrequenciesHz[newValue]
        }
        // `onChange` alone misses the case where `thirdOctaveBandIndex` was set (e.g. by
        // `applyLoadedPinkNoiseMode` on launch) while this branch of `frequencyOrRangeControl`
        // wasn't mounted yet — resync whenever this view (re)appears.
        .onAppear {
            thirdOctaveHzDraft = ThirdOctaveBands.centerFrequenciesHz[thirdOctaveBandIndex]
        }
    }

    /// The `RenderParameters`/`SettingsStore`-facing value, assembled from the UI-facing
    /// family + preset/band selection state so the rest of the app (parameter push,
    /// persistence) only ever deals in the one real `PinkNoiseMode`.
    private var pinkNoiseMode: PinkNoiseMode {
        switch pinkNoiseModeFamily {
        case .fullRange: .fullRange
        case .bandLimited: .bandLimited(bandLimitedPreset)
        case .thirdOctave: .thirdOctave(bandIndex: thirdOctaveBandIndex)
        }
    }

    private var bandLimitedPreset: BandLimitedPreset {
        switch bandLimitedPresetSelection {
        case .preset0to200Hz: .preset0to200Hz
        case .preset200HzTo1kHz: .preset200HzTo1kHz
        case .preset1kTo20kHz: .preset1kTo20kHz
        case .preset7kTo20kHz: .preset7kTo20kHz
        case .manual: .manual(lowHz: manualLowHz, highHz: manualHighHz)
        }
    }

    private var pinkNoiseModeControl: some View {
        Picker("", selection: $pinkNoiseModeFamily) {
            ForEach(PinkNoiseModeFamily.allCases) { family in
                Text(family.rawValue).tag(family)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Occupies the same shared slot `frequencyControl`/`thirdOctaveFrequencyControl` do —
    /// the "frequency-like control" for Pink's Band-limited sub-mode. Manual's low/high
    /// fields live in their own separate reserved slot (`manualRangeFields`), since they
    /// need to appear alongside this picker, not instead of it.
    private var rangeControl: some View {
        HStack {
            Text("Range")

            Picker("", selection: $bandLimitedPresetSelection) {
                ForEach(BandLimitedPresetSelection.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
        }
    }

    /// Binds to the *draft* values, not `manualLowHz`/`manualHighHz` directly — commits
    /// only fire on Return or on losing focus, not per keystroke (see the state
    /// declarations above for why).
    private var manualRangeFields: some View {
        HStack(spacing: 4) {
            TextField("Low", value: $manualLowHzDraft, format: .number.grouping(.never).precision(.fractionLength(0)))
                .font(.system(.body, design: .monospaced))
                .frame(width: 55)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($manualRangeFieldFocus, equals: .low)
                .onSubmit { commitManualLowHz() }
            Text("–")
                .foregroundStyle(.secondary)
            TextField("High", value: $manualHighHzDraft, format: .number.grouping(.never).precision(.fractionLength(0)))
                .font(.system(.body, design: .monospaced))
                .frame(width: 55)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($manualRangeFieldFocus, equals: .high)
                .onSubmit { commitManualHighHz() }
        }
        .onChange(of: manualRangeFieldFocus) { oldValue, newValue in
            if oldValue == .low && newValue != .low { commitManualLowHz() }
            if oldValue == .high && newValue != .high { commitManualHighHz() }
        }
    }

    /// Occupies the same shared slot `frequencyControl`/`thirdOctaveFrequencyControl`/
    /// `rangeControl` do — Sweep's duration field. No `SettingsStore`-free draft state
    /// (unlike the manual-range/1/3-octave fields): duration applies live per keystroke,
    /// same as Level, since there's no filter-coefficient rebuild to protect against
    /// intermediate values here. Uses left/right (not Level's up/down) to avoid a
    /// keyboard-shortcut collision with the always-visible Level stepper, matching this
    /// slot's existing left/right convention from Frequency's prev/next chevrons.
    private var durationControl: some View {
        HStack {
            Text("Duration")

            TextField("s", value: $sweepDurationSeconds, format: .number.grouping(.never).precision(.fractionLength(0...2)))
                .font(.system(.body, design: .monospaced))
                .frame(width: 70)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onChange(of: sweepDurationSeconds) { _, newValue in
                    sweepDurationSeconds = min(max(newValue, 1), 60)
                }
            Text("s")
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Button {
                    adjustSweepDuration(-1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Decrease duration by 1s (←)")

                Button {
                    adjustSweepDuration(1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Increase duration by 1s (→)")
            }
            .buttonStyle(.bordered)
        }
    }

    private var levelControl: some View {
        HStack {
            Text("Level")

            TextField("dBFS", value: $levelDbfs, format: .number.precision(.fractionLength(0...1)))
                .font(.system(.body, design: .monospaced))
                .frame(width: 70)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .onChange(of: levelDbfs) { _, newValue in
                    levelDbfs = min(max(newValue, -99), 0)
                }
            Text("dBFS")
                .foregroundStyle(.secondary)

            // + above -, matching the up-arrow/down-arrow keyboard shortcuts below.
            VStack(spacing: 4) {
                Button {
                    adjustLevel(1)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .help("Increase level by 1dB (↑)")

                Button {
                    adjustLevel(-1)
                } label: {
                    Image(systemName: "minus")
                        .frame(width: Self.stepperButtonSize, height: Self.stepperButtonSize)
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .help("Decrease level by 1dB (↓)")
            }
            .buttonStyle(.bordered)
        }
    }

    /// Shared tap-target size for every stepper button (frequency prev/next, level +/-)
    /// so they read as one consistent control family.
    private static let stepperButtonSize: CGFloat = 16

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
                        Text("CH \(index + 1)")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        Toggle(isOn: $channels[index].muted) {
                            Text("Mute")
                        }
                        .toggleStyle(SolidToggleStyle(color: .red))

                        Toggle(isOn: $channels[index].phaseReversed) {
                            Text("Ø")
                        }
                        .toggleStyle(SolidToggleStyle(color: .soundCheckAmber))
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

    private func commitManualLowHz() {
        manualLowHz = min(max(manualLowHzDraft, 20), manualHighHz - 1)
        manualLowHzDraft = manualLowHz
    }

    private func commitManualHighHz() {
        manualHighHz = max(min(manualHighHzDraft, 20000), manualLowHz + 1)
        manualHighHzDraft = manualHighHz
    }

    private func stepThirdOctaveBand(_ direction: Int) {
        let currentHz = ThirdOctaveBands.centerFrequenciesHz[thirdOctaveBandIndex]
        let newHz = ThirdOctaveBands.step(from: currentHz, direction: direction)
        thirdOctaveBandIndex = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: newHz) ?? thirdOctaveBandIndex
    }

    /// Clamps and snaps a typed `thirdOctaveHzDraft` value to the nearest ISO 266 band on
    /// commit (Return/blur) — `direction: 0` reuses `ThirdOctaveBands.step`'s existing
    /// nearest-index search rather than duplicating it.
    private func commitThirdOctaveDraft() {
        let clamped = min(max(thirdOctaveHzDraft, 20), 20000)
        let snapped = ThirdOctaveBands.step(from: clamped, direction: 0)
        thirdOctaveBandIndex = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: snapped) ?? thirdOctaveBandIndex
        thirdOctaveHzDraft = snapped
    }

    /// Decomposes a loaded `PinkNoiseMode` back into the separate UI-facing family/preset/
    /// band state — the inverse of the `pinkNoiseMode`/`bandLimitedPreset` computed
    /// properties above.
    private func applyLoadedPinkNoiseMode(_ mode: PinkNoiseMode) {
        switch mode {
        case .fullRange:
            pinkNoiseModeFamily = .fullRange
        case .bandLimited(let preset):
            pinkNoiseModeFamily = .bandLimited
            switch preset {
            case .preset0to200Hz: bandLimitedPresetSelection = .preset0to200Hz
            case .preset200HzTo1kHz: bandLimitedPresetSelection = .preset200HzTo1kHz
            case .preset1kTo20kHz: bandLimitedPresetSelection = .preset1kTo20kHz
            case .preset7kTo20kHz: bandLimitedPresetSelection = .preset7kTo20kHz
            case .manual(let lowHz, let highHz):
                bandLimitedPresetSelection = .manual
                manualLowHz = lowHz
                manualHighHz = highHz
                manualLowHzDraft = lowHz
                manualHighHzDraft = highHz
            }
        case .thirdOctave(let bandIndex):
            pinkNoiseModeFamily = .thirdOctave
            thirdOctaveBandIndex = bandIndex
        }
    }

    private func adjustLevel(_ direction: Int) {
        levelDbfs = min(max(levelDbfs + Double(direction), -99), 0)
    }

    private func adjustSweepDuration(_ direction: Int) {
        sweepDurationSeconds = min(max(sweepDurationSeconds + Double(direction), 1), 60)
    }

    private func selectDeviceIfNeeded() {
        guard let device = selectedDevice else { return }
        engineController.selectDevice(device)
        // Every channel is forced muted on every device switch, per ADR 0001 — even for a
        // previously-used device whose saved state had a channel unmuted. Only phase-reverse
        // state is restored from what was saved.
        let statesForSwitch = settingsStore.channelStatesForDeviceSwitch(forDeviceUID: device.uid, channelCount: device.outputChannelCount)
        channels = statesForSwitch.map { ChannelState(muted: $0.muted, phaseReversed: $0.phaseReversed) }
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
        DispatchQueue.main.async {
            // Without this, AppKit auto-focuses the first key-capable control (the
            // frequency field) as soon as the window becomes key, which swallows the
            // spacebar as a typed character instead of triggering the ON/OFF shortcut.
            // initialFirstResponder only governs the *next* time the window becomes
            // key (which may already have happened by now), so also force the
            // current first responder away explicitly. Only runs here in makeNSView,
            // not updateNSView, so it doesn't keep stealing focus from the user later.
            if let window = view.window {
                window.initialFirstResponder = window.contentView
                window.makeFirstResponder(window.contentView)
            }
            configure(view)
        }
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
