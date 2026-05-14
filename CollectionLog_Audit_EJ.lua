-- CollectionLog_Audit_EJ.lua
-- Async Encounter Journal audit tooling, isolated from importer/runtime systems.

local ADDON, ns = ...

local function Print(msg)
  if ns and ns.Print then
    ns.Print(msg)
  else
    print('|cff00ff99Collection Log|r: ' .. tostring(msg))
  end
end

local function EnsureEncounterJournalLoaded()
  if (C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex) or EJ_GetLootInfoByIndex then
    return true
  end
  pcall(LoadAddOn, 'Blizzard_EncounterJournal')
  if EncounterJournal_LoadUI then
    pcall(EncounterJournal_LoadUI)
  end
  return ((C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex) ~= nil) or (EJ_GetLootInfoByIndex ~= nil)
end

local function GetLootInfoByIndex(i)
  if C_EncounterJournal and C_EncounterJournal.GetLootInfoByIndex then
    return C_EncounterJournal.GetLootInfoByIndex(i)
  end
  if EJ_GetLootInfoByIndex then
    return EJ_GetLootInfoByIndex(i)
  end
  return nil
end

local function SetLootTab()
  local ej = _G.EncounterJournal
  if not ej then return false end
  if EncounterJournal_SetTab then
    local ok = pcall(EncounterJournal_SetTab, 3)
    if ok then return true end
  end
  if ej.navBar and ej.navBar.homeButton then
    pcall(function() ej.navBar.homeButton:Click() end)
  end
  if ej.LootJournal and ej.LootJournal.Show then
    pcall(function() ej.LootJournal:Show() end)
  end
  if ej.encounter and ej.encounter.info and ej.encounter.info.lootTab and ej.encounter.info.lootTab.SetChecked then
    pcall(function() ej.encounter.info.lootTab:SetChecked(true) end)
  end
  return true
end

