local ADDON, ns = ...

--[[
Raid/Dungeon metadata foundation.

Purpose:
  Keep raid/dungeon browsing and tooltips datapack-first.  This layer builds
  static, in-memory indexes from shipped data packs and generated completion DBs.
  It does not scan Encounter Journal, request item data, or query ownership.

Runtime ownership still belongs to ns.Truth / Blizzard APIs.  This module only
answers stable metadata questions: source/boss attribution, difficulty identity,
item links, difficulty-specific appearance/source IDs, and sibling variants.
]]

ns.RaidDungeonMeta = ns.RaidDungeonMeta or {}
local Meta = ns.RaidDungeonMeta

Meta.version = 1
Meta.byGroupItem = Meta.byGroupItem or {}
Meta.byItem = Meta.byItem or {}
Meta.byInstanceCategory = Meta.byInstanceCategory or {}
Meta.variantEntries = Meta.variantEntries or {}
Meta.groupVariantItem = Meta.groupVariantItem or {}
Meta.siblingGroups = Meta.siblingGroups or {}
Meta._signature = Meta._signature or nil

local function wipeTable(t)
  if not t then return end
  if wipe then wipe(t) else for k in pairs(t) do t[k] = nil end end
end

function Meta.ClearCache(reason)
  wipeTable(Meta.byGroupItem)
  wipeTable(Meta.byItem)
  wipeTable(Meta.byInstanceCategory)
  wipeTable(Meta.variantEntries)
  wipeTable(Meta.groupVariantItem)
  wipeTable(Meta.siblingGroups)
  Meta._signature = nil
  Meta._lastClearReason = tostring(reason or "manual")
end

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function rawGroupID(groupOrKey)
  if type(groupOrKey) == "table" then return groupOrKey.id or groupOrKey.groupId end
  local s = tostring(groupOrKey or "")
  return s:match("^raw:(.+)$") or s
end

local function resolveGroup(groupOrKey)
  if type(groupOrKey) == "table" then return groupOrKey end
  local gid = rawGroupID(groupOrKey)
  if gid == nil or gid == "" then return nil end
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then return nil end
  return groups[gid] or groups[tonumber(gid) or -1]
end

local function isRaidDungeonGroup(g)
  if type(g) ~= "table" then return false end
  return g.category == "Raids" or g.category == "Dungeons"
end

local DIFFICULTY_LABELS = {
  [17] = "LFR", [7] = "LFR",
  [1] = "Normal", [3] = "Normal", [4] = "Normal", [14] = "Normal",
  [2] = "Heroic", [5] = "Heroic", [6] = "Heroic", [15] = "Heroic",
  [16] = "Mythic", [23] = "Mythic",
}

local function difficultyTierFromID(difficultyID, modeName)
  difficultyID = asNumber(difficultyID)
  local mode = tostring(modeName or ""):lower()
  if difficultyID == 16 or difficultyID == 23 or mode:find("mythic", 1, true) then return "mythic" end
  if difficultyID == 15 or difficultyID == 2 or difficultyID == 5 or difficultyID == 6 or mode:find("heroic", 1, true) then return "heroic" end
  if difficultyID == 17 or difficultyID == 7 or mode:find("looking for raid", 1, true) or mode:find("lfr", 1, true) then return "lfr" end
  if difficultyID == 14 or difficultyID == 1 or difficultyID == 3 or difficultyID == 4 or mode:find("normal", 1, true) then return "normal" end
  if mode:find("timewalking", 1, true) then return "timewalking" end
  return nil
end

local function difficultyRank(tier)
  if tier == "mythic" then return 40 end
  if tier == "heroic" then return 30 end
  if tier == "normal" then return 20 end
  if tier == "lfr" then return 10 end
  if tier == "timewalking" then return 5 end
  return 0
end

