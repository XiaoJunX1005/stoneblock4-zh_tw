[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$GameRoot,

    [Parameter()]
    [string]$PackName = 'sb4-zh_tw',

    [Parameter()]
    [string]$MissingTopMd,

    [Parameter()]
    [string]$TargetModId,

    [Parameter()]
    [int]$KeysPerMod = 50,

    [Parameter()]
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

function Get-Utf8NoBom {
    return New-Object System.Text.UTF8Encoding($false)
}

function New-CaseSensitiveHashtable {
    return New-Object System.Collections.Hashtable ([System.StringComparer]::Ordinal)
}

function New-CaseInsensitiveHashtable {
    return New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
}

function ConvertTo-HashtableFromJsonObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$JsonObject
    )
    $map = New-CaseSensitiveHashtable
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

function Read-JsonFileAsMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )
    try {
        $text = Get-Content -Path $Path -Raw -Encoding UTF8
    } catch {
        Write-Warning ("Failed to read {0}: {1}. {2}" -f $Context, $Path, $_.Exception.Message)
        return $null
    }

    try {
        $obj = $text | ConvertFrom-Json
    } catch {
        Write-Warning ("Invalid JSON for {0}: {1}. {2}" -f $Context, $Path, $_.Exception.Message)
        return $null
    }

    return ConvertTo-HashtableFromJsonObject -JsonObject $obj
}

function Normalize-KeyList {
    param(
        [Parameter()]
        [object]$RawKeys
    )
    if ($null -eq $RawKeys) {
        return @()
    }
    if ($RawKeys -is [string]) {
        return @($RawKeys)
    }
    if ($RawKeys -is [System.Collections.IDictionary]) {
        return if ($RawKeys.Count -gt 0) { @($RawKeys.Keys) } else { @() }
    }
    if ($RawKeys -is [System.Management.Automation.PSCustomObject]) {
        return if ($RawKeys.PSObject.Properties.Count -gt 0) { @($RawKeys.PSObject.Properties.Name) } else { @() }
    }
    if ($RawKeys -is [System.Collections.IEnumerable]) {
        return @($RawKeys)
    }
    return @($RawKeys)
}

function Get-MissingKeysFromMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MissingTopMd,
        [Parameter(Mandatory = $true)]
        [string]$TargetModId,
        [Parameter(Mandatory = $true)]
        [int]$KeysPerMod
    )
    if (-not (Test-Path $MissingTopMd)) {
        Write-Warning "MissingTopMd not found: $MissingTopMd"
        return @()
    }

    $lines = Get-Content -Path $MissingTopMd -Encoding UTF8
    $headerPattern = '^##\s+' + [regex]::Escape($TargetModId) + '\b'

    $startIndex = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $headerPattern) {
            $startIndex = $i + 1
            break
        }
    }

    if ($null -eq $startIndex) {
        Write-Warning "TargetModId '$TargetModId' not found in MissingTopMd."
        return @()
    }

    $keys = New-Object System.Collections.Generic.List[string]
    for ($j = $startIndex; $j -lt $lines.Count; $j++) {
        $line = $lines[$j]
        if ($line -match '^##\s+') {
            break
        }
        if ($line -match '^\s*-\s+(.+)$') {
            $key = $matches[1].Trim()
            if ($key -ne '') {
                $keys.Add($key)
            }
        }
    }

    if ($KeysPerMod -le 0) {
        return @()
    }
    return $keys | Select-Object -First $KeysPerMod
}

function New-BundleObject {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [Parameter(Mandatory = $true)]
        [string]$GeneratedAt
    )
    return [ordered]@{
        meta  = [ordered]@{
            sourcePriority = @('zh_cn', 'en_us')
            target         = 'zh_tw'
            generatedAt    = $GeneratedAt
        }
        items = $Items
    }
}

function New-SubsetEntries {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entries,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$EntrySource,
        [Parameter(Mandatory = $true)]
        [object[]]$Keys
    )
    $subEntries = [ordered]@{}
    $subEntrySource = [ordered]@{}
    foreach ($key in $Keys) {
        $subEntries[$key] = $Entries[$key]
        $subEntrySource[$key] = $EntrySource[$key]
    }
    return [pscustomobject]@{
        entries     = $subEntries
        entrySource = $subEntrySource
    }
}

