local ADDON, ns = ...

ns.CompletionDefinitions = ns.CompletionDefinitions or {}
local CD = ns.CompletionDefinitions

CD.groups = CD.groups or {}
CD.entries = CD.entries or {}
CD.meta = CD.meta or {}
CD.aliases = CD.aliases or {}
CD._built = CD._built or false

local SUPPORTED_CATEGORIES = {
  Raids = true,
  Dungeons = true,
}

-- Explicit mount token fallbacks for known problem cases.
-- These are only used when API-based resolution fails.
local MOUNT_ITEM_TO_SPELL_OVERRIDE = {
  [32458] = 40192, -- Ashes of Al'ar
  [69224] = 97493, -- Pureblood Fire Hawk
  [50818] = 72286, -- Invincible's Reins
  [45693] = 63796, -- Mimiron's Head
}

local function _wipe(tbl)
  if not tbl then return end
  if wipe then wipe(tbl) else for k in pairs(tbl) do tbl[k] = nil end end
end

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function normalizeName(s)
  s = tostring(s or "")
  -- Strip common WoW markup/color/texture wrappers first.
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
  s = s:gsub("|r", "")
  s = s:gsub("|T.-|t", " ")
  s = s:gsub("|A.-|a", " ")
  s = s:gsub("|H.-|h", " ")
  s = s:gsub("|h", " ")
  s = s:lower()
  s = s:gsub("['’`_]", "")
  s = s:gsub("[%p%c]", " ")
  s = s:gsub("%s+", " ")
  s = s:match("^%s*(.-)%s*$") or ""
  return s
end

local function addAlias(map, alias, groupKey)
  alias = normalizeName(alias)
  if alias == "" or not groupKey then return end
  map[alias] = map[alias] or {}
  map[alias][groupKey] = true

  local noThe = alias:gsub("^the ", "")
  if noThe ~= alias and noThe ~= "" then
    map[noThe] = map[noThe] or {}
    map[noThe][groupKey] = true
  end
end


local KNOWN_MOUNT_NAME_ALIASES = {
  ["ashes of alar"] = true,
  ["abyss worm"] = true,
  ["living infernal core"] = true,
  ["experiment 12 b"] = true,
  ["spawn of horridon"] = true,
  ["clutch of ji kun"] = true,
  ["korkron juggernaut"] = true,
  ["ironhoof destroyer"] = true,
  ["felsteel annihilator"] = true,
  ["antoran charhound"] = true,
  ["g m o d"] = true,
  ["glacial tidestorm"] = true,
  ["nyalotha allseer"] = true,
  ["ashes of beloren"] = true,
}

local function extractItemName(group, rawID)
  if type(group) ~= "table" then return nil end
  local itemLinks = type(group.itemLinks) == "table" and group.itemLinks or nil
  local link = itemLinks and itemLinks[rawID] or nil
  if type(link) ~= "string" or link == "" then return nil end
  local name = link:match("|h%[([^%]]+)%]|h")
  if name and name ~= "" then return name end
  return nil
end


local _realItemCache = {}
local _itemNameCache = {}
local _mountDataCache = {}
local _mountLooksLikeCache = {}
local _petResolutionCache = {}

local function getAnyItemName(itemID, group)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  local cached = _itemNameCache[itemID]
  if cached ~= nil then return cached ~= false and cached or nil end
  local name = extractItemName(group, itemID)
  if name and name ~= "" then _itemNameCache[itemID] = name return name end
  if C_Item and C_Item.GetItemNameByID then
    local ok, n = pcall(C_Item.GetItemNameByID, itemID)
    if ok and type(n) == "string" and n ~= "" then _itemNameCache[itemID] = n return n end
  end
  if GetItemInfo then
    local ok, n = pcall(GetItemInfo, itemID)
    if ok and type(n) == "string" and n ~= "" then _itemNameCache[itemID] = n return n end
  end
  _itemNameCache[itemID] = false
  return nil
end

local function isExplicitRaidMount(group, rawID)
  rawID = asNumber(rawID)
  local instanceID = type(group) == "table" and asNumber(group.instanceID) or nil
  if not rawID or not instanceID then return false end
  return ns.CompletionRaidMounts and ns.CompletionRaidMounts.IsExplicitRaidMount and ns.CompletionRaidMounts.IsExplicitRaidMount(instanceID, rawID) and true or false
end

