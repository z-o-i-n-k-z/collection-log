-- =========================
-- Instance lockout helper
-- =========================
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
  s = s:gsub("[’']", "") -- apostrophes
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
    return table.unpack(bestBucketMatch)
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

    if sameInstance then
      -- 1) Prefer exact difficulty ID
      if diffID == difficultyID then
        return i, reset, diffID, difficultyName, locked and true or false
      end
      -- 2) Otherwise remember a bucket match, but keep searching in case an exact match exists later
      local haveBucket = CL_DifficultyBucket(diffID)
      if (not bestBucketMatch) and wantBucket and haveBucket and wantBucket == haveBucket then
        bestBucketMatch = { i, reset, diffID, difficultyName, locked and true or false }
      end
    end
  end

  if bestBucketMatch then
    return table.unpack(bestBucketMatch)
  end
  return nil
end



local function CL_FormatResetSeconds(sec)
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

if not StaticPopupDialogs then StaticPopupDialogs = {} end
StaticPopupDialogs["COLLECTIONLOG_LOCKOUT"] = StaticPopupDialogs["COLLECTIONLOG_LOCKOUT"] or {
  text = "You are locked to this instance on this difficulty.\n\nResets in: %s",
  button1 = OKAY,
  timeout = 0,
  whileDead = 1,
  hideOnEscape = 1,
}

local _cl_lastLockPopupKey, _cl_lastLockPopupAt = nil, 0
local function CL_MaybeShowLockoutPopup(instanceID, difficultyID, resetSeconds)
  -- Intentionally no-op.
  -- Lockout info is displayed only via the lock icon tooltip (no blocking popup dialog).
  return
end

-- CollectionLog_UI.lua (OSRS-style layout with centered collected counter)
local ADDON, ns = ...
ns.UI = ns.UI or {}

ns._clDebug = ns._clDebug or { lastKey = nil, lastTime = 0 }

local function CL_DebugPrint(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(msg)
  else
    print(msg)
  end
end

-- ALT-hover debug: dumps transmog resolution details for the hovered loot item across sibling difficulties.
-- Safe: wrapped in pcall at call site; prints only (no tooltip mutation).
function ns.CL_DebugDumpTransmogForItem(itemID, groupId)
  if not itemID or not groupId then return end

  local now = (GetTime and GetTime()) or 0
  local key = tostring(groupId) .. ":" .. tostring(itemID)
  if ns._clDebug.lastKey == key and (now - (ns._clDebug.lastTime or 0)) < 0.75 then
    return
  end
  ns._clDebug.lastKey = key
  ns._clDebug.lastTime = now

  local g = ns.Data and ns.Data.groups and ns.Data.groups[groupId]
  if not g then
    CL_DebugPrint("|cffffd200[CL Debug]|r No group for " .. key)
    return
  end

  -- Gather sibling groups by instanceID/category (no dependency on local helpers)
  local siblings = {}
  if ns.Data and ns.Data.groups and g.instanceID then
    for _, sg in pairs(ns.Data.groups) do
      if sg and sg.instanceID == g.instanceID and sg.category == g.category then
        table.insert(siblings, sg)
      end
    end
  end

  CL_DebugPrint("|cffffd200[CL Debug]|r itemID=" .. tostring(itemID) .. "  group=" .. (g.name or "?") ..
    "  instanceID=" .. tostring(g.instanceID) .. "  difficultyID=" .. tostring(g.difficultyID))

  local function DumpGroup(sg)
    if not sg then return end
    local links = sg.itemLinks and sg.itemLinks[itemID]
    if not links then return end

    local label = sg.mode or ("difficultyID=" .. tostring(sg.difficultyID))
    CL_DebugPrint("  |cffaaaaaa[Mode]|r " .. tostring(label))

    local linkList = {}
    if type(links) == "table" then
      for _, L in ipairs(links) do
        if type(L) == "string" and L ~= "" then table.insert(linkList, L) end
      end
    elseif type(links) == "string" and links ~= "" then
      table.insert(linkList, links)
    end

    if #linkList == 0 then
      CL_DebugPrint("    (no itemLink)")
      return
    end

    for i, link in ipairs(linkList) do
      local aID, modID = 0, 0
      local okInfo = false
      if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
        local ok, aa, mm = pcall(C_TransmogCollection.GetItemInfo, link)
        if ok then
          okInfo = true
          aID, modID = aa or 0, mm or 0
        end
      end

      local modExists = (modID and modID ~= 0) and true or false
      local modCollected = false
      if modExists and C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
        local ok, res = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, modID)
        if ok and res then modCollected = true end
      end

      local appCollected
      if aID and aID ~= 0 and C_TransmogCollection and C_TransmogCollection.GetAppearanceInfoByID then
        local ok, info = pcall(C_TransmogCollection.GetAppearanceInfoByID, aID)
        if ok and info and info.isCollected ~= nil then
          appCollected = info.isCollected and true or false
        end
      end

      local hasLinkTruth = false
      if ns.IsCollectedFromLink then
        local ok, res = pcall(ns.IsCollectedFromLink, link, itemID)
        if ok and res then hasLinkTruth = true end
      end

      CL_DebugPrint(("    #%d okInfo=%s appearanceID=%s appCollected=%s modID=%s modExists=%s modCollected=%s linkTruth=%s link=%s")
        :format(i, tostring(okInfo), tostring(aID), tostring(appCollected), tostring(modID), tostring(modExists), tostring(modCollected), tostring(hasLinkTruth), tostring(link)))
    end
  end

  -- Dump current + all siblings that have itemLinks for this itemID
  DumpGroup(g)
  for _, sg in ipairs(siblings) do
    if sg ~= g then
      DumpGroup(sg)
    end
  end
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

local UI = ns.UI

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



-- ============================================================
-- Right-click removal (debug / cleanup)
-- ============================================================
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


  -- Window dimensions / scale defaults
  if CollectionLogDB.ui.w == nil then CollectionLogDB.ui.w = 980 end
  if CollectionLogDB.ui.h == nil then CollectionLogDB.ui.h = 640 end
  if CollectionLogDB.ui.scale == nil then CollectionLogDB.ui.scale = 1.0 end

  -- Left-list completion coloring
  -- Persisted per-group completion lets us paint the list instantly on login
  -- without requiring background scanning or per-row clicks.
  if CollectionLogDB.ui.precomputeLeftListColors == nil then
    CollectionLogDB.ui.precomputeLeftListColors = true
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
  UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
  for k, v in pairs(CollectionLogDB.ui.leftListColorCache.cache) do
    if type(k) == "string" and type(v) == "table" and v.total ~= nil and v.collected ~= nil then
      UI._clogLeftListColorCache[k] = { collected = v.collected, total = v.total, hard = (v.hard == true) }
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


local CATEGORIES = { "Overview", "Dungeons", "Raids", "Mounts", "Pets", "Toys" }

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


local function DesaturateIf(tex, yes)
  if tex and tex.SetDesaturated then
    tex:SetDesaturated(yes and true or false)
  end
  if tex and tex.SetVertexColor then
    if yes then tex:SetVertexColor(0.55, 0.55, 0.55) else tex:SetVertexColor(1, 1, 1) end
  end
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
  if tier == "LFR" then return "Raid Finder (LFR)" end
  if tier == "TW" then return "Timewalking (TW)" end
  if tier == "M" then return "Mythic (M)" end

  local needSize = false
  if siblingsContext and siblingsContext.multiSize and (tier == "H" or tier == "N") then
    needSize = siblingsContext.multiSize[tier] or false
  end

  if needSize and size and size > 0 then
    if tier == "H" then return ("Heroic (%d)"):format(size) end
    if tier == "N" then return ("Normal (%d)"):format(size) end
  end

  if tier == "H" then return "Heroic (H)" end
  if tier == "N" then return "Normal (N)" end

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

local function GetCollectibleKey(itemID)
  if not itemID or itemID <= 0 then
    return "I:0"
  end

  -- Prefer transmog appearance identity so shared appearances unify across difficulties.
  if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
    local a, b = C_TransmogCollection.GetItemInfo(itemID)
    local appearanceID, sourceID = a, b

    -- Normalize ambiguous return shapes by probing source info when needed.
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
      return "A:" .. tostring(appearanceID)
    end
  end

  return "I:" .. tostring(itemID)
end

local function FindMatchingItemID(group, key)
  if not group or not key or not group.items then return nil end
  for _, otherID in ipairs(group.items) do
    if GetCollectibleKey(otherID) == key then
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
  if ns and ns.HasCollectedAppearance and ns.HasCollectedAppearance(itemID) then
    return true
  end

  -- 2) Mount items
  if ns and ns.IsMountItemCollected and ns.IsMountItemCollected(itemID) then
    return true
  end

  -- 3) Battle pets (species ownership; itemID used as speciesID in pets groups, but dungeon loot shouldn't hit this)
  if ns and ns.IsPetItemCollected and ns.IsPetItemCollected(itemID) then
    return true
  end

  -- 4) Toys (no tooltip fallback)
  if C_ToyBox and C_ToyBox.GetToyFromItemID and PlayerHasToy then
    local toyID = C_ToyBox.GetToyFromItemID(itemID)
    if toyID and PlayerHasToy(toyID) then
      return true
    end
  end

  return false