function Get-JsonPayload {
    param(
        [Parameter(Mandatory = $true)]
        [object]$BundleObject,
        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding
    )
    $json = $BundleObject | ConvertTo-Json -Depth 100
    $bytes = $Encoding.GetByteCount($json)
    return [pscustomobject]@{
        Json  = $json
        Bytes = $bytes
    }
}

function Render-PromptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplateText,
        [Parameter(Mandatory = $true)]
        [string]$BundleJson,
        [Parameter()]
        [string]$MissingTopText
    )
    $promptText = $TemplateText
    $hadBundlePlaceholder = $promptText.Contains('{{BUNDLE_JSON}}')
    $hadMissingPlaceholder = $promptText.Contains('{{MISSING_TOP_MD}}') -or $promptText.Contains('{{MISSING_TOP}}')

    $promptText = $promptText.Replace('{{BUNDLE_JSON}}', $BundleJson)
    $promptText = $promptText.Replace('{{MISSING_TOP_MD}}', $MissingTopText)
    $promptText = $promptText.Replace('{{MISSING_TOP}}', $MissingTopText)

    if (-not $hadBundlePlaceholder) {
        $promptText = ($promptText.TrimEnd() + "`n`n" + $BundleJson + "`n")
    }
    if (-not $hadMissingPlaceholder -and $MissingTopText) {
        $promptText = ($promptText.TrimEnd() + "`n`n" + $MissingTopText + "`n")
    }
    return $promptText
}

function Load-KubejsLangMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$Lang,
        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$TargetModIds
    )

    $map = New-CaseInsensitiveHashtable
    $assetsRoot = Join-Path $RepoRoot 'kubejs\assets'
    if (-not (Test-Path $assetsRoot)) {
        return $map
    }

    $regex = [regex]("assets[\\/]+([^\\/]+)[\\/]+lang[\\/]+" + [regex]::Escape($Lang) + "\.json$")
    $files = Get-ChildItem -Path $assetsRoot -Recurse -Filter ($Lang + '.json') -File
    foreach ($file in $files) {
        if (-not ($file.FullName -match $regex)) {
            continue
        }
        $modid = $matches[1]
        if ($TargetModIds -and (-not $TargetModIds.Contains($modid))) {
            continue
        }
        if ($map.ContainsKey($modid)) {
            Write-Warning "Duplicate kubejs $Lang for modid '$modid' at $($file.FullName); skipping."
            continue
        }
        $jsonMap = Read-JsonFileAsMap -Path $file.FullName -Context ("kubejs {0} {1}" -f $modid, $Lang)
        if ($null -eq $jsonMap) {
            continue
        }
        $map[$modid] = $jsonMap
    }
    return $map
}

function Get-MissingKeysFromDetails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutDir,
        [Parameter(Mandatory = $true)]
        [string]$TargetModId
    )
    $detailsPath = Join-Path $OutDir 'zh_tw_missing_details.json'
    if (-not (Test-Path $detailsPath)) {
        return @()
    }

    try {
        $text = Get-Content -Path $detailsPath -Raw -Encoding UTF8
        $obj = $text | ConvertFrom-Json
    } catch {
        Write-Warning ("Invalid JSON in missing details: {0}. {1}" -f $detailsPath, $_.Exception.Message)
        return @()
    }

    if (-not $obj.PSObject.Properties.Match('mods')) {
        return @()
    }

    foreach ($mod in $obj.mods) {
        if ($mod.modid -and ([string]$mod.modid).Equals($TargetModId, [System.StringComparison]::OrdinalIgnoreCase)) {
            if ($mod.PSObject.Properties.Match('missingKeys')) {
                return Normalize-KeyList -RawKeys $mod.missingKeys
            }
            return @()
        }
    }

    return @()
}

