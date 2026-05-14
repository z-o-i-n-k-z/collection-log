local ADDON, ns = ...

ns.CompletionHousingItemDB = ns.CompletionHousingItemDB or {}
local DB = ns.CompletionHousingItemDB

-- Generated from HouseDecor.12.0.5.66529.csv + ItemSparse.12.0.5.66529.csv, filtered to itemIDs present in raid/dungeon loot datapacks.
DB.byItemID = {
  [238857] = { decorID = 673, decorName = "Moon-Blessed Storage Crate", itemName = "Moon-Blessed Storage Crate", description = "", type = "1", modelType = "1" },
  [241044] = { decorID = 926, decorName = "Argussian Crate", itemName = "Argussian Crate", description = "", type = "1", modelType = "1" },
  [244655] = { decorID = 1445, decorName = "Gilnean Circular Rug", itemName = "Gilnean Circular Rug", description = "", type = "4", modelType = "1" },
  [245434] = { decorID = 1323, decorName = "Orgrimmar Sconce", itemName = "Orgrimmar Sconce", description = "", type = "2", modelType = "1" },
  [245435] = { decorID = 1324, decorName = "Horde Battle Emblem", itemName = "Horde Battle Emblem", description = "", type = "2", modelType = "1" },
  [245451] = { decorID = 1232, decorName = "Thunder Totem Brazier", itemName = "Thunder Totem Brazier", description = "", type = "1", modelType = "1" },
  [245560] = { decorID = 1749, decorName = "Meadery Ochre Window", itemName = "Meadery Ochre Window", description = "", type = "2", modelType = "1" },
  [245681] = { decorID = 1880, decorName = "Tidesage's Fireplace", itemName = "Tidesage's Fireplace", description = "", type = "1", modelType = "1" },
  [245938] = { decorID = 1893, decorName = "Overgrown Arathi Trellis", itemName = "Overgrown Arathi Trellis", description = "", type = "1", modelType = "1" },
  [246421] = { decorID = 2238, decorName = "Stolen Ironforge Seat", itemName = "Stolen Ironforge Seat", description = "", type = "1", modelType = "1" },
  [246429] = { decorID = 2246, decorName = "Dark Iron Chandelier", itemName = "Dark Iron Chandelier", description = "", type = "3", modelType = "1" },
  [246846] = { decorID = 2512, decorName = "Tome of Pandaren Wisdom", itemName = "Tome of Pandaren Wisdom", description = "", type = "1", modelType = "1" },
  [246865] = { decorID = 2531, decorName = "Tome of Reliquary Insights", itemName = "Tome of Reliquary Insights", description = "", type = "1", modelType = "1" },
  [247913] = { decorID = 4027, decorName = "Ornate Suramar Table", itemName = "Ornate Suramar Table", description = "", type = "1", modelType = "1" },
  [248332] = { decorID = 4401, decorName = "Stormwind Footlocker", itemName = "Stormwind Footlocker", description = "", type = "1", modelType = "1" },
  [251331] = { decorID = 8178, decorName = "Draenic Ottoman", itemName = "Draenic Ottoman", description = "", type = "1", modelType = "1" },
  [253242] = { decorID = 9263, decorName = "Horde Warlord's Throne", itemName = "Horde Warlord's Throne", description = "", type = "1", modelType = "1" },
  [253451] = { decorID = 1137, decorName = "Veilroot Fountain", itemName = "Veilroot Fountain", description = "", type = "1", modelType = "1" },
  [255672] = { decorID = 10887, decorName = "Gnomish Tesla Tower", itemName = "Gnomish Tesla Tower", description = "", type = "1", modelType = "1" },
  [256354] = { decorID = 11137, decorName = "Qalashi Goulash", itemName = "Qalashi Goulash", description = "", type = "1", modelType = "1" },
  [256428] = { decorID = 11163, decorName = "Valdrakken Hanging Lamp", itemName = "Valdrakken Hanging Lamp", description = "", type = "3", modelType = "1" },
  [256682] = { decorID = 11283, decorName = "Magistrix's Garden Fountain", itemName = "Magistrix's Garden Fountain", description = "", type = "1", modelType = "1" },
  [256683] = { decorID = 11284, decorName = "Silvermoon Training Dummy", itemName = "Silvermoon Training Dummy", description = "", type = "1", modelType = "1" },
  [258268] = { decorID = 11934, decorName = "Waxmaster's Candle Rack", itemName = "Waxmaster's Candle Rack", description = "", type = "1", modelType = "1" },
  [258744] = { decorID = 12204, decorName = "Skyreach Circular Table", itemName = "Skyreach Circular Table", description = "", type = "1", modelType = "1" },
  [260359] = { decorID = 14330, decorName = "Valdrakken Bookcase", itemName = "Valdrakken Bookcase", description = "", type = "1", modelType = "1" },
  [262957] = { decorID = 14806, decorName = "Tattered Vanguard Banner", itemName = "Tattered Vanguard Banner", description = "", type = "1", modelType = "1" },
  [263230] = { decorID = 15061, decorName = "Magister's Bookshelf", itemName = "Magister's Bookshelf", description = "", type = "1", modelType = "1" },
  [263238] = { decorID = 15069, decorName = "Illicit Long Table", itemName = "Illicit Long Table", description = "", type = "1", modelType = "1" },
  [264187] = { decorID = 15467, decorName = "Blessed Phoenix Egg", itemName = "Blessed Phoenix Egg", description = "", type = "1", modelType = "1" },
  [264246] = { decorID = 15481, decorName = "Eerie Iridescent Riftshroom", itemName = "Eerie Iridescent Riftshroom", description = "", type = "1", modelType = "1" },
  [264332] = { decorID = 15570, decorName = "Amani Ritual Altar", itemName = "Amani Ritual Altar", description = "", type = "1", modelType = "1" },
  [264336] = { decorID = 15574, decorName = "Voidlight Brazier", itemName = "Voidlight Brazier", description = "", type = "1", modelType = "1" },
  [264338] = { decorID = 15576, decorName = "Domanaar Control Console", itemName = "Domanaar Control Console", description = "", type = "1", modelType = "1" },
  [264491] = { decorID = 15755, decorName = "Voidbound Holding Cell", itemName = "Voidbound Holding Cell", description = "", type = "1", modelType = "1" },
  [264492] = { decorID = 15756, decorName = "Chaotic Void Maw", itemName = "Chaotic Void Maw", description = "", type = "1", modelType = "1" },
  [264494] = { decorID = 15758, decorName = "Banded Domanaar Storage Crate", itemName = "Banded Domanaar Storage Crate", description = "", type = "1", modelType = "1" },
  [264497] = { decorID = 15761, decorName = "Imperator's Torment Crystal", itemName = "Imperator's Torment Crystal", description = "", type = "1", modelType = "1" },
  [264498] = { decorID = 15762, decorName = "Voltaic Trigore Egg", itemName = "Voltaic Trigore Egg", description = "", type = "1", modelType = "1" },
  [264500] = { decorID = 15764, decorName = "Devouring Host Ritual Engine", itemName = "", description = "", type = "1", modelType = "1" },
  [264717] = { decorID = 16094, decorName = "Amani Warding Hex", itemName = "Amani Warding Hex", description = "", type = "1", modelType = "1" },
  [265949] = { decorID = 17628, decorName = "March on Quel'Danas Vanquisher's Aureate Trophy", itemName = "March on Quel'Danas Vanquisher's Aureate Trophy", description = "", type = "1", modelType = "1" },
  [265950] = { decorID = 17629, decorName = "Dreamrift Vanquisher's Aureate Trophy", itemName = "Dreamrift Vanquisher's Aureate Trophy", description = "", type = "1", modelType = "1" },
  [265951] = { decorID = 17630, decorName = "Voidspire Vanquisher's Aureate Trophy", itemName = "Voidspire Vanquisher's Aureate Trophy", description = "", type = "1", modelType = "1" },
  [266885] = { decorID = 18396, decorName = "March on Quel'Danas Vanquisher's Gleaming Trophy", itemName = "March on Quel'Danas Vanquisher's Gleaming Trophy", description = "", type = "1", modelType = "1" },
  [266886] = { decorID = 18397, decorName = "Dreamrift Vanquisher's Gleaming Trophy", itemName = "Dreamrift Vanquisher's Gleaming Trophy", description = "", type = "1", modelType = "1" },
  [266887] = { decorID = 18398, decorName = "Voidspire Vanquisher's Gleaming Trophy", itemName = "Voidspire Vanquisher's Gleaming Trophy", description = "", type = "1", modelType = "1" },
  [267007] = { decorID = 18483, decorName = "Eye of Acherus", itemName = "Eye of Acherus", description = "", type = "1", modelType = "1" },
  [267008] = { decorID = 18484, decorName = "Crucible Votive Rack", itemName = "Crucible Votive Rack", description = "", type = "1", modelType = "1" },
  [267645] = { decorID = 19197, decorName = "Dreamrift Vanquisher's Argent Trophy", itemName = "Dreamrift Vanquisher's Argent Trophy", description = "", type = "1", modelType = "1" },
  [267646] = { decorID = 19198, decorName = "March on Quel'Danas Vanquisher's Argent Trophy", itemName = "March on Quel'Danas Vanquisher's Argent Trophy", description = "", type = "1", modelType = "1" },
  [268049] = { decorID = 19252, decorName = "Voidspire Vanquisher's Argent Trophy", itemName = "Voidspire Vanquisher's Argent Trophy", description = "", type = "1", modelType = "1" },
}

function DB.Get(itemID)
  itemID = tonumber(itemID)
  if not itemID then return nil end
  return DB.byItemID and DB.byItemID[itemID] or nil
end

function DB.IterateIDs()
  local ids = {}
  for itemID in pairs(DB.byItemID or {}) do ids[#ids + 1] = itemID end
  table.sort(ids)
  local i = 0
  return function()
    i = i + 1
    if ids[i] then return ids[i] end
  end
end
