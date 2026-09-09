# OpenMW Lua — accrued research

Written for agents making changes to this mod suite. Everything here was found
by reading, instrumenting or breaking real code: Bardcraft, Sun's Dusk,
Fashionwind, OMWFW, InventoryEquipmentDisplay and CAKE. Where a rule has a
counter-example, the counter-example is named.

Two things dominate: **per-frame work** and **`pcall`**. They are related. Bad
polling wastes frames you can measure; `pcall` hides the bugs you cannot.

---

# Part 1 — Per-frame work

## 1.1 The measured cost

Fashionwind's bug report is the only hard field data in this suite, and it is
worth quoting because it sets the scale:

> 7 NPC scripts have `onUpdate` on every active NPC... One cosmetic mod having
> 7 scripts cranking out constant 1k ops/s in just Pelagiad is really bad. In
> Narsis it's 5-6k ops/s per script.

Seven near-identical scripts, each walking every active NPC's inventory every
20 frames. The fix is not "poll less often". It is **one script instead of
seven**, and then **no polling at all**.

## 1.2 `onFrame` vs `onUpdate` — not interchangeable

| | runs while paused | use it for |
|---|---|---|
| `onFrame` | **yes** | work that must continue during a menu, and nothing else |
| `onUpdate` | no | all gameplay work |

Almost everything in a cosmetic or animation mod wants `onUpdate`. You cannot
change perspective from a menu, so a camera-mode check in `onFrame` is running
during menus purely to observe that nothing happened.

Bardcraft polled `camera.getMode()` in `onFrame`, unconditionally, for the
whole session:

```lua
onFrame = function(dt)
    local camMode = camera.getMode()
    if camMode ~= lastCameraMode then ... end
```

At 144 fps that is ~144 calls a second, forever, to catch an event that happens
a handful of times an hour — and it ran whether or not anything was attached.

## 1.3 The escalation ladder

Take the highest rung that works. Do not start at the bottom.

1. **Engine event.** `onActive`, `onInactive`, `UiModeChanged`, `onSave`/`onLoad`,
   `I.ItemUsage` handlers. Zero cost when nothing happens.
2. **Trigger handler.** `input.registerTriggerHandler("TogglePOV", ...)`.
   Instant, and not reached unless the key is pressed. Register defensively —
   trigger keys come from built-in scripts and a stripped setup may lack them:
   ```lua
   if input.triggers and input.triggers.TogglePOV then
   ```
3. **Storage subscription.** `settings:subscribe(async:callback(fn))`. Fires on
   change only.
4. **Interface subscription.** Publish an interface others subscribe to, and
   **hold the subscription only while it is needed** (§1.5).
5. **One-shot timer.** `async:newUnsavableSimulationTimer(delay, fn)` for a
   deferred settle. `time.runRepeatedly` for genuine periodic work.
6. **Throttled `onUpdate` with a cheap change signature** (§1.6).
7. **`onFrame`.** Only for work that must survive a pause.

## 1.4 Event-first, poll-as-backstop

Some state changes arrive without an event. Camera mode is the canonical case:
`TogglePOV` covers deliberate presses, but vanity mode after idle, preview mode
while a key is held, and another mod calling `setMode` do not fire it.

`AnimRefresh` is the pattern: trigger handler for the case the player notices,
plus a **1 s** poll as a backstop for the cases they did not ask for. One second
of latency is acceptable precisely because those changes were not requested.

Never let the backstop become the mechanism. If the poll is doing all the work,
the event hookup is broken.

## 1.5 Subscribe only while active

The single highest-leverage rule. A mod that costs nothing when idle is a mod
nobody profiles.

```lua
local function syncSubscription(want)
    if want == subscribed then return end
    if not (I.AnimRefresh and I.AnimRefresh.subscribe) then return end
    if want then I.AnimRefresh.subscribe('MyMod', cb)
    else I.AnimRefresh.unsubscribe('MyMod') end
    subscribed = want
end
```

With no subscribers `AnimRefresh`'s `onUpdate` does one table-empty check and
returns, and its trigger handler is never reached. A player wearing nothing pays
essentially zero.

Call `sync` from every place the underlying state can change — in CAKE that is
`onActive`, the equip event, and `UiModeChanged`. A subscription that is never
released is just a poll with extra steps.

## 1.6 The change-signature pattern

When you genuinely must poll, make the "nothing changed" path free. From IED:

```lua
-- Deliberately avoids record() lookups: recordId and count are already on the
-- object, so the common path never touches the record store or the filesystem.
local function buildSignature(actor, equippedWeaponId, equippedShieldId, isDrawn)
```

Compare the string; rebuild only on difference. Two rules:

- **Never do a record lookup, VFS lookup or mesh resolution inside the
  signature.** That is the path taken every tick.
