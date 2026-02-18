-- CollectionLog_Importer_Mounts.lua
local ADDON, ns = ...

-- Minimal, Blizzard-truthful Mounts group.
-- Collectible identity: mountID (C_MountJournal)

local function EnsureCollectionsLoaded()
  if C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID then
    return true
  end
  pcall(LoadAddOn, "Blizzard_Collections")
  return true
end

local function UpsertGeneratedGroup(group)
  if not CollectionLogDB then return end
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups

  for i = #list, 1, -1 do
    if list[i] and list[i].id == group.id then
      list[i] = group
      return
    end
  end
  table.insert(list, group)

end
local function PurgeGeneratedGroupsForCategory(cat)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups
  for i = #list, 1, -1 do
    local g = list[i]
    if g and (g.category == cat or (cat == "Mounts" and type(g.id)=="string" and g.id:find("^mounts:"))) then
      table.remove(list, i)
    end
  end
end

local SOURCE_TYPE_NAMES = {
  [0] = "Unknown",
  [1] = "Drop",
  [2] = "Quest",
  [3] = "Vendor",
  [4] = "Profession",
  [5] = "Achievement",
  [6] = "World Event",
  [7] = "Promotion",
  [8] = "Store",
  [9] = "Trading Post",
  [10] = "PvP",
}


-- Mounts sidebar order (single canonical list; no duplicates).
-- Lower sortIndex appears higher in the left panel.
local MOUNTS_SIDEBAR_ORDER = {
  ["All Mounts"] = 10,
  ["Drops (All)"] = 20,
  ["Drops (Raid)"] = 30,
  ["Drops (Dungeon)"] = 40,
  ["Drops (Open World)"] = 50,
  ["Drops (Delve)"] = 60,

  ["Achievement"] = 70,
  ["Adventures"] = 75,
  ["Quest"] = 80,
  ["Reputation"] = 90,
  ["Profession"] = 100,
  ["Class"] = 110,
  ["Faction"] = 120,
  ["Race"] = 130,
  ["PvP"] = 140,
  ["Vendor"] = 150,
  ["World Event"] = 160,

  ["Store"] = 170,
  ["Trading Post"] = 180,
  ["Promotion"] = 190,
  ["Secret"] = 200,

  ["Garrison Mission"] = 210,
  ["Covenant Feature"] = 220,
  ["Unobtainable"] = 230,
  ["Uncategorized"] = 240,
}

local function MountSidebarIndex(name)
  if type(name) ~= "string" then return 999 end
  return MOUNTS_SIDEBAR_ORDER[name] or 999
end

-- Canonicalize Mounts group labels so we only ever surface ONE version of each.
-- Any variations are merged and de-duped into the canonical bucket.
local function CanonMountGroupName(name)
  if type(name) ~= "string" then return name end
  local n = name:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
  local l = n:lower()

  -- Exact merges / renames
  if l == "covenant" or l == "covenant feature" then return "Covenant Feature" end
  if l == "garrison" or l == "garrison mission" or l == "garrison misson" then return "Garrison Mission" end
  if l == "vendors" or l == "vendor" then return "Vendor" end

  -- Route noisy/legacy buckets into canonical homes
  if l == "world quest" or l == "world quests" then return "Quest" end

  if l == "source" or l:match("^source%s+%d+") then return "Uncategorized" end
  if l == "item" or l == "location" or l == "npc" or l == "trainer" or l == "treasure" or l == "zone" or l == "area" or l == "discovery" then
    return "Uncategorized"
  end

  -- Keep the rest as-is (with original casing)
  return n
end

local function MergeUniqueMountIDs(dst, src)
  if type(dst) ~= "table" then return end
  if type(src) ~= "table" then return end
  local set = {}
  for _, id in ipairs(dst) do set[tonumber(id)] = true end
  for _, id in ipairs(src) do
    id = tonumber(id)
    if id and not set[id] then
      table.insert(dst, id)
      set[id] = true
    end
  end
  table.sort(dst)
end

-- Add mounts to an existing Mounts group by NAME (canonical), or create it.
-- This prevents duplicate sidebar entries like Achievement/Achievement, Vendors/Vendor, etc.
local function AddToMountsGroupByName(name, mountIDs)
  if not CollectionLogDB then return end
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups

  local canon = CanonMountGroupName(name)
  if type(canon) ~= "string" or canon == "" then return end

  local found = nil
  for _, g in ipairs(list) do
    if g and g.category == "Mounts" and type(g.name) == "string" and CanonMountGroupName(g.name) == canon then
      found = g
      break
    end
  end

  if found then
    found.name = canon
    found.sortIndex = MountSidebarIndex(canon)
    found.expansion = (canon == "All Mounts") and "Account" or "Source"
    found.mounts = found.mounts or {}
    MergeUniqueMountIDs(found.mounts, mountIDs)
    return
  end

  local gid = "mounts:canon:" .. canon:gsub("%s+", "_"):lower()
  UpsertGeneratedGroup({
    id = gid,
    name = canon,
    category = "Mounts",
    expansion = (canon == "All Mounts") and "Account" or "Source",
    mounts = mountIDs or {},
    sortIndex = MountSidebarIndex(canon),
  })
end

local function SourceTypeName(sourceType)
  local n = SOURCE_TYPE_NAMES[tonumber(sourceType or 0)]
  if n then return n end
  return ("Source %s"):format(tostring(sourceType or "?"))
