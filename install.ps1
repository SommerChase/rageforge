# RageForge install script
# Copies (or junctions) the addon into a WoW AddOns folder.
#
# Usage:
#   .\install.ps1                  # copy into Anniversary (default)
#   .\install.ps1 -Symlink         # create a junction so edits in the repo are live
#   .\install.ps1 -Uninstall       # remove the addon from AddOns
#   .\install.ps1 -Client Forever  # target Forever beta folder (_classic_beta_)
#   .\install.ps1 -WowPath "..."   # override WoW client folder entirely

[CmdletBinding()]
param(
    [ValidateSet("Anniversary", "Forever")]
    [string]$Client = "Anniversary",
    [string]$WowPath,
    [switch]$Symlink,
    [switch]$Uninstall
)

if (-not $WowPath) {
    if ($Client -eq "Forever") {
        # Forever beta reported under _classic_beta_ during the 1.60.x beta.
        # Live launch folder may differ — pass -WowPath if needed.
        $WowPath = "C:\Program Files (x86)\World of Warcraft\_classic_beta_"
    } else {
        $WowPath = "C:\Program Files (x86)\World of Warcraft\_anniversary_"
    }
}

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
if ($Client -eq "Forever") {
    Write-Host "  1. Launch WoW Forever (beta/live)."
    Write-Host "  2. Confirm Interface with: /dump select(4, GetBuildInfo())  (expect 16001 on Forever Beta)."
} else {
    Write-Host "  1. Launch WoW Anniversary (TBC)."
}
Write-Host "  2. At character select, click AddOns and verify RageForge is enabled."
Write-Host "  3. In game, type /rf help to see commands. Default Tactical Mastery is 5/5 (25 retained)."
Write-Host "  4. Type /rf lock to unlock the bar and drag it to position; /rf lock again to lock."
Write-Host "  5. Optional: /rf status for client / secret-value diagnostics."
