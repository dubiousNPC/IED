# InventoryEquipmentDisplay — assessment

Three questions: extra bones at offsets, whether settings are viable, and a bug
sweep with weapon-sheathing clashes in particular. Short answers: the offset
technique already works and is demonstrated in your own files; settings are
viable but cost two new script contexts; and there were **two real clashes with
OpenMW's native sheathing**, both now fixed and covered by tests.

---

## 1. Extra bones at offsets

The two NIFs the mod ships are doing different jobs, and it is worth being
explicit about which is which.

**`semaroBones.nif` — 59 nodes, identical node *names* to a stock skeleton.**
Byte-diffing it against your three `xbase_anim_bk/ey/nk.nif` examples gives
1,630 differing bytes across a range that is all transform data, with no name
changes at all. That is the offset technique: same bones, moved. It re-places
`Bip01 LongBladeOneHand`, `Bip01 AttachShield` and the rest so sheathed gear
hangs where you want it.

**`dubiousBones.nif` — 127 nodes, a full skeleton with new bones added.** It
carries the whole DBS set (`beltDBS`, `L/R hipDBS`, `chestDBS`, `backpackDBS`,
`capeDBS`, `mouthDBS`, `eyesDBS`, `earsDBS`, `hornsDBS`, `scarfDBS`,
`pendantDBS`) plus two that are new here: **`Bip01 R Smokebone`** and
**`Bip01 L Smokebone`**. That is the "add an attachment point" technique.

Note for the CAKE work: `dubiousBones.nif` still has **no tail bone**, and it is
not in `xbase_animkna` either — the `animations/xbase_animkna/` copy shipped
here is the same file, so the beast skeleton gains no tail bone from it.

### Your three example files are byte-identical

`xbase_anim_bk.nif`, `_ey.nif` and `_nk.nif` have the same MD5. They are three
copies of an unmodified template, presumably named for back / eyes / neck and
awaiting their offsets. Nothing is wrong with that — just flagging it in case
you expected three different transform sets and one overwrote the others.

### The layout is right

```
animations/xbase_anim/       animations/xbase_anim.1st/
animations/xbase_anim_female/ animations/xbase_animkna/
```

All four variants are present, which is what OpenMW needs: base, first-person,
female and beast. Additive skeletons in these folders are merged with
`use additional anim sources`, and the mod correctly guards every attachment
with `anim.hasBone` so a missing bone is a silent skip rather than a broken
mod.

**Adding a new attachment point is a NIF edit plus one line of Lua.** Add the
node to `dubiousBones.nif` (all four folders), then a `BONE_BY_TYPE` row or a
`M.<NAME>_BONE` constant in `bones.lua`. Nothing else needs touching:
`attachVfx` already checks the bone exists first.

---

## 2. Weapon sheathing clashes — two real ones, both fixed

This is the important part. IED attaches to **exactly the bones OpenMW's own
weapon sheathing uses** — `Bip01 LongBladeOneHand`, `Bip01 AttachShield` and so
on. That overlap is intentional and correct, but it means the engine and the
mod can both put a mesh on the same bone.

### Clash A — occupancy was tracked by weapon type, not by bone

`bones.lua` maps two weapon types onto one bone, deliberately:

```
Bip01 LongBladeOneHand  <-  LongBladeOneHand, AxeOneHand
Bip01 Ammo              <-  Arrow, Bolt
```

but `handler()` deduplicated with `slotTaken[rec.type]`. So:

> Equip a longsword and leave it sheathed. The engine draws it on
> `Bip01 LongBladeOneHand`. Carry an axe in your pack. `slotTaken[AxeOneHand]`
> is false, so IED attaches the axe to `Bip01 LongBladeOneHand` too — **two
> meshes in one spot, one of them the engine's.**

The same fault fires with no engine involvement at all: carry a longsword *and*
an axe, equip neither, and both land on the same bone.

**Fix:** occupancy is now keyed by resolved bone name, and `bones.lua` grows a
`sharedBones()` helper that computes the shared set from `BONE_BY_TYPE` rather
than restating it, so editing the map cannot leave a stale list behind.

### Clash B — an equipped shield is drawn by the engine, and IED added another

The equipped shield was excluded only by record id (`rid ~= equippedShieldId`).
Carry two *different* shields with one equipped and the other goes onto
`Bip01 AttachShield` — the same bone the engine has already put the equipped
one on.

