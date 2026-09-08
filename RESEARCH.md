# OpenMW Lua — accrued research

Written for agents making changes to this mod suite. Everything here was found
by reading, instrumenting or breaking real code: Bardcraft, Sun's Dusk,
Fashionwind, OMWFW, InventoryEquipmentDisplay and CAKE, plus the riding stack —
WhyWalk, AnimatedCreatureRiding, Devilish Horse/Guar Riding — and two external
references read for comparison, Sturdy Steed (SimpleHorseRidingBase) and p37z.
A later pass added HookShot — a grapple mod with a teleport-driven pull, a
per-frame rope visual and a four-pose animation state machine — which is the
source for §1.15-§1.18, §2.11-§2.14 and §3.8.
A further pass added FLOW AMF — a parkour movement framework with a nine-state
machine, a shared raycast sensor and the same local/global teleport split as
HookShot — which is the source for §1.19-§1.21 and §2.15-§2.16.
A final pass swept four more: CAKE again (a cosmetic slot framework with no
per-frame handler of its own and the most expensive work in the suite),
take_a_seat with its experimental first-person body view, ImmersiveBlink (a
blink overlay plus a per-creature tomb-respect script) and a re-audit of
HookShot's animation fix. These are the source for §1.22-§1.26 and
§2.17-§2.18, and they shift the emphasis: the remaining costs in this suite are
no longer badly-placed `onUpdate` handlers but **expensive work on frequent
events**, and **writes** repeated where reads would do. Its material is
unusual in one respect: most of it was found by *causing* the bug during
development and reading the resulting log, so the failing line is quoted
verbatim where it exists.
Where a rule has a counter-example, the counter-example is named. One was
claimed against §3.2's `animation.cancel` rule and then **withdrawn on
re-audit** — the retraction is kept in §3.2 because how it failed is more
useful than the claim was.

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
3. **Key press/release handlers.** `onKeyPress` / `onKeyRelease` for held state
   (§1.12). Documented engine handlers for player local scripts; they are what
   `input.isKeyPressed` polling is usually standing in for.
4. **Storage subscription.** `settings:subscribe(async:callback(fn))`. Fires on
   change only.
5. **Interface subscription.** Publish an interface others subscribe to, and
   **hold the subscription only while it is needed** (§1.5).
6. **One-shot timer.** `async:newUnsavableSimulationTimer(delay, fn)` for a
   deferred settle. `time.runRepeatedly` for genuine periodic work.
7. **Throttled `onUpdate` with a cheap change signature** (§1.6).
8. **`onUpdate`, unthrottled.** Only when there is no event for what you are
   watching (§1.11) — and then with an early-out as the first line.
9. **`onFrame`.** Only for work that must survive a pause.

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
| AnimRefresh v1 | 0.1 s timer | none | **no** |
| AnimRefresh v2 | 0.1 s timer | subscriber returns `false` | once |

One frame is not always enough. Use the timer, guard with `hasBone`, retry
once, and **do not retry forever** — a missing bone is usually a missing
skeleton, not a race.

AnimRefresh v1 took the timer and dropped the other two, which is worse than it
sounds: it fires once and then re-baselines, so a subscriber that guessed wrong
never hears about that change again. Before extraction the consumers rebuilt
unconditionally and self-healed within 10 frames (§1.23); after it, a miss is
permanent. take_a_seat had to build its own re-apply schedule on top of the
service, which is the tell that the service was under-delivering.

A shared service cannot apply the `hasBone` guard — it does not know which bone
a subscriber cares about. v2 inverts it instead: **the subscriber returns
`false` to mean "not ready, ask again"**, and the service owns the retry and the
give-up log. The readiness test lives where the knowledge is; the scheduling
lives where it can be done once for everyone.

> A version guard of `>=` resolves two same-numbered copies **by load order**.
> Any change to delivery behaviour must raise the number, or an improved copy
> bundled next to somebody else's older one is a coin flip.

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
- `core.land.getHeightAt(pos, cell)` instead of a downward raycast for ground
  clamping. A direct heightmap query — no ray, no collision traversal — which
  matters when it runs every frame. From Rideable Silt Striders via WhyWalk.
  Exterior-only: guard with `cell.isExterior`, do not discover it by catching
  (§2.4).
- Derive per-object constants from `obj:getBoundingBox()` rather than
  hand-measuring one entry per record. p37z positions a rider as a *fraction*
  of the mount's own half-extents (`Offset:emul(halfSize)`), so one default
  covers every creature in the game; WhyWalk hand-tunes nine `saddle` entries
  and still has nothing for the tenth creature. Fewer entries is also fewer
  lookups.
- Let the engine's character controller drive where you can. Writing
  `controls.movement` / `sideMovement` / `yawChange` on a creature costs
  nothing per frame and gets gait animation, root motion, collision, gravity
  and pathing for free; integrating movement yourself and `teleport`-ing the
  mount every frame reimplements all five, badly. p37z versus WhyWalk. The
  trade is control: you lose exact speed and turn-radius tuning.

## 1.11 When per-frame really is irreducible

Not every `onUpdate` is a failure. **Nothing in the OpenMW Lua API parents one
object's transform to another**, so a mod that pins one object to another has to
place it every frame. There is no event for "the thing I am attached to moved".

WhyWalk states this plainly in its own header, and that is the right way to
handle it: name the irreducible cost, keep it to *one* handler, and put a single
early-out at the top so the not-mounted case is one comparison.

```lua
local function onUpdate(dt)
    if not session then return end   -- the whole cost when not riding
```

The test for whether yours qualifies: **is there an event that fires when the
thing you are watching changes?** Camera mode has one (`TogglePOV`) plus
backstop cases (§1.4). Another object's position does not. If an event exists
and you are polling anyway, you are on the wrong rung.

Two corollaries:

- The irreducible handler should do *only* the irreducible part. WhyWalk's
  `onUpdate` pins the rider; it does not also read keys, or check camera mode,
  or re-derive a mount profile. Everything separable moved to an event.
- Once one handler is per-frame, adding work to it is invisible in a profile
  but not free. Audit it as its own budget.

## 1.12 Held keys are events, not state to poll

The most common avoidable `onFrame` in this suite. Both Devilish riding mods
and Sturdy Steed poll `input.isKeyPressed(input.KEY.W)` every frame to answer a
question the engine already announced twice.

`onKeyPress` / `onKeyRelease` are documented engine handlers for player local
scripts. Track held state from the edges:

```lua
local heldForward = false
local function onKeyPress(key)   if key.symbol == 'w' then heldForward = true  end end
local function onKeyRelease(key) if key.symbol == 'w' then heldForward = false end end
```

Rewriting the riding animation controller this way removed its `onFrame`
outright and took it from ~390 lines to ~270 — the deleted bulk was a throttle
simulation that existed only to give the per-frame poll something to compare.

Three details that bite:

- **Modifier state is cheaper to read than to track.** Rather than matching
  Shift's own `key.symbol`, call `input.isShiftPressed()` at the moment a
  movement key event arrives. Every key event re-evaluates it, including
  Shift's own.
- **Seed once on entry.** A key already held when the state begins generated
  its press event before you were listening. One `isKeyPressed` snapshot on
  mount — not a poll — fixes it.
- **Press events are their own edge detector.** Jump needs no
  `lastJumpPressed` bookkeeping; `onKeyPress` for Space *is* the edge.

## 1.13 Send intent on change, not state every frame

A rider holding W across a valley should generate **one** event, not one per
frame. Both reference riding mods re-send identical control values 60 times a
second; WhyWalk sends on change and integrates movement from last-known intent
in the global script.

This is the event-side twin of §1.6's change signature: instead of making the
"nothing changed" path cheap, do not take the path at all. Where a signature
still costs a comparison per tick, intent events cost nothing between changes.

The MWScript bridge has a matching idiom worth stealing — p37z writes a value,
and the script **zeroes it after applying**:

```
if ( moveX != 0.0 )
    player->setpos x moveX
    set MoveX to 0.0
endif
```

Consume-on-use makes the pin idempotent, stops stale values re-applying, and
means "no fresh write" and "no work" are the same condition. Its one trap is
using `0` as the sentinel for a value that can legitimately *be* zero — p37z
gates rotation on `zRot != 0.0`, so a mount facing exactly north (yaw 0) never
rotates its rider (§3.7).

## 1.14 Handlers that are not rate-limited by the frame

A per-frame poll has an implicit ceiling: it cannot run more than once a frame,
so even a badly broken one degrades to "wasteful". **Event handlers have no such
ceiling**, and the failure mode is qualitatively worse.

