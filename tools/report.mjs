import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import AdmZip from 'adm-zip';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, '..');

const args = process.argv.slice(2);
const command = args.find(arg => !arg.startsWith('-')) || 'progress';

function getArgValue(name, fallback) {
  const idx = args.indexOf(name);
  if (idx === -1) return fallback;
  const next = args[idx + 1];
  if (!next || next.startsWith('-')) return fallback;
  return next;
}

const csvPath = getArgValue('--csv', null);
const topLimit = parseInt(getArgValue('--top', '50'), 10);

const gameRoot = 'C:\\Users\\sad79\\AppData\\Roaming\\PrismLauncher\\instances\\FTB StoneBlock 4\\minecraft';
const modsDir = path.join(gameRoot, 'mods');
const packAssetsRoot = path.join(repoRoot, 'resourcepacks', 'sb4-zh_tw', 'assets');
const kubejsAssetsRoot = path.join(repoRoot, 'kubejs', 'assets');

function readText(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function parseKeysFromText(text, sourcePath, warnings) {
  const keys = new Set();
  try {
    const obj = JSON.parse(text);
    for (const key of Object.keys(obj)) {
      keys.add(key);
    }
    return keys;
  } catch (err) {
    warnings.push({ path: sourcePath, reason: err.message });
  }

  const pattern = /"(?<k>(?:\\.|[^"\\])+?)"\s*:/g;
  for (const match of text.matchAll(pattern)) {
    const key = match.groups?.k || match[1];
    if (key) keys.add(key);
  }
  return keys;
}

function readJsonKeys(filePath, warnings) {
  if (!fs.existsSync(filePath)) return new Set();
  const text = readText(filePath);
  return parseKeysFromText(text, filePath, warnings);
}

function loadEnUsKeysFromJar(jarPath, entryName, warnings) {
  const zip = new AdmZip(jarPath);
  const entry = zip.getEntry(entryName);
  if (!entry) return new Set();
  const text = zip.readAsText(entry);
  const sourcePath = `${jarPath}::${entryName}`;
  return parseKeysFromText(text, sourcePath, warnings);
}

if (!fs.existsSync(modsDir)) {
  console.error(`ModsDir not found: ${modsDir}`);
  process.exit(1);
}

const warnings = [];
const modMap = new Map();

for (const item of fs.readdirSync(modsDir)) {
  if (!item.endsWith('.jar')) continue;
  const jarPath = path.join(modsDir, item);
  let zip;
  try {
    zip = new AdmZip(jarPath);
  } catch (err) {
    warnings.push({ path: jarPath, reason: `Failed to read jar: ${err.message}` });
    continue;
  }

  const entries = zip.getEntries();
  for (const entry of entries) {
    const match = entry.entryName.match(/^assets\/([^/]+)\/lang\/en_us\.json$/);
    if (!match) continue;
    const modid = match[1];
    const enKeys = parseKeysFromText(zip.readAsText(entry), `${jarPath}::${entry.entryName}`, warnings);
    const total = enKeys.size;
    const existing = modMap.get(modid);
    if (!existing || total > existing.total) {
      modMap.set(modid, {
        modid,
        total,
        enKeys,
        sourceJar: jarPath
      });
    }
  }
}

const rows = [];
for (const modid of Array.from(modMap.keys()).sort()) {
  const entry = modMap.get(modid);
  const zhRepoPath = path.join(packAssetsRoot, modid, 'lang', 'zh_tw.json');
  const zhKubePath = path.join(kubejsAssetsRoot, modid, 'lang', 'zh_tw.json');
  const zhKeys = new Set();

  for (const key of readJsonKeys(zhRepoPath, warnings)) zhKeys.add(key);
  for (const key of readJsonKeys(zhKubePath, warnings)) zhKeys.add(key);

  let translated = 0;
  for (const key of entry.enKeys) {
    if (zhKeys.has(key)) translated++;
  }

  let remaining = entry.total - translated;
  if (remaining < 0) remaining = 0;
  const percent = entry.total > 0 ? Math.round((translated / entry.total) * 1000) / 10 : 0;

  rows.push({
    modid,
    translated,
    total: entry.total,
    remaining,
    percent,
    sourceJar: entry.sourceJar,
    zh_tw_repo: zhRepoPath,
    zh_tw_kubejs: zhKubePath
  });
}

rows.sort((a, b) => {
  if (b.remaining !== a.remaining) return b.remaining - a.remaining;
  return a.modid.localeCompare(b.modid);
});

const overallTranslated = rows.reduce((sum, r) => sum + r.translated, 0);
const overallTotal = rows.reduce((sum, r) => sum + r.total, 0);
const overallRemaining = Math.max(0, overallTotal - overallTranslated);
const overallPercent = overallTotal > 0 ? Math.round((overallTranslated / overallTotal) * 1000) / 10 : 0;

function printTable(list) {
  const header = `${'modid'.padEnd(30)} ${'translated'.padStart(10)} ${'total'.padStart(10)} ${'remaining'.padStart(10)} ${'percent'.padStart(8)}`;
  const divider = `${'-'.repeat(30)} ${'-'.repeat(10)} ${'-'.repeat(10)} ${'-'.repeat(10)} ${'-'.repeat(8)}`;
  console.log(header);
  console.log(divider);
  for (const row of list) {
    const percentStr = `${row.percent.toFixed(1)}%`;
    console.log(`${row.modid.padEnd(30)} ${String(row.translated).padStart(10)} ${String(row.total).padStart(10)} ${String(row.remaining).padStart(10)} ${percentStr.padStart(8)}`);
  }
}

if (command === 'progress') {
  console.log(`sb4-zh_tw overall progress: translated=${overallTranslated} / total=${overallTotal}, remaining=${overallRemaining}, percent=${overallPercent}%`);
  printTable(rows.slice(0, topLimit));
} else if (command === 'zero') {
  const list = rows.filter(r => r.total > 0 && r.translated === 0).sort((a, b) => b.total - a.total);
  printTable(list.slice(0, topLimit));
} else if (command === 'remaining') {
  const list = rows.filter(r => r.remaining > 0).sort((a, b) => b.remaining - a.remaining);
  printTable(list.slice(0, topLimit));
} else {
  console.error(`Unknown command: ${command}`);
  process.exit(1);
}

if (warnings.length > 0) {
  console.log(`JSON parse fallback used: ${warnings.length} files`);
  for (const warn of warnings.slice(0, 20)) {
    console.log(`- ${warn.path}: ${warn.reason}`);
  }
}

if (csvPath) {
  const csvLines = [];
  csvLines.push('modid,translated,total,remaining,percent,sourceJar,zh_tw_repo,zh_tw_kubejs');
  for (const row of rows) {
    const line = [
      row.modid,
      row.translated,
      row.total,
      row.remaining,
      row.percent,
      row.sourceJar,
      row.zh_tw_repo,
      row.zh_tw_kubejs
    ].map(value => {
      const str = String(value ?? '');
      if (/[",\n]/.test(str)) {
        return `"${str.replace(/"/g, '""')}"`;
      }
      return str;
    }).join(',');
    csvLines.push(line);
  }
  fs.mkdirSync(path.dirname(csvPath), { recursive: true });
  fs.writeFileSync(csvPath, csvLines.join('\n'), 'utf8');
}
