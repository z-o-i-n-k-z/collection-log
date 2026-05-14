local ADDON, ns = ...

ns.CompletionSnapshot = ns.CompletionSnapshot or {}
local CS = ns.CompletionSnapshot

CS.current = CS.current or nil

local function safePairs(tbl)
  if type(tbl) ~= "table" then return function() return nil end end
  return pairs(tbl)
end

local function ensureCollectionsLoaded()
  if LoadAddOn then
    pcall(LoadAddOn, "Blizzard_Collections")
  end
end

local function buildMountJournalIndex()
  local index = {
    spellToMountID = {},
    ownedBySpell = {},
    mountIDToCollected = {},
  }

  if not (C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID) then
    return index
  end

  local ids = (ns.GetValidMountJournalIDs and ns.GetValidMountJournalIDs(true)) or C_MountJournal.GetMountIDs()
  if type(ids) ~= "table" then return index end

  for _, mountID in ipairs(ids) do
    local ok, name, spellID, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
    if ok and spellID and spellID ~= 0 then
      index.spellToMountID[spellID] = mountID
      index.mountIDToCollected[mountID] = isCollected and true or false
      if isCollected then
        index.ownedBySpell[spellID] = true
      end
    end
  end

  return index
end

local function safeCollectedPetSpecies(speciesID)
  if not speciesID or not (C_PetJournal and C_PetJournal.GetNumCollectedInfo) then return false, 0, 0 end
  local ok, owned, total = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
  owned = ok and tonumber(owned) or 0
  total = ok and tonumber(total) or 0
  return ok and owned > 0 or false, owned, total
end

local function safeCollectedToy(itemID)
  if not itemID then return false end
  if PlayerHasToy then
    local ok, hasToy = pcall(PlayerHasToy, itemID)
    if ok and hasToy then return true end
  end
  if C_ToyBox and C_ToyBox.HasToy then
    local ok, hasToy = pcall(C_ToyBox.HasToy, itemID)
    if ok and hasToy then return true end
  end
  if C_ToyBox and C_ToyBox.GetToyFromItemID and PlayerHasToy then
    local ok, toyID = pcall(C_ToyBox.GetToyFromItemID, itemID)
    if ok and toyID and toyID ~= 0 then
      local ok2, hasToy2 = pcall(PlayerHasToy, toyID)
      if ok2 and hasToy2 then return true end
    end
  end
  return false
end

local appearanceOwnedMemo = {}
local appearanceOwnershipIndex = nil
local sharedSourceInfoCache = {}
local appearanceScanCache = { revision = nil, appearanceIDs = nil, sourceIDs = nil }

local function safeTruthy(value)
  return value == true or value == 1
end

local SLOT_BY_INVENTORY_TYPE = {
  [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5,
  [6] = 6, [7] = 7, [8] = 8,
  [9] = 9, [10] = 10,
  [11] = 11, [12] = 12,
  [13] = 13, [14] = 14,
  [15] = 15, [16] = 16, [17] = 17,
 [20] = 5, -- robe/chest handling is also special-cased below
 [21] = 16, [22] = 17, [23] = 5, [24] = 16, [25] = 17,
 [26] = 16, [27] = 17, [28] = 16,
}

local function sameEquipBucket(a, b)
  if not a or not b then return false end
  if a == b then return true end
  local sa = SLOT_BY_INVENTORY_TYPE[a]
  local sb = SLOT_BY_INVENTORY_TYPE[b]
  return sa and sb and sa == sb or false
end

local function sameATTVisualBucket(knownInfo, otherInfo)
  if type(knownInfo) ~= "table" or type(otherInfo) ~= "table" then return false end
  if tonumber(knownInfo.categoryID) ~= tonumber(otherInfo.categoryID) then return false end
  local knownInv = tonumber(knownInfo.invType)
  local otherInv = tonumber(otherInfo.invType)
  if knownInv and otherInv then
    if knownInv == otherInv then return true end
    if tonumber(knownInfo.categoryID) == 4 then return true end -- chest robe vs chest armor
    if sameEquipBucket(knownInv, otherInv) then return true end
  end
  return false
end

local function safeCollectedSource(sourceID)
  sourceID = tonumber(sourceID)
  if not sourceID or sourceID <= 0 or not C_TransmogCollection then return false, nil end

  if C_TransmogCollection.PlayerKnowsSource then
    local ok, known = pcall(C_TransmogCollection.PlayerKnowsSource, sourceID)
    if ok and known then
      return true, "knows_source"
    end
  end

  if C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    local ok, known = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
    if ok and known then
      return true, "modified_source"
    end
  end

  if C_TransmogCollection.GetSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetSourceInfo, sourceID)
    if ok and type(info) == "table" and safeTruthy(info.isCollected) then
      return true, "source_info"
    end
  end

  if C_TransmogCollection.GetAppearanceSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
    if ok and type(info) == "table" and safeTruthy(info.isCollected) then
      return true, "appearance_source_info"
    end
  end

  return false, nil
