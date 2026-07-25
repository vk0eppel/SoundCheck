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

    /// Clamps a typed Low value to the app's 20Hz floor and below the *last-committed*
    /// `manualHighHz` — not any uncommitted edit still sitting in the caller's own draft
    /// `@State` for High, since the two fields only ever exchange state at commit time (see
    /// this type's doc comment). Returns the clamped value so the caller can reseed its own
    /// per-keystroke draft `@State` with it.
    mutating func commitManualLow(_ typedHz: Double) -> Double {
        let clamped = min(max(typedHz, 20), manualHighHz - 1)
        manualLowHz = clamped
        return clamped
    }

    /// Symmetric with `commitManualLow` — clamps to the app's 20kHz ceiling and above the
    /// last-committed `manualLowHz`.
    mutating func commitManualHigh(_ typedHz: Double) -> Double {
        let clamped = max(min(typedHz, 20000), manualLowHz + 1)
        manualHighHz = clamped
        return clamped
    }

    /// Clamps a typed Hz to the app's 20Hz-20kHz range, then snaps it to the nearest ISO 266
    /// band — `direction: 0` reuses `ThirdOctaveBands.step`'s existing nearest-index search
    /// rather than duplicating it. Returns the snapped Hz so the caller can reseed its own
    /// per-keystroke draft `@State` with it.
    mutating func commitThirdOctaveBand(fromTypedHz typedHz: Double) -> Double {
        let clamped = min(max(typedHz, 20), 20000)
        let snapped = ThirdOctaveBands.step(from: clamped, direction: 0)
        thirdOctaveBandIndex = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: snapped) ?? thirdOctaveBandIndex
        return snapped
    }

    /// Moves to the previous/next ISO 266 band relative to the currently-selected one,
    /// clamped at the band table's edges. Returns the new band's Hz so the caller can reseed
    /// its own per-keystroke draft `@State` with it.
    mutating func steppedThirdOctaveBand(direction: Int) -> Double {
        let currentHz = ThirdOctaveBands.centerFrequenciesHz[thirdOctaveBandIndex]
        let newHz = ThirdOctaveBands.step(from: currentHz, direction: direction)
        thirdOctaveBandIndex = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: newHz) ?? thirdOctaveBandIndex
        return newHz
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

/// The one deliberate carve-out from the shared `Theme` (ADR 0005): the numeric readout's
/// backing stays dark in *both* appearance modes, the way a real instrument's LCD/VFD backlight
/// doesn't turn white in a bright room — so it can't be `theme.bg`, which flips pale in Light
/// mode. Everything else on the screen reads from `theme` (accent, danger, surfaces, text).
extension Color {
    static let soundCheckLCDPanel = Color(red: 0.07, green: 0.065, blue: 0.06)
}

/// A small lit indicator — one lit LED = one active state, the same console language the
/// sibling FreqTrace project uses (ADR 0005): a running tally (`theme.danger`) or an engaged
/// preference (`theme.accent`), shown by lighting a dot rather than flooding the whole control
/// with color.
private struct LEDIndicator: View {
    @Environment(\.theme) private var theme
    let isLit: Bool
    var color: Color?

    var body: some View {
        let lit = color ?? theme.accent
        Circle()
            .fill(isLit ? lit : theme.textFaint.opacity(0.4))
            .frame(width: 8, height: 8)
            .shadow(color: isLit ? lit.opacity(0.8) : .clear, radius: isLit ? 5 : 0)
    }
}

/// A titled grouping, evoking a labeled zone on an instrument's front panel — not
/// decoration: it separates "what's being generated" from "where it's going."
private struct PanelSection<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(2)
                .foregroundStyle(theme.textDim)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A mid console plate (`surface` + `border`), matching FreqTrace's Weighting/FFT Size
        // control modules (its `consolePlate`) -- recessed into the window's lighter
        // `surfaceRaised` chassis. The interactive controls inside lift back up to
        // `surfaceRaised`; the LCD readouts stay darkest (ADR 0005).
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(theme.border, lineWidth: 1)
        )
    }
}

