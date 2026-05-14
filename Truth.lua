local ADDON, ns = ...

ns.Truth = ns.Truth or {}
local Truth = ns.Truth

Truth._mountByMountIDCache = Truth._mountByMountIDCache or {}
Truth._mountBySpellCache = Truth._mountBySpellCache or {}
Truth._appearanceByIDCache = Truth._appearanceByIDCache or {}
Truth._modifiedAppearanceCache = Truth._modifiedAppearanceCache or {}
Truth._appearanceSourceInfoCache = Truth._appearanceSourceInfoCache or {}
Truth._appearanceSourcesCache = Truth._appearanceSourcesCache or {}
Truth._appearanceStateCache = Truth._appearanceStateCache or {}
Truth._isCollectedCache = Truth._isCollectedCache or {}

local function wipeCache(tbl)
  if not tbl then return end
  if wipe then wipe(tbl) else for k in pairs(tbl) do tbl[k] = nil end end
end

function Truth.ClearCache(reason)
  wipeCache(Truth._mountByMountIDCache)
  wipeCache(Truth._mountBySpellCache)
  wipeCache(Truth._appearanceByIDCache)
  wipeCache(Truth._modifiedAppearanceCache)
  wipeCache(Truth._appearanceSourceInfoCache)
  wipeCache(Truth._appearanceSourcesCache)
  wipeCache(Truth._appearanceStateCache)
  wipeCache(Truth._isCollectedCache)
  wipeCache(Truth._itemLinkAppearanceTooltipCache)
  Truth._cacheGeneration = (tonumber(Truth._cacheGeneration or 0) or 0) + 1
  Truth._lastClearReason = tostring(reason or "manual")
end

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function mountCollectedByMountID(mountID)
  mountID = asNumber(mountID)
  if not mountID then return false end
  local cached = Truth._mountByMountIDCache[mountID]
  if cached ~= nil then return cached and true or false end

  local result = false
  -- C_MountJournal.GetMountInfoByID returns isCollected as the 11th
  -- return value.  Be explicit here; the earlier POC accidentally read the
  -- shouldHideOnChar slot, which made owned mounts look missing.
  if C_MountJournal and C_MountJournal.GetMountInfoByID then
    local ok, name, spellID, icon, active, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
    if ok and isCollected ~= nil then
      result = isCollected and true or false
    end
  end

  Truth._mountByMountIDCache[mountID] = result
  return result
end

local function mountCollectedBySpell(spellID)
  spellID = asNumber(spellID)
  if not spellID then return false end
  local cached = Truth._mountBySpellCache[spellID]
  if cached ~= nil then return cached and true or false end

  if ns.CompletionSnapshot and ns.CompletionSnapshot.GetMountDebug then
    local dbg = ns.CompletionSnapshot.GetMountDebug(spellID)
    if type(dbg) == "table" and dbg.collected ~= nil then
      local result = dbg.collected and true or false
      Truth._mountBySpellCache[spellID] = result
      return result
    end
  end

  local row, mountID
  if ns.CompletionMountDB and ns.CompletionMountDB.GetBySpellID then
    row, mountID = ns.CompletionMountDB.GetBySpellID(spellID)
  end
  mountID = asNumber(mountID or (row and row.mountID))

  if mountID then
    local result = mountCollectedByMountID(mountID)
    Truth._mountBySpellCache[spellID] = result
    return result
  end

  -- Fallback for environments where only the live Mount Journal index knows
  -- the spell -> mount mapping.  This is debug/compare-only and intentionally
  -- not used by the UI.
  if C_MountJournal and C_MountJournal.GetNumMounts and C_MountJournal.GetMountFromSpell and C_MountJournal.GetMountInfoByID then
    local okMount, liveMountID = pcall(C_MountJournal.GetMountFromSpell, spellID)
    liveMountID = okMount and asNumber(liveMountID) or nil
    if liveMountID then
      local result = mountCollectedByMountID(liveMountID)
      Truth._mountBySpellCache[spellID] = result
      return result
    end
  end

  Truth._mountBySpellCache[spellID] = false
  return false
end

