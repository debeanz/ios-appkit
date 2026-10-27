#!/usr/bin/env node
// Static dyld check over the finished app: does every library a bundled dylib loads exist
// where dyld will look for it? Catches a missing package or a broken path in CI, instead of
// a "Library not loaded" on the device (Breakpad was found missing that way).
//
//   node tools/check-deps.js <Steam.app>
//
// Checks dylibs and bundles — what gets loaded — not executables: iOS won't launch the Mac
// helper programs. @loader_path is the image's own directory and @rpath is tried against
// the image's LC_RPATHs, as dyld does. @executable_path is checked against the app root
// but also listed, since under LiveContainer it points at LiveContainer instead. System
// paths are routed by lib-routes.js and left to it. Exits 1 if anything is missing.
'use strict';
const fs = require('fs');
const path = require('path');
const mg = require('./machogap.js');

const LC_RPATH = 0x8000001c;
const MH_EXECUTE = 2;

function rpaths(b) {
  const out = [];
  const ncmds = b.readUInt32LE(16);
  let off = 32;
  for (let i = 0; i < ncmds; i++) {
    const cmd = b.readUInt32LE(off), size = b.readUInt32LE(off + 4);
    if (cmd === LC_RPATH) out.push(mg.readCString(b, off + b.readUInt32LE(off + 8)));
    off += size;
  }
  return out;
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isSymbolicLink()) continue;
    if (e.isDirectory()) walk(p, out);
    else if (e.isFile()) out.push(p);
  }
  return out;
}

function main() {
  const app = process.argv[2];
  if (!app) { console.error('usage: node tools/check-deps.js <Steam.app>'); process.exit(2); }
  const missing = [], viaExecutable = [];
  let images = 0, deps = 0;
  for (const f of walk(app)) {
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
    if (r.filetype === MH_EXECUTE) continue;
    images++;
    const dir = path.dirname(f);
    const expand = s => s.replace(/^@loader_path/, dir).replace(/^@executable_path/, app);
    const rel = path.relative(app, f).split(path.sep).join('/');
    for (const d of r.dylibs) {
      if (d.weak || !d.path.startsWith('@')) continue;
      deps++;
      let ok;
      if (d.path.startsWith('@rpath/')) {
        const tail = d.path.slice('@rpath/'.length);
        ok = rpaths(arm.buf).some(rp => fs.existsSync(path.join(expand(rp), tail)));
      } else {
        if (d.path.startsWith('@executable_path')) viaExecutable.push(`${rel}: ${d.path}`);
        ok = fs.existsSync(expand(d.path));
      }
      if (!ok) missing.push(`${rel}: ${d.path}`);
    }
  }
  console.log(`checked ${deps} bundled dependencies of ${images} loadable images`);
  if (viaExecutable.length) {
    console.log(`relying on @executable_path (wrong under LiveContainer):`);
    for (const v of viaExecutable) console.log(`  ${v}`);
  }
  if (missing.length) {
    console.log(`MISSING (${missing.length}):`);
    for (const x of missing) console.log(`  ${x}`);
    process.exit(1);
  }
  console.log('every bundled dependency resolves');
}

main();