function Load-ResourcepackZhTwMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$PackName,
        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$TargetModIds
    )

    $map = New-CaseInsensitiveHashtable
    $assetsRoot = Join-Path $RepoRoot ("resourcepacks\{0}\assets" -f $PackName)
    if (-not (Test-Path $assetsRoot)) {
        return $map
    }

    foreach ($modid in $TargetModIds) {
        $path = Join-Path $assetsRoot ("{0}\lang\zh_tw.json" -f $modid)
        if (-not (Test-Path $path)) {
            continue
        }
        if ($map.ContainsKey($modid)) {
            continue
        }
        $jsonMap = Read-JsonFileAsMap -Path $path -Context ("resourcepack zh_tw {0}" -f $modid)
        if ($null -eq $jsonMap) {
            continue
        }
        $map[$modid] = $jsonMap
    }

    return $map
}

function Get-BundleKeys {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath,
        [Parameter(Mandatory = $true)]
        [string]$ModId
    )
    if (-not (Test-Path $BundlePath)) {
        return @()
    }

    try {
        $text = Get-Content -Path $BundlePath -Raw -Encoding UTF8
        $obj = $text | ConvertFrom-Json
    } catch {
        Write-Warning ("Invalid bundle JSON: {0}. {1}" -f $BundlePath, $_.Exception.Message)
        return @()
    }

    if (-not $obj.PSObject.Properties.Match('items')) {
        return @()
    }

    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($item in $obj.items) {
        if ($item.modid -ne $ModId) {
            continue
        }
        if ($item.entries) {
            foreach ($prop in $item.entries.PSObject.Properties) {
                $keys.Add($prop.Name)
            }
        }
    }

    return $keys
}

function New-OrdinalKeySet {
    $set = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    return $set
}

function Add-KeysToSet {
    param(
        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$Set,
        [Parameter()]
        [object[]]$Keys
    )
    if ($null -eq $Set) {
        return
    }
    foreach ($key in (Normalize-KeyList -RawKeys $Keys)) {
        $null = $Set.Add([string]$key)
    }
}

function Filter-KeysBySet {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Keys,
        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$Exclude
    )
    if ($null -eq $Exclude) {
        return $Keys
    }
    $filtered = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Keys) {
        if (-not $Exclude.Contains([string]$key)) {
            $filtered.Add([string]$key)
        }
    }
    return $filtered
}

function Load-JarLangMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModsDir,
        [Parameter(Mandatory = $true)]
        [string]$Lang,
        [Parameter()]
        [System.Collections.Generic.HashSet[string]]$TargetModIds
    )

    $map = New-CaseInsensitiveHashtable
    $jars = Get-ChildItem -Path $ModsDir -Filter *.jar -File
    foreach ($jar in $jars) {
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -notmatch ("^assets/([^/]+)/lang/" + [regex]::Escape($Lang) + "\.json$")) {
                    continue
                }
                $modid = $matches[1]
                if ($TargetModIds -and (-not $TargetModIds.Contains($modid))) {
                    continue
                }
                if ($map.ContainsKey($modid)) {
                    Write-Warning "Duplicate modid '$modid' for $Lang found in $($jar.Name); skipping."
                    continue
                }
                $content = Read-ZipEntryText -Entry $entry
                try {
                    $obj = $content | ConvertFrom-Json
                } catch {
                    Write-Warning "Invalid $Lang JSON in $($jar.Name) for mod '$modid'; skipping."
                    continue
                }
                $map[$modid] = ConvertTo-HashtableFromJsonObject -JsonObject $obj
            }
        } catch {
            Write-Warning "Failed to read jar: $($jar.FullName). $($_.Exception.Message)"
        } finally {
            if ($zip) { $zip.Dispose() }
        }
    }
    return $map
}

