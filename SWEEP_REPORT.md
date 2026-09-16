# Bug sweep — all live packages

Cod3x 0.4. Four packages: IED, Take a Seat, CAKE, Sun's Dusk Scarves.

---

## Regressions found

### 1. CAKE was still bundling AnimRefresh **v1**

| package | bundled | version |
|---|---|---|
| IED | `AnimRefresh_v3.lua` | 3 |
| Take a Seat | `AnimRefresh_v3.lua` | 3 |
| **CAKE** | **`AnimRefresh_v1.lua`** | **1** |
| Scarves | none | — |

v1 has both faults v3 fixes: the settle timer re-baselines `lastMode` so a late
model rebuild is never noticed again, *and* there is no readiness retry at all.
CAKE uses AnimRefresh to re-attach its worn VFX after a perspective switch —
the exact symptom reported against IED. It would have shown there eventually.

Upgraded to v3 and the manifest updated. Worth noting the version guard could
not have saved this: it only fires when two copies load, and CAKE's copy lived
at a different path (`scripts/cake/`) from IED's (`scripts/AnimRefresh/`), so
both would have registered and the older one might well have won on load order.

**Bundled-library version drift is not visible to any existing checker.** It was
found by grepping `MY_VERSION` across packages by hand.

### 2. `test_ied.lua` could not open its own input

```lua
local DIR='../scripts/show-all-weapons/'
```

Only resolves when run from `tools/`. Its neighbour `test_povrefresh.lua` uses
paths relative to the mod root, so the two test files in one directory needed
different working directories — and the one that was wrong failed by not opening
a file, which reads as a broken harness rather than a broken mod. Both now
resolve from the mod root.

---

## `pcall` removed from AnimRefresh

```lua
local ok, result = pcall(callback, mode, previous)   -- gone
...
local result = callback(mode, previous)
```

This was the case RESEARCH §2.3 names as justified — third-party callback
isolation — so the trade is worth stating once rather than buried:

**Lost.** One throwing subscriber no longer stops delivery to the others on that
refresh. That is a real cost and the reason to reverse this if it bites.

**Gained.** A broken subscriber becomes a stack trace naming the mod that broke,
on the first refresh, instead of a `print` nobody reads repeated a few times an
hour forever. The service fires a handful of times a session, and a subscriber
that throws is always a bug in that subscriber — never a supported state — so
there is nothing here for a guard to legitimately handle.

One compensating change, because removing the guard moves where errors surface:
**`subscribe` now validates the callback is a function.** Without it a non-function
subscriber raises from inside a timer, where the stack says "AnimRefresh" and not
which mod registered it. Checking at registration puts the error where the caller
can act on it.

### Live `pcall`s remaining

| where | verdict |
|---|---|
| `cake_player.lua` — `pcall(require, 'scripts.cake.cake_anim')` | **keep.** `cake_anim.lua` is documented deletable; `require` has no non-throwing form. |
| `SharedRay_v2.lua` — `pcall(callback, result)` | **same shape as the one just removed.** Not touched because it was not asked for, but the argument is identical and it is now the only callback-isolation `pcall` left. |
| `SuperSelect3.lua` | vendored third-party; not ours to edit. |

Nothing else. CAKE, Take a Seat and Scarves have zero in their own scripts.

---

## Toolchain gap closed

`check_load.py` reported **3 of 3 Scarves files failing** with
`attempt to index a nil value (global 'I')` and `concatenate a nil value
(global 'MODNAME')`. Both are Sun's Dusk environment globals the host injects
before requiring its modules — not bugs, and exactly the false-positive flood
`globalcheck.py` already had a preset for.

`check_load.py --preset sunsdusk` now predefines the same list. Verified in both
directions: Scarves goes to 0 failures, and a deliberately injected chunk-level
`[nil] = 1` is still caught. A preset naming exactly what the host provides is a
specification; one that silences everything is a suppression (RESEARCH §4.10).

---

## Results

| | IED | Take a Seat | CAKE | Scarves¹ |
|---|---|---|---|---|
| `luacheck.py` | 8 / 0 | 6 / 0 | 8 / 0 | 3 / 0 |
| `check_load.py` | 7 / 0 | 6 / 0 | 7 / 0 | 3 / 0 |
| `globalcheck.py` | 0 | 0 | 0 | 0 |
| `ctxcheck.py` | 0 | 0 | 0 | 0 |
| `check_manifest.py` | 0 | 0 | 0 | n/a² |
| behaviour tests | 27/27 + POV | — | 21/21 | 19/19 |

¹ with `--preset sunsdusk`. ² registers via `LUAL`, no manifest.

`check_anims.py` on Take a Seat: **0 groups unplayable**.
`check_bones.py` on IED: **1 outstanding** — `Bip01 SpearTwoWideSem`, already
documented in v0.60 and unchanged. Spears fall back to the standard slot, so
under Combined they are the one weapon type with no second slot.

---

## Two things the sweep could not check

- **Bundled shared-library versions.** No tool compares `MY_VERSION` across
  packages, which is how CAKE sat on v1. A checker that walks every bundled copy
  of a named library and reports the spread would have caught it in a second.
- **A callback contract.** Nothing verifies that a subscriber implements what a
  service's header asks of it. That gap is what let IED ship a subscriber
  ignoring the readiness protocol, and it is recorded as RESEARCH §4.7.