local function difficultyShortLabel(difficultyID, modeName)
  local tier = difficultyTierFromID(difficultyID, modeName)
  local mode = tostring(modeName or "")
  if tier == "mythic" then return "M" end
  if tier == "heroic" then
    if mode:find("10") then return "H(10)" end
    if mode:find("25") then return "H(25)" end
    return "H"
  end
  if tier == "normal" then
    if mode:find("10") then return "N(10)" end
    if mode:find("25") then return "N(25)" end
    return "N"
  end
  if tier == "lfr" then return "LFR" end
  if tier == "timewalking" then return "TW" end
  return DIFFICULTY_LABELS[asNumber(difficultyID)] or modeName or tostring(difficultyID or "?")
end

local function appearanceIndexForTier(row, tier)
  local apps = type(row) == "table" and row.appearanceIDs or nil
  if type(apps) ~= "table" then return nil end
  local n = #apps
  if n >= 4 then
    if tier == "lfr" then return 1 end
    if tier == "normal" then return 2 end
    if tier == "heroic" then return 3 end
    if tier == "mythic" then return 4 end
  elseif n == 3 then
    if tier == "normal" then return 1 end
    if tier == "heroic" then return 2 end
    if tier == "mythic" then return 3 end
  elseif n == 2 then
    if tier == "normal" then return 1 end
    if tier == "heroic" or tier == "mythic" then return 2 end
  elseif n == 1 then
    return 1
  end
  return nil
end

local function modIndexForTier(row, tier)
  local mods = type(row) == "table" and (row.modifiedAppearanceIDs or row.modIDs) or nil
  if type(mods) ~= "table" then return nil end
  local n = #mods
  -- Static generated raid order fallback.  This mirrors the existing registry
  -- fallback, but avoids GetAppearanceSourceInfo during browsing/hover.
  if n >= 4 then
    if tier == "normal" then return 1 end
    if tier == "lfr" then return 2 end
    if tier == "heroic" then return 3 end
    if tier == "mythic" then return 4 end
  elseif n == 3 then
    if tier == "normal" then return 1 end
    if tier == "heroic" then return 2 end
    if tier == "mythic" then return 3 end
  elseif n == 2 then
    if tier == "normal" then return 1 end
    if tier == "heroic" or tier == "mythic" then return 2 end
  elseif n == 1 then
    return 1
  end
  return nil
end

local function firstItemLink(group, itemID)
  local links = group and group.itemLinks and (group.itemLinks[itemID] or group.itemLinks[tostring(itemID)]) or nil
  if type(links) == "string" and links ~= "" then return links end
  if type(links) == "table" then
    for _, L in ipairs(links) do if type(L) == "string" and L ~= "" then return L end end
    for _, L in pairs(links) do if type(L) == "string" and L ~= "" then return L end end
  end
  return nil
end

local function itemNameFromLink(link)
  if type(link) ~= "string" then return nil end
  local name = link:match("%|h%[([^%]]+)%]%|h")
  if type(name) == "string" and name ~= "" then return name end
  return nil
end

local function tableItem(t, itemID)
  if type(t) ~= "table" then return nil end
  return t[itemID] or t[tostring(itemID)]
end


local function mapValue(group, mapName, itemID)
  return tableItem(group and group[mapName], itemID)
end

local function metaValue(itemMeta, group, fieldName, mapName, itemID)
  if type(itemMeta) == "table" and itemMeta[fieldName] ~= nil then return itemMeta[fieldName] end
  if mapName then return mapValue(group, mapName, itemID) end
  return nil
end

local function firstListValue(v)
  if type(v) == "table" then
    return v[1] or select(2, next(v))
  end
  return v
end

local function appearancePairFromLink(link)
  if type(link) ~= "string" or link == "" then return nil, nil end
  if not (C_TransmogCollection and C_TransmogCollection.GetItemInfo) then return nil, nil end
  local ok, appearanceID, sourceID = pcall(C_TransmogCollection.GetItemInfo, link)
  if not ok then return nil, nil end
  appearanceID = asNumber(appearanceID)
  sourceID = asNumber(sourceID)
  return appearanceID, sourceID
