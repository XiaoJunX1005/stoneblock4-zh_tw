[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModsDir,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter()]
    [string]$PackName = 'sb4-zh_tw',

    [Parameter()]
    [int]$Top = 20,

    [Parameter()]
    [string]$OutDir
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

if (-not $OutDir -or $OutDir.Trim() -eq '') {
    $OutDir = Join-Path $RepoRoot 'tools\out'
}

if (-not (Test-Path $ModsDir)) {
    throw "ModsDir not found: $ModsDir"
}

$assetsRoot = Join-Path $RepoRoot ("resourcepacks\{0}\assets" -f $PackName)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$csvPath = Join-Path $OutDir 'zh_tw_missing_summary.csv'
$jsonPath = Join-Path $OutDir 'zh_tw_missing_details.json'
$mdPath = Join-Path $OutDir ("zh_tw_missing_top_{0}.md" -f $Top)

Add-Type -AssemblyName System.IO.Compression.FileSystem

$results = New-Object System.Collections.Generic.List[object]
$seenModIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

$jars = Get-ChildItem -Path $ModsDir -Filter *.jar -File
foreach ($jar in $jars) {
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match '^assets/([^/]+)/lang/en_us\.json$') {
                $modid = $matches[1]
                if (-not $seenModIds.Add($modid)) {
                    Write-Warning "Duplicate modid '$modid' found in $($jar.Name); skipping."
                    continue
                }

                $enText = Read-ZipEntryText -Entry $entry
                try {
                    $enObj = $enText | ConvertFrom-Json
                } catch {
                    Write-Warning "Invalid en_us.json in $($jar.Name) for mod '$modid'; skipping."
                    continue
                }

                $enKeys = $enObj.PSObject.Properties.Name
                $enKeyCount = $enKeys.Count

                $zhPath = Join-Path $assetsRoot ("{0}\lang\zh_tw.json" -f $modid)
                $zhKeys = @()
                if (Test-Path $zhPath) {
                    try {
                        $zhText = Get-Content -Path $zhPath -Raw -Encoding UTF8
                        $zhObj = $zhText | ConvertFrom-Json
                        $zhKeys = $zhObj.PSObject.Properties.Name
                    } catch {
                        Write-Warning "Invalid zh_tw.json for mod '$modid' at $zhPath; treating as 0 keys."
                        $zhKeys = @()
                    }
                }

                $zhKeySet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($k in $zhKeys) { $null = $zhKeySet.Add($k) }

                $missingKeys = New-Object System.Collections.Generic.List[string]
                foreach ($k in $enKeys) {
                    if (-not $zhKeySet.Contains($k)) {
                        $missingKeys.Add($k)
                    }
                }

                $missingKeysSorted = $missingKeys | Sort-Object
                $missingCount = $missingKeysSorted.Count

                $results.Add([pscustomobject]@{
                    modid       = $modid
                    jar         = $jar.Name
                    en_us_keys  = $enKeyCount
                    zh_tw_keys  = $zhKeys.Count
                    missing     = $missingCount
                    missingKeys = $missingKeysSorted
                })
            }
        }
    } catch {
        Write-Warning "Failed to read jar: $($jar.FullName). $($_.Exception.Message)"
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

$sorted = $results | Sort-Object -Property missing -Descending

$sorted |
    Select-Object modid, jar, en_us_keys, zh_tw_keys, missing |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

$jsonObj = [ordered]@{
    generatedAt = (Get-Date).ToString('o')
    pack        = $PackName
    mods        = $sorted
}
$jsonText = $jsonObj | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($jsonPath, $jsonText, (Get-Utf8NoBom))

$topMods = if ($Top -gt 0) { $sorted | Select-Object -First $Top } else { @() }
$mdLines = New-Object System.Collections.Generic.List[string]
$mdLines.Add("# Top $Top missing zh_tw keys")
$mdLines.Add("")

foreach ($item in $topMods) {
    $mdLines.Add(("## {0} (missing {1})" -f $item.modid, $item.missing))
    $keysToShow = $item.missingKeys | Select-Object -First 50
    foreach ($k in $keysToShow) {
        $mdLines.Add(("- {0}" -f $k))
    }
    $mdLines.Add("")
}

[System.IO.File]::WriteAllText($mdPath, ($mdLines -join "`n"), (Get-Utf8NoBom))

Write-Host "Output:"
Write-Host ("  CSV:  {0}" -f $csvPath)
Write-Host ("  JSON: {0}" -f $jsonPath)
Write-Host ("  MD:   {0}" -f $mdPath)

Write-Host ""
Write-Host ("Top {0} summary:" -f $Top)
$topMods | Select-Object -Property modid, jar, en_us_keys, zh_tw_keys, missing | Format-Table -AutoSize
