-- CollectionLog_HousingCatalog.lua
-- Blizzard-native Housing catalog + collected detection (no inference)
local ADDON, ns = ...

local HOUSING_CACHE_SCHEMA = 4

ns.HousingCatalog = ns.HousingCatalog or {
  built = false,
  building = false,
  ticker = nil,
}

local function SafeCall(fn, ...)
  if type(fn) ~= "function" then return end
  local ok, err = pcall(fn, ...)
  if not ok then
    -- Avoid hard errors during login. Print only if CollectionLog debug is enabled.
    if ns and ns.Print then
      ns.Print("HousingCatalog error: " .. tostring(err))
    end
  end
end

-- Canonical expansion ordering (newest -> oldest)
local EXPANSION_ORDER = {
  ["Midnight"] = 1,
  ["The War Within"] = 2,
  ["Dragonflight"] = 3,
  ["Shadowlands"] = 4,
  ["Battle for Azeroth"] = 5,
  ["Legion"] = 6,
  ["Warlords of Draenor"] = 7,
  ["Mists of Pandaria"] = 8,
  ["Cataclysm"] = 9,
  ["Wrath of the Lich King"] = 10,
  ["The Burning Crusade"] = 11,
  ["Classic"] = 12,
  ["Vanilla"] = 12,
}

local function ExpansionRank(name)
  if not name or name == "" then return 999 end
  return EXPANSION_ORDER[name] or 999
end

local function StripColors(s)
  if type(s) ~= "string" then return "" end
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
  s = s:gsub("|r", "")
  s = s:gsub("|n", " ")
  -- strip links: |H...|hText|h -> Text
  s = s:gsub("|H.-|h(.-)|h", "%1")
  return s
end

local function ClassifySource(sourceText)
  local s = string.lower(StripColors(sourceText or ""))
  if s == "" then return "Other" end

  if s:find("quest:", 1, true) then return "Quest" end
  if s:find("achievement:", 1, true) then return "Achievement" end
  if s:find("profession:", 1, true) then return "Profession" end
  if s:find("vendor:", 1, true) then return "Vendor" end
  if s:find("drop:", 1, true) or s:find("dropped", 1, true) then return "Drop" end
  if s:find("renown", 1, true) then return "Renown" end
  if s:find("reputation", 1, true) then return "Reputation" end
  if s:find("currency:", 1, true) then return "Currency" end
  return "Other"
end


local function GetItemEraExpansionName(itemID)
  if not itemID or itemID <= 0 then return nil end
  if type(GetItemInfo) ~= "function" then return nil end
  local expacID = select(15, GetItemInfo(itemID))
  if type(expacID) ~= "number" then return nil end

  -- Map Blizzard expacIDs to display names (best-effort; unknown/new IDs fall back to "Midnight")
  local map = {
    [0] = "Classic",
    [1] = "The Burning Crusade",
    [2] = "Wrath of the Lich King",
    [3] = "Cataclysm",
    [4] = "Mists of Pandaria",
    [5] = "Warlords of Draenor",
    [6] = "Legion",
    [7] = "Battle for Azeroth",
    [8] = "Shadowlands",
    [9] = "Dragonflight",
    [10] = "The War Within",
    [11] = "Midnight",
  }
  return map[expacID] or (expacID > 11 and "Midnight" or nil)
end

local function DetectExpansionFromSourceText(sourceText)
  local s = string.lower(StripColors(sourceText or ""))
  if s == "" then return nil end

  -- Strong signals first
  if s:find("venthyr", 1, true) or s:find("kyrian", 1, true) or s:find("night fae", 1, true) or s:find("necrolord", 1, true)
     or s:find("reservoir anima", 1, true) then
    return "Shadowlands"
  end
  if s:find("draenor", 1, true) or s:find("warlords", 1, true) then return "Warlords of Draenor" end
  if s:find("legion", 1, true) then return "Legion" end
  if s:find("battle for azeroth", 1, true) or s:find("kul tiras", 1, true) or s:find("zandalar", 1, true) then
    return "Battle for Azeroth"
  end
  if s:find("dragonflight", 1, true) then return "Dragonflight" end
  if s:find("the war within", 1, true) then return "The War Within" end
  if s:find("midnight", 1, true) then return "Midnight" end
  if s:find("pandaria", 1, true) then return "Mists of Pandaria" end
  if s:find("cataclysm", 1, true) then return "Cataclysm" end
  if s:find("lich king", 1, true) or s:find("northrend", 1, true) then return "Wrath of the Lich King" end
  if s:find("outland", 1, true) or s:find("burning crusade", 1, true) then return "The Burning Crusade" end

  return nil
end