end

local function rawItemList(group)
  local out, seen = {}, {}
  local function add(v)
    local id = asNumber(v)
    if id and not seen[id] then
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
  if type(group.itemLinks) == "table" then
    for k in pairs(group.itemLinks) do add(k) end
  end
  table.sort(out)
  return out
end

local function baseKindAndRow(itemID)
  local row = ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
  if row then return "mount", row end
  if ns.CompletionRaidMounts and ns.CompletionRaidMounts.GetFallbackItemInfo then
    row = ns.CompletionRaidMounts.GetFallbackItemInfo(itemID)
    if row then return "mount", row end
  end
  if ns.CompletionRaidMounts and ns.CompletionRaidMounts.IsExplicitRaidMountItem and ns.CompletionRaidMounts.IsExplicitRaidMountItem(itemID) then
    return "mount", { itemID = itemID }
  end
  row = ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
  if row then return "pet", row end
  row = ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) or nil
  if row then return "toy", row end
  row = ns.CompletionHousingItemDB and ns.CompletionHousingItemDB.Get and ns.CompletionHousingItemDB.Get(itemID) or nil
  if row then return "housing", row end
  row = ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get and ns.CompletionAppearanceItemDB.Get(itemID) or nil
  if row then return "appearance", row end
  return "unknown", nil
end

