-- RageForge: Options.lua
-- Settings UI + Blizzard Options > AddOns registration.
--
-- Forever / Mainline: Settings.RegisterCanvasLayoutCategory +
-- Settings.RegisterAddOnCategory (warcraft.wiki.gg Creating a settings menu).
-- TBC Anniversary: InterfaceOptions_AddCategory fallback.
--
-- /rf opens the registered category when possible
-- (Settings.OpenToCategory / InterfaceOptionsFrame_OpenToCategory),
-- with a standalone movable window as last-resort fallback.
--
-- Controls write ns.Config.db and preview live. Style changes rebuild the
-- bar via RageBar:Rebuild(); a Reload UI button sits next to the selector.

local ADDON_NAME, ns = ...
ns.Options = {}
local Opt = ns.Options

local panel
local window
local registered = false
local buildError
local settingsCategory
local controls = {} -- everything with a _refresh() method, called on panel show

local function applyLive()
    if ns.RageBar and ns.RageBar.ApplyConfig then
        ns.RageBar:ApplyConfig()
    end
end

local function reloadUI()
    if ReloadUI then
        ReloadUI()
    end
end

-- ---------- helpers ----------

local function makeHeader(parent, label, anchor, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if anchor then
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", x or 0, y or -16)
    else
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 16, y or -16)
    end
    fs:SetText(label)
    fs:SetTextColor(1, 0.82, 0)
    return fs
end

local cbCount = 0
local function makeCheckbox(parent, label, getter, setter, tooltip)
    cbCount = cbCount + 1
    local name = "RageForgeOptCB" .. cbCount
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    _G[name .. "Text"]:SetText(label)
    _G[name .. "Text"]:SetTextColor(1, 1, 1)
    cb:SetHitRectInsets(0, -math.max(50, label:len() * 7), 0, 0)
    cb:SetChecked(getter())
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
        applyLive()
    end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    cb._refresh = function() cb:SetChecked(getter()) end
    table.insert(controls, cb)
    return cb
end

local sCount = 0
local function makeSlider(parent, label, minVal, maxVal, step, getter, setter, valueFmt, tooltip)
    sCount = sCount + 1
    local name = "RageForgeOptSlider" .. sCount
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    s:SetMinMaxValues(minVal, maxVal)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:SetWidth(200)
    if _G[name .. "Low"] then _G[name .. "Low"]:SetText(tostring(minVal)) end
    if _G[name .. "High"] then _G[name .. "High"]:SetText(tostring(maxVal)) end

    valueFmt = valueFmt or "%s: %.2f"
    local function updateLabel(v)
        if _G[name .. "Text"] then _G[name .. "Text"]:SetText(valueFmt:format(label, v)) end
    end

    s:SetValue(getter())
    updateLabel(getter())
    s:SetScript("OnValueChanged", function(self, value)
        setter(value)
        updateLabel(value)
        applyLive()
    end)

    if tooltip then
        s:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        s:SetScript("OnLeave", GameTooltip_Hide)
    end

    s._refresh = function() s:SetValue(getter()); updateLabel(getter()) end
    table.insert(controls, s)
    return s
end

