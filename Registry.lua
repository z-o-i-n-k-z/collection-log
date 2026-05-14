local ADDON, ns = ...

ns.Registry = ns.Registry or {}
local Registry = ns.Registry

Registry._groupDefinitionsCache = Registry._groupDefinitionsCache or {}
Registry._itemDefinitionForGroupCache = Registry._itemDefinitionForGroupCache or {}

function Registry.ClearCache(reason)
  if wipe then
    wipe(Registry._groupDefinitionsCache)
    wipe(Registry._itemDefinitionForGroupCache)
  else
    for k in pairs(Registry._groupDefinitionsCache) do Registry._groupDefinitionsCache[k] = nil end
    for k in pairs(Registry._itemDefinitionForGroupCache) do Registry._itemDefinitionForGroupCache[k] = nil end
  end
  Registry._lastClearReason = tostring(reason or "manual")
end

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function normalizeType(kind)
  kind = tostring(kind or ""):lower()
  if kind == "mount" or kind == "pet" or kind == "toy" or kind == "housing" or kind == "appearance" then
    return kind
  end
  return kind ~= "" and kind or "unknown"
end

local function makeDefinition(args)
  if type(args) ~= "table" then return nil end
  local t = normalizeType(args.type or args.kind)
  local itemID = asNumber(args.itemID or args.rawID)
  local collectibleID = asNumber(args.collectibleID or args.identityValue)
  local name = args.name or args.itemName
  if (not name or name == "" or name == "?") and itemID and ns.NameResolver and ns.NameResolver.GetItemName then
    name = ns.NameResolver.GetItemName(itemID, true)
  end
  return {
    itemID = itemID,
    type = t,
    collectibleID = collectibleID,
    identityType = args.identityType,
    sourceGroup = args.sourceGroup or args.groupKey,
    entryKey = args.entryKey,
    name = name,
    raw = args.raw,
  }
end

local function firstRawRef(entry)
  if type(entry) ~= "table" then return nil end
  local refs = entry.rawRefs
  if type(refs) == "table" then
    for i = 1, #refs do
      local v = asNumber(refs[i])
      if v then return v end
    end
    for _, v in pairs(refs) do
      v = asNumber(v)
      if v then return v end
    end
  end

  -- CompletionDefinitions keeps per-kind raw debug maps. Use them as a
  -- secondary source so compare output can preserve source itemIDs even when
  -- an entry was de-duped by collectible identity.
  local dbg = type(entry.debug) == "table" and entry.debug or nil
  if dbg then
    local order = { "mount", "pet", "toy", "appearance", "housing" }
    for _, kind in ipairs(order) do
      local raw = dbg[kind] and dbg[kind].raw
      if type(raw) == "table" then
        for key in pairs(raw) do
          local v = asNumber(key)
          if v then return v end
        end
      end
    end
  end

  return asNumber(entry.rawID or entry.itemID)
end

local function nameFromCompletionDebug(entry, kind, itemID)
  if type(entry) ~= "table" or type(entry.debug) ~= "table" then return nil end
  kind = normalizeType(kind)
  local raw = entry.debug[kind] and entry.debug[kind].raw
  if type(raw) ~= "table" then return nil end
  local key = itemID and tostring(itemID) or nil
  local row = key and raw[key] or nil
  if type(row) == "table" and type(row.itemName) == "string" and row.itemName ~= "" then return row.itemName end
  for _, r in pairs(raw) do
    if type(r) == "table" and type(r.itemName) == "string" and r.itemName ~= "" then return r.itemName end
  end
  return nil
end

local function nameFromStaticDB(kind, itemID, collectibleID)
  kind = normalizeType(kind)
  itemID = asNumber(itemID)
  collectibleID = asNumber(collectibleID)

  if kind == "mount" then
    local row = itemID and ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
    if row and (row.name or row.itemName) then return row.name or row.itemName end
    if collectibleID and ns.CompletionMountDB and ns.CompletionMountDB.GetBySpellID then
      local mrow = ns.CompletionMountDB.GetBySpellID(collectibleID)
      if mrow and mrow.name then return mrow.name end
    end
  elseif kind == "pet" then
    local row = itemID and ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
    if row and (row.name or row.itemName) then return row.name or row.itemName end
  elseif kind == "toy" then
    local row = itemID and ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) or nil
    if row and (row.name or row.itemName) then return row.name or row.itemName end
  end
  return nil
