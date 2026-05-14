-- CollectionLog_DataPack_MountSourceOverrides.lua
-- Explicit, offline-authored mount source label overrides.
-- This is NOT collected-state logic; it only affects grouping labels.
-- Keep this list small and intentional.
local ADDON, ns = ...

ns.DataPacks = ns.DataPacks or {}
ns.DataPacks.MountSourceOverrides = {
  meta = {
    pack = "MountSourceOverrides",
    version = 1,
    build = "12.0.x",
    generatedAt = 0,
    source = "core:manual_overrides",
  },

  -- Keyed by Mount Journal mountID
  map = {
    -- Royal Voidwing: treated as Achievement for grouping purposes (Blizzard labels as Quest).
    [2606] = "Achievement",

    -- Trader's Gilded Brutosaur: guard against sourceType enum drift (ensure Store).
    [2265] = "Store",
  },
}
