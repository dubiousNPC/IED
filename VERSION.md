# IED v0.60

Inventory Equipment Display — carried weapons, shields and ammunition shown on
the body, using the same sheath bones as OpenMW's own weapon sheathing.

---

## What changed in this version

Every Lua file under `scripts/show-all-weapons/` is **byte-identical** to the
previous build. The changes are all assets, packaging and documentation.

| | |
|---|---|
| `animations/*/semaroBones.nif` | **Rewritten — see below.** All four folders, consistent with each other. |
| `animations/*/dubiousBones.nif` | **Removed** (4 files). Correct: it carried the DBS/CAKE bones and two Smokebones, none of which IED names. |
| `scripts/SuperSettingsRenderers/SuperSelect3.lua` | `---@omw-context menu` added. |
| `LICENSE`, `README.md`, `.gitignore`, `.gitattributes` | Added. |
| `tools/nifnodes.py` | Added. |

### The skeleton rewrite is the substantive change, and it is a fix

`semaroBones.nif` previously contained the **12 standard sheath bones** and
**none of the `...Sem` ones**. `bones.lua` has named the Sem bones since the
Base slots feature landed, so:

> **Alternative and Combined modes could never have worked in the shipped
> package.** Every Sem bone failed `hasBone`, so every weapon fell back to the
> standard slot, and the two non-default modes were silently identical to
> Standard.

This version replaces those 12 nodes with the 12 `...Sem` variants. Alternative
and Combined now have bones to attach to. All four skeletons (`xbase_anim`,
`.1st`, `_female`, `_animkna`) carry the same 47-node set, so the behaviour is
consistent across sexes and beast races.

---

## Two things to decide before release

### 1. `Bip01 SpearTwoWideSem` does not exist

`bones.lua:86` maps `SpearTwoWide` to it. Eleven of the twelve weapon types got
a Sem bone; spears did not. The consequence is not a crash — the candidate list
falls back to `Bip01 SpearTwoWide` — but under **Combined**, spears are the one
weapon type that gets no second slot, silently and for no stated reason.

Either add the node to all four skeletons, or drop the `SpearTwoWide` row from
`SEM_OVERRIDE` so the intent is explicit in code rather than implied by an
absent node.

### 2. Standard mode no longer ships its own bones

The 12 standard bones (`Bip01 LongBladeOneHand`, `Bip01 AttachShield`, …) were
removed along with the rename. Both the old and new files carry the embedded
source name `xbase_anim_sh.nif`, so those bones come from OpenMW's weapon
sheathing resource — which the previous package happened to bundle a copy of,
and this one does not.

For a user who already runs weapon sheathing, nothing changes. For one who does
not, **Standard — the default — now has no bones to attach to**, and the failure
is silent.

Two clean options:

- Restore the 12 standard nodes *alongside* the Sem ones, so the mod is
  self-sufficient again (59 Bip01 nodes rather than 47); or
- Declare weapon sheathing a hard requirement in the README, which is arguably
  honest anyway given what the mod does.

`tools/check_bones.py` was written for this and takes the engine-supplied names
via `--external`, so the distinction stays explicit rather than tribal:

```
python3 tools/check_bones.py . --external "Bip01 Ammo,Bip01 AttachWeapon,\
Bip01 AttachShield,Bip01 ShortBladeOneHand,Bip01 LongBladeOneHand,\
Bip01 LongBladeTwoClose,Bip01 BluntOneHand,Bip01 BluntTwoClose,\
Bip01 BluntTwoWide,Bip01 SpearTwoWide,Bip01 AxeTwoClose,Bip01 MarksmanBow,\
Bip01 MarksmanCrossbow,Bip01 MarksmanThrown"
```

---

## Stale documentation

`ASSESSMENT.md` refers to `dubiousBones.nif` in three places, including the
instructions for adding a new attachment point ("add the node to
`dubiousBones.nif` (all four folders)"). That file is no longer shipped, so the
instruction now points at nothing. Either restore the reference to
`semaroBones.nif` or note that the DBS rig moved to CAKE.

---

## Verification

Everything below was run against this package. Cod3x 0.4.

| Check | Result |
|---|---|
| `luacheck.py` — syntax | 8 files, **0 failures** |
| `globalcheck.py` — undeclared globals | **0** |
| `check_names.py` — undefined names, unused requires | **clean** |
| `api_sweep.py` — every `module.member` vs Cod3x 0.4 | **nothing unrecognised** |
| `ctxcheck.py` — `---@omw-context` vs the 0.4 policy | 8 files, **0 issues** |
| `check_manifest.py` — one path, one flag set | **0 mismatches** |
| l10n keys used vs defined | **0 missing, 0 unused** |
| `pcall` in `scripts/show-all-weapons/` | **none** |
| `tools/test_ied.lua` | **21/21 pass** |
| `check_bones.py` | **1 finding** — `Bip01 SpearTwoWideSem` |

The one `pcall` in the package is `AnimRefresh_v2.lua`'s subscriber-callback
isolation, which is the justified case (RESEARCH §2.3).

### Tools that were missing

`check_manifest.py`, `ctxcheck.py`, `globalcheck.py` and `sweep.py` were absent
from `tools/`. They are the four that catch, respectively: a fatal load error, a
context-annotation error, an undeclared global, and a dead setting. All four are
now included, along with the new `check_bones.py`.

---

## Modes

| Option | Bones | Slots per weapon type |
|---|---|---|
| **Standard** (default) | the original `_sh` sheathing slots | 1 |
| **Alternative** | the `_Sem` slots from `semaroBones.nif` | 1 |
| **Combined** | both layers, Standard filled first | 2 |

Combined is player-only, adds no second shield and no second quiver, and falls
back to Standard per bone where a Sem bone is absent. See `BASESLOTS.md`.