end

local mountFrame

local function NotifyCollectionsUIUpdated(category)
  -- Refresh left panel + grid after a generated pack rebuild, but only if the UI exists.
  if not (ns and ns.UI and ns.UI.frame and ns.UI.frame:IsShown()) then return end
  if ns.UI.BuildGroupList then pcall(ns.UI.BuildGroupList) end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == category then
    if ns.UI.RefreshGrid then pcall(ns.UI.RefreshGrid) end
  end
end

local function EnsureMountsEventFrame()
  if mountFrame then return end
  mountFrame = CreateFrame("Frame")
  mountFrame:SetScript("OnEvent", function(self)
    local ok = ns and ns._TryBuildMountsGroups and ns._TryBuildMountsGroups()
    if ok then
      self:UnregisterAllEvents()
      NotifyCollectionsUIUpdated("Mounts")
    end
  end)
end

function ns._TryBuildMountsGroups()
  EnsureCollectionsLoaded()

  if not (C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID) then
    return nil
  end


  -- Purge any previously generated Mounts groups so rebuilds don't accumulate stale/duplicate groups.
  PurgeGeneratedGroupsForCategory("Mounts")


  -- Normalize Mount Journal filters so we build an account-truthful, stable mount list.
  -- Some players (or other addons) can leave the Mount Journal in a filtered state (search text, collected-only, faction-only),
  -- which can cause 0/0 totals or faction-specific mounts showing as uncollected on the opposite faction.
  local function WithAccountTruthFilters(fn)
    if not (C_MountJournal and type(C_MountJournal.GetMountIDs) == "function") then
      return fn()
    end

    local restore = {}

    local function remember(getterName, setterName, desired)
      local getter = C_MountJournal[getterName]
      local setter = C_MountJournal[setterName]
      if type(getter) == "function" and type(setter) == "function" then
        local ok, cur = pcall(getter)
        if ok then
          restore[#restore+1] = function() pcall(setter, cur) end
          pcall(setter, desired)
        end
      end
    end

    -- Collected/uncollected toggles
    remember("GetCollectedFilterSetting", "SetCollectedFilterSetting", true)
    remember("GetUncollectedFilterSetting", "SetUncollectedFilterSetting", true)

    -- Clear search text if supported
    do
      local getSearch = C_MountJournal.GetSearchString
      local setSearch = C_MountJournal.SetSearch
      if type(getSearch) == "function" and type(setSearch) == "function" then
        local ok, cur = pcall(getSearch)
        if ok and cur and cur ~= "" then
          restore[#restore+1] = function() pcall(setSearch, cur) end
          pcall(setSearch, "")
        end
      end
    end

    -- Try to include all factions if the client exposes a filter for it (name varies across builds).
    -- We only call functions if they exist; no hard dependency.
    do
      local candidates = {
        "SetAllFactionFiltering",
        "SetAllFactionFilter",
        "SetAllFactions",
        "SetIncludeOppositeFaction",
        "SetAllowOppositeFaction",
      }
      for _, fnName in ipairs(candidates) do
        local f = C_MountJournal[fnName]
        if type(f) == "function" then
          -- No reliable getter across builds, so we don't restore this one.
          pcall(f, true)
          break
        end
      end
    end

    local out = fn()

    -- Restore filters we changed
    for i = #restore, 1, -1 do
      pcall(restore[i])
    end

    return out
  end

  local mountIDs = WithAccountTruthFilters(function() return C_MountJournal.GetMountIDs() end)
  if type(mountIDs) ~= "table" or #mountIDs == 0 then
    return nil
  end

  -- Debounce: if we already built recently for the same mount count, do not rebuild again.
  ns._clogMountsBuiltCount = ns._clogMountsBuiltCount or 0
  ns._clogMountsBuiltAt = ns._clogMountsBuiltAt or 0
  local now = (GetTime and GetTime()) or 0
  if ns._clogMountsBuiltCount == #mountIDs and (now - ns._clogMountsBuiltAt) < 5 then
    return true
  end


  -- Cleanup: remove legacy/noisy Mounts groups so rebuild does NOT re-surface old labels.
  -- We keep ONLY the canonical set requested for the Mounts sidebar.
  do
    local allowed = {
      ["All Mounts"] = true,
      ["Drops (All)"] = true,
      ["Drops (Raid)"] = true,
      ["Drops (Dungeon)"] = true,
      ["Drops (Open World)"] = true,
      ["Drops (Delve)"] = true,
      ["Achievement"] = true,
      ["Adventures"] = true,
      ["Quest"] = true,
      ["Reputation"] = true,
      ["Profession"] = true,
      ["Class"] = true,
      ["Faction"] = true,
      ["Race"] = true,
      ["PvP"] = true,
      ["Vendor"] = true,
      ["World Event"] = true,
      ["Store"] = true,
      ["Trading Post"] = true,
      ["Promotion"] = true,
      ["Secret"] = true,
      ["Covenant Feature"] = true,
      ["Garrison Mission"] = true,
      ["Unobtainable"] = true,
      ["Uncategorized"] = true,
    }

    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      local list = CollectionLogDB.generatedPack.groups
      for i = #list, 1, -1 do
        local g = list[i]
        if g and g.category == "Mounts" and type(g.name) == "string" then
          local canon = CanonMountGroupName(g.name)
          if not allowed[canon] then
            table.remove(list, i)
          else
            -- Also normalize lingering renamed buckets.
            g.name = canon
            g.sortIndex = MountSidebarIndex(canon)
            g.expansion = (g.name == "All Mounts") and "Account" or "Source"
          end
        end
      end
    end
  end

  -- Helpers
  local function NormKey(s)
    if not s or s == "" then return nil end
    s = tostring(s):lower()
    s = s:gsub("’", "'")
    s = s:gsub("[^%w%s'%-%:]", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
  end

  local function GetSourceText(mountID)
    if C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
      local ok, _, _, st = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
      if ok then
        -- Common pattern: returns creatureDisplayID, description, sourceText, isSelfMount, mountTypeID
        if type(st) == "string" then return st end
        -- Some clients shift positions; try to recover "sourceText" heuristically
        local a, b, c, d, e = C_MountJournal.GetMountInfoExtraByID(mountID)
        if type(c) == "string" then return c end
        if type(b) == "string" and (b:find("Drop", 1, true) or b:find("Vendor", 1, true)) then return b end
      end
    end
    return ""
  end


  local function StripColorCodes(s)
    if type(s) ~= "string" then return "" end
    -- Remove Blizzard color codes like |cFFFFD200 and |r
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    return s
  end

local function SourceLabelFromText(st)
  st = StripColorCodes(st or "")

  -- Some sources are a bare token (no colon), e.g. "In-Game Shop".
  local bare = st:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
  if bare ~= "" and not bare:find(":", 1, true) then
    local b = bare:lower()
    if b == "in-game shop" or b == "shop" then return "Store" end
    if b == "promotion" then return "Promotion" end
    if b == "trading post" then return "Trading Post" end
    if b == "world event" then return "World Event" end
    if b == "achievement" then return "Achievement" end
    if b == "pvp" then return "PvP" end
    if b == "quest" then return "Quest" end
    if b == "drop" then return "Drop" end
    if b == "vendor" then return "Vendor" end
    if b == "profession" then return "Profession" end
    if b == "store" then return "Store" end
  end

  -- Expect formats like "Drop: ..." or "Quest: ..."
  local label = st:match("^%s*([%a%s]+)%s*:%s*")
  if not label then return nil end
  label = label:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
  if label == "" then return nil end

  -- Normalize common variants
  local l = label:lower()
  if l == "world event" then return "World Event" end
  if l == "trading post" then return "Trading Post" end
  if l == "pvp" then return "PvP" end
  if l == "in-game shop" then return "Store" end

  -- Title-case simple labels
  if l == "drop" then return "Drop" end
  if l == "quest" then return "Quest" end
  if l == "vendor" then return "Vendor" end
  if l == "profession" then return "Profession" end
  if l == "achievement" then return "Achievement" end
  if l == "promotion" then return "Promotion" end
  if l == "store" then return "Store" end
  return label
end

  local function SourceTypeLabel(mountID, sourceType)

-- 0) Optional explicit overrides pack (offline-authored; no runtime inference)
local ovPack = ns.GetMountSourceOverridesPack and ns.GetMountSourceOverridesPack() or nil
local ov = (ovPack and ovPack.map) and ovPack.map[mountID] or nil
if type(ov) == "string" and ov ~= "" then
  local l = ov:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  -- Normalize known noisy/duplicate labels into stable buckets
  if l:find("anniversary") or l:find("30th_anniversary") or l:find("15th_anniversary") then return "Anniversary" end
  if l == "ph_quest" or l == "phquest" then return "Quest" end
  if l == "store" or l == "in_game_shop" or l == "shop" then return "Store" end
  if l == "achievement" then return "Achievement" end
  if l == "raid" then return "Raid" end
  if l == "dungeon" then return "Dungeon" end
  if l == "delve" then return "Delve" end
  if l == "open_world" or l == "openworld" then return "Open World" end
  if l == "quest" then return "Quest" end
  if l == "pvp" then return "PvP" end
  if l == "promotion" then return "Promotion" end
  if l == "trading_post" then return "Trading Post" end
  if l == "world_event" then return "World Event" end
  if l == "vendor" then return "Vendor" end
  if l == "profession" then return "Profession" end
  if l == "drop" then return "Drop" end
  return ov
end

  -- Explicit offline source override (datapack)
  local ovPack = ns.GetMountSourceOverridesPack and ns.GetMountSourceOverridesPack() or nil
  local ov = ovPack and ovPack.map and ovPack.map[mountID] or nil
  if type(ov) == "string" and ov ~= "" then
    local l = ov:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if l == "store" then return "Store" end
    if l == "achievement" then return "Achievement" end
    if l == "raid" then return "Raid" end
    if l == "dungeon" then return "Dungeon" end
    if l == "quest" then return "Quest" end
    if l == "pvp" then return "PvP" end
    if l == "promotion" then return "Promotion" end
    if l == "trading_post" then return "Trading Post" end
    if l == "world_event" then return "World Event" end
    return ov
  end

    -- Prefer Mount Journal's own source text token to avoid unstable numeric enums.
    local st = GetSourceText(mountID)
    local fromText = SourceLabelFromText(st)
    if fromText then return fromText end
    -- Fallback: numeric mapping for compatibility
    local n = SOURCE_TYPE_NAMES[tonumber(sourceType or 0)]
    if n then return n end
    return ("Source %s"):format(tostring(sourceType or "?"))
  end

  local function BuildInstanceNameSets()
    local raids = {}
    local dungeons = {}

    -- 1) Prefer our curated EJ-imported groups if present (stable naming)
    if ns and ns.Data and ns.Data.groupsByCategory then
      local r = ns.Data.groupsByCategory["Raids"]
      if type(r) == "table" then
        for _, g in ipairs(r) do
          if g and type(g.name) == "string" and g.name ~= "" then
            local k = NormKey(g.name)
            if k then raids[k] = g.name end
          end
        end
      end

      local d = ns.Data.groupsByCategory["Dungeons"]
      if type(d) == "table" then
        for _, g in ipairs(d) do
          if g and type(g.name) == "string" and g.name ~= "" then
            local k = NormKey(g.name)
            if k then dungeons[k] = g.name end
          end
        end
      end
    end

    -- 2) Fallback: build instance-name sets straight from the Encounter Journal (Blizzard truth).
    -- This prevents mis-bucketing raid/dungeon drops as "Open World" when curated raid/dungeon groups
    -- are not populated yet.
    if (not next(raids)) and (not next(dungeons)) and ns and ns.EnsureEJLoaded and ns.EnsureEJLoaded() then
      local curTier = nil
      if EJ_GetCurrentTier then pcall(function() curTier = EJ_GetCurrentTier() end) end

      local numTiers = 0
      if EJ_GetNumTiers then
        local ok, n = pcall(EJ_GetNumTiers)
        if ok and type(n) == "number" then numTiers = n end
      end
      if numTiers <= 0 then numTiers = 80 end

      for tier = 1, numTiers do
        local okTier = pcall(EJ_SelectTier, tier)
        if not okTier then break end

        for _, isRaid in ipairs({ true, false }) do
          for i = 1, 2000 do
            local okI, instanceID = pcall(EJ_GetInstanceByIndex, i, isRaid)
            if not okI or not instanceID then break end

            local name = nil
            if EJ_GetInstanceInfo then
              pcall(function() name = EJ_GetInstanceInfo(instanceID) end)
            end
            if name and name ~= "" then
              local k = NormKey(name)
              if k then
                if isRaid then raids[k] = name else dungeons[k] = name end
              end
            end
          end
        end
      end

      if curTier and EJ_SelectTier then pcall(EJ_SelectTier, curTier) end
    end

    return raids, dungeons
  end

  local function MatchOneInstance(sourceTextNorm, nameMap)
    if not sourceTextNorm or sourceTextNorm == "" then return nil, false end
    local foundKey, foundName = nil, nil
    local count = 0
    for k, original in pairs(nameMap) do
      if k and k ~= "" and sourceTextNorm:find(k, 1, true) then
        count = count + 1
        foundKey, foundName = k, original
        if count > 1 then
          return nil, true -- ambiguous
        end
      end
    end
    if count == 1 then
      return foundName, false
    end
    return nil, false
  end

  local raidNames, dungeonNames = BuildInstanceNameSets()

  -- Buckets by Blizzard sourceType (truthful, no inference).
  local buckets = {}
  local all = {}

  -- Retired/unobtainable mounts (datapack: name-based; English client).
  local unobtainable = {}

  -- Drop-derived buckets (strict; derived from Blizzard sourceText + EJ instance/encounter truth).
  local dropAll, dropRaid, dropDungeon, dropDelve, dropOpenWorld, dropUnclassified = {}, {}, {}, {}, {}, {}

  for _, mountID in ipairs(mountIDs) do
    local mountName, _, _, _, _, sourceType = C_MountJournal.GetMountInfoByID(mountID)
    table.insert(all, mountID)

    -- If this mount is in the retired/unobtainable datapack, route it exclusively to Unobtainable.
    -- (Keeps sidebar clean and matches user expectations: moved out of other buckets.)
    local lname = mountName and mountName:lower() or nil
    if ns and ns.RetiredMountNameSet and lname and ns.RetiredMountNameSet[lname] then
      table.insert(unobtainable, mountID)
    else
      local key = SourceTypeLabel(mountID, sourceType)
      buckets[key] = buckets[key] or {}
      table.insert(buckets[key], mountID)

      if key == "Drop" then -- Drop
      table.insert(dropAll, mountID)

      local st = GetSourceText(mountID)
      local stNorm = NormKey(st)

      -- 0) Offline drop categories pack (authoritative when present)
