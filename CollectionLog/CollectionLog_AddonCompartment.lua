-- CollectionLog_AddonCompartment.lua
-- Blizzard Addon Compartment (default minimap addon tray) entry.
-- Correct signature: AddonCompartmentFrame:RegisterAddon({ text=..., icon=..., func=... })
-- Safe no-op if unavailable.

local ADDON, ns = ...
local DISPLAY_TEXT = "Collection Log"
local ICON_PATH = "Interface\\AddOns\\CollectionLog\\Media\\MinimapIcon.tga"

local function ToggleMain()
  if ns and ns.UI and type(ns.UI.Toggle) == "function" then
    ns.UI.Toggle()
    return
  end
  if SlashCmdList and SlashCmdList["COLLECTIONLOG"] then
    SlashCmdList["COLLECTIONLOG"]("")
  end
end

local function Register()
  local frame = _G.AddonCompartmentFrame
  if not frame or type(frame.RegisterAddon) ~= "function" then return end

  frame.registeredAddons = frame.registeredAddons or {}
  for i = 1, #frame.registeredAddons do
    local entry = frame.registeredAddons[i]
    if entry and entry.text == DISPLAY_TEXT then
      return
    end
  end

  pcall(function()
    frame:RegisterAddon({
      text = DISPLAY_TEXT,
      icon = ICON_PATH,
      notCheckable = true,
      registerForAnyClick = true,
      func = function() ToggleMain() end,
    })
  end)

  if type(frame.UpdateDisplay) == "function" then
    pcall(function() frame:UpdateDisplay() end)
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function() Register() end)
