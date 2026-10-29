#!/usr/bin/env node
// Mach-O import gap analyzer: what a macOS arm64 binary set needs that iOS lacks.
// usage: node machogap.js <client-dir> <out-dir>
'use strict';
const fs = require('fs');
const path = require('path');

const CPU_ARM64 = 0x0100000c;
const CPU_X86_64 = 0x01000007;
const LC = {
  SYMTAB: 0x2, LOAD_DYLIB: 0xc, ID_DYLIB: 0xd, SEGMENT_64: 0x19, LAZY_LOAD_DYLIB: 0x20,
  VERSION_MIN_MACOSX: 0x24, BUILD_VERSION: 0x32, LOAD_WEAK_DYLIB: 0x80000018,
  REEXPORT_DYLIB: 0x8000001f, LOAD_UPWARD_DYLIB: 0x80000023, DYLD_CHAINED_FIXUPS: 0x80000034,
};
const DYLIB_CMDS = new Set([LC.LOAD_DYLIB, LC.LAZY_LOAD_DYLIB, LC.LOAD_WEAK_DYLIB, LC.REEXPORT_DYLIB, LC.LOAD_UPWARD_DYLIB]);
const PLATFORMS = { 1: 'macOS', 2: 'iOS', 3: 'tvOS', 4: 'watchOS', 6: 'macCatalyst', 7: 'iOSSimulator' };

// Framework availability on iOS. 'missing' = must be shimmed, 'private' = present but undocumented,
// 'partial' = present but some macOS APIs absent (checked with MACOS_ONLY_PREFIXES).
const IOS_STATUS = {
  AppKit: 'missing', Cocoa: 'missing', Carbon: 'missing', ApplicationServices: 'missing', Quartz: 'missing',
  OpenGL: 'missing', OpenCL: 'missing', CoreWLAN: 'missing', ServiceManagement: 'missing', IOBluetooth: 'missing',
  ForceFeedback: 'missing', SecurityInterface: 'missing', ScriptingBridge: 'missing', Kerberos: 'missing',
  PreferencePanes: 'missing', OSAKit: 'missing', InputMethodKit: 'missing', DiskArbitration: 'private',
  IOKit: 'private', CoreDisplay: 'private', SkyLight: 'missing', Hypervisor: 'missing', CoreServices: 'partial',
  CoreGraphics: 'partial', CoreAudio: 'partial', AudioToolbox: 'partial', AudioUnit: 'partial', Security: 'partial',
  SystemConfiguration: 'partial', CoreText: 'partial', AVFoundation: 'partial', CoreVideo: 'partial',
  QuartzCore: 'partial', Foundation: 'partial', CoreFoundation: 'partial', LocalAuthentication: 'partial',
  UserNotifications: 'partial', GameController: 'partial', Metal: 'ok', MetalKit: 'ok', IOSurface: 'ok',
  CoreMedia: 'ok', VideoToolbox: 'ok', ImageIO: 'ok', CoreImage: 'ok', Accelerate: 'ok', CFNetwork: 'ok',
  Network: 'ok', CoreHaptics: 'ok', AVFAudio: 'ok', CoreLocation: 'ok', CoreBluetooth: 'ok', CryptoKit: 'ok',
  UniformTypeIdentifiers: 'ok', MediaPlayer: 'ok', WebKit: 'partial', CoreMIDI: 'ok', OpenAL: 'ok',
  LocalAuthenticationEmbeddedUI: 'ok', ColorSync: 'private', CoreML: 'ok', Vision: 'ok', ScreenCaptureKit: 'missing',
  MetalPerformanceShaders: 'ok', libcups: 'missing', OpenDirectory: 'missing', libsandbox: 'private', libbsm: 'missing',
  AuthenticationServices: 'ok', MediaAccessibility: 'ok', ImageCaptureCore: 'ok', Accessibility: 'ok', SafariServices: 'ok',
  CryptoTokenKit: 'ok', ReplayKit: 'ok', CoreAudioTypes: 'ok', AppleScriptObjC: 'missing', Combine: 'ok', SwiftUI: 'ok',
};
// Symbols that exist only on macOS even though the framework exists on iOS.
const MACOS_ONLY_PREFIXES = [
  'CGDisplay', 'CGMainDisplayID', 'CGGetActiveDisplayList', 'CGGetOnlineDisplayList', 'CGGetDisplaysWith',
  'CGEvent', 'CGWindow', 'CGWarpMouse', 'CGAssociateMouse', 'CGSession', 'CGShieldingWindow', 'CGRequestScreenCapture',
  'CGPreflightScreenCapture', 'CGConfigureDisplay', 'CGBeginDisplayConfiguration', 'CGCompleteDisplayConfiguration',
  'CGCancelDisplayConfiguration', 'CGRestorePermanentDisplayConfiguration', 'CGCaptureAllDisplays', 'CGReleaseAllDisplays',
  'CGSetDisplayTransfer', 'CGDirectDisplay', 'CGAcquireDisplayFadeReservation', 'CGDisplayFade', 'CGCursor',
  'CGSSetConnection', 'CGS', 'CGRegisterScreenRefresh', 'CGOpenGLDisplayMaskToDisplayID',
  'AudioObject', 'AudioDevice', 'AudioHardware', 'AudioStream', 'AudioDeviceCreateIOProcID',
  'LSOpen', 'LSCopy', 'LSSet', 'LSRegister', 'LSGetApplication', 'LSFindApplication', 'FSEvent', 'FSPath', 'FSRef', 'FSFind',
  'FSGet', 'FSMake', 'FSCopy', 'MDQuery', 'MDItem', 'AE', 'kAE', 'Icon', 'UTGetOSType', 'UTCreateStringForOSType',
  'SecKeychain', 'SecTrustedApplication', 'SecAccess', 'SecCode', 'SecStaticCode', 'SecRequirement', 'SecTask',
  'SecTransform', 'SecDigest', 'SecSign', 'SecVerify', 'SecEncrypt', 'SecDecrypt', 'SecItemImport', 'SecItemExport',
  'SecKeyGeneratePair', 'Authorization', 'SCDynamicStore', 'SCPreferences', 'SCNetworkInterface', 'SCNetworkService',
  'SCNetworkSet', 'SCNetworkProtocol', 'SCCopyComputerName', 'SCDynamicStoreCopy',
  'CVDisplayLink', 'CTFontManager', 'CGLChoosePixelFormat', 'CGL', 'NSFileTypeForHFSTypeCode',
];
// Valve/Chromium/other bundled code that ships inside the client: tracked but not part of the gap.
const isInternal = p => p.startsWith('@rpath') || p.startsWith('@loader_path') || p.startsWith('@executable_path');