local dropPack = ns.GetMountDropCategoriesPack and ns.GetMountDropCategoriesPack() or nil

local function normCat(v)
  if type(v) ~= "string" then return nil end
  v = v:upper():gsub("[^A-Z0-9]+", "_")
  -- Collapse common variants to canonical buckets
  if v:find("RAID", 1, true) then return "RAID" end
  if v:find("DUNG", 1, true) then return "DUNGEON" end
  if v:find("DELVE", 1, true) then return "DELVE" end
  if v:find("OPEN", 1, true) or v:find("WORLD", 1, true) then return "OPEN_WORLD" end
  return v
end

local dropEntry = nil
if dropPack and dropPack.map then
  -- Support both numeric and string mountID keys
  dropEntry = dropPack.map[mountID] or dropPack.map[tostring(mountID)]
end

if type(dropEntry) == "table" then
  local cat = normCat(dropEntry.cat or dropEntry.category)
  if cat == "RAID" then
    table.insert(dropRaid, mountID)
  elseif cat == "DUNGEON" then
    table.insert(dropDungeon, mountID)
  elseif cat == "DELVE" then
    table.insert(dropDelve, mountID)
  elseif cat == "OPEN_WORLD" then
    table.insert(dropOpenWorld, mountID)
  else
    table.insert(dropUnclassified, mountID)
  end