local btnCount = 0
local function makeButton(parent, label, onClick, width)
    btnCount = btnCount + 1
    local b = CreateFrame("Button", "RageForgeOptBtn" .. btnCount, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 130, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local radioGroups = {}
local function makeRadio(parent, label, getter, setter, value, groupId)
    cbCount = cbCount + 1
    local name = "RageForgeOptRadio" .. cbCount
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    _G[name .. "Text"]:SetText(label)
    _G[name .. "Text"]:SetTextColor(1, 1, 1)
    cb._radioValue = value
    cb._radioGroup = groupId
    cb:SetChecked(getter() == value)
    cb:SetScript("OnClick", function(self)
        if not self:GetChecked() then
            self:SetChecked(true)
            return
        end
        setter(value)
        for _, sibling in ipairs(radioGroups[groupId] or {}) do
            if sibling ~= self then sibling:SetChecked(false) end
        end
        applyLive()
    end)
    cb._refresh = function() cb:SetChecked(getter() == value) end
    table.insert(controls, cb)
    radioGroups[groupId] = radioGroups[groupId] or {}
    table.insert(radioGroups[groupId], cb)
    return cb
end

-- ---------- panel ----------

local function ensureWindow()
    if window then return end

    window = CreateFrame("Frame", "RageForgeOptionsWindow", UIParent)
    window:SetSize(640, 760)
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    local bg = window:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", window, "TOPLEFT", 8, -8)
    bg:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -8, 8)
    bg:SetColorTexture(0.02, 0.015, 0.012, 0.92)
    window._bg = bg

    local function border(pointA, relPointA, xA, yA, pointB, relPointB, xB, yB, height, width)
        local t = window:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.55, 0.42, 0.22, 0.95)
        t:SetPoint(pointA, window, relPointA, xA, yA)
        t:SetPoint(pointB, window, relPointB, xB, yB)
        if height then t:SetHeight(height) end
        if width then t:SetWidth(width) end
        return t
    end
    border("TOPLEFT", "TOPLEFT", 10, -10, "TOPRIGHT", "TOPRIGHT", -10, -10, 2)
    border("BOTTOMLEFT", "BOTTOMLEFT", 10, 10, "BOTTOMRIGHT", "BOTTOMRIGHT", -10, 10, 2)
    border("TOPLEFT", "TOPLEFT", 10, -10, "BOTTOMLEFT", "BOTTOMLEFT", 10, 10, nil, 2)
    border("TOPRIGHT", "TOPRIGHT", -10, -10, "BOTTOMRIGHT", "BOTTOMRIGHT", -10, 10, nil, 2)

    if window.SetBackdrop then
        window:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true,
            tileSize = 32,
            edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", window, "TOP", 0, -14)
    title:SetText("RageForge Settings")
    title:SetTextColor(1, 0.82, 0)

    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", window, "TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() window:Hide() end)

    if UISpecialFrames then
        table.insert(UISpecialFrames, "RageForgeOptionsWindow")
    end
    window:Hide()
end

local function openStandalone()
    ensureWindow()
    panel:SetParent(window)
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", window, "TOPLEFT", 18, -36)
    panel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -18, 18)
    if panel.refresh then panel.refresh() end
    panel:Show()
    window:Show()
end

local function registerBlizzardCategory()
    -- Forever / Mainline Settings API (canvas layout keeps our custom controls).
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        panel.OnCommit = function() end
        panel.OnDefault = function()
            if panel.default then panel.default() end
        end
        panel.OnRefresh = function()
            if panel.refresh then panel.refresh() end
        end

        local ok, category, layout = pcall(Settings.RegisterCanvasLayoutCategory, panel, "RageForge")
        if ok and category then
            if layout and layout.AddAnchorPoint then
                layout:AddAnchorPoint("TOPLEFT", 10, -10)
                layout:AddAnchorPoint("BOTTOMRIGHT", -10, 10)
            end
            local okReg, errReg = pcall(Settings.RegisterAddOnCategory, category)
            if okReg then
                settingsCategory = category
                return true
            end
            buildError = "Settings.RegisterAddOnCategory failed: " .. tostring(errReg)
        else
            buildError = "Settings.RegisterCanvasLayoutCategory failed: " .. tostring(category)
        end
    end

    -- TBC Anniversary / Classic legacy AddOns list.
    if InterfaceOptions_AddCategory then
        local ok, err = pcall(InterfaceOptions_AddCategory, panel)
        if ok then
            return true
        end
        buildError = (buildError and (buildError .. "; ") or "")
            .. "InterfaceOptions_AddCategory failed: " .. tostring(err)
        return false
    end

    if not buildError then
        buildError = "no Blizzard options API; standalone window only"
    end
    return false
end

