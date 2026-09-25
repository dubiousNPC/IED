---@omw-context player
--[[
    AnimRefresh v4 -- model-rebuild notifier

    THE PROBLEM
    -----------
    Several things rebuild the player's animation object. Scripted animations
    and VFX attached to it are dropped when that happens, so a sitting pose, a
    sheathed instrument or a worn cosmetic silently vanishes. There is no "your
    VFX was removed" event to hook, so every mod that attaches something to the
    player has to notice for itself and re-attach.

    Three causes, and all three are in scope for this service:

      * crossing the FIRST-PERSON boundary,
      * a UI mode that rebuilds the model (Rest, Travel, Training, Jail),
      * loading a save.

    WHAT CHANGED IN v4, AND WHY
    ---------------------------
    v4 is a rewrite following a review by the author of Sun's Dusk, whose
    p_backpacks.lua is the implementation v1 was lifted from. Every point below
    was demonstrated against the real v3 file in a simulated engine before it
    was changed (tools/sim.lua, tools/sim_load.lua).

    1. IT WATCHED THE WRONG SIGNAL. camera.getMode() has five values, but only
       ONE boundary rebuilds anything: first person versus not. ThirdPerson,
       Preview and Vanity all draw the same model. v3 fired on every hop
       between them, so auto-vanity after ~30s idle -- the exact state of a
       player sitting in a chair -- re-issued the pose and restarted it from
       frame 0. Measured: five spurious callbacks for one idle-to-vanity and
       back. v4 tracks a BOOLEAN, `firstPerson`, and fires only when it flips.

    2. THE SETTLE/CONFIRM MACHINERY WAS GUESSING. v3 scheduled delivery off the
       TogglePOV key press, which happens BEFORE the mode changes, so the
       0.1s SETTLE_DELAY was a guess at how long the swap takes, and
       CONFIRM_DELAY was a second guess covering the first one being wrong.
       One press cost four callbacks. camera.getQueuedMode() returns the mode
       the camera is transitioning to, or nil when it has settled -- a real
       signal instead of two guesses. v4 fires when the boundary has flipped
       AND nothing is queued. One event, one delivery.

       With that, the TogglePOV handler is gone too. It existed to beat a 1s
       poll; the poll now runs at POLL_INTERVAL 0.1s, which is a camera-mode
       enum read ten times a second, and costs nothing measurable.

    3. IT MISSED THE TWO CAUSES THAT ACTUALLY BITE IN PLAY. p_backpacks
       refreshes after Rest and Travel, and one frame after a game load. v3 did
       neither, and "you cannot change perspective from a menu" is true but
       beside the point -- the MODEL is rebuilt regardless. Both are now
       handled here rather than left to every subscriber to remember.

    4. subscribe() AND unsubscribe() RE-BASELINED THE MODE. One mod
       unsubscribing mid-switch swallowed that transition for every other
       subscriber. v4 never re-baselines outside the poll, and a new subscriber
       instead gets one refresh of its own shortly after it registers -- which
       is also what makes "subscribe and forget" true after a load, whatever
       order the scripts register in.

    THE CONTRACT
    ------------
        I.AnimRefresh.subscribe("MyMod", function(mode, previousMode)
            -- re-issue whatever you own
        end)
        I.AnimRefresh.unsubscribe("MyMod")

    Your callback MUST be idempotent: REMOVE THEN ADD, every time, exactly as
    p_backpacks does with removeVfx/addVfx. It can be called when nothing was
    lost -- after a load, on subscribing, or on a retry -- and attaching a
    second copy is your bug, not the service's.

    VERIFY. A rebuild can finish AFTER the delivery, dropping what you just
    attached, and no API can report that -- openmw.animation has addVfx and
    removeVfx and nothing that reads back. So a second delivery is the only
    cover, and whether it is wanted depends on what you attach:

        I.AnimRefresh.subscribe("MyMod", cb, { verify = true })

    Pass it if re-attaching is invisible (removeVfx then addVfx). Leave it out
    if a second call is visible -- re-issuing a looping POSE restarts it from
    frame 0, which is why v3 delivering four times per press was a bug for
    sitting mods and merely wasteful for cosmetic ones.

    If you cannot tell whether the model was ready, RETURN FALSE and you will be
    called again on a 0.1s timer, up to MAX_RETRIES times:

        I.AnimRefresh.subscribe("MyMod", function()
            if not animation.hasBone(self, MY_BONE) then return false end
            ...
        end)

    Return false ONLY for a transient state. A bone your skeleton simply does
    not have is not transient, and reporting it as not-ready earns a retry, a
    log line and nothing else.

    Never cache the interface. Call through `I.AnimRefresh.subscribe(...)` each
    time: if an older bundled copy loaded first and this one overrode it, a
    cached `local AR = I.AnimRefresh` is still talking to the dead copy.

    COST WHEN IDLE
    --------------
    With no subscribers, onUpdate does one integer compare and returns. With
    subscribers, it is one enum read every 0.1s and no timers at all until
    something actually changes.
]]

