local ADDON, ns = ...

local function Print(msg)
  if ns and ns.Print then ns.Print(msg) else print("Collection Log: " .. tostring(msg)) end
end

local function countKinds(defs)
  local out = {}
  for i = 1, #(defs or {}) do
    local k = tostring(defs[i].type or "unknown")
    out[k] = (out[k] or 0) + 1
  end
  return out
end

local function sortedKindLine(kinds)
  local order = { "mount", "pet", "toy", "housing", "appearance", "unknown" }
  local parts, seen = {}, {}
  for _, k in ipairs(order) do
    if kinds[k] then
      parts[#parts + 1] = k .. "=" .. tostring(kinds[k])
      seen[k] = true
    end
  end
  local extras = {}
  for k in pairs(kinds or {}) do if not seen[k] then extras[#extras + 1] = k end end
  table.sort(extras)
  for _, k in ipairs(extras) do parts[#parts + 1] = k .. "=" .. tostring(kinds[k]) end
  return table.concat(parts, ", ")
end

local function activeHeaderText()
  local ui = ns and ns.UI or nil
  local fs = ui and ui.groupCount or nil
  if fs and fs.GetText then
    local ok, txt = pcall(fs.GetText, fs)
    if ok and txt and txt ~= "" then return txt end
  end
  return nil
end

local function scopeFromMsg(msg)
  msg = tostring(msg or ""):lower()
  -- Treat the new user-facing "true" mode as the phase2/canonical scope for
  -- now: mounts/pets/toys + appearances, collectible-only, deduped by canonical
  -- identity. Keep the internal scope value as phase2 so existing completion
  -- code remains untouched.
  if msg:find("true", 1, true) or msg:find("canonical", 1, true) or msg:find("dedupe", 1, true) or msg:find("phase2", 1, true) or msg:find("appearance", 1, true) or msg:find("appearances", 1, true) then return "phase2" end
  if msg:find("alltypes", 1, true) or msg:find("fullscope", 1, true) then return "all" end
  return "phase1"
end

local function parseCompareMessage(msg)
  msg = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  local tokens = {}
  for token in msg:gmatch("%S+") do tokens[#tokens + 1] = token end

  local navParts = {}
  local scope = "phase1"
  local verbose, rowMode = false, false
  local sawAll, sawCategory = false, false

  for _, token in ipairs(tokens) do
    local l = token:lower()
    if l == "true" or l == "canonical" or l == "dedupe" or l == "phase2" or l == "appearance" or l == "appearances" then
      scope = "phase2"
    elseif l == "alltypes" or l == "fullscope" then
      scope = "all"
    elseif l == "verbose" or l == "diff" or l == "debug" then
      verbose = true
    elseif l == "row" or l == "rows" or l == "difficulty" or l == "difficulties" or l == "visible" then
      rowMode = true
    else
      navParts[#navParts + 1] = token
      if l == "all" then sawAll = true end
      if l == "raid" or l == "raids" or l == "dungeon" or l == "dungeons" then sawCategory = true end
    end
  end

  local nav = table.concat(navParts, " "):match("^%s*(.-)%s*$") or ""

  -- Canonical/true mode is defined per visible raid/dungeon row.  Make common
  -- user commands do the useful thing even if they omit the word "rows".
  if scope == "phase2" and sawAll then
    rowMode = true
  end

  return {
    raw = msg,
    lower = msg:lower(),
    scope = scope,
    verbose = verbose,
    rowMode = rowMode,
    nav = nav,
    sawAll = sawAll,
    sawCategory = sawCategory,
  }
end

local function scopeLabel(scope)
  scope = tostring(scope or "phase1"):lower()
  if scope == "phase2" or scope == "mpta" or scope == "phase2dedupe" or scope == "dedupe" then return "true collection (collectible-only, canonical-deduped; compare-only)" end
  if scope == "all" then return "all normalized definitions; compare-only" end
  return "phase1 only (mounts/pets/toys). Appearances intentionally excluded."
end

local function missingLabel(scope)
  scope = tostring(scope or "phase1"):lower()
  if scope == "phase2" or scope == "mpta" or scope == "phase2dedupe" or scope == "dedupe" then return "missing phase2" end
  if scope == "all" then return "missing all" end
  return "missing phase1"
end

local function isCollected(def)
  return ns.Truth and ns.Truth.IsCollected and ns.Truth.IsCollected(def) or false
end

local function collectMissing(defs, limit)
  limit = tonumber(limit or 8) or 8
  local missing = {}
  defs = defs or {}
  for i = 1, #defs do
    local def = defs[i]
    if not isCollected(def) then
      missing[#missing + 1] = def
    end
  end
  return missing
end

local function defDisplayName(def, queue)
  if type(def) ~= "table" then return "?" end
  local name = def.name
  if (not name or name == "" or name == "?") and ns.NameResolver and ns.NameResolver.GetDefinitionName then
    name = ns.NameResolver.GetDefinitionName(def, queue and true or false)
  end
  return name or "?"
end

local function printMissing(defs, limit, prefix)
  limit = tonumber(limit or 8) or 8
  prefix = prefix or "  missing phase1"
  local missing = collectMissing(defs, limit)
  for i = 1, math.min(#missing, limit) do
    local def = missing[i]
    Print(("%s: %s item=%s collectible=%s name=%s"):format(prefix, tostring(def.type or "?"), tostring(def.itemID or "?"), tostring(def.collectibleID or "?"), tostring(defDisplayName(def, true))))
  end
  if #missing > limit then Print(("%s: ...and %d more"):format(prefix, #missing - limit)) end
  if #missing == 0 then Print(prefix .. ": none") end
end

local function ensureDefinitionsBuilt()
  if ns.CompletionDefinitions and ns.CompletionDefinitions.EnsureBuilt then
    ns.CompletionDefinitions.EnsureBuilt()
  end
end


local function wantsVerbose(msg)
  msg = tostring(msg or ""):lower()
  return msg:find("verbose", 1, true) or msg:find("diff", 1, true) or msg:find("debug", 1, true)
end

local function rawItemListForGroup(group)
  local out, seen = {}, {}
  if type(group) ~= "table" then return out end
  local function add(v)
    local id = tonumber(v)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  if type(group.items) == "table" then
    for _, id in ipairs(group.items) do add(id) end
  end
  if type(group.itemIDs) == "table" then
    for _, id in ipairs(group.itemIDs) do add(id) end
  end
  if #out == 0 and type(group.itemLinks) == "table" then
    for _, id in ipairs(group.itemLinks) do add(id) end
  end
  table.sort(out)
  return out
end

local function definitionKey(def)
  if type(def) ~= "table" then return nil end
  local t = tostring(def.type or "?"):lower()
  local id = tonumber(def.collectibleID) or tonumber(def.itemID)
  if not id or id <= 0 then return nil end
  return t .. ":" .. tostring(id)
end

local function describeItem(itemID)
  itemID = tonumber(itemID)
  local def = ns.Registry and ns.Registry.GetItemDefinition and ns.Registry.GetItemDefinition(itemID) or nil
  local secFast = ns.GetItemSectionFast and ns.GetItemSectionFast(itemID) or nil
  local secFull = ns.GetItemSection and ns.GetItemSection(itemID) or nil
  local name = def and def.name or nil
  if (not name or name == "" or name == "?") and ns.NameResolver and ns.NameResolver.GetItemName then
    name = ns.NameResolver.GetItemName(itemID, true)
  end
  if (not name or name == "") and GetItemInfo then
    local ok, n = pcall(GetItemInfo, itemID)
    if ok then name = n end
  end
  return {
    itemID = itemID,
    type = def and def.type or "?",
    collectibleID = def and def.collectibleID or "?",
    name = name or "?",
    secFast = secFast or "?",
    secFull = secFull or "?",
    hasRegistry = def and true or false,
  }
end


local function printDedupeDebug(defs)
  local groups = {}
  for i = 1, #(defs or {}) do
    local def = defs[i]
    local sources = type(def) == "table" and def._dedupeSources or nil
    if type(sources) == "table" and #sources > 1 then
      groups[#groups + 1] = def
    end
  end
  table.sort(groups, function(a, b)
    local ak = tostring(a._dedupeCanonicalKey or definitionKey(a) or "")
    local bk = tostring(b._dedupeCanonicalKey or definitionKey(b) or "")
    return ak < bk
  end)

  if #groups == 0 then
    Print("  dedupe debug: no collapsed definitions in this scope")
    return
  end

  Print("  dedupe debug: collapsed definitions (canonical collectible with multiple source items):")
  local maxGroups, maxSources = 20, 12
  for i = 1, math.min(#groups, maxGroups) do
    local def = groups[i]
    local sources = def._dedupeSources or {}
    Print(("    canonical=%s type=%s collectible=%s keptItem=%s keptName=%s sources=%d"):format(tostring(def._dedupeCanonicalKey or definitionKey(def) or "?"), tostring(def.type or "?"), tostring(def.collectibleID or "?"), tostring(def.itemID or "?"), tostring(defDisplayName(def, true)), #sources))
    for j = 1, math.min(#sources, maxSources) do
      local src = sources[j] or {}
      local marker = (tonumber(src.itemID) == tonumber(def.itemID)) and "kept" or "collapsed"
      local srcName = src.name
      if (not srcName or srcName == "" or srcName == "?") and ns.NameResolver and ns.NameResolver.GetItemName and tonumber(src.itemID) then
        srcName = ns.NameResolver.GetItemName(src.itemID, true)
      end
      Print(("      - %s item=%s collectible=%s name=%s entry=%s"):format(marker, tostring(src.itemID or "?"), tostring(src.collectibleID or "?"), tostring(srcName or "?"), tostring(src.entryKey or "?")))
    end
    if #sources > maxSources then
      Print("      ...and " .. tostring(#sources - maxSources) .. " more source items")
    end
  end
  if #groups > maxGroups then
    Print("    ...and " .. tostring(#groups - maxGroups) .. " more collapsed canonical definitions")
  end
end

local function printVerboseDiff(groupKey, group, defs, scope)
  local rawItems = rawItemListForGroup(group)
  local rawSet = {}
  for _, itemID in ipairs(rawItems) do rawSet[itemID] = true end

  local backendItemSet, backendKeySet = {}, {}
  local backendItemCount = 0
  for i = 1, #(defs or {}) do
    local def = defs[i]
    if def and tonumber(def.itemID) then
      local id = tonumber(def.itemID)
      if id and id > 0 and not backendItemSet[id] then
        backendItemSet[id] = true
        backendItemCount = backendItemCount + 1
      end
    end
    local k = definitionKey(def)
    if k then backendKeySet[k] = true end
  end

  local rawMissing, backendOnly = {}, {}
  for _, itemID in ipairs(rawItems) do
    if not backendItemSet[itemID] then
      rawMissing[#rawMissing + 1] = describeItem(itemID)
    end
  end
  for i = 1, #(defs or {}) do
    local def = defs[i]
    local id = tonumber(def and def.itemID)
    if id and id > 0 and not rawSet[id] then
      backendOnly[#backendOnly + 1] = def
    end
  end

  Print(("  verbose diff: raw active row items=%d backend defs=%d backend defs with itemID=%d raw-not-in-backend=%d backend-not-in-raw=%d"):format(#rawItems, #(defs or {}), backendItemCount, #rawMissing, #backendOnly))
  Print(("  verbose diff: group id=%s name=%s category=%s instanceID=%s difficultyID=%s mode=%s"):format(tostring(group and group.id or "?"), tostring(group and group.name or "?"), tostring(group and group.category or "?"), tostring(group and group.instanceID or "?"), tostring(group and group.difficultyID or "?"), tostring(group and group.mode or "?")))
  printDedupeDebug(defs)

  local limit = 30
  if #rawMissing == 0 then
    Print("  raw items missing from backend: none")
  else
    Print("  raw items missing from backend (showing up to " .. tostring(limit) .. "):")
    for i = 1, math.min(#rawMissing, limit) do
      local r = rawMissing[i]
      Print(("    raw-only item=%s type=%s collectible=%s secFast=%s secFull=%s name=%s registry=%s"):format(tostring(r.itemID), tostring(r.type), tostring(r.collectibleID), tostring(r.secFast), tostring(r.secFull), tostring(r.name), r.hasRegistry and "yes" or "no"))
    end
    if #rawMissing > limit then Print("    ...and " .. tostring(#rawMissing - limit) .. " more raw-only items") end
  end

  if #backendOnly == 0 then
    Print("  backend definitions missing from raw row: none")
  else
    Print("  backend definitions missing from raw row (showing up to " .. tostring(limit) .. "):")
    for i = 1, math.min(#backendOnly, limit) do
      local def = backendOnly[i]
      Print(("    backend-only %s item=%s collectible=%s name=%s entry=%s"):format(tostring(def.type or "?"), tostring(def.itemID or "?"), tostring(def.collectibleID or "?"), tostring(def.name or "?"), tostring(def.entryKey or "?")))
    end
    if #backendOnly > limit then Print("    ...and " .. tostring(#backendOnly - limit) .. " more backend-only definitions") end
  end
end

local function printOne(groupKey, group, mode, scope, verbose)
  scope = scope or "phase1"
  local allDefs = ns.Registry and ns.Registry.GetGroupDefinitions and ns.Registry.GetGroupDefinitions(groupKey) or {}
  local status = ns.CompletionV2 and ns.CompletionV2.GetGroupStatus and ns.CompletionV2.GetGroupStatus(groupKey, { scope = scope }) or nil
  local defs = status and status.definitions or {}
  if ns.NameResolver and ns.NameResolver.QueueDefinitions then
    ns.NameResolver.QueueDefinitions(defs, verbose and 500 or 80)
  end
  local allKinds = countKinds(allDefs)
  local phaseKinds = countKinds(defs)

  Print(("Compare: %s [%s] via %s"):format(tostring(group.name or groupKey), tostring(groupKey), tostring(mode or "?")))
  Print("  scope: " .. scopeLabel(scope))
  if status then
    Print(("  backend: %d/%d complete=%s source=%s"):format(tonumber(status.collected or 0), tonumber(status.total or 0), status.complete and "true" or "false", tostring(status.source or "?")))
    if tonumber(status.rawScopedDefinitionCount or #defs) ~= #defs or tonumber(status.dedupedRemoved or 0) > 0 then
      Print(("  dedupe: scoped raw=%d unique=%d removed=%d"):format(tonumber(status.rawScopedDefinitionCount or #defs), #defs, tonumber(status.dedupedRemoved or 0)))
    end
  else
    Print("  backend: unavailable")
  end
  Print("  scoped definitions: " .. tostring(#defs) .. (next(phaseKinds) and (" (" .. sortedKindLine(phaseKinds) .. ")") or ""))
  Print("  all normalized definitions: " .. tostring(#allDefs) .. (next(allKinds) and (" (" .. sortedKindLine(allKinds) .. ")") or ""))
  local hdr = activeHeaderText()
  if hdr then Print("  currently visible header is legacy/full UI, not this compare scope: " .. hdr) end
  printMissing(defs, 8, "  " .. missingLabel(scope))
  if verbose then printVerboseDiff(groupKey, group, defs, scope) end
end

local function categoryFilterFromMsg(msg)
  msg = tostring(msg or ""):lower()
  if msg:find("dungeon", 1, true) then return "Dungeons" end
  if msg:find("raid", 1, true) then return "Raids" end
  return nil
end

local function wantsRawRows(msg)
  msg = tostring(msg or ""):lower()
  return msg:find("row", 1, true) or msg:find("rows", 1, true) or msg:find("difficulty", 1, true) or msg:find("difficulties", 1, true) or msg:find("visible", 1, true)
end

local function runAllRows(msg, scope)
  ensureDefinitionsBuilt()
  scope = scope or scopeFromMsg(msg)
  local category = categoryFilterFromMsg(msg)
  local groups = ns and ns.Data and ns.Data.groups or {}

  local scanned, withScoped, completeGroups, incompleteGroups, emptyScoped = 0, 0, 0, 0, 0
  local defTotals = { mount = 0, pet = 0, toy = 0, appearance = 0, housing = 0 }
  local collectedTotal, totalDefs = 0, 0
  local incomplete = {}

  for _, group in pairs(groups) do
    if type(group) == "table" and (group.category == "Raids" or group.category == "Dungeons") and (not category or group.category == category) then
      local groupKey = ns.Registry and ns.Registry.GetRawGroupKey and ns.Registry.GetRawGroupKey(group) or nil
      if groupKey then
        scanned = scanned + 1
        local status = ns.CompletionV2 and ns.CompletionV2.GetGroupStatus and ns.CompletionV2.GetGroupStatus(groupKey, { scope = scope }) or nil
        local defs = status and status.definitions or {}
        local kinds = countKinds(defs)
        defTotals.mount = defTotals.mount + tonumber(kinds.mount or 0)
        defTotals.pet = defTotals.pet + tonumber(kinds.pet or 0)
        defTotals.toy = defTotals.toy + tonumber(kinds.toy or 0)
        defTotals.appearance = defTotals.appearance + tonumber(kinds.appearance or 0)
        defTotals.housing = defTotals.housing + tonumber(kinds.housing or 0)
        if status and tonumber(status.total or 0) > 0 then
          withScoped = withScoped + 1
          collectedTotal = collectedTotal + tonumber(status.collected or 0)
          totalDefs = totalDefs + tonumber(status.total or 0)
          if status.complete then
            completeGroups = completeGroups + 1
          else
            incompleteGroups = incompleteGroups + 1
            incomplete[#incomplete + 1] = { groupKey = groupKey, group = group, status = status }
          end
        else
          emptyScoped = emptyScoped + 1
        end
      end
    end
  end

  table.sort(incomplete, function(a, b)
    local an = tostring((a.group and a.group.name) or a.groupKey or "")
    local bn = tostring((b.group and b.group.name) or b.groupKey or "")
    if an == bn then return tostring(a.groupKey or "") < tostring(b.groupKey or "") end
    return an < bn
  end)

  local scopeName = category or "Raids+Dungeons"
  Print(("Compare all rows: %s %s backend audit complete"):format(scopeName, scope))
  Print(("  raw rows scanned=%d with scoped definitions=%d empty scoped=%d complete=%d incomplete=%d"):format(scanned, withScoped, emptyScoped, completeGroups, incompleteGroups))
  Print(("  scoped collected=%d/%d definitions (mount=%d, pet=%d, toy=%d, appearance=%d, housing=%d)"):format(collectedTotal, totalDefs, defTotals.mount, defTotals.pet, defTotals.toy, defTotals.appearance, defTotals.housing))

  if #incomplete == 0 then
    Print("  incomplete scoped raw rows: none")
    return
  end

  Print("  incomplete scoped raw rows (showing up to 25):")
  local maxGroups = 25
  for i = 1, math.min(#incomplete, maxGroups) do
    local row = incomplete[i]
    local group = row.group or {}
    local status = row.status or {}
    local label = tostring(group.name or row.groupKey)
    if group.difficultyName and tostring(group.difficultyName) ~= "" then label = label .. " (" .. tostring(group.difficultyName) .. ")" end
    Print(("  - %s [%s]: %d/%d"):format(label, tostring(row.groupKey), tonumber(status.collected or 0), tonumber(status.total or 0)))
    printMissing(status.definitions or {}, 3, "    missing")
  end
  if #incomplete > maxGroups then
    Print(("  ...and %d more incomplete scoped raw rows. Use /clogcompare active %s while viewing a row for details."):format(#incomplete - maxGroups, scope ~= "phase1" and scope or ""))
  end
end

local function runAll(msg, scope)
  ensureDefinitionsBuilt()
  scope = scope or scopeFromMsg(msg)
  local category = categoryFilterFromMsg(msg)
  local groups = {}
  if ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups then
    groups = ns.CompletionDefinitions.GetSupportedGroups(category) or {}
  end

  local scanned, withScoped, completeGroups, incompleteGroups, emptyScoped = 0, 0, 0, 0, 0
  local defTotals = { mount = 0, pet = 0, toy = 0, appearance = 0, housing = 0 }
  local collectedTotal, totalDefs = 0, 0
  local incomplete = {}

  for i = 1, #groups do
    local group = groups[i]
    local groupKey = group and group.groupKey
    if groupKey then
      scanned = scanned + 1
      local status = ns.CompletionV2 and ns.CompletionV2.GetGroupStatus and ns.CompletionV2.GetGroupStatus(groupKey, { scope = scope }) or nil
      local defs = status and status.definitions or {}
      local kinds = countKinds(defs)
      defTotals.mount = defTotals.mount + tonumber(kinds.mount or 0)
      defTotals.pet = defTotals.pet + tonumber(kinds.pet or 0)
      defTotals.toy = defTotals.toy + tonumber(kinds.toy or 0)
      defTotals.appearance = defTotals.appearance + tonumber(kinds.appearance or 0)
      defTotals.housing = defTotals.housing + tonumber(kinds.housing or 0)
      if status and tonumber(status.total or 0) > 0 then
        withScoped = withScoped + 1
        collectedTotal = collectedTotal + tonumber(status.collected or 0)
        totalDefs = totalDefs + tonumber(status.total or 0)
        if status.complete then
          completeGroups = completeGroups + 1
        else
          incompleteGroups = incompleteGroups + 1
          incomplete[#incomplete + 1] = { groupKey = groupKey, group = group, status = status }
        end
      else
        emptyScoped = emptyScoped + 1
      end
    end
  end

  local scopeName = category or "Raids+Dungeons"
  Print(("Compare all: %s %s backend audit complete"):format(scopeName, scope))
  Print(("  groups scanned=%d with scoped definitions=%d empty scoped=%d complete=%d incomplete=%d"):format(scanned, withScoped, emptyScoped, completeGroups, incompleteGroups))
  Print(("  scoped collected=%d/%d definitions (mount=%d, pet=%d, toy=%d, appearance=%d, housing=%d)"):format(collectedTotal, totalDefs, defTotals.mount, defTotals.pet, defTotals.toy, defTotals.appearance, defTotals.housing))

  if #incomplete == 0 then
    Print("  incomplete scoped groups: none")
    return
  end

  Print("  incomplete scoped groups (showing up to 25):")
  local maxGroups = 25
  for i = 1, math.min(#incomplete, maxGroups) do
    local row = incomplete[i]
    local group = row.group or {}
    local status = row.status or {}
    Print(("  - %s [%s]: %d/%d"):format(tostring(group.name or row.groupKey), tostring(row.groupKey), tonumber(status.collected or 0), tonumber(status.total or 0)))
    printMissing(status.definitions or {}, 3, "    missing")
  end
  if #incomplete > maxGroups then
    Print(("  ...and %d more incomplete scoped groups. Use /clogcompare <name> %s for details."):format(#incomplete - maxGroups, scope ~= "phase1" and scope or ""))
  end
end

SLASH_CLOGCOMPARE1 = "/clogcompare"
SlashCmdList.CLOGCOMPARE = function(msg)
  local parsed = parseCompareMessage(msg)
  if parsed.raw == "" then
    Print("Usage: /clogcompare <firelands|eye|active|group name|all|all raids|all dungeons|all rows> [true|phase2] [verbose]")
    return
  end

  local scope = parsed.scope
  local rowMode = parsed.rowMode
  local nav = parsed.nav
  local lower = parsed.lower
  local verbose = parsed.verbose

  if nav == "all" or nav == "all raids" or nav == "raids" or nav == "all dungeons" or nav == "dungeons" then
    if rowMode then
      runAllRows(lower, scope)
    else
      runAll(lower, scope)
    end
    return
  end

  ensureDefinitionsBuilt()

  local query = nav ~= "" and nav or parsed.raw
  local groupKey, group, mode = nil, nil, nil
  if ns.Registry and ns.Registry.ResolveGroup then
    groupKey, group, mode = ns.Registry.ResolveGroup(query)
  end

  -- If a user typed something like "/clogcompare active true" in a build where
  -- parser stripping failed or punctuation was unusual, fall back to resolving
  -- the first navigational token before giving up. This keeps command parsing
  -- from being a false blocker while the backend is being validated.
  if (not groupKey or not group) and nav ~= "" then
    local first = nav:match("^(%S+)")
    if first and first ~= nav and ns.Registry and ns.Registry.ResolveGroup then
      groupKey, group, mode = ns.Registry.ResolveGroup(first)
    end
  end

  if not groupKey or not group then
    Print("Compare: no supported backend group found for '" .. query .. "'.")
    return
  end

  printOne(groupKey, group, mode, scope, verbose)
end
