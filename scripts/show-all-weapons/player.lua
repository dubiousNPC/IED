---@omw-context player
local self       = require('openmw.self')
local core       = require('openmw.core')
local async      = require('openmw.async')
local storage    = require('openmw.storage')
local common     = require('scripts.show-all-weapons.common')
local categories = require('scripts.show-all-weapons.categories')

local general = storage.playerSection('Settings_DED_main')
local weapons = storage.playerSection('Settings_DED_weapons')

local function readCategories()
    local out = {}
    for _, id in ipairs(categories.ORDER) do
        -- getCopy: the value is a table, and get() would hand back a
        -- read-only view tied to this section.
        out[id] = weapons:getCopy(categories.settingKey(id)) or categories.defaultFor(id)
    end
    return out
end

local function push()
    core.sendGlobalEvent('DED_SetSettings', {
        showNpcs     = general:get('SHOWNPCS')     ~= false,
        pollInterval = general:get('POLLINTERVAL') or 0.5,
        npcRange     = general:get('NPCRANGE')     or 3072,
        categories   = readCategories(),
    })
end

general:subscribe(async:callback(push))
weapons:subscribe(async:callback(push))

-- The player's own handlers come from common (no onUpdate; see the note on
-- makeUpdateHandler), with `push` folded into onActive so the global section
-- is re-seeded on every load as well as on every settings change.
local handlers = common.makeUpdateHandler(self, true)
local commonActive = handlers.onActive
handlers.onActive = function()
    push()
    commonActive()
end
handlers.onLoad = handlers.onActive

return {
    engineHandlers = handlers,
}