function Opt:Build()
    if registered then return true end

    panel = CreateFrame("Frame", "RageForgeOptionsPanel")
    panel:SetSize(600, 520)
    panel.name = "RageForge"

    -- Scrollable canvas so Forever Options / TBC Interface Options never clip
    -- or overlap footer credits with Display controls.
    local CONTENT_WIDTH = 560
    local scroll
    local okScroll, scrollOrErr = pcall(CreateFrame, "ScrollFrame", "RageForgeOptionsScroll", panel, "UIPanelScrollFrameTemplate")
    if okScroll and scrollOrErr then
        scroll = scrollOrErr
    else
        scroll = CreateFrame("ScrollFrame", "RageForgeOptionsScroll", panel)
    end
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)

    local content = CreateFrame("Frame", "RageForgeOptionsScrollChild", scroll)
    content:SetWidth(CONTENT_WIDTH)
    content:SetHeight(900)
    scroll:SetScrollChild(content)

    scroll:EnableMouse(true)
    scroll:EnableMouseWheel(true)
    local function onOptionsMouseWheel(scrollFrame, delta)
        local step = 36
        local cur = scrollFrame:GetVerticalScroll() or 0
        local maxScroll = scrollFrame:GetVerticalScrollRange() or 0
        local nextScroll = cur - (delta * step)
        if nextScroll < 0 then nextScroll = 0 end
        if nextScroll > maxScroll then nextScroll = maxScroll end
        scrollFrame:SetVerticalScroll(nextScroll)
    end
    scroll:SetScript("OnMouseWheel", onOptionsMouseWheel)

    local function sizeScrollChild()
        local top = content:GetTop()
        local bottom = content._lastBottom and content._lastBottom:GetBottom()
        if top and bottom then
            local h = (top - bottom) + 28
            if h < 400 then h = 400 end
            content:SetHeight(h)
        end
        if scroll.UpdateScrollChildRect then
            scroll:UpdateScrollChildRect()
        end
    end

    local cfg = ns.Config.db

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -12)
    title:SetText("RageForge")
    title:SetTextColor(1, 0.37, 0.25)

    local subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    subtitle:SetWidth(CONTENT_WIDTH - 24)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Smart rage display for stance-dancing warriors (TBC Anniversary + WoW Forever). " ..
        "Type |cffff5f3f/rf|r in chat for slash commands.")

    -- ===== Position & Scale =====
    local h1 = makeHeader(content, "Position & Scale", subtitle, 0, -20)

    local lock = makeCheckbox(content, "Lock bar (uncheck to drag-and-drop)",
        function() return cfg.locked end,
        function(v) cfg.locked = v end,
        "When unlocked, the RAGE label changes to a small blue drag hint. Re-lock to return to the clean combat view.")
    lock:SetPoint("TOPLEFT", h1, "BOTTOMLEFT", 0, -8)

    local scale = makeSlider(content, "Scale", 0.5, 2.0, 0.05,
        function() return cfg.scale end,
        function(v) cfg.scale = v end,
        "%s: %.2f")
    scale:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 4, -28)

    local resetPos = makeButton(content, "Reset Position", function()
        cfg.position = { point = "CENTER", relPoint = "CENTER", x = -220, y = 0 }
        applyLive()
    end)
    resetPos:SetPoint("LEFT", scale, "RIGHT", 32, 0)

    -- ===== Stance Dance Math =====
    local h2 = makeHeader(content, "Stance Dance Math", scale, -4, -36)

    local tmHelp = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tmHelp:SetPoint("TOPLEFT", h2, "BOTTOMLEFT", 0, -6)
    tmHelp:SetWidth(CONTENT_WIDTH - 24)
    tmHelp:SetJustifyH("LEFT")
    tmHelp:SetText("Tactical Mastery rank \194\183 the rage retained on stance change. " ..
        "Drives the ghost line, dump hint, and zone colors.")

    local tm0 = makeRadio(content, "0/5  (0 retained)",
        function() return cfg.tacticalMasteryRetained end,
        function(v) cfg.tacticalMasteryRetained = v end,
        0, "tm")
    tm0:SetPoint("TOPLEFT", tmHelp, "BOTTOMLEFT", 0, -8)

    local tm3 = makeRadio(content, "3/5  (15 retained)",
        function() return cfg.tacticalMasteryRetained end,
        function(v) cfg.tacticalMasteryRetained = v end,
        15, "tm")
    tm3:SetPoint("LEFT", tm0, "RIGHT", 130, 0)

    local tm5 = makeRadio(content, "5/5  (25 retained)",
        function() return cfg.tacticalMasteryRetained end,
        function(v) cfg.tacticalMasteryRetained = v end,
        25, "tm")
    tm5:SetPoint("LEFT", tm3, "RIGHT", 130, 0)

    -- ===== Bar Style =====
    local hStyle = makeHeader(content, "Bar Style", tm0, -4, -28)

    local styleHelp = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    styleHelp:SetPoint("TOPLEFT", hStyle, "BOTTOMLEFT", 0, -4)
    styleHelp:SetWidth(CONTENT_WIDTH - 24)
    styleHelp:SetJustifyH("LEFT")
    styleHelp:SetText("Blade (default) is a medium elegant curve. Ribbon is thin. Classic is the original thick curve. " ..
        "Applies live via bar rebuild; use Reload UI if anything looks wrong.")

    local function applyStyle(name)
        if ns.Config and ns.Config.ApplyStyle then
            ns.Config:ApplyStyle(name)
        end
        if panel.refresh then panel.refresh() end
    end

    local styleBlade = makeRadio(content, "Blade",
        function() return cfg.barStyle or "blade" end,
        applyStyle,
        "blade", "barStyle")
    styleBlade:SetPoint("TOPLEFT", styleHelp, "BOTTOMLEFT", 0, -8)

    local styleRibbon = makeRadio(content, "Ribbon",
        function() return cfg.barStyle or "blade" end,
        applyStyle,
        "ribbon", "barStyle")
    styleRibbon:SetPoint("LEFT", styleBlade, "RIGHT", 90, 0)

    local styleClassic = makeRadio(content, "Classic",
        function() return cfg.barStyle or "blade" end,
        applyStyle,
        "classic", "barStyle")
    styleClassic:SetPoint("LEFT", styleRibbon, "RIGHT", 90, 0)

    local reloadBtn = makeButton(content, "Reload UI", reloadUI, 100)
    reloadBtn:SetPoint("LEFT", styleClassic, "RIGHT", 100, 0)

    -- ===== Frame Overlay =====
    local hFrame = makeHeader(content, "Frame Overlay", styleBlade, -4, -28)

    local frameHelp = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frameHelp:SetPoint("TOPLEFT", hFrame, "BOTTOMLEFT", 0, -4)
    frameHelp:SetWidth(CONTENT_WIDTH - 24)
    frameHelp:SetJustifyH("LEFT")
    frameHelp:SetText("Thin closed metal rims. Warlord (default) is dark iron with gold trim. " ..
        "Iron is simple steel. Bloodforged is matte black with molten red-orange trim. None hides the rim.")

    local function applyFrame(name)
        if ns.Config and ns.Config.ApplyFrameStyle then
            ns.Config:ApplyFrameStyle(name)
        else
            cfg.frameStyle = name
            applyLive()
        end
        -- Frame clearance changes icon anchors; rebuild geometry.
        if ns.RageBar and ns.RageBar.Rebuild then
            ns.RageBar:Rebuild()
        end
        if panel.refresh then panel.refresh() end
    end

    local frameIron = makeRadio(content, "Iron",
        function() return cfg.frameStyle or "warlord" end,
        applyFrame,
        "iron", "frameStyle")
    frameIron:SetPoint("TOPLEFT", frameHelp, "BOTTOMLEFT", 0, -8)

    local frameBlood = makeRadio(content, "Bloodforged",
        function() return cfg.frameStyle or "warlord" end,
        applyFrame,
        "bloodforged", "frameStyle")
    frameBlood:SetPoint("LEFT", frameIron, "RIGHT", 70, 0)

    local frameWarlord = makeRadio(content, "Warlord",
        function() return cfg.frameStyle or "warlord" end,
        applyFrame,
        "warlord", "frameStyle")
    frameWarlord:SetPoint("LEFT", frameBlood, "RIGHT", 100, 0)

    local frameNone = makeRadio(content, "None",
        function() return cfg.frameStyle or "warlord" end,
        applyFrame,
        "none", "frameStyle")
    frameNone:SetPoint("LEFT", frameWarlord, "RIGHT", 90, 0)

    -- ===== Display =====
    local h3 = makeHeader(content, "Display", frameIron, -4, -28)

    local cbTicks = makeCheckbox(content, "Threshold ticks",
        function() return cfg.showTicks end,
        function(v) cfg.showTicks = v end,
        "Marks important rage breakpoints so you can read your bar at a glance. Each style ships its own default set.")
    cbTicks:SetPoint("TOPLEFT", h3, "BOTTOMLEFT", 0, -8)

    local cbGhost = makeCheckbox(content, "Ghost line + dump hint",
        function() return cfg.showGhostLine end,
        function(v) cfg.showGhostLine = v end,
        "Bright notch on the bar's left edge at the rage you'd land on after stance change, plus the live -X label showing rage you'd lose right now.")
    cbGhost:SetPoint("TOPLEFT", cbTicks, "BOTTOMLEFT", 0, -4)

    local cbStances = makeCheckbox(content, "Stance icon rail",
        function() return cfg.showStanceIcons end,
        function(v) cfg.showStanceIcons = v end,
        "Shows Battle / Defensive / Berserker stance icons touching the bar's left edge. Icons are cropped and rotated; inactive stances are alpha-dimmed only.")
    cbStances:SetPoint("TOPLEFT", cbGhost, "BOTTOMLEFT", 0, -4)

    local cbNumber = makeCheckbox(content, "Big rage number above bar",
        function() return cfg.showNumber end,
        function(v) cfg.showNumber = v end)
    cbNumber:SetPoint("TOPLEFT", cbStances, "BOTTOMLEFT", 0, -4)

    local cbCap = makeCheckbox(content, "Rage cap warning (top of bar pulses near 100)",
        function() return cfg.rageCapWarn end,
        function(v) cfg.rageCapWarn = v end,
        "Subtle yellow pulse on the top edge of the bar when you're within 5 rage of cap, so you spot wasted rage in heated fights.")
    cbCap:SetPoint("TOPLEFT", cbNumber, "BOTTOMLEFT", 0, -4)

    local cbBattleShout = makeCheckbox(content, "Battle Shout reminder",
        function() return cfg.showBattleShoutReminder end,
        function(v) cfg.showBattleShoutReminder = v end,
        "Shows a Battle Shout icon at the bottom-left of RageForge when the buff is missing or has 30 seconds or less remaining. Shows a countdown over the icon while expiring.")
    cbBattleShout:SetPoint("TOPLEFT", cbCap, "BOTTOMLEFT", 0, -4)

    local fontSize = makeSlider(content, "Number font size", 14, 36, 1,
        function() return cfg.numberFontSize end,
        function(v) cfg.numberFontSize = v end,
        "%s: %d")
    fontSize:SetPoint("TOPLEFT", cbBattleShout, "BOTTOMLEFT", 4, -28)

    -- ===== Credits (end of scroll content -- never panel-bottom anchored) =====
    local sep = content:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.55, 0.42, 0.22, 0.6)
    sep:SetHeight(1)
    sep:SetWidth(CONTENT_WIDTH - 24)
    sep:SetPoint("TOPLEFT", fontSize, "BOTTOMLEFT", -4, -28)

    local about = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    about:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -12)
    about:SetWidth(CONTENT_WIDTH - 24)
    about:SetJustifyH("LEFT")
    about:SetText("Created by Chase Sommer, a game designer who loves to play and build addons and communities around WoW.\n" ..
        "X: x.com/SommerChase  \194\183  YouTube: youtube.com/@chasesommer  \194\183  Patreon: patreon.com/cw/chasesommer")

    local credits = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    credits:SetPoint("TOPLEFT", about, "BOTTOMLEFT", 0, -10)
    credits:SetWidth(CONTENT_WIDTH - 24)
    credits:SetJustifyH("LEFT")
    credits:SetText("Bundled font: Prototype by Justin Callaghan (mickeyavenue.com).")

    local footer = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("TOPLEFT", credits, "BOTTOMLEFT", 0, -8)
    footer:SetWidth(CONTENT_WIDTH - 24)
    footer:SetJustifyH("LEFT")
    local version = "0.13.1"
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or version
    elseif GetAddOnMetadata then
        version = GetAddOnMetadata(ADDON_NAME, "Version") or version
    end
    footer:SetText("RageForge v" .. version .. "  \194\183  Settings auto-save.")

    content._lastBottom = footer

    local function refreshScrollLayout()
        sizeScrollChild()
    end

    panel.refresh = function()
        for _, c in ipairs(controls) do
            if c._refresh then c._refresh() end
        end
        refreshScrollLayout()
    end

    panel.default = function()
        local function restore(target, defaults)
            for k, v in pairs(defaults) do
                if type(v) == "table" then
                    target[k] = {}
                    restore(target[k], v)
                else
                    target[k] = v
                end
            end
        end
        restore(ns.Config.db, ns.Config.defaults)
        if ns.Config.ApplyStyle then
            ns.Config:ApplyStyle(ns.Config.db.barStyle or "blade", { silent = true })
        else
            applyLive()
        end
        if panel.refresh then panel.refresh() end
    end

    panel.okay = function() end
    panel.cancel = function() end
    panel.OnRefresh = function()
        if panel.refresh then panel.refresh() end
    end

    panel:HookScript("OnShow", function()
        refreshScrollLayout()
    end)
    panel:HookScript("OnSizeChanged", function()
        refreshScrollLayout()
    end)

    registerBlizzardCategory()

    panel:Hide()
    registered = true
    return true
