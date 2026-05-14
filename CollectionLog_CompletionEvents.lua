local ADDON, ns = ...

ns.CompletionEvents = ns.CompletionEvents or {}
local EV = ns.CompletionEvents

EV.frame = EV.frame or CreateFrame("Frame")
EV.initialized = EV.initialized or false
EV._refreshQueued = EV._refreshQueued or false
EV._dirty = (EV._dirty == nil) and true or EV._dirty
EV._warmed = EV._warmed or false

function EV.Refresh(reason)
  reason = tostring(reason or "manual")

  -- v4.3.63: do not clear the whole TrueCollection/Completion cache for noisy
  -- journal events (TOYS_UPDATED, PET_JOURNAL_LIST_UPDATE, mount list updates).
  -- The global perf audit showed those wipes force expensive group-definition
  -- and completion-status rebuilds during normal UI refreshes. Explicit manual
  -- rebuild/refresh commands still clear caches below.
  if reason == "slash_rebuild" or reason == "manual_refresh" or reason == "explicit_refresh" then
    if ns.TrueCollection and ns.TrueCollection.ClearCache then
      pcall(ns.TrueCollection.ClearCache, "completion_event:" .. reason)
    elseif ns.CompletionV2 and ns.CompletionV2.ClearCache then
      pcall(ns.CompletionV2.ClearCache, "completion_event:" .. reason)
    end
  end

  EV._dirty = false
  EV._warmed = true

  -- Keep the old heavyweight rebuild only for the explicit diagnostic slash.
  if reason == "slash_rebuild" and ns.CompletionEngine and ns.CompletionEngine.RecomputeAll then
    return ns.CompletionEngine.RecomputeAll(reason)
  end
  return true
end

function EV.QueueRefresh(reason, delay)
  EV._dirty = true
  if not EV._warmed then return end
  if EV._refreshQueued then return end
  EV._refreshQueued = true
  local function run()
    EV._refreshQueued = false
    EV.Refresh(reason)
  end
  if C_Timer and C_Timer.After then
    C_Timer.After(tonumber(delay or 0.1) or 0.1, run)
  else
    run()
  end
end


function EV.EnsureWarm(reason)
  if EV._dirty or not EV._warmed then
    return EV.Refresh(reason or "ensure_warm")
  end
  return true
end

function EV.Initialize()
  if EV.initialized then return end
  EV.initialized = true

  local f = EV.frame
  local function SafeReg(ev)
    if f and f.RegisterEvent then pcall(f.RegisterEvent, f, ev) end
  end

  SafeReg("NEW_MOUNT_ADDED")
  SafeReg("MOUNT_JOURNAL_COLLECTION_UPDATED")
  SafeReg("MOUNT_JOURNAL_LIST_UPDATE")
  SafeReg("MOUNT_JOURNAL_USABILITY_CHANGED")
  SafeReg("PET_JOURNAL_LIST_UPDATE")
  SafeReg("PET_JOURNAL_PET_LIST_UPDATE")
  SafeReg("NEW_TOY_ADDED")
  SafeReg("TOYS_UPDATED")

  f:SetScript("OnEvent", function(_, event)
    EV.QueueRefresh(string.lower(event or "event"), 0.2)
  end)
end

EV.Initialize()

SLASH_CLOGCOMPLETION1 = "/clogcompletion"
SLASH_CLOGCOMPLETION2 = "/clogcb"

local function trim(s)
  return tostring(s or ""):match("^%s*(.-)%s*$") or ""
end

local function printUsage()
  ns.Print("Usage: /clogcompletion [status|rebuild|groups [raids|dungeons]|find <name>|group <groupID or name>|entries <groupID or name>|groupkey <exact key>|entrieskey <exact key>|coverage <groupID or name>|coveragekey <exact key>|missing <groupID or name>|missingkey <exact key>|appearance <groupID or name>|appearancekey <exact key>|audit [raids|dungeons] [all|row|panel|partial|full|zero] [page]|changes]")
end

local function categoryArgToLabel(arg)
  arg = trim(arg):lower()
  if arg == "raid" or arg == "raids" then return "Raids" end
  if arg == "dungeon" or arg == "dungeons" then return "Dungeons" end
  return nil
end

local function getSupportedGroupByIndex(category, index)
  local groups = ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups(category) or {}
  index = tonumber(index)
  if index and groups[index] then
    return groups[index].groupKey, groups[index]
  end
  return nil, nil
end

local function resolveQuery(query)
  query = trim(query)
  if query == "" then return nil, nil, "empty" end
  local category, idx = query:match("^(raids?)%s+(%d+)$")
  if not category then category, idx = query:match("^(dungeons?)%s+(%d+)$") end
  if category and idx then
    local key, group = getSupportedGroupByIndex(categoryArgToLabel(category), idx)
    if key and group then return key, group, "list_index" end
  end
  local onlyIdx = tonumber(query)
  if onlyIdx then
    local key, group = getSupportedGroupByIndex(nil, onlyIdx)
    if key and group then return key, group, "list_index" end
  end
  if ns.CompletionDefinitions and ns.CompletionDefinitions.ResolveGroupKey then
    return ns.CompletionDefinitions.ResolveGroupKey(query)
  end
  return nil, nil, "missing"
end


