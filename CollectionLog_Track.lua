-- CollectionLog_Track.lua
local ADDON, ns = ...
local function Print(msg)
  if ns and ns.Print then
    ns.Print(msg)
  elseif print then
    print(msg)
  end
end


-- =======================================
-- Popup Debug (opt-in)
-- =======================================
local function PopupDebugLog(line)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.debug = CollectionLogDB.debug or {}
  CollectionLogDB.debug.popup = CollectionLogDB.debug.popup or { enabled = false, lines = {} }
  local d = CollectionLogDB.debug.popup
  if not d.enabled then return end
  local t = date("%H:%M:%S")
  local msg = "[CL PopDebug " .. t .. "] " .. tostring(line)
  table.insert(d.lines, 1, msg)
  if #d.lines > 40 then
    table.remove(d.lines)
  end
  if ns and ns.Print then
    ns.Print(msg)
  else
    print(msg)
  end
end

ns.PopupDebugLog = PopupDebugLog

ns._newCollectionBaseline = ns._newCollectionBaseline or { track = false, housing = false, ready = false }

local function _CL_ResetNewCollectionBaseline()
  ns._newCollectionBaseline = { track = false, housing = false, ready = false }
end

local function _CL_IsNewCollectionBaselineReady()
  local state = ns and ns._newCollectionBaseline or nil
  return type(state) == "table" and state.ready == true
end

local function _CL_TryFinalizeNewCollectionBaseline()
  local state = ns and ns._newCollectionBaseline or nil
  if type(state) ~= "table" or state.ready then return end
  if state.track and state.housing then
    state.ready = true
    PopupDebugLog("New collection baseline ready")
    if ns and ns.EndSyntheticCollectionSuppression then
      pcall(ns.EndSyntheticCollectionSuppression, "baseline_ready")
    end
  end
end

local function _CL_MarkNewCollectionBaselineComponentReady(component)
  if type(component) ~= "string" or component == "" then return end
  ns._newCollectionBaseline = ns._newCollectionBaseline or { track = false, housing = false, ready = false }
  ns._newCollectionBaseline[component] = true
  _CL_TryFinalizeNewCollectionBaseline()
end

local function _CL_ShouldAllowNewCollectionSideEffects(meta)
  if not _CL_IsNewCollectionBaselineReady() then
    return false
  end
  if ns and ns.ShouldSuppressSyntheticCollectionSideEffects and ns.ShouldSuppressSyntheticCollectionSideEffects(meta) then
    return false
  end
  return true
end