/// Solid color fill + bold white text when on, dim outline when off — engaged/disengaged
/// must be unmistakable at a glance. Mute especially is a safety-critical state (every channel
/// muted by default, ADR 0001), so it deliberately floods the whole control rather than using
/// the softer lit-LED language (ADR 0005): a small dot undersells "am I muted?".
private struct SolidToggleStyle: ToggleStyle {
    @Environment(\.theme) private var theme
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
        .foregroundStyle(configuration.isOn ? .white : theme.textDim)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(configuration.isOn ? Color.clear : theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// SoundCheck's numeric-readout treatment for Frequency/Level/Duration/manual-range fields —
/// a dark inset panel with a hairline glow echoing the ON/OFF button's cyan accent
/// (`onOffButton`), since these fields are the closest thing in the design to an actual
/// instrument's numeric display. Deliberately dark regardless of system appearance, the same
/// way a real LCD/VFD readout's backlight doesn't turn white in a bright room — text color is
/// forced light to stay legible against it in both light and dark appearance. Styling only:
/// doesn't touch any field's commit-timing, clamping, or snapping behavior.
private struct LCDFieldStyle: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            // Forced light text -- legible against the always-dark LCD panel in both
            // appearance modes (theme.text flips near-black in Light mode, so it can't drive
            // this one field).
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
                    .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: theme.accent.opacity(0.25), radius: 3)
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

    @State private var appearanceSettings = AppearanceSettings()
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
    private var theme: Theme { Theme(mode: appearanceSettings.mode) }

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

    /// What the shared frequency-like slot should render right now — Sine/Square's frequency
    /// field, noise Band-limited's "Range" picker, noise 1/3-Octave's band field, Sweep's
    /// duration field, or nothing (full-range noise, where frequency doesn't mean anything).
    /// The one source of truth both `frequencyOrRangeControl`'s dispatch and
    /// `frequencySlotVisible` read directly, instead of each re-deriving the same
    /// noise-family/signal-type condition independently the way `frequencyOrRangeControl`'s
    /// if/else chain and `frequencyOrRangeControlVisible` used to.
    private enum FrequencySlotContent: Equatable {
        case frequency
        case range
        case thirdOctave
        case duration
        case hidden
    }

    private var frequencySlotContent: FrequencySlotContent {
        if isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .bandLimited {
            .range
        } else if isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .thirdOctave {
            .thirdOctave
        } else if isNoiseSignalType && activeNoiseDraft.wrappedValue.family == .fullRange {
            .hidden
        } else if signalSettings.signalType == .sweep {
            .duration
        } else {
            .frequency
        }
    }

    private var frequencySlotVisible: Bool {
        frequencySlotContent != .hidden
    }

