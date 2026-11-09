-- Offline test for QuestBeacon: stubs the WoW API and Questie, then drives the addon.
-- Run from the repo root:  luajit tests/test.lua QuestBeacon.lua
-- Stub WoW + Questie, then drive QuestBeacon's OnUpdate.
local now = 0
function GetTime() return now end
function print(...) io.write(table.concat({...}, " "), "\n") end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strsplit(sep, s) local r = {} for p in (s .. sep):gmatch("(.-)%" .. sep) do r[#r+1] = p end return unpack(r) end
SlashCmdList = {}
function CreateVector2D(x, y) return { x = x, y = y } end
-- world = map coords * 1000 yards, single continent 1 for map 1440
C_Map = {}
local player = { x = 0.50, y = 0.50 }
function C_Map.GetBestMapForUnit() return 1440 end
function C_Map.GetPlayerMapPosition() return { x = player.x, y = player.y } end
function C_Map.GetWorldPosFromMapPos(map, v) if map == 1440 then return 1, { x = v.x * 1000, y = v.y * 1000 } elseif map == 9999 then return 2, { x = 0, y = 0 } end end
local pin
UIParent = {}
local facing = 0
function GetPlayerFacing() return facing end
function C_Map.GetMapWorldSize() return 1000, 1000 end
function IsShiftKeyDown() return false end
GameFontNormal = { GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end }
GameTooltip = setmetatable({}, { __index = function() return function() end end })
function C_Map.CanSetUserWaypointOnMap() return true end
function C_Map.SetUserWaypoint(p) pin = p end
function C_Map.GetUserWaypoint() return pin end
function C_Map.HasUserWaypoint() return pin ~= nil end
function C_Map.ClearUserWaypoint() pin = nil end
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { uiMapID = m, position = { x = x, y = y } } end }
SUPERTRACK_CALLS = 0
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() SUPERTRACK_CALLS = SUPERTRACK_CALLS + 1 end }
SOUNDS = 0
function PlaySound() SOUNDS = SOUNDS + 1 end
SOUNDKIT = { MAP_PING = 3175 }
Questie = { db = { char = {} } }
local plates = {}
local noop = function() end
local function Frame()
  local fr = setmetatable({ shown = true, scripts = {} }, { __index = function() return noop end })
  function fr:RegisterEvent() end
  function fr:SetScript(n, f) self.scripts[n] = f end
  function fr:SetFrameLevel() end function fr:GetFrameLevel() return 1 end
  function fr:SetPoint() end function fr:SetSize(w, h) self.w = w end
  function fr:Show() self.shown = true end function fr:Hide() self.shown = false end
  function fr:CreateTexture() local tx = setmetatable({}, { __index = function() return noop end })
    function tx:CreateAnimationGroup() return fr:CreateAnimationGroup() end
    function tx:SetRotation(r) tx.rot = r end
    function tx:SetSize(w) tx.w = w end
    return tx end
  function fr:CreateFontString() local fs = setmetatable({}, { __index = function() return noop end }) function fs:SetText(t) fs.text = t end return fs end
  function fr:CreateAnimationGroup() return setmetatable({}, { __index = function(t, k)
    if k == "CreateAnimation" then return function() return setmetatable({}, { __index = function() return function() end end }) end end
    return function() end end }) end
  return fr
