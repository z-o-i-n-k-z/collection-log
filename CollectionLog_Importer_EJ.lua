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

local function GetLootInfoByIndex(i, encounterIndex)
  if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
    -- Returns an EncounterJournalItemInfo table on modern clients.
    -- The optional encounterIndex disambiguates loot rows with multiple boss sources.
    return C_EncounterJournal.GetLootInfoByIndex(i, encounterIndex)
  end
  if EJ_GetLootInfoByIndex then
    -- Legacy API: itemID, encounterID, name, icon, slot, armorType, link
    return EJ_GetLootInfoByIndex(i, encounterIndex)
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
-- Loot Row Extraction + Collectible Metadata
-- ============================================================================
local function AsNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function TrimText(v)
  if v == nil then return nil end
  v = tostring(v):gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then return nil end
  return v
end

local function LinkName(link)
  if type(link) ~= "string" then return nil end
  return link:match("%|h%[([^%]]+)%]%|h")
end

local function FirstStringValue(v)
  if type(v) == "string" and v ~= "" then return v end
  if type(v) == "table" then
    for _, s in ipairs(v) do if type(s) == "string" and s ~= "" then return s end end
    for _, s in pairs(v) do if type(s) == "string" and s ~= "" then return s end end
  end
  return nil
end

local function IsNoAppearanceEquipLoc(equipLoc)
  equipLoc = tostring(equipLoc or "")
  return equipLoc == "INVTYPE_NECK"
      or equipLoc == "INVTYPE_FINGER"
      or equipLoc == "INVTYPE_TRINKET"
      or equipLoc == "INVTYPE_RELIC"
      or equipLoc == "INVTYPE_AMMO"
      or equipLoc == "INVTYPE_BAG"
      or equipLoc == "INVTYPE_QUIVER"
      or equipLoc == "INVTYPE_TABARD"
end

local function GetItemStaticInfo(itemID, link, row)
  itemID = AsNumber(itemID)
  local token = link or itemID
  local info = {
    itemID = itemID,
    itemLink = link,
    itemName = LinkName(link) or TrimText(row and row.name),
    icon = row and row.icon or nil,
    slot = TrimText(row and row.slot),
    armorType = TrimText(row and row.armorType),
  }

  if token and GetItemInfoInstant then
    local ok, iid, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID = pcall(GetItemInfoInstant, token)
    if ok then
      info.itemID = AsNumber(iid) or info.itemID
      info.itemType = TrimText(itemType)
      info.itemSubType = TrimText(itemSubType)
      info.equipLoc = TrimText(itemEquipLoc)
      info.icon = icon or info.icon
      info.classID = AsNumber(classID) or tonumber(classID)
      info.subClassID = AsNumber(subClassID) or tonumber(subClassID)
    end
  end

  if token and GetItemInfo then
    local ok, name, itemLink, quality, itemLevel, minLevel, itemType, itemSubType, stackCount, equipLoc, icon, sellPrice, classID, subClassID, bindType, expacID, setID, isCraftingReagent = pcall(GetItemInfo, token)
    if ok then
      info.itemName = TrimText(name) or info.itemName
      info.itemLink = itemLink or info.itemLink
      info.itemQuality = tonumber(quality)
      info.itemLevel = tonumber(itemLevel)
      info.minLevel = tonumber(minLevel)
      info.itemType = TrimText(itemType) or info.itemType
      info.itemSubType = TrimText(itemSubType) or info.itemSubType
      info.stackCount = tonumber(stackCount)
      info.equipLoc = TrimText(equipLoc) or info.equipLoc
      info.icon = icon or info.icon
      info.sellPrice = tonumber(sellPrice)
      info.classID = tonumber(classID) or info.classID
      info.subClassID = tonumber(subClassID) or info.subClassID
      info.bindType = tonumber(bindType)
      info.expacID = tonumber(expacID)
      info.setID = tonumber(setID)
      info.isCraftingReagent = isCraftingReagent and true or nil
    end
  end

  return info
end

