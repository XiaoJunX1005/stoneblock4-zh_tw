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
    [switch]$ReportMissing,

    [Parameter()]
    [int]$MissingTop = 20,

    [Parameter()]
    [switch]$ShowZeroOnly,

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

function Get-JsonKeysFromString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonText,
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )
    $keys = New-OrdinalHashSet
    try {
        $obj = $JsonText | ConvertFrom-Json
        $map = ConvertTo-HashtableFromJsonObject -JsonObject $obj
        foreach ($key in $map.Keys) {
            [void]$keys.Add([string]$key)
        }
        return $keys
    } catch {
        $script:parseErrors.Add([pscustomobject]@{
            path   = $SourcePath
            reason = $_.Exception.Message
        })
    }

    $pattern = '"(?<k>(?:\\.|[^"\\])+)"\s*:'
    foreach ($match in [regex]::Matches($JsonText, $pattern)) {
        $key = $match.Groups['k'].Value
        if ($key) {
            [void]$keys.Add($key)
        }
    }
    return $keys
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
$parseErrors = New-Object System.Collections.Generic.List[psobject]
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
                $sourcePath = Join-Path $jar.FullName $entry.FullName
                $enSet = Get-JsonKeysFromString -JsonText $content -SourcePath $sourcePath
                $total = $enSet.Count

                if (-not $modMap.ContainsKey($modid) -or $total -gt $modMap[$modid].total) {
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
$missingResults = New-Object System.Collections.Generic.List[psobject]

foreach ($modid in ($modMap.Keys | Sort-Object)) {
    $entry = $modMap[$modid]
    $zhPath = Join-Path $PackAssetsRoot ("{0}\lang\zh_tw.json" -f $modid)
    $zhSet = New-OrdinalHashSet
    $zhCount = 0
    if (Test-Path $zhPath) {
        try {
            $zhText = Get-Content -Path $zhPath -Raw -Encoding UTF8
            $zhSet = Get-JsonKeysFromString -JsonText $zhText -SourcePath $zhPath
            $zhCount = $zhSet.Count
        } catch {
            $errorList.Add([pscustomobject]@{
                jar    = (Split-Path $entry.sourceJar -Leaf)
                reason = "Invalid zh_tw.json for ${modid}: $($_.Exception.Message)"
            })
        }
    }

    $translated = 0
    $missingKeys = $null
    if ($ReportMissing) {
        $missingKeys = New-Object System.Collections.Generic.List[string]
    }
    foreach ($key in $entry.enKeys) {
        if ($zhSet.Contains($key)) {
            $translated++
        } elseif ($ReportMissing) {
            $missingKeys.Add($key)
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

    if ($ReportMissing) {
        $sortedMissing = $missingKeys | Sort-Object
        $missingResults.Add([pscustomobject]@{
            modid       = $modid
            jar         = (Split-Path $entry.sourceJar -Leaf)
            en_us_keys  = $entry.total
            zh_tw_keys  = $zhCount
            missing     = $sortedMissing.Count
            missingKeys = $sortedMissing
        })
    }
}

$sortedRows = $rows | Sort-Object -Property @{ Expression = 'remaining'; Descending = $true }, modid

$overallTranslated = ($sortedRows | Measure-Object -Property translated -Sum).Sum
$overallTotal = ($sortedRows | Measure-Object -Property total -Sum).Sum
$overallRemaining = $overallTotal - $overallTranslated
if ($overallRemaining -lt 0) { $overallRemaining = 0 }
$overallPercent = if ($overallTotal -gt 0) { [math]::Round(($overallTranslated / $overallTotal) * 100, 1) } else { 0 }

Write-Output ("sb4-zh_tw overall progress: translated={0} / total={1}, remaining={2}, percent={3}%" -f $overallTranslated, $overallTotal, $overallRemaining, $overallPercent)
Write-Output ("JSON parse fallback used: {0} files" -f $parseErrors.Count)
if ($parseErrors.Count -gt 0) {
    $fallbackRows = $parseErrors | Select-Object -First 20
    foreach ($entry in $fallbackRows) {
        Write-Output ("- {0}: {1}" -f $entry.path, $entry.reason)
    }
}

$header = "{0,-30} {1,10} {2,10} {3,10} {4,8}" -f 'modid', 'translated', 'total', 'remaining', 'percent'
Write-Output $header
Write-Output ("{0,-30} {1,10} {2,10} {3,10} {4,8}" -f ('-' * 30), ('-' * 10), ('-' * 10), ('-' * 10), ('-' * 8))

$displayRows = $sortedRows
if ($ShowZeroOnly) {
    $displayRows = $displayRows | Where-Object { $_.total -gt 0 -and $_.translated -eq 0 }
}
$displayRows = $displayRows | Select-Object -First 30
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

if ($ReportMissing) {
    if (-not (Test-Path $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $missingCsvPath = Join-Path $OutDir 'zh_tw_missing_summary.csv'
    $missingJsonPath = Join-Path $OutDir 'zh_tw_missing_details.json'
    $missingMdPath = Join-Path $OutDir ("zh_tw_missing_top_{0}.md" -f $MissingTop)

    $sortedMissingResults = $missingResults | Sort-Object -Property missing -Descending

    $sortedMissingResults |
        Select-Object modid, jar, en_us_keys, zh_tw_keys, missing |
        Export-Csv -Path $missingCsvPath -NoTypeInformation -Encoding UTF8

    $jsonObj = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        pack        = $PackName
        mods        = $sortedMissingResults
    }
    $jsonText = $jsonObj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($missingJsonPath, $jsonText, (Get-Utf8NoBom))

    $topMods = if ($MissingTop -gt 0) { $sortedMissingResults | Select-Object -First $MissingTop } else { @() }
    $mdLines = New-Object System.Collections.Generic.List[string]
    $mdLines.Add("# Top $MissingTop missing zh_tw keys")
    $mdLines.Add("")

    foreach ($item in $topMods) {
        $mdLines.Add(("## {0} (missing {1})" -f $item.modid, $item.missing))
        $keysToShow = $item.missingKeys | Select-Object -First 50
        foreach ($k in $keysToShow) {
            $mdLines.Add(("- {0}" -f $k))
        }
        $mdLines.Add("")
    }

    [System.IO.File]::WriteAllText($missingMdPath, ($mdLines -join "`n"), (Get-Utf8NoBom))

    Write-Output "Missing zh_tw outputs:"
    Write-Output ("  CSV:  {0}" -f $missingCsvPath)
    Write-Output ("  JSON: {0}" -f $missingJsonPath)
    Write-Output ("  MD:   {0}" -f $missingMdPath)
}

if ($errorList.Count -gt 0) {
    Write-Output "Errors:"
    foreach ($err in $errorList) {
        Write-Output ("- {0}: {1}" -f $err.jar, $err.reason)
    }
}
