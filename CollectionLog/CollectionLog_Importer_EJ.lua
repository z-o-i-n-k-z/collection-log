-- CollectionLog_Importer_EJ.lua
-- Journal Scanner: uses Adventure Guide (Encounter Journal) Loot tab as "all potential drops"

local ADDON, ns = ...

-- ============================================================================
-- Utilities
-- ============================================================================
local function Print(msg)
  if ns and ns.Print then
    ns.Print(msg)
  else
    print("|cff00ff99Collection Log|r: " .. tostring(msg))
  end
end

local function EnsureEncounterJournalLoaded()
  -- In some clients EJ_* APIs are nil until the Blizzard Encounter Journal is loaded.
  -- In newer clients, loot APIs may live under C_EncounterJournal.
  if (C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex) or EJ_GetLootInfoByIndex then
    return true
  end

  pcall(LoadAddOn, "Blizzard_EncounterJournal")
  if EncounterJournal_LoadUI then
    pcall(EncounterJournal_LoadUI)
  end

  return (C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex) ~= nil
     or EJ_GetLootInfoByIndex ~= nil
end

local function GetLootInfoByIndex(i)
  if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
    -- Returns an itemInfo table
    return C_EncounterJournal.GetLootInfoByIndex(i)
  end
  if EJ_GetLootInfoByIndex then
    -- May return multiple values or a table depending on client
    return EJ_GetLootInfoByIndex(i)
  end
  return nil
end


-- ============================================================================
-- EJ Boss -> Instance index (for strict mount drop classification)
-- ============================================================================
local function _NormKey(s)
  if not s or s == "" then return nil end
  s = tostring(s):lower()
  s = s:gsub("’", "'")
  -- keep letters/numbers/spaces/'-:
  s = s:gsub("[^%w%s'%-%:]", "")
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- Public: ensure EJ is loaded enough for encounter/instance enumeration.
function ns.EnsureEJLoaded()
  if (EJ_GetEncounterInfoByIndex and EJ_GetInstanceByIndex and EJ_GetNumTiers) then
    return true
  end
  -- Try load the Blizzard Encounter Journal UI/APIs.
  EnsureEncounterJournalLoaded()
  return (EJ_GetEncounterInfoByIndex and EJ_GetInstanceByIndex and EJ_GetNumTiers) ~= nil
end

-- Public: build (cached) bossName -> { {instanceID, instanceName, category}, ... } index.
function ns.BuildBossToInstanceIndex()
  if ns._bossToInstance then return ns._bossToInstance end

  ns._bossToInstance = {}
  if not ns.EnsureEJLoaded or not ns.EnsureEJLoaded() then
    return ns._bossToInstance
  end

  local curTier = nil
  if EJ_GetCurrentTier then
    pcall(function() curTier = EJ_GetCurrentTier() end)
  end

  local function Add(encName, instanceID, isRaid, instName)
    local k = _NormKey(encName)
    if not k then return end
    ns._bossToInstance[k] = ns._bossToInstance[k] or {}
    table.insert(ns._bossToInstance[k], {
      instanceID = tonumber(instanceID) or 0,
      instanceName = instName or ("Instance " .. tostring(instanceID or "?")),
      category = isRaid and "Raids" or "Dungeons",
    })
  end

  local numTiers = 0
  if EJ_GetNumTiers then
    local ok, n = pcall(EJ_GetNumTiers)
    if ok and type(n) == "number" then numTiers = n end
  end
  if numTiers <= 0 then numTiers = 80 end -- conservative fallback

  for tier = 1, numTiers do
    local okTier = pcall(EJ_SelectTier, tier)
    if not okTier then break end

    for _, isRaid in ipairs({ true, false }) do
      for i = 1, 2000 do
        local okI, instanceID = pcall(EJ_GetInstanceByIndex, i, isRaid)
        if not okI or not instanceID then break end

        local instName = nil
        if EJ_GetInstanceInfo then
          pcall(function() instName = EJ_GetInstanceInfo(instanceID) end)
        end

        pcall(EJ_SelectInstance, instanceID)

        for e = 1, 80 do
          local encName, _, encID = nil, nil, nil
          local okE = pcall(function()
            -- Some clients accept (index, instanceID), others just (index).
            encName, _, encID = EJ_GetEncounterInfoByIndex(e, instanceID)
            if not encName then
              encName, _, encID = EJ_GetEncounterInfoByIndex(e)
            end
          end)
          if not okE or not encName then break end
          Add(encName, instanceID, isRaid, instName)
        end
      end
    end
  end

  if curTier and EJ_SelectTier then
    pcall(EJ_SelectTier, curTier)
  end

  return ns._bossToInstance
end

-- Public: strict resolver from sourceText -> (category, instanceName, instanceID) OR "AMBIGUOUS" OR nil
function ns.ResolveBossToInstanceStrict(sourceText)
  local txt = _NormKey(sourceText or "")
  if not txt or txt == "" then return nil end
  local idx = ns.BuildBossToInstanceIndex and ns.BuildBossToInstanceIndex() or nil
  if not idx then return nil end

  local seen = {}
  local last = nil
  local count = 0

  for bossKey, list in pairs(idx) do
    if txt:find(bossKey, 1, true) then
      for _, rec in ipairs(list) do
        local key = tostring(rec.instanceID or 0)
        if not seen[key] then
          seen[key] = true
          last = rec
          count = count + 1
          if count > 1 then
            return "AMBIGUOUS"
          end
        end
      end
    end
  end

  if count == 1 and last then
    return last.category, last.instanceName, last.instanceID
  end
  return nil
