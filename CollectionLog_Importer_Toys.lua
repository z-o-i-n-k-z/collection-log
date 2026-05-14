-- CollectionLog_Importer_Toys.lua
local ADDON, ns = ...

-- Blizzard-truthful Toys group.
-- Collectible identity: itemID (Toy Box)

local toyFrame

local function EnsureCollectionsLoaded()
  -- Toy Box APIs live under Blizzard_Collections.
  if not (C_ToyBox and C_ToyBox.GetNumToys) then
    pcall(LoadAddOn, "Blizzard_Collections")
  end
end

local function PurgeGeneratedGroupsForCategory(cat)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups

  for i = #list, 1, -1 do
    local g = list[i]
    if g and g.generated and g.category == cat then
      table.remove(list, i)
    end
  end
end

local function AddOrReplaceGeneratedGroup(group)
  if not group or not group.id then return end
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups

  for i = #list, 1, -1 do
    if list[i] and list[i].id == group.id then
      list[i] = group
      return
    end
  end

  table.insert(list, group)
end


local function TryBuildToysGroup()
  EnsureCollectionsLoaded()
  if not (C_ToyBox and C_ToyBox.GetNumToys and (C_ToyBox.GetToyIDs or C_ToyBox.GetToyFromIndex)) then
    return nil
  end

  -- Helper: pull current visible Toy Box IDs under current filters.
  local function GetCurrentToyIDs()
    local items = {}
    if C_ToyBox.GetToyIDs then
      local ids = C_ToyBox.GetToyIDs()
      if type(ids) == "table" and #ids > 0 then
        for i = 1, #ids do
          local itemID = ids[i]
          if itemID and itemID > 0 then
            items[#items + 1] = itemID
          end
        end
      end
    end

    if #items == 0 and C_ToyBox.GetToyFromIndex then
      local n = (C_ToyBox.GetNumFilteredToys and C_ToyBox.GetNumFilteredToys()) or C_ToyBox.GetNumToys()
      if type(n) ~= "number" or n <= 0 then
        return nil
      end
      for i = 1, n do
        local itemID = C_ToyBox.GetToyFromIndex(i)
        if itemID and itemID > 0 then
          items[#items + 1] = itemID
        end
      end
    end

    if #items == 0 then
      return nil
    end

    table.sort(items)
    return items
  end

  -- Save / restore Toy Box filters (best effort; APIs vary by client)
  local prev = {
    filterString = nil,
    collected = nil,
    uncollected = nil,
    source = {},
    expansion = {},
  }

  if C_ToyBox.GetFilterString then
    prev.filterString = C_ToyBox.GetFilterString()
  end
  if C_ToyBox.GetCollectedShown then
    prev.collected = C_ToyBox.GetCollectedShown()
  end
  if C_ToyBox.GetUncollectedShown then
    prev.uncollected = C_ToyBox.GetUncollectedShown()
  end

  local numSource = (C_ToyBox.GetNumSourceTypes and C_ToyBox.GetNumSourceTypes()) or 0
  if numSource > 0 and C_ToyBox.GetSourceTypeFilter then
    for i = 1, numSource do
      prev.source[i] = C_ToyBox.GetSourceTypeFilter(i)
    end
  end

  local numExp = (C_ToyBox.GetNumExpansionTypes and C_ToyBox.GetNumExpansionTypes()) or 0
  if numExp > 0 and C_ToyBox.GetExpansionTypeFilter then
    for i = 1, numExp do
      prev.expansion[i] = C_ToyBox.GetExpansionTypeFilter(i)
    end
  end

  local function RestoreFilters()
    if C_ToyBox.SetFilterString and prev.filterString ~= nil then pcall(C_ToyBox.SetFilterString, prev.filterString) end
    if C_ToyBox.SetCollectedShown and prev.collected ~= nil then pcall(C_ToyBox.SetCollectedShown, prev.collected) end
    if C_ToyBox.SetUncollectedShown and prev.uncollected ~= nil then pcall(C_ToyBox.SetUncollectedShown, prev.uncollected) end
    if numSource > 0 and C_ToyBox.SetSourceTypeFilter then
      for i = 1, numSource do
        if prev.source[i] ~= nil then pcall(C_ToyBox.SetSourceTypeFilter, i, prev.source[i]) end
      end
    end
    if numExp > 0 and C_ToyBox.SetExpansionTypeFilter then
      for i = 1, numExp do
        if prev.expansion[i] ~= nil then pcall(C_ToyBox.SetExpansionTypeFilter, i, prev.expansion[i]) end
      end
    end
  end

  -- Make sure we are looking at the full Toy Box (collected + uncollected), no search string.
  if C_ToyBox.SetCollectedShown then pcall(C_ToyBox.SetCollectedShown, true) end
  if C_ToyBox.SetUncollectedShown then pcall(C_ToyBox.SetUncollectedShown, true) end
  if C_ToyBox.SetFilterString then pcall(C_ToyBox.SetFilterString, "") end

  -- Helper: slugify for deterministic IDs
  local function Slug(s)
    s = tostring(s or ""):lower()
    s = s:gsub("[^%w]+", "_")
    s = s:gsub("^_+", ""):gsub("_+$", "")
    return s
  end

  -- ============================================================
  -- Group 1: All Toys
  -- ============================================================
  local allItems = GetCurrentToyIDs()
  if not allItems then
    RestoreFilters()
    return nil
  end

  local allGroup = {
    id = "toys:all",
    name = "All Toys",
    category = "Toys",
    generated = true,
    items = allItems,
  }
  AddOrReplaceGeneratedGroup(allGroup)

  -- ============================================================
  -- Group 2: Source buckets (Blizzard Toy Box filters)
  -- ============================================================
  -- Blizzard ordering from the Toy Box filter menu:
  local SOURCE_NAMES = {
    "Drop",
    "Quest",
    "Vendor",
    "Profession",
    "Pet Battle",
    "Achievement",
    "World Event",
    "Promotion",
    "In-Game Shop",
    "Discovery",
    "Trading Post",
  }

  if numSource == 0 then numSource = #SOURCE_NAMES end

  if numSource > 0 and C_ToyBox.SetSourceTypeFilter then
    -- Turn all source filters OFF, then enable one at a time.
    for i = 1, numSource do
      pcall(C_ToyBox.SetSourceTypeFilter, i, false)
    end

    for i = 1, numSource do
      -- Enable only this source type
      pcall(C_ToyBox.SetSourceTypeFilter, i, true)
      local ids = GetCurrentToyIDs()
      -- Disable again for next iteration
      pcall(C_ToyBox.SetSourceTypeFilter, i, false)

      if ids and #ids > 0 then
        local name = SOURCE_NAMES[i] or ("Source " .. tostring(i))
        local group = {
          id = "toys:source:" .. Slug(name),
          name = name,
          category = "Toys",
          generated = true,
          sortIndex = i, -- preserves Toy Box order
          items = ids,
        }
        AddOrReplaceGeneratedGroup(group)
      end
    end

    -- Restore all sources ON for subsequent expansion grouping
    for i = 1, numSource do
      pcall(C_ToyBox.SetSourceTypeFilter, i, true)
    end
  end

  -- ============================================================
  -- Group 3: Expansion buckets (Blizzard Toy Box filters)
  -- ============================================================
  -- We map expansion filter indices (when present) onto canonical names.
  -- If the client exposes 12+ expansion types, the last two are assumed to be
  -- The War Within and Midnight in that order (newest -> oldest ordering is handled in UI via sortIndex).
  local EXPANSION_NAMES = {
    "Classic",
    "The Burning Crusade",
    "Wrath of the Lich King",
    "Cataclysm",
    "Mists of Pandaria",
    "Warlords of Draenor",
    "Legion",
    "Battle for Azeroth",
    "Shadowlands",
    "Dragonflight",
    "The War Within",
    "Midnight",
  }

  if numExp == 0 then numExp = #EXPANSION_NAMES end

  local function ExpansionRank(name)
    -- Newest -> oldest rank (Midnight 1 ...)
    if name == "Midnight" then return 1 end
    if name == "The War Within" then return 2 end
    if name == "Dragonflight" then return 3 end
    if name == "Shadowlands" then return 4 end
    if name == "Battle for Azeroth" then return 5 end
    if name == "Legion" then return 6 end
    if name == "Warlords of Draenor" then return 7 end
    if name == "Mists of Pandaria" then return 8 end
    if name == "Cataclysm" then return 9 end
    if name == "Wrath of the Lich King" then return 10 end
    if name == "The Burning Crusade" then return 11 end
    if name == "Classic" then return 12 end
    return 999
  end

  if numExp > 0 and C_ToyBox.SetExpansionTypeFilter then
    -- Turn all expansion filters OFF, then enable one at a time.
    for i = 1, numExp do
      pcall(C_ToyBox.SetExpansionTypeFilter, i, false)
    end

    for i = 1, numExp do
      pcall(C_ToyBox.SetExpansionTypeFilter, i, true)
      local ids = GetCurrentToyIDs()
      pcall(C_ToyBox.SetExpansionTypeFilter, i, false)

      if ids and #ids > 0 then
        local name = EXPANSION_NAMES[i] or ("Expansion " .. tostring(i))
        local rank = ExpansionRank(name)
        local group = {
          id = "toys:exp:" .. Slug(name),
          name = name,
          category = "Toys",
          generated = true,
          expansion = name,
          -- sortIndex: larger = newer (UI sorts desc)
          sortIndex = (rank == 999) and i or (100 - rank),
          items = ids,
        }
        AddOrReplaceGeneratedGroup(group)
      end
    end

    -- Restore all expansions ON
    for i = 1, numExp do
      pcall(C_ToyBox.SetExpansionTypeFilter, i, true)
    end
  end

  -- Register / rebuild
  if ns and ns.RegisterGeneratedPack then
    ns.RegisterGeneratedPack()
  end
  if ns and ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  RestoreFilters()
  return allGroup
end
local function EnsureToysEventFrame()
  if toyFrame then return end
  toyFrame = CreateFrame("Frame")
  toyFrame:SetScript("OnEvent", function(self)
    local g = TryBuildToysGroup()
    if g then
      self:UnregisterAllEvents()
    end
  end)
end

function ns.EnsureToysGroups()
  -- Readiness gate: Toy Box can report 0 toys briefly on login even though APIs exist.
  if not (C_ToyBox and C_ToyBox.GetNumToys) then
    return nil
  end

  local numToys = C_ToyBox.GetNumToys()
  if not numToys or numToys == 0 then
    -- Do not purge/rebuild while Toy Box is "cold".
    EnsureToysEventFrame()
    toyFrame:RegisterEvent("TOYS_UPDATED")
    toyFrame:RegisterEvent("TOYBOX_UPDATED")
    toyFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    return nil
  end

  -- Debounce: avoid rebuilding repeatedly within a short window.
  ns._clogToysBuiltCount = ns._clogToysBuiltCount or 0
  ns._clogToysBuiltAt = ns._clogToysBuiltAt or 0
  local now = (GetTime and GetTime()) or 0
  if ns._clogToysBuiltCount == numToys and (now - ns._clogToysBuiltAt) < 5 then
    return true
  end

  -- Purge/rebuild so the toy list stays current.
  PurgeGeneratedGroupsForCategory("Toys")

  local g = TryBuildToysGroup()
  if g then
    ns._clogToysBuiltCount = numToys
    ns._clogToysBuiltAt = (GetTime and GetTime()) or 0
    NotifyCollectionsUIUpdated("Toys")
    return g
  end

  -- If Toy Box isn't ready yet, wait for it to populate.
  EnsureToysEventFrame()
  toyFrame:RegisterEvent("TOYS_UPDATED")
  toyFrame:RegisterEvent("TOYBOX_UPDATED")
  toyFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

  return nil
end
local function NotifyCollectionsUIUpdated(category)
  if not (ns and ns.UI and ns.UI.frame and ns.UI.frame:IsShown()) then return end
  if ns.UI.BuildGroupList then pcall(ns.UI.BuildGroupList) end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == category then
    if ns.UI.RefreshGrid then pcall(ns.UI.RefreshGrid) end
  end
end

