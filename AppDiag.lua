local ADDON, ns = ...

local function Print(msg)
  if ns and ns.Print then ns.Print(msg) else print("Collection Log: " .. tostring(msg)) end
end

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function parseItemID(msg)
  msg = tostring(msg or "")
  local id = msg:match("item:(%d+)") or msg:match("Hitem:(%d+)") or msg:match("^(%d+)$") or msg:match("(%d+)")
  return asNumber(id)
end

-- Preserve the exact item link/ref when the user shift-clicks an item.
-- Bare itemIDs can resolve to a different/default source than the actual
-- difficulty/bonus-link shown in game, which is exactly what this diagnostic
-- is meant to detect.
local function parseItemRef(msg)
  msg = tostring(msg or "")
  local itemID = parseItemID(msg)
  if msg:find("Hitem:", 1, true) or msg:find("item:", 1, true) then
    return itemID, msg
  end
  return itemID, itemID
end

local function lower(s)
  return tostring(s or ""):lower()
end

local function boolText(v)
  if v == nil then return "nil" end
  return v and "true" or "false"
end

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function itemName(itemID)
  if ns.NameResolver and ns.NameResolver.GetItemName then
    local n = ns.NameResolver.GetItemName(itemID, true)
    if n and n ~= "" and n ~= "?" then return n end
  end
  if C_Item and C_Item.GetItemInfo then
    local ok, info = pcall(C_Item.GetItemInfo, itemID)
    if ok then
      if type(info) == "table" and info.itemName then return info.itemName end
      if type(info) == "string" then return info end
    end
  end
  if GetItemInfo then
    local ok, n = pcall(GetItemInfo, itemID)
    if ok and n then return n end
  end
  return "?"
end

local function getSourceInfoTable(sourceID)
  if not C_TransmogCollection then return nil, "no C_TransmogCollection" end
  if C_TransmogCollection.GetSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetSourceInfo, sourceID)
    if ok and type(info) == "table" then return info, "GetSourceInfo" end
  end
  if C_TransmogCollection.GetAppearanceSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
    if ok and type(info) == "table" then return info, "GetAppearanceSourceInfo" end
    if ok then return nil, "GetAppearanceSourceInfo:" .. tostring(info) end
  end
  return nil, "sourceInfo=n/a"
end

local function firstSourceInfoLine(sourceID)
  local info, api = getSourceInfoTable(sourceID)
  if type(info) ~= "table" then return tostring(api or "sourceInfo=n/a") end

  local parts = { "api=" .. tostring(api) }
  local keys = { "sourceID", "visualID", "appearanceID", "categoryID", "itemID", "invType", "isCollected", "isHideVisual", "isCollectedOnCharacter", "name", "quality", "useError", "sourceType" }
  for _, k in ipairs(keys) do
    if info[k] ~= nil then parts[#parts + 1] = tostring(k) .. "=" .. tostring(info[k]) end
  end
  if #parts <= 1 then
    local n = 0
    for k, v in pairs(info) do
      n = n + 1
      if n <= 10 then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    end
  end
  return table.concat(parts, " ")
end

local function printSourceList(appearanceID, targetSourceID)
  if not (appearanceID and C_TransmogCollection and C_TransmogCollection.GetAllAppearanceSources) then return end
  local ok, sources = pcall(C_TransmogCollection.GetAllAppearanceSources, appearanceID)
  if not ok or type(sources) ~= "table" then
    Print("  appearance sources: unavailable")
    return
  end

  local total = 0
  local collected = 0
  for _ in pairs(sources) do total = total + 1 end
  Print(("  appearance sources: total=%d (showing up to 20)"):format(total))

  local shown = 0
  for _, sid in pairs(sources) do
    sid = asNumber(sid)
    if sid then
      local known = nil
      if C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
        local ok2, k = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sid)
        if ok2 then known = k and true or false end
      end
      if known then collected = collected + 1 end
      shown = shown + 1
      if shown <= 20 then
        local marker = (targetSourceID and sid == targetSourceID) and " <displayed-item-source>" or ""
        Print(("    sourceID=%s collected=%s%s %s"):format(tostring(sid), boolText(known), marker, firstSourceInfoLine(sid)))
      end
    end
  end
  if total > 20 then Print(("    ...and %d more sources"):format(total - 20)) end
  Print(("  appearance sources collected=%d/%d"):format(collected, total))
end

local function registryLine(def)
  if type(def) ~= "table" then return "registry=no" end
  return ("registry=yes type=%s item=%s collectible=%s identityType=%s entry=%s sourceGroup=%s"):format(
    tostring(def.type), tostring(def.itemID), tostring(def.collectibleID), tostring(def.identityType), tostring(def.entryKey), tostring(def.sourceGroup))
end

