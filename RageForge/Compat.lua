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

-- Retained rage on stance change.
-- Forever beta (Wowhead spell 1310185, level 14): baseline 10. Improved
-- Tactical Mastery (spell 12295) adds 3/6/9/12/15. Cap 25.
-- TBC: Tactical Mastery is 5 per rank on spells 12295, 12676, 12677,
-- 12678, 12679. No baseline. Cap 25.
-- Returns nil when the client cannot be read so the manual override is used.
-- A cached nil is intentional; InvalidateRetainedRage() retries.
local FOREVER_TM_BASELINE_SPELL = 1310185
local TM_TALENT_SPELL = 12295
local TBC_TM_RANK_SPELLS = { 12295, 12676, 12677, 12678, 12679 }

local retainedCache
local retainedCacheValid = false

local function onForeverClient()
    return ns.ForeverDisplay ~= nil
end

local function tmKindFromName(name)
    if type(name) ~= "string" then
        return nil
    end
    local key = name:lower()
    if key == "improved tactical mastery" then
        return "forever"
    end
    if key == "tactical mastery" then
        return "tbc"
    end
    return nil
end

local function noteTalent(foundKind, foundRank, kind, rank)
    if not kind then
        return foundKind, foundRank
    end
    rank = tonumber(rank) or 0
    if rank < 0 then
        rank = 0
    end
    if foundKind == "forever" and kind ~= "forever" then
        return foundKind, foundRank
    end
    if not foundKind or kind == "forever" or rank >= (foundRank or 0) then
        return kind, rank
    end
    return foundKind, foundRank
end

local function traitSpellAndName(entryID, configID)
    if not hasFn(C_Traits, "GetEntryInfo") then
        return nil, nil
    end
    local info
    local ok, first = pcall(C_Traits.GetEntryInfo, entryID)
    if ok and type(first) == "table" then
        info = first
    elseif configID then
        local ok2, second = pcall(C_Traits.GetEntryInfo, configID, entryID)
        if ok2 and type(second) == "table" then
            info = second
        end
    end
    if not info or not hasFn(C_Traits, "GetDefinitionInfo") then
        return nil, nil
    end
    local defID = info.definitionID
    if not defID and type(info.definitionIDs) == "table" then
        defID = info.definitionIDs[1]
    end
    if not defID then
        return nil, nil
    end
    local okDef, def = pcall(C_Traits.GetDefinitionInfo, defID)
    if not okDef or type(def) ~= "table" then
        return nil, nil
    end
    local spellID = def.spellID or def.overriddenSpellID
    if not spellID then
        return nil, nil
    end
    return spellID, Compat.GetSpellName(spellID)
end

local function nodeRank(node)
    if type(node) ~= "table" then
        return nil
    end
    local rank = node.currentRank
    if type(rank) ~= "number" then
        rank = node.ranksPurchased
    end
    if type(rank) ~= "number" then
        rank = node.activeRank
    end
    if type(rank) ~= "number" then
        return nil
    end
    return rank
end

-- nil, nil when the API is missing or the tree is not loaded yet.
-- kind nil and rank 0 means the tree loaded and this talent is untrained.
local function scanTraitTalents()
    if not hasFn(C_ClassTalents, "GetActiveConfigID") then
        return nil, nil
    end
    if not hasFn(C_Traits, "GetConfigInfo")
        or not hasFn(C_Traits, "GetTreeNodes")
        or not hasFn(C_Traits, "GetNodeInfo") then
        return nil, nil
    end

    local ok, kind, rank, saw = pcall(function()
        local configID = C_ClassTalents.GetActiveConfigID()
        if not configID then
            return nil
        end
        local info = C_Traits.GetConfigInfo(configID)
        local trees = info and info.treeIDs
        if type(trees) ~= "table" then
            return nil
        end

        local sawAny = false
        local foundKind, foundRank
        for _, treeID in pairs(trees) do
            local nodes = C_Traits.GetTreeNodes(treeID)
            if type(nodes) == "table" then
                for _, nodeID in pairs(nodes) do
                    local node = C_Traits.GetNodeInfo(configID, nodeID)
                    if type(node) == "table" and type(node.entryIDs) == "table" then
                        local purchased = nodeRank(node) or 0
                        for _, entryID in pairs(node.entryIDs) do
                            local spellID, name = traitSpellAndName(entryID, configID)
                            if spellID or (type(name) == "string" and name ~= "") then
                                sawAny = true
                            end
                            local entryKind = tmKindFromName(name)
                            if spellID == TM_TALENT_SPELL then
                                entryKind = onForeverClient() and "forever" or (entryKind or "tbc")
                            end
                            foundKind, foundRank = noteTalent(foundKind, foundRank, entryKind, purchased)
                        end
                    end
                end
            end
        end

        if not sawAny then
            return nil
        end
        return foundKind, foundRank or 0, true
    end)

    if not ok or not saw then
        return nil, nil
    end
    return kind, rank or 0