end

local function getSourceInfoCached(index, sourceID)
  sourceID = tonumber(sourceID)
  if not sourceID or sourceID <= 0 then return nil end
  local cached = index.sourceInfoBySourceID[sourceID]
  if cached == nil then cached = sharedSourceInfoCache[sourceID] end
  if cached ~= nil then
    return cached ~= false and cached or nil
  end
  local info = nil
  if C_TransmogCollection and C_TransmogCollection.GetSourceInfo then
    local ok, res = pcall(C_TransmogCollection.GetSourceInfo, sourceID)
    if ok and type(res) == "table" then
      info = res
    end
  end
  if not info and C_TransmogCollection and C_TransmogCollection.GetAppearanceSourceInfo then
    local ok, res = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
    if ok and type(res) == "table" then
      info = res
    end
  end
  index.sourceInfoBySourceID[sourceID] = info or false
  sharedSourceInfoCache[sourceID] = info or false
  return info
end

local function ensureAppearanceOwnershipIndex(definitions)
  if appearanceOwnershipIndex then return appearanceOwnershipIndex end

  local index = {
    ownedAppearances = {},
    ownedModifiedAppearanceIDs = {},
    ownedSourceIDs = {},
    sharedOwnedSourceIDs = {},
    appearanceToOwnedSourceID = {},
    appearanceToAllSourceIDs = {},
    sourceInfoBySourceID = {},
    visualToSourceIDs = {},
    sourceToAppearanceIDs = {},
  }

  local revision = ns.CompletionDefinitions and ns.CompletionDefinitions.buildRevision or nil
  local appearanceIDsToScan = appearanceScanCache.appearanceIDs
  local sourceIDsToScan = appearanceScanCache.sourceIDs

  local function addNum(set, value)
    value = tonumber(value)
    if value and value > 0 then set[value] = true end
  end

  local function addList(set, list)
    if type(list) ~= 'table' then return end
    for i = 1, #list do
      addNum(set, list[i])
    end
  end

  if appearanceScanCache.revision ~= revision or type(appearanceIDsToScan) ~= 'table' or type(sourceIDsToScan) ~= 'table' then
    appearanceIDsToScan = {}
    sourceIDsToScan = {}
    if type(definitions) == 'table' then
      for _, group in safePairs(definitions) do
        if type(group) == 'table' then
          for _, entryKey in ipairs(group.completionEntries or {}) do
            local entry = ns.CompletionDefinitions and ns.CompletionDefinitions.entries and ns.CompletionDefinitions.entries[entryKey] or nil
            if entry and entry.kind == 'appearance' and entry.identity then
              addNum(appearanceIDsToScan, entry.identity.value)
              local dbg = entry.debug and entry.debug.appearance or nil
              if dbg then
                addList(appearanceIDsToScan, dbg.appearanceIDs)
                addList(sourceIDsToScan, dbg.modifiedAppearanceIDs)
                if type(dbg.raw) == 'table' then
                  for _, row in pairs(dbg.raw) do
                    if type(row) == 'table' then
                      addNum(appearanceIDsToScan, row.appearanceID)
                      addList(appearanceIDsToScan, row.appearanceIDs)
                      addList(sourceIDsToScan, row.modifiedAppearanceIDs)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    appearanceScanCache.revision = revision
    appearanceScanCache.appearanceIDs = appearanceIDsToScan
    appearanceScanCache.sourceIDs = sourceIDsToScan
  end

  for sourceID in pairs(sourceIDsToScan) do
    local info = getSourceInfoCached(index, sourceID)
    if type(info) == 'table' then
      local visualID = tonumber(info.visualID)
      if visualID and visualID > 0 then
        local list = index.visualToSourceIDs[visualID]
        if not list then
          list = {}
          index.visualToSourceIDs[visualID] = list
        end
        list[#list + 1] = sourceID
      end
    end
    local owned, kind = safeCollectedSource(sourceID)
    if owned then
      index.ownedSourceIDs[sourceID] = kind or true
      index.ownedModifiedAppearanceIDs[sourceID] = kind or true
      if type(info) == 'table' and tonumber(info.visualID) then
        index.ownedAppearances[tonumber(info.visualID)] = true
      end
    end
  end

  for sourceID in pairs(sourceIDsToScan) do
    local info = getSourceInfoCached(index, sourceID)
    if type(info) == 'table' then
      local visualID = tonumber(info.visualID)
      if visualID and visualID > 0 then
        if index.ownedSourceIDs[sourceID] then
          index.appearanceToOwnedSourceID[visualID] = index.appearanceToOwnedSourceID[visualID] or sourceID
        end
        local sourceList = index.appearanceToAllSourceIDs[visualID]
        if not sourceList then
          sourceList = {}
          index.appearanceToAllSourceIDs[visualID] = sourceList
        end
        sourceList[#sourceList + 1] = sourceID
      end
    end
  end

  for sourceID in pairs(index.ownedSourceIDs) do
    local knownInfo = getSourceInfoCached(index, sourceID)
    local visualID = knownInfo and tonumber(knownInfo.visualID) or nil
    local siblings = visualID and index.visualToSourceIDs[visualID] or nil
    if siblings then
      for i = 1, #siblings do
        local otherSourceID = tonumber(siblings[i])
        if otherSourceID and not index.ownedSourceIDs[otherSourceID] then
          local otherInfo = getSourceInfoCached(index, otherSourceID)
          if sameATTVisualBucket(knownInfo, otherInfo) then
            index.sharedOwnedSourceIDs[otherSourceID] = sourceID
            index.ownedModifiedAppearanceIDs[otherSourceID] = "shared_visual"
            if visualID and visualID > 0 then
              index.ownedAppearances[visualID] = true
              index.appearanceToOwnedSourceID[visualID] = index.appearanceToOwnedSourceID[visualID] or sourceID
            end
          end
        end
      end
    end
  end

  for appearanceID in pairs(appearanceIDsToScan) do
    if not index.ownedAppearances[appearanceID] then
      if C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemAppearance then
        local ok, hasAppearance = pcall(C_TransmogCollection.PlayerHasTransmogItemAppearance, appearanceID)
        if ok and hasAppearance then
          index.ownedAppearances[appearanceID] = true
        end
      end
      if (not index.ownedAppearances[appearanceID]) and C_TransmogCollection and C_TransmogCollection.GetAppearanceInfoByID then
        local ok, info = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
        if ok and type(info) == 'table' and safeTruthy(info.isCollected) then
          index.ownedAppearances[appearanceID] = true
        end
      end
    end
  end

  appearanceOwnershipIndex = index
  appearanceOwnedMemo = {}
  return index
end

local function safeCollectedAppearance(appearanceID)
  appearanceID = tonumber(appearanceID)
  if not appearanceID or appearanceID <= 0 then return false, nil, nil end

  local memo = appearanceOwnedMemo[appearanceID]
  if memo ~= nil then
    return memo.owned, memo.source, memo.matchedSourceID
  end

  local owned, source, matchedSourceID = false, nil, nil
  local index = appearanceOwnershipIndex
  if index then
    if index.appearanceToOwnedSourceID[appearanceID] then
      owned = true
      matchedSourceID = index.appearanceToOwnedSourceID[appearanceID]
      source = index.ownedSourceIDs[matchedSourceID] and "source_exact" or "appearance_any_source"
    elseif index.ownedAppearances[appearanceID] then
      owned = true
      source = "appearance_index"
    end
  end

  if not owned and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemAppearance then
    local ok, hasAppearance = pcall(C_TransmogCollection.PlayerHasTransmogItemAppearance, appearanceID)
    if ok and hasAppearance then
      owned, source = true, "appearance_api"
    end
  end

  if not owned and C_TransmogCollection and C_TransmogCollection.GetAppearanceInfoByID then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
    if ok and type(info) == "table" and safeTruthy(info.isCollected) then
      owned, source = true, "appearance_info"
    end
  end

  appearanceOwnedMemo[appearanceID] = {
    owned = owned and true or false,
    source = source,
    matchedSourceID = matchedSourceID,
  }
  return owned and true or false, source, matchedSourceID
end

local function safeCollectedAppearanceCandidates(candidateIDs)
  if type(candidateIDs) ~= "table" then return false, nil, nil, nil end
  local seen = {}
  for i = 1, #candidateIDs do
    local appearanceID = tonumber(candidateIDs[i])
    if appearanceID and appearanceID > 0 and not seen[appearanceID] then
      seen[appearanceID] = true
      local owned, source, matchedSourceID = safeCollectedAppearance(appearanceID)
      if owned then
        return true, source or "appearance_candidates", appearanceID, matchedSourceID
      end
    end
  end
  return false, "appearance_candidates", nil, nil
end

local function safeCollectedModifiedAppearanceCandidates(candidateIDs)
  if type(candidateIDs) ~= "table" then return false, nil, nil, nil end
  local index = appearanceOwnershipIndex
  local seen = {}
  for i = 1, #candidateIDs do
    local sourceID = tonumber(candidateIDs[i])
    if sourceID and sourceID > 0 and not seen[sourceID] then
      seen[sourceID] = true
      if index then
        if index.ownedSourceIDs[sourceID] then
          return true, "source_exact", sourceID, sourceID
        end
        if index.sharedOwnedSourceIDs[sourceID] then
          return true, "appearance_any_source", sourceID, index.sharedOwnedSourceIDs[sourceID]
        end
        if index.ownedModifiedAppearanceIDs[sourceID] then
          return true, "modified_appearance_index", sourceID, sourceID
        end
      end
      local owned, kind = safeCollectedSource(sourceID)
      if owned then
        return true, kind or "modified_source_candidates", sourceID, sourceID
      end
    end
  end
  return false, "modified_appearance_candidates", nil, nil
end
local function collectUniqueNumbers(out, values)
  if type(values) ~= "table" then return out end
  out = out or {}
  local seen = {}
  for i = 1, #out do
    local v = tonumber(out[i])
    if v and v > 0 then seen[v] = true end
  end
  for i = 1, #values do
    local v = tonumber(values[i])
    if v and v > 0 and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  return out
end

local function gatherAppearanceDebugIDs(entry)
  local appearanceIDs, modifiedAppearanceIDs = nil, nil
  local dbg = entry and entry.debug and entry.debug.appearance or nil
  if dbg then
    appearanceIDs = collectUniqueNumbers(appearanceIDs, dbg.appearanceIDs)
    modifiedAppearanceIDs = collectUniqueNumbers(modifiedAppearanceIDs, dbg.modifiedAppearanceIDs)
    if type(dbg.raw) == "table" then
      for _, row in pairs(dbg.raw) do
        if type(row) == "table" then
          appearanceIDs = collectUniqueNumbers(appearanceIDs, row.appearanceIDs)
          modifiedAppearanceIDs = collectUniqueNumbers(modifiedAppearanceIDs, row.modifiedAppearanceIDs)
          if row.appearanceID then
            appearanceIDs = collectUniqueNumbers(appearanceIDs, { row.appearanceID })
          end
        end
      end
    end
  end
  return appearanceIDs, modifiedAppearanceIDs
end

function CS.Build(definitions)
  ensureCollectionsLoaded()
  appearanceOwnershipIndex = nil
  appearanceOwnedMemo = {}
  ensureAppearanceOwnershipIndex(definitions)

  local snapshot = {
    revision = (CS.current and (CS.current.revision or 0) or 0) + 1,
    builtAt = GetTime and GetTime() or 0,
    owned = {
      mounts = {},
      pets = {},
      toys = {},
      housing = {},
      appearances = {},
    },
    debug = {
      mounts = {},
      pets = {},
      toys = {},
      housing = {},
      appearances = {},
    },
  }

  if type(definitions) ~= "table" then
    CS.current = snapshot
    return snapshot
  end

  local mountIndex = buildMountJournalIndex()
  snapshot.debug.mountJournalSize = 0
  for _ in pairs(mountIndex.spellToMountID or {}) do
    snapshot.debug.mountJournalSize = snapshot.debug.mountJournalSize + 1
  end

  local seenMounts, seenPets, seenToys, seenHousing, seenAppearances = {}, {}, {}, {}, {}
  for _, group in safePairs(definitions) do
    if type(group) == "table" then
      for _, entryKey in ipairs(group.completionEntries or {}) do
        local entry = ns.CompletionDefinitions and ns.CompletionDefinitions.entries and ns.CompletionDefinitions.entries[entryKey] or nil
        if entry and entry.identity then
          local value = tonumber(entry.identity.value)
          if entry.kind == "mount" and value and not seenMounts[value] then
            seenMounts[value] = true

            local mountID = mountIndex.spellToMountID[value]
            local ownedByJournal = mountIndex.ownedBySpell[value] and true or false
            local ownedByRawItem = false
            local rawChecks = {}

            for _, rawID in ipairs(entry.rawRefs or {}) do
              rawID = tonumber(rawID)
              if rawID and rawChecks[rawID] == nil then
                local hasByItem = false
                if ns.IsMountItemCollected then
                  local ok, res = pcall(ns.IsMountItemCollected, rawID)
                  hasByItem = ok and res and true or false
                end
                rawChecks[rawID] = hasByItem
                if hasByItem then
                  ownedByRawItem = true
                end
              end
            end

            if ownedByJournal or ownedByRawItem then
              snapshot.owned.mounts[value] = true
            end

            snapshot.debug.mounts[value] = {
              spellID = value,
              mountID = mountID,
              ownedByJournal = ownedByJournal,
              ownedByRawItem = ownedByRawItem,
              resolved = (ownedByJournal or ownedByRawItem) and true or false,
              rawChecks = rawChecks,
            }
          elseif entry.kind == "pet" and value and not seenPets[value] then
            seenPets[value] = true
            local owned, ownedCount, totalCount = safeCollectedPetSpecies(value)
            if owned then snapshot.owned.pets[value] = true end
            snapshot.debug.pets[value] = {
              speciesID = value,
              owned = owned and true or false,
              ownedCount = tonumber(ownedCount) or 0,
              totalCount = tonumber(totalCount) or 0,
            }
          elseif entry.kind == "toy" and value and not seenToys[value] then
            seenToys[value] = true
            local owned = safeCollectedToy(value)
            if owned then snapshot.owned.toys[value] = true end
            local toyID = nil
            if C_ToyBox and C_ToyBox.GetToyFromItemID then
              local ok, resolvedToyID = pcall(C_ToyBox.GetToyFromItemID, value)
              if ok and resolvedToyID and resolvedToyID ~= 0 then toyID = resolvedToyID end
            end
            snapshot.debug.toys[value] = {
              itemID = value,
              toyID = toyID,
              owned = owned and true or false,
            }
          elseif entry.kind == "housing" and value and not seenHousing[value] then
            seenHousing[value] = true
            local owned = false
            if ns.IsHousingCollected then
              local ok, res = pcall(ns.IsHousingCollected, value)
              owned = ok and res and true or false
            elseif ns.IsHousingDecorCollected then
              local ok, res = pcall(ns.IsHousingDecorCollected, value)
              owned = ok and res and true or false
            end
            if owned then snapshot.owned.housing[value] = true end
            local decorID = nil
            if ns.GetHousingDecorRecordID then
              local ok, rid = pcall(ns.GetHousingDecorRecordID, value)
              if ok and rid and rid ~= 0 then decorID = rid end
            end
            snapshot.debug.housing[value] = {
              itemID = value,
              decorID = decorID,
              owned = owned and true or false,
            }
          elseif entry.kind == "appearance" and value and not seenAppearances[value] then
            seenAppearances[value] = true
            local candidateIDs, modifiedAppearanceIDs = gatherAppearanceDebugIDs(entry)
            local owned, source, matchedAppearanceID, matchedSourceID = safeCollectedAppearance(value)
            local matchedModifiedAppearanceID = nil
            if owned then
              matchedAppearanceID = value
            end
            if not owned and modifiedAppearanceIDs and #modifiedAppearanceIDs > 0 then
              owned, source, matchedModifiedAppearanceID, matchedSourceID = safeCollectedModifiedAppearanceCandidates(modifiedAppearanceIDs)
              if owned then
                matchedAppearanceID = value
              end
            end
            if not owned and candidateIDs and #candidateIDs > 0 then
              owned, source, matchedAppearanceID, matchedSourceID = safeCollectedAppearanceCandidates(candidateIDs)
            end
            if owned then snapshot.owned.appearances[value] = true end
            snapshot.debug.appearances[value] = {
              appearanceID = value,
              matchedAppearanceID = matchedAppearanceID,
              matchedModifiedAppearanceID = matchedModifiedAppearanceID,
              candidateAppearanceIDs = candidateIDs,
              candidateModifiedAppearanceIDs = modifiedAppearanceIDs,
              owned = owned and true or false,
              source = source,
              matchedSourceID = matchedSourceID,
            }
          end
        end
      end
    end
  end

  CS.current = snapshot
  return snapshot
end

function CS.GetCurrent()
  return CS.current
end

function CS.GetMountDebug(spellID)
  local cur = CS.current
  if not cur or not cur.debug or not cur.debug.mounts then return nil end
  return cur.debug.mounts[tonumber(spellID)]
end


function CS.GetPetDebug(speciesID)
  local cur = CS.current
  if not cur or not cur.debug or not cur.debug.pets then return nil end
  return cur.debug.pets[tonumber(speciesID)]
end


function CS.GetToyDebug(itemID)
  local cur = CS.current
  if not cur or not cur.debug or not cur.debug.toys then return nil end
  return cur.debug.toys[tonumber(itemID)]
end


function CS.GetHousingDebug(itemID)
  local cur = CS.current
  if not cur or not cur.debug or not cur.debug.housing then return nil end
  return cur.debug.housing[tonumber(itemID)]
end


function CS.GetAppearanceDebug(appearanceID)
  local cur = CS.current
  if not cur or not cur.debug or not cur.debug.appearances then return nil end
  return cur.debug.appearances[tonumber(appearanceID)]
end
