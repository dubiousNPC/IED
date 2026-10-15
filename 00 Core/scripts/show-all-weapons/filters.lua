---@omw-context menu|local|player|global
-- NPC display filters: preset class groups, faction families and cell keyword
-- groups. Pure data, no requires -- the MENU settings page, the PLAYER/GLOBAL
-- relay and the NPC scripts all read it.
--
-- Every id here is lowercase. Record ids from the engine are compared
-- lowercased, and ids typed into the settings lists are trimmed and lowercased
-- before use, so case never decides a match.

local M = {}

-- ---------------------------------------------------------------------------
-- CLASS GROUPS -- one checkbox each in the class blacklist.
-- A class may sit in several groups (healer service, scout, smith, warrior);
-- ticking either group blacklists it.
-- ---------------------------------------------------------------------------
M.CLASS_GROUP_ORDER = {
    'commoner', 'publican', 'miner', 'trader', 'alchemist', 'fighting',
}

M.CLASS_GROUPS = {
    publican = { 'publican', 't_glb_publican' },
    alchemist = {
        'healer service', 'alchemist service', 'apothecary service',
        't_glb_apothecaryservice',
    },
    commoner = {
        'commoner', 'slave', 'pilgrim', 'pauper', 't_glb_commoner', 't_glb_pauper',
    },
    miner = { 'miner', 't_glb_miner', 'farmer' },
    trader = {
        'trader service', 'trader', 'bookseller', 't_glb_traderservice',
        't_glb_trader', 'enchanter', 'enchanter service', 'smith', 'clothier',
        'pawnbroker', 'spellsword',
    },
    fighting = {
        'drillmaster', 'drillmaster service', 'master-at-arms', 'scout', 'rogue',
        'crusader', 'smith', 'warrior',
    },
}

-- ---------------------------------------------------------------------------
-- FACTION FAMILIES -- factions sharing a family are treated as one faction:
-- whitelisting any member whitelists the whole family.
-- ---------------------------------------------------------------------------
M.FACTION_FAMILY = {
    ['imperial legion']       = 'imperial',
    ['census and excise']     = 'imperial',
    ['t_cyr_censusandexcise'] = 'imperial',
    ['t_cyr_imperiallegion']  = 'imperial',
    ['t_cyr_imperialnavy']    = 'imperial',
    ['t_mw_imperialnavy']     = 'imperial',
    ['imperial knights']      = 'imperial',
    ['royal guard']           = 'imperial',
    ['east empire company']   = 'imperial',
    ['dat_imperialcuria']     = 'imperial',
    ['temple']                = 'temple',
    ['t_mw_ordinators']       = 'temple',
    ['t_mw_houseindoril']     = 'temple',
}

-- ---------------------------------------------------------------------------
-- CELL GROUPS -- one checkbox each in the cell blacklist. A cell matches when
-- any keyword is a substring of its lowercased name or id.
-- ---------------------------------------------------------------------------
M.CELL_GROUP_ORDER = { 'library', 'holyGround' }

M.CELL_GROUPS = {
    library    = { 'bookseller', 'rare books', 'guild of mages', 'library' },
    holyGround = { 'temple', 'chapel', 'shrine', 'high fane', 'monastery' },
}

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

---Trimmed, lowercased; nil for anything that is not a non-empty string.
---@param s any
---@return string|nil
function M.normalize(s)
    if type(s) ~= 'string' then return nil end
    s = s:match('^%s*(.-)%s*$'):lower()
    if s == '' then return nil end
    return s
end

local function addSetKeys(out, set)
    if type(set) ~= 'table' then return end
    for k, v in pairs(set) do
        local id = v == true and M.normalize(k) or nil
        if id then out[id] = true end
    end
end

---Blacklisted class ids: every member of each ticked group, plus typed ids.
---@param groups table<string, boolean>|nil  multiCheckbox value
---@param ids table<string, boolean>|nil     textSet value
---@return table<string, true>
function M.buildClassSet(groups, ids)
    local out = {}
    if type(groups) == 'table' then
        for _, g in ipairs(M.CLASS_GROUP_ORDER) do
            if groups[g] == true then
                for _, c in ipairs(M.CLASS_GROUPS[g]) do out[c] = true end
            end
        end
    end
    addSetKeys(out, ids)
    return out
end

---Whitelisted faction ids, each typed id expanded to its whole family.
---@param ids table<string, boolean>|nil textSet value
---@return table<string, true>
function M.buildFactionSet(ids)
    local typed = {}
    addSetKeys(typed, ids)
    local families = {}
    local out = {}
    for id in pairs(typed) do
        out[id] = true
        local fam = M.FACTION_FAMILY[id]
        if fam then families[fam] = true end
    end
    for faction, fam in pairs(M.FACTION_FAMILY) do
        if families[fam] then out[faction] = true end
    end
    return out
end

---Cell keywords: every keyword of each ticked group, plus typed entries.
---Returned as an array, since matching is by substring.
---@param groups table<string, boolean>|nil multiCheckbox value
---@param ids table<string, boolean>|nil    textSet value
---@return string[]
function M.buildCellKeywords(groups, ids)
    local set = {}
    if type(groups) == 'table' then
        for _, g in ipairs(M.CELL_GROUP_ORDER) do
            if groups[g] == true then
                for _, k in ipairs(M.CELL_GROUPS[g]) do set[k] = true end
            end
        end
    end
    addSetKeys(set, ids)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

---Whether a cell's name or id contains any keyword.
---@param keywords string[]
---@param name string|nil
---@param id string|nil
function M.cellMatches(keywords, name, id)
    if #keywords == 0 then return false end
    name = type(name) == 'string' and name:lower() or ''
    id   = type(id)   == 'string' and id:lower()   or ''
    for i = 1, #keywords do
        local k = keywords[i]
        if name:find(k, 1, true) or id:find(k, 1, true) then return true end
    end
    return false
end

---Settings defaults: nothing filtered.
function M.defaults()
    local classGroups, cellGroups = {}, {}
    for _, g in ipairs(M.CLASS_GROUP_ORDER) do classGroups[g] = false end
    for _, g in ipairs(M.CELL_GROUP_ORDER) do cellGroups[g] = false end
    return {
        classGroups = classGroups,
        classIds    = {},
        cellGroups  = cellGroups,
        cellIds     = {},
        factionIds  = {},
    }
end

return M