local function DetectExpansionTag(dataTagsByID, itemID, sourceText)
  -- Expansion tags in HousingCatalog are sometimes "feature tags" (e.g., many items carry "Midnight")
  -- so we:
  --  1) Collect explicit expansion-tag candidates from dataTags
  --  2) If multiple expansions exist, ignore "Midnight" unless it's the only one
  --  3) If only "Midnight" is present, validate via item-era or sourceText fallback
  --  4) If no tag match, fall back to sourceText then item-era
  local candidates = {}
  if type(dataTagsByID) == "table" then
    for _, tag in pairs(dataTagsByID) do
      if type(tag) == "string" and EXPANSION_ORDER[tag] then
        candidates[tag] = true
      end
    end
  end

  local count = 0
  for _ in pairs(candidates) do count = count + 1 end

  if count > 1 and candidates["Midnight"] then
    candidates["Midnight"] = nil
    count = count - 1
  end

  local bestName, bestRank = nil, 999
  for tag in pairs(candidates) do
    local r = ExpansionRank(tag)
    if r < bestRank then
      bestRank = r
      bestName = tag
    end
  end

  -- If only "Midnight" tag exists, validate/fall back
  if bestName == "Midnight" and count == 1 then
    local srcExp = DetectExpansionFromSourceText(sourceText)
    local eraExp = GetItemEraExpansionName(itemID)
    if srcExp and srcExp ~= "Midnight" then return srcExp end
    if eraExp and eraExp ~= "Midnight" then return eraExp end
  end

  if bestName then return bestName end

  -- No tag match: sourceText then item-era
  return DetectExpansionFromSourceText(sourceText) or GetItemEraExpansionName(itemID)
end

local function MakeGroupId(prefix, name)
  name = tostring(name or ""):lower()
  name = name:gsub("%s+", "_")
  name = name:gsub("[^%w_]+", "")
  return prefix .. name
end

local function RegisterHousingPack(groups)
  ns.RegisterPack("housing", {
    version = 4,
    groups = groups,
  })
end

-- Build Housing groups from Blizzard C_HousingCatalog.
-- Option A: build every session (dynamic). We do it incrementally to avoid hitches.
function ns.BuildHousingCatalogFromBlizzard(force)
  -- Fast path: already built and not forcing
  if ns.HousingCatalog.building then return true end
  if ns.HousingCatalog.built and not force then return true end

  if not C_HousingCatalog
    or type(C_HousingCatalog.GetDecorMaxOwnedCount) ~= "function"
    or type(C_HousingCatalog.GetCatalogEntryInfoByRecordID) ~= "function"
    or not C_Timer
    or type(C_Timer.NewTicker) ~= "function"
  then
    return false
  end

  -- Cache support (avoids the scan on subsequent loads)
  local function GetBuildKey()
    local ok, _, _, _, build = pcall(GetBuildInfo)
    if ok then return tostring(build or "") end
    return ""
  end

  local function ApplyCache(cache)
    if type(cache) ~= "table" then return false end
    if cache.schema ~= HOUSING_CACHE_SCHEMA then return false end
    if cache.buildKey ~= GetBuildKey() then return false end
    if type(cache.groups) ~= "table" then return false end
    if type(cache.decorByItemID) ~= "table" then return false end
    if type(cache.itemIDs) ~= "table" then return false end

    -- NOTE: We intentionally do NOT load any persisted ownership/collected booleans from SavedVariables.
    -- Those values can go stale and would override Blizzard-truth in real time.
    -- We only cache the catalog -> item mapping and the generated groups.
    ns.HousingDecorByItemID = cache.decorByItemID
    ns.HousingItemIDs = cache.itemIDs
    ns.HousingTypeByItemID = type(cache.typeByItemID) == "table" and cache.typeByItemID or {}
    ns.HousingSizeByItemID = type(cache.sizeByItemID) == "table" and cache.sizeByItemID or {}
    ns.HousingUsableByItemID = type(cache.usableByItemID) == "table" and cache.usableByItemID or {}

    -- Session-only truth cache (only store TRUEs as we discover them)
    ns.HousingCollectedByItemID = {}
    ns.HousingOwnedByItemID = ns.HousingCollectedByItemID
    ns.HousingOwnedByRecordID = {}

    RegisterHousingPack(cache.groups)
    ns.HousingCatalog.built = true
    ns.HousingCatalog.building = false

    if ns.RebuildGroupIndex then SafeCall(ns.RebuildGroupIndex) end
    return true
  end

  if not force and CollectionLogDB and CollectionLogDB.housingCatalogCache then
    if ApplyCache(CollectionLogDB.housingCatalogCache) then
      return true
    end
  end

  local maxEntries = 0
  local ok, res = pcall(C_HousingCatalog.GetDecorMaxOwnedCount)
  if ok and type(res) == "number" then maxEntries = res end
  if not maxEntries or maxEntries <= 0 then return false end

  -- recordIDs are not guaranteed to be <= maxEntries. We'll scan beyond it and stop once we've found enough,
  -- but keep an upper bound so we don't scan forever.
  local scanMax = math.floor(maxEntries * 4)
  if scanMax < 5000 then scanMax = 5000 end
  if scanMax > 30000 then scanMax = 30000 end

  ns.HousingCatalog.building = true
  ns.HousingCatalog.built = false

  -- IMPORTANT: During a forced rebuild (Refresh), do NOT wipe the live tables up-front.
  -- Build into temp tables and swap at the end to prevent a blank Housing tab.
  local rebuilding = force and (type(ns.HousingItemIDs) == "table" and next(ns.HousingItemIDs) ~= nil)

  local liveDecorByItemID = ns.HousingDecorByItemID
  local liveItemIDs = ns.HousingItemIDs
  local liveTypeByItemID = ns.HousingTypeByItemID
  local liveOwnedByItemID = ns.HousingOwnedByItemID
  local liveOwnedByRecordID = ns.HousingOwnedByRecordID

  local newDecorByItemID = {}
  local newItemIDs = {}
  local newTypeByItemID = {}
  
  local newSizeByItemID = {}
  local newUsableByItemID = {}
