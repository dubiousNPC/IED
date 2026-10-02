-- Relative to the MOD ROOT, matching test_povrefresh.lua. It used to be
-- '../scripts/...', which only worked when run from tools/ -- so the two test
-- files in the same directory needed different working directories and one of
-- them silently failed to open its input.
local DIR='scripts/show-all-weapons/'
local fails=0
local function check(n,c,e) if c then print('  ok   '..n) else fails=fails+1; print('  FAIL '..n..' '..tostring(e or '')) end end

local W={ShortBladeOneHand=0,LongBladeOneHand=1,LongBladeTwoHand=2,BluntOneHand=3,
         BluntTwoClose=4,BluntTwoWide=5,SpearTwoWide=6,AxeOneHand=7,AxeTwoHand=8,
         MarksmanBow=9,MarksmanCrossbow=10,MarksmanThrown=11,Arrow=12,Bolt=13}
local world={vfx={},bones={},equip={},stance=0,cfg={},files={}}
local inv={}
local recs={}
local function mk(id,wtype,model)
    -- record.model is a VFS path: meshes/-prefixed, forward slashes, lowercase.
    local m = model or ('meshes/w/'..id..'.nif')
    recs[id]={id=id,type=wtype,model=m}
    world.files[m]=true
    return {recordId=id,count=1,type=nil} end

local WeaponT={TYPE=W, record=function(o) return recs[o.recordId] end,
               objectIsInstance=function(o) return recs[o.recordId]~=nil end}
local ArmorT={TYPE={Shield=8}, record=function(o) return recs[o.recordId] end,
              objectIsInstance=function(o) return recs[o.recordId]~=nil end}