`addAnimationEndedHandler` is the case in this suite. Re-issuing a pose from the
ended-handler is correct — it recovers from interruptions no `TogglePOV` hook
would catch. But if the group name is wrong or its text keys are missing, the
clip ends immediately, the handler re-issues, and that is a tight loop inside
one frame, not one iteration per frame.

AnimatedCreatureRiding burst-guards it: **five restarts in a second stops and
logs a hint.** Any self-re-triggering handler needs the equivalent. The guard is
also a diagnostic — tripping it means a bad group name, which is exactly the
silent-asset class of bug in §3.2.

The same reasoning applies to anything that re-enters its own trigger:
storage subscriptions that write the section they watch, interface callbacks
that re-publish, text-key handlers that replay their own group.

## 1.15 A local/global split must agree about pause

§1.2 frames `onFrame` vs `onUpdate` as a cost question. There is a second,
harder reason, and it is a **correctness** one.

`actor:teleport()` is global-context only, so any mod that moves the player by
position — a grapple pull, a ladder, a vault — ends up split: a player script
decides, a global script executes. HookShot and FLOW AMF both have this shape.

If the two halves disagree about pause, the mod breaks rather than merely
wasting frames:

| local driver | global backend | result while a menu is open |
|---|---|---|
| `onFrame` | `onUpdate` | local keeps integrating and sending; global is frozen. Requests queue or are dropped, and elapsed `dt` accumulates against a world that did not move. |
| `onUpdate` | `onUpdate` | both stop. Correct. |

FLOW AMF's movement states were converted `onFrame` → `onUpdate` for exactly
this reason, not for the frame cost. The rule:

> **Pick the handler to match the context that does the work, not the context
> that does the deciding.**

A corollary for `dt`. A driver that survives a pause its backend did not will
hand that backend a `deltaSeconds` covering the whole menu. Anything that
multiplies `dt` by a speed — a pull step, a climb step — teleports the actor
across the map on the resume frame. If you genuinely need `onFrame`, clamp `dt`.

## 1.16 Per-frame output to a consumer: gate it, and mind the expiry

A visual that tracks a moving thing looks like an irreducible per-frame publish
(§1.11). It usually is not. HookShot's rope has two endpoints that both move
every frame, and it still publishes at roughly 7 Hz standing still.

Two independent gates, and they interact:

```lua
local KEEPALIVE_INTERVAL = 0.15  -- must stay under the consumer's expiry
local MIN_MOVE = 2.0             -- game units before an early send

local due   = (now - lastSentAt) >= KEEPALIVE_INTERVAL
local moved = movedEnough(lastFrom, from) or movedEnough(lastTo, to)
if active and not due and not moved then return end
```

`MIN_MOVE` is the §1.6 change signature applied to cross-script traffic. The
`KEEPALIVE_INTERVAL` is the part that is easy to get wrong, because it is not a
property of the publisher at all — **it is a contract with the consumer's
lifetime**, and nothing in either file enforces it.

The consumer draws the rope as a self-expiring beam re-armed by each update:

```lua
local ROPE_DURATION = 0.40   -- keepalive 0.15 refreshes ~2.5x per lifetime
```

Invert that relationship and the rope strobes at the beat frequency between the
two constants — a bug that looks like a rendering fault and is arithmetic.
**Write the dependency in a comment on both sides.** They are in different
scripts and often different contexts, so nothing else will connect them.

The lifetime choice is worth stealing on its own. A persistent visual needs a
matching teardown call, and every path that can end the state — cancel, block,
cell change, `reloadlua`, an error before the teardown line — is a path that can
strand it in the world forever. A short self-expiring visual, re-armed while the
state holds, **cannot outlive its publisher**. It also removes the need for the
provider to expose a remove method at all.

## 1.17 A per-frame API call is only cheap because of its early-out

`Anim.updateHanging` runs every frame while hanging and calls straight into
`playBlendedAnimation`. That is fine — but only because of one line:

```lua
if currentGroup == group then return end   -- already playing this pose
```

Everything downstream is protected by that single comparison against a cached
name. Which means the cache is not an optimisation, it is **load-bearing**, and
its failure modes are per-frame ones:

- **Cache stale-high** (holds a pose that is no longer playing): every
  transition early-returns and nothing ever plays again. Structural hazard of
  the old ordering rather than a confirmed HookShot fault (§3.2) — but it costs
  nothing to order it away (§2.13).
- **Cache stale-low** (cleared while the pose still runs): the per-frame call
  re-issues the same group every frame. This is §1.14's failure mode reached
  from the polling side rather than the event side — an unbounded API storm
  where you thought you had a cheap poll.

So: any per-frame call whose cost depends on a cached comparison needs the cache
updated on **every** exit path from the code that owns it, including the failing
ones. Treat clearing it as the first statement, not the last (§2.13).

## 1.18 `self.controls` is reset every frame

Not a poll, but it forces a per-frame handler, so it belongs here.

Control fields written from a player script apply for **that frame only**. A
state that steers the player — HookShot's post-pull handoff window — has to
rewrite `movement`, `sideMovement` and `run` every frame for its whole duration.
Writing them once when the state begins does nothing visible.

`jump` is the exception, and inverted: it is an edge, so writing it every frame
re-jumps. Fire it once and clear your own flag.

```lua
if state.handoff.jumpPending then
    self.controls.jump = true
    state.handoff.jumpPending = false
end
```

This also constrains the design above it. **There is no Lua call to set an
actor's velocity**, so momentum cannot be handed from a teleport-driven sequence
to the engine directly — a pull that ends by teleporting arrives with zero
engine velocity. The only transfer available is to stop teleporting early and
drive `controls` (plus gravity) for a window, which is per-frame by
construction. Name that in the comment, or the next reader will try to delete
the handler.

---

## 1.19 A cancel-on-timeout is a second way the pause split breaks

§1.15 describes the local/global pause mismatch as requests queueing or being
dropped. FLOW AMF found a sharper failure of the same cause, worth naming
separately because the symptom points away from the handler entirely.

Its local state ran a duration timer purely as a **safety net**, to release
control if the global tween never reported completion:

```lua
if timeInState > estimatedDuration + COMPLETION_GRACE then
    core.sendGlobalEvent('FLOW_Vault_Cancel', { actor = mwSelf })
    return "Airborne"
end
```

With the local half on `onFrame` and the backend on `onUpdate`, pausing mid-move
froze the tween while the timer kept counting. The timeout then fired a *Cancel*
at a move that was merely suspended, deleting it before `progress >= 1.0` — so
the player never received the final teleport and the vault visibly stopped
short.

The tell is that this looks like a tuning problem. The grace constant was
widened twice before the cause was found, and no value could have worked: the
two halves were counting in different units, not merely drifting.

> **If a timeout on one side can destroy work owned by the other, the two sides
> must share a clock before the timeout is tuned.**

## 1.20 Migrating `onFrame` → `onUpdate` is a correctness fix, not a speed one

Worth stating plainly because the migration is easy to oversell, and FLOW was
sold it — by the agent doing the work — on the wrong grounds.

The `onUpdate` conversion was pitched partly as a performance win: menus,
inventory, dialogue and barter are a large share of playtime, and no raycast
needs to run during them. That is true, and it is not where FLOW's frames were
going. An audit of the same file found:

| Cost | Where | Per frame |
|---|---|---|
| `element:update()` — full UI layout rebuild | debug HUD, **unthrottled and hardcoded on** | 1 |
| String building for that HUD | `string.format` ×3 plus concatenation | ~6 allocations |
| `{ ignore = self.object }` rebuilt per cast | 7 raycast call sites | 7 tables |
| Offset lists rebuilt per call | 2 sites | 2 tables |
| `section:get()` — storage read | mod-enabled + interior checks | 2 |
| Smoothing buffer push + average | `EngineSync` | ~10 VM ops |

The debug HUD alone — a diagnostic, defaulted on, sitting *outside* the idle
throttle that the rest of the pipeline respected — outweighed everything the
handler change touched. The allocations were next. The smoothing buffer, which
was the thing suspected and asked about, was a rounding error.

> **Migrate for pause-correctness. Profile before claiming a frame cost, and
> check the diagnostics first — they are the code most likely to be running
> unthrottled, because nobody counts the cost of looking.**

A related trap in the same file: the idle throttle skipped sensor work while
standing still, but the HUD block sat after it and ran regardless. A throttle
only helps if the expensive thing is inside it.

