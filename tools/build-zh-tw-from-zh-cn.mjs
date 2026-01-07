import fs from "fs";
import path from "path";
import AdmZip from "adm-zip";
import * as OpenCC from "opencc-js";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mods") args.mods = argv[++i];
    else if (a === "--report") args.report = argv[++i];
    else if (a === "--pack") args.pack = argv[++i];
    else if (a === "--mode") args.mode = argv[++i]; // tw | twp
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
  if (!entry) return null;
  const txt = zip.readAsText(entry, "utf8");
  try {
    return JSON.parse(txt);
  } catch {
    return { __parseError: true, __raw: txt };
  }
}

async function main() {
  const { mods, report, pack, mode } = parseArgs(process.argv);

  if (!mods || !report || !pack) {
    console.error(
      `Usage:\n  node tools/build-zh-tw-from-zh-cn.mjs --mods "PATH_TO_MODS" --report "tools/out/lang-report.json" --pack "resourcepacks/sb4-zh_tw" [--mode twp|tw]`
    );
    process.exit(1);
  }

  const modsDir = path.resolve(mods);
  const reportPath = path.resolve(report);
  const packDir = path.resolve(pack);

  const toMode = (mode || "twp").toLowerCase(); // twp: 台灣用語優先（建議）
  // opencc-js 的 Converter 會回傳一個函式（或可呼叫的 converter）
  const convert = OpenCC.Converter({ from: "cn", to: toMode });
  console.log(`[SELFTEST] 自行车 -> ${convert("自行车")}`);

  const rows = readJson(reportPath);

  // 只處理：有 zh_cn 且沒有 zh_tw
  const targets = rows.filter(r => r.zh_cn && !r.zh_tw);

  let ok = 0, skipped = 0, failed = 0;

  for (const r of targets) {
    const jarPath = path.join(modsDir, r.jar);
    if (!fs.existsSync(jarPath)) {
      failed++;
      console.warn("[MISS JAR]", r.jar);
      continue;
    }

    let zip;
    try {
      zip = new AdmZip(jarPath);
    } catch (err) {
      failed++;
      console.warn("[BAD JAR]", r.jar, String(err?.message || err));
      continue;
    }

    const zhCnEntry = `assets/${r.modid}/lang/zh_cn.json`;
    const zhCn = safeParseJsonFromZip(zip, zhCnEntry);

    if (!zhCn || zhCn.__parseError) {
      failed++;
      console.warn("[BAD ZH_CN]", r.jar, r.modid);
      continue;
    }

    const outPath = path.join(packDir, "assets", r.modid, "lang", "zh_tw.json");

    // 保守策略：若你已經手動建立過 zh_tw.json，就不覆蓋
    if (fs.existsSync(outPath)) {
      skipped++;
      continue;
    }

    // 轉繁：只轉 value（key 不動）
    const zhTw = {};
    for (const [k, v] of Object.entries(zhCn)) {
      if (typeof v === "string") zhTw[k] = convert(v);
      else zhTw[k] = v;
    }

    writeJsonPretty(outPath, zhTw);
    ok++;
  }

  // 產出 only-en 清單（方便下一步抽 en_us 做待翻）
  const onlyEn = rows.filter(r => r.en_us && !r.zh_cn && !r.zh_tw);
  const todoCsv = ["jar,modid"].concat(onlyEn.map(r => `${r.jar},${r.modid}`)).join("\n") + "\n";
  ensureDir(path.join("tools", "out"));
  fs.writeFileSync(path.join("tools", "out", "todo-en-only.csv"), todoCsv, "utf8");

  console.log("Done.");
  console.log({ converted: ok, skippedExisting: skipped, failed });
  console.log("Output pack:", packDir);
}

main();
