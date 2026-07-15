# All output channels default to muted, including channel 1

SoundCheck routes the active signal to every channel of the selected output device simultaneously, and level/frequency already have "sounds immediately" defaults (-20dBFS, 1000Hz). It would be easy to also default every channel to unmuted so the app "just plays" on launch. We decided against that: every channel — including channel 1 — defaults to muted on launch and on every device switch, so nothing plays until the user has explicitly unmuted the channel(s) they intend to test.

This is a deliberate safety-over-convenience trade-off: the app is used to drive real speakers, and an engineer plugging into an unfamiliar multichannel interface (8+ outputs is common) should never be surprised by sound coming out of a channel they didn't choose. The cost is a small extra click before first sound; the alternative risks driving unintended hardware or ears at an unknown level.
