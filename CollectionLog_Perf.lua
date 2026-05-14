-- CollectionLog_Perf.lua
-- Lightweight, opt-in performance probe for Collection Log.
-- Disabled by default. Use /clogperf in-game.
local ADDON, ns = ...

ns.Perf = ns.Perf or {}
local P = ns.Perf

P.enabled = false
P.samples = P.samples or {}
P.events = P.events or {}
P.sessionStart = 0
P.memStart = 0
P.memPeak = 0
P.wrapped = P.wrapped or {}

local function Now()
  if debugprofilestop then return debugprofilestop() end
  return (GetTime and GetTime() * 1000) or 0
end

local function MemKB()
  if collectgarbage then return collectgarbage("count") or 0 end
  return 0
end

local function Print(msg)
  if ns and ns.Print then ns.Print(msg) else DEFAULT_CHAT_FRAME:AddMessage("Collection Log: " .. tostring(msg)) end
end

local function Reset()
  P.samples = {}
  P.events = {}
  P.sessionStart = Now()
  P.memStart = MemKB()
  P.memPeak = P.memStart
end

local function AddSample(name, elapsed, memDelta)
  local s = P.samples[name]
  if not s then
    s = { count = 0, total = 0, max = 0, over1 = 0, over5 = 0, over10 = 0, over50 = 0, mem = 0, memMax = 0 }
    P.samples[name] = s
  end
  s.count = s.count + 1
  s.total = s.total + elapsed
  if elapsed > s.max then s.max = elapsed end
  if elapsed >= 1 then s.over1 = s.over1 + 1 end
  if elapsed >= 5 then s.over5 = s.over5 + 1 end
  if elapsed >= 10 then s.over10 = s.over10 + 1 end
  if elapsed >= 50 then s.over50 = s.over50 + 1 end
  if memDelta and memDelta > 0 then
    s.mem = s.mem + memDelta
    if memDelta > s.memMax then s.memMax = memDelta end
  end
end


function P.Measure(name, fn, ...)
  if type(fn) ~= "function" then return nil end
  if not P.enabled then return fn(...) end
  local m0 = MemKB()
  local t0 = Now()
  local out = { pcall(fn, ...) }
  local elapsed = Now() - t0
  local m1 = MemKB()
  if m1 > P.memPeak then P.memPeak = m1 end
  AddSample(tostring(name or "phase"), elapsed, m1 - m0)
  if not out[1] then error(out[2], 2) end
  return unpack(out, 2)
end

local function WrapTable(tbl, prefix)
  if type(tbl) ~= "table" then return end
  for key, fn in pairs(tbl) do
    if type(fn) == "function" then
      local name = prefix .. "." .. tostring(key)
      if not P.wrapped[name] then
        P.wrapped[name] = true
        tbl[key] = function(...)
          if not P.enabled then return fn(...) end
          local m0 = MemKB()
          local t0 = Now()
          local out = { pcall(fn, ...) }
          local elapsed = Now() - t0
          local m1 = MemKB()
          if m1 > P.memPeak then P.memPeak = m1 end
          AddSample(name, elapsed, m1 - m0)
          if not out[1] then error(out[2], 2) end
          return unpack(out, 2)
        end
      end
    end
  end
end

local function WrapGlobal(name)
  local fn = _G[name]
  if type(fn) ~= "function" or P.wrapped[name] then return end
  P.wrapped[name] = true
  _G[name] = function(...)
    if not P.enabled then return fn(...) end
    local m0 = MemKB()
    local t0 = Now()
    local out = { pcall(fn, ...) }
    local elapsed = Now() - t0
    local m1 = MemKB()
    if m1 > P.memPeak then P.memPeak = m1 end
    AddSample(name, elapsed, m1 - m0)
    if not out[1] then error(out[2], 2) end
    return unpack(out, 2)
  end
end

function P.WrapKnownEntryPoints()
  WrapTable(ns.UI, "UI")
  WrapGlobal("CollectionLog_ShowCollectionPopup")
  WrapGlobal("CollectionLog_TestPopup")
  WrapGlobal("CLOG_RefreshCollectionTracker")
end

