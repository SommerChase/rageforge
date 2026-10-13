-- RageForge: ForeverDisplay.lua
-- Forever / Mainline-family curved rage fill that stays secret-safe in combat.
-- Loaded only by RageForge_Forever.toc / RageForge_Camelot.toc.
--
-- Technique (confirmed, warcraft.wiki.gg Secret_Values + StatusBar APIs):
--   StatusBar:SetValue / SetMinMaxValues accept secret numbers (BarValue aspect).
--   Tainted Lua cannot compare or arithmetic on secret UnitPower, but the
--   engine can. So we build the curve as a dense stack of overlapping
--   StatusBar segments along the same parabola as the Classic slice bar.
--   Soft-edged SoftFill texture + overlap hides seams; a single SoftTrackCurve
--   texture paints the empty track; optional Iron/Bloodforged frame overlays
--   mask residual jaggies.
--
-- Coloring uses each segment's baked mid-rage (a plain construction-time
-- number) against the zone palette -- not the live secret power.

local ADDON_NAME, ns = ...
ns.ForeverDisplay = {}
local FD = ns.ForeverDisplay

local MEDIA = "Interface\\AddOns\\RageForge\\Media\\"
local TEX_SOFT_FILL = MEDIA .. "SoftFill"
local TEX_TRACK_CURVE = MEDIA .. "SoftTrackCurve"
local TEX_FRAME = {
    iron = MEDIA .. "FrameIron",
    bloodforged = MEDIA .. "FrameBloodforged",
}

-- Authored texture metrics (see tools / Media generator). Blade curve baked in.
local TEX_W, TEX_H = 128, 512
local TEX_PAD = 16
local TEX_USABLE = TEX_H - 2 * TEX_PAD
local TEX_CX = 72
local TEX_AUTHOR_SCALE = TEX_USABLE / 290
local TEX_AMP = 22 * TEX_AUTHOR_SCALE
local TEX_BW = 16 * TEX_AUTHOR_SCALE

local segments = {}
local tipGlow
local ghostGate
local ghostNotchTex
local trackTex
local frameTex
local built = false
local active = false
local parentFrame
local geom = {}

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
    if trackTex then
        trackTex:Hide()
        trackTex:SetParent(nil)
        trackTex = nil
    end
    if frameTex then
        frameTex:Hide()
        frameTex:SetParent(nil)
        frameTex = nil
    end
end

local function placeCurveArt(tex, anchorX, anchorY, width, height, amplitude)
    -- Non-uniform scale so authored blade art matches live style geometry.
    local scaleY = height / TEX_USABLE
    local scaleX = amplitude / TEX_AMP
    if width and TEX_BW > 0 then
        -- Prefer width match when amp is tiny; blend so both land close.
        local scaleW = width / TEX_BW
        scaleX = (scaleX * 0.65) + (scaleW * 0.35)
    end
    local dispW = TEX_W * scaleX
    local dispH = TEX_H * scaleY
    local x = snapPixel(anchorX - TEX_CX * scaleX)
    local y = snapPixel(anchorY - TEX_PAD * scaleY)
    tex:SetSize(dispW, dispH)
    tex:ClearAllPoints()
    tex:SetPoint("BOTTOMLEFT", parentFrame, "BOTTOMLEFT", x, y)
    return scaleX, scaleY
end

local function applyFrameStyle()
    if not frameTex then
        return
    end
    local cfg = ns.Config.db
    local key = cfg.frameStyle or "iron"
    local path = TEX_FRAME[key]
    if path then
        frameTex:SetTexture(path)
        frameTex:Show()
    else
        frameTex:Hide()
    end
end

