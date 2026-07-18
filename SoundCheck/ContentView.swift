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

/// Bridges `NoiseMode`'s associated-value cases to something SwiftUI's segmented/menu
/// pickers can drive, and back — one instance per noise color (Pink and White each hold
/// their own in `ContentView`, so each color's sub-mode selection persists independently;
/// see docs/v1-spec.md's V2 addendum). Owns the *committed* sub-selection only; transient
/// per-keystroke draft text for the manual-range/1/3-octave fields stays outside, as
/// `ContentView`-only `@State`, since it's UI-input-lifecycle state (avoiding an audible
/// mid-keystroke filter-coefficient hot-swap — see docs/research/band-limited-noise-generation.md's
/// "Cost" section), not domain state that belongs on this type.
struct NoiseModeDraft {
    var family: NoiseMode.Family = .fullRange
    var bandLimitedSelection: BandLimitedPreset.Selection = .preset0to200Hz
    var manualLowHz: Double = 200
    var manualHighHz: Double = 1000
    var thirdOctaveBandIndex: Int = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: 1000) ?? 0

    init() {}

    /// Decomposes a loaded/live `NoiseMode` into this draft's separate family/preset/band
    /// fields — the inverse of `resolved` below.
    init(resolving mode: NoiseMode) {
        switch mode {
        case .fullRange:
            family = .fullRange
        case .bandLimited(let preset):
            family = .bandLimited
            bandLimitedSelection = preset.selection
            if case .manual(let lowHz, let highHz) = preset {
                manualLowHz = lowHz
                manualHighHz = highHz
            }
        case .thirdOctave(let bandIndex):
            family = .thirdOctave
            thirdOctaveBandIndex = bandIndex
        }
    }

    /// The `RenderParameters`/`SettingsStore`-facing value assembled from this draft's
    /// family + preset/band selection, so the rest of the app only ever deals in the one
    /// real `NoiseMode`.
    var resolved: NoiseMode {
        switch family {
        case .fullRange: .fullRange
        case .bandLimited: .bandLimited(bandLimitedPreset)
        case .thirdOctave: .thirdOctave(bandIndex: thirdOctaveBandIndex)
        }
    }

    private var bandLimitedPreset: BandLimitedPreset {
        switch bandLimitedSelection {
        case .preset0to200Hz: .preset0to200Hz
        case .preset200HzTo1kHz: .preset200HzTo1kHz
        case .preset1kTo20kHz: .preset1kTo20kHz
        case .preset7kTo20kHz: .preset7kTo20kHz
        case .manual: .manual(lowHz: manualLowHz, highHz: manualHighHz)
        }
    }
}

/// Identifies which manual-range field currently has focus, so losing focus (blur) can be
/// distinguished from moving between the two fields — see `manualRangeFields`.
private enum ManualRangeField: Hashable {
    case low
    case high
}

/// Identifies which of the Frequency/Level/Duration fields currently has focus, so Return
/// can resign it and hand keyboard focus back to the app (see `editableFieldFocus`).
private enum EditableField: Hashable {
    case frequency
    case level
    case duration
}

