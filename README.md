# DED
OpenMW Gearup style mod, display the extra weapons from your inventory. works for NPCs too

    Attaches inventory weapons and shields to their sheath bones as looping
    VFX, so carried gear is visible on the body.

    WHAT CHANGED FROM THE ORIGINAL
    ------------------------------
    * types.Actor.equipment does not exist -- the API is getEquipment. Because
      the call sat inside a pcall it failed silently, so equippedWeapon and
      equippedShield were ALWAYS nil and the equipped weapon/shield were never
      excluded from the display. They were being drawn twice.
    * The whole VFX set was torn down and rebuilt every 10 frames regardless of
      whether anything had changed, including a vfs.fileExists filesystem hit
      per weapon and a record() lookup per inventory item. Now a cheap
      signature is compared first and the rebuild is skipped when nothing moved.
    * That unconditional rebuild was accidentally load-bearing: switching
      perspective rebuilds the player's animation object and drops attached
      VFX, and rebuilding constantly happened to restore them within 10 frames.
      Skipping redundant rebuilds would have made gear vanish permanently on
      every POV switch, so AnimRefresh now forces a rebuild on that event. Same
      problem, and same fix, as Sun's Dusk uses for its backpack VFX.
    * Record and resolved-mesh lookups are memoized. Both are immutable per
      record id, so they only need computing once per session.
    * Polling is time-based rather than frame-count based; the old
      `frameCount % 10` ran ~14x/sec at 144fps and ~3x/sec at 30fps.
    * resolveMesh's if/else branches were character-for-character identical, so
      USE_SHEATH_MODEL was dead code. Removed.
    * addVfx was passed `tag` and `isMagic`, neither of which exist in the API.
    * Every shield in the inventory attached to the same bone, so three shields
      meant three overlapping meshes in one spot. Capped.
    * The ammo loop was unbounded and relied on a missing bone to stop it.


    # Base slots

```
Base slots        [ Standard  ▾ ]
```

| Option | Bones | Slots per weapon type |
|---|---|---|
| **Standard** (default) | the original `_sh` sheathing slots | 1 |
| **Alternative** | the `_Ded` slots from `DedBones.nif` | 1 |
| **Combined** | both layers, Standard filled first | **2** |

## Combined

Standard is the first layer; the `_Ded` bones add **one extra slot per weapon
type** on top. Two different long blades show two swords — one where the engine
would sheathe it, one on the Ded rig. A third has nowhere to go.

Three deliberate limits:

- **No second shield, no second quiver.** Arrow and Bolt have no `_Ded`
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
before taking it, so a skeleton carrying some `_Ded` bones and not others still
works — each type independently uses whichever layer it actually has.

This replaced a per-actor `hasBone` probe. The probe answered "does this actor
have the Ded rig", which is the wrong granularity: one missing bone made the
whole actor fall back, and a partially-merged skeleton silently showed nothing
for the types it did have. Attaching to a bone that is not there is a **silent**
no-show, so every candidate is verified before use. The check is memoized per
rebuild, since a lookup is real work and a mode can offer the same bone twice.

The shield does the same: if the Ded shield bone is missing, it falls back to
`Bip01 AttachShield` rather than not drawing.

## Interaction with the engine's own sheathing

An equipped, undrawn weapon is on the **Standard** bone, put there by OpenMW's
weapon sheathing. Only that bone is claimed — under Combined the Ded slot for
that type stays open and takes a carried weapon. Drawn, the standard bone frees
up again.

## NPC display range

NPCs further than **NPC display range** (default 3072 units, about three
eighths of an exterior cell) show no carried gear and cost only a distance
check every 2 seconds. They keep their gear until 15% past the range, so
nothing flickers at the edge. Set it to 0 for no limit. The player is never
range-limited.

NPCs also check for gear changes at twice the player interval, each on its own
random phase, so a cell of NPCs activated together never polls in one frame.
