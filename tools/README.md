# Tools

Main scripts:
- make-gemini-bundle.ps1: Build per-mod translation bundles for Gemini.
- extract-zh-cn-to-zh-tw.ps1: Apply translated bundles into the repo (zh_tw.json).
- calc-pack-progress.ps1: Generate pack progress reports (single entry point).

Common commands:
- Generate a bundle:
  powershell -ExecutionPolicy Bypass -File .\tools\make-gemini-bundle.ps1 -RepoRoot . -GameRoot "C:\Users\sad79\AppData\Roaming\PrismLauncher\instances\FTB StoneBlock 4\minecraft" -TargetModId twilightforest -KeysPerMod 200 -OutDir .\tools\out
- Apply translated bundle:
  powershell -ExecutionPolicy Bypass -File .\tools\extract-zh-cn-to-zh-tw.ps1 -RepoRoot . -ApplyBundle .\tools\out\twilightforest\bundle_translated.json -PackName sb4-zh_tw -Overwrite
- Generate pack progress CSV:
  powershell -ExecutionPolicy Bypass -File .\tools\calc-pack-progress.ps1 -ExportCsv
