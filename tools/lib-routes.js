#!/usr/bin/env node
// Library routing: how each system library the macOS client loads is reached on iOS,
// decided from Apple's own export lists (.tbd files) in the iOS SDK. Runs on a Mac (CI).
//
//   node tools/lib-routes.js <client-dir> <iphoneos-sdk> <imports.json> <runtime-gap.json> <out.json>
//   node tools/lib-routes.js --verify <routes.json> <shim-exports.txt>
//
// macOS frameworks are deep (Foundation.framework/Versions/C/Foundation); iOS frameworks are
// shallow (Foundation.framework/Foundation), so not a single macOS framework path loads as-is.
// Every system load command becomes one of:
//   keep    - already an iOS path that exports everything imported from it (libc++, libz).
//   flatten - exists on iOS and exports everything imported from it: rewrite to the iOS path.
//   shim    - absent on iOS, or present but missing macOS-only symbols the client imports:
//             point it at AppKitShim, which implements the macOS-only symbols and re-exports
//             the real iOS libraries (reexportTbds) for everything else. This is the same
//             umbrella mechanism Cocoa and ApplicationServices use on the Mac.
// needFromShim lists, per shim-routed library, the imports no iOS library provides; --verify
// checks them against the built shim's exports so a gap shows up in CI, not on the device.
'use strict';
const fs = require('fs');
const path = require('path');
const mg = require('./machogap.js');
const { canon, walk, parseYaml, parseJson } = require('./ios-sdk-gap.js');

const SHIM = '@rpath/AppKitShim.framework/AppKitShim';

// /System/Library/{,Private}Frameworks/N.framework/Versions/V/B -> .../N.framework/B
function iosPath(p) {
  const m = p.match(/^(\/System\/Library\/(?:Private)?Frameworks\/[^/]+\.framework)\/Versions\/[^/]+\/([^/]+)$/);
  return m ? `${m[1]}/${m[2]}` : p;
}

// Index the SDK one .tbd file at a time. A file's first document is the library itself and
// the rest are the sub-libraries it re-exports (libSystem inlines libsystem_c, _malloc, ...),
// so every symbol in the file is reachable through the main install name. Also index each
// file by where it sits: iOS install names aren't always the shallow guess (IOKit's is still
// IOKit.framework/Versions/A/IOKit), so a library can be found by location too.
function loadSdk(sdk) {
  const reach = new Map();  // main install name -> Set(canonical symbol)
  const tbdOf = new Map();  // main install name -> tbd path relative to the SDK
  const byFile = new Map(); // "/<dir>/<name>" (+ ".dylib" under usr/lib) -> main install name
  const files = [...walk(path.join(sdk, 'System/Library/Frameworks')), ...walk(path.join(sdk, 'usr/lib'))];
  for (const f of files) {
    let text;
    try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
    const syms = new Set();
    let main = null;
    try {
      if (text.trimStart().startsWith('{')) {
        main = JSON.parse(text).main_library?.install_names?.[0]?.name || null;
        parseJson(text, (_, s) => syms.add(s));
      } else {
        main = (text.match(/install-name:\s*'?([^'\n]+)'?/) || [])[1] || null;
        parseYaml(text, (_, s) => syms.add(s));
      }
    } catch { continue; }
    if (!main) continue;
    main = main.trim();
    const rel = path.relative(sdk, f).split(path.sep).join('/');
    if (!reach.has(main)) {
      reach.set(main, new Set());
      tbdOf.set(main, rel);
    }
    for (const s of syms) reach.get(main).add(s);
    const at = '/' + rel.replace(/\.tbd$/, '');
    if (!byFile.has(at)) byFile.set(at, main);
    if (at.startsWith('/usr/lib/') && !byFile.has(at + '.dylib')) byFile.set(at + '.dylib', main);
  }
  const owners = new Map(); // canonical symbol -> [main install names]
  for (const [lib, syms] of reach) for (const s of syms) {
    let o = owners.get(s);
    if (!o) owners.set(s, (o = []));
    o.push(lib);
  }
  return { reach, tbdOf, byFile, owners };
}

// The iOS library a macOS load path corresponds to, by its real install name: the path as
// is, then its shallow form, each tried as an install name and then as a file location.
function resolveIos(p, reach, byFile) {
  for (const c of new Set([p, iosPath(p)])) {
    if (reach.has(c)) return c;
    if (byFile.has(c)) return byFile.get(c);
  }
  return null;
}

function walkFiles(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isSymbolicLink()) continue;
    if (e.isDirectory()) walkFiles(p, out);
    else if (e.isFile()) out.push(p);
  }
  return out;
}