local function addIndexed(t, k, v)
  if not k then return end
  t[k] = t[k] or {}
  t[k][#t[k] + 1] = v
end

local function makeSignature(groups)
  local count, maxID = 0, ""
  if type(groups) == "table" then
    for id, g in pairs(groups) do
      if isRaidDungeonGroup(g) then
        count = count + 1
        local sid = tostring(id)
        if sid > maxID then maxID = sid end
      end
    end
  end
  return tostring(count) .. ":" .. maxID
end

local function build()
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then return false end
  local sig = makeSignature(groups)
  if Meta._signature == sig and next(Meta.byGroupItem) then return true end

  wipeTable(Meta.byGroupItem)
  wipeTable(Meta.byItem)
  wipeTable(Meta.byInstanceCategory)
  wipeTable(Meta.variantEntries)
  wipeTable(Meta.groupVariantItem)
  wipeTable(Meta.siblingGroups)
  Meta._signature = sig

  for _, group in pairs(groups) do
    if isRaidDungeonGroup(group) and group.id ~= nil then
      local groupID = tostring(group.id)
      local tier = difficultyTierFromID(group.difficultyID, group.mode)
      local instanceCategoryKey = tostring(group.category or "?") .. ":" .. tostring(group.instanceID or group.name or "?")
      addIndexed(Meta.byInstanceCategory, instanceCategoryKey, group)
      Meta.byGroupItem[groupID] = Meta.byGroupItem[groupID] or {}
      Meta.groupVariantItem[groupID] = Meta.groupVariantItem[groupID] or {}

      local items = rawItemList(group)
      for i = 1, #items do
        local itemID = items[i]
        local itemMeta = tableItem(group.itemMetadata, itemID)
        local kind, row = baseKindAndRow(itemID)
        if kind == "unknown" then
          local mk = tostring(metaValue(itemMeta, group, "collectibleType", "itemCollectibleTypes", itemID) or metaValue(itemMeta, group, "type", nil, itemID) or ""):lower()
          if mk == "mount" or mk == "pet" or mk == "toy" or mk == "housing" or mk == "appearance" then
            kind = mk
            row = type(itemMeta) == "table" and itemMeta or {}
          end
        end
        if kind ~= "unknown" then
          local link = firstItemLink(group, itemID) or metaValue(itemMeta, group, "itemLink", nil, itemID) or nil
          local appearanceID, modID
          local explicitAppearanceID, explicitModID, usedCanonicalVariantIDs
          if kind == "appearance" and type(row) == "table" then
            -- Scanner-captured values are useful when the older static DB does
            -- not know an item yet, but some scanner/API paths can stamp the
            -- same source/appearance across multiple difficulties. Prefer the
            -- canonical per-item variant arrays whenever they exist so Normal,
            -- Heroic, Mythic, and LFR ownership cannot collapse into one state.
            explicitAppearanceID = asNumber(mapValue(group, "itemAppearanceIDs", itemID) or mapValue(group, "appearanceIDs", itemID) or metaValue(itemMeta, group, "appearanceID", nil, itemID))
            explicitModID = asNumber(mapValue(group, "itemModifiedAppearanceIDs", itemID) or mapValue(group, "itemSourceIDs", itemID) or mapValue(group, "sourceIDs", itemID) or metaValue(itemMeta, group, "sourceID", nil, itemID) or metaValue(itemMeta, group, "itemModifiedAppearanceID", nil, itemID) or metaValue(itemMeta, group, "modID", nil, itemID))

            local ai = appearanceIndexForTier(row, tier)
            local mi = modIndexForTier(row, tier)
            local canonicalAppearanceID = ai and row.appearanceIDs and asNumber(row.appearanceIDs[ai]) or nil
            local canonicalModID = mi and (row.modifiedAppearanceIDs or row.modIDs) and asNumber((row.modifiedAppearanceIDs or row.modIDs)[mi]) or nil
            local appCount = type(row.appearanceIDs) == "table" and #row.appearanceIDs or 0
            local modCount = type(row.modifiedAppearanceIDs or row.modIDs) == "table" and #(row.modifiedAppearanceIDs or row.modIDs) or 0

            -- Scanner/link-derived appearanceIDs are useful because they come
            -- from the actual row we scanned. However, scanner/link-derived
            -- sourceIDs can collapse multiple difficulties onto Normal when the
            -- item link resolves without enough bonus context. For exact-source
            -- ownership, prefer the generated canonical modifiedAppearanceID
            -- for the active difficulty whenever a multi-difficulty source list
            -- exists. This keeps Normal/Heroic/Mythic/LFR from all turning green
            -- when only one source is owned.
            appearanceID = explicitAppearanceID
            modID = explicitModID

            if modCount > 1 and canonicalModID then
              modID = canonicalModID
              usedCanonicalVariantIDs = true
            end

            -- Do NOT replace an explicit appearanceID with a guessed one. A
            -- wrong appearanceID makes "Appearance collected via another source"
            -- fail on the exact Normal/LFR rows the player actually owns.
            -- Last-resort fallback for older packs with no scanner metadata.
            if not appearanceID then
              appearanceID = canonicalAppearanceID or asNumber(row.appearanceID or row.visualID)
            end
          end

          local itemModIDs = nil
          if kind == "appearance" and type(row) == "table" and type(row.modifiedAppearanceIDs or row.modIDs) == "table" then
            itemModIDs = {}
            local mods = row.modifiedAppearanceIDs or row.modIDs
            for _, v in pairs(mods) do
              local n = asNumber(v)
              if n then itemModIDs[#itemModIDs + 1] = n end
            end
          end

          local collectibleID = asNumber(metaValue(itemMeta, group, "collectibleID", "itemCollectibleIDs", itemID))
          local identityType = metaValue(itemMeta, group, "identityType", "itemIdentityTypes", itemID)
          if kind == "mount" then
            collectibleID = collectibleID or asNumber(row.spellID or row.mountID)
            identityType = identityType or (row.spellID and "mountSpellID" or "mountID")
          elseif kind == "pet" then
            collectibleID = collectibleID or asNumber(row.speciesID)
            identityType = identityType or "petSpeciesID"
          elseif kind == "toy" then
            collectibleID = collectibleID or asNumber(row.toyID or itemID)
            identityType = identityType or "toyItemID"
          elseif kind == "housing" then
            collectibleID = collectibleID or asNumber(row.decorID or row.recordID or itemID)
            identityType = identityType or "housingDecorID"
          elseif kind == "appearance" then
            collectibleID = appearanceID or collectibleID
            identityType = identityType or (modID and "itemModifiedAppearanceID" or "appearanceID")
          end

          local itemKey = "item:" .. tostring(itemID)
          local appearanceKey = appearanceID and ("appearance:" .. tostring(appearanceID)) or nil
          local exactSourceKey = modID and ("source:" .. tostring(modID)) or nil
          local variantKey = appearanceKey or itemKey
          local dropName = mapValue(group, "itemSources", itemID) or metaValue(itemMeta, group, "dropsFrom", nil, itemID)
          local encounterID = asNumber(mapValue(group, "itemEncounterIDs", itemID) or mapValue(group, "encounterIDs", itemID) or metaValue(itemMeta, group, "encounterID", nil, itemID))
          local sourceText = metaValue(itemMeta, group, "sourceText", "itemSourceTexts", itemID)
          if (not sourceText or sourceText == "") and dropName and group.name then
            sourceText = tostring(dropName) .. " - " .. tostring(group.name)
          end
          sourceText = sourceText or group.name

          local rawMeta = type(itemMeta) == "table" and itemMeta or {
            itemID = itemID,
            itemName = mapValue(group, "itemNames", itemID),
            collectibleType = kind,
            collectibleID = collectibleID,
            identityType = identityType,
            appearanceID = appearanceID,
            sourceID = modID,
            itemModifiedAppearanceID = modID,
            encounterID = encounterID,
            dropsFrom = dropName,
            sourceText = sourceText,
          }

          local meta = {
            itemID = itemID,
            itemLink = link,
            itemName = metaValue(itemMeta, group, "itemName", "itemNames", itemID) or itemNameFromLink(link) or row.name or row.itemName,
            kind = kind,
            type = kind,
            collectibleID = collectibleID,
            identityType = identityType,
            appearanceID = appearanceID,
            sourceID = modID,
            modID = modID,
            itemModifiedAppearanceID = modID,
            hasExplicitTransmogIDs = (usedCanonicalVariantIDs or explicitAppearanceID ~= nil or explicitModID ~= nil) and true or false,
            -- Set later when duplicate scanner/canonical metadata proves this row
            -- cannot safely identify its exact difficulty source.
            exactSourceUntrusted = false,
            itemModIDs = itemModIDs,
            siblingModIDs = itemModIDs,
            itemKey = itemKey,
            appearanceKey = appearanceKey,
            exactSourceKey = exactSourceKey,
            variantKey = variantKey,
            groupID = groupID,
            rawGroupID = groupID,
            category = group.category,
            expansion = group.expansion,
            instanceID = group.instanceID,
            instanceName = group.name,
            groupName = group.name,
            encounterID = encounterID,
            encounterName = dropName,
            difficultyID = asNumber(group.difficultyID),
            difficultyName = group.mode or metaValue(itemMeta, group, "difficultyName", nil, itemID) or DIFFICULTY_LABELS[asNumber(group.difficultyID)],
            difficultyTier = tier,
            difficultyShort = difficultyShortLabel(group.difficultyID, group.mode),
            sourceText = sourceText,
            dropsFrom = dropName,
            raw = rawMeta,
          }

          Meta.byGroupItem[groupID][itemID] = meta
          Meta.byItem[itemID] = Meta.byItem[itemID] or {}
          Meta.byItem[itemID][groupID] = meta

          addIndexed(Meta.variantEntries, instanceCategoryKey .. ":" .. itemKey, meta)
          Meta.groupVariantItem[groupID][itemKey] = itemID
          if appearanceKey then
            addIndexed(Meta.variantEntries, instanceCategoryKey .. ":" .. appearanceKey, meta)
            Meta.groupVariantItem[groupID][appearanceKey] = itemID
          end
          if exactSourceKey then
            Meta.groupVariantItem[groupID][exactSourceKey] = itemID
          end
        end
      end
    end
  end

  for key, list in pairs(Meta.byInstanceCategory) do
    table.sort(list, function(a, b)
      local ar = difficultyRank(difficultyTierFromID(a.difficultyID, a.mode))
      local br = difficultyRank(difficultyTierFromID(b.difficultyID, b.mode))
      if ar ~= br then return ar > br end
      return tostring(a.id or "") < tostring(b.id or "")
    end)
    Meta.siblingGroups[key] = list
  end

  for variantFullKey, list in pairs(Meta.variantEntries) do
    table.sort(list, function(a, b)
      local ar = difficultyRank(a.difficultyTier)
      local br = difficultyRank(b.difficultyTier)
      if ar ~= br then return ar > br end
      return tostring(a.groupID or "") < tostring(b.groupID or "")
    end)

    -- Scanner/API exports can occasionally stamp the Normal visual/appearanceID
    -- across Heroic/Mythic rows for the same item.  Exact source IDs are still
    -- enough to decide whether that difficulty is owned, but the duplicated
    -- broad appearanceID would falsely produce "Appearance owned via another
    -- source" on other difficulties.  Mark only those duplicate non-primary
    -- rows so Truth can skip the broad appearance-owned fallback while keeping
    -- exact-source and same-item sibling checks intact.
    local isItemVariant = tostring(variantFullKey or ""):find(":item:", 1, true) ~= nil
    if isItemVariant and type(list) == "table" and #list >= 3 then
      local modernItem = false
      for i = 1, #list do
        local iid = asNumber(list[i] and list[i].itemID)
        if iid and iid >= 100000 then modernItem = true; break end
      end
      if modernItem then
        local byAppearance = {}
        for i = 1, #list do
          local m = list[i]
          local appID = asNumber(m and m.appearanceID)
          if appID and tostring(m.kind or m.type or ""):lower() == "appearance" then
            byAppearance[appID] = byAppearance[appID] or {}
            byAppearance[appID][#byAppearance[appID] + 1] = m
          end
        end
        for _, members in pairs(byAppearance) do
          if #members > 1 then
            local keep = nil
            for i = 1, #members do
              if members[i].difficultyTier == "normal" then keep = members[i]; break end
            end
            keep = keep or members[1]
            for i = 1, #members do
              local m = members[i]
              if m ~= keep then
                m.sharedAppearanceUntrusted = true
                m.exactSourceUntrusted = true
                m._sharedAppearanceUntrustedReason = "duplicate appearanceID across item difficulty variants"
                m._exactSourceUntrustedReason = "duplicate scanner/canonical source across item difficulty variants"
              end
            end
          end
        end
      end
    end

    -- Scanner exports can also duplicate the exact sourceID across Normal/Heroic/Mythic
    -- when EJ returns the base item link for several modes.  A duplicated sourceID
    -- is not a trustworthy exact-difficulty identity.  Keep the row with a real
    -- difficulty item link as the trusted source, and force the other rows to
    -- require a future verified link/datapack value before they can count.
    do
      local isItemVariant = tostring(variantFullKey or ""):find(":item:", 1, true) ~= nil
      if isItemVariant and type(list) == "table" and #list >= 2 then
        local bySource = {}
        for i = 1, #list do
          local m = list[i]
          local sid = asNumber(m and (m.sourceID or m.modID or m.itemModifiedAppearanceID))
          if sid and tostring(m and (m.kind or m.type) or ""):lower() == "appearance" then
            bySource[sid] = bySource[sid] or {}
            bySource[sid][#bySource[sid] + 1] = m
          end
        end
        for _, members in pairs(bySource) do
          if #members > 1 then
            local keep = nil
            for i = 1, #members do
              if type(members[i].itemLink) == "string" and members[i].itemLink ~= "" then keep = members[i]; break end
            end
            keep = keep or members[1]
            for i = 1, #members do
              local m = members[i]
              if m ~= keep then
                m.exactSourceUntrusted = true
                m.sharedAppearanceUntrusted = true
                m._exactSourceUntrustedReason = "duplicate sourceID across item difficulty variants"
                m._sharedAppearanceUntrustedReason = m._sharedAppearanceUntrustedReason or "duplicate sourceID across item difficulty variants"
              end
            end
          end
        end
      end
    end

    local siblingModIDs, siblingItemIDs, seenMods = {}, {}, {}
    local function addMod(v)
      v = asNumber(v)
      if v and not seenMods[v] then
        seenMods[v] = true
        siblingModIDs[#siblingModIDs + 1] = v
      end
    end
    for i = 1, #list do
      local m = list[i]
      if m.sourceID then addMod(m.sourceID) end
      if type(m.itemModIDs) == "table" then
        for _, modID in pairs(m.itemModIDs) do addMod(modID) end
      end
      if m.itemID then siblingItemIDs[#siblingItemIDs + 1] = m.itemID end
    end
    local isItemVariant = tostring(variantFullKey or ""):find(":item:", 1, true) ~= nil
    for i = 1, #list do
      if isItemVariant then
        list[i].siblingModIDs = siblingModIDs
        list[i].siblingItemIDs = siblingItemIDs
      elseif not list[i].siblingItemIDs then
        list[i].siblingItemIDs = siblingItemIDs
      end
    end
  end

  return true
end

function Meta.Ensure()
  return build()
end

function Meta.GetItemMeta(groupOrKey, itemID)
  itemID = asNumber(itemID)
  if not itemID or not build() then return nil end
  local group = resolveGroup(groupOrKey)
  local gid = group and tostring(group.id or rawGroupID(groupOrKey)) or tostring(rawGroupID(groupOrKey) or "")
  if gid == "" then return nil end
  local byItem = Meta.byGroupItem[gid]
  return byItem and byItem[itemID] or nil
end

function Meta.GetSiblingGroups(groupOrKey)
  if not build() then return {} end
  local group = resolveGroup(groupOrKey)
  if not group then return {} end
  local key = tostring(group.category or "?") .. ":" .. tostring(group.instanceID or group.name or "?")
  return Meta.siblingGroups[key] or {}
end

function Meta.GetBestVariantKey(groupOrKey, itemID)
  local meta = Meta.GetItemMeta(groupOrKey, itemID)
  if not meta then return nil end
  local instanceCategoryKey = tostring(meta.category or "?") .. ":" .. tostring(meta.instanceID or meta.instanceName or "?")
  local itemList = Meta.variantEntries[instanceCategoryKey .. ":" .. tostring(meta.itemKey or "")]
  if itemList and #itemList > 1 then return meta.itemKey end
  local appList = meta.appearanceKey and Meta.variantEntries[instanceCategoryKey .. ":" .. meta.appearanceKey] or nil
  if appList and #appList > 1 then return meta.appearanceKey end
  return meta.variantKey or meta.itemKey
end

function Meta.GetVariantEntries(groupOrKey, itemID)
  local meta = Meta.GetItemMeta(groupOrKey, itemID)
  if not meta then return nil end
  local key = Meta.GetBestVariantKey(groupOrKey, itemID)
  if not key then return nil end
  local instanceCategoryKey = tostring(meta.category or "?") .. ":" .. tostring(meta.instanceID or meta.instanceName or "?")
  return Meta.variantEntries[instanceCategoryKey .. ":" .. key]
end

function Meta.FindItemIDForVariant(groupOrKey, variantKey)
  if not variantKey or not build() then return nil end
  local group = resolveGroup(groupOrKey)
  local gid = group and tostring(group.id or rawGroupID(groupOrKey)) or tostring(rawGroupID(groupOrKey) or "")
  local byKey = Meta.groupVariantItem[gid]
  return byKey and byKey[variantKey] or nil
end

