local ADDON, ns = ...

ns.CompletionV2 = ns.CompletionV2 or {}
local Completion = ns.CompletionV2


Completion._statusCache = Completion._statusCache or {}
Completion._definitionsScopeCache = Completion._definitionsScopeCache or {}


function Completion.ClearStatusCacheOnly(reason)
  if wipe then
    wipe(Completion._statusCache)
  else
    for k in pairs(Completion._statusCache or {}) do Completion._statusCache[k] = nil end
  end
  if ns.Truth and ns.Truth.ClearCache then pcall(ns.Truth.ClearCache, reason or "status_only") end
  Completion._cacheGeneration = (tonumber(Completion._cacheGeneration) or 0) + 1
  Completion._lastStatusClearReason = tostring(reason or "status_only")
end

function Completion.ClearCache(reason)
  if wipe then
    wipe(Completion._statusCache)
    wipe(Completion._definitionsScopeCache)
  else
    for k in pairs(Completion._statusCache) do Completion._statusCache[k] = nil end
    for k in pairs(Completion._definitionsScopeCache) do Completion._definitionsScopeCache[k] = nil end
  end
  if ns.Registry and ns.Registry.ClearCache then pcall(ns.Registry.ClearCache, reason or "completion_clear") end
  if ns.Truth and ns.Truth.ClearCache then pcall(ns.Truth.ClearCache, reason or "completion_clear") end
  Completion._cacheGeneration = (tonumber(Completion._cacheGeneration) or 0) + 1
  Completion._lastClearReason = tostring(reason or "manual")
end

local PHASE_TYPES = {
  phase1 = { mount = true, pet = true, toy = true },
  mpt = { mount = true, pet = true, toy = true },
  phase2 = { mount = true, pet = true, toy = true, appearance = true, housing = true },
  mpta = { mount = true, pet = true, toy = true, appearance = true, housing = true },
  phase2dedupe = { mount = true, pet = true, toy = true, appearance = true, housing = true },
  dedupe = { mount = true, pet = true, toy = true, appearance = true, housing = true },
}

local function normType(t)
  return tostring(t or ""):lower()
end

function Completion.EnsureReady(reason)
  if ns.CompletionEvents and ns.CompletionEvents.EnsureWarm then
    return ns.CompletionEvents.EnsureWarm(reason or "compare")
  end
  if ns.CompletionEngine and ns.CompletionEngine.RecomputeAll then
    return ns.CompletionEngine.RecomputeAll(reason or "compare")
  end
  return false
end

local function canonicalDefinitionKey(def)
  if type(def) ~= "table" then return nil end
  local t = normType(def.type)
  local id = tonumber(def.collectibleID)
  if not id or id <= 0 then
    id = tonumber(def.itemID)
  end
  if not id or id <= 0 then return nil end

  -- Appearance truth is tracked by the canonical appearanceID, not by the
  -- source itemID / difficulty / Timewalking variant that awarded it.
  if t == "appearance" then return "appearance:" .. tostring(id) end

  -- Mounts/pets/toys were already normalized in phase 1, but keep the same
  -- guard here so compare scopes cannot accidentally double-count aliases.
  return t .. ":" .. tostring(id)
end

local function shouldTreatAggregateAppearanceTotalsAsUnsupported(groupKey)
  groupKey = tostring(groupKey or "")
  if groupKey == "" or groupKey:match("^raw:") then return false end
  local group = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
  local category = type(group) == "table" and tostring(group.category or "") or ""
  return category == "Raids" or category == "Dungeons"
end

local function aggregateDifficultyTierRank(difficultyID, modeName)
  local mode = tostring(modeName or ""):lower()
  if difficultyID == 16 or difficultyID == 23 or mode:find("mythic", 1, true) then return 4 end
  if difficultyID == 15 or difficultyID == 2 or difficultyID == 5 or difficultyID == 6 or difficultyID == 11 or mode:find("heroic", 1, true) then return 3 end
  if difficultyID == 14 or difficultyID == 1 or difficultyID == 3 or difficultyID == 4 or difficultyID == 9 or mode:find("normal", 1, true) or mode:find("timewalking", 1, true) then return 2 end
  if difficultyID == 17 or difficultyID == 7 or mode:find("looking for raid", 1, true) or mode:find("lfr", 1, true) then return 1 end
  return 0
