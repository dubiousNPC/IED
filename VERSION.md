# IED v0.65

## AnimRefresh v3 -> v4

Bundled AnimRefresh is now `scripts/AnimRefresh/AnimRefresh_v4.lua`, rewritten
after a review by the author of Sun's Dusk. It fires once per real model
rebuild instead of four times per POV press, stops firing at all for
vanity/preview (which rebuild nothing), and now covers the two causes v3
missed entirely: **Rest/Travel/Training/Jail** and **loading a save**. The
manifest line changed with the filename.

This mod subscribes with `{ verify = true }`: its re-attach is
`removeVfx` + `addVfx`, so the second delivery that covers a late rebuild
is invisible here. `tools/test_povrefresh.lua` drives the real v4 and still
recovers gear from a rebuild that completes 0.8s after the switch.

Full reasoning, measurements and the subscriber contract: `ANIMREFRESH_V4.md`.
Tested by `tools/test_animrefresh.lua` (19 checks) plus this mod's own suite.

---

# IED v0.62

---

## The bug was in AnimRefresh, not in IED

My last fix was a real improvement and did not address this. Here is what
actually happens.

`scheduleRefresh` fires off the TogglePOV **key press**. v2's settle timer then
did this, 0.10 s later:

```lua
async:newUnsavableSimulationTimer(SETTLE_DELAY, function()
    local mode = camera.getMode()
    lastMode = mode              -- <-- re-baselines here
    fire(mode, previous)
end)
```

If the engine completes its model rebuild *after* that moment, it drops every
attached VFX — and by then:

- the trigger path has already fired and will not fire again, and
- `checkMode` compares `getMode()` against a `lastMode` that is **already** the
  new mode, sees no change, and never fires either.

**The trigger path consumed the transition the poll would otherwise have
caught.** Nothing asks again, so the gear stays gone until something unrelated
changes the signature — which is what drawing a weapon does.

The v2 retry could not help. Retry is keyed on a subscriber returning `false`
for "not ready", and the sheath bones exist throughout a perspective switch, so
IED correctly reported ready every time. **Readiness was the wrong question:**
the refresh did not land too early for the bones, it landed before the engine
had finished throwing the attachments away.

### The fix, in AnimRefresh v3

- **`lastMode` is owned by `checkMode` alone.** The trigger schedules a delivery
  and does not touch the baseline, so the poll still observes the real
  transition and fires on it.
- **Every delivery is followed by a confirmation pass** 0.5 s later. One fixed
  settle delay is a guess; a second delivery costs one timer on an event that
  happens a few times an hour and covers a rebuild that finished late.

There is no "my VFX was removed" event to hook, so a subscriber cannot notice
the loss itself. Delivering twice is the only cover available.

Verified against a rebuild completing at 0.30 s (inside the confirm window, the
confirm pass recovers it) and at 0.80 s (outside it, the poll path recovers it,
because the baseline is no longer poisoned). Both previously stayed broken for
the full 3 s of the test and only recovered on a stance change.

### The file is renamed to `AnimRefresh_v3.lua`

Not cosmetic. The version guard only helps when two copies load as two
different scripts. Two mods both shipping `AnimRefresh_v2.lua` occupy **one VFS
path**, so whichever data directory wins is the only file that exists — and if
that is somebody's older v2, this v3 is not present at all and the guard never
runs. Renaming on a version bump is what lets the guard work.

**`Take a Seat` and the Sun's Dusk `Scarves` module both bundle
`AnimRefresh_v2.lua` and have this same bug.** They should take v3.

---

## Why the earlier test passed a broken mod

The previous suite mocked `I.AnimRefresh` and asserted IED's callback returned
`false` when bones were missing. That tested IED's half in isolation, against a
service that did not exist. The real service was losing the change before the
callback was ever reached a second time.

RESEARCH §4.6 says a mock must exercise the path the engine takes. A mocked
*service* is the same mistake one level up: it verified the contract as I had
written it down rather than as the shipped code implemented it.

`tools/test_povrefresh.lua` now loads the **real** `AnimRefresh_v3.lua` and the
**real** `common.lua`, wires them through a live interfaces table, and drives a
POV press against a simulated timer queue with the engine wiping VFX at a
configurable moment. It fails on v2 and passes on v3.

---

## Kept from v0.61

Both changes stand and neither was wasted:

- **The readiness protocol.** Not the cause here, but correct: it covers the
  case where the bones genuinely are not present yet, which is what Sun's Dusk
  guards with `hasBone`.
- **One signature builder.** `rebuildNow` and the poll built different strings,
  so every forced rebuild was followed by a redundant one.
- **The inventory handle is hoisted**, per the allocation point in
  `The problem described.txt` and RESEARCH §1.10.

---

## Verification

| Check | Result |
|---|---|
| `luacheck.py` | 8 files, **0 failures** |
| `check_load.py` | 7 files, **0 failures** |
| `check_manifest.py` | **0 mismatches** |
| `globalcheck.py` / `check_names.py` / `api_sweep.py` / `ctxcheck.py` | clean |
| `tools/test_ied.lua` | **27/27** |
| `tools/test_povrefresh.lua` | **passes** (fails on v2) |