function Build-ModEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,
        [Parameter()]
        [object[]]$MissingKeys,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$KubejsZhCn,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$JarZhCn,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$KubejsEnUs,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$JarEnUs
    )

    if ($null -eq $MissingKeys) {
        $MissingKeys = @()
    }

    $entries = [ordered]@{}
    $entrySource = [ordered]@{}
    $orderedKeys = New-Object System.Collections.Generic.List[string]
    $hitZhCn = 0
    $hitEnUs = 0
    $skipped = 0
    $totalRequested = $MissingKeys.Count

    foreach ($key in $MissingKeys) {
        $value = $null
        $source = $null

        if ($KubejsZhCn.ContainsKey($ModId) -and $KubejsZhCn[$ModId].ContainsKey($key)) {
            $value = $KubejsZhCn[$ModId][$key]
            $source = 'zh_cn'
        } elseif ($JarZhCn.ContainsKey($ModId) -and $JarZhCn[$ModId].ContainsKey($key)) {
            $value = $JarZhCn[$ModId][$key]
            $source = 'zh_cn'
        } elseif ($KubejsEnUs.ContainsKey($ModId) -and $KubejsEnUs[$ModId].ContainsKey($key)) {
            $value = $KubejsEnUs[$ModId][$key]
            $source = 'en_us'
        } elseif ($JarEnUs.ContainsKey($ModId) -and $JarEnUs[$ModId].ContainsKey($key)) {
            $value = $JarEnUs[$ModId][$key]
            $source = 'en_us'
        }

        if ($null -ne $source) {
            $entries[$key] = $value
            $entrySource[$key] = $source
            $orderedKeys.Add($key)
            if ($source -eq 'zh_cn') { $hitZhCn++ } else { $hitEnUs++ }
        } else {
            $skipped++
        }
    }

    return [pscustomobject]@{
        entries     = $entries
        entrySource = $entrySource
        orderedKeys = $orderedKeys
        stats       = [pscustomobject]@{
            modid          = $ModId
            hitZhCn        = $hitZhCn
            hitEnUs        = $hitEnUs
            skipped        = $skipped
            totalRequested = $totalRequested
        }
    }
}

function Split-KeysBySize {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entries,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$EntrySource,
        [Parameter(Mandatory = $true)]
        [object[]]$Keys,
        [Parameter(Mandatory = $true)]
        [int]$MaxBytes,
        [Parameter(Mandatory = $true)]
        [string]$GeneratedAt,
        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding
    )

    $chunks = New-Object System.Collections.Generic.List[object]
    $currentKeys = New-Object System.Collections.Generic.List[string]

    foreach ($key in $Keys) {
        $currentKeys.Add($key)
        $subset = New-SubsetEntries -Entries $Entries -EntrySource $EntrySource -Keys $currentKeys
        $bundleObj = New-BundleObject -Items @([ordered]@{
            modid       = $ModId
            entries     = $subset.entries
            entrySource = $subset.entrySource
        }) -GeneratedAt $GeneratedAt
        $payload = Get-JsonPayload -BundleObject $bundleObj -Encoding $Encoding

        if ($payload.Bytes -gt $MaxBytes -and $currentKeys.Count -gt 1) {
            $lastKey = $currentKeys[$currentKeys.Count - 1]
            $currentKeys.RemoveAt($currentKeys.Count - 1)

            $subset = New-SubsetEntries -Entries $Entries -EntrySource $EntrySource -Keys $currentKeys
            $bundleObj = New-BundleObject -Items @([ordered]@{
                modid       = $ModId
                entries     = $subset.entries
                entrySource = $subset.entrySource
            }) -GeneratedAt $GeneratedAt
            $payload = Get-JsonPayload -BundleObject $bundleObj -Encoding $Encoding

            $chunks.Add([pscustomobject]@{
                keys       = @($currentKeys)
                entries    = $currentKeys.Count
                payload    = $payload
            })

            $currentKeys = New-Object System.Collections.Generic.List[string]
            $currentKeys.Add($lastKey)
        }
    }

    if ($currentKeys.Count -gt 0) {
        $subset = New-SubsetEntries -Entries $Entries -EntrySource $EntrySource -Keys $currentKeys
        $bundleObj = New-BundleObject -Items @([ordered]@{
            modid       = $ModId
            entries     = $subset.entries
            entrySource = $subset.entrySource
        }) -GeneratedAt $GeneratedAt
        $payload = Get-JsonPayload -BundleObject $bundleObj -Encoding $Encoding

        $chunks.Add([pscustomobject]@{
            keys       = @($currentKeys)
            entries    = $currentKeys.Count
            payload    = $payload
        })
    }

    return $chunks
}