local function CL_AddChatMessage(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(tostring(msg))
  elseif ns and ns.Print then
    ns.Print(msg)
  elseif print then
    print(msg)
  end
end

local function CL_SafeCall(fn, ...)
  if type(fn) ~= "function" then return false end
  local ok = pcall(fn, ...)
  return ok
end

local function CL_GetDifficultyChatLabel(difficultyID)
  difficultyID = tonumber(difficultyID)
  if difficultyID == 16 or difficultyID == 8 or difficultyID == 23 then return "Mythic" end
  if difficultyID == 15 or difficultyID == 2 or difficultyID == 5 or difficultyID == 6 then return "Heroic" end
  if difficultyID == 14 or difficultyID == 1 or difficultyID == 3 or difficultyID == 4 or difficultyID == 9 then return "Normal" end
  if difficultyID == 17 or difficultyID == 7 then return "Raid Finder" end
  if difficultyID == 24 then return "Timewalking" end
  if GetDifficultyInfo and difficultyID then
    local ok, name = pcall(GetDifficultyInfo, difficultyID)
    if ok and name and name ~= "" then
      return tostring(name)
    end
  end
  return tostring(difficultyID or "?")
end

local function CL_IsRaidDungeonGroup(g)
  if type(g) ~= "table" then return false end
  local cat = tostring(g.category or g.parentCategory or ""):lower()
  return cat == "raids" or cat == "dungeons"
end

local function CL_GetGroupDisplayLabel(g)
  if type(g) ~= "table" then return nil end
  local name = g.name or g.label or g.title
  if not name or name == "" then return nil end
  local label = tostring(name)
  if CL_IsRaidDungeonGroup(g) and g.difficultyID then
    label = ("%s (%s)"):format(label, tostring(CL_GetDifficultyChatLabel(g.difficultyID)))
  end
  return label
end

local function CL_GroupContainsValue(list, needle)
  if type(list) ~= "table" or needle == nil then return false end
  needle = tonumber(needle) or needle
  for _, v in ipairs(list) do
    local cmp = tonumber(v) or v
    if cmp == needle then
      return true
    end
  end
  return false
end

local function CL_GetPreferredSourceContext(opts)
  opts = type(opts) == "table" and opts or nil
  local ctx = opts and opts.sourceContext
  if type(ctx) == "table" and (ctx.ejInstanceID or ctx.mapID) and ctx.difficultyID then
    return ctx
  end

  local active = ns and ns._activeRun or nil
  if type(active) == "table" and (active.ejInstanceID or active.mapID) and active.difficultyID then
    return {
      mapID = tonumber(active.mapID),
      ejInstanceID = tonumber(active.ejInstanceID),
      difficultyID = tonumber(active.difficultyID),
      instanceName = active.instanceName and tostring(active.instanceName) or nil,
      difficultyName = active.difficultyName and tostring(active.difficultyName) or nil,
      sourceLabel = active.sourceLabel and tostring(active.sourceLabel) or nil,
    }
  end

  local recent = ns and ns._lastLootSourceContext or nil
  if type(recent) == "table" then
    local age = 999999
    if GetTime and recent.t then
      local ok, now = pcall(GetTime)
      if ok and type(now) == "number" then
        age = now - recent.t
      end
    end

    local inInstance, instanceType = IsInInstance and IsInInstance() or false, nil
    local currentDifficultyID, currentMapID
    if inInstance and GetInstanceInfo then
      local _, itype, did, _, _, _, _, mapID = GetInstanceInfo()
      instanceType = itype
      currentDifficultyID = tonumber(did)
      currentMapID = tonumber(mapID)
    end

    local sameInstance = false
    if (instanceType == "party" or instanceType == "raid") and currentDifficultyID and currentMapID then
      if tonumber(recent.mapID) == currentMapID and tonumber(recent.difficultyID) == currentDifficultyID then
        sameInstance = true
      end
    end

    if age <= 30 and sameInstance and (recent.ejInstanceID or recent.mapID) and recent.difficultyID then
      return recent
    end
  end

  return nil
end

local function CL_CopySourceContext(ctx)
  if type(ctx) ~= "table" then return nil end
  return {
    mapID = tonumber(ctx.mapID),
    ejInstanceID = tonumber(ctx.ejInstanceID),
    difficultyID = tonumber(ctx.difficultyID),
    instanceName = ctx.instanceName and tostring(ctx.instanceName) or nil,
    difficultyName = ctx.difficultyName and tostring(ctx.difficultyName) or nil,
    sourceLabel = ctx.sourceLabel and tostring(ctx.sourceLabel) or nil,
    t = ctx.t,
  }
end

local function CL_ApplySourceContext(meta, ctx)
  meta = type(meta) == "table" and meta or {}
  local copy = CL_CopySourceContext(ctx or CL_GetPreferredSourceContext(meta))
  if copy then meta.sourceContext = copy end
  return meta
end

local function CL_FindExactSourceGroupForCollectible(itemID, mountID, speciesID, opts)
  if not (ns and ns.Data and type(ns.Data.groups) == "table") then return nil end
  local ctx = CL_GetPreferredSourceContext(opts)
  if type(ctx) ~= "table" then return nil end

  local wantDifficultyID = tonumber(ctx.difficultyID)
  local wantInstanceID = tonumber(ctx.ejInstanceID)
  local wantMapID = tonumber(ctx.mapID)
  if not wantDifficultyID then return nil end

  for _, g in pairs(ns.Data.groups) do
    if type(g) == "table" and CL_IsRaidDungeonGroup(g) then
      local gDifficultyID = tonumber(g.difficultyID)
      local gInstanceID = tonumber(g.instanceID)
      local gMapID = tonumber(g.mapID)
      local instanceMatch = false
      if wantInstanceID and gInstanceID and wantInstanceID == gInstanceID then
        instanceMatch = true
      elseif wantMapID and gMapID and wantMapID == gMapID then
        instanceMatch = true
      elseif wantMapID and gInstanceID and wantMapID == gInstanceID then
        instanceMatch = true
      elseif wantInstanceID and gMapID and wantInstanceID == gMapID then
        instanceMatch = true
      end

      if instanceMatch and gDifficultyID == wantDifficultyID then
        local matched = false
        if itemID and (CL_GroupContainsValue(g.items, itemID) or CL_GroupContainsValue(g.itemIDs, itemID) or CL_GroupContainsValue(g.itemLinks, itemID)) then
          matched = true
        elseif mountID and CL_GroupContainsValue(g.mounts, mountID) then
          matched = true
        elseif speciesID and CL_GroupContainsValue(g.pets, speciesID) then
          matched = true
        end
        if matched then
          return g
        end
      end
    end
  end

  return nil
end

local function CL_FindSourceGroupForCollectible(kindLabel, itemID, mountID, speciesID, opts)
  if not (ns and ns.Data and type(ns.Data.groups) == "table") then return nil end

  local exactMatch = CL_FindExactSourceGroupForCollectible(itemID, mountID, speciesID, opts)
  if exactMatch then return exactMatch end

  local bestMatch, fallbackMatch
  for _, g in pairs(ns.Data.groups) do
    if type(g) == "table" then
      local matched = false
      if itemID and (CL_GroupContainsValue(g.items, itemID) or CL_GroupContainsValue(g.itemIDs, itemID) or CL_GroupContainsValue(g.itemLinks, itemID)) then
        matched = true
      elseif mountID and CL_GroupContainsValue(g.mounts, mountID) then
        matched = true
      elseif speciesID and CL_GroupContainsValue(g.pets, speciesID) then
        matched = true
      end

      if matched then
        if CL_IsRaidDungeonGroup(g) then
          return g
        end
        fallbackMatch = fallbackMatch or g
        local cat = tostring(g.category or ""):lower()
        if not bestMatch and (cat == "mounts" or cat == "pets" or cat == "toys" or cat == "housing") then
          bestMatch = g
        end
      end
    end
  end

  return bestMatch or fallbackMatch
end

local function CL_IsCountedCoreLootItem(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return true end

  -- Mirror the UI collectables-only filter for raid/dungeon loot so chat totals
  -- stay aligned with the visible grid/header counts.
  if C_MountJournal then
    if C_MountJournal.GetMountFromItem then
      local ok, mountID = pcall(C_MountJournal.GetMountFromItem, itemID)
      if ok and mountID and mountID ~= 0 then return true end
    end
    if C_MountJournal.GetMountFromItemID then
      local ok, a, b = pcall(C_MountJournal.GetMountFromItemID, itemID)
      if ok then
        local mountID = (a and a ~= 0 and a) or (b and b ~= 0 and b) or nil
        if mountID then return true end
      end
    end
    if C_MountJournal.GetMountIDFromItemID then
      local ok, mountID = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
      if ok and mountID and mountID ~= 0 then return true end
    end
  end

  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local ok, speciesID = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
    if ok and speciesID and speciesID ~= 0 then return true end
  end

  if C_ToyBox then
    if C_ToyBox.GetToyFromItemID then
      local ok, toyID = pcall(C_ToyBox.GetToyFromItemID, itemID)
      if ok and toyID and toyID ~= 0 then return true end
    elseif C_ToyBox.GetToyInfo then
      local ok, toyName = pcall(C_ToyBox.GetToyInfo, itemID)
      if ok and toyName then return true end
    end
  end

  if ns and ns.GetHousingDecorRecordID then
    local ok, decorID = pcall(ns.GetHousingDecorRecordID, itemID)
    if ok and decorID and decorID ~= 0 then return true end
  end

  if ns and ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get then
    local ok, appearanceData = pcall(ns.CompletionAppearanceItemDB.Get, itemID)
    if ok and type(appearanceData) == "table" and tonumber(appearanceData.appearanceID or 0) > 0 then
      return true
    end
  end

  return false
end

local function CL_IsGroupItemCollected(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return false end

  if ns and ns.IsMountCollected and ns.IsMountCollected(itemID) then return true end
  if ns and ns.IsPetCollected and ns.IsPetCollected(itemID) then return true end
  if ns and ns.IsToyCollected and ns.IsToyCollected(itemID) then return true end
  if ns and ns.IsAppearanceCollected and ns.IsAppearanceCollected(itemID) then return true end

  local sec = (ns and ns.GetItemSectionFast and ns.GetItemSectionFast(itemID)) or nil
  if sec == "Mounts" then
    return (ns and ns.IsMountCollected and ns.IsMountCollected(itemID)) or false
  elseif sec == "Pets" then
    return (ns and ns.IsPetCollected and ns.IsPetCollected(itemID)) or false
  elseif sec == "Toys" then
    return (ns and ns.IsToyCollected and ns.IsToyCollected(itemID)) or false
  end

  return (ns and ns.IsCollected and ns.IsCollected(itemID)) or false
end

local function CL_GetGroupProgressForChat(g)
  if type(g) ~= "table" then return nil, nil end
  local total, collected = 0, 0
  local seen = {}

  local function consider(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 or seen[itemID] then return end
    seen[itemID] = true
    if CL_IsRaidDungeonGroup(g) and not CL_IsCountedCoreLootItem(itemID) then return end
    total = total + 1
    if CL_IsGroupItemCollected(itemID) then
      collected = collected + 1
    end
  end

  if CL_IsRaidDungeonGroup(g) then
    if type(g.items) == "table" then
      for _, id in ipairs(g.items) do consider(id) end
    elseif type(g.itemIDs) == "table" then
      for _, id in ipairs(g.itemIDs) do consider(id) end
    elseif type(g.itemLinks) == "table" then
      for _, id in ipairs(g.itemLinks) do consider(id) end
    end
  else
    if type(g.items) == "table" then
      for _, id in ipairs(g.items) do consider(id) end
    end
    if type(g.itemIDs) == "table" then
      for _, id in ipairs(g.itemIDs) do consider(id) end
    end
    if total == 0 and type(g.itemLinks) == "table" then
      for _, id in ipairs(g.itemLinks) do consider(id) end
    end
  end

  return collected, total
end

local function CL_EmitNewCollectionChatMessage(kindLabel, name, sourceLabel, progressLabel)
  local prefix = "|cff00ff99Collection Log|r"
  local action = "|cff40ff40New collection:|r"
  local kind = kindLabel and (" |cffffff00[" .. tostring(kindLabel) .. "]|r") or ""
  local msg = ("%s %s%s |cffffffff%s|r"):format(prefix, action, kind, tostring(name))
  if sourceLabel and sourceLabel ~= "" then
    msg = msg .. " |cffffffff-|r |cffffffff" .. tostring(sourceLabel) .. "|r"
  end
  if progressLabel then
    msg = msg .. " |cffffff00" .. progressLabel .. "|r"
  end
  CL_AddChatMessage(msg)
end

local function CL_FlushBufferedNewCollectionMessages(groupKey)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._pendingChatCollectionBatches = CollectionLogDB._pendingChatCollectionBatches or {}
  local batch = CollectionLogDB._pendingChatCollectionBatches[groupKey]
  if type(batch) ~= "table" then return end
  CollectionLogDB._pendingChatCollectionBatches[groupKey] = nil

  local entries = type(batch.entries) == "table" and batch.entries or {}
  local sourceGroup = batch.sourceGroup
  local sourceLabel = batch.sourceLabel
  local finalCollected, total = CL_GetGroupProgressForChat(sourceGroup)
  finalCollected = tonumber(finalCollected) or 0
  total = tonumber(total) or 0
  local count = #entries
  local startCollected = math.max(0, finalCollected - count)

  for i, entry in ipairs(entries) do
    local progressLabel
    if total > 0 then
      progressLabel = ("(%d/%d)"):format(startCollected + i, total)
    end
    CL_EmitNewCollectionChatMessage(entry.kindLabel, entry.name, sourceLabel, progressLabel)
  end
end

local function CL_PrintNewCollection(kindLabel, name, opts)
  local ok, err = pcall(function()
    if not name or name == "" then name = "Unknown" end
    opts = type(opts) == "table" and opts or nil
    local sourceGroup = CL_FindSourceGroupForCollectible(kindLabel, opts and opts.itemID, opts and opts.mountID, opts and opts.speciesID, opts)
    local sourceLabel = CL_GetGroupDisplayLabel(sourceGroup)

    if sourceGroup and CL_IsRaidDungeonGroup(sourceGroup) then
      local _, total = CL_GetGroupProgressForChat(sourceGroup)
      total = tonumber(total) or 0
      if total > 0 then
        CollectionLogDB = CollectionLogDB or {}
        CollectionLogDB._pendingChatCollectionBatches = CollectionLogDB._pendingChatCollectionBatches or {}
        local groupKey = tostring(sourceGroup.id or sourceGroup.instanceID or sourceLabel or "unknown_group")
        local batch = CollectionLogDB._pendingChatCollectionBatches[groupKey]
        if type(batch) ~= "table" then
          batch = {
            sourceGroup = sourceGroup,
            sourceLabel = sourceLabel,
            entries = {},
          }
          CollectionLogDB._pendingChatCollectionBatches[groupKey] = batch
          if C_Timer and C_Timer.After then
            C_Timer.After(0.20, function()
              local okFlush, flushErr = pcall(CL_FlushBufferedNewCollectionMessages, groupKey)
              if not okFlush and ns and ns._debug and ns._debug.popup then
                PopupDebugLog("CL_FlushBufferedNewCollectionMessages failed: " .. tostring(flushErr))
              end
            end)
          else
            CL_FlushBufferedNewCollectionMessages(groupKey)
          end
        end
        table.insert(batch.entries, {
          kindLabel = kindLabel,
          name = tostring(name),
        })
        return
      end
    end

    local progressLabel
    if sourceGroup then
      local collected, total = CL_GetGroupProgressForChat(sourceGroup)
      if total and total > 0 then
        progressLabel = ("(%d/%d)"):format(tonumber(collected) or 0, tonumber(total) or 0)
      end
    end

    CL_EmitNewCollectionChatMessage(kindLabel, name, sourceLabel, progressLabel)
  end)
  if not ok and ns and ns._debug and ns._debug.popup then
    PopupDebugLog("CL_PrintNewCollection failed: " .. tostring(err))
  end
end

local function CL_GetInstanceName(instanceID, mapID)
  instanceID = tonumber(instanceID)
  mapID = tonumber(mapID)

  if ns and ns.Data and type(ns.Data.groups) == "table" and instanceID then
    for _, g in pairs(ns.Data.groups) do
      if type(g) == "table" and tonumber(g.instanceID) == instanceID then
        local title = g.name or g.label or g.title
        if title and title ~= "" then
          return tostring(title)
        end
      end
    end
  end

  if instanceID and EJ_GetInstanceInfo then
    local ok, name = pcall(EJ_GetInstanceInfo, instanceID)
    if ok and name and name ~= "" then
      return tostring(name)
    end
  end

  if mapID and C_Map and C_Map.GetMapInfo then
    local ok, info = pcall(C_Map.GetMapInfo, mapID)
    if ok and info and info.name and info.name ~= "" then
      return tostring(info.name)
    end
  end

  return "Unknown Instance"
end

local function CL_PrintCompletionUpdate(instanceID, difficultyID, mapID, newCount)
  local ok, err = pcall(function()
    local instanceName = CL_GetInstanceName(instanceID, mapID)
    local difficultyLabel = CL_GetDifficultyChatLabel(difficultyID)
    local prefix = "|cff00ff99Collection Log|r"
    local action = "|cff40ff40Completion logged:|r"
    CL_AddChatMessage(("%s %s |cffffffff%s (%s)|r — total completions: |cffffff00%d|r"):format(
      prefix,
      action,
      tostring(instanceName),
      tostring(difficultyLabel),
      tonumber(newCount) or 0
    ))
  end)
  if not ok and ns and ns._debug and ns._debug.popup then
    PopupDebugLog("CL_PrintCompletionUpdate failed: " .. tostring(err))
  end
end

-- ============================================================
-- Pass 2: Real-time "New Collection" triggers (Blizzard-truthful)
--
-- Goals:
--   * Fire popup for Mounts / Pets / Toys / tracked Items (raid/dungeon loot)
--   * ONLY when the collectible exists in Collection Log data (no noise)
--   * Avoid heuristics: confirm collection via Blizzard APIs and/or your
--     existing CollectionLog item record state.
-- ============================================================

-- =======================================
-- Helpers
-- =======================================
local function GetItemIDFromLink(link)
  if not link then return nil end
  -- Works for item links and some battlepet links; we only care about items for now.
  local itemID = link:match("item:(%d+)")
  if itemID then return tonumber(itemID) end

  -- Fallback: try GetItemInfoInstant on the link (safe)
  local id = GetItemInfoInstant(link)
  if id then return id end
  return nil
end

local function GetQuantityFromLootMsg(msg)
  -- Many loot messages end with "xN"
  local qty = msg:match("x(%d+)")
  if qty then return tonumber(qty) end
  return 1
end

-- =======================================
-- Loot message filtering
--
-- CHAT_MSG_LOOT includes other players' loot messages ("X receives loot: ...").
-- We only want to record items the *player* obtained.
--
-- We do this using Blizzard's own localized global strings for self-loot
-- patterns, so we don't hardcode English phrasing.
-- =======================================
local _selfLootPatterns

local function _MakeLootPattern(fmt)
  if type(fmt) ~= "string" or fmt == "" then return nil end

  -- Replace format tokens with sentinels, escape Lua pattern characters,
  -- then expand sentinels into permissive patterns.
  local p = fmt
  p = p:gsub("%%s", "\001S\001")
  p = p:gsub("%%d", "\001D\001")
  p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("\001S\001", ".+")
  p = p:gsub("\001D\001", "%%d+")

  return "^" .. p .. "$"
end

local function _BuildSelfLootPatterns()
  if _selfLootPatterns then return end
  _selfLootPatterns = {}

  -- Common self-loot patterns (localized): loot, pushed loot, multiple stacks.
  local candidates = {
    _G.LOOT_ITEM_SELF,
    _G.LOOT_ITEM_SELF_MULTIPLE,
    _G.LOOT_ITEM_PUSHED_SELF,
    _G.LOOT_ITEM_PUSHED_SELF_MULTIPLE,
  }

  for _, fmt in ipairs(candidates) do
    local pat = _MakeLootPattern(fmt)
    if pat then
      table.insert(_selfLootPatterns, pat)
    end
  end
end

local function IsLootMessageForPlayer(event, msg)
  if event ~= "CHAT_MSG_LOOT" then return true end
  if type(msg) ~= "string" or msg == "" then return false end

  _BuildSelfLootPatterns()
  if _selfLootPatterns then
    for _, pat in ipairs(_selfLootPatterns) do
      if msg:match(pat) then
        return true
      end
    end
  end

  -- Fallback (rare clients / missing globals): only accept explicit "You..." lines.
  -- This is intentionally conservative to prevent false positives.
  return msg:match("^You ") ~= nil
end

-- ============================================================
-- Tracked lookup caches
--
-- We only want to trigger "New Collection" for collectibles that
-- exist inside Collection Log's current group index.
--
-- These caches are rebuilt opportunistically (on first use and whenever
-- ns.RebuildGroupIndex() runs).
-- ============================================================
local function RebuildTrackedCaches()
  ns._tracked = ns._tracked or {}
  ns._tracked.items = {}
  ns._tracked.mounts = {}
  ns._tracked.mountItems = {}
  ns._tracked.mountItemToMount = {}
  ns._tracked.mountItemByMount = {}
  ns._tracked.pets = {}
  ns._tracked.petItems = {}
  ns._tracked.petItemToSpecies = {}
  ns._tracked.petItemBySpecies = {}
  ns._tracked.toys = {}

  if not (ns.Data and ns.Data.groups) then return end

  for _, g in pairs(ns.Data.groups) do
    if type(g) == "table" then
      if type(g.items) == "table" then
        for _, itemID in ipairs(g.items) do
          if type(itemID) == "number" and itemID > 0 then
            ns._tracked.items[itemID] = true
          end
        end
      end
      if type(g.mounts) == "table" then
        for _, mountID in ipairs(g.mounts) do
          if type(mountID) == "number" and mountID > 0 then
            ns._tracked.mounts[mountID] = true
          end
        end
      end
      if type(g.pets) == "table" then
        for _, speciesID in ipairs(g.pets) do
          if type(speciesID) == "number" and speciesID > 0 then
            ns._tracked.pets[speciesID] = true
          end
        end
      end
    end
  end

  -- Derive tracked conversion item sets from tracked itemIDs.
  -- Prefer the addon's static completion DBs so we do not hammer Blizzard APIs
  -- across the full raid/dungeon dataset during login or pack rebuilds.
  if ns._tracked.items then
    for itemID in pairs(ns._tracked.items) do
      local handled = false

      local toyRow = ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) or nil
      if toyRow then
        ns._tracked.toys[itemID] = true
        handled = true
      end

      local mountRow = ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
      if mountRow and tonumber(mountRow.mountID) and tonumber(mountRow.mountID) > 0 then
        local mountID = tonumber(mountRow.mountID)
        -- Promote item-derived mount mappings into the journal-event tracked set.
        -- NEW_MOUNT_ADDED only reports mountID, so item-only tracking can otherwise miss popups.
        ns._tracked.mounts[mountID] = true
        ns._tracked.mountItems[itemID] = true
        ns._tracked.mountItemToMount[itemID] = mountID
        if ns._tracked.mountItemByMount[mountID] == nil then
          ns._tracked.mountItemByMount[mountID] = itemID
        end
        handled = true
      end

      local petRow = ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
      if petRow and tonumber(petRow.speciesID) and tonumber(petRow.speciesID) > 0 then
        local speciesID = tonumber(petRow.speciesID)
        -- Promote item-derived pet mappings into the journal-event tracked set.
        -- NEW_PET_ADDED / PET_JOURNAL events report species, not the teaching item.
        ns._tracked.pets[speciesID] = true
        ns._tracked.petItems[itemID] = true
        ns._tracked.petItemToSpecies[itemID] = speciesID
        if ns._tracked.petItemBySpecies[speciesID] == nil then
          ns._tracked.petItemBySpecies[speciesID] = itemID
        end
        handled = true
      end

      if not handled then
        if C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(itemID) then
          ns._tracked.toys[itemID] = true
        end
        local mountID = GetMountIDFromItemID_Safe and GetMountIDFromItemID_Safe(itemID) or nil
        if mountID then
          ns._tracked.mounts[mountID] = true
          ns._tracked.mountItems[itemID] = true
          ns._tracked.mountItemToMount[itemID] = mountID
          if ns._tracked.mountItemByMount[mountID] == nil then
            ns._tracked.mountItemByMount[mountID] = itemID
          end
        end
        local speciesID = GetSpeciesIDFromItemID_Safe and GetSpeciesIDFromItemID_Safe(itemID) or nil
        if speciesID then
          ns._tracked.pets[speciesID] = true
          ns._tracked.petItems[itemID] = true
          ns._tracked.petItemToSpecies[itemID] = speciesID
          if ns._tracked.petItemBySpecies[speciesID] == nil then
            ns._tracked.petItemBySpecies[speciesID] = itemID
          end
        end
      end
    end
  end
end

local function EnsureTrackedCaches()
  if not (ns._tracked and ns._tracked.items) then
    RebuildTrackedCaches()
  end
end

-- Rebuild tracked caches any time the addon rebuilds its group index.
if hooksecurefunc and ns and ns.RebuildGroupIndex then
  pcall(hooksecurefunc, ns, "RebuildGroupIndex", function()
    RebuildTrackedCaches()
  end)
end

local function IsTrackedItem(itemID)
  if not itemID then return false end
  EnsureTrackedCaches()
  return ns._tracked and ns._tracked.items and ns._tracked.items[itemID] or false
end

local function IsTrackedToy(itemID)
  if not itemID then return false end
  EnsureTrackedCaches()
  return ns._tracked and ns._tracked.toys and ns._tracked.toys[itemID] or false
end

local function IsTrackedMount(mountID)
  if not mountID then return false end
  EnsureTrackedCaches()
  return ns._tracked and ns._tracked.mounts and ns._tracked.mounts[mountID] or false
end

local function IsTrackedMountItem(itemID)
  if not itemID then return false end
  EnsureTrackedCaches()
  return ns._tracked and ns._tracked.mountItems and ns._tracked.mountItems[itemID] or false
end

local function IsTrackedPet(speciesID)
  if not speciesID then return false end
  EnsureTrackedCaches()
  return ns._tracked and ns._tracked.pets and ns._tracked.pets[speciesID] or false
end

-- =======================================
-- Identify conversion items (mount/pet/toy)
-- =======================================
local function IsToyItem(itemID)
  if not itemID or itemID <= 0 then return false end
  if C_ToyBox and C_ToyBox.GetToyInfo then
    local ok, name = pcall(C_ToyBox.GetToyInfo, itemID)
    if ok and name then return true end
  end
  if C_ToyBox and C_ToyBox.GetToyFromItemID then
    local ok, toyID = pcall(C_ToyBox.GetToyFromItemID, itemID)
    if ok and toyID then return true end
  end
  return false
end

local function GetMountIDFromItemID_Safe(itemID)
  if not itemID or itemID <= 0 then return nil end
  if ns and ns.GetMountIDFromItemID then
    local ok, mid = pcall(ns.GetMountIDFromItemID, itemID)
    if ok and tonumber(mid) and tonumber(mid) > 0 then
      return tonumber(mid)
    end
  end
  if C_MountJournal and C_MountJournal.GetMountFromItem then
    local ok, mid = pcall(C_MountJournal.GetMountFromItem, itemID)
    if ok and tonumber(mid) and tonumber(mid) > 0 then
      return tonumber(mid)
    end
  end
  return nil
end

local function GetSpeciesIDFromItemID_Safe(itemID)
  if not itemID or itemID <= 0 then return nil end
  if ns and ns._tracked and ns._tracked.petItemToSpecies and ns._tracked.petItemToSpecies[itemID] then
    return ns._tracked.petItemToSpecies[itemID]
  end
  local explicit = ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
  if explicit and tonumber(explicit.speciesID) and tonumber(explicit.speciesID) > 0 then
    return tonumber(explicit.speciesID)
  end
  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local ok, speciesID = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
    if ok and tonumber(speciesID) and tonumber(speciesID) > 0 then
      return tonumber(speciesID)
    end
  end
  return nil
end

local function GetTrackedMountItemIDByMountID(mountID)
  mountID = tonumber(mountID)
  if not mountID or mountID <= 0 then return nil end
  EnsureTrackedCaches()
  ns._popupMountItemByMountID = ns._popupMountItemByMountID or {}
  local cached = ns._popupMountItemByMountID[mountID]
  if cached ~= nil then return cached or nil end

  local direct = ns and ns._tracked and ns._tracked.mountItemByMount and ns._tracked.mountItemByMount[mountID] or nil
  if direct then
    ns._popupMountItemByMountID[mountID] = direct
    return direct
  end

  local tracked = ns and ns._tracked and ns._tracked.mountItems or nil
  if type(tracked) == "table" then
    for itemID in pairs(tracked) do
      itemID = tonumber(itemID)
      if itemID and itemID > 0 then
        local mid = GetMountIDFromItemID_Safe(itemID)
        if mid == mountID then
          ns._popupMountItemByMountID[mountID] = itemID
          return itemID
        end
      end
    end
  end

  ns._popupMountItemByMountID[mountID] = false
  return nil
end

local function GetTrackedPetItemIDBySpeciesID(speciesID)
  speciesID = tonumber(speciesID)
  if not speciesID or speciesID <= 0 then return nil end
  EnsureTrackedCaches()
  ns._popupPetItemBySpeciesID = ns._popupPetItemBySpeciesID or {}
  local cached = ns._popupPetItemBySpeciesID[speciesID]
  if cached ~= nil then return cached or nil end

  local direct = ns and ns._tracked and ns._tracked.petItemBySpecies and ns._tracked.petItemBySpecies[speciesID] or nil
  if direct then
    ns._popupPetItemBySpeciesID[speciesID] = direct
    return direct
  end

  local tracked = ns and ns._tracked and ns._tracked.items or nil
  if type(tracked) == "table" then
    for itemID in pairs(tracked) do
      itemID = tonumber(itemID)
      if itemID and itemID > 0 then
        local sid = GetSpeciesIDFromItemID_Safe(itemID)
        if sid == speciesID then
          ns._popupPetItemBySpeciesID[speciesID] = itemID
          return itemID
        end
      end
    end
  end

  ns._popupPetItemBySpeciesID[speciesID] = false
  return nil
end

-- =======================================
-- Recording
-- =======================================
function ns.RecordObtained(itemID, quantity, source)
  if not itemID or itemID <= 0 then return end
  if not IsTrackedItem(itemID) then return end

  ns.EnsureCharacterRecord()
  local guid = ns.GetPlayerGUID()
  if not guid then return end

  quantity = quantity or 1
  if quantity < 1 then quantity = 1 end

  local c = CollectionLogDB.characters[guid]
  c.items = c.items or {}

  local rec = c.items[itemID]
  local now = time()

  if not rec then
    rec = { count = 0, firstTime = now, lastTime = now, source = source }
    c.items[itemID] = rec
  end

  rec.count = (rec.count or 0) + quantity
  rec.lastTime = now
  if not rec.firstTime then rec.firstTime = now end
  if source then rec.source = source end

  -- Light cache (optional): itemOwners
  CollectionLogDB.itemOwners[itemID] = CollectionLogDB.itemOwners[itemID] or {}
  CollectionLogDB.itemOwners[itemID][guid] = true

  -- If UI is open, coalesce visible grid refreshes to avoid repaint churn during loot bursts.
  if ns.UI and ns.UI.ScheduleGridRefreshDebounced and ns.UI.frame and ns.UI.frame:IsShown() then
    ns.UI.ScheduleGridRefreshDebounced()
  elseif ns.UI and ns.UI.RefreshGrid and ns.UI.frame and ns.UI.frame:IsShown() then
    ns.UI.RefreshGrid()
  end
end

-- =======================================
-- Loot/Purchase detection (chat-based)
-- =======================================
local f = CreateFrame("Frame")

-- Disable chat-based tracking in Challenge Mode / Mythic+ to avoid taint.
local function IsChallengeModeActiveSafe()
  if C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive then
    local ok, active = pcall(C_ChallengeMode.IsChallengeModeActive)
    if ok and active then return true end
  end
  return false
end

local function SetChatTrackingEnabled(enabled)
  if not f then return end
  f:UnregisterAllEvents()
  if enabled then
    -- Track player loot messages (primary source for item-based collections).
    f:RegisterEvent("CHAT_MSG_LOOT")
  end
end

-- NOTE:
-- CHAT_MSG_LOOT is the best single “OSRS-like” source: it fires for looting and many purchases.
-- We’ll expand later for edge cases (mailbox, quest rewards, crafting, etc.).

do
  local _, instanceType = IsInInstance()
  if instanceType == "pvp" or instanceType == "arena" then
    SetChatTrackingEnabled(false)
  else
    SetChatTrackingEnabled(not IsChallengeModeActiveSafe())
  end
end


local function _CL_HandleLootChat(self, event, ...)
  -- Never parse loot chat in PvP instances; chat payloads can be protected "secret strings".
  local _, _instanceType = IsInInstance()
  if _instanceType == "pvp" or _instanceType == "arena" then return end

  local msg = select(1, ...)
  if not msg or type(msg) ~= "string" then return end

  -- Some chat payloads (notably in PvP instances) can be "secret strings" that error on pattern/compare operations.
  local okStr = pcall(function() return msg:sub(1, 1) end)
  if not okStr then return end

  -- CHAT_MSG_LOOT includes loot lines for other players in your group.
  -- Only accept messages that correspond to the player obtaining the item.
  local okIsLoot, isForPlayer = pcall(IsLootMessageForPlayer, event, msg)
  if not okIsLoot or not isForPlayer then return end

  -- Extract item link (first link in the message)
  local link = msg:match("(|c%x%x%x%x%x%x%x%x|Hitem:.-|h%[.-%]|h|r)")
  if not link then
    -- Sometimes links appear without color codes; catch raw |Hitem:
    link = msg:match("(|Hitem:.-|h%[.-%]|h)")
  end
  if not link then return end

  local itemID = GetItemIDFromLink(link)
  if not itemID then return end

  local qty = GetQuantityFromLootMsg(msg)

  do
    local inInstance = IsInInstance()
    local _, instanceType, instDifficultyID, _, _, _, _, instanceMapID = GetInstanceInfo()
    if inInstance and (instanceType == "party" or instanceType == "raid") then
      local mapID = tonumber(instanceMapID)
      local did = tonumber(instDifficultyID)
      if mapID and did and ns then
        local active = ns._activeRun or nil
        local ejInstanceID = (type(active) == "table" and tonumber(active.ejInstanceID)) or mapID
        local instanceName = CL_GetInstanceName(ejInstanceID, mapID)
        local difficultyName = CL_GetDifficultyChatLabel(did)
        local sourceLabel = instanceName or nil
        if sourceLabel and difficultyName and difficultyName ~= "" then
          sourceLabel = tostring(sourceLabel) .. " - " .. tostring(difficultyName)
        end
        ns._lastLootSourceContext = {
          mapID = mapID,
          ejInstanceID = ejInstanceID,
          difficultyID = did,
          instanceName = instanceName,
          difficultyName = difficultyName,
          sourceLabel = sourceLabel,
          t = (GetTime and GetTime()) or 0,
        }
      end
    end
  end
  local lootSourceContext = CL_CopySourceContext(ns and ns._lastLootSourceContext)

  -- Only react to items that are in Collection Log.
  -- We still record counts (below) for tracked items only.
  local isTracked = IsTrackedItem(itemID)

  -- OSRS-style popup when a *new* collectible is learned/collected
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}

  local function MarkSeen(key)
    CollectionLogDB._seenNewPopups[key] = true
  end
  local function Seen(key)
    return CollectionLogDB._seenNewPopups[key] and true or false
  end

  local itemName = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID))
  local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))

  local didPopup = false

  -- Tracked Items (raid/dungeon loot etc.)
  -- Popup should ONLY fire when the *account* gains a new appearance from this item.
  -- IMPORTANT: do NOT treat conversion collectibles (toy/mount/pet items) as transmog.
  if not didPopup and isTracked and ns and ns.HasCollectedAppearance then
    -- Skip conversion items entirely (they are handled by NEW_TOY_ADDED / NEW_MOUNT_ADDED / NEW_PET_ADDED).
    local isToy = IsToyItem(itemID)
    local mountFromItem = GetMountIDFromItemID_Safe(itemID)
    local speciesFromItem = GetSpeciesIDFromItemID_Safe(itemID)
    if isToy or mountFromItem or speciesFromItem then
      PopupDebugLog("Skip appearance check for conversion item itemID=" .. itemID .. " toy=" .. tostring(isToy) .. " mountID=" .. tostring(mountFromItem) .. " speciesID=" .. tostring(speciesFromItem))
    else
      local wasCollected = ns.HasCollectedAppearance(itemID) == true
      PopupDebugLog("Loot itemID=" .. itemID .. " wasCollected=" .. tostring(wasCollected))
      if not wasCollected then
        -- Some unlocks are delayed (especially mass-loot / BoE vendor / cache misses).
        -- Try a small fixed set of retries (NO loops): 0.35s, 0.9s, 1.8s
        CollectionLogDB = CollectionLogDB or {}
        CollectionLogDB._pendingAppearanceChecks = CollectionLogDB._pendingAppearanceChecks or {}
        local token = (CollectionLogDB._pendingAppearanceChecks[itemID] or 0) + 1
        CollectionLogDB._pendingAppearanceChecks[itemID] = token

        local function Attempt(attemptN)
          if not (ns and ns.HasCollectedAppearance) then return end
          -- If a newer loot line for the same itemID arrived, abandon this attempt.
          if CollectionLogDB._pendingAppearanceChecks[itemID] ~= token then return end

          local nowCollected = ns.HasCollectedAppearance(itemID) == true
          PopupDebugLog("Appearance attempt " .. attemptN .. " itemID=" .. itemID .. " nowCollected=" .. tostring(nowCollected))
          if not nowCollected then return false end

          CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
          local key = "appearance_item:" .. tostring(itemID)
          if CollectionLogDB._seenNewPopups[key] then
            PopupDebugLog("Already seen popup key=" .. key)
            return true
          end
          if not _CL_ShouldAllowNewCollectionSideEffects({ type = "appearance", itemID = itemID }) then
            CollectionLogDB._seenNewPopups[key] = true
            PopupDebugLog("Suppressed appearance popup until baseline itemID=" .. tostring(itemID))
            return true
          end
          CollectionLogDB._seenNewPopups[key] = true

          local itemName2 = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID)) or "New appearance"
          local icon2 = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))
          if ns and ns.ShowNewCollectionPopup then
            ns.ShowNewCollectionPopup(itemName2, icon2, "Transmog", CL_ApplySourceContext({ type = "appearance", itemID = itemID, itemLink = link, isNew = true, source = "appearance_flip" }, lootSourceContext))
            CL_PrintNewCollection("Appearance", itemName2, { itemID = itemID })
            PopupDebugLog("Fired appearance popup itemID=" .. itemID)
          end
          return true
        end

        local delays = { 0.35, 0.90, 1.80 }
        for i, d in ipairs(delays) do
          C_Timer.After(d, function()
            -- Attempt; if it succeeds we don't need later ones.
            if Attempt(i) then
              -- Invalidate token so later timers no-op.
              if CollectionLogDB and CollectionLogDB._pendingAppearanceChecks then
                CollectionLogDB._pendingAppearanceChecks[itemID] = -1
              end
            end
          end)
        end
      end
    end
  end

  -- Source tagging (optional): rough labels
  -- Later we can detect instance/encounter/vendor specifics.
  local source = "obtained"

  if isTracked then
    ns.RecordObtained(itemID, qty, source)
  end
