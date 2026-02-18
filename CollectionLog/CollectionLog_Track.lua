-- CollectionLog_Track.lua
local ADDON, ns = ...

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
  ns._tracked.pets = {}
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

  -- Toys are identity itemID but we keep a dedicated flag for clarity.
  -- If the Toys importer is loaded, toys are already included in items.
  if ns._tracked.items then
    for itemID in pairs(ns._tracked.items) do
      if C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(itemID) then
        ns._tracked.toys[itemID] = true
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
  if C_PetJournal and C_PetJournal.GetPetInfoByItemID then
    local ok, speciesID = pcall(C_PetJournal.GetPetInfoByItemID, itemID)
    if ok and tonumber(speciesID) and tonumber(speciesID) > 0 then
      return tonumber(speciesID)
    end
  end
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

  -- If UI is open, refresh grid (cheap enough for MVP)
  if ns.UI and ns.UI.frame and ns.UI.frame:IsShown() then
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
          CollectionLogDB._seenNewPopups[key] = true

          local itemName2 = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or (GetItemInfo and GetItemInfo(itemID)) or "New appearance"
          local icon2 = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))
          if ns and ns.ShowNewCollectionPopup then
            ns.ShowNewCollectionPopup(itemName2, icon2, "Transmog", { type = "appearance", itemID = itemID, itemLink = link, isNew = true, source = "appearance_flip" })
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

-- =======================================
-- Mount + Pet journal events
-- =======================================
local jf = CreateFrame("Frame")
jf:RegisterEvent("NEW_MOUNT_ADDED")
jf:RegisterEvent("NEW_PET_ADDED")
jf:RegisterEvent("NEW_TOY_ADDED")

local function SafeMountPopup(mountID)
  if not mountID or mountID <= 0 then return end
  if not IsTrackedMount(mountID) then return end

  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
  local key = "mount:" .. tostring(mountID)
  if CollectionLogDB._seenNewPopups[key] then return end
  CollectionLogDB._seenNewPopups[key] = true

  if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return end
  local ok, name, spellID, icon, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
  if not ok then return end
  if not isCollected then return end

  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name or "New mount", icon, "Mount", { type = "mount", mountID = mountID, spellID = spellID, isNew = true })
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
  if CollectionLogDB._seenNewPopups[key] then return end
  CollectionLogDB._seenNewPopups[key] = true

  local ok2, sname, _, _, _, _, _, _, icon = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
  if ok2 and sname and sname ~= "" then name = sname end

  if ns and ns.ShowNewCollectionPopup then
    ns.ShowNewCollectionPopup(name or "New pet", icon, "Pet", { type = "pet", speciesID = speciesID, isNew = true })
  end
end

jf:SetScript("OnEvent", function(_, event, arg1)
  if event == "NEW_MOUNT_ADDED" then
    SafeMountPopup(tonumber(arg1))
  elseif event == "NEW_PET_ADDED" then
    SafePetPopup(arg1)
  elseif event == "NEW_TOY_ADDED" then
    local itemID = tonumber(arg1)
    if itemID and itemID > 0 and PlayerHasToy and PlayerHasToy(itemID) and IsTrackedToy(itemID) then
      CollectionLogDB = CollectionLogDB or {}
      CollectionLogDB._seenNewPopups = CollectionLogDB._seenNewPopups or {}
      local key = "toy:" .. tostring(itemID)
      if not CollectionLogDB._seenNewPopups[key] then
        CollectionLogDB._seenNewPopups[key] = true
        local name = (C_ToyBox and C_ToyBox.GetToyInfo and C_ToyBox.GetToyInfo(itemID)) or (GetItemInfo and GetItemInfo(itemID)) or "New toy"
        local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)) or (select(10, GetItemInfo(itemID)))
        if ns and ns.ShowNewCollectionPopup then
          ns.ShowNewCollectionPopup(name, icon, "Toy", { type = "toy", itemID = itemID, isNew = true })
        end
      end
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

