local ADDON, ns = ...

ns.NameResolver = ns.NameResolver or {}
local NR = ns.NameResolver

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function db()
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.nameCache = CollectionLogDB.nameCache or {}
  CollectionLogDB.nameCache.items = CollectionLogDB.nameCache.items or {}
  CollectionLogDB.nameCache.appearances = CollectionLogDB.nameCache.appearances or {}
  return CollectionLogDB.nameCache
end

NR._itemQueue = NR._itemQueue or {}
NR._itemQueued = NR._itemQueued or {}
NR._itemLoading = NR._itemLoading or {}
NR._tickerActive = NR._tickerActive or false
NR._processed = NR._processed or 0
NR._resolved = NR._resolved or 0
NR._failed = NR._failed or 0

local function setItemName(itemID, name)
  itemID = asNumber(itemID)
  if not itemID or type(name) ~= "string" or name == "" then return nil end
  db().items[tostring(itemID)] = name
  NR._resolved = (NR._resolved or 0) + 1
  return name
end

local function getCachedItemName(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  local cached = db().items[tostring(itemID)]
  if type(cached) == "string" and cached ~= "" then return cached end
  return nil
end

local function getLiveItemName(itemID)
  itemID = asNumber(itemID)
  if not itemID then return nil end

  if C_Item and C_Item.GetItemInfo then
    local ok, info = pcall(C_Item.GetItemInfo, itemID)
    if ok then
      if type(info) == "table" and type(info.itemName) == "string" and info.itemName ~= "" then return info.itemName end
      if type(info) == "string" and info ~= "" then return info end
    end
  end

  if GetItemInfo then
    local ok, name = pcall(GetItemInfo, itemID)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return nil
end

local function finishItem(itemID, name)
  itemID = asNumber(itemID)
  if not itemID then return end
  NR._itemLoading[itemID] = nil
  NR._itemQueued[itemID] = nil
  name = name or getLiveItemName(itemID)
  if name then
    setItemName(itemID, name)
  else
    NR._failed = (NR._failed or 0) + 1
  end
end

local function requestItemLoad(itemID)
  itemID = asNumber(itemID)
  if not itemID then return end
  if getCachedItemName(itemID) or NR._itemLoading[itemID] then return end

  local live = getLiveItemName(itemID)
  if live then
    finishItem(itemID, live)
    return
  end

  NR._itemLoading[itemID] = true
  NR._processed = (NR._processed or 0) + 1

  if Item and Item.CreateFromItemID then
    local ok, item = pcall(Item.CreateFromItemID, itemID)
    if ok and item and item.ContinueOnItemLoad then
      item:ContinueOnItemLoad(function()
        finishItem(itemID, getLiveItemName(itemID))
      end)
      return
    end
  end

  if C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, itemID)
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(0.75, function() finishItem(itemID, getLiveItemName(itemID)) end)
  else
    finishItem(itemID, getLiveItemName(itemID))
  end
end

local function pump()
  local perTick = 25
  local processed = 0
  while processed < perTick and #NR._itemQueue > 0 do
    local itemID = table.remove(NR._itemQueue, 1)
    if itemID and not getCachedItemName(itemID) then
      requestItemLoad(itemID)
      processed = processed + 1
    end
  end

  if #NR._itemQueue > 0 then
    if C_Timer and C_Timer.After then
      C_Timer.After(0.05, pump)
    else
      NR._tickerActive = false
    end
  else
    NR._tickerActive = false
  end
end

function NR.QueueItem(itemID)
  itemID = asNumber(itemID)
  if not itemID then return false end
  if getCachedItemName(itemID) then return true end

  local live = getLiveItemName(itemID)
  if live then
    setItemName(itemID, live)
    return true
  end

  if not NR._itemQueued[itemID] and not NR._itemLoading[itemID] then
    NR._itemQueued[itemID] = true
    NR._itemQueue[#NR._itemQueue + 1] = itemID
  end
  if not NR._tickerActive then
    NR._tickerActive = true
    if C_Timer and C_Timer.After then C_Timer.After(0.01, pump) else pump() end
  end
  return false
end

function NR.GetItemName(itemID, queue)
  itemID = asNumber(itemID)
  if not itemID then return nil end
  local cached = getCachedItemName(itemID)
  if cached then return cached end
  local live = getLiveItemName(itemID)
  if live then return setItemName(itemID, live) end
  if queue then NR.QueueItem(itemID) end
  return nil
end

function NR.GetDefinitionName(def, queue)
  if type(def) ~= "table" then return nil end
  if type(def.name) == "string" and def.name ~= "" and def.name ~= "?" then return def.name end
  local itemID = asNumber(def.itemID)
  if itemID then
    local name = NR.GetItemName(itemID, queue)
    if name then
      def.name = name
      return name
    end
  end
  return nil
end

function NR.QueueDefinitions(defs, limit)
  limit = tonumber(limit or 250) or 250
  local queued = 0
  for i = 1, #(defs or {}) do
    local def = defs[i]
    local itemID = type(def) == "table" and asNumber(def.itemID) or nil
    if itemID and not NR.GetItemName(itemID, false) then
      NR.QueueItem(itemID)
      queued = queued + 1
      if queued >= limit then break end
    end
  end
  return queued
end

function NR.Status()
  return {
    queued = #(NR._itemQueue or {}),
    loading = (function()
      local n = 0
      for _ in pairs(NR._itemLoading or {}) do n = n + 1 end
      return n
    end)(),
    processed = NR._processed or 0,
    resolved = NR._resolved or 0,
    failed = NR._failed or 0,
  }
end

SLASH_COLLECTIONLOGNAMES1 = "/clognames"
SlashCmdList.COLLECTIONLOGNAMES = function(msg)
  msg = tostring(msg or "")
  local status = NR.Status()
  if msg:lower():find("status", 1, true) or msg == "" then
    local printFn = ns.Print or print
    printFn(("Name resolver: queued=%d loading=%d processed=%d resolved=%d failed=%d"):format(status.queued or 0, status.loading or 0, status.processed or 0, status.resolved or 0, status.failed or 0))
    return
  end
end