else


      local ambiguous = false

      -- 1) Prefer direct instance-name match using our Raids/Dungeons tabs (EJ-backed names)
      local raidMatch, ambRaid = MatchOneInstance(stNorm, raidNames)
      if ambRaid then ambiguous = true end
      local dungeonMatch, ambDung = MatchOneInstance(stNorm, dungeonNames)
      if ambDung then ambiguous = true end

      if not ambiguous and raidMatch and not dungeonMatch then
        table.insert(dropRaid, mountID)
      elseif not ambiguous and dungeonMatch and not raidMatch then
        table.insert(dropDungeon, mountID)
      elseif ambiguous or (raidMatch and dungeonMatch) then
        table.insert(dropUnclassified, mountID)
      else
        -- 2) Boss -> Instance mapping via Encounter Journal (strict)
        if ns and ns.ResolveBossToInstanceStrict then
          local category, _, _ = ns.ResolveBossToInstanceStrict(st)
          if category == "AMBIGUOUS" then
            table.insert(dropUnclassified, mountID)
          elseif category == "Raids" then
            table.insert(dropRaid, mountID)
          elseif category == "Dungeons" then
            table.insert(dropDungeon, mountID)
          elseif category then
            -- Unknown category: do NOT guess. Keep unclassified until an offline pack
            -- (or a future stricter resolver) can place it correctly.
            table.insert(dropUnclassified, mountID)
          else
            -- 3) Delve keyword (derived; fallback)
            if stNorm and stNorm:find("delve", 1, true) then
              table.insert(dropDelve, mountID)
            else
              -- Don't guess "Open World" for unknown drops.
              table.insert(dropUnclassified, mountID)
            end
          end
        else
          -- No EJ mapping available; fallback
          if stNorm and stNorm:find("delve", 1, true) then
            table.insert(dropDelve, mountID)
          else
            -- Don't guess "Open World" for unknown drops.
            table.insert(dropUnclassified, mountID)
          end
        end
      end
      end
    end
    end
  end

  -- Always include a deterministic "All Mounts"
  UpsertGeneratedGroup({
    id = "mounts:all",
    name = "All Mounts",
    category = "Mounts",
    expansion = "Account",
    mounts = all,
    sortIndex = MountSidebarIndex("All Mounts"),
  })

  -- Retired/unobtainable group from datapack (exclusive; removed from other buckets above)
  if type(unobtainable) == "table" and #unobtainable > 0 then
    table.sort(unobtainable)
    UpsertGeneratedGroup({
      id = "mounts:cat:unobtainable",
      name = "Unobtainable",
      category = "Mounts",
      expansion = "Source",
      mounts = unobtainable,
      sortIndex = MountSidebarIndex("Unobtainable"),
    })
  end

  -- Create one group per source type, stable IDs.
  for name, list in pairs(buckets) do
    table.sort(list)
    local gid = "mounts:source:" .. name:gsub("%s+", "_"):lower()
    UpsertGeneratedGroup({
      id = gid,
      name = name,
      category = "Mounts",
      expansion = "Source",
      mounts = list,
      sortIndex = MountSidebarIndex(name),
    })
  end

  -- Derived "Drop" breakdowns (strict; do not replace Blizzard-native Drop bucket).
  -- Derived "Drop" breakdowns (strict; do not replace Blizzard-native Drop bucket).
  local function UpsertDrop(id, name, list, forceCreate)
    if type(list) ~= "table" then list = {} end
    if (not forceCreate) and #list == 0 then return end
    table.sort(list)
    UpsertGeneratedGroup({
      id = id,
      name = name,
      category = "Mounts",
      expansion = "Source",
      mounts = list,
      sortIndex = MountSidebarIndex(name),
    })
  end

  UpsertDrop("mounts:drop:all", "Drops (All)", dropAll, true)
  UpsertDrop("mounts:drop:raid", "Drops (Raid)", dropRaid, true)
  UpsertDrop("mounts:drop:dungeon", "Drops (Dungeon)", dropDungeon, true)
  -- Delve/Open World drops are user-facing categories.
  -- Use non-":derived" IDs so they are not suppressed by the UI.
  UpsertDrop("mounts:drop:delve", "Drops (Delve)", dropDelve, true)
  UpsertDrop("mounts:drop:openworld", "Drops (Open World)", dropOpenWorld, true)
  -- "Drops (Unclassified)" is intentionally not surfaced in the Mounts sidebar.
  -- Unclassified drops remain tracked in stats for debugging, but not shown as a group.


