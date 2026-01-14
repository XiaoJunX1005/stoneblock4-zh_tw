[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoRoot,

    [Parameter()]
    [string]$GameRoot = 'C:\Users\sad79\AppData\Roaming\PrismLauncher\instances\FTB StoneBlock 4\minecraft',

    [Parameter()]
    [string]$ModsDir,

    [Parameter()]
    [string]$PackName = 'sb4-zh_tw',

    [Parameter()]
    [string]$PackAssetsRoot,

    [Parameter()]
    [string]$OutDir,

    [Parameter()]
    [string]$OutCsv,

    [Parameter()]
    [switch]$ExportCsv,

    [Parameter()]
    [switch]$DebugMissing
)

$ErrorActionPreference = 'Stop'

function Get-Utf8NoBom {
    return New-Object System.Text.UTF8Encoding($false)
}

function New-CaseSensitiveHashtable {
    return New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
}

function New-OrdinalHashSet {
    return New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
}

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

function Convert-LangToMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )
    $map = New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
    $lines = $Content -split "`n"
    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1)
        if ($key.Length -eq 0) { continue }
        $map[$key] = $val
    }
    return $map
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

function Get-InferredNamespace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$SourceModId
    )
    $keyText = $Key.ToLowerInvariant()
    $sourceText = $SourceModId.ToLowerInvariant()

    if ($sourceText -eq 'rarcompat') {
        if ($keyText -match '\.relics\.' -or $keyText -like 'relics.*' -or $keyText -like 'key.relics.*') {
            return 'relics'
        }
    }

    if ($keyText -match '^(item|block|entity|key|subtitles|effect|enchantment|advancement|gui|config|stat)\.([a-z0-9_]+)\.') {
        return $matches[2]
    }
    if ($keyText -match '^([a-z0-9_]+)\.') {
        return $matches[1]
    }
    return $sourceText
}

function Build-ZhTwIndex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetsRoot
    )

    $index = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path $AssetsRoot)) {
        return $index
    }

    $regex = [regex]"assets[\\/]+([^\\/]+)[\\/]+lang[\\/]zh_tw\.json$"
    $files = Get-ChildItem -Path $AssetsRoot -Recurse -Filter 'zh_tw.json' -File
    foreach ($file in $files) {
        if (-not ($file.FullName -match $regex)) {
            continue
        }
        $sourceModId = $matches[1].ToLowerInvariant()
        try {
            $zhObj = (Get-Content -Path $file.FullName -Raw -Encoding UTF8) | ConvertFrom-Json
        } catch {
            Write-Warning "Invalid zh_tw.json for mod '$sourceModId' at $($file.FullName): $($_.Exception.Message)"
            continue
        }

        foreach ($prop in $zhObj.PSObject.Properties) {
            $key = [string]$prop.Name
            $owner = Get-InferredNamespace -Key $key -SourceModId $sourceModId
            if (-not $index.ContainsKey($owner)) {
                $index[$owner] = New-CaseSensitiveHashtable
            }
            if (-not $index[$owner].ContainsKey($key)) {
                $index[$owner][$key] = $prop.Value
            }
        }
    }

    return $index
}

if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
if (-not $ModsDir) {
    $ModsDir = Join-Path $GameRoot 'mods'
}
if (-not $PackAssetsRoot) {
    $PackAssetsRoot = Join-Path $RepoRoot ("resourcepacks\{0}\assets" -f $PackName)
}
if (-not $OutDir) {
    $OutDir = Join-Path $RepoRoot 'tools\out'
}
if (-not $OutCsv) {
    $OutCsv = Join-Path $RepoRoot 'pack_progress.csv'
}

$errorList = New-Object System.Collections.Generic.List[psobject]
$modMap = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([System.StringComparer]::OrdinalIgnoreCase)

