# AnimRefresh v3 — conflicts, cost, and the global-script question

## The log spam was IED's fault, not AnimRefresh's

```
[AnimRefresh] 'InventoryEquipmentDisplay' still not ready after 2 attempts;
giving up on this change
```

Twice per perspective change, forever. The service was behaving exactly as
designed; IED was lying to it.

`handler` returned `ready = false` whenever it wanted a bone and found none.
That conflates two different things:

| | retry helps? |
|---|---|
| the animation object is mid-rebuild | **yes** — this is what the protocol is for |
| the bone is not on this skeleton at all | **no** — it will never appear |

A player without the weapon-sheathing resource, or anyone hitting the known
missing `Bip01 SpearTwoWideSem`, is permanently in the second row. So every POV
press produced a retry, a second failure and a give-up line — and v3's
confirmation pass doubled it.

RESEARCH §1.8 already says it: *a missing bone is usually a missing skeleton,
not a race.* I wrote that and then built the opposite into the caller.

**Fix:** readiness is now judged on whether the skeleton answered *at all*.
`handler` tracks `anyBoneResolved`, set when any candidate — Sem, standard or
vanilla fallback — passes `hasBone`. If even one did, the skeleton is up and the
misses are configuration, so it reports ready. Only a skeleton where **nothing**
resolves is transient, and that is precisely the mid-rebuild state.

Two tests pin both directions:

```
a bone absent from a LIVE skeleton reports ready
a skeleton where NOTHING resolves reports not-ready
```

---

## Could it run as a global script instead?

**No, and not for performance reasons — the modules are not available there.**

```
openmw.camera is ['player'], file is global
openmw.input  is ['menu', 'player'], file is global
```

That is `ctxcheck.py` against the Cod3x 0.4 policy. A global script cannot call
`camera.getMode()` and cannot call `input.registerTriggerHandler`, so it can
neither poll the mode nor catch `TogglePOV`. Both detection paths are
player-only by construction.

A global script would also have to *receive* the mode from the player anyway,
which means the player script still polls and then pays an extra event per
change. Strictly worse.

`animation.hasBone` and `addVfx` additionally need a SelfObject, so the work the
subscribers do could not move either.

---

## Cost as it stands

| state | per update tick |
|---|---|
| no subscribers | one integer comparison, then `return` |
| subscribed, idle | `dt` accumulate + one compare; once per second, one `camera.getMode()` |
| on a change | one 0.10 s timer, one delivery, one 0.50 s confirm timer |

The 1 Hz poll only exists as a backstop for mode changes that arrive without a
keypress — vanity after idle, preview while held, another mod calling `setMode`.
The keypress path is a trigger handler and costs nothing until pressed.

There is nothing worth optimising here. The measurable cost in this mod is
IED's own 0.5 s inventory walk, not this.

---

## Conflicts

**Resolved this pass.** CAKE bundled its copy at `scripts/cake/AnimRefresh_v3.lua`
while IED and Take a Seat use `scripts/AnimRefresh/AnimRefresh_v3.lua`. Identical
content, two different VFS paths — so **both chunks load**, and the version
guard only makes the second one return early. That works, but which copy wins
depends on load order, and it is one more thing to reason about for no benefit.

CAKE now uses the shared path. Identical copies at one path collapse to a single
file in the VFS and load once.

The remaining rule stands: **rename the file on a version bump.** Two mods both
shipping `AnimRefresh_v2.lua` occupy one path, so whichever data directory wins
is the only file that exists — and if that is an older v2, the newer copy is not
present at all and the guard never runs.

Version state across the suite: IED v3, Take a Seat v3, CAKE v3. No v1 or v2
copies remain.