local function buildCoverage(groupKey)
  local group = ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
  if not group then return nil end
  local totals = ns.CompletionEngine and ns.CompletionEngine.GetGroupTotals and ns.CompletionEngine.GetGroupTotals(groupKey) or nil
  if not totals then return nil end
  local entries = ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup and ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
  local meta = ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroupMeta and ns.CompletionDefinitions.GetGroupMeta(groupKey) or {}
  local unresolved = ns.CompletionDefinitions and ns.CompletionDefinitions.GetUnresolvedCandidates and ns.CompletionDefinitions.GetUnresolvedCandidates(groupKey) or {}
  local kinds = {}
  local supportedKinds = 0
  for _, entry in ipairs(entries or {}) do
    local kind = tostring(entry.kind or 'unknown')
    local bucket = kinds[kind] or { total = 0, collected = 0 }
    bucket.total = bucket.total + 1
    local state = ns.CompletionEngine and ns.CompletionEngine.GetEntryState and ns.CompletionEngine.GetEntryState(entry.entryKey) or nil
    if state == 'collected' then
      bucket.collected = bucket.collected + 1
    end
    kinds[kind] = bucket
  end
  for _ in pairs(kinds) do supportedKinds = supportedKinds + 1 end

  local rowColorReady = (totals.total or 0) > 0
  local panelTotalsReady = false
  local panelReason = 'partial-scope backend; keep legacy panel totals until full collectible scope is audited'
  if totals.total > 0 and (totals.unsupportedItemCount or 0) == 0 then
    panelTotalsReady = true
    panelReason = 'no unsupported raw items remain in this backend group'
  end

  local unresolvedKinds = {}
  local unresolvedNonAppearance = 0
  local unresolvedAppearance = 0
  for kind, bucket in pairs(unresolved or {}) do
    local count = tonumber(bucket and bucket.count or 0) or 0
    unresolvedKinds[kind] = count
    if kind == 'appearance' then
      unresolvedAppearance = unresolvedAppearance + count
    else
      unresolvedNonAppearance = unresolvedNonAppearance + count
    end
  end

  return {
    group = group,
    totals = totals,
    kinds = kinds,
    supportedKinds = supportedKinds,
    rowColorReady = rowColorReady,
    panelTotalsReady = panelTotalsReady,
    panelReason = panelReason,
    unresolvedKinds = unresolvedKinds,
    unresolvedNonAppearance = unresolvedNonAppearance,
    unresolvedAppearance = unresolvedAppearance,
    unresolvedCandidates = unresolved,
    nonCollectibleCount = tonumber(meta and meta.nonCollectibleCount or 0) or 0,
  }
end

