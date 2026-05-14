-- =========================
-- Instance lockout helper
-- =========================
local _unpack = table.unpack or unpack

local function CL_DifficultyBucket(diffID)
  -- Map difficulty IDs into broad buckets so legacy 10/25 (and similar) still line up with our UI labels.
  -- This intentionally favors "does the player have a lockout for this type of run?" over exact size splits.
  if not diffID then return nil end
  -- LFR / Raid Finder
  if diffID == 7 or diffID == 17 then return "lfr" end
  -- Normal
  if diffID == 1 or diffID == 3 or diffID == 4 or diffID == 9 or diffID == 14 then return "normal" end
  -- Heroic
  if diffID == 2 or diffID == 5 or diffID == 6 or diffID == 11 or diffID == 15 then return "heroic" end
  -- Mythic
  if diffID == 16 then return "mythic" end
  -- Timewalking raids (often share the normal bucket for lockouts)
  if diffID == 24 then return "timewalking" end
  return tostring(diffID)
end

local function CL_NormalizeName(s)
  if not s then return nil end
  s = tostring(s)
  -- strip color codes
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  s = s:lower()
  s = s:gsub("[â€™']", "") -- apostrophes
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- Boss-name canonicalization: SavedInstances and Encounter Journal do not always use identical strings
-- for legacy raids (e.g., ICC "Blood Prince Council" vs SavedInstances "Blood Princes"). We keep this
-- strictly Blizzard-truthful by only normalizing known string variants, then using SavedInstances
-- for the killed/not-killed state.
-- Boss-name canonicalization: SavedInstances and Encounter Journal do not always use identical strings
-- for legacy raids (e.g., ICC "Blood Prince Council" vs SavedInstances "Blood Princes"). We keep this
-- strictly Blizzard-truthful by only normalizing known string variants, then using SavedInstances
-- for the killed/not-killed state.
--
-- IMPORTANT: We canonicalize BOTH sides into the same key space (EJ name and SavedInstances name),
-- so comparison is always `canonical(ejName) == canonical(savedName)`.
local CL_BOSS_NAME_CANON = {
  -- Icecrown Citadel
  ["blood prince council"]      = "icc_blood_princes",
  ["blood princes"]             = "icc_blood_princes",

  ["blood queen lanathel"]      = "icc_blood_queen_lanathel",
  ["blood-queen lanathel"]      = "icc_blood_queen_lanathel",

  ["icecrown gunship battle"]   = "icc_gunship_battle",
  ["gunship battle"]            = "icc_gunship_battle",

  -- If Blizzard adds other wording variants later, we can safely add them here.
}

local function CL_CanonicalBossKey(name)
  local n = CL_NormalizeName(name)
  if not n or n == "" then return n end

  -- normalize hyphens to spaces for matching robustness (do this BEFORE lookup so both sides align)
  n = n:gsub("%-", " ")
  n = n:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")

  return CL_BOSS_NAME_CANON[n] or n
end

local function CL_BuildInstanceNameCandidates(ejInstanceID, fallbackName)
  local out = {}
  local function add(v)
    local n = CL_NormalizeName(v)
    if n and n ~= "" then out[n] = true end
  end
  add(fallbackName)

  -- Try to derive additional names from Encounter Journal metadata (e.g., zone name / parent raid name).
  if EJ_GetInstanceInfo and ejInstanceID then
    local ok, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = pcall(EJ_GetInstanceInfo, ejInstanceID)
    if ok then
      add(a1) -- instance display name
      -- Some returns are mapIDs/areaIDs; convert to zone text if possible.
      for _, v in ipairs({a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15}) do
        if type(v) == "number" and GetRealZoneText then
          local zn = GetRealZoneText(v)
          if zn and zn ~= "" then add(zn) end
        end
      end
    end
  end

  return out
end

function CL_GetSavedLockout(instanceID, instanceName, difficultyID)
  if not GetNumSavedInstances or not GetSavedInstanceInfo then return nil end

  -- Instance identity is messy for legacy raids (wings vs parent raid names, etc.).
  -- Build a small set of candidate names (normalized) and match saved instances by any of them.
  local candidates = CL_BuildInstanceNameCandidates(instanceID, instanceName)

  local n = GetNumSavedInstances()
  local wantBucket = CL_DifficultyBucket(difficultyID)
  local bestBucketMatch = nil

  for i = 1, n do
    local name, _, reset, diffID, locked, _, _, _, _, difficultyName, _, _, _, instID = GetSavedInstanceInfo(i)
    if locked then
      local sameInstance = false

      -- Prefer direct numeric match when it actually represents the same instance ID.
      if instID and instanceID and instID == instanceID then
        sameInstance = true
      else
        local nn = CL_NormalizeName(name)
        if nn and candidates and candidates[nn] then
          sameInstance = true
        end
      end

      if sameInstance then
        -- 1) Prefer exact difficulty ID
        if diffID == difficultyID then
          return true, reset, diffID, difficultyName
        end
        -- 2) Otherwise remember a bucket match, but keep searching for an exact match
        local haveBucket = CL_DifficultyBucket(diffID)
        if (not bestBucketMatch) and wantBucket and haveBucket and wantBucket == haveBucket then
          bestBucketMatch = { true, reset, diffID, difficultyName }
        end
      end
    end
  end

  if bestBucketMatch then
    return _unpack(bestBucketMatch)
  end
  return false, nil
end

function CL_FindSavedInstanceIndex(instanceID, instanceName, difficultyID)
  if not GetNumSavedInstances or not GetSavedInstanceInfo then return nil end
  local candidates = CL_BuildInstanceNameCandidates(instanceID, instanceName)
  local n = GetNumSavedInstances()
  local wantBucket = CL_DifficultyBucket(difficultyID)

  local bestBucketMatch = nil
  for i = 1, n do
    local name, _, reset, diffID, locked, _, _, _, _, difficultyName, _, _, _, instID = GetSavedInstanceInfo(i)
    local sameInstance = false
    if instID and instanceID and instID == instanceID then
      sameInstance = true
    else
      local nn = CL_NormalizeName(name)
      if nn and candidates and candidates[nn] then
        sameInstance = true
      end
    end

    -- Boss-by-boss tooltip should only ever attach to an ACTIVE lockout for the CURRENT character.
    -- Some clients can still surface stale/non-locked instance rows around character swaps or before
    -- Raid Info refresh fully settles; if we don't guard on `locked`, the tooltip can incorrectly show
    -- another character's defeated bosses even while the icon correctly says this character is not locked.
    if sameInstance and locked then
      -- 1) Prefer exact difficulty ID
      if diffID == difficultyID then
        return i, reset, diffID, difficultyName, true
      end
      -- 2) Otherwise remember a bucket match, but keep searching in case an exact match exists later
      local haveBucket = CL_DifficultyBucket(diffID)
      if (not bestBucketMatch) and wantBucket and haveBucket and wantBucket == haveBucket then
        bestBucketMatch = { i, reset, diffID, difficultyName, true }
      end
    end
  end

  if bestBucketMatch then
    return _unpack(bestBucketMatch)
  end
  return nil
end

local CL_FormatResetSeconds
local CL_READY_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local CL_NOTREADY_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"

local function CL_BuildSavedEncounterStatus(instanceID, instanceName, difficultyID)
  if not GetSavedInstanceEncounterInfo then return nil end

  local savedIndex, reset, diffID, difficultyName, locked = CL_FindSavedInstanceIndex(instanceID, instanceName, difficultyID)
  if not savedIndex then return nil end

  local _, _, _, _, _, _, _, _, _, _, numEncounters = GetSavedInstanceInfo(savedIndex)
  local encounters = {}

  if type(numEncounters) ~= "number" or numEncounters < 1 then
    return {
      savedIndex = savedIndex,
      reset = reset,
      diffID = diffID,
      difficultyName = difficultyName,
      locked = locked and true or false,
      encounters = encounters,
    }
  end

  for encounterIndex = 1, numEncounters do
    local bossName, _, isKilled = GetSavedInstanceEncounterInfo(savedIndex, encounterIndex)
    if bossName and bossName ~= "" then
      encounters[#encounters + 1] = {
        name = bossName,
        isKilled = isKilled and true or false,
      }
    end
  end

  return {
    savedIndex = savedIndex,
    reset = reset,
    diffID = diffID,
    difficultyName = difficultyName,
    locked = locked and true or false,
    encounters = encounters,
  }
end

local function CL_AddLockoutBossTooltip(tooltip, instanceID, instanceName, difficultyID)
  if not tooltip then return end

  local status = CL_BuildSavedEncounterStatus(instanceID, instanceName, difficultyID)
  if not status then
    tooltip:AddLine("No active lockout", 0.85, 0.85, 0.85)
    return
  end

  if status.reset and status.reset > 0 then
    tooltip:AddLine(("Resets in: %s"):format(CL_FormatResetSeconds(status.reset)), 0.85, 0.85, 0.85)
  end

  tooltip:AddLine(" ")
  tooltip:AddLine("Boss Availability This Lockout", 1, 0.82, 0)

  local encounters = status.encounters or {}
  if #encounters == 0 then
    tooltip:AddLine("No boss data available.", 0.75, 0.75, 0.75)
    return
  end

  for _, encounter in ipairs(encounters) do
    local icon = encounter.isKilled and CL_NOTREADY_TEX or CL_READY_TEX
    local text = ("|T%s:0|t %s"):format(icon, encounter.name)
    if encounter.isKilled then
      tooltip:AddLine(text, 1.0, 0.25, 0.25)
    else
      tooltip:AddLine(text, 0.25, 1.0, 0.25)
    end
  end

  tooltip:AddLine(" ")
  tooltip:AddLine(("|T%s:0|t Alive / available"):format(CL_READY_TEX), 0.75, 0.75, 0.75)
  tooltip:AddLine(("|T%s:0|t Dead / defeated"):format(CL_NOTREADY_TEX), 0.75, 0.75, 0.75)
end


CL_FormatResetSeconds = function(sec)
  if not sec or sec <= 0 then return "Unknown" end
  local d = math.floor(sec / 86400); sec = sec - d * 86400
  local h = math.floor(sec / 3600);  sec = sec - h * 3600
  local m = math.floor(sec / 60)
  if d > 0 then
    return string.format("%dd %dh", d, h)
  elseif h > 0 then
    return string.format("%dh %dm", h, m)
  else
    return string.format("%dm", m)
  end
end

-- CollectionLog_UI.lua (OSRS-style layout with centered collected counter)
local ADDON, ns = ...
ns.UI = ns.UI or {}

-- Use a local reference for the UI table early (do NOT rely on a global `UI`)
local UI = ns.UI

function UI.UpdateActiveGroupVisuals(oldGroupId, newGroupId)
  if not UI or not UI.groupRows then return end

  local cat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
  local oldKey = oldGroupId ~= nil and tostring(oldGroupId) or nil
  local newKey = newGroupId ~= nil and tostring(newGroupId) or nil

  for _, row in ipairs(UI.groupRows) do
    local btn = row and row.button or nil
    local btnId = btn and btn.groupId or nil
    local btnKey = btnId ~= nil and tostring(btnId) or nil
    if btn and btn:IsShown() and btnKey and (btnKey == oldKey or btnKey == newKey) then
      if UI.RefreshVisibleGroupButtonState then
        UI.RefreshVisibleGroupButtonState(btn, cat)
      end
      -- v4.3.84: row clicks intentionally avoid a full BuildGroupList() for CPU reasons,
      -- but that also meant the right-aligned N/H/M/TW difficulty strip could keep
      -- stale/neutral colors until the difficulty dropdown forced a list rebuild.
      -- Repaint only the affected visible row from the existing cache. This does not
      -- call TrueCollection or perform live lookups.
      if (cat == "Raids" or cat == "Dungeons") and CLOG_RepaintDifficultyIndicatorForGroup then
        CLOG_RepaintDifficultyIndicatorForGroup(btnKey)
      end
    end
  end
end

-- Housing performance cache (non-blocking scan)
UI._housingPerf = UI._housingPerf or {
  started = false,
  done = false,
  scanning = false,
  ticker = nil,
  pendingRefresh = false,
  cache = {},      -- [itemID] = true/false
  total = 0,
  collected = 0,
  items = nil,     -- array of itemIDs
  idx = 1,
}

local function UI_HousingGetItems()
  if UI._housingPerf.items and type(UI._housingPerf.items) == "table" and #UI._housingPerf.items > 0 then
    return UI._housingPerf.items
  end
  local g = ns and ns.Data and ns.Data.groups and ns.Data.groups["housing:all"] or nil
  local src = g and g.items or nil
  if type(src) ~= "table" then return nil end

  -- Deduplicate and keep stable order
  local out, seen = {}, {}
  for _, itemID in ipairs(src) do
    if itemID and not seen[itemID] then
      seen[itemID] = true
      out[#out+1] = itemID
    end
  end
  UI._housingPerf.items = out
  UI._housingPerf.total = #out
  return out
end

local function UI_HousingIsCollectedNow(itemID)
  if not itemID then return false end
  if ns and ns.IsHousingCollected then
    local ok, res = pcall(ns.IsHousingCollected, itemID)
    if ok then return res and true or false end
  end
  if ns and ns.IsCollected then
    local ok, res = pcall(ns.IsCollected, itemID)
    if ok then return res and true or false end
  end
  return false
end

function UI.GetHousingProgressCached(force)
  local hp = UI._housingPerf
  local items = UI_HousingGetItems()
  if not items then return 0, 0, true end

  local now = (GetTime and GetTime()) or 0
  if (not force) and hp and hp.done and hp.cache and hp.total and hp.lastFullScan and (now - hp.lastFullScan) < 5.00 then
    return hp.collected or 0, hp.total or #items, true
  end

  -- Always compute Housing collected state from live truth (ns:IsHousingDecorCollected / ns:IsCollected),
  -- but do not repeat the full decor pass multiple times inside the same UI refresh burst.

  -- Cancel any legacy ticker scan if it was started previously.
  if hp and hp.ticker then
    pcall(function() hp.ticker:Cancel() end)
    hp.ticker = nil
  end

  hp.started = true
  hp.scanning = false
  hp.done = true
  hp.idx = #items + 1
  hp.total = #items
  hp.cache = hp.cache or {}

  local collected = 0
  local map = (ns and ns.HousingCollectedByItemID) or (ns and ns.HousingOwnedByItemID) or nil
  for i = 1, #items do
    local itemID = items[i]
    local c = UI_HousingIsCollectedNow(itemID)
    hp.cache[itemID] = c
    if c then
      collected = collected + 1
      -- Repair stale in-memory maps (session-only) so other callers remain consistent.
      if map then map[itemID] = true end
    end
  end

  hp.collected = collected
  hp.lastFullScan = (GetTime and GetTime()) or now or 0
  return collected, hp.total or 0, true
end

function UI.HousingIsCollectedCached(itemID)
  if not itemID then return false end
  local hp = UI._housingPerf
  if hp and hp.cache and hp.cache[itemID] ~= nil then
    return hp.cache[itemID] and true or false
  end
  local map = (ns and ns.HousingCollectedByItemID) or (ns and ns.HousingOwnedByItemID) or nil
  if map and map[itemID] == true then
    return true
  end
  -- Ensure cache is built (synchronous)
  UI.GetHousingProgressCached()
  if hp and hp.cache and hp.cache[itemID] ~= nil then
    return hp.cache[itemID] and true or false
  end
  return false
end


-- Collection Log: ensure Pet Journal filters do not persist across opens/reloads.
ns.ClearAllPetJournalFilters = ns.ClearAllPetJournalFilters or function()
  if not C_PetJournal then return end

  -- Clear search box (UI) + API filter
  if PetJournalSearchBox and PetJournalSearchBox.SetText then
    pcall(PetJournalSearchBox.SetText, PetJournalSearchBox, "")
    if PetJournalSearchBox.ClearFocus then pcall(PetJournalSearchBox.ClearFocus, PetJournalSearchBox) end
  end
  if C_PetJournal.ClearSearchFilter then
    pcall(C_PetJournal.ClearSearchFilter)
  elseif C_PetJournal.SetSearchFilter then
    pcall(C_PetJournal.SetSearchFilter, "")
  end

  -- Reset all type/source filters
  if C_PetJournal.SetAllPetTypesChecked then
    pcall(C_PetJournal.SetAllPetTypesChecked, true)
  end
  if C_PetJournal.SetAllPetSourcesChecked then
    pcall(C_PetJournal.SetAllPetSourcesChecked, true)
  end
end

ns.HookPetJournalFilterCleanup = ns.HookPetJournalFilterCleanup or function()
  if not PetJournal or PetJournal.__CollectionLog_FilterCleanupHooked then return end
  PetJournal.__CollectionLog_FilterCleanupHooked = true
  PetJournal:HookScript("OnHide", function()
    if ns.ClearAllPetJournalFilters then ns.ClearAllPetJournalFilters() end
  end)
end


local function CL_GetQualityColor(itemID)
  if not itemID then return nil end
  if C_Item and C_Item.GetItemQualityByID then
    local q = C_Item.GetItemQualityByID(itemID)
    if q == nil then return nil end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then return c.r, c.g, c.b end
  end
  return nil
end



-- Resolve backing itemID for Mounts/Pets when possible (used for quality coloring).
local function CL_GetMountItemID(mountID)
  if not mountID then return nil end
  if C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
    local ok, a,b,c,d,e,f,g,h,i,itemID = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
    if ok then return itemID end
  end
  return nil
end

local function CL_GetPetItemID(speciesID)
  if not speciesID then return nil end
  if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
    local ok, name, icon, petType, creatureID, sourceText, description, isWild, canBattle, tradable, unique, obtainable, itemID = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
    if ok then return itemID end
  end
  return nil
end

local Wishlist = {}

do
local function EnsureWishlistState()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.wishlist = CollectionLogDB.wishlist or {}
  CollectionLogDB.wishlist.entries = CollectionLogDB.wishlist.entries or {}
  return CollectionLogDB.wishlist
end

local function EnsureWishlistDB()
  local state = EnsureWishlistState()
  return state.entries
end

local function EnsureTrackedStore()
  if type(_G.CollectionLog_Tracked) ~= "table" then
    _G.CollectionLog_Tracked = {}
  end
  local store = _G.CollectionLog_Tracked
  if type(store.entries) ~= "table" then store.entries = {} end
  if type(store.order) ~= "table" then store.order = {} end
  return store
end

local function WishlistMigrateLegacyTrackedStore()
  local store = EnsureTrackedStore()
  if (type(store.key) ~= "string" or store.key == "") then
    local state = EnsureWishlistState()
    if type(state.trackedKey) == "string" and state.trackedKey ~= "" then
      store.key = state.trackedKey
      state.trackedKey = nil
    end
  end
  if type(store.key) == "string" and store.key ~= "" then
    local key = tostring(store.key)
    if type(store.entries[key]) ~= "table" then
      local copy = {}
      for k, v in pairs(store) do
        if k ~= "entries" and k ~= "order" then copy[k] = v end
      end
      copy.key = key
      store.entries[key] = copy
    end
    local seen = false
    for _, existing in ipairs(store.order) do
      if existing == key then seen = true break end
    end
    if not seen then table.insert(store.order, 1, key) end
    store.key = nil
  end
  return store
end

local function WishlistGetTrackedKeys()
  local store = WishlistMigrateLegacyTrackedStore()
  local keys = {}
  local seen = {}
  for _, key in ipairs(store.order) do
    if type(key) == "string" and key ~= "" and type(store.entries[key]) == "table" and not seen[key] then
      seen[key] = true
      table.insert(keys, key)
    end
  end
  for key, data in pairs(store.entries) do
    if type(key) == "string" and key ~= "" and type(data) == "table" and not seen[key] then
      seen[key] = true
      table.insert(keys, key)
    end
  end
  store.order = keys
  return keys
end

local function WishlistSetTrackedKeys(keys)
  local store = EnsureTrackedStore()
  store.order = {}
  local seen = {}
  if type(keys) == "table" then
    for _, key in ipairs(keys) do
      if type(key) == "string" and key ~= "" and not seen[key] then
        seen[key] = true
        table.insert(store.order, key)
      end
    end
  end
end

local function WishlistIsTrackedKey(key)
  if not key then return false end
  key = tostring(key)
  local store = WishlistMigrateLegacyTrackedStore()
  return type(store.entries[key]) == "table"
end

local function WishlistClearTrackedWaypoint()
  if C_Map and C_Map.ClearUserWaypoint then
    pcall(C_Map.ClearUserWaypoint)
  end
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, false)
  end
end

local function WishlistClearTrackedData()
  local store = EnsureTrackedStore()
  for k in pairs(store.entries) do store.entries[k] = nil end
  store.order = {}
  WishlistClearTrackedWaypoint()
end

local function WishlistMakeKey(kind, id)
  if not kind or id == nil then return nil end
  return tostring(kind) .. ":" .. tostring(id)
end

local function WishlistGetEntry(key)
  if not key then return nil end
  local entries = Wishlist.EnsureWishlistDB()
  local entry = entries[key]
  if entry == true then
    local kind, rawID = tostring(key):match("^(.-):(.-)$")
    entry = { kind = kind, id = tonumber(rawID) or rawID }
    entries[key] = entry
  end
  return entry
end

local function WishlistContainsKey(key)
  if not key then return false end
  local entries = Wishlist.EnsureWishlistDB()
  return entries[key] ~= nil
end

local function WishlistRemoveKey(key)
  if not key then return end
  key = tostring(key)
  local entries = Wishlist.EnsureWishlistDB()
  entries[key] = nil
  if Wishlist.IsTrackedKey(key) then
    local store = EnsureTrackedStore()
    store.entries[key] = nil
    local nextOrder = {}
    for _, existing in ipairs(WishlistGetTrackedKeys()) do
      if existing ~= key then
        table.insert(nextOrder, existing)
      end
    end
    store.order = nextOrder
    if #nextOrder == 0 then
      WishlistClearTrackedWaypoint()
    end
  end
end

local function WishlistGetAppearanceCollected(appearanceID, itemID)
  appearanceID = tonumber(appearanceID or 0) or 0
  if appearanceID > 0 and C_TransmogCollection and C_TransmogCollection.GetAppearanceInfoByID then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
    if ok and type(info) == "table" and info.isCollected ~= nil then
      return info.isCollected and true or false
    end
    local ok2, a,b,c,isCollected = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
    if ok2 and isCollected ~= nil then
      return isCollected and true or false
    end
  end
  if itemID and ns and ns.IsAppearanceCollected then
    return ns.IsAppearanceCollected(itemID) and true or false
  end
  return false
end

local function WishlistTrimText(s)
  if s == nil then return nil end
  s = tostring(s):gsub('^%s+', ''):gsub('%s+$', '')
  if s == '' then return nil end
  return s
end

local function WishlistStripRichText(s)
  s = Wishlist.TrimText(s)
  if not s then return nil end
  s = s:gsub('\124n', '\n')
  s = s:gsub('\124c%x%x%x%x%x%x%x%x', '')
  s = s:gsub('\124r', '')
  s = s:gsub('\124T.-\124t', '')
  s = s:gsub('\124A.-\124a', '')
  s = s:gsub('\124H.-\124h', '')
  s = s:gsub('\124h', '')
  s = s:gsub('%s+', ' ')
  s = s:gsub(' *\n *', '\n')
  return Wishlist.TrimText(s)
end

local function WishlistGetGroupSourceLabel(group)
  if type(group) ~= 'table' then return nil, nil end
  local instanceName = Wishlist.TrimText(group.name or group.label or group.title)
  if not instanceName then return nil, nil end
  local short = nil
  if type(DifficultyShortLabel) == 'function' and (group.difficultyID or group.mode) then
    short = DifficultyShortLabel(group.difficultyID, group.mode)
  end
  short = Wishlist.TrimText(short)
  if short and short ~= '' then
    return string.format('%s (%s)', instanceName, short), short
  end
  return instanceName, nil
end

local function WishlistNormalizeSourceValue(value)
  value = WishlistStripRichText(value)
  if not value then return nil end
  value = value:gsub('^.-Location:%s*', '')
  value = value:gsub('%s+Zone:%s*%S+', '')
  value = value:gsub('%s+Cost:%s*%S+', '')
  value = value:gsub('%s*%(%)', '')
  value = value:gsub('%s*%(%)', '')
  value = value:gsub('%s*%(%)', '')
  value = value:gsub('%s*%((Looking For Raid)%)', '')
  value = value:gsub('%s*%((Timewalking)%)', ' (TW)')
  value = value:gsub('%s+', ' ')
  value = Wishlist.TrimText(value)
  if value == '' then return nil end
  return value
end

local function WishlistParseSourceText(sourceText)
  sourceText = WishlistStripRichText(sourceText)
  if not sourceText then return nil end
  local lines = {}
  for line in sourceText:gmatch('[^\n]+') do
    line = Wishlist.TrimText(line)
    if line then lines[#lines + 1] = line end
  end
  if #lines == 0 then return nil end

  local function matchLine(prefix)
    for _, line in ipairs(lines) do
      local value = line:match('^' .. prefix .. ':%s*(.+)$')
      value = Wishlist.NormalizeSourceValue(value)
      if value then return value end
    end
  end

  local vendor = matchLine('Vendor')
  if vendor then return 'Vendor: ' .. vendor end

  local quest = matchLine('Quest')
  if quest then return 'Quest: ' .. quest end

  local achievement = matchLine('Achievement')
  if achievement then return 'Achievement: ' .. achievement end

  local profession = matchLine('Profession')
  if profession then return 'Profession: ' .. profession end

  local reputation = matchLine('Faction') or matchLine('Reputation')
  if reputation then return reputation end

  local rare = matchLine('Rare')
  if rare then return 'Rare: ' .. rare end

  local boss = matchLine('Boss')
  if boss then return boss end

  local drop = matchLine('Drop')
  if drop then
    if drop == 'Boss Drop' then
      local bossName = matchLine('Boss') or matchLine('Rare')
      if bossName then return bossName end
    end
    return drop
  end

  for _, line in ipairs(lines) do
    if not line:match('^Location:') and not line:match('^Zone:') and not line:match('^Cost:') then
      local cleaned = Wishlist.NormalizeSourceValue(line)
      if cleaned then return cleaned end
    end
  end

  return Wishlist.NormalizeSourceValue(lines[1])
end

local WISHLIST_BROAD_SOURCE_LABELS = {
  ['Mount'] = true, ['Mounts'] = true,
  ['Pet'] = true, ['Pets'] = true,
  ['Toy'] = true, ['Toys'] = true,
  ['Housing'] = true,
  ['Appearance'] = true, ['Appearances'] = true, ['Appearance Set'] = true,
  ['Item'] = true, ['Items'] = true,
  ['Unknown'] = true, ['Unknown Source'] = true,
}

local function WishlistGetExactSourceFromEntry(entry)
  if type(entry) ~= 'table' then return nil end

  local captured = Wishlist.NormalizeSourceValue(entry.capturedSource)
  if captured and not WISHLIST_BROAD_SOURCE_LABELS[captured] and captured ~= 'Unknown' then return captured end

  local instanceName = Wishlist.NormalizeSourceValue(entry.instanceName or entry.sourceName)
  local diff = Wishlist.TrimText(entry.sourceDifficulty)
  if not diff and entry.difficultyID and type(DifficultyShortLabel) == 'function' then
    diff = Wishlist.TrimText(DifficultyShortLabel(entry.difficultyID, entry.mode))
  end
  if instanceName then
    local patternDiff = diff and diff:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1')
    if diff and diff ~= '' and not instanceName:find('%(' .. patternDiff .. '%)$') then
      return string.format('%s (%s)', instanceName, diff)
    end
    return instanceName
  end

  if entry.kind == 'mount' then
    local mountID = tonumber(entry.mountID or entry.id or 0) or 0
    local rawSource = nil
    if mountID > 0 and C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
      local ok, _, descriptionText, sourceText = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
      if ok then rawSource = sourceText or descriptionText end
    end
    if (not rawSource or rawSource == '') and ns and ns.CompletionMountDB and ns.CompletionMountDB.GetByMountID then
      local db = ns.CompletionMountDB.GetByMountID(mountID)
      rawSource = db and db.sourceText or rawSource
    end
    local parsed = WishlistParseSourceText(rawSource)
    if parsed then return parsed end
  elseif entry.kind == 'pet' then
    local speciesID = tonumber(entry.petSpeciesID or entry.id or 0) or 0
    if speciesID > 0 and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
      local ok, _, _, _, _, sourceText = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
      if ok then
        local parsed = WishlistParseSourceText(sourceText)
        if parsed then return parsed end
      end
    end
  elseif entry.category == 'Toys' then
    local itemID = tonumber(entry.itemID or entry.id or 0) or 0
    if itemID > 0 and ns and ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get then
      local row = ns.CompletionToyItemDB.Get(itemID)
      local parsed = WishlistParseSourceText(row and row.sourceText or nil)
      if parsed then return parsed end
    end
  end

  local sourceLabel = Wishlist.NormalizeSourceValue(entry.sourceLabel)
  if sourceLabel and not WISHLIST_BROAD_SOURCE_LABELS[sourceLabel] and sourceLabel ~= 'Unknown' then return sourceLabel end

  local generic = Wishlist.NormalizeSourceValue(entry.source)
  if generic and not WISHLIST_BROAD_SOURCE_LABELS[generic] and generic ~= 'Unknown' then return generic end
  return nil
end

local function WishlistGetDisplayType(entry)
  if type(entry) ~= 'table' then return 'Item' end

  local itemID = tonumber(entry.itemID or entry.id or 0) or 0
  if itemID > 0 and ns and ns.CompletionAppearanceItemDB and ns.CompletionAppearanceItemDB.Get then
    local ok, appearanceData = pcall(ns.CompletionAppearanceItemDB.Get, itemID)
    if ok and type(appearanceData) == 'table' and tonumber(appearanceData.appearanceID or 0) > 0 then
      return 'Appearance'
    end
  end

  local explicit = Wishlist.TrimText(entry.displayType)
  if explicit == 'Appearance Set' or explicit == 'Appearances' then return 'Appearance' end
  if explicit == 'Mounts' then return 'Mount' end
  if explicit == 'Pets' then return 'Pet' end
  if explicit == 'Toys' then return 'Toy' end
  if explicit == 'Housing' then return 'Housing' end
  if explicit then return explicit end

  local category = Wishlist.TrimText(entry.category)
  if category == 'Appearances' then return 'Appearance' end
  if category == 'Mounts' then return 'Mount' end
  if category == 'Pets' then return 'Pet' end
  if category == 'Toys' then return 'Toy' end
  if category == 'Housing' then return 'Housing' end
  if entry.kind == 'appearance' then return 'Appearance' end
  if entry.kind == 'mount' then return 'Mount' end
  if entry.kind == 'pet' then return 'Pet' end

  local fallback = CLOG_GetHistoryTypeText and CLOG_GetHistoryTypeText(entry) or nil
  fallback = Wishlist.TrimText(fallback)
  if fallback == 'Appearance Set' or fallback == 'Appearances' then return 'Appearance' end
  if fallback == 'Mounts' then return 'Mount' end
  if fallback == 'Pets' then return 'Pet' end
  if fallback == 'Toys' then return 'Toy' end
  if fallback then return fallback end
  return 'Item'
end

local function WishlistBuildPayloadFromCell(cell)
  if not cell then return nil end
  if cell.wishlistKey and cell.wishlistPayload then
    return cell.wishlistKey, cell.wishlistPayload
  end
  local activeCat = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory) or nil
  local activeGroupId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
  local activeGroup = (activeGroupId and ns and ns.Data and ns.Data.groups and ns.Data.groups[activeGroupId]) or nil
  local sourceName = nil
  local sourceLabel = nil
  local sourceDifficulty = nil
  local capturedSource = nil
  if activeGroup then
    sourceLabel, sourceDifficulty = WishlistGetGroupSourceLabel(activeGroup)
    sourceName = Wishlist.TrimText(activeGroup.name or activeGroup.label or activeGroup.title)
    capturedSource = sourceLabel or sourceName
  elseif cell.section and tostring(cell.section) ~= "" then
    sourceName = tostring(cell.section)
    sourceLabel = sourceName
  end

  if cell.appearanceEntry then
    local appearanceID = tonumber(cell.appearanceEntry.appearanceID or 0) or 0
    local itemID = tonumber(cell.appearanceEntry.itemID or cell.itemID or 0) or 0
    if appearanceID > 0 then
      local key = WishlistMakeKey("appearance", appearanceID)
      return key, {
        kind = "appearance",
        id = appearanceID,
        appearanceID = appearanceID,
        itemID = itemID > 0 and itemID or nil,
        category = "Appearances",
        displayType = "Appearance",
        source = sourceLabel or sourceName,
        sourceName = sourceName,
        sourceLabel = sourceLabel,
        sourceDifficulty = sourceDifficulty,
        capturedSource = capturedSource,
        instanceName = sourceName,
        mapID = activeGroup and activeGroup.mapID or nil,
        ejInstanceID = activeGroup and activeGroup.instanceID or nil,
        difficultyID = activeGroup and activeGroup.difficultyID or nil,
      }
    end
    if itemID > 0 then
      local key = WishlistMakeKey("item", itemID)
      return key, {
        kind = "item",
        id = itemID,
        itemID = itemID,
        category = "Appearances",
        displayType = "Appearance",
        source = sourceLabel or sourceName,
        sourceName = sourceName,
        sourceLabel = sourceLabel,
        sourceDifficulty = sourceDifficulty,
        capturedSource = capturedSource,
        instanceName = sourceName,
        mapID = activeGroup and activeGroup.mapID or nil,
        ejInstanceID = activeGroup and activeGroup.instanceID or nil,
        difficultyID = activeGroup and activeGroup.difficultyID or nil,
      }
    end
  end

  if cell.mountID then
    local mountID = tonumber(cell.mountID)
    if mountID and mountID > 0 then
      local key = WishlistMakeKey("mount", mountID)
      return key, {
        kind = "mount",
        id = mountID,
        mountID = mountID,
        itemID = CL_GetMountItemID(mountID),
        category = "Mounts",
        displayType = "Mount",
        source = sourceLabel or sourceName,
        sourceName = sourceName,
        sourceLabel = sourceLabel,
        sourceDifficulty = sourceDifficulty,
        capturedSource = capturedSource,
        instanceName = sourceName,
        mapID = activeGroup and activeGroup.mapID or nil,
        ejInstanceID = activeGroup and activeGroup.instanceID or nil,
        difficultyID = activeGroup and activeGroup.difficultyID or nil,
      }
    end
  end

  if cell.petSpeciesID then
    local speciesID = tonumber(cell.petSpeciesID)
    if speciesID and speciesID > 0 then
      local key = WishlistMakeKey("pet", speciesID)
      return key, {
        kind = "pet",
        id = speciesID,
        petSpeciesID = speciesID,
        itemID = CL_GetPetItemID(speciesID),
        category = "Pets",
        displayType = "Pet",
        source = sourceLabel or sourceName,
        sourceName = sourceName,
        sourceLabel = sourceLabel,
        sourceDifficulty = sourceDifficulty,
        capturedSource = capturedSource,
        instanceName = sourceName,
        mapID = activeGroup and activeGroup.mapID or nil,
        ejInstanceID = activeGroup and activeGroup.instanceID or nil,
        difficultyID = activeGroup and activeGroup.difficultyID or nil,
      }
    end
  end

  if cell.itemID then
    local itemID = tonumber(cell.itemID)
    if itemID and itemID > 0 then
      local key = WishlistMakeKey("item", itemID)
      return key, {
        kind = "item",
        id = itemID,
        itemID = itemID,
        category = activeCat or cell.section or "Items",
        displayType = ((activeCat == "Raids" or activeCat == "Dungeons") and cell.section ~= "Mounts" and cell.section ~= "Pets" and cell.section ~= "Toys" and cell.section ~= "Housing") and "Appearance"
          or ((activeCat == "Toys" or cell.section == "Toys") and "Toy")
          or ((activeCat == "Housing" or cell.section == "Housing") and "Housing")
          or ((activeCat == "Raids" or activeCat == "Dungeons") and (cell.section == "Mounts" and "Mount" or cell.section == "Pets" and "Pet" or cell.section == "Toys" and "Toy" or cell.section == "Housing" and "Housing"))
          or (activeCat == "Appearances" and "Appearance")
          or ((activeCat == "Mounts" or cell.section == "Mounts") and "Mount")
          or ((activeCat == "Pets" or cell.section == "Pets") and "Pet")
          or ((activeCat == "Toys" or cell.section == "Toys") and "Toy")
          or (activeCat == "Appearances" and "Appearance")
          or (activeCat or cell.section or "Items"),
        source = sourceLabel or sourceName,
        sourceName = sourceName,
        sourceLabel = sourceLabel,
        sourceDifficulty = sourceDifficulty,
        capturedSource = capturedSource,
        instanceName = sourceName,
        mapID = activeGroup and activeGroup.mapID or nil,
        ejInstanceID = activeGroup and activeGroup.instanceID or nil,
        difficultyID = activeGroup and activeGroup.difficultyID or nil,
      }
    end
  end

  return nil
end

local function WishlistIsEntryCollected(entry)
  if type(entry) ~= "table" then return false end

  if entry.kind == "mount" then
    local mountID = tonumber(entry.mountID or entry.id or 0) or 0
    if mountID > 0 and C_MountJournal and C_MountJournal.GetMountInfoByID then
      local ok, _, _, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
      if ok and isCollected ~= nil then
        return isCollected and true or false
      end
    end
    return false
  elseif entry.kind == "pet" then
    local speciesID = tonumber(entry.petSpeciesID or entry.id or 0) or 0
    if speciesID > 0 and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
      local ok, numCollected = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
      if ok and type(numCollected) == "number" then
        return numCollected > 0
      end
    end
    return false
  elseif entry.kind == "appearance" then
    local appearanceID = tonumber(entry.appearanceID or entry.id or 0) or 0
    local itemID = tonumber(entry.itemID or 0) or 0
    return Wishlist.GetAppearanceCollected(appearanceID, itemID > 0 and itemID or nil)
  end

  local itemID = tonumber(entry.itemID or entry.id or 0) or 0
  if itemID <= 0 then return false end

  if entry.category == "Toys" then
    return (ns and ns.IsToyCollected and ns.IsToyCollected(itemID)) and true or false
  elseif entry.category == "Housing" then
    return (ns and ns.IsHousingCollected and ns.IsHousingCollected(itemID)) and true or false
  elseif entry.category == "Appearances" then
    return (ns and ns.IsAppearanceCollected and ns.IsAppearanceCollected(itemID)) and true or false
  end

  if ns and ns.IsToyCollected and ns.IsToyCollected(itemID) then
    return true
  end
  if ns and ns.IsCollected then
    return ns.IsCollected(itemID) and true or false
  end
  return false
end

local function WishlistPruneCollectedEntries()
  local entries = Wishlist.EnsureWishlistDB()
  local removed = false
  for key, entry in pairs(entries) do
    local normalized = entry
    if entry == true then
      normalized = WishlistGetEntry(key)
    end
    if type(normalized) == "table" and WishlistIsEntryCollected(normalized) then
      Wishlist.RemoveKey(key)
      removed = true
    end
  end
  return removed
end

local function WishlistAddFromCell(cell)
  local key, payload = Wishlist.BuildPayloadFromCell(cell)
  if not key or not payload then return end
  if WishlistIsEntryCollected(payload) then
    Wishlist.RemoveKey(key)
    return
  end
  local legacyItemKey = nil
  if payload.kind == "mount" or payload.kind == "pet" then
    local legacyItemID = tonumber(payload.itemID or 0) or 0
    if legacyItemID > 0 then
      legacyItemKey = WishlistMakeKey("item", legacyItemID)
    end
  end
  local entries = Wishlist.EnsureWishlistDB()
  if legacyItemKey and legacyItemKey ~= key then
    entries[legacyItemKey] = nil
  end
  entries[key] = payload
end

local function WishlistRemoveFromCell(cell)
  local key, payload = Wishlist.BuildPayloadFromCell(cell)
  if key then
    Wishlist.RemoveKey(key)
  end
  if type(payload) == "table" and (payload.kind == "mount" or payload.kind == "pet") then
    local legacyItemID = tonumber(payload.itemID or 0) or 0
    if legacyItemID > 0 then
      Wishlist.RemoveKey(WishlistMakeKey("item", legacyItemID))
    end
  end
end

local function WishlistContainsCell(cell)
  local key, payload = Wishlist.BuildPayloadFromCell(cell)
  if Wishlist.ContainsKey(key) then
    return true
  end

  local candidateKeys = {}
  local seen = {}
  local function addCandidate(kind, id)
    id = tonumber(id or 0) or 0
    if id <= 0 then return end
    local candidate = WishlistMakeKey(kind, id)
    if candidate and not seen[candidate] then
      seen[candidate] = true
      candidateKeys[#candidateKeys + 1] = candidate
    end
  end

  payload = type(payload) == "table" and payload or (cell and cell.wishlistPayload) or nil

  addCandidate("item", cell and cell.itemID)
  addCandidate("mount", cell and cell.mountID)
  addCandidate("pet", cell and cell.petSpeciesID)

  if type(payload) == "table" then
    addCandidate(payload.kind, payload.id)
    addCandidate("item", payload.itemID)
    addCandidate("mount", payload.mountID)
    addCandidate("pet", payload.petSpeciesID)
    addCandidate("appearance", payload.appearanceID)
  end

  if cell and cell.appearanceEntry then
    addCandidate("appearance", cell.appearanceEntry.appearanceID)
    addCandidate("item", cell.appearanceEntry.itemID)
  end

  if cell and cell.section == "Mounts" then
    addCandidate("mount", cell.mountID or (cell.itemID and CL_ResolveMountIDFromItemID and CL_ResolveMountIDFromItemID(cell.itemID)))
  elseif cell and cell.section == "Pets" then
    addCandidate("pet", cell.petSpeciesID or (cell.itemID and CL_ResolvePetSpeciesIDFromItemID and CL_ResolvePetSpeciesIDFromItemID(cell.itemID)))
  end

  for _, candidate in ipairs(candidateKeys) do
    if Wishlist.ContainsKey(candidate) then
      return true
    end
  end

  local cellItemID = tonumber((cell and cell.itemID) or (type(payload) == "table" and payload.itemID) or (cell and cell.appearanceEntry and cell.appearanceEntry.itemID) or 0) or 0
  local cellMountID = tonumber((cell and cell.mountID) or (type(payload) == "table" and payload.mountID) or 0) or 0
  local cellPetSpeciesID = tonumber((cell and cell.petSpeciesID) or (type(payload) == "table" and payload.petSpeciesID) or 0) or 0
  local cellAppearanceID = tonumber((type(payload) == "table" and payload.appearanceID) or (cell and cell.appearanceEntry and cell.appearanceEntry.appearanceID) or 0) or 0

  local function entryMatches(entry)
    if type(entry) ~= "table" then return false end
    local entryItemID = tonumber(entry.itemID or ((entry.kind == "item") and entry.id) or 0) or 0
    local entryMountID = tonumber(entry.mountID or ((entry.kind == "mount") and entry.id) or 0) or 0
    local entryPetSpeciesID = tonumber(entry.petSpeciesID or ((entry.kind == "pet") and entry.id) or 0) or 0
    local entryAppearanceID = tonumber(entry.appearanceID or ((entry.kind == "appearance") and entry.id) or 0) or 0

    if cellAppearanceID > 0 and entryAppearanceID > 0 and cellAppearanceID == entryAppearanceID then
      return true
    end
    if cellMountID > 0 and entryMountID > 0 and cellMountID == entryMountID then
      return true
    end
    if cellPetSpeciesID > 0 and entryPetSpeciesID > 0 and cellPetSpeciesID == entryPetSpeciesID then
      return true
    end
    if cellItemID > 0 and entryItemID > 0 and cellItemID == entryItemID then
      return true
    end
    return false
  end

  local entries = Wishlist.EnsureWishlistDB()
  for storedKey, storedEntry in pairs(entries) do
    local entry = storedEntry
    if entry == true then
      entry = WishlistGetEntry(storedKey)
    end
    if entryMatches(entry) then
      return true
    end
  end

  local trackedStore = EnsureTrackedStore()
  for _, trackedEntry in pairs(trackedStore.entries or {}) do
    if entryMatches(trackedEntry) then
      return true
    end
  end

  return false
end

local function CLOG_ClearWishlistIdentity(cell)
  if not cell then return end
  cell.itemID = nil
  cell.mountID = nil
  cell.petSpeciesID = nil
  cell.appearanceEntry = nil
  cell.groupId = nil
  cell.section = nil
  cell.wishlistKey = nil
  cell.wishlistPayload = nil
end

local function CLOG_AssignWishlistIdentity(cell, key, payload)
  if not cell then return end
  cell.wishlistKey = key
  cell.wishlistPayload = payload
end



local function WishlistGetWaypointTarget(entry)
  if type(entry) ~= 'table' then return nil end
  local storedMapID = tonumber(entry.uiMapID or entry.mapID or 0) or 0
  local storedX = tonumber(entry.x)
  local storedY = tonumber(entry.y)
  if storedMapID > 0 and storedX and storedY then
    return storedMapID, storedX, storedY, nil
  end
  local instanceID = tonumber(entry.ejInstanceID or entry.instanceID or 0) or 0
  if instanceID <= 0 then return nil end
  local resolvedEntrance = Wishlist.ResolveJournalEntrance(instanceID)
  if not resolvedEntrance then return nil end
  local uiMapID, x, y = Wishlist.TryConvertJournalEntranceToWaypoint(resolvedEntrance)
  if not (uiMapID and x and y) then return nil end
  return uiMapID, x, y, resolvedEntrance
end

local function WishlistEntryHasWaypoint(entry)
  return WishlistGetWaypointTarget(entry) ~= nil
end

local function WishlistOpenWaypoint(entry)
  local uiMapID, x, y = WishlistGetWaypointTarget(entry)
  if not (uiMapID and x and y) then return false end
  return Wishlist.ShowWorldMapToWaypoint(uiMapID, x, y) and true or false
end

local function WishlistSetTrackedWaypointOnly(entry)
  local uiMapID, x, y = WishlistGetWaypointTarget(entry)
  if not (uiMapID and x and y and UiMapPoint and UiMapPoint.CreateFromCoordinates and C_Map and C_Map.SetUserWaypoint) then
    return false
  end
  local point = UiMapPoint.CreateFromCoordinates(uiMapID, x, y)
  if not point then return false end
  local ok = pcall(C_Map.SetUserWaypoint, point)
  if not ok then return false end
  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
  end
  return true
end

local function WishlistCanTrackEntry(entry)
  return type(entry) == "table" and entry.key ~= nil
end

local function WishlistBuildTrackedData(entry)
  if type(entry) ~= "table" or not entry.key then return nil end
  local uiMapID, x, y = WishlistGetWaypointTarget(entry)
  local sourceText = Wishlist.GetExactSourceFromEntry(entry) or Wishlist.NormalizeSourceValue(entry.source) or "Unknown Source"
  local displayName = nil
  if entry.kind == "mount" and entry.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
    local ok, name = pcall(C_MountJournal.GetMountInfoByID, entry.mountID)
    if ok and type(name) == "string" and name ~= "" then displayName = name end
  elseif entry.kind == "pet" and entry.petSpeciesID and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
    local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, entry.petSpeciesID)
    if ok and type(name) == "string" and name ~= "" then displayName = name end
  elseif entry.itemID and GetItemInfo then
    local name = GetItemInfo(entry.itemID)
    if type(name) == "string" and name ~= "" then
      displayName = name
    elseif C_Item and C_Item.RequestLoadItemDataByID then
      pcall(C_Item.RequestLoadItemDataByID, entry.itemID)
    end
  end
  if not displayName then
    local fallback = entry.name or entry.displayName or entry.itemName or entry.label or entry.title
    if type(fallback) == "string" and fallback ~= "" and fallback ~= "Tracked Item" then
      displayName = fallback
    end
  end
  if not displayName and entry.appearanceID then
    displayName = "Appearance " .. tostring(entry.appearanceID)
  end
  local data = {
    key = entry.key,
    kind = entry.kind,
    id = entry.id,
    itemID = entry.itemID,
    mountID = entry.mountID,
    petSpeciesID = entry.petSpeciesID,
    appearanceID = entry.appearanceID,
    ejInstanceID = entry.ejInstanceID,
    instanceName = entry.instanceName,
    source = sourceText,
    name = displayName or "Tracked Item",
    hasWaypoint = (uiMapID and x and y) and true or false,
  }
  if uiMapID and x and y then
    data.uiMapID = uiMapID
    data.x = x
    data.y = y
  end
  return data
end

local function WishlistSyncTrackedStore(entry)
  local data = WishlistBuildTrackedData(entry)
  if not data then return nil end
  local store = EnsureTrackedStore()
  store.entries[data.key] = data
  local newOrder = { data.key }
  for _, key in ipairs(WishlistGetTrackedKeys()) do
    if key ~= data.key then table.insert(newOrder, key) end
  end
  store.order = newOrder
  return data
end

local function WishlistApplyTrackedWaypoint(entry)
  if type(entry) ~= "table" then
    WishlistClearTrackedWaypoint()
    return false
  end
  if Wishlist.EntryHasWaypoint(entry) then
    return WishlistSetTrackedWaypointOnly(entry)
  end
  return false
end

local function WishlistGetTrackedEntry()
  local keys = WishlistGetTrackedKeys()
  local key = keys[1]
  if not key then return nil end
  local entry = WishlistGetEntry(key)
  if type(entry) ~= "table" then
    local store = EnsureTrackedStore()
    store.entries[key] = nil
    table.remove(keys, 1)
    store.order = keys
    if #keys == 0 then WishlistClearTrackedWaypoint() end
    return nil
  end
  entry.key = key
  return entry
end

local function WishlistPruneCollectedTrackedEntries()
  local entries = Wishlist.EnsureWishlistDB()
  local store = EnsureTrackedStore()
  local changed = false
  local nextOrder = {}
  for _, key in ipairs(WishlistGetTrackedKeys()) do
    local entry = WishlistGetEntry(key)
    if type(entry) ~= "table" then
      local stored = store.entries[key]
      if type(stored) == "table" then entry = stored end
    end
    if type(entry) == "table" and WishlistIsEntryCollected(entry) then
      entries[key] = nil
      store.entries[key] = nil
      changed = true
    elseif (entries[key] ~= nil) or (type(store.entries[key]) == "table") then
      table.insert(nextOrder, key)
    end
  end
  if changed then
    store.order = nextOrder
    if #nextOrder == 0 then WishlistClearTrackedWaypoint() end
  end
  return changed
end

local function WishlistGetTrackedEntries()
  local tracked = {}
  local prunedCollected = WishlistPruneCollectedTrackedEntries()
  local keys = WishlistGetTrackedKeys()
  local store = EnsureTrackedStore()
  for _, key in ipairs(keys) do
    local entry = WishlistGetEntry(key)
    if type(entry) == "table" then
      entry.key = key
      table.insert(tracked, entry)
      WishlistSyncTrackedStore(entry)
    else
      local stored = store.entries[key]
      if type(stored) == "table" then
        local fallback = {}
        for k, v in pairs(stored) do fallback[k] = v end
        fallback.key = key
        table.insert(tracked, fallback)
      else
        store.entries[key] = nil
      end
    end
  end
  WishlistSetTrackedKeys(keys)
  if prunedCollected and UI and UI.RefreshWishlist then
    pcall(UI.RefreshWishlist)
  end
  if #tracked == 0 then WishlistClearTrackedWaypoint() end
  return tracked
end

local function WishlistRestoreTrackedState()
  WishlistGetTrackedEntries()
  return true
end

local function WishlistSetTrackedEntry(entry, enabled)
  if type(entry) ~= "table" or not entry.key then return false end
  local key = tostring(entry.key)
  local store = EnsureTrackedStore()
  if not enabled then
    if type(store.entries[key]) == "table" then
      store.entries[key] = nil
      local nextOrder = {}
      for _, existing in ipairs(WishlistGetTrackedKeys()) do
        if existing ~= key then table.insert(nextOrder, existing) end
      end
      store.order = nextOrder
      if #nextOrder == 0 then WishlistClearTrackedWaypoint() end
      return true
    end
    return false
  end
  WishlistSyncTrackedStore(entry)
  return true
end

local function WishlistRefreshTrackedDisplayNames()
  local store = EnsureTrackedStore()
  local changed = false
  for key, entry in pairs(store.entries or {}) do
    if type(entry) == "table" then
      local current = entry.name
      local needsName = (type(current) ~= "string" or current == "" or current == "Tracked Item")
      if needsName then
        local resolved = nil
        if entry.kind == "mount" and entry.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
          local ok, name = pcall(C_MountJournal.GetMountInfoByID, entry.mountID)
          if ok and type(name) == "string" and name ~= "" then resolved = name end
        elseif entry.kind == "pet" and entry.petSpeciesID and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
          local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, entry.petSpeciesID)
          if ok and type(name) == "string" and name ~= "" then resolved = name end
        elseif entry.itemID and GetItemInfo then
          local name = GetItemInfo(entry.itemID)
          if type(name) == "string" and name ~= "" then
            resolved = name
          elseif C_Item and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, entry.itemID)
          end
        end
        if not resolved then
          local fallback = entry.displayName or entry.itemName or entry.label or entry.title
          if type(fallback) == "string" and fallback ~= "" and fallback ~= "Tracked Item" then
            resolved = fallback
          end
        end
        if not resolved and entry.appearanceID then
          resolved = "Appearance " .. tostring(entry.appearanceID)
        end
        if type(resolved) == "string" and resolved ~= "" and resolved ~= current then
          entry.name = resolved
          store.entries[key] = entry
          changed = true
        end
      end
    end
  end
  return changed
end

local function WishlistSourceDisplayText(entry)
  local exact = Wishlist.GetExactSourceFromEntry(entry)
  if exact then return exact end
  return 'Unknown Source'
end

Wishlist.EnsureWishlistState = EnsureWishlistState
Wishlist.EnsureWishlistDB = EnsureWishlistDB
Wishlist.EnsureTrackedStore = EnsureTrackedStore
Wishlist.GetTrackedKeys = WishlistGetTrackedKeys
Wishlist.SetTrackedKeys = WishlistSetTrackedKeys
Wishlist.IsTrackedKey = WishlistIsTrackedKey
Wishlist.ClearTrackedWaypoint = WishlistClearTrackedWaypoint
Wishlist.ClearTrackedData = WishlistClearTrackedData
Wishlist.MakeKey = WishlistMakeKey
Wishlist.GetEntry = WishlistGetEntry
Wishlist.ContainsKey = WishlistContainsKey
Wishlist.RemoveKey = WishlistRemoveKey
Wishlist.GetAppearanceCollected = WishlistGetAppearanceCollected
Wishlist.TrimText = WishlistTrimText
Wishlist.StripRichText = WishlistStripRichText
Wishlist.GetGroupSourceLabel = WishlistGetGroupSourceLabel
Wishlist.NormalizeSourceValue = WishlistNormalizeSourceValue
Wishlist.ParseSourceText = WishlistParseSourceText
Wishlist.GetExactSourceFromEntry = WishlistGetExactSourceFromEntry
Wishlist.GetDisplayType = WishlistGetDisplayType
Wishlist.BuildPayloadFromCell = WishlistBuildPayloadFromCell
Wishlist.IsEntryCollected = WishlistIsEntryCollected
Wishlist.PruneCollectedEntries = WishlistPruneCollectedEntries
Wishlist.AddFromCell = WishlistAddFromCell
Wishlist.RemoveFromCell = WishlistRemoveFromCell
Wishlist.ContainsCell = WishlistContainsCell
Wishlist.ClearWishlistIdentity = CLOG_ClearWishlistIdentity
Wishlist.AssignWishlistIdentity = CLOG_AssignWishlistIdentity
Wishlist.GetWaypointTarget = WishlistGetWaypointTarget
Wishlist.EntryHasWaypoint = WishlistEntryHasWaypoint
Wishlist.OpenWaypoint = WishlistOpenWaypoint
Wishlist.SetTrackedWaypointOnly = WishlistSetTrackedWaypointOnly
Wishlist.CanTrackEntry = WishlistCanTrackEntry
Wishlist.BuildTrackedData = WishlistBuildTrackedData
Wishlist.SyncTrackedStore = WishlistSyncTrackedStore
Wishlist.ApplyTrackedWaypoint = WishlistApplyTrackedWaypoint
Wishlist.GetTrackedEntry = WishlistGetTrackedEntry
Wishlist.GetTrackedEntries = WishlistGetTrackedEntries
Wishlist.RestoreTrackedState = WishlistRestoreTrackedState
Wishlist.SetTrackedEntry = WishlistSetTrackedEntry
Wishlist.RefreshTrackedDisplayNames = WishlistRefreshTrackedDisplayNames
Wishlist.SourceDisplayText = WishlistSourceDisplayText

end

local function WishlistEntryDisplayName(entry)
  if not entry then return nil end
  if entry.kind == "mount" and entry.mountID and C_MountJournal and C_MountJournal.GetMountInfoByID then
    local ok, name = pcall(C_MountJournal.GetMountInfoByID, entry.mountID)
    if ok and type(name) == "string" and name ~= "" then return name end
  elseif entry.kind == "pet" and entry.petSpeciesID and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
    local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, entry.petSpeciesID)
    if ok and type(name) == "string" and name ~= "" then return name end
  elseif entry.itemID and GetItemInfo then
    local name = GetItemInfo(entry.itemID)
    if type(name) == "string" and name ~= "" then return name end
  end
  if type(entry.name) == "string" and entry.name ~= "" then return entry.name end
  if entry.appearanceID then return "Appearance " .. tostring(entry.appearanceID) end
  return nil
end

local function WishlistMatchesSearch(entry, search)
  if not search or search == "" then return true end
  search = tostring(search):lower()
  local name = WishlistEntryDisplayName(entry)
  if name and tostring(name):lower():find(search, 1, true) then return true end
  if entry.category and tostring(entry.category):lower():find(search, 1, true) then return true end
  if entry.kind and tostring(entry.kind):lower():find(search, 1, true) then return true end
  if entry.itemID and tostring(entry.itemID):find(search, 1, true) then return true end
  if entry.mountID and tostring(entry.mountID):find(search, 1, true) then return true end
  if entry.petSpeciesID and tostring(entry.petSpeciesID):find(search, 1, true) then return true end
  if entry.appearanceID and tostring(entry.appearanceID):find(search, 1, true) then return true end
  return false
end

local function WishlistGetSortedEntries(search)
  Wishlist.PruneCollectedEntries()
  local entries = Wishlist.EnsureWishlistDB()
  local out = {}
  for key, entry in pairs(entries) do
    local normalized = entry
    if entry == true then
      normalized = WishlistGetEntry(key)
    end
    if type(normalized) == "table" then
      normalized.key = key
      if WishlistMatchesSearch(normalized, search) then
        out[#out + 1] = normalized
      end
    end
  end
  table.sort(out, function(a, b)
    local ca = tostring(a.category or "")
    local cb = tostring(b.category or "")
    if ca ~= cb then return ca < cb end
    local na = tostring(WishlistEntryDisplayName(a) or "")
    local nb = tostring(WishlistEntryDisplayName(b) or "")
    if na ~= nb then return na < nb end
    return tostring(a.key or "") < tostring(b.key or "")
  end)
  return out
end

-- (UI local already defined near top of file)

-- =====================
-- Tooltip scan helper (Toys)
-- We build a custom tooltip but pull authoritative text from the item tooltip.
-- =====================
local CLScanTooltip = CreateFrame("GameTooltip", "CollectionLogScanTooltip", UIParent, "GameTooltipTemplate")
CLScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

local function CL_GetItemTooltipLines(itemID)
  if not itemID then return {} end
  CLScanTooltip:ClearLines()
  CLScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  -- SetItemByID is safe for cached items; if not cached, tooltip will be sparse until item info is available.
  if CLScanTooltip.SetToyByItemID then
    CLScanTooltip:SetToyByItemID(itemID)
  elseif GameTooltip and GameTooltip.SetToyByItemID and CLScanTooltip.SetToyByItemID == nil then
    -- fallback if the tooltip supports it (some clients)
    CLScanTooltip:SetToyByItemID(itemID)
  else
    CLScanTooltip:SetItemByID(itemID)
  end

  local lines = {}
  local n = CLScanTooltip:NumLines() or 0
  for i = 1, n do
    local fs = _G["CollectionLogScanTooltipTextLeft" .. i]
    local t = fs and fs.GetText and fs:GetText() or nil
    if t and t ~= "" then
      lines[#lines+1] = t
    end
  end
  return lines
end

-- Tooltip line objects (text + color), used for Toys so we can mirror Blizzard's red/green requirement coloring.
local function CL_GetItemTooltipLineObjects(itemID, preferToyBox)
  if not itemID then return {} end
  CLScanTooltip:ClearLines()
  CLScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

  if preferToyBox and CLScanTooltip.SetToyByItemID then
    CLScanTooltip:SetToyByItemID(itemID)
  else
    CLScanTooltip:SetItemByID(itemID)
  end

  local out = {}
  local n = CLScanTooltip:NumLines() or 0
  for i = 1, n do
    local fs = _G["CollectionLogScanTooltipTextLeft" .. i]
    local t = fs and fs.GetText and fs:GetText() or nil
    if t and t ~= "" then
      local r, g, b = 1, 1, 1
      if fs and fs.GetTextColor then
        r, g, b = fs:GetTextColor()
      end
      out[#out+1] = { text = t, r = r, g = g, b = b }
    end
  end
  return out
end


local function CL_ExtractToyTooltipBody(itemID)
  -- Use Toy Box tooltip capture so we mirror Blizzard's vendor/zone/cost blocks and their red/green requirement coloring.
  local lines = CL_GetItemTooltipLineObjects(itemID, true)

  local body = {}

  local function isNoise(t)
    if not t or t == "" then return true end
    local low = t:lower()
    -- Filter common addon noise
    if low:find("tsm") or low:find("auctioning") or low:find("min/") or low:find("max prices") then return true end
    -- Filter technical / id block (we stop before it anyway, but keep safe)
    if low:find("^itemid") or low:find("^iconid") or low:find("^spellid") then return true end
    if low:find("^toyid") then return true end
    if low:find("^added with patch") then return true end
    if low:find("^expansion:") then return true end
    return false
  end

  local function isStopLine(t)
    if not t or t == "" then return false end
    local low = t:lower()
    return low:find("^itemid") or low:find("^iconid") or low:find("^spellid") or low:find("^toyid") or low:find("^added with patch") or low:find("^expansion:")
  end

  -- Find the first "Use:" line; Toy Box body generally starts there.
  local startIdx = nil
  for i, L in ipairs(lines) do
    local t = L.text
    if not isNoise(t) and t:match("^Use:") then
      startIdx = i
      break
    end
  end

  -- If no Use: line (some toys), start after the "Toy"/"Warband Toy" label if present, else from first non-noise line.
  if not startIdx then
    for i, L in ipairs(lines) do
      local t = L.text
      if not isNoise(t) then
        local low = t:lower()
        if low == "toy" or low == "warband toy" then
          startIdx = i + 1
          break
        end
      end
    end
  end
  if not startIdx then
    for i, L in ipairs(lines) do
      local t = L.text
      if not isNoise(t) then
        startIdx = i
        break
      end
    end
  end
  if not startIdx then return body end

  local prevWasVendorGroup = false

  for j = startIdx, #lines do
    local L = lines[j]
    local t = L.text
    if isStopLine(t) then
      break
    end
    if not isNoise(t) then
      -- Skip collection flags that don't add value in our custom tooltip (Blizzard already shows them)
      local low = t:lower()
      if low ~= "already known" and not low:find("not learned") and not low:find("learned") and low ~= "toy" and low ~= "warband toy" then
        local isVendorLine = t:match("^Vendor") ~= nil or (t:lower():find("^sold by") ~= nil)
        -- Insert a blank line before each vendor block to mimic Blizzard spacing
        if isVendorLine and not prevWasVendorGroup then
          body[#body+1] = { text = "", r = 1, g = 1, b = 1 }
        end
        body[#body+1] = L
        prevWasVendorGroup = isVendorLine
      end
    end
  end

  -- Trim leading/trailing spacers
  while #body > 0 and body[1].text == "" do table.remove(body, 1) end
  while #body > 0 and body[#body].text == "" do table.remove(body, #body) end

  return body
end

-- Pets: localized pet type names (fallback to English)
local function GetPetTypeName(petType)
  if not petType then return nil end
  local key = "BATTLE_PET_NAME_" .. tostring(petType)
  local loc = _G and _G[key]
  if type(loc) == "string" and loc ~= "" then return loc end
  local fallback = {
    [1] = "Humanoid",
    [2] = "Dragonkin",
    [3] = "Flying",
    [4] = "Undead",
    [5] = "Critter",
    [6] = "Magic",
    [7] = "Elemental",
    [8] = "Beast",
    [9] = "Aquatic",
    [10] = "Mechanical",
  }
  return fallback[petType] or tostring(petType)
end


local function CLOG_Slugify(text)
  text = tostring(text or "")
  text = text:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if text == "" then text = "other" end
  return text
end

local function CLOG_MountSourceName(sourceType)
  local st = tonumber(sourceType or 0) or 0
  if Enum and Enum.MountJournalSource then
    for k, v in pairs(Enum.MountJournalSource) do
      if v == st and type(k) == "string" then
        local label = k:gsub("_", " ")
        label = label:gsub("(%l)(%u)", "%1 %2")
        return label
      end
    end
  end
  local fallback = {
    [1] = "Drop",
    [2] = "Quest",
    [3] = "Vendor",
    [4] = "Profession",
    [5] = "World Event",
    [6] = "Promotion",
    [7] = "Achievement",
    [8] = "Store",
    [9] = "Trading Card Game",
    [10] = "Black Market",
    [11] = "PvP",
    [12] = "Unused",
    [13] = "Mission",
    [14] = "Other",
  }
  return fallback[st] or (st > 0 and ("Source " .. tostring(st)) or "Other")
end

local function CLOG_NormalizePetSource(sourceText)
  if type(sourceText) ~= "string" or sourceText == "" then return "uncategorized", "Uncategorized", 950 end
  local s = sourceText:lower()
  if s:find("vendor") then return "vendor", "Vendor", 210 end
  if s:find("drop") or s:find("drops") then return "drop", "Drop", 220 end
  if s:find("quest") then return "quest", "Quest", 230 end
  if s:find("achievement") then return "achievement", "Achievement", 240 end
  if s:find("reputation") then return "reputation", "Reputation", 250 end
  if s:find("profession") or s:find("crafted") or s:find("crafting") then return "profession", "Profession", 260 end
  if (s:find("pet battle") or s:find("battle")) and s:find("pet") then return "pet_battle", "Pet Battle", 270 end
  if s:find("mission") or s:find("garrison") or s:find("war table") then return "mission", "Mission", 280 end
  if s:find("promotion") or s:find("tcg") or s:find("promo") then return "promotion", "Promotion", 290 end
  if s:find("store") or s:find("shop") then return "store", "Store", 300 end
  if s:find("anniversary") then return "anniversary", "Anniversary", 305 end
  if s:find("world event") or s:find("holiday") or s:find("feast") or s:find("hallow") then return "world_event", "World Event", 310 end
  return "other", "Other", 900
end

local function CLOG_CopyGroupShallow(g)
  local out = {}
  for k, v in pairs(g or {}) do out[k] = v end
  return out
end

local function CLOG_BuildJournalSidebarGroups(cat, list)
  if type(list) ~= "table" then return list end
  if cat ~= "Mounts" and cat ~= "Pets" then return list end

  local allGroup = nil
  local preserved, existingExp = {}, {}
  local existingSource, existingTypes = {}, {}

  local hasMjeMountSource, hasMjeMountExp = false, false
  for _, g in ipairs(list) do
    local gid = tostring((g and g.id) or "")
    if (cat == "Mounts" and gid == "mounts:all") or (cat == "Pets" and gid == "pets:all") then
      allGroup = CLOG_CopyGroupShallow(g)
    elseif cat == "Mounts" and gid:find("^mounts:mje:exp:") then
      if type(g.mounts) == "table" and #g.mounts > 0 then
        existingExp[#existingExp+1] = g
        hasMjeMountExp = true
      end
    elseif cat == "Mounts" and gid:find("^mounts:mje:source:") then
      if type(g.mounts) == "table" and #g.mounts > 0 then
        existingSource[#existingSource+1] = g
        hasMjeMountSource = true
      end
    elseif (cat == "Mounts" and gid:find("^mounts:exp:")) or (cat == "Pets" and gid:find("^pets:exp:")) then
      if ((cat == "Mounts" and type(g.mounts) == "table" and #g.mounts > 0) or (cat == "Pets" and type(g.pets) == "table" and #g.pets > 0)) then
        existingExp[#existingExp+1] = g
      end
    elseif cat == "Mounts" and (gid:find("^mounts:source:") or gid:find("^mounts:drop:") or gid:find("^mounts:cat:") or gid:find("^mounts:canon:")) then
      if type(g.mounts) == "table" and #g.mounts > 0 and not hasMjeMountSource then existingSource[#existingSource+1] = g end
    elseif cat == "Pets" and gid:find("^pets:source:") then
      if type(g.pets) == "table" and #g.pets > 0 then existingSource[#existingSource+1] = g end
    elseif cat == "Pets" and gid:find("^pets:type:") then
      if type(g.pets) == "table" and #g.pets > 0 then existingTypes[#existingTypes+1] = g end
    else
      preserved[#preserved+1] = g
    end
  end

  if cat == "Mounts" and (hasMjeMountSource or hasMjeMountExp) and #preserved > 0 then
    local kept = {}
    for _, g in ipairs(preserved) do
      local gid = tostring((g and g.id) or "")
      if not (gid:find("^mounts:source:") or gid:find("^mounts:drop:") or gid:find("^mounts:cat:") or gid:find("^mounts:canon:") or gid:find("^mounts:exp:")) then
        kept[#kept+1] = g
      end
    end
    preserved = kept
  end

  if not allGroup then return list end

  local rows = { allGroup }

  local function addNonEmpty(target, source, key)
    for _, g in ipairs(source or {}) do
      local items = g and g[key]
      if type(items) == "table" and #items > 0 then
        target[#target+1] = g
      end
    end
  end

  if cat == "Mounts" then
    local sourceOrdered, expOrdered = {}, {}
    addNonEmpty(sourceOrdered, existingSource, "mounts")
    addNonEmpty(expOrdered, existingExp, "mounts")
    table.sort(sourceOrdered, function(a, b)
      if (a.sortIndex or 999) ~= (b.sortIndex or 999) then return (a.sortIndex or 999) < (b.sortIndex or 999) end
      return tostring(a.name or "") < tostring(b.name or "")
    end)
    table.sort(expOrdered, function(a, b)
      if (a.sortIndex or 999) ~= (b.sortIndex or 999) then return (a.sortIndex or 999) < (b.sortIndex or 999) end
      return tostring(a.name or "") < tostring(b.name or "")
    end)
    for _, g in ipairs(sourceOrdered) do rows[#rows+1] = g end
    for _, g in ipairs(expOrdered) do rows[#rows+1] = g end
    return rows

  elseif cat == "Pets" then
    local sourceOrdered, typeOrdered = {}, {}
    addNonEmpty(sourceOrdered, existingSource, "pets")
    addNonEmpty(typeOrdered, existingTypes, "pets")
    table.sort(sourceOrdered, function(a, b)
      if (a.sortIndex or 999) ~= (b.sortIndex or 999) then return (a.sortIndex or 999) < (b.sortIndex or 999) end
      return tostring(a.name or "") < tostring(b.name or "")
    end)
    table.sort(typeOrdered, function(a, b)
      if (a.sortIndex or 999) ~= (b.sortIndex or 999) then return (a.sortIndex or 999) < (b.sortIndex or 999) end
      return tostring(a.name or "") < tostring(b.name or "")
    end)
    for _, g in ipairs(sourceOrdered) do rows[#rows+1] = g end
    for _, g in ipairs(typeOrdered) do rows[#rows+1] = g end
  end

  for _, g in ipairs(existingExp) do rows[#rows+1] = g end
  for _, g in ipairs(preserved) do
    if g.id ~= allGroup.id then rows[#rows+1] = g end
  end

  -- Register any synthetic Mount/Pet sidebar groups into the live group map so
  -- selecting them resolves to actual content in RefreshGrid(). Without this,
  -- the left list can show a valid label while the right pane sees no backing
  -- group and falls back to "Select an entry".
  if ns and ns.Data then
    ns.Data.groups = ns.Data.groups or {}
    for _, g in ipairs(rows) do
      if type(g) == "table" and g.id then
        ns.Data.groups[g.id] = g
      end
    end
  end

  return rows
end


-- ============================================================
-- Right-click removal (debug / cleanup)
-- ============================================================
local CLog_IsRaidDungeonGroup
local CLog_ShouldPersistPrecomputeResult

local function EnsureUIState()
  CollectionLogDB.ui = CollectionLogDB.ui or {}
  CollectionLogDB.ui.hiddenGroups = CollectionLogDB.ui.hiddenGroups or {}

  -- Default view mode: account/warband only (no character filtering UI)
  if CollectionLogDB.ui.viewMode == nil then
    CollectionLogDB.ui.viewMode = "ACCOUNT"
  end
  CollectionLogDB.ui.activeCharacterGUID = nil

  -- Remember last-used difficulty per instance
  CollectionLogDB.ui.lastDifficultyByInstance = CollectionLogDB.ui.lastDifficultyByInstance or {}

  -- Per-category expansion filter (shared dropdown, but NOT shared state)
  CollectionLogDB.ui.expansionFilterByCategory = CollectionLogDB.ui.expansionFilterByCategory or {}

  if CollectionLogDB.ui.appearanceClassFilter == nil then
    local _, classToken = UnitClass("player")
    if classToken == "DRACTHYR" then classToken = "EVOKER" end
    CollectionLogDB.ui.appearanceClassFilter = classToken or "ALL"
  end

  -- Window dimensions / scale defaults
  if CollectionLogDB.ui.w == nil then CollectionLogDB.ui.w = 980 end
  if CollectionLogDB.ui.h == nil then CollectionLogDB.ui.h = 640 end
  if CollectionLogDB.ui.scale == nil then CollectionLogDB.ui.scale = 1.0 end

  -- Collection Log is collectables-only for raid/dungeon loot.
  CollectionLogDB.ui.hideJunk = true

  -- Left-list completion coloring
  -- Persisted per-group completion lets us paint the list instantly on login
  -- without requiring background scanning or per-row clicks.
  -- v4.3.70: default/legacy behavior is cache-only.  Background warming was
  -- repeatedly live-looking up raid/dungeon rows and could keep CPU high after
  -- simple tab switches. Manual Refresh remains the explicit rebuild path.
  CollectionLogDB.ui.precomputeLeftListColors = false
  if CollectionLogDB.ui.autoWarmRaidDungeonSidebar == nil then
    CollectionLogDB.ui.autoWarmRaidDungeonSidebar = false
  end
  CollectionLogDB.ui.leftListColorCache = CollectionLogDB.ui.leftListColorCache or { meta = {}, cache = {} }
  CollectionLogDB.ui.leftListColorCache.meta = CollectionLogDB.ui.leftListColorCache.meta or {}
  CollectionLogDB.ui.leftListColorCache.cache = CollectionLogDB.ui.leftListColorCache.cache or {}

  local curInterface = select(4, GetBuildInfo())
  local curVer = (ns and ns.VERSION) or ""
  local meta = CollectionLogDB.ui.leftListColorCache.meta
  if meta.interface ~= curInterface or meta.version ~= curVer then
    -- Invalidate persisted cache on client/version changes to avoid showing stale completion.
    CollectionLogDB.ui.leftListColorCache.cache = {}
    meta.interface = curInterface
    meta.version = curVer
    meta.generatedAt = time and time() or 0
  end

  -- Mirror persisted cache into session cache for fast reads.
  -- Raid/Dungeon rows are only colored from verified per-instance truth (header/grid),
  -- never from broad startup precompute. Persisted partial rows are now valid because
  -- they come from an explicitly opened, verified instance.
  UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
  for k, v in pairs(CollectionLogDB.ui.leftListColorCache.cache) do
    if type(k) == "string" and CLOG_IsLeftListCacheEntryFresh and CLOG_IsLeftListCacheEntryFresh(v, true) then
      UI._clogLeftListColorCache[k] = v
    end
  end

end

local function RemoveGroupPermanently(groupId)
  if not groupId then return end
  EnsureUIState()

  -- IMPORTANT BEHAVIOR:
  -- * For GeneratedPack groups (created by /clogscan), "Remove" should DELETE the group entirely.
  --   This avoids confusion where a user rescans later but the group stays hidden due to hiddenGroups.
  -- * For static/curated groups (from packs), we cannot truly delete the source, so "Remove" means hide.
  local removedGenerated = false

  if CollectionLogDB.generatedPack and CollectionLogDB.generatedPack.groups then
    for i = #CollectionLogDB.generatedPack.groups, 1, -1 do
      local g = CollectionLogDB.generatedPack.groups[i]
      if g and g.id == groupId then
        table.remove(CollectionLogDB.generatedPack.groups, i)
        removedGenerated = true
      end
    end
  end

  if removedGenerated then
    -- Ensure it is NOT hidden so a future rescan cleanly recreates it.
    CollectionLogDB.ui.hiddenGroups[groupId] = nil
  else
    -- Static pack group: only hide.
    CollectionLogDB.ui.hiddenGroups[groupId] = true
  end

  if ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  if CollectionLogDB.ui.activeGroupId == groupId then
    CollectionLogDB.ui.activeGroupId = nil
  end

  UI.RefreshGrid()
  if UI.BuildGroupList then UI.BuildGroupList() end
end

if not StaticPopupDialogs["COLLECTIONLOG_DELETE_GROUP"] then
  StaticPopupDialogs["COLLECTIONLOG_DELETE_GROUP"] = {
    text = "Remove this entry from Collection Log?\n\nIf this came from a scan, it will be deleted (you can recreate it by scanning again). If it came from a static pack, it will be hidden.",
    button1 = "Remove",
    button2 = CANCEL,
    OnAccept = function(self, data)
      if data and data.groupId then
        RemoveGroupPermanently(data.groupId)
      end
      StaticPopup_Hide("COLLECTIONLOG_DELETE_GROUP")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
end


local CATEGORIES = { "Overview", "Dungeons", "Raids", "Mounts", "Pets", "Toys", "Housing", "Appearances", "Wishlist", "History" }

-- Tight OSRS-ish sizing
local PAD = 8
local TOPBAR_H = 34
local TAB_W = 95
local TAB_H = 22

local LIST_W = 290
-- Header holds: title, collected counter, and an OSRS-style progress bar.
-- Slightly taller so the OSRS-thick bar has room without crowding.
local HEADER_H = 106

local ICON = 34
local GAP = 4

local SECTION_H = 18
local SECTION_GAP = 8

local function Clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function CreateBorder(frame)
  frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
end

-- Thinner border for tight UI elements (progress bar) so the fill can be chunky
-- without being eaten by the tooltip border thickness.
local function CreateThinBorder(frame)
  frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  frame:SetBackdropColor(0.03, 0.03, 0.03, 0.92)
end

-- ============================
-- Progress bar helpers
-- ============================
local function ProgressColor(p)
  -- Smooth red -> yellow -> green
  p = Clamp(p or 0, 0, 1)
  if p <= 0.5 then
    return 1, (p * 2), 0
  end
  return (2 * (1 - p)), 1, 0
end

local function SetProgressBar(collected, total)
  if not UI or not UI.progressBar then return end

  total = tonumber(total) or 0
  collected = tonumber(collected) or 0

  if total <= 0 then
    UI.progressBar:SetMinMaxValues(0, 1)
    UI.progressBar:SetValue(0)
    UI.progressBar:SetStatusBarColor(1, 0, 0, 0.65)
    if UI.progressText then UI.progressText:SetText("") end
    UI.progressBar:Hide()
    if UI.progressBG then UI.progressBG:Hide() end
    return
  end

  local p = collected / total
  local r, g, b = ProgressColor(p)
  UI.progressBar:SetMinMaxValues(0, total)
  UI.progressBar:SetValue(collected)
  UI.progressBar:SetStatusBarColor(r, g, b, 0.90)
  if UI.progressText then
    UI.progressText:SetText( ("%d%%"):format(math.floor(p * 100 + 0.5)) )
  end
  UI.progressBar:Show()
  if UI.progressBG then UI.progressBG:Show() end
end


-- ============================
-- Browser / folder-style tabs
-- Option A: inactive tabs muted
-- ============================
local GOLD_R, GOLD_G, GOLD_B = 1.00, 0.86, 0.08
local INACT_R, INACT_G, INACT_B = 0.70, 0.66, 0.50  -- gray-gold

local function CreateGoldTabBorder(frame)
  frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropColor(0.07, 0.07, 0.07, 0.92)
  frame:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.55)

  -- Subtle fill sheen (helps the tab feel like a "page")
  local sheen = frame:CreateTexture(nil, "ARTWORK")
  sheen:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
  sheen:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
  sheen:SetHeight(10)
  sheen:SetTexture("Interface/Tooltips/UI-Tooltip-Background")
  sheen:SetVertexColor(1, 1, 1, 0.10)
  frame.__clogSheen = sheen

  -- Bottom cover to create the "open-bottom" active tab (hidden by default)
  local cover = frame:CreateTexture(nil, "OVERLAY")
  cover:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 2, 0)
  cover:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 0)
  cover:SetHeight(18) -- covers the tooltip border bottom edge + corner arcs
  cover:SetColorTexture(0.03, 0.03, 0.03, 1.0) -- should match panel bg closely
  cover:Hide()
  frame.__clogBottomCover = cover

  -- Hover glow (subtle, shown only for inactive tabs)
  local hoverGlow = frame:CreateTexture(nil, "BACKGROUND")
  hoverGlow:SetColorTexture(GOLD_R, GOLD_G, GOLD_B, 0.07) -- ~50% of active feel
  hoverGlow:SetBlendMode("ADD")
  hoverGlow:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
  hoverGlow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
  hoverGlow:Hide()
  frame.__clogHoverGlow = hoverGlow
end

local function SetTabActiveVisual(tabButton, isActive)
  if not tabButton then return end

  tabButton._clogIsActive = (isActive and true or false)

  if isActive then
    tabButton:SetBackdropColor(0.14, 0.14, 0.14, 0.95)
    tabButton:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 1.00)
    if tabButton.__clogSheen then tabButton.__clogSheen:SetVertexColor(1,1,1,0.30) end
    if tabButton.__clogBottomCover then tabButton.__clogBottomCover:Show() end
    if tabButton.__clogHoverGlow then tabButton.__clogHoverGlow:Hide() end

    tabButton:SetFrameLevel((tabButton.__clogBaseLevel or tabButton:GetFrameLevel()) + 15)
    tabButton:ClearAllPoints()
    if tabButton.__clogAnchor then
      tabButton:SetPoint(tabButton.__clogAnchor.point, tabButton.__clogAnchor.rel, tabButton.__clogAnchor.relPoint, tabButton.__clogAnchor.x, tabButton.__clogAnchor.y + 3)
    end
  else
    tabButton:SetBackdropColor(0.06, 0.06, 0.06, 0.90)
    tabButton:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.45)
    if tabButton.__clogSheen then tabButton.__clogSheen:SetVertexColor(1,1,1,0.06) end
    if tabButton.__clogBottomCover then tabButton.__clogBottomCover:Hide() end
    if tabButton.__clogHoverGlow then tabButton.__clogHoverGlow:Hide() end

    tabButton:SetFrameLevel(tabButton.__clogBaseLevel or tabButton:GetFrameLevel())
    tabButton:ClearAllPoints()
    if tabButton.__clogAnchor then
      tabButton:SetPoint(tabButton.__clogAnchor.point, tabButton.__clogAnchor.rel, tabButton.__clogAnchor.relPoint, tabButton.__clogAnchor.x, tabButton.__clogAnchor.y)
    end
  end
end


local function ApplyCollectionIconState(tex, isCollected)
  if not tex then return end

  if tex.SetDesaturated then
    tex:SetDesaturated(not isCollected)
  end

  if tex.SetVertexColor then
    if isCollected then
      tex:SetVertexColor(1, 1, 1, 1)
    else
      -- Keep uncollected icons clearly grayscale, but still readable.
      -- The previous pass crushed them too hard and made the border feel
      -- louder than the artwork itself.
      tex:SetVertexColor(0.76, 0.76, 0.76, 1)
    end
  end

  if tex.SetAlpha then
    tex:SetAlpha(isCollected and 1 or 0.88)
  end
end

local function DesaturateIf(tex, yes)
  ApplyCollectionIconState(tex, not yes)
end

local function ApplyCellCollectedVisual(cell, isCollected)
  if not cell then return end
  if cell.SetBackdropBorderColor then
    if isCollected then
      cell:SetBackdropBorderColor(0.88, 0.72, 0.18, 0.65)
    else
      cell:SetBackdropBorderColor(0.24, 0.24, 0.24, 0.30)
    end
    if cell.SetBackdropColor then cell:SetBackdropColor(0.03, 0.03, 0.03, 0.95) end
  end
end

UI._clogItemNameFallbackCache = UI._clogItemNameFallbackCache or {}

function UI.CLOG_NormalizeSortText(value)
  value = tostring(value or ""):lower()
  value = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  value = value:gsub("[^%w%s]", "")
  value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return value
end

function UI.CLOG_GetAnyKnownItemName(itemID)
  itemID = tonumber(itemID or 0) or 0
  if itemID <= 0 then return "" end
  local cached = UI._clogItemNameFallbackCache[itemID]
  if cached ~= nil then return cached end

  local name = ""
  if ns and ns.Data and ns.Data.groups then
    for _, group in pairs(ns.Data.groups) do
      if type(group) == "table" then
        if type(group.itemLinks) == "table" then
          local link = group.itemLinks[itemID] or group.itemLinks[tostring(itemID)]
          if type(link) == "table" then link = link[1] end
          if type(link) == "string" and link ~= "" then
            name = link:match("%[(.-)%]") or ""
          end
        end
        if name == "" and type(group.itemNames) == "table" then
          name = tostring(group.itemNames[itemID] or group.itemNames[tostring(itemID)] or "")
        end
        if name == "" and type(group.itemMetadata) == "table" then
          local meta = group.itemMetadata[itemID] or group.itemMetadata[tostring(itemID)]
          if type(meta) == "table" then
            name = tostring(meta.name or meta.itemName or meta.label or meta.title or "")
          end
        end
        if name ~= "" then break end
      end
    end
  end

  name = UI.CLOG_NormalizeSortText(name)
  UI._clogItemNameFallbackCache[itemID] = name
  return name
end

function UI.CLOG_GetGroupItemSortName(group, itemID)
  itemID = tonumber(itemID or 0) or 0
  if itemID <= 0 then return "" end

  local name = nil
  if type(group) == "table" and type(group.itemLinks) == "table" then
    local link = group.itemLinks[itemID] or group.itemLinks[tostring(itemID)]
    if type(link) == "table" then link = link[1] end
    if type(link) == "string" and link ~= "" then
      name = link:match("%[(.-)%]")
    end
  end
  if type(group) == "table" and type(group.itemNames) == "table" then
    name = name or group.itemNames[itemID] or group.itemNames[tostring(itemID)]
  end
  if (not name or name == "") and type(group) == "table" and type(group.itemMetadata) == "table" then
    local meta = group.itemMetadata[itemID] or group.itemMetadata[tostring(itemID)]
    if type(meta) == "table" then
      name = meta.name or meta.itemName or meta.label or meta.title
    end
  end
  if (not name or name == "") and ns and ns.RaidDungeonMeta and ns.RaidDungeonMeta.GetItemMeta and type(group) == "table" then
    local okMeta, meta = pcall(ns.RaidDungeonMeta.GetItemMeta, group, itemID)
    if okMeta and type(meta) == "table" then
      name = meta.name or meta.itemName or meta.label or meta.title
    end
  end
  if (not name or name == "") and GetItemInfo then
    name = GetItemInfo(itemID)
  end
  if not name or name == "" then
    name = UI.CLOG_GetAnyKnownItemName(itemID)
    return name or ""
  end
  return UI.CLOG_NormalizeSortText(name or "")
end

function UI.CLOG_SortItemIDsByGroupName(itemIDs, group)
  if type(itemIDs) ~= "table" or #itemIDs <= 1 then return itemIDs end
  table.sort(itemIDs, function(a, b)
    local aID = tonumber(a or 0) or 0
    local bID = tonumber(b or 0) or 0
    local aName = UI.CLOG_GetGroupItemSortName(group, aID)
    local bName = UI.CLOG_GetGroupItemSortName(group, bID)
    if aName ~= bName then
      if aName == "" then return false end
      if bName == "" then return true end
      return aName < bName
    end
    return aID < bID
  end)
  return itemIDs
end

local function CLOG_GetSourceItemLink(sourceID)
  sourceID = tonumber(sourceID)
  if not (sourceID and sourceID > 0 and C_TransmogCollection) then return nil end
  if C_TransmogCollection.GetAppearanceSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, sourceID)
    if ok and type(info) == "table" and type(info.itemLink) == "string" and info.itemLink ~= "" then
      return info.itemLink
    end
  end
  if C_TransmogCollection.GetSourceInfo then
    local ok, info = pcall(C_TransmogCollection.GetSourceInfo, sourceID)
    if ok and type(info) == "table" and type(info.itemLink) == "string" and info.itemLink ~= "" then
      return info.itemLink
    end
  end
  return nil
end

local function CLOG_GetTooltipLinkFromTruthState(state)
  local def = type(state) == "table" and state.def or nil
  if type(def) ~= "table" then return nil end
  if type(def.itemLink) == "string" and def.itemLink ~= "" then
    return def.itemLink
  end
  return CLOG_GetSourceItemLink(def.modID or def.sourceID or def.itemModifiedAppearanceID)
end

function UI.IsRaidDungeonGridContext()
  local dbui = CollectionLogDB and CollectionLogDB.ui
  local cat = dbui and dbui.activeCategory
  local mode = dbui and dbui.viewMode
  return cat == "Raids" or cat == "Dungeons" or mode == "raids" or mode == "dungeons"
end

function UI.IsAppearanceLootSection(section)
  section = tostring(section or "")
  if section == "" then return false end
  if section == "Mounts" or section == "Pets" or section == "Toys" or section == "Housing" or section == "Wishlist" or section == "History" then return false end
  -- Raid/Dungeon loot sections may be passed as the major bucket (Weapons/Armor)
  -- or as a subtype/subsection (1H, Dagger, Chest, Wrist, etc.).  Treat every
  -- non-teaching-item section in the raid/dungeon grid as an appearance row so
  -- it cannot fall through to legacy itemID-only wardrobe saturation.
  return true
end

-- =====================
-- Top tabs (categories)
-- =====================

-- ============================================================
-- Difficulty + sibling helpers (UI layer)
-- ============================================================
local function GetDifficultyMeta(difficultyID, modeName)
  -- Returns canonicalTier ("M","H","N","LFR","TW","OTHER"), size (number|nil), and apiName (string|nil)
  local apiName, _, _, groupSize
  if GetDifficultyInfo and difficultyID then
    apiName, _, _, groupSize = GetDifficultyInfo(difficultyID)
  end
  local nameLower = ""
  if type(apiName) == "string" then nameLower = apiName:lower() end
  if type(modeName) == "string" then nameLower = (nameLower .. " " .. modeName:lower()) end

  -- Explicit ID mappings (locale independent)
  -- Modern raid
  if difficultyID == 16 then return "M", nil, apiName end
  if difficultyID == 15 then return "H", nil, apiName end
  if difficultyID == 14 then return "N", nil, apiName end
  if difficultyID == 17 then return "LFR", nil, apiName end
  if difficultyID == 7 then return "LFR", nil, apiName end -- Legacy LFR
  if difficultyID == 9 then return "N", 40, apiName end -- Legacy 40-player

  -- Legacy raid size variants
  if difficultyID == 5 then return "H", 10, apiName end
  if difficultyID == 6 then return "H", 25, apiName end
  if difficultyID == 3 then return "N", 10, apiName end
  if difficultyID == 4 then return "N", 25, apiName end

  -- Dungeons / challenge
  if difficultyID == 23 or difficultyID == 8 then return "M", nil, apiName end
  if difficultyID == 2 then return "H", nil, apiName end
  if difficultyID == 1 then return "N", nil, apiName end

  -- Timewalking
  if difficultyID == 24 then return "TW", nil, apiName end

  -- Fallback inference by strings (English clients)
  if nameLower:find("timewalking", 1, true) or nameLower:find("time walking", 1, true) then
    return "TW", nil, apiName
  end
  if nameLower:find("looking for raid", 1, true) or nameLower:find("raid finder", 1, true) or nameLower:find("lfr", 1, true) then
    return "LFR", nil, apiName
  end
  if nameLower:find("mythic", 1, true) then return "M", groupSize, apiName end
  if nameLower:find("heroic", 1, true) then return "H", groupSize, apiName end
  if nameLower:find("normal", 1, true) then return "N", groupSize, apiName end

  return "OTHER", groupSize, apiName
end

local function DifficultyTierOrder(tier)
  -- Dropdown + tooltip hierarchy (top -> bottom)
  if tier == "M" then return 1 end
  if tier == "H" then return 2 end
  if tier == "N" then return 3 end
  if tier == "LFR" then return 4 end
  if tier == "TW" then return 5 end
  return 99
end

local function DifficultyShortLabel(difficultyID, modeName, siblingsContext)
  local tier, size = GetDifficultyMeta(difficultyID, modeName)
  if tier == "LFR" then return "LFR" end
  if tier == "TW" then return "TW" end
  if tier == "M" then return "M" end

  local needSize = false
  if siblingsContext and siblingsContext.multiSize and (tier == "H" or tier == "N") then
    needSize = siblingsContext.multiSize[tier] or false
  end

  if needSize and size and size > 0 then
    return ("%s(%d)"):format(tier, size)
  end
  return tier
end

local function DifficultyLongLabel(difficultyID, modeName, siblingsContext)
  local tier, size = GetDifficultyMeta(difficultyID, modeName)
  if tier == "LFR" then return "Raid Finder" end
  if tier == "TW" then return "Timewalking (TW)" end
  if tier == "M" then return "Mythic" end

  local needSize = false
  if siblingsContext and siblingsContext.multiSize and (tier == "H" or tier == "N") then
    needSize = siblingsContext.multiSize[tier] or false
  end

  if needSize and size and size > 0 then
    if tier == "H" then return ("Heroic (%d)"):format(size) end
    if tier == "N" then return ("Normal (%d)"):format(size) end
  end

  if tier == "H" then return "Heroic" end
  if tier == "N" then return "Normal" end

  return modeName or tostring(difficultyID or "?")
end

local function DifficultyDisplayOrder(difficultyID, modeName)
  local tier, size = GetDifficultyMeta(difficultyID, modeName)
  local o = DifficultyTierOrder(tier)
  local sizeOrder = 0
  -- Larger raid sizes first (25 above 10)
  if size and size > 0 then sizeOrder = 1000 - size end
  return o * 1000 + sizeOrder
end

local function DifficultyPowerRank(difficultyID, modeName)
  local tier = GetDifficultyMeta(difficultyID, modeName)
  if tier == "M" then return 4 end
  if tier == "H" then return 3 end
  if tier == "N" then return 2 end
  if tier == "LFR" then return 1 end
  return 0
end

local function GetSiblingGroups(instanceID, category)

  local out = {}
  if not instanceID or not ns or not ns.Data or not ns.Data.groups then return out end
  for _, g in pairs(ns.Data.groups) do
    if g and g.instanceID == instanceID then
      if (not category) or (g.category == category) then
        table.insert(out, g)
      end
    end
  end
  table.sort(out, function(a, b)
    local da, db = DifficultyDisplayOrder(a.difficultyID, a.mode), DifficultyDisplayOrder(b.difficultyID, b.mode)
    if da ~= db then return da < db end
    return (a.id or "") < (b.id or "")
  end)
  return out
end

local function GetCollectibleKey(itemID, groupOrKey)
  if not itemID or itemID <= 0 then
    return "I:0"
  end

  -- Datapack-first variant keys.  This avoids calling transmog/source APIs just
  -- to decide which sibling difficulties should appear in the tooltip.
  if groupOrKey and ns and ns.RaidDungeonMeta and ns.RaidDungeonMeta.GetBestVariantKey then
    local okMeta, metaKey = pcall(ns.RaidDungeonMeta.GetBestVariantKey, groupOrKey, itemID)
    if okMeta and type(metaKey) == "string" and metaKey ~= "" then
      return metaKey
    end
  end

  -- Legacy fallback only for rows without raid/dungeon metadata.
  if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
    local a, b = C_TransmogCollection.GetItemInfo(itemID)
    local appearanceID, sourceID = a, b

    if (appearanceID and not sourceID) and C_TransmogCollection.GetAppearanceSourceInfo then
      local info = C_TransmogCollection.GetAppearanceSourceInfo(appearanceID)
      if info and (info.appearanceID or info.isCollected ~= nil) then
        sourceID = appearanceID
        appearanceID = info.appearanceID
      end
    end

    if (sourceID and not appearanceID) and C_TransmogCollection.GetAppearanceSourceInfo then
      local info = C_TransmogCollection.GetAppearanceSourceInfo(sourceID)
      if info and info.appearanceID then
        appearanceID = info.appearanceID
      end
    end

    if appearanceID and appearanceID ~= 0 then
      return "appearance:" .. tostring(appearanceID)
    end
  end

  return "item:" .. tostring(itemID)
end

local function FindMatchingItemID(group, key)
  if not group or not key then return nil end
  if ns and ns.RaidDungeonMeta and ns.RaidDungeonMeta.FindItemIDForVariant then
    local okMeta, matchID = pcall(ns.RaidDungeonMeta.FindItemIDForVariant, group, key)
    if okMeta and tonumber(matchID) then return tonumber(matchID) end
  end
  if not group.items then return nil end
  for _, otherID in ipairs(group.items) do
    if GetCollectibleKey(otherID, group) == key then
      return otherID
    end
  end
  return nil
end


local function SetTabActive(cat)
  for _, c in ipairs(CATEGORIES) do
    local tab = UI.tabs and UI.tabs[c]
    if tab then
      local active = (c == cat)
      SetTabActiveVisual(tab.button, active)
      tab.label:SetTextColor(active and 1 or 0.80, active and 0.88 or 0.80, active and 0.20 or 0.80)
    end
  end
end



-- ============================
-- Left list coloring (Dungeons/Raids)
-- ============================
UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
UI._clogLeftListColorQueue = UI._clogLeftListColorQueue or {}
UI._clogGroupBtnById = UI._clogGroupBtnById or {}

local function CLog_IsCollectedFast(itemID)
  itemID = tonumber(itemID) or 0
  if itemID <= 0 then return false end

  -- 1) Transmog appearance (fast path)
  if ns and ns.IsAppearanceCollected and ns.IsAppearanceCollected(itemID) then
    return true
  end

  -- 2) Mount items
  if ns and ns.IsMountCollected and ns.IsMountCollected(itemID) then
    return true
  end

  -- 3) Battle pets (species ownership; itemID used as speciesID in pets groups, but dungeon loot shouldn't hit this)
  if ns and ns.IsPetCollected and ns.IsPetCollected(itemID) then
    return true
  end

  -- 4) Toys (canonical ToyBox truth)
  if ns and ns.IsToyCollected and ns.IsToyCollected(itemID) then
    return true
  end

  return false
end

local function CLog_RequestGroupItemData(g)
  if not g then return end
  if not (C_Item and C_Item.RequestLoadItemDataByID) then return end
  local items = g.items or g.itemIDs or nil
  if type(items) ~= "table" then return end
  for _, id in ipairs(items) do
    local itemID = tonumber(id)
    if itemID and itemID > 0 then
      pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
  end
end

local function CLog_GroupPrecomputeReady(g)
  if not g or not CLog_IsRaidDungeonGroup or not CLog_IsRaidDungeonGroup(g) then return true end

  local items = g.items or g.itemIDs or nil
  if type(items) ~= "table" then return true end

  for _, id in ipairs(items) do
    local itemID = tonumber(id)
    if itemID and itemID > 0 then
      -- Token-based raid rows are the problem class here. If the item name/spell
      -- payload has not landed yet, section classification can temporarily fall back
      -- to Misc which produces a false yellow until the instance is opened.
      local sec = (UI.GetGroupItemSectionFromMetadata and UI.GetGroupItemSectionFromMetadata(g, itemID))
        or (ns and ns.GetItemSectionFast and ns.GetItemSectionFast(itemID))
        or (ns and ns.GetItemSection and ns.GetItemSection(itemID))
        or nil

      if sec == nil or sec == "Misc" then
        if C_Item and C_Item.RequestLoadItemDataByID then
          pcall(C_Item.RequestLoadItemDataByID, itemID)
        end

        local name = GetItemInfo and GetItemInfo(itemID) or nil
        if not name then
          return false
        end
      end
    end
  end

  return true
end

local function CLog_GetCompletionBackendGroupKey(g)
  if type(g) ~= "table" then return nil end
  if g.category ~= "Raids" and g.category ~= "Dungeons" then return nil end
  local category = tostring(g.category or "")
  local instanceID = tonumber(g.instanceID)
  if instanceID and instanceID > 0 then
    return ("ejinstance:%s:%d"):format(category, instanceID)
  end
  local name = tostring(g.name or ""):lower():gsub("['â€™`_]", ""):gsub("[%p%c]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if name and name ~= "" then
    return "name:" .. category .. ":" .. name
  end
  return nil
end

local function CLog_GetRaidRowColorBackendTotals(g)
  -- v4.3.28 takeover: raid/dungeon row color and visible totals read from
  -- the validated TrueCollection backend (collectible-only, canonical-deduped).
  if type(g) ~= "table" then return nil end
  if not CLog_IsRaidDungeonGroup or not CLog_IsRaidDungeonGroup(g) then return nil end
  if not (ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus) then return nil end

  local status = (CLOG_GetTrueCollectionStatusCached and CLOG_GetTrueCollectionStatusCached(g)) or nil
  if type(status) ~= "table" then return nil end

  local collected = tonumber(status.collected or 0) or 0
  local total = tonumber(status.total or 0) or 0
  if total <= 0 then return nil end
  return collected, total, status
end

local function CLog_GetRaidAggregateBackendTotals(g)
  if type(g) ~= "table" then return nil end
  if not CLog_IsRaidDungeonGroup or not CLog_IsRaidDungeonGroup(g) then return nil end
  if not (ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus) then return nil end

  local groupKey = CLog_GetCompletionBackendGroupKey and CLog_GetCompletionBackendGroupKey(g) or nil
  if not groupKey then return nil end

  local ok, status = pcall(ns.TrueCollection.GetGroupStatus, groupKey)
  if not ok or type(status) ~= "table" then return nil end

  local collected = tonumber(status.collected or 0) or 0
  local total = tonumber(status.total or 0) or 0
  if total <= 0 then return nil end
  return collected, total, status
end

local function CLog_ResolveDisplayedGroupTotals(g, collected, total)
  -- First production integration point for the rebuilt backend.
  -- Only raid/dungeon rows are replaced here; Mounts/Pets/Toys/Housing tabs keep
  -- their established counters until migrated separately.
  local backendCollected, backendTotal, status = CLog_GetRaidAggregateBackendTotals(g)
  if backendTotal and backendTotal > 0 then
    return backendCollected, backendTotal, true, status
  end
  return collected, total, false
end

local function CLog_NormalizeLeftListTrustName(name)
  name = tostring(name or ""):lower()
  name = name:gsub("['â€™`_]", "")
  name = name:gsub("[%p%c]", " ")
  name = name:gsub("%s+", " ")
  name = name:match("^%s*(.-)%s*$") or ""
  return name
end

local function CLog_HasVerifiedLeftListColor(groupId)
  local gidKey = groupId and tostring(groupId) or nil
  if not gidKey then return false end
  local cached = UI and UI._clogLeftListColorCache and UI._clogLeftListColorCache[gidKey] or nil
  if type(cached) == "table" and cached.hard == true and tonumber(cached.total or 0) > 0 then
    return true
  end
  return UI and UI._clogLeftListTruthLock and UI._clogLeftListTruthLock[gidKey] and true or false
end

local function CLog_IsTrustedLeftListColorGroup(gOrId)
  if type(gOrId) == "table" then
    local g = gOrId
    if not CLog_IsRaidDungeonGroup(g) then return false end
    return CLog_HasVerifiedLeftListColor(g.id)
  end

  local groupId = gOrId and tostring(gOrId) or nil
  if not groupId then return false end
  local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[groupId] or ns.Data.groups[tonumber(groupId) or -1])
  if not g or not CLog_IsRaidDungeonGroup(g) then return false end
  return CLog_HasVerifiedLeftListColor(groupId)
end

local function CLog_GroupTotalsForLeftList(g)
  if not g then return 0, 0 end

  local backendCollected, backendTotal = CLog_GetRaidRowColorBackendTotals(g)
  if backendTotal and backendTotal > 0 then
    return backendCollected, backendTotal
  end

  local hideJunk = true

  local total = 0
  local collected = 0

  local function IsCollectedItem(itemID)
    -- Mirror the dungeon/raid header/grid collected logic so left-list always matches 100% state.
    local mode = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.viewMode or nil
    local guid = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCharacterGUID or nil

    -- Universal fast-paths (do not depend on section classification being ready).
    if ns and ns.IsMountCollected and ns.IsMountCollected(itemID) then
      return true
    end
    if ns and ns.IsPetCollected and ns.IsPetCollected(itemID) then
      return true
    end
    if ns and ns.IsToyCollected and ns.IsToyCollected(itemID) then
      return true
    end
    if ns and ns.IsAppearanceCollected and ns.IsAppearanceCollected(itemID) then
      return true
    end

    -- Section-aware handling (mounts/pets/toys inside raid/dungeon packs)
    local sec = (ns and ns.GetItemSectionFast and ns.GetItemSectionFast(itemID)) or nil
    if sec == "Mounts" then
      return (ns and ns.IsMountCollected and ns.IsMountCollected(itemID)) or false
    elseif sec == "Pets" then
      return (ns and ns.IsPetCollected and ns.IsPetCollected(itemID)) or false
    elseif sec == "Toys" then
      return (ns and ns.IsToyCollected and ns.IsToyCollected(itemID)) or false
    end

    -- Generic loot (recorded drops OR Blizzard truth)
    local recCount = (ns and ns.GetRecordedCount and mode and guid) and ns.GetRecordedCount(itemID, mode, guid) or 0
    local blizzCollected = (ns and ns.IsCollected and ns.IsCollected(itemID)) or false
    return (recCount and recCount > 0) or blizzCollected
  end

  -- Fast status flags so we can early-exit once we know it's "partial" (yellow).
  local anyCollected = false
  local allCollected = true

  local function ShouldCountItem(itemID)
    if not hideJunk then return true end
    -- Match the dungeon/raid header/grid behavior: Hide Junk removes non-core loot IDs.
    if type(CL_IsCoreLootItemID) == "function" then
      return CL_IsCoreLootItemID(itemID)
    end
    return true
  end

  local function Consider(itemID)
    if not ShouldCountItem(itemID) then return false end
    total = total + 1

    local isCol = IsCollectedItem(itemID)
    if isCol then
      anyCollected = true
      collected = collected + 1
    else
      allCollected = false
    end

    -- Once we know it's neither 0% nor 100% we can stop scanning the rest.
    if anyCollected and (not allCollected) then
      return true
    end
    return false
  end

  -- EJ packs: items is authoritative; itemLinks may exist as well.
  local items = g.items or g.itemIDs or nil
  if type(items) == "table" then
    for _, id in ipairs(items) do
      local itemID = tonumber(id)
      if itemID and itemID > 0 then
        if Consider(itemID) then break end
      end
    end
  end

  -- Some packs store itemLinks without duplicating items.
  if total == 0 and type(g.itemLinks) == "table" then
    for _, linkOrID in ipairs(g.itemLinks) do
      local itemID = tonumber(linkOrID)
      if itemID and itemID > 0 then
        if Consider(itemID) then break end
      end
    end
  end

  collected, total = CLog_ResolveDisplayedGroupTotals(g, collected, total)
  return collected, total
end

local function CLog_ColorForCompletion(collected, total)
  if not total or total <= 0 then
    return 0.55, 0.55, 0.55, 1 -- gray
  end

  if collected <= 0 then
    return 1.00, 0.35, 0.35, 1 -- red
  end

  if collected >= total then
    return 0.30, 1.00, 0.30, 1 -- green
  end

  return 1.00, 0.88, 0.25, 1 -- yellow
end

-- Forward declarations used by cached category row counters. These helpers are
-- implemented later with the raid/dungeon filtering code, but the category
-- counter lives earlier in the file. Without these locals, Lua resolves them as
-- globals and the Hide Unobtainable filter silently gets skipped.
local CLOG_ShouldHideUnobtainable
local CL_IsUnobtainableMountID
local CL_GetVisibleGroupList

-- ============================================================
-- Cached left-list category counts (Mounts/Pets/Toys/Housing/Appearances)
-- ============================================================
UI._clogCategoryRowCountCache = UI._clogCategoryRowCountCache or {}
UI._clogPerfStats = UI._clogPerfStats or { categoryCountBuilds = 0, categoryCountMs = 0 }

local function CLOG_FormatCount(n)
  n = tonumber(n) or 0
  local s = tostring(math.floor(n))
  local left, num, right = string.match(s, '^([^%d]*%d)(%d*)(.-)$')
  if not num then return s end
  return left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse()) .. right
end

local function CLOG_IsCategoryCountGroup(g)
  if type(g) ~= 'table' then return false end
  local cat = g.category
  return cat == 'Mounts' or cat == 'Pets' or cat == 'Toys' or cat == 'Housing'
end

local function CLOG_GetRawGroupItems(g)
  if type(g) ~= 'table' then return nil end
  if type(g.mounts) == 'table' then return g.mounts end
  if type(g.pets) == 'table' then return g.pets end
  if type(g.items) == 'table' then return g.items end
  if type(g.itemIDs) == 'table' then return g.itemIDs end
  return nil
end


local function CLOG_IsAllMountsGroup(g)
  if type(g) ~= 'table' or g.category ~= 'Mounts' then return false end
  local id = tostring(g.id or ''):lower()
  local name = tostring(g.name or ''):lower()
  return id == 'mounts:all' or id == 'mounts:mje:all' or name == 'all mounts' or name == 'mounts'
end

local function CLOG_GetMountJournalDisplayedTotals()
  if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return nil end
  local ids
  if ns and ns.GetValidMountJournalIDs then
    local ok, res = pcall(ns.GetValidMountJournalIDs)
    if ok and type(res) == 'table' then ids = res end
  end
  if not ids and C_MountJournal.GetMountIDs then
    local ok, res = pcall(C_MountJournal.GetMountIDs)
    if ok and type(res) == 'table' then ids = res end
  end
  if type(ids) ~= 'table' then return nil end

  local hideUnob = CLOG_ShouldHideUnobtainable and CLOG_ShouldHideUnobtainable()
  local total, collected = 0, 0
  for i = 1, #ids do
    local mountID = tonumber(ids[i])
    if mountID and mountID > 0 then
      local ok, _, _, _, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
      if ok then
        local include = true
        if hideUnob and CL_IsUnobtainableMountID and CL_IsUnobtainableMountID(mountID) and not isCollected then
          include = false
        end
        if include then
          total = total + 1
          if isCollected then collected = collected + 1 end
        end
      end
    end
  end
  return collected, total
end

local function CLOG_CountCategoryGroupNow(g)
  local start = (debugprofilestop and debugprofilestop()) or nil
  local total, collected = 0, 0

  if not CLOG_IsCategoryCountGroup(g) then return nil end

  local cat = g.category

  -- Top-level Mounts totals must use the same Blizzard-journal scope as the Mounts tab/Overview.
  -- Counting the sidebar group's raw mount list can include retired/unobtainable IDs even when
  -- Hide Unobtainable is enabled, which caused mismatches like 191/1602 vs 191/1504.
  if cat == 'Mounts' and CLOG_IsAllMountsGroup and CLOG_IsAllMountsGroup(g) then
    local mc, mt = CLOG_GetMountJournalDisplayedTotals and CLOG_GetMountJournalDisplayedTotals()
    if type(mc) == 'number' and type(mt) == 'number' and mt > 0 then
      return mc, mt
    end
  end

  if cat == 'Housing' and type(g.collectedCount) == 'number' and type(g.totalCount) == 'number' then
    collected, total = g.collectedCount or 0, g.totalCount or 0
  else
    -- Category row totals must match the visible list. In particular, Mounts
    -- must honor the Hide Unobtainable setting here too, otherwise the row
    -- can show e.g. 191/1602 while the tab itself correctly shows 191/1504.
    local values = CL_GetVisibleGroupList and CL_GetVisibleGroupList(g) or (CLOG_GetRawGroupItems(g) or {})
    total = #values

    if cat == 'Mounts' then
      for i = 1, total do
        local mountID = values[i]
        local isCollected = false
        if C_MountJournal and C_MountJournal.GetMountInfoByID then
          local ok, _, _, _, _, _, _, _, _, _, _, owned = pcall(C_MountJournal.GetMountInfoByID, mountID)
          isCollected = ok and owned == true
        end
        if isCollected then collected = collected + 1 end
      end
    elseif cat == 'Pets' then
      for i = 1, total do
        local speciesID = tonumber(values[i])
        local isCollected = false
        if speciesID and speciesID > 0 and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
          local ok, numCollected = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
          isCollected = ok and type(numCollected) == 'number' and numCollected > 0
        end
        if isCollected then collected = collected + 1 end
      end
    elseif cat == 'Toys' then
      for i = 1, total do
        local itemID = values[i]
        local ok, has = false, false
        if ns and ns.IsToyCollected then ok, has = pcall(ns.IsToyCollected, itemID) end
        if ok and has then collected = collected + 1 end
      end
    elseif cat == 'Housing' then
      for i = 1, total do
        local itemID = values[i]
        local has = false
        if UI and UI.HousingIsCollectedCached then
          has = UI.HousingIsCollectedCached(itemID) and true or false
        end
        if not has and ns and ns.IsHousingCollected then
          local ok, res = pcall(ns.IsHousingCollected, itemID)
          has = ok and res or false
        end
        if has then collected = collected + 1 end
      end
    elseif cat == 'Appearances' then
      for i = 1, total do
        local itemID = values[i]
        local has = false
        if ns and ns.IsAppearanceCollected then
          local ok, res = pcall(ns.IsAppearanceCollected, itemID)
          has = ok and res or false
        end
        if not has and ns and ns.IsCollected then
          local ok, res = pcall(ns.IsCollected, itemID)
          has = ok and res or false
        end
        if has then collected = collected + 1 end
      end
    end
  end

  if CLog_ResolveDisplayedGroupTotals then
    collected, total = CLog_ResolveDisplayedGroupTotals(g, collected, total)
  end

  if start and UI and UI._clogPerfStats then
    UI._clogPerfStats.categoryCountBuilds = (UI._clogPerfStats.categoryCountBuilds or 0) + 1
    UI._clogPerfStats.categoryCountMs = (UI._clogPerfStats.categoryCountMs or 0) + (((debugprofilestop and debugprofilestop()) or start) - start)
  end

  return collected or 0, total or 0
end

local function CLOG_GetCategoryRowCount(g)
  if not CLOG_IsCategoryCountGroup(g) then return nil end
  local gid = tostring(g.id or g.name or '')
  if gid == '' then return nil end
  local hideFlag = (CLOG_ShouldHideUnobtainable and CLOG_ShouldHideUnobtainable()) and 'hideU=1' or 'hideU=0'
  gid = gid .. '|' .. hideFlag

  UI._clogCategoryRowCountCache = UI._clogCategoryRowCountCache or {}
  local cached = UI._clogCategoryRowCountCache[gid]
  if cached then return cached.collected or 0, cached.total or 0 end

  local c, t = CLOG_CountCategoryGroupNow(g)
  if c ~= nil and t ~= nil then
    cached = { collected = c, total = t }
    UI._clogCategoryRowCountCache[gid] = cached
    return c, t
  end
  return nil
end

local function CLOG_ClearCategoryRowCountCache()
  UI._clogCategoryRowCountCache = UI._clogCategoryRowCountCache or {}
  if wipe then wipe(UI._clogCategoryRowCountCache) else for k in pairs(UI._clogCategoryRowCountCache) do UI._clogCategoryRowCountCache[k] = nil end end
end
UI.ClearCategoryRowCountCache = CLOG_ClearCategoryRowCountCache

local function CLOG_ApplyCategoryRowCountVisual(btn, g)
  if not (btn and btn.text and btn.diffText and CLOG_IsCategoryCountGroup(g)) then return false end
  local c, t = CLOG_GetCategoryRowCount(g)
  if c == nil or t == nil then return false end
  local r, gg, b, a = CLog_ColorForCompletion(c, t)
  btn.diffText:SetText(("%s/%s"):format(CLOG_FormatCount(c), CLOG_FormatCount(t)))
  btn.diffText:SetTextColor(r, gg, b, a)
  btn.diffText:Show()
  btn._clogDifficultyTipLines = nil
  btn._clogDifficultyTipTitle = nil
  btn.text:SetTextColor(r, gg, b, a)
  return true
end


CLog_IsRaidDungeonGroup = function(g)
  if type(g) ~= "table" then return false end
  local cat = g.category
  return cat == "Raids" or cat == "Dungeons"
end

CLog_ShouldPersistPrecomputeResult = function(g, collected, total)
  if total == nil or collected == nil then return false end
  if total <= 0 then return false end

  if type(g) == "table" and CLog_IsRaidDungeonGroup(g) then
    local backendCollected, backendTotal = CLog_GetRaidRowColorBackendTotals(g)
    if backendTotal and backendTotal > 0 and tonumber(collected or 0) == backendCollected and tonumber(total or 0) == backendTotal then
      return true
    end
  end

  -- Raid/Dungeon startup precompute can see temporarily-false pet/mount token states.
  -- Do not persist those rows until the canonical collectible resolvers have warmed.
  if CLog_IsRaidDungeonGroup(g) then
    if ns and ns.AreCollectionResolversWarm and not ns.AreCollectionResolversWarm() then
      return false
    end
    return (collected <= 0) or (collected >= total)
  end

  return true
end


local function CLog_ApplyLeftListTextColor(groupId, isActive)
  groupId = groupId and tostring(groupId) or nil
  local btn = groupId and UI._clogGroupBtnById and UI._clogGroupBtnById[groupId]
  if not btn or not btn.text then return end

  local g = groupId and ns and ns.Data and ns.Data.groups and (ns.Data.groups[groupId] or ns.Data.groups[tonumber(groupId) or -1]) or nil

  if g and CLog_IsRaidDungeonGroup and CLog_IsRaidDungeonGroup(g) then
    -- v4.3.70: Raid/Dungeon row names must reflect the aggregate state of all
    -- real sibling difficulties. A single completed difficulty is not enough
    -- to paint the instance name green. This is cache-only and never calls the
    -- TrueCollection backend from a tab click.
    local agg = CLOG_GetCachedDifficultyAggregateForRow and CLOG_GetCachedDifficultyAggregateForRow(g) or nil
    if agg and (tonumber(agg.known or 0) or 0) > 0 then
      local r, gg, b, a
      if agg.allKnown and agg.allComplete and (tonumber(agg.total or 0) or 0) > 0 then
        r, gg, b, a = CLog_ColorForCompletion(agg.total, agg.total)
      elseif agg.allKnown and (tonumber(agg.total or 0) or 0) > 0 then
        r, gg, b, a = CLog_ColorForCompletion(agg.collected or 0, agg.total or 0)
      elseif (tonumber(agg.collected or 0) or 0) > 0 then
        -- Some difficulties are still uncached. Never show green in this state.
        r, gg, b, a = 1.00, 0.88, 0.25, 1
      else
        -- Unknown/uncached aggregate: keep the classic inactive/active styling.
        if isActive then
          r, gg, b, a = 1, 0.90, 0.20, 1
        else
          r, gg, b, a = 0.68, 0.66, 0.55, 1
        end
      end
      btn.text:SetTextColor(r, gg, b, a)
      return
    end

    -- No cached aggregate yet: do not fall back to a single difficulty's cached
    -- status, because that is exactly how false-green instance names happen.
    if isActive then
      btn.text:SetTextColor(1, 0.90, 0.20, 1)
    else
      btn.text:SetTextColor(0.68, 0.66, 0.55, 1)
    end
    return
  end

  if not CLog_IsTrustedLeftListColorGroup(groupId) then
    if isActive then
      btn.text:SetTextColor(1, 0.90, 0.20, 1)
    else
      btn.text:SetTextColor(0.68, 0.66, 0.55, 1)
    end
    return
  end

  -- Non-raid/dungeon trusted rows can still use their own cached row total.
  local c = UI._clogLeftListColorCache and UI._clogLeftListColorCache[groupId]
  if c and c.total and c.total > 0 then
    local r,gg,b,a = CLog_ColorForCompletion(c.collected or 0, c.total or 0)
    btn.text:SetTextColor(r,gg,b,a)
    return
  end

  if isActive then
    btn.text:SetTextColor(1, 0.90, 0.20, 1)
  else
    btn.text:SetTextColor(0.68, 0.66, 0.55, 1)
  end
end

local function CLog_RefreshVisibleGroupButtonState(btn, cat)
  if not btn then return end

  local activeId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId or nil
  local btnId = btn.groupId
  local isActive = (activeId ~= nil and btnId ~= nil and tostring(activeId) == tostring(btnId)) and true or false

  btn._clogIsActive = isActive

  if isActive then
    btn:SetBackdropColor(0.11, 0.11, 0.11, 0.95)
    btn:SetBackdropBorderColor(1.00, 0.90, 0.20, 0.60)
    if btn.__clogSheen then btn.__clogSheen:SetVertexColor(1, 1, 1, 0.22) end
  else
    btn:SetBackdropColor(0.06, 0.06, 0.06, 0.90)
    btn:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.45)
    if btn.__clogSheen then btn.__clogSheen:SetVertexColor(1, 1, 1, 0.06) end
  end

  if btn._clogActiveBG then btn._clogActiveBG:SetShown(isActive) end
  if btn._clogAccent then btn._clogAccent:Hide() end

  if btn.text then
    if cat == "Dungeons" or cat == "Raids" then
      if btnId ~= nil then
        UI._clogGroupBtnById = UI._clogGroupBtnById or {}
        UI._clogGroupBtnById[tostring(btnId)] = btn
        CLog_ApplyLeftListTextColor(btnId, isActive)
      end
    else
      -- Mounts/Pets/Toys/Housing rows have persistent completion colors/counts.
      -- Selection/hover refreshes should only change the row backdrop, not wipe the
      -- red/yellow/green text color after the user clicks away.
      local categoryGroup = nil
      if btnId ~= nil and ns and ns.Data and ns.Data.groups then
        categoryGroup = ns.Data.groups[tostring(btnId)] or ns.Data.groups[tonumber(btnId) or -1]
      end
      if categoryGroup and CLOG_IsCategoryCountGroup and CLOG_IsCategoryCountGroup(categoryGroup) then
        CLOG_ApplyCategoryRowCountVisual(btn, categoryGroup)
      elseif isActive then
        btn.text:SetTextColor(1, 0.90, 0.20, 1)
      else
        btn.text:SetTextColor(0.68, 0.66, 0.55, 1)
      end
    end
  end
end

UI.RefreshVisibleGroupButtonState = CLog_RefreshVisibleGroupButtonState

local function CLog_QueueLeftListColor(groupId)
  if not groupId then return end
  groupId = tostring(groupId)
  if not CLog_IsTrustedLeftListColorGroup(groupId) then return end
  if UI._clogLeftListTruthLock and UI._clogLeftListTruthLock[groupId] then return end
  if UI._clogLeftListColorCache and UI._clogLeftListColorCache[groupId] then return end
  UI._clogLeftListColorQueue = UI._clogLeftListColorQueue or {}
  UI._clogLeftListColorQueue[groupId] = true
end

local function CLog_ProcessLeftListColorQueue()
  if not UI._clogLeftListColorQueue then return end
  if InCombatLockdown and InCombatLockdown() then return end

  local processed = 0
  local BATCH = 60

  local start = GetTime and GetTime() or 0
  local budget = 0.010 -- ~10ms per frame

  for groupId, queued in pairs(UI._clogLeftListColorQueue) do
    if queued then
      UI._clogLeftListColorQueue[groupId] = nil

      local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[groupId] or ns.Data.groups[tonumber(groupId) or -1])
      if not CLog_IsTrustedLeftListColorGroup(g) then
        if UI._clogLeftListColorCache then UI._clogLeftListColorCache[groupId] = nil end
      elseif UI._clogLeftListTruthLock and UI._clogLeftListTruthLock[groupId] then
        -- Header/grid truth already cached; keep it.
      else
        local collected, total = CLog_GroupTotalsForLeftList(g)
        UI._clogLeftListColorCache[groupId] = { collected = collected, total = total }
      end

      local activeId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil
      local isActive = (activeId and tostring(activeId) == groupId) or false
      CLog_ApplyLeftListTextColor(groupId, isActive)

      processed = processed + 1
      if processed >= BATCH then break end
      if GetTime and (GetTime() - start) > budget then break end
    end
  end

  -- Stop updates if queue is empty
  local hasMore = false
  for _ in pairs(UI._clogLeftListColorQueue) do hasMore = true break end
  if not hasMore and UI._clogLeftColorDriver then
    UI._clogLeftColorDriver:SetScript("OnUpdate", nil)
  end
end


-- =====================
-- Left-list precompute (throttled; no OnUpdate)
--
-- Users want:
-- * Colors to appear without clicking every row
-- * No first-open hitch
-- * Remember colors across sessions
--
-- Strategy:
-- * Paint instantly from persisted cache (loaded in EnsureUIState)
-- * Quietly compute missing groups in small timer-sliced batches
-- * Never overwrite header/grid truth (truthLock)
-- =====================
UI._clogLeftPrecomputeRunning = UI._clogLeftPrecomputeRunning or false

local function CLog_LeftPrecomputeStep()
  if not UI._clogLeftPrecomputeRunning then return end
  if not UI._clogLeftListColorQueue then UI._clogLeftPrecomputeRunning = false return end

  -- Avoid combat.
  if InCombatLockdown and InCombatLockdown() then
    if C_Timer and C_Timer.After then C_Timer.After(0.75, CLog_LeftPrecomputeStep) end
    return
  end

  local start = (GetTime and GetTime()) or 0
  local budget = 0.0025 -- ~2.5ms per slice
  local batch = 2
  local processed = 0

  for gidKey, queued in pairs(UI._clogLeftListColorQueue) do
    if queued then
      UI._clogLeftListColorQueue[gidKey] = nil
      gidKey = tostring(gidKey)

      -- Never overwrite header/grid truth.
      if UI._clogLeftListTruthLock and UI._clogLeftListTruthLock[gidKey] then
        -- noop
      else
        -- Skip if we already have a cached value (persisted or computed earlier).
        if not (UI._clogLeftListColorCache and UI._clogLeftListColorCache[gidKey]) then
          local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
          if g and CLog_IsRaidDungeonGroup(g) then
            -- TrueCollection backend does not depend on item-cache/header warm-up,
            -- but requesting item data remains useful for names/tooltips.
            CLog_RequestGroupItemData(g)
          end
          local hasTrueBackend = false
          if g and CLog_IsRaidDungeonGroup(g) then
            local _, backendTotal = CLog_GetRaidRowColorBackendTotals(g)
            hasTrueBackend = (backendTotal and backendTotal > 0) and true or false
          end
          if (not hasTrueBackend) and g and CLog_IsRaidDungeonGroup(g) and ns and ns.AreCollectionResolversWarm and not ns.AreCollectionResolversWarm() then
            UI._clogLeftListColorQueue[gidKey] = true
          elseif (not hasTrueBackend) and g and not CLog_GroupPrecomputeReady(g) then
            UI._clogLeftListColorQueue[gidKey] = true
          elseif g then
            local ok, collected, total = pcall(function() return CLog_GroupTotalsForLeftList(g) end)
            if ok and total ~= nil and collected ~= nil then
              local canPersist = CLog_ShouldPersistPrecomputeResult(g, collected, total)
              UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
              UI._clogLeftListColorCache[gidKey] = CLOG_MakeLeftListCacheEntry(collected, total, canPersist, "precompute")
              if CLOG_InvalidateDifficultyIndicatorForGroup then CLOG_InvalidateDifficultyIndicatorForGroup(gidKey) end
              if CLOG_ScheduleDifficultyIndicatorRepaintForGroup then CLOG_ScheduleDifficultyIndicatorRepaintForGroup(gidKey) end

              -- Persist only trusted startup truth. Raid/Dungeon partials stay session-only
              -- so a temporary false yellow cannot poison the next login.
              if canPersist and CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
                CollectionLogDB.ui.leftListColorCache.cache[gidKey] = CLOG_MakeLeftListCacheEntry(collected, total, true, "precompute")
                if CollectionLogDB.ui.leftListColorCache.meta then
                  CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
                end
              end
            end
          end
        end

        -- Apply if row exists
        local activeId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil
        local isActive = (activeId and tostring(activeId) == gidKey) or false
        CLog_ApplyLeftListTextColor(gidKey, isActive)
      end

      processed = processed + 1
      if processed >= batch then break end
      if GetTime and (GetTime() - start) > budget then break end
    end
  end

  local hasMore = false
  for _, v in pairs(UI._clogLeftListColorQueue) do if v then hasMore = true break end end
  if hasMore then
    if C_Timer and C_Timer.After then C_Timer.After(0.05, CLog_LeftPrecomputeStep) end
  else
    UI._clogLeftPrecomputeRunning = false
  end
end

function UI.QueueLeftListPrecompute(groupIdList, reason)
  if not groupIdList or type(groupIdList) ~= "table" then return end
  local uiState = CollectionLogDB and CollectionLogDB.ui or nil
  local force = (reason == "manual" or reason == "force" or reason == true)
  local autoWarm = uiState and uiState.autoWarmRaidDungeonSidebar == true
  if not force and not autoWarm then return end
  if not force and not (uiState and uiState.precomputeLeftListColors == true) then return end

  UI._clogLeftListColorQueue = UI._clogLeftListColorQueue or {}
  UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}

  for _, gid in ipairs(groupIdList) do
    local gidKey = tostring(gid)
    local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
    if gidKey and gidKey ~= "" then
      -- v4.3.28: Raid/Dungeon colors can now be safely precomputed because
      -- TrueCollection is UI-independent and canonical-deduped.
      if not UI._clogLeftListColorCache[gidKey] and not (UI._clogLeftListTruthLock and UI._clogLeftListTruthLock[gidKey]) then
        UI._clogLeftListColorQueue[gidKey] = true
      end
    end
  end

  if UI._clogLeftPrecomputeRunning then return end
  UI._clogLeftPrecomputeRunning = true
  if C_Timer and C_Timer.After then
    -- Let the list render first so opening the UI is instant.
    C_Timer.After(0.20, CLog_LeftPrecomputeStep)
  end
end


-- =====================
-- Debug helpers (on-demand; no loops)
-- /clog leftdebug [groupId] [recalc]
-- =====================
function UI.Debug_GroupTotalsForLeftList(groupId)
  if not groupId then return nil end
  local gidKey = tostring(groupId)
  local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
  if not g then return nil end
  local ok, collected, total = pcall(function()
    return CLog_GroupTotalsForLeftList(g)
  end)
  if not ok then return nil end
  return collected, total
end

function UI.Debug_LeftListSnapshot(groupId)
  local gidKey = groupId and tostring(groupId) or nil
  local snap = {
    groupId = gidKey,
    cache = nil,
    truthLock = false,
    button = { exists = false, r=nil,g=nil,b=nil,a=nil, text=nil },
    headerText = nil,
  }
  if not gidKey then return snap end
  if UI._clogLeftListColorCache then snap.cache = UI._clogLeftListColorCache[gidKey] end
  if UI._clogLeftListTruthLock then snap.truthLock = not not UI._clogLeftListTruthLock[gidKey] end
  if UI._clogGroupBtnById and UI._clogGroupBtnById[gidKey] then
    local btn = UI._clogGroupBtnById[gidKey]
    if btn and btn.text then
      snap.button.exists = true
      snap.button.text = btn.text:GetText()
      if btn.text.GetTextColor then
        local r,g,b,a = btn.text:GetTextColor()
        snap.button.r, snap.button.g, snap.button.b, snap.button.a = r,g,b,a
      end
    end
  end
  if UI.groupCount and UI.groupCount.GetText then
    snap.headerText = UI.groupCount:GetText()
  end
  return snap
end



-- ============================================================
-- Raid/Dungeon difficulty indicators (left list)
-- Shows all real sibling difficulties for a visible raid/dungeon row and
-- colors each label from the TrueCollection backend.  This is display-only:
-- it does not open rows, scan EJ, or change collection truth.
-- ============================================================
local CLOG_DIFFICULTY_ORDER = {
  [7] = 10, [17] = 10,
  [1] = 20, [14] = 20,
  [3] = 21, [4] = 22,
  [2] = 30, [15] = 30,
  [5] = 31, [6] = 32,
  [16] = 40, [23] = 40,
  [24] = 50, [33] = 50,
}

local function CLOG_DifficultyLabel(difficultyID, mode)
  difficultyID = tonumber(difficultyID)
  local m = tostring(mode or "")
  local ml = m:lower()
  if difficultyID == 7 or difficultyID == 17 or ml:find("looking for raid", 1, true) or ml:find("lfr", 1, true) then return "LFR" end
  if difficultyID == 9 or ml:find("40 player", 1, true) or ml:find("40%-player") or ml:find("40 man", 1, true) then return "N(40)" end
  if difficultyID == 3 then return "N(10)" end
  if difficultyID == 4 then return "N(25)" end
  if difficultyID == 5 then return "H(10)" end
  if difficultyID == 6 then return "H(25)" end
  if difficultyID == 1 or difficultyID == 14 or ml == "normal" then return "N" end
  if difficultyID == 2 or difficultyID == 15 or ml == "heroic" then return "H" end
  if difficultyID == 16 or difficultyID == 23 or ml == "mythic" then return "M" end
  if difficultyID == 24 or difficultyID == 33 or ml:find("timewalking", 1, true) then return "TW" end
  if m ~= "" then
    local first = m:match("%u") or m:sub(1, 1):upper()
    return first ~= "" and first or tostring(difficultyID or "?")
  end
  return tostring(difficultyID or "?")
end

local function CLOG_DifficultyFullName(difficultyID, mode)
  difficultyID = tonumber(difficultyID)
  local m = tostring(mode or "")
  local ml = m:lower()
  if difficultyID == 9 or ml:find("40 player", 1, true) or ml:find("40%-player") or ml:find("40 man", 1, true) then return "Normal (40)" end
  if m ~= "" then return m end
  if difficultyID == 7 or difficultyID == 17 then return "Looking For Raid" end
  if difficultyID == 3 then return "Normal (10)" end
  if difficultyID == 4 then return "Normal (25)" end
  if difficultyID == 5 then return "Heroic (10)" end
  if difficultyID == 6 then return "Heroic (25)" end
  if difficultyID == 1 or difficultyID == 14 then return "Normal" end
  if difficultyID == 2 or difficultyID == 15 then return "Heroic" end
  if difficultyID == 16 or difficultyID == 23 then return "Mythic" end
  if difficultyID == 24 or difficultyID == 33 then return "Timewalking" end
  return "Difficulty " .. tostring(difficultyID or "?")
end

local function CLOG_DifficultySortKey(g)
  local did = tonumber(g and g.difficultyID)
  local base = CLOG_DIFFICULTY_ORDER[did] or 999
  return base, tostring(g and (g.mode or g.name or g.id) or "")
end

local function CLOG_RawKeyForGroup(g)
  if not g then return nil end
  if ns and ns.Registry and ns.Registry.GetRawGroupKey then
    local ok, key = pcall(ns.Registry.GetRawGroupKey, g)
    if ok and key then return key end
  end
  return g.id and ("raw:" .. tostring(g.id)) or nil
end

-- Cached TrueCollection status for the current sidebar refresh scope.
-- BuildGroupList asks for the same raid/dungeon statuses multiple ways:
--   * row text color
--   * difficulty indicator color
--   * tooltip lines
-- Without this cache, each visible row can re-run the backend resolver for every
-- sibling difficulty, which is the multi-second BuildGroupList spike seen in /clogperf.
CLOG_TRUE_STATUS_CACHE = CLOG_TRUE_STATUS_CACHE or {}

function CLOG_ResetTrueStatusCache()
  if type(wipe) == "function" then
    wipe(CLOG_TRUE_STATUS_CACHE)
  else
    for k in pairs(CLOG_TRUE_STATUS_CACHE) do CLOG_TRUE_STATUS_CACHE[k] = nil end
  end
end

function CLOG_GetTrueCollectionStatusCached(g)
  if not (g and ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus) then return nil end
  local key = CLOG_RawKeyForGroup(g) or (tostring(g.category or "") .. ":" .. tostring(g.id or ""))
  if key == "" then return nil end
  local cached = CLOG_TRUE_STATUS_CACHE[key]
  if cached ~= nil then return cached or nil end
  local ok, status = pcall(ns.TrueCollection.GetGroupStatus, g)
  if ok and type(status) == "table" then
    CLOG_TRUE_STATUS_CACHE[key] = status
    return status
  end
  CLOG_TRUE_STATUS_CACHE[key] = false
  return nil
end

CLOG_AGGREGATE_DIFFICULTY_TOTALS_CACHE = CLOG_AGGREGATE_DIFFICULTY_TOTALS_CACHE or {}

function CLOG_ResetAggregateDifficultyTotalsCache()
  if type(wipe) == "function" then
    wipe(CLOG_AGGREGATE_DIFFICULTY_TOTALS_CACHE)
  else
    for k in pairs(CLOG_AGGREGATE_DIFFICULTY_TOTALS_CACHE) do CLOG_AGGREGATE_DIFFICULTY_TOTALS_CACHE[k] = nil end
  end
end

local function CLOG_StatusColorCode(status)
  local c = tonumber(status and status.collected or 0) or 0
  local t = tonumber(status and status.total or 0) or 0
  if t <= 0 then return "ff888888", 0.55, 0.55, 0.55, "No tracked collectibles" end
  if c >= t then return "ff39d353", 0.22, 0.83, 0.33, "Complete" end
  if c <= 0 then return "ffff5555", 1.00, 0.33, 0.33, "Missing" end
  return "ffffd24a", 1.00, 0.82, 0.29, "Partial"
end

CLOG_DIFFICULTY_SIBLING_CACHE = CLOG_DIFFICULTY_SIBLING_CACHE or {}

function CLOG_ResetDifficultySiblingCache()
  if type(wipe) == "function" then
    wipe(CLOG_DIFFICULTY_SIBLING_CACHE)
  else
    for k in pairs(CLOG_DIFFICULTY_SIBLING_CACHE) do CLOG_DIFFICULTY_SIBLING_CACHE[k] = nil end
  end
end

function CLOG_GetDifficultySiblingIndex(cat)
  cat = tostring(cat or "")
  if cat == "" then return nil end
  local cached = CLOG_DIFFICULTY_SIBLING_CACHE[cat]
  if cached then return cached end

  local list = ns and ns.Data and ns.Data.groupsByCategory and ns.Data.groupsByCategory[cat]
  if type(list) ~= "table" then return nil end

  local index = { byGroupId = {}, byInstance = {}, byName = {} }
  for i = 1, #list do
    local sg = list[i]
    if sg and sg.id and sg.category == cat and sg.difficultyID then
      local bucketKey
      local instanceID = tonumber(sg.instanceID)
      if instanceID then
        bucketKey = "i:" .. tostring(instanceID)
        index.byInstance[bucketKey] = index.byInstance[bucketKey] or {}
        index.byInstance[bucketKey][#index.byInstance[bucketKey] + 1] = sg
      else
        local n = tostring(sg.name or "")
        if n ~= "" then
          bucketKey = "n:" .. n
          index.byName[bucketKey] = index.byName[bucketKey] or {}
          index.byName[bucketKey][#index.byName[bucketKey] + 1] = sg
        end
      end
    end
  end

  local function FinalizeBucket(bucket)
    local seen, out = {}, {}
    for i = 1, #bucket do
      local sg = bucket[i]
      local didKey = tostring(sg.difficultyID) .. ":" .. tostring(sg.mode or "")
      if not seen[didKey] then
        seen[didKey] = true
        out[#out + 1] = sg
      end
    end
    table.sort(out, function(a, b)
      local oa, na = CLOG_DifficultySortKey(a)
      local ob, nb = CLOG_DifficultySortKey(b)
      if oa ~= ob then return oa < ob end
      return na < nb
    end)
    return out
  end

  for key, bucket in pairs(index.byInstance) do index.byInstance[key] = FinalizeBucket(bucket) end
  for key, bucket in pairs(index.byName) do index.byName[key] = FinalizeBucket(bucket) end

  for i = 1, #list do
    local sg = list[i]
    if sg and sg.id and sg.category == cat then
      local instanceID = tonumber(sg.instanceID)
      local key = instanceID and ("i:" .. tostring(instanceID)) or ("n:" .. tostring(sg.name or ""))
      index.byGroupId[tostring(sg.id)] = (instanceID and index.byInstance[key]) or index.byName[key]
    end
  end

  CLOG_DIFFICULTY_SIBLING_CACHE[cat] = index
  return index
end

function CLOG_GetDifficultySiblings(g)
  if not (g and (g.category == "Raids" or g.category == "Dungeons")) then return nil end
  local index = CLOG_GetDifficultySiblingIndex(g.category)
  if not index then return nil end
  return index.byGroupId[tostring(g.id or "")]
end

CLOG_DIFFICULTY_INDICATOR_CACHE = CLOG_DIFFICULTY_INDICATOR_CACHE or {}
CLOG_DIFFICULTY_INDICATOR_REV = CLOG_DIFFICULTY_INDICATOR_REV or 1

function CLOG_GetDifficultyIndicatorRev()
  return tonumber(CLOG_DIFFICULTY_INDICATOR_REV or 1) or 1
end

-- v4.3.87: one freshness contract for sidebar completion cache.
-- Difficulty colors should never be "fixed" by extra row-click work. They should
-- either read a cache entry that was created for the current data/settings schema,
-- or show neutral/unknown until Manual Refresh or exact active-row truth fills it.
CLOG_LEFTLIST_CACHE_SCHEMA = 3

function CLOG_LeftListCacheSignature()
  local hideU = (CLOG_ShouldHideUnobtainable and CLOG_ShouldHideUnobtainable()) and "1" or "0"
  local build = (ns and ns.VERSION) or ""
  return "schema=" .. tostring(CLOG_LEFTLIST_CACHE_SCHEMA) .. ";hideU=" .. hideU .. ";build=" .. tostring(build)
end

function CLOG_MakeLeftListCacheEntry(collected, total, hard, source)
  return {
    collected = tonumber(collected or 0) or 0,
    total = tonumber(total or 0) or 0,
    hard = hard == true,
    source = source,
    schema = CLOG_LEFTLIST_CACHE_SCHEMA,
    sig = CLOG_LeftListCacheSignature and CLOG_LeftListCacheSignature() or nil,
  }
end

function CLOG_IsLeftListCacheEntryFresh(entry, requireHard)
  if type(entry) ~= "table" then return false end
  if requireHard and entry.hard ~= true then return false end
  if tonumber(entry.total or 0) == nil or tonumber(entry.total or 0) <= 0 then return false end
  if tonumber(entry.collected or 0) == nil then return false end
  if tonumber(entry.schema or 0) ~= tonumber(CLOG_LEFTLIST_CACHE_SCHEMA or 0) then return false end
  local expected = CLOG_LeftListCacheSignature and CLOG_LeftListCacheSignature() or nil
  if expected and entry.sig ~= expected then return false end
  return true
end

function CLOG_InvalidateDifficultyIndicatorForGroup(groupId)
  local gidKey = groupId and tostring(groupId) or nil
  if not gidKey or gidKey == "" or not CLOG_DIFFICULTY_INDICATOR_CACHE then return end
  CLOG_DIFFICULTY_INDICATOR_CACHE[gidKey] = nil

  local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
  local siblings = g and CLOG_GetDifficultySiblings and CLOG_GetDifficultySiblings(g) or nil
  if type(siblings) == "table" then
    for i = 1, #siblings do
      local sg = siblings[i]
      if sg and sg.id then CLOG_DIFFICULTY_INDICATOR_CACHE[tostring(sg.id)] = nil end
    end
  end
end

function CLOG_ResetDifficultyIndicatorCache()
  CLOG_DIFFICULTY_INDICATOR_REV = (tonumber(CLOG_DIFFICULTY_INDICATOR_REV or 1) or 1) + 1
  if type(wipe) == "function" then
    wipe(CLOG_DIFFICULTY_INDICATOR_CACHE)
  else
    for k in pairs(CLOG_DIFFICULTY_INDICATOR_CACHE) do CLOG_DIFFICULTY_INDICATOR_CACHE[k] = nil end
  end
  -- v4.3.87: exact sibling refresh is disabled for normal row clicks; keep
  -- legacy queue state cleared on truth invalidation so it cannot revive stale work.
  if CLOG_EXACT_DIFFICULTY_REFRESHED then
    if type(wipe) == "function" then
      wipe(CLOG_EXACT_DIFFICULTY_REFRESHED)
    else
      for k in pairs(CLOG_EXACT_DIFFICULTY_REFRESHED) do CLOG_EXACT_DIFFICULTY_REFRESHED[k] = nil end
    end
  end
end

function CLOG_GetDifficultyIndicatorCached(g)
  local cacheKey = g and g.id and tostring(g.id) or nil
  if not cacheKey then return nil end
  local cached = CLOG_DIFFICULTY_INDICATOR_CACHE and CLOG_DIFFICULTY_INDICATOR_CACHE[cacheKey] or nil
  if type(cached) == "table" and cached.rev == CLOG_GetDifficultyIndicatorRev() then
    return cached.text, cached.lines, cached.complete
  end
  return nil
end

function CLOG_GetCachedDifficultyStatusOnly(sg)
  if not (sg and sg.id) then return nil end
  local gidKey = tostring(sg.id)

  -- Fastest/most stable source: left-list completion cache.  This is filled by
  -- selected-grid truth, manual Refresh, or the throttled color warmer.  Reading
  -- it here is cheap and does not invoke any collection resolver.
  local c = UI and UI._clogLeftListColorCache and UI._clogLeftListColorCache[gidKey] or nil
  if CLOG_IsLeftListCacheEntryFresh and CLOG_IsLeftListCacheEntryFresh(c, true) then
    return { collected = tonumber(c.collected or 0) or 0, total = tonumber(c.total or 0) or 0, cached = true }
  end

  -- Persisted cache from SavedVariables, mirrored on login but kept here as a
  -- direct fallback in case this function is called before the mirror pass.
  -- Stale schema/settings entries are intentionally ignored instead of being
  -- painted and then corrected by later UI interactions.
  local saved = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache and CollectionLogDB.ui.leftListColorCache.cache[gidKey] or nil
  if CLOG_IsLeftListCacheEntryFresh and CLOG_IsLeftListCacheEntryFresh(saved, true) then
    return { collected = tonumber(saved.collected or 0) or 0, total = tonumber(saved.total or 0) or 0, cached = true }
  end

  -- Last-resort read-only session cache.  Do not call TrueCollection here.
  -- The whole point of the difficulty strip is to consume already-known truth,
  -- never to generate truth during a tab click.
  local rawKey = CLOG_RawKeyForGroup and CLOG_RawKeyForGroup(sg) or nil
  local status = rawKey and CLOG_TRUE_STATUS_CACHE and CLOG_TRUE_STATUS_CACHE[rawKey] or nil
  if type(status) == "table" and tonumber(status.total or 0) and tonumber(status.total or 0) > 0 then
    return { collected = tonumber(status.collected or 0) or 0, total = tonumber(status.total or 0) or 0, cached = true }
  end

  return nil
end

function CLOG_GetCachedDifficultyAggregateForRow(g)
  if not (g and (g.category == "Raids" or g.category == "Dungeons")) then return nil end

  local siblings = CLOG_GetDifficultySiblings and CLOG_GetDifficultySiblings(g) or nil
  if type(siblings) ~= "table" or #siblings == 0 then siblings = { g } end

  local seen = {}
  local known, missing = 0, 0
  local collected, total = 0, 0
  local allKnown = true
  local allComplete = true

  for i = 1, #siblings do
    local sg = siblings[i]
    if sg and sg.id then
      local didKey = tostring(sg.difficultyID or sg.id) .. ":" .. tostring(sg.mode or "")
      if not seen[didKey] then
        seen[didKey] = true
        local status = CLOG_GetCachedDifficultyStatusOnly and CLOG_GetCachedDifficultyStatusOnly(sg) or nil
        local st = status and tonumber(status.total or 0) or 0
        if status and st > 0 then
          local sc = tonumber(status.collected or 0) or 0
          if sc < 0 then sc = 0 end
          if sc > st then sc = st end
          known = known + 1
          collected = collected + sc
          total = total + st
          if sc < st then allComplete = false end
        else
          missing = missing + 1
          allKnown = false
          allComplete = false
        end
      end
    end
  end

  if known <= 0 and missing <= 0 then return nil end
  return {
    collected = collected,
    total = total,
    known = known,
    missing = missing,
    allKnown = allKnown,
    allComplete = allComplete,
  }
end

function CLOG_SetDifficultyIndicatorButton(btn, g, text, lines)
  if not (btn and btn.diffText) then return end
  btn.diffText:SetText(text or "")
  btn.diffText:Show()
  btn._clogDifficultyTipLines = lines
  btn._clogDifficultyTipTitle = g and (g.name or g.id) or "Difficulties"
end

function CLOG_RepaintDifficultyIndicatorForGroup(groupId)
  local gidKey = groupId and tostring(groupId) or nil
  if not gidKey or gidKey == "" then return end
  if not (UI and UI._clogGroupBtnById and ns and ns.Data and ns.Data.groups) then return end

  local g = ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1]
  if not (g and (g.category == "Raids" or g.category == "Dungeons")) then return end

  -- The visible sidebar row can be any sibling difficulty for the same instance,
  -- depending on the current active/remembered difficulty. Repaint every visible
  -- sibling row we can find, but only from existing cached completion state.
  local siblings = (CLOG_GetDifficultySiblings and CLOG_GetDifficultySiblings(g)) or nil
  if type(siblings) ~= "table" or #siblings == 0 then siblings = { g } end

  local seen = {}
  local function repaintOne(sg)
    if not (sg and sg.id) then return end
    local key = tostring(sg.id)
    if seen[key] then return end
    seen[key] = true
    local btn = UI._clogGroupBtnById[key]
    if btn and btn:IsShown() and tostring(btn.groupId or "") == key then
      local text, lines
      if CLOG_BuildDifficultyIndicatorData then
        local ok, a, b = pcall(CLOG_BuildDifficultyIndicatorData, sg)
        if ok then text, lines = a, b end
      end
      CLOG_SetDifficultyIndicatorButton(btn, sg, text or "", lines)
    end
  end

  repaintOne(g)
  for i = 1, #siblings do repaintOne(siblings[i]) end
end

function CLOG_ScheduleDifficultyIndicatorRepaintForGroup(groupId)
  if not groupId then return end
  local gidKey = tostring(groupId)
  if CLOG_RepaintDifficultyIndicatorForGroup then CLOG_RepaintDifficultyIndicatorForGroup(gidKey) end
  if C_Timer and C_Timer.After then
    C_Timer.After(0, function()
      if CLOG_RepaintDifficultyIndicatorForGroup then CLOG_RepaintDifficultyIndicatorForGroup(gidKey) end
    end)
    C_Timer.After(0.05, function()
      if CLOG_RepaintDifficultyIndicatorForGroup then CLOG_RepaintDifficultyIndicatorForGroup(gidKey) end
    end)
  end
end


-- v4.3.85: exact sibling-difficulty snapshot.
--
-- The difficulty strip must not be driven by the currently selected dropdown
-- difficulty. The earlier cache-only approach avoided CPU spikes, but it also
-- meant labels could stay stale until the user manually selected each
-- difficulty. This refresher is the middle ground: when a raid/dungeon instance
-- is actively opened, snapshot only that instance's sibling difficulties in
-- tiny slices, store the results in the normal left-list cache, and repaint the
-- visible strip. No full sidebar scan, no EJ scan, no hover-time lookup.
CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE = CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE or {}
CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING = CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING or false
CLOG_EXACT_DIFFICULTY_REFRESHED = CLOG_EXACT_DIFFICULTY_REFRESHED or {}

function CLOG_ExactDifficultyRefreshBucketKey(g)
  if not g then return nil end
  local cat = tostring(g.category or "")
  local inst = tonumber(g.instanceID)
  if inst and inst > 0 then
    return cat .. ":i:" .. tostring(inst) .. ":rev:" .. tostring(CLOG_GetDifficultyIndicatorRev and CLOG_GetDifficultyIndicatorRev() or 1)
  end
  local name = tostring(g.name or g.id or "")
  if name ~= "" then
    return cat .. ":n:" .. name .. ":rev:" .. tostring(CLOG_GetDifficultyIndicatorRev and CLOG_GetDifficultyIndicatorRev() or 1)
  end
  return nil
end

function CLOG_DifficultyRefreshHasWork()
  if not CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE then return false end
  for _, queued in pairs(CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE) do
    if queued then return true end
  end
  return false
end

function CLOG_StoreExactDifficultyStatus(sg, status)
  if not (sg and sg.id and type(status) == "table") then return end
  local gidKey = tostring(sg.id)
  local total = tonumber(status.total or 0) or 0
  if total <= 0 then return end
  local collected = tonumber(status.collected or 0) or 0
  if collected < 0 then collected = 0 end
  if collected > total then collected = total end

  UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
  UI._clogLeftListColorCache[gidKey] = CLOG_MakeLeftListCacheEntry(collected, total, true, "active_sibling_exact")

  UI._clogLeftListTruthLock = UI._clogLeftListTruthLock or {}
  UI._clogLeftListTruthLock[gidKey] = true
  if UI._clogLeftListColorQueue then UI._clogLeftListColorQueue[gidKey] = nil end

  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
    CollectionLogDB.ui.leftListColorCache.cache[gidKey] = CLOG_MakeLeftListCacheEntry(collected, total, true, "active_sibling_exact")
    if CollectionLogDB.ui.leftListColorCache.meta then
      CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
    end
  end

  if CLOG_InvalidateDifficultyIndicatorForGroup then CLOG_InvalidateDifficultyIndicatorForGroup(gidKey) end
end

function CLOG_ExactDifficultyRefreshStep()
  if not CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING then return end
  if InCombatLockdown and InCombatLockdown() then
    if C_Timer and C_Timer.After then C_Timer.After(0.75, CLOG_ExactDifficultyRefreshStep) end
    return
  end

  local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
  if activeCat ~= "Raids" and activeCat ~= "Dungeons" then
    CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING = false
    return
  end

  local processed = 0
  local start = (GetTime and GetTime()) or 0
  local budget = 0.004

  for gidKey, queued in pairs(CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE) do
    if queued then
      CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE[gidKey] = nil
      gidKey = tostring(gidKey)
      local sg = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
      if sg and CLog_IsRaidDungeonGroup and CLog_IsRaidDungeonGroup(sg) then
        local ok, status = pcall(function()
          return CLOG_GetTrueCollectionStatusCached and CLOG_GetTrueCollectionStatusCached(sg) or nil
        end)
        if ok and type(status) == "table" then
          CLOG_StoreExactDifficultyStatus(sg, status)
        end

        local activeId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId or nil
        CLog_ApplyLeftListTextColor(gidKey, activeId and tostring(activeId) == gidKey)
        if CLOG_RepaintDifficultyIndicatorForGroup then CLOG_RepaintDifficultyIndicatorForGroup(gidKey) end
      end

      processed = processed + 1
      if processed >= 1 then break end
      if GetTime and ((GetTime() - start) > budget) then break end
    end
  end

  if CLOG_DifficultyRefreshHasWork() then
    if C_Timer and C_Timer.After then C_Timer.After(0.02, CLOG_ExactDifficultyRefreshStep) else CLOG_ExactDifficultyRefreshStep() end
  else
    CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING = false
  end
end

function CLOG_ScheduleExactSiblingDifficultyRefresh(groupId, reason)
  local gidKey = groupId and tostring(groupId) or nil
  if not gidKey or gidKey == "" then return end
  if not (C_Timer and C_Timer.After and ns and ns.Data and ns.Data.groups) then return end

  local g = ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1]
  if not (g and CLog_IsRaidDungeonGroup and CLog_IsRaidDungeonGroup(g)) then return end

  local bucketKey = CLOG_ExactDifficultyRefreshBucketKey(g)
  if bucketKey and CLOG_EXACT_DIFFICULTY_REFRESHED[bucketKey] then
    if CLOG_ScheduleDifficultyIndicatorRepaintForGroup then CLOG_ScheduleDifficultyIndicatorRepaintForGroup(gidKey) end
    return
  end
  if bucketKey then CLOG_EXACT_DIFFICULTY_REFRESHED[bucketKey] = true end

  local siblings = CLOG_GetDifficultySiblings and CLOG_GetDifficultySiblings(g) or nil
  if type(siblings) ~= "table" or #siblings == 0 then siblings = { g } end

  CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE = CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE or {}
  local seen = {}
  for i = 1, #siblings do
    local sg = siblings[i]
    if sg and sg.id then
      local didKey = tostring(sg.difficultyID or sg.id) .. ":" .. tostring(sg.mode or "")
      if not seen[didKey] then
        seen[didKey] = true
        local sid = tostring(sg.id)
        CLOG_EXACT_DIFFICULTY_REFRESH_QUEUE[sid] = true
      end
    end
  end

  if not CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING and CLOG_DifficultyRefreshHasWork() then
    CLOG_EXACT_DIFFICULTY_REFRESH_RUNNING = true
    C_Timer.After(0.03, CLOG_ExactDifficultyRefreshStep)
  end
end

function CLOG_BuildDifficultyIndicatorData(g)
  local cacheKey = g and g.id and tostring(g.id) or nil
  local rev = CLOG_GetDifficultyIndicatorRev()
  if cacheKey and type(CLOG_DIFFICULTY_INDICATOR_CACHE[cacheKey]) == "table" and CLOG_DIFFICULTY_INDICATOR_CACHE[cacheKey].rev == rev then
    local cached = CLOG_DIFFICULTY_INDICATOR_CACHE[cacheKey]
    return cached.text, cached.lines, cached.complete
  end

  local siblings = CLOG_GetDifficultySiblings(g)
  if not siblings or #siblings == 0 then
    if cacheKey then CLOG_DIFFICULTY_INDICATOR_CACHE[cacheKey] = { text = "", lines = nil, rev = rev, complete = true } end
    return "", nil, true
  end
  local parts, lines = {}, {}
  local complete = true
  for i = 1, #siblings do
    local sg = siblings[i]
    local status = CLOG_GetCachedDifficultyStatusOnly(sg)
    local code, r, gg, b, state
    if status then
      code, r, gg, b, state = CLOG_StatusColorCode(status)
    else
      -- No live lookup here.  Missing status means the difficulty has not been
      -- warmed/cached yet; keep it neutral until a real truth event or manual
      -- refresh fills the cache and invalidates this row's indicator.
      complete = false
      code, r, gg, b, state = "ff888888", 0.55, 0.55, 0.55, "Not cached"
      status = { collected = 0, total = 0 }
    end

    local label = CLOG_DifficultyLabel(sg.difficultyID, sg.mode)
    parts[#parts + 1] = "|c" .. code .. label .. "|r"
    lines[#lines + 1] = {
      label = CLOG_DifficultyFullName(sg.difficultyID, sg.mode),
      short = label,
      collected = tonumber(status and status.collected or 0) or 0,
      total = tonumber(status and status.total or 0) or 0,
      r = r, g = gg, b = b,
      state = state,
      active = (g and sg and tostring(g.id or "") == tostring(sg.id or "")) or false,
    }
  end
  local text = table.concat(parts, " ")
  if cacheKey then
    CLOG_DIFFICULTY_INDICATOR_CACHE[cacheKey] = { text = text, lines = lines, rev = rev, complete = complete }
  end
  return text, lines, complete
end

UI._clogDifficultyIndicatorQueue = UI._clogDifficultyIndicatorQueue or {}
UI._clogDifficultyIndicatorRunning = UI._clogDifficultyIndicatorRunning or false

function CLOG_DifficultyIndicatorQueueHasWork()
  if not UI._clogDifficultyIndicatorQueue then return false end
  for _, queued in pairs(UI._clogDifficultyIndicatorQueue) do
    if queued then return true end
  end
  return false
end

function CLOG_DifficultyIndicatorQueueStep()
  if not UI._clogDifficultyIndicatorRunning then return end
  if not UI._clogDifficultyIndicatorQueue then UI._clogDifficultyIndicatorRunning = false return end

  if InCombatLockdown and InCombatLockdown() then
    if C_Timer and C_Timer.After then C_Timer.After(0.75, CLOG_DifficultyIndicatorQueueStep) end
    return
  end

  local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
  if activeCat ~= "Raids" and activeCat ~= "Dungeons" then
    UI._clogDifficultyIndicatorRunning = false
    return
  end

  local start = (GetTime and GetTime()) or 0
  local budget = 0.003 -- keep this under a single-frame hitch threshold
  local processed = 0
  local batch = 2

  for gidKey, queued in pairs(UI._clogDifficultyIndicatorQueue) do
    if queued then
      UI._clogDifficultyIndicatorQueue[gidKey] = nil
      gidKey = tostring(gidKey)

      local g = ns and ns.Data and ns.Data.groups and (ns.Data.groups[gidKey] or ns.Data.groups[tonumber(gidKey) or -1])
      if g and (g.category == "Raids" or g.category == "Dungeons") then
        local text, lines
        local ok, a, b = pcall(function() return CLOG_BuildDifficultyIndicatorData(g) end)
        if ok then text, lines = a, b end

        local btn = UI._clogGroupBtnById and UI._clogGroupBtnById[gidKey] or nil
        if btn and tostring(btn.groupId or "") == gidKey then
          CLOG_SetDifficultyIndicatorButton(btn, g, text, lines)
        end
      end

      processed = processed + 1
      if processed >= batch then break end
      if GetTime and (GetTime() - start) > budget then break end
    end
  end

  if CLOG_DifficultyIndicatorQueueHasWork() then
    if C_Timer and C_Timer.After then C_Timer.After(0.03, CLOG_DifficultyIndicatorQueueStep) end
  else
    UI._clogDifficultyIndicatorRunning = false
  end
end

function UI.QueueDifficultyIndicatorBuild(groupIdList)
  if type(groupIdList) ~= "table" then return end
  if not C_Timer or not C_Timer.After then return end

  UI._clogDifficultyIndicatorQueue = UI._clogDifficultyIndicatorQueue or {}
  local rev = CLOG_GetDifficultyIndicatorRev and CLOG_GetDifficultyIndicatorRev() or 1
  for _, gid in ipairs(groupIdList) do
    local gidKey = gid and tostring(gid) or nil
    local cached = gidKey and CLOG_DIFFICULTY_INDICATOR_CACHE and CLOG_DIFFICULTY_INDICATOR_CACHE[gidKey] or nil
    if gidKey and gidKey ~= "" and not (type(cached) == "table" and cached.rev == rev) then
      UI._clogDifficultyIndicatorQueue[gidKey] = true
    end
  end

  if UI._clogDifficultyIndicatorRunning then return end
  if not CLOG_DifficultyIndicatorQueueHasWork() then return end
  UI._clogDifficultyIndicatorRunning = true
  -- Let the row list paint first; then fill the difficulty labels in tiny slices.
  C_Timer.After(0.05, CLOG_DifficultyIndicatorQueueStep)
end

local function CLOG_ShowDifficultyTooltip(owner)
  local lines = owner and owner._clogDifficultyTipLines
  if type(lines) ~= "table" or #lines == 0 then return false end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(owner._clogDifficultyTipTitle or "Difficulties", 1, 0.82, 0, true)
  for i = 1, #lines do
    local L = lines[i]
    local prefix = L.active and "> " or "  "
    local text = ("%s%s: %d/%d (%s)"):format(prefix, tostring(L.label or L.short or "?"), tonumber(L.collected or 0), tonumber(L.total or 0), tostring(L.state or ""))
    GameTooltip:AddLine(text, L.r or 1, L.g or 1, L.b or 1, true)
  end
  GameTooltip:Show()
  owner._clogDifficultyTooltipShown = true
  return true
end

local function BuildGroupList()
  local cat = CollectionLogDB.ui.activeCategory
  SetTabActive(cat)

  -- Left-list completion coloring is truth-locked by header computations.
  -- Do NOT background-scan or drive OnUpdate loops here (keeps first-open snappy and avoids addon conflicts).
  if UI._clogLeftColorDriver then
    UI._clogLeftColorDriver:SetScript("OnUpdate", nil)
  end

  if cat == "Overview" then
    if UI.ShowOverview then UI.ShowOverview(true) end
    if UI.ShowHistory then UI.ShowHistory(false) end
    return
  elseif cat == "History" then
    if UI.ShowOverview then UI.ShowOverview(false) end
    if UI.ShowHistory then UI.ShowHistory(true) end
    return
  else
    if UI.ShowOverview then UI.ShowOverview(false) end
    if UI.ShowHistory then UI.ShowHistory(false) end
  end


-- Toys: ensure the Blizzard-truthful Toys group exists so the Toys tab always has content
-- without requiring the user to open the Toy Box UI.
if cat == "Toys" and ns and ns.EnsureToysGroups then
  pcall(ns.EnsureToysGroups)
end
if cat == "Appearances" and ns and ns.EnsureAppearanceSetGroups then
  pcall(ns.EnsureAppearanceSetGroups)
end

  local list
  if cat == "Wishlist" then
    list = { { id = "wishlist:all", name = "All Wishlist", category = "Wishlist", expansion = "Account", sortIndex = 1 } }
  else
    list = ns.Data.groupsByCategory[cat] or {}
  end
  local content = UI.groupScrollContent

-- Reset groupId->button map for left-list coloring.
if UI._clogGroupBtnById then
  if type(wipe) == "function" then
    wipe(UI._clogGroupBtnById)
  else
    for k in pairs(UI._clogGroupBtnById) do UI._clogGroupBtnById[k] = nil end
  end
else
  UI._clogGroupBtnById = {}
end


  
-- Canonical expansion ordering (newest -> oldest) for header sorting.
-- We use this as the primary sort key so headers appear in release order even if some groups lack EJ sortTier.
local EXPANSION_ORDER = {
  ["Midnight"] = 1,
  ["The War Within"] = 2,
  ["Dragonflight"] = 3,
  ["Shadowlands"] = 4,
  ["Battle for Azeroth"] = 5,
  ["Legion"] = 6,
  ["Warlords of Draenor"] = 7,
  ["Mists of Pandaria"] = 8,
  ["Cataclysm"] = 9,
  ["Wrath of the Lich King"] = 10,
  ["The Burning Crusade"] = 11,
["Classic"] = 12,
  ["Vanilla"] = 12,
}

local function ExpansionRank(name)
  if not name or name == "" then return 999 end
  return EXPANSION_ORDER[name] or 999
end

  local function GetExp(g)
    local exp = (g and g.expansion and g.expansion ~= "" and g.expansion) or "Unknown"
    -- Canonicalize common aliasing so expansion headers never duplicate.
    if exp == "Burning Crusade" then exp = "The Burning Crusade" end
    if exp == "Vanilla" then exp = "Classic" end
    return exp
  end
  local function GetTier(g)
  -- Primary: canonical expansion rank (newest -> oldest)
  local expRank = ExpansionRank(GetExp(g))
  if expRank ~= 999 then
    return expRank
  end

  -- Fallback: EJ-derived sortTier if present
  local v = g and g.sortTier
  if type(v) == "number" then return v end

  return 999
end

  local function GetIdx(g)
    local v = g and g.sortIndex
    if type(v) == "number" then return v end
    return 999
  end

  -- Copy + sort for consistent chronological ordering
  EnsureUIState()

  -- Expansion filter (Encounter Panel dropdown)
  CollectionLogDB.ui.expansionFilterByCategory = CollectionLogDB.ui.expansionFilterByCategory or {}
  local expFilter = CollectionLogDB.ui.expansionFilterByCategory[cat] or "ALL"
  CollectionLogDB.ui.expansionFilterByCategory[cat] = expFilter

-- Toys is not meaningfully expansion-filtered (Toy Box spans all expansions).
-- Force ALL so the single "All Toys" group never disappears due to a leftover filter value.
if cat == "Toys" then
  expFilter = "ALL"
  CollectionLogDB.ui.expansionFilterByCategory[cat] = expFilter
end


  -- Canonicalize legacy filter values so old SavedVariables don't create duplicates.
  if expFilter == "Burning Crusade" then
    expFilter = "The Burning Crusade"
    CollectionLogDB.ui.expansionFilterByCategory[cat] = expFilter
  elseif expFilter == "Vanilla" then
    expFilter = "Classic"
    CollectionLogDB.ui.expansionFilterByCategory[cat] = expFilter
  end


  -- ============================================================
  if cat == "Mounts" or cat == "Pets" then
    list = CLOG_BuildJournalSidebarGroups(cat, list)
  end

  -- Mounts sidebar cleanup (deterministic, pack-gated)
  -- ============================================================
  -- We may have overlapping group generators (source-type groups vs
  -- data-pack tag groups; derived drop breakdowns vs curated drop groups).
  --
  -- This pass is intentionally:
  --   * deterministic (no heuristics/inference)
  --   * safe (only affects Mounts category)
  --   * pack-gated (only prefers tag groups when MountTags pack is non-empty)
  --
  -- It does NOT alter collected state, snapshots, or any truth-layer data.
  local suppress = {}
  if cat == "Mounts" and type(list) == "table" then
    -- Detect whether MountTags pack is present + non-empty.
    local hasMountTags = false
    local mt = ns.GetMountTagsPack and ns.GetMountTagsPack() or nil
    if mt and type(mt.mountTags) == "table" then
      for _ in pairs(mt.mountTags) do
        hasMountTags = true
        break
      end
    end

    -- Detect whether a curated plural Drops system exists.
    local hasPluralDrops = false
    local hasTagPromotion, hasTagStore, hasTagTradingPost = false, false, false
    for i = 1, #list do
      local g = list[i]
      local id = g and g.id and tostring(g.id) or ""
      if id:find("^mounts:drops:") then hasPluralDrops = true end
      if id == "mounts:tag:promotion" then hasTagPromotion = true end
      if id == "mounts:tag:store" then hasTagStore = true end
      if id == "mounts:tag:trading_post" then hasTagTradingPost = true end
    end

    -- 1) Always suppress derived breakdown helpers.
    -- Also suppress helper groups not part of the canonical Mounts sidebar.
    suppress["mounts:drop:unclassified"] = true
    suppress["mounts:drops:unclassified"] = true
    suppress["mounts:source:unknown"] = true
    for i = 1, #list do
      local g = list[i]
      local id = g and g.id and tostring(g.id) or ""
      if id ~= "" and id:find(":derived", 1, true) then
        suppress[id] = true
      end
    end

    -- 2) If curated plural drops exist, hide legacy/singular drops and the
    -- Blizzard-native source-type "Drop" bucket to avoid duplicates/confusion.
    if hasPluralDrops then
  suppress["mounts:source:raid"] = true
  suppress["mounts:source:dungeon"] = true
  suppress["mounts:source:delve"] = true

      for i = 1, #list do
        local g = list[i]
        local id = g and g.id and tostring(g.id) or ""
        if id:find("^mounts:drop:") or id == "mounts:source:drop" then
          suppress[id] = true
        end
      end
    end

      -- Also suppress redundant source-type buckets when curated Drops exist
      -- to prevent duplicates like "Raid" vs "Drops (Raid)".
      suppress["mounts:source:raid"] = true
      suppress["mounts:source:dungeon"] = true
      suppress["mounts:source:delve"] = true

    -- 3) If MountTags are present, prefer tag groups over overlapping
    -- source-type groups only when the corresponding tag group exists.
    if hasMountTags then
      if hasTagPromotion then suppress["mounts:source:promotion"] = true end
      if hasTagStore then suppress["mounts:source:store"] = true end
      if hasTagTradingPost then suppress["mounts:source:trading_post"] = true end
      suppress["mounts:source:world_event"] = true -- curated tags override noisy sourceType bucket
    end
  end

  local function IsSuppressed(g)
    if not g or not g.id then return false end
    local id = tostring(g.id)
    return suppress[id] == true
  end

  -- Build dropdown options based on groups present in this category
  local expSet, expList = {}, {}
  for i = 1, #list do
    local g = list[i]
    if g and g.id and not CollectionLogDB.ui.hiddenGroups[g.id] and not IsSuppressed(g) then
      local exp = GetExp(g)
      if not expSet[exp] then
        expSet[exp] = true
        table.insert(expList, exp)
      end
    end
  end
  table.sort(expList, function(a, b)
    local ra, rb = ExpansionRank(a), ExpansionRank(b)
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)

  if UI.expansionDropdown then
    -- Mounts/Pets/Toys/Housing are account-wide and do not participate in expansion filtering.
    if cat == "Mounts" or cat == "Pets" or cat == "Toys" or cat == "Housing" or cat == "Appearances" or cat == "Wishlist" then
      CollectionLogDB.ui.expansionFilterByCategory = CollectionLogDB.ui.expansionFilterByCategory or {}
      CollectionLogDB.ui.expansionFilterByCategory[cat] = "ALL"
      expFilter = "ALL"

      UI.expansionDropdown:Hide()

      -- Pull the left list up since the dropdown is hidden.
      if UI.groupScroll and UI.listPanel then
        UI.groupScroll:ClearAllPoints()
        UI.groupScroll:SetPoint("TOPLEFT", UI.listPanel, "TOPLEFT", 4, -10)
        UI.groupScroll:SetPoint("BOTTOMRIGHT", UI.listPanel, "BOTTOMRIGHT", -28, 6)
      end
    else
      UI.expansionDropdown:Show()

      if UI.groupScroll and UI.listPanel then
        UI.groupScroll:ClearAllPoints()
        UI.groupScroll:SetPoint("TOPLEFT", UI.listPanel, "TOPLEFT", 4, -30)
        UI.groupScroll:SetPoint("BOTTOMRIGHT", UI.listPanel, "BOTTOMRIGHT", -28, 6)
      end

      UIDropDownMenu_Initialize(UI.expansionDropdown, function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = "All Expansions"
        info.value = "ALL"
        info.checked = (expFilter == "ALL")
        info.func = function()
          CollectionLogDB.ui.expansionFilterByCategory = CollectionLogDB.ui.expansionFilterByCategory or {}
          CollectionLogDB.ui.expansionFilterByCategory[cat] = "ALL"
          BuildGroupList()
          UI.RefreshGrid()
        end
        UIDropDownMenu_AddButton(info, level)

        for _, exp in ipairs(expList) do
          local i2 = UIDropDownMenu_CreateInfo()
          i2.text = exp
          i2.value = exp
          i2.checked = (expFilter == exp)
          i2.func = function()
            CollectionLogDB.ui.expansionFilterByCategory = CollectionLogDB.ui.expansionFilterByCategory or {}
            CollectionLogDB.ui.expansionFilterByCategory[cat] = exp
            BuildGroupList()
            UI.RefreshGrid()
          end
          UIDropDownMenu_AddButton(i2, level)
        end
      end)

      UIDropDownMenu_SetText(UI.expansionDropdown, (expFilter == "ALL") and "All Expansions" or expFilter)
    end
  end

  -- Filter visible groups first
  local visible = {}
  for i = 1, #list do
    local g = list[i]
    if g and g.id and not CollectionLogDB.ui.hiddenGroups[g.id] and not IsSuppressed(g) then
      local exp = GetExp(g)
      if (expFilter == "ALL" or exp == expFilter) and CL_GroupHasVisibleCollectibles(g) then
        table.insert(visible, g)
      end
    end
  end

  -- De-dupe list rows: one row per instance (instanceID), pick preferred difficulty
  local byKey = {}
  for _, g in ipairs(visible) do
    local key = g.instanceID

    -- Some older/static rows may not have instanceID populated; derive from deterministic EJ id if possible.
    if (not key) and type(g.id) == "string" then
      local inst = g.id:match("^ej:(%d+):")
      if inst then key = tonumber(inst) end
    end

    key = key or g.id

    byKey[key] = byKey[key] or {}
    table.insert(byKey[key], g)
  end

  local deduped = {}
  local activeId = CollectionLogDB.ui.activeGroupId
  for _, bucket in pairs(byKey) do
    local chosen = bucket[1]
    local choseActive = false

    -- If the currently active group belongs to this instance bucket, KEEP it.
    -- This is critical: we must not override it with "last used" / "highest" selection,
    -- otherwise switching difficulty can cause the list to jump away.
    if activeId then
      for _, gg in ipairs(bucket) do
        if gg and gg.id == activeId then
          chosen = gg
          choseActive = true
          break
        end
      end
    end

    local instanceID = chosen and chosen.instanceID

    -- Only apply remembered/highest selection when we did NOT explicitly choose the active group.
    if instanceID and not choseActive then
      -- Default to the highest available difficulty for this instance.
      -- Use the same ordering as the selector (tier first, then size).
      local bestOrder = nil
      for _, gg in ipairs(bucket) do
        local o = DifficultyDisplayOrder(gg.difficultyID, gg.mode)
        if (bestOrder == nil) or (o < bestOrder) then
          bestOrder = o
          chosen = gg
        end
      end
    end

    table.insert(deduped, chosen)
  end

  table.sort(deduped, function(a, b)
    local ta, tb = GetTier(a), GetTier(b)
    if ta ~= tb then return ta < tb end
    local ea, eb = GetExp(a), GetExp(b)
    if ea ~= eb then return ea < eb end
    local ia, ib = GetIdx(a), GetIdx(b)
    if ia ~= ib then return ia < ib end
    local na, nb = (a.name or a.id or ""), (b.name or b.id or "")
    return na < nb
  end)

  -- If we're switching tabs, force selection to the first visible entry after filtering/sorting.
  if CollectionLogDB.ui._forceDefaultGroup then
    CollectionLogDB.ui._forceDefaultGroup = nil
    CollectionLogDB.ui.activeGroupId = (deduped[1] and deduped[1].id) or nil
  end

  -- Ensure we have a valid active group (especially after filtering)
  local active = CollectionLogDB.ui.activeGroupId

  -- Map instanceID -> chosen row groupId (one row per instance)
  local present = {}
  local byInstance = {}
  for _, g in ipairs(deduped) do
    present[g.id] = true
    if g.instanceID then
      byInstance[g.instanceID] = g.id
    end
  end

  if active and not present[active] and ns.Data and ns.Data.groups and ns.Data.groups[active] then
    -- If the active selection is a sibling that isn't the displayed "chosen" row,
    -- keep the user on the SAME instance by snapping to that instance's chosen row.
    local inst = ns.Data.groups[active].instanceID
    local chosen = inst and byInstance[inst]
    if chosen then
      CollectionLogDB.ui.activeGroupId = chosen
      active = chosen
    end
  end

  if (not active) or (not present[active]) then
    CollectionLogDB.ui.activeGroupId = deduped[1] and deduped[1].id or nil
  end

  -- Build flattened display rows: optional header rows + group rows
  local rows = {}

  local function SortRowsByIndexAsc(list)
    table.sort(list, function(a, b)
      local ia, ib = GetIdx(a), GetIdx(b)
      if ia ~= ib then return ia < ib end
      return (a.name or a.id or "") < (b.name or b.id or "")
    end)
  end

  local function SortRowsByIndexDesc(list)
    table.sort(list, function(a, b)
      local ia, ib = GetIdx(a), GetIdx(b)
      if ia ~= ib then return ia > ib end
      return (a.name or a.id or "") < (b.name or b.id or "")
    end)
  end

  local function SortExpansionRowsNewestFirst(list)
    table.sort(list, function(a, b)
      local ra, rb = ExpansionRank(a and a.name), ExpansionRank(b and b.name)
      if ra ~= rb then return ra < rb end
      local ia, ib = GetIdx(a), GetIdx(b)
      if ia ~= ib then return ia < ib end
      return (a.name or a.id or "") < (b.name or b.id or "")
    end)
  end

  local function AppendSectionRows(title, groups)
    if not groups or #groups == 0 then return end
    rows[#rows+1] = { kind = "header", text = title }
    for _, g in ipairs(groups) do
      rows[#rows+1] = { kind = "group", group = g }
    end
  end

  if cat == "Housing" then
    -- Housing left list is split into:
    --   All Housing
    --   Sources (HomeBound-style categories)
    --   Expansions (expansion buckets)
    -- We intentionally do NOT auto-insert per-expansion headers here (prevents duplicate-looking rows).
    local sourceGroups, expansionGroups = {}, {}
    for _, g in ipairs(deduped) do
      local gid = g.id or ""
      local isAll = (gid == "housing:all")
      local isHB = gid:find("^housing:hb:") ~= nil
      local isHBExp = gid:find("^housing:hb:exp_") ~= nil
      local isExp = (gid:find("^housing:exp:") ~= nil) or isHBExp

      if isAll or (isHB and not isHBExp) then
        -- All Housing + HomeBound-style source categories
        sourceGroups[#sourceGroups+1] = g
      elseif isExp then
        -- Expansion buckets
        -- The Last Titan is intentionally hidden for now
        if (g.name or "") ~= "The Last Titan" then
          expansionGroups[#expansionGroups+1] = g
        end

      else
        -- Anything else (future housing groups) default into Source section
        sourceGroups[#sourceGroups+1] = g
      end
    end
    -- Ensure "All Housing" stays first, then the remaining source groups by sort rules.
    table.sort(sourceGroups, function(a, b)
      if a.id == "housing:all" then return true end
      if b.id == "housing:all" then return false end
      local ia, ib = GetIdx(a), GetIdx(b)
      if ia ~= ib then return ia < ib end
      return (a.name or a.id or "") < (b.name or b.id or "")
    end)

    -- Expansions: show newest first (Midnight -> ... -> Classic)
    SortRowsByIndexAsc(expansionGroups)
    -- Build rows
    for _, g in ipairs(sourceGroups) do
      rows[#rows+1] = { kind = "group", group = g }
    end

    -- Only show the Source header if we have at least one non-All group.
    local hasNonAll = false
    for _, g in ipairs(sourceGroups) do
      if g.id ~= "housing:all" then hasNonAll = true break end
    end
    if hasNonAll then
      -- Insert header just before the first HomeBound-style group (i.e., after All Housing)
      local out = {}
      local inserted = false
      for _, r in ipairs(rows) do
        if (not inserted) and r.kind == "group" and r.group and r.group.id ~= "housing:all" then
          out[#out+1] = { kind = "header", text = "Source" }
          inserted = true
        end
        out[#out+1] = r
      end
      rows = out
    end

    if #expansionGroups > 0 then
      rows[#rows+1] = { kind = "header", text = "Expansions" }
      for _, g in ipairs(expansionGroups) do
        rows[#rows+1] = { kind = "group", group = g }
      end
    end
  elseif cat == "Toys" then
    -- Toys left list is split into:
    --   All Toys
    --   Source (Toy Box source categories)
    --   Expansions (Toy Box expansion buckets)
    -- We render explicit section headers (no per-expansion auto headers).
    local allGroup = nil
    local sourceGroups, expansionGroups, otherGroups = {}, {}, {}
    for _, g in ipairs(deduped) do
      local gid = g.id or ""
      if gid == "toys:all" then
        allGroup = g
      elseif gid:find("^toys:source:") then
        sourceGroups[#sourceGroups+1] = g
      elseif gid:find("^toys:exp:") then
        expansionGroups[#expansionGroups+1] = g
      else
        otherGroups[#otherGroups+1] = g
      end
    end

    SortRowsByIndexAsc(sourceGroups)
    SortExpansionRowsNewestFirst(expansionGroups)

    if allGroup then
      rows[#rows+1] = { kind = "group", group = allGroup }
    end

    AppendSectionRows("Source", sourceGroups)
    AppendSectionRows("Expansions", expansionGroups)

    for _, g in ipairs(otherGroups) do
      rows[#rows+1] = { kind = "group", group = g }
    end

  elseif cat == "Mounts" then
    -- Mounts: prefer the dedicated MJE-style source/expansion sidebar model when present.
    local allGroup = nil
    local sourceGroups, expansionGroups, otherGroups = {}, {}, {}
    local hasMje = false
    for _, g in ipairs(deduped) do
      local gid = g.id or ""
      if gid:find("^mounts:mje:source:") or gid:find("^mounts:mje:exp:") then
        hasMje = true
        break
      end
    end
    for _, g in ipairs(deduped) do
      local gid = g.id or ""
      if gid == "mounts:all" then
        allGroup = g
      elseif gid:find("^mounts:mje:source:") then
        sourceGroups[#sourceGroups+1] = g
      elseif gid:find("^mounts:mje:exp:") then
        expansionGroups[#expansionGroups+1] = g
      elseif not hasMje and (gid:find("^mounts:source:") or gid:find("^mounts:drop:") or gid:find("^mounts:cat:") or gid:find("^mounts:canon:")) then
        sourceGroups[#sourceGroups+1] = g
      elseif not hasMje and gid:find("^mounts:exp:") then
        expansionGroups[#expansionGroups+1] = g
      elseif not (hasMje and (gid:find("^mounts:source:") or gid:find("^mounts:drop:") or gid:find("^mounts:cat:") or gid:find("^mounts:canon:") or gid:find("^mounts:exp:"))) then
        otherGroups[#otherGroups+1] = g
      end
    end

    SortRowsByIndexAsc(sourceGroups)
    SortExpansionRowsNewestFirst(expansionGroups)
    SortRowsByIndexAsc(otherGroups)

    if allGroup then
      rows[#rows+1] = { kind = "group", group = allGroup }
    end

    AppendSectionRows("Source", sourceGroups)
    AppendSectionRows("Expansions", expansionGroups)

    for _, g in ipairs(otherGroups) do
      rows[#rows+1] = { kind = "group", group = g }
    end

  elseif cat == "Pets" then
    -- Pets: follow Blizzard-style grouping concepts in the left list.
    -- Today this means: All Pets, Source buckets, Pet Types, then expansion buckets when present.
    local allGroup = nil
    local sourceGroups, typeGroups, expansionGroups, otherGroups = {}, {}, {}, {}
    for _, g in ipairs(deduped) do
      local gid = g.id or ""
      if gid == "pets:all" then
        allGroup = g
      elseif gid:find("^pets:source:") then
        sourceGroups[#sourceGroups+1] = g
      elseif gid:find("^pets:type:") then
        typeGroups[#typeGroups+1] = g
      elseif gid:find("^pets:exp:") then
        expansionGroups[#expansionGroups+1] = g
      else
        otherGroups[#otherGroups+1] = g
      end
    end

    SortRowsByIndexAsc(sourceGroups)
    SortRowsByIndexAsc(typeGroups)
    SortExpansionRowsNewestFirst(expansionGroups)
    SortRowsByIndexAsc(otherGroups)

    if allGroup then
      rows[#rows+1] = { kind = "group", group = allGroup }
    end

    AppendSectionRows("Source", sourceGroups)
    AppendSectionRows("Pet Types", typeGroups)
    AppendSectionRows("Expansions", expansionGroups)

    for _, g in ipairs(otherGroups) do
      rows[#rows+1] = { kind = "group", group = g }
    end

  elseif cat == "Appearances" then
    for _, g in ipairs(deduped) do
      rows[#rows+1] = { kind = "group", group = g }
    end

  else
    local lastExp = nil
    for _, g in ipairs(deduped) do
      local exp = GetExp(g)
      if expFilter == "ALL" and cat ~= "Toys" then
        if exp ~= lastExp then
          -- Pets/Mounts/Housing: hide the redundant top "Account" section header so the left list starts cleanly.
          if not ((cat == "Pets" or cat == "Mounts" or cat == "Housing") and exp == "Account") then
            rows[#rows+1] = { kind = "header", text = exp }
          end
          lastExp = exp
        end
      end
      rows[#rows+1] = { kind = "group", group = g }
    end
  end

  local rowH = 22
  local headerH = 18
  local pad = 2

  local totalH = 0
  for _, r in ipairs(rows) do
    totalH = totalH + ((r.kind == "header") and (headerH + pad) or (rowH + pad))
  end
  content:SetHeight(math.max(1, totalH))

  UI.groupRows = UI.groupRows or {}

  local function EnsureRow(i)
    local r = UI.groupRows[i]
    if r then return r end

    r = CreateFrame("Frame", nil, content)
    UI.groupRows[i] = r
    r:SetWidth(LIST_W - 34)

    -- Header visuals
    r.header = CreateFrame("Frame", nil, r)
    r.header:SetAllPoints(r)
    r.header.text = r.header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.header.text:SetPoint("LEFT", r.header, "LEFT", 6, 0)
    r.header.text:SetTextColor(1, 1, 1, 1)

    r.header.line = r.header:CreateTexture(nil, "ARTWORK")
    r.header.line:SetHeight(1)
    r.header.line:SetPoint("LEFT", r.header.text, "RIGHT", 8, 0)
    r.header.line:SetPoint("RIGHT", r.header, "RIGHT", -6, 0)
    r.header.line:SetColorTexture(1, 1, 1, 0.15)

    -- Group button visuals
    r.button = CreateFrame("Button", nil, r, "BackdropTemplate")
    r.button:SetAllPoints(r)
    CreateBorder(r.button)
    r.button.__clogBaseLevel = r.button:GetFrameLevel()
    r.button:SetBackdropColor(0.06, 0.06, 0.06, 0.90)
    r.button:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.45)

    -- Subtle sheen like the top tabs (adds 3D page feel)
    if not r.button.__clogSheen then
      local sheen = r.button:CreateTexture(nil, "ARTWORK")
      sheen:SetPoint("TOPLEFT", r.button, "TOPLEFT", 3, -3)
      sheen:SetPoint("TOPRIGHT", r.button, "TOPRIGHT", -3, -3)
      sheen:SetHeight(8)
      sheen:SetTexture("Interface/Tooltips/UI-Tooltip-Background")
      sheen:SetVertexColor(1, 1, 1, 0.08)
      r.button.__clogSheen = sheen
    end

    r.button.__clogBaseScale = 1.0

    r.button.text = r.button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
r.button.text:SetPoint("LEFT", r.button, "LEFT", 8, 0)

    -- Right-aligned difficulty indicators for raid/dungeon rows.  This stays
    -- separate from the row title so long names can truncate without pushing
    -- the difficulty labels out of alignment.
    r.button.diffText = r.button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.button.diffText:SetPoint("RIGHT", r.button, "RIGHT", -7, 0)
    r.button.diffText:SetJustifyH("RIGHT")
    r.button.diffText:SetText("")
    -- Do not enable mouse on the difficulty FontString: it creates a click
    -- deadzone over the right side of the row. The parent row button handles
    -- click + hover tooltip for the entire row, including the difficulty text.
    if r.button.diffText.EnableMouse then r.button.diffText:EnableMouse(false) end
    r.button.diffText:SetScript("OnEnter", nil)
    r.button.diffText:SetScript("OnLeave", nil)
    r.button.diffText:SetScript("OnMouseUp", nil)
    r.button.text:SetPoint("RIGHT", r.button.diffText, "LEFT", -7, 0)
    r.button.text:SetJustifyH("LEFT")
    r.button.text:SetWordWrap(false)

    -- Active selection visuals (filled highlight + left accent bar)
    if not r.button._clogActiveBG then
      local bg = r.button:CreateTexture(nil, "BACKGROUND")
      bg:SetColorTexture(1, 0.86, 0.08, 0.10) -- subtle inner glow
      bg:SetBlendMode("ADD")
      bg:ClearAllPoints()
      bg:SetPoint("TOPLEFT", r.button, "TOPLEFT", 1, -1)
      bg:SetPoint("BOTTOMRIGHT", r.button, "BOTTOMRIGHT", -1, 1)
      bg:Hide()
      r.button._clogActiveBG = bg
    end

    -- Hover glow (inactive rows only) completions: same family as active, but ~50% intensity.
    if not r.button._clogHoverBG then
      local hbg = r.button:CreateTexture(nil, "BACKGROUND")
      hbg:SetColorTexture(1, 0.86, 0.08, 0.05)
      hbg:SetBlendMode("ADD")
      hbg:ClearAllPoints()
      hbg:SetPoint("TOPLEFT", r.button, "TOPLEFT", 1, -1)
      hbg:SetPoint("BOTTOMRIGHT", r.button, "BOTTOMRIGHT", -1, 1)
      hbg:Hide()
      r.button._clogHoverBG = hbg
    end
    if not r.button._clogAccent then
      local ac = r.button:CreateTexture(nil, "ARTWORK")
      ac:SetColorTexture(1, 0.86, 0.08, 0.95)
      ac:SetWidth(3)
      ac:SetPoint("TOPLEFT", r.button, "TOPLEFT", 0, -2)
      ac:SetPoint("BOTTOMLEFT", r.button, "BOTTOMLEFT", 0, 2)
      ac:Hide()
      r.button._clogAccent = ac
    end


r.button:EnableMouse(true)
r.button:RegisterForClicks("AnyUp")

-- Hover glow for inactive rows (do not compete with active selection)
r.button:HookScript("OnEnter", function(self)
  if not self._clogIsActive then
    if self._clogHoverBG then self._clogHoverBG:Show() end
    -- subtle border lift on hover
    self:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 0.55)
    if self.__clogSheen then self.__clogSheen:SetVertexColor(1, 1, 1, 0.12) end
  end
  CLOG_ShowDifficultyTooltip(self)
end)

r.button:HookScript("OnLeave", function(self)
  if self._clogDifficultyTooltipShown then
    GameTooltip:Hide()
    self._clogDifficultyTooltipShown = nil
  end
  if self._clogHoverBG then self._clogHoverBG:Hide() end
  if self._clogIsActive then return end
  self:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.45)
  if self.__clogSheen then self.__clogSheen:SetVertexColor(1, 1, 1, 0.06) end
end)

r.button:SetScript("OnMouseUp", function(self, btn)
  -- WoW sometimes reports right click as "RightButton" or "Button2"
  if btn ~= "LeftButton" then
    if not self.groupId then return end
    EnsureUIState()
    StaticPopup_Show("COLLECTIONLOG_DELETE_GROUP", nil, nil, { groupId = self.groupId })
    return
  end

  if not self.groupId then return end
  local previousGroupId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId or nil
  CollectionLogDB.ui.activeGroupId = self.groupId
  UI.RefreshGrid()
  if UI.UpdateActiveGroupVisuals then
    UI.UpdateActiveGroupVisuals(previousGroupId, self.groupId)
  else
    BuildGroupList()
  end
  -- v4.3.87: no active sibling refresh on row click. Difficulty labels
  -- consume fresh cache only; stale/missing sibling entries stay neutral until
  -- manual Refresh or real collection invalidation populates them.
  if UI.ScheduleEncounterAutoRefresh then UI.ScheduleEncounterAutoRefresh() end
end)


    return r
  end

  local displayedIds
  if cat == "Dungeons" or cat == "Raids" then
    displayedIds = {}
  end

  local y = 0
  for i, rr in ipairs(rows) do
    local row = EnsureRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)

    if rr.kind == "header" then
      row:SetHeight(headerH)
      row.header:Show()
      row.button:Hide()
      row.header.text:SetText(rr.text or "Unknown")
    else
      local g = rr.group
      row:SetHeight(rowH)
      row.header:Hide()
      row.button:Show()
      row.button.groupId = g and g.id or nil
      row.button.text:SetText(g and (g.name or g.id) or "?")

      if row.button.diffText then
        if g and (cat == "Raids" or cat == "Dungeons") then
          -- Do not let difficulty indicators generate collection truth during
          -- a tab click.  Build from existing cache only: static sibling metadata
          -- + already-known row completion.  Missing entries stay neutral until
          -- manual refresh/real collection events fill the cache.
          local diffText, diffLines = CLOG_GetDifficultyIndicatorCached(g)
          if diffText == nil and CLOG_BuildDifficultyIndicatorData then
            diffText, diffLines = CLOG_BuildDifficultyIndicatorData(g)
          end
          CLOG_SetDifficultyIndicatorButton(row.button, g, diffText or "", diffLines)
        elseif g and CLOG_IsCategoryCountGroup and CLOG_IsCategoryCountGroup(g) then
          row.button.diffText:SetText("")
          row.button.diffText:Show()
          row.button._clogDifficultyTipLines = nil
          row.button._clogDifficultyTipTitle = nil
        else
          row.button.diffText:SetText("")
          row.button.diffText:Hide()
          row.button._clogDifficultyTipLines = nil
          row.button._clogDifficultyTipTitle = nil
        end
      end

      if displayedIds and g and g.id then
        table.insert(displayedIds, g.id)
      end

            CLog_RefreshVisibleGroupButtonState(row.button, cat)
            if g and CLOG_IsCategoryCountGroup and CLOG_IsCategoryCountGroup(g) then
              CLOG_ApplyCategoryRowCountVisual(row.button, g)
            end

    end

    row:Show()
    y = y + row:GetHeight() + pad
  end

  -- Hide unused rows
  for i = #rows + 1, #UI.groupRows do
    UI.groupRows[i]:Hide()
  end

  -- CPU discipline: normal Raids/Dungeons tab clicks are cache-only.
  -- Do not auto-warm every visible sidebar row here; that turns simple tab
  -- switching into repeated live collection resolver work.  The Refresh button
  -- is the explicit cache-fill path, while the selected grid caches the active
  -- row as users naturally open instances.
  if displayedIds and #displayedIds > 0 and UI.QueueLeftListPrecompute then
    local autoWarm = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.autoWarmRaidDungeonSidebar == true
    if autoWarm then UI.QueueLeftListPrecompute(displayedIds) end
  end
  -- Difficulty indicators are built inline from cache only. Do not start a
  -- background queue from normal tab/list painting.
end

-- =====================
-- Grid cells


-- =====================
-- Manual Mount grouping overrides (MJE-style Source + Expansion)
-- Shift + Right Click a mount icon to correct sidebar categorization.
-- This ONLY affects display grouping (SavedVariables); it never changes Blizzard truth.
-- =====================
local MJE_MOUNT_OVERRIDE_SOURCES = {
  "Drop",
  "Quest",
  "Vendor",
  "Profession",
  "Instance",
  "Reputation",
  "Achievement",
  "Covenants",
  "Island Expedition",
  "Garrison",
  "PvP",
  "Class",
  "World Event",
  "Trading Post",
  "Shop",
  "Promotion",
  "Other",
}

local MJE_MOUNT_OVERRIDE_EXPANSIONS = {
  "Midnight",
  "The War Within",
  "Dragonflight",
  "Shadowlands",
  "Battle for Azeroth",
  "Legion",
  "Warlords of Draenor",
  "Mists of Pandaria",
  "Cataclysm",
  "Wrath of the Lich King",
  "The Burning Crusade",
  "Classic",
}

local function EnsureMountOverrideState()
  EnsureUIState()
  CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
  local uo = CollectionLogDB.userOverrides
  uo.mounts = uo.mounts or {}
  uo.mounts.primary = uo.mounts.primary or {}
  uo.mounts.extra = uo.mounts.extra or {}
  uo.mounts.sourcePrimary = uo.mounts.sourcePrimary or {}
  uo.mounts.expansionPrimary = uo.mounts.expansionPrimary or {}
  return uo.mounts
end

local function RefreshMountsAfterOverride()
  if ns and ns.EnsureMountsGroups then pcall(ns.EnsureMountsGroups) end
  if ns and ns.RebuildGroupIndex then pcall(ns.RebuildGroupIndex) end
  UI.RefreshGrid()
  BuildGroupList()
end

local function GetMountSourcePrimary(mountID)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return nil end
  local v = st.sourcePrimary[mountID]
  if type(v) == "string" and v ~= "" then return v end
  local legacy = st.primary[mountID]
  if type(legacy) == "string" and legacy ~= "" then
    for _, name in ipairs(MJE_MOUNT_OVERRIDE_SOURCES) do
      if legacy == name then return legacy end
    end
  end
  return nil
end

local function SetMountSourcePrimary(mountID, cat)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return end
  if type(cat) ~= "string" or cat == "" then return end
  st.sourcePrimary[mountID] = cat
  RefreshMountsAfterOverride()
end

local function GetMountExpansionPrimary(mountID)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return nil end
  local v = st.expansionPrimary[mountID]
  if type(v) == "string" and v ~= "" then return v end
  local legacy = st.primary[mountID]
  if type(legacy) == "string" and legacy ~= "" then
    for _, name in ipairs(MJE_MOUNT_OVERRIDE_EXPANSIONS) do
      if legacy == name then return legacy end
    end
  end
  return nil
end

local function SetMountExpansionPrimary(mountID, exp)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return end
  if type(exp) ~= "string" or exp == "" then return end
  st.expansionPrimary[mountID] = exp
  RefreshMountsAfterOverride()
end

local function ResetMountOverride(mountID)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return end
  st.primary[mountID] = nil
  st.extra[mountID] = nil
  st.sourcePrimary[mountID] = nil
  st.expansionPrimary[mountID] = nil
  RefreshMountsAfterOverride()
end

-- Context menu implementation for Mount manual grouping overrides.
-- Prefer modern Menu API (10.0+), fallback to UIDropDownMenu (if available).

local function EnsureMenuAPIs()
  -- Modern context menu (Dragonflight+)
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    if C_AddOns and C_AddOns.LoadAddOn then
      pcall(C_AddOns.LoadAddOn, "Blizzard_Menu")
    elseif UIParentLoadAddOn then
      pcall(UIParentLoadAddOn, "Blizzard_Menu")
    end
  end

  -- Deprecated dropdown menu fallback (if MenuUtil isn't available)
  if not EasyMenu then
    if C_AddOns and C_AddOns.LoadAddOn then
      pcall(C_AddOns.LoadAddOn, "Blizzard_Deprecated")
    elseif UIParentLoadAddOn then
      pcall(UIParentLoadAddOn, "Blizzard_Deprecated")
    end
  end

  return (MenuUtil and MenuUtil.CreateContextMenu) or EasyMenu
end

local function ShowWishlistMenu(anchorFrame, cell)
  if not cell then return end
  anchorFrame = anchorFrame or cell or UIParent
  local key, payload = Wishlist.BuildPayloadFromCell(cell)
  if not key or not payload then return end
  EnsureMenuAPIs()
  local isWishlisted = Wishlist.ContainsKey(key)

  local function applyAndRefresh(add)
    if add then
      Wishlist.AddFromCell(cell)
    else
      Wishlist.RemoveFromCell(cell)
    end
    if UI and UI.RefreshGrid then UI.RefreshGrid() end
  end

  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchorFrame, function(owner, root)
      root:CreateTitle("Wishlist")
      if isWishlisted then
        root:CreateButton("Remove from Wishlist", function() applyAndRefresh(false) end)
      else
        root:CreateButton("Add to Wishlist", function() applyAndRefresh(true) end)
      end
    end)
    return
  end

  if EasyMenu and CreateFrame then
    local menu = {
      { text = "Wishlist", isTitle = true, notCheckable = true },
      { text = isWishlisted and "Remove from Wishlist" or "Add to Wishlist", notCheckable = true, func = function() applyAndRefresh(not isWishlisted) end },
    }
    local dd = _G.CollectionLogWishlistDropDown
    if not dd then
      dd = CreateFrame("Frame", "CollectionLogWishlistDropDown", (UI and UI.frame) or UIParent, "UIDropDownMenuTemplate")
    end
    EasyMenu(menu, dd, "cursor", 0, 0, "MENU", true)
  end
end

local function ShowMountOverrideMenu(anchorFrame, mountID)
  mountID = tonumber(mountID)
  if not mountID then return end
  anchorFrame = anchorFrame or UIParent

  -- Modern (Dragonflight+) completions: MenuUtil.CreateContextMenu
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchorFrame, function(owner, root)
      root:CreateTitle("Mount Grouping Overrides")

      local source = root:CreateButton("Move to Source")
      for _, cat in ipairs(MJE_MOUNT_OVERRIDE_SOURCES) do
        source:CreateRadio(cat,
          function() return GetMountSourcePrimary(mountID) == cat end,
          function() SetMountSourcePrimary(mountID, cat) end
        )
      end

      local exp = root:CreateButton("Move to Expansion")
      for _, name in ipairs(MJE_MOUNT_OVERRIDE_EXPANSIONS) do
        exp:CreateRadio(name,
          function() return GetMountExpansionPrimary(mountID) == name end,
          function() SetMountExpansionPrimary(mountID, name) end
        )
      end

      root:CreateDivider()
      root:CreateButton("Clear Manual Override", function() ResetMountOverride(mountID) end)
    end)
    return
  end

  -- Legacy fallback: try to ensure UIDropDownMenu exists
  if UIParentLoadAddOn then
    pcall(UIParentLoadAddOn, "Blizzard_Deprecated")
  end

  local menu = {
    { text = "Mount Grouping Overrides", isTitle = true, notCheckable = true },
    {
      text = "Move to Source",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(MJE_MOUNT_OVERRIDE_SOURCES) do
          table.insert(sub, {
            text = cat,
            checked = function() return GetMountSourcePrimary(mountID) == cat end,
            func = function() SetMountSourcePrimary(mountID, cat) end,
          })
        end
        return sub
      end)(),
    },
    {
      text = "Move to Expansion",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, name in ipairs(MJE_MOUNT_OVERRIDE_EXPANSIONS) do
          table.insert(sub, {
            text = name,
            checked = function() return GetMountExpansionPrimary(mountID) == name end,
            func = function() SetMountExpansionPrimary(mountID, name) end,
          })
        end
        return sub
      end)(),
    },
    { text = "Clear Manual Override", notCheckable = true, func = function() ResetMountOverride(mountID) end },
  }

  if EasyMenu and CreateFrame then
    local dd = _G.CollectionLogMountOverrideDropDown
    if not dd then
      dd = CreateFrame("Frame", "CollectionLogMountOverrideDropDown", (UI and UI.frame) or UIParent, "UIDropDownMenuTemplate")
    end
    EasyMenu(menu, dd, "cursor", 0, 0, "MENU", true)
  end
end

-- =====================
-- Manual Pet grouping overrides (Primary Source + Extra Source tags)
-- Shift + Right Click a pet icon to set Primary Source group / extra Source tags.
-- This ONLY affects display grouping (SavedVariables); it never changes Blizzard truth.
-- =====================

local function EnsurePetOverrides()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
  local uo = CollectionLogDB.userOverrides
  uo.pets = uo.pets or {}
  uo.pets.primary = uo.pets.primary or {}
  uo.pets.extra = uo.pets.extra or {}
  return uo.pets
end

local function NormalizeKeyFromName(name)
  if type(name) ~= "string" then return nil end
  local key = name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  key = key:gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if key == "" then return nil end
  return key
end

local function GetPetPrimary(speciesID)
  local uo = EnsurePetOverrides()
  return uo.primary[tostring(speciesID)]
end

local function SetPetPrimary(speciesID, name)
  local uo = EnsurePetOverrides()
  uo.primary[tostring(speciesID)] = name
  if ns and ns.EnsurePetsGroups then ns.EnsurePetsGroups() end
  UI.RefreshGrid()
  BuildGroupList()
end

local function HasPetExtra(speciesID, name)
  local uo = EnsurePetOverrides()
  local t = uo.extra[tostring(speciesID)]
  return t and t[name] == true
end

local function TogglePetExtra(speciesID, name)
  local uo = EnsurePetOverrides()
  local k = tostring(speciesID)
  uo.extra[k] = uo.extra[k] or {}
  local t = uo.extra[k]
  if t[name] then t[name] = nil else t[name] = true end
  if ns and ns.EnsurePetsGroups then ns.EnsurePetsGroups() end
  UI.RefreshGrid()
  BuildGroupList()
end

local function ResetPetOverride(speciesID)
  local uo = EnsurePetOverrides()
  local k = tostring(speciesID)
  uo.primary[k] = nil
  uo.extra[k] = nil
  if ns and ns.EnsurePetsGroups then ns.EnsurePetsGroups() end
  UI.RefreshGrid()
  BuildGroupList()
end

local function GetPetOverrideSourceCategories()
  -- Build from current group list so it stays in sync with generated Source groups.
  local cats = {}
  local seen = {}
  if ns and ns.Data and ns.Data.groups then
    for _, g in pairs(ns.Data.groups) do
      if g and g.category == "Pets" and g.expansion == "Source" and g.name then
        if not seen[g.name] then
          seen[g.name] = true
          table.insert(cats, g.name)
        end
      end
    end
  end
  -- Ensure "Uncategorized" exists and is selectable.
  if not seen["Uncategorized"] then
    table.insert(cats, "Uncategorized")
  end
  table.sort(cats)
  return cats
end

local function ShowPetOverrideMenu(anchor, speciesID)
  local categories = GetPetOverrideSourceCategories()

  EnsureMenuAPIs()

  -- Prefer modern context menu API (Dragonflight+), fallback to old dropdown.
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(owner, rootDescription)
      rootDescription:SetTag("COLLECTIONLOG_PET_OVERRIDE")
      local root = rootDescription

      -- Primary
      local primary = root:CreateButton("Set Primary Source")
      for _, cat in ipairs(categories) do
        primary:CreateRadio(cat, function() return GetPetPrimary(speciesID) == cat end, function()
          SetPetPrimary(speciesID, cat)
        end)
      end

      -- Extra
      local extra = root:CreateButton("Also Show In")
      for _, cat in ipairs(categories) do
        extra:CreateCheckbox(cat, function() return HasPetExtra(speciesID, cat) end, function()
          TogglePetExtra(speciesID, cat)
        end)
      end

      root:CreateDivider()
      root:CreateButton("Reset to Default", function() ResetPetOverride(speciesID) end)
    end)
    return
  end

  -- Fallback old menu (if available)
  if not (EasyMenu and CreateFrame) then
    if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: no menu API available (pet override)') end
    return
  end

  local menu = {
    {
      text = "Set Primary Source",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(categories) do
          table.insert(sub, {
            text = cat,
            checked = function() return GetPetPrimary(speciesID) == cat end,
            func = function() SetPetPrimary(speciesID, cat) end,
          })
        end
        return sub
      end)(),
    },
    {
      text = "Also Show In",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(categories) do
          table.insert(sub, {
            text = cat,
            keepShownOnClick = true,
            isNotRadio = true,
            checked = function() return HasPetExtra(speciesID, cat) end,
            func = function() TogglePetExtra(speciesID, cat) end,
          })
        end
        return sub
      end)(),
    },
    { text = "Reset to Default", notCheckable = true, func = function() ResetPetOverride(speciesID) end },
  }

  local dd = _G.CollectionLogPetOverrideDropDown
  if not dd then
    dd = CreateFrame("Frame", "CollectionLogPetOverrideDropDown", (UI and UI.frame) or UIParent, "UIDropDownMenuTemplate")
  end
  EasyMenu(menu, dd, "cursor", 0, 0, "MENU", true)
end


-- =====================
-- Manual Toy grouping overrides (Primary Source + Extra Source tags)
-- Shift + Right Click a toy icon to set Primary Source group / extra Source tags.
-- This ONLY affects display grouping (SavedVariables); it never changes Blizzard truth.
-- =====================

local function EnsureToyOverrides()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
  local uo = CollectionLogDB.userOverrides
  uo.toys = uo.toys or {}
  uo.toys.primary = uo.toys.primary or {}
  uo.toys.extra = uo.toys.extra or {}
  return uo.toys
end

local function GetToyPrimary(itemID)
  local uo = EnsureToyOverrides()
  return uo.primary[tostring(itemID)]
end

local function SetToyPrimary(itemID, name)
  local uo = EnsureToyOverrides()
  uo.primary[tostring(itemID)] = name
  if ns and ns.EnsureToysGroups then pcall(ns.EnsureToysGroups) end
  UI.RefreshGrid()
  BuildGroupList()
end

local function HasToyExtra(itemID, name)
  local uo = EnsureToyOverrides()
  local t = uo.extra[tostring(itemID)]
  return t and t[name] == true
end

local function ToggleToyExtra(itemID, name)
  local uo = EnsureToyOverrides()
  local k = tostring(itemID)
  uo.extra[k] = uo.extra[k] or {}
  local t = uo.extra[k]
  if t[name] then t[name] = nil else t[name] = true end
  if ns and ns.EnsureToysGroups then pcall(ns.EnsureToysGroups) end
  UI.RefreshGrid()
  BuildGroupList()
end

local function ResetToyOverride(itemID)
  local uo = EnsureToyOverrides()
  local k = tostring(itemID)
  uo.primary[k] = nil
  uo.extra[k] = nil
  if ns and ns.EnsureToysGroups then pcall(ns.EnsureToysGroups) end
  UI.RefreshGrid()
  BuildGroupList()
end

local function GetToyOverrideSourceCategories()
  local cats = {}
  local seen = {}
  if ns and ns.Data and ns.Data.groups then
    for _, g in pairs(ns.Data.groups) do
      if g and g.category == "Toys" and g.id and type(g.id) == "string" and g.id:match("^toys:source:") and g.name then
        if not seen[g.name] then
          seen[g.name] = true
          table.insert(cats, g.name)
        end
      end
    end
  end
  if not seen["Uncategorized"] then table.insert(cats, "Uncategorized") end
  table.sort(cats)
  return cats
end

local function ShowToyOverrideMenu(anchor, itemID)
  itemID = tonumber(itemID)
  if not itemID then return end
  local categories = GetToyOverrideSourceCategories()

  EnsureMenuAPIs()

  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(owner, root)
      root:SetTag("COLLECTIONLOG_TOY_OVERRIDE")
      root:CreateTitle("Toy Grouping")

      local primary = root:CreateButton("Set Primary Source")
      for _, cat in ipairs(categories) do
        primary:CreateRadio(cat, function() return GetToyPrimary(itemID) == cat end, function()
          SetToyPrimary(itemID, cat)
        end)
      end

      local extra = root:CreateButton("Also Show In")
      for _, cat in ipairs(categories) do
        extra:CreateCheckbox(cat, function() return HasToyExtra(itemID, cat) end, function()
          ToggleToyExtra(itemID, cat)
        end)
      end

      root:CreateDivider()
      root:CreateButton("Reset to Default", function() ResetToyOverride(itemID) end)
    end)
    return
  end

  if not (EasyMenu and CreateFrame) then
    if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: no menu API available (toy override)') end
    return
  end

  local menu = {
    { text = "Toy Grouping", isTitle = true, notCheckable = true },
    {
      text = "Set Primary Source",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(categories) do
          table.insert(sub, {
            text = cat,
            checked = function() return GetToyPrimary(itemID) == cat end,
            func = function() SetToyPrimary(itemID, cat) end,
          })
        end
        return sub
      end)(),
    },
    {
      text = "Also Show In",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(categories) do
          table.insert(sub, {
            text = cat,
            keepShownOnClick = true,
            isNotRadio = true,
            checked = function() return HasToyExtra(itemID, cat) end,
            func = function() ToggleToyExtra(itemID, cat) end,
          })
        end
        return sub
      end)(),
    },
    { text = "Reset to Default", notCheckable = true, func = function() ResetToyOverride(itemID) end },
  }

  local dd = _G.CollectionLogToyOverrideDropDown
  if not dd then
    dd = CreateFrame("Frame", "CollectionLogToyOverrideDropDown", (UI and UI.frame) or UIParent, "UIDropDownMenuTemplate")
  end
  EasyMenu(menu, dd, "cursor", 0, 0, "MENU", true)
end

-- =====================
-- Manual Housing grouping overrides (Primary Source + Extra Source tags)
-- Shift + Right Click a housing decor icon to set Primary Source group / extra tags.
-- =====================

local function EnsureHousingOverrides()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
  local uo = CollectionLogDB.userOverrides
  uo.housing = uo.housing or {}
  uo.housing.primary = uo.housing.primary or {}
  uo.housing.extra = uo.housing.extra or {}
  return uo.housing
end

local function GetHousingPrimary(itemID)
  local uo = EnsureHousingOverrides()
  return uo.primary[tostring(itemID)]
end

local function SetHousingPrimary(itemID, name)
  local uo = EnsureHousingOverrides()
  uo.primary[tostring(itemID)] = name
  UI.RefreshGrid()
  BuildGroupList()
end

local function HasHousingExtra(itemID, name)
  local uo = EnsureHousingOverrides()
  local t = uo.extra[tostring(itemID)]
  return t and t[name] == true
end

local function ToggleHousingExtra(itemID, name)
  local uo = EnsureHousingOverrides()
  local k = tostring(itemID)
  uo.extra[k] = uo.extra[k] or {}
  local t = uo.extra[k]
  if t[name] then t[name] = nil else t[name] = true end
  UI.RefreshGrid()
  BuildGroupList()
end

local function ResetHousingOverride(itemID)
  local uo = EnsureHousingOverrides()
  local k = tostring(itemID)
  uo.primary[k] = nil
  uo.extra[k] = nil
  UI.RefreshGrid()
  BuildGroupList()
end

local function GetHousingOverrideSourceCategories()
  local cats = {}
  local seen = {}
  if ns and ns.Data and ns.Data.groups then
    for _, g in pairs(ns.Data.groups) do
      if g and g.category == "Housing" and g.expansion == "Source" and g.name then
        if not seen[g.name] then
          seen[g.name] = true
          table.insert(cats, g.name)
        end
      end
    end
  end
  if not seen["Uncategorized"] then table.insert(cats, "Uncategorized") end
  table.sort(cats)
  return cats
end

local function ShowHousingOverrideMenu(anchor, itemID)
  itemID = tonumber(itemID)
  if not itemID then return end
  local categories = GetHousingOverrideSourceCategories()

  EnsureMenuAPIs()

  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(owner, root)
      root:SetTag("COLLECTIONLOG_HOUSING_OVERRIDE")
      root:CreateTitle("Housing Grouping")

      local primary = root:CreateButton("Set Primary Source")
      for _, cat in ipairs(categories) do
        primary:CreateRadio(cat, function() return GetHousingPrimary(itemID) == cat end, function()
          SetHousingPrimary(itemID, cat)
        end)
      end

      local extra = root:CreateButton("Also Show In")
      for _, cat in ipairs(categories) do
        extra:CreateCheckbox(cat, function() return HasHousingExtra(itemID, cat) end, function()
          ToggleHousingExtra(itemID, cat)
        end)
      end

      root:CreateDivider()
      root:CreateButton("Reset to Default", function() ResetHousingOverride(itemID) end)
    end)
    return
  end

  if not (EasyMenu and CreateFrame) then
    if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: no menu API available (housing override)') end
    return
  end

  local menu = {
    { text = "Housing Grouping", isTitle = true, notCheckable = true },
    {
      text = "Set Primary Source",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(categories) do
          table.insert(sub, {
            text = cat,
            checked = function() return GetHousingPrimary(itemID) == cat end,
            func = function() SetHousingPrimary(itemID, cat) end,
          })
        end
        return sub
      end)(),
    },
    {
      text = "Also Show In",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(categories) do
          table.insert(sub, {
            text = cat,
            keepShownOnClick = true,
            isNotRadio = true,
            checked = function() return HasHousingExtra(itemID, cat) end,
            func = function() ToggleHousingExtra(itemID, cat) end,
          })
        end
        return sub
      end)(),
    },
    { text = "Reset to Default", notCheckable = true, func = function() ResetHousingOverride(itemID) end },
  }

  local dd = _G.CollectionLogHousingOverrideDropDown
  if not dd then
    dd = CreateFrame("Frame", "CollectionLogHousingOverrideDropDown", (UI and UI.frame) or UIParent, "UIDropDownMenuTemplate")
  end
  EasyMenu(menu, dd, "cursor", 0, 0, "MENU", true)
end

-- =====================
-- =====================


-- ============================================================
-- Raid/Dungeon tooltip analysis caches
-- ============================================================
-- Hover tooltips are intentionally feature-rich: difficulty variant coloring,
-- exact-source appearance notes, and boss/source text are user-facing behavior.
-- The performance rule is: do that analysis once per item/group/cache generation,
-- then let hover read the cached answer instead of re-walking Blizzard APIs every
-- time the mouse crosses an icon.
function UI.ClearTooltipAnalysisCaches(reason)
  if UI._clogTooltipTruthCache then
    if wipe then wipe(UI._clogTooltipTruthCache) else for k in pairs(UI._clogTooltipTruthCache) do UI._clogTooltipTruthCache[k] = nil end end
  end
  if UI._clogTooltipModeCache then
    if wipe then wipe(UI._clogTooltipModeCache) else for k in pairs(UI._clogTooltipModeCache) do UI._clogTooltipModeCache[k] = nil end end
  end
  if UI._clogTooltipVariantLinkCache then
    if wipe then wipe(UI._clogTooltipVariantLinkCache) else for k in pairs(UI._clogTooltipVariantLinkCache) do UI._clogTooltipVariantLinkCache[k] = nil end end
  end
  if UI._clogTrueCollectedCellCache then
    if wipe then wipe(UI._clogTrueCollectedCellCache) else for k in pairs(UI._clogTrueCollectedCellCache) do UI._clogTrueCollectedCellCache[k] = nil end end
  end
end

local function CLOG_GameTooltipSaysAppearanceUncollected()
  if not (GameTooltip and GameTooltip.NumLines) then return false end
  local n = GameTooltip:NumLines() or 0
  for i = 1, n do
    local fs = _G and _G["GameTooltipTextLeft" .. tostring(i)] or nil
    local text = fs and fs.GetText and fs:GetText() or nil
    if type(text) == "string" then
      local lower = string.lower(text)
      if string.find(lower, "haven't collected this appearance", 1, true)
        or string.find(lower, "have not collected this appearance", 1, true) then
        return true
      end
    end
  end
  return false
end

function UI.GetRaidDungeonTooltipTruthState(itemID, groupId)
  itemID = tonumber(itemID)
  if not (itemID and itemID > 0 and groupId and ns and ns.TrueCollection and ns.TrueCollection.IsItemCollected) then return nil end
  UI._clogTooltipTruthCache = UI._clogTooltipTruthCache or {}
  local gen = tonumber(UI._clogCollectedStateGen or 0) or 0
  local modeKey = (ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode()) or (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode) or "shared"
  local key = tostring(groupId) .. ":" .. tostring(itemID) .. ":" .. tostring(gen) .. ":" .. tostring(modeKey)
  local cached = UI._clogTooltipTruthCache[key]
  if cached ~= nil then return cached end

  local result = { ok = false }
  local okTrue, trueKnown, trueDef = pcall(ns.TrueCollection.IsItemCollected, itemID, groupId)
  result.ok = okTrue and true or false
  if okTrue and trueKnown ~= nil then
    result.known = trueKnown and true or false
    if type(trueDef) == "table" and tostring(trueDef.type or ""):lower() == "appearance" then
      if ns and ns.Truth and ns.Truth.GetAppearanceCollectionState then
        local okState, state = pcall(ns.Truth.GetAppearanceCollectionState, trueDef)
        if okState and type(state) == "table" and state.note then
          result.note = state.note
          result.noteKind = state.sameItemOtherDifficultyOwned and "sameItemOtherDifficulty" or (state.sharedAppearanceOwned and "sharedAppearance" or "appearanceNote")
          result.exactSourceOwned = state.exactSourceOwned and true or false
          result.appearanceOwned = state.collected and true or false
          result.ownedViaAnotherSource = true
        end
      end
    end
  end

  UI._clogTooltipTruthCache[key] = result
  return result
end

function UI.GetRaidDungeonTooltipModeAnalysis(cell, group, itemID, isCollected)
  itemID = tonumber(itemID)
  if not (cell and group and itemID and itemID > 0 and group.instanceID) then return nil end

  UI._clogTooltipModeCache = UI._clogTooltipModeCache or {}

  local gen = tonumber(UI._clogCollectedStateGen or 0) or 0
  local mode = (ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode()) or (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode) or "shared"
  local gkey = tostring(group.id or group.instanceID or "?") .. ":" .. tostring(itemID) .. ":" .. tostring(gen) .. ":" .. tostring(mode)
  local cached = UI._clogTooltipModeCache[gkey]
  if cached ~= nil then return cached end

  local result = {
    modeText = nil,
    modeKnown = 0,
    modeGreen = 0,
    collectedLineColor = isCollected and "|cff00ff00" or "|cffff5555",
  }

  local okMode = pcall(function()
    local siblings = GetSiblingGroups(group.instanceID, group.category)
    local key = GetCollectibleKey(itemID, group)

    local ctx = { multiSize = { H = false, N = false } }
    do
      local sizesH, sizesN = {}, {}
      for _, sg in ipairs(siblings) do
        local tier, size = GetDifficultyMeta(sg.difficultyID, sg.mode)
        if tier == "H" then sizesH[size or 0] = true end
        if tier == "N" then sizesN[size or 0] = true end
      end
      local function CountKeys(t)
        local c = 0
        for _ in pairs(t) do c = c + 1 end
        return c
      end
      ctx.multiSize.H = CountKeys(sizesH) > 1
      ctx.multiSize.N = CountKeys(sizesN) > 1
    end

    local seen = {}
    local parts = {}

    local function GetLinkCandidates(linkOrTable)
      if type(linkOrTable) == "table" then
        local out = {}
        for _, L in ipairs(linkOrTable) do if type(L) == "string" and L ~= "" then out[#out + 1] = L end end
        for _, L in pairs(linkOrTable) do if type(L) == "string" and L ~= "" then out[#out + 1] = L end end
        return out
      end
      if type(linkOrTable) == "string" and linkOrTable ~= "" then return { linkOrTable } end
      return {}
    end

    local function ModifiedAppearanceOwned(sourceID)
      sourceID = tonumber(sourceID)
      if not (sourceID and sourceID > 0 and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance) then return nil end
      local ok, owned = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
      if ok and owned ~= nil then return owned and true or false end
      return nil
    end

    local function AppearanceCollected(appearanceID)
      appearanceID = tonumber(appearanceID)
      if not (appearanceID and appearanceID > 0 and C_TransmogCollection) then return nil end
      if C_TransmogCollection.GetAppearanceInfoByID then
        local ok, a, b, c, isCollected = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
        if ok then
          if type(a) == "table" and a.isCollected ~= nil then return a.isCollected and true or false end
          if isCollected ~= nil then return isCollected and true or false end
        end
      end
      if C_TransmogCollection.PlayerHasTransmogItemAppearance then
        local ok, owned = pcall(C_TransmogCollection.PlayerHasTransmogItemAppearance, appearanceID)
        if ok and owned ~= nil then return owned and true or false end
      end
      return nil
    end

    local function ResolveVariantCollected(sg, matchID)
      -- Use the same group-aware truth state as the grid/header so tooltip mode
      -- letters reflect exact difficulty ownership rather than broad appearance
      -- family ownership.
      if ns and ns.Truth and ns.Truth.GetItemCollectionState then
        local ok, state = pcall(ns.Truth.GetItemCollectionState, matchID, sg)
        if ok and type(state) == "table" and state.countsAsCollected ~= nil then
          return state.countsAsCollected and true or false, true
        end
      end
      return false, false
    end

    local function ColorizeLabel(label, tier, sg, matchID)
      if tier == "M" or tier == "H" or tier == "N" or tier == "LFR" then
        local has, known = ResolveVariantCollected(sg, matchID)
        if known then
          result.modeKnown = result.modeKnown + 1
          if has then result.modeGreen = result.modeGreen + 1 end
          return (has and "|cff00ff00" or "|cffff5555") .. label .. "|r"
        end
        return "|cffaaaaaa" .. label .. "|r"
      end
      return label
    end

    local function AddTier(tier)
      for _, sg in ipairs(siblings) do
        local stier = GetDifficultyMeta(sg.difficultyID, sg.mode)
        if stier == tier then
          local matchID = FindMatchingItemID(sg, key)
          if matchID then
            local label = DifficultyShortLabel(sg.difficultyID, sg.mode, ctx)
            if label and not seen[label] then
              seen[label] = true
              parts[#parts + 1] = ColorizeLabel(label, tier, sg, matchID)
            end
          end
        end
      end
    end

    AddTier("M"); AddTier("H"); AddTier("N"); AddTier("LFR"); AddTier("TW")
    if #parts > 0 then result.modeText = table.concat(parts, " / ") end

    if isCollected and result.modeKnown > 0 then
      if result.modeGreen == result.modeKnown then
        result.collectedLineColor = "|cff00ff00"
      elseif result.modeGreen > 0 then
        result.collectedLineColor = "|cffffff00"
      else
        result.collectedLineColor = "|cffff5555"
      end
    end
  end)

  if not okMode then result.modeText = nil end
  UI._clogTooltipModeCache[gkey] = result
  return result
end

local function EnsureCells(count)
  local grid = UI.grid
  if UI.maxCells >= count then return end

  for i = UI.maxCells + 1, count do
    local cell = CreateFrame("Button", nil, grid, "BackdropTemplate")
    UI.cells[i] = cell
    cell:EnableMouse(true)
    cell:RegisterForClicks("AnyUp")
    cell:SetSize(ICON, ICON)
    CreateBorder(cell)
    cell:SetBackdropColor(0.03, 0.03, 0.03, 0.95)
    cell:SetBackdropBorderColor(0.24, 0.24, 0.24, 0.30)

    local icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon = icon
    icon:SetAllPoints(cell)

    local countText = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    cell.countText = countText
    countText:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -2, 2)
    countText:SetText("")

cell:SetScript("OnEnter", function(self)
  UI._clogLastHoveredGridCell = self
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  local activeCat = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory) or nil

  self:SetScript("OnUpdate", nil)


  -- Pet entry (speciesID)
  -- IMPORTANT: Only use the dedicated Pet tooltip on the Pets tab.
  -- Raid/Dungeon loot cells should keep their original item-based tooltip.
  if self.petSpeciesID and activeCat == "Pets" then
    if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
      local ok, name, icon, petType, creatureID, sourceText = pcall(C_PetJournal.GetPetInfoBySpeciesID, self.petSpeciesID)
      do
      local itemID = self.itemID or CL_GetPetItemID(self.petSpeciesID)
      local rr,gg,bb = CL_GetQualityColor(itemID)
      if rr then
        GameTooltip:SetText((ok and name) or ("Pet " .. tostring(self.petSpeciesID)), rr, gg, bb)
      else
        GameTooltip:SetText((ok and name) or ("Pet " .. tostring(self.petSpeciesID)))
      end
    end

      local collected = false
      if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
        local ok2, numCollected = pcall(C_PetJournal.GetNumCollectedInfo, self.petSpeciesID)
        collected = (ok2 and type(numCollected) == "number" and numCollected > 0) or false
      end

      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)
      GameTooltip:AddLine(("Collected: %s"):format(collected and "|cff00ff00Yes|r" or "|cffff5555No|r"), 0.9, 0.9, 0.9)

      if ok and type(sourceText) == "string" and sourceText ~= "" then
        GameTooltip:AddLine(sourceText, 0.85, 0.85, 0.85, true)
      end

      local groupId = CollectionLogDB.ui.activeGroupId
      local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId]
      if g and g.name then
        GameTooltip:AddLine(("Source: %s"):format(g.name), 0.85, 0.85, 0.85, true)
      end

      if ok and petType and type(petType) == "number" then
        GameTooltip:AddLine(("Pet Type: %s"):format(GetPetTypeName(petType)), 0.85, 0.85, 0.85)
      end
    else
      do
      local itemID = self.itemID or CL_GetPetItemID(self.petSpeciesID)
      local rr,gg,bb = CL_GetQualityColor(itemID)
      if rr then
        GameTooltip:SetText(("Pet %d"):format(self.petSpeciesID), rr, gg, bb)
      else
        GameTooltip:SetText(("Pet %d"):format(self.petSpeciesID))
      end
    end
      GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)
    end

    GameTooltip:Show()
    return
  end

-- Mount entry
-- IMPORTANT: Only use the dedicated Mount tooltip on the Mounts tab.
-- Raid/Dungeon loot cells should keep their original item-based tooltip.
if self.mountID and activeCat == "Mounts" then
  if C_MountJournal and C_MountJournal.GetMountInfoByID then
    local name, spellID, icon, isActive, isUsable, sourceType, isFavorite, isFactionSpecific, faction, hideOnChar, isCollected =
      C_MountJournal.GetMountInfoByID(self.mountID)

    do
      local itemID = self.itemID or CL_GetMountItemID(self.mountID)
      local rr,gg,bb = CL_GetQualityColor(itemID)
      if rr then
        GameTooltip:SetText(name or ("Mount " .. tostring(self.mountID)), rr, gg, bb)
      else
        GameTooltip:SetText(name or ("Mount " .. tostring(self.mountID)))
      end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)

    -- Collected
    GameTooltip:AddLine("Collected: " .. (isCollected and "|cff00ff00Yes|r" or "|cffff5555No|r"), 0.9, 0.9, 0.9)
    -- Blizzard extra text (authoritative): displayID, descriptionText, sourceText
    local descriptionText, sourceText
    if C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
      local _displayID
      _displayID, descriptionText, sourceText = C_MountJournal.GetMountInfoExtraByID(self.mountID)
    end

    -- Details: prefer Blizzard "how to get" (sourceText); fallback to descriptionText
    local detailsText = (sourceText and sourceText ~= "" and sourceText) or (descriptionText and descriptionText ~= "" and descriptionText) or nil
    if detailsText then
      local seen = {}
      local wroteAny = false
      for rawLine in detailsText:gmatch("[^\r\n]+") do
        local line = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
        -- Skip empty lines and exact duplicates (Blizzard sometimes repeats vendor blocks)
        if line ~= "" and not seen[line] then
          seen[line] = true
          GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
          wroteAny = true
        end
      end
      if wroteAny then
        GameTooltip:AddLine(" ")
      end
    end

    -- Expansion (not exposed directly via Blizzard mount API)
    local expansionName = "Unknown"
    if ns and ns.GetExpansionNameForMountID then
      local exp = ns.GetExpansionNameForMountID(self.mountID)
      if exp and exp ~= "" then
        expansionName = exp
      end
    end

    -- Mount ID (Mount Journal mountID)
    GameTooltip:AddLine(("Mount ID: %s"):format(tostring(self.mountID)), 0.85, 0.85, 0.85)

    -- Force left justification for all tooltip font strings (prevents odd right alignment)
    local regions = { GameTooltip:GetRegions() }
    for i = 1, #regions do
      local r = regions[i]
      if r and r.GetObjectType and r:GetObjectType() == "FontString" then
        r:SetJustifyH("LEFT")
      end
    end
  else
    GameTooltip:SetText(("Mount %d"):format(self.mountID))
    GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)

    -- Housing tooltip: keep ALL Collection Log info under this section (no duplicates)
    if activeCat == "Housing" then
      GameTooltip:AddLine(("Collected: %s"):format(isCollected and "|cff00ff00Yes|r" or "|cffff5555No|r"), 0.9, 0.9, 0.9)

      local groupId = CollectionLogDB.ui.activeGroupId
      local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId]
      if g and g.name then
        GameTooltip:AddLine(("Source: %s"):format(g.name), 0.85, 0.85, 0.85, true)
      end

      local hMeta = (ns and ns.HousingItemMeta and ns.HousingItemMeta[self.itemID]) or nil
      if hMeta then
        
        -- Normalize reward source (some mappings use questIDs under "achievement")
        local st, sid = hMeta.sourceType, hMeta.sourceID
        if ns and ns.GetHousingRewardSource then
          local nst, nsid = ns.GetHousingRewardSource(hMeta)
          if nst and nsid then
            st, sid = nst, nsid
          end
        end

if st == "achievement" and sid then
          local function ResolveAchievementName(achievementID)
            -- Prefer modern table-based API: stable across client builds
            local function CleanName(v)
              if type(v) ~= "string" then return nil end
              local s = v
              -- strip WoW color codes
              s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
              s = s:gsub("^%s+", ""):gsub("%s+$", "")
              if s == "" then return nil end
              if s == tostring(achievementID) then return nil end
              if s:match("^%d+$") then return nil end
              return s
            end

                        if C_AchievementInfo and C_AchievementInfo.GetAchievementInfo then
              local info = C_AchievementInfo.GetAchievementInfo(achievementID)
              if info then
                local n = CleanName(info.name) or CleanName(info.title)
                if n then return n end
              end
            end

            -- Fallback: legacy/global API (return order varies; name is commonly 2nd)
            if GetAchievementInfo then
              local ok, r1, r2, r3, r4 = pcall(GetAchievementInfo, achievementID)
              if ok then
                -- Prefer the commonly-correct "name" position first, then scan others.
                local n = CleanName(r2) or CleanName(r1) or CleanName(r3) or CleanName(r4)
                if n then return n end
              end
            end

            return nil
          end

          local aName = ResolveAchievementName(sid)
          if aName then
            GameTooltip:AddLine(("Achievement: %s (%d)"):format(aName, sid), 0.85, 0.85, 0.85, true)
          else
            -- If the client hasn't cached achievement info yet, avoid showing the ID twice.
            GameTooltip:AddLine(("Achievement: %d"):format(sid), 0.85, 0.85, 0.85, true)
          end
        elseif st == "quest" and sid then
          local qTitle = (C_QuestLog and C_QuestLog.GetTitleForQuestID) and C_QuestLog.GetTitleForQuestID(sid) or nil
          if qTitle and qTitle ~= "" then
            GameTooltip:AddLine(("Quest: %s (%d)"):format(qTitle, sid), 0.85, 0.85, 0.85, true)
          else
            GameTooltip:AddLine(("Quest: %d"):format(sid), 0.85, 0.85, 0.85, true)
          end
        end

        if hMeta.expansion and ns and ns.HousingExpansionNames and ns.HousingExpansionNames[hMeta.expansion] then
          GameTooltip:AddLine(("Expansion: %s"):format(ns.HousingExpansionNames[hMeta.expansion]), 0.85, 0.85, 0.85, true)
        end
      end

      
      local function CL_AddKV(label, value)
        if value == nil then return end
        if type(value) == "string" then
          local t = value:gsub("^%s+", ""):gsub("%s+$", "")
          if t == "" then return end
          GameTooltip:AddLine(("%s: %s"):format(label, t), 0.85, 0.85, 0.85, true)
          return
        end
        if type(value) == "number" then
          GameTooltip:AddLine(("%s: %s"):format(label, tostring(value)), 0.85, 0.85, 0.85, true)
          return
        end
        if type(value) == "boolean" then
          GameTooltip:AddLine(("%s: %s"):format(label, value and "Yes" or "No"), 0.85, 0.85, 0.85, true)
          return
        end
      end

      -- Housing extra tooltip fields (omit if missing)
      do
        local t = ns and ns.HousingTypeByItemID and ns.HousingTypeByItemID[self.itemID] or nil
        CL_AddKV("Type", t)
        local u = ns and ns.HousingUsableByItemID and ns.HousingUsableByItemID[self.itemID] or nil
        CL_AddKV("Usable", u)
        local s = ns and ns.HousingSizeByItemID and ns.HousingSizeByItemID[self.itemID] or nil
        CL_AddKV("Size", s)
      end

-- Housing Catalog (Blizzard-native)
      do
        local rid = ns and ns.GetHousingDecorRecordID and ns.GetHousingDecorRecordID(self.itemID) or nil
        if rid and C_HousingCatalog and type(C_HousingCatalog.GetCatalogEntryInfoByRecordID) == "function" then
          local ok, info = pcall(C_HousingCatalog.GetCatalogEntryInfoByRecordID, 1, rid, true)
          if ok and type(info) == "table" then
            if info.sourceText and info.sourceText ~= "" then
              GameTooltip:AddLine(info.sourceText, 0.85, 0.85, 0.85, true)
            end
            local cnt = tonumber(info.destroyableInstanceCount or 0) or 0
            GameTooltip:AddLine(("Owned: %d"):format(cnt), 0.85, 0.85, 0.85, true)
            if type(info.dataTagsByID) == "table" then
              -- Housing catalog tags can include "Midnight" broadly (feature tag). Prefer explicit expansion tags when present.
              local candidates = {}
              local function isExpTag(tag)
                return tag == "Midnight" or tag == "The War Within" or tag == "Dragonflight" or tag == "Shadowlands"
                  or tag == "Battle for Azeroth" or tag == "Legion" or tag == "Warlords of Draenor" or tag == "Mists of Pandaria"
                  or tag == "Cataclysm" or tag == "Wrath of the Lich King" or tag == "The Burning Crusade" or tag == "Classic" or tag == "Vanilla"
              end

              for _, tag in pairs(info.dataTagsByID) do
                if type(tag) == "string" and isExpTag(tag) then
                  candidates[tag] = true
                end
              end

              local count = 0
              for _ in pairs(candidates) do count = count + 1 end
              if count > 1 and candidates["Midnight"] then
                candidates["Midnight"] = nil
                count = count - 1
              end

              local tagExp
              for tag in pairs(candidates) do tagExp = tag break end

              -- Item-era fallback (best-effort)
              local eraExp
              do
                local expacID = select(15, GetItemInfo(self.itemID))
                local map = {
                  [0] = "Classic",
                  [1] = "The Burning Crusade",
                  [2] = "Wrath of the Lich King",
                  [3] = "Cataclysm",
                  [4] = "Mists of Pandaria",
                  [5] = "Warlords of Draenor",
                  [6] = "Legion",
                  [7] = "Battle for Azeroth",
                  [8] = "Shadowlands",
                  [9] = "Dragonflight",
                  [10] = "The War Within",
                  [11] = "Midnight",
                }
                if type(expacID) == "number" then
                  eraExp = map[expacID] or (expacID > 11 and "Midnight" or nil)
                end
              end

              local exp = tagExp
              if exp == "Midnight" and count == 1 and eraExp and eraExp ~= "Midnight" then
                exp = eraExp
              end
              if not exp then
                exp = eraExp
              end

              if exp then
                GameTooltip:AddLine(("Expansion: %s"):format(exp), 0.85, 0.85, 0.85, true)
                if tagExp and eraExp and tagExp ~= eraExp then
                  GameTooltip:AddLine(("ItemEra: %s"):format(eraExp), 0.65, 0.65, 0.65, true)
                end
              end
            end
          end
        end
      end

      -- Vendor Price (last)
      local sellPrice
      if GetItemInfo then
        local _n,_l,_q,_il,_rl,_c,_sc,_st,_el,_ic,_sp = GetItemInfo(self.itemID)
        sellPrice = _sp
      end
      if type(sellPrice) == "number" and sellPrice > 0 then
        local priceText
        if GetCoinTextureString then
          priceText = GetCoinTextureString(sellPrice)
        elseif GetMoneyString then
          priceText = GetMoneyString(sellPrice, true)
        else
          priceText = tostring(sellPrice)
        end
        GameTooltip:AddLine(("Vendor Price: %s"):format(priceText), 0.85, 0.85, 0.85, true)
      end

      GameTooltip:Show()
      return
    end

  end

  GameTooltip:Show()
  return
end


  local function CL_ModifiedAppearanceOwnedForTooltip(sourceID)
    sourceID = tonumber(sourceID)
    if not (sourceID and sourceID > 0 and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance) then return false end
    local ok, owned = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, sourceID)
    return ok and owned == true or false
  end

  local function CL_GetAppearanceAlternateTooltipNote(def)
    if type(def) ~= "table" or tostring(def.type or ""):lower() ~= "appearance" then return nil end
    if ns and ns.Truth and ns.Truth.GetAppearanceCollectionState then
      local ok, state = pcall(ns.Truth.GetAppearanceCollectionState, def)
      if ok and type(state) == "table" and state.note then
        return state.note, state
      end
    end
    return nil
  end

-- Item entry
  if not self.itemID then return end

  local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil

  if activeCat == "Toys" then
    -- Custom Toys tooltip (Blizzard-truth text extracted from the item tooltip)
    local name, _, quality = GetItemInfo(self.itemID)
    if name then
      local r, g, b = 1, 1, 1
      if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
        r, g, b = ITEM_QUALITY_COLORS[quality].r, ITEM_QUALITY_COLORS[quality].g, ITEM_QUALITY_COLORS[quality].b
      end
      GameTooltip:SetText(name, r, g, b)
    else
      GameTooltip:SetText(("Toy %d"):format(self.itemID))
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)

    local collected = (ns and ns.IsToyCollected and ns.IsToyCollected(self.itemID)) and true or false
    GameTooltip:AddLine(("Collected: %s"):format(collected and "|cff00ff00Yes|r" or "|cffff5555No|r"), 0.9, 0.9, 0.9)

    
local bodyLines = CL_ExtractToyTooltipBody(self.itemID)

    GameTooltip:AddLine(" ")
    if bodyLines and #bodyLines > 0 then
      for _, L in ipairs(bodyLines) do
        if not L or not L.text or L.text == "" then
          GameTooltip:AddLine(" ")
        else
          local r = (type(L.r) == "number") and L.r or 0.85
          local g = (type(L.g) == "number") and L.g or 0.85
          local b = (type(L.b) == "number") and L.b or 0.85
          GameTooltip:AddLine(L.text, r, g, b, true)
        end
      end
    end


    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Item ID: %d"):format(self.itemID), 0.85, 0.85, 0.85)
    GameTooltip:Show()
    return
  end

  -- Non-toy item entries: show the full Blizzard item tooltip.
  -- For raid/dungeon rows, prefer the difficulty-specific item link shipped in
  -- the datapack. SetItemByID(self.itemID) uses the base/normal source for
  -- many modern raid items, which makes Blizzard's own tooltip and our
  -- collected state disagree on Mythic/Heroic/LFR variants.
  local tooltipItemLink = nil
  do
    if self._clogTooltipItemLink then
      tooltipItemLink = self._clogTooltipItemLink
    end
  end
  do
    local gid = (self.groupId or (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId))
    local tg = gid and ns and ns.Data and ns.Data.groups and ns.Data.groups[gid] or nil
    if not tooltipItemLink then
      local links = tg and tg.itemLinks and (tg.itemLinks[self.itemID] or tg.itemLinks[tostring(self.itemID)]) or nil
      if type(links) == "string" and links ~= "" then
        tooltipItemLink = links
      elseif type(links) == "table" then
        for _, L in ipairs(links) do
          if type(L) == "string" and L ~= "" then tooltipItemLink = L; break end
        end
        if not tooltipItemLink then
          for _, L in pairs(links) do
            if type(L) == "string" and L ~= "" then tooltipItemLink = L; break end
          end
        end
      end
    end
  end
  if not tooltipItemLink then
    tooltipItemLink = CLOG_GetTooltipLinkFromTruthState(self._clogTruthState)
  end
  if tooltipItemLink and GameTooltip.SetHyperlink then
    GameTooltip:SetHyperlink(tooltipItemLink)
  else
    GameTooltip:SetItemByID(self.itemID)
  end

local viewMode = CollectionLogDB.ui.viewMode
      local guid = CollectionLogDB.ui.activeCharacterGUID
      local recCount = ns.GetRecordedCount(self.itemID, viewMode, guid) or 0

      local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
      local isCollected
      if activeCat == "Toys" then
        isCollected = (ns and ns.IsToyCollected and ns.IsToyCollected(self.itemID)) or false
      elseif activeCat == "Housing" then
        isCollected = (ns and ns.IsHousingCollected and ns.IsHousingCollected(self.itemID)) or false
      elseif UI.IsRaidDungeonGridContext() and UI.IsAppearanceLootSection(self.section) then
        -- Do not seed Raid/Dungeon appearance tooltips from ns.IsCollected();
        -- the difficulty-aware truth object below is the only allowed source.
        isCollected = false
      else
        isCollected = (ns.IsCollected and ns.IsCollected(self.itemID)) or false
      end

      local appearanceOwnership = nil
      if activeCat == "Appearances" and self.appearanceEntry and ns and ns.IsAppearanceSetPieceCollected then
        local okAppearance, owned = pcall(ns.IsAppearanceSetPieceCollected, self.appearanceEntry)
        appearanceOwnership = {
          isAppearanceItem = true,
          exactSourceOwned = owned and true or false,
          appearanceOwned = owned and true or false,
          ownedViaAnotherSource = false,
        }
        isCollected = owned and true or false
      elseif activeCat ~= "Toys" and activeCat ~= "Housing" and not (UI.IsRaidDungeonGridContext() and UI.IsAppearanceLootSection(self.section)) and ns and ns.GetAppearanceOwnershipState then
        local okAppearance, state = pcall(ns.GetAppearanceOwnershipState, self.itemID)
        if okAppearance and type(state) == "table" and state.isAppearanceItem then
          appearanceOwnership = state
        end
      end

      -- Raid/Dungeon tooltips should use the same difficulty-aware
      -- TrueCollection backend as the grid saturation/header. The legacy
      -- itemID-only path can report Normal as uncollected while the selected
      -- Mythic/Heroic/LFR source is collected.
      local activeCatForTooltip = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory
      if (viewMode == "raids" or viewMode == "dungeons" or activeCatForTooltip == "Raids" or activeCatForTooltip == "Dungeons") and self.itemID then
        local gid = self.groupId or (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId)
        local truth = self._clogTruthState or (UI.GetRaidDungeonTooltipTruthState and UI.GetRaidDungeonTooltipTruthState(self.itemID, gid) or nil)
        if truth and (truth.ok ~= false) and (truth.known ~= nil or truth.countsAsCollected ~= nil) then
          isCollected = (truth.countsAsCollected ~= nil and truth.countsAsCollected or truth.known) and true or false
          -- Teaching-item sections have a stable type-specific resolver. If the
          -- backend definition is incomplete for a recovered datapack mount/pet/toy,
          -- do not let that false negative overwrite Blizzard's journal truth.
          if not isCollected and self.section == "Mounts" and ns and ns.IsMountCollected and self.itemID then
            isCollected = ns.IsMountCollected(self.itemID) and true or false
          elseif not isCollected and self.section == "Pets" and ns and ns.IsPetCollected and self.itemID then
            isCollected = ns.IsPetCollected(self.itemID) and true or false
          elseif not isCollected and self.section == "Toys" and ns and ns.IsToyCollected and self.itemID then
            isCollected = ns.IsToyCollected(self.itemID) and true or false
          elseif not isCollected and self.section == "Housing" and ns and ns.IsHousingCollected and self.itemID then
            isCollected = ns.IsHousingCollected(self.itemID) and true or false
          end
          appearanceOwnership = nil

          -- Exact-source policy for raid/dungeon appearance cells: keep the old
          -- tooltip behavior, but read the cached analysis instead of running the
          -- TrueCollection/appearance note path every hover.
          if truth.note then
            appearanceOwnership = {
              isAppearanceItem = true,
              exactSourceOwned = truth.exactSourceOwned and true or false,
              appearanceOwned = truth.appearanceOwned or truth.countsAsCollected or (truth.known and true or false),
              ownedViaAnotherSource = true,
              note = truth.note,
              noteKind = truth.noteKind or (truth.sameItemOtherDifficultyOwned and "sameItemOtherDifficulty" or (truth.sharedAppearanceOwned and "sharedAppearance" or "appearanceNote")),
            }
          end
        end
      end

      -- Safety net: the Blizzard item tooltip for the exact item hyperlink is
      -- already on-screen at this point.  If Blizzard explicitly says this exact
      -- appearance has not been collected, never let Collection Log's cached or
      -- datapack-derived broad appearance state print a contradictory Yes/yellow
      -- owned-via-another-source line.  This is hover-only and does not run EJ or
      -- source discovery.
      if (activeCatForTooltip == "Raids" or activeCatForTooltip == "Dungeons" or viewMode == "raids" or viewMode == "dungeons")
        and CLOG_GameTooltipSaysAppearanceUncollected and CLOG_GameTooltipSaysAppearanceUncollected() then
        -- The Blizzard tooltip saying the exact appearance is uncollected should
        -- prevent a green exact-collection claim, but it should not suppress the
        -- useful yellow notes that explicitly describe non-exact ownership such
        -- as "Collected on another difficulty" or "Appearance owned via another
        -- source".  v4.3.87 cleared the note too, which made the smart tooltip
        -- look broken even when the backend had the right relationship.
        isCollected = false
      end

      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)

      if activeCat ~= "Housing" then
        if appearanceOwnership and appearanceOwnership.ownedViaAnotherSource then
          GameTooltip:AddLine(("Collected: |cffffff00%s|r"):format(tostring(appearanceOwnership.note or "Appearance collected via another source")), 0.9, 0.9, 0.9)
        else
          local collectedText = (isCollected and "|cff00ff00Yes|r" or "|cffff5555No|r")
          GameTooltip:AddLine(("Collected: %s"):format(collectedText), 0.9, 0.9, 0.9)
        end
      end

      if activeCat == "Appearances" and self.appearanceEntry then
        local entry = self.appearanceEntry
        local variantLabel = entry.variantLabel
        if type(variantLabel) == "string" and variantLabel ~= "" then
          GameTooltip:AddLine(("Difficulty: %s"):format(variantLabel), 0.85, 0.85, 0.85)
        end
        local itemID = tonumber(entry.itemID or self.itemID or 0) or 0
        local appearanceID = tonumber(entry.appearanceID or 0) or 0
        if itemID > 0 then
          GameTooltip:AddLine(("Item ID: %d"):format(itemID), 0.75, 0.75, 0.75)
        end
        if appearanceID > 0 then
          GameTooltip:AddLine(("Appearance ID: %d"):format(appearanceID), 0.75, 0.75, 0.75)
        end
      end

      local groupId = CollectionLogDB.ui.activeGroupId

      local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId]

	      -- Housing tooltips: keep all Collection Log info under the Collection Log header,
	      -- with a consistent order and no duplicates.
	      if activeCat == "Housing" then
	        -- Collected
	        local collected = isCollected
	        if ns and ns.IsHousingCollected then
	          local okH, resH = pcall(ns.IsHousingCollected, self.itemID)
	          if okH then collected = resH and true or false end
	        end
	        GameTooltip:AddLine(("Collected: %s"):format(collected and "|cff00ff00Yes|r" or "|cffff5555No|r"), 0.9, 0.9, 0.9)

	        -- Source (group name)
	        if g and g.name then
	          GameTooltip:AddLine(("Source: %s"):format(g.name), 0.85, 0.85, 0.85, true)
	        end

	        -- Housing metadata (achievement/quest + expansion)
	        local hMeta = (ns and ns.HousingItemMeta and ns.HousingItemMeta[self.itemID]) or nil
	        if hMeta then
	          
            -- Normalize reward source (some mappings use questIDs under "achievement")
            local st, sid = hMeta.sourceType, hMeta.sourceID
            if ns and ns.GetHousingRewardSource then
              local nst, nsid = ns.GetHousingRewardSource(hMeta)
              if nst and nsid then
                st, sid = nst, nsid
              end
            end

if st == "achievement" and sid then
	            local aName = nil
	            if C_AchievementInfo and C_AchievementInfo.GetAchievementInfo then
	              local info = C_AchievementInfo.GetAchievementInfo(hMeta.sourceID)
	              if info then aName = info.name or info.title end
	            end
	            if (not aName or aName == "") and GetAchievementInfo then
	              -- Legacy API fallback (name is commonly 2nd return)
	              local okA, r1, r2, r3, r4 = pcall(GetAchievementInfo, hMeta.sourceID)
	              if okA then aName = r2 or r1 or r3 or r4 end
	            end
	            if type(aName) == "string" then
	              aName = aName:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s+", ""):gsub("%s+$", "")
	              if aName == "" or aName:match("^%d+$") or aName == tostring(hMeta.sourceID) then aName = nil end
	            else
	              aName = nil
	            end
	            if aName then
	              GameTooltip:AddLine(("Achievement: %s (%d)"):format(aName, sid), 1, 0.82, 0, true)
	            else
	              GameTooltip:AddLine(("Achievement: %d"):format(sid), 1, 0.82, 0, true)
	            end
	          elseif st == "quest" and sid then
	            local qTitle = (C_QuestLog and C_QuestLog.GetTitleForQuestID) and C_QuestLog.GetTitleForQuestID(sid) or nil
	            if qTitle and qTitle ~= "" then
	              GameTooltip:AddLine(("Quest: %s (%d)"):format(qTitle, sid), 1, 0.82, 0, true)
	            else
	              GameTooltip:AddLine(("Quest: %d"):format(sid), 1, 0.82, 0, true)
	            end
	          end
	          if hMeta.expansion and ns and ns.HousingExpansionNames and ns.HousingExpansionNames[hMeta.expansion] then
	            GameTooltip:AddLine(("Expansion: %s"):format(ns.HousingExpansionNames[hMeta.expansion]), 0.85, 0.85, 0.85, true)
	          end
	        end

	        -- Vendor price (last)
	        local sellPrice
	        if GetItemInfo then
	          local _n,_l,_q,_il,_rl,_c,_sc,_st,_el,_ic,_sp = GetItemInfo(self.itemID)
	          sellPrice = _sp
	        end
	        if type(sellPrice) == "number" and sellPrice > 0 then
	          local priceText
	          if GetCoinTextureString then
	            priceText = GetCoinTextureString(sellPrice)
	          elseif GetMoneyString then
	            priceText = GetMoneyString(sellPrice, true)
	          else
	            priceText = tostring(sellPrice)
	          end
	          GameTooltip:AddLine(("Vendor Price: %s"):format(priceText), 0.85, 0.85, 0.85, true)
	        end

	        GameTooltip:Show()
	        return
	      end
      if g then
        if g.name then
          GameTooltip:AddLine(("Source: %s"):format(g.name), 0.85, 0.85, 0.85, true)
        end
        -- Item-level boss/source truth belongs in the datapack/cache, not in hover.
        -- The old path selected EJ + walked loot rows the first time each item was
        -- hovered, which produced large spikes and stacked requests while mousing
        -- across dense grids.  Prefer the rendered/static source.  A hidden debug
        -- setting can re-enable live EJ fallback for source-audit work, but normal
        -- users should never wake Encounter Journal from a tooltip.
        UI._clogDropSourceCache = UI._clogDropSourceCache or {}
        local dropKey = tostring(g.id or g.instanceID or "?") .. ":" .. tostring(self.itemID or "?")
        local dropSource = UI._clogDropSourceCache[dropKey]
        if dropSource == false then dropSource = nil end
        if not dropSource and type(self._clogDropSource) == "string" and self._clogDropSource ~= "" then
          dropSource = self._clogDropSource
        end
        if not dropSource then
          local meta = ns and ns.RaidDungeonMeta and ns.RaidDungeonMeta.GetItemMeta and ns.RaidDungeonMeta.GetItemMeta(g, self.itemID) or nil
          local staticDropSource = (type(meta) == "table" and meta.dropsFrom) or (g.itemSources and (g.itemSources[self.itemID] or g.itemSources[tostring(self.itemID)])) or nil
          if type(staticDropSource) == "string" and staticDropSource ~= "" then
            dropSource = staticDropSource
          end
        end
        local allowLiveSource = CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.debugLiveEncounterTooltipSources == true
        if (not dropSource) and allowLiveSource and ns and type(ns.GetEncounterSourceForItem) == "function" then
          local okLive, live = pcall(ns.GetEncounterSourceForItem, g, self.itemID)
          if okLive and type(live) == "string" and live ~= "" then
            dropSource = live
          end
        end
        UI._clogDropSourceCache[dropKey] = dropSource or false
        if dropSource then
          GameTooltip:AddLine(("Drops from: %s"):format(dropSource), 0.85, 0.85, 0.85, true)
        end
        -- Mode: which difficulties this collectible drops in (loot-table truth).
        -- The heavy variant-color analysis is cached per item/group/generation so
        -- repeated hover does not keep hitting transmog APIs.
        local modeText
        local modeAnalysis = UI.GetRaidDungeonTooltipModeAnalysis and UI.GetRaidDungeonTooltipModeAnalysis(self, g, self.itemID, isCollected) or nil
        if type(modeAnalysis) == "table" then
          modeText = modeAnalysis.modeText
        end

        if activeCat == "Housing" then
          local sellPrice
          if GetItemInfo then
            local _n,_l,_q,_il,_rl,_c,_sc,_st,_el,_ic,_sp = GetItemInfo(self.itemID)
            sellPrice = _sp
          end
          if type(sellPrice) == "number" and sellPrice > 0 then
            local priceText
            if GetCoinTextureString then
              priceText = GetCoinTextureString(sellPrice)
            elseif GetMoneyString then
              priceText = GetMoneyString(sellPrice, true)
            else
              priceText = tostring(sellPrice)
            end
            GameTooltip:AddLine(("Vendor Price: %s"):format(priceText), 0.85, 0.85, 0.85, true)
          end

          local vendorName
          if MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown() and UnitExists and UnitExists("npc") and UnitName then
            vendorName = UnitName("npc")
          end
          if vendorName and vendorName ~= "" then
            GameTooltip:AddLine(("Vendor: %s"):format(vendorName), 0.85, 0.85, 0.85, true)
          end

          -- Housing metadata (under the Collection Log section)
          local hMeta = (ns and ns.HousingItemMeta and ns.HousingItemMeta[self.itemID]) or nil
          if hMeta then
            
            -- Normalize reward source (some mappings use questIDs under "achievement")
            local st, sid = hMeta.sourceType, hMeta.sourceID
            if ns and ns.GetHousingRewardSource then
              local nst, nsid = ns.GetHousingRewardSource(hMeta)
              if nst and nsid then
                st, sid = nst, nsid
              end
            end

if st == "achievement" and sid then
              local aName, aDesc
              if GetAchievementInfo then
                local ok = true
                ok, aName, _, _, _, _, _, aDesc = pcall(GetAchievementInfo, hMeta.sourceID)
                if not ok then aName, aDesc = nil, nil end
              end
              if aName and aName ~= "" then
                GameTooltip:AddLine(("Achievement: %s"):format(aName), 1, 0.82, 0, true)
                if aDesc and aDesc ~= "" then
                  GameTooltip:AddLine(aDesc, 0.9, 0.9, 0.9, true)
                end
              else
                GameTooltip:AddLine(("Achievement ID: %d"):format(hMeta.sourceID), 1, 0.82, 0, true)
              end
            elseif st == "quest" and sid then
              local qTitle = (C_QuestLog and C_QuestLog.GetTitleForQuestID) and C_QuestLog.GetTitleForQuestID(sid) or nil
              if qTitle and qTitle ~= "" then
                GameTooltip:AddLine(("Quest: %s"):format(qTitle), 1, 0.82, 0, true)
              else
                GameTooltip:AddLine(("Quest ID: %d"):format(hMeta.sourceID), 1, 0.82, 0, true)
              end
            end
            if hMeta.expansion and ns and ns.HousingExpansionNames and ns.HousingExpansionNames[hMeta.expansion] then
              GameTooltip:AddLine(("Expansion: %s"):format(ns.HousingExpansionNames[hMeta.expansion]), 0.85, 0.85, 0.85, true)
            end
          end

        end
        if modeText then
          GameTooltip:AddLine(("Mode: %s"):format(modeText), 0.85, 0.85, 0.85, true)
        elseif g.mode then
          GameTooltip:AddLine(("Mode: %s"):format(g.mode), 0.85, 0.85, 0.85, true)
        end
      end

      if WishlistContainsCell and Wishlist.ContainsCell(self) then
        GameTooltip:AddLine("Wishlist: Yes", 1, 0.82, 0, true)
      end

      GameTooltip:Show()
    end)

    cell:SetScript("OnLeave", function(self)
      self:SetScript("OnUpdate", nil)
      if UI and UI._clogLastHoveredGridCell == self then
        UI._clogLastHoveredGridCell = nil
      end
      GameTooltip:Hide()
    end)
    -- Ctrl+Click: preview items / open mount journal
    cell:SetScript("OnMouseUp", function(self, button)
      -- Shift+Right Click: manual Pet grouping overrides
      if (button == "RightButton" or button == "Button2") and self.petSpeciesID and IsShiftKeyDown and IsShiftKeyDown() then
        local ok, err = pcall(ShowPetOverrideMenu, self, self.petSpeciesID)
        if not ok and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: pet menu error: '..tostring(err)) end
        return
      end

      -- Shift+Right Click: manual Mount grouping overrides
      if (button == "RightButton" or button == "Button2") and self.mountID and IsShiftKeyDown and IsShiftKeyDown() then
        local ok, err = pcall(ShowMountOverrideMenu, self, self.mountID)
        if not ok and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: mount menu error: '..tostring(err)) end
        return
      end

      
      -- Shift+Right Click: manual Toy grouping overrides
      if (button == "RightButton" or button == "Button2") and self.itemID and IsShiftKeyDown and IsShiftKeyDown() then
        local activeCat = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory) or nil
        if activeCat == "Toys" then
          local ok, err = pcall(ShowToyOverrideMenu, self, self.itemID)
          if not ok and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: toy menu error: '..tostring(err)) end
          return
        elseif activeCat == "Housing" then
          local ok, err = pcall(ShowHousingOverrideMenu, self, self.itemID)
          if not ok and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: housing menu error: '..tostring(err)) end
          return
        end
      end

      if (button == "RightButton" or button == "Button2") then
        local ok, err = pcall(ShowWishlistMenu, self, self)
        if not ok and UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage('Collection Log: wishlist menu error: '..tostring(err)) end
        return
      end

if button ~= "LeftButton" then return end
      if not (IsControlKeyDown and IsControlKeyDown()) then return end

      -- Mount: open Mount Journal and try to select it
      if self.mountID then
        -- Open Collections UI (best-effort across versions)
        if ToggleCollectionsJournal then
          pcall(ToggleCollectionsJournal, 1)
        elseif CollectionsJournal and CollectionsJournal.SetShown then
          CollectionsJournal:SetShown(true)
        elseif CollectionsJournal and CollectionsJournal.Show then
          CollectionsJournal:Show()
        end

        -- Switch to Mounts tab (often tab 1)
        if CollectionsJournal_SetTab and CollectionsJournal then
          pcall(CollectionsJournal_SetTab, CollectionsJournal, 1)
        end

        -- Try to select the mount (APIs vary by patch)
        if C_MountJournal and C_MountJournal.SetSelectedMountID then
          pcall(C_MountJournal.SetSelectedMountID, self.mountID)
        elseif MountJournal_SelectByMountID then
          pcall(MountJournal_SelectByMountID, self.mountID)
        elseif MountJournal and MountJournal.SelectByMountID then
          pcall(MountJournal.SelectByMountID, MountJournal, self.mountID)
        end
        return
      end

      -- Pet: open Pet Journal and select the correct species (best-effort)
      if self.petSpeciesID then
        -- Ensure Blizzard collections UI is loaded
        if (not CollectionsJournal) and UIParentLoadAddOn then
          pcall(UIParentLoadAddOn, "Blizzard_Collections")
        end

        -- Open Collections UI and switch to Pets tab
        if ToggleCollectionsJournal then
          pcall(ToggleCollectionsJournal, 2)
        elseif CollectionsJournal and CollectionsJournal.SetShown then
          CollectionsJournal:SetShown(true)
        elseif CollectionsJournal and CollectionsJournal.Show then
          CollectionsJournal:Show()
        end

        if CollectionsJournal_SetTab and CollectionsJournal then
          pcall(CollectionsJournal_SetTab, CollectionsJournal, 2)
        end

	    -- Ensure we clear any temporary filters when the Pet Journal is closed
	    if ns.HookPetJournalFilterCleanup then
	      pcall(ns.HookPetJournalFilterCleanup)
	    end

        local speciesID = self.petSpeciesID
        local petName
        if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
          local okName, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
          if okName then petName = name end
        end

        -- Try selecting species directly (fast path)
        if PetJournal_SelectSpecies then
          pcall(PetJournal_SelectSpecies, speciesID)
        elseif PetJournal and PetJournal.SelectSpecies then
          pcall(PetJournal.SelectSpecies, PetJournal, speciesID)
        elseif C_PetJournal and C_PetJournal.SetSelectedPetSpeciesID then
          pcall(C_PetJournal.SetSelectedPetSpeciesID, speciesID)
        elseif C_PetJournal and C_PetJournal.SetSelectedSpeciesID then
          pcall(C_PetJournal.SetSelectedSpeciesID, speciesID)
        end

        -- Force list narrowing and then select a concrete petID so the Pet Card/model loads
        if C_PetJournal and C_PetJournal.SetSearchFilter and petName then
          pcall(C_PetJournal.SetSearchFilter, petName)
        end

        -- Resolve an owned petID for this species and select it once the Pet Journal list is ready.
        -- Important: Do NOT clear filters while the journal is open; cleanup happens on OnHide.
        if C_Timer and C_Timer.NewTicker and C_PetJournal and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
          local tries = 0
          local ticker
          ticker = C_Timer.NewTicker(0.05, function()
            tries = tries + 1

            local okNum, num = pcall(C_PetJournal.GetNumPets)
            if okNum and type(num) == "number" and num > 0 then
              local targetPetID
              for i = 1, num do
                local okInfo, petID, sID = pcall(C_PetJournal.GetPetInfoByIndex, i)
                if okInfo and petID and sID == speciesID then
                  targetPetID = petID
                  break
                end
              end

              if targetPetID then
                -- Select the owned pet instance (petID), then force a safe Pet Card refresh if available.
                if PetJournal_SelectPet then
                  pcall(PetJournal_SelectPet, targetPetID)
                elseif C_PetJournal.SetSelectedPetID then
                  pcall(C_PetJournal.SetSelectedPetID, targetPetID)
                end

                if PetJournal_UpdatePetCard then
                  pcall(PetJournal_UpdatePetCard)
                end

                if ticker and ticker.Cancel then
                  ticker:Cancel()
                end
                return
              end
            end

            -- Bail out after ~1.5s
            if tries >= 30 then
              if ticker and ticker.Cancel then ticker:Cancel() end
            end
          end)
        else
          -- Fallback: immediate attempt (no retry), best-effort
          if C_PetJournal and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
            local okNum, num = pcall(C_PetJournal.GetNumPets)
            if okNum and type(num) == "number" and num > 0 then
              for i = 1, num do
                local okInfo, petID, sID = pcall(C_PetJournal.GetPetInfoByIndex, i)
                if okInfo and petID and sID == speciesID then
                  if C_PetJournal.SetSelectedPetID then pcall(C_PetJournal.SetSelectedPetID, petID) end
                  if PetJournal_UpdatePetCard then pcall(PetJournal_UpdatePetCard) end
                  break
                end
              end
            end
          end
        end

        return
      end

      -- Item: try to dress up / preview
      if self.itemID then
        local link = select(2, GetItemInfo(self.itemID))
        if not link then
          link = "item:" .. tostring(self.itemID)
        end

        if DressUpItemLink and link then
          pcall(DressUpItemLink, link)
        elseif HandleModifiedItemClick and link then
          pcall(HandleModifiedItemClick, link)
        end
      end

    end)



  end

  UI.maxCells = count
end

-- =====================
-- Section headers
-- =====================
local function EnsureSectionHeaders(count)
  UI.sectionHeaders = UI.sectionHeaders or {}
  if UI.maxSectionHeaders and UI.maxSectionHeaders >= count then return end

  UI.maxSectionHeaders = UI.maxSectionHeaders or 0
  for i = UI.maxSectionHeaders + 1, count do
    local h = CreateFrame("Frame", nil, UI.grid)
    UI.sectionHeaders[i] = h
    h:SetSize(1, SECTION_H)

    local txt = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h.text = txt
    txt:SetPoint("LEFT", h, "LEFT", 2, 0)
    txt:SetTextColor(1, 1, 1, 1)

    local line = h:CreateTexture(nil, "ARTWORK")
    h.line = line
    -- Main category divider: match Blizzard's dropdown arrow gold to improve hierarchy.
    -- (Sub-section dividers remain neutral.)
    -- Subtle (not bold): 1px line, 50% alpha.
    line:SetHeight(1)
    line:SetPoint("LEFT", txt, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", h, "RIGHT", -2, 0)
    line:SetColorTexture(0.75, 0.63, 0.20, 0.42)
  end

  UI.maxSectionHeaders = count
end

-- =====================
-- Sub-section headers (for inline subcategories within Armor/Weapons)
-- =====================
local SUBSECTION_H = 14
local SUBSECTION_GAP = 4
local BLOCK_GAP = 22

local function EnsureSubSectionHeaders(count)
  UI.subSectionHeaders = UI.subSectionHeaders or {}
  if UI.maxSubSectionHeaders and UI.maxSubSectionHeaders >= count then return end

  UI.maxSubSectionHeaders = UI.maxSubSectionHeaders or 0
  for i = UI.maxSubSectionHeaders + 1, count do
    local h = CreateFrame("Frame", nil, UI.grid)
    UI.subSectionHeaders[i] = h
    h:SetSize(1, SUBSECTION_H)

    local txt = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.text = txt
    txt:SetPoint("LEFT", h, "LEFT", 2, 0)
    txt:SetTextColor(1, 1, 1, 0.90)

    local line = h:CreateTexture(nil, "ARTWORK")
    h.line = line
    line:SetHeight(1)
    line:SetPoint("LEFT", txt, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", h, "RIGHT", -2, 0)
    line:SetColorTexture(1, 1, 1, 0.10)
  end

  UI.maxSubSectionHeaders = count
end

-- Fast subcategory classification for inline loot layout.
-- Uses GetItemInfoInstant only (no async), so it is stable on first render.
local ARMOR_SUB_ORDER = { "Head", "Shoulder", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Back", "Off-hand" }
local WEAPON_SUB_ORDER = { "1H", "2H", "Dagger", "Polearm", "Staff", "Fist", "Wand", "Ranged", "Off-hand" }

local function CL_GetArmorSubCategory(itemID)
  local _, _, _, equipLoc, _, classID, subClassID = GetItemInfoInstant(itemID)
  if not equipLoc then return nil end
  if equipLoc == "INVTYPE_HEAD" then return "Head" end
  if equipLoc == "INVTYPE_SHOULDER" then return "Shoulder" end
  if equipLoc == "INVTYPE_CHEST" or equipLoc == "INVTYPE_ROBE" then return "Chest" end
  if equipLoc == "INVTYPE_WRIST" then return "Wrist" end
  if equipLoc == "INVTYPE_HAND" then return "Hands" end
  if equipLoc == "INVTYPE_WAIST" then return "Waist" end
  if equipLoc == "INVTYPE_LEGS" then return "Legs" end
  if equipLoc == "INVTYPE_FEET" then return "Feet" end
  if equipLoc == "INVTYPE_CLOAK" then return "Back" end
  if equipLoc == "INVTYPE_SHIELD" then return "Off-hand" end
  return nil
end

local function CL_GetWeaponSubCategory(itemID)
  local _, _, _, equipLoc, _, classID, subClassID = GetItemInfoInstant(itemID)
  if not equipLoc then return nil end

  if equipLoc == "INVTYPE_HOLDABLE" then return "Off-hand" end

  if equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" then
    if classID == 2 and subClassID == 19 then return "Wand" end
    return "Ranged"
  end

  if equipLoc == "INVTYPE_2HWEAPON" then
    if classID == 2 and subClassID == 10 then return "Staff" end
    if classID == 2 and subClassID == 6 then return "Polearm" end
    return "2H"
  end

  if equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
    if classID == 2 and subClassID == 15 then return "Dagger" end
    if classID == 2 and subClassID == 13 then return "Fist" end
    return "1H"
  end

  if classID == 2 and type(equipLoc) == "string" then
    if equipLoc:find("2H", 1, true) then return "2H" end
    if equipLoc:find("WEAPON", 1, true) then return "1H" end
  end

  return nil
end

local function CL_GetHousingType(itemID)
  if not itemID then return nil end
  if ns and ns.HousingTypeByItemID then
    return ns.HousingTypeByItemID[itemID]
  end
  return nil
end

-- =====================
-- Refresh grid
-- =====================

-- =========================
-- Mount/Pet collected cache (session)
-- Avoid repeated journal calls when switching instances (performance).
-- Truthful: values come only from Blizzard APIs, just memoized.
-- =========================
UI._clogMountCache = UI._clogMountCache or {}
UI._clogPetCache = UI._clogPetCache or {}

local function CL_GetMountIconCollected(mountID)
  if not mountID then return nil, false end

  -- IMPORTANT: Do NOT permanently memoize a false/grey state when the Mount Journal
  -- has not finished initializing for the session. If we cache too early, mounts
  -- can appear uncollected until a second click.
  local c = UI._clogMountCache[mountID]
  if c and c.ready then
    return c.icon, c.collected
  end

  local icon, collected = nil, false
  local ready = false

  if C_MountJournal and C_MountJournal.GetMountInfoByID then
    local _, _, ic, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
    icon = ic
    collected = (isCollected == true)
    -- Treat nil isCollected AND nil icon as "unknown" (journal not ready yet)
    ready = (isCollected ~= nil) or (ic ~= nil)
  end

  -- Only cache when we have a reliable signal.
  if ready then
    UI._clogMountCache[mountID] = { icon = icon, collected = collected, ready = true }
  end

  return icon, collected
end

local function CL_GetPetIconCollected(speciesID)
  speciesID = tonumber(speciesID)
  if not speciesID or speciesID <= 0 then return nil, false end
  local c = UI._clogPetCache[speciesID]
  if c and c.ready then return c.icon, c.collected end
  local icon, collected = nil, false
  local ready = false
  if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
    local ok, _, ic = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
    if ok then icon = ic; if ic ~= nil then ready = true end end
  end
  if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
    local ok, numCollected = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
    if ok and type(numCollected) == "number" then
      collected = numCollected > 0
      ready = true
    end
  end
  if ready then UI._clogPetCache[speciesID] = { icon = icon, collected = collected, ready = true } end
  return icon, collected
end

local function CL_UseTrueCollectionForCell(groupId)
  if not groupId then return false end
  local dbui = CollectionLogDB and CollectionLogDB.ui
  local cat = dbui and dbui.activeCategory
  local mode = dbui and dbui.viewMode

  -- v4.3.42: Raid/Dungeon grid cells live under activeCategory, not viewMode.
  -- viewMode can remain ACCOUNT/CHARACTER and caused TrueCollection saturation
  -- to be bypassed even though the header/row counts were already backend-driven.
  local isRaidDungeon = (cat == "Raids" or cat == "Dungeons" or mode == "raids" or mode == "dungeons")
  return isRaidDungeon and ns and ns.TrueCollection and ns.TrueCollection.IsItemCollected
end

local function CL_GetTruthStateForItem(itemID, groupId)
  itemID = tonumber(itemID)
  if not (itemID and itemID > 0 and groupId and CL_UseTrueCollectionForCell(groupId)) then return nil end

  -- Single visible-cell truth object.  Grid saturation, tooltip notes, and the
  -- visible-state refresh path should all consume this object instead of each
  -- inventing collection state from separate helpers.
  UI._clogTrueCollectedCellCache = UI._clogTrueCollectedCellCache or {}
  local gen = tonumber(UI._clogCollectedStateGen or 0) or 0
  local modeKey = (ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode()) or (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode) or "shared"
  local key = tostring(groupId) .. ":" .. tostring(itemID) .. ":" .. tostring(gen) .. ":" .. tostring(modeKey) .. ":state"
  local cached = UI._clogTrueCollectedCellCache[key]
  if cached ~= nil then
    if cached == "__nil" then return nil end
    return cached
  end

  local state, def
  if ns and ns.Truth and ns.Truth.GetItemCollectionState then
    local okState, st, d = pcall(ns.Truth.GetItemCollectionState, itemID, groupId)
    if okState and type(st) == "table" then
      state, def = st, d
    end
  end

  if not state and ns and ns.TrueCollection and ns.TrueCollection.IsItemCollected then
    local ok, collected, d = pcall(ns.TrueCollection.IsItemCollected, itemID, groupId)
    if ok and collected ~= nil then
      state = { countsAsCollected = collected and true or false, collected = collected and true or false, label = collected and "Yes" or "No", reason = "true_collection_boolean_fallback", def = d }
      def = d
    end
  end

  if state then
    state.countsAsCollected = state.countsAsCollected and true or false
    state.collected = state.countsAsCollected
    state.def = state.def or def
    UI._clogTrueCollectedCellCache[key] = state
    return state
  end

  UI._clogTrueCollectedCellCache[key] = "__nil"
  return nil
end

local function CL_GetTrueCollectedForItem(itemID, groupId)
  local state = CL_GetTruthStateForItem(itemID, groupId)
  if type(state) == "table" and state.countsAsCollected ~= nil then
    return state.countsAsCollected and true or false, state
  end
  return nil, state
end

-- Refresh only the currently-visible cells' collected state (no relayout).
-- This fixes the "first click shows grey, second click shows collected" effect
-- caused by asynchronous item/transmog data.
function UI.RefreshVisibleCollectedStateOnly()
  if not (UI and UI.frame and UI.frame:IsShown() and UI.cells) then return end
  if not (CollectionLogDB and CollectionLogDB.ui) then return end

  local mode = CollectionLogDB.ui.viewMode
  local activeCat = CollectionLogDB.ui.activeCategory
  if mode ~= "dungeons" and mode ~= "raids" and activeCat ~= "Dungeons" and activeCat ~= "Raids" then return end

  local guid = CollectionLogDB.ui.activeCharacterGUID

  for i = 1, (UI.maxCells or 0) do
    local cell = UI.cells[i]
    if cell and cell:IsShown() then
      local collected = false
      local iconFile = nil
      local recCount = 0

      -- v4.3.64: repeated item/journal events can request many visible-only
      -- refreshes in a short burst. Most passes are checking the exact same
      -- visible cells. Reuse the last truthful result until a collection/event
      -- invalidates this generation. This keeps the safety refreshes cheap
      -- without changing the source of truth.
      local modeKey = (ns and ns.GetAppearanceCollectionMode and ns.GetAppearanceCollectionMode()) or (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.appearanceCollectionMode) or "shared"
      local stateKey = tostring(cell.groupId or "") .. "|" .. tostring(cell.section or "") .. "|" .. tostring(cell.itemID or "") .. "|" .. tostring(cell.mountID or "") .. "|" .. tostring(cell.petSpeciesID or "") .. "|" .. tostring(modeKey)
      local stateGen = UI._clogCollectedStateGen or 0
      if cell._clogCollectedStateKey == stateKey and cell._clogCollectedStateGen == stateGen then
        collected = cell._clogCollectedCachedCollected and true or false
        iconFile = cell._clogCollectedCachedIcon
        recCount = cell._clogCollectedCachedCount or 0
        if cell.countText then
          cell.countText:SetText((recCount and recCount > 0) and tostring(recCount) or "")
        end
        if iconFile and cell.icon and cell.icon.GetTexture and (cell.icon:GetTexture() ~= iconFile) then
          cell.icon:SetTexture(iconFile)
        end
        if cell.icon then
          DesaturateIf(cell.icon, not collected)
        end
        ApplyCellCollectedVisual(cell, collected)
      else

      if cell.mountID then
        iconFile, collected = CL_GetMountIconCollected(cell.mountID)
        if cell.countText then cell.countText:SetText("") end
      elseif cell.petSpeciesID then
        iconFile, collected = CL_GetPetIconCollected(cell.petSpeciesID)
        if cell.countText then cell.countText:SetText("") end
      elseif cell.itemID then
        iconFile = select(5, GetItemInfoInstant(cell.itemID))

        local trueCollected, truthState = CL_GetTrueCollectedForItem(cell.itemID, cell.groupId)
        cell._clogTruthState = truthState
        if cell.section == "Mounts" then
          local legacy = (ns.IsMountCollected and ns.IsMountCollected(cell.itemID)) or false
          collected = (trueCollected == true) or legacy
          if cell.countText then cell.countText:SetText("") end
        elseif cell.section == "Pets" then
          local legacy = (ns.IsPetCollected and ns.IsPetCollected(cell.itemID)) or false
          local speciesOwned = false
          local speciesID = cell.petSpeciesID or CL_ResolvePetSpeciesIDFromItemID(cell.itemID)
          if speciesID then
            local petIcon, petCollected = CL_GetPetIconCollected(speciesID)
            speciesOwned = petCollected and true or false
            if petIcon then iconFile = petIcon end
            cell.petSpeciesID = speciesID
          end
          collected = (trueCollected == true) or speciesOwned or legacy
          if cell.countText then cell.countText:SetText("") end
        elseif cell.section == "Toys" then
          local legacy = (ns.IsToyCollected and ns.IsToyCollected(cell.itemID)) or false
          collected = (trueCollected == true) or legacy
          if cell.countText then cell.countText:SetText("") end
        elseif cell.section == "Housing" then
          local legacy = (ns.IsHousingCollected and ns.IsHousingCollected(cell.itemID)) or false
          collected = (trueCollected == true) or legacy
          if cell.countText then cell.countText:SetText("") end
        elseif trueCollected ~= nil then
          collected = trueCollected
          if cell.countText then cell.countText:SetText("") end
        elseif UI.IsRaidDungeonGridContext() and UI.IsAppearanceLootSection(cell.section) then
          -- Raid/Dungeon appearance cells must not fall back to the old itemID-only
          -- ns.IsCollected() path. That legacy helper can report broad wardrobe or
          -- tooltip-family ownership and make a visible icon saturated while the
          -- unified truth/header correctly says 0 collected. If the resolver could
          -- not prove the visible row, fail closed.
          collected = false
          if cell.countText then cell.countText:SetText("") end
        else
          -- Toys should remain Blizzard-truthful via the canonical toy resolver.
          local isToy = (ns.IsToyCollected and ns.IsToyCollected(cell.itemID)) or false
          if isToy or cell.section == "Toys" then
            collected = isToy and true or false
            if cell.countText then cell.countText:SetText("") end
          else
            recCount = ns.GetRecordedCount(cell.itemID, mode, guid)
            local isCollected = (ns.IsCollected and ns.IsCollected(cell.itemID)) or false
            collected = (recCount and recCount > 0) or isCollected
            if cell.countText then
              cell.countText:SetText((recCount and recCount > 0) and tostring(recCount) or "")
            end
          end
        end
      end

      cell._clogCollectedStateKey = stateKey
      cell._clogCollectedStateGen = stateGen
      cell._clogCollectedCachedCollected = collected and true or false
      cell._clogCollectedCachedIcon = iconFile
      cell._clogCollectedCachedCount = recCount or 0
      cell._clogCachedCollected = collected and true or false

      if iconFile and cell.icon and cell.icon.GetTexture and (cell.icon:GetTexture() ~= iconFile) then
        cell.icon:SetTexture(iconFile)
      end
      if cell.icon then
        DesaturateIf(cell.icon, not collected)
      end
      ApplyCellCollectedVisual(cell, collected and true or false)
      end -- cached visible-state fast path
    end
  end
end

-- Lightweight header/progress recompute (no layout rebuild).
-- Used after async collection data arrives so the "Collected X/Y" line and progress bar
-- update without requiring a second click or an expensive full grid rebuild.
function UI.RefreshHeaderCountsOnly()
  if not (UI and UI.frame and UI.frame:IsShown()) then return end
  if not (CollectionLogDB and CollectionLogDB.ui) then return end
  local mode = CollectionLogDB.ui.viewMode
  if mode ~= "dungeons" and mode ~= "raids" then return end

  local groupId = CollectionLogDB.ui.activeGroupId
  local g = groupId and ns and ns.Data and ns.Data.groups and ns.Data.groups[groupId] or nil
  if not g then return end

  local isMounts = (g.category == "Mounts")
  local isPets   = (g.category == "Pets")
  local isToys   = (g.category == "Toys")
  local isHousing= (g.category == "Housing")

  -- Total
  local total = 0
  if mode == "dungeons" or mode == "raids" then
    -- For raid/dungeon groups, apply Hide Junk filter to totals so header matches the grid.
    if g.items then
      local hideJunk = true
      for _, itemID in ipairs(CL_GetVisibleGroupList(g)) do
        if not hideJunk or CL_IsCoreLootItemID(itemID) then
          total = total + 1
        end
      end
    end
  else
    total = #CL_GetVisibleGroupList(g)
  end

  -- Collected
  local collectedCount = 0
  local guid = CollectionLogDB.ui.activeCharacterGUID

  if isMounts then
    for _, mountID in ipairs(CL_GetVisibleGroupList(g)) do
      local _, isCollected = CL_GetMountIconCollected(mountID)
      if isCollected then collectedCount = collectedCount + 1 end
    end
  elseif isPets then
    for _, speciesID in ipairs(CL_GetVisibleGroupList(g)) do
      local _, isCollected = CL_GetPetIconCollected(speciesID)
      if isCollected then collectedCount = collectedCount + 1 end
    end
  elseif isToys then
    for _, toyItemID in ipairs(CL_GetVisibleGroupList(g)) do
      local has = (ns.IsToyCollected and ns.IsToyCollected(toyItemID)) or false
      if has then collectedCount = collectedCount + 1 end
    end
  elseif isHousing then
    -- Housing: use precomputed group counts (fast, stable; no "counting up").
    if type(g.collectedCount) == "number" and type(g.totalCount) == "number" then
      collectedCount = g.collectedCount
      total = g.totalCount
    else
      -- Fallback to cached map
      local map = (ns and ns.HousingCollectedByItemID) or nil
      if map then
        for _, itemID in ipairs(CL_GetVisibleGroupList(g)) do
          if map[itemID] == true then
            collectedCount = collectedCount + 1
          end
        end
      else
        for _, itemID in ipairs(CL_GetVisibleGroupList(g)) do
          if ns and ns.IsHousingCollected and ns.IsHousingCollected(itemID) then
            collectedCount = collectedCount + 1
          end
        end
      end
    end

  else
    local viewMode = mode
    for _, itemID in ipairs(CL_GetVisibleGroupList(g)) do
      local hideJunk = true
      if not hideJunk or CL_IsCoreLootItemID(itemID) then
        -- Section-aware "core" items inside raid/dungeon grids
        local sec = (UI.GetGroupItemSectionFromMetadata and UI.GetGroupItemSectionFromMetadata(g, itemID))
          or (ns and ns.GetItemSectionFast and ns.GetItemSectionFast(itemID))
          or nil
        if sec == "Mounts" then
          if ns.IsMountCollected and ns.IsMountCollected(itemID) then collectedCount = collectedCount + 1 end
        elseif sec == "Pets" then
          if ns.IsPetCollected and ns.IsPetCollected(itemID) then collectedCount = collectedCount + 1 end
        else
          local isToy = (ns.IsToyCollected and ns.IsToyCollected(itemID)) or false
          if isToy or sec == "Toys" then
            if isToy then collectedCount = collectedCount + 1 end
          else
            local recCount = ns.GetRecordedCount(itemID, viewMode, guid)
            local blizzCollected = (ns.IsCollected and ns.IsCollected(itemID)) or false
            if (recCount and recCount > 0) or blizzCollected then
              collectedCount = collectedCount + 1
            end
          end
        end
      end
    end
  end

  collectedCount, total = CLog_ResolveDisplayedGroupTotals(g, collectedCount, total)

  -- Update UI
  local color
  if total == 0 then
    color = "FF808080"
  elseif collectedCount == 0 then
    color = "FFFF2020"
  elseif collectedCount >= total then
    color = "FF20FF20"
  else
    color = "FFFFD100"
  end

  if UI.groupCount then
    UI.groupCount:SetText(("Collected: |c%s%d/%d|r"):format(color, collectedCount, total))
  end
  if SetProgressBar then
    SetProgressBar(collectedCount, total)
  end

  -- Cache completion so left-list coloring matches header/grid truth (and doesn't depend on scan timing).
  local gidKey = groupId and tostring(groupId) or nil
  UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
  if gidKey then
    local canTrust = true
    if CLog_IsRaidDungeonGroup(g) and ns and ns.AreCollectionResolversWarm and not ns.AreCollectionResolversWarm() then
      canTrust = false
    end

    local existing = UI._clogLeftListColorCache and UI._clogLeftListColorCache[gidKey]
    if not (existing and existing.hard == true) then
      UI._clogLeftListColorCache[gidKey] = CLOG_MakeLeftListCacheEntry(collectedCount, total, canTrust, "active_header")
      if CLOG_InvalidateDifficultyIndicatorForGroup then CLOG_InvalidateDifficultyIndicatorForGroup(gidKey) end
      if CLOG_ScheduleDifficultyIndicatorRepaintForGroup then CLOG_ScheduleDifficultyIndicatorRepaintForGroup(gidKey) end

      -- Persist only trusted truth so startup never revives a false yellow state.
      if canTrust and CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
        local existingSaved = CollectionLogDB.ui.leftListColorCache.cache[gidKey]
        if not (CLOG_IsLeftListCacheEntryFresh and CLOG_IsLeftListCacheEntryFresh(existingSaved, true)) then
          CollectionLogDB.ui.leftListColorCache.cache[gidKey] = CLOG_MakeLeftListCacheEntry(collectedCount, total, true, "active_header")
          if CollectionLogDB.ui.leftListColorCache.meta then
            CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
          end
        end
      end
    end
  end
  -- Soft-cache only: do NOT truth-lock. Header compute will set hard truth.
  CLog_ApplyLeftListTextColor(groupId, false)
end


-- Trigger a safe, lightweight "recheck collected" pass without rebuilding layout.
-- Clears session mount/pet memoization and re-evaluates only visible cells.
function UI.TriggerCollectedRefresh()
  if not UI then return end

  -- v4.3.65: hard-throttle collected-state refreshes. The previous debounce
  -- still allowed hundreds of visible-cell refreshes over a short profile run
  -- because post-render timers and journal events kept arriving after each
  -- debounce window. One visible-state pass per short window is enough; real
  -- collection events bump _clogCollectedStateGen elsewhere when needed.
  local now = (GetTime and GetTime()) or 0
  local minGap = 0.75
  if UI._clogCollectedRefreshPending then return end

  local wait = 0.25
  if UI._clogLastCollectedRefreshRun and now > 0 then
    local elapsed = now - UI._clogLastCollectedRefreshRun
    if elapsed < minGap then
      wait = math.max(wait, minGap - elapsed)
    end
  end

  if C_Timer and C_Timer.After then
    UI._clogCollectedRefreshPending = true
    C_Timer.After(wait, function()
      UI._clogCollectedRefreshPending = false
      if UI and UI._clogDoCollectedRefreshNow then pcall(UI._clogDoCollectedRefreshNow) end
    end)
    return
  end

  if UI._clogDoCollectedRefreshNow then return UI._clogDoCollectedRefreshNow() end
end

function UI._clogDoCollectedRefreshNow()
  if not UI then return end

  UI._clogLastCollectedRefreshRun = (GetTime and GetTime()) or 0

  -- Clear memoized journal reads so we don't keep a stale "false" from early init.
  UI._clogMountCache = {}
  UI._clogPetCache = {}

  -- v4.3.71: visible-only refresh must not request item data either. Those
  -- requests fan out into GET_ITEM_INFO_RECEIVED / ITEM_DATA_LOAD_RESULT bursts.

  if UI.RefreshVisibleCollectedStateOnly then
    pcall(UI.RefreshVisibleCollectedStateOnly)
        if UI.RefreshHeaderCountsOnly then pcall(UI.RefreshHeaderCountsOnly) end
  end
end

-- Quiet "auto second click" for Raid/Dungeon encounter selections.
-- After the grid is first built, re-check collected state once (and again shortly after)
-- without rebuilding layout. This resolves early-session journal readiness without lag.
function UI.ScheduleEncounterAutoRefresh()
  if not UI or not C_Timer or not C_Timer.After then return end
  local dbui = CollectionLogDB and CollectionLogDB.ui
  if not dbui then return end

  -- v4.3.71: this old "soft second click" path intentionally rebuilt/rechecked
  -- raid/dungeon grids after selection. It fixed some cold-cache visuals, but it
  -- also means just leaving the UI open schedules extra resolver work. Keep it
  -- opt-in only for debugging; normal use should remain static/cache-only.
  if dbui.enableRaidDungeonAutoSecondPass ~= true then return end

  local cat = dbui.activeCategory
  if cat ~= "Dungeons" and cat ~= "Raids" then return end

  local groupId = dbui.activeGroupId
  if not groupId then return end

  UI._clogAutoSecondToken = (UI._clogAutoSecondToken or 0) + 1
  local token = UI._clogAutoSecondToken
  local key = tostring(cat) .. ":" .. tostring(groupId)

  local function StillSame()
    if UI._clogAutoSecondToken ~= token then return false end
    local cur = CollectionLogDB and CollectionLogDB.ui
    if not cur then return false end
    if cur.activeCategory ~= cat then return false end
    if cur.activeGroupId ~= groupId then return false end
    if UI.frame and not UI.frame:IsShown() then return false end
    return true
  end

  -- Pass 1: cheap visible-only recolor (clears memo caches).
  C_Timer.After(0.08, function()
    if not StillSame() then return end
    if UI.TriggerCollectedRefresh then pcall(UI.TriggerCollectedRefresh) end
  end)

  -- Pass 2: one-time "soft second click" that re-runs the grid build once after item/pet info settles.
  -- This is debounced per encounter selection so it cannot loop or lag.
  C_Timer.After(0.30, function()
    if not StillSame() then return end
    -- If the user manually hit Refresh very recently, don't auto-run again.
    if UI._clogLastManualRefresh and GetTime and (GetTime() - UI._clogLastManualRefresh) < 0.5 then return end
    if UI._clogAutoSecondDoneKey == key then return end
    UI._clogAutoSecondDoneKey = key
    if UI.RefreshGrid then pcall(UI.RefreshGrid) end
  end)
end



-- Build batching (smooth navigation): apply cell updates over multiple frames.
-- How many icon cells to apply per frame-batch.
-- We keep this reasonably high for a snappy feel, but we also time-budget
-- each batch so huge loot tables don't hitch the game.
local CLOG_BUILD_BATCH = 120

-- Non-core loot filtering (optional UI setting)
-- "Core" = Weapons, Armor, Mounts, Pets, Toys, Illusions (best-effort)
-- Everything else (including Jewelry/Trinkets and misc) can be hidden/suppressed.
local function CL_ResolveMountIDFromItemID(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return nil end

  -- Static definitions first so raid mount teaching items can paint on the
  -- first open even if Blizzard's mount journal helpers are still cold.
  local row = ns and ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) or nil
  if not row and ns and ns.CompletionRaidMounts and ns.CompletionRaidMounts.GetFallbackItemInfo then
    row = ns.CompletionRaidMounts.GetFallbackItemInfo(itemID)
  end
  local mid = row and tonumber(row.mountID or row.collectibleID or 0) or nil
  if mid and mid > 0 then return mid end

  if not C_MountJournal then return nil end

  if C_MountJournal.GetMountFromItem then
    local ok, mountID = pcall(C_MountJournal.GetMountFromItem, itemID)
    if ok and mountID and mountID ~= 0 then return mountID end
  end

  if C_MountJournal.GetMountFromItemID then
    local ok, a, b = pcall(C_MountJournal.GetMountFromItemID, itemID)
    if ok then
      local mountID = (a and a ~= 0 and a) or (b and b ~= 0 and b) or nil
      if mountID then return mountID end
    end
  end

  if C_MountJournal.GetMountIDFromItemID then
    local ok, mountID = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
    if ok and mountID and mountID ~= 0 then return mountID end
  end

  return nil
end

local function CL_ResolvePetSpeciesIDFromItemID(itemID)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return nil end

  -- Static datapack first. C_PetJournal.GetPetInfoByItemID can be cold/nil for
  -- raid pet teaching items, which made collected pets count correctly but stay
  -- visually desaturated in the raid/dungeon grid.
  local row = ns and ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) or nil
  local sid = row and tonumber(row.speciesID or row.petSpeciesID or row.collectibleID or 0) or nil
  if sid and sid > 0 then return sid end

  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local ok, speciesID = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
    if ok and speciesID and speciesID ~= 0 then return speciesID end
  end
  return nil
end

CLOG_ShouldHideUnobtainable = function()
  return CollectionLogDB
    and CollectionLogDB.settings
    and CollectionLogDB.settings.hideUnobtainable == true
end

local function CL_IsRetiredMountByName(name)
  if type(name) ~= "string" or name == "" then return false end
  local set = ns and ns.RetiredMountNameSet
  return type(set) == "table" and set[strlower(name)] == true
end

CL_IsUnobtainableMountID = function(mountID)
  mountID = tonumber(mountID)
  if not mountID or mountID <= 0 then return false end
  if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return false end
  local ok, name = pcall(C_MountJournal.GetMountInfoByID, mountID)
  if not ok then return false end
  return CL_IsRetiredMountByName(name)
end

local function CL_IsUnobtainableItemID(itemID, itemLink)
  itemID = tonumber(itemID)
  if not itemID or itemID <= 0 then return false end
  local mountID = CL_ResolveMountIDFromItemID and CL_ResolveMountIDFromItemID(itemID)
  if mountID and CL_IsUnobtainableMountID(mountID) then
    return true
  end
  return false
end

local function CL_IsCollectedForVisibility(category, value, itemLink)
  if category == "Mounts" then
    local mountID = tonumber(value)
    if mountID and mountID > 0 and C_MountJournal and C_MountJournal.GetMountInfoByID then
      local ok, _, spellID, icon, isActive, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
      if ok then
        return isCollected == true
      end
    end
    return false
  end

  if ns and ns.IsCollected then
    local ok, collected = pcall(ns.IsCollected, tonumber(value), itemLink)
    if ok and collected == true then return true end
  end
  return false
end

local function CL_IsVisibleCollectible(category, value, itemLink)
  if not CLOG_ShouldHideUnobtainable() then return true end

  if category == "Mounts" then
    if not CL_IsUnobtainableMountID(value) then return true end
    return CL_IsCollectedForVisibility(category, value, itemLink)
  end

  if not CL_IsUnobtainableItemID(value, itemLink) then return true end
  return CL_IsCollectedForVisibility(category, value, itemLink)
end

CLOG_VISIBLE_GROUP_LIST_CACHE = CLOG_VISIBLE_GROUP_LIST_CACHE or {}
CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE = CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE or {}

function UI.ClearVisibleGroupListCache()
  if type(wipe) == "function" then
    wipe(CLOG_VISIBLE_GROUP_LIST_CACHE)
    wipe(CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE)
  else
    for k in pairs(CLOG_VISIBLE_GROUP_LIST_CACHE) do CLOG_VISIBLE_GROUP_LIST_CACHE[k] = nil end
    for k in pairs(CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE) do CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE[k] = nil end
  end
end

function CLOG_GetRefreshScopedCacheSignature()
  local hideU = (CLOG_ShouldHideUnobtainable and CLOG_ShouldHideUnobtainable()) and "1" or "0"

  -- Important performance note:
  -- These caches hold expensive answers keyed by category/groupId already. They
  -- do NOT depend on the active tab, active group, or expansion dropdown.
  -- Including cat/exp here made normal Raids <-> Dungeons tab switches wipe the
  -- visible-list cache, forcing hundreds of groups to re-check their loot every
  -- click. Only the unobtainable setting changes list membership globally.
  return "hideU=" .. tostring(hideU)
end

function CLOG_ClearRefreshScopedCachesIfNeeded(force)
  local sig = CLOG_GetRefreshScopedCacheSignature and CLOG_GetRefreshScopedCacheSignature() or ""
  if (not force) and UI and UI._clogRefreshScopedCacheSig == sig then return false end
  if UI then UI._clogRefreshScopedCacheSig = sig end
  if UI and UI.ClearCategoryRowCountCache then pcall(UI.ClearCategoryRowCountCache) end
  if UI and UI.ClearVisibleGroupListCache then pcall(UI.ClearVisibleGroupListCache) end
  -- v4.3.70: difficulty indicators are cached by groupId and are safe to
  -- keep across ordinary tab/filter layout refreshes.  Clearing them here made
  -- every Raids/Dungeons tab click synchronously rebuild every visible row's
  -- sibling-status text.  They are now cleared only when collection truth is
  -- actually invalidated (manual refresh / collection events).
  -- if CLOG_ResetDifficultyIndicatorCache then pcall(CLOG_ResetDifficultyIndicatorCache) end
  -- v4.3.64: these are truth/result caches, not layout-scoped caches.
  -- Clearing them on tab/group layout changes caused multi-second group-status
  -- recomputation during ordinary RefreshAll calls. They are cleared by explicit
  -- manual refresh / backend invalidation instead.
  -- if CLOG_ResetTrueStatusCache then pcall(CLOG_ResetTrueStatusCache) end
  -- if CLOG_ResetAggregateDifficultyTotalsCache then pcall(CLOG_ResetAggregateDifficultyTotalsCache) end
  return true
end

CL_GetVisibleGroupList = function(g)
  if not g then return {} end

  local source = g.mounts or g.pets or g.items or {}
  if not CLOG_ShouldHideUnobtainable() then return source end

  local gid = g.id and tostring(g.id) or nil
  local cacheKey = gid and (tostring(g.category or "") .. ":" .. gid) or nil
  if cacheKey and CLOG_VISIBLE_GROUP_LIST_CACHE[cacheKey] then
    return CLOG_VISIBLE_GROUP_LIST_CACHE[cacheKey]
  end

  local out = {}
  if g.category == "Mounts" and type(g.mounts) == "table" then
    for _, mountID in ipairs(g.mounts) do
      if CL_IsVisibleCollectible("Mounts", mountID) then
        out[#out + 1] = mountID
      end
    end
    if cacheKey then CLOG_VISIBLE_GROUP_LIST_CACHE[cacheKey] = out end
    return out
  end

  if type(g.items) == "table" then
    for _, itemID in ipairs(g.items) do
      local itemLink = g.itemLinks and g.itemLinks[itemID] or nil
      if type(itemLink) == "table" then itemLink = itemLink[1] end
      if CL_IsVisibleCollectible(g.category, itemID, itemLink) then
        out[#out + 1] = itemID
      end
    end
    if cacheKey then CLOG_VISIBLE_GROUP_LIST_CACHE[cacheKey] = out end
    return out
  end

  if cacheKey then CLOG_VISIBLE_GROUP_LIST_CACHE[cacheKey] = source end
  return source
end

local CL_IsCoreLootItemID

function UI.GetEligibleVisibleGroupItems(g)
  if type(g) ~= "table" then return {} end
  local visibleItems = CL_GetVisibleGroupList(g)
  if type(visibleItems) ~= "table" then return {} end

  local activeCat = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory) or g.category
  local isInstItems = (activeCat == "Raids" or activeCat == "Dungeons")
  local hideNC = true
  if (not isInstItems) or (not hideNC) then
    return visibleItems
  end

  local gid = g.id and tostring(g.id) or nil
  local cacheKey = gid and (tostring(g.category or "") .. ":" .. gid) or nil
  local cached = cacheKey and CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE[cacheKey] or nil
  if cached then
    return cached
  end

  local out = {}
  for i = 1, #visibleItems do
    local itemID = visibleItems[i]
    if CL_IsCoreLootItemID(itemID) then
      out[#out + 1] = itemID
    end
  end
  if cacheKey then
    CLOG_ELIGIBLE_VISIBLE_GROUP_ITEMS_CACHE[cacheKey] = out
  end
  return out
end

function CL_GroupHasVisibleCollectibles(g)
  if not g then return false end

  if g.category == "Appearances" then
    -- Do not expand appearance sets here just to decide list visibility.
    -- That forces heavy per-set work during group refresh and can freeze the client.
    -- Appearance entries are built only when the selected set is opened.
    return g.setID ~= nil
  end

  local function Check()
    local list = CL_GetVisibleGroupList(g)
    return type(list) == "table" and #list > 0
  end

  if ns and ns.Perf and ns.Perf.Measure then
    return ns.Perf.Measure("UI.CL_GroupHasVisibleCollectibles", Check)
  end
  return Check()
end


function UI.GetGroupItemSectionFromMetadata(g, itemID)
  itemID = tonumber(itemID)
  if type(g) ~= "table" or not itemID then return nil end
  local kind = nil
  if type(g.itemCollectibleTypes) == "table" then
    kind = g.itemCollectibleTypes[itemID] or g.itemCollectibleTypes[tostring(itemID)]
  end
  if not kind and type(g.itemMetadata) == "table" then
    local meta = g.itemMetadata[itemID] or g.itemMetadata[tostring(itemID)]
    if type(meta) == "table" then
      kind = meta.collectibleType or meta.type
    end
  end
  if not kind and ns and ns.RaidDungeonMeta and ns.RaidDungeonMeta.GetItemMeta then
    local okMeta, meta = pcall(ns.RaidDungeonMeta.GetItemMeta, g, itemID)
    if okMeta and type(meta) == "table" then
      kind = meta.kind or meta.type or meta.collectibleType
    end
  end
  kind = tostring(kind or ""):lower()
  if kind == "mount" then return "Mounts" end
  if kind == "pet" then return "Pets" end
  if kind == "toy" then return "Toys" end
  if kind == "housing" then return "Housing" end
  if kind == "appearance" then
    local equipLoc = type(g.itemEquipLocs) == "table" and (g.itemEquipLocs[itemID] or g.itemEquipLocs[tostring(itemID)]) or nil
    local classID = type(g.itemClassIDs) == "table" and tonumber(g.itemClassIDs[itemID] or g.itemClassIDs[tostring(itemID)] or 0) or nil
    if classID == 2 or (type(equipLoc) == "string" and (equipLoc:find("WEAPON", 1, true) or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT")) then return "Weapons" end
    if classID == 4 or (type(equipLoc) == "string" and equipLoc ~= "" and equipLoc ~= "INVTYPE_TRINKET" and equipLoc ~= "INVTYPE_FINGER" and equipLoc ~= "INVTYPE_NECK") then return "Armor" end
    return "Misc"
  end
  return nil
end

function UI.GetGroupItemSubCategoryFromMetadata(g, itemID, section)
  itemID = tonumber(itemID)
  if type(g) ~= "table" or not itemID then return nil end

  local equipLoc = type(g.itemEquipLocs) == "table" and (g.itemEquipLocs[itemID] or g.itemEquipLocs[tostring(itemID)]) or nil
  local classID = type(g.itemClassIDs) == "table" and tonumber(g.itemClassIDs[itemID] or g.itemClassIDs[tostring(itemID)] or 0) or nil
  local subClassID = type(g.itemSubClassIDs) == "table" and tonumber(g.itemSubClassIDs[itemID] or g.itemSubClassIDs[tostring(itemID)] or 0) or nil

  if (not equipLoc or equipLoc == "") and type(g.itemMetadata) == "table" then
    local meta = g.itemMetadata[itemID] or g.itemMetadata[tostring(itemID)]
    if type(meta) == "table" then
      equipLoc = equipLoc or meta.equipLoc or meta.inventoryType
      classID = classID or tonumber(meta.classID or meta.itemClassID or 0) or nil
      subClassID = subClassID or tonumber(meta.subClassID or meta.itemSubClassID or 0) or nil
    end
  end

  section = tostring(section or UI.GetGroupItemSectionFromMetadata(g, itemID) or "")
  if section == "Armor" then
    if equipLoc == "INVTYPE_HEAD" then return "Head" end
    if equipLoc == "INVTYPE_SHOULDER" then return "Shoulder" end
    if equipLoc == "INVTYPE_CHEST" or equipLoc == "INVTYPE_ROBE" then return "Chest" end
    if equipLoc == "INVTYPE_WRIST" then return "Wrist" end
    if equipLoc == "INVTYPE_HAND" then return "Hands" end
    if equipLoc == "INVTYPE_WAIST" then return "Waist" end
    if equipLoc == "INVTYPE_LEGS" then return "Legs" end
    if equipLoc == "INVTYPE_FEET" then return "Feet" end
    if equipLoc == "INVTYPE_CLOAK" then return "Back" end
    if equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then return "Off-hand" end
    return "Other"
  end

  if section == "Weapons" then
    if equipLoc == "INVTYPE_HOLDABLE" then return "Off-hand" end
    if equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" then
      if classID == 2 and subClassID == 19 then return "Wand" end
      return "Ranged"
    end
    if equipLoc == "INVTYPE_2HWEAPON" then
      if classID == 2 and subClassID == 10 then return "Staff" end
      if classID == 2 and subClassID == 6 then return "Polearm" end
      return "2H"
    end
    if equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
      if classID == 2 and subClassID == 15 then return "Dagger" end
      if classID == 2 and subClassID == 13 then return "Fist" end
      return "1H"
    end
    return "Other"
  end

  return nil
end

CL_IsCoreLootItemID = function(itemID, itemLink)
  if not itemID then return true end

  do
    local gid = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
    local g = gid and ns and ns.Data and ns.Data.groups and ns.Data.groups[gid] or nil
    local metaSection = UI.GetGroupItemSectionFromMetadata and UI.GetGroupItemSectionFromMetadata(g, itemID) or nil
    if metaSection and metaSection ~= "Misc" then return true end
  end

  if ns and ns.CompletionMountItemDB and ns.CompletionMountItemDB.Get and ns.CompletionMountItemDB.Get(itemID) then return true end
  if ns and ns.CompletionRaidMounts and ns.CompletionRaidMounts.IsExplicitRaidMountItem and ns.CompletionRaidMounts.IsExplicitRaidMountItem(itemID) then return true end
  if ns and ns.CompletionPetItemDB and ns.CompletionPetItemDB.Get and ns.CompletionPetItemDB.Get(itemID) then return true end
  if ns and ns.CompletionToyItemDB and ns.CompletionToyItemDB.Get and ns.CompletionToyItemDB.Get(itemID) then return true end
  if ns and ns.CompletionHousingItemDB and ns.CompletionHousingItemDB.Get and ns.CompletionHousingItemDB.Get(itemID) then return true end

  -- Collection Log is collectables-only for raid/dungeon loot.
  -- Keep an item only if it resolves to one of our canonical collectible classes:
  -- mount, pet, toy, housing decor, or a generated/datapack appearance mapping.

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


function UI.RefreshGrid()
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Overview" then
    if UI.ShowOverview then UI.ShowOverview(true) end
    if UI.ShowHistory then UI.ShowHistory(false) end
    return
  end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "History" then
    if UI.ShowOverview then UI.ShowOverview(false) end
    if UI.ShowHistory then UI.ShowHistory(true) end
    return
  end
  if UI.ShowWishlist then UI.ShowWishlist(false) end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Wishlist" then
    if UI.ShowOverview then UI.ShowOverview(false) end
    if UI.ShowHistory then UI.ShowHistory(false) end
    if UI.ShowWishlist then UI.ShowWishlist(true) end
    return
  end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Appearances" then
    if UI.ShowOverview then UI.ShowOverview(false) end
    if UI.ShowHistory then UI.ShowHistory(false) end
    if UI.pager then UI.pager:Hide() end
    if UI.pagerPrev then UI.pagerPrev:Hide() end
    if UI.pagerNext then UI.pagerNext:Hide() end
    if UI.pagerText then UI.pagerText:Hide() end
    if UI.pagerShowing then UI.pagerShowing:Hide() end
    local groupId = CollectionLogDB.ui.activeGroupId
    local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId] or nil
    if UI.mapPin then UI.mapPin:Hide() end
    if UI.lockIcon then UI.lockIcon:Hide() end
    if not g or not g.setID then
      UI.groupName:SetText("Select a set")
      if UI.groupCount then UI.groupCount:SetText("") end
      SetProgressBar(0, 0)
      if UI.completionCount then UI.completionCount:Hide() end
      for i = 1, UI.maxCells do UI.cells[i]:Hide() end
      if UI.sectionHeaders then
        for i = 1, (UI.maxSectionHeaders or 0) do UI.sectionHeaders[i]:Hide() end
      end
      if UI.BuildDifficultyDropdown then UI.BuildDifficultyDropdown() end
      return
    end

    UI.groupName:SetText(g.name or ("Set " .. tostring(g.setID)))
    if UI.completionCount then UI.completionCount:Hide() end
    if UI.BuildDifficultyDropdown then UI.BuildDifficultyDropdown() end

    local entries = {}
    if ns and ns.GetAppearanceSetEntries then
      entries = (ns.GetAppearanceSetEntries(g.setID)) or {}
    end

    if UI.sectionHeaders then
      for i = 1, (UI.maxSectionHeaders or 0) do UI.sectionHeaders[i]:Hide() end
    end

    local count = #entries
    EnsureCells(math.max(count, 1))
    EnsureSectionHeaders(6)
    EnsureSubSectionHeaders(24)

    local armorOrder = ARMOR_SUB_ORDER or { "Head", "Shoulder", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Back" }
    local weaponOrder = WEAPON_SUB_ORDER or { "Main Hand", "1H", "2H", "Dagger", "Polearm", "Staff", "Fist", "Wand", "Ranged", "Off-hand" }

    local function appearanceSubCategory(entry)
      local slot = tonumber(entry and entry.slot or 0) or 0
      local itemID = tonumber(entry and entry.itemID or 0) or 0
      if slot ~= 16 and slot ~= 17 then
        return (entry and entry.label) or AR.SLOT_LABELS[slot] or "Other"
      end
      if slot == 17 then
        return "Off-hand"
      end
      if itemID > 0 then
        return CL_GetWeaponSubCategory(itemID) or entry.label or "Main Hand"
      end
      return entry and entry.label or "Main Hand"
    end

    local bySub = {}
    for _, entry in ipairs(entries) do
      local sub = appearanceSubCategory(entry)
      bySub[sub] = bySub[sub] or {}
      bySub[sub][#bySub[sub] + 1] = entry
    end

    local function appearanceEntrySortName(entry)
      if type(entry) ~= "table" then return "" end
      local itemID = tonumber(entry.itemID or 0) or 0
      local rawName = entry.name or entry.displayName or entry.itemName or entry.label
      if (not rawName or rawName == "") and itemID > 0 and GetItemInfo then
        rawName = GetItemInfo(itemID)
      end
      return UI.CLOG_NormalizeSortText(rawName or "")
    end

    for _, subItems in pairs(bySub) do
      table.sort(subItems, function(a, b)
        local aName = appearanceEntrySortName(a)
        local bName = appearanceEntrySortName(b)
        if aName ~= bName then
          if aName == "" then return false end
          if bName == "" then return true end
          return aName < bName
        end
        return (tonumber(a and a.itemID or 0) or 0) < (tonumber(b and b.itemID or 0) or 0)
      end)
    end

    local subDisplayOrder = {}
    for _, sub in ipairs(armorOrder) do subDisplayOrder[#subDisplayOrder + 1] = sub end
    for _, sub in ipairs(weaponOrder) do subDisplayOrder[#subDisplayOrder + 1] = sub end

    local used = 0
    local usedHeaders = 0
    local usedSubHeaders = 0
    local gridWidth = math.max((UI.grid:GetWidth() or 620) - 10, 300)
    local x = 10
    local y = -24
    local rowGap = 3
    local sectionGap = 6
    local labelGap = 1
    local contentW = math.max(gridWidth - 4, 220)

    local function placeMajorHeader(text)
      usedHeaders = usedHeaders + 1
      local h = UI.sectionHeaders[usedHeaders]
      if not h then return end
      h:ClearAllPoints()
      h:SetPoint("TOPLEFT", UI.grid, "TOPLEFT", x, y)
      h:SetPoint("TOPRIGHT", UI.grid, "TOPRIGHT", -10, y)
      h.text:SetText(text)
      h:Show()
      y = y - 20
    end

    local function estimateSubWidth(text, list)
      local labelW = math.max(28, ((#tostring(text or "")) * 6) + 10)
      local iconCount = math.max(1, #list)
      local iconRowW = math.max(ICON, (iconCount * ICON) + ((iconCount - 1) * 3))
      return math.max(labelW, iconRowW, ICON + 10)
    end

    local function styleAppearanceCell(cell, entry)
      cell.icon:SetTexture((cell.itemID and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(cell.itemID)) or 134400)
      cell.countText:SetText("")
      ApplyCollectionIconState(cell.icon, entry.isCollected)
      cell._clogCachedCollected = entry.isCollected and true or false
      cell:SetAlpha(1)
      if cell.slotLabel then cell.slotLabel:Hide() end
      ApplyCellCollectedVisual(cell, entry.isCollected and true or false)
    end

    local function placeSubBand(rowInfos)
      local cursorX = x
      local cursorY = y
      local rowHeight = 0
      local labelBaseline = 14
      local itemsOffset = 18
      local blockGap = 14

      for _, rowInfo in ipairs(rowInfos) do
        local list = rowInfo.items or {}
        local labelW = math.max(34, ((#tostring(rowInfo.name or "")) * 6) + 8)
        local iconCount = math.max(1, #list)
        local iconRowW = (iconCount * ICON) + ((iconCount - 1) * 3)
        local blockW = math.max(labelW, iconRowW) + 8
        local blockH = itemsOffset + ICON

        if cursorX > x and (cursorX + blockW) > (x + contentW) then
          cursorX = x
          cursorY = cursorY - rowHeight - rowGap
          rowHeight = 0
        end

        usedSubHeaders = usedSubHeaders + 1
        local h = UI.subSectionHeaders[usedSubHeaders]
        if h then
          h:ClearAllPoints()
          h:SetPoint("TOPLEFT", UI.grid, "TOPLEFT", cursorX, cursorY)
          h:SetPoint("TOPRIGHT", UI.grid, "TOPLEFT", cursorX + blockW - 4, cursorY)
          h.text:SetJustifyH("LEFT")
          h.text:SetText(rowInfo.name)
          h:Show()
        end

        local itemsY = cursorY - itemsOffset
        for idx, entry in ipairs(list) do
          local i = used + 1
          local cell = UI.cells[i]
          used = i
          cell:Show()
          cell:ClearAllPoints()
          local cellX = cursorX + ((idx - 1) * (ICON + 3))
          local cellY = itemsY
          cell:SetPoint("TOPLEFT", UI.grid, "TOPLEFT", cellX, cellY)
          Wishlist.ClearWishlistIdentity(cell)
          cell.groupId = groupId
          cell.itemID = tonumber(entry.itemID)
          cell.appearanceEntry = entry
          local wishlistKey, wishlistPayload = Wishlist.BuildPayloadFromCell(cell)
          Wishlist.AssignWishlistIdentity(cell, wishlistKey, wishlistPayload)
          styleAppearanceCell(cell, entry)
        end

        rowHeight = math.max(rowHeight, blockH)
        cursorX = cursorX + blockW + blockGap
      end

      y = cursorY - rowHeight - sectionGap
    end

    local armorSubs = {}
    local weaponSubs = {}
    local extraSubs = {}
    local weaponSet = {}
    for _, sub in ipairs(weaponOrder) do weaponSet[sub] = true end
    for _, sub in ipairs(subDisplayOrder) do
      local subItems = bySub[sub]
      if subItems and #subItems > 0 then
        if weaponSet[sub] or sub == "Off-hand" then
          weaponSubs[#weaponSubs + 1] = { name = sub, items = subItems }
        else
          armorSubs[#armorSubs + 1] = { name = sub, items = subItems }
        end
        bySub[sub] = nil
      end
    end
    for sub, subItems in pairs(bySub) do
      if subItems and #subItems > 0 then
        if weaponSet[sub] then
          weaponSubs[#weaponSubs + 1] = { name = sub, items = subItems }
        else
          extraSubs[#extraSubs + 1] = { name = sub, items = subItems }
        end
      end
    end
    table.sort(extraSubs, function(a,b) return tostring(a.name) < tostring(b.name) end)

    if #weaponSubs > 0 then
      placeMajorHeader("Weapons")
      placeSubBand(weaponSubs)
    end
    if #armorSubs > 0 or #extraSubs > 0 then
      placeMajorHeader("Armor")
      local allArmor = {}
      for _, rowInfo in ipairs(armorSubs) do allArmor[#allArmor + 1] = rowInfo end
      for _, rowInfo in ipairs(extraSubs) do allArmor[#allArmor + 1] = rowInfo end
      placeSubBand(allArmor)
    end

    local visibleCount, visibleCollected = used, 0
    for i = 1, used do
      local cell = UI.cells[i]
      if cell and cell.appearanceEntry and cell.appearanceEntry.isCollected then
        visibleCollected = visibleCollected + 1
      end
    end

    if UI.groupCount then
      local color
      if visibleCount == 0 then
        color = "FF808080"
      elseif visibleCollected == 0 then
        color = "FFFF2020"
      elseif visibleCollected >= visibleCount then
        color = "FF20FF20"
      else
        color = "FFFFD100"
      end
      UI.groupCount:SetText(("Collected: |c%s%d/%d|r"):format(color, visibleCollected, visibleCount))
    end
    SetProgressBar(visibleCollected, visibleCount)

    for i = used + 1, UI.maxCells do
      if UI.cells[i] then
        UI.cells[i]:Hide()
        if UI.cells[i].slotLabel then UI.cells[i].slotLabel:Hide() end
      end
    end
    if UI.sectionHeaders then
      for i = usedHeaders + 1, (UI.maxSectionHeaders or 0) do UI.sectionHeaders[i]:Hide() end
    end
    if UI.subSectionHeaders then
      for i = usedSubHeaders + 1, (UI.maxSubSectionHeaders or 0) do UI.subSectionHeaders[i]:Hide() end
    end
    local height = math.max(160, math.abs(y) + 16)
    UI.grid:SetSize(UI.grid:GetWidth() or 620, height)
    if UI.UpdateScrollAffordances and C_Timer and C_Timer.After then C_Timer.After(0, function() UI.UpdateScrollAffordances() end) end
    return
  end
  local groupId = CollectionLogDB.ui.activeGroupId
  local g = groupId and ns.Data.groups[groupId] or nil

  if not g then
    UI.groupName:SetText("Select an entry")
    if UI.groupCount then UI.groupCount:SetText("") end
    -- Hide progress bar when nothing is selected.
    SetProgressBar(0, 0)
    for i = 1, UI.maxCells do UI.cells[i]:Hide() end
    if UI.sectionHeaders then
      for i = 1, (UI.maxSectionHeaders or 0) do
        UI.sectionHeaders[i]:Hide()
      end
    end
    return
  end

  UI.groupName:SetText(g.name or g.id)
  for i = 1, (UI.maxCells or 0) do
    local cell = UI.cells and UI.cells[i]
    if cell and cell.slotLabel then cell.slotLabel:Hide() end
  end

  
-- Map pin + lock icon: show for Raids/Dungeons when a group is selected (even if we don't have entrance data).
do
  local pin = UI.mapPin
  local lockIcon = UI.lockIcon
  if pin then
    local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
    if (activeCat == "Raids" or activeCat == "Dungeons") and g and g.instanceID then
      pin:ClearAllPoints()
      pin:SetPoint("LEFT", UI.groupName, "RIGHT", 4.5, 0)
      pin:Show()
      do
        local resolvedEntrance = Wishlist.ResolveJournalEntrance(g.instanceID)
        local uiMapID, x, y = Wishlist.TryConvertJournalEntranceToWaypoint(resolvedEntrance)
        CLOG_ApplyWaypointButtonState(pin, (uiMapID and x and y) and true or false)
      end

      if lockIcon then
        lockIcon:ClearAllPoints()
        -- Match the same padding used between title->mapPin
        -- Anchor lock to the *left edge of the dropdown text box* (not the arrow button).
        -- UIDropDownMenuTemplate has wide decorative textures; the dropdown frame's LEFT is not the
        -- visual border. We anchor to the Left texture and compensate by using its RIGHT edge,
        -- which aligns with the start of the stretch region (i.e. the visible left border zone).
        local dd = UI.diffDropdown
        local ddLeft = (dd and dd.GetName and _G[dd:GetName().."Left"]) or nil
        if ddLeft then
          lockIcon:ClearAllPoints()
          -- UIDropDownMenuTemplate's left cap texture includes hidden padding.
          -- Nudge right so the lock hugs the *visible* border.
          lockIcon:SetPoint("RIGHT", ddLeft, "LEFT", 12, 1) -- 12 = (-2 gap) + ~14px inset compensation
        elseif dd then
          lockIcon:ClearAllPoints()
          lockIcon:SetPoint("RIGHT", dd, "LEFT", -2, 1)
        end

          do local h=(UI.diffDropdown:GetHeight() or 24); if h<18 then h=18 elseif h>21 then h=21 end; lockIcon:SetSize(h,h) end
        local diffID = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.lastDifficultyByInstance and CollectionLogDB.ui.lastDifficultyByInstance[g.instanceID]) or g.difficultyID
          local locked, reset = CL_GetSavedLockout(g.instanceID, g.name or (UI.groupName and UI.groupName:GetText()), diffID)
        

        -- Tooltip context
        lockIcon._clInstanceID = g.instanceID
        lockIcon._clInstanceName = g.name or (UI.groupName and UI.groupName:GetText())
        lockIcon._clDifficultyID = diffID
-- Visual states:
--   Bright lock + red X   = locked
--   Bright lock + green âœ“ = not locked
lockIcon:SetAlpha(1.00)
if locked then
  local resetStr = CL_FormatResetSeconds(reset)
  lockIcon._lockResetText = resetStr
  if lockIcon._clMarkX then lockIcon._clMarkX:Show() end
  if lockIcon._clMarkCheck then lockIcon._clMarkCheck:Hide() end
  lockIcon:Show()
else
  lockIcon._lockResetText = nil
  if lockIcon._clMarkCheck then lockIcon._clMarkCheck:Show() end
  if lockIcon._clMarkX then lockIcon._clMarkX:Hide() end
  lockIcon:Show()
end
      end
    else
      pin._clHasWaypoint = false
      pin:Hide()
      if lockIcon then
        lockIcon._lockResetText = nil
        lockIcon:Hide()
      end
    end
  end
end


  -- OSRS-style collected counter for the selected entry
  if UI.groupCount then
    local isMounts = (g and g.mounts and g.category == "Mounts")
    local isPets = (g and g.pets and g.category == "Pets")
    local isToys = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Toys")
    local activeCat = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory) or nil
    local isHousing = (activeCat == "Housing")
    local isInstItems = (activeCat == "Raids" or activeCat == "Dungeons")
    local hideNC = true

    -- Total may be filtered (optional) for instance item grids.
    local total
    local collectedCount = 0

    -- Housing:
    --  * For "All Housing" we use the non-blocking scan cache to avoid a hitch.
    --  * For smaller Housing sub-groups (HomeBound-style categories), compute counts
    --    from the scan cache per-item so the header reflects the selected group.
    if isHousing then
      local gid = groupId and tostring(groupId) or ""
      if gid == "housing:all" and UI and UI.GetHousingProgressCached then
        local c, t = UI.GetHousingProgressCached()
        collectedCount = c or 0
        total = t or 0
      else
        total = #(g.items or {})
        collectedCount = 0
        if UI and UI.HousingIsCollectedCached then
          -- Ensure the background scan has started so per-item cache fills in.
          if UI.GetHousingProgressCached then UI.GetHousingProgressCached() end
          for _, itemID in ipairs(g.items or {}) do
            if UI.HousingIsCollectedCached(itemID) then
              collectedCount = collectedCount + 1
            else
              -- If this item hasn't been scanned yet, fall back to a direct check.
              -- These groups are intentionally small, so this stays snappy.
              if ns and ns.IsHousingCollected then
                local ok, res = pcall(ns.IsHousingCollected, itemID)
                if ok and res then collectedCount = collectedCount + 1 end
              end
            end
          end
        end
      end
    else
      if (not isMounts) and (not isPets) and (not isToys) and isInstItems and hideNC then
        total = 0
        for _, itemID in ipairs(CL_GetVisibleGroupList(g)) do
          if CL_IsCoreLootItemID(itemID) then
            total = total + 1
          end
        end
      else
        local visibleItems = CL_GetVisibleGroupList(g)
        total = #visibleItems
      end

      local viewMode = CollectionLogDB.ui.viewMode
      local guid = CollectionLogDB.ui.activeCharacterGUID

      if isMounts then
        for _, mountID in ipairs(CL_GetVisibleGroupList(g)) do
          local _, isCollected = CL_GetMountIconCollected(mountID)
          if isCollected then collectedCount = collectedCount + 1 end
        end
      elseif isPets then
        for _, speciesID in ipairs(CL_GetVisibleGroupList(g)) do
          local _, isCollected = CL_GetPetIconCollected(speciesID)
          if isCollected then collectedCount = collectedCount + 1 end
        end
      else
        for _, itemID in ipairs(CL_GetVisibleGroupList(g)) do
          if (not isToys) and isInstItems and hideNC and (not CL_IsCoreLootItemID(itemID)) then
            -- Hidden by settings (non-core loot)
          else
            if isToys then
              local hasToy = (ns.IsToyCollected and ns.IsToyCollected(itemID)) or false
              if hasToy then
                collectedCount = collectedCount + 1
              end
            else
              local recCount = ns.GetRecordedCount(itemID, viewMode, guid)
              local blizzCollected = (ns.IsCollected and ns.IsCollected(itemID)) or false
              if (recCount and recCount > 0) or blizzCollected then
                collectedCount = collectedCount + 1
              end
            end
          end
        end
      end
    end


    collectedCount, total = CLog_ResolveDisplayedGroupTotals(g, collectedCount, total)

    local color
    if total == 0 then
      color = "FF808080" -- gray
    elseif collectedCount == 0 then
      color = "FFFF2020" -- red
    elseif collectedCount >= total then
      color = "FF20FF20" -- green
    else
      color = "FFFFD100" -- yellow
    end

    UI.groupCount:SetText(("Collected: |c%s%d/%d|r"):format(color, collectedCount, total))

    -- Cache completion so left-list coloring matches header/grid truth (and doesn't depend on scan timing).
    do
      local gidKey = groupId and tostring(groupId) or nil
      UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
      local leftListCollected, leftListTotal = collectedCount, total
      local usingBackendRowColor = false
      do
        local backendCollected, backendTotal = CLog_GetRaidAggregateBackendTotals(g)
        if backendTotal and backendTotal > 0 then
          leftListCollected, leftListTotal = backendCollected, backendTotal
          usingBackendRowColor = true
        end
      end
      local canTrust = true
      if (not usingBackendRowColor) and CLog_IsRaidDungeonGroup(g) and ns and ns.AreCollectionResolversWarm and not ns.AreCollectionResolversWarm() then
        canTrust = false
      end
      if gidKey then
        UI._clogLeftListColorCache[gidKey] = CLOG_MakeLeftListCacheEntry(leftListCollected, leftListTotal, canTrust, "active_header")
        if CLOG_InvalidateDifficultyIndicatorForGroup then CLOG_InvalidateDifficultyIndicatorForGroup(gidKey) end
        if CLOG_ScheduleDifficultyIndicatorRepaintForGroup then CLOG_ScheduleDifficultyIndicatorRepaintForGroup(gidKey) end
      end

        -- Persist hard truth so list paints instantly on next login.
        if canTrust and CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
          CollectionLogDB.ui.leftListColorCache.cache[gidKey] = CLOG_MakeLeftListCacheEntry(leftListCollected, leftListTotal, true, "active_header")
          if CollectionLogDB.ui.leftListColorCache.meta then
            CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
          end
        end
      UI._clogLeftListTruthLock = UI._clogLeftListTruthLock or {}
      if gidKey and canTrust then
        UI._clogLeftListTruthLock[gidKey] = true
        if UI._clogLeftListColorQueue then UI._clogLeftListColorQueue[gidKey] = nil end
      elseif gidKey and UI._clogLeftListColorQueue then
        UI._clogLeftListColorQueue[gidKey] = true
      end
      CLog_ApplyLeftListTextColor(groupId, true)
    end

    -- Instance completion counter (OSRS-style) completions: primary line is always account-wide,
    -- with a hover tooltip showing the current character's count for the same instance/difficulty.
    if UI.completionCount and g and g.instanceID and g.category and (g.category == "Raids" or g.category == "Dungeons") then
      local diffLabel = DifficultyLongLabel(g.difficultyID, g.mode)
      -- For the completion line only, strip the abbreviated suffix like ""
      diffLabel = tostring(diffLabel or ""):gsub("%s%(%u+%)%s*$", "")
      local accountCount = 0
      local characterCount = 0
      local instanceCandidates = {}
      do
        local seen = {}
        local function add(v)
          v = tonumber(v)
          if v and v > 0 and not seen[v] then
            seen[v] = true
            instanceCandidates[#instanceCandidates + 1] = v
          end
        end
        add(g.instanceID)
        add(g.mapID)
      end
      if ns and ns.GetBestInstanceCompletionCount then
        accountCount = ns.GetBestInstanceCompletionCount(instanceCandidates, g.difficultyID, "ACCOUNT") or 0
        characterCount = ns.GetBestInstanceCompletionCount(instanceCandidates, g.difficultyID, "CHARACTER") or 0
      elseif ns and ns.GetInstanceCompletionCount then
        accountCount = ns.GetInstanceCompletionCount(g.instanceID, g.difficultyID, "ACCOUNT") or 0
        characterCount = ns.GetInstanceCompletionCount(g.instanceID, g.difficultyID, "CHARACTER") or 0
        if (accountCount == 0 and characterCount == 0) and tonumber(g.mapID) and tonumber(g.mapID) ~= tonumber(g.instanceID) then
          accountCount = ns.GetInstanceCompletionCount(g.mapID, g.difficultyID, "ACCOUNT") or 0
          characterCount = ns.GetInstanceCompletionCount(g.mapID, g.difficultyID, "CHARACTER") or 0
        end
      end
      UI.completionCount:SetText(("%s (%s) completions: %d"):format(g.name or "Instance", diffLabel, accountCount))
      UI.completionCount._clogTooltipText = ("Completions (this character): %d"):format(characterCount)
      UI.completionCount:Show()
    elseif UI.completionCount then
      UI.completionCount:SetText("")
      UI.completionCount._clogTooltipText = nil
      UI.completionCount:Hide()
      GameTooltip_Hide()
    end

    SetProgressBar(collectedCount, total)
  end

  -- Difficulty dropdown
  if UI.BuildDifficultyDropdown then UI.BuildDifficultyDropdown() end


  local search = (CollectionLogDB.ui.search or ""):lower():match("^%s*(.-)%s*$")
  local isMounts = (g and g.mounts and g.category == "Mounts")
  local isPets = (g and g.pets and g.category == "Pets")
  local isToys = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Toys")
  local isHousing = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Housing")
  local isRaids = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Raids")
  local isDungeons = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Dungeons")

  -- First-paint safety for curated raid collectibles. If a group was cached
  -- before the static mount/pet metadata was augmented, the first click could
  -- render the ordinary loot table and only show Mounts/Pets after a second
  -- click. Make the active group deterministic before reading the visible list.
  if (isRaids or isDungeons) and g and ns and ns.AugmentRaidDungeonGroupCollectibles then
    local okAugment, changed = pcall(ns.AugmentRaidDungeonGroupCollectibles, g)
    if okAugment and changed then
      if CLOG_VISIBLE_GROUP_LIST_CACHE and g.id then
        CLOG_VISIBLE_GROUP_LIST_CACHE[tostring(g.category or "") .. ":" .. tostring(g.id)] = nil
      end
      if ns.ClearFastItemSectionCache then pcall(ns.ClearFastItemSectionCache) end
      if ns.RaidDungeonMeta and ns.RaidDungeonMeta.ClearCache then pcall(ns.RaidDungeonMeta.ClearCache, "active_group_augmented") end
      if ns.Registry and ns.Registry.ClearCache then pcall(ns.Registry.ClearCache, "active_group_augmented") end
    end
  end

  local items = CL_GetVisibleGroupList(g)

  -- Manual grouping overrides (Toys / Housing):
  -- If a user sets a Primary Source, the item is treated as belonging ONLY to that Source group
  -- (plus any "Also Show In" extra tags). This is display-only; it never infers collection.
  if isToys and g and g.id and type(g.id) == "string" and g.id:match("^toys:source:") and g.name then
    local out = {}
    local seen = {}
    -- Base membership, filtered by overrides
    for _, itemID in ipairs(items or {}) do
      if itemID then
        local primary = GetToyPrimary and GetToyPrimary(itemID) or nil
        if primary then
          if primary == g.name or (HasToyExtra and HasToyExtra(itemID, g.name)) then
            out[#out+1] = itemID
            seen[itemID] = true
          end
        else
          out[#out+1] = itemID
          seen[itemID] = true
        end
      end
    end
    -- Add any override-tagged toys that aren't in the base list
    local uo = (CollectionLogDB and CollectionLogDB.userOverrides and CollectionLogDB.userOverrides.toys) or nil
    if uo then
      if uo.primary then
        for k, v in pairs(uo.primary) do
          if v == g.name then
            local itemID = tonumber(k)
            if itemID and not seen[itemID] then
              out[#out+1] = itemID
              seen[itemID] = true
            end
          end
        end
      end
      if uo.extra then
        for k, t in pairs(uo.extra) do
          if t and t[g.name] then
            local itemID = tonumber(k)
            if itemID and not seen[itemID] then
              out[#out+1] = itemID
              seen[itemID] = true
            end
          end
        end
      end
    end
    items = out
  end

  if isHousing and g and g.expansion == "Source" and g.name then
    local out = {}
    local seen = {}
    for _, itemID in ipairs(items or {}) do
      if itemID then
        local primary = GetHousingPrimary and GetHousingPrimary(itemID) or nil
        if primary then
          if primary == g.name or (HasHousingExtra and HasHousingExtra(itemID, g.name)) then
            out[#out+1] = itemID
            seen[itemID] = true
          end
        else
          out[#out+1] = itemID
          seen[itemID] = true
        end
      end
    end
    local uo = (CollectionLogDB and CollectionLogDB.userOverrides and CollectionLogDB.userOverrides.housing) or nil
    if uo then
      if uo.primary then
        for k, v in pairs(uo.primary) do
          if v == g.name then
            local itemID = tonumber(k)
            if itemID and not seen[itemID] then
              out[#out+1] = itemID
              seen[itemID] = true
            end
          end
        end
      end
      if uo.extra then
        for k, t in pairs(uo.extra) do
          if t and t[g.name] then
            local itemID = tonumber(k)
            if itemID and not seen[itemID] then
              out[#out+1] = itemID
              seen[itemID] = true
            end
          end
        end
      end
    end
    items = out
  end



  -- Paging UX: if the search text or selected group changes, reset to page 1
  -- to avoid landing on an out-of-range/empty page.
  if CollectionLogDB and CollectionLogDB.ui then
    local activeGroupId = CollectionLogDB.ui.activeGroupId
    if isPets then
      if UI._lastPetsSearch ~= search or UI._lastPetsGroupId ~= activeGroupId then
        CollectionLogDB.ui.petsPage = 1
        UI._lastPetsSearch = search
        UI._lastPetsGroupId = activeGroupId
      end
    elseif isMounts then
      if UI._lastMountsSearch ~= search or UI._lastMountsGroupId ~= activeGroupId then
        CollectionLogDB.ui.mountsPage = 1
        UI._lastMountsSearch = search
        UI._lastMountsGroupId = activeGroupId
      end
    elseif isToys then
      if UI._lastToysSearch ~= search or UI._lastToysGroupId ~= activeGroupId then
        CollectionLogDB.ui.toysPage = 1
        UI._lastToysSearch = search
        UI._lastToysGroupId = activeGroupId
      end
    end
  end

local filtered = {}
  if search == "" then
    filtered = items
  else
    if isMounts and C_MountJournal and C_MountJournal.GetMountInfoByID then
      for _, mountID in ipairs(items) do
        local name = C_MountJournal.GetMountInfoByID(mountID)
        if name and type(name) == "string" and name:lower():find(search, 1, true) then
          filtered[#filtered+1] = mountID
        end
      end
    elseif isPets and C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
      for _, speciesID in ipairs(items) do
        local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
        if ok and name and type(name) == "string" and name:lower():find(search, 1, true) then
          filtered[#filtered+1] = speciesID
        end
      end
    else
      for _, itemID in ipairs(items) do
        local name = GetItemInfo(itemID)
        if name and name:lower():find(search, 1, true) then
          filtered[#filtered+1] = itemID
        end
      end
    end
  end

  -- Instance loot grids: optional hide jewelry/trinkets (Neck/Rings/Trinkets) for raids/dungeons.
  do
    local activeCat = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory) or nil
    local isInstItems = (activeCat == "Raids" or activeCat == "Dungeons")
    local hideNC = true
    if isInstItems and (not isMounts) and (not isPets) and (not isToys) and hideNC then
      local out = {}
      for _, itemID in ipairs(filtered) do
        if CL_IsCoreLootItemID(itemID) then
          out[#out+1] = itemID
        end
      end
      filtered = out
    end
  end




  -- Pets: optional collected/not-collected filter (UI state only, Blizzard-truthful)
  -- Defaults: show both collected and not-collected (no filtering).
  local showCollected = true
  local showNotCollected = true
  if CollectionLogDB and CollectionLogDB.ui then
    if CollectionLogDB.ui.petsShowCollected ~= nil then showCollected = CollectionLogDB.ui.petsShowCollected end
    if CollectionLogDB.ui.petsShowNotCollected ~= nil then showNotCollected = CollectionLogDB.ui.petsShowNotCollected end
  end

  if isPets and (not showCollected or not showNotCollected) and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
    local out = {}
    for _, speciesID in ipairs(filtered) do
      local ok, numCollected = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
      if ok then
        local isCollected = (type(numCollected) == "number" and numCollected > 0) or false
        if (isCollected and showCollected) or ((not isCollected) and showNotCollected) then
          out[#out+1] = speciesID
        end
      else
        -- If the API errors for any reason, do not guess. Keep it visible rather than hiding truth.
        out[#out+1] = speciesID
      end
    end
    filtered = out
  end

  -- Mounts: optional collected/not-collected filter (UI state only, Blizzard-truthful)
  -- Defaults: show both collected and not-collected (no filtering).
  local mShowCollected, mShowNotCollected = true, true
  if CollectionLogDB and CollectionLogDB.ui then
    if CollectionLogDB.ui.mountsShowCollected ~= nil then mShowCollected = CollectionLogDB.ui.mountsShowCollected end
    if CollectionLogDB.ui.mountsShowNotCollected ~= nil then mShowNotCollected = CollectionLogDB.ui.mountsShowNotCollected end
  end

  if isMounts and (not mShowCollected or not mShowNotCollected) and C_MountJournal and C_MountJournal.GetMountInfoByID then
    local out = {}
    for _, mountID in ipairs(filtered) do
      local ok, name, spellID, icon, active, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHide, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
      if ok then
        local collected = (isCollected == true)
        if (collected and mShowCollected) or ((not collected) and mShowNotCollected) then
          out[#out+1] = mountID
        end
      else
        -- If the API errors for any reason, do not guess. Keep it visible.
        out[#out+1] = mountID
      end
    end
    filtered = out
  end
-- Toys: optional collected/not-collected filter (UI state only, Blizzard-truthful)
-- Defaults: show both collected and not-collected (no filtering).
local tShowCollected, tShowNotCollected = true, true
if CollectionLogDB and CollectionLogDB.ui then
  if CollectionLogDB.ui.toysShowCollected ~= nil then tShowCollected = CollectionLogDB.ui.toysShowCollected end
  if CollectionLogDB.ui.toysShowNotCollected ~= nil then tShowNotCollected = CollectionLogDB.ui.toysShowNotCollected end
end

if isToys and (not tShowCollected or not tShowNotCollected) then
  local out = {}
  for _, itemID in ipairs(filtered) do
    local collected = ((ns and ns.IsToyCollected and ns.IsToyCollected(itemID)) and true) or false
    if (collected and tShowCollected) or ((not collected) and tShowNotCollected) then
      out[#out+1] = itemID
    end
  end
  filtered = out
end

-- Housing: optional collected/not-collected filter (UI state only, Blizzard-truthful)
-- Defaults: show both collected and not-collected (no filtering).
local hShowCollected, hShowNotCollected = true, true
if CollectionLogDB and CollectionLogDB.ui then
  if CollectionLogDB.ui.housingShowCollected ~= nil then hShowCollected = CollectionLogDB.ui.housingShowCollected end
  if CollectionLogDB.ui.housingShowNotCollected ~= nil then hShowNotCollected = CollectionLogDB.ui.housingShowNotCollected end
end

if isHousing and (not hShowCollected or not hShowNotCollected) then
  local out = {}
  for _, itemID in ipairs(filtered) do
    local collected = UI.HousingIsCollectedCached(itemID) and true or false
    if (collected and hShowCollected) or ((not collected) and hShowNotCollected) then
      out[#out+1] = itemID
    end
  end
  filtered = out
end


local w = (UI.gridScroll and UI.gridScroll:GetWidth()) or UI.grid:GetWidth() or 0
  if w < 50 then w = 600 end

  local cols = math.floor((w - (PAD * 2)) / (ICON + GAP))
  cols = Clamp(cols, 1, 14)


  -- Safety: avoid creating thousands of frames at once (Pets can be ~2000+).
  -- We keep totals truthful, but render a fixed-size page to prevent UI stalls / frame limits.
  local pageSize = nil
  if isPets then pageSize = 600 end
  if isMounts then pageSize = 800 end
  if isToys then pageSize = 800 end
  if isHousing then pageSize = 800 end

  local totalItems = (type(filtered) == "table" and #filtered) or 0
  local page = 1
  local maxPage = 1

  if pageSize and totalItems > 0 then
    maxPage = math.max(1, math.ceil(totalItems / pageSize))
    if CollectionLogDB and CollectionLogDB.ui then
      if isPets and type(CollectionLogDB.ui.petsPage) == "number" then page = CollectionLogDB.ui.petsPage end
      if isMounts and type(CollectionLogDB.ui.mountsPage) == "number" then page = CollectionLogDB.ui.mountsPage end
        if isToys and type(CollectionLogDB.ui.toysPage) == "number" then page = CollectionLogDB.ui.toysPage end
        if isHousing and type(CollectionLogDB.ui.housingPage) == "number" then page = CollectionLogDB.ui.housingPage end
    end
    if page < 1 then page = 1 end
    if page > maxPage then page = maxPage end
    if CollectionLogDB and CollectionLogDB.ui then
      if isPets then CollectionLogDB.ui.petsPage = page end
      if isMounts then CollectionLogDB.ui.mountsPage = page end
      if isToys then CollectionLogDB.ui.toysPage = page end
      if isHousing then CollectionLogDB.ui.housingPage = page end
    end
  end

  local renderList = filtered
  local startIndex, endIndex = 1, totalItems
  if pageSize and totalItems > 0 then
    startIndex = ((page - 1) * pageSize) + 1
    endIndex = math.min(startIndex + pageSize - 1, totalItems)
    if startIndex <= endIndex then
      local sliced = {}
      local j = 1
      for i = startIndex, endIndex do
        sliced[j] = renderList[i]
        j = j + 1
      end
      renderList = sliced
    else
      renderList = {}
    end
  end

  -- Update pager UI (Pets/Mounts only). Keep groupCount truthful and move "Showing" to the pager block.
  if UI and UI.UpdatePagerUI then
    UI:UpdatePagerUI(isPets, isMounts, isToys, isHousing, isRaids, page, maxPage, startIndex, endIndex, totalItems)
  end

  -- Build sections for display
local sections = {}
local order

if isMounts then
  sections["Mounts"] = renderList
  order = { "Mounts" }
elseif isPets then
  sections["Pets"] = renderList
  order = { "Pets" }
elseif isToys then
  sections["Toys"] = renderList
  order = { "Toys" }
elseif isHousing then
  -- Housing should behave like Toys/Mounts/Pets: a single flat, paginated list.
  -- IMPORTANT: use renderList (the paginated slice), not `filtered` (the full list),
  -- otherwise we can exceed the number of created grid cells and crash.
  sections["Housing"] = renderList
  order = { "Housing" }
else
  UI.CLOG_SortItemIDsByGroupName(filtered, g)
  for _, itemID in ipairs(filtered) do
    -- Use fast/deterministic section classification so the grid layout is
    -- stable on the first render (avoids the "2-click" re-layout once item
    -- info streams in).
    local sec = (UI.GetGroupItemSectionFromMetadata and UI.GetGroupItemSectionFromMetadata(g, itemID))
      or (ns.GetItemSectionFast and ns.GetItemSectionFast(itemID))
      or (ns.GetItemSection and ns.GetItemSection(itemID))
      or "Misc"
    sections[sec] = sections[sec] or {}
    table.insert(sections[sec], itemID)
  end
  order = ns.SECTION_ORDER or { "Mounts", "Weapons", "Armor", "Toys", "Misc" }
end

local nonEmptySections = 0
  for _, secName in ipairs(order) do
    if sections[secName] and #sections[secName] > 0 then
      nonEmptySections = nonEmptySections + 1
    end
  end

  EnsureCells(#renderList)
  EnsureSectionHeaders(nonEmptySections)

  local renderEntries = {}
  local buildSerial = (UI._gridBuildSerial or 0) + 1
  UI._gridBuildSerial = buildSerial

  if UI.gridScroll then
    UI.grid:SetWidth(math.max(1, UI.gridScroll:GetWidth() or 1))
  end

  -- Layout sections + icons
  local usedCells = 0
  local usedHeaders = 0
  local usedSubHeaders = 0
  local y = PAD
  local col = 0

  local gridW = (UI.gridScroll and UI.gridScroll:GetWidth()) or w
  if gridW < 1 then gridW = w end

  local function NextRow()
    y = y + (ICON + GAP)
    col = 0
  end

  local function PlaceHeader(text)
    -- If we're mid-row, advance to the next icon row first
    if col ~= 0 then
      NextRow()
    end

    usedHeaders = usedHeaders + 1
    local h = UI.sectionHeaders[usedHeaders]
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", UI.grid, "TOPLEFT", PAD, -y)
    h:SetWidth(math.max(1, gridW - (PAD * 2) - 20))
    h.text:SetText(text)
    h:Show()

    y = y + SECTION_H + SECTION_GAP
  end

  local function PlaceSubHeader(text, x, yPos, width)
    usedSubHeaders = usedSubHeaders + 1
    local h = UI.subSectionHeaders and UI.subSectionHeaders[usedSubHeaders] or nil
    if not h then return end
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", UI.grid, "TOPLEFT", x, -yPos)
    h:SetWidth(math.max(1, width or 1))
    h.text:SetText(text)
    h:Show()
  end

  local guid = CollectionLogDB.ui.activeCharacterGUID

  -- Pre-count needed subheaders so we can allocate frames.
  local neededSubHeaders = 0
  do
    for _, secName in ipairs(order) do
      local secItems = sections[secName]
      if secItems and #secItems > 0 and ((secName == "Armor" or secName == "Weapons") or (isHousing and secName == "Housing")) then
        local seen = {}
        for _, itemID in ipairs(secItems) do
          local sub
          if secName == "Housing" and isHousing then
            sub = CL_GetHousingType(itemID)
          else
            sub = (UI.GetGroupItemSubCategoryFromMetadata and UI.GetGroupItemSubCategoryFromMetadata(g, itemID, secName))
              or ((secName == "Armor") and CL_GetArmorSubCategory(itemID) or CL_GetWeaponSubCategory(itemID))
          end
          if sub then
            seen[sub] = true
          else
            seen["Other"] = true
          end
        end
        if secName == "Housing" and isHousing then
          for k in pairs(seen) do
            neededSubHeaders = neededSubHeaders + 1
          end
        else
          local subOrder = (secName == "Armor") and ARMOR_SUB_ORDER or WEAPON_SUB_ORDER
          for _, subName in ipairs(subOrder) do
            if seen[subName] then neededSubHeaders = neededSubHeaders + 1 end
          end
          if seen["Other"] then neededSubHeaders = neededSubHeaders + 1 end
        end
      end
    end
  end

  EnsureSubSectionHeaders(neededSubHeaders)

  for _, secName in ipairs(order) do
    local secItems = sections[secName]
    if secItems and #secItems > 0 then
      PlaceHeader(secName)

      -- Inline subcategory blocks for Armor/Weapons (only show subcategories that exist).
      if secName == "Armor" or secName == "Weapons" or (isHousing and secName == "Housing" and groupId ~= "housing:all") then
        local subBuckets = {}
        for _, itemID in ipairs(secItems) do
          local sub
          if secName == "Housing" and isHousing then
            sub = CL_GetHousingType(itemID)
          else
            sub = (UI.GetGroupItemSubCategoryFromMetadata and UI.GetGroupItemSubCategoryFromMetadata(g, itemID, secName))
              or ((secName == "Armor") and CL_GetArmorSubCategory(itemID) or CL_GetWeaponSubCategory(itemID))
          end
          if not sub then sub = "Other" end
          subBuckets[sub] = subBuckets[sub] or {}
          table.insert(subBuckets[sub], itemID)
        end

        for _, items in pairs(subBuckets) do
          UI.CLOG_SortItemIDsByGroupName(items, g)
        end

        local renderSubOrder = {}
        if secName == "Housing" and isHousing then
          local keys = {}
          for k, v in pairs(subBuckets) do
            if k ~= "Other" and type(v) == "table" and #v > 0 then keys[#keys+1] = k end
          end
          table.sort(keys)
          for _, k in ipairs(keys) do renderSubOrder[#renderSubOrder+1] = k end
          if subBuckets["Other"] and #subBuckets["Other"] > 0 then renderSubOrder[#renderSubOrder+1] = "Other" end
        else
          local subOrder = (secName == "Armor") and ARMOR_SUB_ORDER or WEAPON_SUB_ORDER
          for _, subName in ipairs(subOrder) do
            if subBuckets[subName] and #subBuckets[subName] > 0 then
              renderSubOrder[#renderSubOrder + 1] = subName
            end
          end
          if subBuckets["Other"] and #subBuckets["Other"] > 0 then
            renderSubOrder[#renderSubOrder + 1] = "Other"
          end
        end

        local curX = PAD
        local rowY = y
        local rowH = 0
        local maxX = PAD + (gridW - PAD)
        local capCols = math.max(1, math.min(cols, 6)) -- keep blocks compact so multiple can fit per row
        if isHousing and secName == "Housing" then
          -- Housing types look better full-width (avoid dead space from side-by-side blocks)
          capCols = cols
        end

        for _, subName in ipairs(renderSubOrder) do
          local items = subBuckets[subName] or {}
          local n = #items
          if n > 0 then
            local blockCols = math.min(n, capCols)
            local blockRows = math.ceil(n / blockCols)
            local blockW = (blockCols * (ICON + GAP)) - GAP
            local blockH = SUBSECTION_H + SUBSECTION_GAP + (blockRows * (ICON + GAP))

            if isHousing and secName == "Housing" then
              blockW = (gridW - (PAD * 2))
              curX = PAD
            end

            if curX ~= PAD and (curX + blockW) > maxX then
              rowY = rowY + rowH + SECTION_GAP
              curX = PAD
              rowH = 0
            end

            PlaceSubHeader(subName, curX, rowY, blockW)

            for i = 1, n do
              local itemID = items[i]
              usedCells = usedCells + 1
              local cellIndex = usedCells

              local c = (i - 1) % blockCols
              local r = math.floor((i - 1) / blockCols)

              local x = curX + c * (ICON + GAP)
              local yPos = rowY + SUBSECTION_H + SUBSECTION_GAP + r * (ICON + GAP)
              local activeGroupId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil

              local renderItemID = (not isMounts and not isPets) and itemID or nil
              local renderMountID = isMounts and itemID or nil
              local renderPetSpeciesID = isPets and itemID or nil

              if secName == "Mounts" and renderItemID then
                renderMountID = CL_ResolveMountIDFromItemID(renderItemID)
              elseif secName == "Pets" and renderItemID then
                renderPetSpeciesID = CL_ResolvePetSpeciesIDFromItemID(renderItemID)
              end

              renderEntries[#renderEntries + 1] = {
                idx = cellIndex,
                x = x,
                y = yPos,
                itemID = renderItemID,
                mountID = renderMountID,
                petSpeciesID = renderPetSpeciesID,
                section = secName,
                groupId = activeGroupId,
              }

              local cell = UI.cells[cellIndex]
              Wishlist.ClearWishlistIdentity(cell)
              if cell then
                cell.itemID = nil
                cell.mountID = nil
                cell.petSpeciesID = nil
                cell.appearanceEntry = nil
                cell.section = nil
                cell.groupId = nil
                cell._clogCachedCollected = nil
                cell._clogTooltipItemLink = nil
                cell._clogDropSource = nil
                cell._clogModeText = nil
                cell:Hide()
              end
            end

            if isHousing and secName == "Housing" then
              rowY = rowY + blockH + SECTION_GAP
              curX = PAD
              rowH = 0
            else
              curX = curX + blockW + BLOCK_GAP
              if blockH > rowH then rowH = blockH end
            end
          end
        end

        y = rowY + rowH
        y = y + (SECTION_GAP - 2)
        col = 0
      else
        -- Default flat grid for other sections.
        for _, itemID in ipairs(secItems) do
          usedCells = usedCells + 1
          local cellIndex = usedCells

          local x = PAD + col * (ICON + GAP)
          local yPos = y
          local activeGroupId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil

          local renderItemID = (not isMounts and not isPets) and itemID or nil
          local renderMountID = isMounts and itemID or nil
          local renderPetSpeciesID = isPets and itemID or nil

          if secName == "Mounts" and renderItemID then
            renderMountID = CL_ResolveMountIDFromItemID(renderItemID)
          elseif secName == "Pets" and renderItemID then
            renderPetSpeciesID = CL_ResolvePetSpeciesIDFromItemID(renderItemID)
          end

          renderEntries[#renderEntries + 1] = {
            idx = cellIndex,
            x = x,
            y = yPos,
            itemID = renderItemID,
            mountID = renderMountID,
            petSpeciesID = renderPetSpeciesID,
            section = secName,
            groupId = activeGroupId,
          }

          local cell = UI.cells[cellIndex]
          Wishlist.ClearWishlistIdentity(cell)
          if cell then
            cell.itemID = nil
            cell.mountID = nil
            cell.petSpeciesID = nil
            cell.appearanceEntry = nil
            cell.section = nil
            cell.groupId = nil
            cell._clogCachedCollected = nil
            cell._clogTooltipItemLink = nil
            cell._clogDropSource = nil
            cell._clogModeText = nil
            cell:Hide()
          end

          col = col + 1
          if col >= cols then
            NextRow()
          end
        end

        if col ~= 0 then
          NextRow()
        end

        y = y + (SECTION_GAP - 2)
      end
    end
  end


  -- Apply queued cell updates in batches to avoid frame hitching on large grids.
  UI._gridBuildEntries = renderEntries
  UI._gridBuildIndex = 1

  -- v4.3.71: do not request item data for every visible loot cell during normal
  -- rendering. RequestLoadItemDataByID generates item-data events, and those event
  -- bursts were feeding repeated visible refreshes while the UI was merely open.
  -- Icons use GetItemInfoInstant; deeper data can be warmed by explicit Refresh.

  local function ApplyOne(entry)
    local cell = UI.cells[entry.idx]
    if not cell then return end

    Wishlist.ClearWishlistIdentity(cell)
    cell.itemID = entry.itemID
    cell.mountID = entry.mountID
    cell.petSpeciesID = entry.petSpeciesID
    if entry.section == "Mounts" and cell.itemID and not cell.mountID then
      cell.mountID = CL_ResolveMountIDFromItemID(cell.itemID)
    elseif entry.section == "Pets" and cell.itemID and not cell.petSpeciesID then
      cell.petSpeciesID = CL_ResolvePetSpeciesIDFromItemID(cell.itemID)
    end
    cell.groupId = entry.groupId
    cell.section = entry.section

    cell:ClearAllPoints()
    cell:SetPoint("TOPLEFT", UI.grid, "TOPLEFT", entry.x, -entry.y)

    local iconFile
    local collected = false
    local recCount = 0

    if isMounts then
      iconFile, collected = CL_GetMountIconCollected(entry.mountID)
      cell.countText:SetText("")
    elseif isPets then
      iconFile, collected = CL_GetPetIconCollected(entry.petSpeciesID)
      cell.countText:SetText("")
    else
      iconFile = select(5, GetItemInfoInstant(entry.itemID))

      local trueCollected, truthState = CL_GetTrueCollectedForItem(entry.itemID, entry.groupId)
      cell._clogTruthState = truthState

      -- v4.3.42: Teaching-item sections (mounts/pets/toys/housing) must not be
      -- locked to a false negative from the new backend while legacy/static
      -- journal resolvers still know the item is collected.  Use the backend as
      -- the primary signal, but OR it with the established type-specific
      -- resolver for these sections.  Appearance/armor/weapon cells still use
      -- the strict TrueCollection result so difficulty-specific transmog stays
      -- accurate.
      if entry.section == "Mounts" then
        local legacy = (ns.IsMountCollected and ns.IsMountCollected(entry.itemID)) or false
        collected = (trueCollected == true) or legacy
        cell.countText:SetText("")
      elseif entry.section == "Pets" then
        local legacy = (ns.IsPetCollected and ns.IsPetCollected(entry.itemID)) or false
        local speciesOwned = false
        local speciesID = entry.petSpeciesID or CL_ResolvePetSpeciesIDFromItemID(entry.itemID)
        if speciesID then
          local petIcon, petCollected = CL_GetPetIconCollected(speciesID)
          speciesOwned = petCollected and true or false
          if petIcon then iconFile = petIcon end
          cell.petSpeciesID = speciesID
        end
        collected = (trueCollected == true) or speciesOwned or legacy
        cell.countText:SetText("")
      elseif isToys or entry.section == "Toys" then
        local legacy = (ns.IsToyCollected and ns.IsToyCollected(entry.itemID)) or false
        collected = (trueCollected == true) or legacy
        cell.countText:SetText("")
      elseif entry.section == "Housing" then
        local legacy = (ns.IsHousingCollected and ns.IsHousingCollected(entry.itemID)) or false
        collected = (trueCollected == true) or legacy
        cell.countText:SetText("")
      elseif trueCollected ~= nil then
        collected = trueCollected
        cell.countText:SetText("")
      elseif UI.IsRaidDungeonGridContext() and UI.IsAppearanceLootSection(entry.section) then
        -- Same guard as RefreshVisibleCollectedStateOnly: appearance rows in
        -- Raids/Dungeons are source-truth rows, so the legacy itemID-only
        -- collection helper is not allowed to saturate them.
        collected = false
        cell.countText:SetText("")
      else
        recCount = ns.GetRecordedCount(entry.itemID, CollectionLogDB.ui.viewMode, guid)
        local isCollected = (ns.IsCollected and ns.IsCollected(entry.itemID)) or false
        collected = (recCount and recCount > 0) or isCollected
        cell.countText:SetText((recCount and recCount > 0) and tostring(recCount) or "")
      end
    end

    cell._clogCachedCollected = collected
    cell._clogTooltipItemLink = CLOG_GetTooltipLinkFromTruthState(truthState)
    cell._clogDropSource = nil
    cell._clogModeText = nil

    if entry.itemID and (isRaids or (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Dungeons")) and g then
      cell._clogModeText = g.mode

      if g.itemSources then
        local dropSource = g.itemSources[entry.itemID] or g.itemSources[tostring(entry.itemID)]
        if type(dropSource) == "string" and dropSource ~= "" then
          cell._clogDropSource = dropSource
        end
      end

      if (not cell._clogTooltipItemLink) and g.itemLinks then
        local links = g.itemLinks[entry.itemID] or g.itemLinks[tostring(entry.itemID)]
        if type(links) == "string" and links ~= "" then
          cell._clogTooltipItemLink = links
        elseif type(links) == "table" then
          for _, L in ipairs(links) do
            if type(L) == "string" and L ~= "" then cell._clogTooltipItemLink = L; break end
          end
          if not cell._clogTooltipItemLink then
            for _, L in pairs(links) do
              if type(L) == "string" and L ~= "" then cell._clogTooltipItemLink = L; break end
            end
          end
        end
      end
    end

    local wishlistKey, wishlistPayload = Wishlist.BuildPayloadFromCell(cell)
    Wishlist.AssignWishlistIdentity(cell, wishlistKey, wishlistPayload)
    cell.icon:SetTexture(iconFile or "Interface/Icons/INV_Misc_QuestionMark")
    DesaturateIf(cell.icon, not collected)
    ApplyCellCollectedVisual(cell, collected and true or false)
    -- Final paint authority: after texture, wishlist visuals, and any legacy
    -- fallback handling, force the actual icon artwork from the resolved cell
    -- truth. This prevents old itemID-only paths from leaving saturated artwork
    -- while the header/count says the row is uncollected.
    if cell.icon then DesaturateIf(cell.icon, not collected) end
    cell:Show()
  end

  local function ProcessBatch()
    if UI._gridBuildSerial ~= buildSerial then return end
    local entries = UI._gridBuildEntries or {}
    local i = UI._gridBuildIndex or 1
    local n = #entries
    if i > n then return end

    -- Time-budgeted batching: apply up to CLOG_BUILD_BATCH entries, but also
    -- stop early if we've used up our frame budget (keeps the game snappy on
    -- huge loot tables).
    local start = GetTime and GetTime() or 0
    local budget = 0.008 -- ~8ms per frame max
    local applied = 0

    while i <= n and applied < CLOG_BUILD_BATCH do
      ApplyOne(entries[i])
      i = i + 1
      applied = applied + 1
      if GetTime and (GetTime() - start) > budget then
        break
      end
    end

    UI._gridBuildIndex = i
    if i <= n then
      C_Timer.After(0, ProcessBatch)
    end
  end

  if #renderEntries > 0 then
    ProcessBatch()
  end

  -- v4.3.71: no automatic post-render collected refresh passes. A normal grid
  -- render should paint from current cache and stop. Explicit Refresh and actual
  -- collection events are the only places allowed to advance truth.

  local totalH = y + PAD
  UI.grid:SetHeight(math.max(totalH, UI.gridScroll:GetHeight() or 1))

  -- Hide unused cells
  for i = usedCells + 1, UI.maxCells do
    UI.cells[i].itemID = nil
    UI.cells[i].mountID = nil
    UI.cells[i].petSpeciesID = nil
    UI.cells[i].appearanceEntry = nil
    UI.cells[i].section = nil
    UI.cells[i].groupId = nil
    UI.cells[i]._clogCachedCollected = nil
    UI.cells[i]._clogTooltipItemLink = nil
    UI.cells[i]._clogDropSource = nil
    UI.cells[i]._clogModeText = nil
    UI.cells[i]:Hide()
  end

  -- Hide unused headers
  if UI.sectionHeaders then
    for i = usedHeaders + 1, (UI.maxSectionHeaders or 0) do
      UI.sectionHeaders[i]:Hide()
    end
  end

  -- Hide unused subheaders
  if UI.subSectionHeaders then
    for i = usedSubHeaders + 1, (UI.maxSubSectionHeaders or 0) do
      UI.subSectionHeaders[i]:Hide()
    end
  end

  -- v4.3.72: RefreshGrid is often called directly from row clicks/difficulty
  -- changes, not only through RefreshAll. Re-check scroll affordances after the
  -- new scroll child height has propagated so wheel/bar state cannot get stuck.
  if UI.UpdateScrollAffordances and C_Timer and C_Timer.After then
    C_Timer.After(0, function() UI.UpdateScrollAffordances() end)
    C_Timer.After(0.05, function() UI.UpdateScrollAffordances() end)
  end
end

UI.BuildGroupList = BuildGroupList

function UI.RefreshAll()
  if not UI.frame then return end

  -- Do not wipe the expensive left-list/grid helper caches on every RefreshAll.
  -- RefreshAll is called repeatedly by tab switches, delayed visible-state passes,
  -- and some UI bookkeeping; wiping these caches every time defeated the CPU fix
  -- and forced full sidebar/count/difficulty rebuilds again.
  if CLOG_ClearRefreshScopedCachesIfNeeded then
    CLOG_ClearRefreshScopedCachesIfNeeded(false)
  end

  if UI._clogPendingHiddenCollectionEvent then
    UI._clogPendingHiddenCollectionEvent = nil
    if CLOG_ResetTrueStatusCache then pcall(CLOG_ResetTrueStatusCache) end
    if CLOG_ResetAggregateDifficultyTotalsCache then pcall(CLOG_ResetAggregateDifficultyTotalsCache) end
    if CLOG_ResetDifficultyIndicatorCache then pcall(CLOG_ResetDifficultyIndicatorCache) end
    if UI.ClearVisibleGroupListCache then pcall(UI.ClearVisibleGroupListCache) end
    if ns and ns.CompletionV2 and ns.CompletionV2.ClearStatusCacheOnly then
      pcall(ns.CompletionV2.ClearStatusCacheOnly, "hidden_collection_event")
    end
    if UI._clogMountCache then UI._clogMountCache = {} end
    if UI._clogPetCache then UI._clogPetCache = {} end
  end

  -- v4.3.71: normal UI open/tab selection is display-only.
  -- Do not prime collection resolvers or warm broad caches here. Those passes are
  -- reserved for explicit Refresh or true collection events, otherwise simply
  -- opening Collection Log keeps CPU climbing while the player is idle.

  local cat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil

  local deferGrid = UI._clogDeferNextGridRefresh and (cat == "Raids" or cat == "Dungeons") and C_Timer and C_Timer.After
  UI._clogDeferNextGridRefresh = nil

  if deferGrid then
    if ns and ns.Perf and ns.Perf.Measure then
      ns.Perf.Measure("UI.RefreshAll.phase.BuildGroupList", BuildGroupList)
    else
      BuildGroupList()
    end

    UI._clogDeferredGridSerial = (UI._clogDeferredGridSerial or 0) + 1
    local serial = UI._clogDeferredGridSerial
    local expectedCat = cat
    C_Timer.After(0, function()
      if UI._clogDeferredGridSerial ~= serial then return end
      if not (UI.frame and UI.frame.IsShown and UI.frame:IsShown()) then return end
      local currentCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
      if currentCat ~= expectedCat then return end
      if ns and ns.Perf and ns.Perf.Measure then
        ns.Perf.Measure("UI.RefreshAll.phase.RefreshGrid.deferred", UI.RefreshGrid)
      else
        UI.RefreshGrid()
      end
    end)
  elseif ns and ns.Perf and ns.Perf.Measure then
    ns.Perf.Measure("UI.RefreshAll.phase.BuildGroupList", BuildGroupList)
    ns.Perf.Measure("UI.RefreshAll.phase.RefreshGrid", UI.RefreshGrid)
  else
    BuildGroupList()
    UI.RefreshGrid()
  end

  if UI.UpdateScrollAffordances and C_Timer and C_Timer.After then
    C_Timer.After(0, function() UI.UpdateScrollAffordances() end)
  end
end

-- ============
-- Window init
-- ============
local function CLOG_GetWindowResizeBounds(frame)
  local minW, minH = 760, 500
  local parent = frame and frame:GetParent() or UIParent
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or (frame and frame.GetScale and frame:GetScale()) or 1
  if not scale or scale <= 0 then scale = 1 end

  local screenW = (parent and parent.GetWidth and parent:GetWidth()) or (UIParent and UIParent:GetWidth()) or 1600
  local screenH = (parent and parent.GetHeight and parent:GetHeight()) or (UIParent and UIParent:GetHeight()) or 1000
  local maxW = math.floor((screenW / scale) - 24)
  local maxH = math.floor((screenH / scale) - 24)
  if maxW < minW then maxW = minW end
  if maxH < minH then maxH = minH end
  return minW, minH, maxW, maxH
end

local function CLOG_ApplyWindowResizeBounds(frame)
  if not frame then return end
  local minW, minH, maxW, maxH = CLOG_GetWindowResizeBounds(frame)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(minW, minH, maxW, maxH)
  else
    if frame.SetMinResize then frame:SetMinResize(minW, minH) end
    if frame.SetMaxResize then frame:SetMaxResize(maxW, maxH) end
  end
  local w = frame:GetWidth() or minW
  local h = frame:GetHeight() or minH
  local changed = false
  if w > maxW then w = maxW changed = true end
  if h > maxH then h = maxH changed = true end
  if w < minW then w = minW changed = true end
  if h < minH then h = minH changed = true end
  if changed then frame:SetSize(w, h) end
  if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end
end
local function CLOG_GetCursorInFrameUnits(frame)
  local x, y = GetCursorPosition()
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale()) or 1
  if not scale or scale <= 0 then scale = 1 end
  return (x or 0) / scale, (y or 0) / scale
end

local function CLOG_SaveWindowSize(frame)
  if not frame then return end
  EnsureUIState()
  CollectionLogDB.ui.w = math.floor((frame:GetWidth() or 980) + 0.5)
  CollectionLogDB.ui.h = math.floor((frame:GetHeight() or 640) + 0.5)
end

local function CLOG_StopWindowResize(frame)
  if not frame then return end
  frame._clogResizeDrag = nil
  frame:SetScript("OnUpdate", nil)
  CLOG_ApplyWindowResizeBounds(frame)
  CLOG_SaveWindowSize(frame)
end

local function CLOG_StartWindowResize(frame)
  if not frame then return end
  if frame.StopMovingOrSizing then frame:StopMovingOrSizing() end
  if frame.Raise then frame:Raise() end
  CLOG_ApplyWindowResizeBounds(frame)

  local cursorX, cursorY = CLOG_GetCursorInFrameUnits(frame)
  local minW, minH, maxW, maxH = CLOG_GetWindowResizeBounds(frame)
  frame._clogResizeDrag = {
    cursorX = cursorX,
    cursorY = cursorY,
    startW = frame:GetWidth() or 980,
    startH = frame:GetHeight() or 640,
    minW = minW,
    minH = minH,
    maxW = maxW,
    maxH = maxH,
  }

  frame:SetScript("OnUpdate", function(self)
    local drag = self._clogResizeDrag
    if not drag then return end
    local x, y = CLOG_GetCursorInFrameUnits(self)
    local newW = drag.startW + (x - drag.cursorX)
    local newH = drag.startH - (y - drag.cursorY)
    if newW < drag.minW then newW = drag.minW end
    if newH < drag.minH then newH = drag.minH end
    if newW > drag.maxW then newW = drag.maxW end
    if newH > drag.maxH then newH = drag.maxH end
    self:SetSize(newW, newH)
  end)
end


function UI.Init()
  if UI.frame then return end

  EnsureUIState()
  local db = CollectionLogDB.ui

  local f = CreateFrame("Frame", "CollectionLogFrame", UIParent, "BackdropTemplate")
  UI.frame = f
  f:SetSize(db.w, db.h)
  f:SetScale(db.scale or 1.0)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetClampedToScreen(true)
  if f.SetResizable then f:SetResizable(true) end
  CLOG_ApplyWindowResizeBounds(f)
  CreateBorder(f)

  -- Bottom-right resize grip. This changes the actual window dimensions, unlike
  -- the scale slider, and saves the new size in SavedVariables.
  local resizeGrip = CreateFrame("Button", nil, f)
  UI.resizeGrip = resizeGrip
  resizeGrip:SetSize(18, 18)
  resizeGrip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
  resizeGrip:SetFrameLevel((f:GetFrameLevel() or 0) + 20)
  resizeGrip:EnableMouse(true)
  local rgTex = resizeGrip:CreateTexture(nil, "OVERLAY")
  rgTex:SetAllPoints(resizeGrip)
  rgTex:SetTexture("Interface\\CHATFRAME\\UI-ChatIM-SizeGrabber-Up")
  rgTex:SetVertexColor(1, 0.86, 0.25, 0.85)
  resizeGrip:SetHighlightTexture("Interface\\CHATFRAME\\UI-ChatIM-SizeGrabber-Highlight")
  resizeGrip:SetPushedTexture("Interface\\CHATFRAME\\UI-ChatIM-SizeGrabber-Down")
  resizeGrip:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    CLOG_StartWindowResize(f)
  end)
  resizeGrip:SetScript("OnMouseUp", function()
    CLOG_StopWindowResize(f)
    if UI.RefreshAll then UI.RefreshAll() end
  end)
  resizeGrip:SetScript("OnHide", function()
    CLOG_StopWindowResize(f)
  end)
  resizeGrip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Resize Collection Log", 1, 0.86, 0.25)
    GameTooltip:AddLine("Drag to make the window wider, thinner, taller, or shorter.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  resizeGrip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f:SetScript("OnSizeChanged", function(self)
    CLOG_SaveWindowSize(self)
  end)

  -- Keep the main window in normal strata so it can overlap like a standard UI
  -- window without permanently sitting above the rest of the interface.
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)


  f:SetScript("OnMouseDown", function(self)
    if self.Raise then self:Raise() end
  end)

  f:SetScript("OnDragStart", function(self)
    if self.Raise then self:Raise() end
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, _, x, y = self:GetPoint(1)
    CollectionLogDB.ui.point = point or "CENTER"
    CollectionLogDB.ui.x = x or 0
    CollectionLogDB.ui.y = y or 0
  end)

  f:SetPoint(db.point or "CENTER", UIParent, db.point or "CENTER", db.x or 0, db.y or 0)
  f:Hide()

  -- Allow Escape to close the main window (Blizzard-standard behavior).
  if type(UISpecialFrames) == "table" then
    local exists = false
    for i = 1, #UISpecialFrames do
      if UISpecialFrames[i] == "CollectionLogFrame" then
        exists = true
        break
      end
    end
    if not exists then
      table.insert(UISpecialFrames, "CollectionLogFrame")
    end
  end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  UI.title = title
  title:SetPoint("TOP", f, "TOP", 0, -6)
  title:SetText("Collection Log")

    -- Settings (minimal): icon top-left above the tab row.
  -- Controls Loot pop-up options.
  local settingsBtn = CreateFrame("Button", nil, f)
  UI.settingsBtn = settingsBtn
  settingsBtn:SetSize(18, 18)
  settingsBtn:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 2, -8)
  -- Keep the cog above this window's content, but never above unrelated UI.
  settingsBtn:SetFrameLevel((f:GetFrameLevel() or 0) + 8)
  settingsBtn:EnableMouse(true)

  local gearTex = settingsBtn:CreateTexture(nil, "OVERLAY")
  gearTex:SetAllPoints(settingsBtn)
  gearTex:SetTexture("Interface\\Cursor\\Crosshair\\Interact.blp")
  gearTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  gearTex:SetVertexColor(1, 1, 1, 0.90)

  local gearHL = settingsBtn:CreateTexture(nil, "HIGHLIGHT")
  gearHL:SetAllPoints(settingsBtn)
  gearHL:SetTexture("Interface\\Cursor\\Crosshair\\Interact.blp")
  gearHL:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  gearHL:SetVertexColor(1, 1, 1, 1.0)
  gearHL:SetBlendMode("ADD")

  settingsBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Settings", 1, 1, 1)
    GameTooltip:AddLine("Loot pop-up options", 0.9, 0.9, 0.9)
    GameTooltip:Show()
  end)
  settingsBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  -- Anchor dropdown to our window so it inherits correct layering/visibility.
  local settingsDD = CreateFrame("Frame", "CollectionLogSettingsDropDown", f, "UIDropDownMenuTemplate")
  UI.settingsDD = settingsDD

  local function EnsureSettingsDB()
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.settings = CollectionLogDB.settings or {}

    -- Optional: suppress non-core loot notifications entirely (popup + Latest).
    -- Applies only to item-based events with a resolvable itemID.
    if CollectionLogDB.settings.suppressNonCoreLootPopup == true then
      if type(meta) == "table" and meta.itemID and (not CL_IsCoreLootItemID(meta.itemID, meta.itemLink)) then
        return
      end
    end


    if CollectionLogDB.settings.showLootPopup == nil then CollectionLogDB.settings.showLootPopup = true end
    if CollectionLogDB.settings.onlyNewLootPopup == nil then CollectionLogDB.settings.onlyNewLootPopup = true end
    if CollectionLogDB.settings.popupPosMode == nil then CollectionLogDB.settings.popupPosMode = "default" end

    -- Loot popup settings
    if CollectionLogDB.settings.showLootPopup == nil then
      CollectionLogDB.settings.showLootPopup = true
    end
    if CollectionLogDB.settings.onlyNewLootPopup == nil then
      -- Default ON (matches OSRS-style intent and current behavior)
      CollectionLogDB.settings.onlyNewLootPopup = true
    end

    -- Loot popup sound defaults
    if CollectionLogDB.settings.lootPopupSoundKey == nil then
      CollectionLogDB.settings.lootPopupSoundKey = "CL_COMPLETED"
    end
    if CollectionLogDB.settings.lootPopupSoundChannel == nil then
      -- "SFX" (default WoW behavior) or "Master" (louder, ignores SFX slider)
      CollectionLogDB.settings.lootPopupSoundChannel = "Master"
    end

    -- Popup positioning
    if CollectionLogDB.settings.popupPosMode == nil then
      -- "default" | "topleft" | "topright" | "bottomleft" | "bottomright" | "center" | "custom"
      CollectionLogDB.settings.popupPosMode = "default"
    end
    if CollectionLogDB.settings.popupPoint == nil then
      CollectionLogDB.settings.popupPoint = "TOP"
    end
    if CollectionLogDB.settings.popupX == nil then
      CollectionLogDB.settings.popupX = 0
    end
    if CollectionLogDB.settings.popupY == nil then
      CollectionLogDB.settings.popupY = -180
    end
    if CollectionLogDB.settings.wishlistTrackerUnlock == nil then
      CollectionLogDB.settings.wishlistTrackerUnlock = false
    end
    if CollectionLogDB.settings.wishlistTrackerOpacity == nil then
      if CollectionLogDB.settings.wishlistTrackerTransparent == nil then
        CollectionLogDB.settings.wishlistTrackerOpacity = 35
      elseif CollectionLogDB.settings.wishlistTrackerTransparent ~= false then
        CollectionLogDB.settings.wishlistTrackerOpacity = 35
      else
        CollectionLogDB.settings.wishlistTrackerOpacity = 80
      end
    end
    if CollectionLogDB.settings.wishlistTrackerPoint == nil then
      CollectionLogDB.settings.wishlistTrackerPoint = nil
    end
    if CollectionLogDB.settings.wishlistTrackerRelativePoint == nil then
      CollectionLogDB.settings.wishlistTrackerRelativePoint = nil
    end
    if CollectionLogDB.settings.wishlistTrackerX == nil then
      CollectionLogDB.settings.wishlistTrackerX = nil
    end
    if CollectionLogDB.settings.wishlistTrackerY == nil then
      CollectionLogDB.settings.wishlistTrackerY = nil
    end
    if CollectionLogDB.settings.enableWishlistObjectiveTracker == nil then
      CollectionLogDB.settings.enableWishlistObjectiveTracker = true
    end
    if CollectionLogDB.settings.hideUnobtainable == nil then
      CollectionLogDB.settings.hideUnobtainable = false
    end
    if CollectionLogDB.settings.appearanceCollectionMode == nil then
      CollectionLogDB.settings.appearanceCollectionMode = "shared"
    end

    -- Instance item grid filtering (optional)
    CollectionLogDB.settings.hideNonCoreLootGrids = true
    CollectionLogDB.settings.suppressNonCoreLootPopup = true
  end

  local DONATE_URL = "https://ko-fi.com/zoinkzz"

  local function CLOG_GetWishlistTrackerOpacity()
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.settings = CollectionLogDB.settings or {}
    local opacity = tonumber(CollectionLogDB.settings.wishlistTrackerOpacity)
    if opacity == nil then opacity = 35 end
    if opacity < 0 then opacity = 0 end
    if opacity > 100 then opacity = 100 end
    return opacity
  end

  local function CLOG_HideWishlistTrackerOpacitySlider()
    if UI and UI.wishlistTrackerOpacityFrame then
      UI.wishlistTrackerOpacityFrame:Hide()
    end
  end

  local function CLOG_ShowWishlistTrackerOpacitySlider(anchor)
    if not UI then return end
    EnsureSettingsDB()

    local panel = UI.wishlistTrackerOpacityFrame
    if not panel then
      panel = CreateFrame("Frame", "CollectionLogWishlistTrackerOpacityFrame", UIParent, "BackdropTemplate")
      UI.wishlistTrackerOpacityFrame = panel
      panel:SetSize(220, 86)
      panel:SetFrameStrata("DIALOG")
      panel:SetClampedToScreen(true)
      panel:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
      })
      panel:SetBackdropColor(0.03, 0.03, 0.03, 0.96)
      panel:SetBackdropBorderColor(1, 1, 1, 0.10)
      panel:EnableMouse(true)

      panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -10)
      panel.title:SetText("Wishlist tracker opacity")
      panel.title:SetTextColor(1, 0.82, 0, 1)

      panel.valueText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      panel.valueText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
      panel.valueText:SetJustifyH("RIGHT")

      local slider = CreateFrame("Slider", "CollectionLogWishlistTrackerOpacitySlider", panel, "OptionsSliderTemplate")
      panel.slider = slider
      slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -32)
      slider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -32)
      slider:SetMinMaxValues(0, 100)
      slider:SetValueStep(1)
      slider:SetObeyStepOnDrag(true)
      slider.Low:SetText("0%")
      slider.High:SetText("100%")
      slider.Text:SetText("")
      slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor((tonumber(value) or 0) + 0.5)
        CollectionLogDB.settings.wishlistTrackerOpacity = value
        panel.valueText:SetText(value .. "%")
        if CLOG_ApplyCollectionTrackerSettings then CLOG_ApplyCollectionTrackerSettings() end
      end)

      panel.close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
      panel.close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    end

    panel:ClearAllPoints()
    if anchor and anchor:IsShown() then
      panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    elseif UI.settingsBtn and UI.settingsBtn:IsShown() then
      panel:SetPoint("TOPLEFT", UI.settingsBtn, "BOTTOMLEFT", 0, -8)
    else
      panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    local opacity = CLOG_GetWishlistTrackerOpacity()
    panel.slider:SetValue(opacity)
    panel.valueText:SetText(opacity .. "%")
    panel:Show()
  end

  local function OpenDonatePopup()
    if UI and UI.donatePopup then
      UI.donatePopup:Show()
      if UI.donatePopup.editBox then
        UI.donatePopup.editBox:SetFocus()
        UI.donatePopup.editBox:HighlightText()
      end
      return
    end

    local popup = CreateFrame("Frame", "CollectionLogDonatePopup", UIParent, "BackdropTemplate")
    UI.donatePopup = popup
    popup:SetSize(440, 170)
    popup:SetPoint("CENTER")
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", function(self) self:StartMoving() end)
    popup:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    if popup.SetClampedToScreen then popup:SetClampedToScreen(true) end
    if popup.SetBackdrop then
      popup:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
      })
      popup:SetBackdropColor(0, 0, 0, 0.95)
    end

    local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", popup, "TOP", 0, -16)
    title:SetText("Support Collection Log")

    local body = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", popup, "TOPLEFT", 22, -48)
    body:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -22, -48)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetText("WoW addons cannot open external links directly. Copy the link below and paste it into your browser if you'd like to support the addon.")

    local editBox = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
    popup.editBox = editBox
    editBox:SetSize(360, 32)
    editBox:SetPoint("TOP", body, "BOTTOM", 0, -18)
    editBox:SetAutoFocus(false)
    editBox:SetTextInsets(8, 8, 0, 0)
    editBox:SetText(DONATE_URL)
    editBox:SetCursorPosition(0)
    editBox:SetScript("OnEscapePressed", function(self)
      self:ClearFocus()
      if popup then popup:Hide() end
    end)
    editBox:SetScript("OnEditFocusGained", function(self)
      self:HighlightText()
    end)
    editBox:SetScript("OnMouseUp", function(self)
      self:SetFocus()
      self:HighlightText()
    end)

    local copyBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    copyBtn:SetSize(90, 24)
    copyBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 24, 20)
    copyBtn:SetText("Highlight")
    copyBtn:SetScript("OnClick", function()
      editBox:SetFocus()
      editBox:HighlightText()
    end)

    local closeBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    closeBtn:SetSize(90, 24)
    closeBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -24, 20)
    closeBtn:SetText(CLOSE or "Close")
    closeBtn:SetScript("OnClick", function()
      popup:Hide()
    end)

    local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", popup, "BOTTOM", 0, 26)
    hint:SetPoint("LEFT", copyBtn, "RIGHT", 8, 0)
    hint:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    hint:SetJustifyH("CENTER")
    hint:SetText("Press Ctrl+C after highlighting.")

    local x = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
    x:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -4, -4)

    popup:Show()
    editBox:SetFocus()
    editBox:HighlightText()
  end

  local function SettingsMenuInit(self, level, menuList)
    EnsureSettingsDB()
    local which = menuList or UIDROPDOWNMENU_MENU_LIST or UIDROPDOWNMENU_MENU_VALUE

    -- Level 1: top menu
    if level == 1 then
      local info

      -- UI scale submenu (unchanged)
      info = UIDropDownMenu_CreateInfo()
      info.text = "UI Scale"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "ui_scale"
      info.menuList = "ui_scale"
      UIDropDownMenu_AddButton(info, level)

      -- Minimap button submenu
      info = UIDropDownMenu_CreateInfo()
      info.text = "Minimap button"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "minimap_button"
      info.menuList = "minimap_button"
      UIDropDownMenu_AddButton(info, level)

      -- Pop-up notification submenu
      info = UIDropDownMenu_CreateInfo()
      info.text = "Pop-up notification"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "popup_notification"
      info.menuList = "popup_notification"
      UIDropDownMenu_AddButton(info, level)

      -- Appearance collection mode submenu
      info = UIDropDownMenu_CreateInfo()
      info.text = "Appearance collection mode"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "appearance_collection_mode"
      info.menuList = "appearance_collection_mode"
      UIDropDownMenu_AddButton(info, level)

      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Enable Wishlist objective tracker"
      info.checked = not (CollectionLogDB.settings.enableWishlistObjectiveTracker == false)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.enableWishlistObjectiveTracker = not (CollectionLogDB.settings.enableWishlistObjectiveTracker == false)
        if CLOG_RefreshCollectionTracker then CLOG_RefreshCollectionTracker() end
      end
      UIDropDownMenu_AddButton(info, level)

      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Hide unobtainable collectibles you do not own"
      info.tooltipTitle = "Hide unobtainable collectibles you do not own"
      info.tooltipText = "Conservative filter: hides only unobtainable collectibles that you do not own. Already-collected unobtainable collectibles stay visible and continue counting. In this build that currently applies to retired mounts, including retired mount items shown in raid and dungeon loot."
      info.checked = (CollectionLogDB.settings.hideUnobtainable == true)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.hideUnobtainable = not (CollectionLogDB.settings.hideUnobtainable == true)
        if UI and UI.ClearCategoryRowCountCache then pcall(UI.ClearCategoryRowCountCache) end
        if UI and UI.ClearVisibleGroupListCache then pcall(UI.ClearVisibleGroupListCache) end
        if UI and UI.RequestOverviewRebuild then pcall(UI.RequestOverviewRebuild, "hide_unobtainable", true) end
        if BuildGroupList then BuildGroupList() end
        if UI and UI.RefreshGrid then UI.RefreshGrid() end
      end
      UIDropDownMenu_AddButton(info, level)

      info = UIDropDownMenu_CreateInfo()
      info.text = "Donate"
      info.notCheckable = true
      info.func = function()
        OpenDonatePopup()
      end
      UIDropDownMenu_AddButton(info, level)

      return
    end

    -- Level 2: UI scale submenu (percentage submenu, unchanged)
    if level == 2 and which == "ui_scale" then
      EnsureUIState()
      local function SetScale(val)
        EnsureUIState()
        CollectionLogDB.ui.scale = val
        if UI and UI.frame then
          UI.frame:SetScale(val or 1.0)
        end
      end

      local scales = {
        { label = "50%",  value = 0.50 },
        { label = "60%",  value = 0.60 },
        { label = "70%",  value = 0.70 },
        { label = "80%",  value = 0.80 },
        { label = "90%",  value = 0.90 },
        { label = "100%", value = 1.00 },
        { label = "110%", value = 1.10 },
        { label = "120%", value = 1.20 },
        { label = "130%", value = 1.30 },
        { label = "140%", value = 1.40 },
        { label = "150%", value = 1.50 },
      }

      for _, s in ipairs(scales) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = s.label
        info.func = function() SetScale(s.value) end
        info.checked = (math.abs((CollectionLogDB.ui.scale or 1.0) - s.value) < 0.001)
        info.keepShownOnClick = false
        UIDropDownMenu_AddButton(info, level)
      end

      return
    end


    -- Level 2: Appearance collection mode submenu
    if level == 2 and which == "appearance_collection_mode" then
      EnsureSettingsDB()
      local function SetAppearanceMode(mode)
        EnsureSettingsDB()
        CollectionLogDB.settings.appearanceCollectionMode = mode
        if ns and ns.ClearAppearanceCaches then pcall(ns.ClearAppearanceCaches) end
        if ns and ns.Truth and ns.Truth.ClearCache then pcall(ns.Truth.ClearCache, "appearance_mode") end
        if ns and ns.CompletionV2 and ns.CompletionV2.ClearStatusCacheOnly then pcall(ns.CompletionV2.ClearStatusCacheOnly, "appearance_mode") end
        if UI then
          UI._clogCollectedStateGen = (tonumber(UI._clogCollectedStateGen or 0) or 0) + 1
          if UI.ClearTooltipAnalysisCaches then pcall(UI.ClearTooltipAnalysisCaches, "appearance_mode") end
        end
        if UI and UI.RequestOverviewRebuild then pcall(UI.RequestOverviewRebuild, "appearance_mode", true) end
        if BuildGroupList then BuildGroupList() end
        if UI and UI.RefreshGrid then UI.RefreshGrid() end
      end

      local info = UIDropDownMenu_CreateInfo()
      info.text = "Shared appearance collected"
      info.tooltipTitle = "Shared appearance collected"
      info.tooltipText = "Counts an appearance as collected when Blizzard says the appearance is known, even if it came from another item/source. This is the default behavior."
      info.checked = ((CollectionLogDB.settings.appearanceCollectionMode or "shared") == "shared")
      info.func = function() SetAppearanceMode("shared") end
      UIDropDownMenu_AddButton(info, level)

      info = UIDropDownMenu_CreateInfo()
      info.text = "Exact item/source collected"
      info.tooltipTitle = "Exact item/source collected"
      info.tooltipText = "Only counts an appearance item as collected when Blizzard says this exact transmog source is collected. Shared appearances from another source will no longer fully count."
      info.checked = (CollectionLogDB.settings.appearanceCollectionMode == "strict")
      info.func = function() SetAppearanceMode("strict") end
      UIDropDownMenu_AddButton(info, level)
      return
    end

    -- Level 2: Minimap button submenu
    if level == 2 and which == "minimap_button" then
      local info

      -- Show/Hide minimap button
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Show minimap button"
      info.checked = not (CollectionLogDB.minimapButton and CollectionLogDB.minimapButton.hide)
      info.func = function()
        CollectionLogDB.minimapButton = CollectionLogDB.minimapButton or {}
        CollectionLogDB.minimapButton.hide = not (CollectionLogDB.minimapButton.hide == true)
        if CollectionLogDB.minimapButton.hide then
          if ns.MinimapButton_Hide then ns.MinimapButton_Hide() end
        else
          if ns.MinimapButton_Show then ns.MinimapButton_Show() end
        end
      end
      UIDropDownMenu_AddButton(info, level)

      -- Reset minimap button position
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = false
      info.notCheckable = true
      info.text = "Reset minimap button position"
      info.func = function()
        CollectionLogDB.minimapButton = CollectionLogDB.minimapButton or {}
        CollectionLogDB.minimapButton.minimapPos = 220
        if ns.MinimapButton_Reset then ns.MinimapButton_Reset() end
      end
      UIDropDownMenu_AddButton(info, level)

      return
    end

    -- Level 2: Pop-up notification submenu
    if level == 2 and which == "popup_notification" then
      local info

      -- Show loot pop-up
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Show loot pop-up"
      info.checked = (CollectionLogDB.settings.showLootPopup ~= false)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.showLootPopup = not (CollectionLogDB.settings.showLootPopup ~= false)
      end
      UIDropDownMenu_AddButton(info, level)

      -- Only show pop-up for new collections
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Only show pop-up for new collections"
      info.checked = (CollectionLogDB.settings.onlyNewLootPopup == true)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.onlyNewLootPopup = not (CollectionLogDB.settings.onlyNewLootPopup == true)
      end
      UIDropDownMenu_AddButton(info, level)

      -- Mute pop-up sound
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Mute pop-up sound"
      info.checked = (CollectionLogDB.settings.muteLootPopupSound == true)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.muteLootPopupSound = not (CollectionLogDB.settings.muteLootPopupSound == true)
      end
      UIDropDownMenu_AddButton(info, level)

      -- Play pop-up sound on master channel
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Play pop-up sound on master channel"
      info.checked = ((CollectionLogDB.settings.lootPopupSoundChannel or "SFX") == "Master")
      info.func = function()
        EnsureSettingsDB()
        if (CollectionLogDB.settings.lootPopupSoundChannel or "SFX") == "Master" then
          CollectionLogDB.settings.lootPopupSoundChannel = "SFX"
        else
          CollectionLogDB.settings.lootPopupSoundChannel = "Master"
        end
      end
      UIDropDownMenu_AddButton(info, level)

      -- Pop-up sound submenu
      info = UIDropDownMenu_CreateInfo()
      info.text = "Pop-up sound"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "popup_sound"
      info.menuList = "popup_sound"
      UIDropDownMenu_AddButton(info, level)

      -- Pop-up position submenu (keep as-is)
      info = UIDropDownMenu_CreateInfo()
      info.text = "Pop-up position"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "popup_position"
      info.menuList = "popup_position"
      UIDropDownMenu_AddButton(info, level)

      -- Preview pop-up
      info = UIDropDownMenu_CreateInfo()
      info.text = "Preview pop-up"
      info.notCheckable = true
      info.func = function()
        if ns and ns.ShowNewCollectionPopup then
          ns.ShowNewCollectionPopup("Preview: New Collection!", nil, "Preview", { type = "item", isNew = true, preview = true })
        end
      end
      UIDropDownMenu_AddButton(info, level)

      -- Reset pop-up position
      info = UIDropDownMenu_CreateInfo()
      info.text = "Reset pop-up position"
      info.notCheckable = true
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.popupPosMode = "default"
        CollectionLogDB.settings.popupPoint = "TOP"
        CollectionLogDB.settings.popupX = 0
        CollectionLogDB.settings.popupY = -180
        if ns and ns.ApplyLootPopupPosition then
          ns.ApplyLootPopupPosition()
        end
      end
      UIDropDownMenu_AddButton(info, level)

      return
    end

-- Level 3: pop-up sound submenu
    if level == 3 and which == "popup_sound" then
      EnsureSettingsDB()
      local function AddSound(label, key)
        local info = UIDropDownMenu_CreateInfo()
        info.text = label
        info.checked = ((CollectionLogDB.settings.lootPopupSoundKey or "DEFAULT") == key)
        info.func = function()
          EnsureSettingsDB()
          CollectionLogDB.settings.lootPopupSoundKey = key
        end
        UIDropDownMenu_AddButton(info, level)
      end

      AddSound("C Engineer", "CL_COMPLETED")
      AddSound("Artifact Forge Unlock", "DEFAULT")

      -- Test selected sound (ignores mute setting)
      local info = UIDropDownMenu_CreateInfo()
      info.text = "Test selected sound"
      info.notCheckable = true
      info.func = function()
        EnsureSettingsDB()
        local key = CollectionLogDB.settings.lootPopupSoundKey or "DEFAULT"
        local path
        if key == "CL_COMPLETED" then
          path = "Interface\\AddOns\\CollectionLog\\Media\\collection-log-completed.ogg"
        else
          path = "Interface\\AddOns\\CollectionLog\\Media\\ui_70_artifact_forge_trait_unlock.ogg"
        end
        if type(PlaySoundFile) == "function" then
          PlaySoundFile(path, (CollectionLogDB.settings.lootPopupSoundChannel or "SFX"))
        end
      end
      UIDropDownMenu_AddButton(info, level)

      return
    end

    -- Level 3: pop-up position submenu
    if level == 3 and which == "popup_position" then
      local function AddPos(text, mode)
        local info = UIDropDownMenu_CreateInfo()
        info.text = text
        info.checked = (CollectionLogDB.settings.popupPosMode == mode)
        info.func = function()
          EnsureSettingsDB()
          CollectionLogDB.settings.popupPosMode = mode
          if mode ~= "custom" then
            -- Apply preset immediately
            if ns and ns.ApplyLootPopupPosition then
              ns.ApplyLootPopupPosition()
            end
          else
            -- Custom: prompt user to preview + drag
            if ns and ns.ApplyLootPopupPosition then
              ns.ApplyLootPopupPosition()
            end
            if ns and ns.ShowNewCollectionPopup then
              ns.ShowNewCollectionPopup("Drag me where you want", nil, "Preview", { type = "item", isNew = true, preview = true })
            end
          end
        end
        UIDropDownMenu_AddButton(info, level)
      end

      AddPos("Default (top)", "default")
      AddPos("Top-left", "topleft")
      AddPos("Top-right", "topright")
      AddPos("Bottom-left", "bottomleft")
      AddPos("Bottom-right", "bottomright")
      AddPos("Center", "center")
      AddPos("Custom (drag)", "custom")
      return
    end
  end

  UIDropDownMenu_Initialize(settingsDD, SettingsMenuInit, "MENU")

  UI.OpenSettingsMenu = function(anchor)
    EnsureSettingsDB()
    ToggleDropDownMenu(1, nil, settingsDD, anchor or UI.settingsBtn, 0, 0)
  end


  settingsBtn:SetScript("OnClick", function(self)
    EnsureSettingsDB()
    ToggleDropDownMenu(1, nil, settingsDD, self, 0, 0)
  end)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
  close:SetScale(0.85)
  -- IMPORTANT: Do not elevate strata above the parent frame. Some minimap-button collectors
  -- open their own high-strata frames; if we force a higher strata here, the close button can
  -- bleed above those collector frames even when the main window does not.
  do
    local fl = f:GetFrameLevel() or 1
    close:SetFrameLevel(fl + 2)
  end

  UI.tabs = {}
  local tabsHolder = CreateFrame("Frame", nil, f)
  UI.tabsHolder = tabsHolder
  tabsHolder:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TOPBAR_H))
  tabsHolder:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(TOPBAR_H))
  tabsHolder:SetHeight(TAB_H)
  local function SetActiveCategory(cat)
    CollectionLogDB.ui.activeCategory = cat
    if cat == "Mounts" and ns and ns.EnsureMountsGroups then
      pcall(ns.EnsureMountsGroups)
    end
    if cat == "Pets" and ns and ns.EnsurePetsGroups then
      pcall(ns.EnsurePetsGroups)
    end
    if cat == "Toys" and ns and ns.EnsureToysGroups then
      pcall(ns.EnsureToysGroups)
    end
    if cat == "Housing" and ns and ns.BuildHousingCatalogFromBlizzard then
      ns.HousingCatalog = ns.HousingCatalog or {}
      if ns.HousingCatalog.needsLazyBuild and not ns.HousingCatalog.built and not ns.HousingCatalog.building then
        ns.HousingCatalog.needsLazyBuild = nil
        pcall(ns.BuildHousingCatalogFromBlizzard, false)
      end
    end

    -- Show/hide category-specific filters in the EXACT same header position
    -- used by the Raids/Dungeons Difficulty dropdown.
    if UI.petsFilterDD then
      if cat == "Pets" then
        UI.petsFilterDD:Show()
        if UI.BuildPetsFilterDropdown then UI.BuildPetsFilterDropdown() end
      else
        UI.petsFilterDD:Hide()
      end
    end
    if UI.mountsFilterDD then
      if cat == "Mounts" then
        UI.mountsFilterDD:Show()
        if UI.BuildMountsFilterDropdown then UI.BuildMountsFilterDropdown() end
      else
        UI.mountsFilterDD:Hide()
      end
    end
    if UI.toysFilterDD then
      if cat == "Toys" then
        UI.toysFilterDD:Show()
        if UI.BuildToysFilterDropdown then UI.BuildToysFilterDropdown() end
      else
        UI.toysFilterDD:Hide()
      end
    end

    if UI.housingFilterDD then
      if cat == "Housing" then
        UI.housingFilterDD:Show()
        if UI.BuildHousingFilterDropdown then UI.BuildHousingFilterDropdown() end
      else
        UI.housingFilterDD:Hide()
      end
    end

    if UI.appearanceClassFilterDD then
      if cat == "Appearances" then
        UI.appearanceClassFilterDD:Show()
        if UI.BuildAppearanceClassDropdown then UI.BuildAppearanceClassDropdown() end
      else
        UI.appearanceClassFilterDD:Hide()
      end
    end


local list = ns.Data.groupsByCategory[cat] or {}
    -- Force default selection on tab switch.
    -- Toys and Mounts should always default to their top "All" rows instead of
    -- inheriting the first visible expansion/source bucket.
    if cat == "Toys" then
      CollectionLogDB.ui._forceDefaultGroup = false
      CollectionLogDB.ui.activeGroupId = "toys:all"
    elseif cat == "Mounts" then
      CollectionLogDB.ui._forceDefaultGroup = false
      CollectionLogDB.ui.activeGroupId = "mounts:all"
    elseif cat == "Wishlist" then
      CollectionLogDB.ui._forceDefaultGroup = false
      CollectionLogDB.ui.activeGroupId = "wishlist:all"
    else
      CollectionLogDB.ui._forceDefaultGroup = true
      CollectionLogDB.ui.activeGroupId = nil
    end
    -- Raids/Dungeons have the heaviest sidebar + selected-grid path. Let the
    -- tab/list paint complete first; then refresh the selected grid next frame.
    -- This keeps the actual click from blocking on the loot grid/header work.
    UI._clogDeferNextGridRefresh = (cat == "Raids" or cat == "Dungeons") and true or nil
    UI.RefreshAll()
  end

  for i, cat in ipairs(CATEGORIES) do
    local b = CreateFrame("Button", nil, tabsHolder, "BackdropTemplate")
    -- NOTE: Tab widths/anchors are laid out dynamically to fill the full header width.
    -- We keep a deterministic spacing and compute per-tab widths once the holder has a size.
    b:SetSize(TAB_W, TAB_H)
    b:SetPoint("LEFT", tabsHolder, "LEFT", (i-1) * (TAB_W + 4), 0)
    b.__clogAnchor = { point = "LEFT", rel = tabsHolder, relPoint = "LEFT", x = (i-1) * (TAB_W + 4), y = 0 }
    b.__clogBaseLevel = b:GetFrameLevel()
    CreateGoldTabBorder(b)

    local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t:SetPoint("CENTER", b, "CENTER", 0, 0)
    t:SetText(cat)

    b:SetScript("OnClick", function() SetActiveCategory(cat) end)

    -- Hover glow for inactive tabs (subtle, does not compete with active tab)
    b:HookScript("OnEnter", function(self)
      if self._clogIsActive then return end
      if self.__clogHoverGlow then self.__clogHoverGlow:Show() end
      self:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 0.55)
      if self.__clogSheen then self.__clogSheen:SetVertexColor(1,1,1,0.12) end
    end)

    b:HookScript("OnLeave", function(self)
      if self.__clogHoverGlow then self.__clogHoverGlow:Hide() end
      if self._clogIsActive then return end
      self:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.45)
      if self.__clogSheen then self.__clogSheen:SetVertexColor(1,1,1,0.06) end
    end)

    UI.tabs[cat] = { button = b, label = t }
  end

  -- Stretch top tabs to fill the available header width.
  -- This keeps the clean "folder tab" look while eliminating empty space.
  local function LayoutTopTabs()
    if not tabsHolder or not tabsHolder.GetWidth then return end

    local n = #CATEGORIES
    if n <= 0 then return end

    local holderW = tabsHolder:GetWidth() or 0

    local spacing = 4
    local usableW = holderW
    if usableW < 10 then usableW = holderW end
    if holderW <= 10 then
      -- Defer until the frame has a valid width.
      C_Timer.After(0, LayoutTopTabs)
      return
    end

    local baseW = math.floor((usableW - spacing * (n - 1)) / n)
    if baseW < 40 then baseW = 40 end
    local remainder = usableW - (baseW * n) - (spacing * (n - 1))

    local prev
    for i, cat in ipairs(CATEGORIES) do
      local tab = UI.tabs[cat] and UI.tabs[cat].button
      if tab then
        tab:ClearAllPoints()
        local w = baseW
        if i == n then
          w = baseW + remainder
        end
        tab:SetSize(w, TAB_H)
        if i == 1 then
          tab:SetPoint("LEFT", tabsHolder, "LEFT", 0, 0)
          tab.__clogAnchor = { point = "LEFT", rel = tabsHolder, relPoint = "LEFT", x = 0, y = 0 }
        else
          tab:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
          tab.__clogAnchor = { point = "LEFT", rel = prev, relPoint = "RIGHT", x = spacing, y = 0 }
        end
        prev = tab
      end
    end
  end

  tabsHolder:HookScript("OnShow", LayoutTopTabs)
  tabsHolder:HookScript("OnSizeChanged", function() C_Timer.After(0, LayoutTopTabs) end)
  C_Timer.After(0, LayoutTopTabs)

  local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  UI.searchBox = search
  search:SetAutoFocus(false)
  search:SetSize(180, 20)
  search:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 6, -(TOPBAR_H + TAB_H + 8))
  search:SetText(CollectionLogDB.ui.search or "")
  UI.search = search
  search:SetScript("OnEnterPressed", function(self)
    CollectionLogDB.ui.search = self:GetText() or ""
    self:ClearFocus()
    UI.RefreshGrid()
  end)
  search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

  -- Clear (X) button inside the search box
  local clearSearchBtn = CreateFrame("Button", nil, search)
  UI.clearSearchBtn = clearSearchBtn
  clearSearchBtn:SetSize(18, 18)
  clearSearchBtn:SetPoint("RIGHT", search, "RIGHT", -2, 0)
  clearSearchBtn:SetFrameLevel((search:GetFrameLevel() or 1) + 1)

  -- Use a simple text glyph to avoid texture/theme conflicts
  clearSearchBtn:SetNormalFontObject("GameFontNormalSmall")
  if clearSearchBtn.SetText then clearSearchBtn:SetText("X") end

  local function CLOG_UpdateClearSearchVisibility()
    local t = (search.GetText and search:GetText()) or ""
    if t ~= nil and t ~= "" then
      clearSearchBtn:Show()
    else
      clearSearchBtn:Hide()
    end
  end

  -- Give the edit box some right padding so text doesn't overlap the X
  if search.SetTextInsets then
    search:SetTextInsets(6, 18, 0, 0)
  end

  clearSearchBtn:SetScript("OnClick", function()
    if search.SetText then search:SetText("") end
    if CollectionLogDB and CollectionLogDB.ui then
      CollectionLogDB.ui.search = ""
    end
    UI.RefreshGrid()
    -- Keep focus so the user can immediately type again
    if search.SetFocus then pcall(search.SetFocus, search) end
    CLOG_UpdateClearSearchVisibility()
  end)

  search:HookScript("OnTextChanged", function()
    -- Do not refresh on every keystroke; just toggle the X visibility
    CLOG_UpdateClearSearchVisibility()
  end)

  search:HookScript("OnEditFocusGained", CLOG_UpdateClearSearchVisibility)
  search:HookScript("OnEditFocusLost", CLOG_UpdateClearSearchVisibility)
  CLOG_UpdateClearSearchVisibility()

-- Search button (visual only) completions: use Blizzard template, no tint/overlay, keep logic unchanged
local searchLabel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
UI.searchLabel = searchLabel
searchLabel:SetSize(76, 20)
searchLabel:SetPoint("LEFT", search, "RIGHT", 8, 0)
searchLabel:SetText("Search")

searchLabel:SetScript("OnClick", function()
  -- Apply current search text and refresh the view
  if CollectionLogDB and CollectionLogDB.ui then
    local t = (UI.search and UI.search.GetText and UI.search:GetText()) or (search and search.GetText and search:GetText()) or ""
    CollectionLogDB.ui.search = t or ""
  end
  UI.RefreshGrid()
  -- Keep focus on the search box for quick typing
  if UI.search and UI.search.SetFocus then
    pcall(UI.search.SetFocus, UI.search)
  end
end)

-- Ensure the label reads like a primary control (yellow text), without altering button textures.
do
  local fs = searchLabel.GetFontString and searchLabel:GetFontString()
  if fs then
    fs:SetTextColor(1, 0.82, 0, 1)
  end
end


local function CLOG_FormatLastRefreshAge(ts)
  ts = tonumber(ts or 0) or 0
  if ts <= 0 then return "Not refreshed yet" end
  local now = (time and time()) or 0
  local age = math.max(0, now - ts)
  if age < 10 then return "Last refreshed a few seconds ago" end
  if age < 60 then return "Last refreshed " .. math.floor(age) .. " seconds ago" end
  if age < 3600 then
    local m = math.floor(age / 60)
    return "Last refreshed " .. m .. " minute" .. (m == 1 and "" or "s") .. " ago"
  end
  if age < 86400 then
    local h = math.floor(age / 3600)
    return "Last refreshed " .. h .. " hour" .. (h == 1 and "" or "s") .. " ago"
  end
  if age < 172800 then return "Last refreshed yesterday" end
  local d = math.floor(age / 86400)
  return "Last refreshed " .. d .. " days ago"
end

local function CLOG_IsSoftPauseState()
  if InCombatLockdown and InCombatLockdown() then return true end
  if UnitOnTaxi and UnitOnTaxi("player") then return true end
  if IsFlying and IsFlying() then return true end
  return false
end

local listPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
  UI.listPanel = listPanel
  listPanel:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TOPBAR_H + TAB_H + 36))
  listPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, PAD)
-- Refresh button (same styling as Search) - acts like a "second click" on the current left-panel selection.
-- Vertically aligned with the Search bar row, pinned to the far-right.
local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
UI.refreshBtn = refreshBtn
refreshBtn:SetSize(76, 20)
refreshBtn:ClearAllPoints()
-- Match the Search row's vertical position, but keep the button pinned to the far-right edge.
refreshBtn:SetPoint("RIGHT", f, "RIGHT", -PAD - 6, 0)
refreshBtn:SetPoint("TOP", search, "TOP", 0, 0)
refreshBtn:SetText("Refresh")

local refreshStatus = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
UI.refreshStatus = refreshStatus
refreshStatus:SetPoint("RIGHT", refreshBtn, "LEFT", -8, 0)
refreshStatus:SetJustifyH("RIGHT")
refreshStatus:SetTextColor(0.78, 0.76, 0.68, 1)
refreshStatus:SetText(CLOG_FormatLastRefreshAge(CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.lastManualRefreshAt))

local function CLOG_UpdateRefreshStatusText(forceText)
  if not refreshStatus then return end
  if forceText and forceText ~= "" then
    refreshStatus:SetText(forceText)
    return
  end
  local ts = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.lastManualRefreshAt or 0
  refreshStatus:SetText(CLOG_FormatLastRefreshAge(ts))
end

local function CLOG_ScheduleRefreshStatusTicker()
  if UI._clogRefreshStatusTickerScheduled then return end
  UI._clogRefreshStatusTickerScheduled = true
  if C_Timer and C_Timer.NewTicker then
    UI._clogRefreshStatusTicker = C_Timer.NewTicker(30, function()
      if UI and UI._clogRefreshRun and UI._clogRefreshRun.running then return end
      CLOG_UpdateRefreshStatusText()
    end)
  end
end
CLOG_ScheduleRefreshStatusTicker()

local function CLOG_ForceCurrentSelectionRefresh()
  if not (CollectionLogDB and CollectionLogDB.ui) then return end

  -- Clear any session caches that can stick "unknown" states
  if UI._clogMountCache then wipe(UI._clogMountCache) end
  if UI._clogPetCache then wipe(UI._clogPetCache) end

  -- Re-run the same refresh path as clicking the currently selected row:
  -- update the grid and rebuild the left list highlighting.
  UI.RefreshGrid()
  if UI.BuildGroupList then UI.BuildGroupList() end
end

local function CLOG_TouchCollectionTabsForOverview()
  -- v4.3.30: Refresh should not force-build every collection tab or cold-scan
  -- Housing.  It only invalidates backend caches and repaints the visible UI.
  if UI and UI.RequestOverviewRebuild and CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Overview" then
    pcall(UI.RequestOverviewRebuild, "refresh", true)
  end
end

local function CLOG_ClearLeftListCompletionCaches()
  if UI._clogLeftListColorCache then
    if wipe then wipe(UI._clogLeftListColorCache) else for k in pairs(UI._clogLeftListColorCache) do UI._clogLeftListColorCache[k] = nil end end
  end
  if UI.ClearCategoryRowCountCache then pcall(UI.ClearCategoryRowCountCache) end
  if UI.ClearVisibleGroupListCache then pcall(UI.ClearVisibleGroupListCache) end
  if UI._clogLeftListColorQueue then
    if wipe then wipe(UI._clogLeftListColorQueue) else for k in pairs(UI._clogLeftListColorQueue) do UI._clogLeftListColorQueue[k] = nil end end
  end
  UI._clogLeftPrecomputeRunning = false
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache then
    CollectionLogDB.ui.leftListColorCache.cache = {}
    CollectionLogDB.ui.leftListColorCache.meta = CollectionLogDB.ui.leftListColorCache.meta or {}
    CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
  end
end


local function CLOG_WarmAllRaidDungeonRowColors(onDone, opts)
  -- v4.3.34: Manual Refresh must leave every raid/dungeon row with a trusted
  -- backend color, without opening/rendering every row.  The v4.3.30 refresh
  -- invalidated caches then only let the visible-list precompute refill rows on
  -- its normal slow schedule, which could leave a few rows gray until clicked.
  if not (ns and ns.Data and type(ns.Data.groups) == "table") then
    if onDone then onDone() end
    return
  end

  local ids = {}
  local seen = {}
  for key, g in pairs(ns.Data.groups) do
    if type(g) == "table" and CLog_IsRaidDungeonGroup(g) and g.id ~= nil then
      local gid = tostring(g.id)
      if gid ~= "" and not seen[gid] then
        seen[gid] = true
        ids[#ids + 1] = gid
      end
    end
  end
  table.sort(ids)

  local totalIds = #ids
  local index = 1
  local batch = math.max(1, tonumber(opts and opts.batch) or 10)
  local budget = math.max(0.0005, tonumber(opts and opts.budget) or 0.006)
  local stepDelay = math.max(0, tonumber(opts and opts.delay) or 0.03)
  local statusLabel = tostring((opts and opts.statusLabel) or "Refreshing collections...")

  local function step()
    if InCombatLockdown and InCombatLockdown() then
      if C_Timer and C_Timer.After then C_Timer.After(0.75, step) else if onDone then onDone() end end
      return
    end

    local start = (GetTime and GetTime()) or 0
    local processed = 0

    while index <= totalIds do
      local gid = ids[index]
      index = index + 1
      local g = ns.Data.groups[gid] or ns.Data.groups[tonumber(gid) or -1]
      if g and CLog_IsRaidDungeonGroup(g) then
        local ok, collected, total = pcall(function()
          local c, t = CLog_GetRaidRowColorBackendTotals(g)
          return c, t
        end)
        UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
        if ok and total and total > 0 then
          UI._clogLeftListColorCache[gid] = CLOG_MakeLeftListCacheEntry(collected or 0, total, true, "manual_refresh")
          if CLOG_InvalidateDifficultyIndicatorForGroup then CLOG_InvalidateDifficultyIndicatorForGroup(gid) end
          if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
            CollectionLogDB.ui.leftListColorCache.cache[gid] = CLOG_MakeLeftListCacheEntry(collected or 0, total, true, "manual_refresh")
          end
        else
          -- Trusted empty/unsupported rows remain gray; caching prevents them from
          -- being repeatedly re-queued during the same refresh pass.
          UI._clogLeftListColorCache[gid] = CLOG_MakeLeftListCacheEntry(0, 0, true, "manual_refresh_empty")
          if CLOG_InvalidateDifficultyIndicatorForGroup then CLOG_InvalidateDifficultyIndicatorForGroup(gid) end
        end

        local activeId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil
        local isActive = (activeId and tostring(activeId) == gid) or false
        CLog_ApplyLeftListTextColor(gid, isActive)
      end

      processed = processed + 1
      if processed >= batch then break end
      if GetTime and ((GetTime() - start) > budget) then break end
    end

    if index <= totalIds then
      if CLOG_UpdateRefreshStatusText then
        local done = math.min(index - 1, totalIds)
        local pct = (totalIds > 0) and math.floor(((done / totalIds) * 100) + 0.5) or 100
        if pct < 0 then pct = 0 end
        if pct > 100 then pct = 100 end
        CLOG_UpdateRefreshStatusText(("%s %d%%"):format(statusLabel, pct))
      end
      if C_Timer and C_Timer.After then C_Timer.After(stepDelay, step) else step() end
    else
      if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.meta then
        CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
      end
      if onDone then onDone() end
    end
  end

  step()
end

local function CLOG_RunLightweightManualRefresh()
  if not (CollectionLogDB and CollectionLogDB.ui) then return end
  if UI._clogRefreshRun and UI._clogRefreshRun.running then return end

  local activeCat = CollectionLogDB.ui.activeCategory
  local runToken = ((tonumber(UI._clogRefreshRunToken or 0) or 0) + 1)
  UI._clogRefreshRunToken = runToken
  UI._clogRefreshRun = { running = true, token = runToken, category = activeCat }
  if refreshBtn and refreshBtn.Disable then refreshBtn:Disable() end
  CLOG_UpdateRefreshStatusText("Refreshing collections...")

  if ns and ns.BeginSyntheticCollectionSuppression then pcall(ns.BeginSyntheticCollectionSuppression, 90, "manual_refresh") end
  if ns and ns.TrueCollection and ns.TrueCollection.ClearCache then pcall(ns.TrueCollection.ClearCache, "manual_refresh") end
  if ns and ns.CompletionV2 and ns.CompletionV2.ClearCache then pcall(ns.CompletionV2.ClearCache, "manual_refresh") end
  if CLOG_ResetTrueStatusCache then pcall(CLOG_ResetTrueStatusCache) end
  if CLOG_ResetAggregateDifficultyTotalsCache then pcall(CLOG_ResetAggregateDifficultyTotalsCache) end
  if CLOG_ResetDifficultyIndicatorCache then pcall(CLOG_ResetDifficultyIndicatorCache) end
  if UI.ClearTooltipAnalysisCaches then pcall(UI.ClearTooltipAnalysisCaches, "manual_refresh") end
  CLOG_ClearLeftListCompletionCaches()

  CollectionLogDB.ui.lastManualRefreshAt = (time and time()) or 0

  local function finishVisible()
    if not (UI and UI._clogRefreshRun and UI._clogRefreshRun.token == runToken) then return end
    if ns and ns.EndSyntheticCollectionSuppression then pcall(ns.EndSyntheticCollectionSuppression, "manual_refresh") end
    UI._clogRefreshRun = nil

    if activeCat == "Overview" then
      if UI.RequestOverviewRebuild then pcall(UI.RequestOverviewRebuild, "refresh", true) end
      if UI.RefreshOverview then pcall(UI.RefreshOverview) end
    elseif activeCat == "Wishlist" then
      if UI.RefreshWishlist then pcall(UI.RefreshWishlist) end
    elseif activeCat == "History" then
      if UI.RefreshHistory then pcall(UI.RefreshHistory) end
    else
      if activeCat == "Raids" or activeCat == "Dungeons" then
        UI._clogDeferNextGridRefresh = true
      end
      if UI.RefreshAll then pcall(UI.RefreshAll) end
    end

    CLOG_UpdateRefreshStatusText()
    if refreshBtn and refreshBtn.Enable then refreshBtn:Enable() end
  end

  local function finishBackgroundWarm()
    if UI and UI._clogBackgroundRefreshToken and UI._clogBackgroundRefreshToken ~= runToken then
      return
    end
    UI._clogBackgroundRefreshToken = nil
    if not (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.lastManualRefreshAt) then return end
    if not (UI and not (UI._clogRefreshRun and UI._clogRefreshRun.running)) then return end
    local currentCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
    if currentCat == activeCat then
      if currentCat == "Overview" then
        if UI.RequestOverviewRebuild then pcall(UI.RequestOverviewRebuild, "refresh_complete", true) end
        if UI.RefreshOverview then pcall(UI.RefreshOverview) end
      elseif currentCat == "Raids" or currentCat == "Dungeons" then
        if UI.BuildGroupList then pcall(UI.BuildGroupList) end
        if UI.RefreshGrid then
          if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
              if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == currentCat then
                pcall(UI.RefreshGrid)
              end
            end)
          else
            pcall(UI.RefreshGrid)
          end
        end
      end
    end
    CLOG_UpdateRefreshStatusText()
  end

  local function maybeWarmSidebarInBackground()
    if activeCat ~= "Raids" and activeCat ~= "Dungeons" and activeCat ~= "Overview" then
      return
    end
    if UI._clogBackgroundRefreshToken then
      return
    end
    UI._clogBackgroundRefreshToken = runToken
    CLOG_UpdateRefreshStatusText("Refreshing collections...")
    CLOG_WarmAllRaidDungeonRowColors(finishBackgroundWarm, {
      batch = 1,
      budget = 0.0015,
      delay = 0.10,
      statusLabel = "Refreshing collections..."
    })
  end

  local function runVisibleThenBackground()
    finishVisible()
    if C_Timer and C_Timer.After then
      C_Timer.After(0.10, maybeWarmSidebarInBackground)
    else
      maybeWarmSidebarInBackground()
    end
  end

  if C_Timer and C_Timer.After then C_Timer.After(0.05, runVisibleThenBackground) else runVisibleThenBackground() end
end

refreshBtn:SetScript("OnClick", function()
  UI._clogLastManualRefresh = (GetTime and GetTime()) or 0
  CLOG_RunLightweightManualRefresh()
end)

do
  local fs = refreshBtn.GetFontString and refreshBtn:GetFontString()
  if fs then fs:SetTextColor(1, 0.82, 0, 1) end
end


  listPanel:SetWidth(LIST_W)
  CreateBorder(listPanel)

  -- Expansion filter dropdown (Encounter Panel)
  local expDD = CreateFrame("Frame", "CollectionLogExpansionDropDown", listPanel, "UIDropDownMenuTemplate")
  UI.expansionDropdown = expDD
  expDD:SetPoint("TOPRIGHT", listPanel, "TOPRIGHT", -6, -2)
  UIDropDownMenu_SetWidth(expDD, 190)
  UIDropDownMenu_JustifyText(expDD, "RIGHT")

  local scroll = CreateFrame("ScrollFrame", "CollectionLogGroupScroll", listPanel, "UIPanelScrollFrameTemplate")
  UI.groupScroll = scroll
  scroll:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 4, -30)
  scroll:SetPoint("BOTTOMRIGHT", listPanel, "BOTTOMRIGHT", -28, 6)

  local content = CreateFrame("Frame", nil, scroll)
  UI.groupScrollContent = content
  content:SetSize(LIST_W - 40, 400)
  scroll:SetScrollChild(content)
  UI.groupButtons = {}

  local right = CreateFrame("Frame", nil, f, "BackdropTemplate")
  UI.right = right
  right:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", PAD, 0)
  right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
  CreateBorder(right)

  -- =========================
  -- Overview (fullscreen) tab
  -- =========================
  local overview = CreateFrame("Frame", nil, f, "BackdropTemplate")
  UI.overview = overview
  overview:SetPoint("TOPLEFT", listPanel, "TOPLEFT", 0, 0)
  overview:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
  CreateBorder(overview)

overview:Hide()

local CLOG_CreateCollectionTracker, CLOG_RefreshCollectionTracker

-- ======================
-- Wishlist (fullscreen) tab
-- ======================
local wishlist = CreateFrame("Frame", nil, f, "BackdropTemplate")
UI.wishlist = wishlist
wishlist:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TOPBAR_H + TAB_H + 36))
wishlist:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
CreateBorder(wishlist)
wishlist:Hide()
wishlist:SetFrameLevel((right:GetFrameLevel() or 1) + 20)

local wTitle = wishlist:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
wTitle:SetPoint("TOPLEFT", wishlist, "TOPLEFT", 12, -12)
wTitle:SetText("Wishlist")

local wSub = wishlist:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
wSub:SetPoint("TOPLEFT", wTitle, "BOTTOMLEFT", 0, -4)
wSub:SetText("Everything you marked to come back for.")
UI.wishlistSummary = wSub

local wishlistTrackedText = wishlist:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
UI.wishlistTrackedText = wishlistTrackedText
wishlistTrackedText:SetPoint("TOPRIGHT", wishlist, "TOPRIGHT", -12, -16)
wishlistTrackedText:SetJustifyH("RIGHT")
wishlistTrackedText:SetJustifyV("MIDDLE")
wishlistTrackedText:SetMaxLines(1)
wishlistTrackedText:SetText("Tracking: None")

local wishlistHeaderRow = CreateFrame("Frame", nil, wishlist)
UI.wishlistHeaderRow = wishlistHeaderRow
wishlistHeaderRow:SetPoint("TOPLEFT", wishlist, "TOPLEFT", 10, -50)
wishlistHeaderRow:SetPoint("TOPRIGHT", wishlist, "TOPRIGHT", -30, -50)
wishlistHeaderRow:SetHeight(24)

local ws = CreateFrame("ScrollFrame", "CollectionLogWishlistScroll", wishlist, "UIPanelScrollFrameTemplate")
UI.wishlistScroll = ws
ws:SetPoint("TOPLEFT", wishlistHeaderRow, "BOTTOMLEFT", 0, -2)
ws:SetPoint("BOTTOMRIGHT", wishlist, "BOTTOMRIGHT", -30, 10)

local wsContent = CreateFrame("Frame", nil, ws)
wsContent:SetSize(100, 100)
ws:SetScrollChild(wsContent)
UI.wishlistScrollContent = wsContent
UI.wishlistRows = UI.wishlistRows or {}

local WISHLIST_COLS = {
  { key = "icon",      label = "",            fixed = 36 },
  { key = "name",      label = "Item Name",   min = 220 },
  { key = "type",      label = "Item Type",   fixed = 96 },
  { key = "source",    label = "Source",      min = 180 },
  { key = "waypoint",  label = "Waypoint",    fixed = 60 },
  { key = "tracked",   label = "Tracked",     fixed = 60 },
  { key = "status",    label = "Status",      fixed = 100 },
}
local WISHLIST_GAPS = { 18, 12, 18, 12, 12, 18 }

local function CLOG_GetWishlistGap(index)
  return tonumber(WISHLIST_GAPS[index] or 12) or 12
end
local function CLOG_GetWishlistColumnWidths(totalWidth)
  local widths = {}
  local gapSpace = 0
  for i = 1, (#WISHLIST_COLS - 1) do
    gapSpace = gapSpace + CLOG_GetWishlistGap(i)
  end
  local innerWidth = math.max(620, math.floor((totalWidth or 0) - 18 - gapSpace))
  local iconW = 36
  local typeW = 96
  local waypointW = 60
  local trackedW = 60
  local statusW = 100
  local sourceW = math.max(220, math.floor(innerWidth * 0.30))
  local nameW = math.max(170, innerWidth - iconW - typeW - sourceW - waypointW - trackedW - statusW)
  widths[1] = iconW
  widths[2] = nameW
  widths[3] = typeW
  widths[4] = sourceW
  widths[5] = waypointW
  widths[6] = trackedW
  widths[7] = statusW
  return widths
end

local wishlistHeaderFonts = {}
for i, col in ipairs(WISHLIST_COLS) do
  local fs = wishlistHeaderRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  wishlistHeaderFonts[i] = fs
  fs:SetTextColor(1, 0.82, 0, 1)
  if col.key == "status" then
    fs:SetJustifyH("RIGHT")
  elseif col.key == "waypoint" or col.key == "tracked" then
    fs:SetJustifyH("CENTER")
  else
    fs:SetJustifyH("LEFT")
  end
  fs:SetText(col.label)
end
UI.wishlistHeaderFonts = wishlistHeaderFonts

local function CLOG_LayoutWishlistColumns()
  local available = math.max(620, (UI.wishlistScroll and UI.wishlistScroll:GetWidth() or 860) - 8)
  local widths = CLOG_GetWishlistColumnWidths(available)
  UI.wishlistColumnWidths = widths
  local leftInset = 8
  local rightInset = 10
  local topOffset = -4
  local iconFS = wishlistHeaderFonts[1]
  local nameFS = wishlistHeaderFonts[2]
  local typeFS = wishlistHeaderFonts[3]
  local sourceFS = wishlistHeaderFonts[4]
  local waypointFS = wishlistHeaderFonts[5]
  local trackedFS = wishlistHeaderFonts[6]
  local statusFS = wishlistHeaderFonts[7]
  for _, fs in ipairs(wishlistHeaderFonts) do fs:ClearAllPoints() end
  if iconFS then
    iconFS:SetPoint("TOPLEFT", wishlistHeaderRow, "TOPLEFT", leftInset, topOffset)
    iconFS:SetWidth(widths[1] or 36)
  end
  if statusFS then
    statusFS:SetPoint("TOPRIGHT", wishlistHeaderRow, "TOPRIGHT", -rightInset, topOffset)
    statusFS:SetWidth(widths[7] or 100)
    statusFS:SetJustifyH("RIGHT")
  end
  if trackedFS then
    trackedFS:SetPoint("TOPRIGHT", statusFS, "TOPLEFT", -CLOG_GetWishlistGap(6), 0)
    trackedFS:SetWidth(widths[6] or 60)
    trackedFS:SetJustifyH("CENTER")
  end
  if waypointFS then
    waypointFS:SetPoint("TOPRIGHT", trackedFS, "TOPLEFT", -CLOG_GetWishlistGap(5), 0)
    waypointFS:SetWidth(widths[5] or 60)
    waypointFS:SetJustifyH("CENTER")
  end
  if nameFS then
    nameFS:SetPoint("TOPLEFT", wishlistHeaderRow, "TOPLEFT", leftInset + (widths[1] or 36) + CLOG_GetWishlistGap(1), topOffset)
    nameFS:SetWidth(widths[2] or 260)
    nameFS:SetJustifyH("LEFT")
  end
  if typeFS then
    typeFS:SetPoint("TOPLEFT", nameFS, "TOPRIGHT", CLOG_GetWishlistGap(2), 0)
    typeFS:SetWidth(widths[3] or 96)
    typeFS:SetJustifyH("LEFT")
  end
  if sourceFS then
    sourceFS:SetPoint("TOPLEFT", typeFS, "TOPRIGHT", CLOG_GetWishlistGap(3), 0)
    sourceFS:SetPoint("TOPRIGHT", waypointFS, "TOPLEFT", -CLOG_GetWishlistGap(4), 0)
    sourceFS:SetJustifyH("LEFT")
  end
end

local function CLOG_UpdateWishlistTrackedPanel()
  if not UI then return end
  local textFS = UI.wishlistTrackedText
  if not textFS then return end
  local entries = Wishlist.GetTrackedEntries and Wishlist.GetTrackedEntries() or {}
  local count = #entries
  if count <= 0 then
    textFS:SetText("Tracking: None")
    textFS:SetTextColor(0.75, 0.75, 0.75, 1)
    return
  end
  local label = count == 1 and "1 item" or (tostring(count) .. " items")
  textFS:SetText("Tracking: " .. label)
  textFS:SetTextColor(1, 0.82, 0, 1)
end

function UI.RefreshWishlist()
  if not UI.wishlist or not UI.wishlistRows then return end
  Wishlist.RestoreTrackedState()
  local search = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.search or ""):lower():match("^%s*(.-)%s*$")
  local entries = WishlistGetSortedEntries(search)
  local rows = UI.wishlistRows
  local rowH = 30
  local padY = 2
  local viewportW = math.max(520, (UI.wishlistScroll and UI.wishlistScroll:GetWidth() or 800) - 8)
  local widths = CLOG_GetWishlistColumnWidths(viewportW)
  UI.wishlistColumnWidths = widths
  CLOG_LayoutWishlistColumns()
  local total = #entries
  local collectedCount = 0
  for i, entry in ipairs(entries) do
    local row = rows[i]
    if not row then
      row = CreateFrame("Button", nil, wsContent, "BackdropTemplate")
      row:SetHeight(rowH)
      row:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
      })
      row:SetBackdropColor(0.08, 0.08, 0.08, 0.55)
      row:SetBackdropBorderColor(1, 1, 1, 0.10)
      row.icon = row:CreateTexture(nil, "ARTWORK")
      row.icon:SetSize(20, 20)
      row.glow = row:CreateTexture(nil, "OVERLAY", nil, 6)
      row.glow:SetTexture("Interface\Buttons\UI-ActionButton-Border")
      row.glow:SetBlendMode("ADD")
      row.glow:SetSize(32, 32)
      row.glow:SetVertexColor(1.0, 0.82, 0.25, 1.0)
      row.glow:SetAlpha(0.95)
      row.waypointAnchor = CreateFrame("Frame", nil, row)
      row.waypointAnchor:SetSize(60, rowH)
      row.waypointBtn = CreateFrame("Button", nil, row)
      row.waypointBtn:SetSize(18, 18)
      row.waypointNA = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.waypointNA:SetJustifyH("CENTER")
      row.waypointNA:SetJustifyV("MIDDLE")
      row.waypointNA:SetText("N/A")
      row.waypointNA:Hide()
      row.trackedAnchor = CreateFrame("Frame", nil, row)
      row.trackedAnchor:SetSize(60, rowH)
      row.trackedCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
      row.trackedCheck:SetSize(20, 20)
      row.trackedCheck:SetHitRectInsets(0, 0, 0, 0)
      row.trackedCheck:Hide()
      if row.waypointBtn.SetNormalAtlas then
        local okAtlas = pcall(row.waypointBtn.SetNormalAtlas, row.waypointBtn, "Waypoint-MapPin-Tracked")
        if okAtlas and row.waypointBtn.SetHighlightAtlas then
          pcall(row.waypointBtn.SetHighlightAtlas, row.waypointBtn, "Waypoint-MapPin-Tracked", "ADD")
        end
      end
      if not (row.waypointBtn.GetNormalTexture and row.waypointBtn:GetNormalTexture()) then
        row.waypointBtn:SetNormalTexture("Interface\Buttons\UI-Panel-MinimizeButton-Up")
        row.waypointBtn:SetPushedTexture("Interface\Buttons\UI-Panel-MinimizeButton-Down")
        row.waypointBtn:SetHighlightTexture("Interface\Buttons\UI-Panel-MinimizeButton-Highlight")
      end
      row.waypointBtn:Hide()
      row.waypointBtn:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        local e = parent and parent._clEntry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(WishlistEntryDisplayName(e) or "Unknown", 1, 1, 1)
        GameTooltip:AddLine(Wishlist.SourceDisplayText(e), 0.8, 0.8, 0.8, true)
        if not self._clHasWaypoint then
          GameTooltip:AddLine("Waypoint unavailable", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
      end)
      row.waypointBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row.waypointBtn:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        local e = parent and parent._clEntry
        if not (e and self._clHasWaypoint) then return end
        Wishlist.OpenWaypoint(e)
      end)
      row.trackedCheck:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        local e = parent and parent._clEntry
        if not e then
          self:SetChecked(false)
          return
        end
        local checked = self:GetChecked() and true or false
        Wishlist.SetTrackedEntry(e, checked)
        if UI and UI.RefreshWishlist then UI.RefreshWishlist() end
      end)
      row.trackedCheck:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        local e = parent and parent._clEntry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Tracked", 1, 1, 1)
        GameTooltip:AddLine("Check to add this item to the Collection Log tracker.", 0.8, 0.8, 0.8, true)
        if Wishlist.EntryHasWaypoint(e) then
          GameTooltip:AddLine("Tracked items with a waypoint can set Blizzard's arrow from the tracker.", 0.8, 0.8, 0.8, true)
        else
          GameTooltip:AddLine("This item can still be tracked, but it does not have a waypoint target yet.", 0.8, 0.8, 0.8, true)
        end
        GameTooltip:Show()
      end)
      row.trackedCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      row.sourceFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.typeFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.statusFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      for _, fs in ipairs({ row.nameFS, row.sourceFS, row.typeFS, row.statusFS }) do
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        fs:SetMaxLines(1)
      end
      row.statusFS:SetJustifyH("RIGHT")
      row:SetScript("OnEnter", function(self)
        local e = self._clEntry
        if not e then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local itemLink = e.itemLink
        local itemID = tonumber(e.itemID)
        if itemLink and GameTooltip.SetHyperlink then
          GameTooltip:SetHyperlink(itemLink)
        elseif itemID and itemID > 0 and GameTooltip.SetItemByID then
          GameTooltip:SetItemByID(itemID)
        else
          GameTooltip:SetText(WishlistEntryDisplayName(e) or "Unknown")
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Item Type: " .. Wishlist.GetDisplayType(e), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Source: " .. Wishlist.SourceDisplayText(e), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Status: Not Collected", 0.8, 0.8, 0.8)
        GameTooltip:AddLine(" ")
        if Wishlist.EntryHasWaypoint(e) then
          GameTooltip:AddLine("Left-click waypoint icon to open map and set waypoint", 1.0, 0.82, 0.0, true)
        end
        GameTooltip:AddLine("Check Tracked to add it to your Collection Log tracker", 1.0, 0.82, 0.0, true)
        GameTooltip:AddLine("Right-click to remove from Wishlist", 1.0, 0.82, 0.0)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
          local entry = self._clEntry
          local key = entry and entry.key
          if key then
            Wishlist.RemoveKey(key)
            if UI and UI.RefreshWishlist then UI.RefreshWishlist() end
          end
          return
        end
        if button ~= "LeftButton" then return end
        if not (IsControlKeyDown and IsControlKeyDown()) then return end
        CLOG_PreviewHistoryEntry(self._clEntry)
      end)
      rows[i] = row
    end
    local iconFile = entry.icon or "Interface\Icons\INV_Misc_QuestionMark"
    local collected = false
    if entry.kind == "mount" then
      iconFile, collected = CL_GetMountIconCollected(entry.mountID or entry.id)
    elseif entry.kind == "pet" then
      iconFile, collected = CL_GetPetIconCollected(entry.petSpeciesID or entry.id)
    elseif entry.kind == "appearance" then
      local itemID = tonumber(entry.itemID or 0) or 0
      local appearanceID = tonumber(entry.appearanceID or entry.id or 0) or 0
      if itemID > 0 then
        iconFile = select(5, GetItemInfoInstant(itemID)) or ((C_Item and C_Item.GetItemIconByID) and C_Item.GetItemIconByID(itemID)) or iconFile
      end
      collected = Wishlist.GetAppearanceCollected(appearanceID, itemID > 0 and itemID or nil)
    else
      local itemID = tonumber(entry.itemID or entry.id or 0) or 0
      if itemID > 0 then
        iconFile = select(5, GetItemInfoInstant(itemID)) or ((C_Item and C_Item.GetItemIconByID) and C_Item.GetItemIconByID(itemID)) or iconFile
        if (entry.category == "Toys") or (ns and ns.IsToyCollected and ns.IsToyCollected(itemID)) then
          collected = (ns.IsToyCollected and ns.IsToyCollected(itemID)) and true or false
        else
          collected = ((ns and ns.IsCollected and ns.IsCollected(itemID)) or false) and true or false
        end
      end
    end
    if collected then collectedCount = collectedCount + 1 end
    row:SetWidth(viewportW)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", wsContent, "TOPLEFT", 0, -((i - 1) * (rowH + padY)))
    row.icon:SetTexture(iconFile)
    DesaturateIf(row.icon, not collected)
    row.icon:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.glow:ClearAllPoints()
    row.glow:SetPoint("CENTER", row.icon, "CENTER", 0, 0)
    row.nameFS:ClearAllPoints()
    row.nameFS:SetPoint("LEFT", row, "LEFT", 8 + (widths[1] or 36) + CLOG_GetWishlistGap(1), 0)
    row.nameFS:SetWidth(widths[2] or 260)
    row.nameFS:SetText(WishlistEntryDisplayName(entry) or "Unknown")
    row.typeFS:ClearAllPoints()
    row.typeFS:SetPoint("LEFT", row.nameFS, "RIGHT", CLOG_GetWishlistGap(2), 0)
    row.typeFS:SetWidth(widths[3] or 110)
    row.typeFS:SetText(Wishlist.GetDisplayType(entry))
    row.sourceFS:ClearAllPoints()
    row.sourceFS:SetPoint("LEFT", row.typeFS, "RIGHT", CLOG_GetWishlistGap(3), 0)
    row.sourceFS:SetPoint("RIGHT", row, "RIGHT", -((widths[7] or 100) + (widths[6] or 60) + (widths[5] or 60) + 10 + CLOG_GetWishlistGap(4) + CLOG_GetWishlistGap(5) + CLOG_GetWishlistGap(6)), 0)
    row.sourceFS:SetText(Wishlist.SourceDisplayText(entry))
    row.waypointAnchor:ClearAllPoints()
    row.waypointAnchor:SetPoint("RIGHT", row, "RIGHT", -((widths[7] or 100) + (widths[6] or 60) + 10 + CLOG_GetWishlistGap(6) + CLOG_GetWishlistGap(5)), 0)
    row.waypointAnchor:SetWidth(widths[5] or 60)
    row.waypointAnchor:SetHeight(rowH)
    row.waypointBtn:ClearAllPoints()
    row.waypointBtn:SetPoint("CENTER", row.waypointAnchor, "CENTER", 0, 0)
    row.waypointNA:ClearAllPoints()
    row.waypointNA:SetPoint("LEFT", row.waypointAnchor, "LEFT", 0, 0)
    row.waypointNA:SetPoint("RIGHT", row.waypointAnchor, "RIGHT", 0, 0)
    row.waypointNA:SetHeight(rowH)
    local hasWaypoint = Wishlist.EntryHasWaypoint(entry)
    row.waypointBtn:Show()
    CLOG_ApplyWaypointButtonState(row.waypointBtn, hasWaypoint)
    row.waypointNA:Hide()
    row.trackedAnchor:ClearAllPoints()
    row.trackedAnchor:SetPoint("RIGHT", row, "RIGHT", -((widths[7] or 100) + 10 + CLOG_GetWishlistGap(6)), 0)
    row.trackedAnchor:SetWidth(widths[6] or 60)
    row.trackedAnchor:SetHeight(rowH)
    row.trackedCheck:ClearAllPoints()
    row.trackedCheck:SetPoint("CENTER", row.trackedAnchor, "CENTER", 0, 0)
    row.trackedCheck:SetChecked(Wishlist.IsTrackedKey(entry.key))
    row.trackedCheck:Enable()
    row.trackedCheck:SetAlpha(1)
    row.trackedCheck:Show()
    row.statusFS:ClearAllPoints()
    row.statusFS:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.statusFS:SetWidth(widths[7] or 100)
    row.statusFS:SetText("Not Collected")
    row.statusFS:SetTextColor(1.0, 0.2, 0.2, 1.0)
    row._clEntry = entry
    row._clCollected = collected
    row:Show()
  end
  for i = #entries + 1, #rows do
    rows[i]:Hide()
    if rows[i].waypointBtn then rows[i].waypointBtn:Hide() end
    if rows[i].waypointNA then rows[i].waypointNA:Hide() end
    if rows[i].trackedCheck then rows[i].trackedCheck:Hide() end
    rows[i]._clEntry = nil
    rows[i]._clCollected = nil
  end
  if UI.wishlistSummary then
    local summary = total == 1 and "1 item wishlisted" or (tostring(total) .. " items wishlisted")
    UI.wishlistSummary:SetText(summary .. ".")
  end
  CLOG_UpdateWishlistTrackedPanel()
  if CLOG_RefreshCollectionTracker then CLOG_RefreshCollectionTracker() end
  wsContent:SetWidth(viewportW)
  wsContent:SetHeight(math.max((#entries * (rowH + padY)) + 10, (UI.wishlistScroll and UI.wishlistScroll:GetHeight() or 300)))
end

function UI.ShowWishlist(show)
  if not UI.wishlist then return end
  if show then
    if UI.wishlist:IsShown() and UI._clogWishlistShownActive then
      return
    end
    UI._clogWishlistShownActive = true
    if UI.overview then UI.overview:Hide() end
    if UI.history then UI.history:Hide() end
    if listPanel then listPanel:Hide() end
    if right then right:Hide() end
    if UI.search then UI.search:Show() end
    if UI.searchLabel then UI.searchLabel:Show() end
    if UI.refreshBtn then UI.refreshBtn:Show() end
    if UI.refreshStatus then UI.refreshStatus:Show() end
    UI.wishlist:Show()
    Wishlist.RestoreTrackedState()
    UI.RefreshWishlist()
    if CLOG_RefreshCollectionTracker then CLOG_RefreshCollectionTracker() end
  else
    if (not UI.wishlist:IsShown()) and not UI._clogWishlistShownActive then
      return
    end
    UI._clogWishlistShownActive = false
    UI.wishlist:Hide()
    if listPanel then listPanel:Show() end
    if right then right:Show() end
    -- Do not refresh the objective tracker just because the Wishlist panel was hidden
    -- during a normal Raids/Dungeons/Grid refresh. Tracker state only changes when
    -- Wishlist content/tracked state changes.
  end
end

if wishlist and wishlist.HookScript then
  wishlist:HookScript("OnShow", CLOG_LayoutWishlistColumns)
  wishlist:HookScript("OnSizeChanged", function()
    CLOG_LayoutWishlistColumns()
    if UI and UI.wishlist and UI.wishlist:IsShown() and UI.RefreshWishlist then
      UI.RefreshWishlist()
    end
  end)
end

do
  local function CLOG_GetTrackedObjectiveRows()
    if not UI or not UI.collectionTrackerRows then UI.collectionTrackerRows = {} end
    return UI.collectionTrackerRows
  end


  local function CLOG_ObjectiveTrackerParent()
    return UIParent
  end

  local function CLOG_GetObjectiveTrackerReferenceFrame()
    if ObjectiveTrackerFrame then
      if ObjectiveTrackerFrame.BlocksFrame then
        return ObjectiveTrackerFrame.BlocksFrame
      end
      if ObjectiveTrackerFrame.ContentsFrame then
        return ObjectiveTrackerFrame.ContentsFrame
      end
    end
    return ObjectiveTrackerFrame
  end

  local function CLOG_IsObjectiveTrackerCollapsed()
    if not ObjectiveTrackerFrame then return false end
    if ObjectiveTrackerFrame.isCollapsed or ObjectiveTrackerFrame.collapsed then return true end
    if type(ObjectiveTrackerFrame.IsCollapsed) == "function" then
      local ok, collapsed = pcall(ObjectiveTrackerFrame.IsCollapsed, ObjectiveTrackerFrame)
      if ok then return collapsed and true or false end
    end
    return false
  end

  local function CLOG_GetBottommostVisibleTrackerChild(parent)
    if not parent or not parent.GetChildren then return nil, nil, nil end
    local anchorTarget, anchorBottom, anchorLeft = nil, nil, nil
    for _, child in ipairs({ parent:GetChildren() }) do
      if child and child:IsShown() and child.GetBottom then
        local bottom = child:GetBottom()
        if bottom and (anchorBottom == nil or bottom < anchorBottom) then
          anchorBottom = bottom
          anchorLeft = child.GetLeft and child:GetLeft() or nil
          anchorTarget = child
        end
      end
    end
    return anchorTarget, anchorBottom, anchorLeft
  end

  local function CLOG_ObjectiveTrackerHasVisibleSections()
    if not ObjectiveTrackerFrame or not ObjectiveTrackerFrame:IsShown() or CLOG_IsObjectiveTrackerCollapsed() then
      return false
    end
    local parent = CLOG_GetObjectiveTrackerReferenceFrame()
    local anchorTarget = select(1, CLOG_GetBottommostVisibleTrackerChild(parent))
    return anchorTarget ~= nil
  end

  local function CLOG_GetObjectiveTrackerWidth()
    if ObjectiveTrackerFrame and ObjectiveTrackerFrame.Header and ObjectiveTrackerFrame.Header.GetWidth then
      local width = ObjectiveTrackerFrame.Header:GetWidth()
      if width and width > 0 then return width end
    end
    local parent = CLOG_GetObjectiveTrackerReferenceFrame()
    if parent and parent.GetWidth then
      local width = parent:GetWidth()
      if width and width > 0 then return width end
    end
    if ObjectiveTrackerFrame and ObjectiveTrackerFrame.GetWidth then
      local width = ObjectiveTrackerFrame:GetWidth()
      if width and width > 0 then return width end
    end
    return 260
  end

  local function CLOG_ApplyTrackerCollapseState(frame)
    local collapsed = frame and frame.collectionLogCollapsed == true
    if not frame then return end
    if frame.contentFrame then
      frame.contentFrame:SetShown(not collapsed)
    end
    if frame.headerFrame and type(frame.headerFrame.SetCollapsed) == "function" then
      pcall(frame.headerFrame.SetCollapsed, frame.headerFrame, collapsed)
    elseif frame.headerMinimizeButton and frame.headerMinimizeButton.SetNormalAtlas then
      if collapsed then
        pcall(frame.headerMinimizeButton.SetNormalAtlas, frame.headerMinimizeButton, "ObjectiveTracker-PlusButton")
        if frame.headerMinimizeButton.SetPushedAtlas then
          pcall(frame.headerMinimizeButton.SetPushedAtlas, frame.headerMinimizeButton, "ObjectiveTracker-PlusButton")
        end
      else
        pcall(frame.headerMinimizeButton.SetNormalAtlas, frame.headerMinimizeButton, "ObjectiveTracker-MinusButton")
        if frame.headerMinimizeButton.SetPushedAtlas then
          pcall(frame.headerMinimizeButton.SetPushedAtlas, frame.headerMinimizeButton, "ObjectiveTracker-MinusButton")
        end
      end
    end
    if frame.topHeader and type(frame.topHeader.SetCollapsed) == "function" then
      pcall(frame.topHeader.SetCollapsed, frame.topHeader, collapsed)
    end
  end

  local function CLOG_UpdateTrackerHeaderLayout(frame, mode)
    if not frame then return end
    local width = CLOG_GetObjectiveTrackerWidth()
    frame:SetWidth(width)
    if frame.topHeader then frame.topHeader:SetWidth(width) end
    if frame.headerFrame then frame.headerFrame:SetWidth(width) end

    if mode == "append" then
      if frame.topHeader then frame.topHeader:Hide() end
      if frame.headerFrame then
        frame.headerFrame:Show()
        frame.headerFrame:ClearAllPoints()
        frame.headerFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.headerFrame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
      end
      if frame.contentFrame then
        frame.contentFrame:ClearAllPoints()
        frame.contentFrame:SetPoint("TOPLEFT", frame.headerFrame or frame, "BOTTOMLEFT", 0, -2)
        frame.contentFrame:SetPoint("TOPRIGHT", frame.headerFrame or frame, "BOTTOMRIGHT", 0, -2)
      end
    else
      if frame.headerFrame then frame.headerFrame:Hide() end
      if frame.topHeader then
        frame.topHeader:Show()
        frame.topHeader:ClearAllPoints()
        frame.topHeader:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -3)
        frame.topHeader:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -3)
      end
      if frame.contentFrame then
        frame.contentFrame:ClearAllPoints()
        frame.contentFrame:SetPoint("TOPLEFT", frame.topHeader or frame, "BOTTOMLEFT", 0, -2)
        frame.contentFrame:SetPoint("TOPRIGHT", frame.topHeader or frame, "BOTTOMRIGHT", 0, -2)
      end
    end

    if frame.topHeaderText then
      frame.topHeaderText:SetText("Collection Log - Wishlist")
    end
    if frame.headerText then
      frame.headerText:SetText("Collection Log - Wishlist")
    end

    CLOG_ApplyTrackerCollapseState(frame)
  end

  function CLOG_ApplyCollectionTrackerSettings(resetPosition)
    if not UI or not UI.collectionTracker then return end
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.settings = CollectionLogDB.settings or {}
    local frame = UI.collectionTracker
    if CollectionLogDB.settings.enableWishlistObjectiveTracker == false then
      frame:Hide()
      return
    end
    local opacity = CLOG_GetWishlistTrackerOpacity()
    local alpha = opacity / 100
    local unlocked = (CollectionLogDB.settings.wishlistTrackerUnlock == true)

    frame:SetMovable(unlocked)
    frame:EnableMouse(unlocked)
    if unlocked then
      frame:RegisterForDrag("LeftButton")
    else
      frame:RegisterForDrag()
    end

    local mode = frame.currentAnchorMode or "standalone"
    local useBackdrop = (mode ~= "append")
    if frame.SetBackdropColor then
      if useBackdrop then
        frame:SetBackdropColor(0, 0, 0, alpha)
        frame:SetBackdropBorderColor(1, 1, 1, math.min(0.12, 0.02 + (alpha * 0.10)))
      else
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
      end
    end

    if resetPosition then
      frame:StopMovingOrSizing()
      if frame.anchorToObjectiveTracker then frame.anchorToObjectiveTracker(true) end
      return
    end

    if frame.anchorToObjectiveTracker then
      frame.anchorToObjectiveTracker(false)
    end
  end

  function CLOG_CreateCollectionTracker()
    if not UI or UI.collectionTracker then return UI and UI.collectionTracker end
    local parent = CLOG_ObjectiveTrackerParent()
    local frame = CreateFrame("Frame", "CollectionLogObjectiveTracker", parent, "BackdropTemplate")
    UI.collectionTracker = frame
    frame:SetSize(260, 36)
    frame:SetFrameStrata("LOW")
    frame:SetClampedToScreen(true)
    frame:SetMovable(false)
    frame:EnableMouse(false)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 10,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)
    frame.collectionLogCollapsed = false
    frame:Hide()

    frame.topHeader = CreateFrame("Frame", nil, frame, "ObjectiveTrackerContainerHeaderTemplate")
    frame.topHeader:SetHeight(26)
    frame.topHeaderText = frame.topHeader.Text or frame.topHeader.HeaderText
    frame.topHeaderMinimizeButton = frame.topHeader.MinimizeButton or frame.topHeader.CollapseButton

    frame.headerFrame = CreateFrame("Frame", nil, frame, "ObjectiveTrackerModuleHeaderTemplate")
    frame.headerFrame:SetHeight(26)
    frame.headerText = frame.headerFrame.Text or frame.headerFrame.HeaderText
    frame.headerMinimizeButton = frame.headerFrame.MinimizeButton or frame.headerFrame.CollapseButton

    frame.contentFrame = CreateFrame("Frame", nil, frame)

    local function toggleCollapsed()
      frame.collectionLogCollapsed = not frame.collectionLogCollapsed
      CLOG_ApplyTrackerCollapseState(frame)
      if CLOG_RefreshCollectionTracker then CLOG_RefreshCollectionTracker() end
    end

    frame.topHeaderButton = CreateFrame("Button", nil, frame.topHeader)
    frame.topHeaderButton:SetPoint("TOPLEFT", frame.topHeader, "TOPLEFT", 0, 0)
    frame.topHeaderButton:SetPoint("BOTTOMLEFT", frame.topHeader, "BOTTOMLEFT", 0, 0)
    if frame.topHeaderMinimizeButton then
      frame.topHeaderButton:SetPoint("RIGHT", frame.topHeaderMinimizeButton, "LEFT", 0, 0)
      frame.topHeaderMinimizeButton:SetScript("OnClick", toggleCollapsed)
    else
      frame.topHeaderButton:SetPoint("TOPRIGHT", frame.topHeader, "TOPRIGHT", 0, 0)
      frame.topHeaderButton:SetPoint("BOTTOMRIGHT", frame.topHeader, "BOTTOMRIGHT", 0, 0)
    end
    frame.topHeaderButton:RegisterForClicks("LeftButtonUp")
    frame.topHeaderButton:SetScript("OnClick", toggleCollapsed)

    frame.headerButton = CreateFrame("Button", nil, frame.headerFrame)
    frame.headerButton:SetPoint("TOPLEFT", frame.headerFrame, "TOPLEFT", 0, 0)
    frame.headerButton:SetPoint("BOTTOMLEFT", frame.headerFrame, "BOTTOMLEFT", 0, 0)
    if frame.headerMinimizeButton then
      frame.headerButton:SetPoint("RIGHT", frame.headerMinimizeButton, "LEFT", 0, 0)
      frame.headerMinimizeButton:SetScript("OnClick", toggleCollapsed)
    else
      frame.headerButton:SetPoint("TOPRIGHT", frame.headerFrame, "TOPRIGHT", 0, 0)
      frame.headerButton:SetPoint("BOTTOMRIGHT", frame.headerFrame, "BOTTOMRIGHT", 0, 0)
    end
    frame.headerButton:RegisterForClicks("LeftButtonUp")
    frame.headerButton:SetScript("OnClick", toggleCollapsed)

    local function anchor(forceDefault)
      CollectionLogDB = CollectionLogDB or {}
      CollectionLogDB.settings = CollectionLogDB.settings or {}
      frame:ClearAllPoints()

      local point = CollectionLogDB.settings.wishlistTrackerPoint
      local relativePoint = CollectionLogDB.settings.wishlistTrackerRelativePoint
      local x = CollectionLogDB.settings.wishlistTrackerX
      local y = CollectionLogDB.settings.wishlistTrackerY
      local unlocked = (CollectionLogDB.settings.wishlistTrackerUnlock == true)
      local useManualPoint = (not forceDefault) and point and relativePoint and x and y

      if unlocked and useManualPoint then
        frame.currentAnchorMode = "manual"
        frame:SetPoint(point, UIParent, relativePoint, x, y)
      elseif unlocked then
        frame.currentAnchorMode = "manual"
        if ObjectiveTrackerFrame and ObjectiveTrackerFrame:IsShown() then
          frame:SetPoint("TOPRIGHT", ObjectiveTrackerFrame, "TOPRIGHT", 0, 0)
        else
          frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -260)
        end
      elseif CLOG_ObjectiveTrackerHasVisibleSections() then
        frame.currentAnchorMode = "append"
        local nativeParent = CLOG_GetObjectiveTrackerReferenceFrame()
        local anchorTarget, _, anchorLeft = CLOG_GetBottommostVisibleTrackerChild(nativeParent)
        if anchorTarget then
          local parentLeft = nativeParent and nativeParent.GetLeft and nativeParent:GetLeft() or nil
          local offsetX = 0
          if parentLeft and anchorLeft then
            offsetX = parentLeft - anchorLeft
          end
          frame:SetPoint("TOPLEFT", anchorTarget, "BOTTOMLEFT", offsetX, -10)
        elseif ObjectiveTrackerFrame then
          frame:SetPoint("TOPLEFT", ObjectiveTrackerFrame, "TOPLEFT", 0, 0)
          frame:SetPoint("TOPRIGHT", ObjectiveTrackerFrame, "TOPRIGHT", 0, 0)
        else
          frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -260)
        end
      else
        frame.currentAnchorMode = "standalone"
        if useManualPoint then
          frame:SetPoint(point, UIParent, relativePoint, x, y)
        elseif ObjectiveTrackerFrame and ObjectiveTrackerFrame:IsShown() then
          frame:SetPoint("TOPLEFT", ObjectiveTrackerFrame, "TOPLEFT", 0, 0)
          frame:SetPoint("TOPRIGHT", ObjectiveTrackerFrame, "TOPRIGHT", 0, 0)
        else
          frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -260)
        end
      end

      CLOG_UpdateTrackerHeaderLayout(frame, frame.currentAnchorMode)
      if frame.SetFrameStrata then
        frame:SetFrameStrata(frame.currentAnchorMode == "append" and "LOW" or "MEDIUM")
      end
    end

    frame.anchorToObjectiveTracker = anchor
    anchor(false)

    frame:SetScript("OnDragStart", function(self)
      if not (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.wishlistTrackerUnlock == true) then return end
      self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      CollectionLogDB = CollectionLogDB or {}
      CollectionLogDB.settings = CollectionLogDB.settings or {}
      local point, _, relativePoint, x, y = self:GetPoint(1)
      CollectionLogDB.settings.wishlistTrackerPoint = point
      CollectionLogDB.settings.wishlistTrackerRelativePoint = relativePoint
      CollectionLogDB.settings.wishlistTrackerX = x
      CollectionLogDB.settings.wishlistTrackerY = y
      self.currentAnchorMode = "manual"
      CLOG_UpdateTrackerHeaderLayout(self, self.currentAnchorMode)
    end)

    if ObjectiveTrackerFrame and not frame._clTrackerHooksInstalled then
      frame._clTrackerHooksInstalled = true
      local syncPending = false
      local function syncTrackerAnchor()
        -- v4.3.71: ObjectiveTracker.Update can fire very often. Rebuilding the
        -- entire Wishlist tracker from this hook made the Wishlist system look
        -- like a constant CPU user. These hooks now only re-anchor the existing
        -- frame, and even that is coalesced.
        if syncPending then return end
        syncPending = true
        local function run()
          syncPending = false
          if UI and UI.collectionTracker and UI.collectionTracker:IsShown() and UI.collectionTracker.anchorToObjectiveTracker then
            pcall(UI.collectionTracker.anchorToObjectiveTracker, UI.collectionTracker, false)
          end
        end
        if C_Timer and C_Timer.After then C_Timer.After(0.25, run) else run() end
      end
      if type(ObjectiveTrackerFrame.Update) == "function" then
        hooksecurefunc(ObjectiveTrackerFrame, "Update", syncTrackerAnchor)
      elseif type(ObjectiveTracker_Update) == "function" then
        hooksecurefunc("ObjectiveTracker_Update", syncTrackerAnchor)
      end
      ObjectiveTrackerFrame:HookScript("OnShow", syncTrackerAnchor)
      ObjectiveTrackerFrame:HookScript("OnHide", syncTrackerAnchor)
      ObjectiveTrackerFrame:HookScript("OnSizeChanged", syncTrackerAnchor)
      if ObjectiveTrackerFrame.BlocksFrame and ObjectiveTrackerFrame.BlocksFrame.HookScript then
        ObjectiveTrackerFrame.BlocksFrame:HookScript("OnShow", syncTrackerAnchor)
        ObjectiveTrackerFrame.BlocksFrame:HookScript("OnHide", syncTrackerAnchor)
      end
      if ObjectiveTrackerFrame.ContentsFrame and ObjectiveTrackerFrame.ContentsFrame.HookScript then
        ObjectiveTrackerFrame.ContentsFrame:HookScript("OnShow", syncTrackerAnchor)
        ObjectiveTrackerFrame.ContentsFrame:HookScript("OnHide", syncTrackerAnchor)
      end
      if type(ObjectiveTrackerFrame.SetCollapsed) == "function" then
        hooksecurefunc(ObjectiveTrackerFrame, "SetCollapsed", syncTrackerAnchor)
      end
      if type(UIParent_ManageFramePositions) == "function" then
        hooksecurefunc("UIParent_ManageFramePositions", syncTrackerAnchor)
      end
    end

    CLOG_ApplyCollectionTrackerSettings(false)
    return frame
  end

function CLOG_ApplyWaypointButtonState(button, hasWaypoint, opts)
    if not button then return end
    opts = opts or {}
    button._clHasWaypoint = hasWaypoint and true or false
    if opts.disableWhenUnavailable then
      if hasWaypoint then button:Enable() else button:Disable() end
    else
      button:Enable()
    end
    local normal = button.GetNormalTexture and button:GetNormalTexture() or nil
    local pushed = button.GetPushedTexture and button:GetPushedTexture() or nil
    local highlight = button.GetHighlightTexture and button:GetHighlightTexture() or nil
    if normal and normal.SetDesaturated then normal:SetDesaturated(not hasWaypoint) end
    if pushed and pushed.SetDesaturated then pushed:SetDesaturated(not hasWaypoint) end
    if highlight and highlight.SetDesaturated then highlight:SetDesaturated(not hasWaypoint) end
    local alpha = hasWaypoint and (opts.availableAlpha or 1) or (opts.unavailableAlpha or 0.45)
    if normal and normal.SetAlpha then normal:SetAlpha(alpha) end
    if pushed and pushed.SetAlpha then pushed:SetAlpha(alpha) end
    if highlight and highlight.SetAlpha then highlight:SetAlpha(hasWaypoint and 0.9 or 0.25) end
    if button.SetAlpha then button:SetAlpha(1) end
  end

  function CLOG_RefreshCollectionTracker()
    if not UI then return end
    EnsureSettingsDB()
    local frame = CLOG_CreateCollectionTracker()
    if not frame then return end
    if CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.enableWishlistObjectiveTracker == false then
      frame:Hide()
      local rows = CLOG_GetTrackedObjectiveRows()
      for i = 1, #rows do rows[i]:Hide() end
      return
    end
    Wishlist.RestoreTrackedState()
    local tracked = Wishlist.GetTrackedEntries and Wishlist.GetTrackedEntries() or {}
    local rows = CLOG_GetTrackedObjectiveRows()
    if #tracked == 0 then
      frame:Hide()
      for i = 1, #rows do rows[i]:Hide() end
      return
    end

    frame:Show()
    if frame.anchorToObjectiveTracker then frame.anchorToObjectiveTracker(false) end
    if CLOG_ApplyCollectionTrackerSettings then CLOG_ApplyCollectionTrackerSettings(false) end

    local width = CLOG_GetObjectiveTrackerWidth()
    local rowH = 34
    local sidePadding = 0
    local contentWidth = math.max(200, width - (sidePadding * 2))
    local isAppend = (frame.currentAnchorMode == "append")

    if frame.topHeaderText then frame.topHeaderText:SetText("Collection Log - Wishlist") end
    if frame.headerText then frame.headerText:SetText("Collection Log - Wishlist") end

    for i, entry in ipairs(tracked) do
      local row = rows[i]
      if not row then
        row = CreateFrame("Button", nil, frame.contentFrame)
        rows[i] = row
        row:SetHeight(rowH)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(1, 1)
        row.icon:SetAlpha(0)
        row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -4)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 26, -1)
        row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetJustifyV("TOP")
        if row.name.SetWordWrap then row.name:SetWordWrap(false) end
        if row.name.SetMaxLines then row.name:SetMaxLines(1) end

        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
        row.sub:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, 0)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetJustifyV("TOP")
        if row.sub.SetWordWrap then row.sub:SetWordWrap(false) end
        if row.sub.SetMaxLines then row.sub:SetMaxLines(1) end
        row.sub:SetTextColor(0.76, 0.76, 0.76, 1)

        row.pin = CreateFrame("Button", nil, row)
        row.pin:SetSize(22, 22)
        row.pin:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -1)
        if row.pin.SetNormalAtlas then
          pcall(row.pin.SetNormalAtlas, row.pin, "Waypoint-MapPin-Tracked")
          if row.pin.SetHighlightAtlas then
            pcall(row.pin.SetHighlightAtlas, row.pin, "Waypoint-MapPin-Tracked", "ADD")
          end
        else
          row.pin:SetNormalTexture("Interface\\MINIMAP\\TRACKING\\None")
        end


        row.pin:SetScript("OnClick", function(self)
          local e = self:GetParent()._clEntry
          if not e then return end
          if not self._clHasWaypoint then return end
          if Wishlist.ApplyTrackedWaypoint then Wishlist.ApplyTrackedWaypoint(e) end
          if Wishlist.OpenWaypoint then Wishlist.OpenWaypoint(e) end
        end)

        local function CLOG_OpenWishlistFromTracker(entry)
          if not entry then return end
          if not UI.frame then
            if UI.Init then
              local ok = pcall(UI.Init)
              if not ok or not UI.frame then return end
            else
              return
            end
          end
          CollectionLogDB = CollectionLogDB or {}
          CollectionLogDB.ui = CollectionLogDB.ui or {}
          CollectionLogDB.ui.activeCategory = "Wishlist"
          CollectionLogDB.ui.activeGroupId = "wishlist:all"
          CollectionLogDB.ui._forceDefaultGroup = false
          if not UI.frame:IsShown() then UI.frame:Show() end
          if UI.frame.Raise then UI.frame:Raise() end
          if UI.RefreshAll then pcall(UI.RefreshAll) end
          if UI.ShowWishlist then UI.ShowWishlist(true) end
          if UI.RefreshWishlist then UI.RefreshWishlist() end
        end
        row.pin:SetScript("OnEnter", function(self)
          local e = self:GetParent()._clEntry
          if not e then return end
          GameTooltip:SetOwner(self, "ANCHOR_LEFT")
          GameTooltip:AddLine(WishlistEntryDisplayName(e) or "Tracked Item", 1, 1, 1)
          GameTooltip:AddLine(Wishlist.SourceDisplayText(e), 0.8, 0.8, 0.8, true)
          if not self._clHasWaypoint then
            GameTooltip:AddLine("Waypoint unavailable", 0.6, 0.6, 0.6, true)
          end
          GameTooltip:Show()
        end)
        row.pin:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:SetScript("OnClick", function(self, button)
          local e = self._clEntry
          if not e then return end
          if button == "RightButton" then
            Wishlist.SetTrackedEntry(e, false)
            if UI and UI.RefreshWishlist then UI.RefreshWishlist() end
            if CLOG_RefreshCollectionTracker then CLOG_RefreshCollectionTracker() end
            return
          end
          CLOG_OpenWishlistFromTracker(e)
        end)
        row:SetScript("OnEnter", function(self)
          local e = self._clEntry
          if not e then return end
          GameTooltip:SetOwner(self, "ANCHOR_LEFT")
          GameTooltip:AddLine(WishlistEntryDisplayName(e) or "Tracked Item", 1, 1, 1)
          GameTooltip:AddLine(Wishlist.SourceDisplayText(e), 0.8, 0.8, 0.8, true)
          GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      end

      row:SetWidth(contentWidth)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", frame.contentFrame, "TOPLEFT", sidePadding, -((i - 1) * rowH))
      row._clEntry = entry
      if row.name.SetWidth then row.name:SetWidth(math.max(140, contentWidth - 34)) end
      if row.sub.SetWidth then row.sub:SetWidth(math.max(140, contentWidth - 34)) end
      row.name:SetText(WishlistEntryDisplayName(entry) or "Tracked Item")
      row.sub:SetText(Wishlist.SourceDisplayText(entry) or "Unknown Source")
      local hasWaypoint = Wishlist.EntryHasWaypoint(entry)
      row.pin:SetShown(true)
      CLOG_ApplyWaypointButtonState(row.pin, hasWaypoint)
      row.icon:SetShown(false)
      row:Show()
    end

    for i = #tracked + 1, #rows do rows[i]:Hide() end

    local headerHeight = isAppend and 26 or 29
    local contentHeight = frame.collectionLogCollapsed and 0 or (#tracked * rowH)
    frame.contentFrame:SetHeight(contentHeight)
    frame:SetHeight(headerHeight + contentHeight + (frame.collectionLogCollapsed and 0 or 6))
  end

  local wishlistTrackerBootstrapPending = false
  local wishlistTrackerBootstrapAttempts = 0

  local function CLOG_TryBootstrapCollectionTracker()
    if Wishlist and Wishlist.RestoreTrackedState then
      pcall(Wishlist.RestoreTrackedState)
    end
    if Wishlist and Wishlist.RefreshTrackedDisplayNames then
      pcall(Wishlist.RefreshTrackedDisplayNames)
    end
    if CLOG_CreateCollectionTracker then
      pcall(CLOG_CreateCollectionTracker)
    end
    if CLOG_RefreshCollectionTracker then
      pcall(CLOG_RefreshCollectionTracker)
    end

    local frame = UI and UI.collectionTracker
    local tracked = Wishlist and Wishlist.GetTrackedEntries and Wishlist.GetTrackedEntries() or {}
    local ready = frame and frame:IsShown() and #tracked > 0
    if ready or wishlistTrackerBootstrapAttempts >= 8 then
      wishlistTrackerBootstrapPending = false
      return
    end

    wishlistTrackerBootstrapAttempts = wishlistTrackerBootstrapAttempts + 1
    local delay = ObjectiveTrackerFrame and 0.5 or 1.0
    C_Timer.After(delay, CLOG_TryBootstrapCollectionTracker)
  end

  local function CLOG_BootstrapCollectionTrackerOnLogin()
    if wishlistTrackerBootstrapPending then return end
    wishlistTrackerBootstrapPending = true
    wishlistTrackerBootstrapAttempts = 0
    C_Timer.After(0.25, CLOG_TryBootstrapCollectionTracker)
  end

  local trackerBootstrapFrame = CreateFrame("Frame")
  trackerBootstrapFrame:RegisterEvent("VARIABLES_LOADED")
  trackerBootstrapFrame:RegisterEvent("PLAYER_LOGIN")
  trackerBootstrapFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  trackerBootstrapFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  trackerBootstrapFrame:SetScript("OnEvent", function()
    if CLOG_BootstrapCollectionTrackerOnLogin then
      pcall(CLOG_BootstrapCollectionTrackerOnLogin)
    end
  end)
end

if C_Timer and C_Timer.After then
  C_Timer.After(1, function()
    if CLOG_BootstrapCollectionTrackerOnLogin then
      pcall(CLOG_BootstrapCollectionTrackerOnLogin)
    elseif CLOG_RefreshCollectionTracker then
      pcall(CLOG_RefreshCollectionTracker)
    end
  end)
end

-- ======================
-- History (fullscreen) tab
-- ======================
local history = CreateFrame("Frame", nil, f, "BackdropTemplate")
UI.history = history
history:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(TOPBAR_H + TAB_H + 36))
history:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, PAD)
CreateBorder(history)
history:Hide()
history:SetFrameLevel((right:GetFrameLevel() or 1) + 20)

local hTitle = history:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
hTitle:SetPoint("TOPLEFT", history, "TOPLEFT", 12, -12)
hTitle:SetText("History")

local hSub = history:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hSub:SetPoint("TOPLEFT", hTitle, "BOTTOMLEFT", 0, -4)
hSub:SetText("Newest collections first.")
UI.historySummary = hSub

local clearBtn = CreateFrame("Button", nil, history, "UIPanelButtonTemplate")
clearBtn:SetSize(90, 22)
clearBtn:SetPoint("TOPRIGHT", history, "TOPRIGHT", -12, -10)
clearBtn:SetText("Clear")
clearBtn:SetScript("OnClick", function()
  StaticPopup_Show("COLLECTIONLOG_CLEAR_HISTORY")
end)
UI.historyClearButton = clearBtn

local headerRow = CreateFrame("Frame", nil, history)
UI.historyHeaderRow = headerRow
headerRow:SetPoint("TOPLEFT", history, "TOPLEFT", 10, -50)
headerRow:SetPoint("TOPRIGHT", history, "TOPRIGHT", -30, -50)
headerRow:SetHeight(24)

local hs = CreateFrame("ScrollFrame", "CollectionLogHistoryScroll", history, "UIPanelScrollFrameTemplate")
UI.historyScroll = hs
hs:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
hs:SetPoint("BOTTOMRIGHT", history, "BOTTOMRIGHT", -30, 10)

local hsContent = CreateFrame("Frame", nil, hs)
hsContent:SetSize(100, 100)
hs:SetScrollChild(hsContent)
UI.historyScrollContent = hsContent
UI.historyRows = UI.historyRows or {}

local function CLOG_FormatHistoryWhen(ts)
  ts = tonumber(ts or 0) or 0
  if ts <= 0 then return "Unknown" end
  if date then
    return date("%m-%d-%Y", ts)
  end
  return tostring(ts)
end

local function CLOG_GetDifficultyLabel(difficultyID)
  difficultyID = tonumber(difficultyID)
  if not difficultyID then return nil end
  if GetDifficultyInfo then
    local ok, name = pcall(GetDifficultyInfo, difficultyID)
    if ok and name and name ~= "" then
      return tostring(name)
    end
  end
  return tostring(difficultyID)
end

local function CLOG_GetHistoryTypeText(entry)
  local raw = tostring((entry and (entry.kind or entry.type)) or "")
  local key = string.lower(raw)
  if key == "appearance" or key == "transmog" then return "Appearance" end
  if key == "mount" then return "Mount" end
  if key == "pet" then return "Pet" end
  if key == "toy" then return "Toy" end
  if key == "housing" then return "Housing" end
  if key == "item" then return "Item" end
  if raw ~= "" then
    return raw:gsub("^%l", string.upper)
  end
  return "Unknown"
end

local function CLOG_ResolveHistoryInstanceName(entry)
  if type(entry) ~= "table" then return nil end
  local explicitName = entry.instanceName or entry.sourceInstanceName
  if explicitName and tostring(explicitName) ~= "" then
    return tostring(explicitName)
  end

  local wantMapID = tonumber(entry.mapID)
  local wantInstanceID = tonumber(entry.ejInstanceID)
  local wantDiff = tonumber(entry.difficultyID)

  if ns and ns.Data and type(ns.Data.groups) == "table" then
    for _, g in pairs(ns.Data.groups) do
      if type(g) == "table" then
        local gMapID = tonumber(g.mapID)
        local gInstanceID = tonumber(g.instanceID)
        local gDiff = tonumber(g.difficultyID)
        local instanceMatch = false
        if wantMapID and gMapID and wantMapID == gMapID then instanceMatch = true end
        if wantInstanceID and gInstanceID and wantInstanceID == gInstanceID then instanceMatch = true end
        if wantMapID and gInstanceID and wantMapID == gInstanceID then instanceMatch = true end
        if wantInstanceID and gMapID and wantInstanceID == gMapID then instanceMatch = true end
        if instanceMatch and ((not wantDiff) or gDiff == wantDiff) then
          local name = g.name or g.label or g.title
          if name and name ~= "" then
            return tostring(name)
          end
        end
      end
    end
  end

  if wantInstanceID and EJ_GetInstanceInfo then
    local ok, name = pcall(EJ_GetInstanceInfo, wantInstanceID)
    if ok and name and name ~= "" then
      return tostring(name)
    end
  end

  if wantMapID and C_Map and C_Map.GetMapInfo then
    local ok, info = pcall(C_Map.GetMapInfo, wantMapID)
    if ok and info and info.name and info.name ~= "" then
      return tostring(info.name)
    end
  end

  return nil
end

local function CLOG_GetHistorySourceText(entry)
  if type(entry) ~= "table" then return "Unknown Source" end

  local function IsBagValue(v)
    if v == nil then return false end
    local s = tostring(v):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return s == "bag" or s == "bags" or s == "inventory" or s == "container" or s == "containers"
  end

  if IsBagValue(entry.sourceType) or IsBagValue(entry.obtainType) or IsBagValue(entry.acquisitionType) then
    return "Bag"
  end
  if IsBagValue(entry.source) or IsBagValue(entry.sourceLabel) or IsBagValue(entry.sourceName) or IsBagValue(entry.sourceText) then
    return "Bag"
  end
  if type(entry.meta) == "table" and (IsBagValue(entry.meta.sourceType) or IsBagValue(entry.meta.obtainType) or IsBagValue(entry.meta.acquisitionType) or IsBagValue(entry.meta.source)) then
    return "Bag"
  end
  if type(entry.sourceContext) == "table" and (IsBagValue(entry.sourceContext.sourceType) or IsBagValue(entry.sourceContext.obtainType) or IsBagValue(entry.sourceContext.acquisitionType) or IsBagValue(entry.sourceContext.source)) then
    return "Bag"
  end

  if type(WishlistGetExactSourceFromEntry) == "function" then
    local exact = Wishlist.GetExactSourceFromEntry(entry)
    if exact and exact ~= "" then
      return exact
    end
  end

  local diff = entry.sourceDifficulty
  if (not diff or tostring(diff) == "") and entry.difficultyID and type(DifficultyShortLabel) == "function" then
    diff = DifficultyShortLabel(entry.difficultyID, entry.mode)
  end
  if (not diff or tostring(diff) == "") then
    diff = CLOG_GetDifficultyLabel(entry.difficultyID)
  end
  diff = type(WishlistTrimText) == "function" and Wishlist.TrimText(diff) or diff

  local instanceName = CLOG_ResolveHistoryInstanceName(entry)
  if type(WishlistNormalizeSourceValue) == "function" then
    instanceName = Wishlist.NormalizeSourceValue(instanceName)
  elseif instanceName and tostring(instanceName) ~= "" then
    instanceName = tostring(instanceName)
  else
    instanceName = nil
  end

  if instanceName and instanceName ~= "" then
    local patternDiff = diff and tostring(diff):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    if diff and tostring(diff) ~= "" and not tostring(instanceName):find("%(" .. patternDiff .. "%)$") then
      return string.format("%s (%s)", tostring(instanceName), tostring(diff))
    end
    return tostring(instanceName)
  end

  local sourceLabel = entry.sourceLabel or entry.sourceName or entry.source
  if type(WishlistNormalizeSourceValue) == "function" then
    sourceLabel = Wishlist.NormalizeSourceValue(sourceLabel)
  elseif sourceLabel and tostring(sourceLabel) ~= "" then
    sourceLabel = tostring(sourceLabel)
  else
    sourceLabel = nil
  end
  if sourceLabel and sourceLabel ~= "" then
    return sourceLabel
  end

  return "Unknown Source"
end

local function CLOG_GetHistoryCharacterText(entry)
  if type(entry) ~= "table" then return "Unknown" end
  local who = entry.characterFullName or entry.characterName or entry.character
  if who and tostring(who) ~= "" then return tostring(who) end
  return "Unknown"
end

local function CLOG_GetHistoryList()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.collectionHistory = CollectionLogDB.collectionHistory or {}
  return CollectionLogDB.collectionHistory
end

local function CLOG_PreviewHistoryEntry(entry)
  if type(entry) ~= "table" then return end

  if entry.mountID then
    if ToggleCollectionsJournal then
      pcall(ToggleCollectionsJournal, 1)
    elseif CollectionsJournal and CollectionsJournal.SetShown then
      pcall(CollectionsJournal.SetShown, CollectionsJournal, true)
    elseif CollectionsJournal and CollectionsJournal.Show then
      pcall(CollectionsJournal.Show, CollectionsJournal)
    end

    if CollectionsJournal_SetTab and CollectionsJournal then
      pcall(CollectionsJournal_SetTab, CollectionsJournal, 1)
    end

    if C_MountJournal and C_MountJournal.SetSelectedMountID then
      pcall(C_MountJournal.SetSelectedMountID, entry.mountID)
    elseif MountJournal_SelectByMountID then
      pcall(MountJournal_SelectByMountID, entry.mountID)
    elseif MountJournal and MountJournal.SelectByMountID then
      pcall(MountJournal.SelectByMountID, MountJournal, entry.mountID)
    end
    return
  end

  if entry.speciesID then
    if (not CollectionsJournal) and UIParentLoadAddOn then
      pcall(UIParentLoadAddOn, "Blizzard_Collections")
    end

    if ToggleCollectionsJournal then
      pcall(ToggleCollectionsJournal, 2)
    elseif CollectionsJournal and CollectionsJournal.SetShown then
      pcall(CollectionsJournal.SetShown, CollectionsJournal, true)
    elseif CollectionsJournal and CollectionsJournal.Show then
      pcall(CollectionsJournal.Show, CollectionsJournal)
    end

    if CollectionsJournal_SetTab and CollectionsJournal then
      pcall(CollectionsJournal_SetTab, CollectionsJournal, 2)
    end

    if ns.HookPetJournalFilterCleanup then
      pcall(ns.HookPetJournalFilterCleanup)
    end

    local speciesID = entry.speciesID
    local petName
    if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
      local okName, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
      if okName then petName = name end
    end

    if PetJournal_SelectSpecies then
      pcall(PetJournal_SelectSpecies, speciesID)
    elseif PetJournal and PetJournal.SelectSpecies then
      pcall(PetJournal.SelectSpecies, PetJournal, speciesID)
    elseif C_PetJournal and C_PetJournal.SetSelectedPetSpeciesID then
      pcall(C_PetJournal.SetSelectedPetSpeciesID, speciesID)
    elseif C_PetJournal and C_PetJournal.SetSelectedSpeciesID then
      pcall(C_PetJournal.SetSelectedSpeciesID, speciesID)
    end

    if C_PetJournal and C_PetJournal.SetSearchFilter and petName then
      pcall(C_PetJournal.SetSearchFilter, petName)
    end

    if C_Timer and C_Timer.NewTicker and C_PetJournal and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
      local tries = 0
      local ticker
      ticker = C_Timer.NewTicker(0.05, function()
        tries = tries + 1
        local okNum, num = pcall(C_PetJournal.GetNumPets)
        if okNum and type(num) == "number" and num > 0 then
          local targetPetID
          for i = 1, num do
            local okInfo, petID, sID = pcall(C_PetJournal.GetPetInfoByIndex, i)
            if okInfo and petID and sID == speciesID then
              targetPetID = petID
              break
            end
          end
          if targetPetID then
            if PetJournal_SelectPet then
              pcall(PetJournal_SelectPet, targetPetID)
            elseif C_PetJournal.SetSelectedPetID then
              pcall(C_PetJournal.SetSelectedPetID, targetPetID)
            end
            if PetJournal_UpdatePetCard then
              pcall(PetJournal_UpdatePetCard) end
            if ticker and ticker.Cancel then ticker:Cancel() end
            return
          end
        end
        if tries >= 30 and ticker and ticker.Cancel then ticker:Cancel() end
      end)
    else
      if C_PetJournal and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
        local okNum, num = pcall(C_PetJournal.GetNumPets)
        if okNum and type(num) == "number" and num > 0 then
          for i = 1, num do
            local okInfo, petID, sID = pcall(C_PetJournal.GetPetInfoByIndex, i)
            if okInfo and petID and sID == speciesID then
              if C_PetJournal.SetSelectedPetID then pcall(C_PetJournal.SetSelectedPetID, petID) end
              if PetJournal_UpdatePetCard then pcall(PetJournal_UpdatePetCard) end
              break
            end
          end
        end
      end
    end
    return
  end

  local itemID = tonumber(entry.itemID)
  if (not itemID or itemID <= 0) and entry.mountID and CL_LatestResolveMountItemID then
    itemID = CL_LatestResolveMountItemID(entry.mountID)
  elseif (not itemID or itemID <= 0) and entry.speciesID and CL_LatestResolvePetItemID then
    itemID = CL_LatestResolvePetItemID(entry.speciesID)
  end

  if itemID and itemID > 0 then
    local link = (GetItemInfo and select(2, GetItemInfo(itemID))) or nil
    if not link and C_Item and C_Item.GetItemLinkByID then
      local okLink, resolved = pcall(C_Item.GetItemLinkByID, itemID)
      if okLink and type(resolved) == "string" and resolved ~= "" then
        link = resolved
      end
    end
    if not link then link = "item:" .. tostring(itemID) end

    if DressUpItemLink and link then
      pcall(DressUpItemLink, link)
    elseif HandleModifiedItemClick and link then
      pcall(HandleModifiedItemClick, link)
    end
  end
end

local HISTORY_COLS = {
  { key = "icon",      label = "",          fixed = 36 },
  { key = "name",      label = "Item Name", min = 230, weight = 0.42 },
  { key = "type",      label = "Item Type", fixed = 108 },
  { key = "source",    label = "Source",    min = 290, weight = 0.58 },
  { key = "character", label = "Character", fixed = 156 },
  { key = "date",      label = "Date",      fixed = 104 },
}

local HISTORY_GAPS = { 18, 22, 12, 18, 10 }

local function CLOG_GetHistoryGap(index)
  return tonumber(HISTORY_GAPS[index] or 12) or 12
end

local function CLOG_GetHistoryColumnWidths(totalWidth)
  local widths = {}
  local gapSpace = 0
  for i = 1, (#HISTORY_COLS - 1) do
    gapSpace = gapSpace + CLOG_GetHistoryGap(i)
  end

  local innerWidth = math.max(560, math.floor((totalWidth or 0) - 18 - gapSpace))

  local iconW = 36
  local typeW = 88
  local dateW = 100
  local charW = 130

  local fixedWidth = iconW + typeW + dateW + charW
  local flexibleWidth = math.max(320, innerWidth - fixedWidth)

  local nameMin = 250
  local sourceMin = 170
  local nameW, sourceW

  if flexibleWidth >= (nameMin + sourceMin) then
    local extra = flexibleWidth - (nameMin + sourceMin)
    nameW = nameMin + math.floor(extra * 0.45)
    sourceW = sourceMin + (extra - math.floor(extra * 0.45))
  else
    nameW = math.max(180, math.floor(flexibleWidth * 0.52))
    sourceW = math.max(140, flexibleWidth - nameW)
    if (nameW + sourceW) > flexibleWidth then
      sourceW = math.max(120, flexibleWidth - nameW)
    end
  end

  widths[1] = iconW
  widths[2] = nameW
  widths[3] = typeW
  widths[4] = sourceW
  widths[5] = charW
  widths[6] = dateW

  return widths
end

local headerFonts = {}
for i, col in ipairs(HISTORY_COLS) do
  local fs = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  headerFonts[i] = fs
  fs:SetTextColor(1, 0.82, 0, 1)
  fs:SetJustifyH((i == #HISTORY_COLS or i == (#HISTORY_COLS - 1)) and "RIGHT" or "LEFT")
  fs:SetText(col.label)
end
UI.historyHeaderFonts = headerFonts

local function CLOG_LayoutHistoryColumns()
  local available = math.max(640, (UI.historyScroll and UI.historyScroll:GetWidth() or 900) - 8)
  local widths = CLOG_GetHistoryColumnWidths(available)
  UI.historyColumnWidths = widths

  local leftInset = 8
  local rightInset = 10
  local topOffset = -4
  local gapNameType = CLOG_GetHistoryGap(2)
  local gapTypeSource = CLOG_GetHistoryGap(3)
  local gapSourceCharacter = CLOG_GetHistoryGap(4)
  local gapCharacterDate = CLOG_GetHistoryGap(5)

  local iconFS = headerFonts[1]
  local nameFS = headerFonts[2]
  local typeFS = headerFonts[3]
  local sourceFS = headerFonts[4]
  local characterFS = headerFonts[5]
  local dateFS = headerFonts[6]

  for _, fs in ipairs(headerFonts) do
    fs:ClearAllPoints()
  end

  if iconFS then
    iconFS:SetPoint("TOPLEFT", headerRow, "TOPLEFT", leftInset, topOffset)
    iconFS:SetWidth(widths[1] or 36)
  end

  if dateFS then
    dateFS:SetPoint("TOPRIGHT", headerRow, "TOPRIGHT", -rightInset, topOffset)
    dateFS:SetWidth(widths[6] or 104)
    dateFS:SetJustifyH("RIGHT")
  end

  if characterFS then
    characterFS:SetPoint("TOPRIGHT", dateFS, "TOPLEFT", -gapCharacterDate, 0)
    characterFS:SetWidth(widths[5] or 156)
    characterFS:SetJustifyH("RIGHT")
  end

  if nameFS then
    nameFS:SetPoint("TOPLEFT", headerRow, "TOPLEFT", leftInset + (widths[1] or 36) + CLOG_GetHistoryGap(1), topOffset)
    nameFS:SetWidth(widths[2] or 230)
    nameFS:SetJustifyH("LEFT")
  end

  if typeFS then
    typeFS:SetPoint("TOPLEFT", nameFS, "TOPRIGHT", gapNameType, 0)
    typeFS:SetWidth(widths[3] or 108)
    typeFS:SetJustifyH("LEFT")
  end

  if sourceFS then
    sourceFS:SetPoint("TOPLEFT", typeFS, "TOPRIGHT", gapTypeSource, 0)
    sourceFS:SetPoint("TOPRIGHT", characterFS, "TOPLEFT", -gapSourceCharacter, 0)
    sourceFS:SetJustifyH("LEFT")
  end
end

function UI.RefreshHistory()
  if not UI.history or not UI.historyRows then return end

  local historyList = CLOG_GetHistoryList()
  local rows = UI.historyRows
  local rowH = 28
  local padY = 2
  local viewportW = math.max(640, (UI.historyScroll and UI.historyScroll:GetWidth() or 900) - 8)
  local widths = CLOG_GetHistoryColumnWidths(viewportW)
  local contentW = viewportW
  UI.historyColumnWidths = widths
  CLOG_LayoutHistoryColumns()

  for i, entry in ipairs(historyList) do
    local row = rows[i]
    if not row then
      row = CreateFrame("Button", nil, hsContent, "BackdropTemplate")
      row:SetHeight(rowH)
      row:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
      })
      row:SetBackdropColor(0.08, 0.08, 0.08, 0.55)
      row:SetBackdropBorderColor(1, 1, 1, 0.10)

      row.icon = row:CreateTexture(nil, "ARTWORK")
      row.icon:SetSize(20, 20)

      row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      row.typeFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.sourceFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.characterFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.dateFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      for _, fs in ipairs({ row.nameFS, row.typeFS, row.sourceFS, row.characterFS, row.dateFS }) do
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        fs:SetMaxLines(1)
      end
      row.characterFS:SetJustifyH("RIGHT")
      row.dateFS:SetJustifyH("RIGHT")

      row:SetScript("OnEnter", function(self)
        local histEntry = self._clEntry
        if not histEntry then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local itemLink = histEntry.itemLink
        local itemID = tonumber(histEntry.itemID)
        if itemLink and GameTooltip.SetHyperlink then
          GameTooltip:SetHyperlink(itemLink)
        elseif itemID and itemID > 0 and GameTooltip.SetItemByID then
          GameTooltip:SetItemByID(itemID)
        else
          GameTooltip:SetText(histEntry.name or "Unknown")
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Type: " .. CLOG_GetHistoryTypeText(histEntry), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Source: " .. CLOG_GetHistorySourceText(histEntry), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Character: " .. CLOG_GetHistoryCharacterText(histEntry), 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Recorded: " .. CLOG_FormatHistoryWhen(histEntry.ts), 0.8, 0.8, 0.8)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Ctrl+Left Click to preview", 0.0, 1.0, 0.0)
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() GameTooltip:Hide() end)
      row:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if not (IsControlKeyDown and IsControlKeyDown()) then return end
        CLOG_PreviewHistoryEntry(self._clEntry)
      end)

      rows[i] = row
    end

    row:SetWidth(viewportW)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", hsContent, "TOPLEFT", 0, -((i - 1) * (rowH + padY)))
    row.icon:SetTexture(entry.icon or "Interface\\Icons\\inv_misc_questionmark")

    local leftInset = 8
    local rightInset = 10
    local gapIconName = CLOG_GetHistoryGap(1)
    local gapNameType = CLOG_GetHistoryGap(2)
    local gapTypeSource = CLOG_GetHistoryGap(3)
    local gapSourceCharacter = CLOG_GetHistoryGap(4)
    local gapCharacterDate = CLOG_GetHistoryGap(5)

    row.icon:ClearAllPoints()
    row.icon:SetPoint("LEFT", row, "LEFT", leftInset + 2, 0)

    row.dateFS:ClearAllPoints()
    row.dateFS:SetPoint("RIGHT", row, "RIGHT", -rightInset, 0)
    row.dateFS:SetWidth(widths[6] or 104)
    row.dateFS:SetText(CLOG_FormatHistoryWhen(entry.ts) or "")

    row.characterFS:ClearAllPoints()
    row.characterFS:SetPoint("RIGHT", row.dateFS, "LEFT", -gapCharacterDate, 0)
    row.characterFS:SetWidth(widths[5] or 156)
    row.characterFS:SetText(CLOG_GetHistoryCharacterText(entry) or "")

    row.nameFS:ClearAllPoints()
    row.nameFS:SetPoint("LEFT", row, "LEFT", leftInset + (widths[1] or 36) + gapIconName, 0)
    row.nameFS:SetWidth(widths[2] or 230)
    row.nameFS:SetText(entry.name or "Unknown")

    row.typeFS:ClearAllPoints()
    row.typeFS:SetPoint("LEFT", row.nameFS, "RIGHT", gapNameType, 0)
    row.typeFS:SetWidth(widths[3] or 108)
    row.typeFS:SetText(CLOG_GetHistoryTypeText(entry) or "")

    row.sourceFS:ClearAllPoints()
    row.sourceFS:SetPoint("LEFT", row.typeFS, "RIGHT", gapTypeSource, 0)
    row.sourceFS:SetPoint("RIGHT", row.characterFS, "LEFT", -gapSourceCharacter, 0)
    row.sourceFS:SetText(CLOG_GetHistorySourceText(entry) or "")

    row._clEntry = entry
    row:Show()
  end

  for i = #historyList + 1, #rows do
    rows[i]:Hide()
    rows[i]._clEntry = nil
  end

  local total = #historyList
  local summary = total == 1 and "1 collection recorded" or (tostring(total) .. " collections recorded")
  if UI.historySummary then
    UI.historySummary:SetText(summary .. ". Newest collections first.")
  end

  hsContent:SetWidth(viewportW)
  hsContent:SetHeight(math.max((#historyList * (rowH + padY)) + 10, (UI.historyScroll and UI.historyScroll:GetHeight() or 300)))
end

function UI.ShowHistory(show)
  if not UI.history then return end
  if show then
    if UI.overview then UI.overview:Hide() end
    if UI.wishlist then UI.wishlist:Hide() end
    if listPanel then listPanel:Hide() end
    if right then right:Hide() end
    if UI.search then UI.search:Hide() end
    if UI.searchLabel then UI.searchLabel:Hide() end
    if UI.refreshBtn then UI.refreshBtn:Hide() end
    if UI.refreshStatus then UI.refreshStatus:Hide() end
    UI.history:Show()
    UI.RefreshHistory()
  else
    UI.history:Hide()
    if UI.search then UI.search:Show() end
    if UI.searchLabel then UI.searchLabel:Show() end
    if UI.refreshBtn then UI.refreshBtn:Show() end
    if UI.refreshStatus then UI.refreshStatus:Show() end
  end
end

if history and history.HookScript then
  history:HookScript("OnShow", CLOG_LayoutHistoryColumns)
  history:HookScript("OnSizeChanged", function()
    CLOG_LayoutHistoryColumns()
    if UI and UI.history and UI.history:IsShown() and UI.RefreshHistory then
      UI.RefreshHistory()
    end
  end)
end
if not StaticPopupDialogs["COLLECTIONLOG_CLEAR_HISTORY"] then
  StaticPopupDialogs["COLLECTIONLOG_CLEAR_HISTORY"] = {
    text = "Clear Collection Log history?\n\nThis only clears the History tab and does not remove anything from your actual collections.",
    button1 = "Clear",
    button2 = CANCEL,
    OnAccept = function()
      CollectionLogDB = CollectionLogDB or {}
      CollectionLogDB.collectionHistory = {}
      if UI and UI.RefreshHistory then pcall(UI.RefreshHistory) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
end

local oHeader = CreateFrame("Frame", nil, overview)
  oHeader:SetPoint("TOPLEFT", overview, "TOPLEFT", 6, -10)
  oHeader:SetPoint("TOPRIGHT", overview, "TOPRIGHT", -6, -10)
  oHeader:SetHeight(HEADER_H)

  local oTitle = oHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  oTitle:SetPoint("TOPLEFT", oHeader, "TOPLEFT", 8, -6)
  oTitle:SetText("Overview")
  -- Overview page uses tile cards as the visual header; hide the redundant "Overview" title.
  oHeader:Hide()

  local function MakeOSRSBar(parent, w, h)
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetSize(w, h)
    bg:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    bg:SetBackdropColor(0.12, 0.10, 0.08, 0.95)

    local bar = CreateFrame("StatusBar", nil, bg)
    bar:SetPoint("TOPLEFT", bg, "TOPLEFT", 3, -3)
    bar:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", -3, 3)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    local txt = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txt:SetPoint("CENTER", bar, "CENTER", 0, 0)

    bg._bar = bar
    bg._text = txt
    return bg
  end

  -- Layout: category boxes + big total bar + latest row
  -- Keep the original Overview layout, but shrink tiles so we can fit Housing
  -- to the right of Toys without pushing other elements out of place.
  local boxW = 115
  local boxH = 135
  local boxPad = 10

  local boxes = {}
  -- Overview tiles should reflect the top nav tabs. Add Housing to the right of Toys.
  local cats = { "Dungeons", "Raids", "Mounts", "Pets", "Toys", "Housing" }

  -- Centered 3x2 OSRS-style grid anchor (keeps the whole layout centered and roomy)
  local grid = CreateFrame("Frame", nil, overview)
  UI.overviewGrid = grid
  local gridW = (#cats * boxW) + ((#cats - 1) * boxPad)
  local gridH = boxH
  grid:SetSize(gridW, gridH)
  grid:SetPoint("TOP", overview, "TOP", 0, -22)

  for i, cat in ipairs(cats) do
    local b = CreateFrame("Frame", nil, overview, "BackdropTemplate")
    b:SetSize(boxW, boxH)
    b:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    b:SetBackdropColor(0.10, 0.09, 0.07, 0.90)
    b:SetBackdropBorderColor(1, 1, 1, 0.4)
    b:SetBackdropBorderColor(1, 1, 1, 0.4)

    local col = (i-1)
    b:SetPoint("TOPLEFT", grid, "TOPLEFT", col*(boxW+boxPad), 0)

    -- OSRS-style category icon (static; keeps Blizzard-truthful behavior)
    local ICONS = {
      Dungeons = "Interface\\Icons\\inv_misc_key_13",
      Raids    = "Interface\\Icons\\inv_helmet_06",
      Mounts   = "Interface\\Icons\\ability_mount_ridinghorse",
      -- Pets icon: prefer a paw. Use a widely-available icon to avoid silent missing-texture failures.
      Pets     = "Interface\\Icons\\ability_hunter_beasttraining.blp",
      Toys     = "Interface\\Icons\\inv_misc_toy_10",
      -- Housing: use Sturdy Wooden Chair (itemID 235523)
      Housing  = "Interface\\Icons\\inv_misc_questionmark",
    }

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("CENTER", b, "CENTER", 0, 6)
    -- Housing icon is item-driven (preferred over a generic icon).
    if cat == "Housing" then
      local tex
      if C_Item and C_Item.GetItemIconByID then
        tex = C_Item.GetItemIconByID(235523)
      end
      if not tex and GetItemIcon then
        tex = GetItemIcon(235523)
      end
      icon:SetTexture(tex or ICONS[cat] or "Interface\\Icons\\inv_misc_questionmark")
      icon.__clogItemID = 235523
    else
      icon:SetTexture(ICONS[cat] or "Interface\\Icons\\inv_misc_questionmark")
    end
    icon:SetDesaturated(true)
    icon:SetAlpha(0.90)
    b._icon = icon

    local lab = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lab:SetPoint("TOP", b, "TOP", 0, -8)
    lab:SetText(cat)

    local bar = MakeOSRSBar(b, boxW-16, 16)
    bar:SetPoint("BOTTOM", b, "BOTTOM", 0, 10)

    b._barWrap = bar

    -- Hover glow (matches tab/left-panel hover language)
    local hoverGlow = b:CreateTexture(nil, "ARTWORK")
    hoverGlow:SetColorTexture(1, 0.85, 0.25, 0.08)
    hoverGlow:SetBlendMode("ADD")
    hoverGlow:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    hoverGlow:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    hoverGlow:Hide()
    b.__clogHoverGlow = hoverGlow

    -- Make Overview category boxes clickable (jump to the matching tab)
    b:EnableMouse(true)
    b:SetScript("OnMouseUp", function()
      if UI and UI.tabs and UI.tabs[cat] and UI.tabs[cat].button and UI.tabs[cat].button.Click then
        UI.tabs[cat].button:Click()
      else
        -- Fallback: set activeCategory directly (still safe)
        if CollectionLogDB and CollectionLogDB.ui then
          CollectionLogDB.ui.activeCategory = cat
          CollectionLogDB.ui._forceDefaultGroup = true
          CollectionLogDB.ui.activeGroupId = nil
          if UI and UI.RefreshAll then UI.RefreshAll() end
        end
      end
    end)
    b:SetScript("OnEnter", function()
      b:SetBackdropBorderColor(1, 0.85, 0.25, 0.9)
      if b.__clogHoverGlow then b.__clogHoverGlow:Show() end
    end)
    b:SetScript("OnLeave", function()
      b:SetBackdropBorderColor(1, 1, 1, 0.4)
      if b.__clogHoverGlow then b.__clogHoverGlow:Hide() end
    end)
    boxes[cat] = b
  end

  local totalWrap = MakeOSRSBar(overview, gridW, 52)
  totalWrap:SetPoint("TOP", grid, "BOTTOM", 0, -46)
  totalWrap._text:SetFontObject("GameFontNormal")

  -- Big summary bar: no halo. Only show the same subtle fill glow used by the tiles when hovered.
  local totalHoverGlow = totalWrap:CreateTexture(nil, "ARTWORK")
  totalHoverGlow:SetColorTexture(1, 0.85, 0.25, 0.08)
  totalHoverGlow:SetBlendMode("ADD")
  totalHoverGlow:SetPoint("TOPLEFT", totalWrap, "TOPLEFT", 2, -2)
  totalHoverGlow:SetPoint("BOTTOMRIGHT", totalWrap, "BOTTOMRIGHT", -2, 2)
  totalHoverGlow:Hide()
  totalWrap.__clogHoverGlow = totalHoverGlow

  local totalLabel = overview:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  totalLabel:SetPoint("BOTTOM", totalWrap, "TOP", 0, 6)
  totalLabel:SetText("Collections Logged")

  local latestLabel = overview:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  latestLabel:SetPoint("TOP", totalWrap, "BOTTOM", 0, -34)
  latestLabel:SetText("Latest Collections")

  -- Latest Collections container (OSRS-style row shelf)
  local latestWrap = CreateFrame("Frame", nil, overview, "BackdropTemplate")
  UI.overviewLatestWrap = latestWrap
  latestWrap:SetPoint("TOP", latestLabel, "BOTTOM", 0, -10)
  -- Align shelf edges with the tiles + big bar.
  local shelfW = math.floor(gridW)
  latestWrap:SetSize(shelfW, 86)
  latestWrap:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
  })
  latestWrap:SetBackdropColor(0.10, 0.09, 0.07, 0.90)
  latestWrap:SetBackdropBorderColor(1, 1, 1, 0.35)

  local latestRow = CreateFrame("Frame", nil, latestWrap)
  UI.overviewLatestRow = latestRow

  local function CL_LatestResolveMountItemID(mountID)
    mountID = tonumber(mountID)
    if not mountID or mountID <= 0 then return nil end
    local tracked = ns and ns._tracked and ns._tracked.mountItems or nil
    if type(tracked) ~= "table" then return nil end
    for itemID in pairs(tracked) do
      itemID = tonumber(itemID)
      if itemID and itemID > 0 then
        local resolved = nil
        if ns and ns.GetMountIDFromItemID then
          local ok, mid = pcall(ns.GetMountIDFromItemID, itemID)
          if ok then resolved = tonumber(mid) end
        end
        if (not resolved or resolved == 0) and C_MountJournal and C_MountJournal.GetMountIDFromItemID then
          local ok, mid = pcall(C_MountJournal.GetMountIDFromItemID, itemID)
          if ok then resolved = tonumber(mid) end
        end
        if resolved == mountID then return itemID end
      end
    end
    return nil
  end

  local function CL_LatestResolvePetItemID(speciesID)
    speciesID = tonumber(speciesID)
    if not speciesID or speciesID <= 0 then return nil end
    local tracked = ns and ns._tracked and ns._tracked.items or nil
    if type(tracked) ~= "table" then return nil end
    for itemID in pairs(tracked) do
      itemID = tonumber(itemID)
      if itemID and itemID > 0 and C_PetJournal and C_PetJournal.GetPetInfoByItemID then
        local ok, sid = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
        if ok and tonumber(sid) == speciesID then return itemID end
      end
    end
    return nil
  end

  local ICON_SIZE = 36
  local ICON_GAP  = 6
  local PAD_X     = 14

  local maxSlots = math.floor(((shelfW - (PAD_X*2)) + ICON_GAP) / (ICON_SIZE + ICON_GAP))
  if maxSlots < 8 then maxSlots = 8 end
  if maxSlots > 20 then maxSlots = 20 end
  UI.overviewLatestMaxSlots = maxSlots
  if ns then ns.LATEST_COLLECTIONS_MAX = maxSlots end

  latestRow:SetSize(shelfW - (PAD_X*2), ICON_SIZE)
  latestRow:SetPoint("CENTER", latestWrap, "CENTER", 0, 0)

  UI.overviewLatestButtons = UI.overviewLatestButtons or {}
  UI.overviewLatestIcons = UI.overviewLatestIcons or {} -- legacy alias; buttons own the textures now
  for i = 1, maxSlots do
    local btn = UI.overviewLatestButtons[i]
    if not btn then
      btn = CreateFrame("Button", nil, latestRow)
      btn:SetSize(ICON_SIZE, ICON_SIZE)
      btn:SetPoint("LEFT", latestRow, "LEFT", (i-1)*(ICON_SIZE+ICON_GAP), 0)

      btn.icon = btn:CreateTexture(nil, "ARTWORK")
      btn.icon:SetAllPoints()

      btn.bg = btn:CreateTexture(nil, "BACKGROUND")
      btn.bg:SetAllPoints()
      btn.bg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
      btn.bg:SetAlpha(0.35)

      btn._clEntry = nil
      btn:Hide()

      btn:SetScript("OnEnter", function(self)
        local entry = self._clEntry
        if not entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

        local itemLink = entry.itemLink
        local itemID = tonumber(entry.itemID)

        if (not itemID or itemID <= 0) and entry.mountID then
          itemID = CL_LatestResolveMountItemID(entry.mountID)
        elseif (not itemID or itemID <= 0) and entry.speciesID then
          itemID = CL_LatestResolvePetItemID(entry.speciesID)
        end

        if (not itemLink or itemLink == "") and itemID and itemID > 0 and C_Item and C_Item.GetItemLinkByID then
          local ok, link = pcall(C_Item.GetItemLinkByID, itemID)
          if ok and type(link) == "string" and link ~= "" then itemLink = link end
        end

        if itemLink and GameTooltip.SetHyperlink then
          GameTooltip:SetHyperlink(itemLink)
        elseif itemID and itemID > 0 and GameTooltip.SetItemByID then
          GameTooltip:SetItemByID(itemID)
        else
          GameTooltip:SetText(entry.name or "Unknown")
        end

        GameTooltip:Show()
      end)

      btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
      end)

      -- Latest Collections: CTRL+Left Click preview (matches item grid behavior)
      btn:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if not (IsControlKeyDown and IsControlKeyDown()) then return end
        local entry = self._clEntry
        if not entry then return end

        -- Mount preview
        if entry.mountID then
          if ToggleCollectionsJournal then
            pcall(ToggleCollectionsJournal, 1)
          elseif CollectionsJournal and CollectionsJournal.SetShown then
            pcall(CollectionsJournal.SetShown, CollectionsJournal, true)
          elseif CollectionsJournal and CollectionsJournal.Show then
            pcall(CollectionsJournal.Show, CollectionsJournal)
          end

          if CollectionsJournal_SetTab and CollectionsJournal then
            pcall(CollectionsJournal_SetTab, CollectionsJournal, 1)
          end

          if C_MountJournal and C_MountJournal.SetSelectedMountID then
            pcall(C_MountJournal.SetSelectedMountID, entry.mountID)
          elseif MountJournal_SelectByMountID then
            pcall(MountJournal_SelectByMountID, entry.mountID)
          elseif MountJournal and MountJournal.SelectByMountID then
            pcall(MountJournal.SelectByMountID, MountJournal, entry.mountID)
          end
          return
        end

        -- Pet preview
        if entry.speciesID then
          if (not CollectionsJournal) and UIParentLoadAddOn then
            pcall(UIParentLoadAddOn, "Blizzard_Collections")
          end

          if ToggleCollectionsJournal then
            pcall(ToggleCollectionsJournal, 2)
          elseif CollectionsJournal and CollectionsJournal.SetShown then
            pcall(CollectionsJournal.SetShown, CollectionsJournal, true)
          elseif CollectionsJournal and CollectionsJournal.Show then
            pcall(CollectionsJournal.Show, CollectionsJournal)
          end

          if CollectionsJournal_SetTab and CollectionsJournal then
            pcall(CollectionsJournal_SetTab, CollectionsJournal, 2)
          end

          if ns.HookPetJournalFilterCleanup then
            pcall(ns.HookPetJournalFilterCleanup)
          end

          local speciesID = entry.speciesID
          local petName
          if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
            local okName, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
            if okName then petName = name end
          end

          if PetJournal_SelectSpecies then
            pcall(PetJournal_SelectSpecies, speciesID)
          elseif PetJournal and PetJournal.SelectSpecies then
            pcall(PetJournal.SelectSpecies, PetJournal, speciesID)
          elseif C_PetJournal and C_PetJournal.SetSelectedPetSpeciesID then
            pcall(C_PetJournal.SetSelectedPetSpeciesID, speciesID)
          elseif C_PetJournal and C_PetJournal.SetSelectedSpeciesID then
            pcall(C_PetJournal.SetSelectedSpeciesID, speciesID)
          end

          if C_PetJournal and C_PetJournal.SetSearchFilter and petName then
            pcall(C_PetJournal.SetSearchFilter, petName)
          end

          if C_Timer and C_Timer.NewTicker and C_PetJournal and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
            local tries = 0
            local ticker
            ticker = C_Timer.NewTicker(0.05, function()
              tries = tries + 1
              local okNum, num = pcall(C_PetJournal.GetNumPets)
              if okNum and type(num) == "number" and num > 0 then
                local targetPetID
                for i = 1, num do
                  local okInfo, petID, sID = pcall(C_PetJournal.GetPetInfoByIndex, i)
                  if okInfo and petID and sID == speciesID then
                    targetPetID = petID
                    break
                  end
                end
                if targetPetID then
                  if PetJournal_SelectPet then
                    pcall(PetJournal_SelectPet, targetPetID)
                  elseif C_PetJournal.SetSelectedPetID then
                    pcall(C_PetJournal.SetSelectedPetID, targetPetID)
                  end
                  if PetJournal_UpdatePetCard then
                    pcall(PetJournal_UpdatePetCard)
                  end
                  if ticker and ticker.Cancel then ticker:Cancel() end
                  return
                end
              end
              if tries >= 30 and ticker and ticker.Cancel then ticker:Cancel() end
            end)
          else
            if C_PetJournal and C_PetJournal.GetNumPets and C_PetJournal.GetPetInfoByIndex then
              local okNum, num = pcall(C_PetJournal.GetNumPets)
              if okNum and type(num) == "number" and num > 0 then
                for i = 1, num do
                  local okInfo, petID, sID = pcall(C_PetJournal.GetPetInfoByIndex, i)
                  if okInfo and petID and sID == speciesID then
                    if C_PetJournal.SetSelectedPetID then pcall(C_PetJournal.SetSelectedPetID, petID) end
                    if PetJournal_UpdatePetCard then pcall(PetJournal_UpdatePetCard) end
                    break
                  end
                end
              end
            end
          end
          return
        end

        -- Item preview
        local itemID = entry.itemID
        if itemID then
          local link = select(2, GetItemInfo(itemID))
          if not link then link = "item:" .. tostring(itemID) end
          if DressUpItemLink and link then
            pcall(DressUpItemLink, link)
          elseif HandleModifiedItemClick and link then
            pcall(HandleModifiedItemClick, link)
          end
        end
      end)


      UI.overviewLatestButtons[i] = btn
      UI.overviewLatestIcons[i] = btn.icon -- keep old references working
    end
  end

  local function ColorBarByRatio(bar, ratio)
    -- Smooth red -> yellow -> green (matches the tab language)
    ratio = tonumber(ratio) or 0
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end

    local r, g
    if ratio < 0.5 then
      -- red (1,0) to yellow (1,1)
      r = 1.0
      g = ratio * 2.0
    else
      -- yellow (1,1) to green (0,1)
      r = (1.0 - ratio) * 2.0
      g = 1.0
    end
    local b = 0.10

    -- Slightly mute at very low progress so it doesn't scream.
    local a = 1.0
    if ratio < 0.02 then
      r, g, b = 0.55, 0.12, 0.12
    end

    bar:SetStatusBarColor(r, g, b, a)
  end

  local function IsAppearanceCollectedByID(appearanceID)
    if not appearanceID or appearanceID == 0 then return false end
    if not C_TransmogCollection then return false end
    if C_TransmogCollection.GetAppearanceInfoByID then
      local ok, a,b,c,isCollected = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
      if ok and type(isCollected) == "boolean" then return isCollected end
    end
    if C_TransmogCollection.GetAppearanceSources then
      local ok, sources = pcall(C_TransmogCollection.GetAppearanceSources, appearanceID)
      if ok and type(sources) == "table" then
        for _, s in ipairs(sources) do
          if s and s.isCollected then return true end
        end
      end
    end
    if C_TransmogCollection.GetAppearanceSourceInfo then
      local ok, info = pcall(C_TransmogCollection.GetAppearanceSourceInfo, appearanceID)
      if ok and type(info) == "table" and info.isCollected ~= nil then
        return info.isCollected and true or false
      end
    end
    return false
  end

  local function ComputeCategoryProgress(cat)
    local groups = ns and ns.Data and ns.Data.groupsByCategory and ns.Data.groupsByCategory[cat] or {}
    local total, collected = 0, 0

    if cat == "Mounts" and C_MountJournal and C_MountJournal.GetMountInfoByID then
      local seen = {}
      for _, g2 in ipairs(groups) do
        for _, mid in ipairs(g2.mounts or {}) do
          if mid and not seen[mid] and CL_IsVisibleCollectible("Mounts", mid) then
            seen[mid] = true
            total = total + 1
            local _, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mid)
            if isCollected then collected = collected + 1 end
          end
        end
      end
      return collected, total
    end

    if cat == "Pets" and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
      local seen = {}
      for _, g2 in ipairs(groups) do
        for _, sid in ipairs(g2.pets or {}) do
          if sid and not seen[sid] then
            seen[sid] = true
            total = total + 1
            local numOwned = select(1, C_PetJournal.GetNumCollectedInfo(sid))
            if numOwned and numOwned > 0 then collected = collected + 1 end
          end
        end
      end
      return collected, total
    end

    if cat == "Toys" then
      -- Option A: Toys are Blizzard-truthful (Toy Box). This is the only reliable
      -- way to avoid 0/0 on fresh installs without forcing the Toy Box UI to be opened
      -- or generating large toy lists on login.
      if C_ToyBox and (C_ToyBox.GetNumToys or C_ToyBox.GetNumLearnedToys) then
        local learned2, total2 = GetBlizzardToyTotals()
        return learned2 or 0, total2 or 0
      end

      -- Fallback (should rarely be used): count toys from groups using the canonical toy resolver.
      if ns and ns.IsToyCollected then
        local seen = {}
        for _, g2 in ipairs(groups) do
          for _, itemID in ipairs(g2.items or {}) do
            if itemID and not seen[itemID] then
              seen[itemID] = true
              total = total + 1
              if ns.IsToyCollected(itemID) then collected = collected + 1 end
            end
          end
        end
        return collected, total
      end
    end

    if cat == "Housing" then
      local c, t = UI.GetHousingProgressCached()
      return c, t
    end

    -- Dungeons / Raids: sum the same validated TrueCollection backend statuses
    -- that power the live group headers. This avoids Overview drifting back to
    -- stale legacy appearance counting or 0/0 cache-only behavior.
    if cat == "Raids" or cat == "Dungeons" then
      local supported = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups(cat) or nil
      if type(supported) == "table" and ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus then
        for i = 1, #supported do
          local g2 = supported[i]
          local groupKey = type(g2) == "table" and g2.groupKey or nil
          if groupKey then
            local ok, status = pcall(ns.TrueCollection.GetGroupStatus, groupKey)
            if ok and type(status) == "table" then
              if status.unsupported then
                return nil, nil, "unsupported"
              end
              collected = collected + (tonumber(status.collected or 0) or 0)
              total = total + (tonumber(status.total or 0) or 0)
            end
          end
        end
        return collected, total
      end
      return collected, total
    end

    return collected, total
  end


  -- Toys: to match the addonâ€™s Toys tab totals (datapack-defined scope),
  -- exclude any generated ToyBox-based groups (group.generated == true).
  local function ComputeToysDatapackProgress()
    local groups = ns and ns.Data and ns.Data.groupsByCategory and ns.Data.groupsByCategory["Toys"] or {}
    local total, collected = 0, 0
    if not (ns and ns.IsToyCollected) then
      return 0, 0
    end

    local seen = {}
    for _, g2 in ipairs(groups) do
      if not (g2 and g2.generated) then
        for _, itemID in ipairs(g2.items or {}) do
          if itemID and not seen[itemID] then
            seen[itemID] = true
            total = total + 1
            if ns.IsToyCollected(itemID) then
              collected = collected + 1
            end
          end
        end
      end
    end
    return collected, total
  end

  local OVERVIEW_CACHE_SCHEMA = 7

  -- Overview cache + async rebuild (read-only Overview rendering)
  local function EnsureOverviewCache()
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.cache = CollectionLogDB.cache or {}
    local overview = CollectionLogDB.cache.overview
    if type(overview) ~= "table" or overview._schema ~= OVERVIEW_CACHE_SCHEMA then
      overview = { _schema = OVERVIEW_CACHE_SCHEMA }
      CollectionLogDB.cache.overview = overview
    end
    overview._schema = OVERVIEW_CACHE_SCHEMA
    return overview
  end

  function UI.UpdateOverviewPetsFromCollection(speciesID)
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.cache = CollectionLogDB.cache or {}

    -- A newly collected pet often needs the generated Pets cache refreshed before
    -- Overview can show the new total. Rebuilding pets groups is expensive to do
    -- constantly, but very cheap at the moment of a confirmed new pet.
    if ns and ns.EnsurePetsGroups then
      pcall(ns.EnsurePetsGroups)
    end

    local function syncNow()
      local owned, total
      local species = CollectionLogDB.cache.petSpeciesIDs
      if type(species) == "table" and #species > 0 and C_PetJournal and C_PetJournal.GetNumCollectedInfo then
        total = #species
        owned = 0
        for i = 1, #species do
          local sid = species[i]
          local ok, numOwned = pcall(C_PetJournal.GetNumCollectedInfo, sid)
          if ok and type(numOwned) == "number" and numOwned > 0 then
            owned = owned + 1
          end
        end
      else
        local ok, c, t = pcall(GetBlizzardPetTotals)
        if ok then
          owned, total = c, t
        end
      end

      if type(owned) == "number" and type(total) == "number" and total > 0 then
        CollectionLogDB.cache.petTotals = { c = owned, t = total, ts = (time and time()) or 0 }
        local cache = EnsureOverviewCache()
        cache["Pets"] = { c = owned, t = total, ts = (time and time()) or 0 }
        if CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Overview" and UI.RefreshOverview then
          pcall(UI.RefreshOverview)
        end
        return true
      end
      return false
    end

    if syncNow() then return end

    -- Pet Journal ownership can lag briefly. Retry a couple of times instead of
    -- waiting for the user to open the Pets tab.
    if C_Timer and C_Timer.After then
      C_Timer.After(0.20, function() pcall(syncNow) end)
      C_Timer.After(0.75, function() pcall(syncNow) end)
      C_Timer.After(1.50, function() pcall(syncNow) end)
    elseif UI.RequestOverviewRebuild then
      pcall(UI.RequestOverviewRebuild, "pet_new_collection", true)
    end
  end

  function UI.UpdateOverviewHousingFromCollection(itemID)
    itemID = tonumber(itemID)

    local hp = UI._housingPerf
    local collected, total

    -- Trust the in-session housing cache first for a confirmed new collection.
    -- Live catalog truth can lag behind the popup pipeline, which is why users saw
    -- Overview stay stale until pressing Refresh.
    if hp and type(hp.cache) == "table" then
      if itemID and itemID > 0 then
        hp.cache[itemID] = true
      end
      local c = 0
      for _, owned in pairs(hp.cache) do
        if owned == true then c = c + 1 end
      end
      collected = c
      total = tonumber(hp.total) or 0
      hp.collected = c
    end

    if (not total or total <= 0) and UI.GetHousingProgressCached then
      local c2, t2 = UI.GetHousingProgressCached()
      if type(c2) == "number" and type(t2) == "number" then
        collected, total = c2, t2
      end
    end

    if type(collected) == "number" and type(total) == "number" and total > 0 then
      pcall(UI.UpdateOverviewHousingFromScan, collected, total)
      if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Overview" and UI.RefreshOverview then
        pcall(UI.RefreshOverview)
      end
      return
    end

    if UI.RequestOverviewRebuild then
      pcall(UI.RequestOverviewRebuild, "housing_new_collection", true)
    end
  end

  -- Fast-path sync: when the Housing scan advances, keep Overview's Housing tile in sync
  -- without forcing a full rebuild (prevents stale partial counts like 21/1254).
  function UI.UpdateOverviewHousingFromScan(collected, total)
    local cache = EnsureOverviewCache()
    cache["Housing"] = cache["Housing"] or { c = 0, t = 0, ts = time and time() or 0 }
    cache["Housing"].c = collected or 0
    cache["Housing"].t = total or 0
    cache["Housing"].ts = time and time() or 0

    -- Recompute overall total from the cache entries we display on Overview.
    local sumC, sumT = 0, 0
    local _cats = { "Dungeons", "Raids", "Mounts", "Pets", "Toys", "Housing" }
    for _, cat in ipairs(_cats) do
      local e = cache[cat]
      if e then
        sumC = sumC + (e.c or 0)
        sumT = sumT + (e.t or 0)
      end
    end
    cache._ts = time and time() or 0
    cache._total = { c = sumC, t = sumT, ts = cache._ts }
  end


  -- Prime Blizzard collection APIs so Mount/Pet/Toy totals don't intermittently return 0/0 early in a session.
  local function PrimeCollections()
    if UI._clogCollectionsPrimed then return end
    UI._clogCollectionsPrimed = true

    pcall(function()
      if C_MountJournal and C_MountJournal.GetMountIDs then
        C_MountJournal.GetMountIDs()
      elseif C_MountJournal and C_MountJournal.GetNumMounts then
        C_MountJournal.GetNumMounts()
      end
    end)

    pcall(function()
      if C_PetJournal and C_PetJournal.GetNumPets then
        C_PetJournal.GetNumPets()
      end
    end)

    pcall(function()
      if C_ToyBox and C_ToyBox.GetNumToys then
        C_ToyBox.GetNumToys()
      end
      if C_ToyBox and C_ToyBox.GetNumLearnedToys then
        C_ToyBox.GetNumLearnedToys()
      end
    end)

    -- Housing: best-effort prime of the catalog data so Overview isn't stuck at 0 collected.
    pcall(function()
      if C_HousingCatalog and C_HousingCatalog.GetCatalogEntryInfoByRecordID and ns and ns.GetHousingDecorRecordID then
        local rid = ns.GetHousingDecorRecordID(235523) -- Sturdy Wooden Chair
        if rid then
          C_HousingCatalog.GetCatalogEntryInfoByRecordID(1, rid, true)
        end
      end
    end)
  end

  -- Throttled, safe Overview rebuild request (used by Refresh button + auto-heal).
  function UI.RequestOverviewRebuild(reason, force)
    local cache = EnsureOverviewCache()
    cache._dirty = true
    cache._dirtyReason = tostring(reason or "unknown")
    if cache._building then return end

    if not (UI.overview and UI.overview:IsShown() and UI._clogOverviewShownActive) then
      return
    end

    local now = (GetTime and GetTime()) or 0
    UI._clogOverviewNextRebuild = UI._clogOverviewNextRebuild or 0

    if not force and now < UI._clogOverviewNextRebuild then
      return
    end

    -- 0.5s throttle by default to avoid spam/lag.
    UI._clogOverviewNextRebuild = now + 0.5

    PrimeCollections()

    UI.RebuildOverviewCacheAsync()
  end

  local function GetBlizzardMountTotals()
    -- Retail/modern API: GetNumMounts() returns a single number (total), not (total, collected).
    -- We compute collected by iterating mountIDs and checking isCollected.
    if C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID then
      local ids = (ns.GetValidMountJournalIDs and ns.GetValidMountJournalIDs()) or C_MountJournal.GetMountIDs()
      if ids then
        local total = 0
        local collected = 0
        local hideUnobtainable = CLOG_ShouldHideUnobtainable()
        for i = 1, #ids do
          local mountID = ids[i]
          if mountID then
            local name, spellID, icon, active, usable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected =
              C_MountJournal.GetMountInfoByID(mountID)

            local include = true
            if hideUnobtainable and CL_IsUnobtainableMountID(mountID) and not isCollected then
              include = false
            end

            if include then
              total = total + 1
              if isCollected then
                collected = collected + 1
              end
            end
          end
        end
        return collected, total
      end
    end

    if C_MountJournal and C_MountJournal.GetNumMounts then
      local total = C_MountJournal.GetNumMounts()
      if type(total) == "number" then
        return 0, total
      end
    end

    return 0, 0
  end

  
  -- ToyBox learned count can return 0 briefly on cold login even when the player owns toys.
  -- To stay Blizzard-truthful *and* reliable without forcing the Toy Box UI open, we do a
  -- lightweight, throttled scan (chunked across frames) using GetToyFromIndex + PlayerHasToy
  -- only when needed.

  local function GetDisplayedToyTotalsFast()
    if not C_ToyBox then return 0, 0 end

    local total = 0
    local learned = 0

    -- "Displayed" totals match the Toy Box UI's progress bar (typically ~950), and avoid
    -- counting hidden/internal entries that inflate GetNumToys().
    if C_ToyBox.GetNumTotalDisplayedToys then
      local ok, t = pcall(C_ToyBox.GetNumTotalDisplayedToys)
      if ok and type(t) == "number" then total = t end
    elseif C_ToyBox.GetNumFilteredToys then
      local ok, t = pcall(C_ToyBox.GetNumFilteredToys)
      if ok and type(t) == "number" then total = t end
    elseif C_ToyBox.GetNumToys then
      local ok, t = pcall(C_ToyBox.GetNumToys)
      if ok and type(t) == "number" then total = t end
    end

    if C_ToyBox.GetNumLearnedDisplayedToys then
      local ok, l = pcall(C_ToyBox.GetNumLearnedDisplayedToys)
      if ok and type(l) == "number" then learned = l end
    elseif C_ToyBox.GetNumLearnedToys then
      local ok, l = pcall(C_ToyBox.GetNumLearnedToys)
      if ok and type(l) == "number" then learned = l end
    end

    return learned, total
  end

  local ToyScan = { running = false, learned = nil, total = nil, lastStart = 0 }

  local function StartToyLearnedScan(UI)
    if ToyScan.running then return end
    if not (C_ToyBox and C_ToyBox.GetNumToys and C_ToyBox.GetToyFromIndex and PlayerHasToy and C_Timer and C_Timer.After) then
      return
    end

    local _l0, total = GetDisplayedToyTotalsFast()
    if type(total) ~= "number" or total <= 0 then return end

    local now = GetTime and GetTime() or 0
    if now and ToyScan.lastStart and (now - ToyScan.lastStart) < 5 then
      return -- throttle
    end

    ToyScan.running = true
    ToyScan.lastStart = now
    ToyScan.total = total
    ToyScan.learned = 0

    local i = 1
    local CHUNK = 60

    local function step()
      local n = 0
      while i <= total and n < CHUNK do
        local toyItemID = C_ToyBox.GetToyFromIndex(i)
        if toyItemID and PlayerHasToy(toyItemID) then
          ToyScan.learned = (ToyScan.learned or 0) + 1
        end
        i = i + 1
        n = n + 1
      end

      if i <= total then
        C_Timer.After(0, step)
      else
        ToyScan.running = false
        -- If Overview is visible, repaint once with the corrected learned count.
        if UI and UI.frame and UI.frame.IsShown and UI.frame:IsShown() and UI.overview and UI.overview.IsShown and UI.overview:IsShown() then
          C_Timer.After(0, function()
            if UI.RefreshOverview then pcall(UI.RefreshOverview) end
          end)
        end
      end
    end

    C_Timer.After(0, step)
  end

local function GetBlizzardToyTotals()
    -- Blizzard-truthful Toy Box totals that match Blizzard's Toy Box UI progress bar.
    -- Uses "displayed" totals when available (typically ~950), and falls back safely.
    local learned, total = GetDisplayedToyTotalsFast()

    -- Some clients return learned=0 briefly on cold login even when toys exist.
    -- If that happens, use our cached scan result (if available), and kick off a
    -- throttled scan to populate it, scanning only the displayed list to stay consistent.
    if learned == 0 and total > 0 then
      if type(ToyScan.learned) == "number" and ToyScan.learned >= 0 and type(ToyScan.total) == "number" and ToyScan.total == total then
        learned = ToyScan.learned
      else
        StartToyLearnedScan(UI)
      end
    end

    return learned or 0, total or 0
  end

  local function GetBlizzardPetTotals()
    if not (C_PetJournal and C_PetJournal.GetNumPets) then
      return 0, 0
    end

    -- Pet Journal totals are affected by the userâ€™s Pet Journal filters/search.
    -- Temporarily normalize to an â€œall petsâ€ view, then restore.
    local function WithAllPets(fn)
      local restore = {}

      -- Search filter
      if C_PetJournal.GetSearchFilter and (C_PetJournal.SetSearchFilter or C_PetJournal.ClearSearchFilter) then
        local ok, cur = pcall(C_PetJournal.GetSearchFilter)
        if ok then
          table.insert(restore, function()
            if C_PetJournal.SetSearchFilter then pcall(C_PetJournal.SetSearchFilter, cur or "")
            elseif C_PetJournal.ClearSearchFilter then pcall(C_PetJournal.ClearSearchFilter) end
          end)
        end
        if C_PetJournal.ClearSearchFilter then pcall(C_PetJournal.ClearSearchFilter)
        elseif C_PetJournal.SetSearchFilter then pcall(C_PetJournal.SetSearchFilter, "") end
      end

      -- Pet type filters (best-effort)
      if C_PetJournal.GetPetTypeFilter and C_PetJournal.SetPetTypeFilter then
        local saved = {}
        for i = 1, 10 do
          local ok, v = pcall(C_PetJournal.GetPetTypeFilter, i)
          if ok and type(v) == "boolean" then saved[i] = v end
        end
        table.insert(restore, function()
          for i = 1, 10 do
            if saved[i] ~= nil then pcall(C_PetJournal.SetPetTypeFilter, i, saved[i]) end
          end
        end)
        for i = 1, 10 do pcall(C_PetJournal.SetPetTypeFilter, i, true) end
      elseif C_PetJournal.SetAllPetTypesFilter then
        -- Some clients expose a single â€œall typesâ€ toggle.
        pcall(C_PetJournal.SetAllPetTypesFilter, true)
      end

      -- Source filters (best-effort)
      if C_PetJournal.GetSourceFilter and C_PetJournal.SetSourceFilter then
        local saved = {}
        for i = 1, 20 do
          local ok, v = pcall(C_PetJournal.GetSourceFilter, i)
          if ok and type(v) == "boolean" then saved[i] = v end
        end
        table.insert(restore, function()
          for i = 1, 20 do
            if saved[i] ~= nil then pcall(C_PetJournal.SetSourceFilter, i, saved[i]) end
          end
        end)
        for i = 1, 20 do pcall(C_PetJournal.SetSourceFilter, i, true) end
      elseif C_PetJournal.SetAllPetSourcesFilter then
        pcall(C_PetJournal.SetAllPetSourcesFilter, true)
      end

      local a, b = fn()
      for i = #restore, 1, -1 do pcall(restore[i]) end
      return a, b
    end

    local total, owned = WithAllPets(function() return C_PetJournal.GetNumPets() end)
    if type(total) == "number" and type(owned) == "number" then
      return owned, total
    end
    return 0, 0
  end

  local function RenderOverviewFromCache()
    if not UI.overview or not UI.overview:IsShown() then return end

    local cache = EnsureOverviewCache()
    local sumC, sumT = 0, 0
    local anyUnsupported = false

    for _, cat in ipairs(cats) do
      local entry = cache[cat]
      local c = entry and entry.c or 0
      local t = entry and entry.t or 0
      local unsupported = entry and entry.unsupported or false

      if cat == "Mounts" then
        c, t = GetBlizzardMountTotals()
        cache[cat] = { c = c or 0, t = t or 0, ts = time and time() or 0 }
      elseif cat == "Pets" then
        local pt = CollectionLogDB and CollectionLogDB.cache and CollectionLogDB.cache.petTotals
        if pt and type(pt.c) == "number" and type(pt.t) == "number" and pt.t > 0 then
          c, t = pt.c, pt.t
        else
          c, t = GetBlizzardPetTotals()
        end
        cache[cat] = { c = c or 0, t = t or 0, ts = time and time() or 0 }elseif cat == "Toys" then
        -- Blizzard-truth totals (works without opening the Toy Box UI).
        c, t = GetBlizzardToyTotals()
        cache[cat] = { c = c or 0, t = t or 0, ts = time and time() or 0 }
      end

      if unsupported then
        anyUnsupported = true
      else
        sumC = sumC + (c or 0)
        sumT = sumT + (t or 0)
      end

      local b = boxes[cat]
      if b and b._barWrap and b._barWrap._bar then
        local ratio = (t and t > 0 and not unsupported) and (c / t) or 0
        b._barWrap._bar:SetMinMaxValues(0, (not unsupported and t > 0) and t or 1)
        b._barWrap._bar:SetValue((not unsupported) and c or 0)
        if unsupported then
          b._barWrap._bar:SetStatusBarColor(0.45, 0.45, 0.45)
        else
          ColorBarByRatio(b._barWrap._bar, ratio)
        end
        local countText = unsupported and "N/A" or ("%d/%d"):format(c or 0, t or 0)
        b._barWrap._text:SetText(countText)

        -- Hover: swap X/Y to percent (bar only)
        if not b._barWrap._bar.__clogHoverPct then
          b._barWrap._bar.__clogHoverPct = true
          b._barWrap._bar:EnableMouse(true)
          b._barWrap._bar:SetScript("OnEnter", function(self)
            local wrap = self:GetParent()
            if wrap and wrap._text and self.__clogPercentText then
              wrap._text:SetText(self.__clogPercentText)
            end
          end)
          b._barWrap._bar:SetScript("OnLeave", function(self)
            local wrap = self:GetParent()
            if wrap and wrap._text and self.__clogCountText then
              wrap._text:SetText(self.__clogCountText)
            end
          end)
        end
        b._barWrap._bar.__clogCountText = countText
        b._barWrap._bar.__clogPercentText = unsupported and "N/A" or ("%.1f%%"):format((ratio or 0) * 100)
      end
    end

    local ratio = (sumT and sumT > 0 and not anyUnsupported) and (sumC / sumT) or 0
    totalWrap._bar:SetMinMaxValues(0, (not anyUnsupported and sumT > 0) and sumT or 1)
    totalWrap._bar:SetValue((not anyUnsupported) and sumC or 0)
    if anyUnsupported then
      totalWrap._bar:SetStatusBarColor(0.45, 0.45, 0.45)
    else
      ColorBarByRatio(totalWrap._bar, ratio)
    end
    local countText = anyUnsupported and "N/A" or ("%d/%d"):format(sumC, sumT)
    totalWrap._text:SetText(countText)

    -- Hover: swap X/Y to percent (bar only)
    if not totalWrap._bar.__clogHoverPct then
      totalWrap._bar.__clogHoverPct = true
      totalWrap._bar:EnableMouse(true)
      totalWrap._bar:SetScript("OnEnter", function(self)
        local wrap = self:GetParent()
        if wrap and wrap._text and self.__clogPercentText then
          wrap._text:SetText(self.__clogPercentText)
        end
        if wrap and wrap.__clogHoverGlow then
          wrap.__clogHoverGlow:Show()
        end
      end)
      totalWrap._bar:SetScript("OnLeave", function(self)
        local wrap = self:GetParent()
        if wrap and wrap._text and self.__clogCountText then
          wrap._text:SetText(self.__clogCountText)
        end
        if wrap and wrap.__clogHoverGlow then
          wrap.__clogHoverGlow:Hide()
        end
      end)
    end
    totalWrap._bar.__clogCountText = countText
    totalWrap._bar.__clogPercentText = anyUnsupported and "N/A" or ("%.1f%%"):format((ratio or 0) * 100)

    -- Latest collections icons (hoverable)
    local latest = CollectionLogDB and CollectionLogDB.latestCollections or nil
    local maxSlots = UI.overviewLatestMaxSlots or 10

    -- Build a compact, gap-free list (some entries may lack an icon depending on client timing).
    local visible = {}
    if latest then
      for _, entry in ipairs(latest) do
        if entry and entry.icon then
          visible[#visible+1] = entry
          if #visible >= maxSlots then break end
        end
      end
    end

    for i = 1, maxSlots do
      local btn = UI.overviewLatestButtons and UI.overviewLatestButtons[i] or nil
      local entry = visible[i]
      if btn and btn.icon then
        if entry then
          btn:Show()
          btn.icon:SetTexture(entry.icon)
          btn.icon:SetAlpha(1)
          if btn.bg then btn.bg:Hide() end
          btn._clEntry = entry
        else
          btn._clEntry = nil
          btn:Hide()
        end
      else
        local tex = UI.overviewLatestIcons and UI.overviewLatestIcons[i] or nil
        if tex then
          if entry then
            tex:SetTexture(entry.icon)
            tex:Show()
          else
            tex:Hide()
          end
        end
      end
    end
  end

  local function ComputeOverviewCategoryProgressAsync(cat, onDone)
    if cat ~= "Raids" and cat ~= "Dungeons" then
      local c, t, state = ComputeCategoryProgress(cat)
      onDone(c, t, state)
      return
    end

    local supported = ns and ns.CompletionDefinitions and ns.CompletionDefinitions.GetSupportedGroups and ns.CompletionDefinitions.GetSupportedGroups(cat) or nil
    if type(supported) ~= "table" or #supported == 0 then
      onDone(0, 0, nil)
      return
    end

    local idx = 1
    local collected, total = 0, 0
    local BATCH_SIZE = 6
    local TIME_BUDGET_MS = 8

    local function step()
      local startMs = (debugprofilestop and debugprofilestop()) or nil
      local processed = 0

      while idx <= #supported do
        local g2 = supported[idx]
        idx = idx + 1
        if type(g2) == "table" and g2.groupKey and ns and ns.TrueCollection and ns.TrueCollection.GetGroupStatus then
          local ok, status = pcall(ns.TrueCollection.GetGroupStatus, g2.groupKey)
          if ok and type(status) == "table" then
            if status.unsupported then
              onDone(nil, nil, "unsupported")
              return
            end
            collected = collected + (tonumber(status.collected or 0) or 0)
            total = total + (tonumber(status.total or 0) or 0)
          end
        end

        processed = processed + 1
        if processed >= BATCH_SIZE then break end
        if startMs and debugprofilestop and ((debugprofilestop() - startMs) >= TIME_BUDGET_MS) then break end
      end

      if idx > #supported then
        onDone(collected, total, nil)
        return
      end

      if C_Timer and C_Timer.After then
        C_Timer.After(0, step)
      else
        step()
      end
    end

    step()
  end

  function UI.RebuildOverviewCacheAsync()
    if not UI.overview then return end
    UI._overviewBuildToken = (UI._overviewBuildToken or 0) + 1
    local token = UI._overviewBuildToken

    local cache = EnsureOverviewCache()
    cache._building = true
    cache._dirty = nil
    cache._dirtyReason = nil

    local idx = 1
    local sumC, sumT = 0, 0
    local step

    local function finalizeCategory(cat, c, t, state)
      if token ~= UI._overviewBuildToken then return end
      cache[cat] = { c = c or 0, t = t or 0, ts = time and time() or 0, unsupported = (state == "unsupported") and true or nil }
      if state ~= "unsupported" then
        sumC = sumC + (c or 0)
        sumT = sumT + (t or 0)
      end

      idx = idx + 1
      if C_Timer and C_Timer.After then
        C_Timer.After(0, step)
      else
        step()
      end
    end

    step = function()
      if token ~= UI._overviewBuildToken then return end -- superseded
      local cat = cats[idx]
      if not cat then
        cache._building = nil
        cache._ts = time and time() or 0
        cache._total = { c = sumC, t = sumT, ts = cache._ts }
        RenderOverviewFromCache()
        return
      end

      local c, t, state
      if cat == "Mounts" then
        c, t = GetBlizzardMountTotals()
      elseif cat == "Pets" then
        local pt = CollectionLogDB and CollectionLogDB.cache and CollectionLogDB.cache.petTotals
        if pt and type(pt.c) == "number" and type(pt.t) == "number" and pt.t > 0 then
          c, t = pt.c, pt.t
        else
          c, t = GetBlizzardPetTotals()
        end
      elseif cat == "Toys" then
        -- Blizzard-truth totals (works without opening the Toy Box UI).
        c, t = GetBlizzardToyTotals()
      elseif cat == "Raids" or cat == "Dungeons" then
        ComputeOverviewCategoryProgressAsync(cat, function(ac, at, astate)
          finalizeCategory(cat, ac, at, astate)
        end)
        return
      else
        c, t, state = ComputeCategoryProgress(cat)
      end

      finalizeCategory(cat, c, t, state)
    end

    step()
  end

  function UI.RefreshOverview()
    if not UI.overview or not UI.overview:IsShown() then return end
    RenderOverviewFromCache()

    local cache = EnsureOverviewCache()
    if cache._building then return end
    if cache._dirty then
      UI.RequestOverviewRebuild(cache._dirtyReason or "dirty", true)
      return
    end

    -- Auto-heal: if any category is missing OR looks "not ready" (0/0 while we have groups),
    -- request a rebuild. This prevents Overview from getting stuck at 0/0 until a user clicks tabs.
    local needs = false
    for _, cat in ipairs(cats) do
      if not cache[cat] then
        needs = true
        break
      end

      -- Only treat 0/0 as "not ready" for Mounts/Pets/Toys/Housing.
      if (cat == "Mounts" or cat == "Pets" or cat == "Toys" or cat == "Housing") then
        local entry = cache[cat]
        local c = entry and entry.c or 0
        local t = entry and entry.t or 0
        local groups = ns and ns.Data and ns.Data.groupsByCategory and ns.Data.groupsByCategory[cat]
        local hasGroups = groups and #groups > 0

        -- If the tab has groups but totals are 0, it's likely "not ready" (stale cache).
        if hasGroups and (not t or t == 0) then
          needs = true
          break
        end

        -- If cache is 0/0 while Blizzard totals are non-zero, request a rebuild.
        -- No heavy group generation is triggered from Overview (keeps Overview instant).
        if (cat == "Mounts" or cat == "Pets" or cat == "Toys") and (not t or t == 0) then
          local jc, jt
          if cat == "Mounts" then
            jc, jt = GetBlizzardMountTotals()
          elseif cat == "Pets" then
            jc, jt = GetBlizzardPetTotals()
          else
            jc, jt = GetBlizzardToyTotals()
          end
          if jt and jt > 0 then
            needs = true
            break
          end
        end

        -- Housing: avoid forcing rebuild loops for users who truly have 0 collected.
        -- If cached collected is 0 but we can spot at least one collected housing item now,
        -- it means the earlier cache build happened before the housing catalog was ready.
        if cat == "Housing" and hasGroups and t and t > 0 and (not c or c == 0) then
          local found = false
          local checked = 0
          local MAX_CHECK = 25
          if ns and ns.IsHousingCollected then
            for _, g2 in ipairs(groups) do
              if type(g2) == "table" and type(g2.items) == "table" then
                for _, itemID in ipairs(g2.items) do
                  if itemID then
                    checked = checked + 1
                    if UI.HousingIsCollectedCached(itemID) then
                      found = true
                      break
                    end
                    if checked >= MAX_CHECK then break end
                  end
                end
              end
              if found or checked >= MAX_CHECK then break end
            end
          end
          if found then
            needs = true
            break
          end
        end
      end
    end

    if needs then
      UI.RequestOverviewRebuild("auto", true)
    end
  end

  function UI.ShowOverview(show)
    if not UI.overview then return end
    if show then
      if UI.overview:IsShown() and UI._clogOverviewShownActive then
        return
      end
      UI._clogOverviewShownActive = true
      if UI.wishlist then UI.wishlist:Hide() end
      if listPanel then listPanel:Hide() end
      if right then right:Hide() end
      UI.overview:Show()
      if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_overview", function() UI.RefreshOverview() end) else UI.RefreshOverview() end
    else
      if (not UI.overview:IsShown()) and not UI._clogOverviewShownActive then
        return
      end
      UI._clogOverviewShownActive = false
      UI.overview:Hide()
      if listPanel then listPanel:Show() end
      if right then right:Show() end
    end
  end

  local header = CreateFrame("Frame", nil, right)
  UI.header = header
  header:SetPoint("TOPLEFT", right, "TOPLEFT", 6, -10)
  header:SetPoint("TOPRIGHT", right, "TOPRIGHT", -6, -10)
  header:SetHeight(HEADER_H)

  local groupName = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  UI.groupName = groupName
  groupName:SetPoint("TOPLEFT", header, "TOPLEFT", 8, -6)
  groupName:SetFont(groupName:GetFont(), 16, "OUTLINE")
  groupName:SetText("Select an entry")

  local groupCount = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  UI.groupCount = groupCount
  groupCount:SetPoint("TOPLEFT", groupName, "BOTTOMLEFT", 1, -6)
  groupCount:SetTextColor(1, 1, 1, 1)
  groupCount:SetText("Collected: 0/0")


local completionCount = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
UI.completionCount = completionCount
completionCount:SetPoint("TOPLEFT", groupCount, "BOTTOMLEFT", 0, -4)
completionCount:SetTextColor(1, 1, 1, 1)
completionCount:SetText("")
completionCount:EnableMouse(true)
completionCount:SetScript("OnEnter", function(self)
  local tip = self and self._clogTooltipText
  if not tip or tip == "" then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
  GameTooltip:ClearLines()
  GameTooltip:AddLine(tip, 1, 1, 1, true)
  GameTooltip:Show()
end)
completionCount:SetScript("OnLeave", function()
  GameTooltip_Hide()
end)

  -- OSRS-style progress bar (pure UI; no SavedVariables impact)
  local pbBG = CreateFrame("Frame", nil, header, "BackdropTemplate")
  UI.progressBG = pbBG
  pbBG:SetPoint("TOPLEFT", (UI.completionCount or groupCount), "BOTTOMLEFT", -2, -6)
  pbBG:SetPoint("TOPRIGHT", header, "TOPRIGHT", -10, -6)
  -- OSRS-like thickness.
  pbBG:SetHeight(26)
  CreateThinBorder(pbBG)
  pbBG:SetBackdropBorderColor(0.25, 0.23, 0.16, 0.75)

  local pb = CreateFrame("StatusBar", nil, pbBG)
  UI.progressBar = pb
  pb:SetPoint("TOPLEFT", pbBG, "TOPLEFT", 3, -3)
  pb:SetPoint("BOTTOMRIGHT", pbBG, "BOTTOMRIGHT", -3, 3)
  pb:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
  pb:SetMinMaxValues(0, 1)
  pb:SetValue(0)
  pb:SetStatusBarColor(1, 0, 0, 0.65)

  local pbBack = pb:CreateTexture(nil, "BACKGROUND")
  pbBack:SetAllPoints(pb)
  pbBack:SetColorTexture(0, 0, 0, 0.55)

  local pbText = pb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  UI.progressText = pbText
  pbText:SetPoint("CENTER", pb, "CENTER", 0, 0)
  pbText:SetJustifyH("CENTER")
  pbText:SetText("")
  do
    local font, size, flags = pbText:GetFont()
    if font and size then
      pbText:SetFont(font, size + 2, flags)
    end
  end

  pb:Hide()
  pbBG:Hide()

  
  -- Pets filter dropdown is created after the difficulty dropdown for consistent alignment.

-- Difficulty dropdown (replaces Account/Character UI)
  local diff = CreateFrame("Frame", "CollectionLogDifficultyDropDown", header, "UIDropDownMenuTemplate")
  UI.diffDropdown = diff
  diff:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  UIDropDownMenu_SetWidth(diff, 170)

  -- Map pin button (Raids/Dungeons) completions: opens Encounter Journal to the selected instance.
  local mapPin = CreateFrame("Button", nil, header)
  UI.mapPin = mapPin
  mapPin:SetSize(18, 18)
  mapPin:SetPoint("LEFT", groupName, "RIGHT", 4.5, 0)
  mapPin:Hide()

-- Lock icon button (Raids/Dungeons): indicates you are locked to this instance+difficulty
local lockIcon = CreateFrame("Button", nil, header)
UI.lockIcon = lockIcon
do local h=(diff:GetHeight() or 24); if h<18 then h=18 elseif h>21 then h=21 end; lockIcon:SetSize(h,h) end
-- Anchor lock to the *left edge of the dropdown text box* (not the arrow button)
local ddLeft = (diff and diff.GetName and _G[diff:GetName().."Left"]) or nil
if ddLeft then
  -- UIDropDownMenuTemplate's left cap texture includes hidden padding; nudge right so the lock
  -- hugs the visible border with an effective ~2px gap.
  lockIcon:SetPoint("RIGHT", ddLeft, "LEFT", 12, 1) -- 12 = (-2 gap) + ~14px inset compensation
else
  lockIcon:SetPoint("RIGHT", diff, "LEFT", -2, 1)
end
lockIcon:Hide()

local lockTex = lockIcon:CreateTexture(nil, "OVERLAY")
lockTex:SetAllPoints()
lockTex:SetTexture("Interface\\AddOns\\CollectionLog\\Media\\petbattle-lockicon")
lockIcon.icon = lockTex
  -- Bright gold (match prior "good" look): keep normal BLEND so the texture stays crisp.
  lockTex:SetVertexColor(1.00, 0.92, 0.28, 1.00)
  lockTex:SetBlendMode("BLEND")

  -- Status overlays (top-right corner): red X when locked, green check when not locked.
  do
    local markSize = 14

    local markCheck = lockIcon:CreateTexture(nil, "OVERLAY", nil, 7)
    markCheck:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    markCheck:SetSize(markSize, markSize)
    markCheck:SetPoint("TOPRIGHT", lockTex, "TOPRIGHT", 6, 6)
    markCheck:Hide()

    local markX = lockIcon:CreateTexture(nil, "OVERLAY", nil, 7)
    markX:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    markX:SetSize(markSize, markSize)
    markX:SetPoint("TOPRIGHT", lockTex, "TOPRIGHT", 6, 6)
    markX:Hide()

    lockIcon._clMarkCheck = markCheck
    lockIcon._clMarkX = markX
  end
  -- IMPORTANT: Do not elevate strata above the parent header. Some minimap-button collectors
  -- use high-strata frames; if we force higher strata here, the lock icon can bleed above those
  -- collector frames even when the main window does not.
  do
    local fl = header and header.GetFrameLevel and header:GetFrameLevel() or (diff:GetFrameLevel() or 1)
    lockIcon:SetFrameLevel(fl + 2)
  end
  lockIcon:EnableMouse(true)
  lockIcon:SetHitRectInsets(-2, -2, -2, -2)



-- Ensure Encounter Journal is loaded (needed for EJ_* APIs)
local function CL_EnsureEncounterJournalLoaded()
  local isLoaded = false
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    isLoaded = C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal")
  elseif IsAddOnLoaded then
    isLoaded = IsAddOnLoaded("Blizzard_EncounterJournal")
  end
  if not isLoaded then
    local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn or UIParentLoadAddOn
    if loader then pcall(loader, "Blizzard_EncounterJournal") end
  end
end

local function CL_EnsureWorldMapLoaded()
  local isLoaded = false
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    isLoaded = C_AddOns.IsAddOnLoaded("Blizzard_WorldMap")
  elseif IsAddOnLoaded then
    isLoaded = IsAddOnLoaded("Blizzard_WorldMap")
  end
  if not isLoaded then
    local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn or UIParentLoadAddOn
    if loader then pcall(loader, "Blizzard_WorldMap") end
  end
end

local function CL_GetPlayerFactionIndex()
  local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
  if faction == "Alliance" then return 0 end
  if faction == "Horde" then return 1 end
  return -1
end

Wishlist.ResolveJournalEntrance = function(instanceID)
  local db = rawget(_G, "CollectionLog_JournalInstanceEntrance")
  if not db or type(db.Resolve) ~= "function" then return nil end
  local ok, entry = pcall(db.Resolve, instanceID, CL_GetPlayerFactionIndex())
  if ok and type(entry) == "table" then return entry end
  return nil
end

Wishlist.TryConvertJournalEntranceToWaypoint = function(entry)
  if type(entry) ~= "table" then return nil end

  local rawMapID = tonumber(entry.mapID)
  local wx = tonumber(entry.wx)
  local wy = tonumber(entry.wy)
  if not wx or not wy then return nil end

  if rawMapID and rawMapID > 0 and wx >= 0 and wx <= 1 and wy >= 0 and wy <= 1 then
    return rawMapID, wx, wy
  end

  if not (C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
  if rawMapID == nil then return nil end

  local ok, uiMapID, mapPos = pcall(C_Map.GetMapPosFromWorldPos, rawMapID, CreateVector2D(wx, wy))
  if not ok or not uiMapID or not mapPos or type(mapPos) ~= "table" then return nil end

  local x = tonumber(mapPos.x)
  local y = tonumber(mapPos.y)
  if not x or not y then return nil end
  if x < 0 or x > 1 or y < 0 or y > 1 then return nil end

  return uiMapID, x, y
end

Wishlist.ShowWorldMapToWaypoint = function(uiMapID, x, y)
  if not (uiMapID and x and y and UiMapPoint and UiMapPoint.CreateFromCoordinates and C_Map and C_Map.SetUserWaypoint) then
    return false
  end

  local point = UiMapPoint.CreateFromCoordinates(uiMapID, x, y)
  if not point then return false end

  local ok = pcall(C_Map.SetUserWaypoint, point)
  if not ok then return false end

  if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
    pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
  end

  local inCombat = InCombatLockdown and InCombatLockdown()
  if not inCombat then
    if C_Map and C_Map.OpenWorldMap then
      pcall(C_Map.OpenWorldMap, uiMapID)
    elseif OpenWorldMap then
      pcall(OpenWorldMap, uiMapID)
    end
  end

  return true
end

-- Resolve EJ instanceID by matching the instance name through EJ (EJ IDs often differ from map/instance IDs)
-- Resolve an Encounter Journal instanceID by matching the instance name.
-- EJ instanceIDs are NOT the same as map/instance IDs (e.g. ICC is 631 in maps, but a different EJ id).
-- We do a tier scan and use a normalized comparison to handle punctuation / minor naming differences.
local function CL_ResolveEJInstanceIDByName(instanceName, isRaid)
  if not instanceName or instanceName == "" then return nil end

  -- Ensure EJ API is available (some clients lazy-load the EJ UI)
  if EncounterJournal_LoadUI and not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then
    pcall(EncounterJournal_LoadUI)
  end
  if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then return nil end

  local function norm(s)
    if not s then return "" end
    s = tostring(s)
    s = s:gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r','')
    s = s:lower()
    -- normalize common punctuation/whitespace differences
    s = s:gsub("[â€™']", ""):gsub("%-", " "):gsub("%s+", " ")
    s = s:gsub("[^%w%s]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return s
  end

  local target = norm(instanceName)

  local numTiers = EJ_GetNumTiers()
  if not numTiers or numTiers < 1 then numTiers = 1 end

  local bestID, bestScore = nil, 0

  for tier = 1, numTiers do
    pcall(EJ_SelectTier, tier)

    for idx = 1, 250 do
      local ok, ejID, ejName = pcall(function()
        local a = { EJ_GetInstanceByIndex(idx, isRaid and true or false) }
        return a[1], a[2]
      end)
      if not ok or not ejID then break end

      local n = norm(ejName)
      if n == target then
        return ejID -- perfect match
      end

      -- fuzzy: substring containment; prefer longer/closer matches
      local score = 0
      if n ~= "" and target ~= "" then
        if n:find(target, 1, true) then
          score = 50 + #target
        elseif target:find(n, 1, true) then
          score = 40 + #n
        end
      end

      if score > bestScore then
        bestScore = score
        bestID = ejID
      end
    end
  end

  return bestID
end

lockIcon:SetScript("OnEnter", function(self)
    -- Ask Blizzard to refresh saved-instance data before building the tooltip.
    -- This helps character swaps settle to the current character's lockouts.
    if RequestRaidInfo then pcall(RequestRaidInfo) end

    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    if self._lockResetText then
        GameTooltip:AddLine("Locked out", 1, 1, 1)
    else
        GameTooltip:AddLine("Not locked", 1, 1, 1)
    end

    CL_AddLockoutBossTooltip(GameTooltip, self._clInstanceID, self._clInstanceName, self._clDifficultyID)
    GameTooltip:Show()
end)

lockIcon:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)



  -- Use a map-pin atlas when available; fall back to a small minimize-style icon.
  local okAtlas = false
  if mapPin.SetNormalAtlas then
    okAtlas = pcall(mapPin.SetNormalAtlas, mapPin, "Waypoint-MapPin-Tracked")
    if okAtlas and mapPin.SetHighlightAtlas then
      pcall(mapPin.SetHighlightAtlas, mapPin, "Waypoint-MapPin-Tracked", "ADD")
    end
  end
  if not okAtlas then
    mapPin:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    mapPin:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    mapPin:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
  end

  mapPin:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self._clHasWaypoint then
      GameTooltip:AddLine("Open Map + Set Waypoint", 1, 1, 1)
      GameTooltip:AddLine("Opens the world map and drops a waypoint at this entrance.", 0.8, 0.8, 0.8, true)
    else
      GameTooltip:AddLine("Waypoint unavailable", 1, 1, 1)
      GameTooltip:AddLine("Verified entrance coordinates are not available for this instance yet.", 0.8, 0.8, 0.8, true)
      GameTooltip:AddLine("Click to open the Encounter Journal instead.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
  end)
  mapPin:SetScript("OnLeave", function() GameTooltip:Hide() end)

  mapPin:SetScript("OnClick", function()
    if InCombatLockdown and InCombatLockdown() then return end

    local dbui = CollectionLogDB and CollectionLogDB.ui
    local groupId = dbui and dbui.activeGroupId
    local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId] or nil
    local instanceID = g and g.instanceID or nil
    if not instanceID then return end

    -- Determine whether this is a raid or dungeon for EJ_GetInstanceByIndex.
    local activeCat = dbui and dbui.activeCategory or nil
    local isRaid = (activeCat == "Raids") and true or false

    local resolvedEntrance = Wishlist.ResolveJournalEntrance(instanceID)
    if resolvedEntrance then
      local uiMapID, x, y = Wishlist.TryConvertJournalEntranceToWaypoint(resolvedEntrance)
      if uiMapID and x and y then
        if Wishlist.ShowWorldMapToWaypoint(uiMapID, x, y) then
          return
        end
      end
    end

    -- Load the Encounter Journal UI.
    local isLoaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
      isLoaded = C_AddOns.IsAddOnLoaded("Blizzard_EncounterJournal")
    elseif IsAddOnLoaded then
      isLoaded = IsAddOnLoaded("Blizzard_EncounterJournal")
    end
    if not isLoaded then
      local loader = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn or UIParentLoadAddOn
      if loader then pcall(loader, "Blizzard_EncounterJournal") end
    end
    if EncounterJournal_LoadUI then pcall(EncounterJournal_LoadUI) end

    -- Cache: instanceID -> EJ tier index (small integer, not addon sortTier).
    CollectionLogDB.ui = CollectionLogDB.ui or {}
    CollectionLogDB.ui.ejTierByInstance = CollectionLogDB.ui.ejTierByInstance or {}
    local cache = CollectionLogDB.ui.ejTierByInstance

    local function resolveTierForInstance(id)
      if cache[id] then return cache[id] end
      if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then return nil end

      local numTiers = EJ_GetNumTiers()
      if type(numTiers) ~= "number" or numTiers <= 0 then return nil end

      for tier = 1, numTiers do
        pcall(EJ_SelectTier, tier)

        local numInstances = nil
        if EJ_GetNumInstances then
          numInstances = EJ_GetNumInstances()
        end
        if type(numInstances) ~= "number" or numInstances <= 0 then
          -- Some clients rely on a max scan; 50 is plenty (tiers rarely exceed this).
          numInstances = 50
        end

        for i = 1, numInstances do
          local ok, instID = pcall(function()
            local a = { EJ_GetInstanceByIndex(i, isRaid) }
            return a[1]
          end)
          if ok and instID == id then
            cache[id] = tier
            return tier
          end
        end
      end
      return nil
    end

    local function openAndSelect()
      -- Open/show EJ first so the panel exists.
      if EncounterJournal_OpenJournal then
        -- IMPORTANT: Encounter Journal's OpenJournal signature varies by client version.
        -- On some builds, the instanceID is the *second* argument (encounterID first), and
        -- passing only instanceID can silently open the "home" (Journeys) surface.
        -- Try the common signatures in a safe order.
        local opened = false
        -- (encounterID, instanceID)
        opened = pcall(EncounterJournal_OpenJournal, nil, instanceID) and true or false
        -- (instanceID)
        if not opened then
          opened = pcall(EncounterJournal_OpenJournal, instanceID) and true or false
        end
        -- (instanceID, encounterID)
        if not opened then
          pcall(EncounterJournal_OpenJournal, instanceID, nil)
        end
      elseif ToggleEncounterJournal then
        pcall(ToggleEncounterJournal)
      elseif EncounterJournal and ShowUIPanel then
        pcall(ShowUIPanel, EncounterJournal)
      elseif EncounterJournal and EncounterJournal.Show then
        pcall(EncounterJournal.Show, EncounterJournal)
      end

	      -- Force the EJ into the Instances surface (Dungeons/Raids) rather than the Journeys/Home page.
	      -- On some clients, opening EJ lands on Journeys by default and will ignore tier/instance selection.
	      local desiredTab = isRaid and 2 or 1
	      if EncounterJournal_SelectTab then
	        pcall(EncounterJournal_SelectTab, desiredTab)
	      end
	      if EncounterJournal_SetTab then
	        pcall(EncounterJournal_SetTab, desiredTab)
	      end
	      if EncounterJournal_TabClicked then
	        pcall(EncounterJournal_TabClicked, desiredTab)
	      end
	      local tabBtn = _G and _G["EncounterJournalTab" .. desiredTab] or nil
	      if tabBtn and tabBtn.Click then
	        pcall(tabBtn.Click, tabBtn)
	      end
	      if EncounterJournal and EncounterJournal.tabs and EncounterJournal.tabs[desiredTab] and EncounterJournal.tabs[desiredTab].Click then
	        pcall(EncounterJournal.tabs[desiredTab].Click, EncounterJournal.tabs[desiredTab])
	      end

      -- Now that it's open, resolve tier and select in the correct order.
      local tier = resolveTierForInstance(instanceID)
      if tier and EJ_SelectTier then
        pcall(EJ_SelectTier, tier)
        if EncounterJournal_ListInstances then
          pcall(EncounterJournal_ListInstances)
        end
      end

      -- Some builds don't build the Instances list unless the corresponding UI exists.
      -- If available, force a refresh/update before selecting.
      if EncounterJournal_Refresh then
        pcall(EncounterJournal_Refresh)
      end
      if EncounterJournal_Update then
        pcall(EncounterJournal_Update)
      end

      if EJ_SetDifficulty and g and g.difficultyID then
        pcall(EJ_SetDifficulty, g.difficultyID)
      end
      if EJ_SelectInstance then
        pcall(EJ_SelectInstance, instanceID)
      end

      -- Prefer the instance Overview page (not Loot) for a consistent UX.
      if EncounterJournal_DisplayInstance then
        pcall(EncounterJournal_DisplayInstance, instanceID)
      end
      if EncounterJournal_ShowInstance then
        pcall(EncounterJournal_ShowInstance, instanceID)
      end
      if EncounterJournal_SetTab and EncounterJournal.encounter and EncounterJournal.encounter.info then
        -- Some clients use SetTab for the instance sub-tabs (Overview/Loot); safest is to click the Overview tab if present.
        local overviewTab = EncounterJournal.encounter.info.OverviewTab or EncounterJournal.encounter.info.overviewTab
        if overviewTab and overviewTab.Click then pcall(overviewTab.Click, overviewTab) end
      end
    end

    -- Defer selection to allow EJ to fully initialize (opening on "home" is a timing symptom).
    if C_Timer and C_Timer.After then
      C_Timer.After(0, function()
        openAndSelect()
        C_Timer.After(0.10, openAndSelect)
      end)
    else
      openAndSelect()
    end
  end)

  -- Pager control (Pets/Mounts/Raids). Position is decided dynamically in UpdatePagerUI:
  --  * Pets: in the header, left of the filter dropdown
  --  * Mounts/Raids: bottom-right of the grid (only when more than 1 page)
  -- Layout:
  --    < Page 1/4 >
  --   (1-600 of 1987)
  local pager = CreateFrame("Frame", nil, header)
  UI.pager = pager
  pager:SetSize(140, 34)
  pager:Hide()

  local prev = CreateFrame("Button", nil, pager, "UIPanelButtonTemplate")
  UI.pagerPrev = prev
  prev:SetSize(18, 18)
  prev:SetText("<")
  prev:SetPoint("TOPLEFT", pager, "TOPLEFT", 0, 0)

  local next = CreateFrame("Button", nil, pager, "UIPanelButtonTemplate")
  UI.pagerNext = next
  next:SetSize(18, 18)
  next:SetText(">")
  next:SetPoint("TOPRIGHT", pager, "TOPRIGHT", 0, 0)

  local pageText = pager:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  UI.pagerText = pageText
  pageText:SetPoint("TOP", pager, "TOP", 0, -2)
  pageText:SetJustifyH("CENTER")
  pageText:SetText("Page 1/1")

  local showingText = pager:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  UI.pagerShowing = showingText
  showingText:SetPoint("TOP", pageText, "BOTTOM", 0, -2)
  showingText:SetJustifyH("CENTER")
  showingText:SetText("")
  -- Make the "(x-y of z)" range text slightly smaller than "Page X/Y".
  do
    local font, size, flags = showingText:GetFont()
    if font and size then
      showingText:SetFont(font, size - 1, flags)
    end
  end

  -- Pets filter dropdown (Collected / Not Collected). UI-only; defaults to showing ALL.
  local petsFilter = CreateFrame("Frame", "CollectionLogPetsFilterDropDown", header, "UIDropDownMenuTemplate")
  UI.petsFilterDD = petsFilter
  UIDropDownMenu_SetWidth(petsFilter, 140)

  -- Mounts filter dropdown (Collected / Not Collected). UI-only; defaults to showing ALL.
  local mountsFilter = CreateFrame("Frame", "CollectionLogMountsFilterDropDown", header, "UIDropDownMenuTemplate")
  UI.mountsFilterDD = mountsFilter
  UIDropDownMenu_SetWidth(mountsFilter, 140)

  -- Toys filter dropdown (Collected / Not Collected). UI-only; defaults to showing ALL.
  local toysFilter = CreateFrame("Frame", "CollectionLogToysFilterDropDown", header, "UIDropDownMenuTemplate")
  UI.toysFilterDD = toysFilter
  UIDropDownMenu_SetWidth(toysFilter, 140)

  -- Housing filter dropdown (Collected / Not Collected). UI-only; defaults to showing ALL.
  local housingFilter = CreateFrame("Frame", "CollectionLogHousingFilterDropDown", header, "UIDropDownMenuTemplate")
  UI.housingFilterDD = housingFilter
  UIDropDownMenu_SetWidth(housingFilter, 140)

  local appearanceClassFilter = CreateFrame("Frame", "CollectionLogAppearanceClassFilterDropDown", header, "UIDropDownMenuTemplate")
  UI.appearanceClassFilterDD = appearanceClassFilter
  UIDropDownMenu_SetWidth(appearanceClassFilter, 160)
  appearanceClassFilter:Hide()


  local function GetPetsFilterState()
    local showCollected, showNotCollected = true, true
    if CollectionLogDB and CollectionLogDB.ui then
      if CollectionLogDB.ui.petsShowCollected ~= nil then showCollected = CollectionLogDB.ui.petsShowCollected end
      if CollectionLogDB.ui.petsShowNotCollected ~= nil then showNotCollected = CollectionLogDB.ui.petsShowNotCollected end
    end
    return showCollected, showNotCollected
  end

  local function SetPetsFilterState(showCollected, showNotCollected)
    if CollectionLogDB and CollectionLogDB.ui then
      CollectionLogDB.ui.petsShowCollected = showCollected and true or false
      CollectionLogDB.ui.petsShowNotCollected = showNotCollected and true or false
    end
  end

  local function PetsFilterLabel()
    local showCollected, showNotCollected = GetPetsFilterState()
    if showCollected and showNotCollected then return "All" end
    if showCollected and (not showNotCollected) then return "Collected" end
    if (not showCollected) and showNotCollected then return "Not Collected" end
    return "None"
  end

  function UI.BuildPetsFilterDropdown()
    UIDropDownMenu_SetText(petsFilter, PetsFilterLabel())
    UIDropDownMenu_Initialize(petsFilter, function(self, level)
      local showCollected, showNotCollected = GetPetsFilterState()

      local info = UIDropDownMenu_CreateInfo()
      info.text = "Collected"
      info.checked = showCollected
      info.keepShownOnClick = true
      info.isNotRadio = true
      info.func = function()
        showCollected = not showCollected
        SetPetsFilterState(showCollected, showNotCollected)
        if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.petsPage = 1 end
        UIDropDownMenu_SetText(petsFilter, PetsFilterLabel())
        UI.RefreshGrid()
      end
      UIDropDownMenu_AddButton(info, level)

      info = UIDropDownMenu_CreateInfo()
      info.text = "Not Collected"
      info.checked = showNotCollected
      info.keepShownOnClick = true
      info.isNotRadio = true
      info.func = function()
        showNotCollected = not showNotCollected
        SetPetsFilterState(showCollected, showNotCollected)
        if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.petsPage = 1 end
        UIDropDownMenu_SetText(petsFilter, PetsFilterLabel())
        UI.RefreshGrid()
      end
      UIDropDownMenu_AddButton(info, level)
    end)
  end

  -- =============================
  -- Mounts filter dropdown (Collected / Not Collected)
  -- =============================
  local function GetMountsFilterState()
    local showCollected, showNotCollected = true, true
    if CollectionLogDB and CollectionLogDB.ui then
      if CollectionLogDB.ui.mountsShowCollected ~= nil then showCollected = CollectionLogDB.ui.mountsShowCollected end
      if CollectionLogDB.ui.mountsShowNotCollected ~= nil then showNotCollected = CollectionLogDB.ui.mountsShowNotCollected end
    end
    return showCollected, showNotCollected
  end

  local function SetMountsFilterState(showCollected, showNotCollected)
    if CollectionLogDB and CollectionLogDB.ui then
      CollectionLogDB.ui.mountsShowCollected = showCollected and true or false
      CollectionLogDB.ui.mountsShowNotCollected = showNotCollected and true or false
    end
  end

  local function MountsFilterLabel()
    local showCollected, showNotCollected = GetMountsFilterState()
    if showCollected and showNotCollected then return "All" end
    if showCollected and (not showNotCollected) then return "Collected" end
    if (not showCollected) and showNotCollected then return "Not Collected" end
    return "None"
  end

  function UI.BuildMountsFilterDropdown()
    UIDropDownMenu_SetText(mountsFilter, MountsFilterLabel())
    UIDropDownMenu_Initialize(mountsFilter, function(self, level)
      local showCollected, showNotCollected = GetMountsFilterState()

      local info = UIDropDownMenu_CreateInfo()
      info.text = "Collected"
      info.checked = showCollected
      info.keepShownOnClick = true
      info.isNotRadio = true
      info.func = function()
        showCollected = not showCollected
        SetMountsFilterState(showCollected, showNotCollected)
        if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.mountsPage = 1 end
        UIDropDownMenu_SetText(mountsFilter, MountsFilterLabel())
        UI.RefreshGrid()
      end
      UIDropDownMenu_AddButton(info, level)

      info = UIDropDownMenu_CreateInfo()
      info.text = "Not Collected"
      info.checked = showNotCollected
      info.keepShownOnClick = true
      info.isNotRadio = true
      info.func = function()
        showNotCollected = not showNotCollected
        SetMountsFilterState(showCollected, showNotCollected)
        if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.mountsPage = 1 end
        UIDropDownMenu_SetText(mountsFilter, MountsFilterLabel())
        UI.RefreshGrid()
      end
      UIDropDownMenu_AddButton(info, level)
    end)
  end

  -- Anchor it just left of the difficulty dropdown, matching the Raids/Dungeons layout.
  -- IMPORTANT: For Pets/Mounts, we want the filter control to sit in the EXACT
  -- same header position as the Difficulty dropdown used by Raids/Dungeons.
  -- Therefore we anchor the filter dropdowns to the same point as `diff`.
  appearanceClassFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  function UI.BuildAppearanceClassDropdown()
    local token = (ns and ns.GetAppearanceClassFilter and ns.GetAppearanceClassFilter()) or "ALL"
    local labels = ns and ns.AppearanceRuntime and ns.AppearanceRuntime.CLASS_LABELS or nil
    UIDropDownMenu_SetText(appearanceClassFilter, (labels and labels[token]) or token)
    UIDropDownMenu_Initialize(appearanceClassFilter, function(self, level)
      local order = ns and ns.AppearanceRuntime and ns.AppearanceRuntime.CLASS_ORDER or { "ALL" }
      local classLabels = ns and ns.AppearanceRuntime and ns.AppearanceRuntime.CLASS_LABELS or {}
      for _, classToken in ipairs(order) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = classLabels[classToken] or classToken
        info.value = classToken
        info.checked = (token == classToken)
        info.func = function()
          if ns and ns.SetAppearanceClassFilter then ns.SetAppearanceClassFilter(classToken) end
          if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.activeGroupId = nil; CollectionLogDB.ui._forceDefaultGroup = true end
          UIDropDownMenu_SetText(appearanceClassFilter, classLabels[classToken] or classToken)
          BuildGroupList()
          UI.RefreshGrid()
        end
        UIDropDownMenu_AddButton(info, level)
      end
    end)
  end

local function GetToysFilterState()
  local showCollected, showNotCollected = true, true
  if CollectionLogDB and CollectionLogDB.ui then
    if CollectionLogDB.ui.toysShowCollected ~= nil then showCollected = CollectionLogDB.ui.toysShowCollected end
    if CollectionLogDB.ui.toysShowNotCollected ~= nil then showNotCollected = CollectionLogDB.ui.toysShowNotCollected end
  end
  return showCollected, showNotCollected
end

local function SetToysFilterState(showCollected, showNotCollected)
  if CollectionLogDB and CollectionLogDB.ui then
    CollectionLogDB.ui.toysShowCollected = showCollected and true or false
    CollectionLogDB.ui.toysShowNotCollected = showNotCollected and true or false
  end
end

local function ToysFilterLabel()
  local showCollected, showNotCollected = GetToysFilterState()
  if showCollected and showNotCollected then return "All" end
  if showCollected and (not showNotCollected) then return "Collected" end
  if (not showCollected) and showNotCollected then return "Not Collected" end
  return "None"
end

function UI.BuildToysFilterDropdown()
  UIDropDownMenu_SetText(toysFilter, ToysFilterLabel())
  UIDropDownMenu_Initialize(toysFilter, function(self, level)
    local showCollected, showNotCollected = GetToysFilterState()

    local info = UIDropDownMenu_CreateInfo()
    info.text = "Collected"
    info.checked = showCollected
    info.keepShownOnClick = true
    info.isNotRadio = true
    info.func = function()
      showCollected = not showCollected
      SetToysFilterState(showCollected, showNotCollected)
      if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.toysPage = 1 end
      UIDropDownMenu_SetText(toysFilter, ToysFilterLabel())
      UI.RefreshGrid()
    end
    UIDropDownMenu_AddButton(info, level)

    local info2 = UIDropDownMenu_CreateInfo()
    info2.text = "Not Collected"
    info2.checked = showNotCollected
    info2.keepShownOnClick = true
    info2.isNotRadio = true
    info2.func = function()
      showNotCollected = not showNotCollected
      SetToysFilterState(showCollected, showNotCollected)
      if CollectionLogDB and CollectionLogDB.ui then CollectionLogDB.ui.toysPage = 1 end
      UIDropDownMenu_SetText(toysFilter, ToysFilterLabel())
      UI.RefreshGrid()
    end
    UIDropDownMenu_AddButton(info2, level)
  end)
end

-- =============================
-- Housing filter dropdown (Collected / Not Collected)
-- =============================
local function GetHousingFilterState()
  local showCollected, showNotCollected = true, true
  if CollectionLogDB and CollectionLogDB.ui then
    if CollectionLogDB.ui.housingShowCollected ~= nil then showCollected = CollectionLogDB.ui.housingShowCollected end
    if CollectionLogDB.ui.housingShowNotCollected ~= nil then showNotCollected = CollectionLogDB.ui.housingShowNotCollected end
  end
  return showCollected, showNotCollected
end

local function SetHousingFilterState(showCollected, showNotCollected)
  if CollectionLogDB and CollectionLogDB.ui then
    CollectionLogDB.ui.housingShowCollected = showCollected and true or false
    CollectionLogDB.ui.housingShowNotCollected = showNotCollected and true or false
  end
end

local function HousingFilterLabel()
  local showCollected, showNotCollected = GetHousingFilterState()
  if showCollected and showNotCollected then return "All" end
  if showCollected and (not showNotCollected) then return "Collected" end
  if (not showCollected) and showNotCollected then return "Not Collected" end
  return "None"
end

function UI.BuildHousingFilterDropdown()
  UIDropDownMenu_SetText(housingFilter, HousingFilterLabel())
  UIDropDownMenu_Initialize(housingFilter, function(self, level)
    local showCollected, showNotCollected = GetHousingFilterState()

    local info = UIDropDownMenu_CreateInfo()
    info.text = "Collected"
    info.checked = showCollected
    info.keepShownOnClick = true
    info.isNotRadio = true
    info.func = function()
      showCollected = not showCollected
      SetHousingFilterState(showCollected, showNotCollected)
      UIDropDownMenu_SetText(housingFilter, HousingFilterLabel())
      UI.RefreshGrid()
    end
    UIDropDownMenu_AddButton(info, level)

    local info2 = UIDropDownMenu_CreateInfo()
    info2.text = "Not Collected"
    info2.checked = showNotCollected
    info2.keepShownOnClick = true
    info2.isNotRadio = true
    info2.func = function()
      showNotCollected = not showNotCollected
      SetHousingFilterState(showCollected, showNotCollected)
      UIDropDownMenu_SetText(housingFilter, HousingFilterLabel())
      UI.RefreshGrid()
    end
    UIDropDownMenu_AddButton(info2, level)
  end)
end

  petsFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  mountsFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  toysFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  housingFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  petsFilter:Hide()
  mountsFilter:Hide()
  toysFilter:Hide()
  housingFilter:Hide()

  -- Default state (show all) if unset
  if CollectionLogDB and CollectionLogDB.ui then
    if CollectionLogDB.ui.petsShowCollected == nil then CollectionLogDB.ui.petsShowCollected = true end
    if CollectionLogDB.ui.petsShowNotCollected == nil then CollectionLogDB.ui.petsShowNotCollected = true end
    if CollectionLogDB.ui.mountsShowCollected == nil then CollectionLogDB.ui.mountsShowCollected = true end
    if CollectionLogDB.ui.mountsShowNotCollected == nil then CollectionLogDB.ui.mountsShowNotCollected = true end
    if CollectionLogDB.ui.toysShowCollected == nil then CollectionLogDB.ui.toysShowCollected = true end
    if CollectionLogDB.ui.toysShowNotCollected == nil then CollectionLogDB.ui.toysShowNotCollected = true end
    if CollectionLogDB.ui.housingShowCollected == nil then CollectionLogDB.ui.housingShowCollected = true end
    if CollectionLogDB.ui.housingShowNotCollected == nil then CollectionLogDB.ui.housingShowNotCollected = true end
  end

  -- Pager UI updater. Called by RefreshGrid() after filtering.
  function UI:UpdatePagerUI(isPetsActive, isMountsActive, isToysActive, isHousingActive, isRaidsActive, page, maxPage, startIndex, endIndex, totalItems)
    -- Only show pager for Pets/Mounts/Toys/Housing/Raids.
    if not (isPetsActive or isMountsActive or isToysActive or isHousingActive or isRaidsActive) then
      if pager then pager:Hide() end
      if UI.SetFooterLaneEnabled then UI.SetFooterLaneEnabled(false) end
      return
    end

    page = tonumber(page) or 1
    maxPage = tonumber(maxPage) or 1
    startIndex = tonumber(startIndex) or 0
    endIndex = tonumber(endIndex) or 0
    totalItems = tonumber(totalItems) or 0

    -- If there's only a single page, hide the pager (keeps the header clean).
    if maxPage <= 1 then
      if pager then pager:Hide() end
      -- Mounts/Pets use a reserved footer lane only when paging is needed.
      if (isPetsActive or isMountsActive or isToysActive or isHousingActive) and UI.SetFooterLaneEnabled then
        UI.SetFooterLaneEnabled(false)
      end
      return
    end

    -- Placement rules:
    --  * Mounts & Pets: anchored in a reserved footer lane (bottom-right) so controls
    --    never overlap the icon grid.
    --  * Raids: bottom-right of the grid area (legacy behavior; no footer lane).
    if pager then
      pager:ClearAllPoints()
      if isMountsActive or isPetsActive or isToysActive or isHousingActive then
        if UI.SetFooterLaneEnabled then UI.SetFooterLaneEnabled(true) end
        if UI.footerLane then
          pager:SetPoint("BOTTOMRIGHT", UI.footerLane, "BOTTOMRIGHT", 0, 0)
        elseif UI and UI.right then
          pager:SetPoint("BOTTOMRIGHT", UI.right, "BOTTOMRIGHT", -34, 10)
        else
          pager:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -34, -6)
        end
      elseif isRaidsActive then
        if UI.SetFooterLaneEnabled then UI.SetFooterLaneEnabled(false) end
        if UI and UI.right then
          pager:SetPoint("BOTTOMRIGHT", UI.right, "BOTTOMRIGHT", -34, 10)
        else
          pager:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -34, -6)
        end
      else
        if UI.SetFooterLaneEnabled then UI.SetFooterLaneEnabled(false) end
      end
    end

    if UI.pagerText then UI.pagerText:Show(); UI.pagerText:SetText(string.format("Page %d/%d", page, maxPage)) end
    if UI.pagerShowing then UI.pagerShowing:Show()
      if totalItems > 0 then
        UI.pagerShowing:SetText(string.format("(%d-%d of %d)", startIndex, endIndex, totalItems))
      else
        UI.pagerShowing:SetText("")
      end
    end

    if UI.pagerPrev then UI.pagerPrev:Show(); UI.pagerPrev:SetEnabled(page > 1) end
    if UI.pagerNext then UI.pagerNext:Show(); UI.pagerNext:SetEnabled(page < maxPage) end

    if not pager._wired then
      pager._wired = true
      UI.pagerPrev:SetScript("OnClick", function()
        if not (CollectionLogDB and CollectionLogDB.ui) then return end
        local cat = CollectionLogDB.ui.activeCategory
        if cat == "Pets" then
          CollectionLogDB.ui.petsPage = math.max(1, (CollectionLogDB.ui.petsPage or 1) - 1)
        elseif cat == "Mounts" then
          CollectionLogDB.ui.mountsPage = math.max(1, (CollectionLogDB.ui.mountsPage or 1) - 1)
        elseif cat == "Toys" then
          CollectionLogDB.ui.toysPage = math.max(1, (CollectionLogDB.ui.toysPage or 1) - 1)
        elseif cat == "Housing" then
          CollectionLogDB.ui.housingPage = math.max(1, (CollectionLogDB.ui.housingPage or 1) - 1)
        elseif cat == "Raids" then
          CollectionLogDB.ui.raidsPage = math.max(1, (CollectionLogDB.ui.raidsPage or 1) - 1)
        end
        UI.RefreshGrid()
      end)
      UI.pagerNext:SetScript("OnClick", function()
        if not (CollectionLogDB and CollectionLogDB.ui) then return end
        local cat = CollectionLogDB.ui.activeCategory
        if cat == "Pets" then
          CollectionLogDB.ui.petsPage = (CollectionLogDB.ui.petsPage or 1) + 1
        elseif cat == "Mounts" then
          CollectionLogDB.ui.mountsPage = (CollectionLogDB.ui.mountsPage or 1) + 1
        elseif cat == "Toys" then
          CollectionLogDB.ui.toysPage = (CollectionLogDB.ui.toysPage or 1) + 1
        elseif cat == "Housing" then
          CollectionLogDB.ui.housingPage = (CollectionLogDB.ui.housingPage or 1) + 1
        elseif cat == "Raids" then
          CollectionLogDB.ui.raidsPage = (CollectionLogDB.ui.raidsPage or 1) + 1
        end
        UI.RefreshGrid()
      end)
    end

    if pager then pager:Show() end
  end


  function UI.BuildDifficultyDropdown()
    local groupId = CollectionLogDB.ui.activeGroupId
    local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId]
    if not g or not g.instanceID then
      diff:Hide()
      return
    end

    diff:Show()

    local siblingsRaw = GetSiblingGroups(g.instanceID, g.category)

-- Filter + normalize to the only tiers we support in the selector.
local siblings = {}
local ctx = { multiSize = { H = false, N = false } }
do
  local sizesH, sizesN = {}, {}
  for _, sg in ipairs(siblingsRaw) do
    local tier, size = GetDifficultyMeta(sg.difficultyID, sg.mode)
    if tier == "M" or tier == "H" or tier == "N" or tier == "LFR" or tier == "TW" then
      table.insert(siblings, sg)
      if tier == "H" then sizesH[size or 0] = true end
      if tier == "N" then sizesN[size or 0] = true end
    end
  end
  local function CountKeys(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
  end
  ctx.multiSize.H = CountKeys(sizesH) > 1
  ctx.multiSize.N = CountKeys(sizesN) > 1
end

table.sort(siblings, function(a, b)
  local da = DifficultyDisplayOrder(a.difficultyID, a.mode)
  local db = DifficultyDisplayOrder(b.difficultyID, b.mode)
  if da ~= db then return da < db end
  return (a.id or "") < (b.id or "")
end)

local function DifficultyDropdownLabel(did, mode)
  return DifficultyLongLabel(did, mode, ctx)
end

if #siblings == 0 then
      diff:Hide()
      return
    end

    UIDropDownMenu_Initialize(diff, function(self, level)
      for _, sg in ipairs(siblings) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = DifficultyDropdownLabel(sg.difficultyID, sg.mode)
        info.value = sg.id
        info.checked = (sg.id == CollectionLogDB.ui.activeGroupId)
        info.func = function()
          CollectionLogDB.ui.activeGroupId = sg.id
          CollectionLogDB.ui.lastDifficultyByInstance[g.instanceID] = sg.difficultyID
          UI.RefreshGrid()
          BuildGroupList()
          -- v4.3.87: dropdown changes refresh only the selected group's own truth.
          if CLOG_ScheduleDifficultyIndicatorRepaintForGroup then CLOG_ScheduleDifficultyIndicatorRepaintForGroup(sg.id) end
        end
        UIDropDownMenu_AddButton(info, level)
      end
    end)

    -- Set current label
    local curLabel = DifficultyDropdownLabel(g.difficultyID, g.mode)
    UIDropDownMenu_SetText(diff, curLabel)
    -- v4.3.87: dropdown build is paint-only; no sibling truth generation here.
    if CLOG_ScheduleDifficultyIndicatorRepaintForGroup then CLOG_ScheduleDifficultyIndicatorRepaintForGroup(g.id) end
  end


  local gridScroll = CreateFrame("ScrollFrame", "CollectionLogGridScroll", right, "UIPanelScrollFrameTemplate")
  UI.gridScroll = gridScroll
  gridScroll:SetPoint("TOPLEFT", UI.progressBG or header, "BOTTOMLEFT", 0, -2)
  -- NOTE: The bottom anchor is adjusted dynamically for Mounts/Pets when we enable a
  -- dedicated footer lane for paging controls.
  gridScroll:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -26, 6)

  -- Footer lane (Mounts/Pets only) completions: reserves vertical space so paging controls never
  -- overlap the icon grid.
  local footerLane = CreateFrame("Frame", nil, right)
  UI.footerLane = footerLane
  footerLane:SetHeight(36)
  footerLane:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 8, 6)
  footerLane:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -34, 6) -- leave space for scrollbar
  footerLane:Hide()

  -- Toggle footer lane and adjust the grid scroll area's bottom inset accordingly.
  -- This is a UI-only layout tweak; it does not affect any underlying data.
  UI._gridBottomInsetDefault = 6
  UI._gridBottomInsetWithFooter = 46 -- 6 + 36 footer + ~4 padding
  function UI.SetFooterLaneEnabled(enabled)
    if not UI.gridScroll then return end
    if enabled then
      footerLane:Show()
      UI.gridScroll:ClearAllPoints()
      UI.gridScroll:SetPoint("TOPLEFT", UI.progressBG or header, "BOTTOMLEFT", 0, -2)
      UI.gridScroll:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -26, UI._gridBottomInsetWithFooter)
    else
      footerLane:Hide()
      UI.gridScroll:ClearAllPoints()
      UI.gridScroll:SetPoint("TOPLEFT", UI.progressBG or header, "BOTTOMLEFT", 0, -2)
      UI.gridScroll:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -26, UI._gridBottomInsetDefault)
    end
  end

  local grid = CreateFrame("Frame", nil, gridScroll)
  UI.grid = grid
  grid:SetSize(1, 1)
  gridScroll:SetScrollChild(grid)

  gridScroll:EnableMouseWheel(true)
  -- Clamp mousewheel scrolling to the scroll range so we don't allow "infinite" blank scrolling.
  gridScroll:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll() or 0
    local step = 40
    local maxScroll = self:GetVerticalScrollRange() or 0
    local nextScroll = cur - (delta * step)
    if nextScroll < 0 then nextScroll = 0 end
    if nextScroll > maxScroll then nextScroll = maxScroll end
    self:SetVerticalScroll(nextScroll)
  end)

  UI.cells = {}
  UI.maxCells = 0

  function UI.UpdateScrollAffordances()
    local function apply(sf)
      if not sf then return end
      local range = 0
      pcall(function() range = tonumber(sf:GetVerticalScrollRange() or 0) or 0 end)
      local bar = sf.ScrollBar or _G[(sf:GetName() or "") .. "ScrollBar"]
      if bar then
        if range <= 0 then
          bar:Hide()
          if bar.EnableMouse then pcall(bar.EnableMouse, bar, false) end
        else
          bar:Show()
          if bar.EnableMouse then pcall(bar.EnableMouse, bar, true) end
        end
      end

      -- v4.3.72: never disable mouse wheel based on a transient 0 range.
      -- Scroll ranges can report 0 for a frame while content is being rebound;
      -- disabling the wheel there is what made item/side lists intermittently
      -- unscrollable until the window was reopened. Keep the wheel enabled and
      -- let the OnMouseWheel clamp to the current range.
      if sf.EnableMouseWheel then sf:EnableMouseWheel(true) end
      if range <= 0 then sf:SetVerticalScroll(0) end
    end
    apply(UI.groupScroll)
    apply(UI.gridScroll)
    apply(UI.wishlistScroll)
    apply(UI.historyScroll)
  end

  UI.RefreshAll()
end

function UI.Toggle()
  local function EnsureFrame()
    if UI.frame then return true end
    if UI.Init then
      local ok = pcall(UI.Init)
      if ok and UI.frame then return true end
    end
    return UI.frame ~= nil
  end

  local function DoToggle()
    if not EnsureFrame() then return end
    if UI.frame:IsShown() then
      UI.frame:Hide()
      return
    end
    if ns and ns.TriggerDeferredWarmup then
      pcall(ns.TriggerDeferredWarmup, "ui_toggle")
    end

    -- First open per session should always land on Overview. After that,
    -- respect the user's last-selected tab for subsequent opens.
    if not UI._clogSessionFirstOpenDone then
      CollectionLogDB = CollectionLogDB or {}
      CollectionLogDB.ui = CollectionLogDB.ui or {}
      CollectionLogDB.ui.activeCategory = "Overview"
      CollectionLogDB.ui.activeGroupId = nil
      CollectionLogDB.ui._forceDefaultGroup = true
      UI._clogSessionFirstOpenDone = true
    end

    UI.frame:Show()
    if UI.frame.Raise then UI.frame:Raise() end
    if UI.RefreshAll then pcall(UI.RefreshAll) end
  end

  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("ui_toggle", DoToggle)
  else
    DoToggle()
  end
end


-- Bootstrap the wishlist objective tracker without requiring the main
-- Collection Log window to be opened first. This silently initializes the
-- UI (hidden) when tracked wishlist entries exist, then restores the tracker.
do
  local wishlistTrackerInitPending = false
  local wishlistTrackerInitAttempts = 0

  local function CLOG_HasPersistedTrackedWishlistEntries()
    local store = rawget(_G, "CollectionLog_Tracked")
    if type(store) ~= "table" then return false end
    local entries = type(store.entries) == "table" and store.entries or nil
    if entries then
      for key, data in pairs(entries) do
        if type(key) == "string" and key ~= "" and type(data) == "table" then
          return true
        end
      end
    end
    local order = type(store.order) == "table" and store.order or nil
    if order then
      for _, key in ipairs(order) do
        if type(key) == "string" and key ~= "" then
          return true
        end
      end
    end
    return false
  end

  local function CLOG_BootstrapWishlistTrackerUI()
    if not CLOG_HasPersistedTrackedWishlistEntries() then
      wishlistTrackerInitPending = false
      return
    end

    local trackerReady = (type(CLOG_BootstrapCollectionTrackerOnLogin) == "function") or (type(CLOG_RefreshCollectionTracker) == "function")
    if not trackerReady then
      wishlistTrackerInitAttempts = wishlistTrackerInitAttempts + 1
      if wishlistTrackerInitAttempts <= 12 then
        C_Timer.After(0.5, CLOG_BootstrapWishlistTrackerUI)
      else
        wishlistTrackerInitPending = false
      end
      return
    end

    if type(CLOG_BootstrapCollectionTrackerOnLogin) == "function" then
      pcall(CLOG_BootstrapCollectionTrackerOnLogin)
    elseif type(CLOG_RefreshCollectionTracker) == "function" then
      pcall(CLOG_RefreshCollectionTracker)
    end

    wishlistTrackerInitPending = false
  end

  local trackerInitFrame = CreateFrame("Frame")
  trackerInitFrame:RegisterEvent("VARIABLES_LOADED")
  trackerInitFrame:RegisterEvent("PLAYER_LOGIN")
  trackerInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  trackerInitFrame:SetScript("OnEvent", function()
    if wishlistTrackerInitPending then return end
    if not CLOG_HasPersistedTrackedWishlistEntries() then return end
    wishlistTrackerInitPending = true
    wishlistTrackerInitAttempts = 0
    C_Timer.After(0.25, CLOG_BootstrapWishlistTrackerUI)
  end)
end

-- Clear Pet Journal filters on login/reload so they never "stick"
do
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_LOGIN")

  -- Register only well-known collection events (pcall avoids hard errors on clients missing an event).
  local function SafeReg(ev) pcall(f.RegisterEvent, f, ev) end
  SafeReg("NEW_MOUNT_ADDED")
  SafeReg("MOUNT_JOURNAL_USABILITY_CHANGED")
  SafeReg("MOUNT_JOURNAL_LIST_UPDATE")
  SafeReg("MOUNT_JOURNAL_COLLECTION_UPDATED")
  SafeReg("COMPANION_UPDATE")
  SafeReg("PET_JOURNAL_LIST_UPDATE")
  SafeReg("COMPANION_LEARNED")

  -- Item/transmog data streams in asynchronously. If we render a large loot table
  -- before item data is available, collected state can appear "all grey" until
  -- the user clicks again. We fix that by refreshing visible cells when item or
  -- transmog data arrives.
  SafeReg("GET_ITEM_INFO_RECEIVED")
  SafeReg("ITEM_DATA_LOAD_RESULT")
  SafeReg("TRANSMOG_COLLECTION_UPDATED")
  SafeReg("TOYS_UPDATED")
  SafeReg("PLAYER_ENTERING_WORLD")

  local pendingFull = false
  local pendingCollected = false
  local pendingMountUsability = false

  local function MarkCollectionDataDirty(reason)
    if UI then
      UI._clogPendingHiddenCollectionEvent = true
      UI._clogCollectedStateGen = (tonumber(UI._clogCollectedStateGen or 0) or 0) + 1
      if UI.ClearTooltipAnalysisCaches then pcall(UI.ClearTooltipAnalysisCaches, reason or "collection_dirty") end
    end
  end

  local function RefreshWishlistAndTrackerOnly(reason)
    MarkCollectionDataDirty(reason)
    if Wishlist and Wishlist.PruneCollectedEntries then pcall(Wishlist.PruneCollectedEntries) end
    if Wishlist and Wishlist.RefreshTrackedDisplayNames then pcall(Wishlist.RefreshTrackedDisplayNames) end
    if CLOG_RefreshCollectionTracker then pcall(CLOG_RefreshCollectionTracker) end
    local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
    if activeCat == "Wishlist" and UI and UI.frame and UI.frame.IsShown and UI.frame:IsShown() and UI.RefreshWishlist then
      pcall(UI.RefreshWishlist)
    end
  end

  local function DebouncedFullRefresh()
    if pendingFull then return end
    pendingFull = true
    C_Timer.After(0.15, function()
      pendingFull = false
      -- v4.3.71: collection/journal events must not rebuild the visible grid.
      -- Treat them as dirty markers; explicit Refresh does the expensive work.
      MarkCollectionDataDirty("full_event")
    end)
  end

  local function DebouncedCollectedRefresh()
    if pendingCollected then return end
    pendingCollected = true
    C_Timer.After(0.10, function()
      pendingCollected = false
      -- Item/transmog/journal data events can fire in large bursts while the UI is
      -- open. Never respond by walking all visible cells. Mark dirty only.
      MarkCollectionDataDirty("collected_event")
    end)
  end

  local function DebouncedRealCollectionRefresh()
    if pendingCollected then return end
    pendingCollected = true
    C_Timer.After(0.10, function()
      pendingCollected = false
      -- Real collection events get narrow Wishlist/tracker maintenance, but no
      -- grid rebuild and no broad resolver warmup.
      RefreshWishlistAndTrackerOnly("real_collection_event")
    end)
  end

  local function DebouncedMountUsabilityRefresh()
    if pendingMountUsability then return end
    pendingMountUsability = true
    C_Timer.After(0.50, function()
      pendingMountUsability = false
      MarkCollectionDataDirty("mount_usability")
    end)
  end

  f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
      if ns and ns.ProfilePrint then ns.ProfilePrint("UI PLAYER_LOGIN begin") end
      if ns.ClearAllPetJournalFilters then pcall(ns.ClearAllPetJournalFilters) end
      -- Reset per-session default-tab behavior. We always start the first open on Overview,
      -- then remember the user's last-selected tab for subsequent opens in the same session.
      if UI then UI._clogSessionFirstOpenDone = false end
      if ns and ns.ProfilePrint then ns.ProfilePrint("UI PLAYER_LOGIN end") end
      if UI and UI.ClearTooltipAnalysisCaches then pcall(UI.ClearTooltipAnalysisCaches, "login") end
      pcall(WishlistRestoreTrackedState)
      if CLOG_BootstrapCollectionTrackerOnLogin then
        pcall(CLOG_BootstrapCollectionTrackerOnLogin)
      end
      return
    elseif event == "PLAYER_ENTERING_WORLD" then
      if CLOG_BootstrapCollectionTrackerOnLogin then
        pcall(CLOG_BootstrapCollectionTrackerOnLogin)
      end
      return
    end
    if event == "MOUNT_JOURNAL_USABILITY_CHANGED" then
      DebouncedMountUsabilityRefresh()
    elseif event == "NEW_MOUNT_ADDED" or event == "NEW_PET_ADDED" or event == "NEW_TOY_ADDED" or event == "COMPANION_LEARNED" then
      DebouncedRealCollectionRefresh()
    elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT"
      or event == "TRANSMOG_COLLECTION_UPDATED"
      or event == "TOYS_UPDATED"
      or event == "COMPANION_UPDATE"
      or event == "MOUNT_JOURNAL_LIST_UPDATE"
      or event == "MOUNT_JOURNAL_COLLECTION_UPDATED"
      or event == "PET_JOURNAL_LIST_UPDATE" then
      -- Noisy async streams: mark dirty only. Do not touch visible cells.
      DebouncedCollectedRefresh()
    else
      DebouncedFullRefresh()
    end
  end)
end

-- ============================================================
-- OSRS-style "New item" pop-up (top-center)
-- ============================================================
do
  local popup, iconTex, titleFS, subFS, fadeGroup, glowGroup

  -- Glow texture used by the popup (kept as a named constant so it never drifts).
  local POPUP_GLOW_TEX = "Interface\\Buttons\\UI-ActionButton-Border"

  local function EnsurePopupSettings()
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.settings = CollectionLogDB.settings or {}
    if CollectionLogDB.settings.popupPosMode == nil then
      CollectionLogDB.settings.popupPosMode = "default"
    end
    if CollectionLogDB.settings.popupPoint == nil then CollectionLogDB.settings.popupPoint = "TOP" end
    if CollectionLogDB.settings.popupX == nil then CollectionLogDB.settings.popupX = 0 end
    if CollectionLogDB.settings.popupY == nil then CollectionLogDB.settings.popupY = -180 end
  end

  function ns.ApplyLootPopupPosition(allowDragOverride)
    EnsurePopupSettings()
    if ns and ns.RunOutOfCombat and ns.IsInCombat and ns.IsInCombat() and not ns._clogDeferPopupPos then
      ns._clogDeferPopupPos = true
      ns.RunOutOfCombat("popup_apply_pos", function()
        ns._clogDeferPopupPos = false
        ns.ApplyLootPopupPosition(allowDragOverride)
      end)
      return
    end
    if not popup then
      -- Allow callers to apply position before the popup exists.
      -- Combat-safety: avoid mutating UI during combat. We'll show the popup after combat ends.
    if ns and ns.IsInCombat and ns.IsInCombat() then
      if ns.RunOutOfCombat then
        local meta2
        if type(meta) == "table" then
          meta2 = {}
          for k,v in pairs(meta) do meta2[k] = v end
        else
          meta2 = {}
        end
        meta2._skipLatest = true
        ns.RunOutOfCombat("popup_show_deferred", function()
          ns.ShowNewCollectionPopup(itemName, iconPath, kind, meta2)
        end)
      end
      return
    end

    EnsurePopup()
      if not popup then return end
    end

    local s = CollectionLogDB.settings or {}
    local mode = s.popupPosMode or "default"

    popup:ClearAllPoints()

    if mode == "default" then
      popup:SetPoint("TOP", UIParent, "TOP", 0, -180)
    elseif mode == "topleft" then
      popup:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -60)
    elseif mode == "topright" then
      popup:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -40, -60)
    elseif mode == "bottomleft" then
      popup:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 40, 120)
    elseif mode == "bottomright" then
      popup:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 120)
    elseif mode == "center" then
      popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    elseif mode == "custom" then
      popup:SetPoint(s.popupPoint or "TOP", UIParent, s.popupPoint or "TOP", s.popupX or 0, s.popupY or -180)
    else
      popup:SetPoint("TOP", UIParent, "TOP", 0, -180)
    end

    -- Keep it on screen even if saved coords went off-screen (can happen with UI scale changes).
    do
      local l, b, w, h = popup:GetRect()
      local pw, ph = UIParent:GetWidth(), UIParent:GetHeight()
      if l and b and w and h and pw and ph then
        local off = (l < -10) or (b < -10) or ((l + w) > (pw + 10)) or ((b + h) > (ph + 10))
        if off then
          popup:ClearAllPoints()
          popup:SetPoint("TOP", UIParent, "TOP", 0, -180)
          s.popupPosMode = "default"
          s.popupPoint, s.popupX, s.popupY = "TOP", 0, -180
          CollectionLogDB.settings = s
        end
      end
    end

    local allowDrag = (mode == "custom") or (allowDragOverride == true)

    popup:SetMovable(allowDrag)
    popup:EnableMouse(allowDrag)
    popup:RegisterForDrag("LeftButton")
    popup:SetClampedToScreen(true)

    popup:SetScript("OnDragStart", function(self)
      if not allowDrag then return end
      self:StartMoving()
    end)
    popup:SetScript("OnDragStop", function(self)
      if not allowDrag then
        self:StopMovingOrSizing()
        return
      end
      self:StopMovingOrSizing()
      EnsurePopupSettings()
      local point, _, _, x, y = self:GetPoint(1)
      CollectionLogDB.settings.popupPoint = point or "TOP"
      CollectionLogDB.settings.popupX = x or 0
      CollectionLogDB.settings.popupY = y or 0
      CollectionLogDB.settings.popupPosMode = "custom"
    end)
  end

  local function EnsurePopup()
    if popup then return end
    popup = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    popup:SetSize(360, 86)

    -- Position is user-configurable via settings dropdown (defaults to top).
    -- Applied via ns.ApplyLootPopupPosition().

    popup:SetFrameStrata("DIALOG")
    popup:SetFrameLevel(200)

    if ns and ns.ApplyLootPopupPosition then
      ns.ApplyLootPopupPosition(false)
    end

    popup:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    popup:SetBackdropColor(0.12, 0.10, 0.08, 0.96)

    -- Subtle OSRS-style halo glow (animated).
    -- Important: render as 3 segments (L/C/R) so it spans the full popup width without
    -- the texture's radial falloff "dying" before the edges.
    popup.glowFrame = CreateFrame("Frame", nil, popup)
    -- Keep glow above the backdrop, but below the popup text.
    popup.glowFrame:SetFrameLevel(popup:GetFrameLevel())
    -- ~20% thinner than the earlier version by reducing the expansion padding slightly.
    popup.glowFrame:ClearAllPoints()
    popup.glowFrame:SetPoint("TOPLEFT", popup, "TOPLEFT", -8, 8)
    popup.glowFrame:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", 8, -8)
    popup.glowFrame:SetAlpha(0)

    local function MakeGlowTex()
      local t = popup.glowFrame:CreateTexture(nil, "BORDER")
      t:SetTexture(POPUP_GLOW_TEX)
      t:SetBlendMode("ADD")
      t:SetVertexColor(1.0, 0.82, 0.25)
      return t
    end

    popup.glowL = MakeGlowTex()
    popup.glowR = MakeGlowTex()
    popup.glowC = MakeGlowTex()

    -- Left / Right caps keep the strong edge glow; center is a thin cropped slice that stretches.
    local uMin, uMax = 0.18, 0.82
    local vMin, vMax = 0.18, 0.82
    local uMid = (uMin + uMax) * 0.5
    local uPad = 0.015 -- tiny overlap to avoid visible seams

    popup.glowL:SetTexCoord(uMin, uMid + uPad, vMin, vMax)
    popup.glowC:SetTexCoord(uMid - uPad, uMid + uPad, vMin, vMax)
    popup.glowR:SetTexCoord(uMid - uPad, uMax, vMin, vMax)

    local capW = 68 -- pixels; stable across sizes and keeps the halo "OSRS-ish"

    popup.glowL:ClearAllPoints()
    popup.glowL:SetPoint("TOP", popup.glowFrame, "TOP", 0, 0)
    popup.glowL:SetPoint("BOTTOM", popup.glowFrame, "BOTTOM", 0, 0)
    popup.glowL:SetPoint("LEFT", popup.glowFrame, "LEFT", 0, 0)
    popup.glowL:SetWidth(capW)

    popup.glowR:ClearAllPoints()
    popup.glowR:SetPoint("TOP", popup.glowFrame, "TOP", 0, 0)
    popup.glowR:SetPoint("BOTTOM", popup.glowFrame, "BOTTOM", 0, 0)
    popup.glowR:SetPoint("RIGHT", popup.glowFrame, "RIGHT", 0, 0)
    popup.glowR:SetWidth(capW)

    popup.glowC:ClearAllPoints()
    popup.glowC:SetPoint("TOP", popup.glowFrame, "TOP", 0, 0)
    popup.glowC:SetPoint("BOTTOM", popup.glowFrame, "BOTTOM", 0, 0)
    popup.glowC:SetPoint("LEFT", popup.glowL, "RIGHT", 0, 0)
    popup.glowC:SetPoint("RIGHT", popup.glowR, "LEFT", 0, 0)

    -- Icon intentionally hidden (OSRS-style text-only popup)
    iconTex = popup:CreateTexture(nil, "ARTWORK")
    iconTex:Hide()

    titleFS = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleFS:SetPoint("TOP", popup, "TOP", 0, -10)
    titleFS:SetText("Collection Log")
    do
      local f, s, fl = titleFS:GetFont()
      if f and s then titleFS:SetFont(f, s + 4, fl) end
    end

    subFS = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subFS:SetPoint("TOP", titleFS, "BOTTOM", 0, -6)
    subFS:SetText("New item:")
    subFS:SetJustifyH("CENTER")

    popup.itemFS = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    popup.itemFS:SetPoint("TOP", subFS, "BOTTOM", 0, -4)
    popup.itemFS:SetPoint("LEFT", popup, "LEFT", 14, 0)
    popup.itemFS:SetPoint("RIGHT", popup, "RIGHT", -14, 0)
    popup.itemFS:SetJustifyH("CENTER")

    popup:Hide()
  end

  function ns.PushLatestCollection(entry)
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.latestCollections = CollectionLogDB.latestCollections or {}
    local t = CollectionLogDB.latestCollections

    -- Dedupe: Some collectibles (notably Toys) can fire two signals in quick
    -- succession (e.g., loot -> learned/added). Prevent double entries.
    local function sameLatest(a, b)
      if not a or not b then return false end
      -- Prefer stable identifiers when available
      if a.itemID and b.itemID and a.itemID == b.itemID then return true end
      if a.spellID and b.spellID and a.spellID == b.spellID then return true end
      if a.mountID and b.mountID and a.mountID == b.mountID then return true end
      if a.speciesID and b.speciesID and a.speciesID == b.speciesID then return true end
      if a.itemLink and b.itemLink and a.itemLink == b.itemLink then return true end
      -- Fallback: name + icon + type
      if a.name and b.name and a.name == b.name and a.icon == b.icon and a.type == b.type then
        return true
      end
      return false
    end

    local now = (type(entry) == "table" and entry.ts) or (time and time()) or 0
    local window = 5 -- seconds
    -- One-shot dedupe: Toys/Mounts/Pets should never appear twice in Latest Collections.
    local etype = (type(entry) == "table" and entry.type) or nil
    if etype == "toy" or etype == "mount" or etype == "pet" then
      for i = 1, #t do
        if sameLatest(t[i], entry) then
          return
        end
      end
    end

    for i = 1, math.min(#t, 3) do
      local prev = t[i]
      if prev and sameLatest(prev, entry) then
        local pts = prev.ts or 0
        if math.abs((now or 0) - (pts or 0)) <= window then
          -- Skip near-duplicate
          return
        end
      end
    end

    table.insert(t, 1, entry)
    local maxKeep = (ns and ns.LATEST_COLLECTIONS_MAX) or 10
    while #t > maxKeep do table.remove(t) end
    if UI and UI.RefreshOverview then
      if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_overview", function() UI.RefreshOverview() end) else UI.RefreshOverview() end
    end
  end

  function ns.PushCollectionHistory(entry)
    if type(entry) ~= "table" then return end
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.collectionHistory = CollectionLogDB.collectionHistory or {}
    local t = CollectionLogDB.collectionHistory

    local function sameHistory(a, b)
      if not a or not b then return false end
      if a.itemID and b.itemID and a.itemID == b.itemID then
        local ats = tonumber(a.ts or 0) or 0
        local bts = tonumber(b.ts or 0) or 0
        if math.abs(ats - bts) <= 5 then return true end
      end
      if a.itemLink and b.itemLink and a.itemLink == b.itemLink then
        local ats = tonumber(a.ts or 0) or 0
        local bts = tonumber(b.ts or 0) or 0
        if math.abs(ats - bts) <= 5 then return true end
      end
      if a.mountID and b.mountID and a.mountID == b.mountID then
        local ats = tonumber(a.ts or 0) or 0
        local bts = tonumber(b.ts or 0) or 0
        if math.abs(ats - bts) <= 5 then return true end
      end
      if a.speciesID and b.speciesID and a.speciesID == b.speciesID then
        local ats = tonumber(a.ts or 0) or 0
        local bts = tonumber(b.ts or 0) or 0
        if math.abs(ats - bts) <= 5 then return true end
      end
      return false
    end

    for i = 1, math.min(#t, 8) do
      if sameHistory(t[i], entry) then return end
    end

    table.insert(t, 1, entry)
    while #t > 500 do table.remove(t) end
    if UI and UI.history and UI.history:IsShown() and UI.RefreshHistory then
      UI.RefreshHistory()
    end
  end

  local function CLOG_ShouldSuppressSyntheticCollections(meta)
    if type(meta) == "table" and meta.preview == true then return false end
    if ns and type(ns.ShouldSuppressSyntheticCollectionSideEffects) == "function" then
      local ok, suppress = pcall(ns.ShouldSuppressSyntheticCollectionSideEffects, meta)
      if ok and suppress then return true end
    end
    return false
  end

  function ns.ShowNewCollectionPopup(itemName, iconPath, kind, meta)
    -- Synthetic refresh/bootstrap passes should never seed Latest Collections or popups.
    if CLOG_ShouldSuppressSyntheticCollections(meta) then
      return
    end

    -- Always record Latest Collections; popup display can be disabled via settings.
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.settings = CollectionLogDB.settings or {}

    local entry = {
      name = itemName,
      icon = iconPath,
      kind = kind,
      ts = time and time() or 0,
    }

    -- Optional structured metadata (Pass 1 foundation for hoverable tooltips)
    if type(meta) == "table" then
      if meta.type then entry.type = meta.type end
      if meta.itemID then entry.itemID = meta.itemID end
      if meta.itemLink then entry.itemLink = meta.itemLink end
      if meta.mountID then entry.mountID = meta.mountID end
      if meta.spellID then entry.spellID = meta.spellID end
      if meta.speciesID then entry.speciesID = meta.speciesID end
    end

    -- Back-compat: infer a basic entry.type from kind when not provided.
    if not entry.type and kind then
      local k = string.lower(tostring(kind))
      if k == "toy" then entry.type = "toy"
      elseif k == "mount" then entry.type = "mount"
      elseif k == "pet" then entry.type = "pet"
      elseif k == "item" then entry.type = "item"
      end
    end

    if type(meta) == "table" then
      if type(meta.sourceContext) == "table" then
        local ctx = meta.sourceContext
        if ctx.instanceName then entry.instanceName = entry.instanceName or ctx.instanceName end
        if ctx.instanceName then entry.sourceName = entry.sourceName or ctx.instanceName end
        if ctx.difficultyName then entry.sourceDifficulty = entry.sourceDifficulty or ctx.difficultyName end
        if ctx.sourceLabel then entry.sourceLabel = entry.sourceLabel or ctx.sourceLabel end
        if ctx.mapID then entry.mapID = entry.mapID or ctx.mapID end
        if ctx.ejInstanceID then entry.ejInstanceID = entry.ejInstanceID or ctx.ejInstanceID end
        if ctx.difficultyID then entry.difficultyID = entry.difficultyID or ctx.difficultyID end
      end
      if meta.sourceName then entry.sourceName = meta.sourceName end
      if meta.sourceDifficulty then entry.sourceDifficulty = meta.sourceDifficulty end
      if meta.sourceLabel then entry.sourceLabel = meta.sourceLabel end
      if meta.mapID then entry.mapID = meta.mapID end
      if meta.ejInstanceID then entry.ejInstanceID = meta.ejInstanceID end
      if meta.difficultyID then entry.difficultyID = meta.difficultyID end
      if meta.characterName then entry.characterName = meta.characterName end
      if meta.characterFullName then entry.characterFullName = meta.characterFullName end
    end

    do
      local name, realm = UnitName and UnitName("player") or nil, GetRealmName and GetRealmName() or nil
      if not entry.characterName and name and name ~= "" then entry.characterName = name end
      if not entry.characterFullName and name and name ~= "" then
        if realm and realm ~= "" then entry.characterFullName = tostring(name) .. "-" .. tostring(realm) else entry.characterFullName = name end
      end
      if (not entry.sourceName or entry.sourceName == "") and type(CLOG_ResolveHistoryInstanceName) == "function" then
        entry.sourceName = CLOG_ResolveHistoryInstanceName(entry)
      end
      if (not entry.sourceLabel or entry.sourceLabel == "" or entry.sourceLabel == "Unknown") and entry.sourceName and entry.sourceName ~= "" then
        if entry.sourceDifficulty and entry.sourceDifficulty ~= "" then
          entry.sourceLabel = tostring(entry.sourceName) .. " - " .. tostring(entry.sourceDifficulty)
        else
          entry.sourceLabel = tostring(entry.sourceName)
        end
      end
    end

    if not (type(meta) == "table" and meta._skipLatest == true) then
      ns.PushLatestCollection(entry)
      if ns.PushCollectionHistory then
        ns.PushCollectionHistory(entry)
      end
    end

    if CollectionLogDB.settings.showLootPopup == false then
      return
    end


    -- Optional: only show pop-up when the collectible is truly new (default ON).
    -- Important: only gate when we actually *know* whether it's new.
    -- If meta.isNew is nil (unknown), allow the popup.
    if CollectionLogDB.settings.onlyNewLootPopup ~= false then
      local isPreview = (type(meta) == "table" and meta.preview == true) and true or false
      if type(meta) == "table" and meta.isNew ~= nil then
        local isNew = (meta.isNew == true) and true or false
        if (not isNew) and (not isPreview) then
          return
        end
      elseif isPreview then
        -- preview always allowed
      else
        -- meta missing or doesn't specify isNew -> allow
      end
    end


    -- If several collections are learned in rapid succession (common when learning multiple
    -- housing decor/furniture items from bags), do not restart the glow/fade animation every
    -- time. Latest Collections and History are still recorded above; the visible popup simply
    -- updates its text while the current toast finishes. This avoids stacked/restarted popup
    -- animations causing FPS drops.
    do
      local isPreview = (type(meta) == "table" and meta.preview == true) and true or false
      if (not isPreview) and popup and popup:IsShown() then
        if popup.itemFS then popup.itemFS:SetText(itemName or "New collection") end
        return
      end
    end

    EnsurePopup()
    if not popup then return end

    if ns and ns.ApplyLootPopupPosition then
      local allowDrag = (type(meta) == "table" and meta.preview == true) and true or false
      ns.ApplyLootPopupPosition(allowDrag)
    end

    -- Text-only popup (OSRS-style) â€” keep icon hidden.
    if iconTex then iconTex:Hide() end

    popup.itemFS:SetText(itemName or "New collection")

    popup:SetAlpha(1)
    popup:Show()

    -- Safety: if the popup ended up off-screen or not visible (e.g., bad saved coords), snap back to default.
    do
      local l,b,w,h = popup:GetRect()
      local pw,ph = UIParent:GetWidth(), UIParent:GetHeight()
      if not l or not b or not w or not h or not pw or not ph or l < -10 or b < -10 or (l+w) > (pw+10) or (b+h) > (ph+10) then
        popup:ClearAllPoints()
        popup:SetPoint("TOP", UIParent, "TOP", 0, -180)
        CollectionLogDB.settings.popupPosMode = "default"
        CollectionLogDB.settings.popupPoint = "TOP"
        CollectionLogDB.settings.popupX = 0
        CollectionLogDB.settings.popupY = -180
      end
    end


    -- Optional sound (respects popup + new-only settings). Throttled to avoid spam.
    if CollectionLogDB.settings.muteLootPopupSound ~= true then
      local isPreview = (type(meta) == "table" and meta.preview == true) and true or false
      if not isPreview then
        local now = (GetTime and GetTime()) or 0
        ns._lastPopupSoundAt = ns._lastPopupSoundAt or 0
        if (now - ns._lastPopupSoundAt) > 0.35 then
          ns._lastPopupSoundAt = now
          local soundKey = (CollectionLogDB.settings and CollectionLogDB.settings.lootPopupSoundKey) or "DEFAULT"
          local path
          if soundKey == "CL_COMPLETED" then
            path = "Interface\\AddOns\\CollectionLog\\Media\\collection-log-completed.ogg"
          else
            path = "Interface\\AddOns\\CollectionLog\\Media\\ui_70_artifact_forge_trait_unlock.ogg"
          end
          local ok = PlaySoundFile(path, (CollectionLogDB.settings.lootPopupSoundChannel or "SFX")) and true or false
          if (not ok) and type(PlaySound) == "function" and type(SOUNDKIT) == "table" then
                      local keys = {
                        "UI_70_ARTIFACT_FORGE_TRAIT_UNLOCK",
                        "UI_EPICLOOT_TOAST",
                        "UI_LOOT_TOAST_LEGENDARY",
                        "UI_LOOT_TOAST_LESSER_ITEM_WON",
                        "UI_LOOT_TOAST_LESSER_ITEM_LOOTED",
                        "UI_PET_BATTLE_START",
                        "IG_MAINMENU_OPTION_CHECKBOX_ON",
                        "IG_MAINMENU_OPTION_CHECKBOX_OFF",
                        "IG_MAINMENU_OPTION",
                      }
                      for _, key in ipairs(keys) do
                        local kit = SOUNDKIT[key]
                        if kit then
                          PlaySound(kit, (CollectionLogDB.settings.lootPopupSoundChannel or "SFX"))
                          break
                        end
                      end
                    end
        end
      end
    end


    if fadeGroup then fadeGroup:Stop() end
    if glowGroup then glowGroup:Stop() end

    -- Glow pulse on edges (3 pulses) â€” slowed down ~50% vs prior version.
    glowGroup = glowGroup or popup:CreateAnimationGroup()
    glowGroup:Stop()
    glowGroup:SetToFinalAlpha(true)

    glowGroup.p1 = glowGroup.p1 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p1:SetTarget(popup.glowFrame)
    glowGroup.p1:SetFromAlpha(0.0)
    glowGroup.p1:SetToAlpha(1.0)
    glowGroup.p1:SetDuration(0.44)
    glowGroup.p1:SetOrder(1)

    glowGroup.p2 = glowGroup.p2 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p2:SetTarget(popup.glowFrame)
    glowGroup.p2:SetFromAlpha(1.0)
    glowGroup.p2:SetToAlpha(0.15)
    glowGroup.p2:SetDuration(0.64)
    glowGroup.p2:SetOrder(2)

    glowGroup.p3 = glowGroup.p3 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p3:SetTarget(popup.glowFrame)
    glowGroup.p3:SetFromAlpha(0.15)
    glowGroup.p3:SetToAlpha(1.0)
    glowGroup.p3:SetDuration(0.44)
    glowGroup.p3:SetOrder(3)

    glowGroup.p4 = glowGroup.p4 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p4:SetTarget(popup.glowFrame)
    -- Dip after pulse #2
    glowGroup.p4:SetFromAlpha(1.0)
    glowGroup.p4:SetToAlpha(0.15)
    glowGroup.p4:SetDuration(0.64)
    glowGroup.p4:SetOrder(4)

    -- Pulse #3
    glowGroup.p5 = glowGroup.p5 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p5:SetTarget(popup.glowFrame)
    glowGroup.p5:SetFromAlpha(0.15)
    glowGroup.p5:SetToAlpha(1.0)
    glowGroup.p5:SetDuration(0.44)
    glowGroup.p5:SetOrder(5)

    -- Dip after pulse #3
    glowGroup.p6 = glowGroup.p6 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p6:SetTarget(popup.glowFrame)
    glowGroup.p6:SetFromAlpha(1.0)
    glowGroup.p6:SetToAlpha(0.15)
    glowGroup.p6:SetDuration(0.64)
    glowGroup.p6:SetOrder(6)

    -- Pulse #4
    glowGroup.p7 = glowGroup.p7 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p7:SetTarget(popup.glowFrame)
    glowGroup.p7:SetFromAlpha(0.15)
    glowGroup.p7:SetToAlpha(1.0)
    glowGroup.p7:SetDuration(0.44)
    glowGroup.p7:SetOrder(7)

    -- Fade out
    glowGroup.p8 = glowGroup.p8 or glowGroup:CreateAnimation("Alpha")
    glowGroup.p8:SetTarget(popup.glowFrame)
    glowGroup.p8:SetFromAlpha(1.0)
    glowGroup.p8:SetToAlpha(0.0)
    glowGroup.p8:SetDuration(0.76)
    glowGroup.p8:SetOrder(8)

    glowGroup:Play()
    fadeGroup = fadeGroup or popup:CreateAnimationGroup()
    fadeGroup:Stop()
    fadeGroup:SetToFinalAlpha(true)

    fadeGroup.anim1 = fadeGroup.anim1 or fadeGroup:CreateAnimation("Alpha")
    fadeGroup.anim1:SetFromAlpha(1)
    fadeGroup.anim1:SetToAlpha(1)
    fadeGroup.anim1:SetDuration(4.0)
    fadeGroup.anim1:SetOrder(1)

    fadeGroup.anim2 = fadeGroup.anim2 or fadeGroup:CreateAnimation("Alpha")
    fadeGroup.anim2:SetFromAlpha(1)
    fadeGroup.anim2:SetToAlpha(0)
    fadeGroup.anim2:SetDuration(0.6)
    fadeGroup.anim2:SetOrder(2)

    fadeGroup:SetScript("OnFinished", function()
      if popup then popup:Hide() end
    end)

    fadeGroup:Play()
  end

-- Popup is created lazily on first real/test notification.  Avoiding eager
-- ADDON_LOADED construction removes a small but unnecessary login/reload cost.

end


-- Public wrapper used by popup tests and live collection notifications.
function CollectionLog_ShowCollectionPopup(data)
  if not data then data = {} end
  local name = data.name or data.itemName or "New collection"
  local icon = data.icon or data.iconPath
  local kind = data.kind or data.source
  if ns and ns.ShowNewCollectionPopup then
    -- Pass the full data table as meta so flags like isNew/preview work for gating + sound tests
    ns.ShowNewCollectionPopup(name, icon, kind, data)
  else
    print("|cffff5555CollectionLog: popup renderer not available.|r")
  end
end

SLASH_CLOGUIRESET1 = "/cloguireset"
SlashCmdList.CLOGUIRESET = function()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.ui = CollectionLogDB.ui or {}
  EnsureUIState()

  -- Reset the physical window dimensions/anchor without changing the user's UI scale slider.
  CollectionLogDB.ui.w = 980
  CollectionLogDB.ui.h = 640
  CollectionLogDB.ui.point = "CENTER"
  CollectionLogDB.ui.x = 0
  CollectionLogDB.ui.y = 0

  if UI and UI.frame then
    local f = UI.frame
    if f.StopMovingOrSizing then f:StopMovingOrSizing() end
    if f.ClearAllPoints then f:ClearAllPoints() end
    if f.SetSize then f:SetSize(CollectionLogDB.ui.w, CollectionLogDB.ui.h) end
    if f.SetPoint then f:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
    if CLOG_ApplyWindowResizeBounds then CLOG_ApplyWindowResizeBounds(f) end
    if UI.RefreshAll then UI.RefreshAll() elseif UI.RefreshGrid then UI.RefreshGrid() end
  end

  print("Collection Log: UI window reset to default size and centered position.")
end