- **`getAll` ordering is not documented as stable.** If it ever varies, the
  signature differs and you do one redundant rebuild. Harmless — but do not
  build correctness on the order.

Fold settings into the signature rather than giving every context its own
subscription:

```lua
local signature = buildSignature(...) .. '|' .. tostring(cfg:get('showWeapons'))
```

## 1.7 Detecting rest, wait and travel

Bardcraft's trick, and the one most likely to be missed:

```lua
local currentTime = core.getGameTime()
if lastUpdate and currentTime - lastUpdate > 1 then
    self:setSheatheVfx()   -- rest / wait / fast travel all land here
end
```

Rest, wait and fast travel all appear as a discontinuity in game time. One test
covers all three without knowing which UI mode caused it. `UiModeChanged` on
`Rest`/`Travel`/`Training` covers the menus that rebuild the model **without**
advancing time. **Use both** — neither is a superset.

## 1.8 Deferred refresh after a model rebuild

Attaching to a skeleton that is about to be replaced attaches nothing. Both
prior mods defer, and Sun's Dusk's version is the better one:

| | defer | guard | retry |
|---|---|---|---|
| Bardcraft | 1 frame | none | no |
| Sun's Dusk | 0.1 s timer | `animation.hasBone` | once |

One frame is not always enough. Use the timer, guard with `hasBone`, retry
once, and **do not retry forever** — a missing bone is usually a missing
skeleton, not a race.

## 1.9 NPC scripts

- **One script for all categories.** Adding a slot must not add a script.
- **One inventory walk covering everything**, not one per category.
- `onActive` is normally sufficient. An NPC's inventory does not change while
  you are looking at it.
- If you must poll, `time.runRepeatedly` at ≥1 s, never a frame counter.
- **NPC local scripts cannot read a player settings section.** Route through a
  global section:
  `MENU declares → PLAYER subscribes and pushes → GLOBAL writes globalSection → NPC reads`.
  Absent config must read as *enabled*: an NPC can activate before the section
  is seeded, and defaulting to off looks like a broken mod.

## 1.10 Cheap wins, verified

- `item.recordId` — not a `getRecordId()` helper doing record lookups.
- `inv:find(id)` / `inv:countOf(id)` — engine-side, not a Lua `getAll` loop.
- `types.Actor.inventory(self)` — the handle is stable and self-updating; hoist
  it to script init rather than re-resolving.
- Memoize record and mesh lookups keyed by `recordId`. Cache the **miss** too
  (store `false`, distinguish from `nil`) or you re-derive it every pass.
- Cache a `hasBone` probe per animation-object lifetime, but invalidate it on
  anything that could rebuild the skeleton — and on a deliberate equip, which
  costs one probe on a keypress and stops a stale hit attaching to a bone that
  is no longer there.

## 1.11 "Per-frame" is a proxy for "too often relative to what changed"

CAKE has **no `onFrame` and no `onUpdate` of its own**. By §1.2's test it is
exemplary. It was also the most expensive mod in this suite.

`convertLooseInCell` walks every Miscellaneous object in the cell, then calls
`getAll` on every container in it — and it ran from the `Cake_Changed` handler,
which fires on **every equip and every unequip**.

| cell | `getAll` calls per toggle |
|---|---|
| 10 containers / 150 misc | 12 |
| 40 containers / 600 misc | 42 |
| 120 containers / 2000 misc | 122 |

Dressing up in a guild hall — twelve toggles — cost twelve full cell sweeps.

> Audit a handler by **how often it runs and how much it does**, not by which
> table it sits in. An expensive `onActive`, or an expensive equip handler, is
> the same bug wearing different clothes.

The trigger was also wrong on its own terms: equipping cannot strand a record,
because nothing left the inventory. Half the sweeps could never find anything.

## 1.12 An unconditional refresh can be load-bearing

The most dangerous entry here, because the fix looks obviously correct.

IED rebuilt its whole VFX set every 10 frames, unconditionally. §1.6's
change-signature is the textbook fix and cuts that to one rebuild in ten
seconds. Applying it **alone** would have made attached weapons vanish
permanently on every perspective switch.

Switching perspective rebuilds the player's animation object and drops attached
VFX. The unconditional rebuild was silently repairing that within 10 frames. Add
the early-out and the signature has not changed — so nothing rebuilds, ever
again, that session.

The rebuild was doing two jobs and only one was written down.

> Before making a refresh conditional, ask what else it was accidentally
> fixing. Attribute that, give it its own trigger (§1.8), *then* add the
> early-out.

## 1.13 A destructive call per frame is a compatibility problem, not a cost

ImmersiveBlink, per frame, per undead actor:

```lua
if mode == MODE_DISENGAGE or mode == MODE_NORMAL then
    stripAggro()          -- I.AI.removePackages('Combat') + ('Pursue')
end
```

