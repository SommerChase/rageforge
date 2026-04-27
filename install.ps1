# RageForge install script
# Copies (or junctions) the addon into your WoW Anniversary AddOns folder.
#
# Usage:
#   .\install.ps1                  # copy files (default)
#   .\install.ps1 -Symlink         # create a junction so edits in the repo are live
#   .\install.ps1 -Uninstall       # remove the addon from AddOns
#   .\install.ps1 -WowPath "..."   # override WoW client folder

[CmdletBinding()]
param(
    [string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_anniversary_",
    [switch]$Symlink,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceDir  = Join-Path $RepoRoot "RageForge"
$AddonsRoot = Join-Path $WowPath "Interface\AddOns"
$DestDir    = Join-Path $AddonsRoot "RageForge"

if (-not (Test-Path $WowPath)) {
    Write-Error "WoW path not found: $WowPath`nPass -WowPath '...' to override."
}

if (-not (Test-Path $AddonsRoot)) {
    Write-Host "Creating AddOns directory: $AddonsRoot"
    New-Item -ItemType Directory -Path $AddonsRoot -Force | Out-Null
}

function Remove-Existing {
    if (Test-Path $DestDir) {
        $item = Get-Item $DestDir -Force
        # Detect a junction/reparse point so we don't accidentally delete the source.
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Host "Removing existing junction: $DestDir"
            cmd /c rmdir "$DestDir" | Out-Null
        } else {
            Write-Host "Removing existing folder: $DestDir"
            Remove-Item -Path $DestDir -Recurse -Force
        }
    }
}

if ($Uninstall) {
    Remove-Existing
    Write-Host "RageForge uninstalled."
    return
}

if (-not (Test-Path $SourceDir)) {
    Write-Error "Source folder missing: $SourceDir"
}

Remove-Existing

if ($Symlink) {
    # Junction works without admin and behaves like a folder. Edits in the repo
    # are reflected live in WoW; just /reload (or relog) to pick up changes.
    Write-Host "Creating junction: $DestDir -> $SourceDir"
    New-Item -ItemType Junction -Path $DestDir -Target $SourceDir | Out-Null
} else {
    Write-Host "Copying $SourceDir -> $DestDir"
    Copy-Item -Path $SourceDir -Destination $DestDir -Recurse -Force
}

Write-Host ""
Write-Host "RageForge installed at:" -ForegroundColor Green
Write-Host "  $DestDir"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Launch WoW Anniversary (TBC)."
Write-Host "  2. At character select, click AddOns and verify RageForge is enabled."
Write-Host "  3. In game, type /rf help to see commands. Default Tactical Mastery is 5/5 (25 retained)."
Write-Host "  4. Type /rf lock to unlock the bar and drag it to position; /rf lock again to lock."
