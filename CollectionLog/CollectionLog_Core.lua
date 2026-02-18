-- CollectionLog_Core.lua
local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = "v1.1.0-opt1"

-- ============================================================
-- Utilities
-- ============================================================
local function DeepCopy(src)
  if type(src) ~= "table" then return src end
  local t = {}
  for k, v in pairs(src) do
    t[k] = DeepCopy(v)
  end
  return t
end

local function MergeDefaults(dst, defaults)
  for k, v in pairs(defaults) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      MergeDefaults(dst[k], v)
    else
      if dst[k] == nil then dst[k] = v end
    end
  end
end

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(("|cff00ff99Collection Log|r: %s"):format(tostring(msg)))
end
ns.Print = Print

-- Debug print (toggle via CollectionLogDB.debug = true)
function ns.Debug(msg)
  if _G.CollectionLogDB and _G.CollectionLogDB.debug then
    Print(msg)
  end
end





-- ============================================================
-- Combat-safe UI gating (taint hardening)
-- ============================================================
ns._combatQueue = ns._combatQueue or {}
ns._combatGateFrame = ns._combatGateFrame or CreateFrame("Frame")

local function _IsCombat()
  return (InCombatLockdown and InCombatLockdown()) or false
end
ns.IsInCombat = _IsCombat

-- Run UI mutations out of combat. If in combat, queue and run once when combat ends.
function ns.RunOutOfCombat(key, fn)
  if type(fn) ~= "function" then return end
  if not key or key == "" then key = tostring(fn) end

  if not _IsCombat() then
    local ok, err = pcall(fn)
    if not ok and err then
      ns.Debug(("RunOutOfCombat(%s) error: %s"):format(tostring(key), tostring(err)))
    end
    return
  end

  ns._combatQueue[key] = fn
  local f = ns._combatGateFrame
  if not f._clogRegenHooked then
    f._clogRegenHooked = true
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:SetScript("OnEvent", function()
      f:UnregisterEvent("PLAYER_REGEN_ENABLED")
      f._clogRegenHooked = false
      local q = ns._combatQueue or {}
      ns._combatQueue = {}
      for k, cb in pairs(q) do
        if type(cb) == "function" then
          local ok2, err2 = pcall(cb)
          if not ok2 and err2 then
            ns.Debug(("Deferred(%s) error: %s"):format(tostring(k), tostring(err2)))
          end
        end
      end
    end)
  end
end

-- ============================================================
-- Perf profiling (on-demand)
-- Requires: /console scriptProfile 1 (then /reload)
-- ============================================================
ns.Perf = ns.Perf or {}
ns.Perf._registered = ns.Perf._registered or {}  -- name -> function

local function Perf_HasScriptProfile()
  if type(GetCVar) ~= "function" then return false end
  local v = GetCVar("scriptProfile")
  return v == "1" or v == 1 or v == true
end

function ns.Perf.Register(name, fn)
  if type(name) ~= "string" or name == "" then return false end
  if type(fn) ~= "function" then return false end
  ns.Perf._registered[name] = fn
  return true
end

function ns.Perf.Unregister(name)
  ns.Perf._registered[name] = nil
end

function ns.Perf.Reset()
  if type(ResetCPUUsage) == "function" then
    ResetCPUUsage()
  end
  Print("Perf: CPU counters reset.")
end

function ns.Perf.EnsureDefaults()
  -- Register common hotspots if they exist (safe no-ops if not loaded yet)
  local UI = ns.UI
  if type(UI) == "table" then
    local uiFns = {
      "RefreshAll",
      "RefreshGrid",
      "RefreshHeaderCountsOnly",
      "RefreshVisibleCollectedStateOnly",
      "TriggerCollectedRefresh",
      "ScheduleEncounterAutoRefresh",
      "RefreshOverview",
      "RebuildOverviewCacheAsync",
      "RequestOverviewRebuild",
      "Init",
      "Toggle",
    }
    for _, k in ipairs(uiFns) do
      if type(UI[k]) == "function" then
        ns.Perf.Register("UI." .. k, UI[k])
      end
    end
  end

  local Track = ns.Track
  if type(Track) == "table" then
    local trackFns = {
      "HandleLoot",
      "HandleChatLoot",
      "HandleEncounterLoot",
      "ScanAllCollections",
    }
    for _, k in ipairs(trackFns) do
      if type(Track[k]) == "function" then
        ns.Perf.Register("Track." .. k, Track[k])
      end
    end
  end
end

