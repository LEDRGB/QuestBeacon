-- QuestBeacon: in-world beacon over the nearest quest object you still need
-- (a user waypoint + super-tracking, the same marker as a tracked map pin),
-- and a pulsing glow on the nameplates of mobs you need for quests.
-- Quest/spawn data comes from Questie at runtime.

local ADDON = ...
local QB = {}
_G.QuestBeacon = QB

local TICK = 1.0          -- seconds between beacon updates
local ARRIVE_YARDS = 6    -- this close to an object spawn = "visited", move on
local ARRIVE_MOB_YARDS = 20 -- mobs wander around their spawn point
local VISITED_SECS = 300  -- a visited spawn is skipped for this long
local MAX_YARDS = 2000    -- ignore spawns further than this

local function Print(msg) print("|cffffd200QuestBeacon|r " .. msg) end

---------------------------------------------------------------------------
-- Questie access
---------------------------------------------------------------------------
local QuestiePlayer, ZoneDB
local function LoadQuestie()
  if QuestiePlayer and ZoneDB then return true end
  if not (QuestieLoader and QuestieLoader.ImportModule) then return false end
  local ok1, qp = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestiePlayer")
  local ok2, zdb = pcall(QuestieLoader.ImportModule, QuestieLoader, "ZoneDB")
  if ok1 and ok2 and qp and zdb then QuestiePlayer, ZoneDB = qp, zdb end
  return QuestiePlayer ~= nil
end

local function ObjectiveDone(o)
  if o.Completed then return true end
  if o.Needed and o.Needed > 0 and o.Collected and o.Collected >= o.Needed then return true end
  return false
end

-- Walk every unfinished objective of every quest in the log.
-- cb(source, objective, quest) for each spawn source.
local function ForEachSource(cb)
  if not LoadQuestie() then return end
  for _, quest in pairs(QuestiePlayer.currentQuestlog or {}) do
    if type(quest) == "table" then
      for _, list in ipairs({ quest.Objectives or {}, quest.SpecialObjectives or {} }) do
        for _, o in pairs(list) do
          if type(o) == "table" and not ObjectiveDone(o) and type(o.spawnList) == "table" then
            for _, src in pairs(o.spawnList) do
              if type(src) == "table" then cb(src, o, quest) end
            end
          end
        end
      end
    end
  end
end

-- Which quest to follow: our own pick (middle-click / slash) first, then Questie's tracker focus.
function QB.FollowedQuest()
  if QuestBeaconDB.follow then return QuestBeaconDB.follow, "own" end
  if QuestBeaconDB.useFocus and Questie and Questie.db and Questie.db.char then
    local f = Questie.db.char.TrackerFocus
    if type(f) == "number" then return f, "questie" end
  end
end

local function QuestName(quest)
  return quest and (quest.name or quest.Name) or "?"
end

local function IsMobSource(src)
  if src.Hostile then return true end
  local k = src.TooltipKey
  return type(k) == "string" and k:sub(1, 2) == "m_"
end

---------------------------------------------------------------------------
-- World positions (cached; map->world conversion is the costly bit)
---------------------------------------------------------------------------
local worldCache = {}
local function WorldPos(uiMapID, x, y) -- x,y in 0..1
  local key = uiMapID .. ":" .. x .. ":" .. y
  local c = worldCache[key]
  if c == nil then
    c = false
    local ok, inst, pos = pcall(C_Map.GetWorldPosFromMapPos, uiMapID, CreateVector2D(x, y))
    if ok and inst and pos then c = { inst, pos.x, pos.y } end
    worldCache[key] = c
  end
  return c or nil
end

local function PlayerWorld()
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return end
  local p = C_Map.GetPlayerMapPosition(mapID, "player")
  if not p then return end
  local w = WorldPos(mapID, math.floor(p.x * 1000) / 1000, math.floor(p.y * 1000) / 1000)
  -- don't cache the player's (moving) position forever
  worldCache[mapID .. ":" .. math.floor(p.x * 1000) / 1000 .. ":" .. math.floor(p.y * 1000) / 1000] = nil
  return w