-- ============================================================
-- Curated plural Drops system (datapack-driven; independent of Blizzard sourceType)
-- ============================================================
do
  local dropPack = ns.GetMountDropCategoriesPack and ns.GetMountDropCategoriesPack() or nil
  if dropPack and type(dropPack.map) == "table" then
    -- Empty-pack guard
    local hasAny = false
    for _ in pairs(dropPack.map) do hasAny = true break end

    if hasAny then
      local dpAll, dpRaid, dpDungeon, dpDelve, dpOpenWorld, dpUnclassified = {}, {}, {}, {}, {}, {}
      for _, mountID in ipairs(mountIDs) do
        local dropEntry = dropPack.map[mountID]
        if type(dropEntry) == "table" then
          table.insert(dpAll, mountID)
          local cat = dropEntry.cat or dropEntry.category
          if cat == "RAID" then
            table.insert(dpRaid, mountID)
          elseif cat == "DUNGEON" then
            table.insert(dpDungeon, mountID)
          elseif cat == "DELVE" then
            table.insert(dpDelve, mountID)
          elseif cat == "OPEN_WORLD" then
            table.insert(dpOpenWorld, mountID)
          else
            table.insert(dpUnclassified, mountID)
          end
        end
      end

      local function UpsertPluralDrops(id, name, list)
        if type(list) ~= "table" then list = {} end
        table.sort(list)
        UpsertGeneratedGroup({
      id = id,
      name = name,
      category = "Mounts",
      expansion = "Source",
      mounts = list,
      sortIndex = MountSidebarIndex(name),
    })
      end

      UpsertPluralDrops("mounts:drops:all", "Drops (All)", dpAll)
      UpsertPluralDrops("mounts:drops:raid", "Drops (Raid)", dpRaid)
      UpsertPluralDrops("mounts:drops:dungeon", "Drops (Dungeon)", dpDungeon)
      UpsertPluralDrops("mounts:drops:delve", "Drops (Delve)", dpDelve)
      UpsertPluralDrops("mounts:drops:openworld", "Drops (Open World)", dpOpenWorld)
      -- Do not surface "Drops (Unclassified)" in the Mounts sidebar.
    end
  end