local function Perf_PrintTop(n, includeSubs)
  n = tonumber(n) or 15
  if n < 1 then n = 1 end
  if n > 50 then n = 50 end

  if not Perf_HasScriptProfile() then
    Print("Perf: script profiling is OFF. Run: /console scriptProfile 1  then /reload")
    Print("Perf: After reproducing lag, run: /clog perf")
    return
  end

  ns.Perf.EnsureDefaults()

  if type(UpdateAddOnCPUUsage) == "function" then
    UpdateAddOnCPUUsage()
  end
  if type(UpdateAddOnMemoryUsage) == "function" then
    UpdateAddOnMemoryUsage()
  end

  local addonCPU = (type(GetAddOnCPUUsage) == "function") and GetAddOnCPUUsage(ADDON) or nil
  local addonMem = (type(GetAddOnMemoryUsage) == "function") and GetAddOnMemoryUsage(ADDON) or nil

  Print(("Perf: %s  CPU=%.2fms  Mem=%.1f KB  (tracked funcs=%d, includeSubs=%s)")
    :format(tostring(ADDON), tonumber(addonCPU or 0), tonumber(addonMem or 0), (function()
      local c=0; for _ in pairs(ns.Perf._registered) do c=c+1 end; return c
    end)(), tostring(includeSubs ~= false)))

  local rows = {}
  for name, fn in pairs(ns.Perf._registered) do
    local ms = 0
    if type(GetFunctionCPUUsage) == "function" then
      ms = GetFunctionCPUUsage(fn, includeSubs ~= false) or 0
    end
    rows[#rows+1] = { name = name, ms = tonumber(ms) or 0 }
  end
  table.sort(rows, function(a,b) return a.ms > b.ms end)

  local shown = 0
  for i=1, #rows do
    if rows[i].ms > 0 then
      shown = shown + 1
      Print(("[%02d] %.2fms  %s"):format(shown, rows[i].ms, rows[i].name))
      if shown >= n then break end
    end
  end
  if shown == 0 then
    Print("Perf: No tracked functions have non-zero CPU yet. Reproduce the lag, then run /clog perf again.")
  end
end

ns.Perf.PrintTop = Perf_PrintTop

-- ============================================================
-- Data Packs (optional static datasets)
-- ============================================================
-- Data packs are shipped as Lua files (generated offline) and loaded via TOC order.
-- The addon must remain fully functional without them.

ns.DataPacks = ns.DataPacks or {}

function ns.GetDataPack(name)
  if type(ns.DataPacks) ~= "table" then return nil end
  return ns.DataPacks[name]
end

function ns.HasDataPack(name)
  local p = ns.GetDataPack(name)
  return type(p) == "table" and type(p.meta) == "table"
end

function ns.PackMetaString(pack)
  if type(pack) ~= "table" or type(pack.meta) ~= "table" then return "" end
  local m = pack.meta
  local build = (m.build and m.build ~= "") and (" build=" .. tostring(m.build)) or ""
  local ver = (m.version and m.version ~= "") and (" v=" .. tostring(m.version)) or ""
  return tostring(m.pack or "?") .. ver .. build
end

-- Helpers used by importers/UI (kept tiny).
function ns.GetMountTagsPack()
  local p = ns.GetDataPack("MountTags")
  if type(p) ~= "table" or type(p.mountTags) ~= "table" then return nil end
  return p
end

function ns.GetAppearanceVariantsPack()
  local p = ns.GetDataPack("AppearanceVariants")
  if type(p) ~= "table" or type(p.map) ~= "table" then return nil end
  return p
end


function ns.GetMountDropCategoriesPack()
  local p = ns.GetDataPack("MountDropCategories")
  if type(p) ~= "table" or type(p.map) ~= "table" then return nil end
  return p
end



-- ============================================================
-- Optional Source Overrides pack loader (from separate datapack addon)
-- If an external addon defines a global table `MountSourceOverrides`,
-- import it into ns.DataPacks["MountSourceOverrides"].map so the rest
-- of the addon can consume it via ns.GetMountSourceOverridesPack().
-- ============================================================
function ns.LoadMountSourceOverridesFromGlobal()
  -- External datapack addon should define a global table:
  --   MountSourceOverrides = { [mountID] = "store"|"achievement"|..., ... }
  local t = _G.MountSourceOverrides
  if type(t) ~= "table" then
    return false
  end

  ns.DataPacks = ns.DataPacks or {}

  local pack = ns.DataPacks["MountSourceOverrides"]
  if type(pack) ~= "table" then
    pack = {}
    ns.DataPacks["MountSourceOverrides"] = pack
  end

  pack.map = t
  pack.meta = pack.meta or {}
  pack.meta.pack = pack.meta.pack or "MountSourceOverrides"
  pack.meta.version = pack.meta.version or "external"
  pack.meta.build = pack.meta.build or "external"
  pack.meta.source = pack.meta.source or "global"

  return true
end


local function SafeCall(fn, ...)
  if type(fn) ~= "function" then return false end
  local ok, err = pcall(fn, ...)
  if not ok then
    Print(("Error: %s"):format(tostring(err)))
  end
  return ok
end


-- ============================================================
-- Optional Drop Categories pack loader (from separate datapack addon)
-- If an external addon defines a global table `MountDropCategories`,
-- import it into ns.DataPacks["MountDropCategories"].map so the rest
-- of the addon can consume it via ns.GetMountDropCategoriesPack().
-- ============================================================
function ns.LoadMountDropCategoriesFromGlobal()
  -- External datapack addon should define a global table:
  --   MountDropCategories = { [mountID] = { cat=..., instanceID=..., encounterID=... }, ... }
  local t = _G.MountDropCategories
  if type(t) ~= "table" then
    return false
  end

  ns.DataPacks = ns.DataPacks or {}

  -- Preserve any existing pack object but ensure required fields exist
  local pack = ns.DataPacks["MountDropCategories"]
  if type(pack) ~= "table" then
    pack = {}
    ns.DataPacks["MountDropCategories"] = pack
  end

  pack.map = t
  pack.meta = pack.meta or {}
  -- PackMetaString expects meta.pack / meta.version / meta.build
  pack.meta.pack = pack.meta.pack or "MountDropCategories"
  pack.meta.version = pack.meta.version or "external"
  pack.meta.build = pack.meta.build or "external"
  pack.meta.source = pack.meta.source or "global"

  return true
end
-- ============================================================
-- External Source Override Datapack (MountSourceOverrides)
-- ============================================================
function ns.GetMountSourceOverridesPack()
  local p = ns.GetDataPack and ns.GetDataPack("MountSourceOverrides")
  if type(p) ~= "table" or type(p.map) ~= "table" then return nil end
  return p
end

function ns.LoadMountSourceOverridesFromGlobal()
  local t = _G.MountSourceOverrides
  if type(t) ~= "table" then
    return false
  end

  ns.DataPacks = ns.DataPacks or {}

  local pack = ns.DataPacks["MountSourceOverrides"]
  if type(pack) ~= "table" then
    pack = {}
    ns.DataPacks["MountSourceOverrides"] = pack
  end

  pack.map = t
  pack.meta = pack.meta or {}
  pack.meta.pack = pack.meta.pack or "MountSourceOverrides"
  pack.meta.version = pack.meta.version or "external"
  pack.meta.build = pack.meta.build or "external"
  pack.meta.source = pack.meta.source or "global"

  return true
end



-- ============================================================
-- Item section helpers (UI grouping)
-- ============================================================
-- UI uses these to group the item grid into readable sections.
ns.SECTION_ORDER = { "Mounts", "Pets", "Weapons", "Armor", "Trinkets", "Jewelry", "Toys", "Housing", "Misc" }

-- Housing decor helpers (Midnight)
-- Housing items should behave like collectables: never hidden by the non-collectables filter,
-- and displayed under their own section in raid/dungeon loot tables.
local _fastHousingCache = {}

function ns.IsHousingItemID(itemID)
  if not itemID or itemID <= 0 then return false end
  local cached = _fastHousingCache[itemID]
  if cached ~= nil then return cached end

  -- Explicit override list (datapack can populate this if needed).
  if ns.HousingItemIDs and ns.HousingItemIDs[itemID] then
    _fastHousingCache[itemID] = true
    return true
  end

  -- Authoritative API (preferred): housing catalog lookup by item.
  if C_HousingCatalog and C_HousingCatalog.GetCatalogEntryInfoByItem then
    local ok, info = pcall(C_HousingCatalog.GetCatalogEntryInfoByItem, itemID, true)
    if ok and info then
      _fastHousingCache[itemID] = true
      return true
    end
  end

  _fastHousingCache[itemID] = false
  return false
end


function ns.GetItemSection(itemID)
  if not itemID or itemID <= 0 then
    return "Misc"
  end

  -- If the robust mount collection check has already mapped this item, trust that.
  -- (This covers weird mount items that don't expose a stable spell mapping.)
  if ns._itemToMountID and ns._itemToMountID[itemID] then
    return "Mounts"
  end

  -- Housing decor items (authoritative catalog lookup).
  if ns.IsHousingItemID and ns.IsHousingItemID(itemID) then
    return "Housing"
  end

  -- Fast checks for mounts and toys.
  -- NOTE: We keep this lightweight (no full journal scans) because it's called during UI layout.
  -- We intentionally do NOT force-load Blizzard_Collections here.

  if C_MountJournal then
    if C_MountJournal.GetMountIDFromItemID then
      local ok, mid = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
      if ok and mid and mid ~= 0 then
        return "Mounts"
      end
    end

    if C_MountJournal.GetMountFromItemID then
      local ok, a, b = pcall(C_MountJournal.GetMountFromItemID, itemID)
      if ok then
        local mid = (a and a ~= 0 and a) or (b and b ~= 0 and b) or nil
        if mid then
          return "Mounts"
        end
      end
    end

    if GetItemSpell and C_MountJournal.GetMountFromSpell then
      local _, spellID = GetItemSpell(itemID)
      if spellID then
        local ok, mid = pcall(C_MountJournal.GetMountFromSpell, spellID)
        if ok and mid and mid ~= 0 then
          return "Mounts"
        end
      end
    end
  end

  if C_ToyBox and C_ToyBox.GetToyFromItemID then
    local ok, toyID = pcall(C_ToyBox.GetToyFromItemID, itemID)
    if ok and toyID and toyID ~= 0 then
      return "Toys"
    end
  end

  -- Toys (tooltip-declared)
  -- Some toys (and "adds to your Toy Box" items) may not resolve via ToyBox until Blizzard_Collections is loaded.
  -- The item tooltip reliably marks these as Toy.
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local tip = C_TooltipInfo.GetItemByID(itemID)
    if tip and tip.lines then
      for _, line in ipairs(tip.lines) do
        local txt = line.leftText
        if txt and ((ITEM_TOY and txt == ITEM_TOY) or (TOY and txt == TOY) or txt == "Toy") then
          return "Toys"
        end
      end
    end
  end

  -- Some mount items do not expose a stable spell mapping and may not resolve via mount journal helpers.
  -- However, they are still classified by item class/subclass (Miscellaneous: Mount).
  -- Using numeric IDs avoids locale/string issues.
  if GetItemInfo then
    local _, _, _, _, _, _, _, _, _, _, _, classID, subClassID = GetItemInfo(itemID)
    if classID == 15 and subClassID == 5 then
      return "Mounts"
    end
  end

  -- Pets (battle pet items / companion pet items)
if GetItemInfoInstant then
  local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(itemID)
  if classID == 17 or (classID == 15 and subClassID == 2) then
    return "Pets"
  end
end

-- Fallback to item class.
  if GetItemInfoInstant then
    local _, _, _, equipLoc, _, classID = GetItemInfoInstant(itemID)

    -- Breakouts
    if equipLoc == "INVTYPE_TRINKET" then
      return "Trinkets"
    end
    if equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_NECK" then
      return "Jewelry"
    end

    if classID == 2 then
      return "Weapons"
    end
    if classID == 4 then
      return "Armor"
    end

    -- Some edge-case weapons/armor report class differently but still have equip locations.
    if equipLoc and equipLoc ~= "" then
      if equipLoc == "INVTYPE_TRINKET" then
        return "Trinkets"
      end
      if equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_NECK" then
        return "Jewelry"
      end
      if equipLoc:find("WEAPON", 1, true) or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" then
        return "Weapons"
      end
      if equipLoc:find("HEAD", 1, true) or equipLoc:find("SHOULDER", 1, true) or equipLoc:find("CHEST", 1, true)
        or equipLoc:find("ROBE", 1, true) or equipLoc:find("WRIST", 1, true) or equipLoc:find("HAND", 1, true)
        or equipLoc:find("WAIST", 1, true) or equipLoc:find("LEGS", 1, true) or equipLoc:find("FEET", 1, true)
        or equipLoc:find("CLOAK", 1, true) or equipLoc:find("SHIELD", 1, true) or equipLoc:find("HOLDABLE", 1, true) then
        return "Armor"
      end
    end
  end

  return "Misc"
end

-- ============================================================
-- Fast, deterministic item section classifier
-- ============================================================
--
-- Used for large loot grids (raids/dungeons) where we want a stable
-- layout on the FIRST click (no "second click" re-layout once item
-- info finishes streaming in).
--
-- Design goals:
--   * No GetItemInfo() (async) dependency
--   * No tooltip scans
--   * Cache results per itemID
--
local _fastSectionCache = {}

function ns.ClearFastItemSectionCache()
  if wipe then
    wipe(_fastSectionCache)
  else
    for k in pairs(_fastSectionCache) do _fastSectionCache[k] = nil end
  end
end

function ns.GetItemSectionFast(itemID)
  if not itemID or itemID <= 0 then
    return "Misc"
  end

  local cached = _fastSectionCache[itemID]
  if cached then
    return cached
  end

  -- Housing decor items (authoritative catalog lookup).
  if ns.IsHousingItemID and ns.IsHousingItemID(itemID) then
    _fastSectionCache[itemID] = "Housing"
    return "Housing"
  end


  -- Mount items: prefer direct item→mount APIs when available.
  if C_MountJournal then
    if C_MountJournal.GetMountFromItem then
      local ok, mountID = pcall(C_MountJournal.GetMountFromItem, itemID)
      if ok and mountID and mountID ~= 0 then
        _fastSectionCache[itemID] = "Mounts"
        return "Mounts"
      end
    end
    if C_MountJournal.GetMountFromItemID then
      local ok, a, b = pcall(C_MountJournal.GetMountFromItemID, itemID)
      if ok then
        local mountID = (a and a ~= 0 and a) or (b and b ~= 0 and b) or nil
        if mountID then
          _fastSectionCache[itemID] = "Mounts"
          return "Mounts"
        end
      end
    end
    if C_MountJournal.GetMountIDFromItemID then
      local ok, mountID = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
      if ok and mountID and mountID ~= 0 then
        _fastSectionCache[itemID] = "Mounts"
        return "Mounts"
      end
    end
  end

  -- Pet items: deterministic item→species mapping.
  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local ok, speciesID = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
    if ok and speciesID and speciesID ~= 0 then
      _fastSectionCache[itemID] = "Pets"
      return "Pets"
    end
  end

  -- Toy items: deterministic item→toy mapping.
  if C_ToyBox then
    if C_ToyBox.GetToyFromItemID then
      local ok, toyID = pcall(C_ToyBox.GetToyFromItemID, itemID)
      if ok and toyID and toyID ~= 0 then
        _fastSectionCache[itemID] = "Toys"
        return "Toys"
      end
    elseif C_ToyBox.GetToyInfo then
      local ok, toyName = pcall(C_ToyBox.GetToyInfo, itemID)
      if ok and toyName then
        _fastSectionCache[itemID] = "Toys"
        return "Toys"
      end
    end
  end

  -- Classify by instant item data only.
  if GetItemInfoInstant then
    local _, _, _, equipLoc, _, classID, subClassID = GetItemInfoInstant(itemID)

    -- Miscellaneous: Mount
    if classID == 15 and subClassID == 5 then
      _fastSectionCache[itemID] = "Mounts"
      return "Mounts"
    end

    -- Pets
    if classID == 17 or (classID == 15 and subClassID == 2) then
      _fastSectionCache[itemID] = "Pets"
      return "Pets"
    end

    -- Breakouts
    if equipLoc == "INVTYPE_TRINKET" then
      _fastSectionCache[itemID] = "Trinkets"
      return "Trinkets"
    end
    if equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_NECK" then
      _fastSectionCache[itemID] = "Jewelry"
      return "Jewelry"
    end

    if classID == 2 then
      _fastSectionCache[itemID] = "Weapons"
      return "Weapons"
    end
    if classID == 4 then
      _fastSectionCache[itemID] = "Armor"
      return "Armor"
    end

    if equipLoc and equipLoc ~= "" then
      if equipLoc:find("WEAPON", 1, true) or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" then
        _fastSectionCache[itemID] = "Weapons"
        return "Weapons"
      end
      if equipLoc:find("HEAD", 1, true) or equipLoc:find("SHOULDER", 1, true) or equipLoc:find("CHEST", 1, true)
        or equipLoc:find("ROBE", 1, true) or equipLoc:find("WRIST", 1, true) or equipLoc:find("HAND", 1, true)
        or equipLoc:find("WAIST", 1, true) or equipLoc:find("LEGS", 1, true) or equipLoc:find("FEET", 1, true)
        or equipLoc:find("CLOAK", 1, true) or equipLoc:find("SHIELD", 1, true) or equipLoc:find("HOLDABLE", 1, true) then
        _fastSectionCache[itemID] = "Armor"
        return "Armor"
      end
    end
  end

  _fastSectionCache[itemID] = "Misc"
  return "Misc"
end

-- ============================================================
-- SavedVariables defaults
-- ============================================================
local DEFAULT_DB = {
  version = 1,

  -- User-facing settings (keep minimal; defaults reflect intended UX)
  settings = {
    -- Loot notification popup (OSRS-style)
    showLootPopup = true,
  },

  ui = {
    point = "CENTER",
    x = 0,
    y = 0,
    w = 880,
    h = 560,
    scale = 1.0,

    activeCategory = "Raids",
    activeGroupId = nil,

    -- "ACCOUNT" | "CHARACTER"
    viewMode = "ACCOUNT",
    activeCharacterGUID = nil,

    search = "",

    -- Remember last-used difficulty per instance for the Difficulty dropdown UX
    -- Key: instanceID (number) -> difficultyID (number)
    lastDifficultyByInstance = {},

    -- Encounter panel expansion filter
    -- "ALL" | expansionName
    expansionFilter = "ALL",

    -- optional filters
    missingOnly = false,
    collectedOnly = false,

    -- Auto-scan vendors on MERCHANT_SHOW (only saves if vendor sells collectibles)
    autoScanVendors = false,
    autoScanVendorsNotify = false,
  },

  characters = {
    -- [guid] = { name, realm, class, items = { [itemID] = {count, firstTime, lastTime} }, runs = {} }
  },

  itemOwners = {
    -- [itemID] = { [guid] = true, ... }
  },

  generatedPack = {
    version = 1,
    groups = {},
  },
}

-- ============================================================
-- Data pack registry
-- ============================================================
ns.Data = ns.Data or {}
ns.Data.packs = ns.Data.packs or {}
ns.Data.groups = ns.Data.groups or {}
ns.Data.groupsByCategory = ns.Data.groupsByCategory or {}

function ns.RegisterPack(packId, packTable)
  ns.Data.packs[packId] = packTable
end

function ns.RebuildGroupIndex()
  wipe(ns.Data.groups)
  wipe(ns.Data.groupsByCategory)

  -- Deterministic pack order matters when group IDs collide.
  -- We want generated packs (EJ scans, vendor scans, etc.) to override shipped data packs.
  local packIds = {}
  for packId in pairs(ns.Data.packs) do
    table.insert(packIds, packId)
  end

  local function packPriority(id)
    if type(id) ~= "string" then return 50 end
    -- base data packs first
    if id:find("^data_") then return 10 end
    -- legacy data
    if id:find("^data_legacy") then return 15 end
    -- generated packs last (override)
    if id == "generated" then return 90 end
    if id:find("^generated_") then return 85 end
    return 50
  end

  table.sort(packIds, function(a, b)
    local pa, pb = packPriority(a), packPriority(b)
    if pa == pb then
      return tostring(a) < tostring(b)
    end
    return pa < pb
  end)

  for _, packId in ipairs(packIds) do
    local pack = ns.Data.packs[packId]
    if pack and pack.groups then
      for _, group in ipairs(pack.groups) do
        if group and group.id then
          ns.Data.groups[group.id] = group

          if group.category then
            ns.Data.groupsByCategory[group.category] = ns.Data.groupsByCategory[group.category] or {}
            table.insert(ns.Data.groupsByCategory[group.category], group)
          end
        end
      end
    end
  end
end


-- ============================================================
-- Character helpers
-- ============================================================
function ns.GetPlayerGUID()
  return UnitGUID("player")
end

function ns.EnsureCharacterRecord()
  local guid = ns.GetPlayerGUID()
  if not guid then return end

  local name, realm = UnitName("player")
  realm = realm or GetRealmName()
  local _, class = UnitClass("player")

  CollectionLogDB.characters[guid] = CollectionLogDB.characters[guid] or {
    name = name,
    realm = realm,
    class = class,
    items = {},
    runs = {},
  }

  local c = CollectionLogDB.characters[guid]
  c.name = name
  c.realm = realm
  c.class = class
  c.items = c.items or {}
  c.runs = c.runs or {}

  if not CollectionLogDB.ui.activeCharacterGUID then
    CollectionLogDB.ui.activeCharacterGUID = guid
  end
end

function ns.GetSortedCharacters()
  local out = {}
  for guid, c in pairs(CollectionLogDB.characters) do
    out[#out+1] = { guid = guid, name = c.name, realm = c.realm, class = c.class }
  end
  table.sort(out, function(a, b)
    local an = (a.name or "") .. "-" .. (a.realm or "")
    local bn = (b.name or "") .. "-" .. (b.realm or "")
    return an < bn
  end)
  return out
end

-- ============================================================
-- Collection state helpers (your tracker DB)
-- ============================================================
function ns.GetRecordedCount(itemID, viewMode, characterGUID)
  if not itemID then return 0 end

  if viewMode == "CHARACTER" and characterGUID then
    local c = CollectionLogDB.characters[characterGUID]
    if not c or not c.items then return 0 end
    local rec = c.items[itemID]
    return rec and rec.count or 0
  end

  local total = 0
  for _, c in pairs(CollectionLogDB.characters) do
    local rec = c.items and c.items[itemID]
    if rec and rec.count then total = total + rec.count end
  end
  return total
end

function ns.GetAttainedBy(itemID)
  local owners = {}

  -- Fast path: itemOwners index
  if CollectionLogDB.itemOwners and CollectionLogDB.itemOwners[itemID] then
    for guid in pairs(CollectionLogDB.itemOwners[itemID]) do
      local c = CollectionLogDB.characters and CollectionLogDB.characters[guid]
      if c then
        owners[#owners+1] = ("%s-%s"):format(c.name or "?", c.realm or "?")
      end
    end
    table.sort(owners)
    return owners
  end

  -- Fallback: scan all characters
  for _, c in pairs(CollectionLogDB.characters) do
    local rec = c.items and c.items[itemID]
    if rec and rec.count and rec.count > 0 then
      owners[#owners+1] = ("%s-%s"):format(c.name or "?", c.realm or "?")
    end
  end
  table.sort(owners)
  return owners
end

-- ============================================================
-- Blizzard collection checks
-- ============================================================
local function EnsureCollectionsLoaded()
  -- Ensures ToyBox/MountJournal are initialized when possible
  if CollectionsJournal_LoadUI then
    pcall(CollectionsJournal_LoadUI)
    -- continue so we can prime journals
  end
  if LoadAddOn then
    pcall(LoadAddOn, "Blizzard_Collections")
  end

  -- Prime the Mount Journal once per session.
  -- Some clients return incomplete mount collected-state until the journal has been queried at least once.
  if not ns._mountJournalPrimed then
    ns._mountJournalPrimed = true
    if C_Timer and C_MountJournal and C_MountJournal.GetMountIDs then
      C_Timer.After(0, function()
        pcall(C_MountJournal.GetMountIDs)
      end)
    elseif C_MountJournal and C_MountJournal.GetMountIDs then
      pcall(C_MountJournal.GetMountIDs)
    end
  end
end

-- ============================================================
-- Session warm-up (performance)
-- The first call into Blizzard collection APIs can cause a noticeable spike
-- after /reload or login as the client initializes internal caches.
-- We proactively (and safely) prime the relevant systems once per session,
-- spread over small delays to avoid a single frame hitch.
-- No loops, no OnUpdate.
-- ============================================================
local function PrimeCollectionsWarmupOnce()
  if ns._collectionsWarmupDone then return end
  ns._collectionsWarmupDone = true

  if not (C_Timer and C_Timer.After) then
    -- Fallback: do a minimal prime immediately.
    pcall(EnsureCollectionsLoaded)
    if C_PetJournal and C_PetJournal.GetNumPets then pcall(C_PetJournal.GetNumPets) end
    if C_ToyBox and C_ToyBox.GetNumToys then pcall(C_ToyBox.GetNumToys) end
    return
  end

  -- Staggered warm-ups (short delays) to spread any cache init cost.
  C_Timer.After(0.10, function()
    pcall(EnsureCollectionsLoaded)
  end)

  C_Timer.After(0.30, function()
    if C_PetJournal and C_PetJournal.GetNumPets then
      pcall(C_PetJournal.GetNumPets)
    end
  end)

  C_Timer.After(0.50, function()
    if C_ToyBox and C_ToyBox.GetNumToys then
      pcall(C_ToyBox.GetNumToys)
    end
  end)

  -- Light transmog probe: avoid enumerating sources; just touch an API so the
  -- underlying collection layer is initialized before the UI needs it.
  C_Timer.After(0.70, function()
    if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
      -- Use an invalid itemID safely; this is a cheap call but can initialize caches.
      pcall(C_TransmogCollection.GetItemInfo, 0)
    end
  end)
end

function ns.HasCollectedAppearance(itemID)
  if not itemID or itemID <= 0 then return false end
  if not C_TransmogCollection or not C_TransmogCollection.GetItemInfo then
    return false
  end

  -- GetItemInfo has been observed to return values in different shapes across builds:
  --   (appearanceID, sourceID) or occasionally (sourceID, nil).
  -- We normalize by probing GetAppearanceSourceInfo when needed.
  local a, b = C_TransmogCollection.GetItemInfo(itemID)
  local appearanceID, sourceID = a, b

  -- Normalize ambiguous return shapes by probing source info.
  -- Some builds have returned:
  --   (appearanceID, sourceID)
  --   (sourceID, nil)
  --   (sourceID, appearanceID)
  -- We treat whichever value yields a valid source-info table as the sourceID.
  if C_TransmogCollection.GetAppearanceSourceInfo then
    local function sourceInfo(id)
      if not id then return nil end
      local info = C_TransmogCollection.GetAppearanceSourceInfo(id)
      if info and (info.appearanceID or info.isCollected ~= nil) then
        return info
      end
      return nil
    end

    local infoA = sourceInfo(a)
    local infoB = sourceInfo(b)

    if infoA and not infoB then
      sourceID = a
      appearanceID = infoA.appearanceID or appearanceID
    elseif infoB and not infoA then
      sourceID = b
      appearanceID = infoB.appearanceID or appearanceID
    elseif infoA and infoB then
      -- Both look plausible; prefer b as sourceID to match the common (appearanceID, sourceID) shape.
      sourceID = b
      appearanceID = infoB.appearanceID or appearanceID
    else
      -- If we only got one value, try treating it as a sourceID anyway.
      if a and not b then
        local info = C_TransmogCollection.GetAppearanceSourceInfo(a)
        if info and (info.appearanceID or info.isCollected ~= nil) then
          sourceID = a
          appearanceID = info.appearanceID or appearanceID
        end
      end
    end
  end
-- 1) Best signal: specific source collected.
  if sourceID and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    if C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance(sourceID) then
      return true
    end
  end

  -- 2) Fallback: appearance collected (covers shared appearances where a different source was learned).
  if appearanceID and C_TransmogCollection.PlayerHasTransmogItemAppearance then
    if C_TransmogCollection.PlayerHasTransmogItemAppearance(appearanceID) then
      return true
    end
  end

  -- 3) Last-resort: source info (some items behave oddly with the above APIs).
  if sourceID and C_TransmogCollection.GetAppearanceSourceInfo then
    local info = C_TransmogCollection.GetAppearanceSourceInfo(sourceID)
    if info and info.isCollected then
      return true
    end
  end
  -- 4) Final fallback: Tooltip truth for transmog (STRICT).
  -- Only accept *positive* known markers. Never substring-match "collected" because
  -- negatives like "Not Collected" would otherwise produce false positives.
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local tip = C_TooltipInfo.GetItemByID(itemID)
    if tip and tip.lines then
      local known1 = TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN
      local known2 = TRANSMOGRIFY_TOOLTIP_ITEM_KNOWN
      local known2b = _G.TRANSMOGRIFY_TOOLTIP_ITEM_APPEARANCE_KNOWN
      local known3 = ITEM_SPELL_KNOWN -- sometimes used for learned appearances/illusions
      for _, line in ipairs(tip.lines) do
        local lt = line.leftText
        local rt = line.rightText

        -- Exact global string matches (localized-safe)
        if lt and ((known1 and lt == known1) or (known2 and lt == known2) or (known2b and lt == known2b) or (known3 and lt == known3)) then
          return true
        end
        if rt and ((known1 and rt == known1) or (known2 and rt == known2) or (known2b and rt == known2b) or (known3 and rt == known3)) then
          return true
        end

        -- Very strict literal positives (fallback, English-only)
        if lt then
          local l = lt:lower()
          if l == "collected" or l == "learned" or l == "known" then
            return true
          end
        end
        if rt then
          local r = rt:lower()
          if r == "collected" or r == "learned" or r == "known" then
            return true
          end
        end
      end
    end
  end

  return false
end

-- ============================================================
-- Mount Item Collection (robust)
-- Many mount items trigger a generic "Learning" spell and do NOT expose the actual mount spell.
-- For those, the only authoritative check is the Mount Journal's collected state.
-- This function tries to map itemID -> mountID by matching itemName in mount sourceText (or mount name),
-- caches the mapping, and returns whether the mapped mount is collected.
-- ============================================================
ns._itemToMountID = ns._itemToMountID or {}

function ns.IsMountItemCollected(itemID)
  if not itemID or itemID <= 0 then return false end

  EnsureCollectionsLoaded()

  if not C_MountJournal or not C_MountJournal.GetMountInfoByID then
    return false
  end

  -- IMPORTANT: Some loot tables store mounts as mountIDs (not itemIDs).
  -- However, mountIDs are small integers and can collide with valid itemIDs.
  -- So we only treat the provided ID as a mountID if it does NOT appear to be a real item.
  local appearsToBeItem = false
  do
    -- Prefer fast, non-alloc instant lookup.
    if GetItemInfoInstant then
      local _name = GetItemInfoInstant(itemID)
      if _name then
        appearsToBeItem = true
      end
    end
    if not appearsToBeItem and C_Item and C_Item.DoesItemExistByID then
      local ok, exists = pcall(C_Item.DoesItemExistByID, itemID)
      if ok and exists then
        appearsToBeItem = true
      end
    end
  end

  if not appearsToBeItem then
    local name, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(itemID)
    if name and name ~= "" then
      return isCollected and true or false
    end
  end

  ns._itemToMountID = ns._itemToMountID or {}
  ns._mountNameToID = ns._mountNameToID or nil

  local function IsCollectedByMountID(mountID)
    if not mountID then return false end
    local _, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
    return isCollected and true or false
  end

  local cached = ns._itemToMountID[itemID]
  if cached then
    return IsCollectedByMountID(cached)
  end

  -- Ask client to load the item data (non-blocking) so GetItemInfo/GetItemSpell will become available.
  if C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end

  -- 1) Preferred: official item->mount mapping APIs (names changed over expansions).
  local mountID

  local function tryCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return a, b
  end

  if not mountID and C_MountJournal.GetMountIDFromItemID then
    local a = select(1, tryCall(C_MountJournal.GetMountIDFromItemID, itemID))
    if a and a ~= 0 then mountID = a end
  end
  if not mountID and C_MountJournal.GetMountIDFromItem then
    local a = select(1, tryCall(C_MountJournal.GetMountIDFromItem, itemID))
    if a and a ~= 0 then mountID = a end
  end
  if not mountID and C_MountJournal.GetMountFromItemID then
    local a, b = tryCall(C_MountJournal.GetMountFromItemID, itemID)
    mountID = (a and a ~= 0 and a) or (b and b ~= 0 and b) or nil
  end
  if not mountID and C_MountJournal.GetMountFromItem then
    local a, b = tryCall(C_MountJournal.GetMountFromItem, itemID)
    mountID = (a and a ~= 0 and a) or (b and b ~= 0 and b) or nil
  end

  if mountID then
    ns._itemToMountID[itemID] = mountID
    return IsCollectedByMountID(mountID)
  end

  -- 2) Secondary: item use spell -> mount spell mapping.
  -- This catches mounts where the item teaches the mount via a spell (e.g. Fiendish Hellfire Core, Living Infernal Core)
  -- and where GetMountFromSpell might not be available or might be inconsistent.
  do
    local spellID

    -- Prefer C_Item API when available (more reliable than GetItemSpell while item data is loading).
    if C_Item and C_Item.GetItemSpell then
      local ok, _, sid = pcall(C_Item.GetItemSpell, itemID)
      if ok and sid then spellID = sid end
    end
    if not spellID and GetItemSpell then
      local _, sid = GetItemSpell(itemID)
      if sid then spellID = sid end
    end

    if spellID then
      -- Try Blizzard helper if present.
      if C_MountJournal.GetMountFromSpell then
        local mid = select(1, tryCall(C_MountJournal.GetMountFromSpell, spellID))
        if mid and mid ~= 0 then
          ns._itemToMountID[itemID] = mid
          return IsCollectedByMountID(mid)
        end
      end

      -- Fallback: build a spellID -> mountID index once per session.
      if not ns._mountSpellToID and C_MountJournal.GetMountIDs then
        ns._mountSpellToID = {}
        for _, mid in ipairs(C_MountJournal.GetMountIDs()) do
          local _, mountSpellID = C_MountJournal.GetMountInfoByID(mid)
          if mountSpellID and mountSpellID ~= 0 then
            ns._mountSpellToID[mountSpellID] = mid
          end
        end
      end
      local mid2 = ns._mountSpellToID and ns._mountSpellToID[spellID] or nil
      if mid2 then
        ns._itemToMountID[itemID] = mid2
        return IsCollectedByMountID(mid2)
      end
    end
  end

  -- 3) Smart fallback: build a name->mountID index once and match common token prefixes (Reins of..., etc.)
  local itemName
  if C_Item and C_Item.GetItemNameByID then
    itemName = C_Item.GetItemNameByID(itemID)
  end
  if not itemName and GetItemInfo then
    itemName = GetItemInfo(itemID)
  end
  if itemName and itemName ~= "" and C_MountJournal.GetMountIDs then
    -- Build name index once per session when needed.
    if not ns._mountNameToID then
      ns._mountNameToID = {}
      local ids = C_MountJournal.GetMountIDs()
      for _, mid in ipairs(ids) do
        local name = C_MountJournal.GetMountInfoByID(mid)
        if name and name ~= "" then
          ns._mountNameToID[name:lower()] = mid
        end
      end
    end

    local probe = itemName:lower()

    -- Common mount-token prefixes.
    local stripped = probe
    stripped = stripped:gsub("^reins of the%s+", "")
    stripped = stripped:gsub("^reins of%s+", "")
    stripped = stripped:gsub("^smoldering egg of%s+", "") -- still might not match, but harmless
    stripped = stripped:gsub("^egg of%s+", "")
    stripped = stripped:gsub("^horn of%s+", "")
    stripped = stripped:gsub("^whistle of%s+", "")

    -- Try exact, then stripped exact, then contains-match against mount names (cheap: iterate name index keys once).
    local mid = ns._mountNameToID[probe] or ns._mountNameToID[stripped]
    if mid then
      ns._itemToMountID[itemID] = mid
      return IsCollectedByMountID(mid)
    end

    -- Contains match as a last resort (still O(n) over mount names, but only runs for unmapped tokens).
    for nameLower, mid2 in pairs(ns._mountNameToID) do
      if stripped ~= "" and nameLower:find(stripped, 1, true) then
        ns._itemToMountID[itemID] = mid2
        return IsCollectedByMountID(mid2)
      end
    end
  end

  -- 4) Final fallback: tooltip truth.
  -- Some mount items do not reliably map item->mount across client versions.
  -- When that happens, Blizzard's tooltip will still show an authoritative
  -- "Already Known" line (ITEM_SPELL_KNOWN) once the mount is learned.
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local tip = C_TooltipInfo.GetItemByID(itemID)
    if tip and tip.lines then
      local known = ITEM_SPELL_KNOWN
      for _, line in ipairs(tip.lines) do
        local lt = line.leftText
        local rt = line.rightText
        if known and ((lt and lt == known) or (rt and rt == known)) then
          return true
        end
        -- Strict literal positives (avoid substring false positives like "Not Collected")
        if lt then
          local l = lt:lower()
          if l == "collected" or l == "learned" or l == "known" then
            return true
          end
        end
        if rt then
          local r = rt:lower()
          if r == "collected" or r == "learned" or r == "known" then
            return true
          end
        end
      end
    end
  end

  return false
