-- CollectionLog_MinimapButton.lua
-- Hybrid minimap button:
--   - Preferred: LibDBIcon (same orbit as other addon icons)
--   - Fallback: manual Blizzard-style button (guaranteed even if libs don't load)
-- Why: Some environments report LibStub as a *table* (common modern LibStub), so naive type checks fail.
-- This file handles BOTH LibStub styles and keeps behavior stable.
-- Settings toggle controls CollectionLogDB.minimapButton.hide.

local ADDON, ns = ...
local LDB_NAME  = "CollectionLog"
local ICON_PATH = "Interface\\AddOns\\CollectionLog\\Media\\MinimapIcon.tga"

local DEFAULTS = { hide = false, minimapPos = 220 }
local BTN_NAME = "CollectionLogMinimapButton"
local BTN_SIZE = 31

local BORDER_TEX    = "Interface\\Minimap\\MiniMap-TrackingBorder"
local BG_TEX        = "Interface\\Minimap\\UI-Minimap-Background"
local HIGHLIGHT_TEX = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

local function EnsureDB()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.minimapButton = CollectionLogDB.minimapButton or {}
  local db = CollectionLogDB.minimapButton
  if db.hide == nil then db.hide = DEFAULTS.hide end
  if db.minimapPos == nil then db.minimapPos = DEFAULTS.minimapPos end
  if db.minimapPos == nil and db.angle ~= nil then db.minimapPos = db.angle end
  db.angle = db.minimapPos
end

local function ToggleMain()
  if ns and ns.UI and type(ns.UI.Toggle) == "function" then
    ns.UI.Toggle()
    return
  end
  if SlashCmdList and SlashCmdList["COLLECTIONLOG"] then
    SlashCmdList["COLLECTIONLOG"]("")
  end
end

-- ---------- LibStub helpers (works whether LibStub is a function or a table) ----------
local function GetLibStub()
  local LS = _G.LibStub
  if type(LS) == "function" then
    return LS, "function"
  elseif type(LS) == "table" then
    return LS, "table"
  end
  return nil, "none"
end

local function LibFetch(LS, name, silent)
  if not LS then return nil end
  -- Prefer :GetLibrary when available (works for table LibStub)
  if type(LS) == "table" and type(LS.GetLibrary) == "function" then
    local ok, lib = pcall(LS.GetLibrary, LS, name, silent)
    if ok and lib then return lib end
  end
  -- Otherwise, try calling it (works for function LibStub and table with __call metamethod)
  local ok, lib = pcall(function()
    return LS(name, silent)
  end)
  if ok and lib then return lib end
  return nil
end

local function GetLDBLibs()
  local LS, kind = GetLibStub()
  if not LS then return nil end
  local LDB   = LibFetch(LS, "LibDataBroker-1.1", true)
  local DBIcon= LibFetch(LS, "LibDBIcon-1.0", true)
  if not (LDB and DBIcon) then return nil end
  return { LS = LS, kind = kind, LDB = LDB, DBIcon = DBIcon }
end

-- ---------- LibDBIcon path (preferred) ----------
local function EnsureLDBObject(LDB)
  if ns._clLDBObject then return ns._clLDBObject end
  local obj = LDB:NewDataObject(LDB_NAME, { type = "launcher", icon = ICON_PATH })
  obj.OnClick = function(_, button)
    if button == "LeftButton" then ToggleMain() end
  end
  obj.OnTooltipShow = function(tt)
    tt:AddLine("Collection Log")
    tt:AddLine("Left-click: Open", 1, 1, 1)
    tt:SetScale(GameTooltip:GetScale())
  end
  ns._clLDBObject = obj
  return obj
end

local function ApplyDBIcon(env)
  local DBIcon = env.DBIcon
  if CollectionLogDB.minimapButton.hide then
    if DBIcon.Hide then DBIcon:Hide(LDB_NAME) end
  else
    if DBIcon.Show then DBIcon:Show(LDB_NAME) end
  end
  if DBIcon.Refresh then
    DBIcon:Refresh(LDB_NAME, CollectionLogDB.minimapButton)
  end
end

local function EnsureDBIcon(env)
  local DBIcon = env.DBIcon
  local LDB = env.LDB
  EnsureLDBObject(LDB)

  if not ns._clDBIconRegistered then
    pcall(function()
      DBIcon:Register(LDB_NAME, ns._clLDBObject, CollectionLogDB.minimapButton)
    end)
    ns._clDBIconRegistered = true
  end

  ApplyDBIcon(env)

  -- If LibDBIcon created a frame, we can hide the manual fallback
  local btn = _G["LibDBIcon10_" .. LDB_NAME]
  if btn and btn.IsShown then
    local manual = _G[BTN_NAME]
    if manual and manual.Hide then manual:Hide() end
  end
end

-- ---------- Manual fallback (guaranteed) ----------
local function GetMinimapRadius()
  local mmw = (Minimap and Minimap.GetWidth) and Minimap:GetWidth() or 140
  local mmr = (mmw / 2)
  return mmr + (BTN_SIZE / 2) - 2
end

local function UpdateManualPosition(btn)
  local deg = tonumber(CollectionLogDB.minimapButton.minimapPos) or DEFAULTS.minimapPos
  local a = math.rad(deg)
  local r = GetMinimapRadius()
  local x, y = math.cos(a) * r, math.sin(a) * r
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function EnsureManualButton()
  if _G[BTN_NAME] then return _G[BTN_NAME] end

  local btn = CreateFrame("Button", BTN_NAME, Minimap)
  btn:SetSize(BTN_SIZE, BTN_SIZE)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetClampedToScreen(true)
  btn:RegisterForClicks("AnyUp")
  btn:RegisterForDrag("LeftButton")

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture(BORDER_TEX)
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(BG_TEX)
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5)

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ICON_PATH)
  icon:SetTexCoord(0, 1, 0, 1)
  icon:SetSize(18, 18)
  icon:ClearAllPoints()
  icon:SetPoint("CENTER", btn, "CENTER", 1, -1)

  btn:SetHighlightTexture(HIGHLIGHT_TEX, "ADD")

  btn:SetScript("OnClick", function(_, button)
    if button == "LeftButton" then ToggleMain() end
  end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Collection Log")
    GameTooltip:AddLine("Left-click: Open", 1, 1, 1)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  btn:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      local deg = math.deg(math.atan2(cy - my, cx - mx))
      if deg < 0 then deg = deg + 360 end
      CollectionLogDB.minimapButton.minimapPos = deg
      CollectionLogDB.minimapButton.angle = deg
      UpdateManualPosition(self)
    end)
  end)

  btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)

  UpdateManualPosition(btn)
  return btn
