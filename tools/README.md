# Tools

Translation workflow:
- make-gemini-bundle.ps1: Build per-mod translation bundles.
- extract-zh-cn-to-zh-tw.ps1: Apply translated bundles into zh_tw.json.

Reporting (Node):
- report.mjs: Pack progress and missing/zero/remaining lists.

Examples:
- Generate a bundle:
  powershell -ExecutionPolicy Bypass -File .\tools\make-gemini-bundle.ps1 -RepoRoot . -GameRoot "C:\Users\sad79\AppData\Roaming\PrismLauncher\instances\FTB StoneBlock 4\minecraft" -TargetModId twilightforest -KeysPerMod 200 -OutDir .\tools\out
- Apply translated bundle:
  powershell -ExecutionPolicy Bypass -File .\tools\extract-zh-cn-to-zh-tw.ps1 -RepoRoot . -ApplyBundle .\tools\out\twilightforest\bundle_translated.json -PackName sb4-zh_tw -Overwrite
- Report progress:
  node tools/report.mjs progress --csv tools/out/pack_progress.csv
  node tools/report.mjs zero --top 50
  node tools/report.mjs remaining --top 50
