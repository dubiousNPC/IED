# IED v0.61

---

## The bug: gear vanishes on 1st → 3rd and only returns when you draw

Two independent faults, both in `common.lua`. Neither is in `AnimRefresh_v2`,
which is correct as written.

### 1. IED bundles AnimRefresh v2 and does not use its protocol

v2's whole reason for existing is a readiness handshake. From its own header:

> A subscriber that returns exactly `false` is saying "the model was not ready,
> ask me again". This service cannot apply that guard itself — it has no idea
> which bone a subscriber cares about. So the test is inverted: the subscriber,
> which does know, reports readiness by return value and this schedules the
> retry.

IED's subscriber was:

```lua
I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
    forceRebuild = true
end)
```

It sets a flag and returns `nil`. `nil` means **delivered**. So:

1. POV pressed → AnimRefresh waits `SETTLE_DELAY` (0.10 s) → fires.
2. IED sets `forceRebuild` and returns nil. AnimRefresh counts it delivered and
   **never retries**.
3. On the next `onUpdate`, IED rebuilds. If the animation object is still being
   replaced, every `anim.hasBone` answers false, no candidate bone is `usable`,
   and nothing attaches — **silently**.
4. `rebuildNow` sets `forceRebuild = false` regardless. The failed attempt is
   final.
5. Nothing changes until the *signature* changes — which is what drawing a
   weapon does, via `isDrawn`.

That is the reported symptom, exactly.

**Fix:** the subscriber now rebuilds *in the callback* and returns the answer.
`handler` reports whether it wanted a bone and found none; `rebuildNow`
propagates it; returning `false` makes AnimRefresh retry once on a 0.1 s timer.

Deferring the work to the next tick threw the answer away. **A mod that bundles
a service should use the contract it ships.**

### 2. Two signature builders that could never agree

`rebuildNow` stored a signature built from inventory and stance alone.
The poll compared against one with the settings suffix appended:

```lua
.. tostring(cfgCache.showWeapons) .. tostring(cfgCache.showShields) ...
```

Different strings by construction, so every forced rebuild was followed by a
redundant one on the very next tick. Not the reported bug, but it doubled the
cost of the exact event this mod is most sensitive to.

**Fix:** one `currentSignature()` used by both paths. Two builders for one value
is a bug waiting for someone to edit one of them.

---

## Performance: the allocation point, applied

`The problem described.txt` makes a specific, checkable claim:

> Assume every field index on a userdata that returns something other than a
> function allocates — because it does. Cache your usertypes wherever possible.

IED was calling `types.Actor.inventory(actor)` **twice per cycle** — once in
`buildSignature`, once again inside `handler` — for a handle that is stable and
updates itself. On every poll, on every NPC in the cell.

RESEARCH §1.10 already says exactly this:

> `types.Actor.inventory(self)` — the handle is stable and self-updating; hoist
> it to script init rather than re-resolving.

Now resolved once in `makeUpdateHandler` and passed down. Three call sites
remain, all `inv or types.Actor.inventory(actor)` fallbacks for direct callers.

The rest of the hot path was already right, and worth not regressing: the
"nothing changed" path is a string compare against a cached signature, and
`buildSignature` deliberately reads `item.recordId` and `item.count` off the
object rather than doing a record lookup.

---

## Is H3lp Yours3lf viable as a dependency?

**Not as shipped, and the reason is packaging rather than design.**

The archive contains **no top-level `.omwscripts`**. The only manifest is
`examples/h3-fixtures.omwscripts`, which the documentation explicitly says is
opt-in probe scripts and *not* normal behaviour. `scripts/s3/lf.lua` ends with

```lua
interfaceName = 's3',
interface = { lf = instance },
```

so it must be registered as a PLAYER/LOCAL script for `I.s3.lf` to exist — and
nothing in the download registers it. Any mod depending on `I.s3.lf` would find
it nil. That is worth reporting upstream; it is not an argument about the design.

On the design itself, for **this** mod specifically:

| | |
|---|---|
| What s3lf solves | repeated userdata indexing, and `self.type.stats.dynamic.health(self)` ergonomics |
| What IED's hot path actually does | one cached string compare; a rebuild only on change |
| Overlap | small |

IED's per-poll cost after the hoist above is `getEquipment`, `getStance`, and two
`getAll` walks. `s3lf` would flatten the first two into cached fields, which is a
real but modest saving on a 0.5 s timer — and it would come at the cost of a hard
dependency on a mod that currently cannot register itself, in a mod whose whole
selling point is that it drops into an existing load order.

**Recommendation: no dependency. Steal the idea instead.** The finding worth
taking is the one in `The problem described.txt`, and it cost two lines to apply.
If H3 ships a working manifest and a version-guarded interface, `ProtectedTable`
is the piece worth revisiting — it would replace the MENU → PLAYER → GLOBAL →
NPC settings relay in `global.lua` with one construct. That relay is the ugliest
part of this mod.

Two caveats if that day comes: `ProtectedTable` is documented as unavailable in
MENU context, which is where IED's settings page lives; and it only works with
**global** setting groups, not player ones.

---

## RESEARCH.md compared against these findings

| Finding | RESEARCH says | Verdict |
|---|---|---|
| Re-resolving the inventory handle | §1.10 — hoist it | **Documented, and violated.** |
| Missing bone is a silent no-show | §3.2 | Documented and honoured — `usable()` checks first |
| Deferred refresh, `hasBone` guard, retry once | §1.8 | Documented as a *pattern*; the service implements it, the subscriber did not |
| **A subscriber must report readiness or the retry cannot happen** | **absent** | **Gap.** The v2 contract lives only in v2's own header. |
| **One value, one builder** | **absent** | **Gap.** Two signature builders is the same shape as §4.7's generated-file-fixed-by-hand. |

Both gaps are worth adding. The first is the more valuable: a service can only
honour a contract its subscribers implement, and the half that lives in the
caller is the half nobody reads.

---

## Verification

Cod3x 0.4.

| Check | Result |
|---|---|
| `luacheck.py` | 8 files, **0 failures** |
| `check_load.py` — chunk executes | 7 files, **0 failures** |
| `globalcheck.py` | **0** |
| `check_names.py` | **clean** |
| `api_sweep.py` vs Cod3x 0.4 | **nothing unrecognised** |
| `ctxcheck.py` | **0 issues** |
| `check_manifest.py` | **0 mismatches** |
| `tools/test_ied.lua` | **27/27** |

Six tests are new and reproduce the reported bug directly:

```
IED subscribes to AnimRefresh
gear shows normally
a rebuild into a half-built skeleton attaches nothing
and it tells AnimRefresh to ask again
the retry restores the gear
empty inventory reports ready, not a retry loop
```

That last one matters: an empty inventory must report **ready**, or the retry
becomes a loop that fires on every perspective change for a player carrying
nothing.

### `check_load.py` needed three fixes to run here

`SuperSelect3.lua` exposed gaps in the stub: `scripts.omw.*` are engine-shipped
scripts and must stub like `openmw.*`; chunk-level arithmetic on an engine
constant needs `__add`/`__mul` and friends. The third could not be fixed —
`("x"):gmatch(constant)` needs a real string and Lua will not coerce a table —
so vendored files can now be excluded by name with `--skip`, rather than by
loosening the stub until it stops catching real failures.
