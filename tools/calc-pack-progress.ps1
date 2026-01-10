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
    [switch]$ExportCsv
)

$ErrorActionPreference = 'Stop'

function Get-Utf8NoBom {
    return New-Object System.Text.UTF8Encoding($false)
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

$errorList = New-Object System.Collections.Generic.List[psobject]
$modMap = @{}

if (-not (Test-Path $ModsDir)) {
    throw "ModsDir not found: $ModsDir"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$jars = Get-ChildItem -Path $ModsDir -Filter *.jar -File
$entryPattern = '^assets/([^/]+)/lang/en_us\.json$'

foreach ($jar in $jars) {
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match $entryPattern) {
                $modid = $matches[1]
                $content = Read-ZipEntryText -Entry $entry
                $jsonObj = $null
                try {
                    $jsonObj = $content | ConvertFrom-Json
                } catch {
                    $errorList.Add([pscustomobject]@{
                        jar    = $jar.Name
                        reason = "Invalid JSON for $modid en_us.json: $($_.Exception.Message)"
                    })
                    continue
                }

                $map = ConvertTo-HashtableFromJsonObject -JsonObject $jsonObj
                $total = $map.Count

                if (-not $modMap.ContainsKey($modid) -or $total -gt $modMap[$modid].total) {
                    $enSet = New-OrdinalHashSet
                    foreach ($key in $map.Keys) {
                        [void]$enSet.Add([string]$key)
                    }
                    $modMap[$modid] = [pscustomobject]@{
                        modid     = $modid
                        total     = $total
                        enKeys    = $enSet
                        sourceJar = $jar.FullName
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
}

$rows = New-Object System.Collections.Generic.List[psobject]

foreach ($modid in ($modMap.Keys | Sort-Object)) {
    $entry = $modMap[$modid]
    $zhPath = Join-Path $PackAssetsRoot ("{0}\lang\zh_tw.json" -f $modid)
    $zhSet = New-OrdinalHashSet
    if (Test-Path $zhPath) {
        try {
            $zhObj = (Get-Content -Path $zhPath -Raw -Encoding UTF8) | ConvertFrom-Json
            $zhMap = ConvertTo-HashtableFromJsonObject -JsonObject $zhObj
            foreach ($key in $zhMap.Keys) {
                [void]$zhSet.Add([string]$key)
            }
        } catch {
            $errorList.Add([pscustomobject]@{
                jar    = (Split-Path $entry.sourceJar -Leaf)
                reason = "Invalid zh_tw.json for ${modid}: $($_.Exception.Message)"
            })
        }
    }

    $translated = 0
    foreach ($key in $entry.enKeys) {
        if ($zhSet.Contains($key)) {
            $translated++
        }
    }

    $remaining = $entry.total - $translated
    if ($remaining -lt 0) { $remaining = 0 }
    $percent = if ($entry.total -gt 0) { [math]::Round(($translated / $entry.total) * 100, 1) } else { 0 }

    $rows.Add([pscustomobject]@{
        modid       = $modid
        translated  = $translated
        total       = $entry.total
        remaining   = $remaining
        percent     = $percent
        sourceJar   = $entry.sourceJar
        zh_tw_path  = $zhPath
    })
}

$sortedRows = $rows | Sort-Object -Property @{ Expression = 'remaining'; Descending = $true }, modid

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
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $csvPath = Join-Path $OutDir 'pack_progress.csv'
    $csvLines = $sortedRows | Select-Object modid, translated, total, remaining, percent, sourceJar, zh_tw_path | ConvertTo-Csv -NoTypeInformation
    [System.IO.File]::WriteAllLines($csvPath, $csvLines, (Get-Utf8NoBom))
    Write-Output ("CSV exported: {0}" -f $csvPath)
}

if ($errorList.Count -gt 0) {
    Write-Output "Errors:"
    foreach ($err in $errorList) {
        Write-Output ("- {0}: {1}" -f $err.jar, $err.reason)
    }
}
