import fs from "fs";
import path from "path";
import AdmZip from "adm-zip";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mods") args.mods = argv[++i];
    else if (a === "--out") args.out = argv[++i];
  }
  return args;
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function scanJar(jarPath) {
  const zip = new AdmZip(jarPath);
  const entries = zip.getEntries();

  // modid -> { en_us: bool, zh_cn: bool, zh_tw: bool }
  const found = new Map();

  const re = /^assets\/([^/]+)\/lang\/(en_us|zh_cn|zh_tw)\.json$/;

  for (const e of entries) {
    const m = re.exec(e.entryName);
    if (!m) continue;
    const modid = m[1];
    const lang = m[2];
    if (!found.has(modid)) found.set(modid, { en_us: false, zh_cn: false, zh_tw: false });
    found.get(modid)[lang] = true;
  }

  return Object.fromEntries(found.entries());
}

function main() {
  const { mods, out } = parseArgs(process.argv);

  if (!mods) {
    console.error(`Usage: node tools/scan-langs.mjs --mods "PATH_TO_.minecraft/mods" [--out "OUTPUT_DIR"]`);
    process.exit(1);
  }

  const modsDir = path.resolve(mods);
  if (!fs.existsSync(modsDir)) {
    console.error("Mods dir not found:", modsDir);
    process.exit(1);
  }

  const outDir = path.resolve(out || path.join(process.cwd(), "out"));
  ensureDir(outDir);

  const jars = fs.readdirSync(modsDir)
    .filter(f => f.toLowerCase().endsWith(".jar"))
    .map(f => path.join(modsDir, f));

  const report = [];
  for (const jar of jars) {
    try {
      const perMod = scanJar(jar);
      const rows = Object.entries(perMod).map(([modid, langs]) => ({
        jar: path.basename(jar),
        modid,
        en_us: !!langs.en_us,
        zh_cn: !!langs.zh_cn,
        zh_tw: !!langs.zh_tw
      }));
      report.push(...rows);
    } catch (err) {
      report.push({
        jar: path.basename(jar),
        modid: "(error)",
        en_us: false,
        zh_cn: false,
        zh_tw: false,
        error: String(err?.message || err)
      });
    }
  }

  // JSON
  const jsonPath = path.join(outDir, "lang-report.json");
  fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2), "utf8");

  // CSV
  const csvPath = path.join(outDir, "lang-report.csv");
  const header = "jar,modid,en_us,zh_cn,zh_tw\n";
  const lines = report.map(r =>
    `${r.jar},${r.modid},${r.en_us ? 1 : 0},${r.zh_cn ? 1 : 0},${r.zh_tw ? 1 : 0}`
  );
  fs.writeFileSync(csvPath, header + lines.join("\n"), "utf8");

  // Summary
  const summary = {
    totalRows: report.length,
    hasZhCn: report.filter(r => r.zh_cn).length,
    hasZhTw: report.filter(r => r.zh_tw).length,
    onlyEn: report.filter(r => r.en_us && !r.zh_cn && !r.zh_tw).length
  };
  fs.writeFileSync(path.join(outDir, "summary.json"), JSON.stringify(summary, null, 2), "utf8");

  console.log("Done.");
  console.log("Output:", outDir);
  console.log(summary);
}

main();
