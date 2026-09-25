# AnimRefresh v4

Rewritten after a review by the author of Sun's Dusk, whose `p_backpacks.lua`
is the implementation v1 was lifted from. Every claim below was reproduced
against the **real v3 file** in a simulated engine before anything was
changed, and re-measured after (`tools/test_animrefresh.lua`, 19 checks).

## Measured, v3 vs v4

| | v3 | v4 |
|---|---|---|
| callbacks for one POV press | **4** | 1 (2 if the subscriber opts into `verify`) |
| callbacks for idle → auto-vanity → back | **5** | **0** |
| refresh after Rest / Travel | **never** | yes |
| refresh after loading a save | **never** | yes |
| a mod unsubscribing mid-switch | **swallowed it for everyone** | no effect |
| a mod subscribing | nothing until the next switch | refreshed once |
| `camera.getMode()` reads per second (idle, subscribed) | 1 | 10 |

## What was wrong, and what v4 does

**It watched the wrong signal.** `camera.getMode()` has five values, but only
the first-person boundary rebuilds the model. ThirdPerson, Preview and Vanity
draw the same one. v3 fired on every hop between them, so auto-vanity after
~30s idle — a player sitting in a chair — restarted the sit pose from frame 0.
v4 tracks a boolean and fires only when it flips.

**The settle/confirm delays were guesses.** v3 scheduled delivery off the
TogglePOV key press, which fires *before* the mode changes, so `SETTLE_DELAY`
guessed how long the swap takes and `CONFIRM_DELAY` covered the first guess
being wrong. `camera.getQueuedMode()` returns the mode the camera is moving to
and nil once it has landed — a real signal. v4 fires when the boundary has
flipped and nothing is queued. The TogglePOV handler is gone; it existed to
beat a 1s poll, and the poll now runs at 0.1s, which is an enum read.

**It missed the two causes that actually bite.** Rest, Travel, Training and
Jail rebuild the model without touching the camera, and a game load rebuilds
everything while the service starts from scratch. `p_backpacks` handles both;
v3 handled neither. v4 has a `UiModeChanged` handler and an `onLoad` that
delivers twice (subscribers re-register in an order nothing controls).

**`subscribe()` and `unsubscribe()` re-baselined the mode**, so one mod
leaving mid-switch swallowed that transition for every other subscriber. v4
re-baselines only in the poll, with one deliberate exception: when the *first*
subscriber joins, since nobody else can be listening then. A new subscriber
gets one refresh of its own shortly after registering, which is what makes
"subscribe and forget" true after a load.

## Where v4 does not follow the review

The review says to drop the second delivery entirely. It is kept, but **opt-in
per subscriber**:

```lua
I.AnimRefresh.subscribe("MyMod", cb, { verify = true })
```

A rebuild can finish *after* the delivery and drop what was just attached, and
nothing can detect that: `openmw.animation` has `addVfx` and `removeVfx` and
nothing that reads back whether a VFX is still attached (the whole module was
checked). A second delivery is the only cover. Whether it is wanted depends
entirely on the payload, which is knowledge the subscriber has and the service
does not — the same reasoning as the existing readiness protocol:

- CAKE, IED and Bardcraft pass `verify = true`. Re-attaching is
  `removeVfx` + `addVfx`, so a second call is invisible.
- Take a Seat does **not**. It re-issues a looping pose, and a second call
  restarts it where the player can see it.

IED's own test covers this: an engine that finishes the rebuild 0.8s after the
switch loses the gear without the verify pass and keeps it with one.

## The contract, for anyone writing a subscriber

- Callbacks must be **remove-then-add**. You can be called when nothing was
  lost — after a load, on subscribing, on a retry.
- Return `false` for a **transient** not-ready state and you are called again,
  up to twice. A bone your skeleton does not have is not transient.
- Pass `{ verify = true }` only if a second call is invisible.
- Never cache the interface. Call `I.AnimRefresh.subscribe(...)` each time: if
  an older bundled copy loaded first and was overridden, a cached
  `local AR = I.AnimRefresh` still points at the dead copy.

## Upgrading

The file is `scripts/AnimRefresh/AnimRefresh_v4.lua` and the manifest line
changes with it. A v3 subscriber keeps working unchanged — same callback
signature, same readiness protocol — it simply gets no verify pass until it
asks for one.