`AI.removePackages` **deletes** packages; there is no suspend. `MODE_NORMAL` is
the baseline whenever the player stands in a tomb, so eight undead at 60fps is
~960 package removals a second.

The throughput is the smaller problem. `removePackages` does not care who
started the package, so it also deleted Combat and Pursue started by **other
mods**, or by vanilla AI reacting to an unrelated threat, within a frame of
appearing. Query first and it costs nothing in the common case:

```lua
local ok, target = pcall(I.AI.getActiveTarget, packageType)
if ok then hasPackage = target ~= nil end
if hasPackage then I.AI.removePackages(packageType) end
```

960 deletions/sec → **0**.

> Separate per-frame calls into **reads** and **writes**. A needless read wastes
> time. A needless *write* fights every other mod touching the same state, and
> the bug report will name their mod, not yours.

## 1.14 Not existing beats an early-out

§1.9 says one script for all categories. The stronger form is a script that
decides at **load** whether to exist:

```lua
if not (targets.isTargetActor(self) or targets.isTarget(rec)) then
    return {}
end
```

A `CREATURE:` script attaches to every creature. Returning an empty table means
a rat in a tomb carries **no handlers** — nothing scheduled, nothing to early-out
of, nothing to profile. WhyWalk reaches the same place from the other side:
`addScript` on mount, `removeScript` on dismount, so an unridden creature
carries nothing.

> Prefer, in order: refuse to load → `addScript` on demand → early-out.

---

# Part 2 — `pcall`

## 2.1 The rule

> **`pcall` is banned unless you are calling code you do not control, or
> failure is a supported state you have documented.**

Everywhere else it converts a diagnosable crash into an undiagnosable silence.
On a mod whose entire output is "a mesh appears", silence is indistinguishable
from working.

Audited across this suite: **21 `pcall`s found, 18 removed, 3 kept.**

## 2.2 The two bugs it actually hid

Not hypothetical. Both cost real time.

**CAKE — a whole session.** `cake_shared.lua` baked the plugin's raw `MODL`
string into the registry and handed it to `addVfx`:

```
plugin MODL     RV\Ashmask1.nif        <- raw, relative to meshes/
record.model    meshes/rv/ashmask1.nif <- VFS path, what the API wants
```

Different strings. `addVfx` got a path that does not exist. `pcall` swallowed
it. The item was consumed, the `_eq` record created, state set correctly — and
nothing appeared. The report was "the item does nothing when selected."

**IED — silently believed nothing was ever equipped.** The original called
`types.Actor.equipment`, a function that does not exist. The `pcall` around it
returned `false`, the code treated that as "no equipment", and the mod worked
just wrongly enough not to look broken.

Note the shape both share: **the pcall did not protect against a failure, it
manufactured a plausible-looking wrong answer.**

## 2.3 What justifies one

**Third-party callbacks.** You do not control subscriber code, and one
subscriber throwing must not stop delivery to the others:

```lua
for key, callback in pairs(subscribers) do
    local ok, err = pcall(callback, mode, previous)
    if not ok then
        print("[AnimRefresh] callback error in '" .. tostring(key) .. "': " .. tostring(err))
    end
end
```

Note it **prints the key**. A pcall that discards the error is not isolation,
it is concealment.

**An optional module.** `require` has no non-throwing form, and if the file is
documented as deletable then absence is a supported state:

```lua
local ok, mod = pcall(require, 'scripts.cake.cake_anim')
if not ok then print('[CAKE] cake_anim.lua not loadable; gestures disabled') end
```

That is the entire list.

## 2.4 What does not justify one

Every one of these was removed:

| Call | Why the pcall was wrong |
|---|---|
| `anim.addVfx` | Path and bone are validated immediately above. A failure means one of those checks is wrong. |
| `anim.removeVfx` | Removing an id that was never added is a no-op. |
| `anim.hasBone` | Documented for any actor; cannot throw on a valid one. |
| `anim.playBlended` / `anim.cancel` | Playing or cancelling a group the skeleton lacks is a no-op. |
| `inv:countOf` | Documented method on an inventory you just obtained. |
| `obj:getBoundingBox` | Documented `GameObject` method on an object you just enumerated. |
| `types.Weapon.record` / `types.Armor.record` | The caller already established the type via `getAll(types.X)` or `objectIsInstance`. |
| `types.Actor.getEquipment` / `getStance` | Documented, on a valid actor. |
| `storage.playerSection` | Available in its context and creates on demand. |

The recurring tell: **you are pcall-ing a documented API on an object you have
already validated.** If that can throw, your validation is the bug.

## 2.5 When you want a guard, not a pcall

A missing asset is a legitimate thing to handle — but *report* it:

