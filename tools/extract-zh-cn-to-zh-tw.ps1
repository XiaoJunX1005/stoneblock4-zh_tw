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
$extractSkipped = 0
$errors = 0
$applyWritten = 0
$applySkipped = 0
$applyCreated = 0
$applyUpdated = 0

function ConvertTo-HashtableFromJsonObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$JsonObject
    )
    if ($JsonObject -is [hashtable]) {
        return $JsonObject
    }
    $map = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    foreach ($prop in $JsonObject.PSObject.Properties) {
        $map[$prop.Name] = $prop.Value
    }
    return $map
}

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
                        $extractSkipped++
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
        $modsObj = $null
    } else {
        $modsObj = $bundleObj.mods
    }

    $applyItems = New-Object System.Collections.Generic.List[object]
    if ($modsObj) {
        $modIds = @()
        if ($modsObj -is [hashtable]) {
            $modIds = $modsObj.Keys
        } else {
            $modIds = $modsObj.PSObject.Properties.Name
        }

        foreach ($modid in $modIds) {
            if (-not $modid) { continue }
            $entriesObj = if ($modsObj -is [hashtable]) { $modsObj[$modid] } else { $modsObj.$modid }
            if ($null -eq $entriesObj) { continue }
            $applyItems.Add([pscustomobject]@{
                modid   = [string]$modid
                entries = ConvertTo-HashtableFromJsonObject -JsonObject $entriesObj
            })
        }
    } elseif ($bundleObj.PSObject.Properties.Match('items') -and ($bundleObj.items -is [System.Collections.IEnumerable])) {
        foreach ($item in $bundleObj.items) {
            if (-not $item) { continue }
            $modid = [string]$item.modid
            if (-not $modid) { continue }
            $entriesObj = $item.entries
            if ($null -eq $entriesObj) { continue }
            $applyItems.Add([pscustomobject]@{
                modid   = $modid
                entries = ConvertTo-HashtableFromJsonObject -JsonObject $entriesObj
            })
        }
    } else {
        throw "ApplyBundle missing 'mods' or 'items' array: $ApplyBundle"
    }

    if ($applyItems.Count -eq 0) {
        throw "ApplyBundle has no entries to apply: $ApplyBundle"
    }

    $applyTotal = $applyItems.Count
    $applyFailed = 0

    foreach ($item in $applyItems) {
        $modid = $item.modid
        try {
            $targetDir = Join-Path $assetsRoot ("{0}\lang" -f $modid)
            $targetFile = Join-Path $targetDir 'zh_tw.json'
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

            $fileExists = Test-Path $targetFile
            $currentMap = @{}
            if ($fileExists) {
                try {
                    $existingText = Get-Content -Path $targetFile -Raw -Encoding UTF8
                    $existingObj = $existingText | ConvertFrom-Json
                    $currentMap = ConvertTo-HashtableFromJsonObject -JsonObject $existingObj
                } catch {
                    Write-Warning "Invalid existing zh_tw.json for mod '$modid'; treating as empty."
                    $currentMap = @{}
                }
            }

            $entries = $item.entries
            $changed = $false
            foreach ($key in $entries.Keys) {
                if ($currentMap.ContainsKey($key) -and (-not $Overwrite)) {
                    $applySkipped++
                    continue
                }
                $currentMap[$key] = $entries[$key]
                $applyWritten++
                $changed = $true
            }

            if ($changed) {
                $modJson = $currentMap | ConvertTo-Json -Depth 100
                [System.IO.File]::WriteAllText($targetFile, $modJson, (Get-Utf8NoBom))
                if ($fileExists) { $applyUpdated++ } else { $applyCreated++ }
            }
        } catch {
            $applyFailed++
            $errors++
            Write-Warning "Failed to apply mod '$modid': $($_.Exception.Message)"
        }
    }

    Write-Host ("Apply bundle: totalMods={0}, applied={1}, skipped={2}, created={3}, updated={4}, failed={5}" -f $applyTotal, $applyWritten, $applySkipped, $applyCreated, $applyUpdated, $applyFailed)
}

Write-Host "Summary:"
Write-Host ("  extracted: {0}" -f $extracted)
Write-Host ("  skipped:   {0}" -f $extractSkipped)
Write-Host ("  errors:    {0}" -f $errors)
Write-Host ("  bundle:    {0}" -f $bundlePath)
Write-Host ("  applied:   {0}" -f $applyWritten)
Write-Host ("  skipped:   {0}" -f $applySkipped)
Write-Host ("  created:   {0}" -f $applyCreated)
Write-Host ("  updated:   {0}" -f $applyUpdated)
