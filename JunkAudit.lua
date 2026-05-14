local ADDON, ns = ...

ns.JunkAudit = ns.JunkAudit or {}
local JunkAudit = ns.JunkAudit

local function Print(msg)
  if ns and ns.Print then ns.Print(msg) else print("Collection Log: " .. tostring(msg)) end
end

local function trim(s)
  return (tostring(s or ""):match("^%s*(.-)%s*$")) or ""
end

local function lower(s)
  return tostring(s or ""):lower()
end

local function asNumber(v)
  v = tonumber(v)
  if v and v > 0 then return v end
  return nil
end

local function itemName(itemID)
  if GetItemInfo then
    local ok, name = pcall(GetItemInfo, itemID)
    if ok and name and name ~= "" then return name end
  end
  return "item:" .. tostring(itemID or "?")
end

local function rawItemListForGroup(group)
  local out, seen = {}, {}
  if type(group) ~= "table" then return out end
  local function add(v)
    local id = asNumber(v)
    if id and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  if type(group.items) == "table" then for _, id in ipairs(group.items) do add(id) end end
  if type(group.itemIDs) == "table" then for _, id in ipairs(group.itemIDs) do add(id) end end
  if #out == 0 and type(group.itemLinks) == "table" then for _, id in ipairs(group.itemLinks) do add(id) end end
  table.sort(out)
  return out
end

local function isCollectibleItem(itemID)
  if not itemID then return false, nil end
  local def = ns.Registry and ns.Registry.GetItemDefinition and ns.Registry.GetItemDefinition(itemID) or nil
  if def and def.type and def.type ~= "unknown" and asNumber(def.collectibleID or def.itemID) then
    return true, def
  end
  return false, def
end

local TOKEN_WORDS = {
  "gauntlets of", "crown of", "leggings of", "chest of", "shoulders of",
  "helm of", "helmet of", "gloves of", "robes of", "mantle of",
  "protector", "conqueror", "vanquisher", "token",
}

local function classifyJunk(itemID)
  local secFast = ns.GetItemSectionFast and ns.GetItemSectionFast(itemID) or nil
  local secFull = ns.GetItemSection and ns.GetItemSection(itemID) or nil
  local section = secFull or secFast or "Unknown"
  local name = itemName(itemID)
  local lname = lower(name)

  local reason = "unknown/no collectible mapping"
  if section == "Trinkets" then
    reason = "trinket"
  elseif section == "Jewelry" then
    reason = "jewelry"
  elseif section == "Misc" then
    reason = "misc/non-collectible"
  elseif section == "Weapons" or section == "Armor" then
    reason = "equipment without appearance mapping"
  end

  for _, word in ipairs(TOKEN_WORDS) do
    if lname:find(word, 1, true) then
      reason = "tier/token without direct collectible mapping"
      break
    end
  end

  return {
    itemID = itemID,
    name = name,
    section = section,
    secFast = secFast or "?",
    secFull = secFull or "?",
    reason = reason,
  }
end

local function groupLabel(group)
  if type(group) ~= "table" then return "?" end
  return ("%s [%s:%s:%s]"):format(tostring(group.name or "?"), tostring(group.category or "?"), tostring(group.instanceID or "?"), tostring(group.difficultyID or "?"))
end

