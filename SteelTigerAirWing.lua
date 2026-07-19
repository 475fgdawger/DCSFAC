MESSAGE:New("AIRWING START",10):ToAll()
DWGR = {}
DWGR.FS433=SQUADRON:New("F-4E Group", 48, "433rd FS (POSSUM)")
DWGR.FS433:SetGrouping(2)
--DWGR.FS433:SetCallsign(CALLSIGN.TEAM.Possum, 1)
DWGR.FS433:SetRadio(233)                       -- Squadon communicates on 233 MHz AM.
DWGR.FS433:SetSkill(AI.Skill.EXCELLENT)
DWGR.FS433:SetFuelLowThreshold(.412):SetFuelLowRefuel(true)
DWGR.FS433:AddMissionCapability({AUFTRAG.Type.ORBIT_RACETRACK,AUFTRAG.Type.BAI,AUFTRAG.Type.CAP, AUFTRAG.Type.INTERCEPT,AUFTRAG.Type.CAS,AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.PATROLRACETRACK,AUFTRAG.Type.PATROLZONE,AUFTRAG.Type.SEAD,AUFTRAG.Type.STRAFING,AUFTRAG.Type.STRIKE})
--DWGR.FS433:SetFuelThreshold(0.412) -- 25% fuel remaining triggers RTB
--local FS431=SQUADRON:New("F-100 Group", 12, "431rd FS (HADES)")
--FS431:AddMissionCapability({AUFTRAG.Type.FACA})



DWGR.TFW8 = AIRWING:New("WarehouseUBON", "8th Tactical Fighter Wing")
--UBON is the home base of the 8th TFW, which is the parent unit of the 433rd FS (F-4E) and 431st FS 
--(F-100D). The 8th TFW is a composite wing with multiple squadrons and aircraft types.
-- We are using Caucasus map and the Airwing is based at AIRBASE.Caucasus.Tbilisi_Lochini


DWGR.TFW8:Start()
DWGR.TFW8:SetLandingOverheadBreak()
DWGR.TFW8:SetTakeoffAir()--SetTakeoffHot()


DWGR.TFW8:AddSquadron(DWGR.FS433)



--DWGR.TFW8:AddSquadron(DWGR.FS431)

DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Mk82"), -1, {AUFTRAG.Type.BAI, AUFTRAG.Type.CAS,AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT,AUFTRAG.Type.PATROLZONE}, 80)
DWGR.TFW8:NewPayload(GROUP:FindByName("F-4E Mk82SNAKES"), -1, {AUFTRAG.Type.BAI, AUFTRAG.Type.CAS,AUFTRAG.Type.CASENHANCED,AUFTRAG.Type.ORBIT,AUFTRAG.Type.PATROLZONE}, 80)
--TFW8:NewPayload(GROUP:FindByName("F-100 FAC"), -1, {AUFTRAG.Type.FACA}, 80)


local zoneKheSanh=ZONE:New("KheSanhCont")
DWGR.OrbitMissions = {}
--AUFTRAG:NewORBIT(Coordinate, Altitude, Speed, Heading, Leg)
--KheSanh = AUFTRAG:NewORBIT_RACETRACK(zoneKheSanh:GetCoordinate(), 30000, 300, 045, 10):SetName("Khe SanH CAS")
--KheSanh2 = AUFTRAG:NewORBIT_RACETRACK(zoneKheSanh:GetCoordinate(), 28000, 300, 060, 10):SetName("Khe SanH CAS 2")

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