local function appearanceCollectedByID(appearanceID)
  appearanceID = asNumber(appearanceID)
  if not appearanceID or not C_TransmogCollection then return false end
  local cached = Truth._appearanceByIDCache[appearanceID]
  if cached ~= nil then return cached and true or false end

  local function finish(v)
    v = v and true or false
    Truth._appearanceByIDCache[appearanceID] = v
    return v
  end

  if C_TransmogCollection.PlayerHasTransmogItemAppearance then
    local ok, known = pcall(C_TransmogCollection.PlayerHasTransmogItemAppearance, appearanceID)
    if ok and known ~= nil then return finish(known) end
  end

  if C_TransmogCollection.GetAppearanceInfoByID then
    local ok, a, b, c, isCollected = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
    if ok and isCollected ~= nil then return finish(isCollected) end
  end

  if C_TransmogCollection.GetAppearanceSources then
    local ok, sources = pcall(C_TransmogCollection.GetAppearanceSources, appearanceID)
    if ok and type(sources) == "table" then
      for _, src in ipairs(sources) do
        if type(src) == "table" and src.isCollected then return finish(true) end
      end
    end
  end

  if C_TransmogCollection.GetAllAppearanceSources and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    local ok, sources = pcall(C_TransmogCollection.GetAllAppearanceSources, appearanceID)
    if ok and type(sources) == "table" then
      for _, sourceID in pairs(sources) do
        sourceID = asNumber(sourceID)
        if sourceID then
          local ok2, known = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
          if ok2 and known then return finish(true) end
        end
      end
    end
  end

  return finish(false)
end

local function modifiedAppearanceCollected(sourceID)
  sourceID = asNumber(sourceID)
  if not sourceID or not C_TransmogCollection then return false end
  local cached = Truth._modifiedAppearanceCache[sourceID]
  if cached ~= nil then return cached and true or false end

  local function finish(v)
    v = v and true or false
    Truth._modifiedAppearanceCache[sourceID] = v
    return v
  end

  if C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
    local ok, known = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
    if ok and known ~= nil then return finish(known) end
  end

  if C_TransmogCollection.GetAppearanceSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
    if ok and type(info) == "table" and info.isCollected ~= nil then return finish(info.isCollected) end
  end

  return finish(false)
end



local function appearanceSourceInfo(sourceID)
  sourceID = asNumber(sourceID)
  if not (sourceID and C_TransmogCollection and C_TransmogCollection.GetAppearanceSourceInfo) then return nil end
  local cached = Truth._appearanceSourceInfoCache[sourceID]
  if cached ~= nil then
    if cached == false then return nil end
    return cached
  end
  local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
  if ok and type(info) == "table" then
    Truth._appearanceSourceInfoCache[sourceID] = info
    return info
  end
  Truth._appearanceSourceInfoCache[sourceID] = false
  return nil
end

local function sourceInfoItemID(info)
  if type(info) ~= "table" then return nil end
  return asNumber(info.itemID or info.sourceItemID or info.itemIDDisplayed or info.itemId)
end

local linkAppearanceTooltipState
local exactSourceCanProveOwnership
local skipExactSourceFallback


-- Exact-link tooltip truth guard.
-- Some modern raid/dungeon rows expose duplicated or misleading source IDs via
-- scanner/generated metadata, while Blizzard's final item hyperlink tooltip
-- still correctly says whether that exact displayed appearance is collected.
-- Read that tooltip data once per itemLink and cache the normalized result.
-- This is intentionally itemLink-scoped and does not scan EJ or walk all rows.
Truth._itemLinkAppearanceTooltipCache = Truth._itemLinkAppearanceTooltipCache or {}
linkAppearanceTooltipState = function(itemLink)
  if type(itemLink) ~= "string" or itemLink == "" then return nil end
  local cached = Truth._itemLinkAppearanceTooltipCache[itemLink]
  if cached ~= nil then return cached end

  local result = { known = false }
  local function scanText(text)
    if type(text) ~= "string" or text == "" then return end
    local lower = string.lower(text)
    if string.find(lower, "haven't collected this appearance", 1, true)
      or string.find(lower, "have not collected this appearance", 1, true) then
      result.known = true
      result.exactAppearanceUncollected = true
    elseif (string.find(lower, "collected this appearance", 1, true)
      and (string.find(lower, "but not from this item", 1, true)
        or string.find(lower, "but not from this source", 1, true)
        or string.find(lower, "from another source", 1, true))) then
      result.known = true
      result.appearanceCollectedViaOtherSource = true
    end
  end

  if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, itemLink)
    if ok and type(data) == "table" and type(data.lines) == "table" then
      for i = 1, #data.lines do
        local line = data.lines[i]
        scanText(type(line) == "table" and line.leftText or nil)
        scanText(type(line) == "table" and line.rightText or nil)
      end
    end
  end

  -- Fallback for clients/builds where C_TooltipInfo does not expose hyperlink
  -- lines.  Keep this private and cached; do not mutate the visible GameTooltip.
  if not result.known and CreateFrame and GameTooltip_SetDefaultAnchor then
    Truth._scanTooltip = Truth._scanTooltip or CreateFrame("GameTooltip", "CollectionLogTruthScanTooltip", nil, "GameTooltipTemplate")
    local tt = Truth._scanTooltip
    if tt and tt.SetOwner and tt.SetHyperlink then
      local ok = pcall(function()
        tt:SetOwner(UIParent or WorldFrame, "ANCHOR_NONE")
        tt:ClearLines()
        tt:SetHyperlink(itemLink)
      end)
      if ok and tt.NumLines then
        local n = tt:NumLines() or 0
        for i = 1, n do
          local left = _G and _G["CollectionLogTruthScanTooltipTextLeft" .. tostring(i)]
          local right = _G and _G["CollectionLogTruthScanTooltipTextRight" .. tostring(i)]
          scanText(left and left.GetText and left:GetText() or nil)
          scanText(right and right.GetText and right:GetText() or nil)
        end
      end
      if tt.Hide then tt:Hide() end
    end
  end

  if not result.known then result = false end
  Truth._itemLinkAppearanceTooltipCache[itemLink] = result
  return result ~= false and result or nil