function Build-Chunks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entries,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$EntrySource,
        [Parameter(Mandatory = $true)]
        [object[]]$OrderedKeys,
        [Parameter(Mandatory = $true)]
        [int]$MaxEntries,
        [Parameter(Mandatory = $true)]
        [int]$MaxBytes,
        [Parameter(Mandatory = $true)]
        [string]$GeneratedAt,
        [Parameter(Mandatory = $true)]
        [System.Text.Encoding]$Encoding
    )

    $chunks = New-Object System.Collections.Generic.List[object]
    $total = $OrderedKeys.Count
    if ($total -le 0) {
        return $chunks
    }

    $segments = New-Object System.Collections.Generic.List[object]
    if ($total -le $MaxEntries) {
        $segments.Add(@($OrderedKeys))
    } else {
        for ($i = 0; $i -lt $total; $i += $MaxEntries) {
            $end = [Math]::Min($i + $MaxEntries - 1, $total - 1)
            $segments.Add(@($OrderedKeys[$i..$end]))
        }
    }

    foreach ($segment in $segments) {
        $subset = New-SubsetEntries -Entries $Entries -EntrySource $EntrySource -Keys $segment
        $bundleObj = New-BundleObject -Items @([ordered]@{
            modid       = $ModId
            entries     = $subset.entries
            entrySource = $subset.entrySource
        }) -GeneratedAt $GeneratedAt
        $payload = Get-JsonPayload -BundleObject $bundleObj -Encoding $Encoding

        if ($payload.Bytes -le $MaxBytes -or $segment.Count -le 1) {
            $chunks.Add([pscustomobject]@{
                keys       = $segment
                entries    = $segment.Count
                payload    = $payload
            })
        } else {
            $splitChunks = Split-KeysBySize -ModId $ModId -Entries $Entries -EntrySource $EntrySource -Keys $segment -MaxBytes $MaxBytes -GeneratedAt $GeneratedAt -Encoding $Encoding
            foreach ($chunk in $splitChunks) {
                $chunks.Add($chunk)
            }
        }
    }

    return $chunks
}

if (-not $OutDir -or $OutDir.Trim() -eq '') {
    $OutDir = Join-Path $RepoRoot 'tools\out'
}
if (-not $MissingTopMd -or $MissingTopMd.Trim() -eq '') {
    $MissingTopMd = Join-Path $OutDir 'zh_tw_missing_top_20.md'
}

$modsDir = Join-Path $GameRoot 'mods'
if (-not (Test-Path $modsDir)) {
    throw "ModsDir not found: $modsDir"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$utf8NoBom = Get-Utf8NoBom
$maxEntriesPerChunk = 2000
$maxBytesPerChunk = [int](1.5 * 1024 * 1024)
$generatedAt = (Get-Date).ToString('o')

Add-Type -AssemblyName System.IO.Compression.FileSystem

$templatePath = Join-Path $RepoRoot 'tools\gemini_prompt_template.txt'
$defaultTemplate = @'
你是專業的繁體中文翻譯助手。請將以下 JSON 中 entries 的值翻譯為 zh_tw。
規則：
1) 只輸出 JSON，不要附加任何說明。
2) JSON 結構必須完全一致，key 不可變。
3) 不可更改格式碼/占位符（例如 %s、%d、{0}、{1}、\n、%%）。
4) 保留大小寫、空白、標點與順序。

以下是需要翻譯的 JSON：
{{BUNDLE_JSON}}

參考：缺少 zh_tw 的 top 清單（可忽略）
{{MISSING_TOP_MD}}
'@

$templateText = $null
if (Test-Path $templatePath) {
    $templateText = Get-Content -Path $templatePath -Raw -Encoding UTF8
} else {
    Write-Host "使用內建模板"
    $templateText = $defaultTemplate
}

