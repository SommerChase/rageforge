param(
    [string]$Version
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AddonDir = Join-Path $Root "RageForge"
$TocPath = Join-Path $AddonDir "RageForge.toc"

if (-not (Test-Path $AddonDir)) {
    throw "Missing addon directory: $AddonDir"
}

if (-not $Version) {
    $toc = Get-Content $TocPath
    $versionLine = $toc | Where-Object { $_ -match "^## Version:" } | Select-Object -First 1
    if (-not $versionLine) {
        throw "Could not read version from $TocPath"
    }
    $Version = ($versionLine -replace "^## Version:\s*", "").Trim()
}

$BuildDir = Join-Path $Root "build"
$DistDir = Join-Path $Root "dist"
$StageRoot = Join-Path $BuildDir "RageForge-package"
$StageAddon = Join-Path $StageRoot "RageForge"
$ZipPath = Join-Path $DistDir ("RageForge-v{0}.zip" -f $Version)

Remove-Item $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $StageAddon -Force | Out-Null
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

Copy-Item -Path (Join-Path $AddonDir "*") -Destination $StageAddon -Recurse -Force

# Prototype.ttf ships in releases per the font's own readme, which asks that
# Prototype.txt be included with any redistribution. Make sure both are present.
$PrototypeFont   = Join-Path $StageAddon "Fonts\Prototype.ttf"
$PrototypeReadme = Join-Path $StageAddon "Fonts\Prototype.txt"
if (-not (Test-Path $PrototypeFont)) {
    Write-Warning "Prototype.ttf is missing from the staged build. The release will rely on the SKURRI fallback."
} elseif (-not (Test-Path $PrototypeReadme)) {
    throw "Prototype.ttf is bundled but Prototype.txt is missing; ship both for attribution or remove the font."
}

Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path $StageAddon -DestinationPath $ZipPath

Write-Host "Created $ZipPath"
