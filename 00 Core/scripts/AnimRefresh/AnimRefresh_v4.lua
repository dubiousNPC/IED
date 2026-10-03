---@omw-context player
--[[
    AnimRefresh v4 -- model-rebuild notifier

    Several things rebuild the player's animation object. Scripted animations
    and VFX attached to it are dropped when that happens, so a sitting pose, a
    sheathed instrument or a worn cosmetic silently vanishes. There is no "your
    VFX was removed" event to hook, so every mod that attaches something to the
    player has to notice for itself and re-attach.

    Fires on: crossing the first-person boundary, closing a UI mode that
    rebuilds the model (Rest, Travel, Training, Jail), and loading a save.

        I.AnimRefresh.subscribe("MyMod", function(mode, previousMode)
            -- re-issue whatever you own
        end)
        I.AnimRefresh.unsubscribe("MyMod")

    Callbacks MUST be idempotent -- remove then add, every time. They can be
    called when nothing was lost (on load, on joining, on a retry).

    Pass { verify = true } for one extra delivery VERIFY_DELAY after a boundary
    change, if re-attaching is invisible (removeVfx + addVfx). Leave it out if
    a second call is visible -- re-issuing a looping pose restarts it.

        I.AnimRefresh.subscribe("MyMod", cb, { verify = true })

    Return false ONLY for a transient not-ready state and you are called again
    every RETRY_DELAY, up to MAX_RETRIES times. A bone your skeleton simply
    does not have is not transient.

        I.AnimRefresh.subscribe("MyMod", function()
            if not animation.hasBone(self, MY_BONE) then return false end
            ...
        end)

    Never cache the interface; call through I.AnimRefresh each time.
]]

local camera = require('openmw.camera')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local MY_VERSION = 4

if I.AnimRefresh and I.AnimRefresh.version >= MY_VERSION then
    return
end

local POLL_INTERVAL = 0.1

local MAX_RETRIES = 2
local RETRY_DELAY = 0.10

local LOAD_DELAYS = { 0.10, 0.60 }

local JOIN_DELAY = 0.10

local VERIFY_DELAY = 1.0

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
        local callback = subscribers[key]
        if callback then
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

local function checkBoundary()
    if camera.getQueuedMode() ~= nil then return end

    local mode = camera.getMode()
    local nowFirst = mode == camera.MODE.FirstPerson
    local previous = lastMode
    lastMode = mode

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

local function uiModeChanged(data)
    if subscriberCount == 0 then return end
    if data and data.newMode == nil and data.oldMode and REBUILD_UI_MODES[data.oldMode] then
        fire(lastMode)
    end
end

local function onLoad()
    for _, delay in ipairs(LOAD_DELAYS) do
        async:newUnsavableSimulationTimer(delay, function() fire(lastMode) end)
    end
end

-- ---------------------------------------------------------------------------
-- INTERFACE
-- ---------------------------------------------------------------------------

local function subscribe(key, callback, opts)
    if type(key) ~= 'string' or key == '' then
        error(("[AnimRefresh] subscribe() needs a non-empty string key, got %s")
              :format(type(key) == 'string' and '""' or type(key)))
    end
    if callback ~= nil and type(callback) ~= 'function' then
        error(("[AnimRefresh] subscribe('%s', ...) needs a function, got %s")
              :format(key, type(callback)))
    end

    if subscribers[key] == nil and callback ~= nil then
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
    verifiers[key] = (callback ~= nil and opts and opts.verify) or nil

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
        onUpdate = onUpdate,
        onLoad   = onLoad,
    },
    -- UiModeChanged is an EVENT sent to player scripts, not an engine handler.
    -- Listed under engineHandlers the engine logs "Not supported handler" and
    -- never calls it, so the Rest/Travel/Training/Jail refresh never fired.
    eventHandlers = {
        UiModeChanged = uiModeChanged,
    },
}
