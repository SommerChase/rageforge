std = "lua51"
max_line_length = false
exclude_files = { "build/", "dist/" }
-- WoW client globals (shared + Forever/Mainline family)
globals = {
  "CreateFrame", "UIParent", "DEFAULT_CHAT_FRAME", "GameTooltip", "GameTooltip_Hide",
  "SlashCmdList", "UISpecialFrames", "InterfaceOptions_AddCategory",
  "UnitPower", "UnitPowerMax", "UnitPowerPercent", "UnitClass", "UnitBuff",
  "UnitIsDeadOrGhost", "GetShapeshiftForm", "GetNumShapeshiftForms",
  "GetShapeshiftFormInfo", "GetTime", "GetBuildInfo",
  "GetAddOnMetadata", "GetSpellInfo", "GetSpellTexture",
  "IsSpellKnown", "IsPlayerSpell", "ReloadUI",
  "InterfaceOptions_AddCategory", "InterfaceOptionsFrame_OpenToCategory",
  "InterfaceOptionsFrame",
  "Enum", "C_Spell", "C_SpellBook", "C_UnitAuras", "C_Secrets", "C_CurveUtil", "C_AddOns",
  "issecretvalue", "canaccessvalue", "AbbreviateNumbers", "CreateColor",
  "Settings", "AddonCompartmentFrame", "CurveConstants",
  "RageForgeDB", "wipe",
  "RageForge_OnAddonCompartmentClick",
  "RageForge_OnAddonCompartmentEnter",
  "RageForge_OnAddonCompartmentLeave",
  "SLASH_RAGEFORGE1", "SLASH_RAGEFORGE2",
}
read_globals = {
  "WOW_PROJECT_ID", "WOW_PROJECT_CAMELOT", "WOW_PROJECT_MAINLINE",
  "LE_EXPANSION_LEVEL_CURRENT", "LE_EXPANSION_CLASSIC",
}
ignore = {
  "211", -- unused variable (common with WoW event payloads)
  "212", -- unused argument
  "213", -- unused loop variable
  "311", -- value assigned to variable is unused
  "542", -- empty if branch
}
