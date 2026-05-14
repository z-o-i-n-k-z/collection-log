-- CollectionLog_Importer_Pets.lua
local ADDON, ns = ...

-- Minimal, Blizzard-truthful Pets group.
-- Collectible identity: speciesID (C_PetJournal)

local petFrame

local function EnsureCollectionsLoaded()
  -- Pet Journal APIs may not be loaded until Blizzard_Collections is loaded.
  if not (C_PetJournal and C_PetJournal.GetPetInfoByIndex) then
    pcall(LoadAddOn, "Blizzard_Collections")
  end
  return true
end


local function NotifyCollectionsUIUpdated(category)
  if not (ns and ns.UI and ns.UI.frame and ns.UI.frame:IsShown()) then return end
  if ns.UI.BuildGroupList then pcall(ns.UI.BuildGroupList) end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == category then
    if ns.UI.RefreshGrid then pcall(ns.UI.RefreshGrid) end
  end
end

local function UpsertGeneratedGroup(group)
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

local function PurgeGeneratedGroupsForCategory(cat)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups
  for i = #list, 1, -1 do
    local g = list[i]
    if g and (g.category == cat or (cat == "Pets" and type(g.id)=="string" and g.id:find("^pets:"))) then
      table.remove(list, i)
    end
  end
end


local function ExtractSpeciesIDFromGetPetInfoByIndex(r1, r2, r3)
  -- API return order has varied across builds; accept the first numeric return that looks like a speciesID.
  if type(r2) == "number" and r2 > 0 then return r2 end
  if type(r1) == "number" and r1 > 0 then return r1 end
  if type(r3) == "number" and r3 > 0 then return r3 end
  return nil
end

local function GetPetTypeName(petType)
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
  return fallback[petType] or ("Type " .. tostring(petType))
end


local function NormalizeSourceKey(sourceText)
  -- Blizzard returns a free-form localized source string. We normalize this into a small, stable set
  -- of canonical "Source" buckets to avoid dozens/hundreds of one-off sidebar groups.
  if type(sourceText) ~= "string" or sourceText == "" then return nil end
  local s = sourceText:lower()

  -- Common patterns (keep broad + conservative)
  if s:find("vendor") then return "vendor", "Vendor", 210 end
  if s:find("drop") or s:find("drops") then return "drop", "Drop", 220 end
  if s:find("quest") then return "quest", "Quest", 230 end
  if s:find("achievement") then return "achievement", "Achievement", 240 end
  if s:find("reputation") then return "reputation", "Reputation", 250 end
  if s:find("profession") or s:find("crafted") or s:find("crafting") then return "profession", "Profession", 260 end
  if s:find("pet battle") or s:find("battle") and s:find("pet") then return "pet_battle", "Pet Battle", 270 end
  if s:find("mission") or s:find("garrison") or s:find("war table") then return "mission", "Mission", 280 end
  if s:find("promotion") or s:find("tcg") or s:find("promo") then return "promotion", "Promotion", 290 end
  if s:find("store") or s:find("shop") then return "store", "Store", 300 end
  -- Merge 15th/30th/etc anniversary sources into a single stable bucket.
  if s:find("anniversary") then return "anniversary", "Anniversary", 305 end
  if s:find("world event") or s:find("holiday") or s:find("feast") or s:find("hallow") then return "world_event", "World Event", 310 end

  -- Fallback: keep a single "Other" bucket so we don't explode groups.
  return "other", "Other", 900
end

