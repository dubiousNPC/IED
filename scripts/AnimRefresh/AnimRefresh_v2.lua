---@omw-context player
--[[
    AnimRefresh v1 -- perspective-change notifier

    THE PROBLEM
    -----------
    Switching perspective rebuilds the player's animation object. Scripted
    animations and VFX attached to it are dropped in the process, so a sitting
    pose or a riding pose silently vanishes the moment the player presses the
    POV key. The usual "fix" is to lock the camera, which is what Devilish
    Horse/Guar Riding does (forceFirstPerson re-asserted on a timer). That
    trades the bug for a worse restriction: you can no longer look at the
    animation you are paying for.

    THE APPROACH
    ------------
    Lifted from Sun's Dusk p_backpacks.lua, which has the same problem with a
    backpack VFX and solves it by tracking the last camera mode, and on change
    removing and re-adding the effect. Two details from that implementation are
    worth copying exactly and are easy to miss:

      * the refresh must be DEFERRED, not immediate. Right after the switch the
        new skeleton may not be ready; Sun's Dusk guards with
        animation.hasBone and retries once on a 0.1s timer if the bone is
        missing.
      * it does not run on the per-frame job list. It sits on Sun's Dusk's
        "sluggish" (throttled) list, so even a mod of that size does not check
        camera mode every frame.

    DETECTION -- event first, poll as backstop
    ------------------------------------------
    Deliberate POV presses are caught by a TogglePOV trigger handler, which is
    instant and costs nothing when not pressed. That covers the case the player
    actually notices.

    A mode change can also happen without that key: vanity mode kicking in
    after idle, preview mode while the key is held, another mod calling
    setMode, or this mod's own setMode. Those are caught by a throttled poll
    at POLL_INTERVAL (default 1.0s, honouring the suite's "no more than once
    per second" rule). One second of latency is fine for those cases precisely
    because the player did not ask for them.

    The poll lives in onUpdate, not onFrame. onUpdate is the gameplay handler
    and is skipped while the game is paused, which is correct here -- you
    cannot change perspective from a menu. onFrame would only be needed for
    work that must continue during a pause.

    COST WHEN IDLE
    --------------
    With no subscribers, onUpdate does one table-empty check and returns. The
    trigger handler is not even reached unless the key is pressed. Subscribers
    unsubscribe when they stop animating, so a player who is neither sitting
    nor riding pays essentially nothing.

    USAGE
    -----
        I.AnimRefresh.subscribe("MyMod", function(mode, previousMode)
            -- re-issue whatever scripted animation you own.
            -- Return false if the model was not ready yet and you want one
            -- more attempt; anything else means delivered.
            if not anim.hasBone(self, MY_BONE) then return false end
            reissueMyPose()
        end)
        I.AnimRefresh.unsubscribe("MyMod")

    Bundle this file in every mod that needs it, like SharedRay: the version
    guard below means only the newest loaded copy actually runs.

    VERSION 2 adds the retry described under DELIVERY. The bump is not
    cosmetic: the guard is `>=`, so two copies both claiming version 1 resolve
    by load order -- an improved v1 shipped next to somebody else's old v1 is a
    coin flip. Any change to delivery behaviour needs the number raised or it
    may simply not run.
]]

local camera = require('openmw.camera')
local input  = require('openmw.input')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 2

if I.AnimRefresh and I.AnimRefresh.version >= MY_VERSION then
    return
end

-- How long to wait after a detected change before telling subscribers. The
-- animation object is being rebuilt during this window; firing immediately
-- means re-issuing an animation onto a skeleton that is about to be replaced.
local SETTLE_DELAY = 0.10

-- Backstop poll rate for mode changes that arrive without a TogglePOV press.
local POLL_INTERVAL = 1.0

local subscribers   = {}
local subscriberCount = 0
local lastMode      = camera.getMode()
local pollTimer     = 0
local pendingSettle = false

-- ---------------------------------------------------------------------------
-- DELIVERY
-- ---------------------------------------------------------------------------

-- A subscriber that returns exactly `false` is saying "the model was not ready,
-- ask me again". Anything else -- nil, true, a value -- counts as delivered, so
-- existing callbacks are unaffected.
--
-- WHY THIS EXISTS. SETTLE_DELAY is one fixed guess at how long a skeleton
-- rebuild takes. Version 1 fired once and then re-baselined lastMode, so a
-- subscriber that guessed wrong never heard about that change again and its
-- pose or VFX was lost for the session. Sun's Dusk's original does better:
-- it guards with animation.hasBone and retries once.
--
-- This service cannot apply that guard itself -- it has no idea which bone a
-- subscriber cares about. So the test is inverted: the subscriber, which does
-- know, reports readiness by return value and this schedules the retry.
--
-- Retry ONCE, never in a loop. A bone still missing after two attempts is
-- usually a missing skeleton, not a race, and a permanent retry would be a
-- per-subscriber timer running forever.
local MAX_RETRIES = 1
local RETRY_DELAY = 0.10

local deliver   -- forward declaration: deliver reschedules itself

deliver = function(keys, mode, previous, attempt)
    local notReady = nil

    for key in pairs(keys) do
        -- Re-read from `subscribers`: a retry can land after the subscriber
        -- unsubscribed, and calling a stale callback is exactly the kind of
        -- ghost this service should not create.
        local callback = subscribers[key]
        if callback then
            local ok, result = pcall(callback, mode, previous)
            if not ok then
                print("[AnimRefresh] callback error in '" .. tostring(key) .. "': " .. tostring(result))
            elseif result == false then
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

-- A subscriber blowing up must not stop delivery to the others, same rule
-- SharedRay applies to its callbacks.
local function fire(mode, previous)
    local all = {}
    for key in pairs(subscribers) do all[key] = true end
    deliver(all, mode, previous, 0)
end

local function scheduleRefresh(previous)
    if pendingSettle then return end   -- collapse a burst of changes into one
    pendingSettle = true
    async:newUnsavableSimulationTimer(SETTLE_DELAY, function()
        pendingSettle = false
        local mode = camera.getMode()
        lastMode = mode
        if subscriberCount == 0 then return end
        fire(mode, previous)
    end)
end

local function checkMode()
    local mode = camera.getMode()
    if mode == lastMode then return end
    local previous = lastMode
    lastMode = mode
    scheduleRefresh(previous)
end

-- ---------------------------------------------------------------------------
-- DETECTION
-- ---------------------------------------------------------------------------

-- Registered defensively: TogglePOV is an engine trigger, but trigger keys are
-- registered by built-in scripts and a stripped or modified setup may not have
-- it. If it is absent the poll below still catches everything, just later.
if input.triggers and input.triggers.TogglePOV then
    input.registerTriggerHandler("TogglePOV", async:callback(function()
        if subscriberCount == 0 then return end
        -- The mode has not actually changed yet at trigger time, so schedule
        -- off the press rather than comparing modes here.
        scheduleRefresh(lastMode)
    end))
end

local function onUpdate(dt)
    if subscriberCount == 0 then return end

    pollTimer = pollTimer + dt
    if pollTimer < POLL_INTERVAL then return end
    pollTimer = 0
    checkMode()
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

local function subscribe(key, callback)
    if not key then return end
    if subscribers[key] == nil and callback ~= nil then
        subscriberCount = subscriberCount + 1
    elseif subscribers[key] ~= nil and callback == nil then
        subscriberCount = subscriberCount - 1
    end
    subscribers[key] = callback
    -- Re-baseline so a subscriber joining just after a switch does not get an
    -- immediate spurious refresh for a change it was never present for.
    lastMode = camera.getMode()
    pollTimer = 0
end

local function unsubscribe(key)
    subscribe(key, nil)
end

-- Force a refresh without waiting for a detected change. Useful right after
-- your own setMode call, or after a UI mode that rebuilds the model (Sun's
-- Dusk refreshes its VFX after Rest and Travel menus for exactly this reason).
local function refreshNow()
    scheduleRefresh(lastMode)
end

local function getMode()
    return lastMode
end

return {
    interfaceName = "AnimRefresh",
    interface = {
        version     = MY_VERSION,
        subscribe   = subscribe,
        unsubscribe = unsubscribe,
        refreshNow  = refreshNow,
        getMode     = getMode,
    },
    engineHandlers = {
        onUpdate = onUpdate,
    },
}
