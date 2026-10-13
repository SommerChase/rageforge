-- RageForge: ForeverDisplay.lua
-- Forever / Mainline-family secret-safe rage fill helpers.
-- Loaded only by RageForge_Forever.toc / RageForge_Camelot.toc.
--
-- Why a separate file: the curved 1px-slice renderer compares every row's
-- mid-rage to currentRage. Under Midnight/Forever secret-value rules,
-- primary power (Rage) may be secret in combat, and tainted Lua cannot
-- compare or arithmetic on secrets. StatusBar:SetValue / ColorCurve /
-- FontString:SetText accept secrets at the engine level, so this module
-- builds that fallback path. Classic Anniversary never loads this file.

local ADDON_NAME, ns = ...
ns.ForeverDisplay = {}
local FD = ns.ForeverDisplay

local secretBar
local secretColorCurve
local secretMode = false

local function zoneToColor(zone)
    if not zone then
        return CreateColor(1, 1, 1, 1)
    end
    return CreateColor(zone[1] or 1, zone[2] or 1, zone[3] or 1, zone[4] or 1)
end

function FD:IsAvailable()
    local Compat = ns.Compat
    return Compat
        and Compat.hasSecrets
        and Compat.hasCurveUtil
        and Compat.hasCreateColor
        and type(CreateFrame) == "function"
end

function FD:EnsureColorCurve()
    if secretColorCurve or not self:IsAvailable() then
        return secretColorCurve
    end
    local cfg = ns.Config and ns.Config.db
    if not cfg then
        return nil
    end

    secretColorCurve = C_CurveUtil.CreateColorCurve()
    -- Smooth blend approximating the Classic zone palette.
    -- X is power percent in 0..1 (UnitPowerPercent / StatusBar range).
    if secretColorCurve.SetType and Enum and Enum.LuaCurveType and Enum.LuaCurveType.Linear then
        secretColorCurve:SetType(Enum.LuaCurveType.Linear)
    end

    local retained = (cfg.tacticalMasteryRetained or 25) / 100
    local zones = cfg.zones
    secretColorCurve:AddPoint(0, zoneToColor(zones.safe))
    secretColorCurve:AddPoint(math.max(0.01, retained), zoneToColor(zones.safe))
    secretColorCurve:AddPoint(0.50, zoneToColor(zones.ok))
    secretColorCurve:AddPoint(0.75, zoneToColor(zones.caution))
    secretColorCurve:AddPoint(1.00, zoneToColor(zones.dump))
    return secretColorCurve
end

function FD:RebuildColorCurve()
    secretColorCurve = nil
    self:EnsureColorCurve()
end

-- parent: RageForge bar container. Geometry mirrors the curved bar's
-- centerline envelope as a straight StatusBar (curve lost under secrets).
function FD:Build(parent, width, height, anchorX, anchorY)
    if secretBar or not parent or not self:IsAvailable() then
        return secretBar
    end

    secretBar = CreateFrame("StatusBar", "RageForgeSecretRageBar", parent)
    secretBar:SetSize(width, height)
    secretBar:SetPoint("BOTTOM", parent, "BOTTOMLEFT", anchorX, anchorY)
    secretBar:SetOrientation("VERTICAL")
    if secretBar.SetRotatesTexture then
        secretBar:SetRotatesTexture(true)
    end
    secretBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    secretBar:SetMinMaxValues(0, 1)
    secretBar:SetValue(0)
    secretBar:Hide()

    local bg = secretBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(secretBar)
    bg:SetColorTexture(0.13, 0.11, 0.09, 0.62)
    secretBar._bg = bg

    return secretBar
end

function FD:SetSecretMode(enabled)
    secretMode = enabled and true or false
    if not secretBar then
        return
    end
    if secretMode then
        secretBar:Show()
    else
        secretBar:Hide()
    end
end

function FD:IsSecretMode()
    return secretMode
end

-- Update fill + color from possibly-secret UnitPower values.
-- Never compare or arithmetic on power here.
function FD:Update(power, powerMax, powerType)
    if not secretBar then
        return
    end

    local Compat = ns.Compat
    local curve = self:EnsureColorCurve()

    -- Prefer UnitPowerPercent (0..1) so SetValue never needs Lua division.
    if Compat and Compat.hasUnitPowerPercent then
        local pct
        if curve then
            -- Evaluating percent through the color curve returns a colorRGBA.
            local color = UnitPowerPercent("player", powerType, false, curve)
            if color and color.GetRGB then
                local r, g, b = color:GetRGB()
                secretBar:GetStatusBarTexture():SetVertexColor(r, g, b, 1)
            end
            pct = UnitPowerPercent("player", powerType, false)
        else
            pct = UnitPowerPercent("player", powerType, false)
        end
        if pct ~= nil then
            secretBar:SetMinMaxValues(0, 1)
            secretBar:SetValue(pct)
            return
        end
    end

    -- Fallback: pass secrets straight into StatusBar (engine-accepted).
    if powerMax ~= nil then
        secretBar:SetMinMaxValues(0, powerMax)
    end
    if power ~= nil then
        secretBar:SetValue(power)
    end
end

function FD:HideDecisionHints(ghostNotch, ghostLine, dumpHintFS, capGlow)
    if ghostNotch then ghostNotch:Hide() end
    if ghostLine then ghostLine:Hide() end
    if dumpHintFS then dumpHintFS:Hide() end
    if capGlow then capGlow:Hide() end
end