end


f:SetScript("OnEvent", function(self, event, ...)
  -- Harden against taint/protected payloads: never allow this handler to hard-error.
  pcall(_CL_HandleLootChat, self, event, ...)
end)

local _CL_InitKnownToys
local _CL_TakeBagSnapshot
local _CL_CollectNewBagToyCandidates
local _CL_QueueToyCandidate
local _CL_FireToyPopup
local _CL_VerifyToyCandidates
local _CL_QueueToyVerification
local _CL_InitKnownMounts
local _CL_InitKnownPets
local _CL_CollectNewBagMountPetCandidates
local _CL_QueueMountCandidateByItem
local _CL_QueueMountCandidateByMountID
local _CL_QueuePetCandidateByItem
local _CL_QueuePetCandidateBySpeciesID
local _CL_FireMountPopupByMountID
local _CL_FirePetPopupBySpeciesID
local _CL_VerifyMountCandidates
local _CL_VerifyPetCandidates
local _CL_QueueMountVerification
local _CL_QueuePetVerification
local _CL_QueueAllUnknownTrackedMounts
local _CL_QueueAllUnknownTrackedPets
local _CL_QueueAllUnknownTrackedMountItems
local _CL_MountBootstrapPending = true

-- Targeted collection/clear event diagnostics.
-- Use /clogeventdiag on before testing a stubborn raid/loot event.
local function CL_EventDiagEnabled()
  return ns and ns._debug and ns._debug.events == true
end

local function CL_EventDiag(msg)
  if CL_EventDiagEnabled() and Print then
    Print("EventDiag: " .. tostring(msg))
  end
end

local function _CL_ClearMountQueues()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountCandidateQueue = {}
  CollectionLogDB._mountItemCandidateQueue = {}
end

local function _CL_FinishMountBootstrap()
  _CL_ClearMountQueues()
  _CL_MountBootstrapPending = false
end

local _CL_LastMountUsabilityVerify = 0
local _CL_MountUsabilityRetryPending = false

local function _CL_NowSeconds()
  if GetTime then return GetTime() end
  return 0
end

function ns.BeginSyntheticCollectionSuppression(seconds, reason)
  seconds = tonumber(seconds) or 0
  local untilTs = _CL_NowSeconds() + seconds
  if untilTs > (tonumber(ns._suppressSyntheticCollectionsUntil) or 0) then
    ns._suppressSyntheticCollectionsUntil = untilTs
  end
  ns._suppressSyntheticCollectionsReason = reason or ns._suppressSyntheticCollectionsReason or "synthetic"
end

function ns.EndSyntheticCollectionSuppression(reason)
  ns._suppressSyntheticCollectionsUntil = 0
  if reason then ns._suppressSyntheticCollectionsReason = reason end
end

function ns.ShouldSuppressSyntheticCollectionSideEffects(meta)
  if type(meta) == "table" and meta.preview == true then return false end
  local now = _CL_NowSeconds()
  if (tonumber(ns._suppressSyntheticCollectionsUntil) or 0) > now then
    return true
  end
  if ns and ns.UI and ns.UI._clogRefreshRun and ns.UI._clogRefreshRun.running then
    return true
  end
  return false
end

local function _CL_HandleMountUsabilityChanged()
  if _CL_MountBootstrapPending then return end

  local now = (GetTime and GetTime()) or 0
  if _CL_LastMountUsabilityVerify > 0 and (now - _CL_LastMountUsabilityVerify) < 2.0 then
    return
  end
  _CL_LastMountUsabilityVerify = now

  local db = CollectionLogDB or {}
  local hasMountCandidates = (type(db._mountCandidateQueue) == "table" and next(db._mountCandidateQueue) ~= nil)
    or (type(db._mountItemCandidateQueue) == "table" and next(db._mountItemCandidateQueue) ~= nil)
  if not hasMountCandidates then return end

  _CL_QueueMountVerification("mount_journal_usability")

  if (not _CL_MountUsabilityRetryPending) and C_Timer and C_Timer.After then
    _CL_MountUsabilityRetryPending = true
    C_Timer.After(1.50, function()
      _CL_MountUsabilityRetryPending = false
      pcall(_CL_VerifyMountCandidates, "mount_journal_usability_retry")
    end)
  end
end

-- =======================================
-- Mount + Pet journal events
-- =======================================
local tf = CreateFrame("Frame")
local jf = CreateFrame("Frame")
jf:RegisterEvent("NEW_MOUNT_ADDED")
jf:RegisterEvent("NEW_PET_ADDED")
jf:RegisterEvent("NEW_TOY_ADDED")
pcall(jf.RegisterEvent, jf, "COMPANION_LEARNED")
pcall(jf.RegisterEvent, jf, "MOUNT_JOURNAL_USABILITY_CHANGED")
pcall(jf.RegisterEvent, jf, "PET_JOURNAL_LIST_UPDATE")

tf:RegisterEvent("PLAYER_LOGIN")
tf:RegisterEvent("BAG_UPDATE_DELAYED")
tf:RegisterEvent("QUEST_TURNED_IN")
tf:RegisterEvent("MERCHANT_CLOSED")
pcall(tf.RegisterEvent, tf, "MAIL_CLOSED")
pcall(tf.RegisterEvent, tf, "AUCTION_HOUSE_CLOSED")

