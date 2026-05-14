
local ADDON, ns = ...

ns.AppearanceRuntime = ns.AppearanceRuntime or {}
local AR = ns.AppearanceRuntime
local DATA = ns.AppearanceCanonicalData or { sets = {}, groupNames = {} }

local function normalizeSetKey(name, classMask)
  name = tostring(name or "Unknown Set")
  classMask = tonumber(classMask or 0) or 0
  return name .. "||" .. tostring(classMask)
end

local function band(a, b)
  if bit and bit.band then return bit.band(a, b) end
  if bit32 and bit32.band then return bit32.band(a, b) end
  return 0
end

AR.CLASS_ORDER = {
  "ALL",
  "WARRIOR",
  "PALADIN",
  "HUNTER",
  "ROGUE",
  "PRIEST",
  "DEATHKNIGHT",
  "SHAMAN",
  "MAGE",
  "WARLOCK",
  "MONK",
  "DRUID",
  "DEMONHUNTER",
  "EVOKER",
}

AR.CLASS_LABELS = {
  ALL = "All Classes",
  WARRIOR = "Warrior",
  PALADIN = "Paladin",
  HUNTER = "Hunter",
  ROGUE = "Rogue",
  PRIEST = "Priest",
  DEATHKNIGHT = "Death Knight",
  SHAMAN = "Shaman",
  MAGE = "Mage",
  WARLOCK = "Warlock",
  MONK = "Monk",
  DRUID = "Druid",
  DEMONHUNTER = "Demon Hunter",
  EVOKER = "Evoker",
}

AR.CLASS_MASKS = {
  WARRIOR = 0x1,
  PALADIN = 0x2,
  HUNTER = 0x4,
  ROGUE = 0x8,
  PRIEST = 0x10,
  DEATHKNIGHT = 0x20,
  SHAMAN = 0x40,
  MAGE = 0x80,
  WARLOCK = 0x100,
  MONK = 0x200,
  DRUID = 0x400,
  DEMONHUNTER = 0x800,
  EVOKER = 0x1000,
}

AR.SLOT_ORDER = { 1, 3, 5, 20, 9, 10, 6, 7, 8, 15, 16, 17, 19 }
AR.SLOT_LABELS = {
  [1] = "Head",
  [3] = "Shoulder",
  [5] = "Chest",
  [6] = "Waist",
  [7] = "Legs",
  [8] = "Feet",
  [9] = "Wrist",
  [10] = "Hands",
  [15] = "Back",
  [16] = "Main Hand",
  [17] = "Off Hand",
  [19] = "Tabard",
  [20] = "Chest",
}

local EQUIPLOC_TO_SLOT = {
  INVTYPE_HEAD = 1,
  INVTYPE_SHOULDER = 3,
  INVTYPE_BODY = 20,
  INVTYPE_CHEST = 5,
  INVTYPE_ROBE = 5,
  INVTYPE_WAIST = 6,
  INVTYPE_LEGS = 7,
  INVTYPE_FEET = 8,
  INVTYPE_WRIST = 9,
  INVTYPE_HAND = 10,
  INVTYPE_CLOAK = 15,
  INVTYPE_WEAPON = 16,
  INVTYPE_2HWEAPON = 16,
  INVTYPE_WEAPONMAINHAND = 16,
  INVTYPE_SHIELD = 17,
  INVTYPE_HOLDABLE = 17,
  INVTYPE_WEAPONOFFHAND = 17,
  INVTYPE_RANGED = 16,
  INVTYPE_RANGEDRIGHT = 16,
  INVTYPE_THROWN = 16,
  INVTYPE_RELIC = 17,
  INVTYPE_TABARD = 19,
}

local function getPlayerClassToken()
  local _, classToken = UnitClass("player")
  if classToken == "DRACTHYR" then classToken = "EVOKER" end
  return classToken or "ALL"
end

function ns.GetAppearanceClassFilter()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.ui = CollectionLogDB.ui or {}
  local token = CollectionLogDB.ui.appearanceClassFilter
  if not token or token == "" then
    token = getPlayerClassToken()
    CollectionLogDB.ui.appearanceClassFilter = token
  end
  return token
end

function ns.SetAppearanceClassFilter(token)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.ui = CollectionLogDB.ui or {}
  if token == "DRACTHYR" then token = "EVOKER" end
  CollectionLogDB.ui.appearanceClassFilter = token or "ALL"
  AR.groupCache = nil
  AR.renderCache = {}
  AR.nameCache = nil
  AR.catalogCache = nil