## 1.21 A third-party producer on `onFrame` is usually not your problem

FLOW bundles SharedRay, a shared raycast utility that runs on `onFrame` and is
explicitly not to be modified. After converting everything else to `onUpdate`
the obvious worry is that the two now disagree about pause — the §1.15 failure.

They do not, because the relationship is **producer/consumer, not driver/executor**:

- SharedRay casts and publishes a result. It owns no state of yours.
- FLOW reads the latest published result whenever it next runs.

A consumer that stops for a menu simply picks up whatever is current on resume.
Nothing queues, nothing accumulates, no `dt` is multiplied. The cost is a small
amount of casting during pause, which belongs to the shared utility and is
amortised across every mod using it.

The distinction that matters:

> **Disagreeing about pause is only dangerous when one side is executing work
> the other is still accounting for.** Shared read-only publishers are exempt.


## 1.22 An expensive event handler is the same disease as a poll

CAKE has **no `onFrame` and no `onUpdate` of its own** — the only per-frame
handler in the package is AnimRefresh's, and that is subscriber-gated. By the
usual test it is exemplary. It was also, by some margin, the most expensive mod
in this suite.

`convertLooseInCell` walks every Miscellaneous object in the cell, then calls
`getAll` on every container in it. It was invoked from the `Cake_Changed`
handler — which fires on **every equip and every unequip**.

| cell | `getAll` calls per toggle |
|---|---|
| 10 containers / 150 misc | 12 |
| 40 containers / 600 misc | 42 |
| 120 containers / 2000 misc | 122 |

Dressing up in a guild hall — twelve toggles — cost twelve full cell sweeps.

> **"Per-frame" is a proxy for "too often relative to what actually changed".**
> An event handler that fires on a frequent event, doing work proportional to
> the cell rather than to the change, is the same bug wearing different
> clothes. Audit expensive handlers by *how often they run*, not by which
> handler table they sit in.

The trigger was also wrong on its own terms: equipping cannot strand a record,
because nothing left the inventory. Half the sweeps could never find anything.

## 1.23 An unconditional refresh can be load-bearing

The most dangerous trap in this document, because the fix looks obviously
correct and breaks something nobody wrote down.

IED rebuilt its whole VFX set every 10 frames, unconditionally. §1.6's
signature early-out is the textbook fix and cuts it to one rebuild in ten
seconds. Applying it alone would have made attached weapons **vanish
permanently on every perspective switch**.

Switching perspective rebuilds the player's animation object and drops attached
VFX. The unconditional rebuild was silently repairing that within 10 frames.
Add the early-out and the signature has not changed — so nothing rebuilds, ever
again, for that session.

The rebuild was doing two jobs and only one was documented.

> Before making a refresh conditional, ask what else it was accidentally
> fixing. Anything that reconstructs engine-side state on a timer is probably
> masking a loss you have not attributed yet. Attribute it first, give it its
> own trigger (§1.8), *then* add the early-out.

CAKE's sweep had the same shape at a deeper level: it was propping up a state
model that inferred worn-ness from inventory presence, so removing it exposed a
bug rather than an optimisation. See §3.4.

## 1.24 A destructive call per frame is a compatibility hazard, not a cost

ImmersiveBlink's creature script:

```lua
if mode == MODE_DISENGAGE or mode == MODE_NORMAL then
    stripAggro()          -- I.AI.removePackages('Combat') + ('Pursue')
end
```

`AI.removePackages` **deletes** packages; the API has no suspend equivalent.
`MODE_NORMAL` is the baseline state whenever the player is simply standing in a
tomb, so this ran unconditionally, per frame, per undead actor. Eight undead at
60fps is ~960 package removals a second.

The throughput is the smaller problem. `removePackages` does not care who
started the package, so for as long as the player stood in that tomb it also
deleted Combat and Pursue started by **anything else** — another mod's scripted
combat, or vanilla AI reacting to an unrelated threat — within a frame of it
appearing.

The fix is to query first, and it costs nothing in the common case:

```lua
local ok, target = pcall(I.AI.getActiveTarget, packageType)
if ok then hasPackage = target ~= nil end
if hasPackage then I.AI.removePackages(packageType) end
```

Steady state: 960 deletions/sec → **0**, replaced by two reads per actor per
frame.

> Separate per-frame calls into *reads* and *writes*. A read repeated
> needlessly wastes time. A **write** repeated needlessly fights every other
> mod that touches the same state, and the report you get will be about their
> mod, not yours.

## 1.25 Load-time scoping beats a handler early-out

§1.9 says one script for all categories. ImmersiveBlink demonstrates the
stronger form — the script decides at **load** whether to exist at all:

```lua
local rec = targets.norm(self.recordId)
if not (targets.isTargetActor(self) or targets.isTarget(rec) or targets.isTarget(self.recordId)) then
    return {}
end
```

A CREATURE script is attached to every creature. Returning an empty table means
a rat in a tomb carries **no handlers**, not a handler that returns early. There
is no `onUpdate` to schedule, nothing to early-out of, nothing to profile.

The same idea reached from the other direction: WhyWalk attaches its mount
script with `addScript` on mount and removes it on dismount, so an unridden
creature carries nothing. Two mechanisms, one rule.

> A cheap early-out still costs a scheduled call per actor per frame. Not
> existing costs nothing. Prefer refusing to load, then `addScript`, then an
> early-out — in that order.

## 1.26 Engine-owned state is re-derived every frame; setting it once is not enough

take_a_seat's first-person body view set `camera.MODE.Preview`, a distance and a
focal offset, and got ordinary third person with a mangled offset. Both symptoms
had the same cause: the **built-in camera script re-derives all of it every
frame**, so anything not explicitly stood down is overwritten.

Each piece needs disabling by tag, and they are separate:

| control | if left enabled |
|---|---|
| `disableModeControl` | resolves back to a PRIMARY mode — `getPrimaryMode` returns only FirstPerson or ThirdPerson, so Preview is transient and undone almost immediately |
| `disableThirdPersonOffsetControl` | re-derives the focal offset, discarding yours |
| `disableZoom` | moves the base distance out from under you |
| `disableStandingPreview` | swings into preview on its own when idle — exactly a seated player's state |
| `disableHeadBobbing` | built-in bob, very visible at distance 0 |

These toggles are **reference counted per tag**. Two features sharing one tag
means enabling one releases the other's hold.

There is a second, separate trap. **A mode transition is not atomic.** Entering
Preview re-derives the focal offset as it completes, landing *after* a
same-frame write and silently discarding it. The symptom is diagnostic: the
framing stuck when a settings slider was nudged (mode long settled) but reverted
on every fresh entry. Apply immediately *and* re-apply across the transition:

```lua
local REAPPLY_DELAYS = { 0.05, 0.15, 0.35 }   -- settle time is not documented
```

Guard the re-applies with a generation token so a pending one cannot stamp state
onto an actor that already left the mode. This is one-shot timers, not a poll —
§1.11's exemption does not need invoking.

---


# Part 2 — `pcall`

## 2.1 The rule

> **`pcall` is banned unless you are calling code you do not control, or
> failure is a supported state you have documented.**

Everywhere else it converts a diagnosable crash into an undiagnosable silence.
On a mod whose entire output is "a mesh appears", silence is indistinguishable
from working.

Audited across this suite: **21 `pcall`s found, 18 removed, 3 kept.**
A later sweep of the riding stack found **11 more, 9 removed, 2 kept** — the two
kept being the subscriber-callback isolation in `SharedRay` and `AnimRefresh`
(§2.3). A third sweep, of HookShot, found **39 more, 27 removed, 12 kept** —
every one of the 12 inside a vendored file (`beamfx_adapter.lua`,
`SharedRay_v2.lua`) and therefore §2.3's first category wholesale, not a new
justification. Running total: **71 found, 54 removed, 17 kept.** No sweep so far
has found a *third* category worth keeping.

The HookShot sweep is also the one where the removals were not a tidy-up: two of
them had already caused a shipped bug each, and one was written *during* the
debugging of the bug it went on to hide (§2.14).

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

That is the entire list — with one later addition, §2.16, for the case where a
failure removes the surface you would diagnose it from.

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
| `world.mwscript.getGlobalVariables` | Documented as returning `MWScriptVariables` with no failure path — it fetches Morrowind's own global table, which exists whether or not your ESP loaded. Wrapping it detects nothing (§2.7). |
| `core.land.getHeightAt` | Exterior-only, and `cell.isExterior` is a documented field. Check the condition, do not catch it. |
| `types.Actor.stats.dynamic.health` | On a mount whose `isValid()` passed four lines above and whose type was checked at mount time. |
| `obj:teleport` | Inside a block already guarded by `isValid()` on both objects. |
| `spells:add` / `spells:remove` | See §2.9 — the pcall was covering a placeholder record id, not a runtime failure. |
| `input.isKeyPressed` | Documented for a player local script. If the key enum resolves at all it resolves every time. |

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