local _CL_DeferredWarmupQueued = false

function ns.TriggerDeferredWarmup(reason)
  if _CL_DeferredWarmupQueued then return false end
  _CL_DeferredWarmupQueued = true
  if ns and ns.ProfilePrint then ns.ProfilePrint("Deferred warmup queued reason=" .. tostring(reason or "unknown")) end

  local function queueTask(key, delay, fn)
    if ns and ns.ScheduleStartupTask then
      pcall(ns.ScheduleStartupTask, key, delay, fn)
    elseif C_Timer and C_Timer.After then
      C_Timer.After(delay or 0, function() pcall(fn) end)
    else
      pcall(fn)
    end
  end

  queueTask("core_prime_collections", 0.00, function()
    if ns and ns.PrimeCollectionsWarmupOnce then pcall(ns.PrimeCollectionsWarmupOnce) end
  end)
  queueTask("housing_known_refresh", 0.02, function() pcall(_CL_InitHousingKnown, true) end)
  queueTask("housing_lazy_reconcile", 0.05, function() pcall(_CL_RunHousingSilentReconcile, "lazy_warmup", 60) end)
  queueTask("track_mount_refresh", 0.08, function()
    pcall(_CL_InitKnownMounts, true)
    if ns and ns.StartCollectibleResolverWarmup then
      pcall(ns.StartCollectibleResolverWarmup, 0.05)
    end
  end)
  queueTask("track_mount_recheck", 0.12, function() pcall(_CL_InitKnownMounts, true) end)

  if ns and ns.RequestStartupCoordinatorStart then
    pcall(ns.RequestStartupCoordinatorStart, 0)
  end
  return true
end

tf:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    _CL_ResetNewCollectionBaseline()
    if ns and ns.ProfilePrint then ns.ProfilePrint("Track PLAYER_LOGIN begin") end
    if ns and ns.BeginSyntheticCollectionSuppression then pcall(ns.BeginSyntheticCollectionSuppression, 3, "login_minimal_bootstrap") end
    _CL_MountBootstrapPending = true
    _CL_ClearMountQueues()
    pcall(_CL_InitKnownToys)
    pcall(_CL_InitKnownPets)
    pcall(_CL_TakeBagSnapshot)
    pcall(_CL_InitKnownMounts, true)
    pcall(_CL_FinishMountBootstrap)
    _CL_MarkNewCollectionBaselineComponentReady("track")
    if ns and ns.ProfilePrint then ns.ProfilePrint("Track PLAYER_LOGIN minimal bootstrap complete") end
    if ns and ns.ProfilePrint then ns.ProfilePrint("Track PLAYER_LOGIN end") end
    return
  end

  if event == "BAG_UPDATE_DELAYED" then
    pcall(_CL_CollectNewBagMountPetCandidates, "bag_update")
    pcall(_CL_CollectNewBagToyCandidates, "bag_update")
    _CL_QueueToyVerification("bag_update")
    _CL_QueueMountVerification("bag_update")
    _CL_QueuePetVerification("bag_update")
    return
  end

  if event == "QUEST_TURNED_IN" or event == "MERCHANT_CLOSED" or event == "MAIL_CLOSED" or event == "AUCTION_HOUSE_CLOSED" then
    local reason = string.lower(event)
    pcall(_CL_CollectNewBagMountPetCandidates, reason)
    pcall(_CL_CollectNewBagToyCandidates, reason)
    _CL_QueueToyVerification(reason)
    _CL_QueueMountVerification(reason)
    _CL_QueuePetVerification(reason)
    return
  end
end)

local function SafeMountPopup(mountID)
  if _CL_MountBootstrapPending then return false end
  if not mountID or mountID <= 0 then return false end
  if not IsTrackedMount(mountID) then return false end
  if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return false end

  local ok, name, spellID, icon, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
  if not ok or not isCollected then return false end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
  local key = "mount:" .. tostring(mountID)
  if CollectionLogDB._seenNewPopups[key] then
    return true
  end
  if not _CL_ShouldAllowNewCollectionSideEffects({ type = "mount", mountID = mountID }) then
    CollectionLogDB._seenNewPopups[key] = true
    PopupDebugLog("Suppressed mount popup until baseline mountID=" .. tostring(mountID))
    return true
  end
  CollectionLogDB._seenNewPopups[key] = true

  local itemID = GetTrackedMountItemIDByMountID(mountID)
  local itemLink = itemID and select(2, GetItemInfo(itemID)) or nil
  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name or "New mount", icon, "Mount", CL_ApplySourceContext({ type = "mount", itemID = itemID, itemLink = itemLink, mountID = mountID, spellID = spellID, isNew = true }))
    CL_PrintNewCollection("Mount", name or "New mount", { itemID = itemID, mountID = mountID })
  end
  return true
end

local function TryMountPopupWithRetry(mountID, attempt)
  attempt = attempt or 0
  if SafeMountPopup(mountID) then return end
  if attempt >= 5 then return end

  if C_Timer and C_Timer.After then
    local delays = { 0.20, 0.50, 1.00, 2.00, 3.00 }
    local delay = delays[attempt + 1] or 1.00
    C_Timer.After(delay, function()
      TryMountPopupWithRetry(mountID, attempt + 1)
    end)
  end
end

local function SafePetPopup(petGUID)
  if not petGUID or petGUID == "" then return end
  if not (C_PetJournal and C_PetJournal.GetPetInfoByPetID and C_PetJournal.GetPetInfoBySpeciesID) then return end

  local ok, name, speciesID = pcall(C_PetJournal.GetPetInfoByPetID, petGUID)
  if not ok then return end
  speciesID = tonumber(speciesID)
  if not speciesID or speciesID <= 0 then return end
  if not IsTrackedPet(speciesID) then return end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
  local key = "pet:" .. tostring(speciesID)
  if CollectionLogDB._seenNewPopups[key] then return true end
  if not _CL_ShouldAllowNewCollectionSideEffects({ type = "pet", speciesID = speciesID }) then
    CollectionLogDB._seenNewPopups[key] = true
    PopupDebugLog("Suppressed pet popup until baseline speciesID=" .. tostring(speciesID))
    return true
  end
  CollectionLogDB._seenNewPopups[key] = true

  local icon
  local ok2, sname, sicon = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
  if ok2 and sname and sname ~= "" then name = sname end
  if ok2 then icon = sicon end

  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name or "New pet", icon, "Pet", CL_ApplySourceContext({ type = "pet", speciesID = speciesID, petGUID = petGUID, isNew = true }))
    CL_PrintNewCollection("Pet", name or "New pet", { itemID = GetTrackedPetItemIDBySpeciesID(speciesID), speciesID = speciesID })
  end
  if ns and ns.UI and ns.UI.UpdateOverviewPetsFromCollection then
    pcall(ns.UI.UpdateOverviewPetsFromCollection, speciesID)
  end
  return true
end

local function TryPetPopupWithRetry(petGUID, attempt)
  attempt = attempt or 0
  if SafePetPopup(petGUID) then return end
  if attempt >= 5 then return end

  if C_Timer and C_Timer.After then
    local delays = { 0.20, 0.50, 1.00, 2.00, 3.00 }
    local delay = delays[attempt + 1] or 1.00
    C_Timer.After(delay, function()
      TryPetPopupWithRetry(petGUID, attempt + 1)
    end)
  end
end

-- =======================================
-- Toy non-drop popup detection (Phase 2A)
-- =======================================

local function _CL_GetBagItemCounts()
  local counts = {}
  local numSlotsFunc = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
  local itemInfoFunc = C_Container and C_Container.GetContainerItemInfo or GetContainerItemInfo
  if not numSlotsFunc or not itemInfoFunc then return counts end

  for bag = 0, 4 do
    local okSlots, numSlots = pcall(numSlotsFunc, bag)
    numSlots = tonumber(numSlots) or 0
    if okSlots and numSlots > 0 then
      for slot = 1, numSlots do
        local okInfo, info = pcall(itemInfoFunc, bag, slot)
        if okInfo and info then
          local itemID, stackCount
          if type(info) == "table" then
            itemID = tonumber(info.itemID)
            stackCount = tonumber(info.stackCount or info.stackCount or info.count)
          end
          if (not itemID or itemID <= 0) and GetContainerItemID then
            local okID, maybeID = pcall(GetContainerItemID, bag, slot)
            if okID and maybeID then itemID = tonumber(maybeID) end
          end
          if itemID and itemID > 0 then
            counts[itemID] = (counts[itemID] or 0) + (stackCount or 1)
          end
        end
      end
    end
  end

  return counts
end

_CL_QueueToyCandidate = function(itemID, reason)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return end
  if not IsTrackedToy(itemID) then return end
  if not IsToyItem(itemID) then return end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._toyCandidateQueue = CollectionLogDB._toyCandidateQueue or {}
  local q = CollectionLogDB._toyCandidateQueue
  q[itemID] = reason or q[itemID] or "candidate"
end

_CL_InitKnownToys = function()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._toyKnownCollected = CollectionLogDB._toyKnownCollected or {}
  if CollectionLogDB._toyKnownInit then return end
  if not (ns and ns.IsToyCollected) then return end

  EnsureTrackedCaches()
  local known = CollectionLogDB._toyKnownCollected
  local tracked = ns._tracked and ns._tracked.toys or nil
  if type(tracked) == "table" then
    for itemID in pairs(tracked) do
      if ns.IsToyCollected(itemID) then
        known[itemID] = true
      end
    end
  end
  CollectionLogDB._toyKnownInit = true
end

_CL_TakeBagSnapshot = function()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._toyBagSnapshot = _CL_GetBagItemCounts()
end

_CL_CollectNewBagToyCandidates = function(reason)
  CollectionLogDB = CollectionLogDB or {}
  local prev = CollectionLogDB._toyBagSnapshot or {}
  local now = _CL_GetBagItemCounts()

  for itemID, count in pairs(now) do
    local old = tonumber(prev[itemID]) or 0
    if count > old then
      _CL_QueueToyCandidate(itemID, reason or "bag_delta")
    end
  end

  CollectionLogDB._toyBagSnapshot = now
end

_CL_FireToyPopup = function(itemID, reason)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return end
  if not IsTrackedToy(itemID) then return end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
  local key = "toy:" .. tostring(itemID)
  if CollectionLogDB._seenNewPopups[key] then return end
  if not _CL_ShouldAllowNewCollectionSideEffects({ type = "toy", itemID = itemID }) then
    CollectionLogDB._seenNewPopups[key] = true
    PopupDebugLog("Suppressed toy popup until baseline itemID=" .. tostring(itemID))
    return
  end
  CollectionLogDB._seenNewPopups[key] = true

  local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID))
  if type(name) ~= "string" or name == "" then
    local toyName = (C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(itemID))
    if type(toyName) == "string" and toyName ~= "" then
      name = toyName
    else
      name = "New toy"
    end
  end
  local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))
  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name, icon, "Toy", CL_ApplySourceContext({ type = "toy", itemID = itemID, isNew = true, source = reason or "toy_state_flip" }))
    CL_PrintNewCollection("Toy", name, { itemID = itemID })
  end
end

_CL_VerifyToyCandidates = function(reason)
  _CL_InitKnownToys()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._toyKnownCollected = CollectionLogDB._toyKnownCollected or {}
  CollectionLogDB._toyCandidateQueue = CollectionLogDB._toyCandidateQueue or {}

  if not (ns and ns.IsToyCollected) then return end

  local known = CollectionLogDB._toyKnownCollected
  local q = CollectionLogDB._toyCandidateQueue
  local processedAny = false

  for itemID, queuedReason in pairs(q) do
    processedAny = true
    if ns.IsToyCollected(itemID) then
      if not known[itemID] then
        known[itemID] = true
        _CL_FireToyPopup(itemID, queuedReason or reason or "toy_verify")
        PopupDebugLog("Toy state flip popup itemID=" .. tostring(itemID) .. " reason=" .. tostring(queuedReason or reason))
      else
        known[itemID] = true
      end
      q[itemID] = nil
    end
  end

  if processedAny and reason then
    PopupDebugLog("Toy verify processed reason=" .. tostring(reason))
  end
end

_CL_QueueToyVerification = function(reason)
  local delays = { 0.10, 0.50, 1.20 }
  for _, d in ipairs(delays) do
    C_Timer.After(d, function()
      pcall(_CL_VerifyToyCandidates, reason)
    end)
  end
end

-- =======================================
-- Mount + Pet non-drop popup detection (Phase 2B/2C)
-- =======================================

_CL_InitKnownMounts = function(force)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountKnownCollected = CollectionLogDB._mountKnownCollected or {}
  CollectionLogDB._mountItemKnownCollected = CollectionLogDB._mountItemKnownCollected or {}
  if CollectionLogDB._mountKnownInit and not force then return end

  EnsureTrackedCaches()
  local known = CollectionLogDB._mountKnownCollected
  local itemKnown = CollectionLogDB._mountItemKnownCollected
  local tracked = ns._tracked and ns._tracked.mounts or nil
  if type(tracked) == "table" and C_MountJournal and C_MountJournal.GetMountInfoByID then
    for mountID in pairs(tracked) do
      local ok, _, _, _, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
      if ok and isCollected then
        known[mountID] = true
      end
    end
  end
  local trackedItems = ns._tracked and ns._tracked.mountItems or nil
  if type(trackedItems) == "table" and ns and ns.IsMountCollected then
    for itemID in pairs(trackedItems) do
      if ns.IsMountCollected(itemID) then
        itemKnown[itemID] = true
      end
    end
  end
  CollectionLogDB._mountKnownInit = true
end

_CL_InitKnownPets = function()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._petKnownCollected = CollectionLogDB._petKnownCollected or {}
  if CollectionLogDB._petKnownInit then return end

  EnsureTrackedCaches()
  local known = CollectionLogDB._petKnownCollected
  local tracked = ns._tracked and ns._tracked.pets or nil
  if type(tracked) == "table" and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
    for speciesID in pairs(tracked) do
      local ok, owned = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
      if ok and tonumber(owned) and tonumber(owned) > 0 then
        known[speciesID] = true
      end
    end
  end
  CollectionLogDB._petKnownInit = true
end

_CL_QueueMountCandidateByMountID = function(mountID, reason)
  mountID = tonumber(mountID)
  if not mountID or mountID <= 0 then return end
  if not IsTrackedMount(mountID) then return end
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountCandidateQueue = CollectionLogDB._mountCandidateQueue or {}
  CollectionLogDB._mountCandidateQueue[mountID] = reason or CollectionLogDB._mountCandidateQueue[mountID] or "candidate"
end

_CL_QueueMountCandidateByItem = function(itemID, reason)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return end
  if not IsTrackedMountItem(itemID) then return end
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountItemCandidateQueue = CollectionLogDB._mountItemCandidateQueue or {}
  CollectionLogDB._mountItemCandidateQueue[itemID] = reason or CollectionLogDB._mountItemCandidateQueue[itemID] or "candidate"

  local mountID = GetMountIDFromItemID_Safe(itemID)
  if mountID then
    _CL_QueueMountCandidateByMountID(mountID, reason)
  end
end

_CL_QueuePetCandidateBySpeciesID = function(speciesID, reason)
  speciesID = tonumber(speciesID)
  if not speciesID or speciesID <= 0 then return end
  if not IsTrackedPet(speciesID) then return end
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._petCandidateQueue = CollectionLogDB._petCandidateQueue or {}
  CollectionLogDB._petCandidateQueue[speciesID] = reason or CollectionLogDB._petCandidateQueue[speciesID] or "candidate"
end

_CL_QueuePetCandidateByItem = function(itemID, reason)
  local speciesID = GetSpeciesIDFromItemID_Safe(itemID)
  if speciesID then
    _CL_QueuePetCandidateBySpeciesID(speciesID, reason)
  end
end