end

function ns.ClearAppearanceCaches()
  AR.groupCache = nil
  AR.renderCache = {}
  AR.nameCache = nil
  AR.catalogCache = nil
end

local function setMatchesClass(info, token)
  if token == "ALL" then return true end
  local mask = AR.CLASS_MASKS[token]
  if not mask then return true end
  local classMask = tonumber(info.classMask or 0) or 0
  if classMask == 0 then return true end
  return band(classMask, mask) ~= 0
end

local function buildRuntimeNameCache()
  if AR.nameCache then return AR.nameCache end
  AR.nameCache = {}
  if C_TransmogSets and C_TransmogSets.GetAllSets then
    local ok, sets = pcall(C_TransmogSets.GetAllSets)
    if ok and type(sets) == "table" then
      for _, info in ipairs(sets) do
        if type(info) == "table" and tonumber(info.setID) then
          local sid = tonumber(info.setID)
          if sid then
            AR.nameCache[sid] = info.name or info.label or info.description
          end
        end
      end
    end
  end
  return AR.nameCache
end

local function fallbackSetName(setID, info)
  local classMask = tonumber(info.classMask or 0) or 0
  if classMask ~= 0 then
    for token, mask in pairs(AR.CLASS_MASKS) do
      if mask == classMask then
        local label = AR.CLASS_LABELS[token] or token
        local groupName = DATA.groupNames and DATA.groupNames[tonumber(info.groupID or 0) or 0]
        if type(groupName) == "string" and groupName ~= "" then
          return groupName .. " - " .. label
        end
        return label .. " Set " .. tostring(setID)
      end
    end
  end
  local groupName = DATA.groupNames and DATA.groupNames[tonumber(info.groupID or 0) or 0]
  if type(groupName) == "string" and groupName ~= "" then
    return groupName .. " (" .. tostring(setID) .. ")"
  end
  return "Set " .. tostring(setID)
end


local function isJunkSetName(name)
  if type(name) ~= "string" then return true end
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" or name == "-" then return true end
  if name:match("^Set%s+%d+$") then return true end
  if name:match("^<.*>$") or name:find("<DNT>", 1, true) then return true end
  return false
end

local function bestVisibleSetName(rawSetID, info)
  local raw = type(info.name) == "string" and info.name or nil
  if raw and raw ~= "" and not isJunkSetName(raw) then return raw end
  local cache = buildRuntimeNameCache()
  local runtime = cache and cache[tonumber(rawSetID)]
  if type(runtime) == "string" and runtime ~= "" and not isJunkSetName(runtime) then return runtime end
  local fb = fallbackSetName(rawSetID, info)
  if isJunkSetName(fb) then return nil end
  return fb
end

