---@omw-context player
local self       = require('openmw.self')
local core       = require('openmw.core')
local async      = require('openmw.async')
local storage    = require('openmw.storage')
local common     = require('scripts.show-all-weapons.common')
local categories = require('scripts.show-all-weapons.categories')
local filters    = require('scripts.show-all-weapons.filters')

local general = storage.playerSection('Settings_DED_main')
local weapons = storage.playerSection('Settings_DED_weapons')
local npcs    = storage.playerSection('Settings_DED_npcs')

local function readCategories()
    local out = {}
    for _, id in ipairs(categories.ORDER) do
        -- getCopy: the value is a table, and get() would hand back a
        -- read-only view tied to this section.
        out[id] = weapons:getCopy(categories.settingKey(id)) or categories.defaultFor(id)
    end
    return out
end

-- All five are tables (multiCheckbox / textSet values), so getCopy.
local function readFilters()
    local d = filters.defaults()
    return {
        classGroups = npcs:getCopy('CLASS_GROUPS') or d.classGroups,
        classIds    = npcs:getCopy('CLASS_IDS')    or d.classIds,
        cellGroups  = npcs:getCopy('CELL_GROUPS')  or d.cellGroups,
        cellIds     = npcs:getCopy('CELL_IDS')     or d.cellIds,
        factionIds  = npcs:getCopy('FACTION_IDS')  or d.factionIds,
    }
end

local function push()
    core.sendGlobalEvent('DED_SetSettings', {
        showNpcs     = general:get('SHOWNPCS')     ~= false,
        pollInterval = general:get('POLLINTERVAL') or 0.5,
        npcRange     = general:get('NPCRANGE')     or 3072,
        categories   = readCategories(),
        filters      = readFilters(),
    })
end

general:subscribe(async:callback(push))
weapons:subscribe(async:callback(push))
npcs:subscribe(async:callback(push))

return {
    engineHandlers = {
        onUpdate = common.makeUpdateHandler(self, true),
        onActive = push,
    }
}
