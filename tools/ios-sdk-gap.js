#!/usr/bin/env node
// Exact gap: which of the macOS Steam client's system imports (data/imports.json) the real
// iOS SDK does not export. Reads every .tbd (Apple's text stubs listing a library's exports)
// under the SDK's public frameworks and /usr/lib, so the answer comes from Apple's own lists
// rather than from guessing by name. Runs on a Mac (CI).
//
//   node tools/ios-sdk-gap.js <imports.json> <iphoneos-sdk-path> <out.json>
'use strict';
const fs = require('fs');
const path = require('path');

// Canonical form: no leading underscore (C symbols carry one in Mach-O, tbd v4 and imports).
const canon = s => (s.startsWith('_') ? s.slice(1) : s);

function walk(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.tbd')) out.push(p);
  }
  return out;
}

// tbd v4 (YAML). Several documents per file (umbrellas inline their sub-libraries).
function parseYaml(text, add) {
  for (const doc of text.split(/^---\s/m)) {
    const install = (doc.match(/install-name:\s*'?([^'\n]+)'?/) || [])[1];
    if (!install) continue;
    const re = /(symbols|weak-symbols|thread-local-symbols|objc-classes|objc-eh-types|objc-ivars):\s*\[([^\]]*)\]/g;
    let m;
    while ((m = re.exec(doc))) {
      const items = m[2].split(',').map(s => s.trim().replace(/^'|'$/g, '')).filter(Boolean);
      for (const it of items) {
        switch (m[1]) {
          case 'objc-classes':  add(install, `OBJC_CLASS_$_${it}`); add(install, `OBJC_METACLASS_$_${it}`); break;
          case 'objc-eh-types': add(install, `OBJC_EHTYPE_$_${it}`); break;
          case 'objc-ivars':    add(install, `OBJC_IVAR_$_${it}`); break;
          default:              add(install, canon(it));
        }
      }
    }
  }
}

// tbd v5 (JSON).
function parseJson(text, add) {
  const j = JSON.parse(text);
  for (const lib of [j.main_library, ...(j.libraries || [])]) {
    if (!lib) continue;
    const install = (lib.install_names || [])[0]?.name;
    if (!install) continue;
    for (const group of lib.exported_symbols || []) {
      for (const section of [group.data, group.text]) {
        if (!section) continue;
        for (const s of [...(section.global || []), ...(section.weak || []), ...(section.thread_local || [])]) {
          add(install, canon(s));
        }
        for (const c of section.objc_class || []) { add(install, `OBJC_CLASS_$_${c}`); add(install, `OBJC_METACLASS_$_${c}`); }
        for (const c of section.objc_eh_type || []) add(install, `OBJC_EHTYPE_$_${c}`);
        for (const c of section.objc_ivar || []) add(install, `OBJC_IVAR_$_${c}`);
      }
    }
  }
}

function main() {
  const [importsPath, sdk, outPath] = process.argv.slice(2);
  if (!importsPath || !sdk || !outPath) {
    console.error('usage: node tools/ios-sdk-gap.js <imports.json> <iphoneos-sdk-path> <out.json>');
    process.exit(2);
  }
  const imports = JSON.parse(fs.readFileSync(importsPath, 'utf8')).libraries;

  // symbol -> iOS install names that export it
  const exporters = new Map();
  const add = (install, sym) => {
    let set = exporters.get(sym);
    if (!set) exporters.set(sym, (set = new Set()));
    set.add(install);
  };
  const files = [...walk(path.join(sdk, 'System/Library/Frameworks')), ...walk(path.join(sdk, 'usr/lib'))];
  let parsed = 0;
  for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    try { (text.trimStart().startsWith('{') ? parseJson : parseYaml)(text, add); parsed++; }
    catch (e) { console.error(`skip ${f}: ${e.message}`); }
  }

  const result = { sdk, tbdFiles: parsed, iosSymbols: exporters.size, libraries: {} };
  let imported = 0, missing = 0;
  console.log(`Parsed ${parsed} .tbd files, ${exporters.size} exported iOS symbols.\n`);
  console.log('missing  imported  library');
  for (const [lib, info] of Object.entries(imports)) {
    const gone = info.symbols.filter(s => !exporters.has(canon(s)));
    imported += info.symbols.length;
    missing += gone.length;
    result.libraries[lib] = { framework: info.framework, imported: info.symbols.length, missing: gone };
    if (gone.length) console.log(`${String(gone.length).padStart(7)}  ${String(info.symbols.length).padStart(8)}  ${info.framework}`);
  }
  result.totals = { imported, missing };
  console.log(`\nTOTAL: ${missing} of ${imported} imported system symbols are missing on iOS.`);
  fs.writeFileSync(outPath, JSON.stringify(result, null, 1) + '\n');
}

main();