local function buildVisibleCatalog()
  local filterToken = ns.GetAppearanceClassFilter()
  AR.catalogCache = AR.catalogCache or {}
  if AR.catalogCache[filterToken] then return AR.catalogCache[filterToken] end

  local byKey, ordered = {}, {}
  for rawSetID, info in pairs(DATA.sets or {}) do
    if setMatchesClass(info, filterToken) then
      local name = bestVisibleSetName(rawSetID, info)
      if not name then
        -- hide internal/placeholder rows with no user-facing name
      else
      local classMask = tonumber(info.classMask or 0) or 0
      local key = normalizeSetKey(name, classMask)
      local row = byKey[key]
      if not row then
        row = {
          key = key,
          setID = key,
          name = name,
          classMask = classMask,
          sortIndex = tonumber(info.uiOrder or rawSetID) or 999999,
          rawSetIDs = {},
        }
        byKey[key] = row
        ordered[#ordered + 1] = row
      end
      row.rawSetIDs[#row.rawSetIDs + 1] = tonumber(rawSetID) or rawSetID
      local order = tonumber(info.uiOrder or rawSetID) or 999999
      if order < row.sortIndex then row.sortIndex = order end
      end
    end
  end

  table.sort(ordered, function(a,b)
    local ia, ib = tonumber(a.sortIndex or 999999) or 999999, tonumber(b.sortIndex or 999999) or 999999
    if ia ~= ib then return ia < ib end
    return tostring(a.name or a.key) < tostring(b.name or b.key)
  end)

  local catalog = { byKey = byKey, ordered = ordered }
  AR.catalogCache[filterToken] = catalog
  return catalog
end

local function resolveSetInfo(setID)
  if type(setID) == "string" then
    local catalog = buildVisibleCatalog()
    local row = catalog and catalog.byKey and catalog.byKey[setID]
    if row then return row, row.rawSetIDs end
  end
  local nset = tonumber(setID)
  if nset and DATA.sets and DATA.sets[nset] then
    return DATA.sets[nset], { nset }
  end
  return nil, nil
end

function ns.GetAppearanceSetDisplayName(setID)
  if type(setID) == "string" then
    local catalog = buildVisibleCatalog()
    local row = catalog and catalog.byKey and catalog.byKey[setID]
    if row and row.name then return row.name end
    return "Unknown Set"
  end

  setID = tonumber(setID)
  if not setID then return "Unknown Set" end
  local info = DATA.sets and DATA.sets[setID]
  if not info then return "Set " .. tostring(setID) end

  local raw = info.name
  if type(raw) == "string" and raw ~= "" then
    return raw
  end

  local cache = buildRuntimeNameCache()
  local runtime = cache and cache[setID]
  if type(runtime) == "string" and runtime ~= "" then
    return runtime
  end

  return fallbackSetName(setID, info)
end

local function getEntrySlot(itemID)
  if not itemID or itemID <= 0 then return 999, "" end
  local equipLoc = select(4, GetItemInfoInstant(itemID))
  local slot = EQUIPLOC_TO_SLOT[equipLoc]
  if not slot and C_Item and C_Item.GetItemInventoryTypeByID then
    local ok, invType = pcall(C_Item.GetItemInventoryTypeByID, itemID)
    if ok and invType and invType > 0 then slot = invType end
  end
  slot = tonumber(slot) or 999
  return slot, AR.SLOT_LABELS[slot] or ""
end

function ns.IsAppearanceSetPieceCollected(entry)
  if type(entry) ~= "table" then return false end

  if type(entry.modIDs) == "table" and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    for _, modID in ipairs(entry.modIDs) do
      modID = tonumber(modID)
      if modID and modID > 0 then
        local ok, known = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, modID)
        if ok and known then return true end
        if C_TransmogCollection.GetAppearanceSourceInfo then
          local ok2, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, modID)
          if ok2 and info and info.isCollected then return true end
        end
      end
    end
  end

  if ns and ns.UseStrictAppearanceCollection and ns.UseStrictAppearanceCollection() then
    if ns.GetAppearanceOwnershipState and tonumber(entry.itemID or 0) > 0 then
      local ok, state = pcall(ns.GetAppearanceOwnershipState, tonumber(entry.itemID))
      if ok and type(state) == "table" and state.exactSourceOwned == true then return true end
    end
    return false
  end

  local appearanceID = tonumber(entry.appearanceID or 0) or 0
  if appearanceID > 0 and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemAppearance then
    local ok, known = pcall(C_TransmogCollection.PlayerHasTransmogItemAppearance, appearanceID)
    if ok and known then return true end
  end

  if ns and ns.HasCollectedAppearance and tonumber(entry.itemID or 0) > 0 then
    local ok, known = pcall(ns.HasCollectedAppearance, tonumber(entry.itemID))
    if ok and known then return true end
  end

  return false
end

