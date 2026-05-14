-- CollectionLog_GeneratedPack.lua
local ADDON, ns = ...

function ns.RegisterGeneratedPack()
  if not CollectionLogDB then return end

  -- Legacy single generatedPack
  if CollectionLogDB.generatedPack then
    if not CollectionLogDB.generatedPack.groups then CollectionLogDB.generatedPack.groups = {} end
    ns.RegisterPack("generated", CollectionLogDB.generatedPack)
  end

  -- New: multiple generated packs (kept separate, e.g. dungeons_dragonflight)
  if CollectionLogDB.generatedPacks and type(CollectionLogDB.generatedPacks) == "table" then
    for key, pack in pairs(CollectionLogDB.generatedPacks) do
      if type(key) == "string" and type(pack) == "table" then
        pack.groups = pack.groups or {}
        -- namespace the id to avoid collisions with "generated"
        ns.RegisterPack("generated_" .. key, pack)
      end
    end
  end
  if ns.RegisterExternalDataPacks then
    ns.RegisterExternalDataPacks()
  end
end


function ns.RegisterExternalDataPacks()
  if type(CollectionLog_DataPacks) == "table" then
    for key, pack in pairs(CollectionLog_DataPacks) do
      if type(key) == "string" and type(pack) == "table" then
        pack.groups = pack.groups or {}
        ns.RegisterPack("data_" .. key, pack)
      end
    end
  end
  -- Back-compat: older data addon format
  if type(CollectionLog_EJDataPack) == "table" and type(CollectionLog_EJDataPack.groups) == "table" then
    ns.RegisterPack("data_legacy_ej", CollectionLog_EJDataPack)
  end
end