local camera = require('openmw.camera')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 4

if I.AnimRefresh and I.AnimRefresh.version >= MY_VERSION then
    return
end

-- Poll rate for the first-person boundary. An enum read; see note 2 above.
local POLL_INTERVAL = 0.1

-- Retry cadence for a subscriber that reported "not ready" (returned false).
local MAX_RETRIES = 2
local RETRY_DELAY = 0.10

-- A game load rebuilds the model, and scripts re-register in an order this
-- service does not control. Deliver twice: once almost immediately, once after
-- everything has had a chance to come up.
local LOAD_DELAYS = { 0.10, 0.60 }

-- A new subscriber is refreshed once, shortly after it registers.
local JOIN_DELAY = 0.10

-- Second delivery after a BOUNDARY change, for subscribers that asked for it
-- with `verify = true`. See the VERIFY note in the contract above. This delay
-- is the one guess left in the file and it is deliberate: there is no API to
-- ask whether an attached VFX is still attached (the whole openmw.animation
-- surface was checked -- addVfx/removeVfx and nothing that reads back), so a
-- rebuild that completes after the delivery cannot be detected by anyone,
-- service or subscriber. One second is past any rebuild observed here.
local VERIFY_DELAY = 1.0

-- UI modes that rebuild the model. A menu that merely draws over the world
-- (Inventory, Book, Dialogue) does not, and firing for those would restart a
-- pose every time the player opened a container.
local REBUILD_UI_MODES = {
    Rest     = true,
    Travel   = true,
    Training = true,
    Jail     = true,
}

local subscribers     = {}
local verifiers       = {}   -- subset that asked for the second delivery
local subscriberCount = 0
local pollTimer       = 0

local function isFirstPerson()
    return camera.getMode() == camera.MODE.FirstPerson
end

local firstPerson = isFirstPerson()
local lastMode    = camera.getMode()

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

local deliver   -- forward declaration: deliver reschedules itself

deliver = function(keys, mode, previous, attempt)
    local notReady = nil

    for key in pairs(keys) do
        -- Re-read from `subscribers`: a retry can land after the subscriber
        -- unsubscribed, and calling a stale callback is exactly the kind of
        -- ghost this service should not create.
        local callback = subscribers[key]
        if callback then
            -- NO pcall. A subscriber that throws propagates, and the engine
            -- reports it with the failing mod's own stack. This service fires a
            -- handful of times a session; a subscriber that throws is a bug in
            -- that subscriber, never a supported state, so there is nothing
            -- here for a guard to legitimately handle.
            local result = callback(mode, previous)
            if result == false then
                notReady = notReady or {}
                notReady[key] = true
            end
        end
    end

    if not notReady then return end

    if attempt < MAX_RETRIES then
        async:newUnsavableSimulationTimer(RETRY_DELAY, function()
            deliver(notReady, mode, previous, attempt + 1)
        end)
    else
        -- Say so rather than dropping it silently. A subscriber still not ready
        -- here has a real problem and this is the only place it is visible.
        for key in pairs(notReady) do
            print("[AnimRefresh] '" .. tostring(key) ..
                  "' still not ready after " .. tostring(MAX_RETRIES + 1) ..
                  " attempts; giving up on this change")
        end
    end
end

local function fire(previous)
    if subscriberCount == 0 then return end
    local all = {}
    for key in pairs(subscribers) do all[key] = true end
    deliver(all, camera.getMode(), previous, 0)
end

-- Boundary changes only. A UI mode, a load and a join all deliver at a moment
-- when nothing is mid-rebuild, or already deliver twice.
local function fireBoundary(previous)
    fire(previous)
    if next(verifiers) == nil then return end
    async:newUnsavableSimulationTimer(VERIFY_DELAY, function()
        local again = nil
        for key in pairs(verifiers) do
            if subscribers[key] then again = again or {}; again[key] = true end
        end
        if again then deliver(again, camera.getMode(), previous, 0) end
    end)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------

-- The poll owns the baseline, and it is the ONLY thing that writes it. Nothing
-- else -- not subscribe, not unsubscribe, not a UI mode, not a load -- may
-- touch it, or a pending transition is swallowed for every subscriber (note 4).
local function checkBoundary()
    -- Mid-transition. getQueuedMode() is the mode the camera is moving to, and
    -- it is nil once the switch has landed. Delivering before that is what the
    -- old SETTLE_DELAY was guessing at.
    if camera.getQueuedMode() ~= nil then return end

    local mode = camera.getMode()
    local nowFirst = mode == camera.MODE.FirstPerson
    local previous = lastMode
    lastMode = mode

    -- Hops between ThirdPerson, Preview and Vanity draw the same model and
    -- rebuild nothing. Only the boundary matters.
    if nowFirst == firstPerson then return end
    firstPerson = nowFirst
    fireBoundary(previous)
