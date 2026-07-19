--[[ Count units in trigger zones and color the grid zones.
     MOOSE version (no MIST).

     - Uses live SET_GROUPs (built once) that auto-track births/deaths,
       so CTLD-dropped blue units and late-activated red units are picked
       up automatically.
     - DMIST.OnUnitsCreated() is provided as an optional hook to call from
       a CTLD / spawn callback if you want to force a refresh; it is safe
       to call repeatedly and will not leak event handlers.
]]

DMIST = {}
DMIST.GridStart  = 0     -- first zone number
DMIST.GridEnd    = 99    -- last zone number
DMIST.StepDelay  = 3     -- seconds between each zone update
DMIST.MarkIdBase = 30000 -- base id for drawn zone markups (unique per zone)

-- Colors are {r, g, b, a} on a 0..1 scale for MOOSE/DCS draw calls.
DMIST.Colors = {
  neutral = { line = {1, 1, 1, 0.5}, fill = {1, 1, 1, 0.05}, lineType = 0 }, -- no line
  blue    = { line = {0, 0, 1, 1.0}, fill = {0, 0, 1, 0.05}, lineType = 2 }, -- dashed
  red     = { line = {1, 0, 0, 1.0}, fill = {1, 0, 0, 0.05}, lineType = 2 }, -- dashed
  contest = { line = {1, 1, 0, 1.0}, fill = {1, 1, 0, 0.05}, lineType = 6 }, -- two dash
}

--- Build the coalition SET_GROUPs ONCE. Live sets auto-track births/deaths,
--- so this never needs to run again - but we guard against accidental
--- rebuilds leaking event handlers by only creating each set if it does
--- not exist yet.
function DMIST.MakeSomeTables()
  if not DMIST.BlueSet then
    DMIST.BlueSet = SET_GROUP:New():FilterCoalitions("blue"):FilterCategories("ground"):FilterStart()
  end
  if not DMIST.RedSet then
    DMIST.RedSet = SET_GROUP:New():FilterCoalitions("red"):FilterCategories("ground"):FilterStart()
  end
  env.info("DMIST: sets ready")
end

--- Optional hook: call this after a batch spawn (e.g. from a CTLD callback)
--- if you want to be certain the sets exist before the next grid pass.
--- Safe to call repeatedly - it will not create duplicate sets or leak
--- handlers, and live sets self-update between calls.
function DMIST.OnUnitsCreated()
  DMIST.MakeSomeTables()
  env.info("DMIST: units-created hook fired")
end

--- Count how many units of a coalition SET are inside a zone.
function DMIST.CountInZone(set, zone)
  local count = 0
  if not set then return 0 end
  set:ForEachGroup(function(grp)
    if grp and grp:IsAlive() then
      for _, unit in pairs(grp:GetUnits() or {}) do
        if unit and unit:IsAlive() and zone:IsVec2InZone(unit:GetVec2()) then
          count = count + 1
        end
      end
    end
  end)
  return count
end

--- Return 0 = empty, 1 = red only, 2 = contested (both present).
function DMIST.CheckAZone(zoneName)
  local zone = ZONE:FindByName(zoneName)
  if not zone then return 0 end
  local blueNumber = DMIST.CountInZone(DMIST.BlueSet, zone)
  local redNumber  = DMIST.CountInZone(DMIST.RedSet, zone)
  if redNumber > 0 and blueNumber == 0 then
    return 1
  elseif redNumber > 0 and blueNumber > 0 then
    return 2
  else
    return 0
  end
end

--- Pick the color profile for a zone based on its occupancy.
function DMIST.ProfileFor(zoneName)
  local zone = ZONE:FindByName(zoneName)
  if not zone then return nil end
  local blueNumber = DMIST.CountInZone(DMIST.BlueSet, zone)
  local redNumber  = DMIST.CountInZone(DMIST.RedSet, zone)

  if blueNumber == 0 and redNumber == 0 then
    return DMIST.Colors.neutral
  elseif redNumber == 0 then
    return DMIST.Colors.blue      -- blue present, no red
  elseif blueNumber == 0 then
    return DMIST.Colors.red       -- red present, no blue
  else
    return DMIST.Colors.contest   -- both present
  end
end

--- Draw a single zone with the given color profile.
--- Removes any previous drawing for this zone id, then redraws so colors
--- update in place instead of stacking.
function DMIST.DrawZone(zoneName, profile)
  local zone = ZONE:FindByName(zoneName)
  if not zone then return end
  local markId = DMIST.MarkIdBase + tonumber(zoneName)
  trigger.action.removeMark(markId)
  -- ZONE:DrawZone signature is:
  --   DrawZone(Coalition, Color, Alpha, FillColor, FillAlpha, LineType, ReadOnly)
  -- The colour tables carry {r,g,b,a}, but DrawZone takes the r,g,b table AND a
  -- SEPARATE alpha argument - the 4th table element is ignored. The previous
  -- call passed only 6 args, so from FillAlpha onward everything was shifted one
  -- position left: FillAlpha received lineType (>=1 -> fully opaque fill),
  -- LineType received the readonly flag, and ReadOnly received markId. Passing
  -- the alphas explicitly (pulled from each table's 4th element) fixes it.
  zone:DrawZone(
    -1,               -- Coalition: -1 = all
    profile.line,     -- Color {r,g,b} (4th element ignored)
    profile.line[4],  -- Alpha (line transparency)
    profile.fill,     -- FillColor {r,g,b} (4th element ignored)
    profile.fill[4],  -- FillAlpha (fill transparency) - this is the 0.05
    profile.lineType, -- LineType
    true              -- ReadOnly
  )
end

--- Color every zone in the grid in one pass.
function DMIST.ColorAllZones()
  for i = DMIST.GridStart, DMIST.GridEnd, 1 do
    local zoneName = tostring(i)
    local profile = DMIST.ProfileFor(zoneName)
    if profile then
      DMIST.DrawZone(zoneName, profile)
    end
  end
end

--- Color one zone, then schedule the next (spreads the load over time).
function DMIST.GridCount(zoneName)
  local profile = DMIST.ProfileFor(zoneName)
  if profile then
    DMIST.DrawZone(zoneName, profile)
  end

  if DMIST.GridStart == DMIST.GridEnd then
    DMIST.GridStart = 0  -- wrap the cycle
  end
  SCHEDULER:New(nil, DMIST.GridStatus, {}, DMIST.StepDelay)

  env.info("DMIST: GridCount " .. zoneName)
end

--- Advance to the next zone number and process it.
function DMIST.GridStatus()
  DMIST.GridStart = DMIST.GridStart + 1
  DMIST.GridCount(tostring(DMIST.GridStart))
end

-- Startup
DMIST.MakeSomeTables()   -- build the live sets before anything spawns
DMIST.ColorAllZones()    -- initial full color pass
DMIST.GridStatus()       -- kick off the rolling per-zone update loop
