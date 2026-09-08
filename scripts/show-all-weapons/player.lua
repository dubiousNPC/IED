---@omw-context player
local self    = require('openmw.self')
local core    = require('openmw.core')
local async   = require('openmw.async')
local storage = require('openmw.storage')
local common  = require('scripts.show-all-weapons.common')

local settings = storage.playerSection('Settings_ied_main')

-- The player script is the only context that can read the settings page, so it
-- is also the only one that can tell the rest of the mod about it. Pushed on
-- activation and on every change; global.lua relays it to a section NPC scripts
-- can read.
local function push()
    core.sendGlobalEvent('IED_SetSettings', {
        showNpcs     = settings:get('SHOWNPCS')     ~= false,
        baseSlots    = settings:get('BASESLOTS')    or 'standard',
        showWeapons  = settings:get('SHOWWEAPONS')  ~= false,
        showShields  = settings:get('SHOWSHIELDS')  ~= false,
        showAmmo     = settings:get('SHOWAMMO')     ~= false,
        pollInterval = settings:get('POLLINTERVAL') or 0.5,
    })
end

settings:subscribe(async:callback(push))

return {
    engineHandlers = {
        -- onUpdate, not onFrame. onFrame also runs while the game is paused,
        -- which is pointless here, and the two scripts used different handlers
        -- for identical work.
        onUpdate = common.makeUpdateHandler(self, true),
        onActive = push,
    }
}
