-- Run the REAL AnimRefresh_v3 and the REAL common.lua together and drive a
-- perspective change through the actual timer/trigger machinery.
-- Drives the REAL AnimRefresh and the REAL common.lua together through a
-- simulated perspective switch. The earlier suite mocked AnimRefresh, so it
-- tested IED's callback in isolation and could not see that the SERVICE was
-- losing the change (RESEARCH 4.6: a mock must exercise the path the engine
-- takes). Run from the mod root.
local A='scripts/AnimRefresh/AnimRefresh_v4.lua'
local C='scripts/show-all-weapons/common.lua'

local world={vfx={},bones={},files={},equip={},stance=0,cfg={},mode='third'}
-- One simulated clock for BOTH scripts: AnimRefresh's settle timer and IED's
-- self-re-arming poll chain both come out of newUnsavableSimulationTimer, so a
-- single queue is what the engine actually gives them. There is one actor here
-- and no per-script sandbox to restore, hence the no-op current hooks.
local T = dofile('tools/mock_timers.lua').new(function() return nil end, function() end)
local INTERVAL = 0.5   -- player poll interval (POLL_INTERVAL, no NPC multiplier)

local recs={}
local W={ShortBladeOneHand=0,LongBladeOneHand=1,LongBladeTwoHand=2,BluntOneHand=3,
  BluntTwoClose=4,BluntTwoWide=5,SpearTwoWide=6,AxeOneHand=7,AxeTwoHand=8,
  MarksmanBow=9,MarksmanCrossbow=10,MarksmanThrown=11,Arrow=12,Bolt=13}
local inv={}
local function mk(id,wt)
  local m='meshes/w/'..id..'.nif'; recs[id]={id=id,type=wt,model=m}; world.files[m]=true
  return {recordId=id,count=1}
end
local ArmorT={TYPE={Shield=8},record=function(o) return recs[o.recordId] end,
  objectIsInstance=function(o) return recs[o.recordId]~=nil end}
local WeaponT={TYPE=W,record=function(o) return recs[o.recordId] end,
  objectIsInstance=function(o) return recs[o.recordId]~=nil end}
local invObj={getAll=function(_,t)
    local out={} ; for _,i in ipairs(inv) do
      local r=recs[i.recordId]
      if (t==ArmorT and r.armor) or (t==WeaponT and not r.armor) then out[#out+1]=i end
    end; return out end}

package.preload['openmw.camera']=function() return {
  MODE={FirstPerson='first',ThirdPerson='third'}, getMode=function() return world.mode end,
  getQueuedMode=function() return world.queued end} end
package.preload['openmw.input']=function() return {
  triggers={TogglePOV=true},
  registerTriggerHandler=function(name,cb) world.trigger=cb end} end
package.preload['openmw.async']=function() return {
  callback=function(_,f) return f end,
  newUnsavableSimulationTimer=function(_,d,f) T.add(d,f) end} end
package.preload['openmw.types']=function() return {
  Weapon=WeaponT, Armor=ArmorT,
  Actor={inventory=function() return invObj end,
         getEquipment=function() return world.equip end,
         getStance=function() return world.stance end,
         STANCE={Nothing=0,Weapon=1,Spell=2},
         EQUIPMENT_SLOT={CarriedRight='CR',CarriedLeft='CL'},
         hasEquipped=function() return false end}} end
package.preload['openmw.vfs']=function() return {fileExists=function(p) return world.files[p]==true end} end
package.preload['openmw.animation']=function() return {
  addVfx=function(_,m,o) world.vfx[o.boneName]=o.vfxId end,
  removeVfx=function(_,id) for b,v in pairs(world.vfx) do if v==id then world.vfx[b]=nil end end end,
  hasBone=function(_,b) return world.bones[b]==true end} end
package.preload['openmw.storage']=function() return {
  globalSection=function()
      return dofile('tools/mock_storage.lua').section(function() return world.cfg end, nil)
  end} end

-- The engine's interfaces table is populated progressively as scripts load, so
-- model it as a live table: AnimRefresh loads first and writes into it, then
-- common.lua reads it.
local IFACES = {}
package.preload['openmw.interfaces']=function() return IFACES end
package.preload['openmw.nearby']=function() return { players = {} } end

local AR = dofile(A)
IFACES[AR.interfaceName] = AR.interface

package.path = './?.lua;' .. package.path
local common = dofile(C)

for _,b in ipairs({'Bip01 LongBladeOneHand','Bip01 AttachShield'}) do world.bones[b]=true end
inv={mk('sword',W.LongBladeOneHand)}

-- onActive is what arms the poll chain, and the first poll is the forced
-- build. It is staggered by up to one interval, so one interval on the clock is
-- what makes the build happen.
local h = common.makeUpdateHandler({}, true)
h.onActive()
T.advance(INTERVAL)
print('after first build, vfx on bone:', tostring(world.vfx['Bip01 LongBladeOneHand']))

-- POV press: engine drops the VFX and rebuilds the animation object.
print('\n-- player presses TogglePOV --')
world.vfx = {}                 -- engine dropped them
-- v4 detects the switch itself: the boundary flips and getQueuedMode() goes
-- nil when the camera has settled. There is no TogglePOV handler any more.
world.queued = 'first'
AR.engineHandlers.onUpdate(0.05)   -- mid-transition: must NOT deliver yet
world.mode, world.queued = 'first', nil

-- The engine finishes replacing the animation object LATER than the 0.1s
-- settle guess, and wipes attached VFX when it does.
local WIPE_AT = 0.80
local wiped = false
-- The clock already ran for the first build, so the wipe is timed from the
-- press, not from zero. Advancing the clock is also what drives IED now: its
-- poll chain comes off the same queue as AnimRefresh's settle timer, so there
-- is no per-frame update call to make here.
local t0 = T.now()
for _=1,60 do
  T.advance(0.05)
  if not wiped and T.now() - t0 >= WIPE_AT then
    world.vfx = {}      -- engine drops VFX as the new object comes up
    wiped = true
    print(('  t=%.2f  engine completed the rebuild and dropped the VFX'):format(T.now() - t0))
  end
  AR.engineHandlers.onUpdate(0.05)
end
local recovered = world.vfx['Bip01 LongBladeOneHand'] ~= nil
print((recovered and '  ok   ' or '  FAIL ')
      .. ('gear recovered after a rebuild that completed at t=%.2f'):format(WIPE_AT))
if not recovered then FAILED = true end
print(('after %.1fs, vfx on bone: %s'):format(T.now() - t0, tostring(world.vfx['Bip01 LongBladeOneHand'])))
print('AnimRefresh mode now:', AR.interface.getMode(), ' actual mode:', world.mode)

print('\n-- now the player draws a weapon --')
world.stance = 1
-- The cheap tier carries isDrawn, so the next poll on the chain sees it; one
-- interval of clock is enough to get that poll.
T.run(INTERVAL * 2, 0.05)
print('vfx on bone:', tostring(world.vfx['Bip01 LongBladeOneHand']))


print(FAILED and 'FAILURES' or 'ALL PASS')
if FAILED then os.exit(1) end