    /// The one source of truth for whether the manual-range Low/High fields should show —
    /// read by both the opacity and disabled gates below, instead of writing the same
    /// boolean expression out twice inline. Derives from `frequencySlotContent` rather than
    /// re-testing the noise-family/Band-limited condition `frequencySlotContent` already
    /// encodes, only adding the one further check (`.manual` selected) that's specific to
    /// this row.
    private var manualRangeVisible: Bool {
        frequencySlotContent == .range && activeNoiseDraft.wrappedValue.bandLimitedSelection == .manual
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
                    .tint(theme.accent)
                    .help("Signal type — ⌥S Sine · ⌥Q Square · ⌥P Pink · ⌥W White · ⌥E Sweep")
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
                        .opacity(frequencySlotVisible ? 1 : 0)
                        .disabled(!frequencySlotVisible)

                    // Band-limited's manual low/high fields get their own reserved slot right
                    // below, since they need to appear alongside the Range picker above (not
                    // instead of it) when Manual is selected.
                    manualRangeFields
                        .opacity(manualRangeVisible ? 1 : 0)
                        .disabled(!manualRangeVisible)

                    levelControl
                }
            }

            PanelSection(title: "OUTPUT") {
                VStack(spacing: 16) {
                    devicePicker
                    bulkMuteControls
                    channelRow
                }
            }

            HStack {
                Text(formatReadout)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.textFaint)
                Spacer()
                Picker("", selection: $appearanceSettings.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .font(.caption)
                .help("Dark or Light appearance")
                Toggle("Always on Top", isOn: $alwaysOnTop)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
        .padding(20)
        .frame(width: 420)
        // The lighter console chassis the dark GENERATOR/OUTPUT wells recess into, mirroring
        // FreqTrace's meter-panel-on-surfaceRaised layering (ADR 0005).
        .background(theme.surfaceRaised)
        // Behind the opaque chassis fill above: the invisible shortcut buttons. Every one of
        // these emits into a focused field if left live (bare 1-0 Mute, ⌥1-0 phase, ⌥-letter
        // picker keys), so all are gated by `anyFieldFocused` to keep the typed keystroke. The
        // sub-mode keys are additionally gated off when no noise color is active so they can't
        // silently mutate the hidden draft. (⌥M mute-all is the one deliberate exception — it's
        // on its own visible button below, ungated, so the safety action always fires.)
        .background { channelMuteShortcuts.disabled(anyFieldFocused) }
        .background { channelPhaseShortcuts.disabled(anyFieldFocused) }
        .background { signalTypeShortcuts.disabled(anyFieldFocused) }
        .background { noiseModeShortcuts.disabled(anyFieldFocused || !isNoiseSignalType) }
        .environment(\.theme, theme)
        .preferredColorScheme(appearanceSettings.mode == .dark ? .dark : .light)
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
        .onChange(of: signalSettings.isRunning) { _, running in
            // The engine (and the CoreAudio HAL IO loop it drives) runs only while output is
            // ON — leaving it running while OFF was a large idle-CPU cost on high-channel
            // virtual devices. Funnels every transition (ON/OFF button, ADR-0003 signal-type
            // stop, device-disconnect stop) through one place.
            engineController.setRunning(running)
        }
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
        // Surface a device-bind/start failure instead of leaving it as silent, mysterious
        // no-output: `selectDevice` only stores the reason in `lastStartError`, so without this
        // a failed bind is indistinguishable from "playing but muted."
        .alert(
            "Could Not Start Output",
            isPresented: Binding(
                get: { engineController.lastStartError != nil },
                set: { if !$0 { engineController.clearLastStartError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(engineController.lastStartError ?? "")
        }
    }

    private var onOffButton: some View {
        Button {
            signalSettings.isRunning.toggle()
        } label: {
            HStack(spacing: 10) {
                // A red tally light -- "the signal is live" -- matching FreqTrace's
                // capture-running Stop/Start indicator; distinct from the cyan "armed" outline
                // of the idle state below (ADR 0005).
                LEDIndicator(isLit: signalSettings.isRunning, color: theme.danger)
                Text(signalSettings.isRunning ? "ON" : "OFF")
                    .font(.title2.weight(.bold))
                    .tracking(3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The primary run control needs presence in both appearance modes, so it doesn't lean
        // on a neutral surface fill -- in Light the neutral tokens sit too close to the white
        // panel and the button vanishes. Instead: a cyan-outlined "armed" idle state and a
        // red-filled "live" running state (cyan/red both contrast against a white *and* a dark
        // panel) -- a standby->live instrument progression (ADR 0005).
        .background((signalSettings.isRunning ? theme.danger : theme.accent)
            .opacity(signalSettings.isRunning ? 0.18 : 0.10))
        .foregroundStyle(signalSettings.isRunning ? theme.danger : theme.text)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(signalSettings.isRunning ? theme.danger : theme.accent.opacity(0.55), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .keyboardShortcut(.space, modifiers: [])
        .help("Start or stop the signal (Space)")
    }

    /// The one shared slot for Sine's frequency field, noise Band-limited's "Range" picker,
    /// and noise 1/3-Octave's band field (shared by Pink and White alike, via
    /// `activeNoiseDraft`) — only one of the three is ever mounted at a time, in the exact
    /// same VStack position, rather than three parallel reserved rows. Switches on
    /// `frequencySlotContent` directly rather than re-deriving the dispatch condition here.
    /// `.hidden` (full-range noise) still mounts `frequencyControl` — same as `.frequency` —
    /// since `frequencySlotVisible` is what hides it; the reserved-space/no-reflow guarantee
    /// depends on some view always being mounted here, not on which one.
    @ViewBuilder
    private var frequencyOrRangeControl: some View {
        switch frequencySlotContent {
        case .range: rangeControl
        case .thirdOctave: thirdOctaveFrequencyControl
        case .duration: durationControl
        case .frequency, .hidden: frequencyControl
        }
    }

    private var frequencyControl: some View {
        @Bindable var signalSettings = signalSettings
        return HStack {
            Text("Frequency")

            // Combo box: the LCD field and its band dropdown share one dark panel. Picking a
            // band sets the value live (the clamp below already keeps it in range).
            lcdComboField(width: 96, select: { signalSettings.frequencyHz = $0 }) {
                TextField("Hz", value: $signalSettings.frequencyHz, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($editableFieldFocus, equals: .frequency)
                    .onChange(of: signalSettings.frequencyHz) { _, newValue in
                        signalSettings.frequencyHz = min(max(newValue, 20), 20000)
                    }
                    .onSubmit { editableFieldFocus = nil }
            }

            Text("Hz")
                .foregroundStyle(theme.textDim)

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

            // Combo box: each menu item is already an exact band, so set the committed band
            // index directly (no snap). The `.onChange(of:thirdOctaveBandIndex)` below resyncs
            // the draft text, and pink/whiteDraft.resolved pushes the live mode.
            lcdComboField(width: 96, select: { hz in
                if let index = ThirdOctaveBands.centerFrequenciesHz.firstIndex(of: hz) {
                    activeNoiseDraft.wrappedValue.thirdOctaveBandIndex = index
                }
            }) {
                TextField("Hz", value: $thirdOctaveHzDraft, format: .number.grouping(.never).precision(.fractionLength(0...1)))
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .focused($thirdOctaveFieldFocused)
                    .onSubmit {
                        commitThirdOctaveDraft()
                        thirdOctaveFieldFocused = false
                    }
            }

            Text("Hz")
                .foregroundStyle(theme.textDim)

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
        // Cyan selection, same as the signal-type picker above -- FreqTrace tints every
        // selected segment with the accent (its WATERFALL/RTA tabs and its 1/1..1/48 banding row
        // alike), so one grey picker stacked under an accent-tinted one read as inconsistent (ADR 0005).
        .tint(theme.accent)
        .help("Noise sub-mode — ⌥F Full-range · ⌥B Band-limited · ⌥O 1/3-Octave")
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
                .foregroundStyle(theme.textDim)
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
                .foregroundStyle(theme.textDim)

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
                .foregroundStyle(theme.textDim)

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

    /// A band label matching the frequency field's own display style (no grouping, the 31.5Hz
    /// decimal exception, else whole Hz) — e.g. "1000 Hz", "31.5 Hz", "20000 Hz".
    private static func bandLabel(_ hz: Double) -> String {
        hz.formatted(.number.grouping(.never).precision(.fractionLength(0...1))) + " Hz"
    }

    /// A frequency field's LCD panel with the band dropdown built *into* it: the text field and
    /// a borderless ▾ share one dark panel + cyan border, reading as a single combo box rather
    /// than a field with a detached button beside it. `field` is the caller's already-configured
    /// `TextField` (its own binding/focus/format/commit); `select` receives a picked band's Hz.
    /// The `.lcdFieldStyle()` wraps the whole HStack, so its dark fill/border/glow and forced
    /// light text apply to both halves at once.
    private func lcdComboField<Field: View>(
        width: CGFloat,
        select: @escaping (Double) -> Void,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(spacing: 2) {
            field()
            bandMenuLabel(select: select)
        }
        .frame(width: width)
        .lcdFieldStyle()
    }

    /// The borderless ▾ that lives inside `lcdComboField`'s panel — a cyan chevron (echoing
    /// the LCD's cyan border) opening the ISO 266 band list. No bezel of its own, so it looks
    /// painted onto the dark panel rather than bolted beside it.
    private func bandMenuLabel(select: @escaping (Double) -> Void) -> some View {
        Menu {
            ForEach(ThirdOctaveBands.centerFrequenciesHz, id: \.self) { hz in
                Button(Self.bandLabel(hz)) { select(hz) }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 14, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Pick a 1/3-octave band")
    }

    private var devicePicker: some View {
        Picker("Output Device", selection: $selectedDeviceUID) {
            ForEach(deviceCatalog.devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
        .pickerStyle(.menu)
    }

    /// A single bulk-mute toggle (⌥M), visible above the channel row so the safety-relevant
    /// "kill output" is discoverable and mouse-reachable, not just a shortcut. The button *is*
    /// its own shortcut target — no separate invisible view needed — and it's ungated (unlike
    /// the picker keys) so the safety action always fires, even with a field focused. Its label
    /// and tint reflect the *next* action: "Mute All" (danger) normally, "Unmute All" once every
    /// channel is already muted.
    private var bulkMuteControls: some View {
        HStack(spacing: 8) {
            Button(allChannelsMuted ? "Unmute All" : "Mute All") { toggleAllChannelsMuted() }
                .tint(allChannelsMuted ? theme.accent : theme.danger)
                .keyboardShortcut("m", modifiers: .option)
                .help(allChannelsMuted ? "Unmute every channel (⌥M)" : "Mute every channel (⌥M)")

            Spacer()
        }
        .buttonStyle(.bordered)
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
                            .foregroundStyle(theme.textDim)
                        Toggle(isOn: $signalSettings.channels[index].muted) {
                            Text("Mute")
                        }
                        .toggleStyle(SolidToggleStyle(color: theme.danger))
                        .help(muteShortcutHelp(forChannel: index))

                        Toggle(isOn: $signalSettings.channels[index].phaseReversed) {
                            Text("Ø")
                        }
                        .toggleStyle(SolidToggleStyle(color: theme.accent))
                        .help(phaseShortcutHelp(forChannel: index))
                    }
                    .padding(8)
                    // A channel-strip plate lifted above the `surface` panel (surfaceRaised,
                    // chassis tone) -- ADR 0005's elevation model.
                    .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(theme.border, lineWidth: 1)
                    )
                }
            }
        }
        .frame(height: 100)
    }

    /// Invisible buttons backing the number-key shortcuts that toggle the first ten channels'
    /// Mute (channel 1 → "1" … channel 9 → "9", channel 10 → "0"; channels past ten have no
    /// single-key shortcut). Kept separate from the visible Mute toggles so those stay
    /// mouse-clickable, and gated by `anyFieldFocused` so typing a digit into a numeric field
    /// isn't stolen as a shortcut — a disabled button's `keyboardShortcut` doesn't fire. Placed
    /// behind the opaque window background (see `body`), so they're never seen.
    private var channelMuteShortcuts: some View {
        @Bindable var signalSettings = signalSettings
        return ForEach(signalSettings.channels.indices, id: \.self) { index in
            if let key = Self.muteShortcutKey(forChannel: index) {
                Button("") { signalSettings.channels[index].muted.toggle() }
                    .keyboardShortcut(key, modifiers: [])
            }
        }
    }

    /// Invisible buttons backing ⌥1–⌥0, toggling phase-reverse (Ø) on the first ten channels —
    /// the Option-modified sibling of `channelMuteShortcuts`' bare 1–0 Mute keys, reusing the
    /// same `muteShortcutKey` mapping. Gated by `anyFieldFocused` like the Mute keys, since
    /// Option+digit can still emit a special character into a focused field.
    private var channelPhaseShortcuts: some View {
        @Bindable var signalSettings = signalSettings
        return ForEach(signalSettings.channels.indices, id: \.self) { index in
            if let key = Self.muteShortcutKey(forChannel: index) {
                Button("") { signalSettings.channels[index].phaseReversed.toggle() }
                    .keyboardShortcut(key, modifiers: .option)
            }
        }
    }

    /// Invisible buttons backing the ⌥-letter signal-type shortcuts (⌥S Sine, ⌥Q Square,
    /// ⌥P Pink, ⌥W White, ⌥E Sweep). Assigning `signalType` forces output OFF per ADR 0003, and
    /// the picker's own `.onChange` resyncs the noise drafts — so both happen for free here.
    /// Gated by `anyFieldFocused` (see `body`): while a numeric field is focused an ⌥-letter is
    /// a typed character, and firing it would also stop a running signal out from under the user.
    private var signalTypeShortcuts: some View {
        @Bindable var signalSettings = signalSettings
        return ForEach(GeneratorKind.allCases) { type in
            Button("") { signalSettings.signalType = type }
                .keyboardShortcut(Self.signalTypeShortcutKey(type), modifiers: .option)
        }
    }

    /// Invisible buttons backing the ⌥-letter noise sub-mode shortcuts (⌥F Full-range,
    /// ⌥B Band-limited, ⌥O 1/3-Octave). Inert unless a noise color (Pink/White) is active and no
    /// field is focused — gated via `anyFieldFocused || !isNoiseSignalType` by the caller (see
    /// `body`) so it neither steals a typed ⌥-letter nor silently mutates the hidden draft.
    private var noiseModeShortcuts: some View {
        ForEach(NoiseMode.Family.allCases) { family in
            Button("") { activeNoiseDraft.family.wrappedValue = family }
                .keyboardShortcut(Self.noiseModeShortcutKey(family), modifiers: .option)
        }
    }

    /// The ⌥-letter key for a signal type — mnemonic where possible (Sine/Pink/White), with the
    /// two other S-words disambiguated: sQuare, swEep.
    private static func signalTypeShortcutKey(_ type: GeneratorKind) -> KeyEquivalent {
        switch type {
        case .sine: "s"
        case .square: "q"
        case .pink: "p"
        case .white: "w"
        case .sweep: "e"
        }
    }

    /// The ⌥-letter key for a noise sub-mode — Full-range, Band-limited, 1/3-Octave.
    private static func noiseModeShortcutKey(_ family: NoiseMode.Family) -> KeyEquivalent {
        switch family {
        case .fullRange: "f"
        case .bandLimited: "b"
        case .thirdOctave: "o"
        }
    }

    /// True when every channel is muted — the state that flips the ⌥M toggle from "mute all"
    /// (its normal action) to "unmute all". Empty channel list reads as not-all-muted so the
    /// toggle stays in its default "mute all" direction.
    private var allChannelsMuted: Bool {
        !signalSettings.channels.isEmpty && signalSettings.channels.allSatisfy(\.muted)
    }

    /// ⌥M's action: mute every channel, unless every channel is already muted, in which case
    /// unmute all. Assigns `channels` once (not per element) so `SignalSettings.channels`'
    /// `didSet` dual-write to the render core + `SettingsStore` fires a single time.
    private func toggleAllChannelsMuted() {
        setAllChannelsMuted(!allChannelsMuted)
    }

    private func setAllChannelsMuted(_ muted: Bool) {
        var updated = signalSettings.channels
        for i in updated.indices { updated[i].muted = muted }
        signalSettings.channels = updated
    }

    /// The single digit key that toggles a given channel's Mute — "1"–"9" for the first nine
    /// channels, "0" for the tenth. `nil` past ten: single digits run out, and there's no
    /// clean second key that beats just clicking.
    private static func muteShortcutKey(forChannel index: Int) -> KeyEquivalent? {
        switch index {
        case 0..<9: KeyEquivalent(Character("\(index + 1)"))
        case 9: "0"
        default: nil
        }
    }

    private func muteShortcutHelp(forChannel index: Int) -> String {
        switch Self.muteShortcutKey(forChannel: index) {
        case .some(let key): "Toggle CH \(index + 1) mute (\(key.character))"
        case .none: "Toggle CH \(index + 1) mute"
        }
    }

    private func phaseShortcutHelp(forChannel index: Int) -> String {
        switch Self.muteShortcutKey(forChannel: index) {
        case .some(let key): "Toggle CH \(index + 1) phase (⌥\(key.character))"
        case .none: "Toggle CH \(index + 1) phase"
        }
    }

    /// True while any editable numeric field holds keyboard focus — the gate that keeps the
    /// number-key Mute shortcuts from swallowing digits meant for Frequency/Level/Duration or
    /// the manual-range/1-3-octave fields.
    private var anyFieldFocused: Bool {
        editableFieldFocus != nil || manualRangeFieldFocus != nil || thirdOctaveFieldFocused
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
        manualLowHzDraft = activeNoiseDraft.wrappedValue.commitManualLow(manualLowHzDraft)
    }

    private func commitManualHighHz() {
        manualHighHzDraft = activeNoiseDraft.wrappedValue.commitManualHigh(manualHighHzDraft)
    }

    private func stepThirdOctaveBand(_ direction: Int) {
        _ = activeNoiseDraft.wrappedValue.steppedThirdOctaveBand(direction: direction)
    }

    private func commitThirdOctaveDraft() {
        thirdOctaveHzDraft = activeNoiseDraft.wrappedValue.commitThirdOctaveBand(fromTypedHz: thirdOctaveHzDraft)
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
        let view = FocusSinkView()
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

// Without this, AppKit auto-focuses the first key-capable control (the frequency
// field) as soon as the window becomes key, which swallows the spacebar as a typed
// character instead of triggering the ON/OFF shortcut. Forcibly moving focus away
// *after* the field has it is not an option: resigning an active text field tears
// down its NSTextInputContext, which synchronously waits on AppKit's Default-QoS
// input-system thread -- from the user-interactive main thread that's a priority
// inversion the Thread Performance Checker flags, and no dispatch trick avoids it
// (the main thread's QoS can't be lowered). So instead the field must never get
// auto-focus in the first place: viewDidMoveToWindow runs synchronously while the
// hierarchy is being built, before the window has ever become key, and points
// initialFirstResponder at this view. Unlike the contentView (which refuses first
// responder, making AppKit fall back to the frequency field), this view accepts it,
// so AppKit focuses it directly on becoming key and no text input context ever
// activates. Unhandled keys still bubble up the responder chain, so the spacebar
// shortcut works exactly as when the window itself held focus.
private final class FocusSinkView: NSView {
    override var acceptsFirstResponder: Bool { true }

    private var didBecomeKeyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, didBecomeKeyObserver == nil else { return }
        window.initialFirstResponder = self
        if window.isKeyWindow {
            // Defensive only: at launch this view lands in the hierarchy before the
            // window is ever key, so initialFirstResponder above does all the work.
            window.makeFirstResponder(self)
        } else {
            // One-shot safety net in case something focuses the field at key time
            // despite initialFirstResponder. If this view already holds focus, the
            // call is an early-out no-op inside AppKit (no resign, no input-context
            // teardown), so the normal path stays inversion-free.
            didBecomeKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                if let observer = self.didBecomeKeyObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
    }

    deinit {
        if let didBecomeKeyObserver {
            NotificationCenter.default.removeObserver(didBecomeKeyObserver)
        }
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
