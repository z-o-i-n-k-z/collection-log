-- LibDBIcon-1.0 (minimal)
-- Implements Register/Show/Hide/Refresh for minimap launcher objects.
-- This is a compatibility-focused implementation sufficient for minimap button collectors.

local LibStub = _G.LibStub
if not LibStub then return end

-- NOTE: Bundled *minimal fallback* copy. MINOR is intentionally low so upstream libs win.
local MAJOR, MINOR = "LibDBIcon-1.0", 0
local DBIcon = LibStub:NewLibrary(MAJOR, MINOR)
if not DBIcon then return end

local LDB = LibStub("LibDataBroker-1.1", true)
if not LDB then return end

DBIcon.objects = DBIcon.objects or {}
DBIcon.db = DBIcon.db or {}

local HIGHLIGHT_TEX = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

local function clamp(v, min, max)
  if v < min then return min end
  if v > max then return max end
  return v
end

local function getMinimapRadius()
  if not Minimap or not Minimap.GetWidth then return 70 end
  return (Minimap:GetWidth() or 140) / 2
end

local function positionButton(button, db)
  if not button or not db then return end
  local pos = db.minimapPos or 220
  local angle = math.rad(pos)

  local r = getMinimapRadius() + (button:GetWidth() / 2) - 2
  local x = math.cos(angle) * r
  local y = math.sin(angle) * r

  -- Basic clamp to avoid drifting off-screen for weird minimaps
  local c = getMinimapRadius()
  x = clamp(x, -c - 40, c + 40)
  y = clamp(y, -c - 40, c + 40)

  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function createButton(name, obj)
  local buttonName = "LibDBIcon10_" .. name
  if _G[buttonName] then
    return _G[buttonName]
  end

  local b = CreateFrame("Button", buttonName, Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 10)
  b:SetToplevel(true)
  b:SetClampedToScreen(true)

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(obj.icon)
  icon:SetSize(23, 23)
  icon:SetPoint("CENTER", b, "CENTER", -1, 0)
  b.icon = icon

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  b.border = border

  b:SetHighlightTexture(HIGHLIGHT_TEX, "ADD")
  local hl = b:GetHighlightTexture()
  if hl then
    hl:ClearAllPoints()
    hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    hl:SetSize(31, 31)
  end

  b:RegisterForClicks("AnyUp")
  b:RegisterForDrag("LeftButton")

  b:SetScript("OnClick", function(_, button)
    if obj.OnClick then
      obj:OnClick(button)
    end
  end)

  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    if obj.OnTooltipShow then
      obj.OnTooltipShow(GameTooltip)
    else
      GameTooltip:AddLine(name)
    end
    GameTooltip:Show()
  end)

  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      cx, cy = cx / scale, cy / scale
      local ang = math.deg(math.atan2(cy - my, cx - mx))
      -- Convert so that 0 is east, increasing counter-clockwise, normalized 0..360
      if ang < 0 then ang = ang + 360 end
      DBIcon.db[name].minimapPos = ang
      positionButton(self, DBIcon.db[name])
    end)
  end)

  b:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)

  return b
end

function DBIcon:Register(name, obj, db)
  assert(type(name) == "string", "Register: name must be a string")
  assert(type(obj) == "table", "Register: obj must be a table")
  assert(type(db) == "table", "Register: db must be a table")

  DBIcon.objects[name] = obj
  DBIcon.db[name] = db

  local b = createButton(name, obj)
  b.obj = obj

  if db.hide then
    b:Hide()
  else
    b:Show()
  end

  positionButton(b, db)
end

function DBIcon:Refresh(name, db)
  if db then
    DBIcon.db[name] = db
  end
  local b = _G["LibDBIcon10_" .. name]
  if not b then return end
  local cfg = DBIcon.db[name]
  if cfg and cfg.hide then b:Hide() else b:Show() end
  if cfg then positionButton(b, cfg) end
end

function DBIcon:Show(name)
  local db = DBIcon.db[name]
  if db then db.hide = false end
  local b = _G["LibDBIcon10_" .. name]
  if b then b:Show() end
end

function DBIcon:Hide(name)
  local db = DBIcon.db[name]
  if db then db.hide = true end
  local b = _G["LibDBIcon10_" .. name]
  if b then b:Hide() end
end

function DBIcon:IsRegistered(name)
  return DBIcon.objects[name] ~= nil
end