end

---------------------------------------------------------------------------
-- Beacon
---------------------------------------------------------------------------
local visited = {}   -- key -> time visited
local skippedSrc = {} -- source id -> time skipped (whole object type)
local SKIP_SRC_SECS = 600
local current        -- { key, uiMapID, x, y, name }
local ourPin         -- the waypoint we placed (to tell it apart from a user pin)

local function SamePoint(a, b)
  return a and b and a.uiMapID == b.uiMapID
    and math.abs(a.position.x - b.position.x) < 0.0005
    and math.abs(a.position.y - b.position.y) < 0.0005
end

local function ClearBeacon()
  if ourPin and C_Map.HasUserWaypoint() and SamePoint(C_Map.GetUserWaypoint(), ourPin) then
    C_Map.ClearUserWaypoint()
  end
  ourPin, current = nil, nil
  QuestBeaconDB.pin = nil
end

local function SetBeacon(t)
  if current and current.key == t.key then return end
  if not C_Map.CanSetUserWaypointOnMap(t.uiMapID) then return end
  local point = UiMapPoint.CreateFromCoordinates(t.uiMapID, t.x, t.y)
  C_Map.SetUserWaypoint(point)
  -- No super tracking: Forever doesn't draw the 3D marker, and changing super
  -- tracking makes Questie drop its tracker focus.
  ourPin = C_Map.GetUserWaypoint()
  -- remember it across /reload, or we'd mistake our own pin for the user's
  QuestBeaconDB.pin = ourPin and { m = ourPin.uiMapID, x = ourPin.position.x, y = ourPin.position.y } or nil
  current = t
  if QuestBeaconDB.debug then Print(("-> %s (%.1f, %.1f)"):format(t.name or "?", t.x * 100, t.y * 100)) end
end

local function UpdateBeacon()
  if not QuestBeaconDB.beacon then return end
  -- First run after login/reload with a pin already on the map but no record
  -- of ours (e.g. left by an older version): adopt it rather than pausing forever.
  if not QB.adopted then
    QB.adopted = true
    if not ourPin and C_Map.HasUserWaypoint() then ourPin = C_Map.GetUserWaypoint() end
  end
  -- a pin the user placed themselves wins: stand back until it's gone
  if C_Map.HasUserWaypoint() and not SamePoint(C_Map.GetUserWaypoint(), ourPin) then
    if current and QuestBeaconDB.debug then Print("a map pin you placed is active: pausing (remove it to resume)") end
    ourPin, current = nil, nil
    return
  end
  local me = PlayerWorld()
  if not me then ClearBeacon() return end
  local now = GetTime()
  local best, bestD
  local follow = QB.FollowedQuest()
  local function Consider(src, o, quest, onlyQuest)
    if onlyQuest and quest.Id ~= onlyQuest then return end
    if type(src.Spawns) ~= "table" then return end
    local isMob = IsMobSource(src)
    if isMob and not QuestBeaconDB.mobs then return end
    local sk = skippedSrc[src.Id or src.Name or "?"]
    if sk and now - sk < SKIP_SRC_SECS then return end
    for areaId, spawns in pairs(src.Spawns) do
      local uiMapID = ZoneDB:GetUiMapIdByAreaId(areaId)
      if uiMapID and type(spawns) == "table" then
        for _, s in ipairs(spawns) do
          local x, y = s[1], s[2]
          if x and y and x >= 0 and y >= 0 then
            local key = uiMapID .. ":" .. x .. ":" .. y
            local v = visited[key]
            if not v or now - v > VISITED_SECS then
              local w = WorldPos(uiMapID, x / 100, y / 100)
              if w and w[1] == me[1] then
                local d = math.sqrt((w[2] - me[2]) ^ 2 + (w[3] - me[3]) ^ 2)
                if d <= MAX_YARDS and (not bestD or d < bestD) then
                  best = { key = key, uiMapID = uiMapID, x = x / 100, y = y / 100, name = src.Name, src = src.Id or src.Name or "?", isMob = isMob,
                    questId = quest.Id, questName = QuestName(quest),
                    progress = (o.Needed and o.Needed > 1) and ("%d/%d"):format(o.Collected or 0, o.Needed) or nil }
                  bestD = d
                end
              end
            end
          end
        end
      end
    end
  end
  QB.following = nil
  if follow then
    ForEachSource(function(src, o, quest) Consider(src, o, quest, follow) end)
    if best then QB.following = follow
    elseif QuestBeaconDB.follow then
      -- our followed quest has nothing left (done or abandoned): stop following
      QuestBeaconDB.follow = nil
      Print("followed quest has nothing left to do, back to all quests")
    end
  end
  if not best then ForEachSource(function(src, o, quest) Consider(src, o, quest) end) end
  if best and bestD <= (best.isMob and ARRIVE_MOB_YARDS or ARRIVE_YARDS) then
    -- standing on it: count it as done and go for the next one next tick
    visited[best.key] = now
    if QuestBeaconDB.sound and QB.lastArrived ~= best.key then
      QB.lastArrived = best.key
      pcall(PlaySound, SOUNDKIT and SOUNDKIT.MAP_PING or 3175)
    end
    current = nil
    return
  end
  if best then SetBeacon(best) else ClearBeacon() end