local invObj={getAll=function(_,t)
        local out={}
        for _,i in ipairs(inv) do
            local r=recs[i.recordId]
            local isArmor = r and r.type==ArmorT.TYPE.Shield and r.armor
            if (t==ArmorT and isArmor) or (t==WeaponT and not isArmor) then out[#out+1]=i end
        end
        return out end,
    countOf=function(_,id) local n=0 for _,i in ipairs(inv) do if i.recordId==id then n=n+i.count end end return n end}

package.preload['openmw.types']=function() return {
    Weapon=WeaponT, Armor=ArmorT,
    Actor={inventory=function() return invObj end,
           getEquipment=function() return world.equip end,
           getStance=function() return world.stance end,
           STANCE={Nothing=0,Weapon=1,Spell=2},
           EQUIPMENT_SLOT={CarriedRight='CR',CarriedLeft='CL'},
           hasEquipped=function(_,it) return world.equip.CR==it or world.equip.CL==it
               or world.ammoEquipped==it end},
} end
package.preload['openmw.vfs']=function() return {fileExists=function(p)
    return world.files[p]==true end} end
package.preload['openmw.animation']=function() return {
    hasBone=function(_,b) return world.bones[b]==true end,
    addVfx=function(_,m,o)
        assert(type(m)=='string' and m:sub(1,7)=='meshes/' and not m:find('\\',1,true),
               'addVfx got a non-VFS path: '..tostring(m))
        assert(world.files[m], 'addVfx got a path not in the VFS: '..tostring(m))
        if world.vfx[o.boneName] then world.doubled=(world.doubled or 0)+1 end
        world.vfx[o.boneName]=o.vfxId end,
    removeVfx=function(_,id) for b,v in pairs(world.vfx) do if v==id then world.vfx[b]=nil end end end,
} end
-- cfg is read through a cache refreshed on subscribe, so the mock needs both
-- get and subscribe, and a way to fire the callback when world.cfg changes.
local cfgSubs={}
package.preload['openmw.storage']=function() return {
    globalSection=function()
        return dofile('tools/mock_storage.lua').section(function() return world.cfg end, cfgSubs)
    end } end
package.preload['openmw.async']=function() return {
    callback=function(_,f) return f end,
    newUnsavableSimulationTimer=function(_,_,f) f() end } end
package.preload['openmw.interfaces']=function() return {} end
package.preload['openmw.nearby']=function() return { players = {} } end
package.preload['scripts.show-all-weapons.categories']=function() return dofile(DIR..'categories.lua') end
package.preload['scripts.show-all-weapons.bones']=function() return dofile(DIR..'bones.lua') end

local bones=dofile(DIR..'bones.lua')
local categories=dofile(DIR..'categories.lua')
local common=dofile(DIR..'common.lua')

-- Settings are cached, not read live, so the test must push a change the same
-- way the engine would rather than mutating world.cfg silently.
local function setCfg(t)
    world.cfg=t
    for _,cb in ipairs(cfgSubs) do cb('DED_global', nil) end
end

print('bones.lua / categories.lua')
check('one-hand axes map to their own category', bones.categoryOf(W.AxeOneHand)=='axe')
check('arrows and bolts share the quiver category',
      bones.categoryOf(W.Arrow)=='quiver' and bones.categoryOf(W.Bolt)=='quiver')
check('axes still sheathe on the standard long blade bone',
      bones.standardBone(W.AxeOneHand)=='Bip01 LongBladeOneHand')
local function has(t,v) for _,x in ipairs(t) do if x==v then return true end end return false end
check('a full category offers all four checkboxes',
      #categories.flagsFor('longBlade')==4)
check('spears offer no secondary set (no SpearTwoWideDed)',
      not has(categories.flagsFor('spear'),'secondary') and has(categories.flagsFor('spear'),'alternate'))
check('shields offer no alternate (no AttachShieldAlt)',
      not has(categories.flagsFor('shield'),'alternate') and has(categories.flagsFor('shield'),'secondary'))
check('the quiver offers only show and NPCs',
      #categories.flagsFor('quiver')==2)
check('every category is mapped and ordered', (function()
    for _,id in ipairs(categories.ORDER) do if not categories.BY_ID[id] then return false end end
    return #categories.ORDER==14 end)())

for _,b in pairs({'Bip01 LongBladeOneHand','Bip01 ShortBladeOneHand','Bip01 AttachShield',
                  'Bip01 AxeTwoClose','Bip01 MarksmanBow','Bip01 AttachWeapon'}) do
    world.bones[b]=true
end

print('weapon sheathing clash')
-- equipped longsword, sheathed (engine owns Bip01 LongBladeOneHand);
-- inventory axe maps to the SAME bone
local sword=mk('longsword',W.LongBladeOneHand)
local axe  =mk('axe',W.AxeOneHand)
inv={sword,axe}
world.equip={CR=sword}; world.stance=0; world.doubled=0; world.vfx={}
common.handler(nil, sword, nil, false)
check('inventory axe does NOT stack on the engine-sheathed longsword',
      (world.doubled or 0)==0 and world.vfx['Bip01 LongBladeOneHand']==nil,
      'doubled='..tostring(world.doubled))

-- drawn: engine frees the bone, so the axe may use it
world.stance=1; world.doubled=0; world.vfx={}
common.handler(nil, sword, nil, true)
check('once the weapon is drawn the freed bone is reused',
      world.vfx['Bip01 LongBladeOneHand']=='saw_w_axe',
      tostring(world.vfx['Bip01 LongBladeOneHand']))

-- two inventory weapons that share a bone
inv={mk('ls2',W.LongBladeOneHand), mk('axe2',W.AxeOneHand)}
world.equip={}; world.stance=0; world.doubled=0; world.vfx={}
common.handler(nil, nil, nil, false)
check('two carried weapons sharing a bone do not overlap', (world.doubled or 0)==0,
      'doubled='..tostring(world.doubled))

print('shield sheathing clash')
local sh1=mk('shield1',nil); recs['shield1'].type=ArmorT.TYPE.Shield; recs['shield1'].armor=true
local sh2=mk('shield2',nil); recs['shield2'].type=ArmorT.TYPE.Shield; recs['shield2'].armor=true
inv={sh1,sh2}
world.equip={CL=sh1}; world.stance=0; world.doubled=0; world.vfx={}
common.handler(nil, nil, sh1, false)
check('carried shield does NOT stack on the engine-sheathed one',
      world.vfx['Bip01 AttachShield']==nil, tostring(world.vfx['Bip01 AttachShield']))
world.stance=1; world.vfx={}
common.handler(nil, nil, sh1, true)
check('with the shield drawn the back is free again',
      world.vfx['Bip01 AttachShield']~=nil)

print('settings')
-- handler's 5th arg is isPlayer.
local function asPlayer(w,sh,drawn) return common.handler(nil,w,sh,drawn,true) end
local function asNpc(w,sh,drawn)    return common.handler(nil,w,sh,drawn,nil)  end
local function count(prefix) local n=0 for _,v in pairs(world.vfx) do if tostring(v):find(prefix,1,true) then n=n+1 end end return n end

inv={mk('ls3',W.LongBladeOneHand), mk('sb3',W.ShortBladeOneHand)}
world.equip={}; world.vfx={}
setCfg{categories={longBlade={enabled=false}}}
asPlayer(nil,nil,false)
check('a disabled category hides only that category',
      world.vfx['Bip01 LongBladeOneHand']==nil and world.vfx['Bip01 ShortBladeOneHand']~=nil)
setCfg{}
world.vfx={}
asPlayer(nil,nil,false)
check('absent config behaves as enabled, not disabled', world.vfx['Bip01 LongBladeOneHand']~=nil)

setCfg{categories={longBlade={npc=false}}}
world.vfx={}; asNpc(nil,nil,false)
check('NPCs flag off: the category is hidden on NPCs',
      world.vfx['Bip01 LongBladeOneHand']==nil and world.vfx['Bip01 ShortBladeOneHand']~=nil)
world.vfx={}; asPlayer(nil,nil,false)
check('NPCs flag off: the player still shows it', world.vfx['Bip01 LongBladeOneHand']~=nil)

print('layers')
for _,b in ipairs({'Bip01 LongBladeOneHandDed','Bip01 LongBladeOneHandAlt',
                   'Bip01 AxeOneHandDed','Bip01 AxeOneHandAlt'}) do world.bones[b]=true end

inv={mk('ls9',W.LongBladeOneHand)}; world.equip={}; world.vfx={}
setCfg{}
asPlayer(nil,nil,false)
check('defaults use the standard bone only, even on a skeleton with Ded and Alt',
      world.vfx['Bip01 LongBladeOneHand']~=nil and world.vfx['Bip01 LongBladeOneHandDed']==nil
      and world.vfx['Bip01 LongBladeOneHandAlt']==nil)

world.vfx={}; setCfg{categories={longBlade={alternate=true}}}
asPlayer(nil,nil,false)
check('alternate moves the first layer to the Alt bone',
      world.vfx['Bip01 LongBladeOneHandAlt']~=nil and world.vfx['Bip01 LongBladeOneHand']==nil)

inv={mk('la',W.LongBladeOneHand), mk('lb',W.LongBladeOneHand)}; world.vfx={}
asPlayer(nil,nil,false)
check('alternate does not add a slot: a second blade has nowhere to go', count('saw_w_')==1, count('saw_w_'))

world.bones['Bip01 LongBladeOneHandAlt']=nil
inv={mk('ls11',W.LongBladeOneHand)}; world.vfx={}
asPlayer(nil,nil,false)
check('alternate falls back to standard when the Alt bone is absent',
      world.vfx['Bip01 LongBladeOneHand']~=nil, 'a missing bone is a SILENT no-show')
world.bones['Bip01 LongBladeOneHandAlt']=true

inv={mk('blade_a',W.LongBladeOneHand), mk('blade_b',W.LongBladeOneHand), mk('blade_c',W.LongBladeOneHand)}
world.vfx={}; world.doubled=0; setCfg{categories={longBlade={secondary=true}}}
asPlayer(nil,nil,false)
check('secondary fills the standard slot AND the Ded slot, and no third',
      world.vfx['Bip01 LongBladeOneHand']~=nil and world.vfx['Bip01 LongBladeOneHandDed']~=nil
      and count('saw_w_')==2 and (world.doubled or 0)==0, count('saw_w_'))

world.vfx={}; setCfg{categories={longBlade={secondary=true, alternate=true}}}
asPlayer(nil,nil,false)
check('alternate + secondary: Alt then Ded, standard left alone',
      world.vfx['Bip01 LongBladeOneHandAlt']~=nil and world.vfx['Bip01 LongBladeOneHandDed']~=nil
      and world.vfx['Bip01 LongBladeOneHand']==nil)

inv={mk('ls10',W.LongBladeOneHand), mk('axe10',W.AxeOneHand)}
world.vfx={}; world.doubled=0; setCfg{categories={axe={alternate=true}}}
asPlayer(nil,nil,false)
check('alternate axes get their own bone, so no collision with the long blade',
      world.vfx['Bip01 LongBladeOneHand']=='saw_w_ls10' and world.vfx['Bip01 AxeOneHandAlt']=='saw_w_axe10'
      and (world.doubled or 0)==0)

local eq=mk('blade_eq',W.LongBladeOneHand)
inv={eq, mk('blade_j',W.LongBladeOneHand)}
world.equip={CR=eq}; world.vfx={}; world.doubled=0
setCfg{categories={longBlade={secondary=true}}}
asPlayer(eq,nil,false)
check('an engine-sheathed weapon blocks only the standard slot',
      world.vfx['Bip01 LongBladeOneHand']==nil and world.vfx['Bip01 LongBladeOneHandDed']~=nil)
world.vfx={}; setCfg{categories={longBlade={alternate=true}}}
asPlayer(eq,nil,false)
check('with alternate, a carried blade sits on Alt beside the engine-sheathed one',
      world.vfx['Bip01 LongBladeOneHandAlt']=='saw_w_blade_j')
world.equip={}

inv={mk('blade_f',W.LongBladeOneHand), mk('blade_g',W.LongBladeOneHand)}
world.vfx={}; setCfg{categories={longBlade={secondary=true}}}
asNpc(nil,nil,false)
check('layer flags apply to NPCs too', count('saw_w_')==2, count('saw_w_'))

world.bones['Bip01 SpearTwoWide']=true; world.bones['Bip01 SpearTwoWideDed']=true
inv={mk('sp1',W.SpearTwoWide), mk('sp2',W.SpearTwoWide)}; world.vfx={}
setCfg{categories={spear={secondary=true}}}
asPlayer(nil,nil,false)
check('a stored flag for a layer the category lacks is ignored',
      count('saw_w_')==1 and world.vfx['Bip01 SpearTwoWideDed']==nil)
world.bones['Bip01 SpearTwoWideDed']=nil

print('shields')
world.bones['Bip01 AttachShieldDed']=true
local sa=mk('sh_a'); recs['sh_a'].type=ArmorT.TYPE.Shield; recs['sh_a'].armor=true
local sb=mk('sh_b'); recs['sh_b'].type=ArmorT.TYPE.Shield; recs['sh_b'].armor=true
local sc=mk('sh_c'); recs['sh_c'].type=ArmorT.TYPE.Shield; recs['sh_c'].armor=true
inv={sa,sb,sc}; world.equip={}; world.vfx={}; setCfg{}
asPlayer(nil,nil,false)
check('by default one shield, on the standard bone',
      count('saw_sh_')==1 and world.vfx['Bip01 AttachShield']~=nil)
world.vfx={}; setCfg{categories={shield={secondary=true}}}
asPlayer(nil,nil,false)
check('secondary adds exactly one more shield, on the Ded bone',
      count('saw_sh_')==2 and world.vfx['Bip01 AttachShieldDed']~=nil)
world.equip={CL=sa}; world.vfx={}
asPlayer(nil,sa,false)
check('equipped shield sheathed: a carried one still shows on Ded',
      world.vfx['Bip01 AttachShield']==nil and world.vfx['Bip01 AttachShieldDed']~=nil)
world.equip={}
world.vfx={}; setCfg{categories={shield={enabled=false}}}
asPlayer(nil,nil,false)
check('shields disabled: none shown', count('saw_sh_')==0)

print('quiver')
world.bones['Bip01 Ammo 1']=true; world.bones['Bip01 Ammo 2']=true
local bow=mk('bow1',W.MarksmanBow); local arrow=mk('arrow1',W.Arrow); arrow.count=5
world.bones['Bip01 MarksmanBow']=true
inv={bow,arrow}; world.equip={}; world.ammoEquipped=arrow
world.vfx={}; setCfg{}
asPlayer(nil,nil,false)
check('the quiver shows with a carried bow', count('saw_ammo_')==2, count('saw_ammo_'))
world.vfx={}; setCfg{categories={quiver={enabled=false}}}
asPlayer(nil,nil,false)
check('quiver disabled: no arrows, bow still shown',
      count('saw_ammo_')==0 and world.vfx['Bip01 MarksmanBow']~=nil)
world.ammoEquipped=nil
setCfg{}

print('perspective switch (the reported bug)')
-- Reproduce it exactly: subscribe through the real interface, then fire the
-- callback while the skeleton reports no bones -- as it does for a moment after
-- the animation object is rebuilt.
local subs = {}
package.loaded['openmw.interfaces'] = nil
package.preload['openmw.interfaces'] = function() return {
    AnimRefresh = { subscribe = function(k,cb) subs[k]=cb end,
                    unsubscribe = function(k) subs[k]=nil end },
} end
local common2 = dofile(DIR..'common.lua')

inv={mk('sword_a',W.LongBladeOneHand)}
world.equip={}; world.stance=0; world.vfx={}
setCfg{}
for b in pairs({['Bip01 LongBladeOneHand']=1,['Bip01 AttachShield']=1}) do world.bones[b]=true end

local update = common2.makeUpdateHandler({}, true)
check('IED subscribes to AnimRefresh', subs['InventoryEquipmentDisplay']~=nil)

update(99)                       -- first pass builds
check('gear shows normally', world.vfx['Bip01 LongBladeOneHand']~=nil)

-- the skeleton is mid-rebuild: every bone reports missing
local saved = {}
for k,v in pairs(world.bones) do saved[k]=v end
world.bones={}
world.vfx={}
local answer = subs['InventoryEquipmentDisplay']()
check('a rebuild into a half-built skeleton attaches nothing',
      next(world.vfx)==nil)
check('and it tells AnimRefresh to ask again',
      answer==false,
      'returning nil here is what lost the gear until the next stance change')

-- skeleton finishes rebuilding; AnimRefresh retries
world.bones = saved
local answer2 = subs['InventoryEquipmentDisplay']()
check('the retry restores the gear', world.vfx['Bip01 LongBladeOneHand']~=nil)
check('and reports ready', answer2 ~= false)

-- and a normal refresh with nothing to draw is NOT a false not-ready
inv={}; world.vfx={}
check('empty inventory reports ready, not a retry loop',
      subs['InventoryEquipmentDisplay']() ~= false)

print('readiness is transient-only')
-- The log spam: a bone that is simply not on this skeleton must NOT be
-- reported as not-ready, or AnimRefresh retries and logs a give-up line on
-- every perspective change, forever.
inv={mk('spear1',W.SpearTwoWide)}
world.equip={}; world.vfx={}
setCfg{categories={spear={alternate=true}}}
-- The Alt spear bone is absent from this skeleton; the standard one exists.
world.bones['Bip01 SpearTwoWideAlt']=nil
world.bones['Bip01 SpearTwoWide']=true
world.bones['Bip01 AttachShield']=true
local r1 = common.handler(nil,nil,nil,false,true)
check('a bone absent from a LIVE skeleton reports ready', r1 ~= false,
      'this is what produced "still not ready after 2 attempts" on every POV change')

-- A skeleton mid-rebuild resolves nothing at all -- that IS transient.
local saved = {}
for k,v in pairs(world.bones) do saved[k]=v end
world.bones = {}
world.vfx = {}
local r2 = common.handler(nil,nil,nil,false,true)
check('a skeleton where NOTHING resolves reports not-ready', r2 == false)
world.bones = saved

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
