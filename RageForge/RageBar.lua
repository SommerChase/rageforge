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
local battleShoutFrame
local battleShoutIcon
local battleShoutBorder
local battleShoutTimerFS
local capGlow
local numberFS
local labelFS

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
local inCombat = false

local STANCES = {
    { texture = "Interface\\Icons\\Ability_Warrior_OffensiveStance" },
    { texture = "Interface\\Icons\\Ability_Warrior_DefensiveStance" },
    { texture = "Interface\\Icons\\Ability_Racial_Avatar" },
}

local BATTLE_SHOUT_SPELL_ID = 6673
local BATTLE_SHOUT_NAME = (GetSpellInfo and GetSpellInfo(BATTLE_SHOUT_SPELL_ID)) or "Battle Shout"
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

-- Square-crop the icon and rotate the sampled texture so the spell icon's
-- top edge points left on screen. WoW's 8-argument SetTexCoord maps the
-- sampled image coordinates to the region corners: UL, LL, UR, LR.
local function setStanceIconTexCoord(icon)
    local l, r, t, b = 0.08, 0.92, 0.08, 0.92
    icon:SetTexCoord(
        r, t,  -- upper-left region corner samples top-right of source
        l, t,  -- lower-left region corner samples top-left of source
        r, b,  -- upper-right region corner samples bottom-right of source
        l, b   -- lower-right region corner samples bottom-left of source
    )
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

local function snapPixel(v)
    return math.floor(v + 0.5)
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

function Bar:Build()
    if container then return end

    local cfg = ns.Config.db
    local leftGutter = 66 -- stance rail + left-side dump hint breathing room
    local barCenterlineX = leftGutter + cfg.barCurveAmplitude + cfg.barWidth * 0.5
    local containerWidth = barCenterlineX + cfg.barWidth * 0.5 + 36 -- right side: ticks + labels
    local containerHeight = cfg.barHeight + 64
    local barAnchorY = 36

    container = CreateFrame("Frame", "RageForgeBar", UIParent)
    container:SetSize(containerWidth, containerHeight)
    container:SetPoint(cfg.position.point, UIParent, cfg.position.relPoint, cfg.position.x, cfg.position.y)
    container:SetScale(cfg.scale)
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:EnableMouse(not cfg.locked)
    container:RegisterForDrag("LeftButton")
    container:SetScript("OnDragStart", function(self) if not cfg.locked then self:StartMoving() end end)
    container:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
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

    -- Stance rail. Icons are square-cropped, rotated, and packed into a
    -- tight vertical strip. Each icon's right edge touches the bar's left
    -- edge, which reads as the spell icon's bottom edge touching the bar
    -- after rotation.
    local iconSize = cfg.stanceIconSize or 24
    local railCenterY = snapPixel(barAnchorY + cfg.barHeight * 0.50)
    for i, stance in ipairs(STANCES) do
        local iconY = railCenterY + (2 - i) * iconSize
        local frac = (iconY - barAnchorY) / cfg.barHeight
        local xOff = curveOffset(frac, cfg.barCurveAmplitude, cfg.barCurveDirection)
        local leftEdgeX = snapPixel(barCenterlineX + xOff - cfg.barWidth * 0.5)

        local icon = container:CreateTexture(nil, "OVERLAY", nil, 1)
        icon:SetTexture(stance.texture)
        icon:SetSize(iconSize, iconSize)
        setStanceIconTexCoord(icon)
        icon:SetPoint("RIGHT", container, "BOTTOMLEFT", leftEdgeX, iconY)
        icon:SetAlpha(1)

        local border = container:CreateTexture(nil, "OVERLAY", nil, 2)
        border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        border:SetBlendMode("ADD")
        border:SetSize(iconSize * 1.75, iconSize * 1.75)
        border:SetPoint("CENTER", icon, "CENTER", 0, 0)
        border:SetVertexColor(1.0, 0.82, 0.18, 1.0)
        border:Hide()

        stanceArtifacts[i] = { icon = icon, border = border }
    end

    -- Threshold ticks. Per user feedback (v0.2): ticks live OUTSIDE the bar
    -- to the right (where the number sits), not crossing through the fill.
    for _, rageValue in ipairs(cfg.thresholdTicks) do
        local frac = rageValue / 100
        local xOff = curveOffset(frac, cfg.barCurveAmplitude, cfg.barCurveDirection)
        local rightEdgeX = barCenterlineX + xOff + cfg.barWidth * 0.5

        local tick = container:CreateTexture(nil, "OVERLAY")
        tick:SetSize(7, 1)
        tick:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", rightEdgeX + 2, barAnchorY + frac * cfg.barHeight)
        tick:SetColorTexture(0.85, 0.78, 0.55, 0.55)

        local label = container:CreateFontString(nil, "OVERLAY")
        setFont(label, 11, "OUTLINE")
        label:SetText(rageValue)
        label:SetPoint("LEFT", tick, "RIGHT", 3, 0)
        label:SetTextColor(0.78, 0.72, 0.55, 0.95)

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
    local bottomLeftEdgeX = barCenterlineX + curveOffset(0, cfg.barCurveAmplitude, cfg.barCurveDirection) - cfg.barWidth * 0.5

    battleShoutFrame = CreateFrame("Frame", nil, container)
    battleShoutFrame:SetSize(shoutSize, shoutSize)
    battleShoutFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMLEFT", bottomLeftEdgeX - 10, barAnchorY)
    battleShoutFrame:Hide()

    battleShoutIcon = battleShoutFrame:CreateTexture(nil, "ARTWORK")
    battleShoutIcon:SetAllPoints(battleShoutFrame)
    battleShoutIcon:SetTexture(BATTLE_SHOUT_ICON)
    battleShoutIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

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

    self:UpdateStance()
    self:UpdateAuras()
    self:ApplyConfig()
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

    self:UpdateAuras()

    self:Update()
