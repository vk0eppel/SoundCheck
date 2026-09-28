# Signal type switch forces a full stop, not a crossfade

Originally decided (see prior "Decisions log" entry in `docs/spec.md`, now superseded): switching signal type while running would crossfade smoothly between the old and new generator. That was reversed during architecture design: changing signal type while running now forces a full stop to the OFF state — the user must press ON again to hear the newly selected signal.

Reason: safety and predictability. A live crossfade risks unwanted or unexpected noise during the transition, and this app exists specifically to drive real speakers under test — every sound it produces should follow a deliberate, unambiguous action rather than an automatic transition the user didn't explicitly trigger.

Consequence: the render graph doesn't need to mix between multiple simultaneously-live generator nodes — only one generator needs to be active at a time.