local function GetEncounterIDsForInstance(instanceID)
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
    local ok, _, _, encID = pcall(EJ_GetEncounterInfoByIndex, i)
    if not ok or not encID then break end
    list[#list + 1] = tonumber(encID)
    i = i + 1
  end

  ns._encounterCache[instanceID] = list
  return list
end

local function GetFinalEncounterIDForInstance(instanceID)
  if not instanceID then return nil end

  -- In-memory cache (fast path)
  ns._finalEncounterCache = ns._finalEncounterCache or {}
  if ns._finalEncounterCache[instanceID] then
    return ns._finalEncounterCache[instanceID]
  end

  -- Persistent cache (SavedVariables) so we don't depend on EJ every session.
  CollectionLogDB.global = CollectionLogDB.global or {}
  CollectionLogDB.global.finalEncounters = CollectionLogDB.global.finalEncounters or {}
  local persisted = CollectionLogDB.global.finalEncounters[instanceID]
  if persisted then
    ns._finalEncounterCache[instanceID] = tonumber(persisted)
    return ns._finalEncounterCache[instanceID]
  end

  local list = GetEncounterIDsForInstance(instanceID)
  if type(list) ~= "table" or #list == 0 then
    return nil
  end

  local finalID = tonumber(list[#list])
  if finalID then
    ns._finalEncounterCache[instanceID] = finalID
    CollectionLogDB.global.finalEncounters[instanceID] = finalID
  end
  return finalID
end




-- Resolve Encounter Journal instanceID for a given instance mapID (from GetInstanceInfo()).
local function ResolveEJInstanceIDFromMapID(mapID)
  mapID = tonumber(mapID)
  if not mapID then return nil end
  if EnsureEJLoaded() and EJ_GetInstanceForMap then
    local ok, ejID = pcall(EJ_GetInstanceForMap, mapID)
    if ok and ejID then return tonumber(ejID) end
  end
  return nil
end

-- Returns true if we have a datapack group for this instance+difficulty (prevents counting unknown/unsupported combos).
local function HasGroupForInstanceDifficulty(instanceID, difficultyID)
  if not ns or not ns.Data or type(ns.Data.groups) ~= "table" then return false end
  local gid = "ej:" .. tostring(instanceID) .. ":" .. tostring(difficultyID)
  return ns.Data.groups[gid] ~= nil
end

-- Optional datapack override: allow groups to specify finalEncounterID (future-proofing).
local function GetFinalEncounterIDFromDataPack(instanceID, difficultyID)
  if not ns or not ns.Data or type(ns.Data.groups) ~= "table" then return nil end
  local gid = "ej:" .. tostring(instanceID) .. ":" .. tostring(difficultyID)
  local g = ns.Data.groups[gid]
  if type(g) == "table" then
    local fe = g.finalEncounterID or g.finalBossEncounterID
    if fe then return tonumber(fe) end
  end
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

function ns.GetInstanceCompletionCount(instanceID, difficultyID)
  ns.EnsureCharacterRecord()
  local guid = ns.GetPlayerGUID()
  if not guid then return 0 end
  local c = CollectionLogDB.characters and CollectionLogDB.characters[guid]
  if not c then return 0 end
  c.completions = c.completions or {}
  c.completions[instanceID] = c.completions[instanceID] or {}
  return tonumber(c.completions[instanceID][difficultyID] or 0) or 0
end

local function IncrementInstanceCompletion(instanceID, difficultyID)
  ns.EnsureCharacterRecord()
  local guid = ns.GetPlayerGUID()
  if not guid then return end
  local c = CollectionLogDB.characters[guid]
  c.completions = c.completions or {}
  c.completions[instanceID] = c.completions[instanceID] or {}
  c.completions[instanceID][difficultyID] = (tonumber(c.completions[instanceID][difficultyID] or 0) or 0) + 1
end

-- Runtime-only tracking for the current run (cleared when you leave / enter a new instance).
ns._activeRun = ns._activeRun or { key = nil, killed = {}, completed = false }

local function ResetActiveRun()
  ns._activeRun.key = nil
  ns._activeRun.killed = {}
  ns._activeRun.completed = false
end

local function UpdateRunContext()
  local inInstance = IsInInstance()
  if not inInstance then
    ResetActiveRun()
    return
  end

  local name, instanceType, difficultyID, _, _, _, _, instanceID = GetInstanceInfo()
  instanceID = tonumber(instanceID)
  difficultyID = tonumber(difficultyID)

  if not instanceID or not difficultyID then
    ResetActiveRun()
    return
  end

  local key = GetActiveRunKey(instanceID, difficultyID)
  if ns._activeRun.key ~= key then
    ns._activeRun.key = key
    ns._activeRun.killed = {}
    ns._activeRun.completed = false
  end
end

local function MarkEncounterKilled(instanceID, difficultyID, encounterID)
  UpdateRunContext()
  if not ns._activeRun.key then return end

  local key = GetActiveRunKey(instanceID, difficultyID)
  if ns._activeRun.key ~= key then
    -- Context changed; ensure run context matches
    ns._activeRun.key = key
    ns._activeRun.killed = {}
    ns._activeRun.completed = false
  end

  ns._activeRun.killed[encounterID] = true

  -- Check completion against EJ's encounter list.
  local list = GetEncounterIDsForInstance(instanceID)
  if not list or #list == 0 then return end
  if ns._activeRun.completed then return end

  for _, eid in ipairs(list) do
    if not ns._activeRun.killed[eid] then
      return -- not complete yet
    end
  end

  -- All encounters killed in this run => completion!
  ns._activeRun.completed = true
  IncrementInstanceCompletion(instanceID, difficultyID)

  -- If UI open, refresh header counts immediately.
  if ns.UI and ns.UI.RefreshGrid then
    pcall(ns.UI.RefreshGrid)
  end
end

-- Event frame for encounter completion tracking
local kc = CreateFrame("Frame")
kc:RegisterEvent("PLAYER_ENTERING_WORLD")
kc:RegisterEvent("ENCOUNTER_END")
kc:RegisterEvent("CHALLENGE_MODE_RESET")
kc:RegisterEvent("CHALLENGE_MODE_COMPLETED")
kc:RegisterEvent("CHALLENGE_MODE_START")

local function _CL_HandleKCEvent(event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    UpdateRunContext()
    local _, instanceType = IsInInstance()
    -- Disable chat-based loot parsing in PvP instances (BG/Arena) where chat payloads may be "secret" strings.
    if instanceType == "pvp" or instanceType == "arena" then
      SetChatTrackingEnabled(false)
    else
      SetChatTrackingEnabled(not IsChallengeModeActiveSafe())
    end
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

    local _, _, instDifficultyID, _, _, _, _, instanceMapID = GetInstanceInfo()
    instDifficultyID = tonumber(instDifficultyID)
    local did = instDifficultyID or tonumber(difficultyID)
    local mapID = tonumber(instanceMapID)
    if not did or not mapID or not encounterID then return end

    local _, instanceType = IsInInstance()
    -- Only count clears inside PvE instances.
    if instanceType ~= "party" and instanceType ~= "raid" then return end

    -- Convert mapID -> Encounter Journal instanceID (canonical key for our datapacks/UI).
    local ejInstanceID = ResolveEJInstanceIDFromMapID(mapID)
    local instanceID = ejInstanceID or mapID -- fallback (should be rare)

    -- Prefer counting only for shipped pack groups, but fall back to EJ-based counting when possible.
    -- This prevents "not counting" reports when a pack is missing, while still avoiding weird/unsupported modes.
    local hasPackGroup = HasGroupForInstanceDifficulty(instanceID, did)
    if not hasPackGroup and ns._debug and ns._debug.clears then
      Print(("Clears: NOTICE (no pack group; will try EJ fallback) mapID=%s ejID=%s did=%s encID=%s %s"):format(tostring(mapID), tostring(ejInstanceID), tostring(did), tostring(encounterID), tostring(encounterName or "")))
    end

    -- Don’t count in Challenge Mode / Mythic+.
    if IsChallengeModeActiveSafe() then
      if ns._debug and ns._debug.clears then
        Print(("Clears: SKIP (challenge mode) inst=%s did=%s encID=%s %s"):format(tostring(instanceID), tostring(did), tostring(encounterID), tostring(encounterName or "")))
      end
      return
    end

    local function TryCountClear()
      local finalEncID = GetFinalEncounterIDFromDataPack(instanceID, did) or GetFinalEncounterIDForInstance(instanceID)
      if not finalEncID then return false end
      if tonumber(encounterID) ~= tonumber(finalEncID) then return false end

      if ShouldDebounceClear(instanceID, did, encounterID) then
        if ns._debug and ns._debug.clears then
          Print(("Clears: DEBOUNCE inst=%s did=%s encID=%s final=%s"):format(tostring(instanceID), tostring(did), tostring(encounterID), tostring(finalEncID)))
        end
        return true
      end

      IncrementInstanceCompletion(instanceID, did)
      if ns._debug and ns._debug.clears then
        local newCount = ns.GetInstanceCompletionCount(instanceID, did)
        Print(("Clears: COUNTED inst=%s did=%s encID=%s final=%s -> %s"):format(tostring(instanceID), tostring(did), tostring(encounterID), tostring(finalEncID), tostring(newCount)))
      end
      if hasPackGroup and ns.UI and ns.UI.RefreshGrid then
        if InCombatLockdown and InCombatLockdown() then
          if C_Timer and C_Timer.After then
            C_Timer.After(0.35, function() pcall(ns.UI.RefreshGrid) end)
          end
        else
          pcall(ns.UI.RefreshGrid)
        end
      end
      return true
    end

    -- Avoid calling Encounter Journal APIs while in combat (can cause taint / blocked actions).
    if InCombatLockdown and InCombatLockdown() then
      if ns._debug and ns._debug.clears then
        Print(("Clears: DELAY (in combat) inst=%s did=%s encID=%s %s"):format(tostring(instanceID), tostring(did), tostring(encounterID), tostring(encounterName or "")))
      end
      if C_Timer and C_Timer.After then
        C_Timer.After(0.35, function()
          -- Retry once combat has likely dropped.
          pcall(TryCountClear)
        end)


      end
      return
    end

    -- EJ can be unprimed; try once immediately, then retry shortly after.
    if not TryCountClear() then
      if ns._debug and ns._debug.clears then
        local finalNow = GetFinalEncounterIDFromDataPack(instanceID, did) or GetFinalEncounterIDForInstance(instanceID)
        Print(("Clears: NOCOUNT (not final or no final) inst=%s did=%s encID=%s final=%s %s"):format(tostring(instanceID), tostring(did), tostring(encounterID), tostring(finalNow), tostring(encounterName or "")))
      end
      if C_Timer and C_Timer.After then
        C_Timer.After(0.15, function() TryCountClear() end)
      end
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
ns._debug = ns._debug or { clears = false }

SLASH_COLLECTIONLOGDEBUG1 = "/cldebug"
SlashCmdList.COLLECTIONLOGDEBUG = function(msg)
  msg = (msg or ""):lower():gsub("^%s+",""):gsub("%s+$","")
  if msg == "clears" or msg == "clear" or msg == "kc" then
    ns._debug.clears = not ns._debug.clears
    Print("Debug (clears): " .. (ns._debug.clears and "ON" or "OFF"))
    return
  end
  Print("Usage: /cldebug clears")
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