end

function Bar:RefreshStanceIcons()
    if not container then return end
    local cfg = ns.Config.db
    local _, class = UnitClass("player")

    for i, art in ipairs(stanceArtifacts) do
        local icon = art.icon
        local border = art.border
        if not cfg.showStanceIcons or class ~= "WARRIOR" then
            icon:Hide()
            if border then border:Hide() end
        else
            icon:Show()
            if icon.SetDesaturated then icon:SetDesaturated(false) end
            icon:SetVertexColor(1, 1, 1, 1)
            if i == activeStance then
                icon:SetAlpha(1.0)
                if border then border:Show() end
            else
                icon:SetAlpha(0.68)
                if border then border:Hide() end
            end
        end
    end
end

function Bar:UpdateStance()
    activeStance = (GetShapeshiftForm and GetShapeshiftForm()) or 0
    self:RefreshStanceIcons()
end

function Bar:Update()
    if not container then return end
    local rageType = (Enum and Enum.PowerType and Enum.PowerType.Rage) or 1
    currentRage = UnitPower("player", rageType) or 0
    maxRage = UnitPowerMax("player", rageType) or 100
    if maxRage <= 0 then maxRage = 100 end
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

    for i = 1, 40 do
        local name, rank, buffIcon, count, debuffType, duration, expirationTime = UnitBuff("player", i)
        if not name then break end
        if isBattleShoutAura(name, buffIcon) then
            found = true
            if buffIcon then icon = buffIcon end
            if expirationTime and expirationTime > 0 then
                -- Most clients return an absolute timestamp. Some Classic-era
                -- APIs/addons surface remaining seconds. Support both so the
                -- reminder actually hides after refreshing Battle Shout.
                if expirationTime > now then
                    remaining = expirationTime - now
                else
                    remaining = expirationTime
                end
            elseif duration and duration > 0 then
                -- Some Classic clients expose duration but not expiration.
                -- Track when we first saw/refreshed the aura so the countdown
                -- can still cross into the <=30s warning window.
                if (not battleShoutWasFound) or (not battleShoutDurationStartedAt) or battleShoutLastDuration ~= duration then
                    battleShoutDurationStartedAt = now
                end
                battleShoutLastDuration = duration
                remaining = duration - (now - battleShoutDurationStartedAt)
            else
                if battleShoutDurationStartedAt and battleShoutLastDuration then
                    remaining = battleShoutLastDuration - (now - battleShoutDurationStartedAt)
                else
                    remaining = 999
                end
            end
            break
        end
    end

    if found and battleShoutDurationStartedAt and battleShoutLastDuration then
        local localRemaining = battleShoutLastDuration - (now - battleShoutDurationStartedAt)
        if localRemaining > remaining then
            remaining = localRemaining
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

    if battleShoutIcon then battleShoutIcon:SetTexture(icon) end
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

function Bar:SetInCombat(state)
    inCombat = state
end

local TWEEN_SPEED = 350
function Bar:OnFrame(dt)
    if not container then return end

    auraCheckElapsed = auraCheckElapsed + dt
    if auraCheckElapsed >= 1.0 then
        auraCheckElapsed = 0
        self:UpdateAuras()
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

