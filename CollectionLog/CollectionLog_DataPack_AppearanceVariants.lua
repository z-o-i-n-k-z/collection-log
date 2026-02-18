-- CollectionLog_DataPack_AppearanceVariants.lua
--
-- Optional, static data pack generated offline.
--
-- Goal: deterministic per-difficulty appearance/source mapping to support "1/4" style tracking.
-- The addon must remain functional without this pack.
--
-- Key idea: for a given (instanceID, encounterID, itemID), provide the sourceIDs for each mode.
-- The in-game UI then checks collection state for each sourceID.

local ADDON, ns = ...

ns.DataPacks = ns.DataPacks or {}

ns.DataPacks.AppearanceVariants = ns.DataPacks.AppearanceVariants or {
  meta = {
    pack = "AppearanceVariants",
    version = 1,
    build = "",
    generatedAt = 0,
    source = "",
    modes = { "LFR", "N", "H", "M" },
  },

  -- map["<instanceID>:<encounterID>:<itemID>"] = {
  --   {
  --     appearanceID = 123456, -- optional
  --     sources = {
  --       LFR = { 11111 },
  --       N   = { 22222 },
  --       H   = { 33333 },
  --       M   = { 44444 },
  --     }
  --   },
  -- }
  map = {
    -- empty by default
  },

  -- optional debug metadata
  debug = {
    -- empty by default
  },
}
