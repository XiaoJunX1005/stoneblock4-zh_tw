import fs from "fs";
import path from "path";
import AdmZip from "adm-zip";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mods") args.mods = argv[++i];
    else if (a === "--report") args.report = argv[++i];
    else if (a === "--out") args.out = argv[++i];
  }
  return args;
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJsonPretty(filePath, obj) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(obj, null, 2) + "\n", "utf8");
}

function safeParseJsonFromZip(zip, entryName) {
  const entry = zip.getEntry(entryName);
  if (!entry) return { ok: false, reason: "missing" };
  const txt = zip.readAsText(entry, "utf8");
  try {
    const obj = JSON.parse(txt);
    return { ok: true, obj };
  } catch (e) {
    return { ok: false, reason: "bad_json", error: String(e?.message || e), raw: txt };
  }
}

function toCsv(rows, header) {
  const escape = (v) => {
    const s = String(v ?? "");
    if (/[",\n]/.test(s)) return `"${s.replaceAll('"', '""')}"`;
    return s;
  };
  return header.join(",") + "\n" + rows.map(r => header.map(h => escape(r[h])).join(",")).join("\n") + "\n";
}

function main() {
  const { mods, report, out } = parseArgs(process.argv);

  if (!mods || !report) {
    console.error(
      `Usage:\n  node tools/extract-en-only.mjs --mods "PATH_TO_MODS" --report ".\\tools\\out\\lang-report.json" [--out ".\\tools\\out"]`
    );
    process.exit(1);
  }

  const modsDir = path.resolve(mods);
  const reportPath = path.resolve(report);
  const outDir = path.resolve(out || path.join("tools", "out"));

  ensureDir(outDir);

  const rows = readJson(reportPath);

  // only-en: 有 en_us 且沒有 zh_cn/zh_tw
  const onlyEn = rows.filter(r => r.en_us && !r.zh_cn && !r.zh_tw);

  const perModDir = path.join(outDir, "en-only-per-mod");
  ensureDir(perModDir);

  const merged = {}; // { modid: { key: value } }
  const stats = [];  // { modid, jar, keyCount }
  const errors = []; // { jar, modid, reason, detail }

  for (const r of onlyEn) {
    const jarPath = path.join(modsDir, r.jar);
    if (!fs.existsSync(jarPath)) {
      errors.push({ jar: r.jar, modid: r.modid, reason: "missing_jar", detail: jarPath });
      continue;
    }

    let zip;
    try {
      zip = new AdmZip(jarPath);
    } catch (e) {
      errors.push({ jar: r.jar, modid: r.modid, reason: "bad_jar", detail: String(e?.message || e) });
      continue;
    }

    const enEntry = `assets/${r.modid}/lang/en_us.json`;
    const parsed = safeParseJsonFromZip(zip, enEntry);

    if (!parsed.ok) {
      errors.push({
        jar: r.jar,
        modid: r.modid,
        reason: parsed.reason,
        detail: parsed.reason === "bad_json" ? parsed.error : enEntry
      });

      // 可選：把原始內容吐出來，方便手動修
      if (parsed.reason === "bad_json" && parsed.raw) {
        const rawPath = path.join(outDir, "en-only-raw", `${r.modid}.en_us.raw.txt`);
        ensureDir(path.dirname(rawPath));
        fs.writeFileSync(rawPath, parsed.raw, "utf8");
      }
      continue;
    }

    const enObj = parsed.obj;

    // 合併：同 modid 若出現多次，後者覆蓋前者（一般不會發生）
    if (!merged[r.modid]) merged[r.modid] = {};
    for (const [k, v] of Object.entries(enObj)) {
      merged[r.modid][k] = v;
    }

    const outPath = path.join(perModDir, `${r.modid}.json`);
    writeJsonPretty(outPath, enObj);

    stats.push({ modid: r.modid, jar: r.jar, keyCount: Object.keys(enObj).length });
  }

  // 輸出 merged
  writeJsonPretty(path.join(outDir, "en-only-merged.json"), merged);

  // stats.csv
  fs.writeFileSync(
    path.join(outDir, "en-only-stats.csv"),
    toCsv(stats, ["modid", "jar", "keyCount"]),
    "utf8"
  );

  // errors.csv
  fs.writeFileSync(
    path.join(outDir, "en-only-errors.csv"),
    toCsv(errors, ["jar", "modid", "reason", "detail"]),
    "utf8"
  );

  console.log("Done.");
  console.log({
    onlyEnMods: onlyEn.length,
    extractedMods: stats.length,
    errors: errors.length,
    outDir
  });
}

main();
