[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepoRoot = 'D:\stoneblock4-zh_tw',

    [Parameter()]
    [string]$GameRoot = 'C:\Users\USER\AppData\Roaming\PrismLauncher\instances\FTB StoneBlock 4\minecraft',

    [Parameter()]
    [string]$OutDir = 'D:\stoneblock4-zh_tw\tools\out',

    [Parameter()]
    [string]$ReportsDir = 'D:\stoneblock4-zh_tw\tools\reports',

    [Parameter()]
    [string]$TargetModId = 'chisel',

    [Parameter()]
    [int]$KeysPerMod = 200
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

function Get-EnUsKeyCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JarPath,
        [Parameter(Mandatory = $true)]
        [string]$ModId
    )
    if (-not (Test-Path $JarPath)) {
        return 0
    }

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
        $entry = $zip.GetEntry(("assets/{0}/lang/en_us.json" -f $ModId))
        if (-not $entry) {
            return 0
        }
        $text = Read-ZipEntryText -Entry $entry
        $obj = $text | ConvertFrom-Json
        if ($obj -is [System.Collections.IDictionary]) {
            return $obj.Count
        }
        return @($obj.PSObject.Properties.Name).Count
    } catch {
        return 0
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

$modsDir = Join-Path $GameRoot 'mods'
if (-not (Test-Path $modsDir)) {
    throw "ModsDir not found: $modsDir"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem

$modsLangCsv = Join-Path $ReportsDir 'mods-lang-support.csv'

$pythonScript = @'
import os,glob,json,zipfile,csv,sys,re
mods_dir=sys.argv[1]
repo_root=sys.argv[2]
out_csv=sys.argv[3]

def repo_has_zh_tw(modid):
  p=os.path.join(repo_root,'resourcepacks','sb4-zh_tw','assets',modid,'lang','zh_tw.json')
  if not os.path.exists(p): return False
  try:
    d=json.load(open(p,'r',encoding='utf-8'))
    return isinstance(d,dict) and len(d)>0
  except Exception:
    return False

def jar_langs(jar_path, modid):
  has_en=False; has_cn=False; has_tw=False
  prefix=f'assets/{modid}/lang/'
  try:
    with zipfile.ZipFile(jar_path,'r') as z:
      for e in z.namelist():
        if not e.startswith(prefix): 
          continue
        name=e[len(prefix):]
        if name=='en_us.json': has_en=True
        elif name=='zh_cn.json': has_cn=True
        elif name=='zh_tw.json': has_tw=True
  except Exception:
    pass
  return has_en, has_cn, has_tw

rows=[]
for jar in glob.glob(os.path.join(mods_dir,'*.jar')):
  try:
    with zipfile.ZipFile(jar,'r') as z:
      for e in z.namelist():
        m=re.match(r'^assets/([^/]+)/lang/en_us\.json$', e)
        if not m: 
          continue
        modid=m.group(1)
        has_en, has_cn, has_tw = jar_langs(jar, modid)
        repo_tw = repo_has_zh_tw(modid)
        if repo_tw:
          status='OK'
        else:
          status='CN_only' if has_cn else 'EN_only'
        rows.append({
          'modid': modid,
          'jar': os.path.basename(jar),
          'has_en_us': 'Y' if has_en else 'N',
          'has_zh_cn': 'Y' if has_cn else 'N',
          'has_zh_tw_in_jar': 'Y' if has_tw else 'N',
          'has_zh_tw_in_repo': 'Y' if repo_tw else 'N',
          'status': status
        })
  except Exception:
    continue

rank={'OK':2,'CN_only':1,'EN_only':0}
best={}
for r in rows:
  k=r['modid']
  if k not in best or rank[r['status']] > rank[best[k]['status']]:
    best[k]=r

final=list(best.values())
final.sort(key=lambda x:(x['status'], x['modid']))

os.makedirs(os.path.dirname(out_csv), exist_ok=True)
with open(out_csv,'w',newline='',encoding='utf-8') as f:
  w=csv.DictWriter(f, fieldnames=list(final[0].keys()) if final else ['modid','jar','status'])
  w.writeheader()
  for r in final:
    w.writerow(r)

from collections import Counter
cnt=Counter(r['status'] for r in final)
total=len(final)
print('OUT:', out_csv)
print('Total mods scanned:', total)
print('OK (repo zh_tw exists):', cnt.get('OK',0))
print('CN_only (has zh_cn, no zh_tw):', cnt.get('CN_only',0))
print('EN_only (no zh_cn, no zh_tw):', cnt.get('EN_only',0))
print('Remaining (not OK):', total - cnt.get('OK',0))
'@

& python -c $pythonScript $modsDir $RepoRoot $modsLangCsv

$rows = Import-Csv -Path $modsLangCsv
$enOnly = $rows | Where-Object { $_.status -eq 'EN_only' }

$candidates = foreach ($row in $enOnly) {
    $jarPath = Join-Path $modsDir $row.jar
    $keyCount = Get-EnUsKeyCount -JarPath $jarPath -ModId $row.modid
    [pscustomobject]@{
        ModId    = $row.modid
        KeyCount = $keyCount
        Jar      = $row.jar
    }
}

$candidates = $candidates | Sort-Object -Property @{ Expression = 'KeyCount'; Descending = $true }, @{ Expression = 'ModId'; Descending = $false }

$mdPath = Join-Path $ReportsDir 'next_mod_candidates.md'
$mdLines = New-Object System.Collections.Generic.List[string]
$mdLines.Add('# Next EN_only translation candidates (by en_us key count)')
$mdLines.Add('| Rank | ModId | KeyCount | Jar |')
$mdLines.Add('|---:|---|---:|---|')

$rank = 1
foreach ($c in $candidates) {
    $mdLines.Add(('| {0} | {1} | {2} | {3} |' -f $rank, $c.ModId, $c.KeyCount, $c.Jar))
    $rank++
}

$mdLines.Add('')
$mdLines.Add('Recommendation')
$mdLines.Add('- 建議先翻第 1 名（key 多、最有效率）')
$mdLines.Add('- 若想先補洞，CN_only 模組建議先處理 dimdungeons（若仍存在）')

[System.IO.File]::WriteAllText($mdPath, ($mdLines -join "`n"), (Get-Utf8NoBom))

$countMap = @{}
foreach ($row in $rows) {
    $status = $row.status
    if (-not $countMap.ContainsKey($status)) {
        $countMap[$status] = 0
    }
    $countMap[$status]++
}

$total = $rows.Count
$ok = $countMap['OK']
$cnOnly = $countMap['CN_only']
$enOnlyCount = $countMap['EN_only']
$remaining = $total - $ok

Write-Host ('Total: {0}' -f $total)
Write-Host ('OK: {0}' -f $ok)
Write-Host ('CN_only: {0}' -f $cnOnly)
Write-Host ('EN_only: {0}' -f $enOnlyCount)
Write-Host ('Remaining(not OK): {0}' -f $remaining)

if ($candidates.Count -gt 0) {
    $top = $candidates[0]
    Write-Host ('Recommendation EN_only #1: {0}' -f $top.ModId)
    Write-Host ('KeyCount: {0}' -f $top.KeyCount)
    Write-Host ('Jar: {0}' -f $top.Jar)
}

$reportScript = Join-Path $RepoRoot 'tools\report-missing-zh-tw.ps1'
if (-not (Test-Path $reportScript)) {
    throw "Missing report script: $reportScript"
}

& $reportScript -RepoRoot $RepoRoot -GameRoot $GameRoot -OutDir $OutDir -Top 20

$bundleScript = Join-Path $RepoRoot 'tools\make-gemini-bundle.ps1'
if (-not (Test-Path $bundleScript)) {
    throw "Missing bundle script: $bundleScript"
}

& $bundleScript -RepoRoot $RepoRoot -GameRoot $GameRoot -OutDir $OutDir -TargetModId $TargetModId -KeysPerMod $KeysPerMod

Push-Location $RepoRoot
try {
    $pathsToAdd = @(
        'tools/reports/mods-lang-support.csv',
        'tools/reports/next_mod_candidates.md',
        'tools/out/zh_tw_missing_summary.csv',
        'tools/out/zh_tw_missing_details.json',
        'tools/out/zh_tw_missing_top_20.md',
        ('tools/out/{0}' -f $TargetModId)
    )

    git add @pathsToAdd | Out-Null
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $commitMessage = ('chore: refresh lang reports and {0} bundle' -f $TargetModId)
        git commit -m $commitMessage | Out-Null
        git push | Out-Null
    } else {
        Write-Host 'No changes to commit.'
    }
} finally {
    Pop-Location
}
