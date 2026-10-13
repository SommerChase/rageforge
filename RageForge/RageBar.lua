-- RageForge: RageBar.lua
-- The smart curved rage bar.
--
-- Rendering approach (v0.7):
-- The bar's fill is a stack of 1-pixel-tall horizontal rows, one per
-- logical pixel of barHeight. Each row has an opaque center and softer
-- left/right feather textures. The row center is snapped to whole pixels
-- to avoid sub-pixel sampling shimmer, while the feather strips soften the
-- staircase you naturally get when approximating a curve with rectangular
-- UI textures. This is the strongest no-art approach WoW Classic gives us.
--
-- Why not CreateLine? CreateLine is anti-aliased and perfect for thin
-- single-stroke geometry, but a chain of thick CreateLines does not seam
-- cleanly at joints: each line's thickness is perpendicular to its
-- direction, so on sloped sections the line is *narrower* than its peers,
-- producing visible horizontal stripes. Slices avoid the issue entirely.
--
-- Geometry note: each row is centered on the bar's centerline at its t.
-- Container reserves curveAmplitude + barWidth/2 of horizontal room on
-- the bowing side, plus tick/label space on the other.

local ADDON_NAME, ns = ...
ns.RageBar = {}
local Bar = ns.RageBar

-- All RageForge bar text uses Prototype for a sharper addon-style UI. The
-- bundled font ships with Prototype.txt for attribution. SKURRI.TTF stays as
-- a built-in fallback if the file is ever missing on disk.
local FONT_PATH = "Interface\\AddOns\\RageForge\\Fonts\\Prototype.ttf"
local FALLBACK_FONT_PATH = "Fonts\\SKURRI.TTF"
local MEDIA = "Interface\\AddOns\\RageForge\\Media\\"
local TEX_FRAME = {
    iron = MEDIA .. "FrameIron",
    bloodforged = MEDIA .. "FrameBloodforged",
    warlord = MEDIA .. "FrameWarlord",
}
-- Authored SoftTrackCurve / Frame* metrics (blade curve; t=0 at TGA bottom).
-- 2x the 290px bar so trim lines stay ~2 screen px after filtering.
local TEX_W, TEX_H = 512, 640
local TEX_PAD = 30
local TEX_USABLE = TEX_H - 2 * TEX_PAD
local TEX_CX = 256
local TEX_AUTHOR_SCALE = TEX_USABLE / 290
local TEX_AMP = 22 * TEX_AUTHOR_SCALE
local TEX_BW = 16 * TEX_AUTHOR_SCALE

-- Threshold label colors by meaning (25 = Tactical Mastery retain).
local TICK_COLORS = {
    [15] = { 0.85, 0.78, 0.55 },
    [25] = { 0.78, 0.61, 0.43 }, -- warrior class tan #C69B6D
    [50] = { 1.00, 0.62, 0.22 },
    [75] = { 0.95, 0.28, 0.18 },
}

local function frameClearancePx()
    if ns.ForeverDisplay and ns.ForeverDisplay.GetFrameClearance then
        return ns.ForeverDisplay:GetFrameClearance()
    end
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

local function setFont(fs, size, flags)
    if not fs:SetFont(FONT_PATH, size, flags) then
        fs:SetFont(FALLBACK_FONT_PATH, size, flags)
    end
end

-- Internal state.
local container         -- master frame; owns drag, scale, position
local slices = {}       -- stack of 1px-tall center textures = the fill
local sliceLeftFeathers = {}
local sliceRightFeathers = {}
local sliceMidRage = {} -- rage value at the midpoint of each slice
local tickArtifacts = {}-- { tick, label } pairs to show/hide together
local stanceArtifacts = {} -- cropped stance icons following the bar's left edge
local ghostLine         -- horizontal line left of the bar at retained level
local ghostNotch        -- bright notch ON the bar's left edge at retained level
local dumpHintFS        -- "-X" label showing rage cost of dancing right now
local classicFrameTex   -- Iron/Bloodforged overlay when ForeverDisplay is absent
local battleShoutFrame
local battleShoutIcon
local battleShoutBorder
local battleShoutTimerFS
local capGlow
local numberFS
local labelFS

local function snapPixel(v)
    return math.floor(v + 0.5)
end

local function setCurveTexture(tex, path)
    if not tex or not path then
        return
    end
    local ok = pcall(tex.SetTexture, tex, path, "CLAMP", "CLAMP", "TRILINEAR")
    if not ok then
        tex:SetTexture(path)
    end
    if tex.SetSnapToPixelGrid then
        tex:SetSnapToPixelGrid(false)
    end
    if tex.SetTexelSnappingBias then
        tex:SetTexelSnappingBias(0)
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
        container,
        "BOTTOMLEFT",
        snapPixel(anchorX - TEX_CX * scaleX),
        snapPixel(anchorY - TEX_PAD * scaleY)
    )
end

local function applyClassicFrameStyle()
    if not classicFrameTex then
        return
    end
    local cfg = ns.Config.db
    local path = TEX_FRAME[cfg.frameStyle or "warlord"]
    if path then
        setCurveTexture(classicFrameTex, path)
        classicFrameTex:Show()
    else
        classicFrameTex:Hide()
    end
end

local displayedRage = 0
local currentRage = 0
local maxRage = 100
local activeStance = 0
local battleShoutVisible = false
local battleShoutFlash = false
local battleShoutRemaining = 0
local battleShoutWasFound = false
local battleShoutDurationStartedAt = nil
local battleShoutLastDuration = nil
local auraCheckElapsed = 0