local function TryBuildPetsGroup()
  EnsureCollectionsLoaded()

  -- Purge any previously generated Pets groups so rebuilds don't accumulate stale/duplicate groups.
  PurgeGeneratedGroupsForCategory("Pets")

  if not (C_PetJournal and C_PetJournal.GetPetInfoBySpeciesID) then
    return nil, "Pet Journal API unavailable"
  end

  local pets = {}
  local byType = {}
  local bySource = {}
  local uncategorized = {}


  -- Pet Journal filters can affect index/species iteration on some clients.
  -- To stay fully filter-independent, we probe speciesIDs directly via GetPetInfoBySpeciesID.
  --
  -- IMPORTANT: The full probe can be expensive; we cache the discovered species universe
  -- so subsequent loads are fast and do not risk long stalls/crashes.
  local MAX_SPECIES_ID = 10000

  local cached = CollectionLogDB and CollectionLogDB.cache and CollectionLogDB.cache.petSpeciesIDs
  if type(cached) == "table" and #cached > 0 then
    for i = 1, #cached do
      local speciesID = cached[i]
      local ok2, name, icon, petType, creatureID, sourceText = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
      if ok2 and type(name) == "string" and name ~= "" then
        pets[#pets+1] = speciesID

        if type(petType) == "number" then
          byType[petType] = byType[petType] or {}
          table.insert(byType[petType], speciesID)
        end

        local skey, sname, sidx = NormalizeSourceKey(sourceText)
        if skey then
          bySource[skey] = bySource[skey] or { name = sname, sortIndex = sidx, pets = {} }
          table.insert(bySource[skey].pets, speciesID)
        else
          table.insert(uncategorized, speciesID)
        end
      end
    end
  else
    for speciesID = 1, MAX_SPECIES_ID do
      local ok2, name, icon, petType, creatureID, sourceText = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
      if ok2 and type(name) == "string" and name ~= "" then
        pets[#pets+1] = speciesID

        -- Bucket by type + normalized source (best-effort).
        if type(petType) == "number" then
          byType[petType] = byType[petType] or {}
          table.insert(byType[petType], speciesID)
        end

        local skey, sname, sidx = NormalizeSourceKey(sourceText)
        if skey then
          bySource[skey] = bySource[skey] or { name = sname, sortIndex = sidx, pets = {} }
          table.insert(bySource[skey].pets, speciesID)
        else
          table.insert(uncategorized, speciesID)
        end
      end
    end
  end


  if #pets == 0 then
    return nil, "Pet Journal returned 0 species"
  end

  table.sort(pets)

  -- Cache the discovered species universe + a fast total for the Overview tab.
  if CollectionLogDB then
    CollectionLogDB.cache = CollectionLogDB.cache or {}
    CollectionLogDB.cache.petSpeciesIDs = pets

    local owned = 0
    if C_PetJournal and C_PetJournal.GetNumCollectedInfo then
      for i = 1, #pets do
        local sid = pets[i]
        local okc, numOwned = pcall(C_PetJournal.GetNumCollectedInfo, sid)
        if okc and type(numOwned) == "number" and numOwned > 0 then
          owned = owned + 1
        end
      end
    end

    CollectionLogDB.cache.petTotals = {
      c = owned,
      t = #pets,
      ts = (time and time()) or 0,
    }
  end


  -- Base group
  UpsertGeneratedGroup({
    id = "pets:all",
    name = "All Pets",
    category = "Pets",
    expansion = "Account",
    sortIndex = 1,
    pets = pets,
  })

  -- Type groups (structured)
  for petType, list in pairs(byType) do
    table.sort(list)
    UpsertGeneratedGroup({
      id = "pets:type:" .. tostring(petType),
      name = GetPetTypeName(petType),
      category = "Pets",
      expansion = "Type",
      sortIndex = 100 + (tonumber(petType) or 0),
      pets = list,
    })
  end

    -- Uncategorized source group (for pets without Blizzard source text)
  if uncategorized and #uncategorized > 0 then
    table.sort(uncategorized)
    UpsertGeneratedGroup({
      id = "pets:source:uncategorized",
      name = "Uncategorized",
      category = "Pets",
      expansion = "Source",
      sortIndex = 950,
      pets = uncategorized,
    })
  end

-- Source groups (Blizzard label; free-form text)
  for skey, entry in pairs(bySource) do
    local list = entry.pets
    if list and #list > 0 then
      table.sort(list)
      UpsertGeneratedGroup({
        id = "pets:source:" .. skey,
        name = entry.name or skey,
        category = "Pets",
        expansion = "Source",
        sortIndex = (type(entry.sortIndex)=="number" and entry.sortIndex or 900),
        pets = list,
      })
    end
  end


  -- ============================================================
  -- User overrides (Pets): Primary Source + Extra Source tags
  -- Apply LAST so rebuilds never overwrite user decisions.
  -- ============================================================
  do
    if CollectionLogDB then
      CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
      local uo = CollectionLogDB.userOverrides
      uo.pets = uo.pets or {}
      if not uo.pets.primary then uo.pets.primary = {} end
      if not uo.pets.extra then uo.pets.extra = {} end

      local groups = CollectionLogDB.generatedPack and CollectionLogDB.generatedPack.groups
      if type(groups) == "table" then
        -- Build an index of Source groups by name (and ensure the target group exists).
        local sourceGroupsByName = {}
        local function EnsureSourceGroupByName(name)
          if type(name) ~= "string" or name == "" then name = "Uncategorized" end
          if sourceGroupsByName[name] then return sourceGroupsByName[name] end
          local key = name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
          key = key:gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
          if key == "" then key = "uncategorized" end
          local id = "pets:source:" .. key

          -- find existing
          for _, g in ipairs(groups) do
            if g and g.id == id then
              sourceGroupsByName[name] = g
              return g
            end
          end

          -- create new
          local g = { id = id, name = name, category = "Pets", expansion = "Source", pets = {} }
          table.insert(groups, g)
          sourceGroupsByName[name] = g
          return g
        end

        -- collect current source groups
        for _, g in ipairs(groups) do
          if g and g.category == "Pets" and g.expansion == "Source" and type(g.name) == "string" then
            sourceGroupsByName[g.name] = g
          end
        end

        local function RemoveFromAllSourceGroups(speciesID)
          for _, g in ipairs(groups) do
            if g and g.category == "Pets" and g.expansion == "Source" and type(g.pets) == "table" then
              for i = #g.pets, 1, -1 do
                if g.pets[i] == speciesID then
                  table.remove(g.pets, i)
                end
              end
            end
          end
        end

        local function AddToGroupUnique(g, speciesID)
          if not g or type(g.pets) ~= "table" then return end
          for _, v in ipairs(g.pets) do
            if v == speciesID then return end
          end
          table.insert(g.pets, speciesID)
        end

        -- Apply primary overrides: move between Source groups only.
        for k, targetName in pairs(uo.pets.primary) do
          local sid = tonumber(k)
          if sid then
            RemoveFromAllSourceGroups(sid)
            local dest = EnsureSourceGroupByName(targetName)
            AddToGroupUnique(dest, sid)
          end
        end

        -- Apply extra tags: add to additional Source groups (no removal)
        for k, extras in pairs(uo.pets.extra) do
          local sid = tonumber(k)
          if sid and type(extras) == "table" then
            for targetName, enabled in pairs(extras) do
              if enabled then
                local dest = EnsureSourceGroupByName(targetName)
                AddToGroupUnique(dest, sid)
              end
            end
          end
        end

        -- Sort source group lists for stable UI
        for _, g in ipairs(groups) do
          if g and g.category == "Pets" and g.expansion == "Source" and type(g.pets) == "table" then
            table.sort(g.pets)
          end
        end
      end
    end
  end

  if ns and ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end

  NotifyCollectionsUIUpdated("Pets")

  return true, nil
end


local function EnsurePetsEventFrame()
  if petFrame then return end
  petFrame = CreateFrame("Frame")
  petFrame:SetScript("OnEvent", function(self)
    local g = TryBuildPetsGroup()
    if g then
      self:UnregisterAllEvents()
    end
  end)
end

function ns.EnsurePetsGroups()
  local g = TryBuildPetsGroup()
  if g then
    return g
  end

  -- If the Pet Journal isn't ready yet, wait for Blizzard to populate it.
  EnsurePetsEventFrame()
  petFrame:RegisterEvent("PET_JOURNAL_LIST_UPDATE")
  -- Some builds use a different update event; harmless if it never fires.
  petFrame:RegisterEvent("PET_JOURNAL_PET_LIST_UPDATE")

  return nil
end