## 2.6 The dominant anti-pattern: a static condition, tested at runtime frequency

**Eight of the nine `pcall`s removed from the riding stack shared one shape.**
It is worth naming because it is not obvious from any single site:

> The wrapped call fails for a reason that is fixed at load — and it is being
> re-tested every frame.

Whether the ESP is installed. Whether a spell record exists. Whether a creature
is an Actor. None of these change between frames. Each was wrapped in a `pcall`
that ran at the frequency of the *use*, not of the *condition*.

Three costs, in increasing order of seriousness:

1. Wasted work, forever.
2. The answer is recomputed but never reported, so nobody learns it.
3. The code reads as if failure were expected here, which is a lie about the
   system that the next reader has to disprove.

The fix is always the same shape — resolve once, cache the verdict as a
boolean, branch on it, and **say something when it is false**:

```lua
local bridge = nil
local function bridgeReady()
    if bridge ~= nil then return bridge end
    local g = world.mwscript.getGlobalVariables(world.players[1])
    local ok = pcall(function() return g[NAMES.active] end)
    bridge = ok and g or false
    if not bridge then
        print("[WhyWalk] MWScript bridge unavailable ('" .. NAMES.active
              .. "' not found) -- falling back to the teleport backend")
    end
    return bridge
end
```

One `pcall`, once per session, on the cheapest possible probe. Everything
downstream writes bare, because the probe already established that it can.

Ask of every `pcall`: **at what frequency does the thing it is testing actually
change?** If the answer is "never", it belongs at load, not in the hot path.

## 2.7 The probe that probes the wrong thing

A `pcall` around the wrong call is worse than none: it *looks* like the
capability is being detected, so nobody checks again.

WhyWalk wrapped `world.mwscript.getGlobalVariables(...)` to detect a missing
ESP. But that function returns Morrowind's own global variable table and is
documented with no failure path — it succeeds whether or not the mod's plugin
loaded. The real failure was one layer down, in `g[names.x] = pos.x`, indexing a
name the ESP never defined. So the guard that was supposed to detect "ESP
missing" detected nothing, and the actual failure was caught by a *different*
`pcall`, per frame, silently.

When you write a capability probe, state what specific operation is expected to
fail, and probe **that** — here, reading one of your own names, not fetching the
table that contains them.

## 2.8 Silent degradation is worse than silent failure

§2.2 covers `pcall` producing a plausible wrong answer. There is a nastier
variant: `pcall` selecting a **fallback code path** and never saying so.

`placeRiderMWScript` returned the `pcall`'s `ok`. On failure the caller quietly
used the teleport backend instead — the path the mod's own comments describe as
triggering an engine bug with nearby NPCs. So a user with a missing ESP got the
known-buggier implementation, every frame, forever, with nothing in the log.

The mod did not break. It got worse, invisibly, and the report would have been
about the *symptom of the fallback*, not the missing plugin.

Any `pcall` whose result chooses between implementations must log the choice
once. If two backends exist, which one is live is a fact worth being able to
read out of a log.

## 2.9 A `pcall` standing in for a missing asset

Sometimes the `pcall` is not wrong so much as it is a symptom.

WhyWalk's `levitationSpellId` was `"placeholder_whywalk_levitate"` — a record
that had never been authored. `spells:add` therefore failed **by design**, every
mount, and the `pcall` existed purely to absorb a guaranteed failure. Removing
the `pcall` alone would have been wrong; it was load-bearing for a broken
design.

The real fix removed the dependency. p37z modifies the effect magnitude
directly, with no record at all:

```lua
types.Actor.activeEffects(actor):modify(1, core.magic.EFFECT_TYPE.Levitate)
```

That deleted the spell id, the ESP record it implied, the `levitationAdded`
bookkeeping and **both** `pcall`s together.

When a `pcall` is wrapping your own missing asset, the question is not "is this
`pcall` justified" but "why is the asset missing, and is there a form of this
feature that does not need it?"

## 2.10 Removing a `pcall` exposes what it was resting on

Expect the removal to surface adjacent bugs. That is the point, but it means a
sweep is not a mechanical edit.

Renaming the cached handle in §2.6 turned up `mwGlobals = nil` in `onLoad`,
left over from the old name. After the rename it would have silently created a
**global** variable and left the real cache stale across a load — so a save
loaded with a different mod order would keep the previous session's verdict
forever. The `pcall` had not caused that bug, but it had made the variable's
lifetime invisible enough for it to survive review.

Two habits follow:

- After removing `pcall`s, grep for every name involved. A stale assignment to a
  now-renamed local is a silent global write, and Lua will not tell you.
- Run `check_names.py` (§Part 4) specifically for this. It is the tool that
  catches the class.

## 2.11 The asymmetric guard

A fast tell, and it needs no knowledge of the API being wrapped:

> **If two calls go through the same API and only one is wrapped, the wrap is
> decorative.**

HookShot's animation module guarded the release call and left the play call
bare — both are `I.AnimationController.playBlendedAnimation`:

```lua
if currentGroup then
    pcall(releaseGroup, currentGroup)          -- guarded
end
I.AnimationController.playBlendedAnimation(group, { ... })  -- not guarded
```

Either that API can raise, in which case the second line is an unhandled crash
and the guard bought nothing; or it cannot, in which case the first line is
noise. There is no reading in which the asymmetry is correct.

The asymmetry is diagnostic of *how* the `pcall` got there: nobody designs this.
It appears when a `pcall` is added at the site where a failure was *observed*
rather than at the boundary where failure is *expected* (§2.14). Grep for the
wrapped function name elsewhere in the file before accepting any guard.

## 2.12 Guarding the wrong side of the boundary

§2.7 is about probing the wrong call. This is about guarding at the wrong
*layer*, and the comment is usually what gives it away — it will describe a
trust boundary that is real, just not here.

HookShot's rope publisher:

```lua
-- Rope rendering is optional, best-effort output. Its failure may
-- never interrupt targeting, physics, animation, or controls.
pcall(updateRope, from, to)
```

Every clause of that comment is true. The conclusion does not follow.
`I.DubiousHookshotVisuals` is registered by **this mod's own** consumer script;
the third-party boundary is a layer further down, where that consumer talks to
BeamFX through `beamfx_adapter.lua` — which already carries eleven `pcall`s
doing precisely this job. The player-side wrapper guarded our code against our
code, with the external risk already handled below it.

Interface names are the trap. `I.Something` reads as external whether or not it
is, and a mod that registers its own interfaces to decouple its scripts will
have call sites that *look* like cross-mod calls and are not.

Before keeping a `pcall` on an interface call, answer literally: **which file
registers this interface?** If the answer is one of yours, it is §2.4. If it is
a third party's, check whether an adapter you already ship is guarding it, and
do not guard it twice — the outer one only hides the inner one's diagnostics.

## 2.13 Ordering instead of catching

The most useful outcome of the HookShot sweep. Most `pcall`s that feel necessary
are protecting **state**, not the call — the fear is not that the call fails,
it is that a failure leaves a variable inconsistent. Statement order solves that
completely, for free, and without suppressing the error.

The pose switcher wanted three guarantees: a failing release must not prevent
the incoming pose from starting, must not strand the cached name, and must still
reach the log. The `pcall` version delivered the first two and broke the third.
Reordering delivers all three:

```lua
local outgoing = currentGroup
currentGroup   = group                                     -- 1. bookkeeping
I.AnimationController.playBlendedAnimation(group, { ... })  -- 2. new pose
if outgoing then releaseGroup(outgoing) end                 -- 3. release last
```

Nothing after a possible raise is load-bearing, so the raise is harmless *and*
visible. `stopAnim` uses the same shape — clear the cache, then release:

```lua
local group  = currentGroup
currentGroup = nil
releaseGroup(group)
```

The generalisation:

> **Put the state you must not corrupt before the call that might fail, and the
> call that might fail last.**

Note the argument does not depend on the call actually being able to fail. The
release-then-play order *would* strand `currentGroup` if it ever raised; the
reorder removes that possibility for free, and it is a better answer than a
`pcall` whether or not the risk was ever real. (In HookShot it probably was not
— see the retraction in §3.2. The reorder is still right.)

