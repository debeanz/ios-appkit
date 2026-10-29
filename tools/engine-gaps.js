#!/usr/bin/env node
// What a game engine's Mac build would be missing here, found before anyone plays a game made
// with it. Every Mach-O in each engine folder is routed the way the app routes a game's binaries
// (src/MacPrograms.m: routeLibrary, then throughShimIfLacking) and each import is looked up where
// it would bind: the iOS SDK's export lists, the shim's own exports and the iOS libraries its
// umbrella re-exports, or AKOpenGL. Also reported: code iOS can't run (Intel only, arm64e) and
// engines that write machine code as they run, which iOS doesn't let this app map. Runs in CI
// after the shim is built (ipa.yml); report only.
//
//   node tools/engine-gaps.js <engines-dir> <iphoneos-sdk> <routes.json> <shim-exports.txt>
//                             <opengl-exports.txt> <runtime-gap.json> <out.json>
'use strict';
const fs = require('fs');
const path = require('path');
const mg = require('./machogap.js');
const { canon } = require('./ios-sdk-gap.js');
const { SHIM, loadSdk, resolveIos } = require('./lib-routes.js');

const OPENGL = '@rpath/AKOpenGL.framework/AKOpenGL';
const MH_EXECUTE = 2;
const CPU_SUBTYPE_ARM64E = 2;

// Runtimes that compile to machine code while the game runs, by a file they ship.
const CODEGEN = [
  [/\/libmono(bdwgc|sgen)?-2\.0\.dylib$|\/libmono\.dylib$/, 'Mono (Unity\'s Mono scripting backend, or FNA/MonoGame on Mono)'],
  [/\/libcoreclr\.dylib$/, '.NET (CoreCLR)'],
  [/\/libjvm\.dylib$/, 'Java (HotSpot)'],
  [/\/(Electron Framework|nwjs Framework)$|\/libnode\.dylib$/, 'JavaScript (V8)'],
];

// nm -gU lines are "<address> <type> <name>"; file headers and blank lines fall out as non-symbols.
function readExports(file) {
  const out = new Set();
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const name = line.trim().split(/\s+/).pop();
    if (name && name.startsWith('_')) out.add(name);
  }
  return out;
}

function walkFiles(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isSymbolicLink()) continue;   // frameworks' Versions/Current and the like
    if (e.isDirectory()) walkFiles(p, out);
    else if (e.isFile()) out.push(p);
  }
  return out;
}

// The arm64 slice the app would convert (arm64e can't load into it), or why there is none.
function arm64Slice(buf) {
  const magicBE = buf.readUInt32BE(0);
  const fat = magicBE === 0xcafebabe || magicBE === 0xcafebabf;
  const subtypes = [];
  if (fat) {
    const is64 = magicBE === 0xcafebabf;
    for (let i = 0; i < buf.readUInt32BE(4); i++) subtypes.push(buf.readUInt32BE(8 + i * (is64 ? 32 : 20) + 4) & 0xffffff);
  } else {
    subtypes.push(buf.readUInt32LE(8) & 0xffffff);
  }
  const all = mg.slices(buf);
  let arm64e = false;
  for (let i = 0; i < all.length; i++) {
    if (all[i].cpu !== mg.CPU_ARM64) continue;
    if (all[i].buf.length < 32 || all[i].buf.readUInt32LE(0) !== 0xfeedfacf) return { archive: true };   // a static library's slice
    if (subtypes[i] === CPU_SUBTYPE_ARM64E) { arm64e = true; continue; }
    return { slice: all[i].buf };
  }
  const intel = all.some(s => s.cpu === 0x01000007);
  return { why: arm64e ? 'arm64e only' : intel ? 'Intel only' : 'no arm64 code' };
}

