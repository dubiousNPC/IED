---@omw-context player
local self    = require('openmw.self')
local core    = require('openmw.core')
local async   = require('openmw.async')
local storage = require('openmw.storage')
local common  = require('scripts.show-all-weapons.common')

local settings = storage.playerSection('Settings_ied_main')

local function push()
    core.sendGlobalEvent('DED_SetSettings', {
        showNpcs     = settings:get('SHOWNPCS')     ~= false,
        baseSlots    = settings:get('BASESLOTS')    or 'standard',
        showWeapons  = settings:get('SHOWWEAPONS')  ~= false,
        showShields  = settings:get('SHOWSHIELDS')  ~= false,
        showAmmo     = settings:get('SHOWAMMO')     ~= false,
        pollInterval = settings:get('POLLINTERVAL') or 0.5,
        npcRange     = settings:get('NPCRANGE')     or 3072,
    })
end

settings:subscribe(async:callback(push))

return {
    engineHandlers = {
        onUpdate = common.makeUpdateHandler(self, true),
        onActive = push,
    }
}