end

-- Skip the current spot (next nearest), or every spot of this object type.
function QB.Skip(wholeType)
  if not current then Print("nothing to skip") return end
  if wholeType then
    skippedSrc[current.src] = GetTime()
    Print("skipping all '" .. (current.name or "?") .. "' for 10 min")
  else
    visited[current.key] = GetTime()
    Print("next spot")
  end
  current = nil
  pcall(UpdateBeacon)
end
function QB.ToggleFollow()
  if QuestBeaconDB.follow then
    QuestBeaconDB.follow = nil
    Print("following all quests")
  elseif current and current.questId then
    QuestBeaconDB.follow = current.questId
    Print("following only: " .. (current.questName or current.questId))
  else
    Print("nothing to follow yet")
  end
  current = nil
  pcall(UpdateBeacon)
end
function QuestBeacon_Skip() QB.Skip(false) end
function QuestBeacon_Follow() QB.ToggleFollow() end
BINDING_NAME_QUESTBEACON_FOLLOW = "Follow this quest only (toggle)"
function QuestBeacon_SkipType() QB.Skip(true) end
BINDING_HEADER_QUESTBEACON = "QuestBeacon"
BINDING_NAME_QUESTBEACON_SKIP = "Skip to next spot"
BINDING_NAME_QUESTBEACON_SKIPTYPE = "Skip this object type"