-- Build / rebuild the curved StatusBar stack. Geometry mirrors RageBar.
function FD:Build(parent, width, height, anchorX, anchorY)
    if not parent or not self:IsAvailable() then
        return
    end

    if parentFrame and parentFrame ~= parent then
        clearChildren()
        built = false
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
    local retained = cfg.tacticalMasteryRetained or 25
    local zones = cfg.zones
    local ease = interpolationMode()

    -- Single smooth background track (curved art, not per-row segments).
    trackTex = parent:CreateTexture(nil, "BACKGROUND", nil, 0)
    trackTex:SetTexture(TEX_TRACK_CURVE)
    trackTex:SetVertexColor(1, 1, 1, 1)
    placeCurveArt(trackTex, anchorX, anchorY, stroke, height, amp)
    trackTex:Show()

    -- Dense overlapping StatusBars. ~2 segments per rage-pixel of height,
    -- capped for sanity. Overlap + SoftFill alpha feather kills seams.
    local numSeg = math.min(220, math.max(80, math.floor(height * 1.75)))
    local segH = math.max(2, math.ceil((height / numSeg) * 2.4))
    local centerWidth = math.max(2, stroke)

    for i = 1, numSeg do
        local t = (i - 0.5) / numSeg
        local rageLow = ((i - 1) / numSeg) * 100
        local rageHigh = (i / numSeg) * 100
        local midRage = (rageLow + rageHigh) * 0.5
        local xOff = curveOffset(t, amp, dir)
        local xCenter = snapPixel(anchorX + xOff)
        local y = snapPixel(anchorY + t * height - segH * 0.5)

        local bar = CreateFrame("StatusBar", nil, parent)
        bar:SetSize(centerWidth, segH)
        bar:SetPoint("BOTTOM", parent, "BOTTOMLEFT", xCenter, y)
        bar:SetOrientation("HORIZONTAL")
        bar:SetStatusBarTexture(TEX_SOFT_FILL)
        -- No border / backdrop -- SoftFill carries its own edge alpha.
        if bar.SetBackdrop then
            bar:SetBackdrop(nil)
        end
        if ease then
            bar:SetMinMaxValues(rageLow, rageHigh, ease)
        else
            bar:SetMinMaxValues(rageLow, rageHigh)
        end
        bar:SetValue(0)

        local r, g, b, a = zoneColorForRage(midRage, retained, zones)
        -- Slight vertical gradient bias: brighter toward mid-bar tip of each band.
        local tipBias = 0.92 + 0.08 * (1 - math.abs(0.5 - (i / numSeg)) * 2)
        r, g, b = r * tipBias, g * tipBias, b * tipBias
        if bar.SetStatusBarColor then
            bar:SetStatusBarColor(r, g, b, a or 1)
        end
        local tex = bar:GetStatusBarTexture()
        if tex then
            tex:SetVertexColor(r, g, b, a or 1)
            if tex.SetHorizTile then tex:SetHorizTile(false) end
            if tex.SetVertTile then tex:SetVertTile(false) end
        end

        bar._rageLow = rageLow
        bar._rageHigh = rageHigh
        bar._midRage = midRage
        segments[i] = bar
    end

    -- Optional warrior frame overlay (masks residual segment edges).
    frameTex = parent:CreateTexture(nil, "OVERLAY", nil, 5)
    placeCurveArt(frameTex, anchorX, anchorY, stroke, height, amp)
    applyFrameStyle()

    -- Ghost notch visibility gate: StatusBar min=retained does the
    -- "currentRage > retained" compare at C++ level.
    if cfg.showGhostLine then
        local frac = retained / 100
        local xOff = curveOffset(frac, amp, dir)
        local leftEdgeX = anchorX + xOff - stroke * 0.5
        local yPos = anchorY + frac * height

        ghostGate = CreateFrame("StatusBar", nil, parent)
        ghostGate:SetSize(4, 8)
        ghostGate:SetPoint("CENTER", parent, "BOTTOMLEFT", leftEdgeX, yPos)
        ghostGate:SetFrameLevel((parent:GetFrameLevel() or 0) + 6)
        ghostGate:SetOrientation("VERTICAL")
        ghostGate:SetStatusBarTexture(TEX_SOFT_FILL)
        local gc = cfg.ghostLineColor
        if ghostGate.SetStatusBarColor then
            ghostGate:SetStatusBarColor(gc[1], gc[2], gc[3], gc[4] or 0.9)
        end
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
    active = true
    if not built then
        return
    end
    for _, bar in ipairs(segments) do
        bar:Show()
    end
    if trackTex then trackTex:Show() end
    applyFrameStyle()
end

function FD:IsSecretMode()
    return active and built
end

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
    local n = #segments
    for i, bar in ipairs(segments) do
        local r, g, b, a = zoneColorForRage(bar._midRage, retained, zones)
        local tipBias = 0.92 + 0.08 * (1 - math.abs(0.5 - (i / n)) * 2)
        r, g, b = r * tipBias, g * tipBias, b * tipBias
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
    applyFrameStyle()
end

function FD:ApplyFrameStyle()
    applyFrameStyle()
end

function FD:RebuildColorCurve()
    self:RecolorFromConfig()
end

function FD:HideDecisionHints(ghostNotch, ghostLine, dumpHintFS, capGlow)
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