local function looksLikeMountDrop(group, rawID)
  rawID = asNumber(rawID)
  if not rawID then return false end
  local cacheKey = tostring(rawID)
  if _mountLooksLikeCache[cacheKey] ~= nil then return _mountLooksLikeCache[cacheKey] end
  if MOUNT_ITEM_TO_SPELL_OVERRIDE[rawID] then _mountLooksLikeCache[cacheKey] = true return true end
  if isExplicitRaidMount(group, rawID) then _mountLooksLikeCache[cacheKey] = true return true end

  local itemName = extractItemName(group, rawID)
  local norm = normalizeName(itemName)
  if norm == "" then _mountLooksLikeCache[cacheKey] = false return false end
  if norm:find("reins of ", 1, true) == 1 then _mountLooksLikeCache[cacheKey] = true return true end
  if norm:find(" ashes of ", 1, true) or norm:find("ashes of ", 1, true) == 1 then _mountLooksLikeCache[cacheKey] = true return true end
  if KNOWN_MOUNT_NAME_ALIASES[norm] then _mountLooksLikeCache[cacheKey] = true return true end
  _mountLooksLikeCache[cacheKey] = false
  return false
end

local function appearsToBeRealItem(itemID)
  itemID = asNumber(itemID)
  if not itemID then return false end
  if _realItemCache[itemID] ~= nil then return _realItemCache[itemID] end
  local exists = false
  if GetItemInfoInstant then
    local a = GetItemInfoInstant(itemID)
    if a then exists = true end
  end
  if (not exists) and C_Item and C_Item.DoesItemExistByID then
    local ok, res = pcall(C_Item.DoesItemExistByID, itemID)
    if ok and res then exists = true end
  end
  _realItemCache[itemID] = exists and true or false
  return _realItemCache[itemID]
end

local function getMountSpellIDFromMountID(mountID)
  mountID = asNumber(mountID)
  if not mountID then return nil end
  if C_MountJournal and C_MountJournal.GetMountInfoByID then
    local ok, _, spellID = pcall(C_MountJournal.GetMountInfoByID, mountID)
    if ok and spellID and spellID ~= 0 then return spellID end
  end
  local db = ns.CompletionMountDB and ns.CompletionMountDB.GetByMountID and ns.CompletionMountDB.GetByMountID(mountID) or nil
  local spellID = asNumber(db and db.spellID)
  if spellID then return spellID end
  return nil
end