end

local function scanClassicTalents()
    if type(GetNumTalentTabs) ~= "function"
        or type(GetNumTalents) ~= "function"
        or type(GetTalentInfo) ~= "function" then
        return nil, nil
    end

    local ok, kind, rank, saw = pcall(function()
        local tabs = GetNumTalentTabs()
        if type(tabs) ~= "number" or tabs < 1 then
            return nil
        end
        local sawAny = false
        local foundKind, foundRank
        for tab = 1, tabs do
            local n = GetNumTalents(tab)
            if type(n) ~= "number" then
                n = 0
            end
            for i = 1, n do
                local name, _, _, _, current = GetTalentInfo(tab, i)
                if type(name) == "string" and name ~= "" then
                    sawAny = true
                    foundKind, foundRank = noteTalent(
                        foundKind, foundRank, tmKindFromName(name), tonumber(current) or 0
                    )
                end
            end
        end
        if not sawAny then
            return nil
        end
        return foundKind, foundRank or 0, true
    end)

    if not ok or not saw then
        return nil, nil
    end
    return kind, rank or 0
end

-- Locale-safe TBC probe. Forever reuses spell 12295 for every rank of the
-- renamed talent, so this chain is TBC-only.
local function tbcRankFromKnownSpells()
    if onForeverClient() then
        return nil
    end
    for rank = #TBC_TM_RANK_SPELLS, 1, -1 do
        if Compat.IsSpellKnown(TBC_TM_RANK_SPELLS[rank]) then
            return rank
        end
    end
    return nil
end

local function computeRetainedRage()
    local _, class = UnitClass("player")
    if class ~= "WARRIOR" then
        return nil
    end

    local traitKind, traitRank = scanTraitTalents()
    local classicKind, classicRank = scanClassicTalents()
    local kind, rank, readable
    if traitRank ~= nil or traitKind ~= nil then
        kind, rank, readable = traitKind, traitRank, true
    elseif classicRank ~= nil or classicKind ~= nil then
        kind, rank, readable = classicKind, classicRank, true
    end

    if onForeverClient() then
        if not readable then
            return nil
        end
        local bonus = 0
        if kind then
            bonus = (rank or 0) * 3
        end
        local baseline = 0
        if Compat.IsSpellKnown(FOREVER_TM_BASELINE_SPELL) then
            baseline = 10
        end
        local retained = baseline + bonus
        if retained > 25 then
            retained = 25
        end
        return retained
    end

    local spellRank = tbcRankFromKnownSpells()
    if kind == "tbc" or kind == "forever" then
        local fromTree = (rank or 0) * 5
        if spellRank and (spellRank * 5) > fromTree then
            fromTree = spellRank * 5
        end
        if fromTree > 25 then
            fromTree = 25
        end
        return fromTree
    end
    if spellRank then
        local fromSpells = spellRank * 5
        if fromSpells > 25 then
            fromSpells = 25
        end
        return fromSpells
    end
    -- Tree loaded, but the row was not the English name and no rank spell
    -- was known. Leave the manual value in place (locale / partial data).
    return nil
end

function Compat.InvalidateRetainedRage()
    retainedCacheValid = false
    retainedCache = nil
end

function Compat.GetRetainedRage()
    if retainedCacheValid then
        return retainedCache
    end
    local ok, value = pcall(computeRetainedRage)
    if ok and type(value) == "number" then
        retainedCache = value
    else
        retainedCache = nil
    end
    retainedCacheValid = true
    return retainedCache
end

-- Aura duration wins when the client reports it. This is only the local
-- countdown used when that duration is missing (secret auras, or a cast
-- that has not appeared in the aura list yet).
function Compat.BattleShoutFallbackSeconds()
    if onForeverClient() then
        return 180
    end
    local cfg = ns.Config and ns.Config.db
    local saved = cfg and cfg.battleShoutDuration
    if type(saved) == "number" and saved > 0 then
        return saved
    end
    return 120
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