That is the general case for this technique: ordering costs nothing and needs no
theory about what can fail, whereas a guard requires you to be right about the
failure — and §3.2 is what being wrong about it looks like.

Ask before writing any guard: **is there an order in which this failure does not
matter?** Usually there is.

## 2.14 Never add a `pcall` while debugging

The strongest finding of the HookShot sweep, and the one with a body count.

The nine `pcall`s in `playerAnim.lua` were added *in the middle of* diagnosing
an animation fault, as insurance while the cause was still unknown — and they
were added around the call that was under suspicion. That is the worst possible
moment and the worst possible placement, whichever way the suspicion turns out:

- If the suspicion is right, the guard hides the evidence that would confirm it.
- If the suspicion is wrong — as it was here (§3.2) — the guard is permanent
  noise sitting on the innocent call, and it *also* changed behaviour, becoming
  one of three simultaneous variables that made the eventual fix unattributable.

The two symptom reports were legible precisely *because* nothing swallowed them:
the failure changed shape when the surrounding code moved, and that is what
localised it to one file. Guards present from the first build would have left
poses leaking silently — §2.2's exact shape, arrived at deliberately.

The rule follows directly:

> **A `pcall` written while you are still guessing is a `pcall` around the
> thing you are guessing about.**

If a crash is annoying you mid-investigation, that crash is the highest-value
signal you have. Add a `print` above it, not a `pcall` around it. Sweep the mod
for guards added during past debugging sessions; they cluster around whatever
was hardest to diagnose, which is where you can least afford them.

## 2.15 A `pcall` cannot catch a call that refuses without raising

The most useful finding of the FLOW sweep, because it defeats the guard
entirely rather than merely making it unnecessary.

FLOW registered a custom settings renderer from a player script:

```lua
local rendererOk = pcall(I.Settings.registerRenderer, 'FLOW_AMF/keyBinding', function(...) end)
if not rendererOk then
    KEY_RENDERER = 'number'   -- fall back so the page still builds
end
```

The fallback was written *specifically* to survive this call failing. It never
ran. From the log:

```
[I] Can't register setting renderer "FLOW_AMF/keyBinding".
    registerRenderer and moved to Menu context Settings interface
[E] Menu[scripts/omw/settings/menu.lua] eventHandler[OmWSettingsRegisterPage] failed.
    Lua error: Setting sprintKeyCode of SettingsFLOW_AMF has unknown renderer
    FLOW_AMF/keyBinding
```

`registerRenderer` **logged a refusal and returned normally**. `pcall` reported
success, `rendererOk` was true, the group went on naming a renderer that did not
exist, and the *entire settings page* failed to build — taking with it the debug
toggle needed to diagnose anything else in the mod. Two release cycles were lost
to it.

This is a distinct failure class from §2.7. There the probe tested the wrong
thing; here the probe is correct and the API simply does not participate. A
large amount of OpenMW's Lua surface reports misuse this way — an `[I]` or `[W]`
line and a no-op — because raising would take down the calling script for what
is usually a configuration mistake.

Three consequences:

1. **Success from `pcall` is not evidence the call worked.** If you need to know,
   verify the effect, not the return.
2. **A fallback keyed on `pcall` failure is dead code** against any API in this
   category. Test it by deliberately breaking the call and confirming the
   fallback path runs.
3. **The fix is context, not catching.** `registerRenderer` moved to the MENU
   context; the working version is a `MENU:` script in `.omwscripts` that does
   nothing else. §2.13's rule generalises: ask what arrangement makes the
   failure impossible before asking how to survive it.

> **`pcall` protects against raising. It does not protect against refusing.
> Where the engine logs-and-continues, the only guard is calling it correctly.**

A corollary worth checking on every upgrade: **APIs move between contexts
between releases.** A call that was legal in a player script can become
menu-only, and the symptom is not an error at the call site — it is a downstream
failure in whatever consumed the thing that was never created.

## 2.16 One more justified case: when failure removes the diagnostic surface

§2.3 closes with "That is the entire list." FLOW adds a third entry, and it is
narrow.

Its settings registration is wrapped, and should stay wrapped:

```lua
local pageOk = pcall(I.Settings.registerPage, { ... })
if not pageOk then print("[FLOW] settings page failed to register") end

local coreOk = pcall(I.Settings.registerGroup, { ... })
if not coreOk then print("[FLOW] CORE settings group failed to register") end
```

The justification is not that the call is untrusted — it is that **a single
rejected setting removes every setting on the page**, including the Debug HUD
toggle that every other diagnostic in the mod depends on. The failure is
unrecoverable rather than merely informative: without the page there is no
supported way back in, short of editing storage by hand.

Both calls print. That is what separates this from concealment (§2.3): the error
is surfaced *and* the rest of the page survives. Removing either half would
break the case for the guard.

The same reasoning produced a structural change worth more than the `pcall`:
the settings were split into two groups, so the one containing nothing but plain
checkboxes with literal defaults — no custom renderer, no `input.KEY` lookup,
nothing that can be nil on some build — cannot be taken down by the one that
can. `pcall` was the last resort after ordering and isolation had been applied,
not the first reach.

> **A guard is justified when the failure destroys your ability to diagnose the
> failure. Isolate first, then guard, and always print.**

## 2.17 A `pcall`'d call blamed for a failure it did not cause

The worst outcome in this document: a wrong diagnosis, an elaborate structure
built to work around it, and a real bug hidden inside that structure.

HookShot's `playerAnim.lua` had poses that leaked and then stopped playing
entirely. `animation.cancel` was identified as the cause, on this reasoning:

> OFF BY DEFAULT because `cancel()` is the prime suspect for the animation
> blackout: **it is the only call in this file that can raise**, and the
> symptoms on both sides of the fix line up exactly with it raising.

That produced a feature flag (`USE_ANIMATION_CANCEL = false`), an alternative
release path that reissues the group at `Default` priority, `pcall` scaffolding
around the release, and three paragraphs of post-mortem in the comments.

Every part of it was wrong.

**The signature was never checked.** The blocker was stated as "confirm
`animation.cancel`'s presence and exact signature for this build in Cod3x" —
one grep:

```lua
--- Cancels and removes the animation group from the list of active animations.
--- Can only be used on self.
---@param actor openmw.SelfObject
function animation.cancel(actor, groupName) end
```

`openmw.self` *is* the `SelfObject`. The call was correct as written, and
`cancel` is the **documented** way to end a blended pose —
`clearAnimationQueue` states outright that it does not affect `playBlended`
animations.

**The real cause was a text-key mismatch.** Poses played on `"loop start"` /
`"loop stop"`; the release path passed no keys and fell through to
`playBlended`'s documented defaults of `"start"` / `"stop"`. The reissue named
keys the group did not define, could not resolve, and never replaced the
outgoing pose — so it looped forever. `forceReset` inherited it, so `reloadlua`
cleanup failed the same way.

The workaround built to avoid the innocent call was carrying the actual bug, and
its `pcall` kept it quiet.

> When a `pcall`'d call is blamed for a failure, **check its signature against
> the stubs before building anything around it**. "It is the only call that can
> raise" is a hypothesis, not evidence — and if it is wrong, every line written
> to route around it is a new place for the real bug to hide.

A corollary worth stating separately, because it cost a second round trip: the
`.kf` was later retargeted to `"start"` / `"stop"`, which made the *current*
file look as though the play half had always been broken. **A fix and a data
change landing together will misattribute the history if you read only the end
state.** The durable part of the fix was hoisting both keys to one constant that
both call sites read — the keys had already moved once.

## 2.18 A failed probe has to fall one way; choose which

§2.7 covers probing the wrong call. There is a smaller decision inside every
probe that is usually made by accident: **when the probe itself fails, what do
you assume?**

ImmersiveBlink, after the §1.24 fix:

```lua
local hasPackage = true   -- assume present if the query is unavailable
if I.AI.getActiveTarget then
    local ok, target = pcall(I.AI.getActiveTarget, packageType)
    if ok then hasPackage = target ~= nil end
end
if hasPackage then I.AI.removePackages(packageType) end
```

The default is `true`, so a build without `getActiveTarget`, or a raising call,
falls back to the *old unconditional behaviour* — the mod keeps suppressing
aggro. Defaulting to `false` would have been the quieter code and would have
silently disabled the feature on any build where the query was unavailable.

