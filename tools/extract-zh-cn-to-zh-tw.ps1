[CmdletBinding(DefaultParameterSetName = 'Extract')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Extract')]
    [string]$ModsDir,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter()]
    [string]$PackName = 'sb4-zh_tw',

    [Parameter()]
    [switch]$Overwrite,

    [Parameter(Mandatory = $true, ParameterSetName = 'Apply')]
    [string]$ApplyBundle
)

$ErrorActionPreference = 'Stop'

function Get-Utf8NoBom {
    return New-Object System.Text.UTF8Encoding($false)
}

function Read-ZipEntryText {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchiveEntry]$Entry
    )
    $stream = $Entry.Open()
    try {
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.UTF8Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$bundlePath = Join-Path $RepoRoot 'tools\out\zh_cn_bundle.json'
$assetsRoot = Join-Path $RepoRoot ("resourcepacks\{0}\assets" -f $PackName)

$extracted = 0
$skipped = 0
$errors = 0
$applyWritten = 0

if ($PSCmdlet.ParameterSetName -eq 'Extract') {
    if (-not (Test-Path $ModsDir)) {
        throw "ModsDir not found: $ModsDir"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $bundleMods = [ordered]@{}
    $jars = Get-ChildItem -Path $ModsDir -Filter *.jar -File

    foreach ($jar in $jars) {
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -match '^assets/([^/]+)/lang/zh_cn\.json$') {
                    $modid = $matches[1]
                    if ($bundleMods.Contains($modid)) {
                        $errors++
                        Write-Warning "Duplicate modid '$modid' found in $($jar.Name); skipping."
                        continue
                    }

                    $content = Read-ZipEntryText -Entry $entry
                    try {
                        $jsonObj = $content | ConvertFrom-Json
                    } catch {
                        $errors++
                        Write-Warning "Invalid JSON in $($jar.Name) for mod '$modid'; skipping."
                        continue
                    }

                    $bundleMods[$modid] = $jsonObj

                    $targetDir = Join-Path $assetsRoot ("{0}\lang" -f $modid)
                    $targetFile = Join-Path $targetDir 'zh_tw.json'
                    if ((Test-Path $targetFile) -and (-not $Overwrite)) {
                        $skipped++
                        continue
                    }

                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                    [System.IO.File]::WriteAllText($targetFile, $content, (Get-Utf8NoBom))
                    $extracted++
                }
            }
        } catch {
            $errors++
            Write-Warning "Failed to read jar: $($jar.FullName). $($_.Exception.Message)"
        } finally {
            if ($zip) { $zip.Dispose() }
        }
    }

    $bundle = [ordered]@{
        mods = $bundleMods
    }
    $bundleJson = $bundle | ConvertTo-Json -Depth 100
    New-Item -ItemType Directory -Path (Split-Path $bundlePath -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($bundlePath, $bundleJson, (Get-Utf8NoBom))
}

if ($PSCmdlet.ParameterSetName -eq 'Apply') {
    if (-not (Test-Path $ApplyBundle)) {
        throw "ApplyBundle not found: $ApplyBundle"
    }

    $bundleText = Get-Content -Path $ApplyBundle -Raw -Encoding UTF8
    try {
        $bundleObj = $bundleText | ConvertFrom-Json
    } catch {
        throw "ApplyBundle is not valid JSON: $ApplyBundle"
    }

    if (-not $bundleObj.PSObject.Properties.Match('mods')) {
        throw "ApplyBundle missing 'mods' object: $ApplyBundle"
    }
    $modsObj = $bundleObj.mods
    if (-not $modsObj) {
        throw "ApplyBundle 'mods' is empty: $ApplyBundle"
    }

    $modIds = @()
    if ($modsObj -is [hashtable]) {
        $modIds = $modsObj.Keys
    } else {
        $modIds = $modsObj.PSObject.Properties.Name
    }

    $applyTotal = $modIds.Count
    $applyFailed = 0

    foreach ($modid in $modIds) {
        try {
            $targetDir = Join-Path $assetsRoot ("{0}\lang" -f $modid)
            $targetFile = Join-Path $targetDir 'zh_tw.json'
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

            if ($modsObj -is [hashtable]) {
                $modJson = $modsObj[$modid] | ConvertTo-Json -Depth 100
            } else {
                $modJson = $modsObj.$modid | ConvertTo-Json -Depth 100
            }
            [System.IO.File]::WriteAllText($targetFile, $modJson, (Get-Utf8NoBom))
            $applyWritten++
        } catch {
            $applyFailed++
            $errors++
            Write-Warning "Failed to apply mod '$modid': $($_.Exception.Message)"
        }
    }

    Write-Host ("Apply bundle: total={0}, success={1}, failed={2}" -f $applyTotal, $applyWritten, $applyFailed)
}

Write-Host "Summary:"
Write-Host ("  extracted: {0}" -f $extracted)
Write-Host ("  skipped:   {0}" -f $skipped)
Write-Host ("  errors:    {0}" -f $errors)
Write-Host ("  bundle:    {0}" -f $bundlePath)
Write-Host ("  applied:   {0}" -f $applyWritten)