local function dumpAppearanceInfoByID(appearanceID)
  if not (appearanceID and C_TransmogCollection and C_TransmogCollection.GetAppearanceInfoByID) then return end
  local ok, a, b, c, d, e, f = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
  if not ok then
    Print(("  GetAppearanceInfoByID(%s): error"):format(tostring(appearanceID)))
    return
  end
  if type(a) == "table" then
    local parts = {}
    for _, k in ipairs({"appearanceID","visualID","sourceID","isCollected","isHideVisual","uiOrder","displayIndex","description","name"}) do
      if a[k] ~= nil then parts[#parts+1] = k .. "=" .. tostring(a[k]) end
    end
    local n = 0
    if #parts == 0 then
      for k, v in pairs(a) do n=n+1; if n <= 10 then parts[#parts+1] = tostring(k).."="..tostring(v) end end
    end
    Print(("  GetAppearanceInfoByID(%s): table %s"):format(tostring(appearanceID), table.concat(parts, " ")))
  else
    Print(("  GetAppearanceInfoByID(%s): returns=%s/%s/%s/%s/%s/%s"):format(tostring(appearanceID), tostring(a), tostring(b), tostring(c), tostring(d), tostring(e), tostring(f)))
  end
end

local function dumpAppearanceSourcesAPI(appearanceID, targetSourceID)
  if not (appearanceID and C_TransmogCollection and C_TransmogCollection.GetAppearanceSources) then return end
  local ok, sources = pcall(C_TransmogCollection.GetAppearanceSources, appearanceID)
  if not ok then
    Print(("  GetAppearanceSources(%s): error"):format(tostring(appearanceID)))
    return
  end
  if type(sources) ~= "table" then
    Print(("  GetAppearanceSources(%s): %s"):format(tostring(appearanceID), tostring(sources)))
    return
  end
  local count = 0
  for _ in pairs(sources) do count = count + 1 end
  Print(("  GetAppearanceSources(%s): total=%d (showing up to 20)"):format(tostring(appearanceID), count))
  local shown = 0
  for _, src in pairs(sources) do
    shown = shown + 1
    if shown <= 20 then
      if type(src) == "table" then
        local sid = asNumber(src.sourceID or src.sourceId or src.itemModifiedAppearanceID or src.visualID)
        local marker = (targetSourceID and sid and sid == targetSourceID) and " <displayed-item-source>" or ""
        local parts = {}
        for _, k in ipairs({"sourceID","visualID","appearanceID","itemID","isCollected","isHideVisual","name","categoryID","invType","sourceType"}) do
          if src[k] ~= nil then parts[#parts+1] = k .. "=" .. tostring(src[k]) end
        end
        Print("    src " .. table.concat(parts, " ") .. marker)
      else
        Print("    src " .. tostring(src))
      end
    end
  end
  if count > 20 then Print(("    ...and %d more sources"):format(count - 20)) end
end

local function run(msg)
  local itemID, itemRef = parseItemRef(msg)
  if not itemID then
    Print("Usage: /clogapp <itemID or item link>")
    return
  end

  local name = itemName(itemID)
  Print(("Appearance diag: item=%d name=%s"):format(itemID, tostring(name)))
  if itemRef ~= itemID then Print("  inputRef=" .. tostring(itemRef)) end

  local def = ns.Registry and ns.Registry.GetItemDefinition and ns.Registry.GetItemDefinition(itemID) or nil
  Print("  " .. registryLine(def))

  local appearanceID, sourceID
  if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
    local ok, a, s = pcall(C_TransmogCollection.GetItemInfo, itemRef or itemID)
    if ok then appearanceID, sourceID = asNumber(a), asNumber(s) end
    if (not appearanceID) and itemRef ~= itemID then
      local ok2, a2, s2 = pcall(C_TransmogCollection.GetItemInfo, itemID)
      if ok2 then appearanceID, sourceID = asNumber(a2), asNumber(s2) end
    end
  end
  Print(("  C_TransmogCollection.GetItemInfo: appearanceID=%s sourceID/itemModifiedAppearanceID=%s"):format(tostring(appearanceID), tostring(sourceID)))

  if ns.GetAppearanceOwnershipState then
    local ok, st = pcall(ns.GetAppearanceOwnershipState, itemID)
    if ok and type(st) == "table" then
      Print(("  ns.GetAppearanceOwnershipState: isAppearance=%s appearanceID=%s sourceID=%s exactSourceOwned=%s appearanceOwned=%s ownedViaAnotherSource=%s"):format(
        boolText(st.isAppearanceItem), tostring(st.appearanceID), tostring(st.sourceID), boolText(st.exactSourceOwned), boolText(st.appearanceOwned), boolText(st.ownedViaAnotherSource)))
    else
      Print("  ns.GetAppearanceOwnershipState: unavailable/error")
    end
  end

  local legacyA, legacyB, trueKnown
  if ns.IsAppearanceCollected then
    local ok, k = pcall(ns.IsAppearanceCollected, itemID)
    legacyA = ok and k or nil
  end
  if ns.HasCollectedAppearance then
    local ok, k = pcall(ns.HasCollectedAppearance, itemID)
    legacyB = ok and k or nil
  end
  if ns.TrueCollection and ns.TrueCollection.IsItemCollected then
    local ok, k = pcall(ns.TrueCollection.IsItemCollected, itemID)
    trueKnown = ok and k or nil
  end
  Print(("  collection checks: ns.IsAppearanceCollected=%s ns.HasCollectedAppearance=%s TrueCollection.IsItemCollected=%s"):format(boolText(legacyA), boolText(legacyB), boolText(trueKnown)))

  if appearanceID and C_TransmogCollection then
    if C_TransmogCollection.PlayerHasTransmogItemAppearance then
      local ok, k = pcall(C_TransmogCollection.PlayerHasTransmogItemAppearance, appearanceID)
      Print(("  PlayerHasTransmogItemAppearance(%s)=%s"):format(tostring(appearanceID), ok and boolText(k) or "error"))
    end
    dumpAppearanceInfoByID(appearanceID)
    dumpAppearanceSourcesAPI(appearanceID, sourceID)
  end

  if sourceID and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    local ok, k = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
    Print(("  PlayerHasTransmogItemModifiedAppearance(%s)=%s"):format(tostring(sourceID), ok and boolText(k) or "error"))
    Print("  displayed source info: " .. firstSourceInfoLine(sourceID))
  end

  printSourceList(appearanceID, sourceID)
end


local function collectRawItemsForNameSearch()
  local out, seen = {}, {}
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then return out end
  local function add(id)
    id = asNumber(id)
    if id and not seen[id] then seen[id]=true; out[#out+1]=id end
  end
  for _, g in pairs(groups) do
    if type(g) == "table" then
      if type(g.items) == "table" then for _, id in ipairs(g.items) do add(id) end end
      if type(g.itemIDs) == "table" then for _, id in ipairs(g.itemIDs) do add(id) end end
      if type(g.itemLinks) == "table" then for k, v in pairs(g.itemLinks) do add(k); add(v) end end
    end
  end
  table.sort(out)
  return out
end

local function runNameSearch(msg)
  local q = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  if q == "" then
    Print('Usage: /clogappname <partial item/source name>')
    Print('Tip: shift-clicking the exact item into /clogapp is even better because it preserves difficulty/bonus data.')
    return
  end
  local id = parseItemID(q)
  if id then return run(q) end

  local needle = lower(q)
  local matches = {}
  for _, itemID in ipairs(collectRawItemsForNameSearch()) do
    local n = itemName(itemID)
    if n and n ~= "?" and lower(n):find(needle, 1, true) then
      matches[#matches+1] = { itemID=itemID, name=n }
      if #matches >= 25 then break end
    end
  end

  Print(("Appearance name search: query=%q matches=%d%s"):format(q, #matches, #matches >= 25 and " (capped)" or ""))
  if #matches == 0 then
    Print('  No loaded raw/datapack item names matched. Open the Appearances UI or shift-click the exact item into /clogapp.')
    return
  end
  for i, m in ipairs(matches) do
    local aID, sID
    if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
      local ok, a, s = pcall(C_TransmogCollection.GetItemInfo, m.itemID)
      if ok then aID, sID = asNumber(a), asNumber(s) end
    end
    local collected = nil
    if ns.TrueCollection and ns.TrueCollection.IsItemCollected then
      local ok, k = pcall(ns.TrueCollection.IsItemCollected, m.itemID)
      if ok then collected = k end
    end
    Print(("  #%d item=%s name=%s appearanceID=%s sourceID=%s trueCollected=%s"):format(i, tostring(m.itemID), tostring(m.name), tostring(aID), tostring(sID), boolText(collected)))
  end
  if #matches == 1 then
    Print('  One match found; dumping full diagnostic for it:')
    run(tostring(matches[1].itemID))
  else
    Print('  Use /clogapp <itemID or shift-clicked item link> on the best match for full source-family details.')
  end
end

SLASH_CLOGAPP1 = "/clogapp"
SlashCmdList.CLOGAPP = run
SLASH_CLOGAPPNAME1 = "/clogappname"
SlashCmdList.CLOGAPPNAME = runNameSearch
SLASH_CLOGAPPFAMILY1 = "/clogappfamily"
SlashCmdList.CLOGAPPFAMILY = runNameSearch

-- Broader wardrobe-family diagnostic. This intentionally does not change
-- collection logic. It tries to answer: "Which wardrobe/source variant does
-- Blizzard think I own for this displayed family/name?"
local function sourceCollected(sourceID)
  sourceID = asNumber(sourceID)
  if not sourceID or not C_TransmogCollection then return nil end
  if C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    local ok, k = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
    if ok then return k and true or false end
  end
  local info = getSourceInfoTable(sourceID)
  if type(info) == "table" and info.isCollected ~= nil then return info.isCollected and true or false end
  return nil
end

local function addWardrobeSource(out, seen, sourceID, reason)
  sourceID = asNumber(sourceID)
  if not sourceID or seen[sourceID] then return end
  seen[sourceID] = true
  local info = getSourceInfoTable(sourceID)
  local itemID, name, visualID, categoryID, invType, sourceType, apiCollected
  if type(info) == "table" then
    itemID = asNumber(info.itemID)
    name = info.name
    visualID = asNumber(info.visualID or info.appearanceID)
    categoryID = asNumber(info.categoryID)
    invType = asNumber(info.invType)
    sourceType = asNumber(info.sourceType)
    if info.isCollected ~= nil then apiCollected = info.isCollected and true or false end
  end
  if itemID and (not name or name == "") then name = itemName(itemID) end
  out[#out+1] = {
    sourceID=sourceID,
    itemID=itemID,
    name=name or "?",
    visualID=visualID,
    categoryID=categoryID,
    invType=invType,
    sourceType=sourceType,
    collected=sourceCollected(sourceID),
    apiCollected=apiCollected,
    reason=reason or "source",
  }
end

local function addSourcesForAppearance(out, seen, appearanceID, reason)
  appearanceID = asNumber(appearanceID)
  if not appearanceID or not C_TransmogCollection then return end
  if C_TransmogCollection.GetAllAppearanceSources then
    local ok, sources = pcall(C_TransmogCollection.GetAllAppearanceSources, appearanceID)
    if ok and type(sources) == "table" then
      for _, sid in pairs(sources) do addWardrobeSource(out, seen, sid, reason or ("GetAllAppearanceSources:" .. tostring(appearanceID))) end
    end
  end
  if C_TransmogCollection.GetAppearanceSources then
    local ok, sources = pcall(C_TransmogCollection.GetAppearanceSources, appearanceID)
    if ok and type(sources) == "table" then
      for _, src in pairs(sources) do
        if type(src) == "table" then
          addWardrobeSource(out, seen, src.sourceID or src.sourceId or src.itemModifiedAppearanceID, reason or ("GetAppearanceSources:" .. tostring(appearanceID)))
        else
          addWardrobeSource(out, seen, src, reason or ("GetAppearanceSources:" .. tostring(appearanceID)))
        end
      end
    end
  end
end

local function tryCategoryAppearanceSearch(out, seen, query, categoryID)
  if not (categoryID and C_TransmogCollection and C_TransmogCollection.GetCategoryAppearances) then return 0 end
  local needle = lower(query)
  local calls = {
    {categoryID},
    {categoryID, nil},
    {categoryID, nil, nil},
  }
  local inspected, matched = 0, 0
  for _, args in ipairs(calls) do
    local ok, appearances = pcall(C_TransmogCollection.GetCategoryAppearances, unpack(args))
    if ok and type(appearances) == "table" then
      for _, app in pairs(appearances) do
        inspected = inspected + 1
        if type(app) == "table" then
          local appName = app.name or app.uiName or app.visualName or app.sourceName or ""
          local appID = asNumber(app.visualID or app.appearanceID or app.sourceID)
          if lower(appName):find(needle, 1, true) then
            matched = matched + 1
            if app.sourceID then addWardrobeSource(out, seen, app.sourceID, "categoryAppearance:name-match") end
            if appID then addSourcesForAppearance(out, seen, appID, "categoryAppearance:appearance-match") end
          end
        end
      end
      break
    end
  end
  return matched, inspected
end

local function runWardrobeFamily(msg)
  local raw = tostring(msg or "")
  local itemID, itemRef = parseItemRef(raw)
  local query = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  query = query:gsub("|H.-|h%[(.-)%]|h", "%1")
  query = query:match("^%s*(.-)%s*$") or ""
  if query == "" and itemID then query = itemName(itemID) end
  if query == "" then
    Print('Usage: /clogwardrobe <item link, itemID, or source/item name>')
    Print('Best test: shift-click the exact collected wardrobe item/source if possible.')
    return
  end

  local out, seenSources = {}, {}
  local appearanceIDs, seenApps = {}, {}
  local categoryID

  local function addAppearanceID(aid, reason)
    aid = asNumber(aid)
    if aid and not seenApps[aid] then
      seenApps[aid] = reason or true
      appearanceIDs[#appearanceIDs+1] = aid
      addSourcesForAppearance(out, seenSources, aid, reason or "appearance")
    end
  end

  local function addItem(id, ref, reason)
    id = asNumber(id)
    if not id then return end
    local aID, sID
    if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
      local ok, a, s = pcall(C_TransmogCollection.GetItemInfo, ref or id)
      if ok then aID, sID = asNumber(a), asNumber(s) end
    end
    if sID then addWardrobeSource(out, seenSources, sID, reason or ("item:" .. tostring(id))) end
    if aID then addAppearanceID(aID, reason or ("itemAppearance:" .. tostring(id))) end
    if sID then
      local info = getSourceInfoTable(sID)
      if type(info) == "table" and info.categoryID then categoryID = categoryID or asNumber(info.categoryID) end
    end
  end

  if itemID then addItem(itemID, itemRef, "input-item") end

  local needle = lower(query)
  local rawMatches = 0
  for _, id in ipairs(collectRawItemsForNameSearch()) do
    local n = itemName(id)
    if n and n ~= "?" and lower(n):find(needle, 1, true) then
      rawMatches = rawMatches + 1
      addItem(id, id, "raw-name-match")
    end
  end

  local categoryMatches, categoryInspected = tryCategoryAppearanceSearch(out, seenSources, query, categoryID)

  table.sort(out, function(a,b)
    if (a.visualID or 0) ~= (b.visualID or 0) then return (a.visualID or 0) < (b.visualID or 0) end
    return (a.sourceID or 0) < (b.sourceID or 0)
  end)

  local collected = 0
  for _, s in ipairs(out) do if s.collected then collected = collected + 1 end end
  Print(("Wardrobe family diag: query=%q inputItem=%s categoryID=%s rawNameMatches=%d categoryMatches=%s/%s sources=%d collected=%d"):format(
    query, tostring(itemID), tostring(categoryID), rawMatches, tostring(categoryMatches or 0), tostring(categoryInspected or 0), #out, collected))
  if #appearanceIDs > 0 then
    table.sort(appearanceIDs)
    local shown = {}
    for i, aid in ipairs(appearanceIDs) do if i <= 12 then shown[#shown+1] = tostring(aid) end end
    Print("  appearanceIDs considered: " .. table.concat(shown, ", ") .. (#appearanceIDs > 12 and (" ...+" .. tostring(#appearanceIDs-12)) or ""))
  end
  if #out == 0 then
    Print("  No sources found. Try shift-clicking the exact item/source into /clogwardrobe.")
    return
  end
  Print("  sources (showing up to 40):")
  for i, s in ipairs(out) do
    if i <= 40 then
      Print(("    sourceID=%s visualID=%s item=%s name=%s collected=%s apiCollected=%s category=%s invType=%s sourceType=%s reason=%s"):format(
        tostring(s.sourceID), tostring(s.visualID), tostring(s.itemID), tostring(s.name), boolText(s.collected), boolText(s.apiCollected), tostring(s.categoryID), tostring(s.invType), tostring(s.sourceType), tostring(s.reason)))
    end
  end
  if #out > 40 then Print(("    ...and %d more sources"):format(#out - 40)) end
end

SLASH_CLOGWARDROBE1 = "/clogwardrobe"
SlashCmdList.CLOGWARDROBE = runWardrobeFamily

local function activeGroup()
  local groupId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId or nil
  if not groupId then return nil end
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then return nil end
  return groups[groupId] or groups[tonumber(groupId) or -1]
end

local function activeCollectionMode()
  local mode = CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode or "shared"
  if ns and ns.GetAppearanceCollectionMode then
    local ok, resolved = pcall(ns.GetAppearanceCollectionMode)
    if ok and type(resolved) == "string" and resolved ~= "" then
      mode = resolved
    end
  end
  return mode
end

local function truthField(v)
  if v == nil then return "unknown" end
  return v and "true" or "false"
end

local function sourceTrustOf(def, state)
  local trust = type(state) == "table" and state.sourceTrust or nil
  if type(trust) == "string" and trust ~= "" then return trust end
  trust = type(def) == "table" and def._clogSourceTrust or nil
  if type(trust) == "string" and trust ~= "" then return trust end
  return "unknown"
end

local function printSiblingSources(def)
  local mods = type(def) == "table" and (def.siblingModIDs or def.itemModIDs) or nil
  if type(mods) ~= "table" or #mods == 0 then
    Print("  siblingSources: none")
    return
  end

  Print(("  siblingSources: %d candidate sourceIDs"):format(#mods))
  for i = 1, #mods do
    local sourceID = asNumber(mods[i])
    if sourceID then
      local info = getSourceInfoTable(sourceID)
      local sourceItemID = type(info) == "table" and asNumber(info.itemID or info.sourceItemID or info.itemIDDisplayed or info.itemId) or nil
      local owned = sourceCollected(sourceID)
      Print(("    #%d sourceID=%s sourceItemID=%s owned=%s %s"):format(
        i,
        tostring(sourceID),
        tostring(sourceItemID),
        boolText(owned),
        firstSourceInfoLine(sourceID)))
    end
  end
end

local function printVerifiedAlternateSources(def)
  local appearanceID = type(def) == "table" and asNumber(def.appearanceID or def.collectibleID) or nil
  local itemID = type(def) == "table" and asNumber(def.itemID) or nil
  if not appearanceID then
    Print("  verifiedAlternateSources: none (no appearanceID)")
    return
  end
  if not (C_TransmogCollection and C_TransmogCollection.GetAllAppearanceSources) then
    Print("  verifiedAlternateSources: unavailable")
    return
  end

  local ok, sources = pcall(C_TransmogCollection.GetAllAppearanceSources, appearanceID)
  if not ok or type(sources) ~= "table" then
    Print("  verifiedAlternateSources: unavailable")
    return
  end

  local shown, total = 0, 0
  for _, rawSourceID in pairs(sources) do
    local sourceID = asNumber(rawSourceID)
    if sourceID and sourceID ~= asNumber(def.modID or def.sourceID or def.itemModifiedAppearanceID) then
      local info = getSourceInfoTable(sourceID)
      local sourceItemID = type(info) == "table" and asNumber(info.itemID or info.sourceItemID or info.itemIDDisplayed or info.itemId) or nil
      local owned = sourceCollected(sourceID)
      if owned and sourceItemID and itemID and sourceItemID ~= itemID then
        total = total + 1
        if shown < 10 then
          shown = shown + 1
          Print(("    alternate#%d sourceID=%s sourceItemID=%s owned=%s %s"):format(
            shown,
            tostring(sourceID),
            tostring(sourceItemID),
            boolText(owned),
            firstSourceInfoLine(sourceID)))
        end
      end
    end
  end

  if total == 0 then
    Print("  verifiedAlternateSources: none")
  else
    Print(("  verifiedAlternateSources: %d owned alternate source(s)%s"):format(
      total,
      total > shown and (" (showing first " .. tostring(shown) .. ")") or ""))
  end
end

local function findVisibleCell(itemID, groupID)
  itemID = asNumber(itemID)
  local ui = ns and ns.UI or nil
  if not (ui and ui.cells and itemID and groupID) then return nil end
  local gid = tostring(groupID)
  for i = 1, tonumber(ui.maxCells or 0) or 0 do
    local cell = ui.cells[i]
    if cell and cell:IsShown() and asNumber(cell.itemID) == itemID and tostring(cell.groupId or "") == gid then
      return cell, i
    end
  end
  return nil
end

local function findVisibleCellAnyGroup(itemID)
  itemID = asNumber(itemID)
  local ui = ns and ns.UI or nil
  if not (ui and ui.cells and itemID) then return nil end
  for i = 1, tonumber(ui.maxCells or 0) or 0 do
    local cell = ui.cells[i]
    if cell and cell:IsShown() and asNumber(cell.itemID) == itemID then
      return cell, i
    end
  end
  return nil
end

local function textureBool(tex, methodName)
  if not (tex and tex[methodName]) then return nil end
  local ok, v = pcall(tex[methodName], tex)
  if ok then return v end
  return nil
end

local function printVisibleCellState(itemID, groupID)
  local cell, index = findVisibleCell(itemID, groupID)
  if not cell then
    local anyCell, anyIndex = findVisibleCellAnyGroup(itemID)
    if anyCell then
      Print(("  visibleCell: not in active group, but visible elsewhere at index=%s groupId=%s section=%s cachedCollected=%s"):format(
        tostring(anyIndex),
        tostring(anyCell.groupId),
        tostring(anyCell.section),
        truthField(anyCell._clogCachedCollected)))
    else
      Print("  visibleCell: none")
    end
    return
  end

  local icon = cell.icon
  local r, g, b, a = 1, 1, 1, 1
  if icon and icon.GetVertexColor then
    local ok, vr, vg, vb, va = pcall(icon.GetVertexColor, icon)
    if ok then
      r, g, b, a = vr or r, vg or g, vb or b, va or a
    end
  end
  local alpha = icon and icon.GetAlpha and icon:GetAlpha() or nil
  local desat = textureBool(icon, "IsDesaturated")
  if desat == nil then
    desat = textureBool(icon, "GetDesaturated")
  end

  Print(("  visibleCell: index=%s section=%s cachedCollected=%s truthStatePresent=%s texture=%s desaturated=%s alpha=%s vertex=%.2f,%.2f,%.2f,%.2f"):format(
    tostring(index),
    tostring(cell.section),
    truthField(cell._clogCachedCollected),
    truthField(cell._clogTruthState ~= nil),
    tostring(icon and icon.GetTexture and icon:GetTexture() or nil),
    truthField(desat),
    tostring(alpha),
    tonumber(r or 0) or 0,
    tonumber(g or 0) or 0,
    tonumber(b or 0) or 0,
    tonumber(a or 0) or 0))
end

local function runDebugTruth(msg)
  local itemID, itemRef = parseItemRef(msg)
  local group = activeGroup()
  local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
  local viewMode = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.viewMode or nil

  if not group then
    Print("Usage: /clogdebugtruth <itemID or shift-clicked item link>")
    Print("  No active group is selected.")
    return
  end

  Print(("Truth debug context: category=%s viewMode=%s group=%s groupID=%s difficultyID=%s mode=%s instanceID=%s collectionMode=%s"):format(
    tostring(activeCat),
    tostring(viewMode),
    tostring(group.name or "?"),
    tostring(group.id),
    tostring(group.difficultyID),
    tostring(group.mode),
    tostring(group.instanceID),
    tostring(activeCollectionMode())))

  if not itemID then
    Print("  Provide an item ID or shift-clicked item link from the exact row you want to inspect.")
    return
  end

  local name = itemName(itemID)
  local meta = ns.RaidDungeonMeta and ns.RaidDungeonMeta.GetItemMeta and ns.RaidDungeonMeta.GetItemMeta(group, itemID) or nil
  local def = ns.Registry and ns.Registry.GetItemDefinitionForGroup and ns.Registry.GetItemDefinitionForGroup(itemID, group) or nil
  local state, stateDef = ns.Truth and ns.Truth.GetItemCollectionState and ns.Truth.GetItemCollectionState(itemID, group) or nil, nil
  if ns.Truth and ns.Truth.GetItemCollectionState then
    local okState, st, d = pcall(ns.Truth.GetItemCollectionState, itemID, group)
    if okState and type(st) == "table" then
      state, stateDef = st, d
    end
  end

  local trueCollected = nil
  if ns.TrueCollection and ns.TrueCollection.IsItemCollected then
    local okTrue, collected = pcall(ns.TrueCollection.IsItemCollected, itemID, group)
    if okTrue then trueCollected = collected end
  end

  local exactCollected = nil
  local sameOtherDifficulty = nil
  local appearanceOtherSource = nil
  local countsAsCollected = nil
  if type(state) == "table" then
    exactCollected = state.exactSourceOwned
    sameOtherDifficulty = state.sameItemOtherDifficultyOwned
    appearanceOtherSource = state.appearanceOwnedViaOtherSource
    countsAsCollected = state.countsAsCollected
  end
  local displayLabel = type(state) == "table" and (state.note or state.label) or nil
  local reason = type(state) == "table" and state.reason or nil
  local defToPrint = stateDef or def
  local exactSourceID = type(defToPrint) == "table" and asNumber(defToPrint.modID or defToPrint.sourceID or defToPrint.itemModifiedAppearanceID) or nil
  local visibleCell = findVisibleCellAnyGroup(itemID)
  if not meta and not visibleCell then
    Print("  note: item is not part of the active group's visible row context")
  end

  Print(("  item=%s name=%s inputRef=%s"):format(tostring(itemID), tostring(name), tostring(itemRef or itemID)))
  Print(("  meta: kind=%s appearanceID=%s sourceID=%s itemLink=%s dropsFrom=%s sourceText=%s"):format(
    tostring(meta and meta.kind or meta and meta.type or "nil"),
    tostring(meta and meta.appearanceID),
    tostring(meta and (meta.sourceID or meta.modID or meta.itemModifiedAppearanceID)),
    tostring(meta and meta.itemLink),
    tostring(meta and meta.dropsFrom),
    tostring(meta and meta.sourceText)))
  Print(("  def: type=%s collectibleID=%s appearanceID=%s sourceID=%s itemLink=%s trust=%s exactUntrusted=%s sharedUntrusted=%s"):format(
    tostring(defToPrint and defToPrint.type),
    tostring(defToPrint and defToPrint.collectibleID),
    tostring(defToPrint and defToPrint.appearanceID),
    tostring(exactSourceID),
    tostring(defToPrint and defToPrint.itemLink),
    tostring(sourceTrustOf(defToPrint, state)),
    truthField(defToPrint and defToPrint._exactSourceUntrusted),
    truthField(defToPrint and defToPrint._sharedAppearanceUntrusted)))
  Print(("  state: exactCollected=%s sameItemOtherDifficultyCollected=%s appearanceCollectedViaOtherSource=%s countsAsCollected=%s displayLabel=%s trueCollection=%s"):format(
    truthField(exactCollected),
    truthField(sameOtherDifficulty),
    truthField(appearanceOtherSource),
    truthField(countsAsCollected),
    tostring(displayLabel or "nil"),
    truthField(trueCollected)))
  Print(("  stateDetail: collectionMode=%s sourceTrust=%s reason=%s legacyFallbackUsed=%s"):format(
    tostring(state and state.collectionMode or activeCollectionMode()),
    tostring(sourceTrustOf(defToPrint, state)),
    tostring(reason or "nil"),
    (type(state) == "table" and state.reason == "true_collection_boolean_fallback") and "yes" or "no"))

  if exactSourceID and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    local okOwned, owned = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, exactSourceID)
    Print(("  exactSourceCheck: PlayerHasTransmogItemModifiedAppearance(%s)=%s"):format(
      tostring(exactSourceID),
      okOwned and boolText(owned) or "error"))
  end

  if type(defToPrint) == "table" and type(defToPrint.itemLink) == "string" and defToPrint.itemLink ~= "" and C_TooltipInfo and C_TooltipInfo.GetHyperlink then
    local okTip, data = pcall(C_TooltipInfo.GetHyperlink, defToPrint.itemLink)
    if okTip and type(data) == "table" and type(data.lines) == "table" then
      local matched = {}
      for i = 1, #data.lines do
        local line = data.lines[i]
        local left = type(line) == "table" and line.leftText or nil
        local right = type(line) == "table" and line.rightText or nil
        for _, text in ipairs({ left, right }) do
          if type(text) == "string" then
            local lowerText = string.lower(text)
            if string.find(lowerText, "collected this appearance", 1, true)
              or string.find(lowerText, "haven't collected this appearance", 1, true)
              or string.find(lowerText, "have not collected this appearance", 1, true) then
              matched[#matched + 1] = text
            end
          end
        end
      end
      if #matched > 0 then
        Print("  tooltipTruth:")
        for i = 1, #matched do
          Print("    " .. tostring(matched[i]))
        end
      else
        Print("  tooltipTruth: no direct appearance line found")
      end
    end
  end

  printSiblingSources(defToPrint)
  Print("  verifiedAlternateSources:")
  printVerifiedAlternateSources(defToPrint)
  printVisibleCellState(itemID, group.id)
end

SLASH_CLOGDEBUGTRUTH1 = "/clogdebugtruth"
SlashCmdList.CLOGDEBUGTRUTH = runDebugTruth

local function runDebugOverview(msg)
  local raw = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  local cat = raw
  if cat == "" then cat = "Raids" end
  local lowerCat = lower(cat)
  if lowerCat == "raid" then cat = "Raids"
  elseif lowerCat == "raids" then cat = "Raids"
  elseif lowerCat == "dungeon" then cat = "Dungeons"
  elseif lowerCat == "dungeons" then cat = "Dungeons"
  else
    Print('Usage: /clogdebugoverview [raids|dungeons]')
    return
  end

  local supported = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups(cat) or nil
  if type(supported) ~= "table" then
    Print(("Overview debug %s: no supported aggregate groups"):format(cat))
    return
  end

  local sumCollected, sumTotal = 0, 0
  Print(("Overview debug %s: supportedGroups=%d"):format(cat, #supported))
  for i = 1, #supported do
    local g = supported[i]
    local groupKey = type(g) == "table" and tostring(g.groupKey or "") or ""
    local name = type(g) == "table" and tostring(g.name or groupKey or "?") or "?"
    local totalSupported = type(g) == "table" and tonumber(g.totalSupported or 0) or 0

    local status = nil
    if groupKey ~= "" and ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus then
      local ok, st = pcall(ns.TrueCollection.GetGroupStatus, groupKey)
      if ok and type(st) == "table" then status = st end
    end

    local c = tonumber(status and status.collected or 0) or 0
    local t = tonumber(status and status.total or 0) or 0
    sumCollected = sumCollected + c
    sumTotal = sumTotal + t

    if i <= 40 then
      Print(("  #%d key=%s name=%s totalSupported=%s status=%s/%s"):format(
        i,
        groupKey,
        name,
        tostring(totalSupported),
        tostring(c),
        tostring(t)))
    end
  end

  if #supported > 40 then
    Print(("  ...and %d more groups"):format(#supported - 40))
  end
  Print(("Overview debug %s summary: %d/%d"):format(cat, sumCollected, sumTotal))
end

SLASH_CLOGDEBUGOVERVIEW1 = "/clogdebugoverview"
SlashCmdList.CLOGDEBUGOVERVIEW = runDebugOverview

local function rawKeysToList(sourceGroupKeys)
  local out = {}
  if type(sourceGroupKeys) ~= "table" then return out end
  for k in pairs(sourceGroupKeys) do
    out[#out + 1] = tostring(k)
  end
  table.sort(out)
  return out
end

local function firstN(list, n)
  local out = {}
  if type(list) ~= "table" then return out end
  local limit = math.min(#list, n or #list)
  for i = 1, limit do out[#out + 1] = tostring(list[i]) end
  return out
end

local function joinOrNone(list)
  if type(list) ~= "table" or #list == 0 then return "none" end
  return table.concat(list, ", ")
end

local function normalizeAggregateNeedle(value)
  value = lower(tostring(value or ""):match("^%s*(.-)%s*$") or "")
  value = value:gsub("^the ", "")
  value = value:gsub("[%p%s]+", " ")
  value = value:match("^%s*(.-)%s*$") or ""
  return value
end

local function resolveAggregateGroup(raw)
  local resolver = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.ResolveGroupKey or nil
  if resolver then
    local a, b, mode = resolver(raw)
    if a and type(b) == "table" then
      return a, b, mode
    end
    if mode == "ambiguous" and type(b) == "table" then
      local needle = normalizeAggregateNeedle(raw)
      for i = 1, #b do
        local entry = b[i]
        local g = entry and entry.group or nil
        if g and normalizeAggregateNeedle(g.name) == needle then
          return entry.groupKey, g, "ambiguous_exact_name"
        end
      end
      if #b == 1 and b[1] and b[1].groupKey and b[1].group then
        return b[1].groupKey, b[1].group, "ambiguous_single"
      end
    end
  end

  local supported = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups() or nil
  if type(supported) == "table" then
    local needle = normalizeAggregateNeedle(raw)
    local partial = nil
    for i = 1, #supported do
      local g = supported[i]
      if type(g) == "table" then
        local name = normalizeAggregateNeedle(g.name)
        local catName = normalizeAggregateNeedle((g.category or "") .. " " .. (g.name or ""))
        if name == needle or catName == needle then
          return g.groupKey, g, "supported_exact_name"
        end
        if not partial and ((name ~= "" and name:find(needle, 1, true)) or (needle ~= "" and needle:find(name, 1, true))) then
          partial = g
        end
      end
    end
    if partial then
      return partial.groupKey, partial, "supported_partial_name"
    end
  end

  return nil, nil, "not_found"
end

local function runDebugAggregate(msg)
  local raw = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  raw = raw:gsub('^"(.*)"$', "%1")
  raw = raw:gsub("^'(.*)'$", "%1")
  if raw == "" or raw == "active" then
    local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
    local activeGroup = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
    if type(activeGroup) == "table" and activeGroup.category and activeGroup.instanceID then
      raw = tostring(activeGroup.name or activeGroup.instanceID)
    end
  end

  if raw == "" then
    Print('Usage: /clogdebugaggregate <raid or dungeon name>')
    return
  end

  local groupKey, group = resolveAggregateGroup(raw)
  if not groupKey or type(group) ~= "table" then
    Print(("Aggregate debug: could not resolve '%s'"):format(raw))
    return
  end

  local defs = ns and ns.Registry and ns.Registry.GetGroupDefinitions and ns.Registry.GetGroupDefinitions(groupKey) or {}
  local status = ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus and ns.TrueCollection.GetGroupStatus(groupKey) or nil
  local mode = ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode() or "shared"
  local counts = { mount = 0, pet = 0, toy = 0, housing = 0, appearance = 0, other = 0 }
  local collectedKinds = { mount = 0, pet = 0, toy = 0, housing = 0, appearance = 0, other = 0 }
  local failingAppearanceLines = {}

  Print(("Aggregate debug: key=%s name=%s category=%s mode=%s status=%s/%s defs=%d"):format(
    tostring(groupKey),
    tostring(group.name or "?"),
    tostring(group.category or "?"),
    tostring(mode),
    tostring(status and status.collected or 0),
    tostring(status and status.total or 0),
    #(defs or {})))

  for i = 1, #(defs or {}) do
    local def = defs[i]
    local kind = lower(tostring(def and def.type or "other"))
    if counts[kind] == nil then kind = "other" end
    counts[kind] = (counts[kind] or 0) + 1

    local collected = false
    if ns and ns.Truth and ns.Truth.IsCollected then
      local ok, v = pcall(ns.Truth.IsCollected, def)
      collected = ok and v and true or false
    end
    if collected then
      collectedKinds[kind] = (collectedKinds[kind] or 0) + 1
    end

    if kind == "appearance" and #failingAppearanceLines < 25 then
      local state = ns and ns.Truth and ns.Truth.GetAppearanceCollectionState and ns.Truth.GetAppearanceCollectionState(def) or nil
      local itemName = tostring(def and def.name or ("item:" .. tostring(def and def.itemID or "?")))
      if type(state) == "table" and not (state.countsAsCollected and true or false) then
        local rawEntry = type(def.raw) == "table" and def.raw or nil
        local appDbg = rawEntry and rawEntry.debug and rawEntry.debug.appearance or nil
        local mods = appDbg and appDbg.modifiedAppearanceIDs or nil
        local rawRefs = rawEntry and rawEntry.rawRefs or nil
        local sourceGroups = rawEntry and rawEntry.sourceGroupKeys or nil
        local modList = {}
        if type(mods) == "table" then
          for j = 1, math.min(#mods, 6) do modList[#modList + 1] = tostring(mods[j]) end
        end
        local refList = {}
        if type(rawRefs) == "table" then
          for j = 1, math.min(#rawRefs, 6) do refList[#refList + 1] = tostring(rawRefs[j]) end
        end
        local srcGroups = firstN(rawKeysToList(sourceGroups), 4)
        failingAppearanceLines[#failingAppearanceLines + 1] = ("  appearance miss #%d: name=%s collectibleID=%s reason=%s exact=%s sameDiff=%s otherSource=%s rawRefs=%s mods=%s sourceGroups=%s"):format(
          #failingAppearanceLines + 1,
          itemName,
          tostring(def.collectibleID or def.appearanceID or "?"),
          tostring(state.reason or "?"),
          tostring(state.exactSourceOwned == true),
          tostring(state.sameItemOtherDifficultyOwned == true),
          tostring(state.appearanceOwnedViaOtherSource == true),
          joinOrNone(refList),
          joinOrNone(modList),
          joinOrNone(srcGroups))
      end
    end
  end

  Print(("  kindTotals: appearance=%d mount=%d pet=%d toy=%d housing=%d other=%d"):format(
    counts.appearance or 0, counts.mount or 0, counts.pet or 0, counts.toy or 0, counts.housing or 0, counts.other or 0))
  Print(("  kindCollected: appearance=%d mount=%d pet=%d toy=%d housing=%d other=%d"):format(
    collectedKinds.appearance or 0, collectedKinds.mount or 0, collectedKinds.pet or 0, collectedKinds.toy or 0, collectedKinds.housing or 0, collectedKinds.other or 0))

  if #failingAppearanceLines == 0 then
    Print("  appearance misses: none in first 25 sampled entries")
  else
    Print("  appearance misses:")
    for i = 1, #failingAppearanceLines do
      Print(failingAppearanceLines[i])
    end
  end
end

SLASH_CLOGDEBUGAGGREGATE1 = "/clogdebugaggregate"
SlashCmdList.CLOGDEBUGAGGREGATE = runDebugAggregate

local function shallowCopy(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do out[k] = v end
  end
  return out
end

local function rawGroupFromKey(rawKey)
  local key = tostring(rawKey or "")
  if key == "" then return nil end
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then return nil end
  local rawID = key:match("^raw:(.+)$")
  if rawID and rawID ~= "" then
    return groups[rawID] or groups[tonumber(rawID) or -1]
  end
  return groups[key] or groups[tonumber(key) or -1]
end

local function strictAggregateCandidateKey(rawDef, rawGroup)
  if type(rawDef) ~= "table" or tostring(rawDef.type or ""):lower() ~= "appearance" then return nil end
  local instanceID = tonumber(rawGroup and rawGroup.instanceID or rawDef.instanceID or 0) or 0
  local difficultyID = tonumber(rawGroup and rawGroup.difficultyID or rawDef.difficultyID or 0) or 0
  local itemID = tonumber(rawDef.itemID or 0) or 0
  local sourceID = tonumber(rawDef.modID or rawDef.sourceID or rawDef.itemModifiedAppearanceID or 0) or 0
  local appearanceID = tonumber(rawDef.appearanceID or rawDef.collectibleID or 0) or 0
  if instanceID <= 0 or itemID <= 0 then return nil end
  return ("ejinstance:%d:difficulty:%d:item:%d:source:%d:appearance:%d"):format(instanceID, difficultyID, itemID, sourceID, appearanceID)
end

local function runDebugAggregateStrict(msg)
  local raw = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  raw = raw:gsub('^"(.*)"$', "%1")
  raw = raw:gsub("^'(.*)'$", "%1")
  if raw == "" or raw == "active" then
    local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
    local activeGroup = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
    if type(activeGroup) == "table" and activeGroup.category and activeGroup.instanceID then
      raw = tostring(activeGroup.name or activeGroup.instanceID)
    end
  end
  if raw == "" then
    Print('Usage: /clogdebugaggregatestrict <raid or dungeon name>')
    return
  end

  local groupKey, group = resolveAggregateGroup(raw)
  if not groupKey or type(group) ~= "table" then
    Print(("Aggregate strict debug: could not resolve '%s'"):format(raw))
    return
  end

  local entries = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup and ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
  local seenKeys = {}
  local lines = {}
  local totalCandidates, collectedCandidates = 0, 0
  local itemFamilies = {}

  for i = 1, #(entries or {}) do
    local entry = entries[i]
    if type(entry) == "table" and tostring(entry.kind or ""):lower() == "appearance" then
      local rawRefs = type(entry.rawRefs) == "table" and entry.rawRefs or nil
      local sourceGroupKeys = type(entry.sourceGroupKeys) == "table" and entry.sourceGroupKeys or nil
      if type(rawRefs) == "table" and type(sourceGroupKeys) == "table" then
        for rawKey in pairs(sourceGroupKeys) do
          local rawGroup = rawGroupFromKey(rawKey)
          if type(rawGroup) == "table" and tonumber(rawGroup.instanceID or 0) == tonumber(group.instanceID or -1) then
            for j = 1, #rawRefs do
              local itemID = tonumber(rawRefs[j])
              if itemID and ns and ns.Registry and ns.Registry.GetItemDefinitionForGroup then
                local rawDef = ns.Registry.GetItemDefinitionForGroup(itemID, rawGroup)
                if type(rawDef) == "table" and tostring(rawDef.type or ""):lower() == "appearance" then
                  local strictDef = shallowCopy(rawDef)
                  strictDef._clogAppearanceModeOverride = "strict"
                  strictDef.sourceGroup = rawKey
                  local candidateKey = strictAggregateCandidateKey(strictDef, rawGroup)
                  if candidateKey and not seenKeys[candidateKey] then
                    seenKeys[candidateKey] = true
                    totalCandidates = totalCandidates + 1
                    local state = ns and ns.Truth and ns.Truth.GetAppearanceCollectionState and ns.Truth.GetAppearanceCollectionState(strictDef) or nil
                    local collected = type(state) == "table" and (state.countsAsCollected and true or false) or false
                    if collected then collectedCandidates = collectedCandidates + 1 end
                    local familyKey = tostring(itemID)
                    local fam = itemFamilies[familyKey]
                    if not fam then
                      fam = {
                        itemID = itemID,
                        name = tostring(strictDef.name or ("item:" .. tostring(itemID))),
                        diffs = {},
                        candidateCount = 0,
                        collectedAny = false,
                        collectedReasons = {},
                      }
                      itemFamilies[familyKey] = fam
                    end
                    fam.candidateCount = fam.candidateCount + 1
                    fam.diffs[tostring(rawGroup.difficultyID or "?")] = true
                    if collected then
                      fam.collectedAny = true
                      fam.collectedReasons[tostring(state and state.reason or "?")] = true
                    end
                    if #lines < 35 then
                      lines[#lines + 1] = ("  #%d key=%s name=%s difficultyID=%s sourceID=%s appearanceID=%s collected=%s reason=%s"):format(
                        #lines + 1,
                        candidateKey,
                        tostring(strictDef.name or ("item:" .. tostring(itemID))),
                        tostring(rawGroup.difficultyID or "?"),
                        tostring(strictDef.modID or strictDef.sourceID or strictDef.itemModifiedAppearanceID or "?"),
                        tostring(strictDef.appearanceID or strictDef.collectibleID or "?"),
                        tostring(collected),
                        tostring(state and state.reason or "?"))
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  Print(("Aggregate strict debug: key=%s name=%s category=%s candidates=%d collected=%d"):format(
    tostring(groupKey),
    tostring(group.name or "?"),
    tostring(group.category or "?"),
    totalCandidates,
    collectedCandidates))

  local familyList = {}
  local collectedFamilies = 0
  for _, fam in pairs(itemFamilies) do
    familyList[#familyList + 1] = fam
    if fam.collectedAny then collectedFamilies = collectedFamilies + 1 end
  end
  table.sort(familyList, function(a, b)
    local an = tostring(a.name or "")
    local bn = tostring(b.name or "")
    if an == bn then return tonumber(a.itemID or 0) < tonumber(b.itemID or 0) end
    return an < bn
  end)
  Print(("  strict item families: total=%d collected=%d"):format(#familyList, collectedFamilies))

  if #lines == 0 then
    Print("  no strict appearance candidates found")
  else
    for i = 1, #lines do
      Print(lines[i])
    end
    if totalCandidates > #lines then
      Print(("  ...and %d more strict candidates"):format(totalCandidates - #lines))
    end
  end

  if #familyList > 0 then
    Print("  strict item family samples:")
    for i = 1, math.min(#familyList, 20) do
      local fam = familyList[i]
      local diffs = rawKeysToList(fam.diffs)
      local reasons = rawKeysToList(fam.collectedReasons)
      Print(("    family#%d itemID=%s name=%s candidates=%d collectedAny=%s difficulties=%s reasons=%s"):format(
        i,
        tostring(fam.itemID or "?"),
        tostring(fam.name or "?"),
        tonumber(fam.candidateCount or 0) or 0,
        tostring(fam.collectedAny == true),
        joinOrNone(diffs),
        joinOrNone(reasons)))
    end
    if #familyList > 20 then
      Print(("    ...and %d more item families"):format(#familyList - 20))
    end
  end
end

SLASH_CLOGDEBUGAGGSTRICT1 = "/clogdebugaggregatestrict"
SlashCmdList.CLOGDEBUGAGGSTRICT = runDebugAggregateStrict

local function computeStrictAggregateItemFamilyPreview(raw)
  local groupKey, group = resolveAggregateGroup(raw)
  if not groupKey or type(group) ~= "table" then return nil, nil, "resolve_failed" end

  local entries = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup and ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
  local itemFamilies = {}

  for i = 1, #(entries or {}) do
    local entry = entries[i]
    if type(entry) == "table" and tostring(entry.kind or ""):lower() == "appearance" then
      local rawRefs = type(entry.rawRefs) == "table" and entry.rawRefs or nil
      local sourceGroupKeys = type(entry.sourceGroupKeys) == "table" and entry.sourceGroupKeys or nil
      if type(rawRefs) == "table" and type(sourceGroupKeys) == "table" then
        for rawKey in pairs(sourceGroupKeys) do
          local rawGroup = rawGroupFromKey(rawKey)
          if type(rawGroup) == "table" and tonumber(rawGroup.instanceID or 0) == tonumber(group.instanceID or -1) then
            for j = 1, #rawRefs do
              local itemID = tonumber(rawRefs[j])
              if itemID and ns and ns.Registry and ns.Registry.GetItemDefinitionForGroup then
                local rawDef = ns.Registry.GetItemDefinitionForGroup(itemID, rawGroup)
                if type(rawDef) == "table" and tostring(rawDef.type or ""):lower() == "appearance" then
                  local family = itemFamilies[itemID]
                  if not family then
                    family = { itemID = itemID, name = tostring(rawDef.name or ("item:" .. tostring(itemID))), collected = false }
                    itemFamilies[itemID] = family
                  end
                  if family.collected ~= true then
                    local strictDef = shallowCopy(rawDef)
                    strictDef._clogAppearanceModeOverride = "strict"
                    strictDef.sourceGroup = rawKey
                    local state = ns and ns.Truth and ns.Truth.GetAppearanceCollectionState and ns.Truth.GetAppearanceCollectionState(strictDef) or nil
                    if type(state) == "table" and state.exactSourceOwned == true then
                      family.collected = true
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  local total, collected = 0, 0
  for _, fam in pairs(itemFamilies) do
    total = total + 1
    if fam.collected == true then collected = collected + 1 end
  end
  return {
    groupKey = groupKey,
    group = group,
    total = total,
    collected = collected,
    itemFamilies = itemFamilies,
  }, group, nil
end

ns.ComputeStrictAggregateItemFamilyPreview = computeStrictAggregateItemFamilyPreview

local function selectedDifficultyAggregateKey(def, state, mode)
  if type(def) ~= "table" then return nil end
  local t = lower(tostring(def.type or ""))
  if t == "appearance" then
    if tostring(mode or "shared") == "shared" then
      local appearanceID = tonumber(def.appearanceID or def.collectibleID or 0) or 0
      if appearanceID > 0 then
        return "appearance:" .. tostring(appearanceID)
      end
    end
    local itemID = tonumber(def.itemID or 0) or 0
    if itemID > 0 then
      return "appearance_item:" .. tostring(itemID)
    end
    local sourceID = tonumber(def.modID or def.sourceID or def.itemModifiedAppearanceID or 0) or 0
    if sourceID > 0 then
      return "appearance_source:" .. tostring(sourceID)
    end
    return nil
  end
  local collectibleID = tonumber(def.collectibleID or 0) or 0
  if collectibleID > 0 then
    return t .. ":" .. tostring(collectibleID)
  end
  local itemID = tonumber(def.itemID or 0) or 0
  if itemID > 0 then
    return t .. "_item:" .. tostring(itemID)
  end
  return nil
end

local function computeSelectedDifficultyAggregatePreview(rawGroupOrId, mode)
  local rawGroup = rawGroupOrId
  if type(rawGroupOrId) ~= "table" then
    rawGroup = rawGroupFromKey(rawGroupOrId)
    if not rawGroup then
      local groups = ns and ns.Data and ns.Data.groups or nil
      rawGroup = groups and (groups[rawGroupOrId] or groups[tonumber(rawGroupOrId) or -1]) or nil
    end
  end
  if type(rawGroup) ~= "table" then return nil, "resolve_failed" end
  mode = tostring(mode or ((ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode()) or "shared"))

  local families = {}
  local items = nil
  if ns and ns.UI and ns.UI.GetEligibleVisibleGroupItems then
    items = ns.UI.GetEligibleVisibleGroupItems(rawGroup)
  end
  if type(items) ~= "table" then
    items = type(rawGroup.items) == "table" and rawGroup.items or {}
  end
  for i = 1, #items do
    local itemID = tonumber(items[i])
    if itemID and ns and ns.Registry and ns.Registry.GetItemDefinitionForGroup then
      local def = ns.Registry.GetItemDefinitionForGroup(itemID, rawGroup)
      if type(def) == "table" then
        local state = nil
        if lower(tostring(def.type or "")) == "appearance" and ns and ns.Truth and ns.Truth.GetAppearanceCollectionState then
          local modeDef = shallowCopy(def)
          modeDef._clogAppearanceModeOverride = mode
          state = ns.Truth.GetAppearanceCollectionState(modeDef)
          def = modeDef
        end
        local key = selectedDifficultyAggregateKey(def, state, mode)
        if key and not families[key] then
          local collected = false
          if lower(tostring(def.type or "")) == "appearance" then
            if type(state) == "table" then
              collected = state.countsAsCollected and true or false
            end
          elseif ns and ns.Truth and ns.Truth.IsCollected then
            collected = ns.Truth.IsCollected(def) and true or false
          end
          families[key] = {
            key = key,
            itemID = tonumber(def.itemID or itemID or 0) or 0,
            name = tostring(def.name or ("item:" .. tostring(itemID))),
            type = tostring(def.type or ""),
            collected = collected,
          }
        elseif key and families[key] and families[key].collected ~= true then
          local collected = false
          if lower(tostring(def.type or "")) == "appearance" then
            if type(state) == "table" then
              collected = state.countsAsCollected and true or false
            end
          elseif ns and ns.Truth and ns.Truth.IsCollected then
            collected = ns.Truth.IsCollected(def) and true or false
          end
          if collected then families[key].collected = true end
        end
      end
    end
  end

  local total, collected = 0, 0
  for _, fam in pairs(families) do
    total = total + 1
    if fam.collected == true then collected = collected + 1 end
  end
  return {
    group = rawGroup,
    mode = mode,
    total = total,
    collected = collected,
    families = families,
  }, nil
end

ns.ComputeSelectedDifficultyAggregatePreview = computeSelectedDifficultyAggregatePreview

local function runPreviewAggregateStrict(msg)
  local raw = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  raw = raw:gsub('^"(.*)"$', "%1")
  raw = raw:gsub("^'(.*)'$", "%1")
  if raw == "" or raw == "active" then
    local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
    local activeGroup = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
    if type(activeGroup) == "table" and activeGroup.category and activeGroup.instanceID then
      raw = tostring(activeGroup.name or activeGroup.instanceID)
    end
  end
  if raw == "" then
    Print('Usage: /clogpreviewaggregatestrict <raid or dungeon name>')
    return
  end

  local preview, group, err = computeStrictAggregateItemFamilyPreview(raw)
  if not preview then
    Print(("Strict aggregate preview: could not resolve '%s' (%s)"):format(raw, tostring(err or "unknown")))
    return
  end

  local sharedStatus = ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus and ns.TrueCollection.GetGroupStatus(preview.groupKey) or nil
  local sharedCollected = tonumber(sharedStatus and sharedStatus.collected or 0) or 0
  local sharedTotal = tonumber(sharedStatus and sharedStatus.total or 0) or 0

  Print(("Strict aggregate preview: key=%s name=%s category=%s strict=%d/%d shared=%d/%d"):format(
    tostring(preview.groupKey),
    tostring(group and group.name or "?"),
    tostring(group and group.category or "?"),
    tonumber(preview.collected or 0) or 0,
    tonumber(preview.total or 0) or 0,
    sharedCollected,
    sharedTotal))
end

SLASH_CLOGPREVIEWAGGSTRICT1 = "/clogpreviewaggregatestrict"
SlashCmdList.CLOGPREVIEWAGGSTRICT = runPreviewAggregateStrict

local function runVerifyCounts(msg)
  local raw = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  raw = raw:gsub('^"(.*)"$', "%1")
  raw = raw:gsub("^'(.*)'$", "%1")
  if raw == "" or raw == "active" then
    local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
    local activeGroup = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
    if type(activeGroup) == "table" and activeGroup.category and activeGroup.instanceID then
      raw = tostring(activeGroup.name or activeGroup.instanceID)
    end
  end
  if raw == "" then
    Print('Usage: /clogverifycounts <active|raid or dungeon name>')
    return
  end

  local groupKey, aggregateGroup = resolveAggregateGroup(raw)
  if not groupKey or type(aggregateGroup) ~= "table" then
    Print(("Verify counts: could not resolve '%s'"):format(raw))
    return
  end

  local rawGroup = nil
  local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
  local activeGroup = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
  if type(activeGroup) == "table"
    and tostring(activeGroup.category or "") == tostring(aggregateGroup.category or "")
    and tonumber(activeGroup.instanceID or 0) == tonumber(aggregateGroup.instanceID or -1) then
    rawGroup = activeGroup
  end
  if (not rawGroup) and type(aggregateGroup.sourceGroupKeys) == "table" and ns and ns.Data and ns.Data.groups then
    for sourceKey in pairs(aggregateGroup.sourceGroupKeys) do
      local candidate = ns.Data.groups[sourceKey] or ns.Data.groups[tonumber(sourceKey) or -1]
      if type(candidate) == "table" then
        rawGroup = candidate
        break
      end
    end
  end

  local currentMode = (ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode()) or "shared"
  local aggregateStatus = ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus and ns.TrueCollection.GetGroupStatus(groupKey) or nil
  local activeRawStatus = rawGroup and ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus and ns.TrueCollection.GetGroupStatus(rawGroup) or nil
  local sharedPreview = rawGroup and ns and ns.ComputeSelectedDifficultyAggregatePreview and select(1, ns.ComputeSelectedDifficultyAggregatePreview(rawGroup, "shared")) or nil
  local strictPreview = rawGroup and ns and ns.ComputeSelectedDifficultyAggregatePreview and select(1, ns.ComputeSelectedDifficultyAggregatePreview(rawGroup, "strict")) or nil
  local overviewEntry = CollectionLogDB and CollectionLogDB.cache and CollectionLogDB.cache.overview and CollectionLogDB.cache.overview[aggregateGroup.category] or nil

  local aggC = tonumber(aggregateStatus and aggregateStatus.collected or 0) or 0
  local aggT = tonumber(aggregateStatus and aggregateStatus.total or 0) or 0
  local rawC = tonumber(activeRawStatus and activeRawStatus.collected or 0) or 0
  local rawT = tonumber(activeRawStatus and activeRawStatus.total or 0) or 0
  local sharedC = tonumber(sharedPreview and sharedPreview.collected or 0) or 0
  local sharedT = tonumber(sharedPreview and sharedPreview.total or 0) or 0
  local strictC = tonumber(strictPreview and strictPreview.collected or 0) or 0
  local strictT = tonumber(strictPreview and strictPreview.total or 0) or 0
  local ovC = tonumber(overviewEntry and overviewEntry.c or 0) or 0
  local ovT = tonumber(overviewEntry and overviewEntry.t or 0) or 0

  Print(("Verify counts: name=%s category=%s mode=%s key=%s"):format(
    tostring(aggregateGroup.name or "?"),
    tostring(aggregateGroup.category or "?"),
    tostring(currentMode),
    tostring(groupKey)))
  if rawGroup then
    Print(("  active/raw row status: %d/%d (%s)"):format(
      rawC,
      rawT,
      tostring(rawGroup.name or rawGroup.id or "?")))
  end
  Print(("  aggregate current-mode status: %d/%d"):format(aggC, aggT))
  Print(("  aggregate shared preview: %d/%d"):format(sharedC, sharedT))
  Print(("  aggregate exact preview: %d/%d"):format(strictC, strictT))
  if overviewEntry then
    Print(("  overview tile cache for %s: %d/%d"):format(tostring(aggregateGroup.category or "?"), ovC, ovT))
  else
    Print(("  overview tile cache for %s: none"):format(tostring(aggregateGroup.category or "?")))
  end

  local sharedOk = (sharedC >= strictC)
  local totalOk = (sharedT <= strictT)
  local modeOk = true
  if tostring(currentMode) == "shared" then
    modeOk = (aggC == sharedC and aggT == sharedT)
  elseif tostring(currentMode) == "strict" then
    modeOk = (aggC == strictC and aggT == strictT)
  end
  Print(("  checks: sharedCollected>=exactCollected=%s sharedTotal<=exactTotal=%s currentModeMatchesAggregate=%s"):format(
    boolText(sharedOk),
    boolText(totalOk),
    boolText(modeOk)))
end

SLASH_CLOGVERIFYCOUNTS1 = "/clogverifycounts"
SlashCmdList.CLOGVERIFYCOUNTS = runVerifyCounts

local function runSortDiag(msg)
  local raw = tostring(msg or ""):match("^%s*(.-)%s*$") or ""
  local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
  local group = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
  if raw ~= "" and raw ~= "active" and ns and ns.Data and ns.Data.groups then
    local q = raw:lower()
    for _, candidate in pairs(ns.Data.groups) do
      if type(candidate) == "table" and tostring(candidate.category or "") ~= "" then
        local name = tostring(candidate.name or candidate.id or ""):lower()
        if name == q then
          group = candidate
          break
        end
      end
    end
  end

  if type(group) ~= "table" then
    Print("Usage: /clogsortdiag <active|exact group name>")
    return
  end
  if tostring(group.category or "") ~= "Raids" and tostring(group.category or "") ~= "Dungeons" then
    Print(("Sort diag: active group is not a raid/dungeon row (%s)"):format(tostring(group.category or "?")))
    return
  end

  local ui = ns and ns.UI or nil
  if not (ui and ui.GetEligibleVisibleGroupItems and ui.GetGroupItemSectionFromMetadata and ui.CLOG_GetGroupItemSortName and ui.CLOG_SortItemIDsByGroupName) then
    Print("Sort diag: required UI sort helpers are unavailable")
    return
  end

  local visible = ui.GetEligibleVisibleGroupItems(group) or {}
  local sectionBuckets = {}
  local subBuckets = {}
  for _, itemID in ipairs(visible) do
    local sec = ui.GetGroupItemSectionFromMetadata(group, itemID) or "Misc"
    sectionBuckets[sec] = sectionBuckets[sec] or {}
    sectionBuckets[sec][#sectionBuckets[sec] + 1] = itemID

    if sec == "Weapons" or sec == "Armor" then
      local sub = (sec == "Armor" and CL_GetArmorSubCategory and CL_GetArmorSubCategory(itemID))
        or (sec == "Weapons" and CL_GetWeaponSubCategory and CL_GetWeaponSubCategory(itemID))
        or "Other"
      local bucketKey = sec .. "::" .. tostring(sub)
      subBuckets[bucketKey] = subBuckets[bucketKey] or { section = sec, sub = sub, items = {} }
      subBuckets[bucketKey].items[#subBuckets[bucketKey].items + 1] = itemID
    end
  end

  Print(("Sort diag: group=%s id=%s difficultyID=%s mode=%s visible=%d"):format(
    tostring(group.name or "?"),
    tostring(group.id or "?"),
    tostring(group.difficultyID or "?"),
    tostring(group.mode or "?"),
    #visible))

  local keys = {}
  for bucketKey in pairs(subBuckets) do keys[#keys + 1] = bucketKey end
  table.sort(keys)

  for _, bucketKey in ipairs(keys) do
    local bucket = subBuckets[bucketKey]
    local current = {}
    for i = 1, #bucket.items do current[i] = bucket.items[i] end
    local expected = {}
    for i = 1, #bucket.items do expected[i] = bucket.items[i] end
    ui.CLOG_SortItemIDsByGroupName(expected, group)

    local mismatchAt = nil
    for i = 1, #current do
      if current[i] ~= expected[i] then
        mismatchAt = i
        break
      end
    end

    Print(("  %s / %s: count=%d matchesExpected=%s"):format(
      tostring(bucket.section or "?"),
      tostring(bucket.sub or "?"),
      #current,
      boolText(mismatchAt == nil)))

    local limit = math.min(#current, 8)
    for i = 1, limit do
      local curID = tonumber(current[i] or 0) or 0
      local expID = tonumber(expected[i] or 0) or 0
      local curName = ui.CLOG_GetGroupItemSortName(group, curID)
      local expName = ui.CLOG_GetGroupItemSortName(group, expID)
      local marker = (curID == expID) and "=" or "!"
      Print(("    #%d %s current=%s(%s) expected=%s(%s)"):format(
        i,
        marker,
        tostring(curID),
        tostring(curName),
        tostring(expID),
        tostring(expName)))
    end
  end
end

SLASH_CLOGSORTDIAG1 = "/clogsortdiag"
SlashCmdList.CLOGSORTDIAG = runSortDiag

local function runRenderDiag(msg)
  local ui = ns and ns.UI or nil
  if not (ui and ui.cells and ui.CLOG_SortItemIDsByGroupName and ui.CLOG_GetGroupItemSortName) then
    Print("Render diag: UI helpers unavailable")
    return
  end

  local activeID = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
  local group = activeID and ns and ns.Data and ns.Data.groups and (ns.Data.groups[activeID] or ns.Data.groups[tonumber(activeID) or -1]) or nil
  if type(group) ~= "table" then
    Print("Render diag: no active group")
    return
  end

  local visibleCells = {}
  for i = 1, tonumber(ui.maxCells or 0) or 0 do
    local cell = ui.cells[i]
    if cell and cell.IsShown and cell:IsShown() and tonumber(cell.itemID or 0) > 0 then
      visibleCells[#visibleCells + 1] = cell
    end
  end

  Print(("Render diag: group=%s id=%s difficultyID=%s mode=%s shownCells=%d"):format(
    tostring(group.name or "?"),
    tostring(group.id or "?"),
    tostring(group.difficultyID or "?"),
    tostring(group.mode or "?"),
    #visibleCells))

  local buckets = {}
  for _, cell in ipairs(visibleCells) do
    local sec = tostring(cell.section or "Misc")
    local sub = "Other"
    if sec == "Armor" and CL_GetArmorSubCategory then
      sub = tostring(CL_GetArmorSubCategory(cell.itemID) or "Other")
    elseif sec == "Weapons" and CL_GetWeaponSubCategory then
      sub = tostring(CL_GetWeaponSubCategory(cell.itemID) or "Other")
    end
    local key = sec .. "::" .. sub
    buckets[key] = buckets[key] or { section = sec, sub = sub, cells = {}, itemIDs = {} }
    buckets[key].cells[#buckets[key].cells + 1] = cell
    buckets[key].itemIDs[#buckets[key].itemIDs + 1] = tonumber(cell.itemID)
  end

  local keys = {}
  for key in pairs(buckets) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local bucket = buckets[key]
    local current = {}
    for i = 1, #bucket.itemIDs do current[i] = bucket.itemIDs[i] end
    local expected = {}
    for i = 1, #bucket.itemIDs do expected[i] = bucket.itemIDs[i] end
    ui.CLOG_SortItemIDsByGroupName(expected, group)

    local mismatchAt = nil
    for i = 1, #current do
      if current[i] ~= expected[i] then
        mismatchAt = i
        break
      end
    end
    Print(("  rendered %s / %s: count=%d matchesExpected=%s"):format(
      tostring(bucket.section),
      tostring(bucket.sub),
      #current,
      boolText(mismatchAt == nil)))
    local limit = math.min(#current, 8)
    for i = 1, limit do
      local curID = tonumber(current[i] or 0) or 0
      local expID = tonumber(expected[i] or 0) or 0
      local curName = ui.CLOG_GetGroupItemSortName(group, curID)
      local expName = ui.CLOG_GetGroupItemSortName(group, expID)
      local marker = (curID == expID) and "=" or "!"
      Print(("    #%d %s current=%s(%s) expected=%s(%s)"):format(
        i, marker, tostring(curID), tostring(curName), tostring(expID), tostring(expName)))
    end
  end

  local hover = ui._clogLastHoveredGridCell
  if hover and hover.IsShown and hover:IsShown() then
    local r, g, b, a = 0, 0, 0, 0
    if hover.GetBackdropBorderColor then
      r, g, b, a = hover:GetBackdropBorderColor()
    end
    Print(("  hovered cell: itemID=%s section=%s border=%.2f,%.2f,%.2f,%.2f countText=%s"):format(
      tostring(hover.itemID),
      tostring(hover.section),
      tonumber(r or 0) or 0,
      tonumber(g or 0) or 0,
      tonumber(b or 0) or 0,
      tonumber(a or 0) or 0,
      tostring(hover.countText and hover.countText.GetText and hover.countText:GetText() or "")))
  else
    Print("  hovered cell: none")
  end
end

SLASH_CLOGRENDERDIAG1 = "/clogrenderdiag"
SlashCmdList.CLOGRENDERDIAG = runRenderDiag
