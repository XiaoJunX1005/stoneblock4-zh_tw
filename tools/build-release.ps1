param(
    [string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$resourceRoot = Join-Path $repoRoot "resourcepacks\sb4-zh_tw"
$kubejsRoot = Join-Path $repoRoot "kubejs"
$stagingRoot = Join-Path $repoRoot "tools\out\release_staging"
$outDir = Join-Path $repoRoot "tools\out"
$zipName = "sb4-zh_tw-v$Version.zip"
$zipPath = Join-Path $outDir $zipName

if (-not (Test-Path (Join-Path $resourceRoot "pack.mcmeta"))) {
    throw "Missing required file: resourcepacks/sb4-zh_tw/pack.mcmeta"
}
if (-not (Test-Path (Join-Path $resourceRoot "assets"))) {
    throw "Missing required directory: resourcepacks/sb4-zh_tw/assets/"
}

$langFiles = Get-ChildItem -Path (Join-Path $resourceRoot "assets") -Recurse -Filter "zh_tw.json" |
    Where-Object { $_.FullName -match "\\lang\\zh_tw\.json$" }

$jsonErrors = @()
foreach ($file in $langFiles) {
    try {
        Get-Content -Raw -Encoding UTF8 -Path $file.FullName | ConvertFrom-Json | Out-Null
    } catch {
        $jsonErrors += [PSCustomObject]@{
            Path = $file.FullName
            Error = $_.Exception.Message
        }
    }
}

if ($jsonErrors.Count -gt 0) {
    Write-Output "JSON validation failed for the following files:"
    foreach ($err in $jsonErrors) {
        Write-Output ("- {0}: {1}" -f $err.Path, $err.Error)
    }
    throw "JSON validation failed."
}

if (Test-Path $stagingRoot) {
    Remove-Item -Recurse -Force $stagingRoot
}
New-Item -ItemType Directory -Path $stagingRoot | Out-Null

$resourceDest = Join-Path $stagingRoot "resourcepacks\sb4-zh_tw"
New-Item -ItemType Directory -Path $resourceDest | Out-Null
Copy-Item -Recurse -Force -Path (Join-Path $resourceRoot "*") -Destination $resourceDest

if (Test-Path $kubejsRoot) {
    Copy-Item -Recurse -Force -Path $kubejsRoot -Destination $stagingRoot
}

$forbiddenPaths = @(
    (Join-Path $stagingRoot "docs"),
    (Join-Path $stagingRoot "tools"),
    (Join-Path $stagingRoot ".gitignore"),
    (Join-Path $stagingRoot "package.json"),
    (Join-Path $stagingRoot "package-lock.json")
)

$badHits = @()
foreach ($path in $forbiddenPaths) {
    if (Test-Path $path) {
        $badHits += $path
    }
}

if ($badHits.Count -gt 0) {
    Write-Output "Forbidden paths found in staging:"
    foreach ($hit in $badHits) {
        Write-Output ("- {0}" -f $hit)
    }
    throw "Forbidden paths found in staging."
}

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

Compress-Archive -Path (Join-Path $stagingRoot "*") -DestinationPath $zipPath
Write-Output ("Release ZIP created: {0}" -f $zipPath)