```lua
elseif vfs.fileExists(path) then
    result = path
else
    print("[IED] mesh not in VFS, skipping: " .. tostring(path))
end
```

Checking and logging is not the same as swallowing. The distinction is whether
someone reading the log can tell what happened.

## 2.6 The benchmark: a comparable mod at zero

The strongest argument in this document is not an argument. It is a comparison.

| | lines | `pcall`s |
|---|---|---|
| **OpenMW Dynamic Animations** | 6,871 | **0** |
| NpcPersonality 0.1.5 | 10,176 | 141 |

Same domain — dynamic NPC animation, per-NPC scripts, heavy `openmw.animation`
use. Same engine, same APIs, comparable scale. One of them needs none.

That disposes of the usual defence. The wraps are not the price of working with
the animation API, because a mod doing the same work pays none of it. The count
is a **habit**, not a consequence.

> Density is itself a finding. Past a handful, `pcall` has stopped being a
> considered response to a documented risk and become the default way the
> codebase touches the engine — at which point every rule in this Part is
> already being broken, and the errors that would have told you so are gone.

Two shapes worth naming from that census:

- **101 of 144** in one mod were `pcall(function() ... end)` — not "this API
  might be absent" but an arbitrary block with every error inside swallowed.
  §2.1 cannot even be applied to it, because there is no single call to ask the
  question of.
- The rest included `pcall(camera.getPitch)`, `pcall(input.isKeyPressed)` and
  `pcall(core.getSimulationTime)` — **pure getters that cannot meaningfully
  fail**.

## 2.7 A `pcall`'d write whose caller records it as done

The consequence here is not a missed error. It is **your own state quietly
ceasing to match reality**, permanently, with nothing in any log.

Immersive Riding writes camera shake additively: read the current pitch,
subtract the contribution it made last frame to recover the base, add the new
one, remember it. Good technique — and it depends absolutely on knowing whether
the write landed. The same file implements it twice. First person:

```lua
if pcall(camera.setFirstPersonOffset, writtenOffset) then
    cameraMotionLastWrittenOffset = writtenOffset      -- recorded ONLY on success
end
```

Third person, twenty-four lines later:

```lua
pcall(camera.setPitch, basePitch3rd + pitchShake)
thirdPersonMotionPitch = pitchShake                   -- recorded regardless
```

If `setPitch` fails, the bookkeeping still says it applied. Next frame subtracts
a delta that was never there, so the base is wrong by that amount — and wrong
again next frame, compounding. Clearing the contribution then removes something
that does not exist, leaving the camera permanently rotated with no error and no
way to tell from outside whether the mod, another mod, or the engine did it.

The author knew the correct form. They wrote it, correctly, immediately above.

> If code after a `pcall` records, increments or caches as though the call
> succeeded, the wrap is not protecting you — it is manufacturing a divergence
> between what you believe and what happened. Gate the bookkeeping on the
> result, or do not wrap the call.

## 2.8 Fail toward the mod's intent

Every probe has a decision inside it that is usually made by accident: when the
probe itself fails, what do you assume?

```lua
local hasPackage = true   -- assume present if the query is unavailable
if I.AI.getActiveTarget then
    local ok, target = pcall(I.AI.getActiveTarget, packageType)
    if ok then hasPackage = target ~= nil end
end
```

Defaulting to `true` falls back to the old unconditional behaviour — the mod
keeps working. Defaulting to `false` would be the quieter code and would
silently disable the feature on any build where the query is missing.

> Write the failure default on the line above the probe, with the reason. A
> probe that defaults to "capability absent" turns an API gap into a silently
> disabled feature.

## 2.9 Removing one is a translation, not a deletion

The mechanical shape, so this can be done consistently. The `ok` guard folds
into the value test; `nil` still reads as false; only a genuine raise surfaces:

```lua
-- before                                    -- after
local ok, has = pcall(anim.hasGroup, self, name)
return ok and has == true                    return anim.hasGroup(self, name) == true

local okValid, valid = pcall(partner.isValid, partner)
if not okValid or valid ~= true then         if partner:isValid() ~= true then
```

Two traps found doing this at scale:

- **Mechanical residue.** `local ok = true` followed by `if not ok or ...`, or
  `local ok = yaw ~= nil` followed by a `type(yaw)` test that already subsumes
  it. These are dead guards that read like real ones, and they are exactly what
  gets "restored" to a `pcall` later. Fold them.
- **The behaviour change is the point.** Thirty functions in one mod changed on
  the failure path by design. Errors that were silently swallowed now surface.
  That is what the removal is *for*, and it is also what the first play session
  will reveal — so remove them when you can test, not on the way out the door.

---

# Part 3 — Bug catalogue

Every one of these was found in shipped code in this suite.

## 3.1 Paths and assets