$missingTopText = ''
if (Test-Path $MissingTopMd) {
    $missingTopText = Get-Content -Path $MissingTopMd -Raw -Encoding UTF8
} else {
    Write-Warning "MissingTopMd not found: $MissingTopMd"
}

if ($TargetModId -and $TargetModId.Trim() -ne '') {
    $targetId = $TargetModId.Trim()
    $targetModIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    $null = $targetModIds.Add($targetId)

    $resourceZhTw = Load-ResourcepackZhTwMap -RepoRoot $RepoRoot -PackName $PackName -TargetModIds $targetModIds
    $kubejsZhTw = Load-KubejsLangMap -RepoRoot $RepoRoot -Lang 'zh_tw' -TargetModIds $targetModIds
    $kubejsZhCn = Load-KubejsLangMap -RepoRoot $RepoRoot -Lang 'zh_cn' -TargetModIds $targetModIds
    $kubejsEnUs = Load-KubejsLangMap -RepoRoot $RepoRoot -Lang 'en_us' -TargetModIds $targetModIds
    $jarZhCn = Load-JarLangMap -ModsDir $modsDir -Lang 'zh_cn' -TargetModIds $targetModIds
    $jarEnUs = Load-JarLangMap -ModsDir $modsDir -Lang 'en_us' -TargetModIds $targetModIds

    $missingKeys = Get-MissingKeysFromMarkdown -MissingTopMd $MissingTopMd -TargetModId $targetId -KeysPerMod $KeysPerMod
    $missingKeys = Normalize-KeyList -RawKeys $missingKeys
    $detailsKeys = Get-MissingKeysFromDetails -OutDir $OutDir -TargetModId $targetId
    if ($detailsKeys.Count -gt $missingKeys.Count) {
        $missingKeys = $detailsKeys
    }
    if ($null -eq $missingKeys) {
        $missingKeys = @()
    }
    $translatedKeySet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    if ($resourceZhTw.ContainsKey($targetId)) { Add-KeysToSet -Set $translatedKeySet -Keys $resourceZhTw[$targetId].Keys }
    if ($kubejsZhTw.ContainsKey($targetId)) { Add-KeysToSet -Set $translatedKeySet -Keys $kubejsZhTw[$targetId].Keys }
    $existingBundlePath = Join-Path $OutDir ("{0}\bundle_to_translate.json" -f $targetId)
    Add-KeysToSet -Set $translatedKeySet -Keys (Get-BundleKeys -BundlePath $existingBundlePath -ModId $targetId)
    $missingKeys = Filter-KeysBySet -Keys $missingKeys -Exclude $translatedKeySet
    if ($null -eq $missingKeys) {
        $missingKeys = @()
    }
    if ($KeysPerMod -gt 0) {
        $missingKeys = $missingKeys | Select-Object -First $KeysPerMod
    } else {
        $missingKeys = @()
    }

    $build = Build-ModEntries -ModId $targetId -MissingKeys $missingKeys -KubejsZhCn $kubejsZhCn -JarZhCn $jarZhCn -KubejsEnUs $kubejsEnUs -JarEnUs $jarEnUs

    $stats = @($build.stats)
    Write-Host ("{0}: zh_cn={1}, en_us={2}, skipped={3}, total={4}" -f $build.stats.modid, $build.stats.hitZhCn, $build.stats.hitEnUs, $build.stats.skipped, $build.stats.totalRequested)

    $modOutDir = Join-Path $OutDir $targetId
    New-Item -ItemType Directory -Path $modOutDir -Force | Out-Null

    $statsPath = Join-Path $modOutDir 'bundle_source_stats.json'
    $statsJson = $stats | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($statsPath, $statsJson, $utf8NoBom)

    $bundleItems = @([ordered]@{
        modid       = $targetId
        entries     = $build.entries
        entrySource = $build.entrySource
    })
    $bundleObj = New-BundleObject -Items $bundleItems -GeneratedAt $generatedAt
    $payload = Get-JsonPayload -BundleObject $bundleObj -Encoding $utf8NoBom

    $shouldChunk = ($build.orderedKeys.Count -gt $maxEntriesPerChunk) -or ($payload.Bytes -gt $maxBytesPerChunk)
    if (-not $shouldChunk) {
        $bundlePath = Join-Path $modOutDir 'bundle_to_translate.json'
        [System.IO.File]::WriteAllText($bundlePath, $payload.Json, $utf8NoBom)

        $promptText = Render-PromptText -TemplateText $templateText -BundleJson $payload.Json -MissingTopText $missingTopText
        $promptPath = Join-Path $modOutDir 'gemini_prompt.txt'
        [System.IO.File]::WriteAllText($promptPath, $promptText, $utf8NoBom)

        Write-Host "Output:"
        Write-Host ("  dir:    {0}" -f $modOutDir)
        Write-Host ("  bundle: {0}" -f $bundlePath)
        Write-Host ("  prompt: {0}" -f $promptPath)
        Write-Host ("  stats:  {0}" -f $statsPath)
    } else {
        $chunks = Build-Chunks -ModId $targetId -Entries $build.entries -EntrySource $build.entrySource -OrderedKeys $build.orderedKeys -MaxEntries $maxEntriesPerChunk -MaxBytes $maxBytesPerChunk -GeneratedAt $generatedAt -Encoding $utf8NoBom
        $indexChunks = New-Object System.Collections.Generic.List[object]

        $chunkIndex = 1
        foreach ($chunk in $chunks) {
            $chunkDirName = ("chunk_{0:D3}" -f $chunkIndex)
            $chunkDir = Join-Path $modOutDir $chunkDirName
            New-Item -ItemType Directory -Path $chunkDir -Force | Out-Null

            $chunkBundlePath = Join-Path $chunkDir 'bundle_to_translate.json'
            [System.IO.File]::WriteAllText($chunkBundlePath, $chunk.payload.Json, $utf8NoBom)

            $chunkPromptText = Render-PromptText -TemplateText $templateText -BundleJson $chunk.payload.Json -MissingTopText $missingTopText
            $chunkPromptPath = Join-Path $chunkDir 'gemini_prompt.txt'
            [System.IO.File]::WriteAllText($chunkPromptPath, $chunkPromptText, $utf8NoBom)

            $indexChunks.Add([pscustomobject]@{
                chunk      = $chunkDirName
                entries    = $chunk.entries
                bundlePath = (Join-Path $chunkDirName 'bundle_to_translate.json')
                promptPath = (Join-Path $chunkDirName 'gemini_prompt.txt')
            })

            if ($chunk.payload.Bytes -gt $maxBytesPerChunk -and $chunk.entries -eq 1) {
                Write-Warning ("Chunk {0} exceeds size limit with a single entry ({1} bytes)." -f $chunkDirName, $chunk.payload.Bytes)
            }

            $chunkIndex++
        }

        $indexObj = [ordered]@{
            modid        = $targetId
            generatedAt  = $generatedAt
            totalEntries = $build.orderedKeys.Count
            chunkCount   = $indexChunks.Count
            chunks       = $indexChunks
        }
        $indexPath = Join-Path $modOutDir 'index.json'
        $indexJson = $indexObj | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($indexPath, $indexJson, $utf8NoBom)

        Write-Host "Output:"
        Write-Host ("  dir:   {0}" -f $modOutDir)
        Write-Host ("  stats: {0}" -f $statsPath)
        Write-Host ("  index: {0}" -f $indexPath)
    }

    return
}

