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

// Libraries iOS has but the shim must stand in front of anyway, because it answers some of
// their functions itself (the umbrella lists the shim's code first): CoreAudio's Mac
// hardware calls start iOS's in-process audio hardware layer, whose Bluetooth plug-in then
// kept a thread a quarter busy for nothing (src/CoreAudioHAL.m).
const THROUGH_SHIM = new Set(['/System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio']);

// iOS libraries the umbrella forwards for games' sake, not the client's (see route()).
const FOR_GAMES = ['/System/Library/Frameworks/AVFoundation.framework/AVFoundation'];

// /System/Library/{,Private}Frameworks/N.framework/Versions/V/B -> .../N.framework/B
function iosPath(p) {
  const m = p.match(/^(\/System\/Library\/(?:Private)?Frameworks\/[^/]+\.framework)\/Versions\/[^/]+\/([^/]+)$/);
  return m ? `${m[1]}/${m[2]}` : p;
}

// Index the SDK one .tbd file at a time. A file's first document is the library itself and
// the rest are the sub-libraries it re-exports (libSystem inlines libsystem_c, _malloc, ...),
// so every symbol in the file is reachable through the main install name. Also index each
// file by where it sits: iOS install names aren't always the shallow guess (IOKit's is still
// IOKit.framework/Versions/A/IOKit), so a library can be found by location too. A library
// can also re-export others that live in their own .tbd (its reexported-libraries list:
// CoreLocation -> _LocationEssentials), which dyld follows, so record those edges and
// follow them transitively.
function loadSdk(sdk) {
  const reach = new Map();  // main install name -> Set(canonical symbol)
  const tbdOf = new Map();  // main install name -> tbd path relative to the SDK
  const byFile = new Map(); // "/<dir>/<name>" (+ ".dylib" under usr/lib) -> main install name
  const rexOf = new Map();  // main install name -> Set(install names it re-exports)
  const files = [...walk(path.join(sdk, 'System/Library/Frameworks')), ...walk(path.join(sdk, 'usr/lib'))];
  for (const f of files) {
    let text;
    try { text = fs.readFileSync(f, 'utf8'); } catch { continue; }
    const syms = new Set();
    const rex = [];
    let main = null;
    try {
      if (text.trimStart().startsWith('{')) {
        const lib = JSON.parse(text).main_library || {};
        main = lib.install_names?.[0]?.name || null;
        for (const r of lib.reexported_libraries || []) rex.push(...(r.names || []));
        parseJson(text, (_, s) => syms.add(s));
      } else {
        main = (text.match(/install-name:\s*'?([^'\n]+)'?/) || [])[1] || null;
        // The main document's top-level reexported-libraries block, up to the next key.
        const first = text.split(/^---\s/m).find(d => /install-name:/.test(d)) || '';
        const block = (first.match(/^reexported-libraries:([\s\S]*?)(?=^\S|(?![\s\S]))/m) || [])[1] || '';
        for (const m of block.matchAll(/libraries:\s*\[([^\]]*)\]/g)) {
          rex.push(...m[1].split(',').map(s => s.trim().replace(/^'|'$/g, '')).filter(Boolean));
        }
        parseYaml(text, (_, s) => syms.add(s));
      }
    } catch { continue; }
    if (!main) continue;
    main = main.trim();
    const rel = path.relative(sdk, f).split(path.sep).join('/');
    if (!reach.has(main)) {
      reach.set(main, new Set());
      tbdOf.set(main, rel);
      rexOf.set(main, new Set());
    }
    for (const s of syms) reach.get(main).add(s);
    for (const r of rex) rexOf.get(main).add(r.trim());
    const at = '/' + rel.replace(/\.tbd$/, '');
    if (!byFile.has(at)) byFile.set(at, main);
    if (at.startsWith('/usr/lib/') && !byFile.has(at + '.dylib')) byFile.set(at + '.dylib', main);
  }
  const owners = new Map(); // canonical symbol -> [main install names that define it]
  for (const [lib, syms] of reach) for (const s of syms) {
    let o = owners.get(s);
    if (!o) owners.set(s, (o = []));
    o.push(lib);
  }
  // Everything a library re-exports, transitively (a cycle just stops early).
  const under = new Map();
  const reexportsOf = lib => {
    if (under.has(lib)) return under.get(lib);
    const out = new Set();
    under.set(lib, out);
    for (const r of rexOf.get(lib) || []) {
      if (out.has(r)) continue;
      out.add(r);
      for (const x of reexportsOf(r)) out.add(x);
    }
    return out;
  };
  // Who re-exports a given library: the public route to a symbol whose definer is private.
  const carriers = new Map();
  for (const lib of reach.keys()) for (const u of reexportsOf(lib)) {
    let c = carriers.get(u);
    if (!c) carriers.set(u, (c = []));
    c.push(lib);
  }
  // Can `lib` provide `sym` through two-level lookup (itself or anything it re-exports)?
  const reaches = (lib, sym) =>
    !!reach.get(lib)?.has(sym) || [...reexportsOf(lib)].some(r => reach.get(r)?.has(sym));
  return { reach, tbdOf, byFile, owners, reexportsOf, carriers, reaches };
}