// Every system library path the client's arm64 slices load, with how many binaries load it.
function systemLoadPaths(client) {
  const uses = new Map();
  for (const f of walkFiles(client)) {
    const fd = fs.openSync(f, 'r');
    const head = Buffer.alloc(8);
    const got = fs.readSync(fd, head, 0, 8, 0);
    fs.closeSync(fd);
    if (got < 8) continue;
    const m = head.readUInt32BE(0);
    if (m !== 0xcafebabe && m !== 0xcafebabf && head.readUInt32LE(0) !== 0xfeedfacf) continue;
    const arm = mg.slices(fs.readFileSync(f)).find(s => s.cpu === mg.CPU_ARM64);
    if (!arm) continue;
    for (const d of mg.parseSlice(arm.buf).dylibs) {
      if (d.path.startsWith('/')) uses.set(d.path, (uses.get(d.path) || 0) + 1);
    }
  }
  return uses;
}

function route() {
  const [client, sdk, importsPath, runtimePath, outPath] = process.argv.slice(2);
  if (!outPath) {
    console.error('usage: node tools/lib-routes.js <client-dir> <iphoneos-sdk> <imports.json> <runtime-gap.json> <out.json>');
    process.exit(2);
  }
  const imports = JSON.parse(fs.readFileSync(importsPath, 'utf8')).libraries;
  let runtime = {};
  try { runtime = JSON.parse(fs.readFileSync(runtimePath, 'utf8')).libraries || {}; } catch {}
  const { reach, tbdOf, byFile, owners } = loadSdk(sdk);
  console.log(`iOS SDK: ${reach.size} libraries indexed`);

  const routes = {}, needFromShim = {}, reexports = new Set();
  const uses = systemLoadPaths(client);
  for (const p of [...uses.keys()].sort()) {
    const found = resolveIos(p, reach, byFile);
    const present = !!found;
    const ios = found || iosPath(p);
    if (found && found !== p && found !== iosPath(p)) console.log(`note: ${p} is ${found} on iOS`);
    const syms = (imports[p] && imports[p].symbols) || [];
    const atRuntime = new Set((runtime[p] && runtime[p].presentAtRuntime) || []);
    // What the library at the iOS path can't provide. Symbols the device has at runtime but
    // the SDK doesn't list still resolve when the real library is reached, so they only
    // count against a library that doesn't exist on iOS at all.
    const lacking = syms.filter(s =>
      !(present && (reach.get(ios).has(canon(s)) || atRuntime.has(s))));
    const action = present && lacking.length === 0 ? (ios === p ? 'keep' : 'flatten') : 'shim';
    if (action === 'shim') {
      if (present) reexports.add(ios);
      const none = [];
      for (const s of lacking) {
        const o = owners.get(canon(s));
        if (!o) { none.push(s); continue; }
        // Prefer an owner already re-exported, so the set stays small.
        reexports.add(o.find(l => reexports.has(l)) || o[0]);
      }
      if (none.length) needFromShim[p] = none;
    }
    routes[p] = { action, to: action === 'shim' ? SHIM : ios, binaries: uses.get(p), imported: syms.length, lacking: lacking.length };
  }

  const reexportTbds = [...reexports].sort().map(l => tbdOf.get(l)).filter(Boolean);
  fs.writeFileSync(outPath, JSON.stringify({ shim: SHIM, routes, reexports: [...reexports].sort(), reexportTbds, needFromShim }, null, 1) + '\n');

  const count = a => Object.values(routes).filter(r => r.action === a).length;
  console.log(`routes: ${count('flatten')} flatten, ${count('keep')} keep, ${count('shim')} to the shim`);
  console.log('action   bins  lack  library');
  for (const [p, r] of Object.entries(routes)) {
    console.log(`${r.action.padEnd(8)} ${String(r.binaries).padStart(4)} ${String(r.lacking).padStart(5)}  ${p}`);
  }
  console.log(`\nshim re-exports ${reexports.size} iOS libraries:`);
  for (const l of [...reexports].sort()) console.log(`  ${l}`);
  const need = Object.values(needFromShim).reduce((n, a) => n + a.length, 0);
  console.log(`\n${need} imports must come from the shim itself (checked by --verify)`);
  console.log(`wrote ${outPath}`);
}

// After the shim is built: does it export everything needFromShim says only it can provide?
function verify() {
  const [routesPath, exportsPath] = process.argv.slice(3);
  if (!exportsPath) { console.error('usage: node tools/lib-routes.js --verify <routes.json> <shim-exports.txt>'); process.exit(2); }
  const { needFromShim } = JSON.parse(fs.readFileSync(routesPath, 'utf8'));
  // nm -gU lines: "<address> <type> <name>"
  const exported = new Set(fs.readFileSync(exportsPath, 'utf8').split('\n').map(l => l.trim().split(/\s+/).pop()).filter(Boolean));
  let missing = 0;
  for (const [lib, syms] of Object.entries(needFromShim)) {
    const gone = syms.filter(s => !exported.has(s));
    if (!gone.length) continue;
    missing += gone.length;
    console.log(`MISSING from the shim (${gone.length}) for ${lib}:`);
    for (const s of gone) console.log(`  ${s}`);
  }
  const total = Object.values(needFromShim).reduce((n, a) => n + a.length, 0);
  console.log(`shim provides ${total - missing} of ${total} imports only it can satisfy`);
  // Informational: a missing weak import is harmless, and a strong one names the next fix.
}

if (process.argv[2] === '--verify') verify(); else route();