local newOwnedByItemID = {}
  local newOwnedByRecordID = {}
  local newCollectedByItemID = newOwnedByItemID

  local allItems = {}
  local seenItem = {}
  local bySource = {}
  local byExp = {}

  local recordID = 1
  local batchSize = force and 30 or 15
  local tickInterval = force and 0.01 or 0.03

  local consecutiveMiss = 0

  local function addItem(itemID, expName, sourceGroup)
    if not itemID or itemID <= 0 then return end
    if not seenItem[itemID] then
      seenItem[itemID] = true
      table.insert(allItems, itemID)
      newItemIDs[itemID] = true
    end
    if expName and expName ~= "" then
      byExp[expName] = byExp[expName] or {}
      table.insert(byExp[expName], itemID)
    end
    if sourceGroup and sourceGroup ~= "" then
      bySource[sourceGroup] = bySource[sourceGroup] or {}
      table.insert(bySource[sourceGroup], itemID)
    end
  end

  local function FinishBuild()
    -- Swap into live
    ns.HousingDecorByItemID = newDecorByItemID
    ns.HousingItemIDs = newItemIDs
    ns.HousingTypeByItemID = newTypeByItemID
    ns.HousingSizeByItemID = newSizeByItemID
    ns.HousingUsableByItemID = newUsableByItemID
    ns.HousingCollectedByItemID = newCollectedByItemID
    ns.HousingOwnedByItemID = newOwnedByItemID
    ns.HousingOwnedByRecordID = newOwnedByRecordID

    -- Build groups
    local groups = {}

    table.insert(groups, {
      category = "Housing",
      expansion = "Account",
      sortTier = 1,
      sortIndex = 1,
      name = "All Housing",
      id = "housing:all",
      items = allItems,
    })

    local sourceOrder = { "Quest", "Achievement", "Profession", "Vendor", "Drop", "Renown", "Reputation", "Currency", "Other" }
    local sidx = 1
    for _, sname in ipairs(sourceOrder) do
      local items = bySource[sname]
      if type(items) == "table" and #items > 0 then
        table.insert(groups, {
          category = "Housing",
          expansion = "Source",
          sortTier = 2,
          sortIndex = sidx,
          name = sname,
          id = MakeGroupId("housing:source:", sname),
          items = items,
        })
        sidx = sidx + 1
      end
    end

    local expNames = {}
    for expName in pairs(byExp) do
      table.insert(expNames, expName)
    end
    table.sort(expNames, function(a, b)
      local ra, rb = ExpansionRank(a), ExpansionRank(b)
      if ra == rb then return tostring(a) < tostring(b) end
      return ra < rb
    end)

    local eidx = 1
    for _, expName in ipairs(expNames) do
      local items = byExp[expName]
      if type(items) == "table" and #items > 0 then
        table.insert(groups, {
          category = "Housing",
          expansion = expName,
          sortTier = 3,
          sortIndex = ExpansionRank(expName) ~= 999 and ExpansionRank(expName) or (200 + eidx),
          name = expName,
          id = MakeGroupId("housing:exp:", expName),
          items = items,
        })
        eidx = eidx + 1
      end
    end

    RegisterHousingPack(groups)

    -- Save cache for next load
    if CollectionLogDB then
      CollectionLogDB.housingCatalogCache = {
        schema = HOUSING_CACHE_SCHEMA,
        buildKey = GetBuildKey(),
        groups = groups,
        decorByItemID = newDecorByItemID,
        itemIDs = newItemIDs,
        typeByItemID = newTypeByItemID,
        sizeByItemID = newSizeByItemID,
        usableByItemID = newUsableByItemID,
      }
    end

    ns.HousingCatalog.built = true
    ns.HousingCatalog.building = false

    if ns.RebuildGroupIndex then SafeCall(ns.RebuildGroupIndex) end
    if ns.UI then
      if ns.UI.BuildGroupList then SafeCall(ns.UI.BuildGroupList) end
      if ns.UI.RefreshGrid then SafeCall(ns.UI.RefreshGrid) end
      if ns.UI.RefreshAll then SafeCall(ns.UI.RefreshAll) end
    end
  end

  local function tick()
    local processed = 0
    while processed < batchSize and recordID <= scanMax do
      local rid = recordID
      recordID = recordID + 1
      processed = processed + 1

      local ok2, info = pcall(C_HousingCatalog.GetCatalogEntryInfoByRecordID, 1, rid, true)
      if ok2 and type(info) == "table" then
        local itemID = tonumber(info.itemID or 0) or 0
        if itemID > 0 then
          consecutiveMiss = 0

          newDecorByItemID[itemID] = rid

          local typeName
          local owned = false
          -- Full Blizzard-native ownership rule (covers non-destroyable / redeemable / placed decor).
          do
            local c = 0
            for k, v in pairs(info) do
              if type(k) == "string" and k:find("InstanceCount") and type(v) == "number" and v > 0 then
                c = c + v
              end
            end
            if c > 0 then owned = true end
            if not owned and type(info.destroyableInstanceCount) == "number" and info.destroyableInstanceCount > 0 then owned = true end
            if not owned and type(info.quantity) == "number" and info.quantity > 0 then owned = true end
            if not owned and type(info.remainingRedeemable) == "number" and info.remainingRedeemable > 0 then owned = true end
            if not owned and type(info.numPlaced) == "number" and info.numPlaced > 0 then owned = true end
          end
          if owned then newOwnedByItemID[itemID] = true end
          if owned then newOwnedByRecordID[rid] = true end

          local typeName
          if type(C_HousingCatalog.GetCatalogCategoryInfo) == "function" and type(info.categoryIDs) == "table" then
            local catID = info.categoryIDs[1]
            if catID then
              local okc, cinfo = pcall(C_HousingCatalog.GetCatalogCategoryInfo, catID)
              if okc and type(cinfo) == "table" then
                typeName = cinfo.name or cinfo.displayName or cinfo.text
              end
            end
          end
          if typeName and typeName ~= "" then
            newTypeByItemID[itemID] = typeName
          end

          -- Extra tooltip metadata (omit if missing)
          if type(info.size) == "number" then
            newSizeByItemID[itemID] = info.size
          end
          local indoors = info.isAllowedIndoors
          local outdoors = info.isAllowedOutdoors
          if indoors ~= nil or outdoors ~= nil then
            local usable
            if indoors and outdoors then usable = "Indoors/Outdoors"
            elseif indoors then usable = "Indoors"
            elseif outdoors then usable = "Outdoors"
            end
            if usable then
              newUsableByItemID[itemID] = usable
            end
          end

          local expName = DetectExpansionTag(info.dataTagsByID, itemID, info.sourceText) or "Unknown"
          local sourceGroup = ClassifySource(info.sourceText)

          addItem(itemID, expName, sourceGroup)
        else
          consecutiveMiss = consecutiveMiss + 1
        end
      else
        consecutiveMiss = consecutiveMiss + 1
      end
    end

    -- Early stop: once we've found a lot of items, stop after a long dry spell
    if consecutiveMiss >= 2000 and #allItems >= 800 then
      recordID = scanMax + 1
    end

    if recordID > scanMax or (#allItems >= maxEntries and maxEntries > 0) then
      if ns.HousingCatalog.ticker then
        ns.HousingCatalog.ticker:Cancel()
        ns.HousingCatalog.ticker = nil
      end
      FinishBuild()
    end
  end

  if ns.HousingCatalog.ticker then
    ns.HousingCatalog.ticker:Cancel()
  end
  ns.HousingCatalog.ticker = C_Timer.NewTicker(tickInterval, tick)

  return true
end

local function IsOwnedFromCatalogInfo(info)
  if ns and ns.IsHousingOwnedFromCatalogInfo then
    return ns.IsHousingOwnedFromCatalogInfo(info)
  end
  return false
end
