local DIR='iedsem/IED/scripts/show-all-weapons/'
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
    globalSection=function() return {
        get=function(_,k) return world.cfg[k] end,
        subscribe=function(_,cb) cfgSubs[#cfgSubs+1]=cb end,
    } end } end
package.preload['openmw.async']=function() return {
    callback=function(_,f) return f end,
    newUnsavableSimulationTimer=function(_,_,f) f() end } end
package.preload['openmw.interfaces']=function() return {} end
package.preload['scripts.show-all-weapons.bones']=function() return dofile(DIR..'bones.lua') end

local bones=dofile(DIR..'bones.lua')
local common=dofile(DIR..'common.lua')

-- Settings are cached, not read live, so the test must push a change the same
-- way the engine would rather than mutating world.cfg silently.
local function setCfg(t)
    world.cfg=t
    for _,cb in ipairs(cfgSubs) do cb('IED_global', nil) end
end

print('bones.lua')
local shared=bones.sharedBones()
check('shared bones are computed, not listed',
      shared['Bip01 LongBladeOneHand']==true and shared['Bip01 Ammo']==true)
check('unshared bones are not flagged', shared['Bip01 ShortBladeOneHand']==nil)

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
inv={mk('ls3',W.LongBladeOneHand)}
world.equip={}; world.vfx={}; setCfg{showWeapons=false}
common.handler(nil,nil,nil,false)
check('showWeapons=false hides carried weapons', next(world.vfx)==nil)
setCfg{}
world.vfx={}
common.handler(nil,nil,nil,false)
check('absent config behaves as enabled, not disabled', next(world.vfx)~=nil)

print('base slots')
-- handler's 5th arg is isPlayer; combined is player-only.
local function asPlayer(w,sh,drawn) common.handler(nil,w,sh,drawn,true) end
local function asNpc(w,sh,drawn)    common.handler(nil,w,sh,drawn,nil)  end
-- Standard must never use Sem bones, even on a skeleton that has them.
world.bones['Bip01 LongBladeOneHandSem']=true
world.bones['Bip01 AxeOneHandSem']=true
inv={mk('ls9',W.LongBladeOneHand)}; world.equip={}; world.vfx={}
setCfg{baseSlots='standard'}
common.handler(nil,nil,nil,false)
check('standard uses the original _sh slot',
      world.vfx['Bip01 LongBladeOneHand']~=nil and world.vfx['Bip01 LongBladeOneHandSem']==nil)

world.vfx={}; setCfg{baseSlots='alternative'}
common.handler(nil,nil,nil,false)
check('alternative uses the _Sem slot',
      world.vfx['Bip01 LongBladeOneHandSem']~=nil and world.vfx['Bip01 LongBladeOneHand']==nil)

-- On Sem, axes get their own bone, so the standard collision disappears.
inv={mk('ls10',W.LongBladeOneHand), mk('axe10',W.AxeOneHand)}
world.vfx={}; world.doubled=0
common.handler(nil,nil,nil,false)
check('alternative gives axes their own bone, so no collision',
      world.vfx['Bip01 LongBladeOneHandSem']~=nil
      and world.vfx['Bip01 AxeOneHandSem']~=nil and (world.doubled or 0)==0)

-- A skeleton without the Sem bones must fall back, not show nothing.
world.bones['Bip01 LongBladeOneHandSem']=nil
world.bones['Bip01 AxeOneHandSem']=nil
inv={mk('ls11',W.LongBladeOneHand)}; world.vfx={}
setCfg{baseSlots='alternative'}
common.handler(nil,nil,nil,false)
check('alternative falls back to standard when the Sem bones are absent',
      world.vfx['Bip01 LongBladeOneHand']~=nil,
      'a missing bone is a SILENT no-show, so this must be checked')

-- unset config must not break
world.vfx={}; setCfg{}
common.handler(nil,nil,nil,false)
check('unset baseSlots behaves as standard', world.vfx['Bip01 LongBladeOneHand']~=nil)