_CL_QueueAllUnknownTrackedMounts = function(reason)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountKnownCollected = CollectionLogDB._mountKnownCollected or {}
  EnsureTrackedCaches()
  local known = CollectionLogDB._mountKnownCollected
  local tracked = ns and ns._tracked and ns._tracked.mounts or nil
  if type(tracked) ~= "table" then return end
  for mountID in pairs(tracked) do
    mountID = tonumber(mountID)
    if mountID and mountID > 0 and not known[mountID] then
      _CL_QueueMountCandidateByMountID(mountID, reason or "journal_scan")
    end
  end
end

_CL_QueueAllUnknownTrackedMountItems = function(reason)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountItemKnownCollected = CollectionLogDB._mountItemKnownCollected or {}
  EnsureTrackedCaches()
  local known = CollectionLogDB._mountItemKnownCollected
  local tracked = ns and ns._tracked and ns._tracked.mountItems or nil
  if type(tracked) ~= "table" then return end
  for itemID in pairs(tracked) do
    itemID = tonumber(itemID)
    if itemID and itemID > 0 and not known[itemID] then
      _CL_QueueMountCandidateByItem(itemID, reason or "journal_scan")
    end
  end
end

_CL_QueueAllUnknownTrackedPets = function(reason)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._petKnownCollected = CollectionLogDB._petKnownCollected or {}
  EnsureTrackedCaches()
  local known = CollectionLogDB._petKnownCollected
  local tracked = ns and ns._tracked and ns._tracked.pets or nil
  if type(tracked) ~= "table" then return end
  for speciesID in pairs(tracked) do
    speciesID = tonumber(speciesID)
    if speciesID and speciesID > 0 and not known[speciesID] then
      _CL_QueuePetCandidateBySpeciesID(speciesID, reason or "journal_scan")
    end
  end
end

_CL_CollectNewBagMountPetCandidates = function(reason)
  CollectionLogDB = CollectionLogDB or {}
  local prev = CollectionLogDB._toyBagSnapshot or {}
  local now = _CL_GetBagItemCounts()

  for itemID, count in pairs(now) do
    local old = tonumber(prev[itemID]) or 0
    if count > old then
      _CL_QueueMountCandidateByItem(itemID, reason or "bag_delta")
      _CL_QueuePetCandidateByItem(itemID, reason or "bag_delta")
    end
  end
end

_CL_FireMountPopupByItemID = function(itemID, reason)
  if _CL_MountBootstrapPending then return end
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return end
  if not IsTrackedMountItem(itemID) then return end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
  local mountID = GetMountIDFromItemID_Safe(itemID)
  local key = mountID and ("mount:" .. tostring(mountID)) or ("mountitem:" .. tostring(itemID))
  if CollectionLogDB._seenNewPopups[key] then return end
  if not _CL_ShouldAllowNewCollectionSideEffects({ type = "mount", itemID = itemID, mountID = mountID }) then
    CollectionLogDB._seenNewPopups[key] = true
    PopupDebugLog("Suppressed mount item popup until baseline itemID=" .. tostring(itemID) .. " mountID=" .. tostring(mountID))
    return
  end

  local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID)) or "New mount"
  local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))
  if mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
    local ok, mname, _, micon = pcall(C_MountJournal.GetMountInfoByID, mountID)
    if ok then
      if type(mname) == "string" and mname ~= "" then name = mname end
      if micon then icon = micon end
    end
  end

  CollectionLogDB._seenNewPopups[key] = true
  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name, icon, "Mount", CL_ApplySourceContext({ type = "mount", itemID = itemID, mountID = mountID, isNew = true, source = reason or "mount_state_flip" }))
    CL_PrintNewCollection("Mount", name, { itemID = itemID, mountID = mountID })
  end
  PopupDebugLog("Mount state flip popup itemID=" .. tostring(itemID) .. " mountID=" .. tostring(mountID) .. " reason=" .. tostring(reason))
end

_CL_FireMountPopupByMountID = function(mountID, reason)
  if SafeMountPopup(mountID) then
    PopupDebugLog("Mount state flip popup mountID=" .. tostring(mountID) .. " reason=" .. tostring(reason))
  end
end

_CL_FirePetPopupBySpeciesID = function(speciesID, reason)
  speciesID = tonumber(speciesID)
  if not speciesID or speciesID <= 0 then return end
  if not IsTrackedPet(speciesID) then return end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
  local key = "pet:" .. tostring(speciesID)
  if CollectionLogDB._seenNewPopups[key] then return end
  if not _CL_ShouldAllowNewCollectionSideEffects({ type = "pet", speciesID = speciesID, itemID = GetTrackedPetItemIDBySpeciesID(speciesID) }) then
    CollectionLogDB._seenNewPopups[key] = true
    PopupDebugLog("Suppressed pet popup until baseline speciesID=" .. tostring(speciesID))
    return
  end

  local name, icon
  if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
    local ok, sname, sicon = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
    if ok then
      name = sname
      icon = sicon
    end
  end

  CollectionLogDB._seenNewPopups[key] = true
  local itemID = GetTrackedPetItemIDBySpeciesID(speciesID)
  local itemLink = itemID and select(2, GetItemInfo(itemID)) or nil
  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name or "New pet", icon, "Pet", CL_ApplySourceContext({ type = "pet", itemID = itemID, itemLink = itemLink, speciesID = speciesID, isNew = true, source = reason or "pet_state_flip" }))
    CL_PrintNewCollection("Pet", name or "New pet", { itemID = GetTrackedPetItemIDBySpeciesID(speciesID), speciesID = speciesID })
  end
  if ns and ns.UI and ns.UI.UpdateOverviewPetsFromCollection then
    pcall(ns.UI.UpdateOverviewPetsFromCollection, speciesID)
  end
end

_CL_VerifyMountCandidates = function(reason)
  if _CL_MountBootstrapPending then return end
  _CL_InitKnownMounts()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._mountKnownCollected = CollectionLogDB._mountKnownCollected or {}
  CollectionLogDB._mountItemKnownCollected = CollectionLogDB._mountItemKnownCollected or {}
  CollectionLogDB._mountCandidateQueue = CollectionLogDB._mountCandidateQueue or {}
  CollectionLogDB._mountItemCandidateQueue = CollectionLogDB._mountItemCandidateQueue or {}
  local known = CollectionLogDB._mountKnownCollected
  local itemKnown = CollectionLogDB._mountItemKnownCollected
  local q = CollectionLogDB._mountCandidateQueue
  local itemQ = CollectionLogDB._mountItemCandidateQueue

  for mountID, queuedReason in pairs(q) do
    local nowCollected = false
    if C_MountJournal and C_MountJournal.GetMountInfoByID then
      local ok, _, _, _, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
      nowCollected = ok and isCollected and true or false
    end
    if nowCollected then
      if not known[mountID] then
        known[mountID] = true
        _CL_FireMountPopupByMountID(mountID, queuedReason or reason or "mount_verify")
      else
        known[mountID] = true
      end
      q[mountID] = nil
    end
  end

  if ns and ns.IsMountCollected then
    for itemID, queuedReason in pairs(itemQ) do
      local nowCollected = ns.IsMountCollected(itemID) == true
      if nowCollected then
        if not itemKnown[itemID] then
          itemKnown[itemID] = true
          local mountID = GetMountIDFromItemID_Safe(itemID)
          if mountID then known[mountID] = true end
          _CL_FireMountPopupByItemID(itemID, queuedReason or reason or "mount_item_verify")
        else
          itemKnown[itemID] = true
        end
        itemQ[itemID] = nil
      end
    end
  end
end

_CL_VerifyPetCandidates = function(reason)
  _CL_InitKnownPets()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._petKnownCollected = CollectionLogDB._petKnownCollected or {}
  CollectionLogDB._petCandidateQueue = CollectionLogDB._petCandidateQueue or {}
  local known = CollectionLogDB._petKnownCollected
  local q = CollectionLogDB._petCandidateQueue

  for speciesID, queuedReason in pairs(q) do
    local nowCollected = false
    if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
      local ok, owned = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
      nowCollected = ok and tonumber(owned) and tonumber(owned) > 0 or false
    end
    if nowCollected then
      if not known[speciesID] then
        known[speciesID] = true
        _CL_FirePetPopupBySpeciesID(speciesID, queuedReason or reason or "pet_verify")
        PopupDebugLog("Pet state flip popup speciesID=" .. tostring(speciesID) .. " reason=" .. tostring(queuedReason or reason))
      else
        known[speciesID] = true
      end
      q[speciesID] = nil
    end
  end
end

_CL_QueueMountVerification = function(reason)
  if _CL_MountBootstrapPending then return end
  -- Mount journal state can lag noticeably behind learn/use events on some clients.
  -- Be more patient here than pets/toys so "learned from bag" mounts still flip.
  local delays = { 0.10, 0.50, 1.20, 2.50, 4.00, 6.00 }
  for _, d in ipairs(delays) do
    C_Timer.After(d, function()
      pcall(_CL_VerifyMountCandidates, reason)
    end)
  end
end

_CL_QueuePetVerification = function(reason)
  local delays = { 0.10, 0.50, 1.20 }
  for _, d in ipairs(delays) do
    C_Timer.After(d, function()
      pcall(_CL_VerifyPetCandidates, reason)
    end)
  end
end


-- =======================================
-- Housing "New Collection" Popups
-- =======================================
local _CL_HousingKnownCollected = {}
local _CL_HousingBootstrapPending = true
local _CL_HousingLastTriggerAt = 0
local _CL_HousingLastCatalogReconcileAt = 0
local _CL_HousingPendingPostCombat = false
local _CL_QueueHousingScan
local _CL_HousingCandidateQueue = {}
local _CL_HousingPopupFiredSession = {}
local _CL_HousingVerifyTimerActive = false
local _CL_HousingReconcileQueued = false
local _CL_HousingReconcileCursor = false
local _CL_HousingSourceQuestMap = false
local _CL_HousingSourceAchievementMap = false

local function _CL_SyncHousingUIAfterNewCollection(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return end

  local UI = ns and ns.UI or nil
  if not UI then return end

  local hp = UI._housingPerf
  if hp then
    hp.cache = hp.cache or {}
    hp.cache[itemID] = true
  end

  if UI.UpdateOverviewHousingFromCollection then
    pcall(UI.UpdateOverviewHousingFromCollection, itemID)
  else
    local collected, total
    if hp and type(hp.cache) == "table" then
      local c = 0
      for _, owned in pairs(hp.cache) do
        if owned == true then c = c + 1 end
      end
      collected = c
      total = tonumber(hp.total) or total
    end

    if not total or total <= 0 then
      local ids = (ns and ns.HousingItemIDs) or nil
      if type(ids) == "table" then
        local t = 0
        for _ in pairs(ids) do t = t + 1 end
        total = t
      end
    end

    if not collected then
      collected = 0
      for _ in pairs(_CL_HousingKnownCollected) do
        collected = collected + 1
      end
    end

    if UI.UpdateOverviewHousingFromScan and total and total > 0 then
      pcall(UI.UpdateOverviewHousingFromScan, collected or 0, total or 0)
    end
  end

  local function _doUI()
    if CollectionLogDB and CollectionLogDB.ui then
      if CollectionLogDB.ui.activeCategory == "Housing" and UI.RefreshGrid then
        pcall(UI.RefreshGrid)
      elseif CollectionLogDB.ui.activeCategory == "Overview" and UI.RefreshOverview then
        pcall(UI.RefreshOverview)
      end
    end
  end

  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("ui_refresh_housing_new_collection", _doUI)
  else
    _doUI()
  end
end


local function _CL_MarkHousingTrigger()
  _CL_HousingLastTriggerAt = GetTime and GetTime() or 0
end

local function _CL_GetSecondsSinceHousingTrigger()
  local now = (GetTime and GetTime()) or 0
  local last = tonumber(_CL_HousingLastTriggerAt) or 0
  if last <= 0 then return math.huge end
  return now - last
end

local function _CL_IsTrackedHousingItem(itemID)
  itemID = tonumber(itemID)
  local ids = (ns and ns.HousingItemIDs) or nil
  return itemID and itemID > 0 and type(ids) == "table" and ids[itemID] and true or false
end

local function _CL_BuildHousingSourceMaps()
  if _CL_HousingSourceQuestMap ~= false and _CL_HousingSourceAchievementMap ~= false then
    return
  end

  local questMap, achievementMap = {}, {}
  local metaByItem = (ns and ns.HousingItemMeta) or nil
  if type(metaByItem) == "table" then
    for itemID, meta in pairs(metaByItem) do
      itemID = tonumber(itemID)
      local sourceType = type(meta) == "table" and tostring(meta.sourceType or ""):lower() or ""
      local sourceID = type(meta) == "table" and tonumber(meta.sourceID) or nil
      if itemID and itemID > 0 and sourceID and sourceID > 0 then
        if sourceType == "quest" then
          questMap[sourceID] = questMap[sourceID] or {}
          questMap[sourceID][itemID] = true
        elseif sourceType == "achievement" then
          achievementMap[sourceID] = achievementMap[sourceID] or {}
          achievementMap[sourceID][itemID] = true
        end
      end
    end
  end

  _CL_HousingSourceQuestMap = questMap
  _CL_HousingSourceAchievementMap = achievementMap
end

local function _CL_QueueHousingCandidate(itemID)
  itemID = tonumber(itemID)
  if itemID and itemID > 0 and _CL_IsTrackedHousingItem(itemID) then
    _CL_HousingCandidateQueue[itemID] = true
    return true
  end
  return false
end

local function _CL_QueueHousingCandidatesFromSet(set)
  if type(set) ~= "table" then return 0 end
  local added = 0
  for itemID in pairs(set) do
    if _CL_QueueHousingCandidate(itemID) then
      added = added + 1
    end
  end
  return added
end

local function _CL_QueueHousingCandidatesByQuestID(questID)
  questID = tonumber(questID)
  if not questID or questID <= 0 then return 0 end
  _CL_BuildHousingSourceMaps()
  local questMap = _CL_HousingSourceQuestMap
  return _CL_QueueHousingCandidatesFromSet(type(questMap) == "table" and questMap[questID] or nil)
end

local function _CL_QueueHousingCandidatesByAchievementID(achievementID)
  achievementID = tonumber(achievementID)
  if not achievementID or achievementID <= 0 then return 0 end
  _CL_BuildHousingSourceMaps()
  local achievementMap = _CL_HousingSourceAchievementMap
  return _CL_QueueHousingCandidatesFromSet(type(achievementMap) == "table" and achievementMap[achievementID] or nil)
end

local function _CL_TakeHousingBagSnapshot()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._housingBagSnapshot = _CL_GetBagItemCounts and _CL_GetBagItemCounts() or {}
end

local function _CL_CollectHousingBagChanges(reason)
  CollectionLogDB = CollectionLogDB or {}
  local prev = CollectionLogDB._housingBagSnapshot or {}
  local now = _CL_GetBagItemCounts and _CL_GetBagItemCounts() or {}
  local changed = false

  for itemID, count in pairs(now) do
    if _CL_IsTrackedHousingItem(itemID) and (tonumber(prev[itemID]) or 0) ~= (tonumber(count) or 0) then
      _CL_QueueHousingCandidate(itemID)
      changed = true
    end
  end

  for itemID, count in pairs(prev) do
    if _CL_IsTrackedHousingItem(itemID) and (tonumber(now[itemID]) or 0) ~= (tonumber(count) or 0) then
      _CL_QueueHousingCandidate(itemID)
      changed = true
    end
  end

  CollectionLogDB._housingBagSnapshot = now

  if changed then
    _CL_MarkHousingTrigger()
    _CL_QueueHousingScan(reason or "bag_update")
    return true
  end

  return false
end

local function _CL_InitHousingKnown(force)
  if not force and next(_CL_HousingKnownCollected) and not _CL_HousingBootstrapPending then
    return true
  end

  local ids = (ns and ns.HousingItemIDs) or nil
  if type(ids) ~= "table" or not (ns and ns.IsHousingCollected) then
    return false
  end

  for itemID in pairs(ids) do
    itemID = tonumber(itemID)
    if itemID and itemID > 0 and ns.IsHousingCollected(itemID) then
      _CL_HousingKnownCollected[itemID] = true
    end
  end

  return true
end

local function _CL_FinishHousingBootstrap()
  _CL_HousingBootstrapPending = false
  _CL_HousingPendingPostCombat = false
  PopupDebugLog("Housing bootstrap complete")
end

local function _CL_FireHousingPopup(itemID, reason)
  if _CL_HousingBootstrapPending then return end
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return end
  if not _CL_ShouldAllowNewCollectionSideEffects({ type = "housing", itemID = itemID }) then
    PopupDebugLog("Suppressed housing popup until baseline itemID=" .. tostring(itemID))
    _CL_SyncHousingUIAfterNewCollection(itemID)
    return
  end
  local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID)) or "New housing item"
  local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))
  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name, icon, "Housing", CL_ApplySourceContext({ type = "housing", itemID = itemID, isNew = true, source = reason or "housing_delta" }))
    CL_PrintNewCollection("Housing", name, { itemID = itemID })
  end
  _CL_SyncHousingUIAfterNewCollection(itemID)