end

-- ============================================================================
-- Journal Title + Difficulty (Mode)
-- ============================================================================
local function TryResolveJournalTitle()
  -- Prefer the API if it can tell us the currently-selected instance.
  if EJ_GetInstanceInfo then
    local ok, name = pcall(EJ_GetInstanceInfo)
    if ok and name and name ~= "" then return name end
  end

  local ej = _G.EncounterJournal
  if not ej then return nil end

  -- Some clients keep the selected instanceID on the journal object.
  if EJ_GetInstanceInfo and ej.instanceID then
    local ok, name = pcall(EJ_GetInstanceInfo, ej.instanceID)
    if ok and name and name ~= "" then return name end
  end

  -- UI text fallbacks (varies by client build)
  if ej.instance and ej.instance.title and ej.instance.title.GetText then
    local t = ej.instance.title:GetText()
    if t and t ~= "" then return t end
  end

  if ej.Title and ej.Title.GetText then
    local t = ej.Title:GetText()
    if t and t ~= "" then return t end
  end

  return nil
end

local function TryResolveJournalDifficulty()
  -- Prefer the API when available.
  local diffID
  if EJ_GetDifficulty then
    diffID = EJ_GetDifficulty()
  elseif EJ and EJ.GetDifficulty then
    diffID = EJ.GetDifficulty()
  end

  local name = diffID and GetDifficultyInfo(diffID)
  if name and name ~= "" then return name end

  -- Fallback: dropdown text (varies by client)
  local ej = _G.EncounterJournal
  if ej and ej.difficulty and ej.difficulty.GetText then
    local t = ej.difficulty:GetText()
    if t and t ~= "" then return t end
  end

  return "Unknown"
end


-- ============================================================================
-- Instance Type (Raid vs Dungeon) + Expansion/Tier Resolution
-- ============================================================================
local function GetSelectedInstanceID()
  local ej = _G.EncounterJournal
  if ej and ej.instanceID then
    return tonumber(ej.instanceID)
  end
  return nil
end

local function GetSelectedDifficultyID()
  local ej = _G.EncounterJournal
  if ej and ej.difficultyID then
    return tonumber(ej.difficultyID)
  end
  local diffID
  if EJ_GetDifficulty then
    diffID = EJ_GetDifficulty()
  elseif EJ and EJ.GetDifficulty then
    diffID = EJ.GetDifficulty()
  end
  return diffID and tonumber(diffID) or nil
end

local function ResolveCategoryFromLists(instanceID)
  if not instanceID or not EJ_GetInstanceByIndex then return nil end

  -- Raid list (true)
  for i = 1, 600 do
    local ok, id = pcall(EJ_GetInstanceByIndex, i, true)
    if not ok or not id then break end
    if id == instanceID then return "Raids", i end
  end

  -- Dungeon list (false)
  for i = 1, 1200 do
    local ok, id = pcall(EJ_GetInstanceByIndex, i, false)
    if not ok or not id then break end
    if id == instanceID then return "Dungeons", i end
  end

  return nil
end

-- ==========================================================================
-- Difficulty Availability (LFG-gated)
-- ==========================================================================
-- The Encounter Journal can sometimes expose encounters/loot for difficulties
-- that are not actually available to players (e.g., special one-difficulty
-- instances). To avoid generating confusing empty/duplicate groups, we gate
-- scanning by what the LFG system advertises for the instance name.
--
-- NOTE: There is no perfect public API that maps EJ instanceID -> LFGID.
-- We therefore build a cache from GetLFGDungeonInfo() keyed by *instance name*
-- and allow scanning when we cannot confidently decide.

local _LFG_DIFFICULTY_CACHE = nil

