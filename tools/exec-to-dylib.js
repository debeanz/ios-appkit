#!/usr/bin/env node
// Convert a thin arm64 Mach-O program into a loadable library, so the iOS app can run it in
// process rather than as a child process (iOS can't launch one; see src/InProcessExec.m).
// This is the same adjustment LiveContainer makes to the app programs it hosts.
//
//   node tools/exec-to-dylib.js <thin-arm64-macho>
//
// Edits, in place (everything is checked first; the file is only written if all of it works):
//   - header type MH_EXECUTE -> MH_DYLIB, and the position-independent flag cleared (a
//     library is always relocatable);
//   - __PAGEZERO (the 4 GB guard region a program maps at address 0) shrunk to one page just
//     below __TEXT, so loading it doesn't try to reserve 4 GB of address space. It keeps its
//     slot in the segment order: fixup and rebase tables address segments by index;
//   - the dynamic-linker-path command, which only a program has, rewritten in place as a
//     harmless LC_RPATH "@loader_path" of the same size (so nothing after it moves);
//   - an LC_ID_DYLIB (the identity every library needs) appended in the header's spare space.
// The entry-point command (LC_MAIN) stays: the shim reads it to find the program's main().
'use strict';
const fs = require('fs');

const MH_MAGIC_64 = 0xfeedfacf;
const MH_EXECUTE = 2, MH_DYLIB = 6;
const MH_PIE = 0x200000;
const LC_SEGMENT_64 = 0x19, LC_ID_DYLIB = 0xd, LC_LOAD_DYLINKER = 0xe, LC_RPATH = 0x8000001c;
const ONE_PAGE = 0x4000n;

function fail(msg) { console.error(`exec-to-dylib: ${msg}`); process.exit(1); }
const align8 = n => (n + 7) & ~7;

function main() {
  const file = process.argv[2];
  if (!file) fail('usage: node tools/exec-to-dylib.js <thin-arm64-macho>');
  const b = fs.readFileSync(file);
  if (b.length < 32 || b.readUInt32LE(0) !== MH_MAGIC_64) fail(`${file}: not a thin 64-bit Mach-O (lipo -thin arm64 first)`);
  const filetype = b.readUInt32LE(12);
  if (filetype === MH_DYLIB) { console.log(`exec-to-dylib: ${file} is already a library`); return; }
  if (filetype !== MH_EXECUTE) fail(`${file}: header type ${filetype}, expected a program (2)`);
  const ncmds = b.readUInt32LE(16), sizeofcmds = b.readUInt32LE(20);

  // Survey: __TEXT address, __PAGEZERO and dylinker command positions, first section offset.
  let off = 32, textVmaddr = null, pageZeroOff = null, dylinkerOff = null, dylinkerSize = 0;
  let firstSectionOff = Infinity, hasId = false;
  for (let i = 0; i < ncmds; i++) {
    if (off + 8 > b.length) fail(`${file}: load commands run past the file`);
    const cmd = b.readUInt32LE(off), size = b.readUInt32LE(off + 4);
    if (size < 8 || off + size > 32 + sizeofcmds) fail(`${file}: malformed load command ${i}`);
    if (cmd === LC_SEGMENT_64) {
      const seg = b.toString('latin1', off + 8, off + 24).replace(/\0.*$/, '');
      if (seg === '__TEXT') textVmaddr = b.readBigUInt64LE(off + 24);
      if (seg === '__PAGEZERO') pageZeroOff = off;
      const nsects = b.readUInt32LE(off + 64);
      for (let s = 0; s < nsects; s++) {
        const so = off + 72 + s * 80;
        const secOff = b.readUInt32LE(so + 48), secSize = b.readBigUInt64LE(so + 40);
        if (secOff && secSize > 0n) firstSectionOff = Math.min(firstSectionOff, secOff);
      }
    } else if (cmd === LC_LOAD_DYLINKER) {
      dylinkerOff = off; dylinkerSize = size;
    } else if (cmd === LC_ID_DYLIB) {
      hasId = true;
    }
    off += size;
  }
  if (textVmaddr === null) fail(`${file}: no __TEXT segment`);
  if (dylinkerOff === null) fail(`${file}: no dynamic-linker command (not a dynamically linked program?)`);
  const rpathStr = Buffer.from('@loader_path\0', 'utf8');
  if (12 + rpathStr.length > dylinkerSize) fail(`${file}: dynamic-linker command too small (${dylinkerSize} bytes)`);

  // The identity command to append.
  const name = '@rpath/' + file.split(/[\\/]/).pop();
  const nameBytes = Buffer.from(name + '\0', 'utf8');
  const idSize = align8(24 + nameBytes.length);
  const end = 32 + sizeofcmds;
  if (!hasId && end + idSize > firstSectionOff) fail(`${file}: no room for an id command (${firstSectionOff - end} bytes spare, need ${idSize})`);
  for (let i = end; i < end + idSize; i++) if (b[i] !== 0) fail(`${file}: header padding isn't empty`);

  // Edit.
  b.writeUInt32LE(MH_DYLIB, 12);
  b.writeUInt32LE(b.readUInt32LE(24) & ~MH_PIE, 24);

  if (pageZeroOff !== null) {
    b.writeBigUInt64LE(textVmaddr >= ONE_PAGE ? textVmaddr - ONE_PAGE : 0n, pageZeroOff + 24);   // vmaddr
    b.writeBigUInt64LE(ONE_PAGE, pageZeroOff + 32);                                               // vmsize
  } else {
    console.error(`exec-to-dylib: ${file}: note — no __PAGEZERO`);
  }

  b.fill(0, dylinkerOff, dylinkerOff + dylinkerSize);
  b.writeUInt32LE(LC_RPATH, dylinkerOff);
  b.writeUInt32LE(dylinkerSize, dylinkerOff + 4);
  b.writeUInt32LE(12, dylinkerOff + 8);            // path offset within the command
  rpathStr.copy(b, dylinkerOff + 12);

  if (!hasId) {
    b.writeUInt32LE(LC_ID_DYLIB, end);
    b.writeUInt32LE(idSize, end + 4);
    b.writeUInt32LE(24, end + 8);                  // name offset
    b.writeUInt32LE(0, end + 12);                  // timestamp
    b.writeUInt32LE(0x10000, end + 16);            // current version 1.0.0
    b.writeUInt32LE(0x10000, end + 20);            // compatibility version 1.0.0
    nameBytes.copy(b, end + 24);
    b.writeUInt32LE(ncmds + 1, 16);
    b.writeUInt32LE(sizeofcmds + idSize, 20);
  }

  fs.writeFileSync(file, b);
  console.log(`exec-to-dylib: ${file} is now a loadable library (${name})`);
}

main();
