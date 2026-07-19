MESSAGE:New("AIRWING START",10):ToAll()
DWGR = {}
DWGR.FS433=SQUADRON:New("F-4E Group", 48, "POSSUM ")
DWGR.FS433:SetGrouping(2)

DWGR.FS433:SetRadio(233)                       -- Squadon communicates on 233 MHz AM.
DWGR.FS433:SetSkill(AI.Skill.EXCELLENT)
DWGR.FS433:SetFuelLowThreshold(.412):SetFuelLowRefuel(true)
DWGR.FS433:AddMissionCapability({AUFTRAG.Type.ORBIT_RACETRACK,AUFTRAG.Type.BAI,AUFTRAG.Type.CAP, AUFTRAG.Type.INTERCEPT,AUFTRAG.Type.CAS,AUFTRAG.Type.CASENHANCED,
    AUFTRAG.Type.PATROLRACETRACK,AUFTRAG.Type.PATROLZONE,AUFTRAG.Type.SEAD,AUFTRAG.Type.STRAFING,AUFTRAG.Type.STRIKE})

DWGR.TFW8 = AIRWING:New("WarehouseUBON", "8th Tactical Fighter Wing")
--UBON is the home base of the 8th TFW, which is the parent unit of the 433rd FS (F-4E) and 431st FS 
--(F-100D). The 8th TFW is a composite wing with multiple squadrons and aircraft types.
-- We are using Caucasus map and the Airwing is based at AIRBASE.Caucasus.Tbilisi_Lochini

DWGR.TFW8:Start()
DWGR.TFW8:SetLandingOverheadBreak()
DWGR.TFW8:SetTakeoffAir()--SetTakeoffHot()

DWGR.TFW8:AddSquadron(DWGR.FS433)

DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Group"), 48, {AUFTRAG.Type.CAP,AUFTRAG.Type.INTERCEPT}, 100)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Mk82"), 48, {AUFTRAG.Type.BAI, AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT}, 79)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Mk82SNAKES"), 6, {AUFTRAG.Type.BAI, AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT}, 81)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E SEADMk22"), 4, {AUFTRAG.Type.SEAD}, 80)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E SEADMix"), 4, {AUFTRAG.Type.SEAD}, 79)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E STRIKE1"), 12, {AUFTRAG.Type.STRIKE }, 80)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E STRIKE2"), 12, {AUFTRAG.Type.STRIKE}, 79)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E STRIKE1"), 2, { AUFTRAG.Type.BAI,AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT,AUFTRAG.Type.PATROLZONE}, 70)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E STRIKE2"), 2, { AUFTRAG.Type.BAI,AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT,AUFTRAG.Type.PATROLZONE}, 71)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Strafe"), 6, { AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT}, 80)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Strafe"), 48, { AUFTRAG.Type.STRAFING}, 100)


local zoneKheSanh=ZONE:New("KheSanhCont")
DWGR.OrbitMissions = {}

function DWGR.TFW8:OnAfterFlightOnMission(From, Event, To, FlightGroup, Mission)
  local flightgroup=FlightGroup --Ops.FlightGroup#FLIGHTGROUP
  local mission=Mission         --Ops.Auftrag#AUFTRAG
  
  -- Info message.
  local text=string.format("Flight group %s on %s mission %s", flightgroup:GetName(), mission:GetType(), mission:GetName())
  if mission.GetType() == "ORBIT" then
    
  end
  env.info(text)
  MESSAGE:New(text, 300):ToAll()
end

--DWGR.TFW8:AddMission(KheSanh)
--DWGR.TFW8:AddMission(KheSanh2)