**Fix:** if a shield is equipped and the actor is not in weapon stance, the bone
belongs to the engine and IED yields it entirely. Once drawn, the shield moves
to the arm and IED may use the back again.

### The equipped weapon is now stance-aware

Previously the equipped weapon's slot was claimed unconditionally. It is now
claimed only while **not drawn**, which is when the engine actually occupies the
sheath bone. Draw your sword and the freed bone becomes available to a carried
weapon of that type — a small feature that falls out of modelling the clash
correctly.

### One thing that was already right

`addVfx`'s `vfxId` is documented as the handle the engine uses to add and remove
*magic effects*, with an explicit warning to use identifiers unrelated to magic
effect ids. IED's `saw_w_<recordId>` / `saw_sh_<n>` / `saw_ammo_<type>_<n>` tags
are safely namespaced. Worth not breaking.

---

## 3. Other findings from the sweep

| Severity | Finding |
|---|---|
| — | **No syntax errors.** All seven Lua files parse clean against liblua5.4, and a static undefined-name / unused-require pass is clean. |
| low | `buildSignature` walks **all** armour, not just shields, building a string from every cuirass and boot every poll. Cheap per item, but it is the "nothing changed" fast path, so it is the one place worth keeping tight. Left alone: filtering to shields needs a record lookup, which costs more than it saves. |
| low | `resolveMesh` lowercases paths. Harmless — OpenMW's VFS is case-insensitive and this is only ever fed back to `addVfx`. |
| low | `Bip01 Ammo` is not in any skeleton shipped here, so the quiver never appears without a third-party quiver skeleton. `attachVfx` returns false and the loop breaks on the first miss, so it costs one failed attempt, not twelve. |
| info | `activeTags` and the record caches are module-level, but each local script gets its own Lua environment, so they are per-actor already. The existing comment says this and is correct. |
| info | The `I.AnimRefresh` subscription key is a fixed string. Safe because `makeUpdateHandler` is called once per actor environment. |

### Verified against the Cod3x stubs

`Actor.getEquipment`, `Actor.getStance`, `Actor.STANCE`, `Actor.hasEquipped`,
`Actor.EQUIPMENT_SLOT`, `Inventory:countOf`, and the five documented `addVfx`
options are all real and used correctly.

---

## 4. Are optional settings viable?

**Yes, but the cost is structural, not incremental.** The mod is two LOCAL
scripts and nothing else, and **a local script running on an NPC cannot read a
player settings section.** So any setting that affects NPC display has to
travel:

```
MENU (declares)  ->  PLAYER (subscribes, pushes)
                       ->  GLOBAL (owns a writable global section)
                             ->  NPC (reads, read-only)
```

Adding settings therefore means adding a MENU script *and* a GLOBAL script. Not
difficult, but it doubles the script count, and it is the same detour CAKE uses
for its NPC toggle. Settings that only ever affect the player would not need it.

Implemented here, since it is a small amount of code once the shape is clear:

| Setting | Default | Notes |
|---|---|---|
| NPCs display carried gear | on | Strips immediately when turned off, rather than freezing current meshes |
| Show carried weapons | on | |
| Show carried shields | on | |
| Show quiver | on | Inert without an ammo-bone skeleton |
| Update interval | 0.5s | Exposed, but see below |

Two details worth keeping:

- **Absent config reads as enabled.** `cfg:get()` returns nil before the global
  section is seeded, and an NPC can become active in that window. `enabled()`
  tests `~= false`, so the permissive default wins.
- **Settings are folded into the change signature**, so toggling one rebuilds on
  the next poll without every context needing its own subscription.

The update-interval dial is honest but oversold: the poll is a string compare
against a cached signature and touches neither the record store nor the
filesystem. Raising it saves very little. It is exposed for very large load
orders, and the description says so.

---

## 5. Tests

`tools/test_ied.lua` mocks the OpenMW API and drives the real `handler()`,
asserting the clashes specifically — including a counter that fires whenever two
meshes land on one bone:

```
inventory axe does NOT stack on the engine-sheathed longsword
once the weapon is drawn the freed bone is reused
two carried weapons sharing a bone do not overlap
carried shield does NOT stack on the engine-sheathed one
with the shield drawn the back is free again
showWeapons=false hides carried weapons
absent config behaves as enabled, not disabled
```

9/9 pass. Run with `python3 tools/luarun.py tools/test_ied.lua`.
