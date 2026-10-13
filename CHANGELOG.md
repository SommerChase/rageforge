# Changelog

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
