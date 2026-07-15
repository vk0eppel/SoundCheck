# SoundCheck

A signal generator utility for sound engineers, techs, and hifi enthusiasts to test speakers and sound systems. Generates test signals only — never analyses or captures audio.

## Language

**Channel**:
One output of the currently selected Core Audio device, independent of the device's stereo/multichannel layout. The signal is routed to every channel of the device simultaneously; each channel has its own independent mute and phase-reverse state.
_Avoid_: Output, port

**Muted (channel default)**:
Every channel's mute state defaults to muted — including channel 1 — on app launch and whenever the output device is switched. Nothing plays until the user explicitly unmutes the channel(s) they intend to test.
_Avoid_: Default-on, armed