$missingDetailsPath = Join-Path $OutDir 'zh_tw_missing_details.json'
if (-not (Test-Path $missingDetailsPath)) {
    throw "Missing details not found: $missingDetailsPath"
}

$missingText = Get-Content -Path $missingDetailsPath -Raw -Encoding UTF8
try {
    $missingObj = $missingText | ConvertFrom-Json
} catch {
    throw "Invalid JSON in missing details: $missingDetailsPath"
}

if (-not $missingObj.PSObject.Properties.Match('mods')) {
    throw "Missing details JSON missing 'mods' field: $missingDetailsPath"
}

$modsList = $missingObj.mods
if (-not $modsList) {
    throw "Missing details JSON 'mods' is empty: $missingDetailsPath"
}

$targetModIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($m in $modsList) {
    if ($m.modid) {
        $null = $targetModIds.Add([string]$m.modid)
    }
}

$resourceZhTw = Load-ResourcepackZhTwMap -RepoRoot $RepoRoot -PackName $PackName -TargetModIds $targetModIds
$kubejsZhTw = Load-KubejsLangMap -RepoRoot $RepoRoot -Lang 'zh_tw' -TargetModIds $targetModIds
$kubejsZhCn = Load-KubejsLangMap -RepoRoot $RepoRoot -Lang 'zh_cn' -TargetModIds $targetModIds
$kubejsEnUs = Load-KubejsLangMap -RepoRoot $RepoRoot -Lang 'en_us' -TargetModIds $targetModIds
$jarZhCn = Load-JarLangMap -ModsDir $modsDir -Lang 'zh_cn' -TargetModIds $targetModIds
$jarEnUs = Load-JarLangMap -ModsDir $modsDir -Lang 'en_us' -TargetModIds $targetModIds