> Write the failure default on the line above the probe, with the reason. Fail
> **toward the mod's intent**, not toward the cheaper branch. A probe that
> defaults to "capability absent" turns an API gap into a silently disabled
> feature, which is §2.8 in miniature.

Two related shapes seen in the same sweep:

- **A `pcall` around a destructive call whose result is discarded** tells you
  neither that it failed nor that it did anything. Combined with per-frame
  invocation (§1.24) there is no surface on which to notice either way. If the
  call mutates shared state, return whether it acted.
- **`pcall(function() return section:get(key) end)`** around an optional
  third-party storage section is legitimate under §2.3 — CAKE and take_a_seat
  both use it to detect SuperSettingsRenderers without requiring anything from
  it. The section may genuinely not exist. Compare with §2.6: the answer is
  fixed once at load, so read it once into a local, not per registration.

---

## 2.19 A `pcall`'d write whose caller records it as done

The strongest single argument in this document for not reaching for `pcall` by
default, because the consequence is not a missed error. It is **your own state
quietly ceasing to match reality**, permanently, with nothing in any log.

Immersive Riding writes camera shake *additively* — it reads the current pitch,
subtracts the contribution it made last frame to recover the base, adds its new
one, and remembers it. That is a genuinely good technique (see §1.26 for the
exclusive alternative), and it depends absolutely on knowing whether the write
landed.

The same file implements it twice. First person:

```lua
if pcall(camera.setFirstPersonOffset, writtenOffset) then
    cameraMotionLastWrittenOffset = writtenOffset      -- recorded ONLY on success
end
```

Third person, twenty-four lines later:

```lua
pcall(camera.setPitch, basePitch3rd + pitchShake)
pcall(camera.setYaw,   baseYaw3rd   + yawShake)

thirdPersonMotionPitch = pitchShake                   -- recorded regardless
thirdPersonMotionYaw   = yawShake
```

If `setPitch` fails, `thirdPersonMotionPitch` still says it applied. Next frame
computes `basePitch3rd = currentPitch - thirdPersonMotionPitch` and subtracts a
delta that was never there, so the base is wrong by exactly that amount — and
wrong again next frame, compounding. `clearThirdPersonContribution()` then
removes a contribution that does not exist, leaving the camera permanently
rotated with no error, no log line, and no way to tell from the outside whether
the mod, another mod, or the engine did it.

The author knew the correct form. They wrote it, correctly, immediately above.
That is what makes this a habit rather than a mistake: once `pcall(...)` is the
reflex for touching the engine, the difference between the two forms stops being
visible, because nothing ever fails loudly enough to make you look.

> If code after a `pcall` records, increments, caches, or otherwise **assumes
> the wrapped call succeeded**, the `pcall` is not protecting you — it is
> manufacturing a divergence between what you believe and what happened. Either
> gate the bookkeeping on the result, or do not wrap the call.

This is §2.18's sharper sibling: there, a discarded result meant nothing could
observe whether the call worked. Here, something does observe it — incorrectly.

### Why the count matters, not just the pattern

That mod carries **144** `pcall`s. The distribution is the argument:

| form | count |
|---|---|
| `pcall(function() ... end)` — whole blocks | **101** |
| named single calls | 43 |

The closure form is not "this API may not exist". It is an arbitrary block with
every error inside it swallowed, and it cannot be reasoned about per §2.1
because there is no single call to ask the question of. Among the named ones:
`pcall(camera.getPitch)`, `pcall(input.isKeyPressed)`, `pcall(input.isShiftPressed)`
— pure getters that cannot meaningfully fail — and `pcall(anim.cancel)` five
times, the exact call §2.17 records being wrongly blamed in HookShot for a
failure it did not cause, *because a `pcall` hid the real one*. The same trap,
pre-loaded five times over.

Compare HookShot after its rework: **zero**. Same engine, same problem domain,
same author's suite. The count is a choice, not a consequence of the API.

> Density is itself a finding. Past a handful, `pcall` has stopped being a
> considered response to a specific documented risk and become the default way
> the codebase touches the engine — at which point every rule in this Part is
> already being violated, and the errors that would have told you so are gone.

---

## 2.20 Removal checklist

For each `pcall`, in order. Any "no" means remove it.

1. Is the wrapped code third-party, or a documented-optional `require`? → keep
   (§2.3).
2. Does the failure it catches change at runtime, or is it fixed at load?
   (§2.6)
3. Is it wrapping the call that actually fails, or a neighbouring one? (§2.7)
4. Does the failure path silently select a different implementation? (§2.8)
5. Is it covering an asset of yours that does not exist yet? (§2.9)
6. Has the object already been validated by an enclosing guard?
7. Which file registers the interface being called? If it is one of yours, the
   boundary is elsewhere (§2.12). If it is a third party's, is an adapter you
   ship already guarding it? Do not guard it twice.
8. Is the same API called unwrapped anywhere else in this file? An asymmetric
   guard is decorative (§2.11).
9. Is it protecting *state* rather than the call? Reorder so the state is
   settled before the fallible call, and drop the guard (§2.13).
10. Does this API actually raise on misuse, or does it log and return? If it
    logs, the guard is inert and the fallback behind it is dead code (§2.15).
11. Would the failure remove your ability to diagnose the failure? That is the
    only case §2.3 does not already cover — isolate first, then guard, and
    print (§2.16).
12. Was it added during a debugging session, before the cause was known? Assume
    it is wrapping the cause (§2.14).
13. Is the wrapped call being *blamed* for a failure? Check its signature
    against the stubs before building a workaround around it — the workaround
    is where the real bug will hide (§2.17).
14. If the probe fails, which way does it fall? Write the default and the
    reason on the line above, and fail toward the mod's intent (§2.18).
15. Does the wrapped call mutate shared state while discarding its result? Then
    nothing can observe whether it worked or whether it did anything (§2.18).
16. Does anything AFTER the `pcall` record, increment or cache as though the
    call succeeded? Then the wrap is manufacturing a divergence between your
    state and the engine's. Gate the bookkeeping on the result, or drop the
    wrap (§2.19).
17. If it stays: does it print the error, and enough context to identify the
    subscriber or path? A `pcall` that discards the error is concealment.

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
| **`animation.cancel`** | Lives on `openmw.animation` and takes the actor. It is not on `I.AnimationController`. Cancelling a group the skeleton lacks is a no-op, not an error (§2.4). |
| **Release at the layer you played at** | `openmw.animation.playBlended` pairs with `openmw.animation.cancel`. If you play through `I.AnimationController.playBlendedAnimation` instead, the controller keeps its own record of what is active, and cancelling underneath it at module level leaves the two disagreeing. Unverified but the one real difference between HookShot and the mods this rule came from — see the note after this table. |
| **A group name with no clip is not an error** | Naming a group the `.kf` lacks suppresses vanilla animation and supplies nothing, so the actor T-poses. Verify every group with `animation.hasGroup` against the actual binary, and treat placeholder names (`hookgo_creature`) as unshipped assets, not TODOs. |
| **`types.Actor.equipment`** | Does not exist. It is `getEquipment`. |
| **KF text keys** | A group keyed `loop start`/`loop stop` will not answer to `start`/`stop`. Read the keys out of the binary; the resulting stuck or absent pose reads as a scripting bug when it is a naming one. Both conventions are in use — HookShot's clips key on `start`/`stop`, and its script carried the `loop start`/`loop stop` pair inherited from an earlier module until it was corrected. Neither is the default; check per project, not per habit. |
| **`vfxId` and magic effects** | The engine uses `vfxId` to add and remove magic effects. The docs warn explicitly against ids that collide with `core.MagicEffectId` values. Namespace yours (`saw_w_<recordId>`, `cake_<category>`). |

**Retracted: the `animation.cancel` counter-example.**

An earlier revision of this file recorded HookShot as contradicting Part 5 item
11, claiming `anim.cancel` raises. **That claim was wrong and is withdrawn.** It
is documented here because the reasoning error is a recurring one.

What was actually observed, in order:

1. Poses were leaking (a switch never released the outgoing group), and they
   looped forever.
2. A fix added the missing release *before* the play. Result: animations stopped
   appearing.
3. A second fix changed three things at once — swapped `anim.cancel` for a
   mask-aware reissue, added `pcall` guards, and introduced `GROUP_BLEND_MASK`.
   Animations returned.

The conclusion drawn was "`anim.cancel` raises". Three faults with it:

- **Affirming the consequent.** A simulation showed *if* the release raises,
  *then* the symptoms follow. It never showed the converse. Several other causes
  produce the same two symptoms, and the simulation was written from the
  hypothesis, so it could only agree with it.