local function getMountDataFromItemID(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  if _mountDataCache[itemID] ~= nil then
    return _mountDataCache[itemID] ~= false and _mountDataCache[itemID] or nil
  end

  local explicit = ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
  local mountID = asNumber(explicit and explicit.mountID) or nil
  if (not mountID) and ns.GetMountIDFromItemID then
    local ok, resolvedMountID = pcall(ns.GetMountIDFromItemID, itemID)
    if ok and resolvedMountID and resolvedMountID ~= 0 then
      mountID = resolvedMountID
    end
  end

  if (not mountID) and C_MountJournal and C_MountJournal.GetMountIDFromItemID then
    local ok, resolvedMountID = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
    if ok and resolvedMountID and resolvedMountID ~= 0 then
      mountID = resolvedMountID
    end
  end

  local spellID = asNumber(explicit and explicit.spellID) or getMountSpellIDFromMountID(mountID)
  if not spellID then
    spellID = MOUNT_ITEM_TO_SPELL_OVERRIDE[itemID]
  end

  if mountID or spellID then
    local db = nil
    if ns.CompletionMountDB then
      if mountID and ns.CompletionMountDB.GetByMountID then
        db = ns.CompletionMountDB.GetByMountID(mountID)
      end
      if (not db) and spellID and ns.CompletionMountDB.GetBySpellID then
        local data, resolvedMountID = ns.CompletionMountDB.GetBySpellID(spellID)
        db = data or db
        if (not mountID) and resolvedMountID then
          mountID = resolvedMountID
        end
      end
    end
    local out = {
      mountID = asNumber(mountID),
      spellID = asNumber(spellID),
      name = (explicit and explicit.name) or (db and db.name) or nil,
      sourceText = db and db.sourceText or nil,
      sourceType = asNumber(db and db.sourceType),
    }
    _mountDataCache[itemID] = out
    return out
  end

  _mountDataCache[itemID] = false
  return nil
end

local function getMountSpellIDFromItemID(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end

  local data = getMountDataFromItemID(itemID)
  if data and data.spellID then
    return data.spellID
  end

  if C_Item and C_Item.GetItemSpell then
    local ok, _, spellID = pcall(C_Item.GetItemSpell, itemID)
    if ok and spellID and spellID ~= 0 then
      return spellID
    end
  end

  return MOUNT_ITEM_TO_SPELL_OVERRIDE[itemID]
end


local _petSpeciesNameIndex = nil
local _petSpeciesIndexBuilt = false

local function buildPetSpeciesNameIndex()
  if _petSpeciesIndexBuilt then return _petSpeciesNameIndex or {} end
  _petSpeciesIndexBuilt = true
  _petSpeciesNameIndex = {}

  local db = ns.CompletionPetSpeciesDB
  if not (db and db.IterateIDs and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID) then
    return _petSpeciesNameIndex
  end

  for _, speciesID in db.IterateIDs() do
    local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
    if ok and type(name) == "string" and name ~= "" then
      local norm = normalizeName(name)
      if norm ~= "" and not _petSpeciesNameIndex[norm] then
        _petSpeciesNameIndex[norm] = speciesID
      end
    end
  end

  return _petSpeciesNameIndex
end

local function resolvePetSpeciesIDByName(itemID, group)
  local itemName = getAnyItemName(itemID, group)
  local norm = normalizeName(itemName)
  if norm == "" then return nil, { source = "name_lookup_empty", itemName = itemName, normalizedName = norm } end

  local idx = buildPetSpeciesNameIndex()
  local speciesID = asNumber(idx[norm])
  return speciesID, {
    source = speciesID and "name_lookup" or "name_lookup_miss",
    itemName = itemName,
    normalizedName = norm,
  }
end

local function getPetSpeciesIDDirect(rawID)
  rawID = asNumber(rawID)
  if not rawID or not C_PetJournal then return nil, { source = "direct_invalid" } end

  if C_PetJournal.GetNumCollectedInfo then
    local okSpecies, owned, total = pcall(C_PetJournal.GetNumCollectedInfo, rawID)
    if okSpecies and type(total) == "number" and total > 0 then
      return rawID, {
        source = "species_direct",
        collectedCount = tonumber(owned) or 0,
        totalCount = tonumber(total) or 0,
      }
    end
  end

  if not C_PetJournal.GetPetInfoByItemID then
    return nil, { source = "direct_api_missing" }
  end

  local ok, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, r13 = pcall(C_PetJournal.GetPetInfoByItemID, rawID)
  if not ok then
    return nil, { source = "direct_error" }
  end

  if type(r1) == "table" then
    local speciesID = asNumber(r1.speciesID or r1[13])
    if speciesID then
      return speciesID, { source = "item_api_table" }
    end
  end
  if type(r13) == "number" and r13 > 0 then
    return r13, { source = "item_api_r13" }
  end
  for idx, v in ipairs({ r1, r2, r3, r4, r5 }) do
    if type(v) == "number" and v > 0 then
      return v, { source = "item_api_r" .. tostring(idx) }
    end
  end
  return nil, { source = "item_api_miss" }
end

local function getPetSpeciesIDFromItemDB(rawID)
  rawID = asNumber(rawID)
  if not rawID then return nil, { source = "pet_item_db_invalid" } end
  local row = ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(rawID) or nil
  if row and row.speciesID then
    return asNumber(row.speciesID), {
      source = "pet_item_db",
      itemName = row.itemName,
      normalizedName = normalizeName(row.name or row.itemName),
      dbName = row.name,
    }
  end
  return nil, { source = "pet_item_db_miss" }
end

local function getPetSpeciesResolution(rawID, group)
  rawID = asNumber(rawID)
  if not rawID then return nil, { source = "invalid" } end
  local cached = _petResolutionCache[rawID]
  if cached then
    return cached[1], cached[2]
  end
  local fromDB, dbMeta = getPetSpeciesIDFromItemDB(rawID)
  if fromDB then
    dbMeta = dbMeta or {}
    dbMeta.source = dbMeta.source or "pet_item_db"
    _petResolutionCache[rawID] = { fromDB, dbMeta }
    return fromDB, dbMeta
  end

  local direct, directMeta = getPetSpeciesIDDirect(rawID)
  if direct then
    directMeta = directMeta or {}
    directMeta.source = directMeta.source or "direct"
    _petResolutionCache[rawID] = { direct, directMeta }
    return direct, directMeta
  end

  local fallback, fallbackMeta = resolvePetSpeciesIDByName(rawID, group)
  fallbackMeta = fallbackMeta or {}
  fallbackMeta.source = fallbackMeta.source or "name_lookup"
  _petResolutionCache[rawID] = { fallback, fallbackMeta }
  return fallback, fallbackMeta
end



local function getHousingDataFromItemID(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  return ns.CompletionHousingItemDB and ns.CompletionHousingItemDB.Get and ns.CompletionHousingItemDB.Get(itemID) or nil
end

local function isKnownHousingItem(itemID)
  itemID = asNumber(itemID)
  if not itemID then return false end
  return getHousingDataFromItemID(itemID) and true or false
end

local function getToyDataFromItemID(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  return ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) or nil
end

local function isKnownToyItem(itemID)
  itemID = asNumber(itemID)
  if not itemID then return false end
  return getToyDataFromItemID(itemID) and true or false
end

local function getAppearanceDataFromItemID(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  return ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get and ns.CompletionAppearanceItemDB.Get(itemID) or nil
end

local function isKnownAppearanceItem(itemID)
  itemID = asNumber(itemID)
  if not itemID then return false end
  return getAppearanceDataFromItemID(itemID) and true or false
end


local APPEARANCE_SECTION_HINTS = {
  ["Head"] = true,
  ["Shoulder"] = true,
  ["Chest"] = true,
  ["Wrist"] = true,
  ["Hands"] = true,
  ["Waist"] = true,
  ["Legs"] = true,
  ["Feet"] = true,
  ["Back"] = true,
  ["Armor"] = true,
  ["Shirt"] = true,
  ["Tabard"] = true,
  ["1H"] = true,
  ["2H"] = true,
  ["Dagger"] = true,
  ["Staff"] = true,
  ["Wand"] = true,
  ["Ranged"] = true,
  ["Off-hand"] = true,
  ["Off Hand"] = true,
  ["Shield"] = true,
  ["Weapon"] = true,
  ["Main Hand"] = true,
  ["One-Hand"] = true,
  ["Two-Hand"] = true,
}

local function classifyUnresolvedCandidate(rawID, group, reason)
  rawID = asNumber(rawID)
  if not rawID then return nil, 'invalid' end
  local section = ns.GetItemSectionFast and ns.GetItemSectionFast(rawID) or 'Misc'
  if reason == 'mount_unresolved' or section == 'Mounts' or isExplicitRaidMount(group, rawID) or looksLikeMountDrop(group, rawID) then
    return 'mount', section
  end
  if reason == 'pet_unresolved' or section == 'Pets' then
    return 'pet', section
  end
  if section == 'Toys' or isKnownToyItem(rawID) then
    return 'toy', section
  end
  if section == 'Housing' or isKnownHousingItem(rawID) or (ns.IsHousingItemID and ns.IsHousingItemID(rawID)) then
    return 'housing', section
  end
  if APPEARANCE_SECTION_HINTS[section] or isKnownAppearanceItem(rawID) then
    return 'appearance', section
  end
  return nil, section
end

local function resolveEntry(rawID, group)
  rawID = asNumber(rawID)
  if not rawID then return nil, "invalid" end

  local section = ns.GetItemSectionFast and ns.GetItemSectionFast(rawID) or "Misc"
  local realItem = appearsToBeRealItem(rawID)

  local mountData = nil
  if realItem then
    mountData = getMountDataFromItemID(rawID)
  elseif section == "Mounts" then
    local mountSpellID = getMountSpellIDFromMountID(rawID)
    if mountSpellID then
      mountData = { mountID = rawID, spellID = mountSpellID }
    end
  end

  if section == "Mounts" or isExplicitRaidMount(group, rawID) or looksLikeMountDrop(group, rawID) or (mountData and mountData.spellID) then
    local mountSpellID = mountData and mountData.spellID or nil
    if not mountSpellID then
      if realItem or looksLikeMountDrop(group, rawID) then
        mountSpellID = getMountSpellIDFromItemID(rawID)
      else
        mountSpellID = getMountSpellIDFromMountID(rawID)
      end
    end
    if mountSpellID then
      return {
        kind = "mount",
        identityType = "mountSpellID",
        identityValue = mountSpellID,
      }
    end
    return nil, "mount_unresolved"
  end

  local petSpeciesID, petMeta = nil, nil
  if realItem or section == "Pets" then
    petSpeciesID, petMeta = getPetSpeciesResolution(rawID, group)
  end

  if section == "Pets" or petSpeciesID then
    if petSpeciesID then
      return {
        kind = "pet",
        identityType = "petSpeciesID",
        identityValue = petSpeciesID,
        debug = {
          pet = {
            source = petMeta and petMeta.source or "unknown",
            itemName = petMeta and petMeta.itemName or getAnyItemName(rawID, group),
            normalizedName = petMeta and petMeta.normalizedName or nil,
            collectedCount = petMeta and petMeta.collectedCount or nil,
            totalCount = petMeta and petMeta.totalCount or nil,
          },
        },
      }
    end
    return nil, "pet_unresolved"
  end

  local toyData = nil
  if realItem or section == "Toys" then
    toyData = getToyDataFromItemID(rawID)
  end

  if section == "Toys" or toyData then
    return {
      kind = "toy",
      identityType = "toyItemID",
      identityValue = rawID,
      debug = {
        toy = {
          source = toyData and "toy_item_db" or "toy_section_only",
          itemName = (toyData and toyData.itemName) or getAnyItemName(rawID, group),
          sourceText = toyData and toyData.sourceText or nil,
          toyID = toyData and toyData.toyID or nil,
        },
      },
    }
  end

  local housingData = nil
  if realItem or section == "Housing" or (ns.IsHousingItemID and ns.IsHousingItemID(rawID)) then
    housingData = getHousingDataFromItemID(rawID)
  end

  if section == "Housing" or housingData or (ns.IsHousingItemID and ns.IsHousingItemID(rawID)) or isKnownHousingItem(rawID) then
    return {
      kind = "housing",
      identityType = "housingItemID",
      identityValue = rawID,
      debug = {
        housing = {
          source = housingData and "housing_item_db" or "housing_section_only",
          itemName = (housingData and (housingData.itemName ~= "" and housingData.itemName or housingData.decorName)) or getAnyItemName(rawID, group),
          decorID = housingData and housingData.decorID or nil,
          decorName = housingData and housingData.decorName or nil,
        },
      },
    }
  end

  local appearanceData = nil
  if realItem or APPEARANCE_SECTION_HINTS[section] or isKnownAppearanceItem(rawID) then
    appearanceData = getAppearanceDataFromItemID(rawID)
  end

  if appearanceData and appearanceData.appearanceID then
    return {
      kind = "appearance",
      identityType = "appearanceID",
      identityValue = appearanceData.appearanceID,
      debug = {
        appearance = {
          source = appearanceData.source or "appearance_item_db",
          itemName = getAnyItemName(rawID, group),
          appearanceID = appearanceData.appearanceID,
          appearanceIDs = appearanceData.appearanceIDs,
          modifiedAppearanceIDs = appearanceData.modifiedAppearanceIDs,
        },
      },
    }
  end

  return nil, "unsupported"
end

local function getAggregateKey(group)
  local category = tostring(group.category or "?")
  local instanceID = asNumber(group.instanceID)
  if instanceID then
    return ("ejinstance:%s:%d"):format(category, instanceID)
  end
  return ("name:%s:%s"):format(category, normalizeName(group.name))
end

function CD.Build()
  _wipe(CD.groups)
  _wipe(CD.entries)
  _wipe(CD.meta)
  _wipe(CD.aliases)
  _wipe(_realItemCache)
  _wipe(_itemNameCache)
  _wipe(_mountDataCache)
  _wipe(_mountLooksLikeCache)
  _wipe(_petResolutionCache)

  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then
    CD._built = false
    return false
  end

  local indexedGroups, builtEntries = 0, 0
  for rawGroupKey, group in pairs(groups) do
    if type(group) == "table" and SUPPORTED_CATEGORIES[group.category] and type(group.items) == "table" then
      indexedGroups = indexedGroups + 1
      local aggregateKey = getAggregateKey(group)
      local def = CD.groups[aggregateKey]
      if not def then
        def = {
          groupKey = aggregateKey,
          category = group.category,
          name = group.name,
          expansion = group.expansion,
          instanceID = group.instanceID,
          completionEntries = {},
          _entryLookup = {},
          _searchNames = {},
          sourceGroupKeys = {},
          sourceGroupIDs = {},
          rawGroupCount = 0,
          rawItemCount = 0,
          unsupportedItemCount = 0,
          unresolvedCandidates = {},
          unresolvedCandidateCount = 0,
          nonCollectibleCount = 0,
        }
        CD.groups[aggregateKey] = def
        addAlias(CD.aliases, group.name, aggregateKey)
        addAlias(CD.aliases, tostring(group.category or "") .. " " .. tostring(group.name or ""), aggregateKey)
      end

      def.rawGroupCount = (def.rawGroupCount or 0) + 1
      def.sourceGroupKeys[tostring(rawGroupKey)] = true
      def.sourceGroupIDs[tostring(group.id or rawGroupKey)] = true

      local aliasCandidates = {
        group.name,
        (group.category or "") .. " " .. (group.name or ""),
        aggregateKey,
        tostring(group.instanceID or ""),
        tostring(group.id or rawGroupKey),
      }
      for _, candidate in ipairs(aliasCandidates) do
        local norm = normalizeName(candidate)
        if norm ~= "" then
          def._searchNames[norm] = true
          addAlias(CD.aliases, norm, aggregateKey)
        end
      end

      for _, rawID in ipairs(group.items) do
        def.rawItemCount = def.rawItemCount + 1
        local resolved, unresolvedReason = resolveEntry(rawID, group)
        if resolved then
          local entryKey = table.concat({
            def.groupKey,
            resolved.kind,
            tostring(resolved.identityValue),
          }, ":")

          local entry = CD.entries[entryKey]
          if not entry then
            entry = {
              entryKey = entryKey,
              groupKey = def.groupKey,
              kind = resolved.kind,
              identity = {
                type = resolved.identityType,
                value = resolved.identityValue,
              },
              rawRefs = {},
              sourceGroupKeys = {},
              sourceGroupIDs = {},
              debug = {},
            }
            CD.entries[entryKey] = entry
            def._entryLookup[entryKey] = true
            table.insert(def.completionEntries, entryKey)
            builtEntries = builtEntries + 1
          end

          entry.sourceGroupKeys[tostring(rawGroupKey)] = true
          entry.sourceGroupIDs[tostring(group.id or rawGroupKey)] = true
          entry.rawRefs[#entry.rawRefs + 1] = rawID
          if resolved.debug then
            entry.debug = entry.debug or {}
            if resolved.debug.pet then
              entry.debug.pet = entry.debug.pet or { sources = {}, raw = {} }
              local petDbg = entry.debug.pet
              local source = tostring(resolved.debug.pet.source or "unknown")
              petDbg.sources[source] = (petDbg.sources[source] or 0) + 1
              petDbg.raw[tostring(rawID)] = {
                source = source,
                itemName = resolved.debug.pet.itemName,
                normalizedName = resolved.debug.pet.normalizedName,
                collectedCount = resolved.debug.pet.collectedCount,
                totalCount = resolved.debug.pet.totalCount,
              }
            end
            if resolved.debug.toy then
              entry.debug.toy = entry.debug.toy or { sources = {}, raw = {} }
              local toyDbg = entry.debug.toy
              local source = tostring(resolved.debug.toy.source or "unknown")
              toyDbg.sources[source] = (toyDbg.sources[source] or 0) + 1
              toyDbg.raw[tostring(rawID)] = {
                source = source,
                itemName = resolved.debug.toy.itemName,
                sourceText = resolved.debug.toy.sourceText,
                toyID = resolved.debug.toy.toyID,
              }
            end
            if resolved.debug.housing then
              entry.debug.housing = entry.debug.housing or { sources = {}, raw = {} }
              local housingDbg = entry.debug.housing
              local source = tostring(resolved.debug.housing.source or "unknown")
              housingDbg.sources[source] = (housingDbg.sources[source] or 0) + 1
              housingDbg.raw[tostring(rawID)] = {
                source = source,
                itemName = resolved.debug.housing.itemName,
                decorID = resolved.debug.housing.decorID,
                decorName = resolved.debug.housing.decorName,
              }
            end
            if resolved.debug.appearance then
              entry.debug.appearance = entry.debug.appearance or { sources = {}, raw = {}, appearanceIDs = {}, modifiedAppearanceIDs = {} }
              local appearanceDbg = entry.debug.appearance
              local source = tostring(resolved.debug.appearance.source or "unknown")
              appearanceDbg.sources[source] = (appearanceDbg.sources[source] or 0) + 1
              appearanceDbg.raw[tostring(rawID)] = {
                source = source,
                itemName = resolved.debug.appearance.itemName,
                appearanceID = resolved.debug.appearance.appearanceID,
                appearanceIDs = resolved.debug.appearance.appearanceIDs,
                modifiedAppearanceIDs = resolved.debug.appearance.modifiedAppearanceIDs,
              }
              local function addUniqueNumber(list, value)
                value = tonumber(value)
                if not value or value <= 0 then return end
                for i = 1, #list do
                  if tonumber(list[i]) == value then return end
                end
                list[#list + 1] = value
              end
              addUniqueNumber(appearanceDbg.appearanceIDs, resolved.debug.appearance.appearanceID)
              if type(resolved.debug.appearance.appearanceIDs) == "table" then
                for i = 1, #resolved.debug.appearance.appearanceIDs do
                  addUniqueNumber(appearanceDbg.appearanceIDs, resolved.debug.appearance.appearanceIDs[i])
                end
              end
              if type(resolved.debug.appearance.modifiedAppearanceIDs) == "table" then
                for i = 1, #resolved.debug.appearance.modifiedAppearanceIDs do
                  addUniqueNumber(appearanceDbg.modifiedAppearanceIDs, resolved.debug.appearance.modifiedAppearanceIDs[i])
                end
              end
            end
          end
        else
          def.unsupportedItemCount = def.unsupportedItemCount + 1
          local candidateKind, section = classifyUnresolvedCandidate(rawID, group, unresolvedReason)
          if candidateKind then
            def.unresolvedCandidates[candidateKind] = def.unresolvedCandidates[candidateKind] or { count = 0, items = {} }
            local bucket = def.unresolvedCandidates[candidateKind]
            bucket.count = (bucket.count or 0) + 1
            bucket.items[#bucket.items + 1] = {
              rawID = rawID,
              itemName = getAnyItemName(rawID, group),
              section = section,
            }
            def.unresolvedCandidateCount = (def.unresolvedCandidateCount or 0) + 1
          else
            def.nonCollectibleCount = (def.nonCollectibleCount or 0) + 1
          end
        end
      end
    end
  end

  for groupKey, def in pairs(CD.groups) do
    table.sort(def.completionEntries)
    def.totalSupported = #def.completionEntries
    CD.meta[groupKey] = {
      rawItemCount = def.rawItemCount,
      supportedEntryCount = def.totalSupported,
      unsupportedItemCount = def.unsupportedItemCount,
      unresolvedCandidateCount = def.unresolvedCandidateCount or 0,
      nonCollectibleCount = def.nonCollectibleCount or 0,
      rawGroupCount = def.rawGroupCount,
    }
    def._entryLookup = nil
  end

  CD._built = true
  CD._builtAt = GetTime and GetTime() or 0
  CD.buildRevision = (tonumber(CD.buildRevision) or 0) + 1
  CD._stats = {
    groups = indexedGroups,
    supportedGroups = 0,
    entries = builtEntries,
  }

  for _, def in pairs(CD.groups) do
    if tonumber(def.totalSupported or 0) > 0 then
      CD._stats.supportedGroups = (CD._stats.supportedGroups or 0) + 1
    end
  end

  return true
end

function CD.EnsureBuilt()
  if not CD._built then
    return CD.Build()
  end
  return true
end

function CD.GetGroup(groupKey)
  if not CD._built then CD.Build() end
  return CD.groups and CD.groups[tostring(groupKey)] or nil
end

function CD.GetAllGroups()
  if not CD._built then CD.Build() end
  return CD.groups
end

function CD.GetEntriesForGroup(groupKey)
  if not CD._built then CD.Build() end
  local group = CD.groups and CD.groups[tostring(groupKey)] or nil
  if not group then return nil end
  local out = {}
  for _, entryKey in ipairs(group.completionEntries or {}) do
    local entry = CD.entries and CD.entries[entryKey] or nil
    if entry then out[#out + 1] = entry end
  end
  return out
end

function CD.GetSupportedGroups(category)
  if not CD._built then CD.Build() end
  local out = {}
  for _, group in pairs(CD.groups or {}) do
    if type(group) == "table" and tonumber(group.totalSupported or 0) > 0 then
      if not category or group.category == category then
        out[#out + 1] = group
      end
    end
  end
  table.sort(out, function(a, b)
    local an = tostring((a and a.name) or a.groupKey or "")
    local bn = tostring((b and b.name) or b.groupKey or "")
    if an == bn then
      return tostring(a.groupKey or "") < tostring(b.groupKey or "")
    end
    return an < bn
  end)
  return out
end

function CD.ResolveGroupKey(input)
  if not CD._built then CD.Build() end
  input = tostring(input or ""):match("^%s*(.-)%s*$") or ""
  if input == "" then return nil end

  if CD.groups and CD.groups[input] and tonumber(CD.groups[input].totalSupported or 0) > 0 then
    return input, CD.groups[input], "exact_key"
  end

  local needle = normalizeName(input)
  if needle == "" then return nil end
  local needleNoThe = needle:gsub("^the ", "")

  local exactMatches, partialMatches = {}, {}
  local seenExact, seenPartial = {}, {}

  local function pushExact(groupKey, group)
    if groupKey and group and not seenExact[groupKey] and tonumber(group.totalSupported or 0) > 0 then
      seenExact[groupKey] = true
      exactMatches[#exactMatches + 1] = { groupKey = groupKey, group = group }
    end
  end

  local function pushPartial(groupKey, group)
    if groupKey and group and not seenExact[groupKey] and not seenPartial[groupKey] and tonumber(group.totalSupported or 0) > 0 then
      seenPartial[groupKey] = true
      partialMatches[#partialMatches + 1] = { groupKey = groupKey, group = group }
    end
  end

  local function checkCandidate(groupKey, group, candidate)
    candidate = normalizeName(candidate)
    if candidate == "" then return end
    local candidateNoThe = candidate:gsub("^the ", "")
    if needle == candidate or needleNoThe == candidateNoThe then
      pushExact(groupKey, group)
    elseif candidate:find(needle, 1, true) or needle:find(candidate, 1, true) or candidateNoThe:find(needleNoThe, 1, true) or needleNoThe:find(candidateNoThe, 1, true) then
      pushPartial(groupKey, group)
    end
  end

  local aliasHits = CD.aliases and (CD.aliases[needle] or CD.aliases[needleNoThe]) or nil
  if aliasHits then
    for groupKey in pairs(aliasHits) do
      pushExact(groupKey, CD.groups and CD.groups[groupKey] or nil)
    end
  end

  for groupKey, group in pairs(CD.groups or {}) do
    if type(group) == "table" and tonumber(group.totalSupported or 0) > 0 then
      checkCandidate(groupKey, group, group.name)
      checkCandidate(groupKey, group, (group.category or "") .. " " .. (group.name or ""))
      checkCandidate(groupKey, group, groupKey)
      checkCandidate(groupKey, group, group.instanceID)
      if type(group._searchNames) == "table" then
        for candidate in pairs(group._searchNames) do
          checkCandidate(groupKey, group, candidate)
        end
      end
    end
  end

  local function sorter(a, b)
    local an = tostring((a.group and a.group.name) or a.groupKey or "")
    local bn = tostring((b.group and b.group.name) or b.groupKey or "")
    if an == bn then return tostring(a.groupKey or "") < tostring(b.groupKey or "") end
    return an < bn
  end

  if #exactMatches == 1 then
    return exactMatches[1].groupKey, exactMatches[1].group, "exact_name"
  elseif #exactMatches > 1 then
    table.sort(exactMatches, sorter)
    return nil, exactMatches, "ambiguous"
  end

  if #partialMatches == 1 then
    return partialMatches[1].groupKey, partialMatches[1].group, "partial_name"
  elseif #partialMatches > 1 then
    table.sort(partialMatches, sorter)
    return nil, partialMatches, "ambiguous"
  end

  return nil, {}, "none"
end



function CD.GetUnresolvedCandidates(groupKey)
  if not CD._built then CD.Build() end
  local group = CD.groups and CD.groups[tostring(groupKey)] or nil
  return group and group.unresolvedCandidates or nil
end

function CD.GetGroupMeta(groupKey)
  if not CD._built then CD.Build() end
  return CD.meta and CD.meta[tostring(groupKey)] or nil
end

function CD.GetStats()
  if not CD._built then CD.Build() end
  return CD._stats or { groups = 0, supportedGroups = 0, entries = 0 }
end