local function printCoverage(groupKey, group, mode)
  local coverage = buildCoverage(groupKey)
  if not coverage then
    ns.Print('Completion backend coverage missing for: ' .. tostring(groupKey))
    return
  end
  local totals = coverage.totals
  ns.Print(("[%s] %s | %s | supported=%d/%d | unsupported raw items=%d of %d | supported kinds=%d | match=%s"):format(
    tostring(groupKey), tostring(group.name or groupKey), tostring(group.category or '?'), tonumber(totals.collected or 0), tonumber(totals.total or 0), tonumber(totals.unsupportedItemCount or 0), tonumber(totals.rawItemCount or 0), tonumber(coverage.supportedKinds or 0), tostring(mode or '?')
  ))
  local order = { 'mount', 'pet', 'toy', 'housing', 'appearance', 'unknown' }
  local seen = {}
  for _, kind in ipairs(order) do
    local bucket = coverage.kinds[kind]
    if bucket then
      seen[kind] = true
      ns.Print(("  %s: %d/%d"):format(kind, tonumber(bucket.collected or 0), tonumber(bucket.total or 0)))
    end
  end
  local extras = {}
  for kind in pairs(coverage.kinds) do
    if not seen[kind] then extras[#extras+1] = kind end
  end
  table.sort(extras)
  for _, kind in ipairs(extras) do
    local bucket = coverage.kinds[kind]
    ns.Print(("  %s: %d/%d"):format(kind, tonumber(bucket.collected or 0), tonumber(bucket.total or 0)))
  end
  ns.Print(("  rowColorReady=%s"):format(coverage.rowColorReady and 'true' or 'false'))
  ns.Print(("  panelTotalsReady=%s"):format(coverage.panelTotalsReady and 'true' or 'false'))
  ns.Print(("  panelTotalsReason=%s"):format(tostring(coverage.panelReason or '')))
end





local function printMissing(groupKey, group, mode)
  local coverage = buildCoverage(groupKey)
  if not coverage then
    ns.Print('Completion backend missing-audit unavailable for: ' .. tostring(groupKey))
    return
  end
  local totals = coverage.totals
  ns.Print(("[%s] %s | %s | supported=%d/%d | unsupported raw items=%d of %d | match=%s"):format(
    tostring(groupKey), tostring(group.name or groupKey), tostring(group.category or '?'), tonumber(totals.collected or 0), tonumber(totals.total or 0), tonumber(totals.unsupportedItemCount or 0), tonumber(totals.rawItemCount or 0), tostring(mode or '?')
  ))
  ns.Print(("  unresolvedNonAppearance=%d | unresolvedAppearance=%d | explicitNonCollectible=%d"):format(
    tonumber(coverage.unresolvedNonAppearance or 0), tonumber(coverage.unresolvedAppearance or 0), tonumber(coverage.nonCollectibleCount or 0)
  ))
  local order = { 'mount', 'pet', 'toy', 'housing', 'appearance' }
  local any = false
  for _, kind in ipairs(order) do
    local count = tonumber(coverage.unresolvedKinds and coverage.unresolvedKinds[kind] or 0) or 0
    if count > 0 then
      any = true
      ns.Print(("  unresolved %s: %d"):format(kind, count))
      local bucket = coverage.unresolvedCandidates and coverage.unresolvedCandidates[kind] or nil
      local items = bucket and bucket.items or nil
      if type(items) == 'table' then
        for i = 1, math.min(#items, 8) do
          local row = items[i]
          ns.Print(("    - %s (%s) section=%s"):format(tostring(row.itemName or ('item:' .. tostring(row.rawID))), tostring(row.rawID), tostring(row.section or '?')))
        end
        if #items > 8 then
          ns.Print(("    ...and %d more"):format(#items - 8))
        end
      end
    end
  end
  if not any then
    ns.Print('  No unresolved collectible candidates in the current non-appearance audit.')
  end
end

local function collectCoverageRows(category)
  local groups = ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups(category) or {}
  local rows = {}
  local stats = {
    groups = 0,
    rowReady = 0,
    panelReady = 0,
    partial = 0,
    full = 0,
    zero = 0,
    supportedCollected = 0,
    supportedTotal = 0,
  }
  for i = 1, #groups do
    local group = groups[i]
    local coverage = buildCoverage(group.groupKey)
    if coverage then
      local row = {
        groupKey = group.groupKey,
        group = group,
        coverage = coverage,
        collected = tonumber(coverage.totals and coverage.totals.collected or 0) or 0,
        total = tonumber(coverage.totals and coverage.totals.total or 0) or 0,
        unsupported = tonumber(coverage.totals and coverage.totals.unsupportedItemCount or 0) or 0,
        raw = tonumber(coverage.totals and coverage.totals.rawItemCount or 0) or 0,
      }
      rows[#rows + 1] = row
      stats.groups = stats.groups + 1
      stats.supportedCollected = stats.supportedCollected + row.collected
      stats.supportedTotal = stats.supportedTotal + row.total
      if coverage.rowColorReady then stats.rowReady = stats.rowReady + 1 end
      if coverage.panelTotalsReady then stats.panelReady = stats.panelReady + 1 end
      if row.unsupported > 0 then stats.partial = stats.partial + 1 else stats.full = stats.full + 1 end
    end
  end
  return rows, stats
end

local function filterAuditRows(rows, mode)
  mode = trim(mode):lower()
  if mode == '' or mode == 'all' then return rows, 'all' end
  local filtered = {}
  for i = 1, #rows do
    local row = rows[i]
    local ok = false
    if mode == 'row' then ok = row.coverage and row.coverage.rowColorReady
    elseif mode == 'panel' then ok = row.coverage and row.coverage.panelTotalsReady
    elseif mode == 'partial' then ok = row.unsupported > 0
    elseif mode == 'full' then ok = row.unsupported == 0
    elseif mode == 'zero' then ok = row.total == 0
    end
    if ok then filtered[#filtered + 1] = row end
  end
  return filtered, mode
end

local function sortAuditRows(rows, mode)
  table.sort(rows, function(a, b)
    if mode == 'panel' or mode == 'full' then
      if a.total ~= b.total then return a.total > b.total end
      if a.group and b.group and tostring(a.group.name or '') ~= tostring(b.group.name or '') then
        return tostring(a.group.name or '') < tostring(b.group.name or '')
      end
      return tostring(a.groupKey) < tostring(b.groupKey)
    end
    if a.unsupported ~= b.unsupported then return a.unsupported > b.unsupported end
    if a.total ~= b.total then return a.total > b.total end
    if a.group and b.group and tostring(a.group.name or '') ~= tostring(b.group.name or '') then
      return tostring(a.group.name or '') < tostring(b.group.name or '')
    end
    return tostring(a.groupKey) < tostring(b.groupKey)
  end)
end

local function printAudit(category, mode, page)
  local rows, stats = collectCoverageRows(category)
  local filtered, resolvedMode = filterAuditRows(rows, mode)
  sortAuditRows(filtered, resolvedMode)
  page = tonumber(page) or 1
  if page < 1 then page = 1 end
  local perPage = 15
  local totalPages = math.max(1, math.ceil(#filtered / perPage))
  if page > totalPages then page = totalPages end
  ns.Print(("Completion backend audit [%s] mode=%s | groups=%d | rowReady=%d | panelReady=%d | partial=%d | full=%d | zero=%d | supported=%d/%d | page=%d/%d"):format(
    tostring(category or 'All'), tostring(resolvedMode or 'all'), tonumber(stats.groups or 0), tonumber(stats.rowReady or 0), tonumber(stats.panelReady or 0), tonumber(stats.partial or 0), tonumber(stats.full or 0), tonumber(stats.zero or 0), tonumber(stats.supportedCollected or 0), tonumber(stats.supportedTotal or 0), tonumber(page), tonumber(totalPages)
  ))
  if #filtered == 0 then
    ns.Print('  No groups matched that audit filter.')
    return
  end
  local startIdx = ((page - 1) * perPage) + 1
  local endIdx = math.min(#filtered, startIdx + perPage - 1)
  for i = startIdx, endIdx do
    local row = filtered[i]
    local coverage = row.coverage
    ns.Print(("  %d) %s | key=%s | supported=%d/%d | unsupported=%d/%d raw | kinds=%d | row=%s | panel=%s"):format(
      i,
      tostring(row.group and row.group.name or row.groupKey),
      tostring(row.groupKey),
      tonumber(row.collected or 0), tonumber(row.total or 0),
      tonumber(row.unsupported or 0), tonumber(row.raw or 0),
      tonumber(coverage and coverage.supportedKinds or 0),
      coverage and coverage.rowColorReady and 'Y' or 'N',
      coverage and coverage.panelTotalsReady and 'Y' or 'N'
    ))
  end
  if totalPages > 1 then
    ns.Print(("  Use /clogcompletion audit %s %s %d for the next page."):format(
      tostring((category or 'raids'):lower()), tostring(resolvedMode or 'all'), tonumber(math.min(totalPages, page + 1))
    ))
  end
end

local function formatEntryLine(entry, state)
  local rawBits = {}
  for _, rawID in ipairs(entry.rawRefs or {}) do
    rawBits[#rawBits + 1] = tostring(rawID)
  end
  local rawText = #rawBits > 0 and (" raw=" .. table.concat(rawBits, ",")) or ""

  local extra = ""
  if entry and ns.CompletionEngine and ns.CompletionEngine.GetEntryDebug then
    local dbg = ns.CompletionEngine.GetEntryDebug(entry.entryKey)
    if entry.kind == "mount" then
      local m = dbg and dbg.mount or nil
      if m then
        local rawChecks = {}
        for rawID, hasIt in pairs(m.rawChecks or {}) do
          rawChecks[#rawChecks + 1] = tostring(rawID) .. ":" .. (hasIt and "true" or "false")
        end
        table.sort(rawChecks)
        extra = (" mountID=%s journal=%s rawOwned=%s"):format(
          tostring(m.mountID or "nil"),
          m.ownedByJournal and "true" or "false",
          m.ownedByRawItem and "true" or "false"
        )
        if #rawChecks > 0 then
          extra = extra .. " rawChecks=" .. table.concat(rawChecks, "|")
        end
      end
    elseif entry.kind == "pet" then
      local p = dbg and dbg.pet or nil
      local defPet = entry.debug and entry.debug.pet or nil
      local sourceBits = {}
      if defPet and type(defPet.sources) == "table" then
        for source, count in pairs(defPet.sources) do
          sourceBits[#sourceBits + 1] = tostring(source) .. ":" .. tostring(count)
        end
        table.sort(sourceBits)
      end
      extra = (" owned=%s ownedCount=%s totalCount=%s"):format(
        (p and p.owned) and "true" or "false",
        tostring(p and p.ownedCount or 0),
        tostring(p and p.totalCount or 0)
      )
      if #sourceBits > 0 then
        extra = extra .. " sources=" .. table.concat(sourceBits, "|")
      end
      local rawPetBits = {}
      if defPet and type(defPet.raw) == "table" then
        for rawID, row in pairs(defPet.raw) do
          local bit = tostring(rawID) .. ":" .. tostring(row.source or "unknown")
          if row and row.itemName then bit = bit .. ":" .. tostring(row.itemName) end
          rawPetBits[#rawPetBits + 1] = bit
        end
        table.sort(rawPetBits)
      end
      if #rawPetBits > 0 then
        extra = extra .. " rawPet=" .. table.concat(rawPetBits, "|")
      end
    elseif entry.kind == "toy" then
      local t = dbg and dbg.toy or nil
      local defToy = entry.debug and entry.debug.toy or nil
      local sourceBits = {}
      if defToy and type(defToy.sources) == "table" then
        for source, count in pairs(defToy.sources) do
          sourceBits[#sourceBits + 1] = tostring(source) .. ":" .. tostring(count)
        end
        table.sort(sourceBits)
      end
      extra = (" owned=%s toyID=%s"):format(
        (t and t.owned) and "true" or "false",
        tostring(t and t.toyID or "nil")
      )
      if #sourceBits > 0 then
        extra = extra .. " sources=" .. table.concat(sourceBits, "|")
      end
      local rawToyBits = {}
      if defToy and type(defToy.raw) == "table" then
        for rawID, row in pairs(defToy.raw) do
          local bit = tostring(rawID) .. ":" .. tostring(row.source or "unknown")
          if row and row.itemName then bit = bit .. ":" .. tostring(row.itemName) end
          rawToyBits[#rawToyBits + 1] = bit
        end
        table.sort(rawToyBits)
      end
      if #rawToyBits > 0 then
        extra = extra .. " rawToy=" .. table.concat(rawToyBits, "|")
      end
    elseif entry.kind == "housing" then
      local h = dbg and dbg.housing or nil
      local defHousing = entry.debug and entry.debug.housing or nil
      local sourceBits = {}
      if defHousing and type(defHousing.sources) == "table" then
        for source, count in pairs(defHousing.sources) do
          sourceBits[#sourceBits + 1] = tostring(source) .. ":" .. tostring(count)
        end
        table.sort(sourceBits)
      end
      extra = (" owned=%s decorID=%s"):format(
        (h and h.owned) and "true" or "false",
        tostring(h and h.decorID or "nil")
      )
      if #sourceBits > 0 then
        extra = extra .. " sources=" .. table.concat(sourceBits, "|")
      end
      local rawHousingBits = {}
      if defHousing and type(defHousing.raw) == "table" then
        for rawID, row in pairs(defHousing.raw) do
          local bit = tostring(rawID) .. ":" .. tostring(row.source or "unknown")
          if row and row.itemName then bit = bit .. ":" .. tostring(row.itemName) end
          if row and row.decorName then bit = bit .. ":" .. tostring(row.decorName) end
          rawHousingBits[#rawHousingBits + 1] = bit
        end
        table.sort(rawHousingBits)
      end
      if #rawHousingBits > 0 then
        extra = extra .. " rawHousing=" .. table.concat(rawHousingBits, "|")
      end
    elseif entry.kind == "appearance" then
      local a = dbg and dbg.appearance or nil
      local defAppearance = entry.debug and entry.debug.appearance or nil
      local sourceBits = {}
      if defAppearance and type(defAppearance.sources) == "table" then
        for source, count in pairs(defAppearance.sources) do
          sourceBits[#sourceBits + 1] = tostring(source) .. ":" .. tostring(count)
        end
        table.sort(sourceBits)
      end
      local candidateBits = {}
      if a and type(a.candidateAppearanceIDs) == "table" then
        for i = 1, #a.candidateAppearanceIDs do
          candidateBits[#candidateBits + 1] = tostring(a.candidateAppearanceIDs[i])
        end
      elseif defAppearance and type(defAppearance.appearanceIDs) == "table" then
        for i = 1, #defAppearance.appearanceIDs do
          candidateBits[#candidateBits + 1] = tostring(defAppearance.appearanceIDs[i])
        end
      end
      local modifiedBits = {}
      if a and type(a.candidateModifiedAppearanceIDs) == "table" then
        for i = 1, #a.candidateModifiedAppearanceIDs do
          modifiedBits[#modifiedBits + 1] = tostring(a.candidateModifiedAppearanceIDs[i])
        end
      elseif defAppearance and type(defAppearance.modifiedAppearanceIDs) == "table" then
        for i = 1, #defAppearance.modifiedAppearanceIDs do
          modifiedBits[#modifiedBits + 1] = tostring(defAppearance.modifiedAppearanceIDs[i])
        end
      end
      extra = (" owned=%s matchedAppearanceID=%s matchedModifiedAppearanceID=%s source=%s"):format(
        (a and a.owned) and "true" or "false",
        tostring(a and a.matchedAppearanceID or "nil"),
        tostring(a and a.matchedModifiedAppearanceID or "nil"),
        tostring(a and a.source or "nil")
      )
      if #candidateBits > 0 then
        extra = extra .. " candidates=" .. table.concat(candidateBits, ",")
      end
      if #modifiedBits > 0 then
        extra = extra .. " modifiedCandidates=" .. table.concat(modifiedBits, ",")
      end
      if #sourceBits > 0 then
        extra = extra .. " sources=" .. table.concat(sourceBits, "|")
      end
      local rawAppearanceBits = {}
      if defAppearance and type(defAppearance.raw) == "table" then
        for rawID, row in pairs(defAppearance.raw) do
          local bit = tostring(rawID) .. ":" .. tostring(row.source or "unknown")
          if row and row.itemName then bit = bit .. ":" .. tostring(row.itemName) end
          if row and row.appearanceID then bit = bit .. ":appearance=" .. tostring(row.appearanceID) end
          if row and type(row.appearanceIDs) == "table" and #row.appearanceIDs > 0 then
            local ids = {}
            for i = 1, #row.appearanceIDs do ids[#ids+1] = tostring(row.appearanceIDs[i]) end
            bit = bit .. ":candidates=" .. table.concat(ids, ",")
          end
          rawAppearanceBits[#rawAppearanceBits + 1] = bit
        end
        table.sort(rawAppearanceBits)
      end
      if #rawAppearanceBits > 0 then
        extra = extra .. " rawAppearance=" .. table.concat(rawAppearanceBits, "|")
      end
    end
  end

  return ("  - [%s] %s %s%s%s"):format(tostring(state or "?"), tostring(entry.kind or "?"), tostring(entry.identity and entry.identity.value or "?"), rawText, extra)
end


local function printAppearanceAudit(groupKey, group, mode)
  local coverage = buildCoverage(groupKey)
  if not coverage then
    ns.Print('Completion backend appearance-audit unavailable for: ' .. tostring(groupKey))
    return
  end
  local totals = coverage.totals or {}
  local entries = ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup and ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
  local unresolvedBucket = coverage.unresolvedCandidates and coverage.unresolvedCandidates.appearance or nil
  local appearanceEntries, collectedEntries = 0, 0
  local missingOwned, missingMapping = 0, 0
  local lines = {}
  for i = 1, #entries do
    local entry = entries[i]
    if entry and entry.kind == 'appearance' then
      appearanceEntries = appearanceEntries + 1
      local state = ns.CompletionEngine and ns.CompletionEngine.GetEntryState and ns.CompletionEngine.GetEntryState(entry.entryKey) or '?'
      if state == 'collected' then
        collectedEntries = collectedEntries + 1
      end
      local dbg = ns.CompletionEngine and ns.CompletionEngine.GetEntryDebug and ns.CompletionEngine.GetEntryDebug(entry.entryKey) or nil
      local a = dbg and dbg.appearance or nil
      local rawCount = type(entry.rawRefs) == 'table' and #entry.rawRefs or 0
      local status = (a and a.owned) and 'collected' or 'missing'
      local matched = a and a.matchedAppearanceID or nil
      local matchedModified = a and a.matchedModifiedAppearanceID or nil
      local source = a and a.source or nil
      local candidates = a and a.candidateAppearanceIDs or (entry.debug and entry.debug.appearance and entry.debug.appearance.appearanceIDs) or nil
      local modifiedCandidates = a and a.candidateModifiedAppearanceIDs or (entry.debug and entry.debug.appearance and entry.debug.appearance.modifiedAppearanceIDs) or nil
      if status == 'missing' then
        if (type(candidates) == 'table' and #candidates > 0) or (type(modifiedCandidates) == 'table' and #modifiedCandidates > 0) or (entry.identity and tonumber(entry.identity.value)) then
          missingOwned = missingOwned + 1
        else
          missingMapping = missingMapping + 1
        end
      end
      local bits = {}
      bits[#bits+1] = ('[%s] appearance=%s'):format(status, tostring(entry.identity and entry.identity.value or '?'))
      if matched then bits[#bits+1] = 'matched=' .. tostring(matched) end
      if matchedModified then bits[#bits+1] = 'matchedModified=' .. tostring(matchedModified) end
      if source then bits[#bits+1] = 'source=' .. tostring(source) end
      bits[#bits+1] = 'rawCount=' .. tostring(rawCount)
      if type(candidates) == 'table' and #candidates > 0 then
        local c = {}
        for j = 1, math.min(#candidates, 8) do c[#c+1] = tostring(candidates[j]) end
        if #candidates > 8 then c[#c+1] = ('+%d more'):format(#candidates - 8) end
        bits[#bits+1] = 'candidates=' .. table.concat(c, ',')
      else
        bits[#bits+1] = 'candidates=none'
      end
      if type(modifiedCandidates) == 'table' and #modifiedCandidates > 0 then
        local mc = {}
        for j = 1, math.min(#modifiedCandidates, 8) do mc[#mc+1] = tostring(modifiedCandidates[j]) end
        if #modifiedCandidates > 8 then mc[#mc+1] = ('+%d more'):format(#modifiedCandidates - 8) end
        bits[#bits+1] = 'modifiedCandidates=' .. table.concat(mc, ',')
      else
        bits[#bits+1] = 'modifiedCandidates=none'
      end
      if type(entry.rawRefs) == 'table' and #entry.rawRefs > 0 then
        local raws = {}
        for j = 1, math.min(#entry.rawRefs, 6) do raws[#raws+1] = tostring(entry.rawRefs[j]) end
        if #entry.rawRefs > 6 then raws[#raws+1] = ('+%d more'):format(#entry.rawRefs - 6) end
        bits[#bits+1] = 'raw=' .. table.concat(raws, ',')
      end
      lines[#lines + 1] = '  - ' .. table.concat(bits, ' ')
    end
  end
  ns.Print(("[%s] %s | %s | supported=%d/%d | unsupported raw items=%d of %d | match=%s"):format(
    tostring(groupKey), tostring(group.name or groupKey), tostring(group.category or '?'), tonumber(totals.collected or 0), tonumber(totals.total or 0), tonumber(totals.unsupportedItemCount or 0), tonumber(totals.rawItemCount or 0), tostring(mode or '?')
  ))
  ns.Print(("  appearance entries=%d | collected=%d | missing=%d | unresolved raw appearance candidates=%d"):format(
    appearanceEntries, collectedEntries, math.max(0, appearanceEntries - collectedEntries), tonumber(unresolvedBucket and unresolvedBucket.count or 0) or 0
  ))
  ns.Print(("  missingBecauseUnowned=%d | missingBecauseNoCandidates=%d"):format(missingOwned, missingMapping))
  if unresolvedBucket and type(unresolvedBucket.items) == 'table' and #unresolvedBucket.items > 0 then
    ns.Print('  unresolved raw appearance candidates:')
    for i = 1, math.min(#unresolvedBucket.items, 12) do
      local row = unresolvedBucket.items[i]
      ns.Print(("    - %s (%s) section=%s"):format(tostring(row.itemName or ('item:' .. tostring(row.rawID))), tostring(row.rawID), tostring(row.section or '?')))
    end
    if #unresolvedBucket.items > 12 then
      ns.Print(("    ...and %d more"):format(#unresolvedBucket.items - 12))
    end
  end
  if #lines == 0 then
    ns.Print('  No supported appearance entries for this key yet.')
    return
  end
  for i = 1, math.min(#lines, 60) do
    ns.Print(lines[i])
  end
  if #lines > 60 then
    ns.Print(("  ...and %d more appearance entries"):format(#lines - 60))
  end
end

SlashCmdList.CLOGCOMPLETION = function(msg)
  msg = tostring(msg or "")
  local cmd, rest = msg:match("^(%S+)%s*(.-)$")
  cmd = cmd and cmd:lower() or "status"
  rest = rest or ""

  if ns.CompletionDefinitions and ns.CompletionDefinitions.EnsureBuilt then ns.CompletionDefinitions.EnsureBuilt() end

  if cmd == "status" then
    local stats = ns.CompletionDefinitions and ns.CompletionDefinitions.GetStats and ns.CompletionDefinitions.GetStats() or { groups = 0, entries = 0 }
    local supportedRaidGroups = ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups("Raids") or {}
    local supportedDungeonGroups = ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups("Dungeons") or {}
    local raids = ns.CompletionEngine and ns.CompletionEngine.GetOverviewTotals and ns.CompletionEngine.GetOverviewTotals("Raids") or nil
    local dungeons = ns.CompletionEngine and ns.CompletionEngine.GetOverviewTotals and ns.CompletionEngine.GetOverviewTotals("Dungeons") or nil
    ns.Print(("Completion backend indexed groups=%d supported entries=%d"):format(tonumber(stats.groups or 0), tonumber(stats.entries or 0)))
    ns.Print(("  Supported groups: Raids=%d Dungeons=%d"):format(#supportedRaidGroups, #supportedDungeonGroups))
    if raids then
      local _, raidAudit = collectCoverageRows("Raids")
      ns.Print(("  Raids: %d/%d across %d supported groups (rowReady=%d panelReady=%d zero=%d)"):format(tonumber(raids.collected or 0), tonumber(raids.total or 0), tonumber(raids.groups or 0), tonumber(raidAudit and raidAudit.rowReady or 0), tonumber(raidAudit and raidAudit.panelReady or 0)))
    end
    if dungeons then
      local _, dungeonAudit = collectCoverageRows("Dungeons")
      ns.Print(("  Dungeons: %d/%d across %d supported groups (rowReady=%d panelReady=%d zero=%d)"):format(tonumber(dungeons.collected or 0), tonumber(dungeons.total or 0), tonumber(dungeons.groups or 0), tonumber(dungeonAudit and dungeonAudit.rowReady or 0), tonumber(dungeonAudit and dungeonAudit.panelReady or 0)))
    end
    local changes = ns.CompletionEngine and ns.CompletionEngine.GetLatestChanges and ns.CompletionEngine.GetLatestChanges() or {}
    ns.Print(("  Latest refresh changes=%d  use /clogcompletion find <name> or /clogcompletion groups"):format(#changes))
    return
  end

  if cmd == "rebuild" or cmd == "refresh" then
    if ns.CompletionDefinitions then
      ns.CompletionDefinitions._built = false
    end
    EV.Refresh("slash_rebuild")
    local stats = ns.CompletionDefinitions and ns.CompletionDefinitions.GetStats and ns.CompletionDefinitions.GetStats() or { groups = 0, entries = 0 }
    ns.Print(("Completion backend rebuilt: indexed groups=%d supported entries=%d"):format(tonumber(stats.groups or 0), tonumber(stats.entries or 0)))
    return
  end

  if cmd == "groups" then
    local category = categoryArgToLabel(rest)
    local groups = ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups(category) or {}
    ns.Print(("Completion backend supported groups%s: %d"):format(category and (" [" .. category .. "]") or "", #groups))
    local limit = math.min(#groups, 20)
    for i = 1, limit do
      local group = groups[i]
      ns.Print(("  %d) %s | key=%s | %s | supported=%d/%d raw"):format(i, tostring(group.name or group.groupKey), tostring(group.groupKey), tostring(group.category or "?"), tonumber(group.totalSupported or 0), tonumber(group.rawItemCount or 0)))
    end
    if #groups > limit then
      ns.Print(("  ...and %d more. Use /clogcompletion find <name> to narrow it down."):format(#groups - limit))
    end
    return
  end

  if cmd == "find" then
    local needle = trim(rest)
    if needle == "" then
      ns.Print("Usage: /clogcompletion find <raid or dungeon name>")
      return
    end
    local resolvedKey, resolved, mode = resolveQuery(needle)
    if resolvedKey and resolved then
      ns.Print(("Found: %s | key=%s | %s | supported=%d/%d raw | match=%s"):format(tostring(resolved.name or resolvedKey), tostring(resolvedKey), tostring(resolved.category or "?"), tonumber(resolved.totalSupported or 0), tonumber(resolved.rawItemCount or 0), tostring(mode or "?")))
      return
    end
    local matches = type(resolved) == "table" and resolved or {}
    if #matches == 0 then
      ns.Print("No supported backend group matched: " .. needle)
      ns.Print("Try /clogcompletion groups raids or /clogcompletion groups dungeons, then /clogcompletion group raids <number>")
      return
    end
    ns.Print(("Supported backend matches for '%s': %d"):format(needle, #matches))
    for i = 1, math.min(#matches, 10) do
      local row = matches[i]
      ns.Print(("  %d) %s | key=%s | %s | supported=%d/%d raw"):format(i, tostring(row.group and row.group.name or row.groupKey), tostring(row.groupKey), tostring(row.group and row.group.category or "?"), tonumber(row.group and row.group.totalSupported or 0), tonumber(row.group and row.group.rawItemCount or 0)))
    end
    return
  end

  if cmd == "groupkey" or cmd == "entrieskey" then
    local groupKey = trim(rest)
    local resolved = ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
    if not resolved then
      ns.Print("Completion backend has no supported group for exact key: " .. tostring(groupKey))
      return
    end

    local totals = ns.CompletionEngine and ns.CompletionEngine.GetGroupTotals and ns.CompletionEngine.GetGroupTotals(groupKey) or nil
    if not totals then
      ns.Print("Completion backend totals missing for: " .. tostring(groupKey))
      return
    end

    ns.Print(("[%s] %s | %s | %d/%d supported entries | unsupported raw items=%d of %d | match=exact_key"):format(
      tostring(groupKey), tostring(resolved.name or groupKey), tostring(resolved.category or "?"), tonumber(totals.collected or 0), tonumber(totals.total or 0), tonumber(totals.unsupportedItemCount or 0), tonumber(totals.rawItemCount or 0)
    ))

    if cmd == "entrieskey" then
      local entries = ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup and ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
      if #entries == 0 then
        ns.Print("  No supported entries.")
        return
      end
      for i = 1, #entries do
        local entry = entries[i]
        local state = ns.CompletionEngine and ns.CompletionEngine.GetEntryState and ns.CompletionEngine.GetEntryState(entry.entryKey) or "?"
        ns.Print(formatEntryLine(entry, state))
      end
    end
    return
  end

  if cmd == "group" or cmd == "entries" then
    local query = trim(rest)
    if query == "" then
      ns.Print(("Usage: /clogcompletion %s <groupID or visible name>"):format(cmd))
      return
    end
    local groupKey, resolved, mode = resolveQuery(query)
    if not groupKey or not resolved then
      local matches = type(resolved) == "table" and resolved or {}
      if #matches > 1 then
        ns.Print(("Ambiguous group '%s'. Top matches:"):format(query))
        for i = 1, math.min(#matches, 10) do
          local row = matches[i]
          ns.Print(("  %d) %s | key=%s | %s"):format(i, tostring(row.group and row.group.name or row.groupKey), tostring(row.groupKey), tostring(row.group and row.group.category or "?")))
        end
      else
        ns.Print("Completion backend has no supported group for: " .. tostring(query))
      end
      return
    end

    local totals = ns.CompletionEngine and ns.CompletionEngine.GetGroupTotals and ns.CompletionEngine.GetGroupTotals(groupKey) or nil
    if not totals then
      ns.Print("Completion backend totals missing for: " .. tostring(groupKey))
      return
    end

    ns.Print(("[%s] %s | %s | %d/%d supported entries | unsupported raw items=%d of %d | match=%s"):format(
      tostring(groupKey), tostring(resolved.name or groupKey), tostring(resolved.category or "?"), tonumber(totals.collected or 0), tonumber(totals.total or 0), tonumber(totals.unsupportedItemCount or 0), tonumber(totals.rawItemCount or 0), tostring(mode or "?")
    ))

    if cmd == "entries" then
      local entries = ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup and ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
      if #entries == 0 then
        ns.Print("  No supported entries.")
        return
      end
      for i = 1, #entries do
        local entry = entries[i]
        local state = ns.CompletionEngine and ns.CompletionEngine.GetEntryState and ns.CompletionEngine.GetEntryState(entry.entryKey) or "?"
        ns.Print(formatEntryLine(entry, state))
      end
    end
    return
  end

  if cmd == "coveragekey" then
    local groupKey = trim(rest)
    local resolved = ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
    if not resolved then
      ns.Print("Completion backend has no supported group for exact key: " .. tostring(groupKey))
      return
    end
    printCoverage(groupKey, resolved, "exact_key")
    return
  end

  if cmd == "coverage" then
    local query = trim(rest)
    if query == "" then
      ns.Print("Usage: /clogcompletion coverage <groupID or visible name>")
      return
    end
    local groupKey, resolved, mode = resolveQuery(query)
    if not groupKey or not resolved then
      local matches = type(resolved) == "table" and resolved or {}
      if #matches > 1 then
        ns.Print(("Ambiguous group '%s'. Top matches:"):format(query))
        for i = 1, math.min(#matches, 10) do
          local row = matches[i]
          ns.Print(("  %d) %s | key=%s | %s"):format(i, tostring(row.group and row.group.name or row.groupKey), tostring(row.groupKey), tostring(row.group and row.group.category or "?")))
        end
      else
        ns.Print("Completion backend has no supported group for: " .. tostring(query))
      end
      return
    end
    printCoverage(groupKey, resolved, mode)
    return
  end


  if cmd == "missingkey" then
    local groupKey = trim(rest)
    if groupKey == "" then
      ns.Print("Usage: /clogcompletion missingkey <exact key>")
      return
    end
    local resolved = ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
    if not resolved then
      ns.Print("Completion backend has no supported group for exact key: " .. tostring(groupKey))
      return
    end
    printMissing(groupKey, resolved, "exact_key")
    return
  end

  if cmd == "missing" then
    local query = trim(rest)
    if query == "" then
      ns.Print("Usage: /clogcompletion missing <groupID or visible name>")
      return
    end
    local groupKey, resolved, mode = resolveQuery(query)
    if not groupKey or not resolved then
      local matches = type(resolved) == "table" and resolved or {}
      if #matches > 1 then
        ns.Print(("Ambiguous group '%s'. Top matches:"):format(query))
        for i = 1, math.min(#matches, 10) do
          local row = matches[i]
          ns.Print(("  %d) %s | key=%s | %s"):format(i, tostring(row.group and row.group.name or row.groupKey), tostring(row.groupKey), tostring(row.group and row.group.category or "?")))
        end
      else
        ns.Print("Completion backend has no supported group for: " .. tostring(query))
      end
      return
    end
    printMissing(groupKey, resolved, mode)
    return
  end

  if cmd == "appearancekey" then
    local groupKey = trim(rest)
    if groupKey == "" then
      ns.Print("Usage: /clogcompletion appearancekey <exact key>")
      return
    end
    local resolved = ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
    if not resolved then
      ns.Print("Completion backend has no supported group for exact key: " .. tostring(groupKey))
      return
    end
    printAppearanceAudit(groupKey, resolved, "exact_key")
    return
  end

  if cmd == "appearance" then
    local query = trim(rest)
    if query == "" then
      ns.Print("Usage: /clogcompletion appearance <groupID or visible name>")
      return
    end
    local groupKey, resolved, mode = resolveQuery(query)
    if not groupKey or not resolved then
      local matches = type(resolved) == "table" and resolved or {}
      if #matches > 1 then
        ns.Print(("Ambiguous group '%s'. Top matches:"):format(query))
        for i = 1, math.min(#matches, 10) do
          local row = matches[i]
          ns.Print(("  %d) %s | key=%s | %s"):format(i, tostring(row.group and row.group.name or row.groupKey), tostring(row.groupKey), tostring(row.group and row.group.category or "?")))
        end
      else
        ns.Print("Completion backend has no supported group for: " .. tostring(query))
      end
      return
    end
    printAppearanceAudit(groupKey, resolved, mode)
    return
  end

  if cmd == "audit" then
    local arg1, arg2, arg3 = rest:match("^(%S*)%s*(%S*)%s*(%S*)$")
    arg1 = trim(arg1)
    arg2 = trim(arg2)
    arg3 = trim(arg3)
    local category = categoryArgToLabel(arg1)
    if not category then
      category = "Raids"
      arg3 = arg2
      arg2 = arg1
    end
    local mode = arg2 ~= "" and arg2 or "all"
    local page = tonumber(arg3) or 1
    printAudit(category, mode, page)
    return
  end

  if cmd == "changes" then
    local changes = ns.CompletionEngine and ns.CompletionEngine.GetLatestChanges and ns.CompletionEngine.GetLatestChanges() or {}
    ns.Print(("Completion backend latest changes: %d"):format(#changes))
    for i = 1, math.min(#changes, 10) do
      local row = changes[i]
      ns.Print(("  %d) %s | %s | %s"):format(i, tostring(row.groupKey), tostring(row.kind), tostring(row.identityValue)))
    end
    return
  end

  printUsage()
end
