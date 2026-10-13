-- RageForge: Core.lua
-- Addon bootstrap, event router, and update driver.

local ADDON_NAME, ns = ...

ns.Core = {}
local Core = ns.Core

-- A single hidden frame owns all our events. Keeps the global namespace clean.
local f = CreateFrame("Frame", "RageForgeCoreFrame", UIParent)

-- Forever/Mainline renamed LEARNED_SPELL_IN_TAB -> LEARNED_SPELL_IN_SKILL_LINE.
-- Guard every registration so unknown events never error the load.
local function safeRegister(eventName)
    if C_EventUtils and C_EventUtils.IsEventValid then
        if not C_EventUtils.IsEventValid(eventName) then
            return false
        end
    end
    local ok = pcall(f.RegisterEvent, f, eventName)
    return ok and true or false
end

local CORE_EVENTS = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "UNIT_POWER_UPDATE",
    "UNIT_MAXPOWER",
    "UNIT_DISPLAYPOWER",
    "UNIT_AURA",
    "UNIT_SPELLCAST_SUCCEEDED",
    "PLAYER_DEAD",
    "PLAYER_ALIVE",
    "PLAYER_UNGHOST",
    "UPDATE_SHAPESHIFT_FORM",
    "UPDATE_SHAPESHIFT_FORMS",
    "SPELLS_CHANGED",
    "LEARNED_SPELL_IN_TAB",          -- TBC / Classic
    "LEARNED_SPELL_IN_SKILL_LINE",   -- Forever / Mainline (11.0+)
    "PLAYER_LEVEL_UP",
    "PLAYER_REGEN_DISABLED",
    "PLAYER_REGEN_ENABLED",
}

for i = 1, #CORE_EVENTS do
    safeRegister(CORE_EVENTS[i])
end

local function isStanceLearnEvent(event)
    return event == "UPDATE_SHAPESHIFT_FORM"
        or event == "UPDATE_SHAPESHIFT_FORMS"
        or event == "SPELLS_CHANGED"
        or event == "LEARNED_SPELL_IN_TAB"
        or event == "LEARNED_SPELL_IN_SKILL_LINE"
        or event == "PLAYER_LEVEL_UP"
end

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

    elseif isStanceLearnEvent(event) then
        -- Stance rail shows only learned forms; refresh as soon as a stance
        -- quest/spell unlocks so Defensive/Berserker appear without /reload.
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
