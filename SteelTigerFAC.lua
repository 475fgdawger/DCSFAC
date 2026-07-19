--[[==========================================================================
  SteelTiger FAC-driven CAS Orbit Stack
  ---------------------------------------------------------------------------
  Depends on SteelTigerAirWing.lua having already run and defined:
      DWGR            -- namespace table
      DWGR.TFW8       -- the AIRWING (8th Tactical Fighter Wing)
      DWGR.FS433      -- the F-4E squadron

  Lifecycle
  ---------
   1. A unit whose GROUP name contains "FAC" takes off.
   2. After DWGR.StackLaunchDelay seconds, IF no stack is up yet (latch),
      launch a stack of DWGR.StackQuantity ORBIT flights at the INITIAL
      point (DWGR.InitialOrbit zone if set, else the FACORBIT point
      closest to the home airbase). Flights are stacked from
      DWGR.StackBottomAltitude upward in DWGR.StackAltitudeSeparation steps.
      Racetrack inbound heading = bearing(home airbase -> orbit point),
      legs = DWGR.OrbitLegNM.
   3. A FAC fires an M156 WP -> on impact a CAS zone is built -> the spawned
      orbiter CLOSEST TO THE IMPACT is pulled off its orbit and assigned a
      CASENHANCED (WeaponExpend = ALL). A backfill ORBIT flight is requested
      immediately into the VACATED altitude, anchored on the FACORBIT point
      closest to the FAC's current position.
   4. When the CAS mission completes (MOOSE built-in success/done
      evaluation) the flight RTBs.
   5. Any orbiting flight that drops below DWGR.RTBFuelFraction of internal
      fuel RTBs. (Hook is centralised in DWGR.SendHome so a future
      tanker-vs-airbase choice can be added in one place.)

  Built for MOOSE build 2918.  Confirmed on that build:
    - GetAssetsOnMission returns ASSET ITEMS; the live flight is asset.flightgroup
      and only exists when asset.spawned == true.
    - NewORBIT_RACETRACK(Coordinate, Altitude, Speed, Heading, Leg)
============================================================================]]--

-- Guard: this file must load AFTER the airwing file.
if not DWGR or not DWGR.TFW8 then
  env.error("SteelTigerFAC: DWGR.TFW8 not found - load SteelTigerAirWing.lua first!")
  return
end

-- ===========================================================================
-- ===============  USER CONFIGURATION  ======================================
-- ===========================================================================

-- --- Stack composition -----------------------------------------------------
DWGR.StackQuantity          = 2        -- flights to keep in the orbit stack
DWGR.StackBottomAltitude    = 18000    -- ft MSL of the lowest orbit slot
DWGR.StackAltitudeSeparation= 2000     -- ft between stacked slots

-- --- Timing ----------------------------------------------------------------
DWGR.StackLaunchDelay       = 0      -- s after FAC takeoff before stack launches (0 = immediate)

-- --- Orbit geometry --------------------------------------------------------
DWGR.OrbitLegNM             = 10       -- racetrack leg length in NM
DWGR.OrbitSpeed             = 350      -- orbit speed (kts) passed to the AUFTRAG
DWGR.FACOrbitPrefix         = "FACORBIT" -- ME zone name prefix for candidate orbit points
DWGR.InitialOrbit           = "FACORBIT5" or nil     -- optional: exact FACORBIT zone NAME (string) for the FIRST stack.
                                       -- If nil, the initial point is the FACORBIT closest to the home airbase.

