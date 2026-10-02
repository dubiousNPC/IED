---@omw-context menu|local|player
-- Weapon display categories: one per sheath bone, each with the bones each
-- layer uses. Pure data, no requires -- the MENU settings page and the local
-- scripts both read it, and openmw.types is not available in menu context.
--
--   std  the bone OpenMW's own weapon sheathing uses (first layer)
--   alt  replacement for the first layer, from xbase_anim_ded2.nif ("Alt")
--   ded  the second layer, from DedBones.nif ("Ded")
--
-- A layer with no bone in the shipped NIFs is nil, and the settings page
-- offers no checkbox for it. Verified against the NIFs: there is no
-- `Bip01 SpearTwoWideDed`, no `Bip01 AttachShieldAlt`, and no Ded or Alt ammo
-- bone at all.

local M = {}

-- Settings-page order.
M.ORDER = {
    'shortBlade', 'longBlade', 'longBladeTwoHand', 'axe', 'axeTwoHand',
    'blunt', 'bluntTwoClose', 'bluntTwoWide', 'spear',
    'bow', 'crossbow', 'thrown', 'quiver', 'shield',
}

M.BY_ID = {
    shortBlade       = { std = "Bip01 ShortBladeOneHand",  alt = "Bip01 ShortBladeOneHandAlt",  ded = "Bip01 ShortBladeOneHandDed" },
    -- One-hand axes share the standard long blade bone: the sheathing
    -- skeleton's own `Bip01 AxeOneHand` is positioned for a very different
    -- silhouette. Both extra sets give axes their own bone.
    longBlade        = { std = "Bip01 LongBladeOneHand",   alt = "Bip01 LongBladeOneHandAlt",   ded = "Bip01 LongBladeOneHandDed" },
    axe              = { std = "Bip01 LongBladeOneHand",   alt = "Bip01 AxeOneHandAlt",         ded = "Bip01 AxeOneHandDed" },
    longBladeTwoHand = { std = "Bip01 LongBladeTwoClose",  alt = "Bip01 LongBladeTwoCloseAlt",  ded = "Bip01 LongBladeTwoCloseDed" },
    axeTwoHand       = { std = "Bip01 AxeTwoClose",        alt = "Bip01 AxeTwoCloseAlt",        ded = "Bip01 AxeTwoCloseDed" },
    blunt            = { std = "Bip01 BluntOneHand",       alt = "Bip01 BluntOneHandAlt",       ded = "Bip01 BluntOneHandDed" },
    bluntTwoClose    = { std = "Bip01 BluntTwoClose",      alt = "Bip01 BluntTwoCloseAlt",      ded = "Bip01 BluntTwoCloseDed" },
    bluntTwoWide     = { std = "Bip01 BluntTwoWide",       alt = "Bip01 BluntTwoWideAlt",       ded = "Bip01 BluntTwoWideDed" },
    spear            = { std = "Bip01 SpearTwoWide",       alt = "Bip01 SpearTwoWideAlt" },
    bow              = { std = "Bip01 MarksmanBow",        alt = "Bip01 MarksmanBowAlt",        ded = "Bip01 MarksmanBowDed" },
    crossbow         = { std = "Bip01 MarksmanCrossbow",   alt = "Bip01 MarksmanCrossbowAlt",   ded = "Bip01 MarksmanCrossbowDed" },
    thrown           = { std = "Bip01 MarksmanThrown",     alt = "Bip01 MarksmanThrownAlt",     ded = "Bip01 MarksmanThrownDed" },
    -- Numbered: "Bip01 Ammo 1", "Bip01 Ammo 2", ...
    quiver           = { std = "Bip01 Ammo" },
    shield           = { std = "Bip01 AttachShield",                                            ded = "Bip01 AttachShieldDed" },
}

-- Checkbox keys, in display order. Each is also an l10n key.
M.FLAG_ENABLED   = 'enabled'
M.FLAG_SECONDARY = 'secondary'
M.FLAG_ALTERNATE = 'alternate'
M.FLAG_NPC       = 'npc'

---The checkboxes a category gets: only the layers it has bones for.
---@param id string
---@return string[]
function M.flagsFor(id)
    local c = M.BY_ID[id]
    local keys = { M.FLAG_ENABLED }
    if c.ded then keys[#keys + 1] = M.FLAG_SECONDARY end
    if c.alt then keys[#keys + 1] = M.FLAG_ALTERNATE end
    keys[#keys + 1] = M.FLAG_NPC
    return keys
end

-- Defaults reproduce the old "Standard" behaviour: every category shown,
-- on the standard bones only, for the player and NPCs alike.
M.DEFAULT_FLAGS = {
    enabled   = true,
    secondary = false,
    alternate = false,
    npc       = true,
}

---@param id string
---@return table<string, boolean>
function M.defaultFor(id)
    local d = {}
    for _, k in ipairs(M.flagsFor(id)) do d[k] = M.DEFAULT_FLAGS[k] end
    return d
end

---Settings key for a category. Prefixed so it cannot collide with the
---general group's keys if the two are ever merged.
---@param id string
function M.settingKey(id)
    return 'CAT_' .. id
end

return M