end



-- Strict collectible fallback table for known raid/dungeon mount tokens that are
-- present in the shipped completion definitions but not yet represented in the
-- generated mount item DB. This keeps the raw-row collectible filter honest
-- without allowing generic/junk items through.
local MOUNT_ITEM_FALLBACKS = {
  [69224] = { spellID = 97493, name = "Pureblood Fire Hawk", itemName = "Smoldering Egg of Millagazor" },
}

function Registry.FromCompletionEntry(entry, groupKey)
  if type(entry) ~= "table" then return nil end
  local identity = entry.identity or {}
  local itemID = firstRawRef(entry)
  return makeDefinition({
    itemID = itemID,
    type = entry.kind,
    collectibleID = identity.value,
    identityType = identity.type,
    sourceGroup = groupKey or entry.groupKey,
    entryKey = entry.entryKey,
    name = entry.name or entry.itemName or nameFromCompletionDebug(entry, entry.kind, itemID) or nameFromStaticDB(entry.kind, itemID, identity.value),
    raw = entry,
  })
end



local DIFFICULTY_LABELS = {
  [17] = "LFR", [7] = "LFR",
  [1] = "Normal", [3] = "Normal", [4] = "Normal", [14] = "Normal",
  [2] = "Heroic", [5] = "Heroic", [6] = "Heroic", [15] = "Heroic",
  [16] = "Mythic", [23] = "Mythic",
}

local function resolveRawGroup(groupOrKey)
  if type(groupOrKey) == "table" then return groupOrKey end
  local key = tostring(groupOrKey or "")
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) == "table" then
    if key:match("^raw:") then
      local rawID = key:match("^raw:(.+)$")
      return groups[rawID] or groups[tonumber(rawID) or -1]
    end
    return groups[key] or groups[tonumber(key) or -1]
  end
  return nil
end

local function groupItemLinksForItem(group, itemID)
  itemID = asNumber(itemID)
  if not (group and itemID and type(group.itemLinks) == "table") then return nil end
  return group.itemLinks[itemID] or group.itemLinks[tostring(itemID)]
end

local function firstLinkValue(links)
  if type(links) == "string" and links ~= "" then return links end
  if type(links) == "table" then
    for _, L in ipairs(links) do if type(L) == "string" and L ~= "" then return L end end
    for _, L in pairs(links) do if type(L) == "string" and L ~= "" then return L end end
  end
  return nil
end


local function difficultyTierFromID(difficultyID, modeName)
  difficultyID = asNumber(difficultyID)
  local mode = tostring(modeName or ""):lower()
  if difficultyID == 16 or difficultyID == 23 or mode:find("mythic", 1, true) then return "mythic" end
  if difficultyID == 15 or difficultyID == 2 or difficultyID == 5 or difficultyID == 6 or mode:find("heroic", 1, true) then return "heroic" end
  if difficultyID == 17 or difficultyID == 7 or mode:find("looking for raid", 1, true) or mode:find("lfr", 1, true) then return "lfr" end
  if difficultyID == 14 or difficultyID == 1 or difficultyID == 3 or difficultyID == 4 or mode:find("normal", 1, true) then return "normal" end
  return nil
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

local function sourceVisualID(sourceID)
  sourceID = asNumber(sourceID)
  if not (sourceID and C_TransmogCollection) then return nil end
  if C_TransmogCollection.GetSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetSourceInfo, sourceID)
    if ok and type(info) == "table" then
      return asNumber(info.visualID or info.appearanceID), info
    end
  end
  if C_TransmogCollection.GetAppearanceSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
    if ok and type(info) == "table" then
      return asNumber(info.visualID or info.appearanceID), info
    end
  end
  return nil
end