| Bug | Detail |
|---|---|
| **Raw `MODL` vs VFS path** | Plugin `MODL` is relative to `meshes/` with original case and backslashes. `record.model` is a VFS path. Resolve from the record **at runtime**; never bake the plugin string into Lua. |
| **Sharing one mesh between world object and VFX** | Bardcraft states it outright: a mesh attached as VFX stops being interactable until restart. Sun's Dusk avoids it by convention — `_g` ground mesh on the base record, worn mesh on `_eq`. Treat "worn model ≠ ground model" as a requirement. |
| **Unchecked base mesh path** | Existence-checking only a `_sh`/`_eq` variant and returning the base path unchecked is one `pcall` away from silent failure. |
| **Preserving plugin fidelity in the wrong place** | Reproducing paths verbatim is right for the *plugin* and wrong for the *Lua registry*. Assert against the engine's expectations, not the plugin's. |

## 3.2 Animation API

| Bug | Detail |
|---|---|
| **`BONE_GROUP` ≠ `BLEND_MASK`** | `BONE_GROUP` is a sequential index (LowerBody 1, Torso 2, LeftArm 3, RightArm 4). `BLEND_MASK` is a bitmask (1, 2, 4, 8). Summing `BONE_GROUP` yields a valid but meaningless mask — Torso+LeftArm+RightArm = 9 = LowerBody+RightArm. `BLEND_MASK.UpperBody` (14) already means torso plus both arms. |
| **`PRIORITY.Scripted`** | Pauses every non-Scripted animation globally. Wrong for a short gesture — it freezes the walk cycle. Use `PRIORITY.Weapon` on an upper-body mask. |
| **Missing bone is silent** | Attaching to a bone that does not exist is a no-show, not an error. Always `hasBone` first, and always declare a vanilla fallback. |
| **`animation.cancel`** | Lives on `openmw.animation` and takes the actor. It is not on `I.AnimationController`. |
| **`types.Actor.equipment`** | Does not exist. It is `getEquipment`. |
| **KF text keys** | A group keyed `loop start`/`loop stop` will not answer to `start`/`stop`. Read the keys out of the binary; the resulting stuck or absent pose reads as a scripting bug when it is a naming one. |
| **`vfxId` and magic effects** | The engine uses `vfxId` to add and remove magic effects. The docs warn explicitly against ids that collide with `core.MagicEffectId` values. Namespace yours (`saw_w_<recordId>`, `cake_<category>`). |

## 3.3 Bones and slot arbitration

| Bug | Detail |
|---|---|
| **Occupancy keyed by type, not bone** | IED mapped `AxeOneHand` and `LongBladeOneHand` to one bone, and `Arrow`/`Bolt` to another, but deduplicated by weapon *type*. An equipped sheathed longsword plus a carried axe stacked two meshes on one bone. Key by **resolved bone name**, and compute the shared set from the map rather than restating it. |
| **The engine occupies the same bones** | OpenMW's native weapon sheathing puts the equipped-and-undrawn weapon and shield on the same bones a display mod uses. Claim the bone only while `not isDrawn`; drawn, it is free again. |
| **Excluding by record id, not occupancy** | Skipping "the equipped shield" by `recordId` still lets a *second, different* shield onto the bone the engine already filled. |
| **Arbitration that never arbitrates** | OMWFW's five head categories each wrote their "bone owner" lock to a *different* storage section, so every `xIsOurs()` was unconditionally true. Distinct `vfxId`s mean shared-bone categories do not evict each other anyway — declare explicit `conflicts` both ways and assert symmetry. |

## 3.4 State

| Bug | Detail |
|---|---|
| **Inferring worn state from inventory presence** | If "the `_eq` record is in your bag" *is* the test, then **looting one equals wearing it**. Keep explicit state set by activation; the inventory audits it, it does not define it. |
| **String surgery for id derivation** | `id:sub(1, -4)` and `id .. "_eq"` are right only if the id already carries the expected prefix. Use an explicit reverse index so a naming change fails loudly at generation time, not silently at runtime. |
| **Record ids are lowercase** | Comparisons against `item.recordId` must be lowercased. Half of one table's keys were capitalised and could never match. |
| **A refresh trigger that does not refresh** | Bardcraft's `UiModeChanged` called `verifySheathedInstrument()`, which returns a boolean and has no side effect. The documented refresh never happened. |

## 3.5 Plugin data