- **Contradicted by better evidence already in this file.** §2.4 records that
  cancelling a group the skeleton lacks is a no-op. That entry came from
  instrumented work; the contradiction came from inference over a symptom
  report. The weaker evidence should not have won.
- **The confounded fix.** Step 3 changed three variables together, so the
  recovery attributes to none of them. It was read as confirming the mechanism
  swap purely because that was the change under suspicion.

> **A fix that changes three things at once proves nothing about which one
> mattered.** If you are testing a hypothesis, change one variable. If you just
> need it working, change three — but do not then report the result as evidence.

What survives the re-audit, from diffing the shipped builds:

- The **leak** was real, and the release-before-play fix for it was correct. That
  part is independent of the mechanism question (§1.17, §3.4).
- The two builds either side of the blackout differ **only** in `playerAnim.lua`,
  so the regression was in that change, not in the rope port or group renames.
- HookShot plays via `I.AnimationController.playBlendedAnimation` but released
  via `openmw.animation.cancel` — a **layer mismatch** the mods behind §2.4 do
  not have, since they play with `anim.playBlended`. That is the one substantive
  difference, it is untested, and it is a far better hypothesis than "cancel
  raises."
- The text keys were changed from `loop start`/`loop stop` to `start`/`stop`
  *after* the blackout — **author-confirmed as intentional**, matching the keys
  actually present in the `.kf`. They are therefore not implicated in the
  blackout, and the builds that preceded the change demonstrably did animate:
  the earlier symptom was poses *looping*, which requires them to have played.
  What the change does do is land in the same window as the mechanism swap, so
  the recovery from the blackout spans **four** simultaneous variables, not
  three. That strengthens the retraction above rather than weakening it — there
  is even less basis for attributing the recovery to the mechanism.

Nothing here justifies changing Part 5 item 11. Use `animation.cancel`; if you
play through `I.AnimationController`, check the pairing first.

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
| **A "current" cache cleared only on the success path** | `currentGroup` was assigned after the work and cleared after the release. Any raise in between would leave it naming a pose that was not playing, and the `currentGroup == group` early-out would then block every future transition — one failed call disabling the subsystem for the session. Not confirmed to have fired in HookShot (§3.2), but free to design out: clear or reassign the cache **first**, then do the fallible work (§2.13). |
| **Masking a leak with a pass-through state** | The pose leak existed from the start but was invisible because `fireHookshot` routed DRAWN → IDLE → FIRING, and IDLE happened to stop the pose. Removing the redundant IDLE hop — a correct change on its own terms — exposed it. When a refactor "causes" a bug in unrelated code, check whether it removed an accidental cleanup rather than assuming it introduced the fault. |

## 3.5 Plugin data

| Bug | Detail |
|---|---|
| **`_eq` applied to `FNAM` instead of `NAME`** | 320 records with 160 unique ids: two identical blocks differing only in display name. The second silently overwrote the first (TES3 is last-wins), leaving zero `_eq` records and every item named "…_eq". |
| **Ids from a different content set** | 50 ids in a script, **none** of which existed in any shipped plugin. Always cross-check the registry against the plugin binary. |
| **Undeclared masters** | Meshes from OAAB, Project Cyrodiil and others resolve fine for you and not for users. Declare the masters — do **not** "fix" it by editing or dropping the records; those paths are correct. |
| **Bodypart / item id collisions** | Reusing bodypart ids (`_RV_Ashmask1_H`) for wearable items works at the engine level but conflates the two everywhere else. A prefix resolves it. |

## 3.6 Structure

- **Dead settings are worse than no settings** — they imply a feature exists.
  Cross-reference declared against read.
- **An empty category is a load failure waiting to happen** if anything
  validates its keys against it. Prune empties at generation time.
- **Registration must be idempotent.** `onInit` and `onLoad` both call it and
  only one runs on a given start.
- **Bundle shared libraries, do not copy them in.** Version-guard the file
  itself (`if I.X and I.X.version >= MY_VERSION then return end`) so only the
  newest loaded copy runs. `AnimRefresh`, `SharedRay`, `SuperSettingsRenderers`.
- **Event payloads carry `self.object`, not `self`.** `openmw.self` is the
  `SelfObject`, a distinct type from the `GObject`/`LObject` a payload should
  hold. CAKE and ImmersiveBlink both sent `self`. Neither broke visibly:
  ImmersiveBlink's receiver tested it with `types.Player.objectIsInstance` and
  fell back to `nearby.players[1]`, which happens to be the right answer with
  one player nearby. It degrades quietly, which is why it survives review.
- **`---@omw-context` must be present and must be a real token.** The Cod3x
  plugin poisons a *missing* annotation and an *invalid* one identically, so
  both fail the same way. Valid:
  `global | local | player | menu | load | runtime | all | none`. `shared` is
  not a token — CAKE used it on a module with no `openmw.*` requires, which
  wanted `none`. And `none` is only correct with **zero** requires: a data
  module pulling in `openmw.types` and required from both a player and a local
  script wants `runtime`, not `none`.

## 3.7 Riding, pinning and the MWScript bridge