local function ensureCanonicalAppearanceItemIndex()
  Registry._canonicalAppearanceByItem = Registry._canonicalAppearanceByItem or nil
  if Registry._canonicalAppearanceByItem ~= nil then return Registry._canonicalAppearanceByItem end
  local out = {}
  local data = ns and ns.AppearanceCanonicalData or nil
  local sets = data and data.sets or nil
  if type(sets) == "table" then
    for _, set in pairs(sets) do
      local entries = type(set) == "table" and set.entries or nil
      if type(entries) == "table" then
        for i = 1, #entries do
          local entry = entries[i]
          local itemID = asNumber(entry and entry.itemID)
          if itemID then
            local row = out[itemID]
            local mods = type(entry.modIDs) == "table" and entry.modIDs or nil
            -- Prefer the richest entry if duplicate set rows exist for an item.
            if (not row) or ((mods and #mods or 0) > (row.modIDs and #row.modIDs or 0)) then
              local copyMods = nil
              if mods then
                copyMods = {}
                for mi = 1, #mods do
                  local modID = asNumber(mods[mi])
                  if modID then copyMods[#copyMods + 1] = modID end
                end
              end
              out[itemID] = {
                itemID = itemID,
                appearanceID = asNumber(entry.appearanceID),
                modIDs = copyMods,
              }
            end
          end
        end
      end
    end
  end
  Registry._canonicalAppearanceByItem = out
  return out
end

local function canonicalAppearanceEntryForItem(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  local index = ensureCanonicalAppearanceItemIndex()
  return type(index) == "table" and index[itemID] or nil
end

local function attachCanonicalSiblingMods(def, itemID)
  if type(def) ~= "table" then return def end
  local canon = canonicalAppearanceEntryForItem(itemID or def.itemID)
  if type(canon) ~= "table" then return def end
  if canon.appearanceID then
    -- Keep the exact link-derived appearance when present, but fill missing
    -- rows from the canonical set table.  The canonical table is static data;
    -- it does not query Blizzard while browsing.
    def.appearanceID = def.appearanceID or canon.appearanceID
    def.collectibleID = def.collectibleID or def.appearanceID
  end
  if type(canon.modIDs) == "table" and #canon.modIDs > 0 then
    -- Canonical set data has the full variant source family. Prefer it over
    -- scanner-derived sibling lists, because scanner source IDs are the exact
    -- field that got duplicated across some modern difficulties.
    def.siblingModIDs = canon.modIDs
    def.itemModIDs = canon.modIDs
    if type(def._clogStaticMeta) == "table" then
      def._clogStaticMeta.siblingModIDs = canon.modIDs
      def._clogStaticMeta.itemModIDs = canon.modIDs
    end
  end
  return def
end

local function listHasValue(list, needle)
  needle = asNumber(needle)
  if not (type(list) == "table" and needle) then return false end
  for _, v in pairs(list) do
    if asNumber(v) == needle then return true end
  end
  return false
end

local function applyValidatedMetaVariant(diffDef, meta, row)
  if type(diffDef) ~= "table" or type(meta) ~= "table" then return diffDef, false end

  local metaAppearanceID = asNumber(meta.appearanceID)
  local metaModID = asNumber(meta.sourceID or meta.modID or meta.itemModifiedAppearanceID)
  local rowApps = type(row) == "table" and row.appearanceIDs or nil
  local rowMods = type(row) == "table" and (row.modifiedAppearanceIDs or row.modIDs) or nil

  local appearanceValid = metaAppearanceID and (listHasValue(rowApps, metaAppearanceID) or metaAppearanceID == asNumber(row and (row.appearanceID or row.visualID))) or false
  local modValid = metaModID and listHasValue(rowMods, metaModID) or false

  if not appearanceValid and not modValid then
    return diffDef, false
  end

  -- Keep the hyperlink itself for Blizzard tooltip truth, but anchor the row's
  -- identity to the active group's validated variant metadata. This prevents a
  -- generic/default hyperlink source from silently redefining Mythic/Heroic/etc.
  -- as the wrong appearance/source while still allowing the hyperlink tooltip to
  -- veto false greens for the exact displayed item.
  if appearanceValid then
    diffDef.appearanceID = metaAppearanceID
    diffDef.collectibleID = metaAppearanceID
  end
  if modValid then
    diffDef.sourceID = metaModID
    diffDef.modID = metaModID
    diffDef.itemModifiedAppearanceID = metaModID
  end
  if appearanceValid or modValid then
    diffDef._clogSourceTrust = modValid and "generatedDB" or "generatedAppearanceDB"
  end
  if type(meta.siblingModIDs) == "table" then
    diffDef.siblingModIDs = meta.siblingModIDs
    diffDef.itemModIDs = meta.itemModIDs or meta.siblingModIDs
  end
  return diffDef, true
end

local function cohereAppearanceSourcePair(def)
  if type(def) ~= "table" then return def end
  local sourceID = asNumber(def.modID or def.sourceID or def.itemModifiedAppearanceID)
  local appearanceID = asNumber(def.appearanceID or def.collectibleID)
  if not sourceID then return def end

  local visualID = sourceVisualID(sourceID)
  if not visualID then return def end

  if not appearanceID then
    def.appearanceID = visualID
    def.collectibleID = visualID
    return def
  end

  if visualID ~= appearanceID then
    -- The row's exact-source identity and broad appearance identity disagree.
    -- This is the failure mode that turns an unowned Mythic row green via a
    -- different appearance family. Anchor the row to the exact source's visual
    -- and disable broad shared-appearance fallback for this row until a better
    -- verified mapping is available.
    def.appearanceID = visualID
    def.collectibleID = visualID
    def._sharedAppearanceUntrusted = true
    def._sharedAppearanceUntrustedReason = "source_visual_mismatch_fail_closed"
  end
  return def
end

local function findModIDForAppearance(row, appearanceID, tier)
  appearanceID = asNumber(appearanceID)
  local mods = type(row) == "table" and (row.modifiedAppearanceIDs or row.modIDs) or nil
  if not (appearanceID and type(mods) == "table") then return nil end

  -- Prefer Blizzard source metadata: it directly tells us which modified
  -- appearance/source belongs to the chosen visualID. This avoids relying on
  -- generated-array ordering, which is not always parallel to appearanceIDs.
  for i = 1, #mods do
    local modID = asNumber(mods[i])
    local visualID = sourceVisualID(modID)
    if visualID == appearanceID then return modID end
  end

  -- Known generated raid order fallback. For four-way raid variants the
  -- appearanceIDs are commonly LFR/Normal/Heroic/Mythic, while modified source
  -- IDs may be Normal/LFR/Heroic/Mythic. Use this only if source metadata was
  -- unavailable.
  if #mods >= 4 then
    if tier == "normal" then return asNumber(mods[1]) end
    if tier == "lfr" then return asNumber(mods[2]) end
    if tier == "heroic" then return asNumber(mods[3]) end
    if tier == "mythic" then return asNumber(mods[4]) end
  elseif #mods == 3 then
    if tier == "normal" then return asNumber(mods[1]) end
    if tier == "heroic" then return asNumber(mods[2]) end
    if tier == "mythic" then return asNumber(mods[3]) end
  elseif #mods == 2 then
    if tier == "normal" then return asNumber(mods[1]) end
    if tier == "heroic" or tier == "mythic" then return asNumber(mods[2]) end
  elseif #mods == 1 then
    return asNumber(mods[1])
  end
  return nil
end

local function staticDifficultyAppearanceFromRow(itemID, groupOrKey, baseDef)
  itemID = asNumber(itemID)
  local row = ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get and ns.CompletionAppearanceItemDB.Get(itemID) or nil
  local group = resolveRawGroup(groupOrKey)
  if not (itemID and row and group) then return nil end

  local tier = difficultyTierFromID(group.difficultyID, group.mode)
  if not tier then return nil end
  local idx = appearanceIndexForTier(row, tier)
  local apps = row.appearanceIDs
  local appearanceID = apps and idx and asNumber(apps[idx]) or nil
  if not appearanceID then return nil end
  local modID = findModIDForAppearance(row, appearanceID, tier)

  local name = baseDef and baseDef.name or row.name or row.itemName
  if (not name or name == "" or name == "?") and itemID and ns.NameResolver and ns.NameResolver.GetItemName then
    name = ns.NameResolver.GetItemName(itemID, true)
  end

  local def = makeDefinition({
    itemID = itemID,
    type = "appearance",
    collectibleID = appearanceID,
    identityType = "appearanceID",
    name = name,
    raw = row,
    sourceGroup = group and ("raw:" .. tostring(group.id or "")) or (baseDef and baseDef.sourceGroup),
  })
  if not def then return nil end
  def.appearanceID = appearanceID
  def.modID = modID
  def.sourceID = modID
  def.itemModifiedAppearanceID = modID
  def.difficultyID = asNumber(group.difficultyID)
  def.difficultyName = group.mode or DIFFICULTY_LABELS[asNumber(group.difficultyID)]
  def._difficultyTier = tier
  def._clogSourceTrust = modID and "generatedDB" or (appearanceID and "generatedAppearanceDB" or "unknown")
  if type(def.raw) == "table" then
    def.raw._activeDifficultyAppearanceID = appearanceID
    def.raw._activeDifficultyModID = modID
  end
  return def, appearanceID, modID, nil, group
end

local function difficultyAppearanceFromLink(itemID, groupOrKey, baseDef)
  itemID = asNumber(itemID)
  local group = resolveRawGroup(groupOrKey)
  if not (itemID and group and C_TransmogCollection and C_TransmogCollection.GetItemInfo) then return nil end
  local link = firstLinkValue(groupItemLinksForItem(group, itemID))
  if not link then return nil end
  local ok, appearanceID, modID = pcall(C_TransmogCollection.GetItemInfo, link)
  appearanceID, modID = asNumber(appearanceID), asNumber(modID)
  if not (appearanceID or modID) then return nil end

  local raw = type(baseDef) == "table" and type(baseDef.raw) == "table" and baseDef.raw or nil
  local name = baseDef and baseDef.name
  if (not name or name == "" or name == "?") and itemID and ns.NameResolver and ns.NameResolver.GetItemName then
    name = ns.NameResolver.GetItemName(itemID, true)
  end
  local def = makeDefinition({
    itemID = itemID,
    type = "appearance",
    collectibleID = appearanceID or (baseDef and baseDef.collectibleID),
    identityType = modID and "itemModifiedAppearanceID" or "appearanceID",
    name = name,
    raw = raw or (baseDef and baseDef.raw),
    sourceGroup = group and ("raw:" .. tostring(group.id or "")) or (baseDef and baseDef.sourceGroup),
  })
  if def then
    def._clogSourceTrust = modID and "itemLink" or (appearanceID and "itemLinkAppearance" or "unknown")
    def.itemLink = link
  end
  return def, appearanceID, modID, link, group
end


local function definitionFromRaidDungeonMeta(meta, baseDef)
  if type(meta) ~= "table" then return nil end
  local def = makeDefinition({
    itemID = meta.itemID,
    type = meta.kind or meta.type,
    collectibleID = meta.collectibleID,
    identityType = meta.identityType,
    name = meta.itemName or (baseDef and baseDef.name),
    raw = meta.raw or (baseDef and baseDef.raw),
    sourceGroup = meta.groupID and ("raw:" .. tostring(meta.groupID)) or (baseDef and baseDef.sourceGroup),
  })
  if not def then return nil end
  def.appearanceID = meta.appearanceID
  def.sourceID = meta.sourceID
  def.modID = meta.modID or meta.sourceID
  def.itemModifiedAppearanceID = meta.itemModifiedAppearanceID or meta.sourceID
  def.difficultyID = meta.difficultyID
  def.difficultyName = meta.difficultyName
  def._difficultyTier = meta.difficultyTier
  def.itemLink = meta.itemLink
  def.dropsFrom = meta.dropsFrom
  def.sourceText = meta.sourceText
  def.instanceID = meta.instanceID
  def.instanceName = meta.instanceName
  def.category = meta.category
  def.expansion = meta.expansion
  def.variantKey = meta.variantKey
  def.appearanceKey = meta.appearanceKey
  def.itemKey = meta.itemKey
  def.siblingModIDs = meta.siblingModIDs or meta.itemModIDs
  def.itemModIDs = meta.itemModIDs
  def.siblingItemIDs = meta.siblingItemIDs
  def._sharedAppearanceUntrusted = meta.sharedAppearanceUntrusted and true or false
  def._sharedAppearanceUntrustedReason = meta._sharedAppearanceUntrustedReason
  def._exactSourceUntrusted = meta.exactSourceUntrusted and true or false
  def._exactSourceUntrustedReason = meta._exactSourceUntrustedReason
  def._clogStaticMeta = meta
  def._clogSourceTrust = (def.modID or def.sourceID or def.itemModifiedAppearanceID) and "datapack" or "unknown"
  if type(def.raw) == "table" then
    def.raw._activeDifficultyAppearanceID = meta.appearanceID
    def.raw._activeDifficultyModID = meta.sourceID or meta.modID
  end
  attachCanonicalSiblingMods(def, meta.itemID)
  return def
end

function Registry.GetItemDefinitionForGroup(itemID, groupOrKey)
  itemID = asNumber(itemID)
  if not itemID then return nil end

  local groupKey
  if type(groupOrKey) == "table" then
    groupKey = tostring(groupOrKey.id or groupOrKey.groupId or groupOrKey.instanceID or groupOrKey.name or "?")
      .. ":" .. tostring(groupOrKey.difficultyID or groupOrKey.mode or "?")
  else
    groupKey = tostring(groupOrKey or "?")
  end

  Registry._itemDefinitionForGroupCache = Registry._itemDefinitionForGroupCache or {}
  local cacheKey = tostring(itemID) .. "|" .. groupKey
  local cached = Registry._itemDefinitionForGroupCache[cacheKey]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end

  local function EnrichDisplayFromMeta(def, meta)
    if type(def) ~= "table" or type(meta) ~= "table" then return def end
    -- Datapack/scanner metadata is retained for display/source attribution and
    -- first-paint classification, but it is not allowed to replace the v4.3.69
    -- difficulty/source truth fields that drive collection status.
    def.itemLink = def.itemLink or meta.itemLink
    def.dropsFrom = def.dropsFrom or meta.dropsFrom
    def.sourceText = def.sourceText or meta.sourceText
    def.instanceID = def.instanceID or meta.instanceID
    def.instanceName = def.instanceName or meta.instanceName
    def.category = def.category or meta.category
    def.expansion = def.expansion or meta.expansion
    def.variantKey = def.variantKey or meta.variantKey
    def.appearanceKey = def.appearanceKey or meta.appearanceKey
    def.itemKey = def.itemKey or meta.itemKey
    def.siblingItemIDs = def.siblingItemIDs or meta.siblingItemIDs
    def._clogStaticMeta = meta
    return def
  end

  local function Build()
    local baseDef = Registry.GetItemDefinition(itemID)
    local meta = ns.RaidDungeonMeta and ns.RaidDungeonMeta.GetItemMeta and ns.RaidDungeonMeta.GetItemMeta(groupOrKey, itemID) or nil

    -- v4.3.96: Restore the v4.3.69 appearance ownership hierarchy.
    -- For raid/dungeon appearances, exact/source truth comes from the generated
    -- CompletionAppearanceItemDB difficulty row first, then the difficulty item
    -- link. Datapack metadata remains display metadata only. This prevents dirty
    -- scanner/source IDs from cross-contaminating Mythic/Heroic/Normal rows while
    -- keeping the newer boss/source/performance improvements.
    if type(baseDef) == "table" and normalizeType(baseDef.type) == "appearance" then
      local row = ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get and ns.CompletionAppearanceItemDB.Get(itemID) or nil
      -- v4.3.96: For raid/dungeon difficulty variants, the exact item hyperlink
      -- is the best ownership key.  The generated appearance DB is useful as a
      -- fallback, but modern items can have upgrade/bonus/difficulty mappings that
      -- make generated array order unsafe for exact source truth.  Prefer the
      -- difficulty-specific itemLink first, then fall back to the static row.
      local diffDef, appearanceID, modID, link, group = difficultyAppearanceFromLink(itemID, groupOrKey, baseDef)
      if not diffDef then
        diffDef, appearanceID, modID, link, group = staticDifficultyAppearanceFromRow(itemID, groupOrKey, baseDef)
      end
      if diffDef then
        diffDef.sourceID = modID
        diffDef.modID = modID
        diffDef.itemModifiedAppearanceID = modID
        diffDef.appearanceID = appearanceID
        diffDef.collectibleID = appearanceID or diffDef.collectibleID
        diffDef.difficultyID = group and asNumber(group.difficultyID) or nil
        diffDef.difficultyName = group and (group.mode or DIFFICULTY_LABELS[asNumber(group.difficultyID)]) or nil
        diffDef.itemLink = link or diffDef.itemLink
        diffDef.raw = diffDef.raw or row
        diffDef._clogSourceTrust = modID and (link and "itemLink" or "generatedDB") or (appearanceID and (link and "itemLinkAppearance" or "generatedAppearanceDB") or "unknown")
        diffDef._exactSourceUntrusted = false
        diffDef._sharedAppearanceUntrusted = false
        if type(diffDef.raw) == "table" then
          diffDef.raw._activeDifficultyAppearanceID = appearanceID
          diffDef.raw._activeDifficultyModID = modID
        end
        diffDef = attachCanonicalSiblingMods(diffDef, itemID)
        diffDef = EnrichDisplayFromMeta(diffDef, meta)
        diffDef = select(1, applyValidatedMetaVariant(diffDef, meta, row))
        diffDef = cohereAppearanceSourcePair(diffDef)
        return diffDef
      end
      return EnrichDisplayFromMeta(baseDef, meta)
    end

    -- Non-appearance collectible rows, and new appearance rows that are not yet
    -- represented in CompletionAppearanceItemDB, may still be created from the
    -- enriched datapack. Scanner-only appearance source IDs are kept as metadata
    -- candidates, not trusted exact ownership proof.
    local metaDef = definitionFromRaidDungeonMeta(meta, baseDef)
    if metaDef then
      if normalizeType(metaDef.type) == "appearance" then
        metaDef._clogSourceTrust = metaDef._clogSourceTrust or "datapack"
        metaDef._exactSourceUntrusted = true
      end
      return metaDef
    end

    return baseDef
  end

  local built = Build()
  Registry._itemDefinitionForGroupCache[cacheKey] = built or false
  return built
end

function Registry.GetItemDefinition(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end

  local row
  row = ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
  if row then
    return makeDefinition({ itemID = itemID, type = "mount", collectibleID = row.spellID or row.mountID, identityType = row.spellID and "mountSpellID" or "mountID", name = row.name or row.itemName, raw = row })
  end

  row = MOUNT_ITEM_FALLBACKS[itemID]
  if row then
    local name = row.name or row.itemName
    if row.spellID and ns.CompletionMountDB and ns.CompletionMountDB.GetBySpellID then
      local mrow = ns.CompletionMountDB.GetBySpellID(row.spellID)
      if mrow and mrow.name then name = mrow.name end
    end
    return makeDefinition({ itemID = itemID, type = "mount", collectibleID = row.spellID or row.mountID, identityType = row.spellID and "mountSpellID" or "mountID", name = name, raw = row })
  end

  row = ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
  if row then
    return makeDefinition({ itemID = itemID, type = "pet", collectibleID = row.speciesID, identityType = "petSpeciesID", name = row.name or row.itemName, raw = row })
  end

  row = ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) or nil
  if row then
    return makeDefinition({ itemID = itemID, type = "toy", collectibleID = row.toyID or itemID, identityType = "toyItemID", name = row.name or row.itemName, raw = row })
  end

  row = ns.CompletionHousingItemDB and ns.CompletionHousingItemDB.Get and ns.CompletionHousingItemDB.Get(itemID) or nil
  if row then
    return makeDefinition({ itemID = itemID, type = "housing", collectibleID = row.decorID or row.recordID or itemID, identityType = "housingDecorID", name = row.name or row.itemName, raw = row })
  end

  row = ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get and ns.CompletionAppearanceItemDB.Get(itemID) or nil
  if row then
    return makeDefinition({ itemID = itemID, type = "appearance", collectibleID = row.appearanceID or row.visualID, identityType = "appearanceID", name = row.name or row.itemName, raw = row })
  end

  return nil
end



local function rawItemListForGroup(group)
  local out, seen = {}, {}
  local function add(v)
    local id = asNumber(v)
    if id and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  if type(group) ~= "table" then return out end
  if type(group.items) == "table" then for _, id in ipairs(group.items) do add(id) end end
  if type(group.itemIDs) == "table" then for _, id in ipairs(group.itemIDs) do add(id) end end
  if type(group.itemLinks) == "table" then
    for k, v in pairs(group.itemLinks) do
      add(k)
      add(v)
    end
  end
  table.sort(out)
  return out
end

local function rawGroupKeyFor(group, groupId)
  local id = group and group.id or groupId
  if id == nil then return nil end
  return "raw:" .. tostring(id)
end

local function getRawGroupFromKey(groupKey)
  local rawID = tostring(groupKey or ""):match("^raw:(.+)$")
  if not rawID or rawID == "" then return nil, nil end
  local groups = ns and ns.Data and ns.Data.groups or nil
  if type(groups) ~= "table" then return nil, rawID end
  return groups[rawID] or groups[tonumber(rawID) or -1], rawID
end

function Registry.ResolveGroup(query)
  query = tostring(query or ""):match("^%s*(.-)%s*$") or ""
  if query == "" or query == "active" or query == "visible" or query == "current" then
    local groupId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
    local group = groupId and ns.Data and ns.Data.groups and (ns.Data.groups[groupId] or ns.Data.groups[tonumber(groupId) or -1]) or nil
    local rawKey = rawGroupKeyFor(group, groupId)
    if group and rawKey then
      return rawKey, group, "active_raw_row"
    end
    return nil, nil, "active_missing"
  end
  if tostring(query):match("^raw:") then
    local group = getRawGroupFromKey(query)
    if group then return query, group, "exact_raw_key" end
  end
  if ns.CompletionDefinitions and ns.CompletionDefinitions.ResolveGroupKey then
    return ns.CompletionDefinitions.ResolveGroupKey(query)
  end
  return nil, nil, "resolver_missing"
end

function Registry.GetGroupDefinitions(groupKey)
  if not (ns.CompletionDefinitions and ns.CompletionDefinitions.GetEntriesForGroup) then return {} end
  groupKey = tostring(groupKey or "")
  Registry._groupDefinitionsCache = Registry._groupDefinitionsCache or {}
Registry._itemDefinitionForGroupCache = Registry._itemDefinitionForGroupCache or {}
  local cached = Registry._groupDefinitionsCache[groupKey]
  if cached then return cached end

  -- Difficulty/visible-row compare mode. The legacy completion definition
  -- builder aggregates all raw groups by EJ instance; for parity work we also
  -- need to compare the exact row the UI is rendering. Entries already record
  -- which raw group IDs contributed to them, so we can filter the aggregate
  -- entry table without rebuilding or touching UI code.
  local rawGroup, rawID = getRawGroupFromKey(groupKey)
  if rawGroup and rawID then
    -- For visible-row parity we do not use the aggregate CompletionDefinitions
    -- table. That table is useful for broad lookup, but it can pull in entries
    -- from sibling difficulties/variants. The desired Collection Log pipeline is
    -- collectible-only per visible row: raw row loot -> strict collectible gate ->
    -- normalized truth. Non-collectables never enter the returned definitions.
    local out = {}
    local items = rawItemListForGroup(rawGroup)
    for i = 1, #items do
      local def = Registry.GetItemDefinitionForGroup(items[i], rawGroup)
      if def then
        def.sourceGroup = groupKey
        out[#out + 1] = def
      end
    end
    Registry._groupDefinitionsCache[groupKey] = out
    return out
  end

  local entries = ns.CompletionDefinitions.GetEntriesForGroup(groupKey) or {}
  local out = {}
  for i = 1, #entries do
    local def = Registry.FromCompletionEntry(entries[i], groupKey)
    if def then out[#out + 1] = def end
  end
  Registry._groupDefinitionsCache[groupKey] = out
  return out
end

function Registry.GetRawGroupKey(group)
  return rawGroupKeyFor(group)
end