local function AppearancePairFromLinkOrItem(link, itemID)
  if not (C_TransmogCollection and C_TransmogCollection.GetItemInfo) then return nil, nil end
  local token = FirstStringValue(link) or itemID
  if not token then return nil, nil end
  local ok, appearanceID, sourceID = pcall(C_TransmogCollection.GetItemInfo, token)
  if not ok then return nil, nil end
  return AsNumber(appearanceID), AsNumber(sourceID)
end

local function ResolveMountCollectible(itemID)
  local row = ns and ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
  if row then
    return {
      collectibleType = "mount",
      type = "mount",
      collectibleID = AsNumber(row.spellID or row.mountID),
      identityType = row.spellID and "mountSpellID" or "mountID",
      spellID = AsNumber(row.spellID),
      mountID = AsNumber(row.mountID),
      collectibleName = row.name or row.itemName,
    }
  end

  local mountID
  if C_MountJournal then
    if C_MountJournal.GetMountFromItem then
      local ok, id = pcall(C_MountJournal.GetMountFromItem, itemID)
      if ok then mountID = AsNumber(id) end
    end
    if not mountID and C_MountJournal.GetMountFromItemID then
      local ok, a, b = pcall(C_MountJournal.GetMountFromItemID, itemID)
      if ok then mountID = AsNumber(a) or AsNumber(b) end
    end
    if not mountID and C_MountJournal.GetMountIDFromItemID then
      local ok, id = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
      if ok then mountID = AsNumber(id) end
    end
  end
  if mountID then
    return { collectibleType = "mount", type = "mount", collectibleID = mountID, identityType = "mountID", mountID = mountID }
  end
  return nil
end

local function ResolvePetCollectible(itemID)
  local row = ns and ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
  if row then
    return {
      collectibleType = "pet",
      type = "pet",
      collectibleID = AsNumber(row.speciesID or row.petSpeciesID),
      identityType = "petSpeciesID",
      speciesID = AsNumber(row.speciesID or row.petSpeciesID),
      collectibleName = row.name or row.itemName,
    }
  end
  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local ok, speciesID = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
    speciesID = ok and AsNumber(speciesID) or nil
    if speciesID then
      return { collectibleType = "pet", type = "pet", collectibleID = speciesID, identityType = "petSpeciesID", speciesID = speciesID }
    end
  end
  return nil
end

local function ResolveToyCollectible(itemID)
  local row = ns and ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) or nil
  if row then
    return {
      collectibleType = "toy",
      type = "toy",
      collectibleID = AsNumber(row.toyID or itemID) or itemID,
      identityType = "toyItemID",
      toyID = AsNumber(row.toyID or itemID) or itemID,
      collectibleName = row.name or row.itemName,
    }
  end
  if C_ToyBox then
    if C_ToyBox.GetToyFromItemID then
      local ok, toyID = pcall(C_ToyBox.GetToyFromItemID, itemID)
      toyID = ok and AsNumber(toyID) or nil
      if toyID then return { collectibleType = "toy", type = "toy", collectibleID = toyID, identityType = "toyItemID", toyID = toyID } end
    end
    if C_ToyBox.GetToyInfo then
      local ok, toyName = pcall(C_ToyBox.GetToyInfo, itemID)
      if ok and toyName then return { collectibleType = "toy", type = "toy", collectibleID = itemID, identityType = "toyItemID", toyID = itemID, collectibleName = toyName } end
    end
  end
  return nil
end

local function ResolveHousingCollectible(itemID)
  local row = ns and ns.CompletionHousingItemDB and ns.CompletionHousingItemDB.Get and ns.CompletionHousingItemDB.Get(itemID) or nil
  if row then
    local decorID = AsNumber(row.decorID or row.recordID or row.collectibleID or itemID) or itemID
    return {
      collectibleType = "housing",
      type = "housing",
      collectibleID = decorID,
      identityType = "housingDecorID",
      decorID = decorID,
      collectibleName = row.name or row.itemName,
    }
  end
  if ns and ns.GetHousingDecorRecordID then
    local ok, decorID = pcall(ns.GetHousingDecorRecordID, itemID)
    decorID = ok and AsNumber(decorID) or nil
    if decorID then
      return { collectibleType = "housing", type = "housing", collectibleID = decorID, identityType = "housingDecorID", decorID = decorID }
    end
  end
  return nil