local function auditGroup(group)
  local items = rawItemListForGroup(group)
  local out = {
    group = group,
    raw = #items,
    collectible = 0,
    junk = 0,
    junkItems = {},
    collectibleKinds = {},
    junkReasons = {},
  }

  for _, itemID in ipairs(items) do
    local ok, def = isCollectibleItem(itemID)
    if ok then
      out.collectible = out.collectible + 1
      local k = tostring(def and def.type or "collectible")
      out.collectibleKinds[k] = (out.collectibleKinds[k] or 0) + 1
    else
      out.junk = out.junk + 1
      local row = classifyJunk(itemID)
      out.junkItems[#out.junkItems + 1] = row
      out.junkReasons[row.reason] = (out.junkReasons[row.reason] or 0) + 1
    end
  end

  return out
end

local function kindLine(t)
  local order = { "mount", "pet", "toy", "housing", "appearance" }
  local parts, seen = {}, {}
  for _, k in ipairs(order) do
    if t[k] then parts[#parts + 1] = k .. "=" .. tostring(t[k]); seen[k] = true end
  end
  local extras = {}
  for k in pairs(t or {}) do if not seen[k] then extras[#extras + 1] = k end end
  table.sort(extras)
  for _, k in ipairs(extras) do parts[#parts + 1] = k .. "=" .. tostring(t[k]) end
  return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function printGroupAudit(audit, opts)
  opts = type(opts) == "table" and opts or {}
  local limit = tonumber(opts.limit or 25) or 25
  Print(("Junk audit: %s"):format(groupLabel(audit.group)))
  Print(("  raw=%d collectible=%d junk=%d"):format(audit.raw or 0, audit.collectible or 0, audit.junk or 0))
  Print("  collectible kinds: " .. kindLine(audit.collectibleKinds))
  Print("  junk reasons: " .. kindLine(audit.junkReasons))

  if audit.junk == 0 then
    Print("  junk items: none")
    return
  end

  Print("  junk items (showing up to " .. tostring(limit) .. "):")
  for i = 1, math.min(#audit.junkItems, limit) do
    local r = audit.junkItems[i]
    Print(("    item=%s section=%s reason=%s name=%s"):format(tostring(r.itemID), tostring(r.section), tostring(r.reason), tostring(r.name)))
  end
  if #audit.junkItems > limit then
    Print("    ...and " .. tostring(#audit.junkItems - limit) .. " more junk items")
  end
end

local function activeGroup()
  local groupId = CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeGroupId
  local groups = ns and ns.Data and ns.Data.groups or nil
  if not (groupId and type(groups) == "table") then return nil end
  return groups[groupId] or groups[tonumber(groupId) or -1]
end

local function allGroups(scope)
  local groups = ns and ns.Data and ns.Data.groups or nil
  local out = {}
  scope = lower(scope)
  if type(groups) ~= "table" then return out end
  for _, group in pairs(groups) do
    if type(group) == "table" and (type(group.items) == "table" or type(group.itemIDs) == "table" or type(group.itemLinks) == "table") then
      local cat = lower(group.category)
      local include = false
      if scope == "raids" then include = cat == "raids" or cat == "raid" end
      if scope == "dungeons" then include = cat == "dungeons" or cat == "dungeon" end
      if scope == "all" or scope == "" then include = (cat == "raids" or cat == "raid" or cat == "dungeons" or cat == "dungeon") end
      if include then out[#out + 1] = group end
    end
  end
  table.sort(out, function(a, b)
    local ca, cb = tostring(a.category or ""), tostring(b.category or "")
    if ca ~= cb then return ca < cb end
    local na, nb = tostring(a.name or ""), tostring(b.name or "")
    if na ~= nb then return na < nb end
    return tostring(a.id or "") < tostring(b.id or "")
  end)
  return out
end

local function printAll(scope, opts)
  local groups = allGroups(scope)
  local totalGroups, groupsWithJunk, raw, collectible, junk = 0, 0, 0, 0, 0
  local reasonTotals, kindTotals, worst = {}, {}, {}

  for _, group in ipairs(groups) do
    local audit = auditGroup(group)
    totalGroups = totalGroups + 1
    raw = raw + audit.raw
    collectible = collectible + audit.collectible
    junk = junk + audit.junk
    if audit.junk > 0 then
      groupsWithJunk = groupsWithJunk + 1
      worst[#worst + 1] = audit
    end
    for k, v in pairs(audit.junkReasons) do reasonTotals[k] = (reasonTotals[k] or 0) + v end
    for k, v in pairs(audit.collectibleKinds) do kindTotals[k] = (kindTotals[k] or 0) + v end
  end

  table.sort(worst, function(a, b)
    if (a.junk or 0) ~= (b.junk or 0) then return (a.junk or 0) > (b.junk or 0) end
    return tostring(a.group and a.group.name or "") < tostring(b.group and b.group.name or "")
  end)

  Print(("Junk audit all %s complete"):format(scope ~= "" and scope or "raids+dungeons"))
  Print(("  groups scanned=%d groups with junk=%d raw items=%d collectible=%d junk=%d"):format(totalGroups, groupsWithJunk, raw, collectible, junk))
  Print("  collectible kinds: " .. kindLine(kindTotals))
  Print("  junk reasons: " .. kindLine(reasonTotals))

  local limit = tonumber(opts and opts.limit or 25) or 25
  if #worst == 0 then
    Print("  groups with junk: none")
    return
  end

  Print("  groups with junk (showing up to " .. tostring(limit) .. "):")
  for i = 1, math.min(#worst, limit) do
    local a = worst[i]
    Print(("  - %s: junk=%d raw=%d collectible=%d"):format(groupLabel(a.group), a.junk or 0, a.raw or 0, a.collectible or 0))
    local itemLimit = 3
    for j = 1, math.min(#a.junkItems, itemLimit) do
      local r = a.junkItems[j]
      Print(("      junk: item=%s section=%s reason=%s name=%s"):format(tostring(r.itemID), tostring(r.section), tostring(r.reason), tostring(r.name)))
    end
    if #a.junkItems > itemLimit then Print("      ...and " .. tostring(#a.junkItems - itemLimit) .. " more") end
  end
  if #worst > limit then Print("  ...and " .. tostring(#worst - limit) .. " more groups with junk") end
end

function JunkAudit.Run(msg)
  msg = lower(trim(msg))
  local verbose = msg:find("verbose", 1, true) or msg:find("debug", 1, true) or msg:find("full", 1, true)
  local limit = verbose and 60 or 25

  if msg == "" or msg:find("active", 1, true) or msg:find("current", 1, true) then
    local group = activeGroup()
    if not group then
      Print("Junk audit: no active raid/dungeon row found. Open Collection Log and select a row, or use /clogjunk all raids.")
      return
    end
    printGroupAudit(auditGroup(group), { limit = limit })
    return
  end

  if msg:find("all", 1, true) then
    local scope = "all"
    if msg:find("raid", 1, true) then scope = "raids" end
    if msg:find("dungeon", 1, true) then scope = "dungeons" end
    printAll(scope, { limit = limit })
    return
  end

  -- Convenience aliases.
  if msg:find("raid", 1, true) then printAll("raids", { limit = limit }); return end
  if msg:find("dungeon", 1, true) then printAll("dungeons", { limit = limit }); return end

  Print("Usage: /clogjunk active | /clogjunk all | /clogjunk all raids | /clogjunk all dungeons")
end

SLASH_CLOGJUNK1 = "/clogjunk"
SlashCmdList.CLOGJUNK = function(msg) JunkAudit.Run(msg) end
