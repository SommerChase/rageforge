-- RageForge: Config.lua
-- SavedVariables, defaults, and the /rf slash command.

local ADDON_NAME, ns = ...
ns.Config = {}
local C = ns.Config

-- Default settings. These get deep-copied into RageForgeDB on first load and
-- any missing keys are filled in on subsequent loads (forward-compatible).
C.defaults = {
    -- How much rage is retained on stance change.
    -- Tactical Mastery: 0/5 = 0, 3/5 = 15, 5/5 = 25.
    -- This is the linchpin of the whole addon. Get it right.
    tacticalMasteryRetained = 25,

    -- Bar geometry (logical, before scale). barHeight directly determines
    -- the vertical resolution of the fill -- one 1px slice per logical
    -- pixel of barHeight (see RageBar.lua "Build").
    barWidth = 22,
    barHeight = 280,
    barCurveAmplitude = 16,   -- pixels of horizontal "bow" at the midpoint
    barCurveDirection = -1,   -- -1 bows left, +1 bows right
    barEdgeFeatherWidth = 2,  -- soft left/right edge pixels per row
    barEdgeAlpha = 0.45,      -- alpha multiplier for feather strips

    -- Position. Anchored to UIParent CENTER by default; user can drag.
    position = {
        point = "CENTER",
        relPoint = "CENTER",
        x = -220,
        y = 0,
    },
    scale = 1.0,
    locked = false,

    -- Threshold ticks shown on the bar (rage values).
    -- These are the ability rage costs that matter most for warrior decisions.
    thresholdTicks = { 10, 15, 25, 30, 50, 75 },
    showTicks = true,
    showStanceIcons = true,
    stanceIconSize = 24,

    -- Visual zones for stance-dance economy. Tones are brighter than v0.5
    -- but still warrior-flavored: emerald, bright gold, molten orange,
    -- blood red. RageBar.lua blends between these stops instead of snapping
    -- at hard boundaries.
    zones = {
        safe     = { 0.30, 0.72, 0.38, 1.00 }, -- emerald:       0..TM (free dance)
        ok       = { 0.98, 0.78, 0.24, 1.00 }, -- bright gold:   TM..50 (small loss)
        caution  = { 1.00, 0.50, 0.16, 1.00 }, -- molten orange: 50..75 (consider dumping)
        dump     = { 0.92, 0.16, 0.12, 1.00 }, -- blood red:     75..100 (DUMP NOW)
        empty    = { 0.13, 0.11, 0.09, 0.62 }, -- dark steel:    unfilled portion
    },

    -- Ghost line (where you'd land after stance dance). Warm tan rather
    -- than pale blue -- matches the warrior class color tone.
    showGhostLine = true,
    ghostLineColor = { 0.95, 0.74, 0.42, 0.90 },

    -- Big numerical readout in/over the bar.
    showNumber = true,
    numberFontSize = 22,

    -- Rage cap warning: subtle border glow at 100 rage so you notice waste.
    rageCapWarn = true,

    -- Battle Shout reminder: show icon when missing or expiring soon.
    showBattleShoutReminder = true,
    battleShoutWarnSeconds = 30,
    battleShoutIconSize = 32,
    battleShoutDuration = 120,
}

-- Deep-merge defaults into target, never overwriting existing values.
local function fillDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(target[k]) ~= "table" then target[k] = {} end
            fillDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
end

-- Hard-replace a sub-table from defaults, used by migrations.
local function resetTo(target, defaults, key)
    target[key] = {}
    for k, v in pairs(defaults[key]) do
        if type(v) == "table" then
            target[key][k] = {}
            for k2, v2 in pairs(v) do target[key][k][k2] = v2 end
        else
            target[key][k] = v
        end
    end
end

-- Bump SCHEMA_VERSION whenever a default's *value* changes in a way that
-- should propagate to existing users (e.g. recolor, layout). fillDefaults
-- alone won't push new values into a user that already has the key.
C.SCHEMA_VERSION = 9

function C:Load()
    RageForgeDB = RageForgeDB or {}
    fillDefaults(RageForgeDB, self.defaults)

    local saved = RageForgeDB._schemaVersion or 0

    if saved < 5 then
        -- v5: warrior-themed zone repalette + ghost line tone change.
        -- Old users had neon RGB colors; force them onto the new palette.
        resetTo(RageForgeDB, self.defaults, "zones")
        RageForgeDB.ghostLineColor = { unpack(self.defaults.ghostLineColor) }
        RageForgeDB.barSegments = nil -- field removed in v0.5
    end

    if saved < 6 then
        -- v6: brighter blended palette + soft bar-edge feathering.
        resetTo(RageForgeDB, self.defaults, "zones")
        RageForgeDB.ghostLineColor = { unpack(self.defaults.ghostLineColor) }
        RageForgeDB.barEdgeFeatherWidth = self.defaults.barEdgeFeatherWidth
        RageForgeDB.barEdgeAlpha = self.defaults.barEdgeAlpha
    end

    if saved < 7 then
        -- v7: add the 30-rage PvP breakpoint tick to existing SavedVariables.
        RageForgeDB.thresholdTicks = { unpack(self.defaults.thresholdTicks) }
    end

    if saved < 8 then
        -- v8: remove the Overpower overlay/module from saved config.
        RageForgeDB.overpowerEnabled = nil
        RageForgeDB.overpowerColor = nil
        RageForgeDB.overpowerDuration = nil
    end

    if saved < 9 then
        -- v9: remove the low-value 5-rage tick from the default marker set.
        RageForgeDB.thresholdTicks = { unpack(self.defaults.thresholdTicks) }
    end

    RageForgeDB._schemaVersion = C.SCHEMA_VERSION
    self.db = RageForgeDB
    return self.db
end

-- Convenience accessors.
function C:Get(key) return self.db[key] end
function C:Set(key, value)
    self.db[key] = value
    if ns.RageBar and ns.RageBar.ApplyConfig then ns.RageBar:ApplyConfig() end
end

-- Print a styled chat message to the player.
function C:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff5f3fRageForge|r " .. tostring(msg))
end

-- /rf slash command. Keep flags minimal and mnemonic.
local function handleSlash(input)
    input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = input:match("^(%S+)%s*(.*)$")
    cmd = cmd or ""

    if cmd == "" then
        if ns.Options and ns.Options.Open then
            ns.Options:Open()
        else
            C:Print("options panel not loaded yet")
        end
        return
    end

    if cmd == "help" then
        C:Print("commands:")
        C:Print("  /rf                   open the RageForge settings window")
        C:Print("  /rf options           open the RageForge settings window")
        C:Print("  /rf tm <0|3|5>        set Tactical Mastery rank (rage retained on stance change)")
        C:Print("  /rf lock              lock/unlock the bar (drag to move when unlocked)")
        C:Print("  /rf scale <0.5-2.0>   set UI scale")
        C:Print("  /rf reset             reset position to default")
        C:Print("  /rf ticks             toggle threshold tick marks")
        C:Print("  /rf stances           toggle stance icon rail")
        C:Print("  /rf ghost             toggle ghost line (post-stance-dance preview)")
        return
    end

    if cmd == "options" or cmd == "config" or cmd == "opt" then
        if ns.Options and ns.Options.Open then
            ns.Options:Open()
        else
            C:Print("options panel not loaded yet")
        end
        return
    end

    if cmd == "tm" then
        local n = tonumber(rest)
        if n == 0 then C:Set("tacticalMasteryRetained", 0)
        elseif n == 3 then C:Set("tacticalMasteryRetained", 15)
        elseif n == 5 then C:Set("tacticalMasteryRetained", 25)
        elseif n then C:Set("tacticalMasteryRetained", math.max(0, math.min(25, n))) -- raw value too
        else
            C:Print("usage: /rf tm <0|3|5>  (or a raw rage number 0-25)")
            return
        end
        C:Print(("Tactical Mastery retained rage: %d"):format(C:Get("tacticalMasteryRetained")))
        return
    end

    if cmd == "lock" then
        C:Set("locked", not C:Get("locked"))
        C:Print(C:Get("locked") and "bar locked" or "bar unlocked - drag to move")
        return
    end

    if cmd == "scale" then
        local s = tonumber(rest)
        if not s then C:Print("usage: /rf scale 1.0"); return end
        s = math.max(0.5, math.min(2.0, s))
        C:Set("scale", s)
        C:Print(("scale: %.2f"):format(s))
        return
    end

    if cmd == "reset" then
        C.db.position = { point = "CENTER", relPoint = "CENTER", x = -220, y = 0 }
        if ns.RageBar then ns.RageBar:ApplyConfig() end
        C:Print("position reset")
        return
    end

    if cmd == "ticks" then
        C:Set("showTicks", not C:Get("showTicks"))
        C:Print(C:Get("showTicks") and "ticks on" or "ticks off")
        return
    end

    if cmd == "stances" or cmd == "stance" then
        C:Set("showStanceIcons", not C:Get("showStanceIcons"))
        C:Print(C:Get("showStanceIcons") and "stance icons on" or "stance icons off")
        return
    end

    if cmd == "ghost" then
        C:Set("showGhostLine", not C:Get("showGhostLine"))
        C:Print(C:Get("showGhostLine") and "ghost line on" or "ghost line off")
        return
    end

    C:Print("unknown command. /rf help for options.")
end

function C:RegisterSlash()
    SLASH_RAGEFORGE1 = "/rf"
    SLASH_RAGEFORGE2 = "/rageforge"
    SlashCmdList["RAGEFORGE"] = handleSlash
end