end


  -- Optional: Curated multi-tag groups (pack-driven).
  --
  -- If a MountTags data pack is installed and contains mountTags entries,
  -- we create additional groups under the Mounts category.
  --
  -- IMPORTANT:
  -- * This does NOT change any existing grouping when the pack is empty.
  -- * A single mount may appear in multiple tag groups.
  local mountTagsPack = ns.GetMountTagsPack and ns.GetMountTagsPack() or nil
  if mountTagsPack and type(mountTagsPack.mountTags) == "table" then
    -- Detect "empty pack" cheaply.
    local hasAny = false
    for _ in pairs(mountTagsPack.mountTags) do
      hasAny = true
      break
    end

    if hasAny then
      -- Build a quick set of valid mountIDs from the journal snapshot so we
      -- don't surface stale IDs from older packs.
      local valid = {}
      for _, mid in ipairs(mountIDs) do valid[mid] = true end

      local tagBuckets = {}
      for mid, tags in pairs(mountTagsPack.mountTags) do
        mid = tonumber(mid)
        if mid and valid[mid] and type(tags) == "table" then
          for _, tagKey in ipairs(tags) do
            if type(tagKey) == "string" and tagKey ~= "" then
              tagBuckets[tagKey] = tagBuckets[tagKey] or {}
              table.insert(tagBuckets[tagKey], mid)
            end
          end
        end
      end

      for tagKey, list in pairs(tagBuckets) do
        if type(list) == "table" and #list > 0 then
          table.sort(list)

          local display = tagKey
          local sortIndex = 100
          if type(mountTagsPack.tags) == "table" and type(mountTagsPack.tags[tagKey]) == "table" then
            local t = mountTagsPack.tags[tagKey]
            if type(t.name) == "string" and t.name ~= "" then
              display = t.name
            end
            if tonumber(t.sort) then
              sortIndex = tonumber(t.sort)
            end
          end

          -- Skip redundant structural tags that are represented by Drops subcategories.
          local dispName = display
          if dispName == "Raid" or dispName == "Dungeon" or dispName == "Open World" then
            -- represented by Drops (Raid/Dungeon/Open World)
          else
            local canon = CanonMountGroupName(dispName)
            -- Merge into canonical buckets by NAME to prevent duplicates.
            AddToMountsGroupByName(canon, list)
          end
        end
      end
    end
  end
  -- Ensure all requested Mounts sidebar categories exist at least as empty placeholders.
  -- This is grouping metadata only; it does not affect Blizzard truth / collected state.
  do
    local want = {
      { id = "mounts:cat:reputation",    name = "Reputation" },
      { id = "mounts:cat:adventures",    name = "Adventures" },
      { id = "mounts:cat:class",         name = "Class" },
      { id = "mounts:cat:faction",       name = "Faction" },
      { id = "mounts:cat:race",          name = "Race" },
      { id = "mounts:cat:covenant_feature", name = "Covenant Feature" },
      { id = "mounts:cat:garrison_mission", name = "Garrison Mission" },
      { id = "mounts:cat:unobtainable",  name = "Unobtainable" },
      { id = "mounts:cat:uncategorized", name = "Uncategorized" },
      { id = "mounts:cat:secret",        name = "Secret" },
    }

    local existingIds, existingNames = {}, {}
    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      for _, g in ipairs(CollectionLogDB.generatedPack.groups) do
        if g and g.id then existingIds[tostring(g.id)] = true end
        if g and g.category == "Mounts" and type(g.name) == "string" then existingNames[g.name] = true end
      end
    end

    for _, w in ipairs(want) do
      if (not existingIds[w.id]) and (not existingNames[w.name]) then
        UpsertGeneratedGroup({
          id = w.id,
          name = w.name,
          category = "Mounts",
          expansion = "Source",
          mounts = {},
          sortIndex = MountSidebarIndex(w.name),
        })
      end
    end
  end



  -- ============================================================
  -- Manual Mount grouping overrides (Primary + Extra tags)
  -- Philosophy-safe: does NOT change collected truth; only display buckets.
  -- Stored in SavedVariables under CollectionLogDB.userOverrides.mounts
  -- Apply LAST so rebuilds never overwrite user decisions.
  -- ============================================================
  do
    if CollectionLogDB then
      CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
      local uo = CollectionLogDB.userOverrides
      uo.mounts = uo.mounts or {}
      if not uo.mounts.primary then uo.mounts.primary = {} end
      if not uo.mounts.extra then uo.mounts.extra = {} end

      local list = (CollectionLogDB.generatedPack and CollectionLogDB.generatedPack.groups) or nil
      if type(list) == "table" then
        local function RemoveMountFromList(t, mountID)
          if type(t) ~= "table" then return end
          for i = #t, 1, -1 do
            if tonumber(t[i]) == tonumber(mountID) then
              table.remove(t, i)
            end
          end
        end

        local function RemoveMountEverywhereExcept(mountID, keepSet)
          for _, g in ipairs(list) do
            if g and g.category == "Mounts" and type(g.mounts) == "table" and type(g.name) == "string" then
              local canon = CanonMountGroupName(g.name)
              if not keepSet[canon] then
                RemoveMountFromList(g.mounts, mountID)
              end
            end
          end
        end

        -- 1) Primary overrides
        for mountID, primaryName in pairs(uo.mounts.primary) do
          mountID = tonumber(mountID)
          if mountID and type(primaryName) == "string" and primaryName ~= "" then
            local primaryCanon = CanonMountGroupName(primaryName)
            local keep = { ["All Mounts"] = true }
            keep[primaryCanon] = true

            local extras = uo.mounts.extra[mountID]
            if type(extras) == "table" then
              for tagName, enabled in pairs(extras) do
                if enabled and type(tagName) == "string" then
                  keep[CanonMountGroupName(tagName)] = true
                end
              end
            end

            RemoveMountEverywhereExcept(mountID, keep)
            AddToMountsGroupByName(primaryCanon, { mountID })
          end
        end

        -- 2) Extra tags
        for mountID, tags in pairs(uo.mounts.extra) do
          mountID = tonumber(mountID)
          if mountID and type(tags) == "table" then
            for tagName, enabled in pairs(tags) do
              if enabled and type(tagName) == "string" and tagName ~= "" then
                local canon = CanonMountGroupName(tagName)
                if canon ~= "All Mounts" and canon ~= "Drops (All)" then
                  AddToMountsGroupByName(canon, { mountID })
                end
              end
            end
          end
        end

        -- 3) Recompute Drops (All)
        local function FindGroupByCanon(canonName)
          for _, g in ipairs(list) do
            if g and g.category == "Mounts" and type(g.name) == "string" then
              if CanonMountGroupName(g.name) == canonName then
                return g
              end
            end
          end
          return nil
        end

        local gAll = FindGroupByCanon("Drops (All)")
        if gAll and type(gAll.mounts) == "table" then
          local union, set = {}, {}
          local function AddFrom(canon)
            local gg = FindGroupByCanon(canon)
            if gg and type(gg.mounts) == "table" then
              for _, mid in ipairs(gg.mounts) do
                mid = tonumber(mid)
                if mid and not set[mid] then
                  set[mid] = true
                  table.insert(union, mid)
                end
              end
            end
          end
          AddFrom("Drops (Raid)")
          AddFrom("Drops (Dungeon)")
          AddFrom("Drops (Open World)")
          AddFrom("Drops (Delve)")
          table.sort(union)
          gAll.mounts = union
        end
      end
    end
  end







  -- ============================================================
  -- FINAL Mounts group normalization + suppression (canonical sidebar)
  -- Some generators/datapacks may append raw tag/source groups directly.
  -- Normalize ALL Mounts groups into your canonical buckets every rebuild:
  --  * Merge duplicate/variant names via CanonMountGroupName
  --  * Route legacy/noisy buckets into Uncategorized (or Quest)
  --  * Suppress any Mounts groups not in the canonical allowlist
  -- This guarantees old labels cannot "come back" after a rebuild.
  -- ============================================================
  do
    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      local groups = CollectionLogDB.generatedPack.groups

      -- Canonical allowlist (ONLY these appear in Mounts left panel)
      local ALLOW = {
        ["All Mounts"] = true,
        ["Drops (All)"] = true,
        ["Drops (Raid)"] = true,
        ["Drops (Dungeon)"] = true,
        ["Drops (Open World)"] = true,
        ["Drops (Delve)"] = true,
        ["Achievement"] = true,
        ["Adventures"] = true,
        ["Quest"] = true,
        ["Reputation"] = true,
        ["Profession"] = true,
        ["Class"] = true,
        ["Faction"] = true,
        ["Race"] = true,
        ["PvP"] = true,
        ["Vendor"] = true,
        ["World Event"] = true,
        ["Store"] = true,
        ["Trading Post"] = true,
        ["Promotion"] = true,
        ["Secret"] = true,
        ["Covenant Feature"] = true,
        ["Garrison Mission"] = true,
        ["Unobtainable"] = true,
        ["Uncategorized"] = true,
      }

      -- Collect all mounts into canonical buckets
      local buckets = {}  -- canonName -> { mounts = {..}, meta = firstGroup }
      local function bucketFor(canon)
        if not buckets[canon] then
          buckets[canon] = { mounts = {}, meta = nil }
        end
        return buckets[canon]
      end

      for _, g in ipairs(groups) do
        if g and g.category == "Mounts" and type(g.name) == "string" and type(g.mounts) == "table" then
          local canon = CanonMountGroupName(g.name)
          -- Anything that canonicalizes to a non-allowed bucket goes to Uncategorized
          if not ALLOW[canon] then
            canon = "Uncategorized"
          end
          local b = bucketFor(canon)
          if not b.meta then
            b.meta = g
          end
          MergeUniqueMountIDs(b.mounts, g.mounts)
        end
      end

      -- Rebuild Mounts groups list in canonical order, preserving other categories
      local newGroups = {}
      for _, g in ipairs(groups) do
        if not (g and g.category == "Mounts") then
          table.insert(newGroups, g)
        end
      end

      -- Emit canonical Mounts groups in sidebar order
      local ordered = {
        "All Mounts",
        "Drops (All)",
        "Drops (Raid)",
        "Drops (Dungeon)",
        "Drops (Open World)",
        "Drops (Delve)",
        "Achievement",
        "Adventures",
        "Quest",
        "Reputation",
        "Profession",
        "Class",
        "Faction",
        "Race",
        "PvP",
        "Vendor",
        "World Event",
        "Store",
        "Trading Post",
        "Promotion",
        "Secret",
        "Garrison Mission",
        "Covenant Feature",
        "Unobtainable",
        "Uncategorized",
      }

      for _, name in ipairs(ordered) do
        local b = buckets[name]
        if b and type(b.mounts) == "table" then
          -- Always keep your canonical buckets, even if empty, so order is stable.
          local gg = b.meta or { category = "Mounts", name = name, mounts = {} }
          gg.category = "Mounts"
          gg.name = name
          gg.mounts = b.mounts
          gg.sortIndex = MountSidebarIndex(name)
          table.insert(newGroups, gg)
        else
          -- Create empty placeholder to keep UI order stable
          table.insert(newGroups, { category = "Mounts", name = name, mounts = {}, sortIndex = MountSidebarIndex(name) })
        end
      end

      CollectionLogDB.generatedPack.groups = newGroups
    end
  end
  -- Debug helper for quick verification
  ns._lastMountDropStats = {
    total = #dropAll,
    raid = #dropRaid,
    dungeon = #dropDungeon,
    delve = #dropDelve,
    openworld = #dropOpenWorld,
    unclassified = #dropUnclassified,
  }

  if ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end
  if ns.Print then
    ns.Print("Built mounts groups (Mount Journal + strict Drop classification)")
  end
  ns._clogMountsBuiltCount = #ids
  ns._clogMountsBuiltAt = (GetTime and GetTime()) or 0
  return true