print('combined mode')
world.bones['Bip01 LongBladeOneHandSem']=true
world.bones['Bip01 AxeOneHandSem']=true
world.bones['Bip01 AttachShieldSem']=true

-- two DIFFERENT long blades: standard takes the first, Sem the second
inv={mk('blade_a',W.LongBladeOneHand), mk('blade_b',W.LongBladeOneHand)}
world.equip={}; world.vfx={}; world.doubled=0
setCfg{baseSlots='combined'}
asPlayer(nil,nil,false)
check('combined fills the standard slot AND the Sem slot',
      world.vfx['Bip01 LongBladeOneHand']~=nil
      and world.vfx['Bip01 LongBladeOneHandSem']~=nil
      and (world.doubled or 0)==0)

-- a third has nowhere to go
inv={mk('blade_c',W.LongBladeOneHand), mk('blade_d',W.LongBladeOneHand),
     mk('blade_e',W.LongBladeOneHand)}
world.vfx={}; world.doubled=0
asPlayer(nil,nil,false)
local n=0; for _ in pairs(world.vfx) do n=n+1 end
check('combined adds exactly one extra slot, not unlimited', n==2 and (world.doubled or 0)==0, n)

-- NO second shield
local sa=mk('sh_a'); recs['sh_a'].type=ArmorT.TYPE.Shield; recs['sh_a'].armor=true
local sb=mk('sh_b'); recs['sh_b'].type=ArmorT.TYPE.Shield; recs['sh_b'].armor=true
inv={sa,sb}; world.equip={}; world.vfx={}
asPlayer(nil,nil,false)
local shields=0
for _,v in pairs(world.vfx) do if tostring(v):find('saw_sh_') then shields=shields+1 end end
check('combined does NOT add a second shield', shields==1, shields)
check('combined puts the shield on the STANDARD bone',
      world.vfx['Bip01 AttachShield']~=nil and world.vfx['Bip01 AttachShieldSem']==nil)

-- NO second quiver: Arrow has no Sem override
world.bones['Bip01 Ammo 1']=true; world.bones['Bip01 Ammo 2']=true
local bow=mk('bow1',W.MarksmanBow); local arrow=mk('arrow1',W.Arrow)
inv={bow,arrow}; world.equip={}; world.ammoEquipped=arrow
world.vfx={}
asPlayer(nil,nil,false)
check('combined does NOT add a second quiver bone',
      world.vfx['Bip01 AmmoSem']==nil and world.vfx['Bip01 AmmoSem 1']==nil)
world.ammoEquipped=nil

-- player only
inv={mk('blade_f',W.LongBladeOneHand), mk('blade_g',W.LongBladeOneHand)}
world.equip={}; world.vfx={}
asNpc(nil,nil,false)
check('combined is ignored on NPCs, which get standard',
      world.vfx['Bip01 LongBladeOneHand']~=nil
      and world.vfx['Bip01 LongBladeOneHandSem']==nil)

-- standard is always the fallback
world.bones['Bip01 LongBladeOneHandSem']=nil
world.bones['Bip01 AxeOneHandSem']=nil
inv={mk('blade_h',W.LongBladeOneHand), mk('blade_i',W.LongBladeOneHand)}
world.vfx={}
asPlayer(nil,nil,false)
check('combined degrades to standard when the Sem bones are absent',
      world.vfx['Bip01 LongBladeOneHand']~=nil)

-- the engine's sheathed weapon holds the standard bone; the Sem slot stays open
world.bones['Bip01 LongBladeOneHandSem']=true
local eq=mk('blade_eq',W.LongBladeOneHand)
inv={eq, mk('blade_j',W.LongBladeOneHand)}
world.equip={CR=eq}; world.vfx={}; world.doubled=0
asPlayer(eq,nil,false)
check('an engine-sheathed weapon blocks only the standard slot',
      world.vfx['Bip01 LongBladeOneHand']==nil
      and world.vfx['Bip01 LongBladeOneHandSem']~=nil
      and (world.doubled or 0)==0)

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
