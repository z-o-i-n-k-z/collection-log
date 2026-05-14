local ADDON, ns = ...

ns.CompletionRaidMounts = ns.CompletionRaidMounts or {}
local CRM = ns.CompletionRaidMounts

-- Explicit, instance-level raid mount definitions for the completion backend.
-- These are intentionally narrow and curated so backend coverage can grow from
-- stable definitions instead of runtime loot-table heuristics.
CRM.byInstance = {
  [74] = { 63041 }, -- Throne of the Four Winds: Reins of the Drake of the South Wind
  [78] = { 71665, 69224 }, -- Firelands: Flametalon of Alysrazor, Pureblood Fire Hawk
  [187] = { 77067, 78919 }, -- Dragon Soul: Blazing Drake, Experiment 12-B
  [317] = { 87777 }, -- Mogu'shan Vaults: Reins of the Astral Cloud Serpent
  [362] = { 93666, 95059 }, -- Throne of Thunder: Spawn of Horridon, Clutch of Ji-Kun
  [369] = { 104253 }, -- Siege of Orgrimmar: Kor'kron Juggernaut
  [457] = { 116660 }, -- Blackrock Foundry: Ironhoof Destroyer
  [669] = { 123890 }, -- Hellfire Citadel: Felsteel Annihilator
  [749] = { 32458 }, -- The Eye: Ashes of Al'ar
  [786] = { 137574 }, -- The Nighthold: Living Infernal Core
  [875] = { 143643 }, -- Tomb of Sargeras: Abyss Worm
  [946] = { 152816 }, -- Antorus, the Burning Throne: Antoran Charhound
  [1176] = { 166518, 166705 }, -- Battle of Dazar'alor: G.M.O.D., Glacial Tidestorm
  [1180] = { 174872 }, -- Ny'alotha, the Waking City: Ny'alotha Allseer
  [1207] = { 210061 }, -- Amirdrassil, the Dream's Hope: Reins of Anu'relos, Flame's Guidance
  [1273] = { 224147, 224151 }, -- Nerub-ar Palace: Sureki / Ascendant Skyrazor
  [1308] = { 246590 }, -- March on Quel'Danas: Ashes of Belo'ren
}

CRM.itemToInstance = CRM.itemToInstance or nil

local function buildReverseIndex()
  local out = {}
  for instanceID, itemIDs in pairs(CRM.byInstance or {}) do
    if type(itemIDs) == 'table' then
      for _, itemID in ipairs(itemIDs) do
        itemID = tonumber(itemID)
        if itemID and itemID > 0 then
          out[itemID] = tonumber(instanceID)
        end
      end
    end
  end
  CRM.itemToInstance = out
end

-- Explicit fallback metadata for raid mount teaching items that are not present
-- in the generated MountItemDB yet. Keep this narrow and curated.
CRM.itemFallbacks = CRM.itemFallbacks or {
  [69224] = {
    itemID = 69224,
    itemName = "Smoldering Egg of Millagazor",
    name = "Pureblood Fire Hawk",
    spellID = 97493,
    mountID = 425,
    sourceText = "|cFFFFD200Drop: |rRagnaros|n|cFFFFD200Zone: |rFirelands",
    sourceType = 0,
  },
}

function CRM.GetFallbackItemInfo(itemID)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  return CRM.itemFallbacks and CRM.itemFallbacks[itemID] or nil
end

function CRM.IsExplicitRaidMountItem(itemID)
  itemID = tonumber(itemID)
  if not itemID then return false end
  if CRM.GetFallbackItemInfo and CRM.GetFallbackItemInfo(itemID) then return true end
  if not CRM.itemToInstance then buildReverseIndex() end
  return CRM.itemToInstance and CRM.itemToInstance[itemID] ~= nil or false
end

function CRM.GetItemIDsForInstance(instanceID)
  instanceID = tonumber(instanceID)
  if not instanceID then return nil end
  return CRM.byInstance and CRM.byInstance[instanceID] or nil
end

function CRM.IsExplicitRaidMount(instanceID, itemID)
  instanceID = tonumber(instanceID)
  itemID = tonumber(itemID)
  if not instanceID or not itemID then return false end
  local itemIDs = CRM.byInstance and CRM.byInstance[instanceID] or nil
  if type(itemIDs) ~= 'table' then return false end
  for _, v in ipairs(itemIDs) do
    if tonumber(v) == itemID then
      return true
    end
  end
  return false
end

function CRM.GetInstanceForItem(itemID)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  if not CRM.itemToInstance then buildReverseIndex() end
  return CRM.itemToInstance and CRM.itemToInstance[itemID] or nil
end
