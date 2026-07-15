# Custom AVAudioSourceNode render blocks, no third-party DSP library

SoundCheck's generators (sine, pink noise, white noise, later sweep/square/filtered noise) are implemented as hand-written `AVAudioSourceNode` render blocks rather than via a third-party audio library like AudioKit. The UI-locked behaviors — crossfade on signal switch, click-free start/stop ramp, per-channel mute/phase — need tight control over the render callback that a library's oscillator/graph abstractions would work against rather than for. The DSP itself is also simple enough (a sine and two noise generators, filters coming in V2) that it doesn't justify a dependency, and for a tool sound engineers trust to be precise, owning the signal path outright is worth more than the convenience a library would add.

This was a considered rejection, not an oversight: AudioKit was the specific alternative discussed and declined.
