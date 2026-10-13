-- RageForge: ForeverDisplay.lua
-- Forever / Mainline-family curved rage fill that stays secret-safe in combat.
-- Loaded only by RageForge_Forever.toc / RageForge_Camelot.toc.
--
-- Technique (confirmed, warcraft.wiki.gg Secret_Values + StatusBar APIs):
--   StatusBar:SetValue / SetMinMaxValues accept secret numbers (BarValue aspect).
--   Tainted Lua cannot compare or arithmetic on secret UnitPower, but the
--   engine can. So we build the curve as a stack of short StatusBar segments
--   along the same parabola as the Classic slice bar. Each segment owns a
--   plain rage sub-range via SetMinMaxValues(low, high) and receives the
--   (possibly secret) UnitPower through SetValue every update. No Lua math
--   on the secret is required for fill.
--
-- Coloring uses each segment's baked mid-rage (a plain construction-time
-- number) against the zone palette -- not the live secret power.
--
-- Forever always uses this path (combat and out-of-combat), so the curve
-- never disappears when restrictions flip. Classic Anniversary never loads
-- this file and keeps the Texture-slice renderer in RageBar.lua.
--
-- Speculative extras (used when present, ignored when missing):
--   Enum.StatusBarInterpolation.ExponentialEaseOut for smooth fill easing
--   UnitPowerPercent + ColorCurve tip tint
--   StatusBar ghost-notch visibility via min=retained (engine compare)

local ADDON_NAME, ns = ...
ns.ForeverDisplay = {}
local FD = ns.ForeverDisplay

local segments = {}       -- StatusBar fill segments along the curve
local trackRows = {}      -- background track textures (always visible)
local tipGlow             -- soft tip highlight StatusBar (1 segment)
local ghostGate           -- StatusBar that reveals ghost notch without Lua compare
local ghostNotchTex
local built = false
local active = false
local parentFrame
local geom = {}

local function zoneToColor(zone)
    return CreateColor(zone[1] or 1, zone[2] or 1, zone[3] or 1, zone[4] or 1)
end

local function clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function mixColor(a, b, t)
    t = clamp(t, 0, 1)
    return lerp(a[1], b[1], t), lerp(a[2], b[2], t), lerp(a[3], b[3], t), lerp(a[4], b[4], t)
end

local function zoneColorForRage(rageValue, retainedRage, zones)
    if rageValue <= retainedRage then
        local c = zones.safe
        return c[1], c[2], c[3], c[4]
    elseif rageValue <= 50 then
        local span = math.max(1, 50 - retainedRage)
        return mixColor(zones.safe, zones.ok, (rageValue - retainedRage) / span)
    elseif rageValue <= 75 then
        return mixColor(zones.ok, zones.caution, (rageValue - 50) / 25)
    else
        return mixColor(zones.caution, zones.dump, (rageValue - 75) / 25)
    end
end

-- Same parabola as RageBar.lua (shared visual language).
local function curveOffset(t, amplitude, direction)
    local p = 1 - (2 * t - 1) ^ 2
    return amplitude * p * direction
end

local function snapPixel(v)
    return math.floor(v + 0.5)
end

local function interpolationMode()
    if Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut then
        return Enum.StatusBarInterpolation.ExponentialEaseOut
    end
    return nil
end

function FD:IsAvailable()
    return type(CreateFrame) == "function"
end

function FD:IsActive()
    return active
end

local function clearChildren()
    for _, bar in ipairs(segments) do
        bar:Hide()
        bar:SetParent(nil)
    end
    wipe(segments)
    for _, tex in ipairs(trackRows) do
        tex:Hide()
        tex:SetParent(nil)
    end
    wipe(trackRows)
    if tipGlow then
        tipGlow:Hide()
        tipGlow:SetParent(nil)
        tipGlow = nil
    end
    if ghostGate then
        ghostGate:Hide()
        ghostGate:SetParent(nil)
        ghostGate = nil
    end
    if ghostNotchTex then
        ghostNotchTex:Hide()
        ghostNotchTex:SetParent(nil)
        ghostNotchTex = nil
    end
end