/// SoundCheck's one signature accent — a warning-lamp amber, used for the running state and
/// its echoes (the phase toggle, the LED), the selected signal-type tab, and (as a subtle
/// hairline glow, not a fill) the numeric-readout fields' `LCDFieldStyle`. Everything else
/// stays semantic system color so light/dark appearance keeps following the system
/// automatically — `soundCheckLCDPanel` is the one deliberate, narrow exception, matching
/// the amber LED's own appearance-independent color (see `LCDFieldStyle`'s doc comment).
extension Color {
    static let soundCheckAmber = Color(red: 0.90, green: 0.58, blue: 0.10)
    static let soundCheckLCDPanel = Color(red: 0.07, green: 0.065, blue: 0.06)
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

/// SoundCheck's numeric-readout treatment for Frequency/Level/Duration/manual-range fields —
/// a dark inset panel with a hairline glow echoing the ON/OFF button's amber LED
/// (`onOffButton`), since these fields are the closest thing in the design to an actual
/// instrument's numeric display. Deliberately dark regardless of system appearance, the same
/// way a real LCD/VFD readout's backlight doesn't turn white in a bright room — text color is
/// forced light to stay legible against it in both light and dark appearance. Styling only:
/// doesn't touch any field's commit-timing, clamping, or snapping behavior.
private struct LCDFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                // Opaque, not a translucent black -- a `.opacity()` fill blends toward
                // whatever's behind it, which washes out to a pale gray (not a dark LCD
                // panel) against a light-appearance PanelSection background.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.soundCheckLCDPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.soundCheckAmber.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color.soundCheckAmber.opacity(0.25), radius: 3)
    }
}

private extension View {
    func lcdFieldStyle() -> some View {
        modifier(LCDFieldStyle())
    }
}

#if os(macOS)
struct ContentView: View {
    @State private var deviceCatalog = AudioDeviceCatalog()
    @State private var engineController: AudioEngineController
    @State private var settingsStore: SettingsStore
    @State private var signalSettings: SignalSettings

    @State private var alwaysOnTop = false
    // Committed sub-mode selection, one instance per noise color so Pink's and White's
    // selections persist independently (see `NoiseModeDraft`'s doc comment). Which one is
    // "active" is derived from `signalSettings.signalType` via `activeNoiseDraft` below.
    @State private var pinkDraft = NoiseModeDraft()
    @State private var whiteDraft = NoiseModeDraft()
    // Transient per-keystroke draft text, shared (not duplicated per color) since only one
    // color's manual-range/1/3-octave field is ever visible at a time and these are
    // re-seeded from the active draft's committed values on appear/signal-type switch, not
    // persisted across a switch. Kept separate from the committed values above so a
    // filter-coefficient rebuild only happens on commit (blur/Return), not per keystroke --
    // per docs/research/band-limited-noise-generation.md's Cost section, hot-swapping a
    // running filter's coefficients on every intermediate drag/keystroke frame risks an
    // audible discontinuity.
    @State private var manualLowHzDraft: Double = 200
    @State private var manualHighHzDraft: Double = 1000
    @FocusState private var manualRangeFieldFocus: ManualRangeField?
    // Draft for the shared Frequency field's TextField when it's driving 1/3-octave noise
    // rather than Sine -- kept separate from `frequencyHz` (Sine's own persisted value) so
    // typing a band value here can't clobber Sine's saved frequency, and committed
    // (blur/Return) rather than live for the same filter-coefficient-hot-swap reason as
    // `manualLowHzDraft`/`manualHighHzDraft` above.
    @State private var thirdOctaveHzDraft: Double = 1000
    @FocusState private var thirdOctaveFieldFocused: Bool
    // Frequency/Level/Duration apply live per keystroke (no commit-on-blur step, unlike
    // the manual-range/1/3-octave fields above), but still need focus tracking: without
    // it, pressing Return has nothing to resign, and the field keeps first-responder
    // status indefinitely -- silently swallowing the space/arrow-key shortcuts below
    // (AppKit routes those to the focused text field, not up to the app) until the user
    // manually clicks elsewhere.
    @FocusState private var editableFieldFocus: EditableField?
    @State private var selectedDeviceUID: String?
    @State private var showsDeviceDisconnectedAlert = false

    /// `signalSettings` is constructed here (not with a plain default expression) because it
    /// needs references to `engineController.renderCore` and `settingsStore` — both
    /// constructed first, then handed to `SignalSettings` as injected dependencies (see
    /// issue #31).
    init() {
        let settingsStore = SettingsStore()
        let engineController = AudioEngineController()
        _settingsStore = State(initialValue: settingsStore)
        _engineController = State(initialValue: engineController)
        _signalSettings = State(initialValue: SignalSettings(renderCore: engineController.renderCore, settingsStore: settingsStore))
    }