end

local function _CL_RunHousingSilentReconcile(reason, limit)
  if _CL_HousingBootstrapPending then return end
  if InCombatLockdown and InCombatLockdown() then
    _CL_HousingPendingPostCombat = true
    _CL_HousingReconcileQueued = true
    return
  end

  if not _CL_InitHousingKnown(false) then
    return
  end

  local ids = (ns and ns.HousingItemIDs) or nil
  if type(ids) ~= "table" or not (ns and ns.IsHousingCollected) then
    return
  end

  local itemList = {}
  for itemID in pairs(ids) do
    itemList[#itemList + 1] = tonumber(itemID)
  end
  table.sort(itemList)

  local startIndex = tonumber(_CL_HousingReconcileCursor) or 1
  local chunk = tonumber(limit) or 12
  local processed = 0

  for idx = startIndex, #itemList do
    local itemID = itemList[idx]
    if itemID and itemID > 0 and ns.IsHousingCollected(itemID) then
      _CL_HousingKnownCollected[itemID] = true
    end
    processed = processed + 1
    if processed >= chunk then
      _CL_HousingReconcileCursor = idx + 1
      _CL_HousingReconcileQueued = true
      if C_Timer and C_Timer.After then
        C_Timer.After(0.20, function()
          pcall(_CL_RunHousingSilentReconcile, reason or "reconcile", chunk)
        end)
      end
      return
    end
  end

  _CL_HousingReconcileCursor = false
  _CL_HousingReconcileQueued = false
  PopupDebugLog("Housing silent reconcile complete reason=" .. tostring(reason))
end

local function _CL_ScanHousingNew(reason)
  if _CL_HousingBootstrapPending then return end
  if InCombatLockdown and InCombatLockdown() then
    _CL_HousingPendingPostCombat = true
    return
  end

  if not _CL_InitHousingKnown(false) then
    return
  end

  if type(_CL_HousingCandidateQueue) ~= "table" or not next(_CL_HousingCandidateQueue) then
    return
  end

  if not (ns and ns.IsHousingCollected) then
    return
  end

  local pendingRetry = {}
  local fired = 0
  local checked = 0
  local MAX_PER_SCAN = 12

  for itemID in pairs(_CL_HousingCandidateQueue) do
    itemID = tonumber(itemID)
    _CL_HousingCandidateQueue[itemID] = nil
    if itemID and itemID > 0 then
      checked = checked + 1
      local wasKnown = _CL_HousingKnownCollected[itemID] == true
      local isCollected = ns.IsHousingCollected(itemID) and true or false
      if isCollected then
        _CL_HousingKnownCollected[itemID] = true
        if (not wasKnown) and (not _CL_HousingPopupFiredSession[itemID]) then
          _CL_HousingPopupFiredSession[itemID] = true
          fired = fired + 1
          _CL_FireHousingPopup(itemID, reason)
        end
      else
        pendingRetry[itemID] = true
      end
      if checked >= MAX_PER_SCAN then
        break
      end
    end
  end

  for itemID in pairs(_CL_HousingCandidateQueue) do
    pendingRetry[itemID] = true
    _CL_HousingCandidateQueue[itemID] = nil
  end

  _CL_HousingCandidateQueue = pendingRetry

  if fired > 0 then
    PopupDebugLog("Housing candidate verify fired=" .. fired .. " reason=" .. tostring(reason))
  end
end

_CL_QueueHousingScan = function(reason)
  if _CL_HousingBootstrapPending then return end
  if type(_CL_HousingCandidateQueue) ~= "table" or not next(_CL_HousingCandidateQueue) then
    return
  end
  if _CL_HousingVerifyTimerActive then
    return
  end
  _CL_HousingVerifyTimerActive = true
  local retryReason = tostring(reason or "housing_candidate")
  local function _run(delay, final)
    C_Timer.After(delay, function()
      pcall(_CL_ScanHousingNew, retryReason)
      if final then
        _CL_HousingVerifyTimerActive = false
      end
    end)
  end
  _run(0.40, false)
  _run(1.50, true)
end

-- Housing trigger events: quest turn-ins / vendor-AH-mail flows / bag updates / housing catalog updates.
local hf = CreateFrame("Frame")
hf:RegisterEvent("PLAYER_LOGIN")
hf:RegisterEvent("QUEST_TURNED_IN")
hf:RegisterEvent("BAG_UPDATE_DELAYED")
hf:RegisterEvent("PLAYER_REGEN_ENABLED")
hf:RegisterEvent("MERCHANT_CLOSED")
pcall(hf.RegisterEvent, hf, "MAIL_CLOSED")
pcall(hf.RegisterEvent, hf, "AUCTION_HOUSE_CLOSED")
pcall(hf.RegisterEvent, hf, "ACHIEVEMENT_EARNED")
-- Some clients may emit a housing-specific update; safe to register if it exists.
pcall(hf.RegisterEvent, hf, "HOUSING_CATALOG_UPDATE")
pcall(hf.RegisterEvent, hf, "HOUSING_CATALOG_UPDATED")

hf:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    if ns and ns.ProfilePrint then ns.ProfilePrint("Housing tracker PLAYER_LOGIN begin") end
    _CL_HousingBootstrapPending = true
    pcall(_CL_TakeHousingBagSnapshot)
    pcall(_CL_InitHousingKnown, true)
    pcall(_CL_FinishHousingBootstrap)
    _CL_MarkNewCollectionBaselineComponentReady("housing")
    if ns and ns.ProfilePrint then ns.ProfilePrint("Housing tracker PLAYER_LOGIN minimal bootstrap complete") end
    if ns and ns.ProfilePrint then ns.ProfilePrint("Housing tracker PLAYER_LOGIN end") end
    return
  end

  if event == "QUEST_TURNED_IN" then
    local questID = ...
    _CL_MarkHousingTrigger()
    _CL_QueueHousingCandidatesByQuestID(questID)
    _CL_QueueHousingScan("quest_turned_in")
    return
  end

  if event == "ACHIEVEMENT_EARNED" then
    local achievementID = ...
    _CL_MarkHousingTrigger()
    _CL_QueueHousingCandidatesByAchievementID(achievementID)
    _CL_QueueHousingScan("achievement_earned")
    return
  end

  if event == "MERCHANT_CLOSED" or event == "MAIL_CLOSED" or event == "AUCTION_HOUSE_CLOSED" then
    _CL_MarkHousingTrigger()
    return
  end

  if event == "BAG_UPDATE_DELAYED" then
    if _CL_CollectHousingBagChanges("bag_update") then
      return
    end
    return
  end

  if event == "PLAYER_REGEN_ENABLED" then
    if _CL_HousingPendingPostCombat then
      _CL_HousingPendingPostCombat = false
      if next(_CL_HousingCandidateQueue) then
        _CL_QueueHousingScan("post_combat")
      elseif _CL_HousingReconcileQueued then
        _CL_RunHousingSilentReconcile("post_combat_reconcile", 12)
      end
      return
    end
    return
  end

  if event == "HOUSING_CATALOG_UPDATE" or event == "HOUSING_CATALOG_UPDATED" then
    if next(_CL_HousingCandidateQueue) then
      _CL_QueueHousingScan("housing_catalog")
      return
    end

    local sinceTrigger = _CL_GetSecondsSinceHousingTrigger()
    local now = (GetTime and GetTime()) or 0
    local sinceCatalogReconcile = now - (tonumber(_CL_HousingLastCatalogReconcileAt) or 0)

    -- The catalog can fire a burst of updates right after learning a new decor item.
    -- A full all-items reconcile here causes large frame spikes exactly when the popup is visible.
    -- We already update the confirmed item incrementally, so keep catalog-wide reconciliation
    -- as a low-priority fallback only after the unlock flow has settled.
    if sinceTrigger < 10 then
      return
    end
    if sinceCatalogReconcile < 20 then
      return
    end

    if not _CL_HousingReconcileQueued then
      _CL_HousingReconcileQueued = true
      _CL_HousingLastCatalogReconcileAt = now
      if C_Timer and C_Timer.After then
        C_Timer.After(2.50, function()
          pcall(_CL_RunHousingSilentReconcile, "housing_catalog", 12)
        end)
      else
        _CL_RunHousingSilentReconcile("housing_catalog", 12)
      end
    end
    return
  end
end)

jf:SetScript("OnEvent", function(_, event, arg1)
  if event == "NEW_MOUNT_ADDED" then
    if _CL_MountBootstrapPending then return end
    local mountID = tonumber(arg1)
    CL_EventDiag("NEW_MOUNT_ADDED mountID=" .. tostring(mountID) .. " tracked=" .. tostring(mountID and IsTrackedMount(mountID)))
    if mountID and mountID > 0 then
      _CL_QueueMountCandidateByMountID(mountID, "new_mount_added")
      TryMountPopupWithRetry(mountID, 0)
    end
    -- Do not queue every unknown tracked mount here.
    -- NEW_MOUNT_ADDED is authoritative for the specific mount that was learned,
    -- and broad rescans can surface unrelated already-owned mounts as false "new" popups.
    _CL_QueueMountVerification("new_mount_added")
  elseif event == "NEW_PET_ADDED" then
    local petGUID = arg1
    if petGUID and petGUID ~= "" and C_PetJournal and C_PetJournal.GetPetInfoByPetID then
      local ok, _, speciesID = pcall(C_PetJournal.GetPetInfoByPetID, petGUID)
      if ok and tonumber(speciesID) and tonumber(speciesID) > 0 then
        _CL_QueuePetCandidateBySpeciesID(tonumber(speciesID), "new_pet_added")
      end
      TryPetPopupWithRetry(petGUID, 0)
    end
    -- NEW_PET_ADDED is already specific enough; do not broad-scan every unknown tracked pet.
    _CL_QueuePetVerification("new_pet_added")
  elseif event == "NEW_TOY_ADDED" then
    local itemID = tonumber(arg1)
    if itemID and itemID > 0 then
      _CL_QueueToyCandidate(itemID, "new_toy_added")
    else
      _CL_CollectNewBagToyCandidates("new_toy_added")
    end
    _CL_QueueToyVerification("new_toy_added")
  elseif event == "COMPANION_LEARNED" then
    if _CL_MountBootstrapPending then
      pcall(_CL_CollectNewBagMountPetCandidates, "companion_learned")
      _CL_QueuePetVerification("companion_learned")
      return
    end
    -- Use bag deltas here as a narrow fallback for learned items.
    -- Broad mount rescans from COMPANION_LEARNED can incorrectly fire unrelated tracked mounts.
    pcall(_CL_CollectNewBagMountPetCandidates, "companion_learned")
    _CL_QueueMountVerification("companion_learned")
    _CL_QueuePetVerification("companion_learned")
  elseif event == "MOUNT_JOURNAL_USABILITY_CHANGED" then
    _CL_HandleMountUsabilityChanged()
  elseif event == "PET_JOURNAL_LIST_UPDATE" then
    -- This event can fire while idle and is not proof that a Collection Log pet changed.
    -- Only verify an already queued specific candidate; never broad-scan all unknown pets.
    local db = CollectionLogDB or {}
    if type(db._petCandidateQueue) == "table" and next(db._petCandidateQueue) ~= nil then
      _CL_QueuePetVerification("pet_journal")
    end
  end
end)

f:SetScript("OnEvent", function(self, event, ...)
  local ok = pcall(_CL_HandleLootChat, self, event, ...)
  if not ok then return end
end)


-- =======================================
-- Optional: manual test command
-- =======================================


-- ============================================================
-- Instance Completion Counter (OSRS-style "KC")
-- ============================================================
-- Definition: a "completion" increments when the player has killed ALL encounters
-- in an instance for the current difficulty within a single continuous run.
--
-- This is Blizzard-truthful: driven by ENCOUNTER_END success events + Encounter Journal encounter lists.
-- It is NOT retroactive (no universal lifetime API); it starts counting after install.

local function EnsureEJLoaded()
  if (EJ_GetEncounterInfoByIndex and EJ_SelectInstance and EJ_GetInstanceForEncounter) then
    return true
  end
  pcall(LoadAddOn, "Blizzard_EncounterJournal")
  if EncounterJournal_LoadUI then pcall(EncounterJournal_LoadUI) end
  return (EJ_GetEncounterInfoByIndex and EJ_SelectInstance) ~= nil
end

local function GetEncounterMetaForInstance(instanceID)
  if not instanceID then return nil end
  if not EnsureEJLoaded() then return nil end

  ns._encounterCache = ns._encounterCache or {}
  if ns._encounterCache[instanceID] then
    return ns._encounterCache[instanceID]
  end

  local list = {}
  pcall(EJ_SelectInstance, instanceID)

  local i = 1
  while true do
    local ok, name, _, journalEncounterID, _, _, _, dungeonEncounterID = pcall(EJ_GetEncounterInfoByIndex, i, instanceID)
    if not ok or not journalEncounterID then break end
    list[#list + 1] = {
      index = i,
      name = name,
      journalEncounterID = tonumber(journalEncounterID),
      dungeonEncounterID = tonumber(dungeonEncounterID),
    }
    i = i + 1
  end

  ns._encounterCache[instanceID] = list
  return list
end

local function EnsureEncounterLookup(instanceID)
  instanceID = tonumber(instanceID)
  if not instanceID then return nil end
  ns._encounterLookup = ns._encounterLookup or {}
  if ns._encounterLookup[instanceID] then
    return ns._encounterLookup[instanceID]
  end

  local list = GetEncounterMetaForInstance(instanceID)
  if not list then return nil end

  local lookup = {}
  for _, meta in ipairs(list) do
    local jeid = tonumber(meta.journalEncounterID)
    local deid = tonumber(meta.dungeonEncounterID)
    if jeid then lookup[jeid] = meta end
    if deid then lookup[deid] = meta end
  end
  ns._encounterLookup[instanceID] = lookup
  return lookup
end

local function FindEncounterMeta(instanceID, encounterID)
  local eid = tonumber(encounterID)
  if not eid then return nil end
  local lookup = EnsureEncounterLookup(instanceID)
  if lookup and lookup[eid] then
    return lookup[eid]
  end
  local list = GetEncounterMetaForInstance(instanceID)
  if not list then return nil end
  for _, meta in ipairs(list) do
    if tonumber(meta.dungeonEncounterID) == eid or tonumber(meta.journalEncounterID) == eid then
      return meta
    end
  end
  return nil
end

