-- RageForge: ForeverDisplay.lua
-- Forever / Mainline-family curved rage fill that stays secret-safe in combat.
-- Loaded only by RageForge_Forever.toc / RageForge_Camelot.toc.
--
-- Technique (warcraft.wiki.gg Secret_Values + StatusBar BarValue aspect):
--   Dense stack of VERTICAL StatusBars along the blade parabola. Each owns a
--   plain rage sub-range via SetMinMaxValues(low, high) and receives (possibly
--   secret) UnitPower through SetValue. Orientation VERTICAL so fill rises
--   up the curve as rage grows (no sideways sweep). Solid SoftFill + heavy
--   overlap + disabled texel snapping removes horizontal seams. SoftTrackCurve
--   is the empty track; Iron/Bloodforged/Warlord frames (closed end caps)
--   mask residual edge jaggies. No inner highlight strip — the fill stays a
--   solid gradient. SetValue uses ExponentialEaseOut when the client has it
--   (secret-safe). Clients without that enum lerp one shared rage out of combat.

local ADDON_NAME, ns = ...
ns.ForeverDisplay = {}
local FD = ns.ForeverDisplay

local MEDIA = "Interface\\AddOns\\RageForge\\Media\\"
local TEX_SOFT_FILL = MEDIA .. "SoftFill"
local TEX_TRACK_CURVE = MEDIA .. "SoftTrackCurve"
local TEX_FRAME = {
    iron = MEDIA .. "FrameIron",
    bloodforged = MEDIA .. "FrameBloodforged",
    warlord = MEDIA .. "FrameWarlord",
}

-- Authored at 2x the 290px bar so a 2-screen-px accent is 4 texels
-- (source = 2 * texHeight / displayHeight). t=0 at bottom of TGA.
local TEX_W, TEX_H = 512, 640
local TEX_PAD = 30
local TEX_USABLE = TEX_H - 2 * TEX_PAD
local TEX_CX = 256
local TEX_AUTHOR_SCALE = TEX_USABLE / 290
local TEX_AMP = 22 * TEX_AUTHOR_SCALE
local TEX_BW = 16 * TEX_AUTHOR_SCALE

local segments = {}
local ghostGate
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

-- Kill texel snapping / edge shimmer that shows as horizontal seams.
local function disableTexelSnap(tex)
    if not tex then return end
    if tex.SetSnapToPixelGrid then
        tex:SetSnapToPixelGrid(false)
    end
    if tex.SetTexelSnappingBias then
        tex:SetTexelSnappingBias(0)
    end
    if tex.SetHorizTile then tex:SetHorizTile(false) end
    if tex.SetVertTile then tex:SetVertTile(false) end
end

local function styleStatusBar(bar, texturePath)
    bar:SetStatusBarTexture(texturePath)
    if bar.SetBackdrop then
        bar:SetBackdrop(nil)
    end
    local tex = bar:GetStatusBarTexture()
    disableTexelSnap(tex)
    if bar.SetSnapToPixelGrid then
        bar:SetSnapToPixelGrid(false)
    end
    if bar.SetTexelSnappingBias then
        bar:SetTexelSnappingBias(0)
    end
    return tex
end

function FD:IsAvailable()
    return type(CreateFrame) == "function"
end

function FD:IsActive()
    return active
end

-- Outer rim clearance in screen px (icons must sit outside this).
function FD:GetFrameClearance()
    local cfg = ns.Config and ns.Config.db
    local key = (cfg and cfg.frameStyle) or "warlord"
    local info = ns.Config and ns.Config.FRAME_STYLES and ns.Config.FRAME_STYLES[key]
    if info and info.clearance then
        return info.clearance
    end
    if key == "none" then
        return 0
    end
    return 12
end

local function clearChildren()
    for _, bar in ipairs(segments) do
        bar:Hide()
        bar:SetParent(nil)
    end
    wipe(segments)
    if ghostGate then
        ghostGate:Hide()
        ghostGate:SetParent(nil)
        ghostGate = nil
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
    local scaleY = height / TEX_USABLE
    local scaleX = amplitude / TEX_AMP
    if width and TEX_BW > 0 then
        local scaleW = width / TEX_BW
        scaleX = (scaleX * 0.65) + (scaleW * 0.35)
    end
    tex:SetSize(TEX_W * scaleX, TEX_H * scaleY)
    tex:ClearAllPoints()
    tex:SetPoint(
        "BOTTOMLEFT",
        parentFrame,
        "BOTTOMLEFT",
        snapPixel(anchorX - TEX_CX * scaleX),
        snapPixel(anchorY - TEX_PAD * scaleY)
    )
    disableTexelSnap(tex)
    return scaleX, scaleY
end

-- Trilinear keeps the ~2px accent continuous when the UI scale drops to 0.64.
-- The 4-arg form is Forever/Mainline; Classic clients fall back to the path.
local function setCurveTexture(tex, path)
    if not tex or not path then
        return
    end
    local ok = pcall(tex.SetTexture, tex, path, "CLAMP", "CLAMP", "TRILINEAR")
    if not ok then
        tex:SetTexture(path)
    end
    disableTexelSnap(tex)
end

