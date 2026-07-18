# Shared design tokens with FreqTrace, and owning appearance instead of following the system

Originally (V1 "Visual design", `docs/v1-spec.md`), SoundCheck deliberately **followed the system light/dark appearance automatically** — the identity came from typography, proportion, and one signature accent (`Color.soundCheckAmber`, plus the always-dark `Color.soundCheckLCDPanel` as the single narrow exception), never from an app-owned theme. That stance is reversed here.

## Decision

SoundCheck adopts the sibling [FreqTrace](../../../FreqTrace) project's design-token system verbatim: `DesignSystem/DesignTokens.swift` (the hex-string, unit-testable palette), `Theme.swift` (tokens → SwiftUI `Color`, exposed via `EnvironmentValues.theme`), `HexColor.swift`, and `AppearanceSettings.swift` (a persisted manual Dark/Light toggle). The app now **owns its appearance** — defaulting to Dark like FreqTrace, with a footer picker — rather than deferring to the OS.

## Reason

The two apps are functional companions in the same domain (FreqTrace *analyzes* live sound; SoundCheck *generates* test signals) by the same author, meant to sit open side by side. They had already converged independently on the same identity — a warning-lamp amber accent, red for danger, a console/instrument aesthetic — so formalizing one shared vocabulary is an asset, not templating. FreqTrace had already done the hard part: a layered, unit-tested token set (`bg`/`surface`/`surfaceRaised`/`border`/`text` tiers) with *both* appearance modes deliberately designed (Light is a higher-contrast redesign, not an inversion). Reinventing that in SoundCheck would be strictly worse.

Adopting it also resolves a real flaw in SoundCheck's own accent discipline: `soundCheckAmber` had been carrying three meanings (running, selected tab, engaged Ø). FreqTrace's console language already separates these — **`danger` (red) is the running/tally light**, **`accent` (amber) is a selected preference** — so the ON/running indicator moves to red and amber becomes purely "selected."

## Consequences

- SoundCheck no longer follows system appearance; it drives `.preferredColorScheme` from `AppearanceSettings.mode` so any residual system-semantic colors match the owned theme.
- The **LCD numeric readout stays always-dark regardless of mode** (a real instrument backlight doesn't go white in a bright room) — the one deliberate carve-out from the theme, using a fixed dark panel color rather than `theme.bg`, which flips pale in Light mode. This preserves the "backlit display" signature that V1's `soundCheckLCDPanel` established.
- The token files are currently a copy, not a shared Swift package. If a third consumer appears, or the palettes drift, promote them to a shared package. Until then a copy avoids restructuring two Xcode projects.