local eventFrame = CreateFrame("Frame")
local events = {
  "BAG_UPDATE_DELAYED",
  "CHAT_MSG_LOOT",
  "NEW_MOUNT_ADDED",
  "NEW_PET_ADDED",
  "NEW_TOY_ADDED",
  "PET_JOURNAL_LIST_UPDATE",
  "PET_JOURNAL_PET_LIST_UPDATE",
  "TOYS_UPDATED",
  "TOYBOX_UPDATED",
  "MOUNT_JOURNAL_USABILITY_CHANGED",
  "QUEST_TURNED_IN",
  "MERCHANT_CLOSED",
  "MAIL_CLOSED",
  "AUCTION_HOUSE_CLOSED",
  "ACHIEVEMENT_EARNED",
  "HOUSING_CATALOG_UPDATE",
}
for _, ev in ipairs(events) do pcall(eventFrame.RegisterEvent, eventFrame, ev) end

eventFrame:SetScript("OnEvent", function(_, event)
  if not P.enabled then return end
  local e = P.events[event]
  if not e then e = { count = 0, first = Now(), last = Now() }; P.events[event] = e end
  e.count = e.count + 1
  e.last = Now()
end)

local function SortedSamples(limit)
  local rows = {}
  for name, s in pairs(P.samples) do
    rows[#rows + 1] = { name = name, data = s }
  end
  table.sort(rows, function(a, b) return (a.data.total or 0) > (b.data.total or 0) end)
  if limit and #rows > limit then
    for i = #rows, limit + 1, -1 do rows[i] = nil end
  end
  return rows
end

local function SortedEvents(limit)
  local rows = {}
  for name, e in pairs(P.events) do rows[#rows + 1] = { name = name, data = e } end
  table.sort(rows, function(a, b) return (a.data.count or 0) > (b.data.count or 0) end)
  if limit and #rows > limit then
    for i = #rows, limit + 1, -1 do rows[i] = nil end
  end
  return rows
end

function P.Report(limit)
  limit = tonumber(limit) or 15
  local runtime = math.max(0.001, Now() - (P.sessionStart or Now()))
  Print(("Perf report: %.1fs sampled, memory %+0.1f KB, peak %+0.1f KB"):format(runtime / 1000, MemKB() - (P.memStart or 0), (P.memPeak or 0) - (P.memStart or 0)))
  for _, row in ipairs(SortedSamples(limit)) do
    local s = row.data
    Print(("CPU %-36s total %.2fms avg %.3fms max %.2fms calls %d >5ms %d >10ms %d mem %+0.1f KB"):format(row.name, s.total, s.total / math.max(1, s.count), s.max, s.count, s.over5, s.over10, s.mem or 0))
  end
  local evRows = SortedEvents(8)
  if #evRows > 0 then
    Print("Event counts while profiling:")
    for _, row in ipairs(evRows) do
      Print(("  %s x%d"):format(row.name, row.data.count or 0))
    end
  end
end

function P.Start(seconds)
  P.WrapKnownEntryPoints()
  Reset()
  P.enabled = true
  seconds = tonumber(seconds or 0) or 0
  if seconds > 0 and C_Timer and C_Timer.After then
    C_Timer.After(seconds, function()
      if P.enabled then
        P.enabled = false
        P.Report(20)
      end
    end)
    Print(("Perf probe started for %d seconds. Now reproduce the lag."):format(seconds))
  else
    Print("Perf probe started. Reproduce the lag, then run /clogperf stop or /clogperf report.")
  end
end

function P.Stop()
  P.enabled = false
  Print("Perf probe stopped.")
  P.Report(20)
end

SLASH_CLOGPERF1 = "/clogperf"
SlashCmdList.CLOGPERF = function(msg)
  msg = tostring(msg or ""):lower()
  local cmd, arg = msg:match("^(%S*)%s*(.-)$")
  if cmd == "start" then
    P.Start(arg)
  elseif cmd == "stop" then
    P.Stop()
  elseif cmd == "report" then
    P.Report(tonumber(arg) or 20)
  elseif cmd == "reset" then
    Reset(); Print("Perf samples reset.")
  elseif cmd == "mem" then
    Print(("Current Lua memory: %.1f KB"):format(MemKB()))
  else
    Print("Usage: /clogperf start [seconds], /clogperf stop, /clogperf report [rows], /clogperf reset, /clogperf mem")
  end
end
