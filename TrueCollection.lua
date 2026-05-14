local ADDON, ns = ...

--[[
TrueCollection is the stable backend-facing API for the rebuilt Collection Log
truth model.  It intentionally does not paint UI, mutate rows, scan EJ, or touch
Refresh behavior.  It only exposes the canonical collectible-only result for a
visible/raw group or normalized group key.

Canonical units:
  mount      -> mount spell/mount identity from Registry/Truth
  pet        -> speciesID
  toy        -> toy itemID
  appearance -> appearanceID
  housing    -> housing decor item/record identity

Non-collectable raw loot is excluded before totals are calculated.
]]

ns.TrueCollection = ns.TrueCollection or {}
local TrueCollection = ns.TrueCollection

local TRUE_SCOPE = "phase2"

function TrueCollection.GetGroupStatus(groupKeyOrGroup)
  local groupKey = groupKeyOrGroup
  if type(groupKeyOrGroup) == "table" and ns.Registry and ns.Registry.GetRawGroupKey then
    groupKey = ns.Registry.GetRawGroupKey(groupKeyOrGroup)
  end
  groupKey = tostring(groupKey or "")
  if groupKey == "" then return nil end
  if not (ns.CompletionV2 and ns.CompletionV2.GetGroupStatus) then return nil end
  return ns.CompletionV2.GetGroupStatus(groupKey, { scope = TRUE_SCOPE })
end

function TrueCollection.GetActiveStatus()
  local groupKey, group = ns.Registry and ns.Registry.ResolveGroup and ns.Registry.ResolveGroup("active") or nil, nil
  if ns.Registry and ns.Registry.ResolveGroup then
    groupKey, group = ns.Registry.ResolveGroup("active")
  end
  if not groupKey then return nil end
  return TrueCollection.GetGroupStatus(groupKey), groupKey, group
end

function TrueCollection.GetPolicyLabel()
  return "true collection: collectible-only, canonical-deduped"
end


function TrueCollection.ClearCache(reason)
  if ns.CompletionV2 and ns.CompletionV2.ClearCache then
    ns.CompletionV2.ClearCache(reason or "true_collection")
  end
end


function TrueCollection.GetItemDefinition(itemID)
  if ns.Registry and ns.Registry.GetItemDefinition then
    return ns.Registry.GetItemDefinition(itemID)
  end
  return nil
end

function TrueCollection.IsItemCollected(itemID, groupOrKey)
  local def
  if groupOrKey and ns.Registry and ns.Registry.GetItemDefinitionForGroup then
    def = ns.Registry.GetItemDefinitionForGroup(itemID, groupOrKey)
  else
    def = TrueCollection.GetItemDefinition(itemID)
  end
  if type(def) ~= "table" then return nil end
  if ns.Truth then
    if ns.Truth.IsExactCollected then
      return ns.Truth.IsExactCollected(def) and true or false, def
    end
    if ns.Truth.IsCollected then
      return ns.Truth.IsCollected(def) and true or false, def
    end
  end
  return nil, def
end
