// 翻訳の原文一覧を作り、各言語ファイルの抜け・余りを表示する
//   node tools/i18n.js            … i18n/_source.json を作り直して確認
// 原文 = index.html の CONFIG と T にある英語（{ja,en} の en と、T の [日本語, 英語] の英語）
const fs = require("fs"), path = require("path");
const root = path.join(__dirname, ".."), html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const a = html.indexOf("const CONFIG = {"), b = html.indexOf("\n};", html.indexOf("const T = {")) + 3;
const { CONFIG, T } = new Function(html.slice(a, b) + ";return {CONFIG,T};")();
const hkey = s => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++){ h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193); } return (h >>> 0).toString(36); };
const src = new Map(), add = s => { if (typeof s === "string" && /[A-Za-z]/.test(s)) src.set(hkey(s), s); };
const walk = o => { if (Array.isArray(o)) return o.forEach(walk); if (o && typeof o === "object"){ if ("ja" in o && "en" in o) [].concat(o.en).forEach(add); else Object.values(o).forEach(walk); } };
walk(CONFIG);
const walkT = v => { if (!Array.isArray(v)) return; if (v.length === 2 && typeof v[0] === "string" && typeof v[1] === "string") return add(v[1]); v.forEach(walkT); };
for (const k in T) if (k !== "wd") walkT(T[k]);
const out = Object.fromEntries(src);
fs.writeFileSync(path.join(root, "i18n/_source.json"), JSON.stringify(out, null, 1) + "\n");
console.log("原文", src.size, "件");
for (const f of fs.readdirSync(path.join(root, "i18n")).filter(f => /^[a-z].*\.json$/.test(f) && f !== "_source.json")){
  const tx = JSON.parse(fs.readFileSync(path.join(root, "i18n", f), "utf8"));
  const miss = [...src.keys()].filter(k => !tx[k]), extra = Object.keys(tx).filter(k => !src.has(k));
  console.log(f.padEnd(14), "訳あり", Object.keys(tx).length - extra.length, "／抜け", miss.length, extra.length ? "／不要 " + extra.length : "");
  if (process.argv.includes("-v")) miss.forEach(k => console.log("   -", k, src.get(k).slice(0, 70)));
}