---------------------------------------------------------------------------
-- On-screen arrow (Forever doesn't draw the 3D waypoint marker)
---------------------------------------------------------------------------
local arrowFrame
-- Resize by changing sizes (not SetScale) so the saved position stays put.
function QB.SetArrowSize(size, quiet)
  size = math.max(0.4, math.min(4, math.floor(size * 10 + 0.5) / 10))
  QuestBeaconDB.arrowSize = size
  local a = arrowFrame
  if not a then return size end
  a:SetSize(64 * size, 64 * size)
  a.glow:SetSize(96 * size, 96 * size)
  local font, _, flags = GameFontNormal:GetFont()
  a.text:SetFont(font, math.max(10, math.floor(12 * math.sqrt(size) + 0.5)), flags)
  if not quiet and QuestBeaconDB.debug then Print("arrow size " .. size) end
  return size
end

local function GetArrow()
  if arrowFrame then return arrowFrame end
  local a = CreateFrame("Frame", "QuestBeaconArrow", UIParent)
  a:SetSize(64, 64)
  a:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
  a:SetFrameStrata("HIGH")
  a:SetMovable(true)
  a:SetClampedToScreen(true)
  a:EnableMouse(true)
  a:RegisterForDrag("LeftButton")
  a:SetScript("OnDragStart", function(self) if not QuestBeaconDB.locked then self:StartMoving() end end)
  a:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local cx, cy = self:GetCenter()
    local ux, uy = UIParent:GetCenter()
    local sc = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
    QuestBeaconDB.arrowX, QuestBeaconDB.arrowY = cx * sc - ux, cy * sc - uy
    self:ClearAllPoints()
    self:SetPoint("CENTER", UIParent, "CENTER", QuestBeaconDB.arrowX, QuestBeaconDB.arrowY)
  end)
  a:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then QB.Skip(IsShiftKeyDown())
    elseif button == "MiddleButton" then QB.ToggleFollow() end
  end)
  a:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("QuestBeacon")
    if current and current.questName then GameTooltip:AddLine("Quest: " .. current.questName, 1, 0.82, 0) end
    if QuestBeaconDB.locked then
      GameTooltip:AddLine("Locked (/beacon lock to unlock)", 1, 0.4, 0.4)
    else
      GameTooltip:AddLine("Drag: move the arrow", 1, 1, 1)
      GameTooltip:AddLine("Mouse wheel: bigger / smaller", 1, 1, 1)
    end
    GameTooltip:AddLine("Middle-click: follow only this quest / all quests", 1, 1, 1)
    GameTooltip:AddLine("Right-click: next spot", 1, 1, 1)
    GameTooltip:AddLine("Shift+right-click: skip this object type", 1, 1, 1)
    GameTooltip:Show()
  end)
  a:SetScript("OnLeave", function() GameTooltip:Hide() end)
  if QuestBeaconDB.arrowX then
    a:ClearAllPoints()
    a:SetPoint("CENTER", UIParent, "CENTER", QuestBeaconDB.arrowX, QuestBeaconDB.arrowY)
  end
  local glow = a:CreateTexture(nil, "BACKGROUND")
  glow:SetPoint("CENTER")
  a.glow = glow
  glow:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  glow:SetBlendMode("ADD")
  glow:SetVertexColor(1, 0.85, 0.2, 0.8)
  local t = a:CreateTexture(nil, "ARTWORK")
  t:SetAllPoints()
  t:SetTexture("Interface\\Minimap\\MinimapArrow")
  t:SetVertexColor(1, 0.85, 0.2)
  a.tex = t
  local fs = a:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("TOP", a, "BOTTOM", 0, -2)
  a.text = fs
  local fs2 = a:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs2:SetPoint("TOP", fs, "BOTTOM", 0, -1)
  a.sub = fs2
  a:EnableMouseWheel(true)
  a:SetScript("OnMouseWheel", function(_, delta)
    if not QuestBeaconDB.locked then QB.SetArrowSize((QuestBeaconDB.arrowSize or 1) + delta * 0.1) end
  end)
  QB.SetArrowSize(QuestBeaconDB.arrowSize or 1, true)
  local ag = glow:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local an = ag:CreateAnimation("Alpha")
  an:SetFromAlpha(0.3) an:SetToAlpha(1) an:SetDuration(0.6)
  ag:Play()
  a:Hide()
  arrowFrame = a
  _G.QB_ARROW = a
  return a
end

-- Bearing to the target relative to where the player faces.
-- Returns angle for SetRotation (0 = straight ahead, + = to the left) and yards.
function QB.ArrowAngle(t)
  if not t then return end
  local p = C_Map.GetPlayerMapPosition(t.uiMapID, "player")
  local w, h = C_Map.GetMapWorldSize(t.uiMapID)
  local facing = GetPlayerFacing()
  if not (p and w and h and w > 0 and facing) then return end
  local dx = (t.x - p.x) * w   -- yards east
  local dy = (t.y - p.y) * h   -- yards south
  local bearing = math.atan2(-dx, -dy) -- counter-clockwise from north, like GetPlayerFacing
  return bearing - facing, math.sqrt(dx * dx + dy * dy)