local function CountKeys(t)
  local n = 0
  if type(t) ~= 'table' then return 0 end
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function SortedArrayFromSet(setTbl)
  local out = {}
  if type(setTbl) ~= 'table' then return out end
  for k in pairs(setTbl) do out[#out + 1] = k end
  table.sort(out, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == 'number' and tb == 'number' then return a < b end
    return tostring(a) < tostring(b)
  end)
  return out
end

local function FirstNFromSet(setTbl, limit)
  local sorted = SortedArrayFromSet(setTbl)
  local out = {}
  limit = tonumber(limit) or 10
  for i = 1, math.min(#sorted, limit) do out[#out + 1] = sorted[i] end
  return out
end

local function Join(list, sep)
  if type(list) ~= 'table' or #list == 0 then return '' end
  return table.concat(list, sep or ', ')
end

local function UniqueItemSet(items)
  local setTbl, duplicates = {}, {}
  if type(items) ~= 'table' then return setTbl, duplicates end
  for _, itemID in ipairs(items) do
    itemID = tonumber(itemID)
    if itemID and itemID > 0 then
      if setTbl[itemID] then duplicates[itemID] = true end
      setTbl[itemID] = true
    end
  end
  return setTbl, duplicates
end

local function ExtractLootRows()
  local out = {}
  local i = 1
  while true do
    local ok, a, b, c, d, e, f = pcall(GetLootInfoByIndex, i)
    if not ok or not a then break end
    local itemID, link
    if type(a) == 'table' then
      link = a.link or a.itemLink or a.hyperlink or a.itemlink
      itemID = a.itemID or a.itemId or a.id or (link and select(1, GetItemInfoInstant(link)))
    else
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

local function ExtractLiveItemSet()
  local out = {}
  for _, row in ipairs(ExtractLootRows() or {}) do
    local itemID = row and tonumber(row.itemID)
    if itemID and itemID > 0 then out[itemID] = true end
  end
  return out
end

local function HasCurrentEncounterContent()
  if EJ_GetEncounterInfoByIndex then
    local ok, name = pcall(EJ_GetEncounterInfoByIndex, 1)
    if ok and name then return true end
  end
  local li = GetLootInfoByIndex(1)
  if li ~= nil then
    if type(li) == 'table' then
      if li.itemID or li.itemId or li.name or li.link or li.itemLink then return true end
    else
      return true
    end
  end
  return false
end

local function DedupDifficultyList(list)
  local out, seen = {}, {}
  if type(list) ~= 'table' then return out end
  for _, diffID in ipairs(list) do
    diffID = tonumber(diffID)
    if diffID and not seen[diffID] then
      seen[diffID] = true
      out[#out + 1] = diffID
    end
  end
  return out
end

local function GetSelectedInstanceID()
  if EJ_GetCurrentInstance then
    local ok, id = pcall(EJ_GetCurrentInstance)
    if ok and id then return tonumber(id) end
  end
  return nil
end

local function GetSelectedDifficultyID()
  if EJ_GetDifficulty then
    local ok, id = pcall(EJ_GetDifficulty)
    if ok and id then return tonumber(id) end
  end
  return nil
end

local function SetDifficulty(diffID)
  local ej = _G.EncounterJournal
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
  local ej = _G.EncounterJournal
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

local function GetCurrentInstanceDifficulties(isRaid, instanceID)
  local out = {}
  if EJ_GetNumInstanceDifficulties and EJ_GetInstanceDifficulty then
    local okN, n = pcall(EJ_GetNumInstanceDifficulties)
    if okN and type(n) == 'number' and n > 0 then
      for idx = 1, n do
        local okD, diffID = pcall(EJ_GetInstanceDifficulty, idx)
        if okD and diffID then out[#out + 1] = tonumber(diffID) end
      end
    end
  end
  if #out == 0 then
    local candidates = isRaid and {17,14,15,16,3,4,5,6,33,151} or {1,2,23,8,24}
    for _, diffID in ipairs(candidates) do
      local valid = true
      if EJ_IsValidInstanceDifficulty then
        local okV, v = pcall(EJ_IsValidInstanceDifficulty, diffID)
        if okV then valid = v and true or false end
      end
      if valid then
        local advertised = true
        if IsDifficultyAdvertisedByLFG then
          local okA, adv = pcall(IsDifficultyAdvertisedByLFG, instanceID, diffID)
          if okA then advertised = adv and true or false end
        end
        if advertised then out[#out + 1] = diffID end
      end
    end
  end
  return DedupDifficultyList(out)
end

local function BuildShippedEncounterIndex(filterMode)
  local byId, all, duplicates, duplicatePacks = {}, {}, {}, {}
  local includeRaids = (filterMode == nil or filterMode == '' or filterMode == 'all' or filterMode == 'raids' or filterMode == 'raid')
  local includeDungeons = (filterMode == nil or filterMode == '' or filterMode == 'all' or filterMode == 'dungeons' or filterMode == 'dungeon')
  if not includeRaids and not includeDungeons then includeRaids, includeDungeons = true, true end
  if not (ns and ns.Data and ns.Data.packs) then
    return { byId = byId, all = all, duplicates = duplicates, duplicatePacks = duplicatePacks }
  end
  local packIds = {}
  for packId, _ in pairs(ns.Data.packs) do packIds[#packIds + 1] = packId end
  table.sort(packIds, function(a, b) return tostring(a) < tostring(b) end)
  for _, packId in ipairs(packIds) do
    local pack = ns.Data.packs[packId]
    local isGenerated = (packId == 'generated') or (type(packId) == 'string' and packId:find('^generated_'))
    if (not isGenerated) and type(pack) == 'table' and type(pack.groups) == 'table' then
      for _, group in ipairs(pack.groups) do
        local cat = group and group.category
        local include = (cat == 'Raids' and includeRaids) or (cat == 'Dungeons' and includeDungeons)
        if include and group and group.id then
          local itemSet, dupItems = UniqueItemSet(group.items)
          local rec = {
            id = group.id,
            name = group.name,
            mode = group.mode,
            category = cat,
            expansion = group.expansion,
            instanceID = tonumber(group.instanceID),
            difficultyID = tonumber(group.difficultyID),
            items = itemSet,
            duplicateItems = dupItems,
            sourcePack = packId,
          }
          all[#all + 1] = rec
          if byId[rec.id] then
            duplicates[rec.id] = true
            duplicatePacks[rec.id] = duplicatePacks[rec.id] or {}
            duplicatePacks[rec.id][byId[rec.id].sourcePack or '?'] = true
            duplicatePacks[rec.id][packId] = true
          else
            byId[rec.id] = rec
          end
        end
      end
    end
  end
  return { byId = byId, all = all, duplicates = duplicates, duplicatePacks = duplicatePacks }
end

local function FormatGroupLabel(groupOrRec)
  if type(groupOrRec) ~= 'table' then return tostring(groupOrRec) end
  local name = groupOrRec.name or groupOrRec.instanceName or ('Instance ' .. tostring(groupOrRec.instanceID or '?'))
  local mode = groupOrRec.mode or groupOrRec.diffName or tostring(groupOrRec.difficultyID or '?')
  local category = groupOrRec.category or '?'
  return ('%s [%s, %s]'):format(tostring(name), tostring(category), tostring(mode))
end

local function PrintSummary(results)
  Print(('EJ audit summary: scanned=%d matched=%d missingGroups=%d extraGroups=%d mismatchedItems=%d duplicateGroups=%d duplicateItems=%d'):format(
    tonumber(results.scanned or 0), tonumber(results.matched or 0), tonumber(results.missingGroups or 0), tonumber(results.extraGroups or 0), tonumber(results.mismatchedItems or 0), tonumber(results.duplicateGroups or 0), tonumber(results.duplicateItems or 0)
  ))

  if results.scanned == 0 then
    Print('Warning: no live Encounter Journal groups were scanned. The journal may not have finished loading yet.')
  end
  if results.missingGroupLabels and #results.missingGroupLabels > 0 then
    Print(('Missing shipped groups (%d): %s'):format(#results.missingGroupLabels, Join(results.missingGroupLabels, ' | ')))
  end
  if results.extraGroupLabels and #results.extraGroupLabels > 0 then
    Print(('Extra shipped groups (%d): %s'):format(#results.extraGroupLabels, Join(results.extraGroupLabels, ' | ')))
  end
  if results.mismatchLabels and #results.mismatchLabels > 0 then
    Print(('Item mismatches (%d): %s'):format(#results.mismatchLabels, Join(results.mismatchLabels, ' | ')))
  end
  if results.duplicateGroupLabels and #results.duplicateGroupLabels > 0 then
    Print(('Duplicate shipped group ids (%d): %s'):format(#results.duplicateGroupLabels, Join(results.duplicateGroupLabels, ' | ')))
  end
  if results.duplicateItemLabels and #results.duplicateItemLabels > 0 then
    Print(('Duplicate item ids inside shipped groups (%d): %s'):format(#results.duplicateItemLabels, Join(results.duplicateItemLabels, ' | ')))
  end
end

local function ParseAuditArgs(msg)
  local auditMode, scope = 'full', 'all'
  local tokens = {}
  msg = type(msg) == 'string' and msg:lower() or ''
  for token in msg:gmatch('%S+') do
    tokens[#tokens + 1] = token
  end
  for _, token in ipairs(tokens) do
    if token == 'group' or token == 'groups' then
      auditMode = 'groups'
    elseif token == 'item' or token == 'items' then
      auditMode = 'items'
    elseif token == 'resolution' or token == 'resolve' then
      auditMode = 'resolution'
    elseif token == 'full' or token == 'all' then
      auditMode = 'full'
    elseif token == 'raid' or token == 'raids' then
      scope = 'raids'
    elseif token == 'dungeon' or token == 'dungeons' then
      scope = 'dungeons'
    end
  end
  return auditMode, scope
end

local function PrintModeSummary(results, auditMode)
  auditMode = auditMode or 'full'
  if auditMode == 'groups' then
    Print(('EJ audit groups: scanned=%d matched=%d missingGroups=%d extraGroups=%d duplicateGroups=%d'):format(
      tonumber(results.scanned or 0), tonumber(results.matched or 0), tonumber(results.missingGroups or 0), tonumber(results.extraGroups or 0), tonumber(results.duplicateGroups or 0)
    ))
    if results.scanned == 0 then
      Print('Warning: no live Encounter Journal groups were scanned. The journal may not have finished loading yet.')
    end
    if results.missingGroupLabels and #results.missingGroupLabels > 0 then
      Print(('Missing shipped groups (%d): %s'):format(#results.missingGroupLabels, Join(results.missingGroupLabels, ' | ')))
    end
    if results.extraGroupLabels and #results.extraGroupLabels > 0 then
      Print(('Extra shipped groups (%d): %s'):format(#results.extraGroupLabels, Join(results.extraGroupLabels, ' | ')))
    end
    if results.duplicateGroupLabels and #results.duplicateGroupLabels > 0 then
      Print(('Duplicate shipped group ids (%d): %s'):format(#results.duplicateGroupLabels, Join(results.duplicateGroupLabels, ' | ')))
    end
    return
  elseif auditMode == 'items' then
    Print(('EJ audit items: comparedGroups=%d mismatchedItems=%d duplicateItems=%d'):format(
      tonumber(results.matched or 0), tonumber(results.mismatchedItems or 0), tonumber(results.duplicateItems or 0)
    ))
    if results.mismatchLabels and #results.mismatchLabels > 0 then
      Print(('Item mismatches (%d): %s'):format(#results.mismatchLabels, Join(results.mismatchLabels, ' | ')))
    end
    if results.duplicateItemLabels and #results.duplicateItemLabels > 0 then
      Print(('Duplicate item ids inside shipped groups (%d): %s'):format(#results.duplicateItemLabels, Join(results.duplicateItemLabels, ' | ')))
    end
    return
  end
  PrintSummary(results)
end

local function RunResolutionAudit(scope, silentPrefix)
  scope = scope or 'all'
  local includeRaids = (scope == 'all' or scope == 'raid' or scope == 'raids')
  local includeDungeons = (scope == 'all' or scope == 'dungeon' or scope == 'dungeons')
  if not includeRaids and not includeDungeons then includeRaids, includeDungeons = true, true end

  if not (ns and ns.CompletionDefinitions and ns.CompletionDefinitions.EnsureBuilt and ns.CompletionDefinitions.GetAllGroups) then
    Print('Resolution audit unavailable: completion definition APIs are missing.')
    return
  end
  local okBuilt = ns.CompletionDefinitions.EnsureBuilt()
  if not okBuilt then
    Print('Resolution audit failed: could not build completion definitions.')
    return
  end

  local defs = ns.CompletionDefinitions.GetAllGroups() or {}
  local results = {
    groups = 0,
    supportedGroups = 0,
    rawItems = 0,
    supportedEntries = 0,
    unresolvedGroups = 0,
    unresolvedItems = 0,
    nonCollectibleItems = 0,
    unsupportedItems = 0,
    unresolvedLabels = {},
    unresolvedDetails = {},
    emptyLabels = {},
  }

  for _, def in pairs(defs) do
    if type(def) == 'table' then
      local cat = def.category
      local include = (cat == 'Raids' and includeRaids) or (cat == 'Dungeons' and includeDungeons)
      if include then
        results.groups = results.groups + 1
        local rawCount = tonumber(def.rawItemCount or 0) or 0
        local supportedCount = tonumber(def.totalSupported or 0) or 0
        local unresolvedCount = tonumber(def.unresolvedCandidateCount or 0) or 0
        local nonCollectibleCount = tonumber(def.nonCollectibleCount or 0) or 0
        local unsupportedCount = tonumber(def.unsupportedItemCount or 0) or 0
        results.rawItems = results.rawItems + rawCount
        results.supportedEntries = results.supportedEntries + supportedCount
        results.unresolvedItems = results.unresolvedItems + unresolvedCount
        results.nonCollectibleItems = results.nonCollectibleItems + nonCollectibleCount
        results.unsupportedItems = results.unsupportedItems + unsupportedCount
        if supportedCount > 0 then
          results.supportedGroups = results.supportedGroups + 1
        elseif rawCount > 0 then
          results.emptyLabels[#results.emptyLabels + 1] = ('%s => raw:%d supported:%d'):format(
            FormatGroupLabel(def), rawCount, supportedCount
          )
        end
        if unresolvedCount > 0 then
          results.unresolvedGroups = results.unresolvedGroups + 1
          local groupLabel = FormatGroupLabel(def)
          results.unresolvedLabels[#results.unresolvedLabels + 1] = ('%s => unresolved:%d raw:%d supported:%d'):format(
            groupLabel, unresolvedCount, rawCount, supportedCount
          )
          local details = {}
          if type(def.unresolvedCandidates) == 'table' then
            for candidateKind, bucket in pairs(def.unresolvedCandidates) do
              if type(bucket) == 'table' and type(bucket.items) == 'table' then
                for i = 1, #bucket.items do
                  local item = bucket.items[i]
                  if type(item) == 'table' then
                    details[#details + 1] = ('%s:%s (%s%s)'):format(
                      tostring(candidateKind),
                      tostring(item.rawID or '?'),
                      tostring(item.itemName or '?'),
                      item.section and (' @ ' .. tostring(item.section)) or ''
                    )
                  end
                end
              end
            end
          end
          table.sort(details)
          if #details > 0 then
            results.unresolvedDetails[#results.unresolvedDetails + 1] = groupLabel .. ' => ' .. table.concat(details, ', ')
          end
        end
      end
    end
  end

  table.sort(results.unresolvedLabels)
  table.sort(results.emptyLabels)

  if not silentPrefix then
    Print('Resolution audit started. Validating collectible resolution across shipped raid/dungeon groups...')
  end
  Print(('Resolution audit summary: groups=%d supportedGroups=%d rawItems=%d supportedEntries=%d unresolvedGroups=%d unresolvedItems=%d nonCollectibleItems=%d unsupportedItems=%d'):format(
    tonumber(results.groups or 0), tonumber(results.supportedGroups or 0), tonumber(results.rawItems or 0), tonumber(results.supportedEntries or 0), tonumber(results.unresolvedGroups or 0), tonumber(results.unresolvedItems or 0), tonumber(results.nonCollectibleItems or 0), tonumber(results.unsupportedItems or 0)
  ))
  if #results.unresolvedLabels > 0 then
    Print(('Resolution audit unresolved groups (%d): %s'):format(#results.unresolvedLabels, Join(results.unresolvedLabels, ' | ')))
  end
  if results.unresolvedDetails and #results.unresolvedDetails > 0 then
    local maxDetails = math.min(#results.unresolvedDetails, 8)
    for i = 1, maxDetails do
      Print('Resolution audit unresolved detail: ' .. results.unresolvedDetails[i])
    end
    if #results.unresolvedDetails > maxDetails then
      Print(('Resolution audit unresolved detail: ... %d more group(s) omitted.'):format(#results.unresolvedDetails - maxDetails))
    end
  end
  if #results.emptyLabels > 0 then
    Print(('Resolution audit empty collectible groups (%d): %s'):format(#results.emptyLabels, Join(results.emptyLabels, ' | ')))
  end
end

local function BuildTierJobs(mode)
  local jobs = {}
  local wantedRaid = (mode == 'all' or mode == 'raid' or mode == 'raids')
  local wantedDungeon = (mode == 'all' or mode == 'dungeon' or mode == 'dungeons')
  local numTiers = 0
  if EJ_GetNumTiers then
    local okN, n = pcall(EJ_GetNumTiers)
    if okN and type(n) == 'number' then numTiers = n end
  end
  if numTiers <= 0 then numTiers = 80 end
  for tier = 1, numTiers do
    if wantedRaid then jobs[#jobs + 1] = { tier = tier, isRaid = true } end
    if wantedDungeon then jobs[#jobs + 1] = { tier = tier, isRaid = false } end
  end
  return jobs
end

function ns.RunEncounterDataAudit(msg)
  local auditMode, scope = ParseAuditArgs(msg)
  if auditMode == 'resolution' then
    RunResolutionAudit(scope)
    return
  end
  local mode = scope
  if ns._ejAuditRunning then
    Print('EJ datapack audit is already running.')
    return
  end
  if not EnsureEncounterJournalLoaded() then
    Print('Unable to load Blizzard Encounter Journal APIs. Audit aborted.')
    return
  end
  if not (EJ_SelectTier and EJ_GetInstanceByIndex and EJ_SelectInstance) then
    Print('Encounter Journal instance APIs are unavailable. Audit aborted.')
    return
  end

  pcall(LoadAddOn, 'Blizzard_EncounterJournal')
  if EncounterJournal_LoadUI then pcall(EncounterJournal_LoadUI) end

  local shipped = BuildShippedEncounterIndex(mode)
  Print(('EJ audit: indexed %d shipped raid/dungeon groups from datapacks.'):format(#(shipped.all or {})))
  local results = {
    scanned = 0, matched = 0, missingGroups = 0, extraGroups = 0, mismatchedItems = 0,
    duplicateGroups = CountKeys(shipped.duplicates), duplicateItems = 0,
    missingGroupLabels = {}, extraGroupLabels = {}, mismatchLabels = {}, duplicateGroupLabels = {}, duplicateItemLabels = {},
  }

  for groupId, packSet in pairs(shipped.duplicatePacks or {}) do
    results.duplicateGroupLabels[#results.duplicateGroupLabels + 1] = tostring(groupId) .. ' (' .. Join(FirstNFromSet(packSet, 5), ', ') .. ')'
  end
  for _, rec in ipairs(shipped.all or {}) do
    local dupItems = FirstNFromSet(rec.duplicateItems, 5)
    if #dupItems > 0 then
      results.duplicateItems = results.duplicateItems + 1
      results.duplicateItemLabels[#results.duplicateItemLabels + 1] = FormatGroupLabel(rec) .. ' => ' .. Join(dupItems, ', ')
    end
  end

  local originalTier, originalDiff, originalInstance = nil, nil, nil
  if EJ_GetCurrentTier then pcall(function() originalTier = EJ_GetCurrentTier() end) end
  originalDiff = GetSelectedDifficultyID()
  originalInstance = GetSelectedInstanceID()

  local liveById = {}
  local enumJobs = BuildTierJobs(mode)
  local enumIndex, instanceIndex = 1, 1
  local scanQueue, queued = {}, {}

  local function QueueJob(job)
    if not job or not job.instanceID or not job.difficultyID then return end
    local key = tostring(job.id or ('ej:' .. tostring(job.instanceID) .. ':' .. tostring(job.difficultyID)))
    if queued[key] then return end
    queued[key] = true
    scanQueue[#scanQueue + 1] = job
  end

  local function Restore()
    if originalTier then pcall(EJ_SelectTier, originalTier) end
    if originalInstance then SetInstance(originalInstance) end
    if originalDiff then SetDifficulty(originalDiff) end
    SetLootTab()
  end

  local function Finalize()
    for liveID, liveRec in pairs(liveById) do
      local shippedRec = shipped.byId[liveID]
      if not shippedRec then
        results.missingGroups = results.missingGroups + 1
        results.missingGroupLabels[#results.missingGroupLabels + 1] = FormatGroupLabel(liveRec)
      else
        results.matched = results.matched + 1
        local missingFromPack, extraInPack = {}, {}
        for itemID in pairs(liveRec.items or {}) do
          if not shippedRec.items[itemID] then missingFromPack[itemID] = true end
        end
        for itemID in pairs(shippedRec.items or {}) do
          if not liveRec.items[itemID] then extraInPack[itemID] = true end
        end
        local missingCount, extraCount = CountKeys(missingFromPack), CountKeys(extraInPack)
        if missingCount > 0 or extraCount > 0 then
          results.mismatchedItems = results.mismatchedItems + 1
          results.mismatchLabels[#results.mismatchLabels + 1] = ('%s => missing:%d [%s] extra:%d [%s]'):format(
            FormatGroupLabel(liveRec),
            missingCount, Join(FirstNFromSet(missingFromPack, 6), ', '),
            extraCount, Join(FirstNFromSet(extraInPack, 6), ', ')
          )
        end
      end
    end

    for shippedID, shippedRec in pairs(shipped.byId) do
      if not liveById[shippedID] then
        results.extraGroups = results.extraGroups + 1
        results.extraGroupLabels[#results.extraGroupLabels + 1] = FormatGroupLabel(shippedRec)
      end
    end

    Restore()
    ns._ejAuditRunning = nil
    PrintModeSummary(results, auditMode)
    if auditMode == 'full' then
      RunResolutionAudit(scope, true)
    end
  end

  local function ScanNextJob()
    local job = table.remove(scanQueue, 1)
    if not job then
      Finalize()
      return
    end
    pcall(EJ_SelectTier, job.tier)
    C_Timer.After(0.05, function()
      if not SetInstance(job.instanceID) then
        C_Timer.After(0, ScanNextJob)
        return
      end
      SetLootTab()
      C_Timer.After(0.08, function()
        if not SetDifficulty(job.difficultyID) then
          C_Timer.After(0, ScanNextJob)
          return
        end
        SetLootTab()
        C_Timer.After(0.18, function()
          local itemSet = ExtractLiveItemSet()
          local hasContent = HasCurrentEncounterContent() or CountKeys(itemSet) > 0
          if hasContent then
            local liveID = tostring(job.id)
            liveById[liveID] = {
              id = liveID,
              instanceID = tonumber(job.instanceID),
              difficultyID = tonumber(job.difficultyID),
              category = job.category,
              name = job.name,
              mode = job.mode,
              items = itemSet,
            }
            results.scanned = results.scanned + 1
            if (results.scanned % 25) == 0 then
              Print(('EJ audit progress: scanned %d live groups...'):format(results.scanned))
            end
          end
          C_Timer.After(0.01, ScanNextJob)
        end)
      end)
    end)
  end

  local function EnumerateNextInstance()
    local enum = enumJobs[enumIndex]
    if not enum then
      if #scanQueue == 0 then
        Print('EJ audit warning: live instance enumeration found no groups to scan.')
      else
        Print(('EJ audit: scanning %d live raid/dungeon groups...'):format(#scanQueue))
      end
      C_Timer.After(0.02, ScanNextJob)
      return
    end

    pcall(EJ_SelectTier, enum.tier)
    C_Timer.After(0.06, function()
      local okI, instanceID = pcall(EJ_GetInstanceByIndex, instanceIndex, enum.isRaid)
      if not okI or not instanceID then
        enumIndex = enumIndex + 1
        instanceIndex = 1
        C_Timer.After(0.01, EnumerateNextInstance)
        return
      end
      instanceIndex = instanceIndex + 1

      if not SetInstance(instanceID) then
        C_Timer.After(0.01, EnumerateNextInstance)
        return
      end
      SetLootTab()
      C_Timer.After(0.08, function()
        local instanceName = nil
        if EJ_GetInstanceInfo then
          pcall(function() instanceName = EJ_GetInstanceInfo(instanceID) end)
        end
        local diffs = GetCurrentInstanceDifficulties(enum.isRaid, instanceID)
        for _, diffID in ipairs(diffs) do
          local diffName = tostring(diffID)
          if GetDifficultyInfo then
            local okDN, dn = pcall(GetDifficultyInfo, diffID)
            if okDN and dn and dn ~= '' then diffName = dn end
          end
          QueueJob({
            id = string.format('ej:%d:%d', tonumber(instanceID) or 0, tonumber(diffID) or 0),
            tier = enum.tier,
            isRaid = enum.isRaid,
            instanceID = tonumber(instanceID),
            difficultyID = tonumber(diffID),
            category = enum.isRaid and 'Raids' or 'Dungeons',
            name = instanceName,
            mode = diffName,
          })
        end
        C_Timer.After(0.01, EnumerateNextInstance)
      end)
    end)
  end

  ns._ejAuditRunning = true
  Print(('EJ audit started (%s/%s). Opening the Encounter Journal data and scanning live raid/dungeon groups...'):format(tostring(auditMode), tostring(scope)))
  C_Timer.After(0.15, EnumerateNextInstance)
end

SLASH_CLOGAUDIT1 = '/clogaudit'
SlashCmdList.CLOGAUDIT = function(msg)
  if ns and ns.RunEncounterDataAudit then
    local ok, err = pcall(ns.RunEncounterDataAudit, msg)
    if not ok then
      ns._ejAuditRunning = nil
      Print('EJ datapack audit failed: ' .. tostring(err))
      Print('Usage: /clogaudit [groups|items|resolution|full] [raids|dungeons]')
    end
  else
    Print('EJ datapack audit is unavailable.')
  end
end
