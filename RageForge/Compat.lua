-- RageForge: Compat.lua
-- Runtime API / client capability probes. Feature-detect only -- never branch
-- on WOW_PROJECT_ID (Forever has been observed returning Mainline's value).

local ADDON_NAME, ns = ...
ns.Compat = {}
local Compat = ns.Compat

local function hasFn(tbl, name)
    return type(tbl) == "table" and type(tbl[name]) == "function"
end

-- Interface / build probes (logging and TOC notes only).
Compat.interfaceVersion = select(4, GetBuildInfo()) or 0

-- Secret-value toolbox (Midnight / Forever Mainline family).
Compat.hasSecrets = type(issecretvalue) == "function"
Compat.hasCanAccessValue = type(canaccessvalue) == "function"
Compat.hasAbbreviateNumbers = type(AbbreviateNumbers) == "function"
Compat.hasUnitPowerPercent = type(UnitPowerPercent) == "function"
Compat.hasCurveUtil = hasFn(C_CurveUtil, "CreateColorCurve")
Compat.hasCreateColor = type(CreateColor) == "function"

-- Aura / spell modern APIs.
Compat.hasCUnitAuras = type(C_UnitAuras) == "table"
Compat.hasGetPlayerAuraBySpellID = hasFn(C_UnitAuras, "GetPlayerAuraBySpellID")
Compat.hasGetAuraDataByIndex = hasFn(C_UnitAuras, "GetAuraDataByIndex")
Compat.hasCSpell = type(C_Spell) == "table"
Compat.hasCSecrets = type(C_Secrets) == "table"

-- Forever / Mainline-family: GetSpellInfo was reported missing on Forever beta.
-- Prefer C_Spell; fall back to the legacy global when present (TBC Anniversary).
function Compat.GetSpellName(spellId)
    if hasFn(C_Spell, "GetSpellName") then
        return C_Spell.GetSpellName(spellId)
    end
    if hasFn(C_Spell, "GetSpellInfo") then
        local info = C_Spell.GetSpellInfo(spellId)
        if type(info) == "table" then
            return info.name
        end
        if type(info) == "string" then
            return info
        end
    end
    if type(GetSpellInfo) == "function" then
        return GetSpellInfo(spellId)
    end
    return nil
end

function Compat.GetSpellTexture(spellId)
    if hasFn(C_Spell, "GetSpellTexture") then
        return C_Spell.GetSpellTexture(spellId)
    end
    if hasFn(C_Spell, "GetSpellInfo") then
        local info = C_Spell.GetSpellInfo(spellId)
        if type(info) == "table" and info.iconID then
            return info.iconID
        end
    end
    if type(GetSpellTexture) == "function" then
        return GetSpellTexture(spellId)
    end
    if type(GetSpellInfo) == "function" then
        local _, _, icon = GetSpellInfo(spellId)
        return icon
    end
    return nil
end

function Compat.RagePowerType()
    if Enum and Enum.PowerType and Enum.PowerType.Rage ~= nil then
        return Enum.PowerType.Rage
    end
    return 1
end

-- Spell-known probe (TBC + Forever). Prefer IsPlayerSpell / IsSpellKnown;
-- C_SpellBook.IsSpellInSpellBook when present on Mainline-family clients.
function Compat.IsSpellKnown(spellId)
    if not spellId then
        return false
    end
    if type(IsPlayerSpell) == "function" then
        local ok, known = pcall(IsPlayerSpell, spellId)
        if ok then
            return known and true or false
        end
    end
    if type(IsSpellKnown) == "function" then
        local ok, known = pcall(IsSpellKnown, spellId)
        if ok then
            return known and true or false
        end
    end
    if hasFn(C_SpellBook, "IsSpellInSpellBook") then
        local ok, known = pcall(C_SpellBook.IsSpellInSpellBook, spellId)
        if ok then
            return known and true or false
        end
    end
    return false
end

-- Returns a packed list of learned warrior stances from the stance bar.
-- GetNumShapeshiftForms / GetShapeshiftFormInfo only expose slots the player
-- currently has (Battle from character creation; Defensive / Berserker after
-- the quests teach them). No level hardcoding. IsSpellKnown is available via
-- Compat.IsSpellKnown for other probes; the stance bar itself is authoritative
-- here so we do not false-negative on clients where stance spells probe oddly.
-- Each entry: { index, icon, name, active, castable, spellId }
function Compat.GetLearnedStances()
    local list = {}
    if type(GetNumShapeshiftForms) ~= "function" or type(GetShapeshiftFormInfo) ~= "function" then
        return list
    end

    local n = GetNumShapeshiftForms() or 0
    for i = 1, n do
        local a, b, c, d, e = GetShapeshiftFormInfo(i)
        local icon, name, active, castable, spellId
        -- Classic-era sometimes returns (icon, name, active, castable, spellId).
        -- Modern docs list (icon, active, castable, spellID).
        if type(b) == "string" then
            icon, name, active, castable, spellId = a, b, c, d, e
        else
            icon, name, active, castable, spellId = a, nil, b, c, d
        end

        if icon then
            list[#list + 1] = {
                index = i,
                icon = icon,
                name = name,
                active = active and true or false,
                castable = castable and true or false,
                spellId = spellId,
            }
        end
    end
    return list
end

-- True when tainted code may freely compare / math on this value.
function Compat.CanUseNumber(value)
    if value == nil then
        return false
    end
    if not Compat.hasSecrets then
        return true
    end
    if issecretvalue(value) then
        return false
    end
    if Compat.hasCanAccessValue and not canaccessvalue(value) then
        return false
    end
    return true
end

-- Prefer C_Secrets when present; otherwise probe UnitPower itself.
function Compat.ShouldUnitPowerBeSecret(unit, powerType)
    if hasFn(C_Secrets, "ShouldUnitPowerBeSecret") then
        return C_Secrets.ShouldUnitPowerBeSecret(unit, powerType) and true or false
    end
    if not Compat.hasSecrets then
        return false
    end
    local power = UnitPower(unit, powerType)
    return issecretvalue(power) and true or false
end

function Compat.ShouldAurasBeSecret()
    if hasFn(C_Secrets, "ShouldAurasBeSecret") then
        return C_Secrets.ShouldAurasBeSecret() and true or false
    end
    return false
end

-- Returns name, icon, duration, expirationTime (absolute or remaining),
-- and a boolean `readable` when timing fields can be used in Lua math.
-- On Forever, prefer C_UnitAuras; UnitBuff remains for TBC Anniversary.
function Compat.FindPlayerBuffBySpellIds(spellIds, nameMatcher, iconMatcher)
    if Compat.hasGetPlayerAuraBySpellID then
        for spellId in pairs(spellIds) do
            local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellId)
            if aura then
                local name = aura.name
                local icon = aura.icon
                local duration = aura.duration
                local expirationTime = aura.expirationTime
                local readable = Compat.CanUseNumber(expirationTime)
                    and (duration == nil or Compat.CanUseNumber(duration))
                if not nameMatcher or nameMatcher(name, icon) then
                    return name, icon, duration, expirationTime, readable, true
                end
            end
        end
    end

    if Compat.hasGetAuraDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
            if not aura then
                break
            end
            local name = aura.name
            local icon = aura.icon
            local spellId = aura.spellId
            if (spellId and spellIds[spellId]) or (nameMatcher and nameMatcher(name, icon)) then
                local duration = aura.duration
                local expirationTime = aura.expirationTime
                local readable = Compat.CanUseNumber(expirationTime)
                    and (duration == nil or Compat.CanUseNumber(duration))
                return name, icon, duration, expirationTime, readable, true
            end
        end
        return nil, nil, nil, nil, false, false
    end

    if type(UnitBuff) == "function" then
        for i = 1, 40 do
            -- TBC Anniversary layout used elsewhere in RageBar:
            -- name, rank, icon, count, debuffType, duration, expirationTime, ...
            local name, _, buffIcon, _, _, duration, expirationTime = UnitBuff("player", i)
            if not name then
                break
            end
            if (nameMatcher and nameMatcher(name, buffIcon))
                or (iconMatcher and buffIcon and iconMatcher(buffIcon)) then
                return name, buffIcon, duration, expirationTime, true, true
            end
        end
    end

    return nil, nil, nil, nil, false, false
end

-- Format a possibly-secret number for FontString display without Lua math.
function Compat.FormatNumber(value)
    if value == nil then
        return ""
    end
    if Compat.CanUseNumber(value) then
        return tostring(math.floor(value + 0.5))
    end
    if Compat.hasAbbreviateNumbers then
        -- AbbreviateNumbers accepts secrets and returns a plain string (Midnight docs).
        local ok, text = pcall(AbbreviateNumbers, value)
        if ok and text ~= nil then
            return text
        end
    end
    -- Last resort: FontString:SetText accepts secrets directly on Mainline-family.
    return value
end

-- True when this client needs the secret-safe StatusBar fill path for rage.
function Compat.NeedsSecretSafeRageDisplay()
    if not Compat.hasSecrets then
        return false
    end
    return Compat.ShouldUnitPowerBeSecret("player", Compat.RagePowerType())
end
