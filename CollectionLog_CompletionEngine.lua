local ADDON, ns = ...

ns.CompletionEngine = ns.CompletionEngine or {}
local CE = ns.CompletionEngine

CE.groupTotals = CE.groupTotals or {}
CE.entryStates = CE.entryStates or {}
CE.latestChanges = CE.latestChanges or {}
CE.overviewTotals = CE.overviewTotals or {}

local function _wipe(tbl)
  if not tbl then return end
  if wipe then wipe(tbl) else for k in pairs(tbl) do tbl[k] = nil end end
end

local function getPrevStateStore()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.completionBackend = CollectionLogDB.completionBackend or {
    version = 1,
    previousEntryState = {},
    history = {},
  }
  CollectionLogDB.completionBackend.previousEntryState = CollectionLogDB.completionBackend.previousEntryState or {}
  CollectionLogDB.completionBackend.history = CollectionLogDB.completionBackend.history or {}
  return CollectionLogDB.completionBackend.previousEntryState, CollectionLogDB.completionBackend
end

local function entryCollected(snapshot, entry)
  if not snapshot or not entry or not entry.identity then return false end
  local value = tonumber(entry.identity.value)
  if not value then return false end
  if entry.kind == "mount" then
    return snapshot.owned and snapshot.owned.mounts and snapshot.owned.mounts[value] and true or false
  elseif entry.kind == "pet" then
    return snapshot.owned and snapshot.owned.pets and snapshot.owned.pets[value] and true or false
  elseif entry.kind == "toy" then
    return snapshot.owned and snapshot.owned.toys and snapshot.owned.toys[value] and true or false
  elseif entry.kind == "housing" then
    return snapshot.owned and snapshot.owned.housing and snapshot.owned.housing[value] and true or false
  elseif entry.kind == "appearance" then
    return snapshot.owned and snapshot.owned.appearances and snapshot.owned.appearances[value] and true or false
  end
  return false
end

function CE.RecomputeAll(reason)
  if not (ns.CompletionDefinitions and ns.CompletionDefinitions.EnsureBuilt) then return false end
  ns.CompletionDefinitions.EnsureBuilt()

  local groups = ns.CompletionDefinitions.groups or {}
  local snapshot = ns.CompletionSnapshot and ns.CompletionSnapshot.Build and ns.CompletionSnapshot.Build(groups) or nil
  if not snapshot then return false end

  _wipe(CE.groupTotals)
  _wipe(CE.entryStates)
  _wipe(CE.latestChanges)
  _wipe(CE.overviewTotals)

  local prevStates, backendDB = getPrevStateStore()
  local now = time and time() or 0

  for groupKey, group in pairs(groups) do
    local totals = {
      groupKey = groupKey,
      category = group.category,
      collected = 0,
      total = #(group.completionEntries or {}),
      complete = false,
      authoritative = true,
      unknownCount = 0,
      missingEntries = {},
      collectedEntries = {},
      unsupportedItemCount = group.unsupportedItemCount or 0,
      rawItemCount = group.rawItemCount or 0,
      reason = reason,
    }

    for _, entryKey in ipairs(group.completionEntries or {}) do
      local entry = ns.CompletionDefinitions.entries and ns.CompletionDefinitions.entries[entryKey] or nil
      local collected = entryCollected(snapshot, entry)
      CE.entryStates[entryKey] = collected and "collected" or "missing"
      if collected then
        totals.collected = totals.collected + 1
        totals.collectedEntries[entryKey] = true
      else
        totals.missingEntries[entryKey] = true
      end

      local prev = prevStates[entryKey]
      if prev == false and collected == true then
        CE.latestChanges[#CE.latestChanges + 1] = {
          entryKey = entryKey,
          groupKey = groupKey,
          kind = entry and entry.kind or nil,
          identityValue = entry and entry.identity and entry.identity.value or nil,
          when = now,
          reason = reason,
        }
      end
      prevStates[entryKey] = collected and true or false
    end

    totals.complete = totals.total > 0 and totals.collected == totals.total
    CE.groupTotals[groupKey] = totals

    if totals.total > 0 then
      local bucket = CE.overviewTotals[group.category] or { category = group.category, collected = 0, total = 0, groups = 0, completeGroups = 0 }
      bucket.collected = bucket.collected + totals.collected
      bucket.total = bucket.total + totals.total
      bucket.groups = bucket.groups + 1
      if totals.complete then bucket.completeGroups = bucket.completeGroups + 1 end
      CE.overviewTotals[group.category] = bucket
    end
  end

  backendDB.lastReason = reason
  backendDB.lastComputedAt = now
  backendDB.history[#backendDB.history + 1] = {
    when = now,
    reason = reason,
    changedEntries = #CE.latestChanges,
  }
  if #backendDB.history > 20 then
    table.remove(backendDB.history, 1)
  end

  return true
end

function CE.GetGroupTotals(groupKey)
  return CE.groupTotals and CE.groupTotals[tostring(groupKey)] or nil
end

function CE.GetOverviewTotals(category)
  if category then
    return CE.overviewTotals and CE.overviewTotals[category] or nil
  end
  return CE.overviewTotals
end

function CE.GetEntryState(entryKey)
  return CE.entryStates and CE.entryStates[entryKey] or nil
end

function CE.GetLatestChanges()
  return CE.latestChanges or {}
end

function CE.GetEntryDebug(entryKey)
  local entry = ns.CompletionDefinitions and ns.CompletionDefinitions.entries and ns.CompletionDefinitions.entries[entryKey] or nil
  if not entry then return nil end
  local snapshot = ns.CompletionSnapshot and ns.CompletionSnapshot.GetCurrent and ns.CompletionSnapshot.GetCurrent() or nil
  local out = { entry = entry }
  if entry.kind == "mount" and entry.identity then
    local spellID = tonumber(entry.identity.value)
    out.mount = ns.CompletionSnapshot and ns.CompletionSnapshot.GetMountDebug and ns.CompletionSnapshot.GetMountDebug(spellID) or nil
  elseif entry.kind == "pet" and entry.identity then
    local speciesID = tonumber(entry.identity.value)
    out.pet = ns.CompletionSnapshot and ns.CompletionSnapshot.GetPetDebug and ns.CompletionSnapshot.GetPetDebug(speciesID) or nil
  elseif entry.kind == "toy" and entry.identity then
    local itemID = tonumber(entry.identity.value)
    out.toy = ns.CompletionSnapshot and ns.CompletionSnapshot.GetToyDebug and ns.CompletionSnapshot.GetToyDebug(itemID) or nil
  elseif entry.kind == "housing" and entry.identity then
    local itemID = tonumber(entry.identity.value)
    out.housing = ns.CompletionSnapshot and ns.CompletionSnapshot.GetHousingDebug and ns.CompletionSnapshot.GetHousingDebug(itemID) or nil
  elseif entry.kind == "appearance" and entry.identity then
    local appearanceID = tonumber(entry.identity.value)
    out.appearance = ns.CompletionSnapshot and ns.CompletionSnapshot.GetAppearanceDebug and ns.CompletionSnapshot.GetAppearanceDebug(appearanceID) or nil
  end
  return out
end