$bundleItems = New-Object System.Collections.Generic.List[object]
$stats = New-Object System.Collections.Generic.List[object]

foreach ($mod in $modsList) {
    $modid = [string]$mod.modid
    if (-not $modid) { continue }

    $missingKeys = @()
    if ($mod.PSObject.Properties.Match('missingKeys')) {
        $missingKeys = Normalize-KeyList -RawKeys $mod.missingKeys
    }

    $translatedKeySet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::Ordinal)
    if ($resourceZhTw.ContainsKey($modid)) { Add-KeysToSet -Set $translatedKeySet -Keys $resourceZhTw[$modid].Keys }
    if ($kubejsZhTw.ContainsKey($modid)) { Add-KeysToSet -Set $translatedKeySet -Keys $kubejsZhTw[$modid].Keys }
    $existingBundlePath = Join-Path $OutDir ("{0}\bundle_to_translate.json" -f $modid)
    Add-KeysToSet -Set $translatedKeySet -Keys (Get-BundleKeys -BundlePath $existingBundlePath -ModId $modid)
    $missingKeys = Filter-KeysBySet -Keys $missingKeys -Exclude $translatedKeySet

    $build = Build-ModEntries -ModId $modid -MissingKeys $missingKeys -KubejsZhCn $kubejsZhCn -JarZhCn $jarZhCn -KubejsEnUs $kubejsEnUs -JarEnUs $jarEnUs

    $bundleItems.Add([ordered]@{
        modid       = $modid
        entries     = $build.entries
        entrySource = $build.entrySource
    })
    $stats.Add($build.stats)

    Write-Host ("{0}: zh_cn={1}, en_us={2}, skipped={3}, total={4}" -f $build.stats.modid, $build.stats.hitZhCn, $build.stats.hitEnUs, $build.stats.skipped, $build.stats.totalRequested)
}

$bundleObj = New-BundleObject -Items $bundleItems -GeneratedAt $generatedAt
$payload = Get-JsonPayload -BundleObject $bundleObj -Encoding $utf8NoBom

$bundlePath = Join-Path $OutDir 'gemini_bundle.json'
[System.IO.File]::WriteAllText($bundlePath, $payload.Json, $utf8NoBom)

$statsPath = Join-Path $OutDir 'bundle_source_stats.json'
$statsJson = $stats | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($statsPath, $statsJson, $utf8NoBom)

$promptText = Render-PromptText -TemplateText $templateText -BundleJson $payload.Json -MissingTopText $missingTopText
$promptPath = Join-Path $OutDir 'gemini_prompt.txt'
[System.IO.File]::WriteAllText($promptPath, $promptText, $utf8NoBom)

Write-Host "Output:"
Write-Host ("  bundle:  {0}" -f $bundlePath)
Write-Host ("  stats:   {0}" -f $statsPath)
Write-Host ("  prompt:  {0}" -f $promptPath)