| Bug | Detail |
|---|---|
| **`_eq` applied to `FNAM` instead of `NAME`** | 320 records with 160 unique ids: two identical blocks differing only in display name. The second silently overwrote the first (TES3 is last-wins), leaving zero `_eq` records and every item named "…_eq". |
| **Ids from a different content set** | 50 ids in a script, **none** of which existed in any shipped plugin. Always cross-check the registry against the plugin binary. |
| **Undeclared masters** | Meshes from OAAB, Project Cyrodiil and others resolve fine for you and not for users. Declare the masters — do **not** "fix" it by editing or dropping the records; those paths are correct. |
| **Bodypart / item id collisions** | Reusing bodypart ids (`_RV_Ashmask1_H`) for wearable items works at the engine level but conflates the two everywhere else. A prefix resolves it. |

## 3.6 Structure

- **A `.omwscripts` is not the only way to register scripts.** A plugin can
  carry `LUAL` records that do the same job, and a mod using them ships no
  manifest at all — H3lp Yours3lf and T4rg3t5 both do. Each record is a `LUAS`
  script path plus a `LUAF` flag word: `0x01` GLOBAL, `0x04` PLAYER, `0x10`
  MENU, `0x00` LOCAL/CUSTOM.

  Two consequences. **Absence of a manifest is not absence of scripts** —
  concluding a mod "cannot register itself" from an empty zip listing is wrong,
  and that call was made here before checking the plugin. And a checker reading
  only `.omwscripts` reports *0 script(s)* for such a mod and passes, which is
  a checker going quiet rather than failing.

  A module's `---@omw-context` annotation and its registered contexts are also
  **different claims**. `protectedTable.lua` is annotated `local | player` but
  registered `0x04` (PLAYER), so `I.S3ProtectedTable` exists on the player and
  not on an NPC local script. Read the LUAL, not the annotation, when deciding
  whether an interface will be present.


- **Dead settings are worse than no settings** — they imply a feature exists.
  Cross-reference declared against read.
- **An empty category is a load failure waiting to happen** if anything
  validates its keys against it. Prune empties at generation time.
- **Registration must be idempotent.** `onInit` and `onLoad` both call it and
  only one runs on a given start.
- **Bundle shared libraries, do not copy them in.** Version-guard the file
  itself (`if I.X and I.X.version >= MY_VERSION then return end`) so only the
  newest loaded copy runs. `AnimRefresh`, `SharedRay`, `SuperSettingsRenderers`.

## 3.7 State machines and lifecycle

| Bug | Detail |
|---|---|
| **A state with only one exit, and that exit is an event** | HookShot's item drop: `setMode(FIRING)` was unconditional while the sequence that produces `ITEM_DROP_COMPLETE` was guarded by `if ragdoll then`. The menu closure holds the ragdoll table alive after `removeByTarget` compacts it out of the registry, so the sequence went onto an orphan, `update()` never walked it, and the event never came. The pose looped until reload. **Enter a state only when something can take you out of it**, and make the queueing call return whether it queued. |
| **A version guard of `>=` resolves ties by load order** | Two bundled copies both claiming `version = 1` means whichever loads first wins — so an improved v1 shipped next to somebody else's old v1 is a coin flip. Any change to a bundled service's behaviour must raise the number. CAKE shipped `AnimRefresh_v1.lua` and `v2.lua` in the same archive. |
| **A fix that lands on the wrong branch** | Work done on 0.1 was absent from 0.1.5, which forked earlier; FLOW's priority-tier and suspension-guard fixes were lost the same way in a partial merge. Verify a fix is present in the branch under active development, not just in the copy you edited. A hash comparison across every bundled copy takes seconds. |

## 3.8 Globals as a deliberate interface

Two mods here use the shared environment as an inter-module bus, and both look
like sloppiness until you read the other half.

- **dbsHUD.** `BSC_settings.lua` is `require`d into `BSC_p.lua`'s environment,
  writes changed values back with `_G[setting] = ...`, and calls
  `rebuildTiles()` / `createCompassHud()` by bare name. Localising those --
  which is what "fix the accidental globals" looks like -- does **not** error,
  because the call sites are guarded with `if fn then`. It silently turns every
  settings callback into a no-op.
- **Sun's Dusk addons.** `sd_p.lua` (PLAYER) and `sd_g.lua` (GLOBAL) walk their
  module directories with `vfs.pathsWithPrefix` and `require` what they find, so
  a module inherits the loader's context and reads `core`, `types`, `util`,
  `I`, `saveData` and the `G_*` job tables as globals the host assigned
  deliberately. Requiring them locally would work; the `G_*` scheduler tables
  have no local equivalent at all.

> Before localising an implicit global, find its readers. If another file reads
> it out of the shared environment, the global **is** the interface — document
> it and leave it. Note which names are host-provided so a static checker can
> be told (`--globals`), rather than silenced.

Context follows the loader, not the filename: a `*_settings.lua` under Sun's
Dusk is `global`, because `sd_g.lua` is the script that requires it.

---

# Part 4 — Verification