end

local function UpdateArrow()
  local a = arrowFrame
  if not (QuestBeaconDB and QuestBeaconDB.arrow and QuestBeaconDB.beacon and current) then
    if a then a:Hide() end
    return
  end
  local ang, d = QB.ArrowAngle(current)
  if not ang then if a then a:Hide() end return end
  a = GetArrow()
  a.tex:SetRotation(ang)
  local dcol = d < 40 and "ff33ff33" or d < 150 and "ffffff33" or "ffff4444"
  local prog = current.progress and (" |cffcccccc" .. current.progress .. "|r") or ""
  if current.isMob then
    a.tex:SetVertexColor(1, 0.35, 0.3)
    a.glow:SetVertexColor(1, 0.3, 0.2, 0.8)
    a.text:SetText(("|cffff5555Kill|r %s%s  |c%s%d yd|r"):format(current.name or "?", prog, dcol, d))
  else
    a.tex:SetVertexColor(1, 0.85, 0.2)
    a.glow:SetVertexColor(1, 0.85, 0.2, 0.8)
    a.text:SetText(("%s%s  |c%s%d yd|r"):format(current.name or "?", prog, dcol, d))
  end
  a.sub:SetText(QB.following and ("Following: " .. (current.questName or "?")) or "")
  a.isMob = current.isMob
  a:Show()
end
QB.UpdateArrow = UpdateArrow

---------------------------------------------------------------------------
-- Nameplate glow
---------------------------------------------------------------------------
local neededMobs = {}
local glows = {}
QB.glows = glows

local function RebuildMobs()
  wipe(neededMobs)
  ForEachSource(function(src)
    if IsMobSource(src) and src.Id then neededMobs[tonumber(src.Id)] = true end
  end)
end

local function NpcID(unit)
  local guid = UnitGUID(unit)
  if not guid then return end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

local function GetGlow(plate)
  local g = glows[plate]
  if g then return g end
  g = CreateFrame("Frame", nil, plate)
  g:SetFrameLevel(plate:GetFrameLevel() + 5)
  g:SetPoint("CENTER", plate, "CENTER", 0, 0)
  g:SetSize(150, 44)
  local t = g:CreateTexture(nil, "OVERLAY")
  t:SetAllPoints()
  t:SetTexture("Interface\\GLUES\\Models\\UI_Draenei\\GenericGlow64")
  t:SetBlendMode("ADD")
  t:SetVertexColor(1, 0.85, 0.2)
  local ag = g:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(0.35) a:SetToAlpha(1) a:SetDuration(0.6)
  ag:Play()
  glows[plate] = g
  return g
end

local function UpdatePlate(unit)
  local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
  if not ok or not plate then return end
  local need = QuestBeaconDB.glow and not UnitIsDead(unit) and not UnitIsPlayer(unit)
    and neededMobs[NpcID(unit) or 0]
  if need then
    pcall(function() GetGlow(plate):Show() end)
  elseif glows[plate] then
    glows[plate]:Hide()
  end
end

local function UpdateAllPlates()
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
    local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
    if unit then UpdatePlate(unit) end
  end
end

---------------------------------------------------------------------------
-- Events, ticker, slash command
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
f:RegisterEvent("UNIT_HEALTH")

