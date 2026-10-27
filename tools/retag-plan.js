#!/usr/bin/env node
// Retarget plan: for every Mach-O the iOS app must ship, work out the Mach-O surgery
// needed to run it on iOS. This is the analysis half of the IPA pipeline; it runs on
// any OS (pure parsing). The execution half (package-ipa.sh) consumes plan.json on the
// Mac runner and drives Apple's own lipo / vtool / install_name_tool.
//
//   node tools/retag-plan.js <client-dir> <out.json> [routes.json]
//
// For each binary it records:
//   thin      - has an x86_64 slice that must be dropped (iOS is arm64-only)
//   retag     - arm64 slice is tagged macOS and must become iOS (vtool -set-build-version)
//   repoint[] - LC_LOAD_DYLIB entries to rewrite (install_name_tool -change from to). With
//               routes.json (lib-routes.js, built from the iOS SDK) that is every system
//               library: to the shim or to its shallow iOS path. Without it, only frameworks
//               iOS lacks entirely go to the shim (the pre-SDK fallback).
//   id        - LC_ID_DYLIB install name (dylibs only), used to wire @rpath references
//   missingSystem[] - dylib deps on iOS-missing frameworks with NO shim coverage (a gap)
'use strict';
const fs = require('fs');
const path = require('path');
const mg = require('./machogap.js');
const { slices, parseSlice, frameworkOf, isInternal, archName, CPU_ARM64 } = mg;

// Frameworks iOS does not provide at all: every load command pointing here must be
// repointed to the shim, which re-exports their macOS symbol names. Kept in sync with
// machogap.js's IOS_STATUS 'missing' set plus the /usr/lib shims the client needs.
const MISSING_FRAMEWORKS = new Set([
  'AppKit', 'Cocoa', 'Carbon', 'ApplicationServices', 'Quartz', 'OpenGL', 'OpenCL',
  'CoreWLAN', 'ServiceManagement', 'IOBluetooth', 'ForceFeedback', 'SecurityInterface',
  'ScriptingBridge', 'Kerberos', 'PreferencePanes', 'OSAKit', 'InputMethodKit', 'SkyLight',
  'Hypervisor', 'ScreenCaptureKit', 'OpenDirectory', 'AppleScriptObjC',
  'libcups', 'cups', 'libbsm',
]);
// /usr/lib install names that map to a missing framework (cups prints as libcups.2).
const MISSING_LIB_RE = /\/lib(cups|bsm)[.\d]*\.dylib$/;

// The shim install name every repointed load command will be changed to. The shim dylib
// ships in the app's Frameworks dir and re-exports all the macOS names (src builds it with
// asm labels). @rpath resolves against the app's LC_RPATH (added by the packager).
const SHIM_INSTALL = '@rpath/AppKitShim.framework/AppKitShim';

function isMissing(p) {
  if (isInternal(p)) return false;            // bundled Valve/CEF code, resolved in-app
  if (!p.startsWith('/')) return false;        // relative / already rewritten
  const fw = frameworkOf(p);
  return MISSING_FRAMEWORKS.has(fw) || MISSING_LIB_RE.test(p);
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
  const [root, outFile, routesFile] = process.argv.slice(2);
  if (!root || !outFile) { console.error('usage: node retag-plan.js <client-dir> <out.json> [routes.json]'); process.exit(2); }
  const routes = routesFile ? JSON.parse(fs.readFileSync(routesFile, 'utf8')).routes : null;

  const plan = [];
  let x86only = 0;
  const repointFw = {};   // framework -> count of load commands repointed
  const gaps = {};        // missing framework with no shim coverage -> binaries

  for (const file of walk(root)) {
    const fd = fs.openSync(file, 'r');
    const head = Buffer.alloc(8);
    const got = fs.readSync(fd, head, 0, 8, 0);
    fs.closeSync(fd);
    if (got < 8) continue;
    const m = head.readUInt32BE(0);
    if (m !== 0xcafebabe && m !== 0xcafebabf && head.readUInt32LE(0) !== 0xfeedfacf) continue;

    const buf = fs.readFileSync(file);
    const sl = slices(buf);
    if (!sl.length) continue;
    const arm = sl.find(s => s.cpu === CPU_ARM64);
    const rel = path.relative(root, file).split(path.sep).join('/');
    const archs = sl.map(s => archName(s.cpu));

    if (!arm) { x86only++; plan.push({ file: rel, archs, drop: true, reason: 'x86_64-only, no arm64 slice' }); continue; }

    const r = parseSlice(arm.buf);
    const repoint = [];
    for (const d of r.dylibs) {
      let to = null;
      if (routes) {
        const route = routes[d.path];
        if (route && route.to !== d.path) to = route.to;
      } else if (isMissing(d.path)) {
        to = SHIM_INSTALL;
      }
      if (!to) continue;
      repoint.push({ from: d.path, to, framework: frameworkOf(d.path), weak: d.weak });
      repointFw[frameworkOf(d.path)] = (repointFw[frameworkOf(d.path)] || 0) + 1;
    }
    const entry = {
      file: rel,
      archs,
      kind: r.filetype === 2 ? 'executable' : r.filetype === 6 ? 'dylib' : r.filetype === 8 ? 'bundle' : String(r.filetype),
      platform: r.platform,
      thin: archs.includes('x86_64'),
      retag: r.platform === 'macOS',
      repoint,
    };
    if (r.id) entry.id = r.id;
    plan.push(entry);
  }

  const out = {
    root,
    shimInstallName: SHIM_INSTALL,
    counts: {
      binaries: plan.length,
      drop: plan.filter(p => p.drop).length,
      thin: plan.filter(p => p.thin).length,
      retag: plan.filter(p => p.retag).length,
      repointLoadCommands: Object.values(repointFw).reduce((a, b) => a + b, 0),
    },
    repointByFramework: repointFw,
    binaries: plan.sort((a, b) => (b.repoint ? b.repoint.length : 0) - (a.repoint ? a.repoint.length : 0)),
  };
  fs.writeFileSync(outFile, JSON.stringify(out, null, 1));

  console.log(`Binaries: ${out.counts.binaries}  drop(x86-only): ${out.counts.drop}  thin(fat): ${out.counts.thin}  retag(macOS->iOS): ${out.counts.retag}`);
  console.log(`Load commands to rewrite${routes ? ' (shim or iOS path)' : ' to the shim'}: ${out.counts.repointLoadCommands}`);
  console.log('By framework:', JSON.stringify(out.repointByFramework));
  console.log(`\nTop consumers of missing frameworks:`);
  for (const b of out.binaries.filter(b => b.repoint && b.repoint.length).slice(0, 15)) {
    console.log(`  ${String(b.repoint.length).padStart(2)}  ${b.file}  [${[...new Set(b.repoint.map(r => r.framework))].join(', ')}]`);
  }
  console.log(`\nwrote ${outFile}`);
}

if (require.main === module) main();