end

local function ResolveAppearanceCollectible(itemID, link, info)
  if info and IsNoAppearanceEquipLoc(info.equipLoc) then return nil end

  local appearanceID, sourceID = AppearancePairFromLinkOrItem(link, itemID)
  local row = ns and ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get and ns.CompletionAppearanceItemDB.Get(itemID) or nil

  appearanceID = appearanceID or AsNumber(row and (row.appearanceID or row.visualID))
  sourceID = sourceID or AsNumber(row and (row.sourceID or row.itemModifiedAppearanceID))

  if appearanceID or sourceID then
    return {
      collectibleType = "appearance",
      type = "appearance",
      collectibleID = appearanceID or sourceID,
      identityType = sourceID and "itemModifiedAppearanceID" or "appearanceID",
      appearanceID = appearanceID,
      sourceID = sourceID,
      modID = sourceID,
      itemModifiedAppearanceID = sourceID,
      collectibleName = row and (row.name or row.itemName) or nil,
    }
  end

  return nil
end

local function ResolveCollectibleForScan(itemID, link, row)
  itemID = AsNumber(itemID)
  if not itemID then return nil, nil, "invalid itemID" end
  local info = GetItemStaticInfo(itemID, link, row)

  local def = ResolveMountCollectible(itemID)
           or ResolvePetCollectible(itemID)
           or ResolveToyCollectible(itemID)
           or ResolveHousingCollectible(itemID)
           or ResolveAppearanceCollectible(itemID, info.itemLink or link, info)

  if def then
    for k, v in pairs(info) do
      if def[k] == nil then def[k] = v end
    end
    def.itemID = itemID
    def.itemName = def.itemName or info.itemName or def.collectibleName
    def.itemLink = def.itemLink or info.itemLink or link
    return def, info, nil
  end

  local reason = "no collectible mapping"
  if info.equipLoc == "INVTYPE_TRINKET" then reason = "trinket" end
  if info.equipLoc == "INVTYPE_NECK" or info.equipLoc == "INVTYPE_FINGER" then reason = "jewelry" end
  if info.classID == 15 or tostring(info.itemType or ""):lower() == "miscellaneous" then reason = "misc/non-collectible" end
  if info.classID == 12 or tostring(info.itemType or ""):lower() == "quest" then reason = "quest/token" end
  if (info.classID == 2 or info.classID == 4) and not IsNoAppearanceEquipLoc(info.equipLoc) then reason = "equipment without appearance mapping" end
  return nil, info, reason
end

