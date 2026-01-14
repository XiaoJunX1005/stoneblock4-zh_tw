[CmdletBinding()]
param(
    [Parameter()]
    [string]$ModsDir,

    [Parameter()]
    [string]$GameRoot,

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

function New-OrdinalKeySet {
    return New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
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
            $zhText = Get-Content -Path $file.FullName -Raw -Encoding UTF8
            $zhObj = $zhText | ConvertFrom-Json
        } catch {
            Write-Warning "Invalid zh_tw.json for mod '$sourceModId' at $($file.FullName); treating as 0 keys."
            continue
        }

        foreach ($prop in $zhObj.PSObject.Properties) {
            $key = [string]$prop.Name
            $owner = Get-InferredNamespace -Key $key -SourceModId $sourceModId
            if (-not $index.ContainsKey($owner)) {
                $index[$owner] = (New-OrdinalKeySet)
            }
            $null = $index[$owner].Add($key)
        }
    }

    return $index
}

if (-not $OutDir -or $OutDir.Trim() -eq '') {
    $OutDir = Join-Path $RepoRoot 'tools\out'
}

if (-not $ModsDir -or $ModsDir.Trim() -eq '') {
    if ($GameRoot -and $GameRoot.Trim() -ne '') {
        $ModsDir = Join-Path $GameRoot 'mods'
    }
}

if (-not $ModsDir -or $ModsDir.Trim() -eq '') {
    throw "ModsDir or GameRoot is required."
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
$ownerMap = New-Object 'System.Collections.Generic.Dictionary[string, object]' ([System.StringComparer]::OrdinalIgnoreCase)

$jars = Get-ChildItem -Path $ModsDir -Filter *.jar -File
foreach ($jar in $jars) {
    $zip = $null
    $foundEntry = $false
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match '^assets/([^/]+)/lang/en_us\.json$') {
                $sourceModId = $matches[1].ToLowerInvariant()
                $foundEntry = $true

                $enText = Read-ZipEntryText -Entry $entry
                try {
                    $enObj = $enText | ConvertFrom-Json
                } catch {
                    Write-Warning "Invalid en_us.json in $($jar.Name) for mod '$sourceModId'; skipping."
                    continue
                }

                foreach ($prop in $enObj.PSObject.Properties) {
                    $key = [string]$prop.Name
                    $owner = Get-InferredNamespace -Key $key -SourceModId $sourceModId
                    if (-not $ownerMap.ContainsKey($owner)) {
                        $ownerMap[$owner] = [pscustomobject]@{
                            modid     = $owner
                            enKeys    = (New-OrdinalKeySet)
                            jarCounts = @{}
                        }
                    }

                    $entryOwner = $ownerMap[$owner]
                    if ($entryOwner.enKeys.Add($key)) {
                        if (-not $entryOwner.jarCounts.ContainsKey($jar.Name)) {
                            $entryOwner.jarCounts[$jar.Name] = 0
                        }
                        $entryOwner.jarCounts[$jar.Name]++
                    }
                }
            }
        }
    } catch {
        Write-Warning "Failed to read jar: $($jar.FullName). $($_.Exception.Message)"
    } finally {
        if ($zip) { $zip.Dispose() }
    }
    if (-not $foundEntry) {
        Write-Warning "No en_us.json found in $($jar.Name); skipped."
    }
}

$zhIndex = Build-ZhTwIndex -AssetsRoot $assetsRoot

foreach ($owner in $ownerMap.Keys) {
    $entryOwner = $ownerMap[$owner]
    $enKeys = $entryOwner.enKeys
    $enKeyCount = $enKeys.Count

    $zhKeySet = if ($zhIndex.ContainsKey($owner)) { $zhIndex[$owner] } else { New-OrdinalKeySet }
    $missingKeys = New-Object System.Collections.Generic.List[string]
    foreach ($k in $enKeys) {
        if (-not $zhKeySet.Contains($k)) {
            $missingKeys.Add($k)
        }
    }

    $missingKeysSorted = $missingKeys | Sort-Object
    $missingCount = $missingKeysSorted.Count
    $jarName = ''
    if ($entryOwner.jarCounts.Count -gt 0) {
        $jarName = ($entryOwner.jarCounts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Name
    }

    $results.Add([pscustomobject]@{
        modid       = $owner
        jar         = $jarName
        en_us_keys  = $enKeyCount
        zh_tw_keys  = $zhKeySet.Count
        missing     = $missingCount
        missingKeys = $missingKeysSorted
    })
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