end

function ns.EnsureMountsGroups()
  local ok = ns._TryBuildMountsGroups and ns._TryBuildMountsGroups()
  if ok then
    NotifyCollectionsUIUpdated("Mounts")
    return ok
  end

  -- If the Mount Journal isn't ready yet, wait for Blizzard to populate it.
  EnsureMountsEventFrame()
  -- Register the known mount journal update events (pcall avoids hard errors on builds missing an event).
  local function SafeReg(ev) pcall(mountFrame.RegisterEvent, mountFrame, ev) end
  SafeReg("MOUNT_JOURNAL_LIST_UPDATE")
  SafeReg("MOUNT_JOURNAL_COLLECTION_UPDATED")
  SafeReg("MOUNT_JOURNAL_USABILITY_CHANGED")
  SafeReg("NEW_MOUNT_ADDED")

  return nil
end

-- ============================================================================
-- Debug: Drop classification summary (Mount Journal)
-- Usage: /clogmountsdrop
-- ============================================================================
function ns.DebugDumpMountDrops()
  EnsureCollectionsLoaded()
  local stats = ns._lastMountDropStats
  if not stats then
    if ns.EnsureMountsGroups then pcall(ns.EnsureMountsGroups) end
    stats = ns._lastMountDropStats
  end

  local function Print(msg)
    if ns and ns.Print then ns.Print(msg) else print("|cff00ff99Collection Log|r: " .. tostring(msg)) end
  end

  if not stats then
    Print("No mount drop stats available yet. Open the Mounts tab once and try again.")
    return
  end

  Print(("Mount Drop Classification (strict): total=%d raid=%d dungeon=%d delve=%d openworld=%d unclassified=%d"):format(
    stats.total or 0, stats.raid or 0, stats.dungeon or 0, stats.delve or 0, stats.openworld or 0, stats.unclassified or 0
  ))
end

-- NOTE: Plural Drops groups are generated inside ns.EnsureMountsGroups() where we have access
-- to the current Mount Journal snapshot. We intentionally avoid generating them here.