-- --- Home airbase (orbit groups' departure base; drives racetrack heading) --
DWGR.HomeAirbaseName        = AIRBASE.Caucasus.Tbilisi_Lochini

-- --- CAS trigger -----------------------------------------------------------
DWGR.M156TypeName           = "FFAR M156 WP" -- weapon type that marks a FAC designation
DWGR.FACNamePattern         = "FAC"           -- substring that identifies a FAC group
DWGR.CASZoneRadius          = 500             -- m radius of the CAS target zone built at impact
DWGR.CASAltitude            = 5000            -- ft AGL/working altitude passed to CASENHANCED
DWGR.MaxConcurrentCAS       = 6               -- cap on CAS flights live at once (0 = uncapped).
                                              -- Only gates the empty-stack SCRAMBLE path; peeling an
                                              -- already-airborne orbiter is never blocked.

-- --- Weapon tracking (self-contained; does NOT use MOOSE's WEAPON class) ----
DWGR.TrackInterval          = 0.2      -- s between position polls of a tracked M156
DWGR.TrackTimeout           = 120      -- s before a tracker gives up (prevents orphaned pollers)
DWGR.MarkImpact             = true     -- drop an F10 map marker at the impact point
DWGR.SmokeImpact            = true    -- smoke the impact point, sustained until its CAS completes

-- Smoke colours are cycled through this pool, one per M156 impact, so
-- concurrent CAS targets are visually distinguishable. DCS offers exactly five.
DWGR.SmokeColors = {
  trigger.smokeColor.Green,
  trigger.smokeColor.Red,
  trigger.smokeColor.White,
  trigger.smokeColor.Orange,
  trigger.smokeColor.Blue,
}
DWGR.SmokeColorNames = { "Green", "Red", "White", "Orange", "Blue" }

-- DCS colored smoke burns for ~300s and CANNOT be cancelled (there is no
-- removal function for trigger.action.smoke - only effectSmokeBig has one).
-- We therefore SUSTAIN a mark by re-issuing smoke slightly before it expires,
-- and simply stop re-issuing once the CAS is done. Consequence: the final puff
-- burns out up to SmokeLifetime seconds AFTER the mission completes.
DWGR.SmokeLifetime          = 300      -- s a DCS smoke plume lasts (engine constant)
DWGR.SmokeRefresh           = 290      -- s between re-issues; must be < SmokeLifetime

-- --- Callsigns -------------------------------------------------------------
DWGR.CallsignName           = CALLSIGN.Aircraft.Ford -- callsign family for spawned flights

-- --- Fuel ------------------------------------------------------------------
DWGR.RTBFuelFraction        = 0.412    -- orbiters RTB when internal fuel drops below this fraction

-- --- Debug -----------------------------------------------------------------
DWGR.Debug                  = true     -- true = verbose env.info + on-screen MESSAGEs

-- ===========================================================================
-- ===============  END CONFIGURATION  =======================================
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- Internal state
--
-- NOTE: there is deliberately NO "stack launched" latch. A boolean cannot tell
-- "stack full at 2" from "stack down to 1", so a FAC taking off while one
-- orbiter remained would never top the stack back up. Instead every FAC takeoff
-- simply TOPS THE STACK UP to DWGR.StackQuantity. That one rule covers first
-- launch, restart after wind-down, reslots, and additional FACs with no
-- special cases and nothing to reset.
-- ---------------------------------------------------------------------------
DWGR.OrbitPoints     = {}      -- { {name=, coord=, heading=} , ... }  (heading precomputed from home airbase)
DWGR.Stack           = {}      -- slot index -> { alt=, flightgroup=, mission=, active= }  (nil/inactive = empty slot)
DWGR.HomeCoord       = nil     -- COORDINATE of the home airbase
DWGR.CASCount        = 0       -- running CAS mission counter for naming
DWGR.FuelWatchSet    = {}      -- flightgroup name -> true, so we only add the fuel watch once per group
DWGR.CallsignCounter = 0       -- rolling callsign group number for spawned flights
DWGR.MarkIdCounter   = 90000   -- monotonic F10 marker id (random ids can collide and overwrite)


-- ---------------------------------------------------------------------------
-- Small logging helper (respects DWGR.Debug for the on-screen half)
-- ---------------------------------------------------------------------------
function DWGR.Log(msg, seconds)
  env.info("DWGR: " .. msg)
  if DWGR.Debug then
    MESSAGE:New(msg, seconds or 15):ToAll():ToLog()
  end
end


-- ---------------------------------------------------------------------------
-- Build the table of candidate FACORBIT points from the Mission Editor.
-- Each point stores its coordinate AND the precomputed racetrack heading
-- (bearing from the home airbase toward that point), which never changes.
-- ---------------------------------------------------------------------------
function DWGR.BuildOrbitPoints()
  DWGR.OrbitPoints = {}

  -- Resolve the home airbase coordinate once (used for both heading + initial-point selection).
  local homeAB = AIRBASE:FindByName(DWGR.HomeAirbaseName)
  if not homeAB then
    env.error("DWGR: home airbase '" .. tostring(DWGR.HomeAirbaseName) .. "' not found!")
    return
  end
  DWGR.HomeCoord = homeAB:GetCoordinate()

  -- Discover every ME zone whose name starts with the FACORBIT prefix.
  -- We probe FACORBIT1..N; ZONE:FindByName returns nil for gaps, so we scan a
  -- generous range and also try a bare-prefix zone.
  local function tryAdd(zoneName)
    local zone = ZONE:FindByName(zoneName)
    if zone then
      local coord   = zone:GetCoordinate()
      local heading = DWGR.HomeCoord:HeadingTo(coord)   -- bearing home-airbase -> point (deg, world frame)
      table.insert(DWGR.OrbitPoints, { name = zoneName, coord = coord, heading = heading })
      env.info(string.format("DWGR: registered orbit point %s  hdg=%.0f", zoneName, heading))
    end
  end

  tryAdd(DWGR.FACOrbitPrefix)                 -- e.g. a lone "FACORBIT"
  for i = 1, 50 do                            -- FACORBIT1 .. FACORBIT50
    tryAdd(DWGR.FACOrbitPrefix .. i)
  end

  DWGR.Log(string.format("Registered %d FACORBIT point(s).", #DWGR.OrbitPoints), 20)
end


-- ---------------------------------------------------------------------------
-- Point selection helpers
-- ---------------------------------------------------------------------------

-- Return the orbit-point entry (name/coord/heading) closest to a COORDINATE.
function DWGR.GetClosestOrbitPoint(refCoord)
  local best, bestDist = nil, math.huge
  for _, p in ipairs(DWGR.OrbitPoints) do
    local d = refCoord:Get2DDistance(p.coord)
    if d < bestDist then
      bestDist = d
      best     = p
    end
  end
  return best
end

-- Return the orbit-point entry for the INITIAL stack:
--   DWGR.InitialOrbit (named zone) if set & found, else closest to home airbase.
function DWGR.GetInitialOrbitPoint()
  if DWGR.InitialOrbit then
    for _, p in ipairs(DWGR.OrbitPoints) do
      if p.name == DWGR.InitialOrbit then
        return p
      end
    end
    env.warning("DWGR: InitialOrbit '" .. tostring(DWGR.InitialOrbit)
                .. "' not found among FACORBIT points; falling back to closest-to-airbase.")
  end
  return DWGR.GetClosestOrbitPoint(DWGR.HomeCoord)
end


-- ---------------------------------------------------------------------------
-- Altitude for a given stack slot index (1-based).
--   slot 1 -> StackBottomAltitude, slot 2 -> +Separation, ...
-- ---------------------------------------------------------------------------
function DWGR.SlotAltitude(slotIndex)
  return DWGR.StackBottomAltitude + (slotIndex - 1) * DWGR.StackAltitudeSeparation
end


-- ---------------------------------------------------------------------------
-- Create + queue one ORBIT_RACETRACK mission at a given point/altitude and
-- record it in the stack slot. The AIRWING recruits & spawns the asset.
-- ---------------------------------------------------------------------------
function DWGR.AssignOrbit(slotIndex, orbitPoint, altitude)
  local mission = AUFTRAG:NewORBIT_RACETRACK(
      orbitPoint.coord,
      altitude,
      DWGR.OrbitSpeed,
      orbitPoint.heading,
      DWGR.OrbitLegNM)
    :SetName(string.format("FAC Orbit slot%d %s @%dft", slotIndex, orbitPoint.name, altitude))

  DWGR.TFW8:AddMission(mission)

  DWGR.Stack[slotIndex] = {
    alt          = altitude,
    orbitPoint   = orbitPoint.name,
    mission      = mission,
    flightgroup  = nil,      -- filled in once the asset spawns (see FlightOnMission hook)
    active       = true,     -- true while this slot is meant to be an orbiter (false once pushed to CAS)
  }

  DWGR.Log(string.format("Orbit assigned: slot %d, %s, %d ft (hdg %.0f).",
      slotIndex, orbitPoint.name, altitude, orbitPoint.heading), 20)

  return mission
end


-- ---------------------------------------------------------------------------
-- Is at least one BLUE FAC group alive? (parked or airborne both count)
-- Client groups in DCS are single-unit, so any living unit = living FAC.
-- Used to decide whether a bingo-fuel vacancy is worth backfilling.
-- ---------------------------------------------------------------------------
function DWGR.AnyFACAlive()
  local found = false

  local ok = pcall(function()
    local facSet = SET_GROUP:New()
      :FilterCoalitions("blue")
      :FilterActive(true)
      :FilterOnce()

    facSet:ForEachGroup(function(grp)
      if not found and grp and grp:IsAlive() then
        local name = grp:GetName()
        if name and string.find(name, DWGR.FACNamePattern) then
          found = true
        end
      end
    end)
  end)

  if not ok then
    -- Never let a lookup failure decide policy silently; assume a FAC lives so
    -- we keep the stack up rather than winding it down on a transient error.
    env.error("DWGR: AnyFACAlive() lookup failed; assuming a FAC is alive.")
    return true
  end

  return found
end


-- ---------------------------------------------------------------------------
-- Is a stack slot currently occupied by a live, active orbiter?
-- ---------------------------------------------------------------------------
function DWGR.IsSlotOccupied(slot)
  local data = DWGR.Stack[slot]
  if not data or not data.active then return false end

  -- A slot with a mission but no flightgroup yet is still "occupied":
  -- the airwing has been asked for an asset and it is spawning.
  if not data.flightgroup then
    return true
  end

  local ok, alive = pcall(function() return data.flightgroup:IsAlive() end)
  if not ok or not alive then
    return false
  end
  return true
end


-- Count how many stack slots hold a live/pending orbiter.
function DWGR.CountStack()
  local n = 0
  for slot = 1, DWGR.StackQuantity do
    if DWGR.IsSlotOccupied(slot) then
      n = n + 1
    end
  end
  return n
end


-- Mark a slot as vacated (its orbiter is gone: pushed to CAS, RTB, or dead).
function DWGR.VacateSlot(slot, why)
  local data = DWGR.Stack[slot]
  if not data then return end
  data.active      = false
  data.flightgroup = nil
  data.mission     = nil
  env.info(string.format("DWGR: slot %d vacated (%s).", slot, why or "unknown"))
end


-- ---------------------------------------------------------------------------
-- Top the stack up to DWGR.StackQuantity.
--
-- This REPLACES the old one-shot LaunchStack/StackLaunched latch. It is safe to
-- call on every FAC takeoff:
--   stack 0/2 -> launches 2 (cold start, or restart after wind-down)
--   stack 1/2 -> launches 1 (the case a boolean latch got wrong)
--   stack 2/2 -> launches 0 (no-op; extra FAC takeoffs cannot multiply it)
--
-- Empty slots are filled at the INITIAL point (DWGR.InitialOrbit if set, else
-- the FACORBIT closest to the home airbase), keeping their fixed slot altitude.
-- ---------------------------------------------------------------------------
function DWGR.TopUpStack()
  if #DWGR.OrbitPoints == 0 then
    env.error("DWGR: cannot top up stack - no FACORBIT points registered.")
    return
  end

  local have = DWGR.CountStack()
  local need = DWGR.StackQuantity - have

  if need <= 0 then
    DWGR.Log(string.format("Stack already at %d/%d - nothing to launch.",
        have, DWGR.StackQuantity), 10)
    return
  end

  local point = DWGR.GetInitialOrbitPoint()
  if not point then
    env.error("DWGR: cannot top up stack - no initial orbit point resolved.")
    return
  end

  DWGR.Log(string.format("Stack at %d/%d - launching %d at %s.",
      have, DWGR.StackQuantity, need, point.name), 20)

  for slot = 1, DWGR.StackQuantity do
    if not DWGR.IsSlotOccupied(slot) then
      DWGR.AssignOrbit(slot, point, DWGR.SlotAltitude(slot))
    end
  end
end


-- ---------------------------------------------------------------------------
-- Centralised "send this flight home" routine.
--
-- IMPORTANT: our orbit flights are AIRWING-recruited and AIR-spawned
-- (the airwing uses SetTakeoffAir), so their route is NOT pinned to a
-- departure airbase. Calling flightgroup:RTB() with NO argument makes MOOSE
-- try to resolve a home base that does not exist -> it indexes a nil 'airbase'
-- and THROWS. Because SendHome runs inside event/FSM callbacks, that throw
-- propagates into MOOSE's shared event dispatcher and silently stops other
-- handlers (this is what was killing EVENTS.Shot capture mid-mission).
--
-- Fix: always pass an EXPLICIT destination AIRBASE object, and wrap the call
-- in pcall so no failure here can ever again escape into the dispatcher.
--
-- This is also the single choke point where the future tanker-vs-airbase
-- decision will live.
-- ---------------------------------------------------------------------------
function DWGR.SendHome(flightgroup, reason)
  if not flightgroup then return end

  -- Guard: flight may have died/despawned between the triggering event and now.
  local aliveOk, alive = pcall(function() return flightgroup:IsAlive() end)
  if not aliveOk or not alive then return end

  -- Resolve an explicit destination airbase (never rely on an unpinned home base).
  local destBase = AIRBASE:FindByName(DWGR.HomeAirbaseName)

  -- FUTURE: if a tanker is closer than the airbase, route to tanker instead.
  -- e.g.  local tanker = flightgroup:GetClosestTanker()   -- FLIGHTGROUP helper on build 2918
  --       if tanker and tankerCloserThanAirbase then ... route to tanker ... return end

  -- Wrap the RTB so ANY internal MOOSE failure is contained, not thrown into
  -- the event dispatcher.
  local ok, err = pcall(function()
    if destBase then
      flightgroup:RTB(destBase)      -- explicit destination airbase (correct path)
    else
      flightgroup:RTB()              -- last resort; still guarded by this pcall
    end
  end)

  if ok then
    DWGR.Log(string.format("%s RTB to %s (%s).",
        flightgroup:GetName(),
        destBase and destBase:GetName() or "nearest",
        reason or "ordered"), 20)
  else
    env.error(string.format("DWGR: RTB failed for %s (%s): %s",
        flightgroup:GetName(), reason or "ordered", tostring(err)))
  end
end


-- ---------------------------------------------------------------------------
-- Handle an orbiter going bingo fuel.
--
-- This fixes a real bug: previously bingo-fuel RTB sent the flight home but
-- NEVER touched its stack slot, so the stack silently attrited from 2 -> 1 -> 0
-- while still believing it was full.
--
-- Policy (per design):
--   - vacate the slot
--   - backfill it ONLY if at least one blue FAC is alive
--   - if no FAC is alive, leave it empty; the stack winds down toward 0 and a
--     future FAC takeoff will top it back up.
-- ---------------------------------------------------------------------------
function DWGR.OnOrbiterBingo(flightgroup)
  local slot = DWGR.FindSlotByFlightgroup(flightgroup)

  -- Send it home first (guarded inside SendHome).
  DWGR.SendHome(flightgroup, "bingo fuel")

  if not slot then
    -- Not a stack orbiter (e.g. a CAS flight that went bingo): nothing to backfill.
    return
  end

  local vacatedAlt = DWGR.Stack[slot] and DWGR.Stack[slot].alt or DWGR.SlotAltitude(slot)
  DWGR.VacateSlot(slot, "bingo fuel")

  if DWGR.AnyFACAlive() then
    -- Backfill at the FACORBIT closest to the home airbase / InitialOrbit,
    -- same as a fresh stack launch (no FAC position implied by a fuel state).
    local point = DWGR.GetInitialOrbitPoint()
    if point then
      DWGR.AssignOrbit(slot, point, vacatedAlt)
      DWGR.Log(string.format("Bingo backfill: slot %d (%d ft) at %s.",
          slot, vacatedAlt, point.name), 20)
    else
      env.error("DWGR: bingo backfill failed - no orbit point resolved.")
    end
  else
    DWGR.Log(string.format("Slot %d went bingo with no FAC - not backfilling (stack now %d/%d).",
        slot, DWGR.CountStack(), DWGR.StackQuantity), 20)
  end
end


-- ---------------------------------------------------------------------------
-- Fuel watch: add a low-fuel RTB to an orbiting flight, once.
-- MOOSE's threshold is a FRACTION of max internal fuel (0..1).
-- ---------------------------------------------------------------------------
function DWGR.AddFuelWatch(flightgroup)
  if not flightgroup then return end
  local fgName = flightgroup:GetName()
  if DWGR.FuelWatchSet[fgName] then return end
  DWGR.FuelWatchSet[fgName] = true

  -- Set the low-fuel threshold and route the "low fuel" reaction through
  -- our centralised SendHome so the future tanker logic applies here too.
  flightgroup:SetFuelLowThreshold(DWGR.RTBFuelFraction)

  -- When MOOSE flags the flight low on fuel, send it home and manage the slot.
  function flightgroup:OnAfterFuelLow(From, Event, To)
    DWGR.OnOrbiterBingo(self)
  end

  env.info(string.format("DWGR: fuel watch armed on %s at %.3f.", fgName, DWGR.RTBFuelFraction))
end


-- ---------------------------------------------------------------------------
-- Find the stack slot (and live flightgroup) whose orbiter is closest to a
-- COORDINATE. Only considers ACTIVE, spawned, alive orbiters.
-- Returns slotIndex, flightgroup  (or nil).
-- ---------------------------------------------------------------------------
function DWGR.GetClosestOrbiter(refCoord)
  local bestSlot, bestFG, bestDist = nil, nil, math.huge

  -- Prefer the live picture from the airwing's ORBIT assets (authoritative on spawn state),
  -- then match each spawned flightgroup back to a stack slot by orbit mission.
  local orbitAssets = DWGR.TFW8:GetAssetsOnMission({ AUFTRAG.Type.ORBIT })
  if orbitAssets then
    for _, asset in pairs(orbitAssets) do
      if asset.spawned == true and asset.flightgroup then
        local fg = asset.flightgroup
        if fg:IsAlive() then
          local grp = fg:GetGroup()
          if grp and grp:IsAlive() then
            local d = grp:GetCoordinate():Get2DDistance(refCoord)
            if d < bestDist then
              -- match this flightgroup to a stack slot
              local slot = DWGR.FindSlotByFlightgroup(fg)
              if slot and DWGR.Stack[slot] and DWGR.Stack[slot].active then
                bestDist = d
                bestFG   = fg
                bestSlot = slot
              end
            end
          end
        end
      end
    end
  end

  return bestSlot, bestFG
end


-- ---------------------------------------------------------------------------
-- Match a live flightgroup to a stack slot.  We stored the ORBIT mission per
-- slot; the flightgroup's current mission should be that same AUFTRAG object.
-- ---------------------------------------------------------------------------
function DWGR.FindSlotByFlightgroup(flightgroup)
  -- Fast path: we cached the flightgroup on the slot when it went on mission.
  for slot, data in pairs(DWGR.Stack) do
    if data.flightgroup == flightgroup then
      return slot
    end
  end
  -- Fallback: match by current mission object.
  local cur = flightgroup.GetMissionCurrent and flightgroup:GetMissionCurrent() or nil
  if cur then
    for slot, data in pairs(DWGR.Stack) do
      if data.mission == cur then
        return slot
      end
    end
  end
  return nil
end


-- ---------------------------------------------------------------------------
-- SUSTAINED IMPACT SMOKE
--
-- DCS colored smoke burns ~300s and has NO removal function (only
-- effectSmokeBig can be stopped by name; trigger.action.smoke cannot). So to
-- keep a target marked for as long as its CAS mission runs, we re-issue the
-- smoke every DWGR.SmokeRefresh seconds and stop re-issuing when the mission
-- completes. The last puff necessarily lingers up to SmokeLifetime seconds
-- after that - there is no way to snuff it early.
--
-- Each impact takes the next colour from DWGR.SmokeColors so concurrent CAS
-- targets are tellable apart.
-- ---------------------------------------------------------------------------

DWGR.SmokeColorIndex = 0     -- rolling index into DWGR.SmokeColors
DWGR.ActiveSmokes    = {}    -- smokeId -> true while that mark should be sustained
DWGR.SmokeIdCounter  = 0

-- Take the next colour from the pool (wraps).
function DWGR.NextSmokeColor()
  if not DWGR.SmokeColors or #DWGR.SmokeColors == 0 then
    return trigger.smokeColor.Red, "Red"
  end
  DWGR.SmokeColorIndex = DWGR.SmokeColorIndex + 1
  if DWGR.SmokeColorIndex > #DWGR.SmokeColors then
    DWGR.SmokeColorIndex = 1
  end
  local i = DWGR.SmokeColorIndex
  return DWGR.SmokeColors[i], (DWGR.SmokeColorNames and DWGR.SmokeColorNames[i]) or tostring(i)
end


-- Begin sustaining smoke at pos. Returns a smokeId used to stop it later.
function DWGR.StartSustainedSmoke(pos, color)
  DWGR.SmokeIdCounter = DWGR.SmokeIdCounter + 1
  local smokeId = DWGR.SmokeIdCounter
  DWGR.ActiveSmokes[smokeId] = true

  local function puff()
    -- Stop re-issuing once the owning CAS mission has cleared this id.
    if not DWGR.ActiveSmokes[smokeId] then
      return nil    -- unschedule; the last plume burns out on its own
    end
    pcall(function() trigger.action.smoke(pos, color) end)
    return timer.getTime() + DWGR.SmokeRefresh
  end

  -- First puff immediately, then re-issue on the refresh cadence.
  pcall(function() trigger.action.smoke(pos, color) end)
  timer.scheduleFunction(puff, nil, timer.getTime() + DWGR.SmokeRefresh)

  return smokeId
end


-- Stop sustaining a smoke mark. The currently-burning plume cannot be removed
-- by DCS, so it simply expires; we just stop refreshing it.
function DWGR.StopSustainedSmoke(smokeId)
  if smokeId then
    DWGR.ActiveSmokes[smokeId] = nil
  end
end


-- ---------------------------------------------------------------------------
-- Build a CASENHANCED mission for an impact zone, with the RTB-on-completion
-- hooks attached. Used by BOTH the peel path and the empty-stack scramble path.
--
-- smokeId (optional): if the impact was smoked, the plume is sustained until
-- this mission reaches Success/Done, then released (it then burns out on its
-- own - DCS cannot cancel colored smoke).
-- markId  (optional): the F10 map marker for this impact, REMOVED outright when
-- the mission reaches Success/Done (markers, unlike smoke, can be deleted).
-- ---------------------------------------------------------------------------
function DWGR.BuildCASMission(FACZone, smokeId, markId)
  DWGR.CASCount = DWGR.CASCount + 1

  local casMission = AUFTRAG:NewCASENHANCED(FACZone, DWGR.CASAltitude)
    :SetName("FAC CAS " .. DWGR.CASCount)

  -- Bias toward dumping all A/G ordnance on the attack. This is a BIAS only:
  -- DCS AI decides releases per pass and typically ripples 2 Mk82s at a time.
  if casMission.SetWeaponExpend then
    casMission:SetWeaponExpend(AI.Task.WeaponExpend.ALL)
  end

  -- When the CAS completes, send every flight on it home (MOOSE's built-in
  -- success/done evaluation decides when that is) and release its smoke mark.
  function casMission:OnAfterSuccess(From, Event, To)
    DWGR.Log(casMission:GetName() .. " success.", 20)
    DWGR.StopSustainedSmoke(smokeId)
    DWGR.RemoveMark(markId)
    local grps = casMission:GetOpsGroups()
    if grps then
      for _, fg in pairs(grps) do
        DWGR.SendHome(fg, "CAS complete")
      end
    end
  end

  -- Also cover the plain Done path (target gone / evaluated without explicit Success).
  function casMission:OnAfterDone(From, Event, To)
    DWGR.StopSustainedSmoke(smokeId)
    DWGR.RemoveMark(markId)
    local grps = casMission:GetOpsGroups()
    if grps then
      for _, fg in pairs(grps) do
        DWGR.SendHome(fg, "CAS done")
      end
    end
  end

  return casMission
end


-- ---------------------------------------------------------------------------
-- Count CAS missions currently live (queued, requested, or executing) at the
-- airwing. Used to cap how many jets a FAC can scramble at an empty stack.
-- ---------------------------------------------------------------------------
function DWGR.CountActiveCAS()
  local n = 0
  local ok = pcall(function()
    local assets = DWGR.TFW8:GetAssetsOnMission({ AUFTRAG.Type.CASENHANCED })
    if assets then
      for _, _asset in pairs(assets) do
        n = n + 1
      end
    end
  end)
  if not ok then return 0 end
  return n
end


-- ---------------------------------------------------------------------------
-- Assign CAS for an M156 impact.
--
-- Two paths:
--   A) STACK HAS AN ORBITER -> peel the closest one and backfill its slot.
--      This is the fast path: the jet is already airborne and on station.
--   B) STACK IS EMPTY -> hand the CAS straight to the AIRWING, which recruits
--      and spawns a fresh flight onto it. Previously this case built a CAS
--      mission and then THREW IT AWAY, so the shot was silently forgotten.
--
--      Note the scramble does NOT route via the orbit stack: with no orbiter
--      up there is no speed advantage to be had, and queueing the target to
--      wait for a backfill would cost the same spawn latency while adding
--      stale-target and contention problems. The stack still tops itself up
--      independently on the next FAC takeoff.
-- ---------------------------------------------------------------------------
function DWGR.AssignCAS(FACZone, FACCoord, smokeId, markId)
  local impactCoord = FACZone:GetCoordinate()

  -- 1) find the closest spawned orbiter to the impact
  local slot, flightgroup = DWGR.GetClosestOrbiter(impactCoord)

  -- ---------------------------------------------------------------------
  -- PATH B: stack is empty -> scramble a fresh flight from the airwing.
  -- ---------------------------------------------------------------------
  if not slot or not flightgroup then
    local live = DWGR.CountActiveCAS()
    if DWGR.MaxConcurrentCAS and DWGR.MaxConcurrentCAS > 0 and live >= DWGR.MaxConcurrentCAS then
      DWGR.Log(string.format(
          "Stack empty and %d/%d CAS already active - shot not tasked.",
          live, DWGR.MaxConcurrentCAS), 20)
      return nil
    end

    local casMission = DWGR.BuildCASMission(FACZone, smokeId, markId)
    DWGR.TFW8:AddMission(casMission)

    DWGR.Log(string.format("Stack empty - scrambling fresh flight for %s.",
        casMission:GetName()), 20)

    return casMission
  end

  -- ---------------------------------------------------------------------
  -- PATH A: peel the closest orbiter off its orbit onto the CAS.
  -- ---------------------------------------------------------------------
  local vacatedAlt = DWGR.Stack[slot].alt

  local casMission = DWGR.BuildCASMission(FACZone, smokeId, markId)

  local orbitMission = DWGR.Stack[slot].mission
  if orbitMission then
    flightgroup:MissionCancel(orbitMission)
  end
  flightgroup:AddMission(casMission)

  -- mark the slot inactive (it is no longer an orbiter)
  DWGR.VacateSlot(slot, "peeled to CAS")

  DWGR.Log(string.format("Slot %d (%d ft) peeled to CAS %s.", slot, vacatedAlt, casMission:GetName()), 20)

  -- backfill the vacated altitude at the FACORBIT closest to the FAC
  local backfillPoint = DWGR.GetClosestOrbitPoint(FACCoord or impactCoord)
  if backfillPoint then
    DWGR.AssignOrbit(slot, backfillPoint, vacatedAlt)
  else
    env.error("DWGR: backfill failed - no orbit point resolved.")
  end

  return casMission
end


-- ---------------------------------------------------------------------------
-- SELF-CONTAINED WEAPON TRACKING (replaces MOOSE's WEAPON:StartTrack)
--
-- WHY: MOOSE's WEAPON class + StartTrack() was correlated with our EVENTS.Shot
-- subscription silently dying mid-mission (RAWSHOT stopped incrementing for
-- ALL units a few seconds after a tracked weapon's impact, while every other
-- MOOSE FSM kept running). MOOSE's weapon tracker does its own event
-- subscription/teardown; its teardown appears to collaterally kill our shot
-- handler. We do not need that machinery.
--
-- HOW: we poll the RAW DCS weapon object's position on a short timer. A weapon
-- ceases to exist at impact, so the LAST KNOWN POSITION before it disappears
-- IS the impact point. No MOOSE WEAPON object, no extra event subscriptions,
-- nothing that can unsubscribe anything.
--
-- Each tracker is bounded by DWGR.TrackTimeout so a weapon that never resolves
-- (out of range, despawned) can never leave an orphaned poller running.
-- ---------------------------------------------------------------------------

-- Remove an F10 map marker by id. Unlike colored smoke (which DCS cannot
-- cancel), markers CAN be deleted outright - which is why marker ids are drawn
-- from a monotonic counter rather than math.random: we need a stable, unique
-- handle to remove later.
function DWGR.RemoveMark(markId)
  if not markId then return end
  pcall(function() trigger.action.removeMark(markId) end)
end


-- Fired when a tracked M156 has impacted; pos is a DCS Vec3 of the impact point.
function DWGR.HandleImpact(pos)
  if not pos then
    DWGR.Log("M156 impact: no position captured.", 20)
    return
  end

  local impactCoord = COORDINATE:NewFromVec3(pos)

  -- Smoke the impact with the next colour in the pool, sustained until the CAS
  -- assigned to this impact completes.
  local smokeId    = nil
  local colorName  = nil
  if DWGR.SmokeImpact then
    local color
    color, colorName = DWGR.NextSmokeColor()
    smokeId = DWGR.StartSustainedSmoke(pos, color)
    env.info(string.format("DWGR: impact smoked %s (id %d).", colorName, smokeId))
  end

  -- RESERVE the marker id up front so it can be handed to the CAS mission (which
  -- removes the marker on completion), but do not DRAW the marker yet: its label
  -- needs the mission name, which does not exist until AssignCAS has run.
  local markId = nil
  if DWGR.MarkImpact then
    DWGR.MarkIdCounter = (DWGR.MarkIdCounter or 90000) + 1
    markId = DWGR.MarkIdCounter
  end

  local zoneName = "FAC_Zone_" .. tostring(timer.getTime())
  local FACZone  = ZONE_RADIUS:New(zoneName, impactCoord:GetVec2(), DWGR.CASZoneRadius)

  -- Assign CAS FIRST so the map marker can name the mission that got tasked,
  -- and so the mission owns both the smoke and the marker for cleanup.
  local casMission = DWGR.AssignCAS(FACZone, impactCoord, smokeId, markId)

  -- Now draw the marker, labelled with the CAS mission actually assigned.
  if markId then
    local label
    if casMission then
      label = casMission:GetName()
      if colorName then
        label = label .. " (" .. colorName .. " smoke)"
      end
    else
      -- No CAS was tasked (e.g. concurrent-CAS cap reached): say so rather
      -- than leave a bare mark with no explanation.
      label = "M156 impact - no CAS assigned"
    end

    pcall(function()
      -- readOnly = true: players cannot delete this marker from the F10 map.
      trigger.action.markToAll(markId, label, pos, true)
    end)

    -- An unassigned mark has no mission to remove it on Success/Done, so it
    -- would sit on the F10 map forever. Expire it on the same clock as the
    -- smoke plume, so the two disappear together.
    if not casMission then
      local expiringId = markId
      timer.scheduleFunction(function()
        DWGR.RemoveMark(expiringId)
        return nil
      end, nil, timer.getTime() + DWGR.SmokeLifetime)
    end
  end

  -- If no CAS was created (e.g. concurrent-CAS cap reached), nothing will ever
  -- release the smoke, so stop sustaining it now rather than leak a refresher.
  if not casMission and smokeId then
    DWGR.StopSustainedSmoke(smokeId)
  end
end


-- Start tracking a raw DCS weapon object to its impact point.
-- Polls position every DWGR.TrackInterval seconds; when the weapon no longer
-- exists, the last good position is the impact point.
function DWGR.TrackWeapon(rawWeapon)
  if not rawWeapon then return end

  local lastPos  = nil
  local deadline = timer.getTime() + DWGR.TrackTimeout

  local function poll()
    -- Everything in here is guarded: this runs on a scheduler, and a throw
    -- inside a scheduled function is exactly the class of failure that has
    -- bitten this script before.
    local ok, stillFlying = pcall(function()
      if rawWeapon:isExist() then
        lastPos = rawWeapon:getPoint()   -- DCS Vec3
        return true
      end
      return false
    end)

    if not ok then
      -- Weapon object went invalid between checks: treat as impact at last pos.
      pcall(DWGR.HandleImpact, lastPos)
      return nil
    end

    if stillFlying then
      if timer.getTime() >= deadline then
        env.info("DWGR: weapon track timed out; using last known position.")
        pcall(DWGR.HandleImpact, lastPos)
        return nil   -- stop polling
      end
      return timer.getTime() + DWGR.TrackInterval   -- reschedule
    end

    -- Weapon no longer exists -> it impacted. Last known position is the point.
    pcall(DWGR.HandleImpact, lastPos)
    return nil       -- stop polling
  end

  timer.scheduleFunction(poll, nil, timer.getTime() + DWGR.TrackInterval)
end


-- ---------------------------------------------------------------------------
-- AIRWING hook: when a flight goes on a mission, cache it into its stack slot
-- and (if it's an orbit) arm the fuel watch. This is how DWGR.Stack learns the
-- live flightgroup object for each orbiter.
-- ---------------------------------------------------------------------------
function DWGR.TFW8:OnAfterFlightOnMission(From, Event, To, FlightGroup, Mission)
  local flightgroup = FlightGroup
  local mission     = Mission

  local text = string.format("Flight %s on %s mission %s",
      flightgroup:GetName(), mission:GetType(), mission:GetName())
  env.info("DWGR: " .. text)
  if DWGR.Debug then MESSAGE:New(text, 30):ToAll() end

  -- If this mission matches one of our stack slots, cache the live flightgroup.
  for slot, data in pairs(DWGR.Stack) do
    if data.mission == mission then
      data.flightgroup = flightgroup

      -- Assign an iterating callsign so every spawned flight isn't FORD 21.
      -- COHORT:SetCallsign does NOT iterate - it applies one callsign to every
      -- asset - so we do it per-flight here. DCS group numbers are 1..9, so we
      -- wrap the counter rather than passing an invalid number.
      DWGR.CallsignCounter = (DWGR.CallsignCounter or 0) + 1
      local groupNumber = ((DWGR.CallsignCounter - 1) % 9) + 1
      local csOk, csErr = pcall(function()
        flightgroup:SwitchCallsign(DWGR.CallsignName, groupNumber)
      end)
      if csOk then
        env.info(string.format("DWGR: callsign set on %s -> group #%d.",
            flightgroup:GetName(), groupNumber))
      else
        env.error(string.format("DWGR: SwitchCallsign failed on %s: %s",
            flightgroup:GetName(), tostring(csErr)))
      end

      if mission:GetType() == AUFTRAG.Type.ORBIT then
        DWGR.AddFuelWatch(flightgroup)   -- orbiters get low-fuel RTB
      end
      break
    end
  end
end


-- ---------------------------------------------------------------------------
-- Shot handler: catch the M156 WP fired by a FAC group, track it to impact.
--
-- WHY RAW DCS EVENTS INSTEAD OF MOOSE'S EVENTHANDLER:
--   Our MOOSE EVENTS.Shot subscription repeatedly died silently mid-mission -
--   the RAWSHOT counter (first line of the handler) simply stopped incrementing
--   for ALL units, while every other MOOSE FSM/scheduler kept running and no
--   error was ever logged. We removed the MOOSE WEAPON tracker (a suspect) and
--   it still died. Rather than keep hunting which MOOSE component tears the
--   subscription down, we subscribe DIRECTLY to the DCS event API. DCS itself
--   manages this handler, so nothing in MOOSE's event bookkeeping can drop it.
--
-- PERFORMANCE-CRITICAL ORDERING:
--   S_EVENT_SHOT fires for EVERY weapon release on the map - AAA, SAMs, and the
--   CAS flights' own bombs generate huge volume (700+ events in ~12 min). We
--   therefore reject non-FAC / non-M156 events using ONLY cheap raw-DCS reads,
--   and touch nothing heavier until an event passes both filters.
--
--   Filter order (cheapest, most-selective first):
--     1. initiator's GROUP name must contain the FAC substring
--     2. weapon type name must equal the M156 type
--     3. only then: log + start our own (non-MOOSE) impact tracker
--
-- The whole body is wrapped in pcall: a throw inside a DCS event handler is
-- exactly the failure class that has bitten this script before.
-- ---------------------------------------------------------------------------

-- Instrumentation: total shot events seen vs. events that passed the FAC filter.
DWGR.ShotEventCount = 0
DWGR.FACShotCount   = 0

DWGR.RawShotHandler = {}

function DWGR.RawShotHandler:onEvent(event)
  if not event then return end

  -- Takeoff: drives the orbit stack top-up. Defined further below.
  if event.id == world.event.S_EVENT_TAKEOFF then
    local ok, err = pcall(DWGR.HandleTakeoff, event)
    if not ok then
      env.error("DWGR: raw takeoff handler error (contained): " .. tostring(err))
    end
    return
  end

  -- Everything past here is shots only.
  if event.id ~= world.event.S_EVENT_SHOT then
    return
  end

  local ok, err = pcall(function()
    DWGR.ShotEventCount = DWGR.ShotEventCount + 1

    local initiator = event.initiator
    local weapon    = event.weapon
    if not initiator or not weapon then return end

    -- --- Filter 1: initiator's GROUP name contains the FAC substring --------
    -- Read straight off the raw DCS objects; no MOOSE wrappers built.
    local groupName
    local gnOk = pcall(function()
      local grp = initiator:getGroup()
      if grp then groupName = grp:getName() end
    end)
    if not gnOk or not groupName then return end
    if not string.find(groupName, DWGR.FACNamePattern) then
      return  -- AAA, SAMs, CAS bombs, non-FAC shots: rejected cheaply
    end

    -- --- Filter 2: weapon type name equals the M156 type --------------------
    local wType
    local wtOk = pcall(function() wType = weapon:getTypeName() end)
    if not wtOk or wType ~= DWGR.M156TypeName then
      return  -- a FAC firing something else (its gun, etc.): ignore
    end

    -- --- Passed both filters: this is a FAC-fired M156 WP -------------------
    DWGR.FACShotCount = DWGR.FACShotCount + 1
    DWGR.Log(string.format("FAC M156 #%d from %s (shot event #%d).",
        DWGR.FACShotCount, groupName, DWGR.ShotEventCount), 15)

    -- Track the raw DCS weapon ourselves (see DWGR.TrackWeapon).
    DWGR.TrackWeapon(weapon)
  end)

  if not ok then
    env.error("DWGR: raw shot handler error (contained): " .. tostring(err))
  end
end

-- (raw DCS handler is registered at the END of this file, once every
-- function it dispatches to has been defined.)


-- ---------------------------------------------------------------------------
-- Takeoff handling: ANY blue FAC takeoff tops the stack up to StackQuantity.
--
-- Handled on the SAME raw DCS subscription as shots (see above) so the stack
-- launch does not depend on MOOSE's event layer either.
--
-- There is no latch. TopUpStack() is idempotent with respect to a full stack:
--   stack 0/2 -> launches 2   (first FAC, or restart after the stack wound down)
--   stack 1/2 -> launches 1   (a boolean latch would wrongly do nothing here)
--   stack 2/2 -> launches 0   (extra/reslotted FACs cannot multiply the stack)
--
-- This covers first launch, reslots, respawns after ejection, and additional
-- FACs with a single rule and nothing to reset.
-- ---------------------------------------------------------------------------
function DWGR.HandleTakeoff(event)
  local initiator = event.initiator
  if not initiator then return end

  -- Cheap raw reads only; no MOOSE wrappers.
  local groupName, coalitionSide
  local ok = pcall(function()
    local grp = initiator:getGroup()
    if grp then
      groupName     = grp:getName()
      coalitionSide = grp:getCoalition()
    end
  end)
  if not ok or not groupName then return end

  -- FAC groups only.
  if not string.find(groupName, DWGR.FACNamePattern) then return end

  -- Blue FACs only.
  if coalitionSide ~= coalition.side.BLUE then return end

  local delay = DWGR.StackLaunchDelay or 0
  DWGR.Log(string.format("Blue FAC '%s' airborne - topping stack up%s.",
      groupName,
      delay > 0 and string.format(" in %ds", delay) or " now"), 20)

  if delay > 0 then
    timer.scheduleFunction(function()
      pcall(DWGR.TopUpStack)
      return nil
    end, nil, timer.getTime() + delay)
  else
    pcall(DWGR.TopUpStack)
  end
end


-- ---------------------------------------------------------------------------
-- Initialise: build the orbit-point table now that the ME zones exist.
-- ---------------------------------------------------------------------------
DWGR.BuildOrbitPoints()

-- ---------------------------------------------------------------------------
-- Register the RAW DCS event handler LAST, so every function it dispatches to
-- (DWGR.HandleTakeoff, DWGR.TrackWeapon, ...) is already defined. Registering
-- earlier would leave a window where a takeoff/shot could call a nil.
-- ---------------------------------------------------------------------------
world.addEventHandler(DWGR.RawShotHandler)
env.info("DWGR: raw DCS event handler registered for S_EVENT_SHOT + S_EVENT_TAKEOFF (bypasses MOOSE EVENTHANDLER).")

DWGR.Log("SteelTiger FAC CAS-stack script loaded.", 20)