local dirty = true
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    QuestBeaconDB = QuestBeaconDB or {}
    if QuestBeaconDB.beacon == nil then QuestBeaconDB.beacon = true end
    if QuestBeaconDB.glow == nil then QuestBeaconDB.glow = true end
    if QuestBeaconDB.arrow == nil then QuestBeaconDB.arrow = true end
    if QuestBeaconDB.mobs == nil then QuestBeaconDB.mobs = true end
    if QuestBeaconDB.sound == nil then QuestBeaconDB.sound = true end
    if QuestBeaconDB.useFocus == nil then QuestBeaconDB.useFocus = true end
    local p = QuestBeaconDB.pin
    if p and p.m then ourPin = { uiMapID = p.m, position = { x = p.x, y = p.y } } end
  elseif event == "NAME_PLATE_UNIT_ADDED" then
    UpdatePlate(arg1)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    local plate = C_NamePlate.GetNamePlateForUnit(arg1)
    if plate and glows[plate] then glows[plate]:Hide() end
  elseif event == "UNIT_HEALTH" then
    if arg1 and arg1:find("^nameplate") and UnitIsDead(arg1) then UpdatePlate(arg1) end
  else
    dirty = true -- quest log changed / zoned: rebuild on next tick
  end
end)

local elapsed = 0
local rebuildTimer = 0
f:SetScript("OnUpdate", function(_, dt)
  local okA, errA = pcall(UpdateArrow)
  if not okA and not QB.arrowErrored then QB.arrowErrored = true Print("arrow error: " .. tostring(errA)) end
  elapsed = elapsed + dt
  rebuildTimer = rebuildTimer + dt
  if elapsed < TICK then return end
  elapsed = 0
  if not QuestBeaconDB then return end
  -- Questie fills spawn lists asynchronously, so refresh mobs every 5s too
  if dirty or rebuildTimer > 5 then
    dirty, rebuildTimer = false, 0
    RebuildMobs()
    UpdateAllPlates()
  end
  local ok, err = pcall(UpdateBeacon)
  if not ok and not QB.errored then QB.errored = true Print("error: " .. tostring(err)) end
end)