    /// Pink and White are the two "noise-family" signal types -- both carry a `NoiseMode`
    /// sub-selection and share the mode-picker/range/manual-field views.
    private var isNoiseSignalType: Bool {
        signalSettings.signalType == .pink || signalSettings.signalType == .white
    }

    /// Whichever of `pinkDraft`/`whiteDraft` corresponds to the current `signalSettings.signalType`
    /// -- both noise-family signal types share the mode-picker/range/manual-field views by
    /// binding to this, rather than duplicating those views per color.
    private var activeNoiseDraft: Binding<NoiseModeDraft> {
        Binding(
            get: { signalSettings.signalType == .white ? whiteDraft : pinkDraft },
            set: { newValue in
                if signalSettings.signalType == .white { whiteDraft = newValue } else { pinkDraft = newValue }
            }
        )
    }

    var body: some View {
        @Bindable var signalSettings = signalSettings
        VStack(spacing: 16) {
            PanelSection(title: "GENERATOR") {
                VStack(spacing: 16) {
                    Picker("", selection: $signalSettings.signalType) {
                        ForEach(GeneratorKind.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(.soundCheckAmber)
                    .onChange(of: signalSettings.signalType) { _, _ in
                        // Resync the transient draft text to whichever color is now active --
                        // `thirdOctaveFrequencyControl`'s own `onAppear` resync (below) covers
                        // the case where it's newly mounted, but SwiftUI may preserve an
                        // already-mounted instance's identity across this switch, so resync
                        // explicitly here too rather than relying on that alone.
                        manualLowHzDraft = activeNoiseDraft.wrappedValue.manualLowHz
                        manualHighHzDraft = activeNoiseDraft.wrappedValue.manualHighHz
                        thirdOctaveHzDraft = ThirdOctaveBands.centerFrequenciesHz[activeNoiseDraft.wrappedValue.thirdOctaveBandIndex]
                    }

                    onOffButton

                    // Reserved even when not applicable (not conditionally removed) so the
                    // fixed-size window doesn't reflow when switching signal type or noise
                    // sub-mode. The mode selector sits right under on/off, shared by Pink and
                    // White (both "noise-family" signal types).
                    noiseModeControl
                        .opacity(isNoiseSignalType ? 1 : 0)
                        .disabled(!isNoiseSignalType)

                    // One shared slot, not three parallel reserved rows: Sine's frequency
                    // field, noise 1/3-Octave's band field, and noise Band-limited's "Range"
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
                        .opacity(isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .bandLimited && activeNoiseDraft.wrappedValue.bandLimitedSelection == .manual ? 1 : 0)
                        .disabled(!(isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .bandLimited && activeNoiseDraft.wrappedValue.bandLimitedSelection == .manual))

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
        .contentShape(Rectangle())
        .onTapGesture { dismissFieldFocus() }
        .onAppear {
            let snapshot = settingsStore.snapshot
            pinkDraft = NoiseModeDraft(resolving: snapshot.pinkNoiseMode)
            whiteDraft = NoiseModeDraft(resolving: snapshot.whiteNoiseMode)
            manualLowHzDraft = activeNoiseDraft.wrappedValue.manualLowHz
            manualHighHzDraft = activeNoiseDraft.wrappedValue.manualHighHz
            thirdOctaveHzDraft = ThirdOctaveBands.centerFrequenciesHz[activeNoiseDraft.wrappedValue.thirdOctaveBandIndex]

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
        .onChange(of: pinkDraft.resolved) { _, newValue in
            // Applies live, same as frequency/level — only a signal-*type* switch
            // forces a full stop (ADR 0003), not a change within a noise color's sub-modes.
            signalSettings.pinkNoiseMode = newValue
        }
        .onChange(of: whiteDraft.resolved) { _, newValue in
            signalSettings.whiteNoiseMode = newValue
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
            signalSettings.isRunning.toggle()
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(signalSettings.isRunning ? Color.soundCheckAmber : Color.black.opacity(0.25))
                    .frame(width: 10, height: 10)
                    .shadow(color: signalSettings.isRunning ? .soundCheckAmber : .clear, radius: 6)
                Text(signalSettings.isRunning ? "ON" : "OFF")
                    .font(.title2.weight(.bold))
                    .tracking(3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(signalSettings.isRunning ? Color.soundCheckAmber.opacity(0.22) : Color.secondary.opacity(0.15))
        .foregroundStyle(signalSettings.isRunning ? Color.soundCheckAmber : .primary)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(signalSettings.isRunning ? Color.soundCheckAmber.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop the signal (Space)")
    }

    /// The one shared slot for Sine's frequency field, noise Band-limited's "Range" picker,
    /// and noise 1/3-Octave's band field (shared by Pink and White alike, via
    /// `activeNoiseDraft`) — only one of the three is ever mounted at a time, in the exact
    /// same VStack position, rather than three parallel reserved rows.
    @ViewBuilder
    private var frequencyOrRangeControl: some View {
        if isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .bandLimited {
            rangeControl
        } else if isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .thirdOctave {
            thirdOctaveFrequencyControl
        } else if signalSettings.signalType == .sweep {
            durationControl
        } else {
            frequencyControl
        }
    }

    private var frequencyOrRangeControlVisible: Bool {
        switch signalSettings.signalType {
        case .sine: true
        case .pink, .white:
            activeNoiseDraft.wrappedValue.family == .bandLimited || activeNoiseDraft.wrappedValue.family == .thirdOctave
        case .sweep: true
        case .square: true
        }
    }

    private var frequencyControl: some View {
        @Bindable var signalSettings = signalSettings
        return HStack {
            Text("Frequency")

            TextField("Hz", value: $signalSettings.frequencyHz, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .lcdFieldStyle()
                .frame(width: 80)
                .focused($editableFieldFocus, equals: .frequency)
                .onChange(of: signalSettings.frequencyHz) { _, newValue in
                    signalSettings.frequencyHz = min(max(newValue, 20), 20000)
                }
                .onSubmit { editableFieldFocus = nil }
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
                .multilineTextAlignment(.center)
                .lcdFieldStyle()
                .frame(width: 80)
                .focused($thirdOctaveFieldFocused)
                .onSubmit {
                    commitThirdOctaveDraft()
                    thirdOctaveFieldFocused = false
                }
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
        .onChange(of: activeNoiseDraft.wrappedValue.thirdOctaveBandIndex) { _, newValue in
            thirdOctaveHzDraft = ThirdOctaveBands.centerFrequenciesHz[newValue]
        }
        // `onChange` alone misses the case where `thirdOctaveBandIndex` was set (e.g. by
        // `NoiseModeDraft(resolving:)` on launch) while this branch of `frequencyOrRangeControl`
        // wasn't mounted yet — resync whenever this view (re)appears.
        .onAppear {
            thirdOctaveHzDraft = ThirdOctaveBands.centerFrequenciesHz[activeNoiseDraft.wrappedValue.thirdOctaveBandIndex]
        }
    }

    /// Shared by Pink and White (both "noise-family" signal types) via `activeNoiseDraft` —
    /// visible only when `isNoiseSignalType`.
    private var noiseModeControl: some View {
        Picker("", selection: activeNoiseDraft.family) {
            ForEach(NoiseMode.Family.allCases) { family in
                Text(family.rawValue).tag(family)
            }
        }
        .pickerStyle(.segmented)
        // Deliberately neutral, not system blue and not `.soundCheckAmber` -- amber is
        // reserved for the running-state LED, the selected signal-type tab, and the engaged
        // Ø toggle only (docs/v1-spec.md's Visual design section), and this control isn't
        // one of those three.
        .tint(.secondary)
    }

    /// Occupies the same shared slot `frequencyControl`/`thirdOctaveFrequencyControl` do —
    /// the "frequency-like control" for a noise color's Band-limited sub-mode. Manual's
    /// low/high fields live in their own separate reserved slot (`manualRangeFields`), since
    /// they need to appear alongside this picker, not instead of it.
    private var rangeControl: some View {
        HStack {
            Text("Range")

            Picker("", selection: activeNoiseDraft.bandLimitedSelection) {
                ForEach(BandLimitedPreset.Selection.allCases) { preset in
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
                .multilineTextAlignment(.center)
                .lcdFieldStyle()
                .frame(width: 55)
                .focused($manualRangeFieldFocus, equals: .low)
                .onSubmit {
                    commitManualLowHz()
                    manualRangeFieldFocus = nil
                }
            Text("–")
                .foregroundStyle(.secondary)
            TextField("High", value: $manualHighHzDraft, format: .number.grouping(.never).precision(.fractionLength(0)))
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .lcdFieldStyle()
                .frame(width: 55)
                .focused($manualRangeFieldFocus, equals: .high)
                .onSubmit {
                    commitManualHighHz()
                    manualRangeFieldFocus = nil
                }
        }
        .onChange(of: manualRangeFieldFocus) { oldValue, newValue in
            if oldValue == .low && newValue != .low { commitManualLowHz() }
            if oldValue == .high && newValue != .high { commitManualHighHz() }
        }
        // Explicit, tighter than the TextFields' own natural height -- reserved uniformly
        // whether this row is shown or hidden (see the `.opacity`/`.disabled` gate above),
        // so the gap above Level reads tight in every mode without touching the
        // reserve-space/no-reflow guarantee itself. Comfortably fits the Low/High fields
        // when they're actually visible (Band-limited/Manual).
        .frame(height: 24)
    }

    /// Occupies the same shared slot `frequencyControl`/`thirdOctaveFrequencyControl`/
    /// `rangeControl` do — Sweep's duration field. No `SettingsStore`-free draft state
    /// (unlike the manual-range/1/3-octave fields): duration applies live per keystroke,
    /// same as Level, since there's no filter-coefficient rebuild to protect against
    /// intermediate values here. Uses left/right (not Level's up/down) to avoid a
    /// keyboard-shortcut collision with the always-visible Level stepper, matching this
    /// slot's existing left/right convention from Frequency's prev/next chevrons.
    private var durationControl: some View {
        @Bindable var signalSettings = signalSettings
        return HStack {
            Text("Duration")

            TextField("s", value: $signalSettings.sweepDurationSeconds, format: .number.grouping(.never).precision(.fractionLength(0...2)))
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .lcdFieldStyle()
                .frame(width: 70)
                .focused($editableFieldFocus, equals: .duration)
                .onChange(of: signalSettings.sweepDurationSeconds) { _, newValue in
                    signalSettings.sweepDurationSeconds = min(max(newValue, 1), 60)
                }
                .onSubmit { editableFieldFocus = nil }
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
        @Bindable var signalSettings = signalSettings
        return HStack {
            Text("Level")

            TextField("dBFS", value: $signalSettings.levelDbfs, format: .number.precision(.fractionLength(0...1)))
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
                .lcdFieldStyle()
                .frame(width: 70)
                .focused($editableFieldFocus, equals: .level)
                .onChange(of: signalSettings.levelDbfs) { _, newValue in
                    signalSettings.levelDbfs = min(max(newValue, -99), 0)
                }
                .onSubmit { editableFieldFocus = nil }
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
        @Bindable var signalSettings = signalSettings
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(signalSettings.channels.indices, id: \.self) { index in
                    VStack(spacing: 6) {
                        Text("CH \(index + 1)")
                            .font(.caption2.weight(.semibold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        Toggle(isOn: $signalSettings.channels[index].muted) {
                            Text("Mute")
                        }
                        .toggleStyle(SolidToggleStyle(color: .red))

                        Toggle(isOn: $signalSettings.channels[index].phaseReversed) {
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
        signalSettings.frequencyHz = ThirdOctaveBands.step(from: signalSettings.frequencyHz, direction: direction)
    }

    private func commitManualLowHz() {
        let newLow = min(max(manualLowHzDraft, 20), activeNoiseDraft.wrappedValue.manualHighHz - 1)
        activeNoiseDraft.wrappedValue.manualLowHz = newLow
        manualLowHzDraft = newLow
    }

    private func commitManualHighHz() {
        let newHigh = max(min(manualHighHzDraft, 20000), activeNoiseDraft.wrappedValue.manualLowHz + 1)
        activeNoiseDraft.wrappedValue.manualHighHz = newHigh
        manualHighHzDraft = newHigh
    }

    private func stepThirdOctaveBand(_ direction: Int) {
        let currentHz = ThirdOctaveBands.centerFrequenciesHz[activeNoiseDraft.wrappedValue.thirdOctaveBandIndex]
        let newHz = ThirdOctaveBands.step(from: currentHz, direction: direction)
        activeNoiseDraft.wrappedValue.thirdOctaveBandIndex =
            ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: newHz) ?? activeNoiseDraft.wrappedValue.thirdOctaveBandIndex
    }

    /// Clamps and snaps a typed `thirdOctaveHzDraft` value to the nearest ISO 266 band on
    /// commit (Return/blur) — `direction: 0` reuses `ThirdOctaveBands.step`'s existing
    /// nearest-index search rather than duplicating it.
    private func commitThirdOctaveDraft() {
        let clamped = min(max(thirdOctaveHzDraft, 20), 20000)
        let snapped = ThirdOctaveBands.step(from: clamped, direction: 0)
        activeNoiseDraft.wrappedValue.thirdOctaveBandIndex =
            ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: snapped) ?? activeNoiseDraft.wrappedValue.thirdOctaveBandIndex
        thirdOctaveHzDraft = snapped
    }

    private func adjustLevel(_ direction: Int) {
        signalSettings.levelDbfs = min(max(signalSettings.levelDbfs + Double(direction), -99), 0)
    }

    private func adjustSweepDuration(_ direction: Int) {
        signalSettings.sweepDurationSeconds = min(max(signalSettings.sweepDurationSeconds + Double(direction), 1), 60)
    }

    /// Clicking a non-control area (panel background, labels) doesn't resign a focused
    /// `NSTextField`'s first-responder status on its own -- unlike iOS, AppKit only moves
    /// focus when another focusable control claims it, so without this the field (and the
    /// space/arrow shortcuts it silently swallows) stays stuck until the user happens to
    /// click a different field or button. Wired to a tap gesture on the whole window body.
    private func dismissFieldFocus() {
        editableFieldFocus = nil
        manualRangeFieldFocus = nil
        thirdOctaveFieldFocused = false
    }

    private func selectDeviceIfNeeded() {
        guard let device = selectedDevice else { return }
        engineController.selectDevice(device)
        signalSettings.deviceDidChange(to: device.uid)
        // Every channel is forced muted on every device switch, per ADR 0001 — even for a
        // previously-used device whose saved state had a channel unmuted. Only phase-reverse
        // state is restored from what was saved.
        let statesForSwitch = settingsStore.channelStatesForDeviceSwitch(forDeviceUID: device.uid, channelCount: device.outputChannelCount)
        signalSettings.channels = statesForSwitch
    }

    private func handleDeviceListChanged() {
        guard let selectedDeviceUID, !deviceCatalog.devices.contains(where: { $0.uid == selectedDeviceUID }) else {
            return
        }
        if signalSettings.isRunning {
            signalSettings.isRunning = false
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