local function ExtractLootRows()
  local out = {}
  local i = 1

  while true do
    local ok, a, b, c, d, e, f, g = pcall(GetLootInfoByIndex, i)
    if not ok or not a then break end

    local itemID
    local encounterID
    local link
    local name, icon, slot, armorType

    if type(a) == "table" then
      link = a.link or a.itemLink or a.hyperlink or a.itemlink
      itemID = a.itemID or a.itemId or a.id or (link and select(1, GetItemInfoInstant(link)))
      encounterID = a.encounterID or a.encounterId
      name = a.name or a.itemName
      icon = a.icon or a.itemIcon or a.texture
      slot = a.slot or a.slotName or a.equipLoc
      armorType = a.armorType or a.armorClass
    else
      -- Legacy EJ_GetLootInfoByIndex returns:
      -- itemID, encounterID, name, icon, slot, armorType, link
      itemID = a or (g and select(1, GetItemInfoInstant(g)))
      encounterID = b
      name = c
      icon = d
      slot = e
      armorType = f
      link = g
    end

    itemID = AsNumber(itemID)
    encounterID = AsNumber(encounterID)
    if itemID then
      out[#out + 1] = {
        itemID = itemID,
        encounterID = encounterID,
        link = link,
        name = name,
        icon = icon,
        slot = slot,
        armorType = armorType,
        lootIndex = i,
      }
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

  -- v4.3.77 scanner contract:
  -- items and all per-item metadata below are collectible-only.  Raw EJ junk
  -- rows are not persisted; only skippedCounts/skippedTotal are kept for audit.
  scanVersion = 2,
  scanKind = "collectible-metadata",
  items = {},
  itemSources = {},
  itemSourceLists = {},
  itemEncounterIDs = {},
  itemEncounterIDLists = {},
  itemLinks = {},
  itemNames = {},
  itemIcons = {},
  itemTypes = {},
  itemSubTypes = {},
  itemEquipLocs = {},
  itemClassIDs = {},
  itemSubClassIDs = {},
  itemCollectibleTypes = {},
  itemCollectibleIDs = {},
  itemIdentityTypes = {},
  itemAppearanceIDs = {},
  itemModifiedAppearanceIDs = {},
  itemMetadata = {},
  skippedCounts = {},
  skippedTotal = 0,
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

  local encounterNames = {}
  local encounterOrder = {}
  local e = 1
  while true do
    local ok, encName, _, encID = pcall(EJ_GetEncounterInfoByIndex, e)
    if not ok or not encName then break end
    encID = tonumber(encID)
    if encID and encID > 0 then
      encounterNames[encID] = encName
      encounterOrder[#encounterOrder + 1] = { id = encID, name = encName }
    end
    e = e + 1
  end

  local function ResolveRowSource(row, fallback)
    local encID = tonumber(row and row.encounterID)
    if encID and encounterNames[encID] then
      return encounterNames[encID], encID
    end
    return fallback or "Instance", encID
  end

  local function AddUnique(list, value)
    value = TrimText(value)
    if not value then return end
    for _, v in ipairs(list) do
      if v == value then return end
    end
    list[#list + 1] = value
  end

  local function AddUniqueNumber(list, value)
    value = AsNumber(value)
    if not value then return end
    for _, v in ipairs(list) do
      if tonumber(v) == value then return end
    end
    list[#list + 1] = value
  end

  local function AddSource(itemID, source, encounterID)
    itemID = AsNumber(itemID)
    if not itemID then return end

    source = TrimText(source) or "Instance"
    group.itemSourceLists[itemID] = group.itemSourceLists[itemID] or {}
    AddUnique(group.itemSourceLists[itemID], source)
    group.itemSources[itemID] = table.concat(group.itemSourceLists[itemID], ", ")

    encounterID = AsNumber(encounterID)
    if encounterID then
      group.itemEncounterIDLists[itemID] = group.itemEncounterIDLists[itemID] or {}
      AddUniqueNumber(group.itemEncounterIDLists[itemID], encounterID)
      group.itemEncounterIDs[itemID] = group.itemEncounterIDs[itemID] or encounterID
    end
  end

  local function AddLink(itemID, link)
    if not (itemID and link and link ~= "") then return end
    local cur = group.itemLinks[itemID]
    if type(cur) == "string" then
      if cur ~= link then group.itemLinks[itemID] = { cur, link } end
    elseif type(cur) == "table" then
      local seen = false
      for _, v in ipairs(cur) do if v == link then seen = true break end end
      if not seen then cur[#cur + 1] = link end
    else
      group.itemLinks[itemID] = link
    end
  end

  local function RecordSkipped(reason)
    reason = TrimText(reason) or "skipped"
    group.skippedTotal = (group.skippedTotal or 0) + 1
    group.skippedCounts[reason] = (group.skippedCounts[reason] or 0) + 1
  end

  local function CopyPresent(dst, src, keys)
    for _, key in ipairs(keys) do
      local v = src and src[key]
      if v ~= nil and v ~= "" then dst[key] = v end
    end
  end

  local function AddItem(row, source, encounterID)
    local itemID = AsNumber(row and row.itemID)
    if not itemID then return false end

    local def, info, skipReason = ResolveCollectibleForScan(itemID, row.link, row)
    if not def then
      RecordSkipped(skipReason)
      return false
    end

    if not group.items[itemID] then
      group.items[#group.items + 1] = itemID
      group.items[itemID] = true
    end

    AddSource(itemID, source or "Instance", encounterID)
    AddLink(itemID, def.itemLink or row.link)

    group.itemNames[itemID] = def.itemName or info.itemName or group.itemNames[itemID]
    group.itemIcons[itemID] = def.icon or info.icon or group.itemIcons[itemID]
    group.itemTypes[itemID] = def.itemType or info.itemType or group.itemTypes[itemID]
    group.itemSubTypes[itemID] = def.itemSubType or info.itemSubType or group.itemSubTypes[itemID]
    group.itemEquipLocs[itemID] = def.equipLoc or info.equipLoc or group.itemEquipLocs[itemID]
    group.itemClassIDs[itemID] = tonumber(def.classID or info.classID) or group.itemClassIDs[itemID]
    group.itemSubClassIDs[itemID] = tonumber(def.subClassID or info.subClassID) or group.itemSubClassIDs[itemID]
    group.itemCollectibleTypes[itemID] = def.collectibleType or def.type
    group.itemCollectibleIDs[itemID] = AsNumber(def.collectibleID)
    group.itemIdentityTypes[itemID] = def.identityType

    if def.appearanceID then group.itemAppearanceIDs[itemID] = AsNumber(def.appearanceID) end
    if def.sourceID or def.itemModifiedAppearanceID or def.modID then
      group.itemModifiedAppearanceIDs[itemID] = AsNumber(def.sourceID or def.itemModifiedAppearanceID or def.modID)
    end

    local meta = group.itemMetadata[itemID] or {}
    group.itemMetadata[itemID] = meta
    CopyPresent(meta, def, {
      "itemID", "itemName", "itemLink", "icon", "itemQuality", "itemLevel", "minLevel",
      "itemType", "itemSubType", "equipLoc", "classID", "subClassID", "bindType", "expacID", "setID",
      "slot", "armorType", "collectibleType", "type", "collectibleID", "identityType",
      "collectibleName", "mountID", "spellID", "speciesID", "toyID", "decorID",
      "appearanceID", "sourceID", "modID", "itemModifiedAppearanceID"
    })
    meta.itemID = itemID
    meta.collectibleType = meta.collectibleType or meta.type
    meta.type = meta.collectibleType or meta.type
    meta.instanceID = instanceID
    meta.instanceName = title
    meta.category = category
    meta.expansion = expansion or "Unknown"
    meta.difficultyID = difficultyID
    meta.difficultyName = mode
    meta.encounterID = AsNumber(encounterID) or meta.encounterID
    meta.dropsFrom = group.itemSources[itemID]
    meta.sourceText = (group.itemSources[itemID] and (group.itemSources[itemID] .. " - " .. tostring(title))) or tostring(title)
    meta.encounterIDs = group.itemEncounterIDLists[itemID]
    meta.dropSources = group.itemSourceLists[itemID]

    return true
  end

  local function GetSourceCountForLootRow(row)
    if not (row and row.lootIndex and EJ_GetNumEncountersForLootByIndex) then return 1 end
    local ok, n = pcall(EJ_GetNumEncountersForLootByIndex, row.lootIndex)
    n = ok and tonumber(n) or nil
    if n and n > 1 then return n end
    return 1
  end

  local function ExtractSpecificLootSource(row, sourceIndex)
    if not (row and row.lootIndex and sourceIndex and sourceIndex > 1) then return nil end
    local ok, a, b, c, d, e, f, g = pcall(GetLootInfoByIndex, row.lootIndex, sourceIndex)
    if not ok or not a then return nil end

    local itemID, encounterID, link, name, icon, slot, armorType
    if type(a) == "table" then
      link = a.link or a.itemLink or a.hyperlink or a.itemlink
      itemID = a.itemID or a.itemId or a.id or (link and select(1, GetItemInfoInstant(link)))
      encounterID = a.encounterID or a.encounterId
      name = a.name or a.itemName
      icon = a.icon or a.itemIcon or a.texture
      slot = a.slot or a.slotName or a.equipLoc
      armorType = a.armorType or a.armorClass
    else
      itemID = a or (g and select(1, GetItemInfoInstant(g)))
      encounterID = b
      name = c
      icon = d
      slot = e
      armorType = f
      link = g
    end

    itemID = AsNumber(itemID)
    if not itemID or itemID ~= row.itemID then return nil end
    return {
      itemID = itemID,
      encounterID = AsNumber(encounterID),
      link = link or row.link,
      name = name or row.name,
      icon = icon or row.icon,
      slot = slot or row.slot,
      armorType = armorType or row.armorType,
      lootIndex = row.lootIndex,
    }
  end

  local function AddLootRowWithAllSources(row)
    local sourceCount = GetSourceCountForLootRow(row)
    if sourceCount > 1 then
      local added = false
      for sourceIndex = 1, sourceCount do
        local sourceRow = ExtractSpecificLootSource(row, sourceIndex) or (sourceIndex == 1 and row) or nil
        if sourceRow then
          local source, encID = ResolveRowSource(sourceRow, "Instance")
          if AddItem(sourceRow, source, encID) then added = true end
        end
      end
      if added then return end
    end

    local source, encID = ResolveRowSource(row, "Instance")
    AddItem(row, source, encID)
  end

  -- Source attribution should come from the Encounter Journal loot row's
  -- encounterID/source index. Selecting each boss and assuming the visible loot
  -- list is filtered is unsafe on newer clients; it can return the full instance
  -- loot and incorrectly stamp every item with the first boss.
  pcall(EJ_SelectEncounter, 0)
  if difficultyID and EJ_SetDifficulty then pcall(EJ_SetDifficulty, difficultyID) end
  local rows = ExtractLootRows()
  for _, row in ipairs(rows) do
    AddLootRowWithAllSources(row)
  end

  -- Very old clients/builds may only expose encounter-specific loot after a boss
  -- is selected. Only use this as a fill-in pass; the row encounterID still wins.
  if #rows == 0 then
    for _, enc in ipairs(encounterOrder) do
      pcall(EJ_SelectEncounter, enc.id)
      if difficultyID and EJ_SetDifficulty then pcall(EJ_SetDifficulty, difficultyID) end
      for _, row in ipairs(ExtractLootRows()) do
        local source, encID = ResolveRowSource(row, enc.name)
        AddItem(row, source, encID or enc.id)
      end
    end
  end

  return group
end


-- ============================================================================
-- Lua Snippet Generator
-- ============================================================================
local function GroupToLuaSnippet(group)
  local function isArray(t)
    if type(t) ~= "table" then return false end
    local n = #t
    local count = 0
    for k in pairs(t) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
      count = count + 1
    end
    return count == n
  end

  local function sortedKeys(t)
    local keys = {}
    for k in pairs(t or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return tostring(a) < tostring(b) end
      return type(a) < type(b)
    end)
    return keys
  end

  local function serialize(v, indent)
    indent = indent or ""
    local tv = type(v)
    if tv == "number" then return tostring(v) end
    if tv == "boolean" then return v and "true" or "false" end
    if tv == "string" then return string.format("%q", v) end
    if tv ~= "table" then return "nil" end

    local nextIndent = indent .. "  "
    local parts = { "{" }
    if isArray(v) then
      for _, value in ipairs(v) do
        parts[#parts + 1] = nextIndent .. serialize(value, nextIndent) .. ","
      end
    else
      for _, key in ipairs(sortedKeys(v)) do
        local value = v[key]
        local keyText
        if type(key) == "number" then
          keyText = "[" .. tostring(key) .. "]"
        elseif type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
          keyText = key
        else
          keyText = "[" .. serialize(key, nextIndent) .. "]"
        end
        parts[#parts + 1] = nextIndent .. keyText .. " = " .. serialize(value, nextIndent) .. ","
      end
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
  end

  local out = {
    id = group.id,
    name = group.name,
    mode = group.mode,
    category = group.category,
    instanceID = group.instanceID,
    difficultyID = group.difficultyID,
    expansion = group.expansion,
    sortTier = group.sortTier,
    sortIndex = group.sortIndex,
    scanVersion = group.scanVersion,
    scanKind = group.scanKind,
    items = group.items,
    itemSources = group.itemSources,
    itemSourceLists = group.itemSourceLists,
    itemEncounterIDs = group.itemEncounterIDs,
    itemEncounterIDLists = group.itemEncounterIDLists,
    itemLinks = group.itemLinks,
    itemNames = group.itemNames,
    itemIcons = group.itemIcons,
    itemTypes = group.itemTypes,
    itemSubTypes = group.itemSubTypes,
    itemEquipLocs = group.itemEquipLocs,
    itemClassIDs = group.itemClassIDs,
    itemSubClassIDs = group.itemSubClassIDs,
    itemCollectibleTypes = group.itemCollectibleTypes,
    itemCollectibleIDs = group.itemCollectibleIDs,
    itemIdentityTypes = group.itemIdentityTypes,
    itemAppearanceIDs = group.itemAppearanceIDs,
    itemModifiedAppearanceIDs = group.itemModifiedAppearanceIDs,
    itemMetadata = group.itemMetadata,
    skippedTotal = group.skippedTotal,
    skippedCounts = group.skippedCounts,
  }

  return serialize(out, "") .. ","
end


-- ============================================================================
-- Live EJ boss-source resolution for tooltip truth
-- ============================================================================
do
  local function _TrimText(value)
    if value == nil then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
  end

  local function _GetEncounterNameByID(encounterID)
    encounterID = tonumber(encounterID)
    if not encounterID or encounterID <= 0 then return nil end

    if EJ_GetEncounterInfo then
      local ok, name = pcall(EJ_GetEncounterInfo, encounterID)
      name = ok and _TrimText(name) or nil
      if name then return name end
    end

    if EJ_GetEncounterInfoByIndex then
      local i = 1
      while true do
        local ok, name, _, id = pcall(EJ_GetEncounterInfoByIndex, i)
        if not ok or not name then break end
        if tonumber(id) == encounterID then
          return _TrimText(name)
        end
        i = i + 1
      end
    end

    return nil
  end

  local function _ExtractLootInfoAt(index, encounterIndex)
    local ok, a, b, c, d, e, f, g = pcall(GetLootInfoByIndex, index, encounterIndex)
    if not ok or not a then return nil end

    local itemID, encounterID, link
    if type(a) == "table" then
      link = a.link or a.itemLink or a.hyperlink or a.itemlink
      itemID = a.itemID or a.itemId or a.id or (link and select(1, GetItemInfoInstant(link)))
      encounterID = a.encounterID or a.encounterId
    else
      -- Legacy EJ_GetLootInfoByIndex: itemID, encounterID, name, icon, slot, armorType, link
      itemID = a or (g and select(1, GetItemInfoInstant(g)))
      encounterID = b
      link = g
    end

    itemID = tonumber(itemID)
    encounterID = tonumber(encounterID)
    if not itemID or itemID <= 0 then return nil end
    return { itemID = itemID, encounterID = encounterID, link = link }
  end

  local function _GetNumLootRows()
    if EJ_GetNumLoot then
      local ok, n = pcall(EJ_GetNumLoot)
      if ok and tonumber(n) then return tonumber(n) end
    end

    local n = 0
    while _ExtractLootInfoAt(n + 1) do
      n = n + 1
      if n > 1000 then break end
    end
    return n
  end

  local function _GetNumSourcesForLootIndex(index)
    if EJ_GetNumEncountersForLootByIndex then
      local ok, n = pcall(EJ_GetNumEncountersForLootByIndex, index)
      n = ok and tonumber(n) or nil
      if n and n > 0 then return n end
    end
    return 1
  end

  local function _BuildStrictSourceListForItem(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then return nil end

    local names, seen = {}, {}
    local numLoot = _GetNumLootRows()
    for lootIndex = 1, numLoot do
      local base = _ExtractLootInfoAt(lootIndex)
      if base and base.itemID == itemID then
        local numSources = _GetNumSourcesForLootIndex(lootIndex)
        for sourceIndex = 1, numSources do
          local info = _ExtractLootInfoAt(lootIndex, sourceIndex) or base
          if info and info.itemID == itemID then
            local name = _GetEncounterNameByID(info.encounterID)
            if name and not seen[name] then
              seen[name] = true
              names[#names + 1] = name
            end
          end
        end
      end
    end

    if #names > 0 then
      return table.concat(names, ", ")
    end
    return nil
  end

  local function _SelectGroupJournalContext(group)
    if type(group) ~= "table" then return false end
    local instanceID = tonumber(group.instanceID)
    local difficultyID = tonumber(group.difficultyID)
    if not instanceID or not difficultyID then return false end
    if not EnsureEncounterJournalLoaded() then return false end

    pcall(EJ_SelectInstance, instanceID)
    if EJ_SetDifficulty then pcall(EJ_SetDifficulty, difficultyID) end
    if EJ_SelectEncounter then pcall(EJ_SelectEncounter, 0) end

    if C_EncounterJournal and C_EncounterJournal.ResetLootFilter then
      pcall(C_EncounterJournal.ResetLootFilter)
    end
    if C_EncounterJournal and C_EncounterJournal.ResetSlotFilter then
      pcall(C_EncounterJournal.ResetSlotFilter)
    end
    if EJ_ResetLootFilter then pcall(EJ_ResetLootFilter) end
    if EJ_SetLootFilter then pcall(EJ_SetLootFilter, 0, 0) end

    return true
  end

  function ns.ClearEncounterSourceCache()
    -- Kept for compatibility with older callers. Strict mode intentionally does
    -- not use a boss-source cache; the tooltip/source resolver asks EJ directly.
  end

  function ns.GetEncounterSourceForItem(group, itemID)
    if type(group) ~= "table" or not itemID then return nil end

    local prevTier, prevInstance, prevDifficulty, prevEncounter = nil, nil, nil, nil
    if EJ_GetCurrentTier then pcall(function() prevTier = EJ_GetCurrentTier() end) end
    if EJ_GetCurrentInstance then pcall(function() prevInstance = EJ_GetCurrentInstance() end) end
    if EJ_GetDifficulty then pcall(function() prevDifficulty = EJ_GetDifficulty() end) end
    if EJ_GetCurrentEncounter then pcall(function() prevEncounter = EJ_GetCurrentEncounter() end) end

    local source = nil
    local ok = pcall(function()
      if _SelectGroupJournalContext(group) then
        source = _BuildStrictSourceListForItem(itemID)
      end
    end)

    -- Restore the user's Encounter Journal context as best as the public API allows.
    if prevTier and EJ_SelectTier then pcall(EJ_SelectTier, prevTier) end
    if prevInstance and EJ_SelectInstance then pcall(EJ_SelectInstance, prevInstance) end
    if prevDifficulty and EJ_SetDifficulty then pcall(EJ_SetDifficulty, prevDifficulty) end
    if prevEncounter and EJ_SelectEncounter then pcall(EJ_SelectEncounter, prevEncounter) end

    if ok and source then return source end
    return group.itemSources and group.itemSources[tonumber(itemID)] or nil
  end
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

  Print(("Scanned %d collectible items from %s (%s). Skipped %d non-collectible EJ rows."):format(
    #group.items,
    group.name or "?",
    group.mode or "?",
    tonumber(group.skippedTotal or 0) or 0
  ))

  -- Persist into SavedVariables so scans don't disappear
CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or { version = 2, groups = {} }
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
  CollectionLogDB.generatedPacks[key] = CollectionLogDB.generatedPacks[key] or { version = 2, groups = {} }
  CollectionLogDB.generatedPacks[key].groups = CollectionLogDB.generatedPacks[key].groups or {}
  return CollectionLogDB.generatedPacks[key]
end

local function SaveGroupToPack(packKey, group)
  if not group or not group.id then return end

  if not packKey or packKey == "" then
    -- legacy behavior
    CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or { version = 2, groups = {} }
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

  Print(("Scanned %d collectible items from %s (%s). Skipped %d non-collectible EJ rows."):format(
    #group.items,
    group.name or "?",
    group.mode or "?",
    tonumber(group.skippedTotal or 0) or 0
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




