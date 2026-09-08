# Base slots

```
Base slots        [ Standard  ▾ ]
```

| Option | Bones | Slots per weapon type |
|---|---|---|
| **Standard** (default) | the original `_sh` sheathing slots | 1 |
| **Alternative** | the `_Sem` slots from `semaroBones.nif` | 1 |
| **Combined** | both layers, Standard filled first | **2** |

## Combined

Standard is the first layer; the `_Sem` bones add **one extra slot per weapon
type** on top. Two different long blades show two swords — one where the engine
would sheathe it, one on the Sem rig. A third has nowhere to go.

Three deliberate limits:

- **No second shield, no second quiver.** Arrow and Bolt have no `_Sem`
  override, so `bonesForWeapon` returns a single candidate for them under every
  mode — the quiver cannot double even in principle. The shield is explicitly
  one bone per mode, and under Combined it uses the **Standard** bone, since a
  lone shield belongs on the layer the engine itself would use.
- **Player only.** An NPC asked for Combined gets Standard. Doubling every
  actor's attachments across a cell is precisely the cost this mod exists to
  avoid.
- **One attachment per distinct record.** The vfx tag is derived from the record
  id, and two attachments sharing a tag remove each other. Two of the *same*
  sword therefore fill one slot; two *different* swords fill both. Say if you
  want stacks to fill both slots — it needs per-copy tags, which is a small but
  real change.

## Standard is always the fallback

Checked per **bone**, not per actor. `bonesForWeapon` returns the fallback as a
later candidate and the caller tests each one against that actor's own skeleton
before taking it, so a skeleton carrying some `_Sem` bones and not others still
works — each type independently uses whichever layer it actually has.

This replaced a per-actor `hasBone` probe. The probe answered "does this actor
have the Sem rig", which is the wrong granularity: one missing bone made the
whole actor fall back, and a partially-merged skeleton silently showed nothing
for the types it did have. Attaching to a bone that is not there is a **silent**
no-show, so every candidate is verified before use. The check is memoized per
rebuild, since a lookup is real work and a mode can offer the same bone twice.

The shield does the same: if the Sem shield bone is missing, it falls back to
`Bip01 AttachShield` rather than not drawing.

## Interaction with the engine's own sheathing

An equipped, undrawn weapon is on the **Standard** bone, put there by OpenMW's
weapon sheathing. Only that bone is claimed — under Combined the Sem slot for
that type stays open and takes a carried weapon. Drawn, the standard bone frees
up again.

## Rebuild trigger

`baseSlots` is part of the change signature. Switching mode changes which bones
are used and how many attachments exist, but nothing about the inventory, so
without it the change would not appear until the player next picked something
up.

## Verification

| Sweep | Result |
|---|---|
| `luacheck.py` | 6 files, 0 failures |
| `check_names.py` | clean |
| `api_sweep.py` | nothing unrecognised |
| l10n keys used vs defined | 0 missing, 0 unused |
| `pcall` in `show-all-weapons/` | none |

`tools/test_ied.lua` — **21/21 pass**, eight new:

```
combined fills the standard slot AND the Sem slot
combined adds exactly one extra slot, not unlimited
combined does NOT add a second shield
combined puts the shield on the STANDARD bone
combined does NOT add a second quiver bone
combined is ignored on NPCs, which get standard
combined degrades to standard when the Sem bones are absent
an engine-sheathed weapon blocks only the standard slot
```

The mock counts every time two meshes land on one bone, and that counter is
asserted zero throughout — RESEARCH §4.1.

## A note on how this went

The first attempt at `bones.lua` edited an API that was no longer there:
`bonesForWeapon(weaponType, mode)` and `shieldBone(mode)` already existed in a
better form than the one being written, and the string replacements silently
matched nothing. The error surfaced only when the tests called
`shieldBoneFor`, which was never created.

Every replacement in the second pass asserts it matched before writing. That is
worth adding to RESEARCH: an unverified string replacement is the same class of
failure as an unverified `pcall` — it turns "this did not happen" into
"something else happened later, somewhere else".