if (-not (Test-Path $ModsDir)) {
    throw "ModsDir not found: $ModsDir"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$jars = Get-ChildItem -Path $ModsDir -Filter *.jar -File
$entryPattern = '^assets/([^/]+)/lang/en_us\.(json|lang)$'

foreach ($jar in $jars) {
    $zip = $null
    $foundEntry = $false
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match $entryPattern) {
                $sourceModId = $matches[1].ToLowerInvariant()
                $format = $matches[2]
                $foundEntry = $true
                $content = Read-ZipEntryText -Entry $entry
                $map = $null
                if ($format -eq 'json') {
                    $jsonObj = $null
                    try {
                        $jsonObj = $content | ConvertFrom-Json
                    } catch {
                        $errorList.Add([pscustomobject]@{
                            jar    = $jar.Name
                            reason = "Invalid JSON for $sourceModId en_us.json: $($_.Exception.Message)"
                        })
                        continue
                    }
                    $map = ConvertTo-HashtableFromJsonObject -JsonObject $jsonObj
                } else {
                    try {
                        $map = Convert-LangToMap -Content $content
                    } catch {
                        $errorList.Add([pscustomobject]@{
                            jar    = $jar.Name
                            reason = "Invalid en_us.lang for ${sourceModId}: $($_.Exception.Message)"
                        })
                        continue
                    }
                }

                foreach ($key in $map.Keys) {
                    $owner = Get-InferredNamespace -Key ([string]$key) -SourceModId $sourceModId
                    if (-not $modMap.ContainsKey($owner)) {
                        $modMap[$owner] = [pscustomobject]@{
                            modid       = $owner
                            enMap       = New-CaseSensitiveHashtable
                            sourceJar   = $jar.FullName
                            sourceEntry = $entry.FullName
                        }
                    }
                    $entryOwner = $modMap[$owner]
                    if (-not $entryOwner.enMap.ContainsKey([string]$key)) {
                        $entryOwner.enMap[[string]$key] = $map[$key]
                    }
                }
            }
        }
    } catch {
        $errorList.Add([pscustomobject]@{
            jar    = $jar.Name
            reason = "Failed to read jar: $($_.Exception.Message)"
        })
    } finally {
        if ($zip) { $zip.Dispose() }
    }
    if (-not $foundEntry) {
        $errorList.Add([pscustomobject]@{
            jar    = $jar.Name
            reason = "No en_us.json or en_us.lang found; skipped"
        })
    }
}

$rows = New-Object System.Collections.Generic.List[psobject]
$diagnosticRows = New-Object System.Collections.Generic.List[psobject]
$zhIndex = Build-ZhTwIndex -AssetsRoot $PackAssetsRoot

foreach ($modid in ($modMap.Keys | Sort-Object)) {
    $entry = $modMap[$modid]
    $zhPath = Join-Path $PackAssetsRoot ("{0}\lang\zh_tw.json" -f $modid)
    $zhMap = if ($zhIndex.ContainsKey($modid)) { $zhIndex[$modid] } else { New-CaseSensitiveHashtable }

    $translated = 0
    foreach ($key in $entry.enMap.Keys) {
        if (-not $zhMap.ContainsKey($key)) {
            continue
        }
        $enVal = $entry.enMap[$key]
        $zhVal = $zhMap[$key]
        $enStr = if ($null -eq $enVal) { '' } else { [string]$enVal }
        $zhStr = if ($null -eq $zhVal) { '' } else { [string]$zhVal }
        $enEmpty = [string]::IsNullOrWhiteSpace($enStr)
        $zhEmpty = [string]::IsNullOrWhiteSpace($zhStr)
        if ($enEmpty) {
            $translated++
            continue
        }
        if (-not $zhEmpty) {
            $translated++
            continue
        }
        if ($DebugMissing) {
            $diagnosticRows.Add([pscustomobject]@{
                modid    = $modid
                key      = $key
                en_empty = $enEmpty
                zh_empty = $zhEmpty
            })
        }
    }

    $total = $entry.enMap.Count
    $remaining = $total - $translated
    if ($remaining -lt 0) { $remaining = 0 }
    $percent = if ($total -gt 0) { [math]::Round(($translated / $total) * 100, 1) } else { 0 }

    $rows.Add([pscustomobject]@{
        modid       = $modid
        translated  = $translated
        total       = $total
        remaining   = $remaining
        percent     = $percent
        sourceJar   = $entry.sourceJar
        zh_tw_path  = $zhPath
    })
}

$sortedRows = $rows | Sort-Object -Property @{ Expression = 'remaining'; Descending = $true }, @{ Expression = 'total'; Descending = $true }, modid