local function _NormalizeName(s)
  if type(s) ~= "string" then return nil end
  -- Lowercase and collapse whitespace/punct to make matching more resilient.
  s = s:lower()
  s = s:gsub("[%s%p]+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function _EnsureLFGDifficultyCache()
  if _LFG_DIFFICULTY_CACHE ~= nil then return end
  _LFG_DIFFICULTY_CACHE = {}

  if not GetLFGDungeonInfo then
    return
  end

  local consecutiveNil = 0
  -- Scan a generous range; break after a long run of nils.
  for dungeonID = 1, 10000 do
    local ok, name, _, _, _, _, _, _, _, _, _, _, _, _, difficultyID = pcall(GetLFGDungeonInfo, dungeonID)
    if ok and name and name ~= "" then
      consecutiveNil = 0
      local key = _NormalizeName(name)
      if key then
        _LFG_DIFFICULTY_CACHE[key] = _LFG_DIFFICULTY_CACHE[key] or {}
        if difficultyID then
          -- Some clients return a non-numeric difficulty token here; guard
          -- against tonumber() returning nil to avoid "table index is nil".
          local did = tonumber(difficultyID)
          if did then
            _LFG_DIFFICULTY_CACHE[key][did] = true
          end
        end
      end
    else
      consecutiveNil = consecutiveNil + 1
      if consecutiveNil >= 600 then
        break
      end
    end
  end
end

local function IsDifficultyAdvertisedByLFG(instanceID, difficultyID)
  if not instanceID or not difficultyID or not EJ_GetInstanceInfo then
    return true -- can't decide; don't block
  end

  local ok, name = pcall(EJ_GetInstanceInfo, instanceID)
  if not ok or not name or name == "" then
    return true
  end

  _EnsureLFGDifficultyCache()
  if not _LFG_DIFFICULTY_CACHE then
    return true
  end

  local key = _NormalizeName(name)
  if not key then return true end

  local diffs = _LFG_DIFFICULTY_CACHE[key]
  if not diffs then
    -- If we have no LFG record for this name, we cannot confidently gate.
    return true
  end

  if not next(diffs) then
    -- We have an LFG record for the instance name but no reliable difficulty IDs.
    -- Treat as unknown and do not block scanning.
    return true
  end

  local did = tonumber(difficultyID)
  if not did then
    return true
  end

  return diffs[did] == true
end

-- Best-effort instance name for chat logs. Must never throw.
local function ResolveInstanceNameSafe(instanceID)
  if EJ_GetInstanceInfo and instanceID then
    local name = EJ_GetInstanceInfo(instanceID)
    if type(name) == "string" and name ~= "" then
      return name
    end
  end
  return "instance " .. tostring(instanceID or "?")
end

-- Resolve expansion name + chronological tier order by scanning EJ tiers and
-- locating the instance in either the raid or dungeon lists.
local function ResolveExpansionAndOrder(instanceID)
  if not instanceID or not EJ_SelectTier or not EJ_GetTierInfo or not EJ_GetInstanceByIndex then
    return "Unknown", 999, 999, nil
  end

  local curTier
  if EJ_GetCurrentTier then
    local ok, t = pcall(EJ_GetCurrentTier)
    if ok then curTier = t end
  end

  local function TryTier(tier)
    pcall(EJ_SelectTier, tier)

    local tierName
    do
      local ok, n = pcall(EJ_GetTierInfo, tier)
      tierName = ok and n or nil
    end

    if not tierName or tierName == "" then
      return nil
    end

    local cat, idx = ResolveCategoryFromLists(instanceID)
    if cat then
      return tierName, tier, idx, cat
    end

    return false
  end

  for tier = 1, 80 do
    local res = TryTier(tier)
    if res == nil then
      -- Past the end of tiers
      break
    elseif res ~= false then
      local tierName, sortTier, sortIndex, cat = res
      if curTier and EJ_SelectTier then pcall(EJ_SelectTier, curTier) end
      return tierName, sortTier, sortIndex, cat
    end
  end

  if curTier and EJ_SelectTier then pcall(EJ_SelectTier, curTier) end
  return "Unknown", 999, 999, nil
end

local function ResolveCategory()
  local instanceID = GetSelectedInstanceID()
  local cat = instanceID and select(1, ResolveCategoryFromLists(instanceID)) or nil
  return cat or "Raids" -- safest default for legacy behavior
end

-- ============================================================================
-- Loot Row Extraction

-- ============================================================================
local function ExtractLootRows()
  local out = {}
  local i = 1

  while true do
    local ok, a, b, c, d, e, f, g = pcall(GetLootInfoByIndex, i)
    if not ok or not a then break end

    local itemID
    local link

    if type(a) == "table" then
      -- C_EncounterJournal.GetLootInfoByIndex returns a table (and some builds of EJ_* do too)
      link = a.link or a.itemLink or a.hyperlink or a.itemlink
      itemID = a.itemID or a.itemId or a.id or (link and select(1, GetItemInfoInstant(link)))
    else
      -- EJ_GetLootInfoByIndex may return multiple values:
      -- name, icon, slot, armorType, itemID, link, ...
      -- Correct mapping: itemID = e, link = f
      link = f
      itemID = e or (link and select(1, GetItemInfoInstant(link)))
    end

    itemID = tonumber(itemID)
    if itemID and itemID > 0 then
      out[#out + 1] = { itemID = itemID, link = link }
    end

    i = i + 1
  end

  return out
end


-- ============================================================================
-- Group Builder
-- ============================================================================
local function BuildGroup()
  local title = TryResolveJournalTitle()
  if not title then
    Print("Could not resolve instance title from Encounter Journal.")
    return nil
  end

  local mode = TryResolveJournalDifficulty()
local instanceID = GetSelectedInstanceID()
local difficultyID = GetSelectedDifficultyID()

-- Resolve expansion (tier) + ordering deterministically from EJ
local expansion, sortTier, sortIndex, resolvedCategory = ResolveExpansionAndOrder(instanceID)
local category = resolvedCategory or ResolveCategory()

local group = {
  instanceID = instanceID,
  difficultyID = difficultyID,
  -- Stable identity: (instanceID + difficultyID)
  id = string.format("ej:%d:%d", tonumber(instanceID) or 0, tonumber(difficultyID) or 0),

  name = title,
  mode = mode,
  category = category,

  expansion = expansion or "Unknown",
  sortTier = sortTier or 999,
  sortIndex = sortIndex or 999,

  items = {},
  itemSources = {},
}

  -- Reset loot filters (safe across clients)
  if C_EncounterJournal and C_EncounterJournal.ResetLootFilter then
    pcall(C_EncounterJournal.ResetLootFilter)
  end
  if EJ_ResetLootFilter then
    pcall(EJ_ResetLootFilter)
  end
  if EJ_SetLootFilter then
    -- (classID, specID) = (0,0) means "All"
    pcall(EJ_SetLootFilter, 0, 0)
  end

  local function AddItem(itemID, source, link)
    if not group.items[itemID] then
      group.items[#group.items + 1] = itemID
      group.items[itemID] = true
      group.itemSources[itemID] = source
    end
    if link and link ~= "" then
      group.itemLinks = group.itemLinks or {}
      local cur = group.itemLinks[itemID]
      if type(cur) == "string" then
        if cur ~= link then
          group.itemLinks[itemID] = { cur, link }
        end
      elseif type(cur) == "table" then
        local seen = false
        for _, v in ipairs(cur) do
          if v == link then seen = true break end
        end
        if not seen then
          cur[#cur+1] = link
        end
      else
        group.itemLinks[itemID] = link
      end
    end
  end

  -- Boss loot FIRST (so "Drops from" is the boss name whenever possible)
  local e = 1
  while true do
    local ok, encName, _, encID = pcall(EJ_GetEncounterInfoByIndex, e)
    if not ok or not encName then break end

    pcall(EJ_SelectEncounter, encID)
    if difficultyID and EJ_SetDifficulty then pcall(EJ_SetDifficulty, difficultyID) end

    for _, row in ipairs(ExtractLootRows()) do
      AddItem(row.itemID, encName, row.link)
    end

    e = e + 1
  end

  -- Instance-wide loot SECOND (fills remaining items as "Instance")
  pcall(EJ_SelectEncounter, 0)
  for _, row in ipairs(ExtractLootRows()) do
    AddItem(row.itemID, "Instance", row.link)
  end

  return group
end


-- ============================================================================
-- Lua Snippet Generator
-- ============================================================================
local function GroupToLuaSnippet(group)
  local lines = {}
  lines[#lines + 1] = "{"
  lines[#lines + 1] = string.format('  id = "%s",', group.id)
  lines[#lines + 1] = string.format('  name = "%s",', group.name)
  lines[#lines + 1] = string.format('  mode = "%s",', group.mode)
  lines[#lines + 1] = string.format('  category = "%s",', group.category)
  lines[#lines + 1] = "  items = {"

  for _, itemID in ipairs(group.items) do
    lines[#lines + 1] = string.format("    %d,", itemID)
  end

  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  itemSources = {"

  for itemID, src in pairs(group.itemSources) do
    lines[#lines + 1] = string.format("    [%d] = %q,", itemID, src)
  end

  lines[#lines + 1] = "  },"

  if group.itemLinks then
    lines[#lines + 1] = "  itemLinks = {"
    for itemID, link in pairs(group.itemLinks) do
      lines[#lines + 1] = string.format("    [%d] = %q,", itemID, link)
    end
    lines[#lines + 1] = "  },"
  end
  lines[#lines + 1] = "},"

  return table.concat(lines, "\n")
end

-- ============================================================================
-- Public API
-- ============================================================================

function ns.ScanCurrentJournalLoot()
  -- Ensure Blizzard Encounter Journal is loaded so EJ_* APIs exist
  if not EnsureEncounterJournalLoaded() then
    Print("Encounter Journal not available. (Tip: open the Adventure Guide once: Shift+J)")
    return
  end

  -- Basic state sanity: instance selected + loot tab visible usually required for stable results
  if EJ_GetInstanceInfo then
    local ok, name = pcall(EJ_GetInstanceInfo)
    if not ok or not name or name == "" then
      Print("No instance selected in the Adventure Guide. Select a raid/dungeon, then go to its Loot tab.")
      return
    end
  end

  local group = BuildGroup()
  if not group then return end

  Print(("Scanned %d items from %s (%s)."):format(
    #group.items,
    group.name or "?",
    group.mode or "?"
  ))

  -- Persist into SavedVariables so scans don't disappear
CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or { version = 1, groups = {} }
CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}

local replaced = false

-- Preferred: replace by stable id (instanceID + difficultyID)
for i, g in ipairs(CollectionLogDB.generatedPack.groups) do
  if g and g.id == group.id then
    CollectionLogDB.generatedPack.groups[i] = group
    replaced = true
    break
  end
end

-- Legacy migration: replace prior scans that used name/mode/category-based ids
if not replaced then
  for i, g in ipairs(CollectionLogDB.generatedPack.groups) do
    if g
      and g.name == group.name
      and g.mode == group.mode
      and g.category == group.category
    then
      CollectionLogDB.generatedPack.groups[i] = group
      replaced = true
      break
    end
  end
end

if not replaced then
  table.insert(CollectionLogDB.generatedPack.groups, group)
end


  -- Keep a copy for snippet UI if you ever expose it again
  ns._lastScannedGroup = group

  -- Rebuild indexes from packs (generated pack is already registered on login)
  if ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  -- Switch UI to the scanned group
  if CollectionLogDB and CollectionLogDB.ui then
    CollectionLogDB.ui.activeCategory = group.category
    CollectionLogDB.ui.activeGroupId = group.id
  end

  if ns.UI and ns.UI.RefreshAll then
    ns.UI.RefreshAll()
  elseif ns.UI and ns.UI.RefreshGrid then
    ns.UI.RefreshGrid()
  end

-- ============================================================================
-- Generated Pack Writer (multi-pack support)
-- ============================================================================
local function EnsureGeneratedPacksRoot()
  CollectionLogDB.generatedPacks = CollectionLogDB.generatedPacks or {}
end

local function EnsurePack(key)
  EnsureGeneratedPacksRoot()
  CollectionLogDB.generatedPacks[key] = CollectionLogDB.generatedPacks[key] or { version = 1, groups = {} }
  CollectionLogDB.generatedPacks[key].groups = CollectionLogDB.generatedPacks[key].groups or {}
  return CollectionLogDB.generatedPacks[key]
end

local function SaveGroupToPack(packKey, group)
  if not group or not group.id then return end

  if not packKey or packKey == "" then
    -- legacy behavior
    CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or { version = 1, groups = {} }
    CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
    local t = CollectionLogDB.generatedPack.groups
    local replaced = false
    for i, g in ipairs(t) do
      if g and g.id == group.id then
        t[i] = group
        replaced = true
        break
      end
    end
    if not replaced then table.insert(t, group) end
    return
  end

  local pack = EnsurePack(packKey)
  local t = pack.groups
  local replaced = false
  for i, g in ipairs(t) do
    if g and g.id == group.id then
      t[i] = group
      replaced = true
      break
    end
  end
  if not replaced then table.insert(t, group) end
end

-- Public: scan currently selected EJ instance+diff loot into a specific generated pack key.
function ns.ScanCurrentJournalLootInto(packKey)
  if not EnsureEncounterJournalLoaded() then
    Print("Encounter Journal not available. (Tip: open the Adventure Guide once: Shift+J)")
    return
  end

  if EJ_GetInstanceInfo then
    local ok, name = pcall(EJ_GetInstanceInfo)
    if not ok or not name or name == "" then
      Print("No instance selected in the Adventure Guide. Select a raid/dungeon, then go to its Loot tab.")
      return
    end
  end

  local group = BuildGroup()
  if not group then return end

  Print(("Scanned %d items from %s (%s)."):format(
    #group.items,
    group.name or "?",
    group.mode or "?"
  ))

  SaveGroupToPack(packKey, group)

  ns._lastScannedGroup = group

  if ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  if CollectionLogDB and CollectionLogDB.ui then
    CollectionLogDB.ui.activeCategory = group.category
    CollectionLogDB.ui.activeGroupId = group.id
  end

  if ns.UI and ns.UI.RefreshAll then
    ns.UI.RefreshAll()
  elseif ns.UI and ns.UI.RefreshGrid then
    ns.UI.RefreshGrid()
  end
end

-- ============================================================================
-- Tier-scoped scanner (safe for modern expansions like DF/TWW)
-- ============================================================================
local function FindTierIndexByName(sub)
  if not sub or sub == "" or not EJ_GetNumTiers or not EJ_GetTierInfo then return nil end
  sub = tostring(sub):lower()
  local okN, n = pcall(EJ_GetNumTiers)
  if not okN or type(n) ~= "number" then return nil end
  for i = 1, n do
    local ok, name = pcall(EJ_GetTierInfo, i)
    if ok and name and tostring(name):lower():find(sub, 1, true) then
      return i
    end
  end
  return nil
end

-- Public: scan a specific tier (e.g. "Dragonflight") for raids/dungeons into a dedicated generated pack.
-- mode: "dungeons" or "raids"
function ns.ScanTierInstancesAllDifficulties(packKey, tierName, mode)
  if not EnsureEncounterJournalLoaded() then
    Print("Encounter Journal not available. (Tip: open the Adventure Guide once: Shift+J)")
    return
  end

  local want = (type(mode) == "string" and mode:lower()) or "dungeons"
  local isRaid = (want == "raids" or want == "raid")
  local tierIdx = FindTierIndexByName(tierName or "")
  if not tierIdx then
    Print(("Could not find EJ tier for '%s'. Open the Adventure Guide (Shift+J) once, then try again."):format(tostring(tierName)))
    return
  end

  -- Try to open the Adventure Guide so EJ state is valid.
  if ToggleEncounterJournal then pcall(ToggleEncounterJournal) end
  local ej = _G.EncounterJournal
  if ej and ej.Show then pcall(ej.Show, ej) end

  local function SetLootTab()
    if EncounterJournal_SetTab then
      pcall(EncounterJournal_SetTab, 2)
    end
  end

  local function SetDifficulty(diffID)
    if EJ_SetDifficulty then
      local ok = pcall(EJ_SetDifficulty, diffID)
      if ok then return true end
    end
    if EncounterJournal_SetDifficulty then
      local ok = pcall(EncounterJournal_SetDifficulty, diffID)
      if ok then return true end
    end
    if ej then ej.difficultyID = diffID return true end
    return false
  end

  local function SetInstance(instanceID)
    if EJ_SelectInstance then
      local ok = pcall(EJ_SelectInstance, instanceID)
      if ok then
        if ej then ej.instanceID = instanceID end
        return true
      end
    end
    if ej then ej.instanceID = instanceID return true end
    return false
  end

  local originalTier
  if EJ_GetCurrentTier then pcall(function() originalTier = EJ_GetCurrentTier() end) end
  local originalInstance = GetSelectedInstanceID()
  local originalDiff = GetSelectedDifficultyID()

  local function Restore()
    if originalTier and EJ_SelectTier then pcall(EJ_SelectTier, originalTier) end
    if originalInstance then SetInstance(originalInstance) end
    if originalDiff then SetDifficulty(originalDiff) end
    SetLootTab()
  end

  if EJ_SelectTier then pcall(EJ_SelectTier, tierIdx) end

  local jobs = {}
  for i = 1, 2000 do
    if not EJ_GetInstanceByIndex then break end
    local ok, instanceID = pcall(EJ_GetInstanceByIndex, i, isRaid)
    if not ok or not instanceID then break end
    jobs[#jobs+1] = { tier = tierIdx, isRaid = isRaid, instanceID = instanceID }
  end

  if #jobs == 0 then
    Restore()
    Print(("No %s found to scan in tier '%s'."):format(isRaid and "raids" or "dungeons", tostring(tierName)))
    return
  end

  -- Modern difficulty sets only (DF/TWW-friendly)
  local RAID_DIFFS = { 17, 14, 15, 16 }       -- LFR/Normal/Heroic/Mythic
  local DUNGEON_DIFFS = { 1, 2, 23 }          -- Normal/Heroic/Mythic (no keystone)

  local diffs = isRaid and RAID_DIFFS or DUNGEON_DIFFS

  local jobIdx, diffIdx = 1, 1
  local scannedGroups = 0

  local function Step()
    local job = jobs[jobIdx]
    if not job then
      Restore()
      Print(("Tier scan complete (%s - %s). Saved/updated %d groups into pack '%s'."):format(
        tostring(tierName),
        isRaid and "Raids" or "Dungeons",
        scannedGroups,
        tostring(packKey)
      ))
      return
    end

    if EJ_SelectTier then pcall(EJ_SelectTier, job.tier) end
    if not SetInstance(job.instanceID) then
      jobIdx = jobIdx + 1
      diffIdx = 1
      C_Timer.After(0, Step)
      return
    end

    SetLootTab()

    local diffID = diffs[diffIdx]
    if not diffID then
      jobIdx = jobIdx + 1
      diffIdx = 1
      C_Timer.After(0, Step)
      return
    end
    diffIdx = diffIdx + 1

    if GetDifficultyInfo and not GetDifficultyInfo(diffID) then
      C_Timer.After(0, Step)
      return
    end

    -- Use LFG gate for modern content to avoid phantom diffs.
    if not IsDifficultyAdvertisedByLFG(job.instanceID, diffID) then
      C_Timer.After(0.05, Step)
      return
    end

    if not SetDifficulty(diffID) then
      C_Timer.After(0, Step)
      return
    end

    -- Let EJ settle a bit longer (stability over speed)
    C_Timer.After(0.18, function()
      local hasContent = false
      if EJ_GetEncounterInfoByIndex then
        local name = EJ_GetEncounterInfoByIndex(1)
        if name then hasContent = true end
      end
      if not hasContent then
        local li = GetLootInfoByIndex(1)
        if li ~= nil then
          if type(li) == "table" then
            if li.itemID or li.name then hasContent = true end
          else
            hasContent = true
          end
        end
      end

      if not hasContent then
        C_Timer.After(0.10, Step)
        return
      end

      ns.ScanCurrentJournalLootInto(packKey)
      scannedGroups = scannedGroups + 1
      C_Timer.After(0.10, Step)
    end)
  end

  Print(("Scanning %d %s in tier '%s' into pack '%s'..."):format(
    #jobs, isRaid and "raids" or "dungeons", tostring(tierName), tostring(packKey)
  ))
  C_Timer.After(0.2, Step)
end

end

-- ==========================================================================
-- Scan All Difficulties Helper
-- ==========================================================================
-- This is a convenience wrapper for rebuilding your GeneratedPack quickly
-- after wiping SavedVariables.
--
-- It will:
--   1) Ensure EJ is loaded
--   2) Detect whether the selected instance is a Raid or Dungeon
--   3) Iterate common difficulty IDs for that type
--   4) Run the same scan pipeline as /clogscan for each difficulty
--
-- Notes:
-- * We intentionally keep the difficulty list small and "Blizzard-truthful".
-- * If a difficulty isn't valid for the selected instance, the scan will
--   either return 0 items or be skipped without error.
--
-- You can call:
--   /clogscanall
--   /clogscanall raid
--   /clogscanall dungeon
function ns.ScanCurrentJournalLootAllDifficulties(forceType)
  -- Ensure Blizzard Encounter Journal is loaded
  if not EnsureEncounterJournalLoaded() then
    Print("Encounter Journal not available. (Tip: open the Adventure Guide once: Shift+J)")
    return
  end

  local instanceID = GetSelectedInstanceID()
  if not instanceID then
    Print("No instance selected in the Adventure Guide. Select a raid/dungeon, then go to its Loot tab.")
    return
  end

  local detectedCategory = ResolveCategoryFromLists(instanceID)

  local want = (type(forceType) == "string" and forceType:lower()) or ""
  local isRaid = (want == "raid") or (want == "raids")
  local isDungeon = (want == "dungeon") or (want == "dungeons")

  if not isRaid and not isDungeon then
    -- Auto-detect
    if detectedCategory == "Raids" then
      isRaid = true
    elseif detectedCategory == "Dungeons" then
      isDungeon = true
    end
  end

  if not isRaid and not isDungeon then
    Print("Could not detect whether this is a Raid or Dungeon. Try: /clogscanall raid  (or dungeon)")
    return
  end


  -- Determine available difficulties from the Encounter Journal dropdown.
  -- This matches exactly what the player can select in the Adventure Guide.
  local function GetDropdownDifficulties()
    local out = {}

    if EJ_GetNumInstanceDifficulties and EJ_GetInstanceDifficulty then
      local okN, n = pcall(EJ_GetNumInstanceDifficulties)
      if okN and type(n) == "number" and n > 0 then
        for idx = 1, n do
          local okD, diffID, diffName = pcall(EJ_GetInstanceDifficulty, idx)
          if okD and diffID then
            out[#out+1] = diffID
          end
        end
      end
    end

    -- Fallback: fixed candidates (legacy + modern + timewalking) gated by EJ validity where possible.
    if #out == 0 then
      local candidates
      if isRaid then
        -- Modern: LFR/Normal/Heroic/Mythic; Legacy sizes; Timewalking raid (+ TW LFR if present)
        candidates = { 17, 14, 15, 16, 3, 4, 5, 6, 33, 151 }
      else
        -- Normal/Heroic/Mythic/Keystone; Timewalking party
        candidates = { 1, 2, 23, 8, 24 }
      end

      for _, diffID in ipairs(candidates) do
        local valid = true
        if EJ_IsValidInstanceDifficulty then
          local okV, v = pcall(EJ_IsValidInstanceDifficulty, diffID)
          if okV then valid = (v and true) or false end
        end
        if valid then
          out[#out+1] = diffID
        end
      end
    end

    return out
  end

  local diffs = GetDropdownDifficulties()

  local originalDiff = GetSelectedDifficultyID()

  local function SetDifficulty(diffID)
    -- Prefer the EJ API if available
    if EJ_SetDifficulty then
      local ok = pcall(EJ_SetDifficulty, diffID)
      if ok then return true end
    end

    -- Some clients expose EncounterJournal_SetDifficulty
    if EncounterJournal_SetDifficulty then
      local ok = pcall(EncounterJournal_SetDifficulty, diffID)
      if ok then return true end
    end

    -- Fallback: try setting the journal fields (best-effort)
    local ej = _G.EncounterJournal
    if ej then
      ej.difficultyID = diffID
      if ej.difficulty and ej.difficulty.SetText and GetDifficultyInfo then
        local name = GetDifficultyInfo(diffID)
        if name and name ~= "" then
          pcall(ej.difficulty.SetText, ej.difficulty, name)
        end
      end
      return true
    end

    return false
  end

  -- Run sequentially using a timer to give the EJ UI a frame to update.
  local i = 1
  local scanned = 0

  local function Step()
    local diffID = diffs[i]
    if not diffID then
      -- Restore original difficulty if possible
      if originalDiff then
        SetDifficulty(originalDiff)
      end
      Print(("Scan-all complete. Saved/updated %d groups."):format(scanned))
      return
    end

    i = i + 1

    -- Skip unknown difficulty IDs for this client
    if GetDifficultyInfo and not GetDifficultyInfo(diffID) then
      C_Timer.After(0, Step)
      return
    end


    if not SetDifficulty(diffID) then
      C_Timer.After(0, Step)
      return
    end

    -- Let EncounterJournal update its state before scanning
    C_Timer.After(0.05, function()
      -- Only scan difficulties that actually exist for this instance.
      -- Some instances (e.g., "Khaz Algar") only have one difficulty and will show empty EJ data for others.
      local hasContent = false

      if EJ_GetEncounterInfoByIndex then
        local name = EJ_GetEncounterInfoByIndex(1)
        if name then hasContent = true end
      end

      if not hasContent then
        local li = GetLootInfoByIndex(1)
        if li ~= nil then
          if type(li) == "table" then
            if li.itemID or li.name then
              hasContent = true
            end
          else
            hasContent = true
          end
        end
      end

      if not hasContent then
        -- Skip this difficulty (no encounters/loot populated)
        C_Timer.After(0.05, Step)
        return
      end

      ns.ScanCurrentJournalLoot()
      scanned = scanned + 1
      C_Timer.After(0.05, Step)
    end)
  end

  Print(("Scanning all available %s difficulties for current instance..."):format(isRaid and "raid" or "dungeon"))
  Step()
end


-- ==========================================================================
-- Scan All Instances (Raids/Dungeons) on All Difficulties
-- ==========================================================================
-- Rebuild your GeneratedPack from scratch with one command.
--
-- IMPORTANT:
-- * This drives the Encounter Journal UI. It must be able to open/update.
-- * It runs incrementally using timers to avoid freezing the client.
-- * You can cancel by /reload.
--
-- Usage:
--   /clogscanallinstances          (raids + dungeons)
--   /clogscanallinstances raids
--   /clogscanallinstances dungeons
function ns.ScanAllJournalInstancesAllDifficulties(mode)
  if not EnsureEncounterJournalLoaded() then
    Print("Encounter Journal not available. (Tip: open the Adventure Guide once: Shift+J)")
    return
  end

  local want = (type(mode) == "string" and mode:lower()) or ""
  local doRaids = (want == "" or want == "both" or want == "all" or want == "raids" or want == "raid")
  local doDungeons = (want == "" or want == "both" or want == "all" or want == "dungeons" or want == "dungeon")

  if not doRaids and not doDungeons then
    Print("Usage: /clogscanallinstances  (or 'raids' / 'dungeons')")
    return
  end

  -- Try to open the Adventure Guide so EJ state is valid.
  if ToggleEncounterJournal then
    pcall(ToggleEncounterJournal)
  end
  local ej = _G.EncounterJournal
  if ej and ej.Show then pcall(ej.Show, ej) end

  local function SetLootTab()
    -- 2 is the Loot tab on modern clients.
    if EncounterJournal_SetTab then
      pcall(EncounterJournal_SetTab, 2)
    elseif ej and ej.navBar and ej.navBar.homeButton and ej.navBar.homeButton.Click then
      -- best-effort, not critical
      pcall(ej.navBar.homeButton.Click, ej.navBar.homeButton)
    end
  end

  local function SetDifficulty(diffID)
    if EJ_SetDifficulty then
      local ok = pcall(EJ_SetDifficulty, diffID)
      if ok then return true end
    end
    if EncounterJournal_SetDifficulty then
      local ok = pcall(EncounterJournal_SetDifficulty, diffID)
      if ok then return true end
    end
    if ej then
      ej.difficultyID = diffID
      return true
    end
    return false
  end

  local function SetInstance(instanceID)
    if EJ_SelectInstance then
      local ok = pcall(EJ_SelectInstance, instanceID)
      if ok then
        if ej then ej.instanceID = instanceID end
        return true
      end
    end
    if ej then
      ej.instanceID = instanceID
      return true
    end
    return false
  end

  -- Snapshot original EJ state so we can restore.
  local originalTier
  if EJ_GetCurrentTier then
    pcall(function() originalTier = EJ_GetCurrentTier() end)
  end
  local originalInstance = GetSelectedInstanceID()
  local originalDiff = GetSelectedDifficultyID()

  local function Restore()
    if originalTier and EJ_SelectTier then pcall(EJ_SelectTier, originalTier) end
    if originalInstance then SetInstance(originalInstance) end
    if originalDiff then SetDifficulty(originalDiff) end
    SetLootTab()
  end

  -- Build a job list: { tier=number, isRaid=bool, instanceID=number, label=string }
  local jobs = {}

  local numTiers
  if EJ_GetNumTiers then
    local ok, n = pcall(EJ_GetNumTiers)
    numTiers = ok and n or nil
  end
  numTiers = tonumber(numTiers) or 0
  if numTiers <= 0 then
    -- fallback scan
    numTiers = 40
  end

  local function AddJobsFor(isRaid)
    for tier = 1, numTiers do
      if EJ_SelectTier then pcall(EJ_SelectTier, tier) end

      -- If tier info is nil/empty, we might be past end on some clients.
      if EJ_GetTierInfo then
        local ok, name = pcall(EJ_GetTierInfo, tier)
        if not ok or not name or name == "" then
          -- keep going; some clients have gaps
        end
      end

      for i = 1, 2000 do
        if not EJ_GetInstanceByIndex then break end
        local ok, instanceID = pcall(EJ_GetInstanceByIndex, i, isRaid)
        if not ok or not instanceID then break end
        jobs[#jobs+1] = {
          tier = tier,
          isRaid = isRaid,
          instanceID = instanceID,
        }
      end
    end
  end

  if doRaids then AddJobsFor(true) end
  if doDungeons then AddJobsFor(false) end

  if #jobs == 0 then
    Restore()
    Print("No instances found to scan. (Try opening the Adventure Guide: Shift+J)")
    return
  end

  -- Difficulty sets
  local RAID_DIFFS = { 17, 14, 15, 16 }
  local DUNGEON_DIFFS = { 1, 2, 23, 8 }

  -- Run jobs sequentially
  local jobIdx = 1
  local diffIdx = 1
  local scannedGroups = 0

  local function Step()
    local job = jobs[jobIdx]
    if not job then
      Restore()
      Print(("Scan-all-instances complete. Saved/updated %d groups."):format(scannedGroups))
      return
    end

    -- Ensure tier + instance selected
    if EJ_SelectTier then pcall(EJ_SelectTier, job.tier) end
    if not SetInstance(job.instanceID) then
      jobIdx = jobIdx + 1
      diffIdx = 1
      C_Timer.After(0, Step)
      return
    end

    SetLootTab()

    local diffs = job.isRaid and RAID_DIFFS or DUNGEON_DIFFS
    local diffID = diffs[diffIdx]

    if not diffID then
      jobIdx = jobIdx + 1
      diffIdx = 1
      C_Timer.After(0, Step)
      return
    end

    diffIdx = diffIdx + 1

    if GetDifficultyInfo and not GetDifficultyInfo(diffID) then
      C_Timer.After(0, Step)
      return
    end

    -- LFG gate: avoid scanning difficulties that are not actually available
    -- for this instance, even if the Encounter Journal has seeded data.
    if not IsDifficultyAdvertisedByLFG(job.instanceID, diffID) then
      C_Timer.After(0.01, Step)
      return
    end

    if not SetDifficulty(diffID) then
      C_Timer.After(0, Step)
      return
    end

    -- Allow EJ to settle, then scan.
    C_Timer.After(0.08, function()
      -- Skip difficulties that do not populate encounters/loot for this instance.
      local hasContent = false

      if EJ_GetEncounterInfoByIndex then
        local name = EJ_GetEncounterInfoByIndex(1)
        if name then hasContent = true end
      end

      if not hasContent then
        local li = GetLootInfoByIndex(1)
        if li ~= nil then
          if type(li) == "table" then
            if li.itemID or li.name then hasContent = true end
          else
            hasContent = true
          end
        end
      end

      if not hasContent then
        C_Timer.After(0.06, Step)
        return
      end

      ns.ScanCurrentJournalLoot()
      scannedGroups = scannedGroups + 1
      C_Timer.After(0.06, Step)
    end)
  end

  Print(("Scanning %d %s across all difficulties... (you can /reload to cancel)"):format(
    #jobs,
    (doRaids and doDungeons) and "instances" or (doRaids and "raids" or "dungeons")
  ))

  -- Start
  Step()
end


function ns.ShowScanner()
  EnsureScannerUI()
  ScannerUI.frame:Show()
end