-- Fallback textures keyed by stance spellID when GetShapeshiftFormInfo
-- returns a numeric fileID we still want a known path, or for debugging.
-- Not used to decide which stances are shown -- learning state comes from
-- GetNumShapeshiftForms / GetShapeshiftFormInfo (+ IsSpellKnown when present).
local STANCE_FALLBACK_BY_SPELL = {
    [2457] = "Interface\\Icons\\Ability_Warrior_OffensiveStance", -- Battle
    [71]   = "Interface\\Icons\\Ability_Warrior_DefensiveStance", -- Defensive
    [2458] = "Interface\\Icons\\Ability_Racial_Avatar",           -- Berserker
}
local MAX_STANCE_SLOTS = 3

local BATTLE_SHOUT_SPELL_ID = 6673
local BATTLE_SHOUT_ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"
local BATTLE_SHOUT_ICON_LOWER = string.lower(BATTLE_SHOUT_ICON)
local BATTLE_SHOUT_SPELL_IDS = {
    [6673] = true,
    [5242] = true,
    [6192] = true,
    [11549] = true,
    [11550] = true,
    [11551] = true,
    [25289] = true,
    [2048] = true,
}

-- Resolved after Compat loads (TOC order). Forever is missing GetSpellInfo.
local BATTLE_SHOUT_NAME = "Battle Shout"
local rageSecretMode = false
local lastAccessibleRage = 0

local function resolveBattleShoutName()
    if ns.Compat and ns.Compat.GetSpellName then
        BATTLE_SHOUT_NAME = ns.Compat.GetSpellName(BATTLE_SHOUT_SPELL_ID) or BATTLE_SHOUT_NAME
    elseif type(GetSpellInfo) == "function" then
        BATTLE_SHOUT_NAME = GetSpellInfo(BATTLE_SHOUT_SPELL_ID) or BATTLE_SHOUT_NAME
    end
end