$overallTranslated = ($sortedRows | Measure-Object -Property translated -Sum).Sum
$overallTotal = ($sortedRows | Measure-Object -Property total -Sum).Sum
$overallRemaining = $overallTotal - $overallTranslated
if ($overallRemaining -lt 0) { $overallRemaining = 0 }
$overallPercent = if ($overallTotal -gt 0) { [math]::Round(($overallTranslated / $overallTotal) * 100, 1) } else { 0 }

Write-Output ("sb4-zh_tw overall progress: translated={0} / total={1}, remaining={2}, percent={3}%" -f $overallTranslated, $overallTotal, $overallRemaining, $overallPercent)

$header = "{0,-30} {1,10} {2,10} {3,10} {4,8}" -f 'modid', 'translated', 'total', 'remaining', 'percent'
Write-Output $header
Write-Output ("{0,-30} {1,10} {2,10} {3,10} {4,8}" -f ('-' * 30), ('-' * 10), ('-' * 10), ('-' * 10), ('-' * 8))

$displayRows = $sortedRows | Select-Object -First 30
foreach ($row in $displayRows) {
    Write-Output ("{0,-30} {1,10} {2,10} {3,10} {4,8}" -f $row.modid, $row.translated, $row.total, $row.remaining, ("{0}%" -f $row.percent.ToString('0.0')))
}

if ($ExportCsv) {
    $csvDir = Split-Path -Parent $OutCsv
    if (-not (Test-Path $csvDir)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }
    $csvPath = $OutCsv
    $csvLines = $sortedRows | Select-Object modid, translated, total, remaining, percent, sourceJar, zh_tw_path | ConvertTo-Csv -NoTypeInformation
    [System.IO.File]::WriteAllLines($csvPath, $csvLines, (Get-Utf8NoBom))
    Write-Output ("CSV exported: {0}" -f $csvPath)
}

if ($modMap.ContainsKey('ars_nouveau')) {
    $entry = $modMap['ars_nouveau']
    $zhMap = if ($zhIndex.ContainsKey('ars_nouveau')) { $zhIndex['ars_nouveau'] } else { New-CaseSensitiveHashtable }

    $missingKeys = New-Object System.Collections.Generic.List[string]
    $translated = 0
    foreach ($key in $entry.enMap.Keys) {
        if (-not $zhMap.ContainsKey($key)) {
            $missingKeys.Add($key) | Out-Null
            continue
        }
        $enVal = $entry.enMap[$key]
        $zhVal = $zhMap[$key]
        $enStr = if ($null -eq $enVal) { '' } else { [string]$enVal }
        $zhStr = if ($null -eq $zhVal) { '' } else { [string]$zhVal }
        $enEmpty = [string]::IsNullOrWhiteSpace($enStr)
        $zhEmpty = [string]::IsNullOrWhiteSpace($zhStr)
        if ($enEmpty) {
            $translated++
            continue
        }
        if (-not $zhEmpty) {
            $translated++
            continue
        }
        $missingKeys.Add($key) | Out-Null
    }
    $total = $entry.enMap.Count
    $remaining = $total - $translated
    if ($remaining -lt 0) { $remaining = 0 }
    Write-Output ("ars_nouveau check: translated={0} total={1} remaining={2}" -f $translated, $total, $remaining)
    $missingPreview = $missingKeys | Select-Object -First 20
    if ($missingPreview.Count -gt 0) {
        Write-Output "ars_nouveau missing keys (first 20):"
        foreach ($k in $missingPreview) { Write-Output ("- {0}" -f $k) }
    }
}

if ($DebugMissing -and $diagnosticRows.Count -gt 0) {
    Write-Output "Debug: zh_tw present but treated as untranslated (first 30)"
    $diagnosticRows | Select-Object -First 30 | ForEach-Object {
        Write-Output ("- {0}:{1} en_empty={2} zh_empty={3}" -f $_.modid, $_.key, $_.en_empty, $_.zh_empty)
    }
}

if ($errorList.Count -gt 0) {
    Write-Output "Errors:"
    foreach ($err in $errorList) {
        Write-Output ("- {0}: {1}" -f $err.jar, $err.reason)
    }
}