end

local function ApplyManual()
  local btn = EnsureManualButton()
  if CollectionLogDB.minimapButton.hide then
    btn:Hide()
  else
    btn:Show()
    UpdateManualPosition(btn)
  end
end

-- ---------- Unified apply ----------
local function ApplyAll()
  EnsureDB()
  local env = GetLDBLibs()
  if env then
    EnsureDBIcon(env)
  else
    ApplyManual()
  end
end

-- Public API used by settings
function ns.MinimapButton_Init()
  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("minimap_apply_init", ApplyAll)
  else
    ApplyAll()
  end
end

function ns.MinimapButton_Show()
  EnsureDB()
  CollectionLogDB.minimapButton.hide = false
  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("minimap_apply_show", ApplyAll)
  else
    ApplyAll()
  end
end

function ns.MinimapButton_Hide()
  EnsureDB()
  CollectionLogDB.minimapButton.hide = true
  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("minimap_apply_hide", ApplyAll)
  else
    ApplyAll()
  end
end

function ns.MinimapButton_Toggle()
  EnsureDB()
  CollectionLogDB.minimapButton.hide = not CollectionLogDB.minimapButton.hide
  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("minimap_apply_toggle", ApplyAll)
  else
    ApplyAll()
  end
end

function ns.MinimapButton_Reset()
  EnsureDB()
  CollectionLogDB.minimapButton.hide = DEFAULTS.hide
  CollectionLogDB.minimapButton.minimapPos = DEFAULTS.minimapPos
  CollectionLogDB.minimapButton.angle = DEFAULTS.minimapPos
  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("minimap_apply_reset", ApplyAll)
  else
    ApplyAll()
  end
end


-- Debug: show what libs were detected and whether the LibDBIcon frame exists
SLASH_COLLECTIONLOGMM1 = "/clogmm"
SlashCmdList["COLLECTIONLOGMM"] = function()
  EnsureDB()
  local LS, kind = GetLibStub()
  local env = GetLDBLibs()
  local ldbYes = env and "yes" or "no"
  local dbiYes = env and "yes" or "no"
  local libstubYes = (LS and "yes" or "no")
  local frame = _G["LibDBIcon10_" .. LDB_NAME]
  local manual = _G[BTN_NAME]
  print("|cFFf4d03fCollection Log Minimap|r",
    "LibStub:", libstubYes .. "(" .. kind .. ")",
    "LDB:", ldbYes,
    "DBIcon:", dbiYes,
    "LibDBIconFrame:", frame and "yes" or "no",
    "ManualFrame:", manual and "yes" or "no",
    "Hide:", CollectionLogDB.minimapButton.hide and "true" or "false")
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() ApplyAll() end)