end
local mainFrame
function CreateFrame(kind, name, parent) local fr = Frame() if not parent then mainFrame = fr end return fr end
local units = { nameplate1 = { guid = "Creature-0-1-2-3-100-0000", dead = false }, nameplate2 = { guid = "Creature-0-1-2-3-200-0000", dead = false } }
C_NamePlate = {}
for u in pairs(units) do plates[u] = Frame() plates[u].namePlateUnitToken = u end
function C_NamePlate.GetNamePlateForUnit(u) return plates[u] end
function C_NamePlate.GetNamePlates() local r = {} for _, p in pairs(plates) do r[#r+1] = p end return r end
function UnitGUID(u) return units[u] and units[u].guid end
function UnitIsDead(u) return units[u] and units[u].dead end
function UnitIsPlayer() return false end
-- Questie
local questlog = {
  [1] = { Id = 1, name = "Gather Crates", Objectives = {
    { Completed = false, Needed = 5, Collected = 0, spawnList = {
      [5001] = { Id = 5001, Name = "Crate", TooltipKey = "o_5001", Spawns = { [10] = { { 60, 50 }, { 52, 50 } }, [99] = { { 1, 1 } } } },
      [100]  = { Id = 100, Name = "Wolf", Hostile = true, TooltipKey = "m_100", Spawns = { [10] = { { 50.1, 50 } } } } } },
    { Completed = true, spawnList = { [5002] = { Id = 5002, Name = "Done thing", Spawns = { [10] = { { 50.2, 50 } } } },
                                      [200] = { Id = 200, Name = "Done mob", Hostile = true, Spawns = {} } } },
  } },
  [2] = 12345, -- quest id only, no object (Questie does this)
}
QuestieLoader = { ImportModule = function(_, n)
  if n == "QuestiePlayer" then return { currentQuestlog = questlog } end
  if n == "ZoneDB" then return { GetUiMapIdByAreaId = function(_, a) return ({ [10] = 1440, [99] = 9999 })[a] end } end
end }

assert(loadfile(arg[1]))("QuestBeacon", {})
mainFrame.scripts.OnEvent(mainFrame, "ADDON_LOADED", "QuestBeacon")
check0 = QuestBeaconDB.mobs == true
QuestBeaconDB.mobs = false
local function tick() now = now + 1.1 mainFrame.scripts.OnUpdate(mainFrame, 1.1) end
local function check(name, cond) print((cond and "PASS " or "FAIL ") .. name) if not cond then FAILED = true end end

tick()
check("beacon on nearest crate (52,50)", pin and math.abs(pin.position.x - 0.52) < 1e-6)
check("mob spawn not used for beacon", pin and pin.position.x ~= 0.501)
check("other-continent spawn ignored", pin.uiMapID == 1440)
local G = QuestBeacon.glows
check("glow on needed mob 100", G[plates.nameplate1] and G[plates.nameplate1].shown)
check("no glow on mob of finished objective", not (G[plates.nameplate2] and G[plates.nameplate2].shown))
units.nameplate1.dead = true
mainFrame.scripts.OnEvent(mainFrame, "UNIT_HEALTH", "nameplate1")
check("glow removed when mob dies", not G[plates.nameplate1].shown)
units.nameplate1.dead = false
mainFrame.scripts.OnEvent(mainFrame, "NAME_PLATE_UNIT_ADDED", "nameplate1")
-- glow frames are children; find via QuestBeacon internals indirectly: re-run UpdatePlate path
-- walk to the crate -> visited, then beacon should move to (60,50)
player.x = 0.5201
tick() tick()
check("after arriving, beacon moves to (60,50)", pin and math.abs(pin.position.x - 0.60) < 1e-6)
-- user places own pin -> addon stands back
pin = UiMapPoint.CreateFromCoordinates(1440, 0.1, 0.1)
tick()
check("user pin kept", math.abs(pin.position.x - 0.1) < 1e-6)
pin = nil tick()
check("beacon resumes after user pin cleared", pin and math.abs(pin.position.x - 0.60) < 1e-6)
-- skip: from (60,50) the only other unvisited crate spot is none -> walk back: reset visits via skip test setup
player.x, player.y = 0.55, 0.5
QuestBeacon.Skip(false)     -- skip current (60,50)
tick()
check("skip -> no other crate spot left (52 visited, 60 skipped) clears beacon", pin == nil)
SlashCmdList.QUESTBEACON("reset") tick()
check("reset -> beacon back on nearest", pin ~= nil)
local before = pin.position.x
QuestBeacon.Skip(false) tick()
check("skip moves to the other spot", pin and pin.position.x ~= before)
QuestBeacon.Skip(true) tick()
check("skip type drops all Crate spots", pin == nil)
SlashCmdList.QUESTBEACON("reset") tick()
-- resize
SlashCmdList.QUESTBEACON("size 2")
check("size 2 saved", QuestBeaconDB.arrowSize == 2)
QuestBeacon.UpdateArrow()
local A = _G.QB_ARROW
SlashCmdList.QUESTBEACON("size 99")
check("size clamped to 4", QuestBeaconDB.arrowSize == 4)
SlashCmdList.QUESTBEACON("size 0.1")
check("size clamped to 0.4", QuestBeaconDB.arrowSize == 0.4)
check("arrow frame resized to 0.4 (25.6px)", A and math.abs(A.w - 25.6) < 1e-6)
SlashCmdList.QUESTBEACON("size 1")
check("glow resized with arrow (96px at size 1)", A and A.glow.w == 96)
-- objective done -> beacon cleared
questlog[1].Objectives[1].Collected = 5
tick()
check("beacon cleared when objective complete", pin == nil)
check("mob glow gone when its objective completes", not G[plates.nameplate1].shown)
-- arrow geometry: target due east of player
local T = { uiMapID = 1440, x = 0.6, y = 0.5 }
player.x, player.y = 0.5, 0.5
local function near(a, b) return math.abs(((a - b + math.pi) % (2 * math.pi)) - math.pi) < 1e-6 end
facing = 0;            local a, d = QuestBeacon.ArrowAngle(T)
check("east target, facing north -> arrow points right (-90deg)", near(a, -math.pi / 2) and math.abs(d - 100) < 1e-6)
facing = -math.pi / 2; a = QuestBeacon.ArrowAngle(T)
check("east target, facing east -> straight ahead", near(a, 0))
facing = math.pi / 2;  a = QuestBeacon.ArrowAngle(T)
check("east target, facing west -> behind", near(a, math.pi))
T.x, T.y = 0.5, 0.4; facing = 0; a = QuestBeacon.ArrowAngle(T)
check("north target, facing north -> straight ahead", near(a, 0))
T.x, T.y = 0.4, 0.5; a = QuestBeacon.ArrowAngle(T)
check("west target, facing north -> left (+90deg)", near(a, math.pi / 2))
-- /reload while our pin is on the map: must keep working, not treat it as the user's
questlog[1].Objectives[1].Collected = 0
SlashCmdList.QUESTBEACON("reset") tick()
check("pin set before reload", pin ~= nil)
local pinBefore = pin
assert(loadfile(arg[1]))("QuestBeacon", {})   -- fresh addon state, same saved DB + map pin
mainFrame.scripts.OnEvent(mainFrame, "ADDON_LOADED", "QuestBeacon")
tick()
QuestBeacon = _G.QuestBeacon
check("after reload the beacon keeps the same spot (not paused)", pin and pin.position.x == pinBefore.position.x and pin.position.y == pinBefore.position.y)
QuestBeacon.UpdateArrow()
check("after reload the arrow shows", _G.QB_ARROW and _G.QB_ARROW.shown)
-- leftover pin from an older version, no record in saved DB (the user's real case)
QuestBeaconDB.pin = nil
pin = UiMapPoint.CreateFromCoordinates(1440, 0.33, 0.33)
assert(loadfile(arg[1]))("QuestBeacon", {})
mainFrame.scripts.OnEvent(mainFrame, "ADDON_LOADED", "QuestBeacon")
tick()
check("leftover unknown pin adopted -> beacon resumes on quest spot", pin and math.abs(pin.position.x - 0.33) > 1e-6)
_G.QuestBeacon.UpdateArrow()
check("leftover pin case: arrow shows", _G.QB_ARROW and _G.QB_ARROW.shown)
-- a pin placed by the user AFTER load still pauses it
pin = UiMapPoint.CreateFromCoordinates(1440, 0.11, 0.11)
tick()
check("pin placed later by user still respected", math.abs(pin.position.x - 0.11) < 1e-6)
pin = nil tick()
check("mobs targeting on by default", check0)
-- quest mobs: wolf spawn at (50.1,50) is nearer than any crate
questlog[1].Objectives[1].Collected = 0
SlashCmdList.QUESTBEACON("reset")
player.x, player.y = 0.45, 0.5
SlashCmdList.QUESTBEACON("mobs") tick()
check("mobs on -> arrow on nearest wolf spawn (50.1,50)", pin and math.abs(pin.position.x - 0.501) < 1e-6)
_G.QuestBeacon.UpdateArrow()
check("mob target labelled Kill", _G.QB_ARROW.text.text and _G.QB_ARROW.text.text:find("Kill") ~= nil)
player.x = 0.485 tick() tick()   -- 16 yd from the wolf spawn
check("within 20 yd of mob spawn counts as reached -> next target (crate 52,50)", pin and math.abs(pin.position.x - 0.52) < 1e-6)
_G.QuestBeacon.UpdateArrow()
check("object target not labelled Kill", not _G.QB_ARROW.text.text:find("Kill"))
SlashCmdList.QUESTBEACON("mobs") SlashCmdList.QUESTBEACON("reset") player.x = 0.45 tick()
check("mobs off -> crate again", pin and math.abs(pin.position.x - 0.52) < 1e-6)
-- ===== v0.7 features =====
QuestBeaconDB.mobs = false  -- objects only for these checks
SlashCmdList.QUESTBEACON("reset")
questlog[1].Objectives[1].Collected = 2
player.x, player.y = 0.45, 0.5
tick()
_G.QuestBeacon.UpdateArrow()
local A = _G.QB_ARROW
check("progress shown on arrow (2/5)", A.text.text:find("2/5", 1, true) ~= nil)
check("medium target -> yellow distance (70 yd)", A.text.text:find("ffffff33", 1, true) ~= nil)
player.x = 0.30 tick() _G.QuestBeacon.UpdateArrow()
check("far target -> red distance (220 yd)", A.text.text:find("ffff4444", 1, true) ~= nil)
player.x = 0.50 tick() _G.QuestBeacon.UpdateArrow()
check("close target -> green distance (20 yd)", A.text.text:find("ff33ff33", 1, true) ~= nil)
check("no Blizzard super tracking calls (keeps Questie focus intact)", SUPERTRACK_CALLS == 0)
-- second quest with an object nearer than quest 1's crates
questlog[3] = { Id = 3, name = "Shiny Rocks", Objectives = { { Completed = false, Needed = 1, Collected = 0, spawnList = {
  [7001] = { Id = 7001, Name = "Rock", TooltipKey = "o_7001", Spawns = { [10] = { { 49, 50 } } } } } } } }
player.x = 0.50 SlashCmdList.QUESTBEACON("reset") tick()
check("without follow: nearest is Rock (quest 3)", pin and math.abs(pin.position.x - 0.49) < 1e-6)
Questie.db.char.TrackerFocus = 1 tick()
check("Questie focus on quest 1 -> crate, ignoring nearer Rock", pin and math.abs(pin.position.x - 0.52) < 1e-6)
_G.QuestBeacon.UpdateArrow()
check("arrow says Following: Gather Crates", A.sub.text and A.sub.text:find("Gather Crates", 1, true) ~= nil)
Questie.db.char.TrackerFocus = nil tick()
check("focus cleared -> nearest again (Rock)", pin and math.abs(pin.position.x - 0.49) < 1e-6)
_G.QuestBeacon.ToggleFollow()   -- follow quest of current target = quest 3
check("middle-click follow picks the current target's quest", QuestBeaconDB.follow == 3)
questlog[3].Objectives[1].Collected = 1 tick()
check("followed quest done -> follow cleared, back to all quests", QuestBeaconDB.follow == nil and pin and math.abs(pin.position.x - 0.52) < 1e-6)
-- arrival sound
local before = SOUNDS
player.x = 0.5199 tick()
check("arrival plays a sound", SOUNDS == before + 1)
-- lock
local moved = false
A.StartMoving = function() moved = true end
SlashCmdList.QUESTBEACON("lock")
A.scripts.OnDragStart(A)
check("locked arrow does not move", not moved)
local sz = QuestBeaconDB.arrowSize
A.scripts.OnMouseWheel(A, 1)
check("locked arrow does not resize", QuestBeaconDB.arrowSize == sz)
SlashCmdList.QUESTBEACON("lock")
A.scripts.OnDragStart(A)
check("unlocked arrow moves", moved)
player.x = 0.45 tick()
A.scripts.OnMouseUp(A, "MiddleButton")
check("middle-click toggles follow via the arrow", QuestBeaconDB.follow ~= nil)
SlashCmdList.QUESTBEACON("debug")
print(FAILED and "SOME FAILED" or "ALL PASSED")