function main() {
  const [enginesDir, sdk, routesPath, shimExportsPath, glExportsPath, runtimePath, outPath] = process.argv.slice(2);
  if (!outPath) {
    console.error('usage: node tools/engine-gaps.js <engines-dir> <iphoneos-sdk> <routes.json> <shim-exports.txt> <opengl-exports.txt> <runtime-gap.json> <out.json>');
    process.exit(2);
  }
  const { routes, reexports: reexportList } = JSON.parse(fs.readFileSync(routesPath, 'utf8'));
  const reexports = new Set(reexportList);
  const shimExports = readExports(shimExportsPath);
  const glExports = readExports(glExportsPath);
  // Names the device has though the SDK doesn't list them (tools/runtime-gap.m).
  const atRuntime = new Set();
  try {
    for (const l of Object.values(JSON.parse(fs.readFileSync(runtimePath, 'utf8')).libraries || {}))
      for (const s of l.presentAtRuntime || []) atRuntime.add(s.startsWith('_') ? s : '_' + s);
  } catch {}
  const { reach, byFile, reaches } = loadSdk(sdk);

  const provides = (to, sym) => {
    if (atRuntime.has(sym)) return true;
    if (to === OPENGL) return glExports.has(sym);
    if (to === SHIM) return shimExports.has(sym) || [...reexports].some(r => reaches(r, canon(sym)));
    return reaches(to, canon(sym));
  };
  // Where a game binary's library reference goes (MacPrograms.m routeLibrary), or null for the
  // game's own libraries, which are checked as files of their own.
  const routeOf = lib => {
    if (lib.startsWith('/System/Library/Frameworks/OpenGL.framework/')) return OPENGL;
    const r = routes[lib];
    if (r && typeof r.to === 'string') return r.to;
    if (!lib.startsWith('/System/Library/') && !lib.startsWith('/usr/lib/')) return null;
    return resolveIos(lib, reach, byFile) || SHIM;
  };

  const report = {};
  for (const engine of fs.readdirSync(enginesDir).sort()) {
    const root = path.join(enginesDir, engine);
    if (!fs.statSync(root).isDirectory()) continue;
    const e = report[engine] = { binaries: 0, cannotRun: [], codegen: [], luajit: [], missing: {}, flatLookups: 0 };
    for (const file of walkFiles(root)) {
      const rel = path.relative(root, file);
      let buf;
      try {
        const head = Buffer.alloc(4), fd = fs.openSync(file, 'r');
        const got = fs.readSync(fd, head, 0, 4, 0);
        fs.closeSync(fd);
        const magic = got === 4 ? head.readUInt32BE(0) : 0;
        if (magic !== 0xcafebabe && magic !== 0xcafebabf && magic !== 0xcffaedfe) continue;
        buf = fs.readFileSync(file);
      } catch { continue; }
      if (buf.length < 32 || !mg.slices(buf).length) continue;
      for (const [re, what] of CODEGEN) if (re.test('/' + rel)) e.codegen.push(`${rel}: ${what}`);
      const { slice, why, archive } = arm64Slice(buf);
      if (archive) continue;   // linked into a game when it's built, not loaded
      if (!slice) { e.cannotRun.push(`${rel}: ${why}`); continue; }
      let r;
      try { r = mg.parseSlice(slice); } catch (err) { e.cannotRun.push(`${rel}: unreadable (${err.message})`); continue; }
      if (r.platform && r.platform !== 'macOS') continue;   // an xcframework's iOS copies
      e.binaries++;
      if (slice.includes('_luaJIT_setmode\0')) e.luajit.push(rel);
      // Strong imports by library, as the app sees them for throughShimIfLacking.
      const byLib = new Map();
      for (const imp of r.imports) {
        if (imp.ord === 0xfe || imp.ord === 0xfd) { e.flatLookups++; continue; }
        if (imp.ord < 1 || imp.ord > r.dylibs.length || imp.weak) continue;
        const lib = r.dylibs[imp.ord - 1].path;
        if (!byLib.has(lib)) byLib.set(lib, []);
        byLib.get(lib).push(imp.name);
      }
      for (const [lib, names] of byLib) {
        let to = routeOf(lib);
        if (!to) continue;
        if (to !== SHIM && to !== OPENGL && reexports.has(to) && names.some(n => !provides(to, n))) to = SHIM;
        const gone = names.filter(n => !provides(to, n) && !n.startsWith('_OBJC_METACLASS_$_'));
        if (!gone.length) continue;
        const key = `${lib} -> ${to}`;
        const list = e.missing[key] || (e.missing[key] = new Set());
        for (const n of gone) list.add(n.replace(/^_/, ''));
      }
    }
    for (const k of Object.keys(e.missing)) e.missing[k] = [...e.missing[k]].sort();
  }

  fs.writeFileSync(outPath, JSON.stringify(report, null, 1) + '\n');
  let total = 0;
  for (const [engine, e] of Object.entries(report)) {
    const n = Object.values(e.missing).reduce((a, l) => a + l.length, 0);
    total += n;
    console.log(`\n== ${engine}: ${e.binaries} arm64 binaries, ${n} names missing here`);
    for (const c of e.cannotRun) console.log(`  can't run: ${c}`);
    for (const c of e.codegen) console.log(`  compiles code as it runs: ${c}`);
    for (const l of e.luajit) console.log(`  LuaJIT: ${l}`);
    if (e.flatLookups) console.log(`  ${e.flatLookups} imports looked up by name at load (flat namespace)`);
    for (const [k, list] of Object.entries(e.missing)) console.log(`  ${k} (${list.length}): ${list.join(' ')}`);
  }
  console.log(`\n${total} missing names across ${Object.keys(report).length} engines; wrote ${outPath}`);
}

main();
