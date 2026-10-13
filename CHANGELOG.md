# Changelog

## 0.13.1

- Removed Ember and Filigree. Frame choices are None, Iron, Bloodforged, and
  Warlord. **Warlord** is the default for new installs. Saved settings that
  still say ember or filigree fall back to Warlord. Blade stays the default
  bar style.

## 0.13.0

- **Thin metal frames:** Iron, Bloodforged, and Warlord stay selectable (plus
  None). Outlines are thinner, and the top/bottom caps span exactly the outer
  rail width so they close the curve instead of sticking out past it.
- **Illustrated frames:** `Ember` (molten crescent) and `Filigree` (gold
  scrollwork crescent), original art in the spirit of retail spell-proc
  overlays. Not Blizzard textures. `/rf frame ember|filigree`.

## 0.12.0

- **Closed frame caps** at top and bottom (forged end plates); rails no longer open.
- **Seamless vertical fill:** StatusBar segments use `VERTICAL` orientation
  (rage rises up / falls down the curve), solid `SoftFill` (no edge darkening),
  heavy overlap, and `SetSnapToPixelGrid(false)` / `SetTexelSnappingBias(0)`.
- **Richer frames:** `Iron` (simple steel), `Bloodforged` (matte/obsidian
  black iron + molten red-orange ember glow — Blackrock fold-in), new
  `Warlord` (dark iron + gold trim + warrior tan `#C69B6D` + shield/axe
  caps). Secret-safe `InnerGlow` StatusBars intensify with rage.
- **Threshold markers:** deep notches in the frame art; larger outlined labels
  colored by meaning (25 = TM retain / class tan).
- **Icon clearance:** stance rail and Battle Shout shift outward by per-frame
  clearance so they no longer overlap the rim.

## 0.11.0

- **Forever curve polish:** denser overlapping StatusBar segments with
  soft-edged `SoftFill` texture (no per-segment borders); single curved
  `SoftTrackCurve` background track; subtle zone gradient shading.
- **Frame overlays:** warrior-themed `Iron` (default) and `Bloodforged`
  rim textures in `RageForge/Media/`, plus `None`. Settings radios and
  `/rf frame <none|iron|bloodforged>`. Works on Forever and TBC.
- Blade remains the default bar style for new installs.

## 0.10.4

- Options panel uses a ScrollFrame; credits sit at the end of scroll content
  (no more footer overlapping Display checkboxes / overflowing the Options frame).
  Mouse-wheel scrolling works on Forever and TBC.
- Default bar style for **new installs** is **blade**. Existing SavedVariables
  keep their chosen style.

## 0.10.3

- Safe `RegisterEvent` everywhere (`C_EventUtils.IsEventValid` when present,
  else `pcall`). Forever no longer errors on `LEARNED_SPELL_IN_TAB`; also
  listens for `LEARNED_SPELL_IN_SKILL_LINE`.

## 0.10.2

- **Options > AddOns registration:** Forever uses `Settings.RegisterCanvasLayoutCategory`
  + `RegisterAddOnCategory`; TBC falls back to `InterfaceOptions_AddCategory`.
  `/rf` opens the Blizzard category (`Settings.OpenToCategory` /
  `InterfaceOptionsFrame_OpenToCategory`) with a standalone window as fallback.
- **Addon compartment** entry on Forever/Camelot TOCs.
- **Bar style selector** (Ribbon / Blade / Classic) with live `RageBar:Rebuild()`
  and a Reload UI button beside it.
- **Stance rail:** only shows stances returned by `GetNumShapeshiftForms` /
  `GetShapeshiftFormInfo` (learned/unlocked). Relayout packs icons with no gaps.
  Refreshes on `UPDATE_SHAPESHIFT_FORMS`, `SPELLS_CHANGED`, `LEARNED_SPELL_IN_TAB`,
  and `PLAYER_LEVEL_UP`.

## 0.10.1

- **Forever curved combat fill:** replaced the straight StatusBar fallback with a
  stack of short `StatusBar` segments along the curve. Each segment uses plain
  `SetMinMaxValues(rageLow, rageHigh)` and passes (possibly secret) `UnitPower`
  to `SetValue` — engine-side fill, no Lua math on secrets
  (warcraft.wiki.gg Secret_Values / StatusBar BarValue aspect).
- Forever uses this curved path **in and out of combat** so the shape no longer
  collapses when restrictions flip.
- Ghost notch on Forever uses a tiny StatusBar gated at retained rage (engine
  compare). Dump-hint `-X` text still hides while rage is secret.
- **Bar styles:** `classic` / `ribbon` (default) / `blade` via `/rf style` and
  the settings window. Ribbon is thinner, deeper bow, fewer ticks (25/50/75).
- Schema 10 migrates existing users onto the ribbon defaults (`/reload` after
  style changes that alter geometry).

## 0.10.0

- **WoW Forever support** from the same addon folder as TBC Anniversary.
  - Multi-TOC: `RageForge_TBC.toc` (Interface **20506**), `RageForge_Forever.toc`
    and `RageForge_Camelot.toc` (Interface **16001**, Forever Beta), plus
    unsuffixed `RageForge.toc` fallback.
  - `Compat.lua` feature-detects `C_Spell`, `C_UnitAuras`, and secret-value
    APIs. Does **not** branch on `WOW_PROJECT_ID`.
  - `ForeverDisplay.lua` (Forever TOC only): when player rage is secret in
    combat, the curved slice fill degrades to a vertical StatusBar + ColorCurve
    path. Ghost line, dump hint, and rage-cap glow comparisons hide until rage
    is readable again (typically out of combat).
  - Battle Shout reminder uses `C_UnitAuras` on Forever; when auras are secret,
    falls back to the local `UNIT_SPELLCAST_SUCCEEDED` countdown.
- Bumped Anniversary Interface from 20505 to **20506** (Warcraft Wiki).
- Added `/rf status` for client / secret-value diagnostics.
- Added `.pkgmeta` for CurseForge / Wago / BigWigs multi-flavor packaging.
- **Unverified until in-game Forever beta check:** Interface `16001` may change
  at launch (Nov 4 2026). Confirm with `/dump select(4, GetBuildInfo())`.

## 0.9.8

- Fixed settings window layout: bottom checkboxes (Stance icon rail, Big rage number, Rage cap warning, Battle Shout reminder) were overlapping the about/credits/footer text. Window grew taller and a separator line now divides the controls from the footer.

## 0.9.7

- Added Battle Shout reminder with missing/expiring states, countdown text, death suppression, and local countdown fallback for Classic aura timing.
- Added stance icon rail with rotated cropped icons and active stance border.
- Added standalone `/rf` settings window with live preview controls.
- Added left-side dump hint and retained-rage ghost marker.
- Added rage thresholds at 10 / 15 / 25 / 30 / 50 / 75.
- Removed Overpower overlay module after visual testing.
- Improved curved rage bar rendering with blended colors and soft edge feathering.
- Added creator bio/social links in README and in-game settings.
- Bundled `Prototype.ttf` font with original `Prototype.txt` readme for attribution.

## 0.1.0-alpha

- Initial curved rage bar prototype for TBC warrior stance-dance decisions.