end

local function onUpdate(dt)
    if subscriberCount == 0 then return end
    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkBoundary()
end

-- Rest, Travel, Training and Jail rebuild the model without touching the
-- camera, so the poll above can never see them. Fire when such a menu CLOSES.
local function uiModeChanged(data)
    if subscriberCount == 0 then return end
    if data and data.newMode == nil and data.oldMode and REBUILD_UI_MODES[data.oldMode] then
        fire(lastMode)
    end
end

-- A load re-reads every script, so this service starts from nothing and the
-- camera has not "changed" by any measure it could take. Deliver on a timer
-- instead, twice, because subscribers register in an order set by load order.
local function onLoad()
    for _, delay in ipairs(LOAD_DELAYS) do
        async:newUnsavableSimulationTimer(delay, function() fire(lastMode) end)
    end
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

local function subscribe(key, callback, opts)
    -- A silent no-op on a bad key is the failure class this suite's no-pcall
    -- rule exists to kill: a typo'd key constant would mean the mod never
    -- refreshes and never says why.
    if type(key) ~= 'string' or key == '' then
        error(("[AnimRefresh] subscribe() needs a non-empty string key, got %s")
              :format(type(key) == 'string' and '""' or type(key)))
    end
    -- Validated at registration rather than at call time: with no pcall around
    -- delivery, a non-function subscriber would raise from inside a timer,
    -- where the stack says "AnimRefresh" and not which mod registered it.
    if callback ~= nil and type(callback) ~= 'function' then
        error(("[AnimRefresh] subscribe('%s', ...) needs a function, got %s")
              :format(key, type(callback)))
    end

    if subscribers[key] == nil and callback ~= nil then
        -- Going from nobody to somebody: re-baseline. The poll returns early
        -- while there are no subscribers, so the baseline is as old as the last
        -- one to leave, and without this the first poll would report a flip
        -- that happened while nothing was listening -- restarting a pose the
        -- player just sat down in. This is NOT v3's fault returning: it fires
        -- only on 0 -> 1, when by definition there is no one else to swallow a
        -- transition from.
        if subscriberCount == 0 then
            lastMode    = camera.getMode()
            firstPerson = lastMode == camera.MODE.FirstPerson
            pollTimer   = 0
        end
        subscriberCount = subscriberCount + 1
    elseif subscribers[key] ~= nil and callback == nil then
        subscriberCount = subscriberCount - 1
    end
    subscribers[key] = callback
    -- `verify = true` buys one extra delivery per boundary change. Say yes if
    -- re-attaching is invisible (removeVfx + addVfx). Say nothing if being
    -- called twice is visible -- a looping POSE restarts from frame 0.
    verifiers[key] = (callback ~= nil and opts and opts.verify) or nil

    -- One refresh for the joiner alone, shortly after it registers. It makes
    -- subscribing sufficient on its own -- after a load, or when a mod starts
    -- owning something mid-session -- without touching the shared baseline and
    -- without disturbing anyone else. Harmless because callbacks are required
    -- to be remove-then-add.
    if callback ~= nil then
        async:newUnsavableSimulationTimer(JOIN_DELAY, function()
            if subscribers[key] then
                deliver({ [key] = true }, camera.getMode(), lastMode, 0)
            end
        end)
    end
end

local function unsubscribe(key)
    if type(key) ~= 'string' or key == '' then return end
    if subscribers[key] == nil then return end
    subscriberCount = subscriberCount - 1
    subscribers[key] = nil
    verifiers[key] = nil
end

-- Force a refresh without waiting for a detected change. For a mod that does
-- something this service cannot see -- its own setMode, a model swap of its
-- own. Not needed for perspective, UI modes or loading.
local function refreshNow()
    fire(lastMode)
end

local function getMode()
    return camera.getMode()
end

local function isFirstPersonNow()
    return firstPerson
end

return {
    interfaceName = "AnimRefresh",
    interface = {
        version       = MY_VERSION,
        subscribe     = subscribe,
        unsubscribe   = unsubscribe,
        refreshNow    = refreshNow,
        getMode       = getMode,
        isFirstPerson = isFirstPersonNow,
    },
    engineHandlers = {
        onUpdate       = onUpdate,
        onLoad         = onLoad,
        UiModeChanged  = uiModeChanged,
    },
}