-- Square-crop only. Icons stay upright (rotation 0); positions are unchanged.
local function setStanceIconTexCoord(icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if icon.SetRotation then
        icon:SetRotation(0)
    end
end

local function clamp(v, minVal, maxVal)
    if v < minVal then return minVal end
    if v > maxVal then return maxVal end
    return v
end

local function lerp(a, b, t)
    return a + (b - a) * t
end

local function mixColor(a, b, t)
    t = clamp(t, 0, 1)
    return
        lerp(a[1], b[1], t),
        lerp(a[2], b[2], t),
        lerp(a[3], b[3], t),
        lerp(a[4], b[4], t)
end

local function isBattleShoutAura(name, icon)
    if name and BATTLE_SHOUT_NAME and name == BATTLE_SHOUT_NAME then
        return true
    end
    if name and string.find(string.lower(name), "battle shout", 1, true) then
        return true
    end
    return icon and string.lower(icon) == BATTLE_SHOUT_ICON_LOWER
end

local function isBattleShoutSpellcast(value)
    if type(value) == "number" then
        return BATTLE_SHOUT_SPELL_IDS[value] == true
    elseif type(value) == "string" then
        return string.find(string.lower(value), "battle shout", 1, true) ~= nil
    end
    return false
end

local function setRowColor(i, r, g, b, a, edgeAlpha)
    local center = slices[i]
    local left = sliceLeftFeathers[i]
    local right = sliceRightFeathers[i]
    if not center then return end

    center:SetColorTexture(r, g, b, a)

    if left and right then
        local alpha = a * edgeAlpha
        left:SetColorTexture(r, g, b, alpha)
        right:SetColorTexture(r, g, b, alpha)
    end
end

-- Returns a smoothly blended zone color for a rage value. The retained band
-- stays green, then colors interpolate through gold -> orange -> blood red
-- instead of snapping at hard thresholds.
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

-- Parabolic bow: 0 at endpoints, peaks at t=0.5.
local function curveOffset(t, amplitude, direction)
    local p = 1 - (2 * t - 1) ^ 2
    return amplitude * p * direction
end

local function setSlicesShown(shown)
    for i, s in ipairs(slices) do
        if shown then
            s:Show()
            if sliceLeftFeathers[i] then sliceLeftFeathers[i]:Show() end
            if sliceRightFeathers[i] then sliceRightFeathers[i]:Show() end
        else
            s:Hide()
            if sliceLeftFeathers[i] then sliceLeftFeathers[i]:Hide() end
            if sliceRightFeathers[i] then sliceRightFeathers[i]:Hide() end
        end
    end
end

-- Tear down and rebuild geometry (style / width / height / curve changes).
-- Prefer this over /reload when switching Ribbon / Blade / Classic.
function Bar:Rebuild()
    if container then
        container:Hide()
        container:SetParent(nil)
        container = nil
    end

    wipe(slices)
    wipe(sliceLeftFeathers)
    wipe(sliceRightFeathers)
    wipe(sliceMidRage)
    wipe(tickArtifacts)
    wipe(stanceArtifacts)

    ghostLine = nil
    ghostNotch = nil
    dumpHintFS = nil
    classicFrameTex = nil
    battleShoutFrame = nil
    battleShoutIcon = nil
    battleShoutBorder = nil
    battleShoutTimerFS = nil
    capGlow = nil
    numberFS = nil
    labelFS = nil
    rageSecretMode = false

    if ns.ForeverDisplay then
        -- Force ForeverDisplay to treat the next Build as fresh.
        if ns.ForeverDisplay.Rebuild then
            -- parent cleared; Build() below recreates against the new container.
        end
    end

    self:Build()
    self:Update()
    return true
end

function Bar:Build()
    if container then return end

    resolveBattleShoutName()

    local cfg = ns.Config.db
    local clearance = frameClearancePx()
    -- Stance rail + dump hint + frame rim clearance so icons never clip the forge.
    local leftGutter = 66 + clearance
    local barCenterlineX = leftGutter + cfg.barCurveAmplitude + cfg.barWidth * 0.5
    local containerWidth = barCenterlineX + cfg.barWidth * 0.5 + clearance + 48
    local containerHeight = cfg.barHeight + 64
    local barAnchorY = 36

    container = CreateFrame("Frame", "RageForgeBar", UIParent)
    container._frameClearance = clearance
    container:SetSize(containerWidth, containerHeight)
    container:SetPoint(cfg.position.point, UIParent, cfg.position.relPoint, cfg.position.x, cfg.position.y)
    container:SetScale(cfg.scale)
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:EnableMouse(not cfg.locked)
    container:RegisterForDrag("LeftButton")
    container:SetScript("OnDragStart", function(frame)
        if not cfg.locked then frame:StartMoving() end
    end)
    container:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local point, _, relPoint, x, y = frame:GetPoint()
        cfg.position = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    -- Build the slice stack. Each row is center fill + soft edge feathers.
    -- We bake the rage value of each slice into sliceMidRage so Render()
    -- doesn't recompute it per frame.
    local NUM_SLICES = math.floor(cfg.barHeight)
    local emptyC = cfg.zones.empty
    local edgeWidth = cfg.barEdgeFeatherWidth or 2
    local centerWidth = math.max(1, cfg.barWidth - edgeWidth * 2)
    for i = 1, NUM_SLICES do
        local t = (i - 0.5) / NUM_SLICES
        local xOff = curveOffset(t, cfg.barCurveAmplitude, cfg.barCurveDirection)
        local xCenter = snapPixel(barCenterlineX + xOff)
        local y = barAnchorY + (i - 1)

        local left = container:CreateTexture(nil, "ARTWORK", nil, 0)
        left:SetSize(edgeWidth, 1)
        left:SetPoint("BOTTOMRIGHT", container, "BOTTOMLEFT", xCenter - centerWidth * 0.5, y)
        left:SetColorTexture(emptyC[1], emptyC[2], emptyC[3], emptyC[4] * (cfg.barEdgeAlpha or 0.42))

        local s = container:CreateTexture(nil, "ARTWORK", nil, 1)
        s:SetSize(centerWidth, 1)
        s:SetPoint("BOTTOM", container, "BOTTOMLEFT",
            xCenter,
            y)
        s:SetColorTexture(emptyC[1], emptyC[2], emptyC[3], emptyC[4])

        local right = container:CreateTexture(nil, "ARTWORK", nil, 0)
        right:SetSize(edgeWidth, 1)
        right:SetPoint("BOTTOMLEFT", s, "BOTTOMRIGHT", 0, 0)
        right:SetColorTexture(emptyC[1], emptyC[2], emptyC[3], emptyC[4] * (cfg.barEdgeAlpha or 0.42))

        sliceLeftFeathers[i] = left
        slices[i] = s
        sliceRightFeathers[i] = right
        sliceMidRage[i] = t * 100
    end

    -- Stance rail slots (max 3). Visibility + texture + packed layout are
    -- driven by learned shapeshift forms in RefreshStanceIcons -- never by
    -- hardcoded level checks.
    local iconSize = cfg.stanceIconSize or 24
    local railCenterY = snapPixel(barAnchorY + cfg.barHeight * 0.50)
    container._railCenterY = railCenterY
    container._stanceIconSize = iconSize
    for i = 1, MAX_STANCE_SLOTS do
        local icon = container:CreateTexture(nil, "OVERLAY", nil, 1)
        icon:SetSize(iconSize, iconSize)
        setStanceIconTexCoord(icon)
        icon:SetAlpha(1)
        icon:Hide()

        local border = container:CreateTexture(nil, "OVERLAY", nil, 2)
        border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        border:SetBlendMode("ADD")
        border:SetSize(iconSize * 1.75, iconSize * 1.75)
        border:SetPoint("CENTER", icon, "CENTER", 0, 0)
        border:SetVertexColor(1.0, 0.82, 0.18, 1.0)
        border:Hide()

        stanceArtifacts[i] = { icon = icon, border = border, formIndex = nil }
    end

    -- Threshold ticks live OUTSIDE the bar to the right. Bright notches +
    -- large outlined labels; 25 uses warrior class tan (TM retain).
    for _, rageValue in ipairs(cfg.thresholdTicks) do
        local frac = rageValue / 100
        local xOff = curveOffset(frac, cfg.barCurveAmplitude, cfg.barCurveDirection)
        local rightEdgeX = barCenterlineX + xOff + cfg.barWidth * 0.5 + clearance
        local tc = TICK_COLORS[rageValue] or { 0.90, 0.82, 0.55 }

        local tick = container:CreateTexture(nil, "OVERLAY", nil, 3)
        tick:SetSize(12, 3)
        tick:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", rightEdgeX + 2, barAnchorY + frac * cfg.barHeight - 1)
        tick:SetColorTexture(tc[1], tc[2], tc[3], 0.95)

        local label = container:CreateFontString(nil, "OVERLAY")
        setFont(label, 14, "OUTLINE")
        label:SetText(tostring(rageValue))
        label:SetPoint("LEFT", tick, "RIGHT", 4, 0)
        label:SetTextColor(tc[1], tc[2], tc[3], 1)

        tickArtifacts[#tickArtifacts + 1] = { tick = tick, label = label }
    end

    -- Ghost-line family: notch on the bar's left edge at retained level,
    -- horizontal line extending left, and the dump-hint label at the end.
    -- Hidden by Render() when there's no decision (currentRage <= retained).
    ghostNotch = container:CreateTexture(nil, "OVERLAY", nil, 2)
    ghostNotch:SetSize(3, 6)
    ghostNotch:SetColorTexture(unpack(cfg.ghostLineColor))
    ghostNotch:Hide()

    ghostLine = container:CreateTexture(nil, "OVERLAY", nil, 1)
    ghostLine:SetSize(10, 2)
    ghostLine:SetColorTexture(unpack(cfg.ghostLineColor))
    ghostLine:Hide()

    -- Dump hint: "-X" label = rage you'd lose dancing right now.
    dumpHintFS = container:CreateFontString(nil, "OVERLAY")
    setFont(dumpHintFS, 14, "OUTLINE")
    dumpHintFS:SetJustifyH("RIGHT")
    dumpHintFS:SetText("")
    dumpHintFS:SetTextColor(1, 0.6, 0.25, 1)
    dumpHintFS:Hide()

    -- Battle Shout reminder: bottom-left utility icon. Hidden while the buff
    -- is healthy; shown/flashing when missing or under the configured warning
    -- threshold.
    local shoutSize = cfg.battleShoutIconSize or 32
    local bottomLeftEdgeX = barCenterlineX
        + curveOffset(0, cfg.barCurveAmplitude, cfg.barCurveDirection)
        - cfg.barWidth * 0.5
        - clearance

    battleShoutFrame = CreateFrame("Frame", nil, container)
    battleShoutFrame:SetSize(shoutSize, shoutSize)
    battleShoutFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMLEFT", bottomLeftEdgeX - 12, barAnchorY)
    battleShoutFrame:Hide()

    battleShoutIcon = battleShoutFrame:CreateTexture(nil, "ARTWORK")
    battleShoutIcon:SetAllPoints(battleShoutFrame)
    battleShoutIcon:SetTexture(BATTLE_SHOUT_ICON)
    battleShoutIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if battleShoutIcon.SetRotation then
        battleShoutIcon:SetRotation(0)
    end

    battleShoutBorder = battleShoutFrame:CreateTexture(nil, "OVERLAY")
    battleShoutBorder:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    battleShoutBorder:SetBlendMode("ADD")
    battleShoutBorder:SetSize(shoutSize * 1.75, shoutSize * 1.75)
    battleShoutBorder:SetPoint("CENTER", battleShoutFrame, "CENTER", 0, 0)
    battleShoutBorder:SetVertexColor(1.0, 0.30, 0.18, 1.0)

    battleShoutTimerFS = battleShoutFrame:CreateFontString(nil, "OVERLAY")
    setFont(battleShoutTimerFS, 14, "OUTLINE")
    battleShoutTimerFS:SetPoint("CENTER", battleShoutFrame, "CENTER", 0, 0)
    battleShoutTimerFS:SetTextColor(1, 0.95, 0.55, 1)
    battleShoutTimerFS:SetText("")

    -- Cap glow: top of the bar pulses gold when within 5 rage of cap.
    capGlow = container:CreateTexture(nil, "OVERLAY", nil, 2)
    capGlow:SetSize(cfg.barWidth + 14, 6)
    do
        local xOff = curveOffset(1, cfg.barCurveAmplitude, cfg.barCurveDirection)
        capGlow:SetPoint("BOTTOM", container, "BOTTOMLEFT", barCenterlineX + xOff, barAnchorY + cfg.barHeight + 2)
    end
    capGlow:SetColorTexture(0.95, 0.78, 0.30, 0)
    capGlow:Hide()

    -- Big rage number, anchored above the top of the bar (follows the curve).
    numberFS = container:CreateFontString(nil, "OVERLAY")
    setFont(numberFS, cfg.numberFontSize, "OUTLINE")
    numberFS:SetText("0")
    do
        local xOff = curveOffset(1, cfg.barCurveAmplitude, cfg.barCurveDirection)
        numberFS:SetPoint("BOTTOM", container, "BOTTOMLEFT", barCenterlineX + xOff, barAnchorY + cfg.barHeight + 8)
    end
    numberFS:SetTextColor(0.78, 0.61, 0.43)

    -- "RAGE" label below the bar. Doubles as drag affordance: the label
    -- changes to "RAGE -- drag" while the bar is unlocked. No background
    -- box, no chrome -- just a hint that this thing is movable now.
    labelFS = container:CreateFontString(nil, "OVERLAY")
    setFont(labelFS, 11, "OUTLINE")
    labelFS:SetText("RAGE")
    do
        local xOff = curveOffset(0, cfg.barCurveAmplitude, cfg.barCurveDirection)
        labelFS:SetPoint("TOP", container, "BOTTOMLEFT", barCenterlineX + xOff, barAnchorY - 6)
    end
    labelFS:SetTextColor(0.78, 0.72, 0.55, 0.95)

    -- Cache values used by Render() per-tick.
    container._barCenterlineX = barCenterlineX
    container._barAnchorY = barAnchorY

    -- Forever: curved StatusBar segment stack (secret-safe). Owns the fill
    -- in and out of combat so the curve never collapses to a straight bar.
    -- Classic Anniversary TOC does not load ForeverDisplay.lua.
    if ns.ForeverDisplay and ns.ForeverDisplay.Build then
        ns.ForeverDisplay:Build(
            container,
            cfg.barWidth,
            cfg.barHeight,
            barCenterlineX,
            barAnchorY
        )
        setSlicesShown(false)
        ns.ForeverDisplay:SetSecretMode(true)
    else
        -- TBC / Classic: optional warrior frame overlay over the slice stack.
        classicFrameTex = container:CreateTexture(nil, "OVERLAY", nil, 5)
        placeCurveArt(
            classicFrameTex,
            barCenterlineX,
            barAnchorY,
            cfg.barWidth,
            cfg.barHeight,
            cfg.barCurveAmplitude or 16
        )
        applyClassicFrameStyle()
    end

    self:UpdateStance()
    self:UpdateAuras()
    self:ApplyConfig()
end

function Bar:ApplyFrameStyle()
    if ns.ForeverDisplay and ns.ForeverDisplay.ApplyFrameStyle then
        ns.ForeverDisplay:ApplyFrameStyle()
    end
    applyClassicFrameStyle()
end

function Bar:ApplyConfig()
    if not container then return end
    local cfg = ns.Config.db

    container:SetScale(cfg.scale)
    container:ClearAllPoints()
    container:SetPoint(cfg.position.point, UIParent, cfg.position.relPoint, cfg.position.x, cfg.position.y)
    container:EnableMouse(not cfg.locked)

    -- Drag affordance lives in the RAGE label, not a background tint.
    -- "\194\183" is the UTF-8 encoding of U+00B7 MIDDLE DOT.
    if labelFS then
        if cfg.locked then
            labelFS:SetText("RAGE")
            labelFS:SetTextColor(0.78, 0.72, 0.55, 0.95)
        else
            labelFS:SetText("RAGE \194\183 drag")
            labelFS:SetTextColor(0.55, 0.78, 0.95, 0.95) -- light blue: "I'm grabable now"
        end
    end

    -- Ghost-line family: shown/hidden by Render() based on live rage value.
    -- ApplyConfig only honors the master toggle.
    if not cfg.showGhostLine then
        if ghostLine then ghostLine:Hide() end
        if ghostNotch then ghostNotch:Hide() end
        if dumpHintFS then dumpHintFS:Hide() end
    end

    self:RefreshStanceIcons()

    for _, t in ipairs(tickArtifacts) do
        if cfg.showTicks then t.tick:Show(); t.label:Show()
        else t.tick:Hide(); t.label:Hide() end
    end

    if numberFS then
        if cfg.showNumber then numberFS:Show() else numberFS:Hide() end
        setFont(numberFS, cfg.numberFontSize, "OUTLINE")
    end

    if ns.ForeverDisplay and ns.ForeverDisplay.RebuildColorCurve then
        ns.ForeverDisplay:RebuildColorCurve()
    end
    self:ApplyFrameStyle()

    self:UpdateAuras()

    self:Update()
end

function Bar:RefreshStanceIcons()
    if not container then return end
    local cfg = ns.Config.db
    local _, class = UnitClass("player")
    local iconSize = container._stanceIconSize or cfg.stanceIconSize or 24
    local railCenterY = container._railCenterY
        or snapPixel(container._barAnchorY + cfg.barHeight * 0.50)
    local barAnchorY = container._barAnchorY or 36
    local barCenterlineX = container._barCenterlineX or 0

    -- Hide everything when disabled or non-warrior.
    if not cfg.showStanceIcons or class ~= "WARRIOR" then
        for _, art in ipairs(stanceArtifacts) do
            art.icon:Hide()
            if art.border then art.border:Hide() end
            art.formIndex = nil
        end
        return
    end

    local Compat = ns.Compat
    local learned = (Compat and Compat.GetLearnedStances and Compat.GetLearnedStances()) or {}
    local count = #learned

    for slot = 1, MAX_STANCE_SLOTS do
        local art = stanceArtifacts[slot]
        if not art then break end
        local icon = art.icon
        local border = art.border

        if slot <= count then
            local info = learned[slot]
            local tex = info.icon
            if type(tex) ~= "string" and info.spellId and STANCE_FALLBACK_BY_SPELL[info.spellId] then
                tex = STANCE_FALLBACK_BY_SPELL[info.spellId]
            end
            icon:SetTexture(tex)
            setStanceIconTexCoord(icon)
            if icon.SetDesaturated then icon:SetDesaturated(false) end
            icon:SetVertexColor(1, 1, 1, 1)

            -- Pack tightly around the rail center — no gaps for locked stances.
            local iconY = railCenterY + ((count + 1) * 0.5 - slot) * iconSize
            local frac = clamp((iconY - barAnchorY) / math.max(1, cfg.barHeight), 0, 1)
            local xOff = curveOffset(frac, cfg.barCurveAmplitude, cfg.barCurveDirection)
            local clearance = container._frameClearance or frameClearancePx()
            local leftEdgeX = snapPixel(barCenterlineX + xOff - cfg.barWidth * 0.5 - clearance)
            icon:ClearAllPoints()
            icon:SetPoint("RIGHT", container, "BOTTOMLEFT", leftEdgeX - 2, iconY)
            icon:Show()

            art.formIndex = info.index
            local isActive = info.active or (activeStance == info.index)
            if isActive then
                icon:SetAlpha(1.0)
                if border then
                    border:ClearAllPoints()
                    border:SetPoint("CENTER", icon, "CENTER", 0, 0)
                    border:Show()
                end
            else
                icon:SetAlpha(0.68)
                if border then border:Hide() end
            end
        else
            icon:Hide()
            if border then border:Hide() end
            art.formIndex = nil
        end
    end
end

function Bar:UpdateStance()
    activeStance = (GetShapeshiftForm and GetShapeshiftForm()) or 0
    self:RefreshStanceIcons()
end

function Bar:Update()
    if not container then return end
    local Compat = ns.Compat
    local rageType = (Compat and Compat.RagePowerType and Compat.RagePowerType())
        or ((Enum and Enum.PowerType and Enum.PowerType.Rage) or 1)

    local power = UnitPower("player", rageType) or 0
    local powerMax = UnitPowerMax("player", rageType) or 100

    local powerUsable = (not Compat) or Compat.CanUseNumber(power)
    local maxUsable = (not Compat) or Compat.CanUseNumber(powerMax)

    -- ForeverDisplay owns the curved fill whenever it is loaded. Segment
    -- StatusBars accept secret SetValue (wiki Secret_Values / BarValue aspect),
    -- so combat and out-of-combat share one curved renderer.
    if ns.ForeverDisplay and ns.ForeverDisplay.IsActive and ns.ForeverDisplay:IsActive() then
        rageSecretMode = true
        setSlicesShown(false)
        currentRage = power
        if maxUsable then
            if powerMax <= 0 then powerMax = 100 end
            maxRage = powerMax
        elseif maxRage <= 0 then
            maxRage = 100
        end
        if powerUsable then
            lastAccessibleRage = power
        end
        ns.ForeverDisplay:Update(power, maxRage, rageType)
        return
    end

    rageSecretMode = false

    if powerUsable then
        currentRage = power
        lastAccessibleRage = power
    else
        currentRage = lastAccessibleRage
    end

    if maxUsable then
        maxRage = powerMax
        if maxRage <= 0 then maxRage = 100 end
    elseif maxRage <= 0 then
        maxRage = 100
    end
end

function Bar:UpdateAuras()
    if not container or not battleShoutFrame then return end

    local cfg = ns.Config.db
    local _, class = UnitClass("player")
    if not cfg.showBattleShoutReminder or class ~= "WARRIOR" or UnitIsDeadOrGhost("player") then
        battleShoutVisible = false
        battleShoutFlash = false
        battleShoutRemaining = 0
        if battleShoutTimerFS then battleShoutTimerFS:SetText("") end
        battleShoutFrame:Hide()
        return
    end

    local found = false
    local remaining = 0
    local icon = BATTLE_SHOUT_ICON
    local now = GetTime()
    local Compat = ns.Compat
    local aurasSecret = Compat and Compat.ShouldAurasBeSecret and Compat.ShouldAurasBeSecret()

    -- When Forever marks auras secret in combat, skip reading aura payloads
    -- and rely on the local UNIT_SPELLCAST_SUCCEEDED countdown instead.
    if aurasSecret then
        if battleShoutDurationStartedAt and battleShoutLastDuration then
            found = true
            remaining = battleShoutLastDuration - (now - battleShoutDurationStartedAt)
            if remaining <= 0 then
                found = false
                remaining = 0
                battleShoutDurationStartedAt = nil
                battleShoutLastDuration = nil
            end
        else
            found = false
            remaining = 0
        end
    else
        local buffIcon, duration, expirationTime, readable
        if Compat and Compat.FindPlayerBuffBySpellIds then
            local _
            _, buffIcon, duration, expirationTime, readable, found =
                Compat.FindPlayerBuffBySpellIds(
                    BATTLE_SHOUT_SPELL_IDS,
                    isBattleShoutAura,
                    function(ic) return string.lower(ic) == BATTLE_SHOUT_ICON_LOWER end
                )
        else
            for i = 1, 40 do
                local name, _, ic, _, _, dur, exp = UnitBuff("player", i)
                if not name then break end
                if isBattleShoutAura(name, ic) then
                    found = true
                    buffIcon = ic
                    duration = dur
                    expirationTime = exp
                    readable = true
                    break
                end
            end
        end

        if found then
            if buffIcon then icon = buffIcon end
            local expOk = readable and expirationTime
                and ((not Compat) or Compat.CanUseNumber(expirationTime))
                and expirationTime > 0
            local durOk = readable and duration
                and ((not Compat) or Compat.CanUseNumber(duration))
                and duration > 0

            if expOk then
                if expirationTime > now then
                    remaining = expirationTime - now
                else
                    remaining = expirationTime
                end
            elseif durOk then
                if (not battleShoutWasFound) or (not battleShoutDurationStartedAt) or battleShoutLastDuration ~= duration then
                    battleShoutDurationStartedAt = now
                end
                battleShoutLastDuration = duration
                remaining = duration - (now - battleShoutDurationStartedAt)
            elseif battleShoutDurationStartedAt and battleShoutLastDuration then
                remaining = battleShoutLastDuration - (now - battleShoutDurationStartedAt)
            elseif readable then
                remaining = 999
            else
                -- Aura present but timing secret: prefer local cast countdown.
                if battleShoutDurationStartedAt and battleShoutLastDuration then
                    remaining = battleShoutLastDuration - (now - battleShoutDurationStartedAt)
                else
                    remaining = 999
                end
            end
        end

        if found and battleShoutDurationStartedAt and battleShoutLastDuration then
            local localRemaining = battleShoutLastDuration - (now - battleShoutDurationStartedAt)
            if localRemaining > remaining then
                remaining = localRemaining
            end
        end
    end

    local threshold = cfg.battleShoutWarnSeconds or 30
    battleShoutRemaining = math.max(0, remaining)
    battleShoutVisible = (not found) or remaining <= threshold
    battleShoutFlash = battleShoutVisible
    battleShoutWasFound = found

    if not found then
        battleShoutDurationStartedAt = nil
        battleShoutLastDuration = nil
    end

    if battleShoutIcon then
        battleShoutIcon:SetTexture(icon)
        battleShoutIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if battleShoutIcon.SetRotation then
            battleShoutIcon:SetRotation(0)
        end
    end
    if battleShoutTimerFS then
        if found and battleShoutVisible and battleShoutRemaining > 0 and battleShoutRemaining < 999 then
            battleShoutTimerFS:SetText(tostring(math.ceil(battleShoutRemaining)))
        else
            battleShoutTimerFS:SetText("")
        end
    end
    if battleShoutVisible then
        battleShoutFrame:Show()
    else
        battleShoutFrame:Hide()
    end
end

function Bar:OnSpellcastSucceeded(unit, ...)
    if unit ~= "player" then return end

    local matched = false
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if isBattleShoutSpellcast(value) then
            matched = true
            break
        end
    end

    if matched then
        local duration = (ns.Config and ns.Config.db and ns.Config.db.battleShoutDuration) or 120
        battleShoutDurationStartedAt = GetTime()
        battleShoutLastDuration = duration
        battleShoutWasFound = true
        battleShoutRemaining = duration
        battleShoutVisible = false
        battleShoutFlash = false
        if battleShoutTimerFS then battleShoutTimerFS:SetText("") end
        if battleShoutFrame then battleShoutFrame:Hide() end
    end
end

function Bar:SetInCombat(_state)
    -- Combat transitions can flip Forever secret-value restrictions on rage /
    -- auras. Refresh immediately so we enter or leave StatusBar fallback mode
    -- without waiting for the next UNIT_POWER_UPDATE.
    self:Update()
    self:UpdateAuras()
end

local TWEEN_SPEED = 350
function Bar:OnFrame(dt)
    if not container then return end

    auraCheckElapsed = auraCheckElapsed + dt
    if auraCheckElapsed >= 1.0 then
        auraCheckElapsed = 0
        self:UpdateAuras()
    end

    -- Secret rage cannot be tweened (arithmetic on secrets errors).
    if rageSecretMode then
        self:Render()
        return
    end

    local Compat = ns.Compat
    if Compat and not Compat.CanUseNumber(currentRage) then
        self:Render()
        return
    end

    local diff = currentRage - displayedRage
    if math.abs(diff) < 0.25 then
        displayedRage = currentRage
    else
        local step = TWEEN_SPEED * dt
        if math.abs(diff) <= step then
            displayedRage = currentRage
        else
            displayedRage = displayedRage + (diff > 0 and step or -step)
        end
    end

    self:Render()
end

function Bar:Render()
    local cfg = ns.Config.db
    local zones = cfg.zones
    local retained = cfg.tacticalMasteryRetained
    local Compat = ns.Compat

    -- ForeverDisplay path: curved StatusBar segments own the fill. Dump-hint
    -- math and Classic ghost textures still need plain numbers -- hide those
    -- when rage is not usable; the Forever ghostGate StatusBar replaces the
    -- notch via engine-side min/max compare.
    if rageSecretMode or (ns.ForeverDisplay and ns.ForeverDisplay.IsActive and ns.ForeverDisplay:IsActive()) then
        local powerReadable = (not Compat) or Compat.CanUseNumber(currentRage)
        if (not powerReadable) or (Compat and Compat.hasSecrets and Compat.NeedsSecretSafeRageDisplay and Compat.NeedsSecretSafeRageDisplay()) then
            if ns.ForeverDisplay and ns.ForeverDisplay.HideDecisionHints then
                ns.ForeverDisplay:HideDecisionHints(ghostNotch, ghostLine, dumpHintFS, capGlow)
            else
                if ghostNotch then ghostNotch:Hide() end
                if ghostLine then ghostLine:Hide() end
                if dumpHintFS then dumpHintFS:Hide() end
                if capGlow then capGlow:Hide() end
            end
        elseif powerReadable then
            -- Out of combat on Forever: rage is plain -- show dump hint like Classic.
            if cfg.showGhostLine and currentRage > retained then
                local frac = retained / 100
                local xOff = curveOffset(frac, cfg.barCurveAmplitude, cfg.barCurveDirection)
                local leftEdgeX = container._barCenterlineX + xOff - cfg.barWidth * 0.5
                local yPos = container._barAnchorY + frac * cfg.barHeight

                ghostNotch:ClearAllPoints()
                ghostNotch:SetPoint("CENTER", container, "BOTTOMLEFT", leftEdgeX, yPos)
                ghostNotch:Show()

                ghostLine:ClearAllPoints()
                ghostLine:SetPoint("RIGHT", container, "BOTTOMLEFT", leftEdgeX - 2, yPos)
                ghostLine:Show()

                local dumpAmount = math.floor(currentRage - retained + 0.5)
                dumpHintFS:SetText(("-%d"):format(dumpAmount))
                local r, g, b
                if dumpAmount < 15 then
                    r, g, b = 0.98, 0.78, 0.24
                elseif dumpAmount < 30 then
                    r, g, b = 1.00, 0.50, 0.16
                else
                    r, g, b = 0.92, 0.16, 0.12
                end
                dumpHintFS:SetTextColor(r, g, b, 1.0)
                dumpHintFS:ClearAllPoints()
                dumpHintFS:SetPoint("RIGHT", ghostLine, "LEFT", -3, 0)
                dumpHintFS:Show()
            else
                ghostNotch:Hide()
                ghostLine:Hide()
                dumpHintFS:Hide()
            end

            if cfg.rageCapWarn and capGlow then
                if currentRage >= maxRage - 5 then
                    local pulse = 0.5 + 0.5 * math.sin(GetTime() * 6)
                    capGlow:SetColorTexture(0.95, 0.78, 0.30, 0.30 + 0.40 * pulse)
                    capGlow:Show()
                else
                    capGlow:Hide()
                end
            end
        end

        if numberFS and cfg.showNumber then
            if Compat and Compat.FormatNumber then
                numberFS:SetText(Compat.FormatNumber(currentRage))
            else
                numberFS:SetText(currentRage)
            end
            if powerReadable then
                local r, g, b = zoneColorForRage(currentRage, retained, zones)
                numberFS:SetTextColor(r, g, b, 1)
            else
                numberFS:SetTextColor(0.98, 0.78, 0.24, 1)
            end
        end

        if battleShoutFrame and battleShoutVisible then
            if battleShoutFlash then
                local pulse = 0.5 + 0.5 * math.sin(GetTime() * 8)
                battleShoutFrame:SetAlpha(0.35 + 0.65 * pulse)
            else
                battleShoutFrame:SetAlpha(1)
            end
        end
        return
    end

    local fillRage = math.floor(displayedRage + 0.5)
    local emptyC = zones.empty

    -- Color each row: bright blended zone if filled, dim empty if not. Each
    -- filled center stays fully opaque; only the row edges feather out.
    for i, s in ipairs(slices) do
        local mid = sliceMidRage[i]
        if mid <= fillRage then
            local r, g, b, a = zoneColorForRage(mid, retained, zones)
            setRowColor(i, r, g, b, a, cfg.barEdgeAlpha or 0.42)
        else
            setRowColor(i, emptyC[1], emptyC[2], emptyC[3], emptyC[4], (cfg.barEdgeAlpha or 0.42) * 0.7)
        end
    end

    if numberFS and cfg.showNumber then
        numberFS:SetText(tostring(math.floor(currentRage + 0.5)))
        local r, g, b = zoneColorForRage(currentRage, retained, zones)
        numberFS:SetTextColor(r, g, b, 1)
    end

    -- Ghost line + dump hint. Whole family hides when there's no decision
    -- to make (showGhostLine off, or currentRage <= retained = free dance).
    if cfg.showGhostLine and currentRage > retained then
        local frac = retained / 100
        local xOff = curveOffset(frac, cfg.barCurveAmplitude, cfg.barCurveDirection)
        local leftEdgeX = container._barCenterlineX + xOff - cfg.barWidth * 0.5
        local yPos = container._barAnchorY + frac * cfg.barHeight

        ghostNotch:ClearAllPoints()
        ghostNotch:SetPoint("CENTER", container, "BOTTOMLEFT", leftEdgeX, yPos)
        ghostNotch:Show()

        ghostLine:ClearAllPoints()
        ghostLine:SetPoint("RIGHT", container, "BOTTOMLEFT", leftEdgeX - 2, yPos)
        ghostLine:Show()

        local dumpAmount = math.floor(currentRage - retained + 0.5)
        dumpHintFS:SetText(("-%d"):format(dumpAmount))

        -- Severity color: how painful is the dance right now? Tones match
        -- the bar's zone palette (warm, muted, not neon).
        local r, g, b
        if dumpAmount < 15 then
            r, g, b = 0.98, 0.78, 0.24    -- gold: small loss, fine
        elseif dumpAmount < 30 then
            r, g, b = 1.00, 0.50, 0.16    -- molten orange: meaningful
        else
            r, g, b = 0.92, 0.16, 0.12    -- blood red: heavy, dump first
        end

        dumpHintFS:SetTextColor(r, g, b, 1.0)
        dumpHintFS:ClearAllPoints()
        dumpHintFS:SetPoint("RIGHT", ghostLine, "LEFT", -3, 0)
        dumpHintFS:Show()
    else
        ghostNotch:Hide()
        ghostLine:Hide()
        dumpHintFS:Hide()
    end

    if cfg.rageCapWarn and capGlow then
        if currentRage >= maxRage - 5 then
            local pulse = 0.5 + 0.5 * math.sin(GetTime() * 6)
            capGlow:SetColorTexture(0.95, 0.78, 0.30, 0.30 + 0.40 * pulse)
            capGlow:Show()
        else
            capGlow:Hide()
        end
    end

    if battleShoutFrame and battleShoutVisible then
        if battleShoutFlash then
            local pulse = 0.5 + 0.5 * math.sin(GetTime() * 8)
            battleShoutFrame:SetAlpha(0.35 + 0.65 * pulse)
        else
            battleShoutFrame:SetAlpha(1)
        end
    end
end