Tooling in `tools/`. No Lua interpreter is installed; `luacheck.py` and
`luarun.py` drive the system `liblua5.4.so.0` through ctypes.

| Tool | Catches |
|---|---|
| `luacheck.py` | Syntax. |
| `globalcheck.py` | **Reads of undeclared globals** — a class the others miss entirely (§4.4). |
| `ctxcheck.py` | `---@omw-context` legality, incl. per-member and per-interface scoping. |
| `check_names.py` | Undefined names, unused requires. |
| `api_sweep.py` | Every `module.member` call vs the Cod3x stubs. **Run this** — a misspelled API inside a pcall-wrapped call is §2.2 again. |
| `sweep.py` | Settings declared vs read, categories used vs defined, events sent vs handled, l10n keys, orphaned modules. |
| `check_load.py` | **Chunk-level runtime errors.** luacheck proves a file parses; this proves it LOADS. `[nil] = x` parses fine and takes the whole script down (§4.6). |
| `check_manifest.py` | One script path declared under two flags — fatal at load. Reads `.omwscripts` **and** `LUAL` records inside plugins (§3.6). |
| `check_bones.py` | Bone names in Lua vs node names in the shipped `.nif`s. |
| `check_anims.py` | Animation groups played vs text keys in the shipped `.kf`s, per skeleton folder. |
| `test_*.lua` | Mocked-API behaviour tests. |

## 4.1 A mock that accepts everything tests nothing

The single most important testing lesson here. CAKE's integration test passed
through the entire path-bug session because its mock returned `m/<id>.nif` for
`record.model` and its `addVfx` accepted any string.

Mocks must **assert the contract the engine enforces**:

```lua
addVfx = function(_, path, o)
    assert(path:sub(1,7)=='meshes/' and not path:find('\\',1,true),
           'addVfx got a non-VFS path: '..path)
    assert(world.files[path], 'addVfx got a path not in the VFS: '..path)
    if world.vfx[o.boneName] then world.doubled = (world.doubled or 0) + 1 end
    ...
```

That last line is the other half: a counter that trips whenever two meshes land
on one bone turns §3.3 into a test rather than a code review.

## 4.2 Assert the invariant that matters

Four assertions were once added guarding "the registry matches the plugin". It
did. The thing that had to match was **the engine**. Before writing an
assertion, ask which side actually enforces the constraint.

## 4.3 Generate, do not hand-maintain

Registries derived from plugin data should be generated by a script that
**asserts its own invariants** — every category bone exists in the skeleton,
every item resolves to a category, ids are lowercase, conflicts are symmetric.
A typo then fails at generation rather than silently in game.

## 4.4 An undeclared global is valid Lua, so nothing else catches it

FLOW v0.55 shipped `main.lua` requiring `openmw.self` as `self`, and one line
written in the siblings' idiom:

```lua
local isIdle = activeName == "Idle" and not mwSelf.controls.run
```

`mwSelf` was an undeclared global. Indexing nil raised **2,293 times in 79
seconds** — once per frame.

The severity is the lesson. The throw was near the top of `onUpdate`, so nothing
below it ran: the sensor, the ledge-hang extension, the state manager and the
debug HUD were all dead. Vault, mantle, shimmy and roll did nothing. But **init
logged normally** — twenty cheerful registration lines and zero runtime
activity. A mod can look like it loaded perfectly and be entirely non-functional.

Why every existing check passed it:

| tool | why |
|---|---|
| `luacheck` | an undeclared global is **valid Lua**; it parses |
| forward-reference sweep | it matched `name(` — a **call**. This is an **index** |
| `api_sweep` | it resolves `module.member` for names bound by a `require`; `mwSelf` is bound to nothing, so there is no module to check |

`globalcheck.py` closes it: track `local`, `local function`, multi-name locals,
parameters, numeric and generic `for`, method `self`, and Lua keywords, then
report any remaining bare name used as a value. It is deliberately
**scope-insensitive** — a name declared anywhere in the file counts as declared
everywhere — because a checker that cries wolf gets switched off.

## 4.5 Do not trust a new checker's first output

Every checker written here cried wolf before it was worth running. Recording the
failures, because they are what a heuristic costs:

- **Lua keywords.** The candidate pattern matched `not (`, `and (`, `return (`.
- **`package`, `M`.** `package` was missing from the builtin set; `M` is
  **injected on purpose** — `luarun.py` does `lua_setglobal(L, b'M')` before
  running the test harness. Neither was a mod bug. Hence `--globals` for
  host-injected names and skipping `tools/` by default.
- **Strings spanning newlines.** `[^"\\]` matches a newline, so one unbalanced
  quote swallowed **214 of 501 lines** — taking the `local function`
  declarations with it and leaving their call sites behind. The checker then
  reported eight declared functions as undeclared globals. A Lua short string
  cannot contain a raw newline; the class must exclude it. **The same bug was in
  `api_sweep.py` and `check_names.py`**, where it silently skipped whole regions
  rather than reporting them.