end
-- ============================================================
-- Pet Item Collection (battle pets)
-- For caged / learnable battle pets, collected state is based on species ownership, not "spell known".
-- ============================================================
function ns.IsPetItemCollected(itemID)
  if not itemID or itemID <= 0 then return false end

  -- Ensure Pet Journal is loaded (some clients won't return stable data until Blizzard_Collections is loaded)
  if LoadAddOn then
    pcall(LoadAddOn, "Blizzard_Collections")
  end

  if not C_PetJournal
    or not C_PetJournal.GetPetInfoByItemID
    or not C_PetJournal.GetNumCollectedInfo then
    return false
  end

  -- IMPORTANT: Some loot tables (and some of our datapacks) store battle pets as speciesIDs
  -- rather than as learnable itemIDs. SpeciesIDs are small integers and will never resolve
  -- via GetPetInfoByItemID(). Detect this case up-front to avoid false negatives.
  do
    local okS, owned, total = pcall(C_PetJournal.GetNumCollectedInfo, itemID)
    -- If total is a positive number, Blizzard recognized this as a speciesID.
    if okS and type(total) == "number" and total > 0 then
      return (type(owned) == "number" and owned > 0) and true or false
    end
  end

  -- Capture multiple return shapes safely. Some clients return speciesID as the 13th value.
  local ok, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13 =
    pcall(C_PetJournal.GetPetInfoByItemID, itemID)

  if not ok then return false end

  local speciesID = nil

  -- Case 1: table return
  if type(r1) == "table" then
    speciesID = r1.speciesID or r1[13]
  end

  -- Case 2: retail-style 13th return
  if not speciesID and type(r13) == "number" and r13 > 0 then
    speciesID = r13
  end

  -- Case 3: older clients may return speciesID early
  if not speciesID then
    for _, v in ipairs({ r1, r2, r3, r4, r5 }) do
      if type(v) == "number" and v > 0 then
        speciesID = v
        break
      end
    end
  end

  if not speciesID then
    -- Final fallback: tooltip truth ("Already Known" / "Collected").
    -- Some pet tokens do not resolve via GetPetInfoByItemID() consistently,
    -- but Blizzard's item tooltip will still show an authoritative collected/known marker.
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
      local tip = C_TooltipInfo.GetItemByID(itemID)
      if tip and tip.lines then
        local known = ITEM_SPELL_KNOWN
        for _, line in ipairs(tip.lines) do
          local lt = line.leftText
          local rt = line.rightText
          if known and ((lt and lt == known) or (rt and rt == known)) then
            return true
          end
          if lt then
            local l = lt:lower()
            if l == "collected" or l == "learned" or l == "known" then
              return true
            end
          end
          if rt then
            local r = rt:lower()
            if r == "collected" or r == "learned" or r == "known" then
              return true
            end
          end
        end
      end
    end
    return false
  end

  local ok2, owned = pcall(function()
    return (select(1, C_PetJournal.GetNumCollectedInfo(speciesID)))
  end)

  return (ok2 and owned and owned > 0) and true or false
end


-- ============================================================
-- Generic "Collected" check used by UI
-- ============================================================
function ns.IsCollected(itemID)
  if not itemID or itemID <= 0 then return false end

  -- 1) Transmog appearance
  if ns.HasCollectedAppearance and ns.HasCollectedAppearance(itemID) then
    return true
  end

  -- 2) Mount items (robust journal scan)
  if ns.IsMountItemCollected and ns.IsMountItemCollected(itemID) then
    return true
  end