local function applyFrameStyle()
    if not frameTex then
        return
    end
    local cfg = ns.Config.db
    local key = cfg.frameStyle or "warlord"
    local path = TEX_FRAME[key]
    if path then
        setCurveTexture(frameTex, path)
        frameTex:Show()
    else
        frameTex:Hide()
    end
end

-- Assigned below. Declared here so Build closes over the local, not a global.
local ensureSmoothDriver

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

    trackTex = parent:CreateTexture(nil, "BACKGROUND", nil, 0)
    setCurveTexture(trackTex, TEX_TRACK_CURVE)
    placeCurveArt(trackTex, anchorX, anchorY, stroke, height, amp)
    trackTex:Show()

    -- Dense VERTICAL StatusBars. Spacing ~0.45px of bar height; each segment
    -- is ~3x taller so neighbors fully overlap — solid SoftFill has no edge
    -- darkening, so overlapped regions stay continuous (no striations).
    local numSeg = math.min(280, math.max(120, math.floor(height * 2.2)))
    local step = height / numSeg
    local segH = math.max(3, math.ceil(step * 3.2))
    local centerWidth = math.max(2, stroke + 1)

    for i = 1, numSeg do
        local t = (i - 0.5) / numSeg
        local rageLow = ((i - 1) / numSeg) * 100
        local rageHigh = (i / numSeg) * 100
        local midRage = (rageLow + rageHigh) * 0.5
        local xOff = curveOffset(t, amp, dir)
        local xCenter = anchorX + xOff
        -- Do NOT snap segment Y — snapping caused visible seam ladders.
        local y = anchorY + t * height - segH * 0.5

        local bar = CreateFrame("StatusBar", nil, parent)
        bar:SetSize(centerWidth, segH)
        bar:SetPoint("BOTTOM", parent, "BOTTOMLEFT", xCenter, y)
        bar:SetOrientation("VERTICAL")
        local tex = styleStatusBar(bar, TEX_SOFT_FILL)
        bar:SetMinMaxValues(rageLow, rageHigh)
        bar:SetValue(0)

        local r, g, b, a = zoneColorForRage(midRage, retained, zones)
        if bar.SetStatusBarColor then
            bar:SetStatusBarColor(r, g, b, a or 1)
        end
        if tex then
            tex:SetVertexColor(r, g, b, a or 1)
        end

        bar._rageLow = rageLow
        bar._rageHigh = rageHigh
        bar._midRage = midRage
        segments[i] = bar
    end

    frameTex = parent:CreateTexture(nil, "OVERLAY", nil, 5)
    placeCurveArt(frameTex, anchorX, anchorY, stroke, height, amp)
    applyFrameStyle()

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
        styleStatusBar(ghostGate, TEX_SOFT_FILL)
        local gc = cfg.ghostLineColor
        if ghostGate.SetStatusBarColor then
            ghostGate:SetStatusBarColor(gc[1], gc[2], gc[3], gc[4] or 0.9)
        end
        ghostGate:SetMinMaxValues(retained, retained + 0.05)
        ghostGate:SetValue(0)
        ghostGate:Show()
    end

    ensureSmoothDriver(parent)

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

-- One shared displayed rage so every segment's top edge stays on the same
-- curve sample. Per-bar timers would stair-step the rim.
local shownRage = 0
local targetRage = 0
local luaLerp = false
local smoothFrame

local function valueIsSecret(v)
    if type(issecretvalue) == "function" and issecretvalue(v) then
        return true
    end
    return type(v) ~= "number"
end

local function pushValue(value, withEase)
    local ease = withEase and interpolationMode() or nil
    for _, bar in ipairs(segments) do
        if ease then
            bar:SetValue(value, ease)
        else
            bar:SetValue(value)
        end
    end
    if ghostGate then
        if ease then
            ghostGate:SetValue(value, ease)
        else
            ghostGate:SetValue(value)
        end
    end
end

local function onSmooth(_, dt)
    if not luaLerp or not built then
        return
    end
    if not dt or dt <= 0 then
        dt = 0.016
    end
    local diff = targetRage - shownRage
    if diff > -0.05 and diff < 0.05 then
        if shownRage ~= targetRage then
            shownRage = targetRage
            pushValue(shownRage, false)
        end
        return
    end
    -- Exponential ease-out: same feel as StatusBarInterpolation.ExponentialEaseOut.
    local k = 1 - math.exp(-8 * dt)
    if k > 1 then
        k = 1
    end
    shownRage = shownRage + diff * k
    pushValue(shownRage, false)
end

ensureSmoothDriver = function(parent)
    if not smoothFrame then
        smoothFrame = CreateFrame("Frame")
        smoothFrame:SetScript("OnUpdate", onSmooth)
    end
    smoothFrame:SetParent(parent)
    smoothFrame:Show()
end

function FD:Update(power, powerMax, powerType)
    if not built or power == nil then
        return
    end

    local ease = interpolationMode()
    -- Engine easing works on secret values and keeps every segment on the
    -- same target. Lua cannot read a secret, so it cannot lerp in combat.
    if ease or valueIsSecret(power) then
        luaLerp = false
        pushValue(power, ease ~= nil)
        return
    end

    if not luaLerp then
        shownRage = power
    end
    targetRage = power
    luaLerp = true
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