function ns.GetAppearanceSetEntries(setID)
  local cacheKey = tostring(setID)
  AR.renderCache = AR.renderCache or {}
  local cached = AR.renderCache[cacheKey]
  if cached then return cached.entries, cached.collected, cached.total end

  local info, rawSetIDs = resolveSetInfo(setID)
  if not info then
    AR.renderCache[cacheKey] = { entries = {}, collected = 0, total = 0 }
    return {}, 0, 0
  end

  local sourceSetIDs = rawSetIDs
  if type(setID) == "string" then
    local catalog = buildVisibleCatalog()
    local row = catalog and catalog.byKey and catalog.byKey[setID]
    if row and row.primaryRawSetID then
      sourceSetIDs = { row.primaryRawSetID }
    end
  end
  if type(sourceSetIDs) ~= "table" then
    sourceSetIDs = {}
  end

  local mergedByAppearance = {}
  local entries, collected = {}, 0
  for _, rawSetID in ipairs(sourceSetIDs) do
    local rawInfo = DATA.sets and DATA.sets[tonumber(rawSetID)]
    if rawInfo and type(rawInfo.entries) == "table" then
      for _, raw in ipairs(rawInfo.entries) do
        local appearanceID = tonumber(raw.appearanceID or 0) or 0
        local itemID = tonumber(raw.itemID or 0) or 0
        local key = appearanceID > 0 and appearanceID or ("item:" .. tostring(itemID))
        local entry = mergedByAppearance[key]
        if not entry then
          entry = { appearanceID = appearanceID, itemID = itemID, modIDs = {} }
          mergedByAppearance[key] = entry
          entries[#entries + 1] = entry
        elseif (not entry.itemID or entry.itemID <= 0) and itemID > 0 then
          entry.itemID = itemID
        end
        if type(raw.modIDs) == "table" then
          entry.modIDsSeen = entry.modIDsSeen or {}
          for _, mid in ipairs(raw.modIDs) do
            mid = tonumber(mid)
            if mid and mid > 0 and not entry.modIDsSeen[mid] then
              entry.modIDsSeen[mid] = true
              entry.modIDs[#entry.modIDs + 1] = mid
            end
          end
        end
      end
    end
  end

  local collapsed, seen = {}, {}
  for _, entry in ipairs(entries) do
    entry.modIDsSeen = nil
    local slot, label = getEntrySlot(entry.itemID)
    entry.slot = slot
    entry.label = label
    entry.isCollected = ns.IsAppearanceSetPieceCollected(entry)
    local equipLoc = (entry.itemID and select(4, GetItemInfoInstant(entry.itemID))) or ""
    local weaponLike = (slot == 16 or slot == 17)
    local visibleKey
    if weaponLike then
      visibleKey = table.concat({ tostring(slot), tostring(entry.itemID or 0), tostring(equipLoc or "") }, "||")
    else
      visibleKey = table.concat({ tostring(slot), tostring(entry.appearanceID or 0) }, "||")
    end
    local existing = seen[visibleKey]
    if not existing then
      seen[visibleKey] = entry
      collapsed[#collapsed + 1] = entry
    else
      if (not existing.isCollected and entry.isCollected) or ((not existing.itemID or existing.itemID <= 0) and (entry.itemID or 0) > 0) then
        seen[visibleKey] = entry
        for i, v in ipairs(collapsed) do if v == existing then collapsed[i] = entry break end end
      end
    end
  end
  entries = collapsed
  collected = 0
  for _, entry in ipairs(entries) do if entry.isCollected then collected = collected + 1 end end

  table.sort(entries, function(a, b)
    local sa, sb = tonumber(a.slot or 999) or 999, tonumber(b.slot or 999) or 999
    if sa ~= sb then return sa < sb end
    local ia, ib = tonumber(a.itemID or 0) or 0, tonumber(b.itemID or 0) or 0
    if ia ~= ib then return ia < ib end
    return (tonumber(a.appearanceID or 0) or 0) < (tonumber(b.appearanceID or 0) or 0)
  end)

  -- Assign difficulty labels only when the slot clearly looks like a standard
  -- 4-tier bundle (typically LFR/Normal/Heroic/Mythic). Keep this conservative.
  local bySlot = {}
  for _, entry in ipairs(entries) do
    local slot = tonumber(entry.slot or 999) or 999
    bySlot[slot] = bySlot[slot] or {}
    table.insert(bySlot[slot], entry)
  end
  local fourTier = { "LFR", "Normal", "Heroic", "Mythic" }
  for slot, slotEntries in pairs(bySlot) do
    local weaponLike = (slot == 16 or slot == 17)
    if (not weaponLike) and #slotEntries == 4 then
      table.sort(slotEntries, function(a, b)
        return (tonumber(a.appearanceID or 0) or 0) < (tonumber(b.appearanceID or 0) or 0)
      end)
      for i, entry in ipairs(slotEntries) do
        entry.variantLabel = fourTier[i]
      end
    end
  end

  local total = #entries
  AR.renderCache[cacheKey] = { entries = entries, collected = collected, total = total }
  return entries, collected, total
end

function ns.GetAppearanceSetProgress(setID)
  local _, collected, total = ns.GetAppearanceSetEntries(setID)
  return collected, total
end

function ns.EnsureAppearanceSetGroups()
  local catalog = buildVisibleCatalog()
  local groups = {}

  for _, row in ipairs(catalog.ordered or {}) do
    groups[#groups + 1] = {
      id = "appearance:set:" .. tostring(row.key),
      name = row.name,
      category = "Appearances",
      expansion = "Sets",
      sortIndex = row.sortIndex,
      setID = row.key,
      classMask = row.classMask,
      items = {},
    }
  end

  ns.RegisterPack("appearance_runtime", { version = 4, groups = groups })
  if ns.RebuildGroupIndex then ns.RebuildGroupIndex() end
end