local function BuildClearTrackingIndexes()
  local groupCount = 0
  if ns and ns.Data and type(ns.Data.groups) == "table" then
    for _ in pairs(ns.Data.groups) do groupCount = groupCount + 1 end
  end

  if ns._clearTrackingIndexesBuilt and ns._clearTrackingIndexesGroupCount == groupCount then
    return
  end
  ns._clearTrackingIndexesBuilt = true
  ns._clearTrackingIndexesGroupCount = groupCount

  ns._clearGroupLookup = {}
  ns._clearFinalEncounterLookup = {}
  ns._clearEncounterInstanceLookup = {}

  if not (ns and ns.Data and type(ns.Data.groups) == "table") then return end

  for gid, g in pairs(ns.Data.groups) do
    if type(g) == "table" then
      local instanceID = tonumber(g.instanceID)
      local did = tonumber(g.difficultyID)
      if instanceID and instanceID > 0 and did then
        local runKey = tostring(instanceID) .. ":" .. tostring(did)
        ns._clearGroupLookup[runKey] = true

        local explicitFinalID = tonumber(g.finalEncounterID or g.finalBossEncounterID)
        if explicitFinalID and explicitFinalID > 0 then
          ns._clearFinalEncounterLookup[runKey] = explicitFinalID
        end

        local list = GetEncounterMetaForInstance(instanceID)
        if list and #list > 0 then
          local finalMeta = list[#list]
          if finalMeta then
            local finalID = tonumber(ns._clearFinalEncounterLookup[runKey])
            if not finalID or finalID <= 0 then
              finalID = tonumber(finalMeta.journalEncounterID) or tonumber(finalMeta.dungeonEncounterID)
              if finalID and finalID > 0 then
                ns._clearFinalEncounterLookup[runKey] = finalID
              end
            end
          end

          local byEncounter = ns._clearEncounterInstanceLookup[did] or {}
          ns._clearEncounterInstanceLookup[did] = byEncounter
          for _, meta in ipairs(list) do
            local jeid = tonumber(meta.journalEncounterID)
            local deid = tonumber(meta.dungeonEncounterID)
            if jeid then
              byEncounter[jeid] = byEncounter[jeid] or instanceID
            end
            if deid then
              byEncounter[deid] = byEncounter[deid] or instanceID
            end
          end
        end
      end
    end
  end
end

BuildClearTrackingIndexes()

-- Normalize runtime Encounter Journal/map IDs to the canonical group IDs used by the shipped datapacks.
-- Some legacy instances report a different runtime EJ/map ID than the collectible datapack key.
-- Throne of the Four Winds is the known case: runtime reports map=754 / EJ=740, while CL groups use EJ instanceID=74.
local CL_CANONICAL_CLEAR_INSTANCE_IDS = {
  [740] = 74, -- Throne of the Four Winds runtime EJ -> Collection Log datapack EJ
  [754] = 74, -- Throne of the Four Winds instance map -> Collection Log datapack EJ
}

local function CLOG_NormalizeClearInstanceID(instanceID, mapID, encounterID, encounterName)
  local iid = tonumber(instanceID)
  local mid = tonumber(mapID)
  if iid and CL_CANONICAL_CLEAR_INSTANCE_IDS[iid] then
    return CL_CANONICAL_CLEAR_INSTANCE_IDS[iid]
  end
  if mid and CL_CANONICAL_CLEAR_INSTANCE_IDS[mid] then
    return CL_CANONICAL_CLEAR_INSTANCE_IDS[mid]
  end

  -- Extra guard for Al'Akir/Conclave event IDs in Throne if Blizzard returns neither expected ID.
  local eid = tonumber(encounterID)
  if eid == 1034 or eid == 1035 then
    return 74
  end
  if type(encounterName) == "string" then
    local n = encounterName:lower():gsub("[^a-z]", "")
    if n == "alakir" or n == "conclaveofwind" then
      return 74
    end
  end
  return iid
end

-- Resolve Encounter Journal instanceID for a given instance mapID (from GetInstanceInfo()).
local function ResolveEJInstanceIDFromMapID(mapID)
  mapID = tonumber(mapID)
  if not mapID then return nil end
  if EnsureEJLoaded() and EJ_GetInstanceForMap then
    local ok, ejID = pcall(EJ_GetInstanceForMap, mapID)
    ejID = tonumber(ejID)
    if ok and ejID and ejID > 0 then return CLOG_NormalizeClearInstanceID(ejID, mapID) or ejID end
  end
  return nil
end

local function ResolveEJInstanceIDFromEncounter(difficultyID, encounterID)
  local did = tonumber(difficultyID)
  local eid = tonumber(encounterID)
  if not did or not eid then return nil end
  BuildClearTrackingIndexes()
  local byEncounter = ns._clearEncounterInstanceLookup and ns._clearEncounterInstanceLookup[did]
  if byEncounter then
    local instanceID = tonumber(byEncounter[eid])
    if instanceID and instanceID > 0 then
      return CLOG_NormalizeClearInstanceID(instanceID, nil, encounterID) or instanceID
    end
  end
  return nil
end

local function ResolveBestEJInstanceID(mapID, difficultyID, encounterID, encounterName)
  local normalized = CLOG_NormalizeClearInstanceID(nil, mapID, encounterID, encounterName)
  if normalized and normalized > 0 then
    return normalized
  end

  local ejID = ResolveEJInstanceIDFromMapID(mapID)
  ejID = CLOG_NormalizeClearInstanceID(ejID, mapID, encounterID, encounterName) or ejID
  if ejID and ejID > 0 then
    return ejID
  end

  ejID = ResolveEJInstanceIDFromEncounter(difficultyID, encounterID)
  ejID = CLOG_NormalizeClearInstanceID(ejID, mapID, encounterID, encounterName) or ejID
  if ejID and ejID > 0 then
    return ejID
  end
  return nil
end

-- Returns true if we have a datapack group for this instance+difficulty (prevents counting unknown/unsupported combos).
local function HasGroupForInstanceDifficulty(instanceID, difficultyID)
  BuildClearTrackingIndexes()
  local key = tostring(instanceID) .. ":" .. tostring(difficultyID)
  return ns._clearGroupLookup and ns._clearGroupLookup[key] == true or false
end

-- Optional datapack override: allow groups to specify finalEncounterID (future-proofing).
local function GetFinalEncounterIDFromDataPack(instanceID, difficultyID)
  BuildClearTrackingIndexes()
  local key = tostring(instanceID) .. ":" .. tostring(difficultyID)
  local fe = ns._clearFinalEncounterLookup and ns._clearFinalEncounterLookup[key]
  if fe then return tonumber(fe) end
  return nil
end

-- Debounce to prevent double-counting due to duplicate ENCOUNTER_END firings.
ns._lastClear = ns._lastClear or { key = nil, t = 0 }

local function ShouldDebounceClear(instanceID, difficultyID, encounterID)
  local now = GetTime and GetTime() or time()
  local key = tostring(instanceID or 0) .. ":" .. tostring(difficultyID or 0) .. ":" .. tostring(encounterID or 0)
  if ns._lastClear.key == key and (now - (ns._lastClear.t or 0)) < 30 then
    return true
  end
  ns._lastClear.key = key
  ns._lastClear.t = now
  return false
end

local function GetActiveRunKey(instanceID, difficultyID)
  return tostring(instanceID or 0) .. ":" .. tostring(difficultyID or 0)
end

function ns.GetInstanceCompletionCount(instanceID, difficultyID, viewMode, characterGUID)
  ns.EnsureCharacterRecord()
  if not instanceID or not difficultyID then return 0 end

  local mode = viewMode
  if mode == nil and CollectionLogDB and CollectionLogDB.ui then
    mode = CollectionLogDB.ui.viewMode
  end

  if mode == "CHARACTER" then
    local guid = characterGUID
    if not guid and CollectionLogDB and CollectionLogDB.ui then
      guid = CollectionLogDB.ui.activeCharacterGUID
    end
    if not guid then
      guid = ns.GetPlayerGUID()
    end
    if not guid then return 0 end

    local c = CollectionLogDB.characters and CollectionLogDB.characters[guid]
    if not c then return 0 end
    c.completions = c.completions or {}
    c.completions[instanceID] = c.completions[instanceID] or {}
    return tonumber(c.completions[instanceID][difficultyID] or 0) or 0
  end

  local total = 0
  local chars = CollectionLogDB and CollectionLogDB.characters or nil
  if not chars then return 0 end
  for _, c in pairs(chars) do
    local byInstance = c.completions and c.completions[instanceID]
    if byInstance then
      total = total + (tonumber(byInstance[difficultyID] or 0) or 0)
    end
  end
  return total
end

local function CLOG_GetEquivalentDifficultyIDs(difficultyID)
  local did = tonumber(difficultyID)
  if not did then return {} end

  local out, seen = {}, {}
  local function add(v)
    v = tonumber(v)
    if v and not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end

  add(did)

  -- Legacy 10/25 raids and their modern Normal/Heroic equivalents need a tolerant lookup.
  -- We keep the selected difficulty first, then include the most likely Blizzard aliases.
  if did == 3 or did == 4 then
    add(14)
  elseif did == 5 or did == 6 then
    add(15)
  elseif did == 14 then
    add(3)
    add(4)
  elseif did == 15 then
    add(5)
    add(6)
  end

  return out
end

function ns.GetBestInstanceCompletionCount(instanceIDs, difficultyID, viewMode, characterGUID)
  ns.EnsureCharacterRecord()

  local ids = {}
  local seenIDs = {}
  if type(instanceIDs) == "table" then
    for _, v in ipairs(instanceIDs) do
      v = tonumber(v)
      if v and v > 0 and not seenIDs[v] then
        seenIDs[v] = true
        ids[#ids + 1] = v
      end
    end
  else
    local v = tonumber(instanceIDs)
    if v and v > 0 then ids[1] = v end
  end
  if #ids == 0 then return 0 end

  local dids = CLOG_GetEquivalentDifficultyIDs(difficultyID)
  if #dids == 0 then return 0 end

  local mode = viewMode
  if mode == nil and CollectionLogDB and CollectionLogDB.ui then
    mode = CollectionLogDB.ui.viewMode
  end

  local function bestForCharacter(c)
    if type(c) ~= "table" then return 0 end
    c.completions = c.completions or {}
    local best = 0
    for _, iid in ipairs(ids) do
      local byInstance = c.completions[iid]
      if byInstance then
        for _, did in ipairs(dids) do
          local count = tonumber(byInstance[did] or 0) or 0
          if count > best then best = count end
        end
      end
    end
    return best
  end

  if mode == "CHARACTER" then
    local guid = characterGUID
    if not guid and CollectionLogDB and CollectionLogDB.ui then
      guid = CollectionLogDB.ui.activeCharacterGUID
    end
    if not guid then guid = ns.GetPlayerGUID() end
    if not guid then return 0 end
    local c = CollectionLogDB.characters and CollectionLogDB.characters[guid]
    return bestForCharacter(c)
  end

  local total = 0
  local chars = CollectionLogDB and CollectionLogDB.characters or nil
  if not chars then return 0 end
  for _, c in pairs(chars) do
    total = total + bestForCharacter(c)
  end
  return total
end

local function IncrementInstanceCompletion(instanceID, difficultyID, aliasInstanceID)
  ns.EnsureCharacterRecord()
  local guid = ns.GetPlayerGUID()
  if not guid then return end
  local c = CollectionLogDB.characters[guid]
  c.completions = c.completions or {}

  local function bump(id)
    id = tonumber(id)
    if not id or id <= 0 then return end
    c.completions[id] = c.completions[id] or {}
    c.completions[id][difficultyID] = (tonumber(c.completions[id][difficultyID] or 0) or 0) + 1
  end

  bump(instanceID)
  if tonumber(aliasInstanceID) and tonumber(aliasInstanceID) ~= tonumber(instanceID) then
    bump(aliasInstanceID)
  end
end

-- Runtime-only tracking for the current run (cleared when you leave / enter a new instance).
ns._activeRun = ns._activeRun or {
  key = nil,
  mapID = nil,
  ejInstanceID = nil,
  difficultyID = nil,
  fresh = false,
  completed = false,
  killedJournal = {},
  killedDungeon = {},
}
ns._pendingClear = ns._pendingClear or nil

local function ResetActiveRun()
  ns._activeRun.key = nil
  ns._activeRun.mapID = nil
  ns._activeRun.ejInstanceID = nil
  ns._activeRun.difficultyID = nil
  ns._activeRun.fresh = false
  ns._activeRun.completed = false
  ns._activeRun.killedJournal = {}
  ns._activeRun.killedDungeon = {}
  ns._pendingClear = nil
end

local function IsJournalEncounterComplete(mapID, difficultyID, journalEncounterID)
  if not mapID or not difficultyID or not journalEncounterID then return nil end
  if not C_RaidLocks or not C_RaidLocks.IsEncounterComplete then return nil end
  local ok, complete = pcall(C_RaidLocks.IsEncounterComplete, mapID, journalEncounterID, difficultyID)
  if ok then return complete and true or false end
  return nil
end

-- Freshness is intentionally no longer snapshotted here.
-- It used to perform a full raid-lock scan on run initialization, but completion
-- counting no longer depends on "fresh" and the scan caused avoidable hitching
-- on kill / run-context initialization. Keep the field for debug compatibility.
local function SnapshotRunFreshness(mapID, ejInstanceID, difficultyID)
  return false
end

local function UpdateRunContext(mapID, difficultyID, ejInstanceID)
  local inInstance = IsInInstance()
  if not inInstance then
    ResetActiveRun()
    return
  end

  local _, instanceType, liveDifficultyID, _, _, _, _, liveMapID = GetInstanceInfo()
  if instanceType ~= "party" and instanceType ~= "raid" then
    ResetActiveRun()
    return
  end

  mapID = tonumber(mapID or liveMapID)
  difficultyID = tonumber(difficultyID or liveDifficultyID)
  BuildClearTrackingIndexes()
  ejInstanceID = tonumber(CLOG_NormalizeClearInstanceID(ejInstanceID, mapID) or ejInstanceID or ResolveBestEJInstanceID(mapID, difficultyID) or mapID)

  if not mapID or not difficultyID or not ejInstanceID then
    ResetActiveRun()
    return
  end

  local key = GetActiveRunKey(mapID, difficultyID)
  if ns._activeRun.key ~= key then
    ns._activeRun.key = key
    ns._activeRun.mapID = mapID
    ns._activeRun.ejInstanceID = ejInstanceID
    ns._activeRun.difficultyID = difficultyID
    ns._activeRun.fresh = SnapshotRunFreshness(mapID, ejInstanceID, difficultyID)
    ns._activeRun.completed = false
    ns._activeRun.killedJournal = {}
    ns._activeRun.killedDungeon = {}
  end
end

local function IsRunComplete(mapID, ejInstanceID, difficultyID)
  local list = GetEncounterMetaForInstance(ejInstanceID)
  if not list or #list == 0 then return false end
  for _, meta in ipairs(list) do
    local complete = IsJournalEncounterComplete(mapID, difficultyID, meta.journalEncounterID)
    if complete == nil then
      complete = ns._activeRun.killedJournal[meta.journalEncounterID] or ns._activeRun.killedDungeon[meta.dungeonEncounterID]
    end
    if not complete then
      return false
    end
  end
  return true
end

local function IsFinalEncounterForInstance(ejInstanceID, difficultyID, encounterID, encounterName)
  local eid = tonumber(encounterID)
  local instanceID = tonumber(ejInstanceID)
  local did = tonumber(difficultyID)
  if not eid or not instanceID or not did then return false end

  -- Throne of the Four Winds has historically been fragile for run-completion tracking.
  -- Al'Akir is the true final boss; count it as final even if EJ ordering/IDs disagree.
  if instanceID == 74 and type(encounterName) == "string" then
    local n = encounterName:lower():gsub("[^a-z]", "")
    if n == "alakir" then
      return true
    end
  end

  local explicitFinalID = GetFinalEncounterIDFromDataPack(instanceID, did)
  if explicitFinalID and explicitFinalID > 0 then
    if eid == explicitFinalID then
      return true
    end
    local explicitMeta = FindEncounterMeta(instanceID, explicitFinalID)
    if explicitMeta and (eid == tonumber(explicitMeta.journalEncounterID) or eid == tonumber(explicitMeta.dungeonEncounterID)) then
      return true
    end
  end

  local list = GetEncounterMetaForInstance(instanceID)
  if not list or #list == 0 then return false end
  local finalMeta = list[#list]
  if not finalMeta then return false end

  return eid == tonumber(finalMeta.journalEncounterID) or eid == tonumber(finalMeta.dungeonEncounterID)
end

local function ScheduleClearUIRefresh()
  if ns._clearRefreshPending then return end
  if not (ns.UI and ns.UI.RefreshGrid and ns.UI.frame and ns.UI.frame.IsShown and ns.UI.frame:IsShown()) then return end

  ns._clearRefreshPending = true
  local function _run()
    ns._clearRefreshPending = false
    if not (ns._activeRun and ns._activeRun.completed) then return end
    if not (ns.UI and ns.UI.RefreshGrid and ns.UI.frame and ns.UI.frame.IsShown and ns.UI.frame:IsShown()) then return end
    pcall(ns.UI.RefreshGrid)
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(0.05, _run)
  else
    _run()
  end
end

local function CountActiveRunCompletion(mapID, ejInstanceID, difficultyID, reason)
  ns._activeRun.completed = true
  IncrementInstanceCompletion(ejInstanceID, difficultyID, mapID)

  local newCount = ns.GetInstanceCompletionCount(ejInstanceID, difficultyID)
  CL_PrintCompletionUpdate(ejInstanceID, difficultyID, mapID, newCount)

  if ns._debug and ns._debug.clears then
    Print(("Clears: COUNTED inst=%s map=%s did=%s reason=%s -> %s"):format(
      tostring(ejInstanceID), tostring(mapID), tostring(difficultyID), tostring(reason or "primary"), tostring(newCount)
    ))
  end

  ScheduleClearUIRefresh()
  return true
end

local function MarkEncounterKilled(mapID, ejInstanceID, difficultyID, encounterID, encounterName)
  UpdateRunContext(mapID, difficultyID, ejInstanceID)
  if not ns._activeRun.key or ns._activeRun.completed then return false end

  local meta = FindEncounterMeta(ejInstanceID, encounterID)
  if meta then
    if meta.journalEncounterID then ns._activeRun.killedJournal[meta.journalEncounterID] = true end
    if meta.dungeonEncounterID then ns._activeRun.killedDungeon[meta.dungeonEncounterID] = true end
  else
    local eid = tonumber(encounterID)
    if eid then
      ns._activeRun.killedDungeon[eid] = true
    end
  end


  local isFinalEncounter = IsFinalEncounterForInstance(ejInstanceID, difficultyID, encounterID, encounterName)
  if not isFinalEncounter then
    return false
  end

  if IsRunComplete(mapID, ejInstanceID, difficultyID) then
    return CountActiveRunCompletion(mapID, ejInstanceID, difficultyID, "full")
  end

  if HasGroupForInstanceDifficulty(ejInstanceID, difficultyID) then
    if ns._debug and ns._debug.clears then
      Print(("Clears: FINAL-BOSS fallback inst=%s map=%s did=%s encID=%s"):format(
        tostring(ejInstanceID), tostring(mapID), tostring(difficultyID), tostring(encounterID)
      ))
    end
    return CountActiveRunCompletion(mapID, ejInstanceID, difficultyID, "final-boss")
  end

  return false
end

-- Event frame for encounter completion tracking
local kc = CreateFrame("Frame")
kc:RegisterEvent("PLAYER_ENTERING_WORLD")
kc:RegisterEvent("PLAYER_REGEN_ENABLED")
kc:RegisterEvent("ENCOUNTER_END")
kc:RegisterEvent("CHALLENGE_MODE_RESET")
kc:RegisterEvent("CHALLENGE_MODE_COMPLETED")
kc:RegisterEvent("CHALLENGE_MODE_START")

local function TryCountClearNow(mapID, ejInstanceID, did, encounterID, encounterName)
  if ShouldDebounceClear(mapID, did, encounterID) then
    if ns._debug and ns._debug.clears then
      Print(("Clears: DEBOUNCE map=%s did=%s encID=%s"):format(tostring(mapID), tostring(did), tostring(encounterID)))
    end
    return ns._activeRun and ns._activeRun.completed
  end
  return MarkEncounterKilled(mapID, ejInstanceID, did, encounterID, encounterName)
end

local function QueuePendingClear(mapID, ejInstanceID, did, encounterID, encounterName)
  ns._pendingClear = {
    mapID = tonumber(mapID),
    ejInstanceID = tonumber(ejInstanceID),
    difficultyID = tonumber(did),
    encounterID = tonumber(encounterID),
    encounterName = encounterName,
    queuedAt = GetTime and GetTime() or time(),
  }
end

local function FlushPendingClear()
  local pending = ns._pendingClear
  if not pending then return end
  if InCombatLockdown and InCombatLockdown() then return end

  local _, instanceType, instDifficultyID, _, _, _, _, instanceMapID = GetInstanceInfo()
  local liveMapID = tonumber(instanceMapID)
  local liveDid = tonumber(instDifficultyID)
  if instanceType ~= "party" and instanceType ~= "raid" then
    ns._pendingClear = nil
    return
  end
  if pending.mapID and liveMapID and pending.mapID ~= liveMapID then
    ns._pendingClear = nil
    return
  end
  if pending.difficultyID and liveDid and pending.difficultyID ~= liveDid then
    ns._pendingClear = nil
    return
  end

  ns._pendingClear = nil
  local counted = TryCountClearNow(pending.mapID or liveMapID, pending.ejInstanceID, pending.difficultyID or liveDid, pending.encounterID, pending.encounterName)
  if (not counted) and C_Timer and C_Timer.After then
    C_Timer.After(0.15, function()
      if ns._activeRun and ns._activeRun.completed then return end
      pcall(TryCountClearNow, pending.mapID or liveMapID, pending.ejInstanceID, pending.difficultyID or liveDid, pending.encounterID, pending.encounterName)
    end)
    C_Timer.After(0.5, function()
      if ns._activeRun and ns._activeRun.completed then return end
      pcall(TryCountClearNow, pending.mapID or liveMapID, pending.ejInstanceID, pending.difficultyID or liveDid, pending.encounterID, pending.encounterName)
    end)
  end
end

local function _CL_HandleKCEvent(event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    BuildClearTrackingIndexes()
    UpdateRunContext()
    local _, instanceType = IsInInstance()
    -- Disable chat-based loot parsing in PvP instances (BG/Arena) where chat payloads may be "secret" strings.
    if instanceType == "pvp" or instanceType == "arena" then
      SetChatTrackingEnabled(false)
    else
      SetChatTrackingEnabled(not IsChallengeModeActiveSafe())
    end
    if instanceType ~= "party" and instanceType ~= "raid" then
      ns._pendingClear = nil
    end
    return
  end

  if event == "PLAYER_REGEN_ENABLED" then
    FlushPendingClear()
    return
  end

  if event == "CHALLENGE_MODE_START" then
    SetChatTrackingEnabled(false)
    return
  end

  if event == "CHALLENGE_MODE_COMPLETED" or event == "CHALLENGE_MODE_RESET" then
    SetChatTrackingEnabled(true)
    return
  end

  if event == "ENCOUNTER_END" then
    local encounterID, encounterName, difficultyID, _, success = ...
    if success ~= 1 then return end

    local _, instanceType, instDifficultyID, _, _, _, _, instanceMapID = GetInstanceInfo()
    local did = tonumber(instDifficultyID) or tonumber(difficultyID)
    local mapID = tonumber(instanceMapID)
    if not did or not mapID or not encounterID then return end
    if instanceType ~= "party" and instanceType ~= "raid" then return end

    BuildClearTrackingIndexes()
    local ejInstanceID = ResolveBestEJInstanceID(mapID, did, encounterID, encounterName) or CLOG_NormalizeClearInstanceID(nil, mapID, encounterID, encounterName) or mapID
    UpdateRunContext(mapID, did, ejInstanceID)

    local hasPackGroup = HasGroupForInstanceDifficulty(ejInstanceID, did)
    if not hasPackGroup and ns._debug and ns._debug.clears then
      Print(("Clears: NOTICE (no pack group; EJ fallback) mapID=%s ejID=%s did=%s encID=%s %s"):format(tostring(mapID), tostring(ejInstanceID), tostring(did), tostring(encounterID), tostring(encounterName or "")))
    end

    if IsChallengeModeActiveSafe() then
      if ns._debug and ns._debug.clears then
        Print(("Clears: SKIP (challenge mode) inst=%s did=%s encID=%s %s"):format(tostring(ejInstanceID), tostring(did), tostring(encounterID), tostring(encounterName or "")))
      end
      return
    end

    local meta = FindEncounterMeta(ejInstanceID, encounterID)
    CL_EventDiag(("ENCOUNTER_END map=%s ej=%s did=%s encID=%s name=%s hasPack=%s final=%s"):format(
      tostring(mapID), tostring(ejInstanceID), tostring(did), tostring(encounterID), tostring(encounterName or ""),
      tostring(hasPackGroup), tostring(IsFinalEncounterForInstance(ejInstanceID, did, encounterID, encounterName))
    ))
    if ns._debug and ns._debug.clears then
      Print(("Clears: ENCOUNTER map=%s ej=%s did=%s eventEnc=%s dungeonEnc=%s journalEnc=%s fresh=%s %s"):format(
        tostring(mapID), tostring(ejInstanceID), tostring(did), tostring(encounterID),
        tostring(meta and meta.dungeonEncounterID or nil), tostring(meta and meta.journalEncounterID or nil),
        tostring(ns._activeRun and ns._activeRun.fresh), tostring(encounterName or "")
      ))
    end

    if InCombatLockdown and InCombatLockdown() then
      if ns._debug and ns._debug.clears then
        Print(("Clears: DELAY (in combat) map=%s ej=%s did=%s encID=%s %s"):format(tostring(mapID), tostring(ejInstanceID), tostring(did), tostring(encounterID), tostring(encounterName or "")))
      end
      QueuePendingClear(mapID, ejInstanceID, did, encounterID, encounterName)
      return
    end

    if not TryCountClearNow(mapID, ejInstanceID, did, encounterID, encounterName) and C_Timer and C_Timer.After then
      C_Timer.After(0.15, function()
        if ns._activeRun and ns._activeRun.completed then return end
        pcall(TryCountClearNow, mapID, ejInstanceID, did, encounterID, encounterName)
      end)
      C_Timer.After(0.5, function()
        if ns._activeRun and ns._activeRun.completed then return end
        pcall(TryCountClearNow, mapID, ejInstanceID, did, encounterID, encounterName)
      end)
    end
  end
end

kc:SetScript("OnEvent", function(_, event, ...)
  -- Harden against taint edge-cases: never allow event handlers to hard-error.
  pcall(_CL_HandleKCEvent, event, ...)
end)



-- ============================================================
-- Debug toggles
-- ============================================================
ns._debug = ns._debug or { clears = false, events = false }
if ns._debug.clears == nil then ns._debug.clears = false end
if ns._debug.events == nil then ns._debug.events = false end

SLASH_COLLECTIONLOGDEBUG1 = "/cldebug"
SLASH_COLLECTIONLOGDEBUG2 = "/cldbg"
SLASH_COLLECTIONLOGEVENTDIAG1 = "/clogeventdiag"

local function CL_SetEventDiag(mode)
  mode = tostring(mode or ""):lower():gsub("^%s+",""):gsub("%s+$","")
  if mode == "" or mode == "on" then
    ns._debug.events = true
    Print("Debug (events): ON")
  elseif mode == "off" then
    ns._debug.events = false
    Print("Debug (events): OFF")
  elseif mode == "status" then
    Print("Debug (events): " .. (ns._debug.events and "ON" or "OFF"))
  else
    Print("Usage: /clogeventdiag [on|off|status]")
  end
end

SlashCmdList.COLLECTIONLOGEVENTDIAG = function(msg)
  CL_SetEventDiag(msg)
end

SlashCmdList.COLLECTIONLOGDEBUG = function(msg)
  msg = (msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
  if msg == "events" or msg == "event" then
    ns._debug.events = not ns._debug.events
    Print("Debug (events): " .. (ns._debug.events and "ON" or "OFF"))
    return
  elseif msg == "events on" or msg == "event on" then
    ns._debug.events = true
    Print("Debug (events): ON")
    return
  elseif msg == "events off" or msg == "event off" then
    ns._debug.events = false
    Print("Debug (events): OFF")
    return
  elseif msg == "" or msg == "clears" or msg == "clear" or msg == "kc" or msg == "on" then
    ns._debug.clears = (msg == "on") and true or (msg == "" and not ns._debug.clears or not ns._debug.clears)
    Print("Debug (clears): " .. (ns._debug.clears and "ON" or "OFF"))
    return
  elseif msg == "off" then
    ns._debug.clears = false
    Print("Debug (clears): OFF")
    return
  elseif msg == "status" then
    Print("Debug (clears): " .. (ns._debug.clears and "ON" or "OFF") .. "; events: " .. (ns._debug.events and "ON" or "OFF"))
    return
  end
  Print("Usage: /cldebug [clears|events|on|off|status]")
end

-- ============================================================
-- Pack validation (structure checks)
-- ============================================================
SLASH_COLLECTIONLOGVALIDATE1 = "/clvalidate"
SlashCmdList.COLLECTIONLOGVALIDATE = function(msg)
  msg = (msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
  if msg ~= "packs" and msg ~= "" then
    Print("Usage: /clvalidate packs")
    return
  end

  local seen = {}
  local dups = 0
  local total = 0
  local missing = 0

  if type(ns.Data) ~= "table" or type(ns.Data.packs) ~= "table" then
    Print("Validate: ns.Data.packs missing (are packs loaded?)")
    return
  end

  for packId, pack in pairs(ns.Data.packs) do
    if type(pack) == "table" and type(pack.groups) == "table" then
      for _, g in ipairs(pack.groups) do
        if type(g) == "table" then
          local gid = g.id
          if type(gid) == "string" and gid ~= "" then
            total = total + 1
            if seen[gid] then dups = dups + 1 else seen[gid] = packId end
            if g.instanceID == nil or g.difficultyID == nil then missing = missing + 1 end
          end
        end
      end
    end
  end

  Print(("Validate packs: %d groups, %d duplicate IDs, %d missing instanceID/difficultyID."):format(total, dups, missing))
  if dups > 0 then
    Print("Tip: duplicates are resolved by pack priority (generated packs override shipped packs).")
  end
end

SLASH_COLLECTIONLOGTEST1 = "/clogadd"
SlashCmdList.COLLECTIONLOGTEST = function(msg)
  -- /clogadd 19019 2
  local a, b = msg:match("^(%d+)%s*(%d*)$")
  local itemID = tonumber(a)
  local qty = tonumber(b) or 1
  if itemID then
    ns.RecordObtained(itemID, qty, "manual")
    ns.Print(("Manually recorded item %d x%d"):format(itemID, qty))
  else
    ns.Print("Usage: /clogadd <itemID> [qty]")
  end
end


-- ============================================================
-- Pets helper (no scan; builds the Blizzard-truthful pets group)
-- ============================================================
SLASH_COLLECTIONLOGPETS1 = "/clogpets"
SlashCmdList.COLLECTIONLOGPETS = function()
  if ns and ns.EnsurePetsGroups then
    local g = ns.EnsurePetsGroups()
    if g and g.pets then
      DEFAULT_CHAT_FRAME:AddMessage(("Collection Log: Pets group built (%d species)."):format(#g.pets))
    else
      DEFAULT_CHAT_FRAME:AddMessage("Collection Log: Pet Journal not ready yet. Open your Pet Journal (Shift+P) once, then revisit the Pets tab.")
    end
  else
    DEFAULT_CHAT_FRAME:AddMessage("Collection Log: Pets function missing (file not loaded).")
  end
end