end

-- Open Blizzard Options > AddOns > RageForge when registered; else standalone.
function Opt:Open()
    local ok, built = pcall(self.Build, self)
    if not ok then
        if ns.Config and ns.Config.Print then
            ns.Config:Print("options panel failed: " .. tostring(built))
        end
        return
    end
    if not built then
        if ns.Config and ns.Config.Print then
            ns.Config:Print("options panel failed to register: " .. tostring(buildError or "unknown error"))
        end
        return
    end

    if Settings and Settings.OpenToCategory and settingsCategory then
        local target = settingsCategory
        if settingsCategory.GetID then
            local idOk, id = pcall(settingsCategory.GetID, settingsCategory)
            if idOk and id ~= nil then
                target = id
            end
        end
        local openOk = pcall(Settings.OpenToCategory, target)
        if openOk then
            if panel.refresh then panel.refresh() end
            return
        end
    end

    if InterfaceOptionsFrame_OpenToCategory and panel then
        -- Classic bug: first call can fail to select; call twice.
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        pcall(InterfaceOptionsFrame_OpenToCategory, panel)
        if InterfaceOptionsFrame and InterfaceOptionsFrame.Show then
            InterfaceOptionsFrame:Show()
        end
        if panel.refresh then panel.refresh() end
        return
    end

    openStandalone()
end

function Opt:OpenStandalone()
    local ok = pcall(self.Build, self)
    if ok then
        openStandalone()
    end
end

-- Addon compartment click (Forever TOC AddonCompartmentFunc). Must be global.
function RageForge_OnAddonCompartmentClick()
    if ns.Options and ns.Options.Open then
        ns.Options:Open()
    end
end

function RageForge_OnAddonCompartmentEnter()
    if GameTooltip then
        GameTooltip:SetText("RageForge", 1, 0.82, 0)
        GameTooltip:AddLine("Open RageForge settings", 1, 1, 1, true)
        GameTooltip:Show()
    end
end

function RageForge_OnAddonCompartmentLeave()
    if GameTooltip then
        GameTooltip:Hide()
    end
end
