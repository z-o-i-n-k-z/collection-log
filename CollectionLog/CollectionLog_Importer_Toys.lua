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

  -- Ensure we are looking at the full Toy Box (collected + uncollected), without filters.
if C_ToyBox.SetCollectedShown then pcall(C_ToyBox.SetCollectedShown, true) end
if C_ToyBox.SetUncollectedShown then pcall(C_ToyBox.SetUncollectedShown, true) end
if C_ToyBox.SetFilterString then pcall(C_ToyBox.SetFilterString, "") end

  -- Prefer the unfiltered master list when available.
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

  -- Fallback: iterate by index.
  if #items == 0 and C_ToyBox.GetToyFromIndex then
    local n = C_ToyBox.GetNumToys()
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

  local group = {
    id = "toys:all",
    name = "All Toys",
    category = "Toys",
    generated = true,
    items = items,
  }

  AddOrReplaceGeneratedGroup(group)

  if ns and ns.RegisterGeneratedPack then
    ns.RegisterGeneratedPack()
  end
  if ns and ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  return group
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