end

local function CLog_GroupTotalsForLeftList(g)
  if not g then return 0, 0 end

  local hideJunk = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.hideJunk) or false

  local total = 0
  local collected = 0

  local function IsCollectedItem(itemID)
    -- Mirror the dungeon/raid header/grid collected logic so left-list always matches 100% state.
    local mode = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.viewMode or nil
    local guid = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCharacterGUID or nil

    -- Universal fast-paths (do not depend on section classification being ready).
    if ns and ns.IsMountItemCollected and ns.IsMountItemCollected(itemID) then
      return true
    end
    if ns and ns.IsPetItemCollected and ns.IsPetItemCollected(itemID) then
      return true
    end
    if C_ToyBox and C_ToyBox.GetToyFromItemID and PlayerHasToy then
      local toyID = C_ToyBox.GetToyFromItemID(itemID)
      if toyID and PlayerHasToy(toyID) then
        return true
      end
    end
    if ns and ns.HasCollectedAppearance and ns.HasCollectedAppearance(itemID) then
      return true
    end

    -- Section-aware handling (mounts/pets/toys inside raid/dungeon packs)
    local sec = (ns and ns.GetItemSectionFast and ns.GetItemSectionFast(itemID)) or nil
    if sec == "Mounts" then
      return (ns and ns.IsMountItemCollected and ns.IsMountItemCollected(itemID)) or false
    elseif sec == "Pets" then
      return (ns and ns.IsPetItemCollected and ns.IsPetItemCollected(itemID)) or false
    elseif sec == "Toys" then
      local isToy = (PlayerHasToy and PlayerHasToy(itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(itemID)) or false
      return isToy
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

local function CLog_ApplyLeftListTextColor(groupId, isActive)
  groupId = groupId and tostring(groupId) or nil
  local btn = groupId and UI._clogGroupBtnById and UI._clogGroupBtnById[groupId]
  if not btn or not btn.text then return end

  local c = UI._clogLeftListColorCache and UI._clogLeftListColorCache[groupId]
  if c and c.total and c.total > 0 then
    local r,g,b,a = CLog_ColorForCompletion(c.collected or 0, c.total or 0)
    btn.text:SetTextColor(r,g,b,a)
    return
  end

  -- No cached completion yet: keep the classic styling.
  if isActive then
    btn.text:SetTextColor(1, 0.90, 0.20, 1)
  else
    btn.text:SetTextColor(0.68, 0.66, 0.55, 1)
  end
end

local function CLog_QueueLeftListColor(groupId)
  if not groupId then return end
  groupId = tostring(groupId)
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
      -- If header/grid has already computed truth for this group, do not overwrite it with a background scan.
      if UI._clogLeftListTruthLock and UI._clogLeftListTruthLock[groupId] then
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
          if g then
            local ok, collected, total = pcall(function() return CLog_GroupTotalsForLeftList(g) end)
            if ok and total ~= nil and collected ~= nil then
              UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}
              UI._clogLeftListColorCache[gidKey] = { collected = collected, total = total, hard = true }

              -- Persist
              if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
                CollectionLogDB.ui.leftListColorCache.cache[gidKey] = { collected = collected, total = total, hard = true }
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

function UI.QueueLeftListPrecompute(groupIdList)
  if not (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.precomputeLeftListColors) then return end
  if not groupIdList or type(groupIdList) ~= "table" then return end

  UI._clogLeftListColorQueue = UI._clogLeftListColorQueue or {}
  UI._clogLeftListColorCache = UI._clogLeftListColorCache or {}

  for _, gid in ipairs(groupIdList) do
    local gidKey = tostring(gid)
    if gidKey and gidKey ~= "" then
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
    return
  else
    if UI.ShowOverview then UI.ShowOverview(false) end
  end


-- Toys: ensure the Blizzard-truthful Toys group exists so the Toys tab always has content
-- without requiring the user to open the Toy Box UI.
if cat == "Toys" and ns and ns.EnsureToysGroups then
  pcall(ns.EnsureToysGroups)
