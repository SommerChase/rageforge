-- RageForge: Core.lua
-- Addon bootstrap, event router, and update driver.

local ADDON_NAME, ns = ...

ns.Core = {}
local Core = ns.Core

-- A single hidden frame owns all our events. Keeps the global namespace clean.
local f = CreateFrame("Frame", "RageForgeCoreFrame", UIParent)

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("UNIT_POWER_UPDATE")
f:RegisterEvent("UNIT_MAXPOWER")
f:RegisterEvent("UNIT_DISPLAYPOWER")
f:RegisterEvent("UNIT_AURA")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("PLAYER_ALIVE")
f:RegisterEvent("PLAYER_UNGHOST")
f:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
f:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == ADDON_NAME then
            ns.Config:Load()
            ns.Config:RegisterSlash()
            if ns.Options and ns.Options.Build then
                local ok, err = pcall(ns.Options.Build, ns.Options)
                if not ok and ns.Config and ns.Config.Print then
                    ns.Config:Print("options panel failed: " .. tostring(err))
                end
            end
        end

    elseif event == "PLAYER_LOGIN" then
        -- Build UI once the player frame exists.
        ns.RageBar:Build()
        if ns.Options and ns.Options.Build then
            local ok, err = pcall(ns.Options.Build, ns.Options)
            if not ok and ns.Config and ns.Config.Print then
                ns.Config:Print("options panel failed: " .. tostring(err))
            end
        end
        ns.RageBar:Update()
        if ns.RageBar.UpdateAuras then ns.RageBar:UpdateAuras() end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Force a refresh on zone changes / login completion.
        ns.RageBar:Update()
        if ns.RageBar.UpdateAuras then ns.RageBar:UpdateAuras() end

    elseif event == "UNIT_POWER_UPDATE" then
        local unit, powerType = ...
        if unit == "player" and powerType == "RAGE" then
            ns.RageBar:Update()
        end

    elseif event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        local unit = ...
        if unit == "player" then
            ns.RageBar:Update()
        end

    elseif event == "UNIT_AURA" then
        local unit = ...
        if (not unit or unit == "player") and ns.RageBar and ns.RageBar.UpdateAuras then
            ns.RageBar:UpdateAuras()
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if ns.RageBar and ns.RageBar.OnSpellcastSucceeded then
            ns.RageBar:OnSpellcastSucceeded(...)
        end

    elseif event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        if ns.RageBar and ns.RageBar.UpdateAuras then
            ns.RageBar:UpdateAuras()
        end

    elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_SHAPESHIFT_FORMS" then
        if ns.RageBar and ns.RageBar.UpdateStance then
            ns.RageBar:UpdateStance()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        ns.RageBar:SetInCombat(true)

    elseif event == "PLAYER_REGEN_ENABLED" then
        ns.RageBar:SetInCombat(false)
    end
end)

-- Lightweight OnUpdate: drives smooth tween animation for the rage fill.
-- Throttled to ~60fps; no per-frame rage queries.
local TICK = 1 / 60
local accumulator = 0
f:SetScript("OnUpdate", function(_, elapsed)
    accumulator = accumulator + elapsed
    if accumulator < TICK then return end
    local dt = accumulator
    accumulator = 0

    if ns.RageBar and ns.RageBar.OnFrame then
        ns.RageBar:OnFrame(dt)
    end
end)

Core.frame = f