end

local function aggregateDifficultySizeValue(difficultyID, modeName)
  local mode = tostring(modeName or "")
  local size = tonumber(mode:match("(%d+)"))
  if size and size > 0 then return size end
  if difficultyID == 3 or difficultyID == 5 then return 10 end
  if difficultyID == 4 or difficultyID == 6 then return 25 end
  return 0
end

local function betterAggregateRawGroupCandidate(a, b)
  if not a then return b end
  if not b then return a end
  local ar, br = aggregateDifficultyTierRank(a.difficultyID, a.mode), aggregateDifficultyTierRank(b.difficultyID, b.mode)
  if ar ~= br then
    return (br > ar) and b or a
  end
  local as, bs = aggregateDifficultySizeValue(a.difficultyID, a.mode), aggregateDifficultySizeValue(b.difficultyID, b.mode)
  if as ~= bs then
    return (bs > as) and b or a
  end
  return tostring(b.id or "") < tostring(a.id or "") and b or a
end

local function chooseAggregateRawGroup(aggregate)
  if type(aggregate) ~= "table" then return nil end
  local sourceKeys = type(aggregate.sourceGroupKeys) == "table" and aggregate.sourceGroupKeys or nil
  if not (sourceKeys and ns and ns.Data and ns.Data.groups) then return nil end

  local candidates = {}
  for rawKey in pairs(sourceKeys) do
    local rawGroup = ns.Data.groups[rawKey] or ns.Data.groups[tonumber(rawKey) or -1]
    if type(rawGroup) == "table" then
      candidates[#candidates + 1] = rawGroup
    end
  end
  if #candidates == 0 then return nil end

  local aggregateCategory = tostring(aggregate.category or "")
  local aggregateInstanceID = tonumber(aggregate.instanceID or 0) or 0

  local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId or nil
  local activeGroup = activeID and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
  if type(activeGroup) == "table"
    and tostring(activeGroup.category or "") == aggregateCategory
    and tonumber(activeGroup.instanceID or 0) == aggregateInstanceID then
    for i = 1, #candidates do
      if tostring(candidates[i].id or "") == tostring(activeGroup.id or "") then
        return candidates[i]
      end
    end
  end

  local rememberedDifficultyID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.lastDifficultyByInstance and CollectionLogDB.ui.lastDifficultyByInstance[aggregateInstanceID] or nil
  if rememberedDifficultyID then
    local remembered = nil
    for i = 1, #candidates do
      local candidate = candidates[i]
      if tonumber(candidate.difficultyID or 0) == tonumber(rememberedDifficultyID or -1) then
        remembered = betterAggregateRawGroupCandidate(remembered, candidate)
      end
    end
    if remembered then return remembered end
  end

  local chosen = nil
  for i = 1, #candidates do
    chosen = betterAggregateRawGroupCandidate(chosen, candidates[i])
  end
  return chosen
end

local function getAggregatePreviewStatus(groupKey, appearanceMode)
  if not (ns and ns.ComputeSelectedDifficultyAggregatePreview and ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup) then
    return nil
  end

  local aggregate = ns.CompletionDefinitions.GetGroup(groupKey)
  if type(aggregate) ~= "table" then return nil end

  local chosen = chooseAggregateRawGroup(aggregate)
  if type(chosen) ~= "table" then
    return nil
  end

  local preview = select(1, ns.ComputeSelectedDifficultyAggregatePreview(chosen, appearanceMode))
  if type(preview) ~= "table" then
    return nil
  end

  local collected = tonumber(preview.collected or 0) or 0
  local total = tonumber(preview.total or 0) or 0
  return {
    groupKey = groupKey,
    collected = collected,
    total = total,
    complete = (total > 0 and collected >= total) or false,
    unsupported = nil,
    unsupportedItemCount = 0,
    rawItemCount = total,
    source = "Registry+Truth(aggregate_preview:" .. tostring(appearanceMode or "shared") .. ")",
    scope = "phase2",
    definitions = {},
    rawScopedDefinitionCount = total,
    dedupedRemoved = 0,
  }
end

local function aggregateSelectionCacheSuffix(groupKey)
  if not shouldTreatAggregateAppearanceTotalsAsUnsupported(groupKey) then
    return ""
  end

  local aggregate = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetGroup and ns.CompletionDefinitions.GetGroup(groupKey) or nil
  local instanceID = type(aggregate) == "table" and tonumber(aggregate.instanceID or 0) or 0
  local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId or nil
  local activeGroup = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
  local activePart = ""
  if type(activeGroup) == "table"
    and tonumber(activeGroup.instanceID or 0) == instanceID
    and tostring(activeGroup.category or "") == tostring(aggregate and aggregate.category or "") then
    activePart = "|activeGroup=" .. tostring(activeGroup.id or "")
  end

  local rememberedDifficultyID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.lastDifficultyByInstance and CollectionLogDB.ui.lastDifficultyByInstance[instanceID] or nil
  local rememberedPart = rememberedDifficultyID and ("|rememberedDifficulty=" .. tostring(rememberedDifficultyID)) or ""
  return activePart .. rememberedPart
end

local function shallowCopyDefinition(def)
  local copy = {}
  if type(def) == "table" then
    for k, v in pairs(def) do copy[k] = v end
  end
  return copy
end

local function sourceDebug(def)
  if type(def) ~= "table" then return nil end
  local name = def.name
  if (not name or name == "" or name == "?") and ns.NameResolver and ns.NameResolver.GetDefinitionName then
    name = ns.NameResolver.GetDefinitionName(def, true)
  end
  return {
    itemID = def.itemID,
    collectibleID = def.collectibleID,
    type = def.type,
    name = name,
    entryKey = def.entryKey,
  }
end

local function dedupeDefinitions(defs)
  local out, seen, removed = {}, {}, 0
  for i = 1, #(defs or {}) do
    local def = defs[i]
    local key = canonicalDefinitionKey(def)
    if key then
      if not seen[key] then
        local kept = shallowCopyDefinition(def)
        kept._dedupeCanonicalKey = key
        kept._dedupeSources = { sourceDebug(def) }
        seen[key] = kept
        out[#out + 1] = kept
      else
        removed = removed + 1
        -- Preserve debug context on the kept definition so verbose compare can
        -- show exactly which source variants collapsed together.  Do this on a
        -- per-call copy, not the registry definition, so repeated compare runs
        -- do not accumulate duplicate debug rows.
        local kept = seen[key]
        kept._dedupeSources = kept._dedupeSources or {}
        kept._dedupeSources[#kept._dedupeSources + 1] = sourceDebug(def)
      end
    else
      -- Unknown definitions are kept rather than silently discarded.
      out[#out + 1] = shallowCopyDefinition(def)
    end
  end
  return out, removed
end

function Completion.GetDefinitionsForScope(groupKey, scope, opts)
  groupKey = tostring(groupKey or "")
  scope = tostring(scope or "phase1"):lower()
  opts = type(opts) == "table" and opts or {}
  local dedupe = (scope == "phase2" or scope == "mpta" or scope == "phase2dedupe" or scope == "dedupe" or opts.dedupe) and true or false
  local cacheable = opts.noCache ~= true
  local cacheKey = scope .. "|" .. (dedupe and "1" or "0") .. "|" .. groupKey
  Completion._definitionsScopeCache = Completion._definitionsScopeCache or {}
  local cached = cacheable and Completion._definitionsScopeCache[cacheKey] or nil
  if cached then return cached.defs, cached.rawScopedCount, cached.dedupedRemoved end

  local defs = ns.Registry and ns.Registry.GetGroupDefinitions and ns.Registry.GetGroupDefinitions(groupKey) or {}
  if scope == "all" then
    if cacheable then Completion._definitionsScopeCache[cacheKey] = { defs = defs, rawScopedCount = #defs, dedupedRemoved = 0 } end
    return defs, #defs, 0
  end

  local allowed = PHASE_TYPES[scope] or PHASE_TYPES.phase1
  local filtered = {}
  for i = 1, #defs do
    if allowed[normType(defs[i].type)] then
      filtered[#filtered + 1] = defs[i]
    end
  end

  if dedupe then
    local deduped, removed = dedupeDefinitions(filtered)
    if cacheable then Completion._definitionsScopeCache[cacheKey] = { defs = deduped, rawScopedCount = #filtered, dedupedRemoved = removed } end
    return deduped, #filtered, removed
  end

  if cacheable then Completion._definitionsScopeCache[cacheKey] = { defs = filtered, rawScopedCount = #filtered, dedupedRemoved = 0 } end
  return filtered, #filtered, 0
end

function Completion.CalculateDefinitions(defs)
  local collected, total = 0, #(defs or {})
  for i = 1, total do
    if ns.Truth and ns.Truth.IsCollected and ns.Truth.IsCollected(defs[i]) then
      collected = collected + 1
    end
  end
  return collected, total, (total > 0 and collected >= total or false)
end

function Completion.GetGroupStatus(groupKey, opts)
  groupKey = tostring(groupKey or "")
  if groupKey == "" then return nil end

  opts = type(opts) == "table" and opts or {}
  local scope = tostring(opts.scope or "phase1"):lower()
  local cacheable = opts.noCache ~= true
  local appearanceMode = ""
  if scope == "phase2" or scope == "mpta" or scope == "phase2dedupe" or scope == "dedupe" then
    local okMode, mode = false, nil
    if ns and ns.GetAppearanceCollectionMode then
      okMode, mode = pcall(ns.GetAppearanceCollectionMode)
    end
    appearanceMode = "|appearanceMode=" .. tostring((okMode and mode) or (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode) or "shared")
  end
  local cacheKey = scope .. "|" .. groupKey .. appearanceMode .. aggregateSelectionCacheSuffix(groupKey)

  if cacheable and Completion._statusCache and Completion._statusCache[cacheKey] then
    return Completion._statusCache[cacheKey]
  end

  -- Compare scopes deliberately do NOT use the legacy CompletionEngine totals.
  -- This layer proves normalized registry/truth behavior before any UI code is
  -- allowed to consume the result.
  local aggregateAppearanceMode = appearanceMode:match("|appearanceMode=([^|]+)")
  if (scope == "phase2" or scope == "mpta" or scope == "phase2dedupe" or scope == "dedupe")
    and shouldTreatAggregateAppearanceTotalsAsUnsupported(groupKey) then
    local previewStatus = getAggregatePreviewStatus(groupKey, aggregateAppearanceMode or "shared")
    if previewStatus then
      if cacheable then
        Completion._statusCache = Completion._statusCache or {}
        Completion._statusCache[cacheKey] = previewStatus
      end
      return previewStatus
    end
    if appearanceMode:find("|appearanceMode=strict", 1, true) then
      local unsupported = {
        groupKey = groupKey,
        collected = 0,
        total = 0,
        complete = false,
        unsupported = true,
        unsupportedReason = "aggregate_raid_dungeon_strict_totals_not_supported",
        unsupportedScope = "aggregateAppearanceTotals",
        source = "Registry+Truth(unsupported_aggregate_strict_totals)",
        scope = scope,
        definitions = {},
        rawScopedDefinitionCount = 0,
        dedupedRemoved = 0,
      }
      if cacheable then
        Completion._statusCache = Completion._statusCache or {}
        Completion._statusCache[cacheKey] = unsupported
      end
      return unsupported
    end
  end
  local defs, rawScopedCount, dedupedRemoved = Completion.GetDefinitionsForScope(groupKey, scope, opts)
  local collected, total, complete = Completion.CalculateDefinitions(defs)

  local result = {
    groupKey = groupKey,
    collected = collected,
    total = total,
    complete = complete,
    unsupportedItemCount = 0,
    rawItemCount = total,
    source = scope == "all" and "Registry+Truth(all)" or (scope == "phase2" or scope == "mpta" or scope == "phase2dedupe" or scope == "dedupe") and "Registry+Truth(phase2:mpt+appearances+housing:deduped)" or "Registry+Truth(phase1:mpt)",
    scope = scope,
    definitions = defs,
    rawScopedDefinitionCount = rawScopedCount or #defs,
    dedupedRemoved = dedupedRemoved or 0,
  }

  if cacheable then
    Completion._statusCache = Completion._statusCache or {}
    Completion._statusCache[cacheKey] = result
  end
  return result
end