end

  local list = ns.Data.groupsByCategory[cat] or {}
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
    -- Mounts/Pets are account-wide and do not participate in expansion filtering.
    if cat == "Mounts" or cat == "Pets" or cat == "Toys" then
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
      if expFilter == "ALL" or exp == expFilter then
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
  local lastExp = nil
  for _, g in ipairs(deduped) do
    local exp = GetExp(g)
    if expFilter == "ALL" and cat ~= "Toys" then
      if exp ~= lastExp then
        -- Pets: hide the redundant top "Account" section header so the left list starts cleanly with "All Pets".
        if not ((cat == "Pets" or cat == "Mounts") and exp == "Account") then
          rows[#rows+1] = { kind = "header", text = exp }
        end
        lastExp = exp
      end
    end
    rows[#rows+1] = { kind = "group", group = g }
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
  if self._clogIsActive then return end
  if self._clogHoverBG then self._clogHoverBG:Show() end
  -- subtle border lift on hover
  self:SetBackdropBorderColor(GOLD_R, GOLD_G, GOLD_B, 0.55)
  if self.__clogSheen then self.__clogSheen:SetVertexColor(1, 1, 1, 0.12) end
end)

r.button:HookScript("OnLeave", function(self)
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
  CollectionLogDB.ui.activeGroupId = self.groupId
  UI.RefreshGrid()
  BuildGroupList()
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

      if displayedIds and g and g.id then
        table.insert(displayedIds, g.id)
      end

            local isActive = (CollectionLogDB.ui.activeGroupId == (g and g.id))
      row.button._clogIsActive = (isActive and true or false)

-- Match the "folder tab" language:
-- inactive = muted gray-gold; active = vibrant gold + subtle depth (no scale/framelevel)
if isActive then
  -- Active: keep the soft glow, but add a thin gold edge like the tabs (no left spine)
  row.button:SetBackdropColor(0.11, 0.11, 0.11, 0.95)
  row.button:SetBackdropBorderColor(1.00, 0.90, 0.20, 0.60)
  if row.button.__clogSheen then row.button.__clogSheen:SetVertexColor(1, 1, 1, 0.22) end
else
  -- Inactive: receded / cool gray
  row.button:SetBackdropColor(0.06, 0.06, 0.06, 0.90)
  row.button:SetBackdropBorderColor(INACT_R, INACT_G, INACT_B, 0.45)
  if row.button.__clogSheen then row.button.__clogSheen:SetVertexColor(1, 1, 1, 0.06) end
end

if row.button._clogActiveBG then row.button._clogActiveBG:SetShown(isActive) end
-- Always keep the left accent bar off (it reads like an artifact on some UI scales)
if row.button._clogAccent then row.button._clogAccent:Hide() end
if row.button.text then
  if isActive then
    if cat == "Dungeons" or cat == "Raids" then
      UI._clogGroupBtnById[tostring(g.id)] = row.button
      CLog_ApplyLeftListTextColor(g.id, true)
else
      row.button.text:SetTextColor(1, 0.90, 0.20, 1)
    end
  else
    -- Dungeons/Raids: color by completion (computed asynchronously)
    if cat == "Dungeons" or cat == "Raids" then
      UI._clogGroupBtnById[tostring(g.id)] = row.button
      CLog_ApplyLeftListTextColor(g.id, false)
else
      row.button.text:SetTextColor(0.68, 0.66, 0.55, 1)
    end
  end
end

    end

    row:Show()
    y = y + row:GetHeight() + pad
  end

  -- Hide unused rows
  for i = #rows + 1, #UI.groupRows do
    UI.groupRows[i]:Hide()
  end

  -- Quietly fill in any missing completion colors for the rows we just displayed.
  -- This is timer-sliced and persisted, so users get colors without clicking each row,
  -- and future sessions paint instantly.
  if displayedIds and #displayedIds > 0 and UI.QueueLeftListPrecompute then
    UI.QueueLeftListPrecompute(displayedIds)
  end
end

-- =====================
-- Grid cells


-- =====================
-- Manual Mount grouping overrides (Primary + Extra tags)
-- Shift + Right Click a mount icon to set Primary category / extra tags.
-- This ONLY affects display grouping (SavedVariables); it never changes Blizzard truth.
-- =====================
local MOUNT_OVERRIDE_CATEGORIES = {
  "Drops (Raid)",
  "Drops (Dungeon)",
  "Drops (Open World)",
  "Drops (Delve)",
  "Achievement",
  "Adventures",
  "Quest",
  "Reputation",
  "Profession",
  "Class",
  "Faction",
  "Race",
  "PvP",
  "Vendor",
  "World Event",
  "Store",
  "Trading Post",
  "Promotion",
  "Secret",
  "Garrison Mission",
  "Covenant Feature",
  "Unobtainable",
  "Uncategorized",
}

local function EnsureMountOverrideState()
  EnsureUIState()
  CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
  local uo = CollectionLogDB.userOverrides
  uo.mounts = uo.mounts or {}
  uo.mounts.primary = uo.mounts.primary or {}
  uo.mounts.extra = uo.mounts.extra or {}
  return uo.mounts
end

local function RefreshMountsAfterOverride()
  if ns and ns.EnsureMountsGroups then pcall(ns.EnsureMountsGroups) end
  if ns and ns.RebuildGroupIndex then pcall(ns.RebuildGroupIndex) end
  UI.RefreshGrid()
  BuildGroupList()
end

local function GetMountPrimary(mountID)
  local st = EnsureMountOverrideState()
  return st.primary[tonumber(mountID)]
end

local function SetMountPrimary(mountID, cat)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return end
  if type(cat) ~= "string" or cat == "" then return end
  st.primary[mountID] = cat
  RefreshMountsAfterOverride()
end

local function ToggleMountExtra(mountID, cat)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return end
  if type(cat) ~= "string" or cat == "" then return end
  st.extra[mountID] = st.extra[mountID] or {}
  st.extra[mountID][cat] = not not (not st.extra[mountID][cat])
  -- toggle: if it was true, set false; if false/nil, set true
  if st.extra[mountID][cat] then
    st.extra[mountID][cat] = true
  else
    st.extra[mountID][cat] = nil
  end
  RefreshMountsAfterOverride()
end

local function HasMountExtra(mountID, cat)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return false end
  local t = st.extra[mountID]
  return (type(t) == "table" and t[cat]) and true or false
end

local function ResetMountOverride(mountID)
  local st = EnsureMountOverrideState()
  mountID = tonumber(mountID)
  if not mountID then return end
  st.primary[mountID] = nil
  st.extra[mountID] = nil
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

local function ShowMountOverrideMenu(anchorFrame, mountID)
  mountID = tonumber(mountID)
  if not mountID then return end
  anchorFrame = anchorFrame or UIParent

  -- Modern (Dragonflight+) completions: MenuUtil.CreateContextMenu
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchorFrame, function(owner, root)
      root:CreateTitle("Mount Grouping")

      local primary = root:CreateButton("Set Primary Category")
      for _, cat in ipairs(MOUNT_OVERRIDE_CATEGORIES) do
        primary:CreateRadio(cat,
          function() return GetMountPrimary(mountID) == cat end,
          function() SetMountPrimary(mountID, cat) end
        )
      end

      local extra = root:CreateButton("Also Show In")
      for _, cat in ipairs(MOUNT_OVERRIDE_CATEGORIES) do
        extra:CreateCheckbox(cat,
          function() return HasMountExtra(mountID, cat) end,
          function() ToggleMountExtra(mountID, cat) end
        )
      end

      root:CreateDivider()
      root:CreateButton("Reset to Default", function() ResetMountOverride(mountID) end)
    end)
    return
  end

  -- Legacy fallback: try to ensure UIDropDownMenu exists
  if UIParentLoadAddOn then
    pcall(UIParentLoadAddOn, "Blizzard_Deprecated")
  end

  local menu = {
    { text = "Mount Grouping", isTitle = true, notCheckable = true },
    {
      text = "Set Primary Category",
      notCheckable = true,
      hasArrow = true,
      menuList = (function()
        local sub = {}
        for _, cat in ipairs(MOUNT_OVERRIDE_CATEGORIES) do
          table.insert(sub, {
            text = cat,
            checked = function() return GetMountPrimary(mountID) == cat end,
            func = function() SetMountPrimary(mountID, cat) end,
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
        for _, cat in ipairs(MOUNT_OVERRIDE_CATEGORIES) do
          table.insert(sub, {
            text = cat,
            keepShownOnClick = true,
            isNotRadio = true,
            checked = function() return HasMountExtra(mountID, cat) end,
            func = function() ToggleMountExtra(mountID, cat) end,
          })
        end
        return sub
      end)(),
    },
    { text = "Reset to Default", notCheckable = true, func = function() ResetMountOverride(mountID) end },
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
-- =====================

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

    local icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon = icon
    icon:SetAllPoints(cell)

    local countText = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    cell.countText = countText
    countText:SetPoint("BOTTOMRIGHT", cell, "BOTTOMRIGHT", -2, 2)
    countText:SetText("")

cell:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

  -- ALT-hover debug (dynamic while hovering)
  self.__clHovering = true
  self:SetScript("OnUpdate", function(btn)
    if not btn.__clHovering then return end
    if IsAltKeyDown and IsAltKeyDown() then
      if not btn.__clDebugDone and btn.itemID and btn.groupId and ns and ns.CL_DebugDumpTransmogForItem then
        local ok, err = pcall(ns.CL_DebugDumpTransmogForItem, btn.itemID, btn.groupId)
        if not ok and UIErrorsFrame and UIErrorsFrame.AddMessage then
          UIErrorsFrame:AddMessage("Collection Log: debug error: " .. tostring(err))
        end
        btn.__clDebugDone = true
      end
    else
      btn.__clDebugDone = nil
    end
  end)


  -- Pet entry (speciesID)
  if self.petSpeciesID then
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
if self.mountID then
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
  end

  GameTooltip:Show()
  return
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

    GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)

    local collected = ((PlayerHasToy and PlayerHasToy(self.itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(self.itemID))) and true or false
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

  -- Non-toy item entries: show the full Blizzard item tooltip
  GameTooltip:SetItemByID(self.itemID)

local viewMode = CollectionLogDB.ui.viewMode
      local guid = CollectionLogDB.ui.activeCharacterGUID
      local recCount = ns.GetRecordedCount(self.itemID, viewMode, guid) or 0

      local activeCat = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory or nil
      local isCollected
      if activeCat == "Toys" then
        isCollected = (PlayerHasToy and PlayerHasToy(self.itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(self.itemID)) or false
      else
        isCollected = (ns.IsCollected and ns.IsCollected(self.itemID)) or false
      end

      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("|cff00ff99Collection Log|r", 1, 1, 1)

      local groupId = CollectionLogDB.ui.activeGroupId

      local g = groupId and ns.Data and ns.Data.groups and ns.Data.groups[groupId]
      if g then
        if g.name then
          GameTooltip:AddLine(("Source: %s"):format(g.name), 0.85, 0.85, 0.85, true)
        end
        if g.itemSources and g.itemSources[self.itemID] then
          GameTooltip:AddLine(("Drops from: %s"):format(g.itemSources[self.itemID]), 0.85, 0.85, 0.85, true)
        end
        -- Mode: which difficulties this collectible drops in (loot-table truth)
        local modeText
        local modeKnown, modeGreen = 0, 0   -- only counts M/H/N/LFR where we can resolve the appearance variant
        local collectedLineColor = isCollected and "|cff00ff00" or "|cffff5555"

        local okMode = pcall(function()
        if g.instanceID then
            local siblings = GetSiblingGroups(g.instanceID, g.category)
            local key = GetCollectibleKey(self.itemID)
  
            -- Build a siblings context to decide when to include group-size disambiguation.
            local ctx = { multiSize = { H = false, N = false } }
            do
              local sizesH, sizesN = {}, {}
              for _, sg in ipairs(siblings) do
                local tier, size = GetDifficultyMeta(sg.difficultyID, sg.mode)
                if tier == "H" then
                  sizesH[size or 0] = true
                elseif tier == "N" then
                  sizesN[size or 0] = true
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
  
            local seen = {}
            local parts = {}
  
            local function GetLinkCandidates(linkOrTable)
              if type(linkOrTable) == "table" then
                return linkOrTable
              end
              if type(linkOrTable) == "string" and linkOrTable ~= "" then
                return { linkOrTable }
              end
              return {}
            end

            local function ResolveVariantCollected(sg, matchID)
              -- Hybrid, Blizzard-truthful check:
              -- Evaluate ALL candidate itemLinks we have stored for this difficulty (some items, especially weapons,
              -- can have multiple links/modifiers). We treat the variant as collected if ANY candidate link resolves
              -- to a collected transmog (exact modified appearance preferred, then appearance-level fallback).
              --
              -- Returns: has (bool), known (bool)
              if not (C_TransmogCollection and C_TransmogCollection.GetItemInfo) then
                return false, false
              end

              local links = sg and sg.itemLinks and GetLinkCandidates(sg.itemLinks[matchID]) or {}
              if type(links) ~= "table" or #links == 0 then
                return false, false
              end

              local anyKnown = false
              local anyCollected = false

              local function EvalLink(link)
                if type(link) ~= "string" or link == "" then
                  return nil -- unknown
                end

                local okGet, appearanceID, itemModAppearanceID = pcall(C_TransmogCollection.GetItemInfo, link)
                if not okGet then
                  return nil
                end
                if (not appearanceID or appearanceID == 0) and (not itemModAppearanceID or itemModAppearanceID == 0) then
                  -- Blizzard couldn't resolve an appearance identity for this link.
                  -- Stay truthful: treat as unknown (gray) rather than guessing.
                  return nil
                end

                -- Primary truth: appearance-level ownership by appearanceID (matches the Wardrobe UI).
                if appearanceID and appearanceID ~= 0 and C_TransmogCollection.GetAppearanceInfoByID then
                  local okApp, appInfo = pcall(C_TransmogCollection.GetAppearanceInfoByID, appearanceID)
                  if okApp and appInfo and appInfo.isCollected ~= nil then
                    return appInfo.isCollected and true or false
                  end
                end

                -- Secondary truth (only when appearance info is unavailable): modified-appearance ownership.
                -- IMPORTANT: We only use this to return TRUE; a FALSE here is not authoritative.
                if itemModAppearanceID and itemModAppearanceID ~= 0
                  and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance then
                  local okHas, has = pcall(C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance, itemModAppearanceID)
                  if okHas and has then
                    return true
                  end
                end

                -- If we can't determine appearance ownership from Blizzard APIs, treat as unknown.
                return nil
              end

              for i = 1, #links do
                local r = EvalLink(links[i])
                if r ~= nil then
                  anyKnown = true
                  if r == true then
                    anyCollected = true
                    break
                  end
                end
              end

              return anyCollected, anyKnown
            end

            local function ColorizeLabel(label, tier, sg, matchID)
              -- Only M/H/N/LFR get the appearance-variant coloring rules.
              if tier == "M" or tier == "H" or tier == "N" or tier == "LFR" then
                local has, known = ResolveVariantCollected(sg, matchID)
                if known then
                  modeKnown = modeKnown + 1
                  if has then modeGreen = modeGreen + 1 end
                  return (has and "|cff00ff00" or "|cffff5555") .. label .. "|r"
                else
                  return "|cffaaaaaa" .. label .. "|r"
                end
              end
              -- Everything else (e.g., TW) stays neutral.
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
                      table.insert(parts, ColorizeLabel(label, tier, sg, matchID))
                    end
                  end
                end
              end
            end
  
            -- Required order: M, H/H(X), N/N(X), LFR, TW
            AddTier("M")
            AddTier("H")
            AddTier("N")
            AddTier("LFR")
            AddTier("TW")
  
            if #parts > 0 then
              modeText = table.concat(parts, " / ")
            end
  
            -- Color the main Collected: Yes/No line based on per-variant appearance ownership.
            -- Only affects the visual color; the Yes/No text remains item-collection truth.
            if isCollected then
              if modeKnown > 0 then
                if modeGreen == modeKnown then
                  collectedLineColor = "|cff00ff00"  -- all variants owned
                elseif modeGreen > 0 then
                  collectedLineColor = "|cffffff00"  -- partial variants owned
                else
                  collectedLineColor = "|cffff5555"  -- zero variants owned
                end
              end
            end
          end
        end)

        GameTooltip:AddLine(("Collected: %s%s|r"):format(collectedLineColor, isCollected and "Yes" or "No"), 0.9, 0.9, 0.9)
        if modeText then
          GameTooltip:AddLine(("Mode: %s"):format(modeText), 0.85, 0.85, 0.85, true)
        elseif g.mode then
          GameTooltip:AddLine(("Mode: %s"):format(g.mode), 0.85, 0.85, 0.85, true)
        end
      end

      GameTooltip:Show()
    end)

    cell:SetScript("OnLeave", function(self)
  self.__clHovering = nil
  self.__clDebugDone = nil
  self:SetScript("OnUpdate", nil)
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
    line:SetHeight(1)
    line:SetPoint("LEFT", txt, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", h, "RIGHT", -2, 0)
    line:SetColorTexture(1, 1, 1, 0.15)
  end

  UI.maxSectionHeaders = count
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
  if not speciesID then return nil, false end
  local c = UI._clogPetCache[speciesID]
  if c then return c.icon, c.collected end
  local icon, collected = nil, false
  if C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID then
    local ok, _, ic = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
    if ok then icon = ic end
  end
  if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
    local ok, numCollected = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
    collected = (ok and type(numCollected) == "number" and numCollected > 0) or false
  end
  UI._clogPetCache[speciesID] = { icon = icon, collected = collected }
  return icon, collected
end

-- Refresh only the currently-visible cells' collected state (no relayout).
-- This fixes the "first click shows grey, second click shows collected" effect
-- caused by asynchronous item/transmog data.
function UI.RefreshVisibleCollectedStateOnly()
  if not (UI and UI.frame and UI.frame:IsShown() and UI.cells) then return end
  if not (CollectionLogDB and CollectionLogDB.ui) then return end

  local mode = CollectionLogDB.ui.viewMode
  if mode ~= "dungeons" and mode ~= "raids" then return end

  local guid = CollectionLogDB.ui.activeCharacterGUID

  for i = 1, (UI.maxCells or 0) do
    local cell = UI.cells[i]
    if cell and cell:IsShown() then
      local collected = false
      local iconFile = nil
      local recCount = 0

      if cell.mountID then
        iconFile, collected = CL_GetMountIconCollected(cell.mountID)
        if cell.countText then cell.countText:SetText("") end
      elseif cell.petSpeciesID then
        iconFile, collected = CL_GetPetIconCollected(cell.petSpeciesID)
        if cell.countText then cell.countText:SetText("") end
      elseif cell.itemID then
        iconFile = select(5, GetItemInfoInstant(cell.itemID))

        -- Raid/Dungeon special sections: token items that grant a mount/pet/toy.
        if cell.section == "Mounts" then
          collected = (ns.IsMountItemCollected and ns.IsMountItemCollected(cell.itemID)) or false
          if cell.countText then cell.countText:SetText("") end
        elseif cell.section == "Pets" then
          collected = (ns.IsPetItemCollected and ns.IsPetItemCollected(cell.itemID)) or false
          if cell.countText then cell.countText:SetText("") end
        else
          -- Toys should remain Blizzard-truthful via the ToyBox.
          local isToy = (PlayerHasToy and PlayerHasToy(cell.itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(cell.itemID))
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

      if iconFile and cell.icon and cell.icon.GetTexture and (cell.icon:GetTexture() ~= iconFile) then
        cell.icon:SetTexture(iconFile)
      end
      if cell.icon then
        DesaturateIf(cell.icon, not collected)
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

  -- Total
  local total = 0
  if mode == "dungeons" or mode == "raids" then
    -- For raid/dungeon groups, apply Hide Junk filter to totals so header matches the grid.
    if g.items then
      local hideJunk = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.hideJunk
      for _, itemID in ipairs(g.items) do
        if not hideJunk or CL_IsCoreLootItemID(itemID) then
          total = total + 1
        end
      end
    end
  else
    total = isMounts and #(g.mounts or {}) or (isPets and #(g.pets or {}) or #(g.items or {}))
  end

  -- Collected
  local collectedCount = 0
  local guid = CollectionLogDB.ui.activeCharacterGUID

  if isMounts then
    for _, mountID in ipairs(g.mounts or {}) do
      local _, isCollected = CL_GetMountIconCollected(mountID)
      if isCollected then collectedCount = collectedCount + 1 end
    end
  elseif isPets then
    for _, speciesID in ipairs(g.pets or {}) do
      local _, isCollected = CL_GetPetIconCollected(speciesID)
      if isCollected then collectedCount = collectedCount + 1 end
    end
  elseif isToys then
    for _, toyItemID in ipairs(g.items or {}) do
      local has = (PlayerHasToy and PlayerHasToy(toyItemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(toyItemID))
      if has then collectedCount = collectedCount + 1 end
    end
  else
    local viewMode = mode
    for _, itemID in ipairs(g.items or {}) do
      local hideJunk = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.hideJunk
      if not hideJunk or CL_IsCoreLootItemID(itemID) then
        -- Section-aware "core" items inside raid/dungeon grids
        local sec = (ns and ns.GetItemSectionFast and ns.GetItemSectionFast(itemID)) or nil
        if sec == "Mounts" then
          if ns.IsMountItemCollected and ns.IsMountItemCollected(itemID) then collectedCount = collectedCount + 1 end
        elseif sec == "Pets" then
          if ns.IsPetItemCollected and ns.IsPetItemCollected(itemID) then collectedCount = collectedCount + 1 end
        else
          local isToy = (PlayerHasToy and PlayerHasToy(itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(itemID))
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
    local existing = UI._clogLeftListColorCache and UI._clogLeftListColorCache[gidKey]
    if not (existing and existing.hard == true) then
      UI._clogLeftListColorCache[gidKey] = { collected = collectedCount, total = total, hard = true }

      -- Persist so the left list can paint instantly on next login.
      if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
        local existingSaved = CollectionLogDB.ui.leftListColorCache.cache[gidKey]
        if not (type(existingSaved) == "table" and existingSaved.hard == true) then
          CollectionLogDB.ui.leftListColorCache.cache[gidKey] = { collected = collectedCount, total = total, hard = true }
          if CollectionLogDB.ui.leftListColorCache.meta then
            CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
          end
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

  -- Clear memoized journal reads so we don't keep a stale "false" from early init.
  UI._clogMountCache = {}
  UI._clogPetCache = {}

  -- Nudge item data for visible token items (non-blocking).
  if C_Item and C_Item.RequestLoadItemDataByID and UI.cells then
    for i = 1, (UI.maxCells or 0) do
      local cell = UI.cells[i]
      if cell and cell:IsShown() and cell.itemID then
        pcall(C_Item.RequestLoadItemDataByID, cell.itemID)
      end
    end
  end

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
local function CL_IsCoreLootItemID(itemID, itemLink)
  if not itemID then return true end

  -- Fast deterministic section classification (no async GetItemInfo dependency).
  -- This is critical so "Hide Junk" never causes a 2-click layout where mounts/pets/toys
  -- appear only after item data finishes streaming in.
  if ns and ns.GetItemSectionFast then
    local ok, sec = pcall(ns.GetItemSectionFast, itemID)
    if ok and sec then
      if sec == "Weapons" or sec == "Armor" or sec == "Mounts" or sec == "Pets" or sec == "Toys" or sec == "Housing" then
        return true
      end
      if sec == "Jewelry" or sec == "Trinkets" then
        return false
      end
    end
  end

  -- Items that grant account collections should always be considered "core".
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

  -- Best-effort: some illusion items are transmog sources even though they're not weapons/armor.
  if C_TransmogCollection and C_TransmogCollection.GetItemInfo then
    local ok, canTransmog = pcall(C_TransmogCollection.GetItemInfo, itemLink or itemID)
    if ok and canTransmog then return true end
  end

  -- Weapons/Armor (exclude jewelry/trinkets) using instant data where possible.
  local equipLoc, classID
  local gotInstant = false
  if GetItemInfoInstant then
    local ok, _, _, _, eLoc, _, cID = pcall(GetItemInfoInstant, itemID)
    if ok then
      gotInstant = true
      equipLoc, classID = eLoc, cID
    end
  end

  -- If we cannot classify the item yet (item data still streaming), do NOT hide it.
  -- Being conservative avoids "missing mounts/pets/toys until the second click".
  if not gotInstant and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end

  if equipLoc == nil and not gotInstant then
    return true
  end

  if equipLoc == "INVTYPE_NECK" or equipLoc == "INVTYPE_FINGER" or equipLoc == "INVTYPE_TRINKET" then
    return false
  end

  if classID == 2 or classID == 4 then
    return true
  end

  if equipLoc and equipLoc ~= "" then
    if equipLoc:find("WEAPON", 1, true) or equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT" then
      return true
    end
    if equipLoc:find("HEAD", 1, true) or equipLoc:find("SHOULDER", 1, true) or equipLoc:find("CHEST", 1, true)
      or equipLoc:find("ROBE", 1, true) or equipLoc:find("WRIST", 1, true) or equipLoc:find("HAND", 1, true)
      or equipLoc:find("WAIST", 1, true) or equipLoc:find("LEGS", 1, true) or equipLoc:find("FEET", 1, true)
      or equipLoc:find("CLOAK", 1, true) or equipLoc:find("SHIELD", 1, true) or equipLoc:find("HOLDABLE", 1, true) then
      return true
    end
  end

  return false
end


function UI.RefreshGrid()
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Overview" then
    if UI.ShowOverview then UI.ShowOverview(true) end
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
--   Bright lock + green ✓ = not locked
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
    local isInstItems = (activeCat == "Raids" or activeCat == "Dungeons")
    local hideNC = (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.hideNonCoreLootGrids == true) and true or false

    -- Total may be filtered (optional) for instance item grids.
    local total
    if (not isMounts) and (not isPets) and (not isToys) and isInstItems and hideNC then
      total = 0
      for _, itemID in ipairs(g.items or {}) do
        if CL_IsCoreLootItemID(itemID) then
          total = total + 1
        end
      end
    else
      total = isMounts and #(g.mounts or {}) or (isPets and #(g.pets or {}) or #(g.items or {}))
    end

    local collectedCount = 0
    local viewMode = CollectionLogDB.ui.viewMode
    local guid = CollectionLogDB.ui.activeCharacterGUID

    if isMounts then
      for _, mountID in ipairs(g.mounts or {}) do
        local _, isCollected = CL_GetMountIconCollected(mountID)
        if isCollected then collectedCount = collectedCount + 1 end
      end
    elseif isPets then
      for _, speciesID in ipairs(g.pets or {}) do
        local _, isCollected = CL_GetPetIconCollected(speciesID)
        if isCollected then collectedCount = collectedCount + 1 end
      end
    else
      for _, itemID in ipairs(g.items or {}) do
        if (not isToys) and isInstItems and hideNC and (not CL_IsCoreLootItemID(itemID)) then
          -- Hidden by settings (non-core loot)
        else
        if isToys then
          local hasToy = (PlayerHasToy and PlayerHasToy(itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(itemID)) or false
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
      if gidKey then
        UI._clogLeftListColorCache[gidKey] = { collected = collectedCount, total = total, hard = true }
      end

        -- Persist hard truth so list paints instantly on next login.
        if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.leftListColorCache and CollectionLogDB.ui.leftListColorCache.cache then
          CollectionLogDB.ui.leftListColorCache.cache[gidKey] = { collected = collectedCount, total = total, hard = true }
          if CollectionLogDB.ui.leftListColorCache.meta then
            CollectionLogDB.ui.leftListColorCache.meta.generatedAt = time and time() or 0
          end
        end
      UI._clogLeftListTruthLock = UI._clogLeftListTruthLock or {}
      if gidKey then
        UI._clogLeftListTruthLock[gidKey] = true
        if UI._clogLeftListColorQueue then UI._clogLeftListColorQueue[gidKey] = nil end
      end
      CLog_ApplyLeftListTextColor(groupId, true)
    end

    -- Instance completion counter (OSRS-style) completions: counts full clears per instance per difficulty.
    if UI.completionCount and g and g.instanceID and g.category and (g.category == "Raids" or g.category == "Dungeons") then
      local diffLabel = DifficultyLongLabel(g.difficultyID, g.mode)
      -- For the completion line only, strip the abbreviated suffix like " (N)"
      diffLabel = tostring(diffLabel or ""):gsub("%s%(%u+%)%s*$", "")
      local count = 0
      if ns and ns.GetInstanceCompletionCount then
        count = ns.GetInstanceCompletionCount(g.instanceID, g.difficultyID) or 0
      end
      UI.completionCount:SetText(("%s (%s) completions: %d"):format(g.name or "Instance", diffLabel, count))
      UI.completionCount:Show()
    elseif UI.completionCount then
      UI.completionCount:SetText("")
      UI.completionCount:Hide()
    end

    SetProgressBar(collectedCount, total)
  end

  -- Difficulty dropdown
  if UI.BuildDifficultyDropdown then UI.BuildDifficultyDropdown() end


  local search = (CollectionLogDB.ui.search or ""):lower():match("^%s*(.-)%s*$")
  local isMounts = (g and g.mounts and g.category == "Mounts")
  local isPets = (g and g.pets and g.category == "Pets")
  local isToys = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Toys")
  local isRaids = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == "Raids")
  local items = isMounts and (g.mounts or {}) or (isPets and (g.pets or {}) or (g.items or {}))

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
    local hideNC = (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.hideNonCoreLootGrids == true) and true or false
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
    local collected = ((PlayerHasToy and PlayerHasToy(itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(itemID))) and true or false
    if (collected and tShowCollected) or ((not collected) and tShowNotCollected) then
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

  local totalItems = (type(filtered) == "table" and #filtered) or 0
  local page = 1
  local maxPage = 1

  if pageSize and totalItems > 0 then
    maxPage = math.max(1, math.ceil(totalItems / pageSize))
    if CollectionLogDB and CollectionLogDB.ui then
      if isPets and type(CollectionLogDB.ui.petsPage) == "number" then page = CollectionLogDB.ui.petsPage end
      if isMounts and type(CollectionLogDB.ui.mountsPage) == "number" then page = CollectionLogDB.ui.mountsPage end
        if isToys and type(CollectionLogDB.ui.toysPage) == "number" then page = CollectionLogDB.ui.toysPage end
    end
    if page < 1 then page = 1 end
    if page > maxPage then page = maxPage end
    if CollectionLogDB and CollectionLogDB.ui then
      if isPets then CollectionLogDB.ui.petsPage = page end
      if isMounts then CollectionLogDB.ui.mountsPage = page end
      if isToys then CollectionLogDB.ui.toysPage = page end
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
    UI:UpdatePagerUI(isPets, isMounts, isToys, isRaids, page, maxPage, startIndex, endIndex, totalItems)
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
else
  for _, itemID in ipairs(filtered) do
    -- Use fast/deterministic section classification so the grid layout is
    -- stable on the first render (avoids the "2-click" re-layout once item
    -- info streams in).
    local sec = (ns.GetItemSectionFast and ns.GetItemSectionFast(itemID))
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

  local guid = CollectionLogDB.ui.activeCharacterGUID

  for _, secName in ipairs(order) do
    local secItems = sections[secName]
    if secItems and #secItems > 0 then
      PlaceHeader(secName)

      for _, itemID in ipairs(secItems) do
        usedCells = usedCells + 1
        local cellIndex = usedCells

        local x = PAD + col * (ICON + GAP)
        local yPos = y
        local activeGroupId = (CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId) or nil

        renderEntries[#renderEntries + 1] = {
          idx = cellIndex,
          x = x,
          y = yPos,
          itemID = (not isMounts and not isPets) and itemID or nil,
          mountID = isMounts and itemID or nil,
          petSpeciesID = isPets and itemID or nil,
          section = secName,
          groupId = activeGroupId,
        }

        local cell = UI.cells[cellIndex]
        cell.itemID = nil
        cell.mountID = nil
        cell.petSpeciesID = nil
        cell.groupId = nil
        cell.section = nil
        cell:Hide()

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


  -- Apply queued cell updates in batches to avoid frame hitching on large grids.
  UI._gridBuildEntries = renderEntries
  UI._gridBuildIndex = 1

  -- Proactively request item data for loot-table items so collected state can be
  -- computed correctly on the first click. This is a non-blocking hint to the
  -- client; results arrive later via ITEM_DATA_LOAD_RESULT/GET_ITEM_INFO_RECEIVED.
  if C_Item and C_Item.RequestLoadItemDataByID then
    for _, e in ipairs(renderEntries) do
      if e.itemID then
        pcall(C_Item.RequestLoadItemDataByID, e.itemID)
      end
    end
  end

  local function ApplyOne(entry)
    local cell = UI.cells[entry.idx]
    if not cell then return end

    cell.itemID = entry.itemID
    cell.mountID = entry.mountID
    cell.petSpeciesID = entry.petSpeciesID
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

      -- Raid/Dungeon special sections: these are "token" items that grant a mount/pet/toy.
      -- They must use Blizzard-truthful collection state (Mount/Pet journal/ToyBox),
      -- not transmog/item ownership.
      if entry.section == "Mounts" then
        collected = (ns.IsMountItemCollected and ns.IsMountItemCollected(entry.itemID)) or false
        cell.countText:SetText("")
      elseif entry.section == "Pets" then
        collected = (ns.IsPetItemCollected and ns.IsPetItemCollected(entry.itemID)) or false
        cell.countText:SetText("")
      elseif isToys or entry.section == "Toys" then
        collected = (PlayerHasToy and PlayerHasToy(entry.itemID)) or (C_ToyBox and C_ToyBox.HasToy and C_ToyBox.HasToy(entry.itemID)) or false
        cell.countText:SetText("")
      else
        recCount = ns.GetRecordedCount(entry.itemID, CollectionLogDB.ui.viewMode, guid)
        local isCollected = (ns.IsCollected and ns.IsCollected(entry.itemID)) or false
        collected = (recCount and recCount > 0) or isCollected
        cell.countText:SetText((recCount and recCount > 0) and tostring(recCount) or "")
      end
    end

    cell.icon:SetTexture(iconFile or "Interface/Icons/INV_Misc_QuestionMark")
    DesaturateIf(cell.icon, not collected)
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

  -- Post-render collected refresh passes (no relayout).
  -- Some Blizzard collection APIs (especially mount items like 71665) become
  -- authoritative slightly after first render without necessarily firing a
  -- reliable event. Schedule a few lightweight refreshes so the user doesn't
  -- need to click the instance twice.
  if UI and UI.RefreshVisibleCollectedStateOnly then
    local thisSerial = buildSerial
    local function Post(delay)
      C_Timer.After(delay, function()
        if UI._gridBuildSerial ~= thisSerial then return end
        if not (UI.frame and UI.frame:IsShown()) then return end
        -- Allow re-query once the journals finish initializing.
        UI._clogMountCache = {}
        UI._clogPetCache = {}
        if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_visible_collected", function() pcall(UI.RefreshVisibleCollectedStateOnly) end) else pcall(UI.RefreshVisibleCollectedStateOnly) end
      end)
    end
    Post(0.10)
    Post(0.35)
    Post(0.90)
  end

  local totalH = y + PAD
  UI.grid:SetHeight(math.max(totalH, UI.gridScroll:GetHeight() or 1))

  -- Hide unused cells
  for i = usedCells + 1, UI.maxCells do
    UI.cells[i].itemID = nil
    UI.cells[i].mountID = nil
    UI.cells[i]:Hide()
  end

  -- Hide unused headers
  if UI.sectionHeaders then
    for i = usedHeaders + 1, (UI.maxSectionHeaders or 0) do
      UI.sectionHeaders[i]:Hide()
    end
  end
end

UI.BuildGroupList = BuildGroupList

function UI.RefreshAll()
  if not UI.frame then return end
  BuildGroupList()
  UI.RefreshGrid()
end

-- ============
-- Window init
-- ============
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
  CreateBorder(f)

  -- Participate in Blizzard's UIPanel system so Collection Log stacks correctly
  -- with Blizzard panels (Talents/Spellbook/etc.) and other well-behaved addons.
  f:SetFrameStrata("HIGH")

  if type(UIPanelWindows) == "table" then
    UIPanelWindows["CollectionLogFrame"] = UIPanelWindows["CollectionLogFrame"] or {
      area = "center",
      pushable = 1,
      whileDead = 1,
    }
  end


  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
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

    -- Instance item grid filtering (optional)
    if CollectionLogDB.settings.hideNonCoreLootGrids == nil then
      CollectionLogDB.settings.hideNonCoreLootGrids = false
    end
    if CollectionLogDB.settings.suppressNonCoreLootPopup == nil then
      CollectionLogDB.settings.suppressNonCoreLootPopup = false
    end
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

      -- Hide non-collectables (grids + overview totals)
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Hide non-collectables (jewelry, trinkets, misc, etc.)"
      info.checked = (CollectionLogDB.settings.hideNonCoreLootGrids == true)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.hideNonCoreLootGrids = not (CollectionLogDB.settings.hideNonCoreLootGrids == true)
        -- Clear overview cache so the Overview tab reflects the filter.
        if CollectionLogDB.cache and CollectionLogDB.cache.overview then
          CollectionLogDB.cache.overview["Dungeons"] = nil
          CollectionLogDB.cache.overview["Raids"] = nil
          CollectionLogDB.cache.overview._total = nil
        end
        if UI and UI.RebuildOverviewCacheAsync then UI.RebuildOverviewCacheAsync() end
      end
      UIDropDownMenu_AddButton(info, level)

      -- Pop-up notification submenu
      info = UIDropDownMenu_CreateInfo()
      info.text = "Pop-up notification"
      info.notCheckable = true
      info.hasArrow = true
      info.value = "popup_notification"
      info.menuList = "popup_notification"
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

      -- Disable pop-up for non-collectables
      info = UIDropDownMenu_CreateInfo()
      info.isNotRadio = true
      info.keepShownOnClick = true
      info.notCheckable = false
      info.text = "Disable pop-up for non-collectables"
      info.checked = (CollectionLogDB.settings.suppressNonCoreLootPopup == true)
      info.func = function()
        EnsureSettingsDB()
        CollectionLogDB.settings.suppressNonCoreLootPopup = not (CollectionLogDB.settings.suppressNonCoreLootPopup == true)
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


local list = ns.Data.groupsByCategory[cat] or {}
    -- Force default selection to the first *visible* entry (after filters/sorting) on tab switch.
    CollectionLogDB.ui._forceDefaultGroup = true
    CollectionLogDB.ui.activeGroupId = nil
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

refreshBtn:SetScript("OnClick", function()
  -- Throttled full refresh: repaint current selection + rebuild Overview totals.
  UI._clogLastManualRefresh = (GetTime and GetTime()) or 0

  CLOG_ForceCurrentSelectionRefresh()
  if UI.RequestOverviewRebuild then
    UI.RequestOverviewRebuild("button", true)
  end

  -- Quiet follow-up pass in case Blizzard collection data becomes ready a moment later.
  -- IMPORTANT: Do NOT rebuild the entire grid again here (can cause pets to briefly appear
  -- collected and then flip back if journal/item APIs return different answers across frames).
  -- Instead, just re-check collected state for visible cells.
  if C_Timer and C_Timer.After then
    C_Timer.After(0.25, function()
      if UI.TriggerCollectedRefresh then
        pcall(UI.TriggerCollectedRefresh)
      elseif UI.RefreshVisibleCollectedStateOnly then
        if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_visible_collected", function() pcall(UI.RefreshVisibleCollectedStateOnly) end) else pcall(UI.RefreshVisibleCollectedStateOnly) end
        if UI.RefreshHeaderCountsOnly then pcall(UI.RefreshHeaderCountsOnly) end
      end
    end)

    C_Timer.After(0.35, function()
      if UI.RequestOverviewRebuild then
        -- allow another rebuild regardless of throttle for this one follow-up
        UI._clogOverviewNextRebuild = 0
        UI.RequestOverviewRebuild("buttonFollowup", true)
      end
    end)

    C_Timer.After(0.6, function()
      if refreshBtn.Enable then refreshBtn:Enable() end
    end)
  else
    if refreshBtn.Enable then refreshBtn:Enable() end
  end
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

  -- Layout: 5 category boxes + big total bar + latest row
  local boxW = 135
  local boxH = 135
  local boxPad = 14

  local boxes = {}
  local cats = { "Dungeons", "Raids", "Mounts", "Pets", "Toys" }

  -- Centered 3x2 OSRS-style grid anchor (keeps the whole layout centered and roomy)
  local grid = CreateFrame("Frame", nil, overview)
  UI.overviewGrid = grid
  local gridW = (5 * boxW) + (4 * boxPad)
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
    }

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(40, 40)
    icon:SetPoint("CENTER", b, "CENTER", 0, 6)
    icon:SetTexture(ICONS[cat] or "Interface\\Icons\\inv_misc_questionmark")
    icon:SetDesaturated(true)
    icon:SetAlpha(0.90)
    b._icon = icon

    local lab = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lab:SetPoint("TOP", b, "TOP", 0, -8)
    lab:SetText(cat)

    local bar = MakeOSRSBar(b, boxW-18, 16)
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

        -- Prefer true item hyperlinks when we have them; otherwise fall back to name-only.
        if entry.type == "item" or entry.type == "toy" then
          if entry.itemLink and GameTooltip.SetHyperlink then
            GameTooltip:SetHyperlink(entry.itemLink)
          elseif entry.itemID and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(entry.itemID)
          else
            GameTooltip:SetText(entry.name or "Unknown")
          end
        else
          GameTooltip:SetText(entry.name or "Unknown")
        end

        GameTooltip:Show()
      end)

      btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
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
          if mid and not seen[mid] then
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

      -- Fallback (should rarely be used): count toys from groups using PlayerHasToy.
      if PlayerHasToy then
        local seen = {}
        for _, g2 in ipairs(groups) do
          for _, itemID in ipairs(g2.items or {}) do
            if itemID and not seen[itemID] then
              seen[itemID] = true
              total = total + 1
              if PlayerHasToy(itemID) then collected = collected + 1 end
            end
          end
        end
        return collected, total
      end
    end

    -- Dungeons / Raids: count unique appearance keys (A:<appearanceID>), fall back to item keys.
    local seen = {}
    local hideNC = (CollectionLogDB and CollectionLogDB.settings and CollectionLogDB.settings.hideNonCoreLootGrids == true) and true or false
    for _, g2 in ipairs(groups) do
      for _, itemID in ipairs(g2.items or {}) do
        if hideNC and (not CL_IsCoreLootItemID(itemID)) then
          -- Hidden by settings (non-core loot)
        else
          local key = GetCollectibleKey(itemID)
          if key and not seen[key] then
            seen[key] = itemID or true
          end
        end
      end
    end


    for key, itemID in pairs(seen) do
      total = total + 1
      if type(key) == "string" and key:sub(1,2) == "A:" then
        local aid = tonumber(key:sub(3))
        if IsAppearanceCollectedByID(aid) then collected = collected + 1 end
      end
    end

    return collected, total
  end


  -- Toys: to match the addon’s Toys tab totals (datapack-defined scope),
  -- exclude any generated ToyBox-based groups (group.generated == true).
  local function ComputeToysDatapackProgress()
    local groups = ns and ns.Data and ns.Data.groupsByCategory and ns.Data.groupsByCategory["Toys"] or {}
    local total, collected = 0, 0
    if not PlayerHasToy then
      return 0, 0
    end

    local seen = {}
    for _, g2 in ipairs(groups) do
      if not (g2 and g2.generated) then
        for _, itemID in ipairs(g2.items or {}) do
          if itemID and not seen[itemID] then
            seen[itemID] = true
            total = total + 1
            if PlayerHasToy(itemID) then
              collected = collected + 1
            end
          end
        end
      end
    end
    return collected, total
  end

  -- Overview cache + async rebuild (read-only Overview rendering)
  local function EnsureOverviewCache()
    CollectionLogDB = CollectionLogDB or {}
    CollectionLogDB.cache = CollectionLogDB.cache or {}
    CollectionLogDB.cache.overview = CollectionLogDB.cache.overview or {}
    return CollectionLogDB.cache.overview
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
  end

  -- Throttled, safe Overview rebuild request (used by Refresh button + auto-heal).
  function UI.RequestOverviewRebuild(reason, force)
    local cache = EnsureOverviewCache()
    if cache._building then return end

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
      local ids = C_MountJournal.GetMountIDs()
      if ids then
        local total = #ids
        local collected = 0
        for i = 1, total do
          local mountID = ids[i]
          if mountID then
            local name, spellID, icon, active, usable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected =
              C_MountJournal.GetMountInfoByID(mountID)
            if isCollected then
              collected = collected + 1
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

    -- Pet Journal totals are affected by the user’s Pet Journal filters/search.
    -- Temporarily normalize to an “all pets” view, then restore.
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
        -- Some clients expose a single “all types” toggle.
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

    for _, cat in ipairs(cats) do
      local entry = cache[cat]
      local c = entry and entry.c or 0
      local t = entry and entry.t or 0

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

      sumC = sumC + (c or 0)
      sumT = sumT + (t or 0)

      local b = boxes[cat]
      if b and b._barWrap and b._barWrap._bar then
        local ratio = (t and t > 0) and (c / t) or 0
        b._barWrap._bar:SetMinMaxValues(0, t > 0 and t or 1)
        b._barWrap._bar:SetValue(c)
        ColorBarByRatio(b._barWrap._bar, ratio)
        local countText = ("%d/%d"):format(c or 0, t or 0)
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
        b._barWrap._bar.__clogPercentText = ("%.1f%%"):format((ratio or 0) * 100)
      end
    end

    local ratio = (sumT and sumT > 0) and (sumC / sumT) or 0
    totalWrap._bar:SetMinMaxValues(0, sumT > 0 and sumT or 1)
    totalWrap._bar:SetValue(sumC)
    ColorBarByRatio(totalWrap._bar, ratio)
    local countText = ("%d/%d"):format(sumC, sumT)
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
    totalWrap._bar.__clogPercentText = ("%.1f%%"):format((ratio or 0) * 100)

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

  function UI.RebuildOverviewCacheAsync()
    if not UI.overview then return end
    UI._overviewBuildToken = (UI._overviewBuildToken or 0) + 1
    local token = UI._overviewBuildToken

    local cache = EnsureOverviewCache()
    cache._building = true

    local idx = 1
    local sumC, sumT = 0, 0

    local function step()
      if token ~= UI._overviewBuildToken then return end -- superseded
      local cat = cats[idx]
      if not cat then
        cache._building = nil
        cache._ts = time and time() or 0
        cache._total = { c = sumC, t = sumT, ts = cache._ts }
        RenderOverviewFromCache()
        return
      end

      local c, t
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
      else
        c, t = ComputeCategoryProgress(cat)
      end

      cache[cat] = { c = c or 0, t = t or 0, ts = time and time() or 0 }
      sumC = sumC + (c or 0)
      sumT = sumT + (t or 0)

      idx = idx + 1
      if C_Timer and C_Timer.After then
        C_Timer.After(0, step)
      else
        step()
      end
    end

    step()
  end

  function UI.RefreshOverview()
    if not UI.overview or not UI.overview:IsShown() then return end
    RenderOverviewFromCache()

    local cache = EnsureOverviewCache()
    if cache._building then return end

    -- Auto-heal: if any category is missing OR looks "not ready" (0/0 while we have groups),
    -- request a rebuild. This prevents Overview from getting stuck at 0/0 until a user clicks tabs.
    local needs = false
    for _, cat in ipairs(cats) do
      if not cache[cat] then
        needs = true
        break
      end

      -- Only treat 0/0 as "not ready" for Mounts/Pets/Toys.
      if (cat == "Mounts" or cat == "Pets" or cat == "Toys") then
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
      end
    end

    if needs then
      UI.RequestOverviewRebuild("auto", true)
    end
  end

  function UI.ShowOverview(show)
    if not UI.overview then return end
    if show then
      if listPanel then listPanel:Hide() end
      if right then right:Hide() end
      UI.overview:Show()
      if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_overview", function() UI.RefreshOverview() end) else UI.RefreshOverview() end
    else
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
    s = s:gsub("[’']", ""):gsub("%-", " "):gsub("%s+", " ")
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
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self._lockResetText then
        GameTooltip:AddLine("Locked out", 1, 1, 1)
        GameTooltip:AddLine(("Resets in: %s"):format(self._lockResetText), 0.85, 0.85, 0.85)
    else
        GameTooltip:AddLine("Not locked", 1, 1, 1)
        GameTooltip:AddLine("You can run this difficulty now.", 0.85, 0.85, 0.85)
    end

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
    GameTooltip:AddLine("Open Encounter Journal", 1, 1, 1)
    GameTooltip:AddLine("Jumps to this raid/dungeon in the Encounter Journal.", 0.8, 0.8, 0.8, true)
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

  petsFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  mountsFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  toysFilter:SetPoint("TOPRIGHT", header, "TOPRIGHT", 20, -6)
  petsFilter:Hide()
  mountsFilter:Hide()
  toysFilter:Hide()

  -- Default state (show all) if unset
  if CollectionLogDB and CollectionLogDB.ui then
    if CollectionLogDB.ui.petsShowCollected == nil then CollectionLogDB.ui.petsShowCollected = true end
    if CollectionLogDB.ui.petsShowNotCollected == nil then CollectionLogDB.ui.petsShowNotCollected = true end
    if CollectionLogDB.ui.mountsShowCollected == nil then CollectionLogDB.ui.mountsShowCollected = true end
    if CollectionLogDB.ui.mountsShowNotCollected == nil then CollectionLogDB.ui.mountsShowNotCollected = true end
    if CollectionLogDB.ui.toysShowCollected == nil then CollectionLogDB.ui.toysShowCollected = true end
    if CollectionLogDB.ui.toysShowNotCollected == nil then CollectionLogDB.ui.toysShowNotCollected = true end
  end

  -- Pager UI updater. Called by RefreshGrid() after filtering.
  function UI:UpdatePagerUI(isPetsActive, isMountsActive, isToysActive, isRaidsActive, page, maxPage, startIndex, endIndex, totalItems)
    -- Only show pager for Pets/Mounts/Toys/Raids.
    if not (isPetsActive or isMountsActive or isToysActive or isRaidsActive) then
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
      if (isPetsActive or isMountsActive or isToysActive) and UI.SetFooterLaneEnabled then
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
      if isMountsActive or isPetsActive then
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

    if UI.pagerText then
      UI.pagerText:SetText(string.format("Page %d/%d", page, maxPage))
    end
    if UI.pagerShowing then
      if totalItems > 0 then
        UI.pagerShowing:SetText(string.format("(%d-%d of %d)", startIndex, endIndex, totalItems))
      else
        UI.pagerShowing:SetText("")
      end
    end

    if UI.pagerPrev then UI.pagerPrev:SetEnabled(page > 1) end
    if UI.pagerNext then UI.pagerNext:SetEnabled(page < maxPage) end

    if not pager._wired then
      pager._wired = true
      UI.pagerPrev:SetScript("OnClick", function()
        if not (CollectionLogDB and CollectionLogDB.ui) then return end
        local cat = CollectionLogDB.ui.activeCategory
        if cat == "Pets" then
          CollectionLogDB.ui.petsPage = math.max(1, (CollectionLogDB.ui.petsPage or 1) - 1)
        elseif cat == "Mounts" then
          CollectionLogDB.ui.mountsPage = math.max(1, (CollectionLogDB.ui.mountsPage or 1) - 1)
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
        end
        UIDropDownMenu_AddButton(info, level)
      end
    end)

    -- Set current label
    local curLabel = DifficultyDropdownLabel(g.difficultyID, g.mode)
    UIDropDownMenu_SetText(diff, curLabel)
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

  UI.RefreshAll()
end

function UI.Toggle()
  if not UI.frame then return end

  local function DoToggle()
    if not UI.frame then return end
    if UI.frame:IsShown() then
      UI.frame:Hide()
      return
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
    if UI.RefreshAll then pcall(UI.RefreshAll) end
  end

  if ns and ns.RunOutOfCombat then
    ns.RunOutOfCombat("ui_toggle", DoToggle)
  else
    DoToggle()
  end
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

  local pendingFull = false
  local pendingCollected = false

  local function DebouncedFullRefresh()
    if pendingFull then return end
    pendingFull = true
    C_Timer.After(0.15, function()
      pendingFull = false
      if UI and UI._clogMountCache then UI._clogMountCache = {} end
      if UI and UI._clogPetCache then UI._clogPetCache = {} end
      if ns and ns.ClearFastItemSectionCache then pcall(ns.ClearFastItemSectionCache) end
      if UI and UI.RefreshGrid and UI.frame and UI.frame:IsShown() then
        if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_grid", function() pcall(UI.RefreshGrid) end) else pcall(UI.RefreshGrid) end
      end
    end)
  end

  -- For item/transmog updates, avoid rebuilding the whole grid (expensive and causes
  -- visible reshuffling). Instead, just refresh the visible cells' collected state.
  local function DebouncedCollectedRefresh()
    if pendingCollected then return end
    pendingCollected = true
    C_Timer.After(0.10, function()
      pendingCollected = false
      -- Mount/Pet Journal data can become authoritative slightly after the UI first renders.
      -- If we cached an "unknown" state early, we must allow the next refresh to re-query.
      if UI and UI._clogMountCache then UI._clogMountCache = {} end
      if UI and UI._clogPetCache then UI._clogPetCache = {} end
      if UI and UI.RefreshVisibleCollectedStateOnly and UI.frame and UI.frame:IsShown() then
        if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_visible_collected", function() pcall(UI.RefreshVisibleCollectedStateOnly) end) else pcall(UI.RefreshVisibleCollectedStateOnly) end
      elseif UI and UI.RefreshGrid and UI.frame and UI.frame:IsShown() then
        if ns and ns.RunOutOfCombat then ns.RunOutOfCombat("ui_refresh_grid", function() pcall(UI.RefreshGrid) end) else pcall(UI.RefreshGrid) end
      end
    end)
  end

  f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
      if ns.ClearAllPetJournalFilters then pcall(ns.ClearAllPetJournalFilters) end
      -- Reset per-session default-tab behavior. We always start the first open on Overview,
      -- then remember the user's last-selected tab for subsequent opens in the same session.
      if UI then UI._clogSessionFirstOpenDone = false end
      return
    end
    if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT"
      or event == "TRANSMOG_COLLECTION_UPDATED"
      or event == "TOYS_UPDATED"
      or event == "COMPANION_UPDATE"
      or event == "MOUNT_JOURNAL_LIST_UPDATE"
      or event == "MOUNT_JOURNAL_COLLECTION_UPDATED" then
      -- Item and collection data streams in asynchronously. Refreshing the entire raid/dungeon
      -- grid on every item-data event is expensive and can cause lag. Instead, we refresh the
      -- visible collected state and let the user's manual Refresh (or tab reselect) handle any
      -- rare reclassification cases.
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

  function ns.ShowNewCollectionPopup(itemName, iconPath, kind, meta)
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

    if not (type(meta) == "table" and meta._skipLatest == true) then
      ns.PushLatestCollection(entry)
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

    EnsurePopup()
    if not popup then return end

    if ns and ns.ApplyLootPopupPosition then
      local allowDrag = (type(meta) == "table" and meta.preview == true) and true or false
      ns.ApplyLootPopupPosition(allowDrag)
    end

    -- Text-only popup (OSRS-style) — keep icon hidden.
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

    -- Glow pulse on edges (3 pulses) — slowed down ~50% vs prior version.
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

-- Ensure popup frame exists at addon initialization so test commands always work
local _popupInitFrame = CreateFrame("Frame")
_popupInitFrame:RegisterEvent("ADDON_LOADED")
_popupInitFrame:SetScript("OnEvent", function(_, _, addonName)
  if addonName ~= "CollectionLog" then return end
  EnsurePopup()
  if popup then popup:Hide() end
  _popupInitFrame:UnregisterEvent("ADDON_LOADED")
end)


end


-- Public wrapper used by /cltestpopup (kept stable for testing)

-- Public wrapper used by /cltestpopup (kept stable for testing)
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

-- =====================================

-- Collection Log: Popup Test Command
-- =====================================

function CollectionLog_TestPopup()
    if not CollectionLog_ShowCollectionPopup then
        print("|cffff5555CollectionLog: Collection popup function not found.|r")
        return
    end

    CollectionLog_ShowCollectionPopup({
        name = "Beekeeper's Legs",
        icon = 134586, -- OSRS-ish honeycomb icon
        source = "Test Trigger",
        preview = true,
        isNew = true,
    })
end

SLASH_COLLECTIONLOGTESTPOPUP1 = "/cltestpopup"
SlashCmdList["COLLECTIONLOGTESTPOPUP"] = function()
    CollectionLog_TestPopup()
end