-- 2.5) Battle pets (species ownership)
if ns.IsPetItemCollected and ns.IsPetItemCollected(itemID) then
  return true
end


  -- 3) Toys
  EnsureCollectionsLoaded()
  if C_ToyBox and C_ToyBox.GetToyFromItemID and PlayerHasToy then
    local toyID = C_ToyBox.GetToyFromItemID(itemID)
    if toyID and PlayerHasToy(toyID) then
      return true
    end
  end

  -- 4) Blizzard tooltip truth: if tooltip says "Already known", treat as collected.
  -- Works for mounts and toys too (and anything Blizzard marks as known).
  if C_TooltipInfo and C_TooltipInfo.GetItemByID and ITEM_SPELL_KNOWN then
    local tip = C_TooltipInfo.GetItemByID(itemID)
    if tip and tip.lines then
      for _, line in ipairs(tip.lines) do
        local txt = line.leftText
        if txt and (txt == ITEM_SPELL_KNOWN or txt:find(ITEM_SPELL_KNOWN, 1, true)) then
          return true
        end
      end
    end
  end

  -- 4.5) Blizzard tooltip truth for transmog appearances.
  -- Some items are shown as "Collected" in the default tooltip even when transmog APIs
  -- don't resolve a stable sourceID/appearanceID (vendor oddities, legacy items, etc.).
  -- Prefer global strings when available to avoid locale issues.
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local tip = C_TooltipInfo.GetItemByID(itemID)
    if tip and tip.lines then
      local needles = {}
      if _G.TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN then
        needles[#needles+1] = _G.TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN
      end
      if _G.TRANSMOGRIFY_TOOLTIP_ITEM_APPEARANCE_KNOWN then
        needles[#needles+1] = _G.TRANSMOGRIFY_TOOLTIP_ITEM_APPEARANCE_KNOWN
      end
      -- As a last resort, match the plain English word used by Blizzard in many clients.
            local function MatchesAny(text)
        if not text or text == "" then return false end
        for _, n in ipairs(needles) do
          if n and n ~= "" and (text == n or text:find(n, 1, true)) then
            return true
          end
        end
        return false
      end

      for _, line in ipairs(tip.lines) do
        if MatchesAny(line.leftText) or MatchesAny(line.rightText) then
          return true
        end
      end
    end
  end

  -- 5) Spell-known fallback (good for some “learn/use” items)
  -- NOTE: This won't help for mount items that trigger generic "Learning" spells (like 71665),
  -- but it can still be useful for other collectible unlock items.
  if GetItemSpell then
    local _, spellID = GetItemSpell(itemID)
    if spellID then
      if (IsSpellKnown and IsSpellKnown(spellID)) or (IsPlayerSpell and IsPlayerSpell(spellID)) then
        return true
      end
    end
  end

  return false
end


-- Check collected state using a concrete itemLink when available (preferred for difficulty variants
-- where the base itemID stays the same but bonusIDs/modifiers differ).
function ns.IsCollectedFromLink(itemLink, itemID)
  if itemLink and itemLink ~= "" then
    -- 1) Transmog known markers from tooltip (Blizzard-authoritative, locale-safe globals).
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
      local tip = C_TooltipInfo.GetHyperlink(itemLink)
      if tip and tip.lines then
        local needles = {}
        if _G.TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN then
          needles[#needles+1] = _G.TRANSMOGRIFY_TOOLTIP_APPEARANCE_KNOWN
        end
        if _G.TRANSMOGRIFY_TOOLTIP_ITEM_APPEARANCE_KNOWN then
          needles[#needles+1] = _G.TRANSMOGRIFY_TOOLTIP_ITEM_APPEARANCE_KNOWN
        end
        if _G.TRANSMOGRIFY_TOOLTIP_ITEM_KNOWN then
          needles[#needles+1] = _G.TRANSMOGRIFY_TOOLTIP_ITEM_KNOWN
        end

        local function MatchesAny(text)
          if not text or text == "" then return false end
          for _, n in ipairs(needles) do
            if n and n ~= "" and (text == n or text:find(n, 1, true)) then
              return true
            end
          end
          return false
        end

        for _, line in ipairs(tip.lines) do
          if MatchesAny(line.leftText) or MatchesAny(line.rightText) then
            return true
          end
        end
      end
    end

    -- 2) Generic spell-known marker (covers mounts/toys sometimes)
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink and ITEM_SPELL_KNOWN then
      local tip = C_TooltipInfo.GetHyperlink(itemLink)
      if tip and tip.lines then
        for _, line in ipairs(tip.lines) do
          local txt = line.leftText
          if txt and (txt == ITEM_SPELL_KNOWN or txt:find(ITEM_SPELL_KNOWN, 1, true)) then
            return true
          end
        end
      end
    end
  end

  -- Fall back to itemID-based checks.
  return ns.IsCollected(itemID)
end


-- ============================================================
-- Bootstrap events
-- ============================================================
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    CollectionLogDB = CollectionLogDB or DeepCopy(DEFAULT_DB)
    MergeDefaults(CollectionLogDB, DEFAULT_DB)
    CollectionLogDB.characters = CollectionLogDB.characters or {}
    CollectionLogDB.itemOwners = CollectionLogDB.itemOwners or {}
  end

  if event == "PLAYER_LOGIN" then
    ns.EnsureCharacterRecord()

    -- Warm up Blizzard collection subsystems once per session to reduce the
    -- first-open hitch after login/reload.
    PrimeCollectionsWarmupOnce()

    -- Generated pack registers from CollectionLog_GeneratedPack.lua
    if ns.RegisterGeneratedPack then
      SafeCall(ns.RegisterGeneratedPack)
    end


-- Optional: import external drop categories pack (if installed)
if ns.LoadMountDropCategoriesFromGlobal then
  SafeCall(ns.LoadMountDropCategoriesFromGlobal)
end

-- Optional: import external source override pack (if installed)
if ns.LoadMountSourceOverridesFromGlobal then
  SafeCall(ns.LoadMountSourceOverridesFromGlobal)
end

    ns.RebuildGroupIndex()

    -- Ensure we have a default selected group
    if not CollectionLogDB.ui.activeGroupId then
      local cat = CollectionLogDB.ui.activeCategory or "Raids"
      local list = ns.Data.groupsByCategory[cat]
      if list and list[1] then
        CollectionLogDB.ui.activeGroupId = list[1].id
      end
    end

    if ns.UI and ns.UI.Init then
      SafeCall(ns.UI.Init)
    end

    if ns.MinimapButton_Init then
      SafeCall(ns.MinimapButton_Init)
    end

    Print("Loaded. Type /clog")
  end
end)

-- ============================================================
-- Slash commands (Core owns them)
-- ============================================================
SLASH_COLLECTIONLOG1 = "/clog"
SlashCmdList.COLLECTIONLOG = function(msg)
  msg = tostring(msg or "")
  local cmd, rest = msg:match("^%s*(%S+)%s*(.-)%s*$")
  cmd = cmd and cmd:lower() or ""
  if cmd == "testsound" then cmd = "soundtest" end


  if cmd == "minimap" then
    local sub = (rest or ""):lower()
    if sub == "show" then
      if ns.MinimapButton_Show then ns.MinimapButton_Show() end
    elseif sub == "hide" then
      if ns.MinimapButton_Hide then ns.MinimapButton_Hide() end
    elseif sub == "toggle" or sub == "" then
      if ns.MinimapButton_Toggle then ns.MinimapButton_Toggle() end
    elseif sub == "reset" then
      if ns.MinimapButton_Reset then ns.MinimapButton_Reset() end
    else
      Print("Usage: /clog minimap [show|hide|toggle|reset]")
    end
    return
  end
  if cmd == "perf" or cmd == "profile" then
    local arg = (rest or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if arg == "help" or arg == "h" or arg == "?" then
      Print("Perf usage:")
      Print("  /console scriptProfile 1  (then /reload)")
      Print("  reproduce lag")
      Print("  /clog perf [N]         (show top N tracked funcs, default 15)")
      Print("  /clog perf reset       (reset CPU counters)")
      Print("  /clog perf nosubs [N]  (exclude subcalls)")
      return
    end

    if arg == "reset" then
      if ns.Perf and ns.Perf.Reset then ns.Perf.Reset() end
      return
    end

    local includeSubs = true
    local n = nil
    if arg:find("nosubs") then
      includeSubs = false
      local nn = arg:match("nosubs%s+(%d+)")
      if nn then n = tonumber(nn) end
    else
      local nn = arg:match("^(%d+)$")
      if nn then n = tonumber(nn) end
    end

    if ns.Perf and ns.Perf.PrintTop then
      ns.Perf.PrintTop(n or 15, includeSubs)
    else
      Print("Perf: module unavailable")
    end
    return
  end





if cmd == "leftdebug" or cmd == "ldebug" then
  if not (ns and ns.UI and type(ns.UI.Debug_LeftListSnapshot) == "function") then
    Print("LeftDebug: UI not available yet. Open Collection Log once, then run again.")
    return
  end

  local arg = (rest or ""):gsub("^%s+",""):gsub("%s+$","")
  local gid, opt = arg:match("^(%S+)%s*(.*)$")
  opt = (opt or ""):lower()
  local groupId = gid and tonumber(gid) or nil
  if not groupId then
    groupId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil
  end
  if not groupId then
    Print("LeftDebug: no active groupId. Click a raid/encounter first.")
    return
  end

  local gidKey = tostring(groupId)
  local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
  local name = g and g.name or "(unknown)"
  Print("LeftDebug: groupId=" .. gidKey .. " name=" .. tostring(name))

  local snap = ns.UI.Debug_LeftListSnapshot(groupId)
  if snap.cache and snap.cache.total then
    Print(("Cache: %d/%d (truthLock=%s)"):format(tonumber(snap.cache.collected or 0), tonumber(snap.cache.total or 0), tostring(snap.truthLock)))
  else
    Print("Cache: (none) (truthLock=" .. tostring(snap.truthLock) .. ")")
  end

  if snap.button and snap.button.exists then
    Print(("Button: '%s' color=%.3f,%.3f,%.3f,%.3f"):format(tostring(snap.button.text or ""), snap.button.r or 0, snap.button.g or 0, snap.button.b or 0, snap.button.a or 0))
  else
    Print("Button: (not found in UI._clogGroupBtnById for this groupId)")
  end

  if snap.headerText then
    Print("Header: " .. tostring(snap.headerText))
  end

  if opt:find("recalc") then
    local c,t = ns.UI.Debug_GroupTotalsForLeftList(groupId)
    if c and t then
      Print(("Recalc (leftlist fn): %d/%d"):format(tonumber(c or 0), tonumber(t or 0)))
    else
      Print("Recalc: failed (group missing or error)")
    end
  end

  Print("Usage: /clog leftdebug [groupId] [recalc]")
  return
end

  -- Subcommands to avoid unreliable long slash registrations on some clients
  if cmd == "testpopup" or cmd == "tp" then
    local arg = (rest or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    local isNew = not (arg == "old" or arg == "0" or arg == "false")

    -- Ensure popup wrapper exists (UI file defines it)
    if type(_G.CollectionLog_ShowCollectionPopup) ~= "function" then
      -- Try to force-load UI by toggling once (non-destructive; user can close)
      if ns.UI and ns.UI.Toggle then
        ns.UI.Toggle()
      end
    end

    if type(_G.CollectionLog_ShowCollectionPopup) ~= "function" then
      Print("TestPopup: popup function not available yet. Open the Collection Log UI once, then try again.")
      return
    end

    Print("TestPopup: triggering popup (isNew=" .. tostring(isNew) .. ")")
    _G.CollectionLog_ShowCollectionPopup({
      name = "Test Collection",
      icon = 134586, -- honeycomb icon (easy to spot)
      source = "Test Trigger",
      isNew = isNew,
    })
    return
  elseif cmd == "soundtest" or cmd == "st" then
    -- NOTE: use double backslashes so the path is not mangled by Lua string escapes
    local path = "Sound\\Interface\\UI_70_Artifact_Forge_Trait_Unlock.ogg"
    local ok = false
    if type(PlaySoundFile) == "function" then
      ok = PlaySoundFile(path, "SFX") and true or false
    end
    Print("SoundTest: PlaySoundFile(" .. path .. ") => " .. tostring(ok))
    if (not ok) and type(PlaySound) == "function" and type(SOUNDKIT) == "table" then
          local keys = {
            "UI_70_ARTIFACT_FORGE_TRAIT_UNLOCK",
            "UI_EPICLOOT_TOAST",
            "UI_LOOT_TOAST_LEGENDARY",
            "UI_LOOT_TOAST_LESSER_ITEM_WON",
            "UI_LOOT_TOAST_LESSER_ITEM_LOOTED",
            "UI_PET_BATTLE_START",
            "IG_MAINMENU_OPTION_CHECKBOX_ON",
            "IG_MAINMENU_OPTION_CHECKBOX_OFF",
            "IG_MAINMENU_OPTION",
          }
          for _, key in ipairs(keys) do
            local kit = SOUNDKIT[key]
            if kit then
              PlaySound(kit, "SFX")
              Print("SoundTest: fallback SOUNDKIT." .. key .. " played")
              return
            end
          end
          Print("SoundTest: no SOUNDKIT fallback available on this client")
        end
    return
  elseif cmd == "popdebug" or cmd == "popupdebug" then
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.debug = CollectionLogDB.debug or {}
    CollectionLogDB.debug.popup = CollectionLogDB.debug.popup or { enabled = false, lines = {} }
    local arg = (rest or ""):lower():gsub("^%s+",""):gsub("%s+$","")
    if arg == "on" or arg == "1" or arg == "true" then
      CollectionLogDB.debug.popup.enabled = true
    elseif arg == "off" or arg == "0" or arg == "false" then
      CollectionLogDB.debug.popup.enabled = false
    else
      CollectionLogDB.debug.popup.enabled = not CollectionLogDB.debug.popup.enabled
    end
    Print("PopDebug: " .. (CollectionLogDB.debug.popup.enabled and "ON" or "OFF"))
    return
  elseif cmd == "popdump" or cmd == "popupdump" then
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.debug = CollectionLogDB.debug or {}
    CollectionLogDB.debug.popup = CollectionLogDB.debug.popup or { enabled = false, lines = {} }
    Print("PopDebug: last " .. tostring(#(CollectionLogDB.debug.popup.lines or {})) .. " lines")
    for i = #(CollectionLogDB.debug.popup.lines or {}), 1, -1 do
      Print(CollectionLogDB.debug.popup.lines[i])
    end
    return
  elseif cmd == "help" or cmd == "?" then
    Print("Commands: /clog (toggle), /clog testpopup [old], /clog soundtest, /clog popdebug [on|off], /clog popdump")
    return
  elseif cmd ~= "" then
    Print("Unknown /clog command: " .. cmd .. " (try /clog help)")
    return
  end

  -- Default: toggle UI
  if ns.UI and ns.UI.Toggle then
    ns.UI.Toggle()
  else
    Print("UI not loaded (check Lua errors).")
  end
end


-- Test popup command (for verifying popup + sound gating)
-- Test popup / sound commands (for verifying popup + sound gating)
SLASH_COLLECTIONLOGTESTPOPUP1 = "/cltestpopup"
SLASH_COLLECTIONLOGTESTPOPUP2 = "/cltp"
SlashCmdList.COLLECTIONLOGTESTPOPUP = function(msg)
  msg = tostring(msg or "")
  msg = msg:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local isNew = true
  if msg == "old" or msg == "0" or msg == "false" then
    isNew = false
  end

  if type(_G.CollectionLog_ShowCollectionPopup) ~= "function" then
    Print("TestPopup: popup function not available yet. Open the Collection Log UI once, then try again.")
    return
  end

  Print("TestPopup: triggering popup (isNew=" .. tostring(isNew) .. ")")
  _G.CollectionLog_ShowCollectionPopup({
    name = "Test Collection",
    icon = 134586, -- honeycomb icon (easy to spot)
    source = "Test Trigger",
    isNew = isNew,
  })
end

SLASH_CLOGSOUNDTEST1 = "/clogsoundtest"
SLASH_CLOGSOUNDTEST2 = "/clst"
SlashCmdList.CLOGSOUNDTEST = function()
  local path = "Sound\\Interface\\UI_70_Artifact_Forge_Trait_Unlock.ogg"
  local ok = false
  if type(PlaySoundFile) == "function" then
    ok = PlaySoundFile(path, "SFX") and true or false
  end
  Print("SoundTest: PlaySoundFile(" .. path .. ") => " .. tostring(ok))
  if (not ok) and type(PlaySound) == "function" and type(SOUNDKIT) == "table" then
          local keys = {
            "UI_70_ARTIFACT_FORGE_TRAIT_UNLOCK",
            "UI_EPICLOOT_TOAST",
            "UI_LOOT_TOAST_LEGENDARY",
            "UI_LOOT_TOAST_LESSER_ITEM_WON",
            "UI_LOOT_TOAST_LESSER_ITEM_LOOTED",
            "UI_PET_BATTLE_START",
            "IG_MAINMENU_OPTION_CHECKBOX_ON",
            "IG_MAINMENU_OPTION_CHECKBOX_OFF",
            "IG_MAINMENU_OPTION",
          }
          for _, key in ipairs(keys) do
            local kit = SOUNDKIT[key]
            if kit then
              PlaySound(kit, "SFX")
              Print("SoundTest: fallback SOUNDKIT." .. key .. " played")
              return
            end
          end
          Print("SoundTest: no SOUNDKIT fallback available on this client")
        end
end

-- Scan currently-selected Adventure Guide instance loot tab
SLASH_CLOGSCAN1 = "/clogscan"
SlashCmdList.CLOGSCAN = function()
  if ns and ns.ScanCurrentJournalLoot then
    SafeCall(ns.ScanCurrentJournalLoot)
  elseif ns and ns.ShowScanner then
    SafeCall(ns.ShowScanner)
  else
    Print("Scanner not loaded. Ensure CollectionLog_Importer_EJ.lua is error-free.")
  end
end

-- Scan all common difficulties for the currently-selected Adventure Guide instance.
-- Usage:
--   /clogscanall
--   /clogscanall raid
--   /clogscanall dungeon
SLASH_CLOGSCANALL1 = "/clogscanall"
SlashCmdList.CLOGSCANALL = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local arg = msg:match("^%s*(%S+)")
  if ns and ns.ScanCurrentJournalLootAllDifficulties then
    SafeCall(ns.ScanCurrentJournalLootAllDifficulties, arg)
  else
    Print("Scan-all not available. Ensure CollectionLog_Importer_EJ.lua is loaded without errors.")
  end
end


-- Scan *all* raids and/or dungeons in the Encounter Journal across common difficulties.
-- Usage:
--   /clogscanallinstances          (raids + dungeons)
--   /clogscanallinstances raids
--   /clogscanallinstances dungeons
SLASH_CLOGSCANALLINSTANCES1 = "/clogscanallinstances"
SlashCmdList.CLOGSCANALLINSTANCES = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local arg = msg:match("^%s*(%S+)")
  if ns and ns.ScanAllJournalInstancesAllDifficulties then
    SafeCall(ns.ScanAllJournalInstancesAllDifficulties, arg)
  else
    Print("Scan-all-instances not available. Ensure CollectionLog_Importer_EJ.lua is loaded without errors.")
  end
end



-- Scan a specific expansion tier into a dedicated generated pack (kept separate).
-- These are designed for modern tiers (Dragonflight / The War Within), using LFG gating to avoid phantom difficulties.
-- Usage:
--   /clogbuilddf dungeons
--   /clogbuilddf raids
--   /clogbuildtww dungeons
--   /clogbuildtww raids
SLASH_CLOGBUILDDf1 = "/clogbuilddf"
SlashCmdList.CLOGBUILDDf = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local want = (msg:match("^%s*(%S+)") or "dungeons"):lower()
  if not (ns and ns.ScanTierInstancesAllDifficulties) then
    Print("Tier scanner not available. Ensure CollectionLog_Importer_EJ.lua is loaded without errors.")
    return
  end
  local packKey = (want == "raids" or want == "raid") and "raids_dragonflight" or "dungeons_dragonflight"
  SafeCall(ns.ScanTierInstancesAllDifficulties, packKey, "Dragonflight", want)
end

SLASH_CLOGBUILDTww1 = "/clogbuildtww"
SlashCmdList.CLOGBUILDTww = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local want = (msg:match("^%s*(%S+)") or "dungeons"):lower()
  if not (ns and ns.ScanTierInstancesAllDifficulties) then
    Print("Tier scanner not available. Ensure CollectionLog_Importer_EJ.lua is loaded without errors.")
    return
  end
  local packKey = (want == "raids" or want == "raid") and "raids_tww" or "dungeons_tww"
  -- Tier name in EJ is usually "The War Within", but we match by substring "war within" in the scanner.
  SafeCall(ns.ScanTierInstancesAllDifficulties, packKey, "War Within", want)
end

-- Clear all *scanned* (GeneratedPack) Encounter Journal groups for raids/dungeons.
-- IMPORTANT: This deletes the groups (does not hide), so a rescan will recreate them
-- without requiring /clogunhide or manual SavedVariables edits.
-- Usage:
--   /clogclearencounters            (raids + dungeons)
--   /clogclearencounters raids
--   /clogclearencounters dungeons
SLASH_CLOGCLEARENC1 = "/clogclearencounters"
SLASH_CLOGCLEARENC2 = "/clogclear"
SlashCmdList.CLOGCLEARENC = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local want = (msg:match("^%s*(%S+)") or ""):lower()

  local clearRaids = (want == "" or want == "all" or want == "both" or want == "raids" or want == "raid")
  local clearDungeons = (want == "" or want == "all" or want == "both" or want == "dungeons" or want == "dungeon")

  if not clearRaids and not clearDungeons then
    Print("Usage: /clogclearencounters  (or 'raids' / 'dungeons')")
    return
  end

  if not CollectionLogDB then
    Print("CollectionLogDB not initialized yet.")
    return
  end

  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or { version = 1, groups = {} }
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  CollectionLogDB.ui = CollectionLogDB.ui or {}
  CollectionLogDB.ui.hiddenGroups = CollectionLogDB.ui.hiddenGroups or {}

  local removed = 0

  -- Remove matching groups in reverse to preserve indices
  for i = #CollectionLogDB.generatedPack.groups, 1, -1 do
    local g = CollectionLogDB.generatedPack.groups[i]
    if g and type(g.id) == "string" and g.id:match("^ej:%d+:%d+$") then
      local cat = (type(g.category) == "string") and g.category or ""
      if (clearRaids and cat == "Raids") or (clearDungeons and cat == "Dungeons") then
        -- Ensure no lingering hidden state blocks future rescans
        if CollectionLogDB.ui.hiddenGroups[g.id] then
          CollectionLogDB.ui.hiddenGroups[g.id] = nil
        end
        table.remove(CollectionLogDB.generatedPack.groups, i)
        removed = removed + 1
      end
    end
  end

  -- Rebuild indices and refresh UI so tabs repopulate immediately
  if ns and ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  -- If the active group was deleted, pick a sane default
  if CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId then
    local active = CollectionLogDB.ui.activeGroupId
    local stillExists = false
    local groups = ns and ns.Data and ns.Data.groupsById
    if groups and groups[active] then
      stillExists = true
    end
    if not stillExists then
      CollectionLogDB.ui.activeGroupId = nil
    end
  end

  if ns and ns.UI and ns.UI.RefreshAll then
    ns.UI.RefreshAll()
  elseif ns and ns.UI and ns.UI.RefreshGrid then
    ns.UI.RefreshGrid()
  end

  Print(("Cleared %d scanned %s encounter groups. You can rescan immediately."):format(
    removed,
    (clearRaids and clearDungeons) and "raid+dungeon" or (clearRaids and "raid" or "dungeon")
  ))
end

-- Scan currently-open vendor (Merchant window) into a deterministic Vendors group.
-- Usage: open a vendor, then /clogvendor
SLASH_CLOGVENDOR1 = "/clogvendor"
SlashCmdList.CLOGVENDOR = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local lower = msg:lower()

  -- Config: /clogvendor auto on|off|status  (default off)
  --         /clogvendor notify on|off
  if lower:match("^%s*auto") then
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.ui = CollectionLogDB.ui or {}
    local arg = lower:match("^%s*auto%s*(%S*)") or ""
    if arg == "on" then
      CollectionLogDB.ui.autoScanVendors = true
      Print("Vendor autoscan: ON (only saves vendors with collectibles).")
    elseif arg == "off" then
      CollectionLogDB.ui.autoScanVendors = false
      Print("Vendor autoscan: OFF.")
    else
      Print(("Vendor autoscan is currently: %s"):format(CollectionLogDB.ui.autoScanVendors and "ON" or "OFF"))
      Print(("Vendor autoscan notify is: %s"):format(CollectionLogDB.ui.autoScanVendorsNotify and "ON" or "OFF"))
      Print("Usage: /clogvendor auto on|off")
      Print("       /clogvendor notify on|off")
    end
    return
  end

  if lower:match("^%s*notify") then
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.ui = CollectionLogDB.ui or {}
    local arg = lower:match("^%s*notify%s*(%S*)") or ""
    if arg == "on" then
      CollectionLogDB.ui.autoScanVendorsNotify = true
      Print("Vendor autoscan notify: ON.")
    elseif arg == "off" then
      CollectionLogDB.ui.autoScanVendorsNotify = false
      Print("Vendor autoscan notify: OFF.")
    else
      Print(("Vendor autoscan notify is currently: %s"):format(CollectionLogDB.ui.autoScanVendorsNotify and "ON" or "OFF"))
      Print("Usage: /clogvendor notify on|off")
    end
    return
  end

  local wantSnippet = lower:find("snippet", 1, true) ~= nil
  local forceAll = lower:find("all", 1, true) ~= nil

  if ns and ns.ScanCurrentMerchantVendor then
    SafeCall(ns.ScanCurrentMerchantVendor, { printSnippet = wantSnippet, requireCollectible = (not forceAll), silent = false })
  else
    Print("Vendor scanner not loaded (check Lua errors / TOC order).")
  end
end

-- Optional helpers
SLASH_COLLECTIONLOGIMPORT1 = "/clogimport"
SlashCmdList.COLLECTIONLOGIMPORT = function()
  if ns and ns.ShowScanner then
    SafeCall(ns.ShowScanner)
  else
    Print("Importer UI not available.")
  end
end

SLASH_COLLECTIONLOGEJDEBUG1 = "/clogej"
SlashCmdList.COLLECTIONLOGEJDEBUG = function()
  local ok = pcall(function()
    if EncounterJournal_LoadUI then EncounterJournal_LoadUI() end


    local tiers = (EJ_GetNumTiers and EJ_GetNumTiers()) or -1
    Print(("EJ debug: tiers=%s"):format(tostring(tiers)))
  end)
  if not ok then
    Print("EJ debug error.")
  end
end


-- ==========================================================================
-- Mounts helpers
-- ==========================================================================

-- Force rebuild mounts groups + refresh UI
-- Usage: /clogmounts
SLASH_CLOGMOUNTS1 = "/clogmounts"
SlashCmdList.CLOGMOUNTS = function()
  if ns and ns.EnsureMountsGroups then
    SafeCall(ns.EnsureMountsGroups)
  else
    Print("Mounts importer not loaded (check Lua errors / TOC order).")
    return
  end

  if ns and ns.RebuildGroupIndex then
    SafeCall(ns.RebuildGroupIndex)
  end

  if ns and ns.UI then
    if ns.UI.BuildGroupList then SafeCall(ns.UI.BuildGroupList) end
    if ns.UI.RefreshGrid then SafeCall(ns.UI.RefreshGrid) end
  end

  Print("Rebuilt Mounts groups.")
end

-- Debug: mount drop classification summary (requires Mounts importer)
-- Usage: /clogmountsdrop
SLASH_CLOGMOUNTSDROP1 = "/clogmountsdrop"
SlashCmdList.CLOGMOUNTSDROP = function()
  if ns and ns.DebugDumpMountDrops then
    SafeCall(ns.DebugDumpMountDrops)
  else
    Print("Mounts drop debug not available.")
  end
end

-- Debug: MountDropCategories datapack counts (RAID/DUNGEON/OPEN_WORLD/DELVE)
-- Usage: /clogdebugdrops
SLASH_CLOGDEBUGDROPS1 = "/clogdebugdrops"
SlashCmdList.CLOGDEBUGDROPS = function()
  local function norm(v)
    if type(v) ~= "string" then return nil end
    v = v:upper():gsub("[^A-Z0-9]+", "_")
    return v
  end

  local map, meta

  -- Preferred: namespaced pack (main addon)
  if ns and ns.DataPacks and ns.DataPacks.MountDropCategories then
    local p = ns.DataPacks.MountDropCategories
    map = p.map or p
    meta = p.meta
    Print("CLOG DEBUG: using ns.DataPacks.MountDropCategories")
  end

  -- Fallback: companion addon globals
  if not map and _G and _G.MountDropCategories then
    map = _G.MountDropCategories
    meta = _G.MountDropCategories_META
    Print("CLOG DEBUG: using global MountDropCategories (companion addon)")
  end

  if not map then
    Print("CLOG DEBUG: MountDropCategories pack NOT FOUND")
    return
  end

  local counts = { RAID=0, DUNGEON=0, OPEN_WORLD=0, DELVE=0 }
  local samples = { RAID={}, DUNGEON={}, OPEN_WORLD={}, DELVE={} }
  local total = 0

  for k, entry in pairs(map) do
    total = total + 1

    local cat = entry
    if type(entry) == "table" then
      cat = entry.cat or entry.category or entry.type
    end
    cat = norm(cat)

    if cat then
      if cat:find("RAID") then
        counts.RAID = counts.RAID + 1
        if #samples.RAID < 5 then table.insert(samples.RAID, tostring(k)) end
      elseif cat:find("DUNGEON") then
        counts.DUNGEON = counts.DUNGEON + 1
        if #samples.DUNGEON < 5 then table.insert(samples.DUNGEON, tostring(k)) end
      elseif cat:find("DELVE") then
        counts.DELVE = counts.DELVE + 1
        if #samples.DELVE < 5 then table.insert(samples.DELVE, tostring(k)) end
      elseif cat:find("OPEN") or cat:find("WORLD") then
        counts.OPEN_WORLD = counts.OPEN_WORLD + 1
        if #samples.OPEN_WORLD < 5 then table.insert(samples.OPEN_WORLD, tostring(k)) end
      end
    end
  end

  Print(("CLOG DEBUG: entries=%d  RAID=%d  DUNGEON=%d  OPEN_WORLD=%d  DELVE=%d"):format(
    total, counts.RAID, counts.DUNGEON, counts.OPEN_WORLD, counts.DELVE
  ))

  for bucket, t in pairs(samples) do
    if #t > 0 then
      Print(("  %s sample mountIDs: %s"):format(bucket, table.concat(t, ", ")))
    end
  end

  -- Invalidate Overview totals cache so it can never get stuck at 0/0 after datapacks/index changes.
  if CollectionLogDB and CollectionLogDB.cache and CollectionLogDB.cache.overview then
    wipe(CollectionLogDB.cache.overview)
  end

  -- If the UI is already loaded, ask it to rebuild the Overview cache on next tick.
  if ns and ns.UI and ns.UI.RequestOverviewRebuild then
    ns.UI.RequestOverviewRebuild("groupIndex")
  end
end

-- ==========================================================================
-- Data Packs debug
-- Usage: /clogpacks
-- ==========================================================================
SLASH_CLOGPACKS1 = "/clogpacks"
SlashCmdList.CLOGPACKS = function()
  local any = false
  if type(ns.DataPacks) ~= "table" then
    Print("No data packs table loaded.")
    return
  end

  for name, pack in pairs(ns.DataPacks) do
    if type(pack) == "table" and type(pack.meta) == "table" then
      any = true
      Print(("Pack %s: %s"):format(tostring(name), ns.PackMetaString(pack)))
    end
  end

  if not any then
    Print("No data packs loaded (this is OK).")
  end
end



-- ==========================================================================
-- Mount Groups debug dump (SavedVariables)
-- Usage:
--   /clogmountgroups        (build/refresh dump)
--   /clogmountgroups count  (print group count + duplicate name count)
--   /clogmountgroups clear  (clear dump)
--
-- Notes:
-- - The dump is written to CollectionLogMountGroupsDB (SavedVariables).
-- - SavedVariables are only guaranteed to persist after a full logout/exit.
--
-- This snapshots the Mounts sidebar groups currently generated by the addon,
-- including internal IDs, display names, and mount counts.
-- ==========================================================================
SLASH_CLOGMOUNTGROUPS1 = "/clogmountgroups"
SlashCmdList.CLOGMOUNTGROUPS = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local lower = msg:lower()

  CollectionLogMountGroupsDB = CollectionLogMountGroupsDB or {}

  if lower:match("^%s*clear") then
    CollectionLogMountGroupsDB = {}
    Print("Cleared CollectionLogMountGroupsDB.")
    return
  end

  if lower:match("^%s*count") then
    local n = (type(CollectionLogMountGroupsDB.groups) == "table") and #CollectionLogMountGroupsDB.groups or 0
    local d = (type(CollectionLogMountGroupsDB.duplicateNames) == "table") and #CollectionLogMountGroupsDB.duplicateNames or 0
    Print(("Mount groups dump: groups=%d duplicateNames=%d"):format(n, d))
    return
  end

  -- Ensure groups are built (Mounts importer)
  if ns and ns.EnsureMountsGroups then
    SafeCall(ns.EnsureMountsGroups)
  end

  local groups = {}
  local byName = {}

  if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
    for _, g in ipairs(CollectionLogDB.generatedPack.groups) do
      if g and g.category == "Mounts" then
        local id = tostring(g.id or "")
        local name = tostring(g.name or "")
        local count = (type(g.mounts) == "table") and #g.mounts or 0

        local kind = "other"
        if id:find("^mounts:tag:") then kind = "tag" end
        if id:find("^mounts:source:") then kind = "source" end
        if id:find("^mounts:drop:") then kind = "drop" end
        if id == "mounts:all" then kind = "all" end

        local preview = {}
        if type(g.mounts) == "table" then
          for i = 1, math.min(10, #g.mounts) do
            preview[i] = g.mounts[i]
          end
        end

        table.insert(groups, {
          id = id,
          name = name,
          kind = kind,
          sortIndex = tonumber(g.sortIndex or 0) or 0,
          count = count,
          preview = preview,
        })

        local nk = name:lower()
        byName[nk] = byName[nk] or { name = name, ids = {} }
        table.insert(byName[nk].ids, id)
      end
    end
  end

  table.sort(groups, function(a,b)
    if a.kind ~= b.kind then return tostring(a.kind) < tostring(b.kind) end
    if (a.sortIndex or 0) ~= (b.sortIndex or 0) then return (a.sortIndex or 0) < (b.sortIndex or 0) end
    if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
    return (a.id or "") < (b.id or "")
  end)

  local duplicates = {}
  for _, v in pairs(byName) do
    if v and type(v.ids) == "table" and #v.ids > 1 then
      table.sort(v.ids)
      table.insert(duplicates, { name = v.name, ids = v.ids })
    end
  end
  table.sort(duplicates, function(a,b) return (a.name or "") < (b.name or "") end)

  local _, build, _, toc = GetBuildInfo()
  CollectionLogMountGroupsDB.meta = {
    generatedAt = time(),
    build = tostring(build or ""),
    toc = tostring(toc or ""),
  }
  CollectionLogMountGroupsDB.groups = groups
  CollectionLogMountGroupsDB.duplicateNames = duplicates

  Print(("Mount groups dump built: %d groups (%d duplicate names). (Exit game to save SavedVariables.)"):format(#groups, #duplicates))
end


-- ==========================================================================
-- Mount -> Groups export (SavedVariables)
-- Usage:
--   /clogmountexport        (build/refresh export)
--   /clogmountexport count  (print counts)
--   /clogmountexport clear  (clear export)
--
-- Notes:
-- - The export is written to CollectionLogMountGroupingExportDB (SavedVariables).
-- - SavedVariables are only guaranteed to persist after a full logout/exit.
--
-- This snapshots how mounts are grouped in the current runtime build:
-- - For each mountID, records every Mounts sidebar group it appears in.
-- - Records group IDs + display names to make debugging deterministic.
-- ==========================================================================
SLASH_CLOGMOUNTEXPORT1 = "/clogmountexport"
SlashCmdList.CLOGMOUNTEXPORT = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local lower = msg:lower()

  CollectionLogMountGroupingExportDB = CollectionLogMountGroupingExportDB or {}

  if lower:match("^%s*clear") then
    CollectionLogMountGroupingExportDB = {}
    Print("Cleared CollectionLogMountGroupingExportDB.")
    return
  end

  if lower:match("^%s*count") then
    local m = (type(CollectionLogMountGroupingExportDB.mounts) == "table") and CollectionLogMountGroupingExportDB.mounts or {}
    local mountsCount = 0
    for _ in pairs(m) do mountsCount = mountsCount + 1 end
    local groupsCount = (type(CollectionLogMountGroupingExportDB.groups) == "table") and #CollectionLogMountGroupingExportDB.groups or 0
    Print(("Mount export: mounts=%d groups=%d"):format(mountsCount, groupsCount))
    return
  end

  -- Ensure groups are built (Mounts importer)
  if ns and ns.EnsureMountsGroups then
    SafeCall(ns.EnsureMountsGroups)
  end

  local mountsMap = {}
  local groupsOut = {}

  local function EnsureCollectionsLoaded()
    if C_MountJournal and C_MountJournal.GetMountInfoByID then return true end
    pcall(LoadAddOn, "Blizzard_Collections")
    return true
  end
  EnsureCollectionsLoaded()

  if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
    for _, g in ipairs(CollectionLogDB.generatedPack.groups) do
      if g and g.category == "Mounts" and type(g.mounts) == "table" then
        local gid = tostring(g.id or "")
        local gname = tostring(g.name or "")
        local kind = "other"
        if gid == "mounts:all" then kind = "all" end
        if gid:find("^mounts:tag:") then kind = "tag" end
        if gid:find("^mounts:source:") then kind = "source" end
        if gid:find("^mounts:drop:") then kind = "drop" end
        if gid:find("^mounts:drops:") then kind = "drops" end

        table.insert(groupsOut, {
          id = gid,
          name = gname,
          kind = kind,
          sortIndex = tonumber(g.sortIndex or 0) or 0,
          count = #g.mounts,
        })

        for _, mountID in ipairs(g.mounts) do
          local mid = tonumber(mountID)
          if mid and mid > 0 then
            local entry = mountsMap[mid]
            if not entry then
              entry = { groups = {} }

              -- Best-effort name + collected state (truth from Blizzard when available)
              if C_MountJournal and C_MountJournal.GetMountInfoByID then
                local ok, name, spellID, icon, active, isUsable, sourceType, isFavorite, isFactionSpecific, faction, hideOnChar, isCollected = pcall(C_MountJournal.GetMountInfoByID, mid)
                if ok then
                  entry.name = name
                  entry.spellID = spellID
                  entry.isCollected = isCollected
                end
              end

              mountsMap[mid] = entry
            end

            table.insert(entry.groups, { id = gid, name = gname, kind = kind })
          end
        end
      end
    end
  end

  -- Sort for deterministic diffs
  table.sort(groupsOut, function(a,b)
    if (a.sortIndex or 0) ~= (b.sortIndex or 0) then return (a.sortIndex or 0) < (b.sortIndex or 0) end
    if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
    return (a.id or "") < (b.id or "")
  end)
  for _, e in pairs(mountsMap) do
    if e and type(e.groups) == "table" then
      table.sort(e.groups, function(a,b)
        if (a.kind or "") ~= (b.kind or "") then return (a.kind or "") < (b.kind or "") end
        if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
        return (a.id or "") < (b.id or "")
      end)
    end
  end

  local _, build, _, toc = GetBuildInfo()
  CollectionLogMountGroupingExportDB.meta = {
    generatedAt = time(),
    build = tostring(build or ""),
    toc = tostring(toc or ""),
    addonVersion = tostring(ns.VERSION or ""),
  }
  CollectionLogMountGroupingExportDB.groups = groupsOut
  CollectionLogMountGroupingExportDB.mounts = mountsMap

  local mountsCount = 0
  for _ in pairs(mountsMap) do mountsCount = mountsCount + 1 end
  Print(("Mount export built: mounts=%d groups=%d. (Exit game to save SavedVariables.)"):format(mountsCount, #groupsOut))
end
-- ==========================================================================
-- Mount Journal dump (SavedVariables)
-- Usage:
--   /clogmountdump        (build/refresh dump)
--   /clogmountdump count  (print counts)
--   /clogmountdump clear  (clear dump)
--
-- Notes:
-- - The dump is written to CollectionLogMountDumpDB (SavedVariables).
-- - SavedVariables are only guaranteed to persist after a full logout/exit.
-- ==========================================================================
SLASH_CLOGMOUNTDUMP1 = "/clogmountdump"
SlashCmdList.CLOGMOUNTDUMP = function(msg)
  msg = (type(msg) == "string") and msg or ""
  local lower = msg:lower()

  CollectionLogMountDumpDB = CollectionLogMountDumpDB or {}

  local function EnsureCollectionsLoaded()
    if C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID then
      return true
    end
    pcall(LoadAddOn, "Blizzard_Collections")
    return true
  end

  if lower:match("^%s*clear") then
    CollectionLogMountDumpDB = {}
    Print("Cleared CollectionLogMountDumpDB.")
    return
  end

  if lower:match("^%s*count") then
    local n = (type(CollectionLogMountDumpDB.mounts) == "table") and #CollectionLogMountDumpDB.mounts or 0
    Print(("Mount dump count: %d"):format(n))
    return
  end

  EnsureCollectionsLoaded()
  if not (C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID) then
    Print("Mount Journal not available (Blizzard_Collections not loaded?).")
    return
  end

  local ids = C_MountJournal.GetMountIDs()
  if type(ids) ~= "table" or #ids == 0 then
    Print("No mounts returned by C_MountJournal.GetMountIDs().")
    return
  end

  local function GetSourceText(mountID)
    if C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
      local ok, a, b, c, d, e = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
      if ok then
        -- Most clients: creatureDisplayID, description, sourceText, isSelfMount, mountTypeID
        if type(c) == "string" then return c end
        -- Fallback: try other positions if the tuple differs
        if type(b) == "string" then return b end
        if type(d) == "string" then return d end
      end
    end
    return ""
  end

  local function SourceTypeName(sourceType)
    local st = tonumber(sourceType or 0) or 0
    -- Prefer Blizzard enum names when available
    if Enum and Enum.MountJournalSource then
      for k, v in pairs(Enum.MountJournalSource) do
        if v == st and type(k) == "string" then
          return k
        end
      end
    end
    return tostring(st)
  end

  local out = {}
  for _, mountID in ipairs(ids) do
    local name, spellID, icon, active, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected =
      C_MountJournal.GetMountInfoByID(mountID)

    local entry = {
      mountID = mountID,
      name = name or "",
      spellID = spellID or 0,
      sourceType = tonumber(sourceType or 0) or 0,
      sourceTypeName = SourceTypeName(sourceType),
      sourceText = GetSourceText(mountID),
      isCollected = not not isCollected,
      isUsable = not not isUsable,
      isFavorite = not not isFavorite,
      faction = faction,
      -- Raw tuples for forward compatibility/debugging
      rawInfo = { name, spellID, icon, active, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected },
    }

    if C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
      local ok, a, b, c, d, e = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
      if ok then
        entry.rawExtra = { a, b, c, d, e }
      end
    end

    table.insert(out, entry)
  end

  CollectionLogMountDumpDB.meta = {
    generatedAt = time and time() or 0,
    version = ns.VERSION or "",
    interface = select(4, GetBuildInfo()),
    locale = GetLocale and GetLocale() or "",
  }
  CollectionLogMountDumpDB.mounts = out
  Print(("Mount dump built: %d mounts. (Exit game to save SavedVariables.)"):format(#out))
end


-- Inspect an itemID and print mapping info for Pets/Toys debugging
SLASH_CLOGINSPECT1 = "/cloginspect"
SlashCmdList.CLOGINSPECT = function(msg)
  local itemID = tonumber((msg or ""):match("(%d+)"))
  if not itemID then
    Print("Usage: /cloginspect <itemID>")
    return
  end


  Print(("Inspect itemID=%d"):format(itemID))

  -- Item identity
  local name, link, quality, ilvl, reqLevel, class, subClass, maxStack, equipLoc, icon, sellPrice, classID, subClassID =
    (GetItemInfo and GetItemInfo(itemID))
  local iName, iLink
  if name then
    Print(("Name: %s"):format(tostring(name)))
  else
    Print("Name: (not cached yet; try again in a moment)")
  end

  if GetItemInfoInstant then
    local ii = { GetItemInfoInstant(itemID) }
    -- Returns: itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID
    Print(("InfoInstant: type=%s subType=%s equipLoc=%s classID=%s subClassID=%s"):format(
      tostring(ii[2]), tostring(ii[3]), tostring(ii[4]), tostring(ii[6]), tostring(ii[7])
    ))
  end

  -- Use/teach spell mapping
  if GetItemSpell then
    local spellName, spellID = GetItemSpell(itemID)
    if spellID then
      Print(("ItemSpell: %s (%s)"):format(tostring(spellName), tostring(spellID)))
      if IsSpellKnown then
        Print(("IsSpellKnown(%s): %s"):format(tostring(spellID), tostring(IsSpellKnown(spellID))))
      end
      if IsPlayerSpell then
        Print(("IsPlayerSpell(%s): %s"):format(tostring(spellID), tostring(IsPlayerSpell(spellID))))
      end
    else
      Print("ItemSpell: (none)")
    end
  end

  -- Toy mapping
  local toyFromItem
  if C_ToyBox and C_ToyBox.GetToyFromItemID then
    toyFromItem = C_ToyBox.GetToyFromItemID(itemID)
    Print(("ToyBox.GetToyFromItemID: %s"):format(tostring(toyFromItem)))
    if toyFromItem and toyFromItem ~= 0 and PlayerHasToy then
      Print(("PlayerHasToy(%s): %s"):format(tostring(toyFromItem), tostring(PlayerHasToy(toyFromItem))))
    end
  else
    Print("ToyBox: (API not available yet)")
  end

  -- Pet mapping
  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local speciesID = select(13, C_PetJournal.GetPetInfoByItemID(itemID))
    if not speciesID or speciesID == 0 then
      -- Some clients return speciesID as first value; try that too
      speciesID = C_PetJournal.GetPetInfoByItemID(itemID)
      if type(speciesID) ~= "number" then
        speciesID = nil
      end
    end

    Print(("PetJournal speciesID: %s"):format(tostring(speciesID)))
    if speciesID and C_PetJournal.GetNumCollectedInfo then
      local owned = select(1, C_PetJournal.GetNumCollectedInfo(speciesID))
      Print(("GetNumCollectedInfo(%s) owned: %s"):format(tostring(speciesID), tostring(owned)))
    end
  else
    Print("PetJournal: (API not available yet)")
  end

  -- Tooltip truth
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local tip = C_TooltipInfo.GetItemByID(itemID)
    if tip and tip.lines then
      Print("Tooltip lines:")
      local shown = 0
      for _, line in ipairs(tip.lines) do
        local txt = line.leftText or line.rightText
        if txt and txt ~= "" then
          shown = shown + 1
          Print(("  %s"):format(txt))
          if shown >= 25 then
            Print("  (truncated)")
            break
          end
        end
      end
      if shown == 0 then
        Print("  (no text lines)")
      end
    else
      Print("Tooltip: (no data)")
    end
  else
    Print("Tooltip: (C_TooltipInfo not available)")
  end
end
-- /clogunhide [all | <groupId>[,<groupId>...]]
SLASH_CLOGUNHIDE1 = "/clogunhide"
SlashCmdList.CLOGUNHIDE = function(msg)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.ui = CollectionLogDB.ui or {}
  CollectionLogDB.ui.hiddenGroups = CollectionLogDB.ui.hiddenGroups or {}

  msg = (msg or "")
  msg = msg:match("^%s*(.-)%s*$") or ""

  local unhid = 0

  if msg == "" or msg:lower() == "all" then
    for k in pairs(CollectionLogDB.ui.hiddenGroups) do
      CollectionLogDB.ui.hiddenGroups[k] = nil
      unhid = unhid + 1
    end
    Print("Unhid " .. unhid .. " encounter(s).")
  else
    for token in msg:gmatch("[^,%s]+") do
      if CollectionLogDB.ui.hiddenGroups[token] then
        CollectionLogDB.ui.hiddenGroups[token] = nil
        unhid = unhid + 1
      end
    end

    if unhid > 0 then
      Print("Unhid " .. unhid .. " encounter(s).")
    else
      Print("No matching hidden groupId found. Tip: /clogunhide all")
    end
  end

  if ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  if ns.UI and ns.UI.BuildGroupList then
    ns.UI.BuildGroupList()
  end

  if ns.UI and ns.UI.RefreshGrid then
    ns.UI.RefreshGrid()
  end
end



-- Dump Encounter Journal instance metadata for debugging
SLASH_CLOGEJDUMP1 = "/clogejdump"
SlashCmdList.CLOGEJDUMP = function()
  local function Print(msg)
    if ns and ns.Print then
      ns.Print(msg)
    else
      print("|cff00ff99Collection Log|r: " .. tostring(msg))
    end
  end

  Print("=== Encounter Journal Dump ===")

  local ej = _G.EncounterJournal
  local instanceID = ej and ej.instanceID or nil
  Print(("EncounterJournal.instanceID = %s"):format(tostring(instanceID)))

  if EJ_GetInstanceInfo then
    local ok, a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12 =
      pcall(EJ_GetInstanceInfo)
    Print("EJ_GetInstanceInfo() returns:")
    Print(("  1=%s 2=%s 3=%s 4=%s 5=%s 6=%s"):format(
      tostring(a1), tostring(a2), tostring(a3),
      tostring(a4), tostring(a5), tostring(a6)
    ))
    Print(("  7=%s 8=%s 9=%s 10=%s 11=%s 12=%s"):format(
      tostring(a7), tostring(a8), tostring(a9),
      tostring(a10), tostring(a11), tostring(a12)
    ))
  else
    Print("EJ_GetInstanceInfo() not available")
  end

  if EJ_GetInstanceInfo and instanceID then
    local ok, b1,b2,b3,b4,b5,b6,b7,b8,b9,b10,b11,b12 =
      pcall(EJ_GetInstanceInfo, instanceID)
    Print(("EJ_GetInstanceInfo(%s) returns:"):format(tostring(instanceID)))
    Print(("  1=%s 2=%s 3=%s 4=%s 5=%s 6=%s"):format(
      tostring(b1), tostring(b2), tostring(b3),
      tostring(b4), tostring(b5), tostring(b6)
    ))
    Print(("  7=%s 8=%s 9=%s 10=%s 11=%s 12=%s"):format(
      tostring(b7), tostring(b8), tostring(b9),
      tostring(b10), tostring(b11), tostring(b12)
    ))
  end

  if C_EncounterJournal and C_EncounterJournal.GetInstanceInfo and instanceID then
    local ok, info = pcall(C_EncounterJournal.GetInstanceInfo, instanceID)
    Print("C_EncounterJournal.GetInstanceInfo(instanceID) returns:")
    if ok and type(info) == "table" then
      for k, v in pairs(info) do
        Print(("  %s = %s"):format(tostring(k), tostring(v)))
      end
    else
      Print(("  %s"):format(tostring(info)))
    end
  else
    Print("C_EncounterJournal.GetInstanceInfo not available")
  end

  local encCount = 0
  if EJ_GetNumEncounters then
    local ok, n = pcall(EJ_GetNumEncounters)
    if ok then encCount = n or 0 end
  end
  Print(("EJ_GetNumEncounters() = %d"):format(encCount))

  if EJ_GetInstanceByIndex then
    local inRaidList = false
    local inDungeonList = false

    local i = 1
    while true do
      local ok, id = pcall(EJ_GetInstanceByIndex, i, true)
      if not ok or not id then break end
      if id == instanceID then
        inRaidList = true
        break
      end
      i = i + 1
    end

    i = 1
    while true do
      local ok, id = pcall(EJ_GetInstanceByIndex, i, false)
      if not ok or not id then break end
      if id == instanceID then
        inDungeonList = true
        break
      end
      i = i + 1
    end

    Print(("Appears in Raid list: %s"):format(tostring(inRaidList)))
    Print(("Appears in Dungeon list: %s"):format(tostring(inDungeonList)))
  else
    Print("EJ_GetInstanceByIndex not available")
  end

  Print("=== End Dump ===")
end


-- ============================================================================
-- Debug: dump stored Encounter Journal links for a group / item
-- Usage:
--   /cloglinks ej:1302:16
--   /cloglinks item 212397
-- ============================================================================
SLASH_CLOGLINKS1 = "/cloglinks"
SlashCmdList["CLOGLINKS"] = function(msg)
  msg = (msg or ""):gsub("^%s+",""):gsub("%s+$","")
  if msg == "" then
    Print("Usage: /cloglinks <groupId>  OR  /cloglinks item <itemID>")
    return
  end

  local function dumpGroup(gid, g)
    Print("Group " .. tostring(gid) .. "  title=" .. tostring(g.title) .. "  instanceID=" .. tostring(g.instanceID) .. "  difficultyID=" .. tostring(g.difficultyID))
    if not g.itemLinks then
      Print("  itemLinks: (none)")
      return
    end
    local n = 0
    for itemID, link in pairs(g.itemLinks) do
      if type(itemID) == "number" then
        n = n + 1
        if type(link) == "table" then
          Print("  itemID=" .. itemID .. " links=" .. #link)
          for i, L in ipairs(link) do
            Print("    ["..i.."] " .. tostring(L))
          end
        else
          Print("  itemID=" .. itemID .. " link=" .. tostring(link))
        end
      end
    end
    if n == 0 then Print("  itemLinks: (empty)") end
  end

  local words = {}
  for w in msg:gmatch("%S+") do words[#words+1]=w end

  if words[1] == "item" and words[2] then
    local want = tonumber(words[2])
    if not want then Print("Invalid itemID.") return end
    local found = 0
    for gid, g in pairs(ns.Data and ns.Data.groups or {}) do
      if g.itemLinks and g.itemLinks[want] then
        dumpGroup(gid, g)
        found = found + 1
      end
    end
    if found == 0 then Print("No groups contain itemID " .. want .. " in itemLinks.") end
    return
  end

  local gid = msg
  local g = ns.Data and ns.Data.groups and ns.Data.groups[gid]
  if not g then
    Print("Group not found: " .. tostring(gid))
    return
  end
  dumpGroup(gid, g)
end