- **Table fields at column 0.** `key = 'General'` inside a multi-line table read
  as a root assignment until the scanner tracked brace depth.

> Run a new checker against a **known bug** to prove it fires, and against
> **known-good code** to prove it stays quiet. A checker only ever run on broken
> code is untested in the direction that matters.

And when a policy file it reads is restructured, the parser can start returning
**nothing** and pass everything silently. Print what was loaded — "25 modules,
44 scoped members" — so an empty result is distinguishable from a clean one.

---

## 4.6 luacheck proves a file parses, not that it loads

A chunk that parses cleanly can still raise the moment the engine runs it:

```lua
local T = SEAT_TYPE                          -- six fields, no THRONE
local SEAT_ANIM = { [T.THRONE] = "dbssit8" } -- table index is nil
```

OpenMW logs `Can't start L@0x1[...]`; the script never runs and the mod is inert
with no other symptom. That shipped past six checkers because **not one of them
ever ran the file**. `check_load.py` executes each chunk with the engine's
modules stubbed and reports what raises.

Building it taught three things about stubbing, each of which had to be fixed
before it was usable: the stub must be **comparable** (`version >= MY_VERSION`),
must return **nil for numeric keys** (or `ipairs` never terminates and the
checker hangs), and must let **project-local requires resolve for real** (or a
load error in a required module hides behind a require failure in its caller).
It stubs generously on purpose: a clean result proves little, a **failure is
always real**.

## 4.7 A service's contract has a half that lives in the caller

`AnimRefresh_v2`'s whole purpose is a handshake: a subscriber returning exactly
`false` means "the model was not ready, ask me again", and the service retries
once. IED bundles v2, and its subscriber set a flag and returned `nil` — which
means *delivered*. The retry could never fire, the rebuild landed in a
half-built skeleton, attached nothing silently, and cleared its own retry flag.

**The protocol was documented only in the service's own header.** The mod that
shipped the service was the mod that did not implement it.

When a service's contract requires something *of the caller*, that requirement
belongs in the caller's documentation too — and in a test that drives the
callback and asserts **its return value**, not merely that it was called.

## 4.8 One value, one builder

IED computed its change signature in two places: one included the settings
suffix, one did not, so they could never compare equal and every forced rebuild
was followed by a redundant one. Neither was wrong in isolation, which is what
makes the shape hard to see. Two sources for one value, nothing keeping them
honest. Build it once and call that.

---

# Part 5 — Checklist before changing anything here

1. Does this add an `onFrame` or `onUpdate` handler? Justify it against §1.3.
2. Does it poll anything a subscription or engine event would give you?
3. If it subscribes, is the subscription released when idle?
4. Are you adding a `pcall`? It needs to be third-party code or a documented
   optional. Otherwise remove it and let the error surface.
5. Are you passing a mesh path? Resolve it from the record at runtime.
6. Are you attaching to a bone? `hasBone` first, vanilla fallback declared.
7. Are you tracking occupancy? Key it by bone, not by type — and check whether
   the engine already owns that bone.
8. Are you inferring state from inventory presence? Don't.
9. Is this handler expensive *and* frequently triggered? Frequency is what
   matters, not which handler table it sits in (§1.11).
10. Is it a per-frame **write** to state the engine or another mod also owns?
    Query first; a needless write is a compatibility bug (§1.13).
11. Could this script decline to load at all for actors it does not care about
    (§1.14)?
12. Does anything after a `pcall` record, increment or cache as though the call
    succeeded (§2.7)?
13. Are you removing a `pcall`? Fold the `ok` guard into the value test, and
    delete the residue — `local ok = true` is a dead guard that reads like a
    real one (§2.9).
14. Are you localising an implicit global? Find its readers first; another file
    may be reading it out of the shared environment (§3.8).
15. Does your change land in the branch that is actually being developed? Hash
    every bundled copy of a shared service (§3.7).
16. Are you subscribing to a service? Read its header for a contract it
    expects of YOU — a return value, a key, an unsubscribe (§4.7).
17. Are you computing a value in two places? Build it once (§4.8).
18. Touching a `.omwscripts`? One path, one flag set. And check the plugin for
    `LUAL` records before concluding a mod registers nothing (§3.6).
19. Run `luacheck.py`, `check_load.py`, `globalcheck.py`, `ctxcheck.py`,
    `check_names.py`, `api_sweep.py`, `sweep.py`, `check_manifest.py` and the
    tests. All of them, not the first one. `check_load.py` is the one that
    catches a mod being inert.
20. If you added behaviour, does the mock enforce the engine's contract, and
    does it reach the code the way the engine does?