SLASH_QUESTBEACON1 = "/beacon"
SLASH_QUESTBEACON2 = "/glow"
SlashCmdList.QUESTBEACON = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "beacon" then
    QuestBeaconDB.beacon = not QuestBeaconDB.beacon
    if not QuestBeaconDB.beacon then ClearBeacon() end
    Print("beacon " .. (QuestBeaconDB.beacon and "on" or "off"))
  elseif msg == "glow" then
    QuestBeaconDB.glow = not QuestBeaconDB.glow
    UpdateAllPlates()
    Print("nameplate glow " .. (QuestBeaconDB.glow and "on" or "off"))
  elseif msg == "follow" then
    QB.ToggleFollow()
  elseif msg == "focus" then
    QuestBeaconDB.useFocus = not QuestBeaconDB.useFocus
    current = nil
    Print("follow Questie tracker focus " .. (QuestBeaconDB.useFocus and "on" or "off"))
  elseif msg == "sound" then
    QuestBeaconDB.sound = not QuestBeaconDB.sound
    Print("arrival sound " .. (QuestBeaconDB.sound and "on" or "off"))
  elseif msg == "lock" then
    QuestBeaconDB.locked = not QuestBeaconDB.locked
    Print("arrow " .. (QuestBeaconDB.locked and "locked" or "unlocked"))
  elseif msg == "mobs" then
    QuestBeaconDB.mobs = not QuestBeaconDB.mobs
    current = nil
    Print("pointing at quest mobs " .. (QuestBeaconDB.mobs and "on" or "off"))
  elseif msg == "arrow" then
    QuestBeaconDB.arrow = not QuestBeaconDB.arrow
    Print("arrow " .. (QuestBeaconDB.arrow and "on" or "off"))
  elseif msg == "interact" or msg == "interact off" then
    -- Built-in soft-target interact: the game itself draws an icon over the
    -- nearest usable object (quest crates, plants, ...) in the 3D world.
    local on = msg == "interact"
    local cvars = {
      SoftTargetInteract = on and "3" or "0",        -- always pick a soft interact target
      SoftTargetIconGameObject = on and "1" or "0",  -- icon over game objects
      SoftTargetIconInteract = on and "1" or "0",    -- icon for the interact target
      SoftTargetInteractArc = on and "2" or "1",     -- any direction around you
      SoftTargetInteractRange = on and "15" or "10", -- yards
    }
    local okAll, missing = true, {}
    for k, v in pairs(cvars) do
      local get = C_CVar and C_CVar.GetCVar or GetCVar
      if get(k) == nil then
        okAll = false
        missing[#missing + 1] = k
      else
        local set = C_CVar and C_CVar.SetCVar or SetCVar
        pcall(set, k, v)
      end
    end
    if okAll then
      Print("game interact icons " .. (on and "ON: walk near a quest object and an icon appears over it. Bind 'Interact with target' in Key Bindings to loot it with one key." or "OFF"))
    else
      Print("this client is missing: " .. table.concat(missing, ", "))
    end
  elseif msg:match("^size") then
    local n = tonumber(msg:match("^size%s+([%d%.]+)"))
    if n then
      Print("arrow size " .. QB.SetArrowSize(n, true))
    else
      Print("arrow size " .. (QuestBeaconDB.arrowSize or 1) .. "  (e.g. /beacon size 1.5, range 0.4-4, or mouse wheel over the arrow)")
    end
  elseif msg == "skip" then
    QB.Skip(false)
  elseif msg == "skiptype" then
    QB.Skip(true)
  elseif msg == "reset" then
    wipe(visited) wipe(skippedSrc) current = nil
    QuestBeaconDB.arrowX, QuestBeaconDB.arrowY = nil, nil
    QB.SetArrowSize(1, true)
    if arrowFrame then arrowFrame:ClearAllPoints() arrowFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 170) end
    Print("skips cleared, arrow back to default spot")
  elseif msg == "debug" then
    QuestBeaconDB.debug = not QuestBeaconDB.debug
    local n, m = 0, 0
    ForEachSource(function(src) if IsMobSource(src) then m = m + 1 else n = n + 1 end end)
    Print(("debug %s | Questie loaded: %s | object sources: %d | mob sources: %d | target: %s"):format(
      QuestBeaconDB.debug and "on" or "off", tostring(LoadQuestie()), n, m, current and current.name or "none"))
    local wp = C_Map.HasUserWaypoint() and C_Map.GetUserWaypoint()
    Print(("map pin: %s | ours: %s | supertracking pin: %s | C_Navigation: %s | nav frame: %s | SuperTrackedFrame: %s"):format(
      wp and ("%d %.1f,%.1f"):format(wp.uiMapID, wp.position.x * 100, wp.position.y * 100) or "none",
      tostring(wp and SamePoint(wp, ourPin) or false),
      tostring(C_SuperTrack and C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint()),
      tostring(C_Navigation ~= nil),
      tostring(C_Navigation and C_Navigation.GetFrame and C_Navigation.GetFrame() ~= nil),
      tostring(_G.SuperTrackedFrame ~= nil)))
    local ang, yd = QB.ArrowAngle(current)
    Print(("arrow: setting %s | frame %s | shown %s | angle %s | yards %s | map size %s"):format(
      tostring(QuestBeaconDB.arrow), tostring(arrowFrame ~= nil), tostring(arrowFrame and arrowFrame:IsShown()),
      tostring(ang), tostring(yd), current and tostring(C_Map.GetMapWorldSize(current.uiMapID)) or "-"))
    local me = PlayerWorld()
    Print("player map: " .. tostring(C_Map.GetBestMapForUnit("player")) .. " | world pos: " .. (me and ("%d %.0f,%.0f"):format(me[1], me[2], me[3]) or "none"))
  else
    local on = QuestBeaconDB.beacon or QuestBeaconDB.glow
    QuestBeaconDB.beacon, QuestBeaconDB.glow = not on, not on
    if on then ClearBeacon() end
    UpdateAllPlates()
    Print((on and "off" or "on") .. "  (/beacon follow | focus | lock | sound | beacon | arrow | mobs | glow | interact | size N | skip | skiptype | reset | debug; drag the arrow to move it, wheel to resize, right-click to skip, middle-click to follow a quest)")
  end
end