function frameworkOf(p) {
  const m = p.match(/\/([^/]+)\.framework\//);
  if (m) return m[1];
  return path.basename(p).replace(/\.(\d+\.)*dylib$/, '').replace(/\.dylib$/, '');
}

function readCString(buf, off) {
  let end = off;
  while (end < buf.length && buf[end] !== 0) end++;
  return buf.toString('latin1', off, end);
}

function slices(buf) {
  const magicBE = buf.readUInt32BE(0);
  if (magicBE === 0xcafebabe || magicBE === 0xcafebabf) {
    const is64 = magicBE === 0xcafebabf;
    const n = buf.readUInt32BE(4);
    if (n > 30) return []; // Java class files share 0xcafebabe
    const out = [];
    for (let i = 0; i < n; i++) {
      const b = 8 + i * (is64 ? 32 : 20);
      const cpu = buf.readUInt32BE(b);
      const off = is64 ? Number(buf.readBigUInt64BE(b + 8)) : buf.readUInt32BE(b + 8);
      const size = is64 ? Number(buf.readBigUInt64BE(b + 16)) : buf.readUInt32BE(b + 12);
      out.push({ cpu, buf: buf.subarray(off, off + size) });
    }
    return out;
  }
  if (buf.readUInt32LE(0) === 0xfeedfacf) return [{ cpu: buf.readUInt32LE(4), buf }];
  return [];
}

const archName = c => (c === CPU_ARM64 ? 'arm64' : c === CPU_X86_64 ? 'x86_64' : '0x' + c.toString(16));

function parseSlice(b) {
  const ncmds = b.readUInt32LE(16);
  const filetype = b.readUInt32LE(12);
  let off = 32;
  const r = { filetype, dylibs: [], platform: null, minos: null, imports: [], selectors: 0, id: null };
  let symtab = null, chained = null;
  for (let i = 0; i < ncmds; i++) {
    const cmd = b.readUInt32LE(off), size = b.readUInt32LE(off + 4);
    if (DYLIB_CMDS.has(cmd)) {
      r.dylibs.push({ path: readCString(b, off + b.readUInt32LE(off + 8)), weak: cmd === LC.LOAD_WEAK_DYLIB });
    } else if (cmd === LC.ID_DYLIB) {
      r.id = readCString(b, off + b.readUInt32LE(off + 8));
    } else if (cmd === LC.BUILD_VERSION) {
      r.platform = PLATFORMS[b.readUInt32LE(off + 8)] || String(b.readUInt32LE(off + 8));
      const v = b.readUInt32LE(off + 12);
      r.minos = `${v >>> 16}.${(v >> 8) & 0xff}`;
    } else if (cmd === LC.VERSION_MIN_MACOSX) {
      r.platform = 'macOS';
      const v = b.readUInt32LE(off + 8);
      r.minos = `${v >>> 16}.${(v >> 8) & 0xff}`;
    } else if (cmd === LC.SYMTAB) {
      symtab = { symoff: b.readUInt32LE(off + 8), nsyms: b.readUInt32LE(off + 12), stroff: b.readUInt32LE(off + 16) };
    } else if (cmd === LC.DYLD_CHAINED_FIXUPS) {
      chained = { off: b.readUInt32LE(off + 8), size: b.readUInt32LE(off + 12) };
    } else if (cmd === LC.SEGMENT_64) {
      const nsects = b.readUInt32LE(off + 64);
      for (let s = 0; s < nsects; s++) {
        const so = off + 72 + s * 80;
        const sect = readCString(b.subarray(so, so + 16), 0);
        if (sect === '__objc_methname') {
          const fo = b.readUInt32LE(so + 48), sz = Number(b.readBigUInt64LE(so + 40));
          let n = 0;
          for (let k = fo; k < fo + sz; k++) if (b[k] === 0) n++;
          r.selectors = n;
          r.selectorBlob = [fo, sz];
        }
      }
    }
    off += size;
  }

  // An import is weak (binds to NULL when missing) only if every reference to it is weak.
  const seen = new Map();
  const add = (ord, name, weak) => {
    const key = ord + '\0' + name;
    const had = seen.get(key);
    if (had) { if (!weak) had.weak = false; return; }
    const imp = { ord, name, weak: !!weak };
    seen.set(key, imp);
    r.imports.push(imp);
  };
  if (symtab) {
    for (let i = 0; i < symtab.nsyms; i++) {
      const e = symtab.symoff + i * 16;
      const type = b[e + 4];
      if ((type & 0xe0) !== 0) continue; // stab
      if ((type & 0x0e) !== 0 || !(type & 0x01)) continue; // not undefined external
      const desc = b.readUInt16LE(e + 6);
      add((desc >> 8) & 0xff, readCString(b, symtab.stroff + b.readUInt32LE(e)), desc & 0x40);
    }
  }
  if (chained) {
    const h = chained.off;
    const importsOff = h + b.readUInt32LE(h + 8), symsOff = h + b.readUInt32LE(h + 12);
    const count = b.readUInt32LE(h + 16), fmt = b.readUInt32LE(h + 20);
    for (let i = 0; i < count; i++) {
      let ord, nameOff, weak;
      if (fmt === 1 || fmt === 2) {
        const v = b.readUInt32LE(importsOff + i * (fmt === 1 ? 4 : 8));
        ord = v & 0xff; weak = (v >>> 8) & 1; nameOff = v >>> 9;
      } else if (fmt === 3) {
        const v = b.readBigUInt64LE(importsOff + i * 16);
        ord = Number(v & 0xffffn); weak = Number((v >> 16n) & 1n); nameOff = Number(v >> 32n);
        if (ord === 0xffff || ord === 0xfffe || ord === 0xfffd) ord = ord & 0xff;
      } else break;
      add(ord, readCString(b, symsOff + nameOff), weak);
    }
  }
  return r;
}

function libFor(r, ord) {
  if (ord === 0) return '(self)';
  if (ord === 0xff) return '(main executable)';
  if (ord === 0xfe) return '(flat lookup)';
  if (ord === 0xfd) return '(weak lookup)';
  return r.dylibs[ord - 1] ? r.dylibs[ord - 1].path : `(ordinal ${ord})`;
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
  const [root, outDir] = process.argv.slice(2);
  if (!root || !outDir) { console.error('usage: node machogap.js <client-dir> <out-dir>'); process.exit(2); }
  fs.mkdirSync(outDir, { recursive: true });

  const binaries = [];
  for (const file of walk(root)) {
    const fd = fs.openSync(file, 'r');
    const head = Buffer.alloc(8);
    const got = fs.readSync(fd, head, 0, 8, 0);
    fs.closeSync(fd);
    if (got < 8) continue;
    const m = head.readUInt32BE(0);
    if (m !== 0xcafebabe && m !== 0xcafebabf && head.readUInt32LE(0) !== 0xfeedfacf) continue;
    const sl = slices(fs.readFileSync(file));
    if (!sl.length) continue;
    const arm = sl.find(s => s.cpu === CPU_ARM64);
    const rel = path.relative(root, file).split(path.sep).join('/');
    const entry = { file: rel, archs: sl.map(s => archName(s.cpu)), size: fs.statSync(file).size };
    if (arm) Object.assign(entry, parseSlice(arm.buf));
    binaries.push(entry);
  }

  // Aggregate external imports by framework.
  const fw = {};
  const selectors = new Set();
  for (const bin of binaries) {
    if (!bin.imports) continue;
    if (bin.selectorBlob) {
      const sl = slices(fs.readFileSync(path.join(root, bin.file))).find(s => s.cpu === CPU_ARM64).buf;
      const [fo, sz] = bin.selectorBlob;
      for (const s of sl.toString('latin1', fo, fo + sz).split('\0')) if (s) selectors.add(s);
      delete bin.selectorBlob;
    }
    for (const imp of bin.imports) {
      const lib = libFor(bin, imp.ord);
      if (lib.startsWith('(') || isInternal(lib)) continue;
      const name = frameworkOf(lib);
      const f = (fw[name] ||= { lib, status: IOS_STATUS[name] || (lib.startsWith('/usr/lib/') ? 'ok' : 'unknown'), symbols: {}, users: new Set() });
      (f.symbols[imp.name] ||= new Set()).add(bin.file);
      f.users.add(bin.file);
    }
  }

  const strip = s => s.replace(/^_/, '').replace(/^OBJC_(CLASS|METACLASS|EHTYPE)_\$_/, '');
  const rows = Object.entries(fw).map(([name, f]) => {
    const syms = Object.keys(f.symbols).sort();
    const macOnly = f.status === 'partial' ? syms.filter(s => MACOS_ONLY_PREFIXES.some(p => strip(s).startsWith(p))) : [];
    const classes = syms.filter(s => s.includes('OBJC_CLASS_$_')).map(strip);
    return { name, lib: f.lib, status: f.status, symbolCount: syms.length, gap: f.status === 'missing' ? syms.length : macOnly.length,
      classes, macOnly, symbols: syms, users: [...f.users].sort() };
  }).sort((a, b) => b.gap - a.gap || b.symbolCount - a.symbolCount);

  const json = {
    root, binaries: binaries.map(b => ({ ...b, imports: undefined, importCount: b.imports ? b.imports.length : 0 })),
    frameworks: rows, selectorCount: selectors.size,
  };
  fs.writeFileSync(path.join(outDir, 'gap.json'), JSON.stringify(json, null, 1));
  fs.writeFileSync(path.join(outDir, 'selectors.txt'), [...selectors].sort().join('\n'));
  for (const r of rows.filter(r => r.gap > 0)) {
    const list = r.status === 'missing' ? r.symbols : r.macOnly;
    fs.writeFileSync(path.join(outDir, `gap-${r.name}.txt`),
      list.map(s => `${s}\t${[...fw[r.name].symbols[s]].join(', ')}`).join('\n'));
  }

  // Console summary.
  const total = rows.reduce((n, r) => n + r.gap, 0);
  console.log(`Mach-O files: ${binaries.length}  (arm64: ${binaries.filter(b => b.archs.includes('arm64')).length}, x86_64-only: ${binaries.filter(b => !b.archs.includes('arm64')).length})`);
  const plats = {};
  for (const b of binaries) if (b.platform) plats[`${b.platform} ${b.minos}`] = (plats[`${b.platform} ${b.minos}`] || 0) + 1;
  console.log('Platforms (arm64 slices):', JSON.stringify(plats));
  console.log(`Distinct ObjC selectors used: ${selectors.size}`);
  console.log(`\nSystem libraries, sorted by gap (symbols iOS lacks):`);
  console.log('status   gap   imported  framework (used by N binaries)');
  for (const r of rows) console.log(`${r.status.padEnd(8)} ${String(r.gap).padStart(5)} ${String(r.symbolCount).padStart(9)}  ${r.name} (${r.users.length})`);
  console.log(`\nTOTAL GAP: ${total} symbols`);
}

if (require.main === module) main();
module.exports = { slices, parseSlice, libFor, readCString, frameworkOf, isInternal, archName, CPU_ARM64, LC };