| Bug | Detail |
|---|---|
| **Missing `player->` prefix** | In MWScript an unprefixed command applies to the object the script runs on. `SetAngle Z pa` in a script attached to a creature rotates the **mount**; `player->SetAngle Z pa` rotates the rider. Both Sturdy Steed scripts keep the prefix even in `SimpleHorseRiding222`, which *is* a local creature script — the prefix is what makes the target explicit rather than positional. Symptom: the mount spins instead of the rider. |
| **`rotateZ` sign is not settled** | Four independent usages disagree. Sturdy Steed's pillion positioning and WhyWalk's rider use `rotateZ(+yaw)`; p37z's rider and WhyWalk's *mount* use `rotateZ(-yaw)` — WhyWalk uses both signs in one function. Cod3x documents the `teleport` rotation parameter only as `util.Transform`, with no sign convention. Vector transforms are unambiguous (`rotateZ(getYaw())`, per Cod3x's own actor-space example); the `teleport` rotation argument is not. **Verify in game before changing either.** A negation may also be compensating for a creature NIF whose mesh faces −Y. |
| **Perspective gate on the wrong side** | The rider's body yaw must be forced **only** in third person — in first person the player's yaw *is* the look direction and overwriting it fights mouse-look. `PCGet3rdPerson` is free and always correct in MWScript, and camera mode is not readable from a global Lua script, so the gate belongs in the MWScript, not in Lua. |
| **`0` as both a value and a sentinel** | p37z signals "do not rotate" by writing `zRot = 0`, and the script gates on `zRot != 0.0`. A mount facing exactly north has yaw 0, which is indistinguishable from "no request" — the rider never aligns. Pick a sentinel outside the value's range, or carry a separate flag. |
| **One saddle offset for both perspectives** | `setFirstPersonOffset` is documented as the offset between the character's **head** and the camera. The pin places the rider's **feet**, so a first-person camera lands at `saddle.up` + head height above the mount — far too high — and the only correction available walks the camera down *through* the mount's neck. Sturdy Steed carries two poses per creature (`sdlUp3 80` / `sdlUp1 47`) and picks on `PCGet3rdPerson`: move the body, not the camera. |
| **Mixed priority tiers in one pose** | `RightArm` at `PRIORITY.Scripted` while `LeftArm`/`Torso` were `PRIORITY.Weapon`, in the same `playBlendedAnimation` call. Given §3.2's note that `Scripted` pauses all non-Scripted animation, mixing tiers within one pose is almost certainly unintentional. |
| **A defined group that is never played** | `GROUPS.HANDOFF` existed and the state branch played `GROUPS.DRAWN` instead. Cross-reference every declared group against its play sites — `sweep.py` territory. |
| **Cancel with a hardcoded blend mask** | The "reissue at `Default` priority" cancel idiom must reproduce the mask the group was *played* with. A shared `releaseGroup` hardcoding the full-body mask corrupted upper-body-only poses. `animation.cancel` takes only the group name and cannot get this wrong (§3.2). |
| **Reset lists that miss a group** | `forceReset()` released the groups that existed when it was written and was never updated for `HANDOFF` or the per-target-type firing variants. Enumerate from the table that defines them, do not restate the list. |
| **`for i = n, -1 do`** | p37z's duplicate-registration guard. No step, so it counts *up* from `n` to `-1` and the body never runs when `n >= 0`. The guard it advertises does not exist. `for i = n, 1, -1`. |

## 3.8 Actor origin and offsets

Three bugs in one mod traced to the same wrong assumption, so it is worth
stating once: **an actor's `position` is at its feet, not its centre.**
`hookshot_physics` builds its collision cage upward from `position` to
`+height`, which only works feet-anchored.

| Bug | Detail |
|---|---|
| **`halfExtents.z` as a body-height offset** | `getPathfindingAgentBounds(actor).halfExtents.z` is *half* standing height. Offsetting up by it from a feet origin lands at the **waist**. Two separate rope-origin implementations in one mod both did this while their comments said "hand" and "shoulder". Full height is `halfExtents.z * 2`; shoulder is ~0.81 of it, measured from the ground. |
| **Clamping the feet when the constraint is on the head** | A rappel ascent limited to `playerZ < anchorZ - 64` let the *head* — 128 units up — climb 64 units past the anchor and into the surface the hook was embedded in. Against a ceiling anchor that is ~131 units of penetration at the apex. Clamp the extremity the constraint actually applies to: `(playerZ + PLAYER_HEIGHT) < anchorZ - clearance`. |
| **Asymmetric probes for symmetric motion** | The descend path cast a ground ray; the ascend path cast nothing. If a movement mode can go two directions, both need the same class of check, or the unchecked direction is where the clipping report comes from. |
| **Two implementations of one offset** | The mod-side helper and the visual consumer each computed their own launch point, and they disagreed by ~40 units vertically. Because the gameplay side measured hook flight distance from *its* copy, installing or retuning the optional visual mod silently changed hook timing. Offsets used by both gameplay and rendering belong in one shared helper, with the other side delegating to it. |

Scale-proportional fractions (`0.81 * fullHeight`) rather than flat constants
(`+104`) also survive Beast races, `NPC.setScale` and any scaled creature, at no
extra cost — the bounds query is already being made.

---

# Part 4 — Verification

Tooling in `tools/`. No Lua interpreter is installed; `luacheck.py` and
`luarun.py` drive the system `liblua5.4.so.0` through ctypes. (The same library
also links directly — `gcc` against `/usr/lib/x86_64-linux-gnu/liblua5.4.so.0`
with `luaL_newstate` / `luaL_loadfilex` / `lua_tolstring` declared by hand, since
no Lua headers are installed. Useful as a second opinion when a ctypes signature
is in doubt.)

| Tool | Catches |
|---|---|
| `luacheck.py` | Syntax. |
| `globalcheck.py` | **Reads of undeclared globals.** See §4.4 — this is a class the other two miss entirely. |
| `check_names.py` | Undefined names, unused requires. |
| `api_sweep.py` | Every `module.member` call vs the Cod3x stubs. **Run this** — a misspelled API inside a pcall-wrapped call is §2.2 again. |
| `sweep.py` | Settings declared vs read, categories used vs defined, events sent vs handled, l10n keys, orphaned modules. |
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

## 4.4 An undeclared global is valid Lua, so nothing above catches it

FLOW v0.55 shipped with this in `main.lua`:

```lua
local self = require('openmw.self')          -- line 5: named `self` HERE
...
local isIdle = activeName == "Idle" and not mwSelf.controls.run   -- line 151
```

Every other file in that mod requires `openmw.self` as `mwSelf`; `main.lua` is
the one that calls it `self`. The line was written in the siblings' idiom, so
`mwSelf` was an undeclared global, and indexing nil raised **2,293 times in 79
seconds** — once per frame.

The severity is the part worth internalising. The throw is at line 151, so
nothing below it in `onUpdate` ran: `Sensor.update`, `SensorExt.updateLedgeHang`,
`StateManager.update` and the debug HUD were all dead. Vault, mantle, ledge-hang,
shimmy and roll did nothing. But **init logged normally** — the log shows twenty
cheerful `[FLOW] Registered State` and `[FLOW][anim] ... -> OK` lines and zero
runtime state activity. A mod can look like it loaded perfectly and be entirely
non-functional.

Why the existing tools all missed it:

| tool | why it passed |
|---|---|
| `luacheck.py` | An undeclared global is **valid Lua**. It parses. |
| forward-reference sweep | It matched `name(` — a **call**. `mwSelf.controls.run` is an **index**. |
| `api_sweep.py` | It resolves `module.member` against Cod3x for names bound by a `require`. `mwSelf` is bound to nothing, so there is no module to check against. |

`globalcheck.py` closes it. It tracks `local`, `local function`, multi-name
locals, function parameters, numeric and generic `for`, method `self`, and Lua
keywords, then reports any remaining bare name used as a value.

It is deliberately **scope-insensitive**: a name declared anywhere in the file
counts as declared everywhere. That means it cannot report "used outside its
block", and a real miss can hide behind an unrelated local of the same name.
Accepted on purpose — a checker that cries wolf gets switched off, and this one
has to survive being run over the whole suite.

### It cried wolf twice before it was trustworthy

Both rounds are worth recording, because they are what a heuristic checker costs:

1. **Lua keywords.** The candidate pattern matched `not (`, `and (`, `return (`,
   `if (`. Seven bogus hits across FLOW alone.
2. **`package`, and `M`.** `package` is a stdlib global that was simply missing
   from the builtin set. `M` is **injected on purpose** — `luarun.py` does
   `lua_setglobal(L, b'M')` before running `test_shared.lua`. Neither was a mod
   bug.

Hence `--globals NAME,NAME` for harness-injected names, and `tools/` skipped by
default (`--all` to include). After both fixes: **zero** undeclared reads across
every project in this suite, with the FLOW bug still reported.

> Do not trust a new checker's first output. Run it against a known bug to prove
> it fires, and against known-good code to prove it stays quiet. A checker that
> has only ever been run on broken code is untested in the direction that
> matters.

---

# Part 5 — Checklist before changing anything here

1. Does this add an `onFrame` or `onUpdate` handler? Justify it against §1.3.
   Specifically: **is there an event for the thing you are watching?** If yes,
   you are on the wrong rung. If genuinely not (§1.11), is the early-out the
   first line?
2. Does it poll anything a subscription or engine event would give you? Held
   keys are the usual offender — `onKeyPress`/`onKeyRelease`, not
   `isKeyPressed` every frame (§1.12).
3. If it subscribes, is the subscription released when idle?
4. Does it re-send unchanged state? Send intent on change instead (§1.13).
5. Can the handler re-trigger itself? Animation-ended and text-key handlers are
   not rate-limited by the frame — burst-guard them (§1.14).
6. Are you adding a `pcall`? Walk §2.15. It needs to be third-party code or a
   documented optional; everything else has a specific reason it is wrong. If
   you are adding it *while debugging*, stop — it is almost certainly wrapping
   the cause (§2.14).
7. Are you passing a mesh path? Resolve it from the record at runtime.
8. Are you attaching to a bone? `hasBone` first, vanilla fallback declared.
9. Are you tracking occupancy? Key it by bone, not by type — and check whether
   the engine already owns that bone.
10. Are you inferring state from inventory presence? Don't.
11. Are you cancelling an animation? `animation.cancel(self, group)` — not a
    reissue at `Default` priority with a hand-written blend mask (§3.7). A
    HookShot counter-claim against this was withdrawn on re-audit (§3.2). Two
    riders: release at the same layer you played at (module-level `cancel` pairs
    with `anim.playBlended`, not necessarily with
    `I.AnimationController.playBlendedAnimation`), and if you do use a reissue,
    record each group's mask at play time rather than hardcoding one.
12. Are you switching a held pose? Release the outgoing group — a pose played
    with `loops = -1, forceLoop = true, autoDisable = false` runs until
    something cancels it, and overwriting the cached name orphans it forever
    (§3.4). Order it bookkeeping → play → release (§2.13).
13. Are you offsetting from an actor's position? It is at the **feet**, and
    `halfExtents.z` is *half* height — check §3.8 before trusting either.
14. Is the handler you are adding driven by a global backend? Match its pause
    behaviour, and clamp `dt` if you genuinely need `onFrame` (§1.15).
15. Publishing a visual every frame? Change-gate it, and check the keepalive is
    shorter than the consumer's expiry (§1.16).
16. Did you write MWScript? Every command that should affect the player needs
    the `player->` prefix (§3.7).
17. Run `luacheck.py`, `check_names.py`, `api_sweep.py`, `sweep.py` and the
    tests. All five, not the first one. After a `pcall` sweep, `check_names.py`
    is the one that matters (§2.10).
18. If you added behaviour, does the mock actually enforce the engine's
    contract, or would it accept a wrong answer?
