# SoundCheck

A signal generator utility for sound engineers, techs, and hifi enthusiasts to test speakers and sound systems. Generates test signals only — never analyses or captures audio.

## Language

**Channel**:
One output of the currently selected Core Audio device, independent of the device's stereo/multichannel layout. The signal is routed to every channel of the device simultaneously; each channel has its own independent mute and phase-reverse state. Modeled as one type, `Channel` (`SoundCheck/Channel.swift`), used directly by both live UI state and persistence — no separate UI-facing/persisted structs translated by hand.
_Avoid_: Output, port

**Muted (channel default)**:
Every channel's mute state defaults to muted — including channel 1 — on app launch and whenever the output device is switched. Nothing plays until the user explicitly unmutes the channel(s) they intend to test.
_Avoid_: Default-on, armed

**Click (signal)**:
The Click generator's output: a short positive-going pulse repeated at the user's Interval, sent to every unmuted Channel at once, used to check inter-speaker delay alignment by ear (one tight click vs. a "flam"). Its Level is the pulse's peak, not RMS.
_Avoid_: "click" for the defect sense — an unwanted discontinuity in the output is a **click artifact** or **pop**