end

local function collectAppearanceSources(appearanceID)
  appearanceID = asNumber(appearanceID)
  if not (appearanceID and C_TransmogCollection) then return {} end
  local cached = Truth._appearanceSourcesCache[appearanceID]
  if cached ~= nil then return cached end
  local out, seen = {}, {}
  local function addSource(v)
    local sourceID
    local info
    if type(v) == "table" then
      sourceID = asNumber(v.sourceID or v.sourceIDDisplayed or v.itemModifiedAppearanceID or v.sourceIDVisual)
      info = v
    else
      sourceID = asNumber(v)
    end
    if sourceID and not seen[sourceID] then
      seen[sourceID] = true
      info = type(info) == "table" and info or appearanceSourceInfo(sourceID)
      out[#out + 1] = { sourceID = sourceID, info = info }
    end
  end

  if C_TransmogCollection.GetAppearanceSources then
    local ok, sources = pcall(C_TransmogCollection.GetAppearanceSources, appearanceID)
    if ok and type(sources) == "table" then
      for _, src in pairs(sources) do addSource(src) end
    end
  end
  if C_TransmogCollection.GetAllAppearanceSources then
    local ok, sources = pcall(C_TransmogCollection.GetAllAppearanceSources, appearanceID)
    if ok and type(sources) == "table" then
      for _, src in pairs(sources) do addSource(src) end
    end
  end
  Truth._appearanceSourcesCache[appearanceID] = out
  return out
end

local function appearanceCollectionMode(def)
  if type(def) == "table" then
    local override = tostring(def._clogAppearanceModeOverride or "")
    if override == "strict" or override == "shared" then return override end
  end
  if ns and ns.GetAppearanceCollectionMode then
    local ok, mode = pcall(ns.GetAppearanceCollectionMode)
    if ok and (mode == "strict" or mode == "shared") then return mode end
  end
  local mode = CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode or "shared"
  return (mode == "strict") and "strict" or "shared"
end

local function sourceTrust(def)
  if type(def) ~= "table" then return "unknown" end
  local trust = tostring(def._clogSourceTrust or "")
  if trust ~= "" then return trust end
  local meta = type(def._clogStaticMeta) == "table" and def._clogStaticMeta or nil
  if meta and (def.modID or def.sourceID or def.itemModifiedAppearanceID) then return "datapack" end
  if def.itemLink then return "itemLink" end
  return "legacy"
end

exactSourceCanProveOwnership = function(def)
  local trust = sourceTrust(def)
  if trust == "itemLink" or trust == "generatedDB" or trust == "legacy" then return true end
  -- itemLinkAppearance/generatedAppearanceDB can support appearance-family notes,
  -- but not exact modified-source ownership.
  return false
end

local function appearanceCanProveSharedOwnership(def)
  local trust = sourceTrust(def)
  if trust == "itemLink" or trust == "itemLinkAppearance" or trust == "generatedDB" or trust == "generatedAppearanceDB" or trust == "legacy" then return true end
  return false
end

local function appearanceStateCacheKey(def)
  if type(def) ~= "table" then return nil end
  return tostring(appearanceCollectionMode(def)) .. ":"
    .. tostring(def.sourceGroup or "") .. ":"
    .. tostring(def.entryKey or "") .. ":"
    .. tostring(def.itemID or "") .. ":"
    .. tostring(def.appearanceID or def.collectibleID or "") .. ":"
    .. tostring(def.modID or def.sourceID or def.itemModifiedAppearanceID or "") .. ":"
    .. tostring(def.itemLink or "") .. ":"
    .. tostring(sourceTrust(def)) .. ":"
    .. tostring(def._sharedAppearanceUntrusted and 1 or 0) .. ":"
    .. tostring(def._exactSourceUntrusted and 1 or 0)
end

local function skipSharedAppearanceFallback(def)
  if type(def) ~= "table" then return false end
  if def._sharedAppearanceUntrusted == true then return true end
  if def._sharedAppearanceUntrusted == false then return false end
  local meta = type(def._clogStaticMeta) == "table" and def._clogStaticMeta or nil
  return meta and meta.sharedAppearanceUntrusted and true or false
end

skipExactSourceFallback = function(def)
  if type(def) ~= "table" then return false end
  if def._exactSourceUntrusted == true then return true end
  if def._exactSourceUntrusted == false then return false end
  local meta = type(def._clogStaticMeta) == "table" and def._clogStaticMeta or nil
  return meta and meta.exactSourceUntrusted and true or false
end

function Truth.GetAppearanceCollectionState(def)
  if type(def) ~= "table" or tostring(def.type or ""):lower() ~= "appearance" then return nil end
  local cacheKey = appearanceStateCacheKey(def)
  if cacheKey then
    local cached = Truth._appearanceStateCache[cacheKey]
    if cached ~= nil then return cached end
  end

  local mode = appearanceCollectionMode(def)
  local itemID = asNumber(def.itemID)
  local appearanceID = asNumber(def.appearanceID or def.collectibleID)
  local exactModID = asNumber(def.modID or def.sourceID or def.itemModifiedAppearanceID)
  local trust = sourceTrust(def)
  local linkState = linkAppearanceTooltipState(def.itemLink)

  local function finish(state)
    state.collectionMode = mode
    state.sourceTrust = trust
    state.countsAsCollected = state.countsAsCollected and true or false
    -- Back-compat: callers that ask for .collected get the completion-mode
    -- result, while exact source truth remains available as .exactSourceOwned.
    state.collected = state.countsAsCollected
    if cacheKey then Truth._appearanceStateCache[cacheKey] = state end
    return state
  end

  -- If Blizzard's exact displayed hyperlink says the appearance is not collected,
  -- do not let generated/scanner/source-family data overrule that row.  This is
  -- especially important for modern raid difficulty/upgrade variants where
  -- broad appearance families can otherwise bleed into the selected difficulty.
  if type(linkState) == "table" and linkState.exactAppearanceUncollected then
    return finish({
      exactSourceOwned = false,
      sharedAppearanceOwned = false,
      sameItemOtherDifficultyOwned = false,
      appearanceOwnedViaOtherSource = false,
      label = "No",
      note = nil,
      reason = "exact_item_link_tooltip_uncollected",
      countsAsCollected = false,
    })
  end

  -- Exact source owned is the only unconditional green/counting state.
  -- The source must come from a trusted exact row (itemLink/generatedDB/legacy),
  -- not scanner/datapack metadata marked untrusted.
  if exactModID and exactSourceCanProveOwnership(def) and (not skipExactSourceFallback(def)) and modifiedAppearanceCollected(exactModID) then
    return finish({
      exactSourceOwned = true,
      sharedAppearanceOwned = false,
      sameItemOtherDifficultyOwned = false,
      appearanceOwnedViaOtherSource = false,
      label = "Yes",
      note = nil,
      reason = "exact_source_owned_4369_hierarchy",
      countsAsCollected = true,
    })
  end

  if type(linkState) == "table" and linkState.appearanceCollectedViaOtherSource then
    local counts = (mode == "shared")
    return finish({
      exactSourceOwned = false,
      sharedAppearanceOwned = true,
      sameItemOtherDifficultyOwned = false,
      appearanceOwnedViaOtherSource = true,
      label = "Appearance collected via another source",
      note = "Appearance collected via another source",
      reason = counts and "exact_item_link_tooltip_other_source_shared_mode" or "exact_item_link_tooltip_other_source_exact_mode",
      countsAsCollected = counts,
    })
  end

  local sameItemOtherDifficultyOwned = false
  local sharedAppearanceOwned = false
  local unverifiedDifferentSourceOwned = false

  -- v4.3.69 behavior restored: walk Blizzard's appearance source family after
  -- exact source fails, classify exact same item vs. different source item.
  -- Difference from the old build: anonymous/unknown source-item ownership is
  -- tracked for debug but does not count or label positively. That preserves the
  -- user's current Exact/Shared rules and avoids the false green regressions.
  if appearanceID and appearanceCanProveSharedOwnership(def) and (not skipSharedAppearanceFallback(def)) then
    local sources = collectAppearanceSources(appearanceID)
    for i = 1, #sources do
      local sourceID = sources[i].sourceID
      if sourceID and sourceID ~= exactModID and modifiedAppearanceCollected(sourceID) then
        local srcItemID = sourceInfoItemID(sources[i].info)
        if itemID and srcItemID and srcItemID == itemID then
          sameItemOtherDifficultyOwned = true
        elseif srcItemID and itemID and srcItemID ~= itemID then
          sharedAppearanceOwned = true
        else
          unverifiedDifferentSourceOwned = true
        end
      end
    end
  end

  -- Explicit modifiedAppearanceID families remain the source for same-item /
  -- other-difficulty notes. This is the old working behavior and does not make
  -- the active row count as collected.
  if not sharedAppearanceOwned then
    local raw = type(def.raw) == "table" and def.raw or nil
    local mods = nil
    if raw then
      mods = raw.modifiedAppearanceIDs or raw.modIDs
      if not mods and raw.debug and raw.debug.appearance then mods = raw.debug.appearance.modifiedAppearanceIDs end
    end
    if type(mods) == "table" then
      for _, modID in pairs(mods) do
        modID = asNumber(modID)
        if modID and modID ~= exactModID and modifiedAppearanceCollected(modID) then
          sameItemOtherDifficultyOwned = true
          break
        end
      end
    end
  end

  if sharedAppearanceOwned then
    local counts = (mode == "shared")
    return finish({
      exactSourceOwned = false,
      sharedAppearanceOwned = true,
      sameItemOtherDifficultyOwned = sameItemOtherDifficultyOwned,
      appearanceOwnedViaOtherSource = true,
      unverifiedDifferentSourceOwned = unverifiedDifferentSourceOwned,
      label = "Appearance collected via another source",
      note = "Appearance collected via another source",
      reason = counts and "verified_different_source_shared_mode_4369_hierarchy" or "verified_different_source_exact_mode_4369_hierarchy",
      countsAsCollected = counts,
    })
  end

  if sameItemOtherDifficultyOwned then
    return finish({
      exactSourceOwned = false,
      sharedAppearanceOwned = false,
      sameItemOtherDifficultyOwned = true,
      appearanceOwnedViaOtherSource = false,
      unverifiedDifferentSourceOwned = unverifiedDifferentSourceOwned,
      label = "Collected on another difficulty",
      note = "Collected on another difficulty",
      reason = "same_item_other_difficulty_informational_4369_hierarchy",
      countsAsCollected = false,
    })
  end

  return finish({
    exactSourceOwned = false,
    sharedAppearanceOwned = false,
    sameItemOtherDifficultyOwned = false,
    appearanceOwnedViaOtherSource = false,
    unverifiedDifferentSourceOwned = unverifiedDifferentSourceOwned,
    label = "No",
    note = nil,
    reason = unverifiedDifferentSourceOwned and "unverified_different_source_ignored_4369_hierarchy" or "no_owned_source_found_4369_hierarchy",
    countsAsCollected = false,
  })
end

local function appearanceCollected(def)
  if type(def) ~= "table" then return false end

  local state = Truth.GetAppearanceCollectionState and Truth.GetAppearanceCollectionState(def)
  if type(state) == "table" then
    if state.countsAsCollected ~= nil then return state.countsAsCollected and true or false end
    if state.collected ~= nil then return state.collected and true or false end
  end

  -- Fallback only for non-row/static definitions that cannot provide a
  -- difficulty-specific source.  Prefer exact/shared source state whenever it
  -- is available so same-item different-difficulty ownership does not inflate
  -- totals.
  local modID = asNumber(def.modID or def.sourceID or def.itemModifiedAppearanceID)
  if modID and (not skipExactSourceFallback(def)) and modifiedAppearanceCollected(modID) then return true end

  local id = asNumber(def.collectibleID or def.appearanceID)
  if id then return appearanceCollectedByID(id) end
  return false
end


function Truth.GetItemCollectionState(itemID, groupOrKey)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  local def
  if groupOrKey and ns.Registry and ns.Registry.GetItemDefinitionForGroup then
    def = ns.Registry.GetItemDefinitionForGroup(itemID, groupOrKey)
  elseif ns.Registry and ns.Registry.GetItemDefinition then
    def = ns.Registry.GetItemDefinition(itemID)
  end
  if type(def) ~= "table" then return nil end

  local t = tostring(def.type or ""):lower()
  if t == "appearance" and Truth.GetAppearanceCollectionState then
    local state = Truth.GetAppearanceCollectionState(def)
    if type(state) == "table" then
      state.def = def
      state.itemID = state.itemID or def.itemID or itemID
      return state, def
    end
  end

  local collected = Truth.IsCollected(def) and true or false
  return {
    exactSourceOwned = collected,
    sharedAppearanceOwned = false,
    sameItemOtherDifficultyOwned = false,
    appearanceOwnedViaOtherSource = false,
    label = collected and "Yes" or "No",
    note = nil,
    reason = collected and "non_appearance_collected" or "non_appearance_not_collected",
    countsAsCollected = collected,
    collected = collected,
    def = def,
    itemID = def.itemID or itemID,
    type = t,
  }, def
end

function Truth.IsDisplayCollected(def)
  if type(def) ~= "table" then return false end
  local t = tostring(def.type or ""):lower()
  if t == "appearance" and Truth.GetAppearanceCollectionState then
    local state = Truth.GetAppearanceCollectionState(def)
    if type(state) == "table" and state.countsAsCollected ~= nil then
      return state.countsAsCollected and true or false
    end
  end
  return Truth.IsCollected(def) and true or false
end

function Truth.IsExactCollected(def)
  if type(def) ~= "table" then return false end
  local t = tostring(def.type or ""):lower()
  if t == "appearance" then
    local state = Truth.GetAppearanceCollectionState and Truth.GetAppearanceCollectionState(def)
    if type(state) == "table" then
      if state.countsAsCollected ~= nil then return state.countsAsCollected and true or false end
      if state.collected ~= nil then return state.collected and true or false end
    end
  end
  return Truth.IsCollected(def)
end

local function truthDefCacheKey(def)
  if type(def) ~= "table" then return nil end
  local t = tostring(def.type or "")
  local modePart = (t:lower() == "appearance") and (":" .. tostring(appearanceCollectionMode(def)) .. ":" .. tostring(sourceTrust(def))) or ""
  return t .. ":" .. tostring(def.identityType or "") .. ":" .. tostring(def.sourceGroup or "") .. ":" .. tostring(def.entryKey or "") .. ":" .. tostring(def.itemID or "") .. ":" .. tostring(def.collectibleID or "") .. ":" .. tostring(def.appearanceID or "") .. ":" .. tostring(def.modID or def.sourceID or def.itemModifiedAppearanceID or "") .. modePart
end

function Truth.IsCollected(def)
  if type(def) ~= "table" then return false end

  local key = truthDefCacheKey(def)
  if key then
    local cached = Truth._isCollectedCache[key]
    if cached ~= nil then return cached and true or false end
  end

  local result = false
  local t = tostring(def.type or ""):lower()
  local id = asNumber(def.collectibleID)
  if t == "mount" then
    if (def.identityType == "mountSpellID" and id) or (id and id > 1000) then result = mountCollectedBySpell(id)
    elseif def.identityType == "mountID" and id then result = mountCollectedByMountID(id)
    elseif ns.IsMountCollected and def.itemID then result = ns.IsMountCollected(def.itemID) and true or false end
  elseif t == "pet" then
    if id and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
      local ok, owned = pcall(C_PetJournal.GetNumCollectedInfo, id)
      result = ok and tonumber(owned or 0) > 0 or false
    end
  elseif t == "toy" then
    local itemID = asNumber(def.itemID) or id
    if ns.IsToyCollected and itemID then result = ns.IsToyCollected(itemID) and true or false
    elseif PlayerHasToy and itemID then local ok, has = pcall(PlayerHasToy, itemID); result = ok and has or false end
  elseif t == "housing" then
    local itemID = asNumber(def.itemID) or id
    if ns.IsHousingCollected and itemID then result = ns.IsHousingCollected(itemID) and true or false end
  elseif t == "appearance" then
    result = appearanceCollected(def)
  end

  result = result and true or false
  if key then Truth._isCollectedCache[key] = result end
  return result
end