// Public libraries are ones a client may link: not a _Private.framework, a PrivateFramework,
// or a /usr/lib/system piece of libSystem.
const isPublic = lib => !/\/_[^/]*\.framework\//.test(lib) && !lib.includes('/PrivateFrameworks/') &&
  !lib.startsWith('/usr/lib/system/');

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

// Every system library path the client's arm64 slices load, with how many binaries load it,
// and the symbols they import from each. Read from the binaries being shipped, so routing
// can't miss a library or symbol that a committed snapshot (imports.json) predates.
function systemLoadPaths(client) {
  const uses = new Map();
  const symbols = new Map(); // library path -> Set(imported symbol)
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
    const r = mg.parseSlice(arm.buf);
    for (const d of r.dylibs) {
      if (d.path.startsWith('/')) uses.set(d.path, (uses.get(d.path) || 0) + 1);
    }
    for (const imp of r.imports) {
      const lib = mg.libFor(r, imp.ord);
      if (!lib.startsWith('/')) continue; // self, flat lookup, bundled code
      let s = symbols.get(lib);
      if (!s) symbols.set(lib, (s = new Set()));
      s.add(imp.name);
    }
  }
  return { uses, symbols };
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
  const { reach, tbdOf, byFile, owners, reexportsOf, carriers, reaches } = loadSdk(sdk);
  console.log(`iOS SDK: ${reach.size} libraries indexed`);

  // Pass 1: each library's action, judged by what its iOS counterpart reaches through its
  // own re-exports, exactly as dyld's two-level lookup would.
  const routes = {}, needFromShim = {}, lackingOf = {}, reexports = new Set();
  const { uses, symbols } = systemLoadPaths(client);
  for (const p of [...uses.keys()].sort()) {
    const found = resolveIos(p, reach, byFile);
    const present = !!found;
    const ios = found || iosPath(p);
    if (found && found !== p && found !== iosPath(p)) console.log(`note: ${p} is ${found} on iOS`);
    // What the shipped binaries import from it, plus anything the committed snapshot lists.
    const syms = [...new Set([...(symbols.get(p) || []), ...((imports[p] && imports[p].symbols) || [])])];
    const atRuntime = new Set((runtime[p] && runtime[p].presentAtRuntime) || []);
    // What the library at the iOS path can't provide. Symbols the device has at runtime but
    // the SDK doesn't list still resolve when the real library is reached, so they only
    // count against a library that doesn't exist on iOS at all.
    const lacking = syms.filter(s => !(present && (reaches(ios, canon(s)) || atRuntime.has(s))));
    const action = present && lacking.length === 0 && !THROUGH_SHIM.has(p) ? (ios === p ? 'keep' : 'flatten') : 'shim';
    // A shim-routed library that exists on iOS is forwarded whole by the umbrella.
    if (action === 'shim' && present) reexports.add(ios);
    lackingOf[p] = lacking;
    routes[p] = { action, to: action === 'shim' ? SHIM : ios, binaries: uses.get(p), imported: syms.length, lacking: lacking.length };
  }

  // Pass 2: for each symbol a shim-routed library lacks, make sure the umbrella reaches it:
  // through what it already re-exports if possible, else by adding the library that defines
  // it — or a public library that re-exports that one, since a private one can't be linked.
  const covered = new Set();
  const cover = lib => { covered.add(lib); for (const u of reexportsOf(lib)) covered.add(u); };
  for (const r of reexports) cover(r);
  for (const [p, r] of Object.entries(routes)) {
    if (r.action !== 'shim') continue;
    const none = [];
    for (const s of lackingOf[p]) {
      const defs = owners.get(canon(s));
      if (!defs) { none.push(s); continue; }
      if (defs.some(d => covered.has(d))) continue;
      const candidates = [...defs, ...defs.flatMap(d => carriers.get(d) || [])];
      const pick = candidates.find(isPublic) || candidates[0];
      reexports.add(pick);
      cover(pick);
    }
    if (none.length) needFromShim[p] = none;
  }

  // Libraries iOS has that games use with a few macOS-only names in them (AVFoundation's Mac
  // capture presets): forwarded whole, so a game binary using one of those names can reach
  // that library through the shim, which adds them (MacPrograms.m).
  for (const l of FOR_GAMES) if (reach.has(l)) { reexports.add(l); cover(l); }

  // Drop a re-export another re-export already carries: the linker drops it anyway, and
  // the umbrella check below compares names exactly.
  for (const r of [...reexports]) {
    if ([...reexports].some(o => o !== r && reexportsOf(o).has(r))) reexports.delete(r);
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

if (require.main === module) {
  if (process.argv[2] === '--verify') verify(); else route();
}
module.exports = { SHIM, iosPath, loadSdk, resolveIos };
