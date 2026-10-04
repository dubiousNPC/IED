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


# Weapon settings

Settings → DED → **Weapons** has one row per weapon category, each with up to
four checkboxes:

| Checkbox | Effect |
|---|---|
| **Show** | Display carried weapons of this category at all. |
| **Secondary set** | Add a second slot on the `Ded` bones (`DedBones.nif`), so two *different* weapons of the category can show. |
| **Alternate** | Move the first slot from the standard sheath bone to the `Alt` bone (`xbase_anim_ded2.nif`). It moves the slot, it does not add one. |
| **NPCs** | Also show this category on NPCs. Only works while **NPCs display carried gear** is on. |

A category only offers the checkboxes it has bones for: spears have no Ded bone
(no secondary set), shields have no Alt bone (no alternate), and the quiver has
neither.

Defaults are the old "Standard" behaviour: every category shown, standard bones
only, on the player and NPCs.

## Standard is always the fallback

Checked per **bone**, not per actor. If Alternate is on but the actor's skeleton
lacks that Alt bone, the first slot falls back to the standard bone rather than
showing nothing. It falls back only when the Alt bone is *absent*, never when it
is merely taken, so Alternate can never add a slot.

## Interaction with the engine's own sheathing

An equipped, undrawn weapon is on the **standard** bone, put there by OpenMW's
weapon sheathing. That bone is claimed, so nothing stacks on it. With Secondary
set on, a carried weapon of the same category still shows on the Ded bone; with
Alternate on, it shows on the Alt bone. Shields work the same way: with an
equipped shield sheathed, a carried one can show on the Ded shield bone.

One attachment per distinct record: two of the *same* sword fill one slot, two
*different* swords fill both.

## Requirements

The Weapons rows use the multiCheckbox renderer from
[Bor's Drop-in Utils](https://github.com/OpenMW-Mod-Collection/DropinUtils),
bundled under `scripts/DropinUtils/` and registered ahead of the settings page
in `DED.omwscripts`.

## NPC display range

NPCs further than **NPC display range** (default 3072 units, about three
eighths of an exterior cell) show no carried gear and cost only a distance
check every 2 seconds. They keep their gear until 15% past the range, so
nothing flickers at the edge. Set it to 0 for no limit. The player is never
range-limited.

NPCs also check for gear changes at twice the player interval, each on its own
random phase, so a cell of NPCs activated together never polls in one frame.