-- Build / rebuild the curved StatusBar stack. Geometry mirrors RageBar.
function FD:Build(parent, width, height, anchorX, anchorY)
    if not parent or not self:IsAvailable() then
        return
    end

    parentFrame = parent
    geom.width = width
    geom.height = height
    geom.anchorX = anchorX
    geom.anchorY = anchorY

    clearChildren()

    local cfg = ns.Config.db
    local style = ns.Config.GetStyle and ns.Config:GetStyle() or nil
    local amp = (style and style.curveAmplitude) or cfg.barCurveAmplitude or 16
    local dir = cfg.barCurveDirection or -1
    local stroke = (style and style.barWidth) or width
    local feather = (style and style.edgeFeather) or cfg.barEdgeFeatherWidth or 2
    local edgeAlpha = (style and style.edgeAlpha) or cfg.barEdgeAlpha or 0.45
    local retained = cfg.tacticalMasteryRetained or 25
    local zones = cfg.zones
    local emptyC = zones.empty
    local ease = interpolationMode()

    -- Prefer ~1 StatusBar per rage (100) so engine compares are fine-grained,
    -- but never denser than 1px of bar height.
    local numSeg = math.min(100, math.max(40, math.floor(height)))
    local centerWidth = math.max(1, stroke - feather * 2)

    for i = 1, numSeg do
        local t = (i - 0.5) / numSeg
        local rageLow = ((i - 1) / numSeg) * 100
        local rageHigh = (i / numSeg) * 100
        local midRage = (rageLow + rageHigh) * 0.5
        local xOff = curveOffset(t, amp, dir)
        local xCenter = snapPixel(anchorX + xOff)
        local y = anchorY + t * height - (height / numSeg) * 0.5
        local segH = math.max(1, math.ceil(height / numSeg) + 1) -- slight overlap hides seams

        -- Background track row (plain textures; no secrets involved).
        local track = parent:CreateTexture(nil, "BACKGROUND", nil, 0)
        track:SetSize(stroke, segH)
        track:SetPoint("BOTTOM", parent, "BOTTOMLEFT", xCenter, y)
        track:SetColorTexture(emptyC[1], emptyC[2], emptyC[3], (emptyC[4] or 0.62) * 0.85)
        trackRows[i] = track

        -- Soft feather strips for anti-aliased-looking edges.
        if feather > 0 then
            local left = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
            left:SetSize(feather, segH)
            left:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", xCenter - centerWidth * 0.5, y)
            left:SetColorTexture(emptyC[1], emptyC[2], emptyC[3], (emptyC[4] or 0.62) * edgeAlpha)
            trackRows[#trackRows + 1] = left

            local right = parent:CreateTexture(nil, "BACKGROUND", nil, 1)
            right:SetSize(feather, segH)
            right:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", xCenter + centerWidth * 0.5, y)
            right:SetColorTexture(emptyC[1], emptyC[2], emptyC[3], (emptyC[4] or 0.62) * edgeAlpha)
            trackRows[#trackRows + 1] = right
        end

        -- Fill segment: StatusBar with plain rage sub-range. SetValue(secret)
        -- is legal; the engine decides whether this band is lit.
        local bar = CreateFrame("StatusBar", nil, parent)
        bar:SetSize(centerWidth, segH)
        bar:SetPoint("BOTTOM", parent, "BOTTOMLEFT", xCenter, y)
        bar:SetOrientation("HORIZONTAL")
        bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        if ease then
            bar:SetMinMaxValues(rageLow, rageHigh, ease)
        else
            bar:SetMinMaxValues(rageLow, rageHigh)
        end
        bar:SetValue(0)

        local r, g, b, a = zoneColorForRage(midRage, retained, zones)
        local tex = bar:GetStatusBarTexture()
        if tex then
            tex:SetVertexColor(r, g, b, a or 1)
        end
        if bar.SetStatusBarColor then
            bar:SetStatusBarColor(r, g, b, a or 1)
        end

        bar._rageLow = rageLow
        bar._rageHigh = rageHigh
        bar._midRage = midRage
        segments[i] = bar
    end

    -- Ghost notch visibility gate: StatusBar min=retained does the
    -- "currentRage > retained" compare at C++ level (speculative but
    -- follows the documented SetValue secret-accept pattern).
    if cfg.showGhostLine then
        local frac = retained / 100
        local xOff = curveOffset(frac, amp, dir)
        local leftEdgeX = anchorX + xOff - stroke * 0.5
        local yPos = anchorY + frac * height

        ghostGate = CreateFrame("StatusBar", nil, parent)
        ghostGate:SetSize(4, 8)
        ghostGate:SetPoint("CENTER", parent, "BOTTOMLEFT", leftEdgeX, yPos)
        ghostGate:SetOrientation("VERTICAL")
        ghostGate:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local gc = cfg.ghostLineColor
        if ghostGate.SetStatusBarColor then
            ghostGate:SetStatusBarColor(gc[1], gc[2], gc[3], gc[4] or 0.9)
        end
        -- Narrow window just above retained: empty when power <= retained,
        -- full when power is above. Engine comparison, no Lua.
        ghostGate:SetMinMaxValues(retained, retained + 0.05)
        ghostGate:SetValue(0)
        ghostGate:Show()
    end

    built = true
    active = true
    return true
end

function FD:Rebuild()
    if not parentFrame or not geom.height then
        return
    end
    self:Build(parentFrame, geom.width, geom.height, geom.anchorX, geom.anchorY)
end

function FD:SetSecretMode(enabled)
    -- Forever always draws through this module; secret mode no longer
    -- swaps to a straight bar. Keep the API so RageBar call sites stay stable.
    active = true
    if not built then
        return
    end
    for _, bar in ipairs(segments) do
        bar:Show()
    end
    for _, tex in ipairs(trackRows) do
        tex:Show()
    end
end

function FD:IsSecretMode()
    -- Historical name: means "ForeverDisplay owns the fill."
    return active and built
end

-- Push possibly-secret power into every segment. No compare / arithmetic
-- on power or powerMax here.
function FD:Update(power, powerMax, powerType)
    if not built then
        return
    end

    local ease = interpolationMode()
    for _, bar in ipairs(segments) do
        if power ~= nil then
            if ease then
                bar:SetValue(power, ease)
            else
                bar:SetValue(power)
            end
        end
    end

    if ghostGate and power ~= nil then
        if ease then
            ghostGate:SetValue(power, ease)
        else
            ghostGate:SetValue(power)
        end
    end
end

function FD:RecolorFromConfig()
    if not built then
        return
    end
    local cfg = ns.Config.db
    local retained = cfg.tacticalMasteryRetained or 25
    local zones = cfg.zones
    for _, bar in ipairs(segments) do
        local r, g, b, a = zoneColorForRage(bar._midRage, retained, zones)
        if bar.SetStatusBarColor then
            bar:SetStatusBarColor(r, g, b, a or 1)
        end
        local tex = bar:GetStatusBarTexture()
        if tex then
            tex:SetVertexColor(r, g, b, a or 1)
        end
    end
    if ghostGate and cfg.showGhostLine then
        local gc = cfg.ghostLineColor
        ghostGate:SetMinMaxValues(retained, retained + 0.05)
        if ghostGate.SetStatusBarColor then
            ghostGate:SetStatusBarColor(gc[1], gc[2], gc[3], gc[4] or 0.9)
        end
        ghostGate:Show()
    elseif ghostGate then
        ghostGate:Hide()
    end
end

function FD:RebuildColorCurve()
    -- Kept for RageBar ApplyConfig call sites; recolor segments instead.
    self:RecolorFromConfig()
end

function FD:HideDecisionHints(ghostNotch, ghostLine, dumpHintFS, capGlow)
    -- Dump amount and Classic ghost textures still need Lua compares.
    -- Forever's ghostGate StatusBar replaces the notch visually.
    if ghostNotch then ghostNotch:Hide() end
    if ghostLine then ghostLine:Hide() end
    if dumpHintFS then dumpHintFS:Hide() end
    if capGlow then capGlow:Hide() end
end

function FD:HideClassicSlices(sliceList, leftFeathers, rightFeathers)
    for i, s in ipairs(sliceList or {}) do
        s:Hide()
        if leftFeathers and leftFeathers[i] then leftFeathers[i]:Hide() end
        if rightFeathers and rightFeathers[i] then rightFeathers[i]:Hide() end
    end
end
