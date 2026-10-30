// Mac programs Steam starts: its games.
//
// Steam downloads a game's Mac build and starts it with -[NSWorkspace launchApplicationAtURL:
// options:configuration:error:]. iOS starts no second process, so the game runs in this one,
// the way Steam Helper does (InProcessExec.m): its program is loaded as a library and its
// main() runs on a thread of its own, with a stand-in pid Steam can watch. It runs from a copy
// of its .app (the download itself must stay as Steam installed it: see "The game's converted
// copy"), in which every Mach-O gets the edits the IPA build gives Steam's own binaries
// (tools/package-ipa.sh, exec-to-dylib.js), here on the device because the game only arrives
// here:
//   - the arm64 code alone (an Intel-only game can't run: iOS has no x86 translation);
//   - platform macOS relabelled iOS (LC_BUILD_VERSION / LC_VERSION_MIN);
//   - each system library it links routed as the client's are (client/routes.json from the
//     build; a library Steam doesn't use goes to iOS's own copy if there is one, else to the
//     shim), @executable_path made @loader_path-relative (in this process it would mean
//     Steam's program);
//   - the program made a library (exec-to-dylib: MH_DYLIB, a one-page __PAGEZERO, the
//     dynamic-linker command become an rpath, an id), keeping LC_MAIN for its main();
//   - signed again, with LiveContainer's own signer and the certificate imported into it, as
//     LiveContainer signs the apps it installs (since iOS 26 it runs apps only that way, its
//     JIT-less mode: JIT no longer lets unsigned code load).
// A file already done is left alone, so a game is converted and signed once per download (and
// signed again if the certificate changes). Before it loads, everything it imports that isn't
// here yet is logged at once.
// While the game runs, NSBundle's and CoreFoundation's main bundle and _NSGetExecutablePath
// are the game's when the game asks, its main thread gets an app delegate and event loop of
// its own (NSApplication.m), and its windows go above Steam's interface (NSWindow.m).
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <limits.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <sys/stat.h>
#import "AKShimPrivate.h"
#import "AppKitShim/LibSystemMac.h"
#import "SteamIPC.h"
#import <signal.h>

#ifndef PLATFORM_IOS
#define PLATFORM_IOS 2
#endif
static const uint32_t kMinOS = 0x000F0000;   // iOS 15.0
static const uint32_t kSDK = 0x00120000;     // iOS 18.0

static void gameLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void gameLog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[AppKitShim] game: %s\n", line.UTF8String);
}

#pragma mark Where things are

// This framework's folder: <app>/Frameworks/AppKitShimCore.framework/AppKitShimCore.
static NSString *shimCorePath(void) {
  Dl_info info;
  return dladdr((const void *)&shimCorePath, &info) && info.dli_fname ? @(info.dli_fname) : nil;
}

// The app's Frameworks folder, and the umbrella Steam's binaries link there, by the install
// name they use (found through an rpath to that folder).
static NSString *const kShimName = @"@rpath/AppKitShim.framework/AppKitShim";

static NSString *frameworksDir(void) {
  return shimCorePath().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
}

// `to` from folder `fromDir`, as a relative path (for @loader_path), so a game folder that
// moves keeps working.
static NSString *relativePath(NSString *fromDir, NSString *to) {
  NSArray<NSString *> *a = fromDir.stringByStandardizingPath.pathComponents, *b = to.stringByStandardizingPath.pathComponents;
  NSUInteger common = 0;
  while (common < a.count && common < b.count && [a[common] isEqualToString:b[common]]) common++;
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSUInteger i = common; i < a.count; i++) [parts addObject:@".."];
  [parts addObjectsFromArray:[b subarrayWithRange:NSMakeRange(common, b.count - common)]];
  return parts.count ? [parts componentsJoinedByString:@"/"] : @".";
}

// @executable_path meant the game's program; in this process it would mean Steam's.
static NSString *fromExecutablePath(NSString *name, NSString *programDir, NSString *fileDir) {
  NSString *rest = [name substringFromIndex:@"@executable_path".length];
  NSString *target = [programDir stringByAppendingString:rest].stringByStandardizingPath;
  return [@"@loader_path/" stringByAppendingString:relativePath(fileDir, target)];
}

// The build's routes for the client's system libraries: {macOS path: {action, to}}; and the
// iOS libraries the shim's umbrella re-exports whole.
static NSSet<NSString *> *gShimForwards;

static NSDictionary<NSString *, NSDictionary *> *clientRoutes(void) {
  static NSDictionary *routes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *app = shimCorePath().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSData *json = [NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"client/routes.json"]];
    NSDictionary *all = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    routes = [all[@"routes"] isKindOfClass:NSDictionary.class] ? all[@"routes"] : @{};
    gShimForwards = [all[@"reexports"] isKindOfClass:NSArray.class] ? [NSSet setWithArray:all[@"reexports"]] : [NSSet set];
    if (!routes.count) gameLog(@"no client/routes.json in the app; system libraries are routed by rule only");
  });
  return routes;
}

static NSSet<NSString *> *shimForwards(void) {
  clientRoutes();
  return gShimForwards;
}

// Where a game binary's library reference should point here. A name already routed comes
// back unchanged, so converting again is harmless.
static NSString *const kOpenGLName = @"@rpath/AKOpenGL.framework/AKOpenGL";

static NSString *routeLibrary(NSString *name, NSString *programDir, NSString *fileDir) {
  if ([name hasPrefix:@"@executable_path/"]) return fromExecutablePath(name, programDir, fileDir);
  // OpenGL, and the libGL and libGLU inside it: Mesa's OpenGL (Zink on MoltenVK) through
  // AKOpenGL.framework, which re-exports Mesa and adds CGL, GLU and Apple's extensions.
  static BOOL haveOpenGL;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    haveOpenGL = [NSFileManager.defaultManager fileExistsAtPath:[frameworksDir() stringByAppendingPathComponent:@"AKOpenGL.framework/AKOpenGL"]];
  });
  if (haveOpenGL && [name hasPrefix:@"/System/Library/Frameworks/OpenGL.framework/"]) return kOpenGLName;
  NSDictionary *route = clientRoutes()[name];
  if ([route[@"to"] isKindOfClass:NSString.class]) return route[@"to"];
  if (![name hasPrefix:@"/System/Library/"] && ![name hasPrefix:@"/usr/lib/"]) return name;   // @loader_path, @rpath, the game's own
  // A system library the client doesn't use: iOS's own at its shallow path if iOS has it.
  NSString *shallow = name;
  NSRange versions = [name rangeOfString:@".framework/Versions/"];
  if (versions.location != NSNotFound) {
    NSString *framework = [name substringToIndex:versions.location + @".framework".length];
    shallow = [framework stringByAppendingPathComponent:framework.lastPathComponent.stringByDeletingPathExtension];
  }
  if (dlopen_preflight(shallow.fileSystemRepresentation)) return shallow;
  return kShimName;
}

#pragma mark Converting a binary

static uint32_t align8(uint32_t n) { return (n + 7) & ~7u; }

static NSData *stringCommand(uint32_t cmd, uint32_t headerSize, NSData *header, NSString *string) {
  NSData *bytes = [string dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t size = align8(headerSize + (uint32_t)bytes.length + 1);
  NSMutableData *c = [NSMutableData dataWithLength:size];
  if (header) memcpy(c.mutableBytes, header.bytes, MIN(header.length, headerSize));
  ((struct load_command *)c.mutableBytes)->cmd = cmd;
  ((struct load_command *)c.mutableBytes)->cmdsize = size;
  memcpy((uint8_t *)c.mutableBytes + headerSize, bytes.bytes, bytes.length);
  return c;
}

// The arm64 code of a Mach-O file (thin or universal), or nil with a reason.
static NSData *arm64Code(NSData *file, NSString **why) {
  const uint8_t *p = file.bytes;
  if (file.length < sizeof(struct mach_header_64)) { *why = @"too small"; return nil; }
  uint32_t magic = *(const uint32_t *)p;
  if (magic == MH_MAGIC_64) {
    const struct mach_header_64 *mh = (const void *)p;
    if (mh->cputype == CPU_TYPE_ARM64) return file;
    *why = mh->cputype == CPU_TYPE_X86_64 ? @"Intel only" : @"not arm64";
    return nil;
  }
  if (magic != FAT_CIGAM && magic != FAT_CIGAM_64) { *why = @"not a Mach-O"; return nil; }
  BOOL wide = magic == FAT_CIGAM_64;
  uint32_t count = OSSwapBigToHostInt32(((const struct fat_header *)p)->nfat_arch);
  BOOL intel = NO, arm64e = NO;
  for (uint32_t i = 0; i < count; i++) {
    uint64_t offset, size;
    cpu_type_t type;
    cpu_subtype_t subtype;
    if (wide) {
      const struct fat_arch_64 *a = (const void *)(p + sizeof(struct fat_header) + i * sizeof(struct fat_arch_64));
      if ((const uint8_t *)(a + 1) > p + file.length) break;
      type = (cpu_type_t)OSSwapBigToHostInt32(a->cputype); subtype = (cpu_subtype_t)OSSwapBigToHostInt32(a->cpusubtype);
      offset = OSSwapBigToHostInt64(a->offset); size = OSSwapBigToHostInt64(a->size);
    } else {
      const struct fat_arch *a = (const void *)(p + sizeof(struct fat_header) + i * sizeof(struct fat_arch));
      if ((const uint8_t *)(a + 1) > p + file.length) break;
      type = (cpu_type_t)OSSwapBigToHostInt32(a->cputype); subtype = (cpu_subtype_t)OSSwapBigToHostInt32(a->cpusubtype);
      offset = OSSwapBigToHostInt32(a->offset); size = OSSwapBigToHostInt32(a->size);
    }
    if (type == CPU_TYPE_X86_64) intel = YES;
    if (type != CPU_TYPE_ARM64) continue;
    // arm64e code (pointer authentication) can't load into this arm64 process.
    if ((subtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E) { arm64e = YES; continue; }
    if (offset + size > file.length) { *why = @"truncated"; return nil; }
    return [file subdataWithRange:NSMakeRange((NSUInteger)offset, (NSUInteger)size)];
  }
  *why = arm64e ? @"arm64e only" : intel ? @"Intel only" : @"no arm64 code";
  return nil;
}

// The names (without their leading underscore) a binary imports from each library it links,
// in load-command order as two-level ordinals count them; nil when its symbol table can't tell.
// Weak imports are left out: one that's missing binds to NULL and the binary still loads.
static NSArray<NSArray<NSString *> *> *importsByLibrary(NSData *code) {
  const struct mach_header_64 *mh = code.bytes;
  if (!(mh->flags & MH_TWOLEVEL)) return nil;
  const uint8_t *cmds = (const uint8_t *)(mh + 1);
  const struct symtab_command *symtab = NULL;
  NSUInteger libs = 0;
  uint32_t off = 0;
  for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    if (!lc->cmdsize || off + lc->cmdsize > mh->sizeofcmds) return nil;
    switch (lc->cmd) {
      case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_LOAD_UPWARD_DYLIB:
        libs++;
        break;
      case LC_SYMTAB:
        symtab = (const void *)lc;
        break;
    }
    off += lc->cmdsize;
  }
  if (!symtab || symtab->symoff + (uint64_t)symtab->nsyms * sizeof(struct nlist_64) > code.length ||
      (uint64_t)symtab->stroff + symtab->strsize > code.length) return nil;
  const struct nlist_64 *syms = (const void *)((const uint8_t *)code.bytes + symtab->symoff);
  const char *strs = (const char *)code.bytes + symtab->stroff;
  NSMutableArray<NSMutableArray<NSString *> *> *byLibrary = [NSMutableArray array];
  for (NSUInteger i = 0; i < libs; i++) [byLibrary addObject:[NSMutableArray array]];
  for (uint32_t i = 0; i < symtab->nsyms; i++) {
    const struct nlist_64 *s = &syms[i];
    if ((s->n_type & N_TYPE) != N_UNDF || !(s->n_type & N_EXT) || s->n_value || (s->n_desc & N_WEAK_REF)) continue;
    uint32_t ordinal = GET_LIBRARY_ORDINAL(s->n_desc);
    if (ordinal < 1 || ordinal > libs || s->n_un.n_strx >= symtab->strsize) continue;
    const char *name = strs + s->n_un.n_strx;
    if (*name != '_') continue;
    NSString *shown = [NSString stringWithUTF8String:name + 1];
    if (shown) [byLibrary[ordinal - 1] addObject:shown];
  }
  return byLibrary;
}

// An iOS library a binary imports macOS-only names from goes through the shim instead, which
// adds them, when the shim's umbrella re-exports the rest of that library whole (AVFoundation's
// Mac capture presets in Unity's player). `file`, when given, is logged as the one that needed it.
static NSString *throughShimIfLacking(NSString *lib, NSArray<NSString *> *names, NSString *file) {
  if (!names.count || ![shimForwards() containsObject:lib]) return lib;
  void *ios = dlopen(lib.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
  if (!ios) return lib;
  for (NSString *name in names) {
    if (dlsym(ios, name.UTF8String)) continue;
    if (file) gameLog(@"  %@: its %@ goes through the shim, for %@ (macOS only)", file.lastPathComponent, lib.lastPathComponent, name);
    return kShimName;
  }
  return lib;
}

// UnityPlayer.dylib defines operator new and delete (Unity's memory manager) and exports them.
// dyld then binds every image loaded after it that refers to operator new (GameAssembly's code
// among them) to Unity's, while iOS's libc++ in the shared cache keeps the system delete: a
// std::string grown inside libc++ frees Unity's memory with free(), "pointer being freed was not
// allocated" in il2cpp_init (found running Tunic's Mac build, debeanz/tunic-ios-port). Renaming
// the four in its export trie, one letter of the edge that completes each name (__Znwm becomes
// __ZnWm, its nothrow and sized variants with it), makes every image use the system's. Same
// length: nothing moves. Returns how many are (with `write`, were) renamed.
static const char *const kOperatorNewDelete[] = { "__Znwm", "__Znam", "__ZdlPv", "__ZdaPv" };

static BOOL readUleb(const uint8_t *p, const uint8_t *end, uint64_t *value, const uint8_t **next) {
  uint64_t v = 0;
  unsigned shift = 0;
  while (p < end) {
    uint8_t b = *p++;
    if (shift < 64) v |= (uint64_t)(b & 0x7f) << shift;
    shift += 7;
    if (!(b & 0x80)) { *value = v; *next = p; return YES; }
  }
  return NO;
}

static int hideInTrie(const uint8_t *trie, size_t size, uint8_t *write, uint64_t node, char *name, size_t length, int depth) {
  if (depth > 64 || node >= size) return 0;
  const uint8_t *p = trie + node, *end = trie + size;
  uint64_t terminal, child;
  if (!readUleb(p, end, &terminal, &p) || terminal >= (uint64_t)(end - p)) return 0;
  p += terminal;
  int children = *p++, hidden = 0;
  for (int i = 0; i < children && p < end; i++) {
    const uint8_t *label = p;
    size_t n = strnlen((const char *)label, (size_t)(end - label));
    if (label + n >= end || !readUleb(label + n + 1, end, &child, &p)) return hidden;
    if (length + n >= 256) continue;
    memcpy(name + length, label, n);
    name[length + n] = 0;
    BOOL completes = NO, leadsOn = NO;
    for (size_t k = 0; k < sizeof kOperatorNewDelete / sizeof kOperatorNewDelete[0]; k++) {
      const char *t = kOperatorNewDelete[k];
      size_t tl = strlen(t);
      if (length >= tl || strncmp(name, t, length)) continue;   // not on its path
      if (length + n >= tl) completes |= !strncmp(name, t, tl);
      else leadsOn |= !strncmp(name, t, length + n);
    }
    if (completes) {
      if (write) write[label - trie] = islower(label[0]) ? (uint8_t)toupper(label[0]) : '!';
      hidden++;
    } else if (leadsOn) {
      hidden += hideInTrie(trie, size, write, child, name, length + n, depth + 1);
    }
  }
  return hidden;
}

static int hideOperatorNewDelete(const uint8_t *code, size_t size, uint8_t *write) {
  const struct mach_header_64 *mh = (const void *)code;
  const uint8_t *cmds = (const uint8_t *)(mh + 1);
  uint32_t off = 0, trieOff = 0, trieSize = 0;
  for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    if (!lc->cmdsize) break;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
      trieOff = ((const struct dyld_info_command *)lc)->export_off;
      trieSize = ((const struct dyld_info_command *)lc)->export_size;
    } else if (lc->cmd == LC_DYLD_EXPORTS_TRIE) {
      trieOff = ((const struct linkedit_data_command *)lc)->dataoff;
      trieSize = ((const struct linkedit_data_command *)lc)->datasize;
    }
    off += lc->cmdsize;
  }
  if (!trieSize || (uint64_t)trieOff + trieSize > size) return 0;
  char name[256] = "";
  return hideInTrie(code + trieOff, trieSize, write ? write + trieOff : NULL, 0, name, 0, 0);
}

// Beside a game's converted copy: a link to the app's Frameworks folder, for binaries whose
// header has no room for that folder's full path (see convertFile).
static NSString *const kShimLink = @".shim";

// Converts one file in place: done again on every launch, which changes nothing once a file is
// converted except the rpath to the app's Frameworks folder, kept current in case the app
// moved. Returns nil when it is ready (*changed says whether it was written), else why it
// can't be.
static NSString *convertFile(NSString *path, NSString *programDir, NSString *bundlePath, BOOL isProgram, BOOL *changed) {
  *changed = NO;
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (!file) return @"can't read it";
  NSString *why = nil;
  NSData *code = arm64Code(file, &why);
  if (!code) return why;
  const struct mach_header_64 *mh = code.bytes;
  if (mh->sizeofcmds > code.length - sizeof *mh) return @"bad load commands";
  BOOL thin = code == file;
  BOOL exec = mh->filetype == MH_EXECUTE;
  if (exec && !isProgram) return @"a helper program, not run here";
  NSString *fileDir = path.stringByDeletingLastPathComponent;
  NSString *frameworks = frameworksDir();

  const uint8_t *cmds = (const uint8_t *)(mh + 1);
  uint64_t firstSection = code.length, textVM = 0;
  BOOL hasId = NO, iOS = NO, macOS = NO;
  uint32_t off = 0;
  for (uint32_t i = 0; i < mh->ncmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    if (off + sizeof *lc > mh->sizeofcmds || lc->cmdsize < sizeof *lc || off + lc->cmdsize > mh->sizeofcmds) return @"bad load command";
    if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *seg = (const void *)lc;
      if (!strncmp(seg->segname, "__TEXT", 16)) textVM = seg->vmaddr;
      const struct section_64 *sect = (const void *)(seg + 1);
      for (uint32_t s = 0; s < seg->nsects; s++)
        if (sect[s].offset && sect[s].size) firstSection = MIN(firstSection, sect[s].offset);
    } else if (lc->cmd == LC_BUILD_VERSION) {
      uint32_t platform = ((const struct build_version_command *)lc)->platform;
      iOS = platform == PLATFORM_IOS;
      macOS = platform == PLATFORM_MACOS;
    } else if (lc->cmd == LC_VERSION_MIN_MACOSX) {
      macOS = YES;
    } else if (lc->cmd == LC_VERSION_MIN_IPHONEOS) {
      iOS = YES;
    } else if (lc->cmd == LC_ID_DYLIB) {
      hasId = YES;
    }
    off += lc->cmdsize;
  }
  if (!macOS && !iOS) return @"no platform label";

  NSArray<NSArray<NSString *> *> *imports = importsByLibrary(code);
  NSString *home = bundlePath.stringByDeletingLastPathComponent;
  struct rpath_command rpathHeader = { LC_RPATH, 0, { sizeof(struct rpath_command) } };
  NSData *rpathHeaderData = [NSData dataWithBytes:&rpathHeader length:sizeof rpathHeader];
  // A header too full for what's added makes room by levels. 1: the load commands only tools
  // read go (source version, data-in-code and function-start tables, signing requirements,
  // linker hints), and the Frameworks folder is reached through the short link beside the copy
  // (kShimLink) instead of its full path. 2, for a library rather than the program: no rpath
  // of its own at all; dyld also searches the rpaths of the images that load it.
  NSMutableData *out;
  uint32_t ncmds;
  int squeeze = 0;
  for (;; squeeze++) {
    out = [NSMutableData data];
    ncmds = 0;
    NSUInteger dylibs = 0;
    off = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
      const struct load_command *lc = (const void *)(cmds + off);
      NSData *original = [NSData dataWithBytes:lc length:lc->cmdsize];
      off += lc->cmdsize;
      switch (lc->cmd) {
        // LC_CODE_SIGNATURE stays: the edits void the signature, and the signer replaces it.
        case LC_SOURCE_VERSION: case LC_DATA_IN_CODE: case LC_FUNCTION_STARTS: case LC_DYLIB_CODE_SIGN_DRS:
        case LC_LINKER_OPTIMIZATION_HINT:
          if (squeeze) continue;
          [out appendData:original];
          break;
        case LC_BUILD_VERSION: {
          NSMutableData *c = [original mutableCopy];
          struct build_version_command *bv = c.mutableBytes;
          if (bv->platform != PLATFORM_IOS) {
            bv->platform = PLATFORM_IOS;
            bv->minos = kMinOS;
            bv->sdk = kSDK;
          }
          [out appendData:c];
          break;
        }
        case LC_VERSION_MIN_MACOSX: {
          NSMutableData *c = [original mutableCopy];
          struct version_min_command *v = c.mutableBytes;
          v->cmd = LC_VERSION_MIN_IPHONEOS;
          v->version = kMinOS;
          v->sdk = kSDK;
          [out appendData:c];
          break;
        }
        case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_LOAD_UPWARD_DYLIB: {
          const struct dylib_command *d = (const void *)lc;
          if (d->dylib.name.offset >= lc->cmdsize) return @"bad library command";
          NSString *name = @((const char *)lc + d->dylib.name.offset);
          NSString *to = routeLibrary(name, programDir, fileDir);
          if (dylibs < imports.count) to = throughShimIfLacking(to, imports[dylibs], squeeze ? nil : path);
          dylibs++;
          if ([to isEqualToString:name]) { [out appendData:original]; break; }
          struct dylib_command header = *d;
          header.dylib.name.offset = sizeof header;
          [out appendData:stringCommand(lc->cmd, sizeof header, [NSData dataWithBytes:&header length:sizeof header], to)];
          break;
        }
        case LC_RPATH: {
          const struct rpath_command *r = (const void *)lc;
          if (r->path.offset >= lc->cmdsize) return @"bad rpath command";
          NSString *rpath = @((const char *)lc + r->path.offset);
          // The rpath to the app's Frameworks folder from an earlier conversion: added afresh below.
          if ([rpath hasPrefix:@"/"] && [rpath hasSuffix:@"/Frameworks"] && ![rpath hasPrefix:bundlePath]) continue;
          if ([rpath hasPrefix:@"@loader_path/"] && [rpath.lastPathComponent isEqualToString:kShimLink]) continue;
          if ([rpath hasPrefix:@"@executable_path"]) {
            [out appendData:stringCommand(LC_RPATH, sizeof rpathHeader, rpathHeaderData, fromExecutablePath(rpath, programDir, fileDir))];
            break;
          }
          [out appendData:original];
          break;
        }
        case LC_LOAD_DYLINKER: {
          if (!exec) { [out appendData:original]; break; }
          [out appendData:stringCommand(LC_RPATH, sizeof rpathHeader, rpathHeaderData, @"@loader_path")];
          break;
        }
        case LC_SEGMENT_64: {
          const struct segment_command_64 *seg = (const void *)lc;
          if (exec && !strncmp(seg->segname, "__PAGEZERO", 16)) {
            // A library can't reserve the 4 GB at address 0: one page just below __TEXT, in its slot.
            NSMutableData *c = [original mutableCopy];
            struct segment_command_64 *z = c.mutableBytes;
            z->vmaddr = textVM >= 0x4000 ? textVM - 0x4000 : 0;
            z->vmsize = 0x4000;
            [out appendData:c];
            break;
          }
          [out appendData:original];
          break;
        }
        default:
          [out appendData:original];
      }
      ncmds++;
    }
    // How the shim (and what it re-exports) is found: by the app's Frameworks folder.
    if (squeeze < 2) {
      NSString *rpath = squeeze ? [@"@loader_path/" stringByAppendingString:relativePath(fileDir, [home stringByAppendingPathComponent:kShimLink])]
                                : frameworks;
      [out appendData:stringCommand(LC_RPATH, sizeof rpathHeader, rpathHeaderData, rpath)];
      ncmds++;
    }
    if (exec && !hasId) {
      struct dylib_command header = { LC_ID_DYLIB, 0, { { sizeof(struct dylib_command) }, 0, 0x10000, 0x10000 } };
      [out appendData:stringCommand(LC_ID_DYLIB, sizeof header, [NSData dataWithBytes:&header length:sizeof header], path)];
      ncmds++;
    }
    if (sizeof *mh + out.length <= firstSection) break;
    if (squeeze == (exec ? 1 : 2))
      return [NSString stringWithFormat:@"no room in its header (%llu bytes free, %lu needed)",
              firstSection - sizeof *mh, (unsigned long)out.length];
  }
  int operators = [path.lastPathComponent isEqualToString:@"UnityPlayer.dylib"] ? hideOperatorNewDelete(code.bytes, code.length, NULL) : 0;
  // Already as it should be: left alone.
  if (thin && !exec && !operators && mh->ncmds == ncmds && mh->sizeofcmds == out.length && !memcmp(cmds, out.bytes, out.length)) return nil;

  NSMutableData *m = [code mutableCopy];
  if (operators) hideOperatorNewDelete(m.bytes, m.length, m.mutableBytes);
  struct mach_header_64 *w = m.mutableBytes;
  memset((uint8_t *)(w + 1), 0, MAX(w->sizeofcmds, (uint32_t)out.length));
  memcpy((uint8_t *)(w + 1), out.bytes, out.length);
  w->ncmds = ncmds;
  w->sizeofcmds = (uint32_t)out.length;
  if (exec) {
    w->filetype = MH_DYLIB;
    w->flags &= ~MH_PIE;
  }
  NSError *error;
  if (![m writeToFile:path options:NSDataWritingAtomic error:&error]) return error.localizedDescription;
  *changed = YES;
  if (operators)
    gameLog(@"  %@: its own operator new and delete hidden (%d exports): every library uses the system's", path.lastPathComponent, operators);
  if (squeeze)
    gameLog(@"  %@: its header was nearly full; it made room by %@", path.lastPathComponent,
            squeeze == 1 ? @"leaving out what only tools read and reaching the app's Frameworks through a short link"
                         : @"also finding the app's Frameworks through what loads it");
  return nil;
}

#pragma mark Converting a game

static BOOL isMachO(NSString *path) {
  FILE *f = fopen(path.fileSystemRepresentation, "rb");
  if (!f) return NO;
  uint32_t magic = 0;
  BOOL yes = fread(&magic, 4, 1, f) == 1 && (magic == MH_MAGIC_64 || magic == FAT_CIGAM || magic == FAT_CIGAM_64);
  fclose(f);
  return yes;
}

#pragma mark The game's converted copy

static NSString *sha256Hex(NSData *data);

// Steam's own checks must keep seeing the game exactly as it was downloaded: before a launch it
// verifies the signature Valve embeds in some games' universal binaries (the app's
// "signaturescheckedonlaunch" files; an edited file fails with "Corrupt file signature"), and
// validation flags any changed file. So the download is never touched. The game runs from a
// copy of its .app in which every Mach-O is a converted, signed copy and everything else is a
// symlink to the original (a folder with no code in it is one symlink). Each launch brings the
// copy up to date: files Steam updated are copied again, files it removed go.
static NSString *convertedGamesRoot(void) {
  NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  return [support stringByAppendingPathComponent:@"Steam games for iOS"];
}

static NSString *const kManifest = @"manifest.plist";   // next to the copy: {source, files: {rel: "size mtime"}}

// A thin binary already labelled iOS: converted.
static BOOL labelledIOS(NSString *path) {
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  const struct mach_header_64 *mh = file.bytes;
  if (file.length < sizeof *mh || mh->magic != MH_MAGIC_64 || mh->sizeofcmds > file.length - sizeof *mh) return NO;
  const uint8_t *lc = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0, off = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *c = (const void *)(lc + off);
    if (!c->cmdsize) break;
    if (c->cmd == LC_VERSION_MIN_IPHONEOS) return YES;
    if (c->cmd == LC_BUILD_VERSION) return ((const struct build_version_command *)c)->platform == PLATFORM_IOS;
    off += c->cmdsize;
  }
  return NO;
}

// A binary has no extension, or one of these; anything else isn't opened to look.
static BOOL mayBeMachO(NSString *path) {
  NSString *ext = path.pathExtension.lowercaseString;
  return (!ext.length || [@[ @"dylib", @"so", @"bundle", @"plugin" ] containsObject:ext]) && isMachO(path);
}

static NSString *fileStamp(NSDictionary *attributes) {
  return [NSString stringWithFormat:@"%llu %.0f", [attributes[NSFileSize] unsignedLongLongValue],
          [attributes[NSFileModificationDate] timeIntervalSince1970]];
}

// `dst` made a symlink to `target` (whatever was there goes).
static BOOL linkTo(NSString *dst, NSString *target) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *now = [fm destinationOfSymbolicLinkAtPath:dst error:nil];
  if ([now isEqualToString:target]) return YES;
  [fm removeItemAtPath:dst error:nil];
  return [fm createSymbolicLinkAtPath:dst withDestinationPath:target error:nil];
}

typedef struct {
  NSSet<NSString *> *code;           // relative paths of the Mach-O files
  NSSet<NSString *> *codeDirs;       // and of every folder holding one
  NSMutableDictionary *oldFiles, *newFiles;
  unsigned copied;
} ak_mirror;

static NSString *mirrorDir(NSString *src, NSString *dst, NSString *rel, ak_mirror *m) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSError *error;
  NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:src error:&error];
  if (!entries) return error.localizedDescription;
  NSSet *wanted = [NSSet setWithArray:entries];
  for (NSString *gone in [fm contentsOfDirectoryAtPath:dst error:nil])
    if (![wanted containsObject:gone]) [fm removeItemAtPath:[dst stringByAppendingPathComponent:gone] error:nil];
  for (NSString *name in entries) {
    NSString *s = [src stringByAppendingPathComponent:name], *d = [dst stringByAppendingPathComponent:name];
    NSString *r = rel.length ? [rel stringByAppendingPathComponent:name] : name;
    NSDictionary *attributes = [fm attributesOfItemAtPath:s error:nil];
    NSString *type = attributes[NSFileType];
    if ([type isEqualToString:NSFileTypeSymbolicLink]) {
      // Frameworks' Versions/Current and the like: the same (relative) link.
      NSString *target = [fm destinationOfSymbolicLinkAtPath:s error:nil];
      if (target && !linkTo(d, target)) return [NSString stringWithFormat:@"can't link %@", r];
    } else if ([type isEqualToString:NSFileTypeDirectory]) {
      if ([m->codeDirs containsObject:r]) {
        NSDictionary *have = [fm attributesOfItemAtPath:d error:nil];
        if (have && ![have[NSFileType] isEqualToString:NSFileTypeDirectory]) [fm removeItemAtPath:d error:nil];
        if (![fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:&error]) return error.localizedDescription;
        NSString *why = mirrorDir(s, d, r, m);
        if (why) return why;
      } else if (!linkTo(d, s)) {
        return [NSString stringWithFormat:@"can't link %@", r];
      }
    } else if ([m->code containsObject:r]) {
      NSString *stamp = fileStamp(attributes);
      NSDictionary *have = [fm attributesOfItemAtPath:d error:nil];
      if (![m->oldFiles[r] isEqualToString:stamp] || ![have[NSFileType] isEqualToString:NSFileTypeRegular]) {
        [fm removeItemAtPath:d error:nil];
        if (![fm copyItemAtPath:s toPath:d error:&error]) return error.localizedDescription;
        m->copied++;
      }
      m->newFiles[r] = stamp;
    } else if (!linkTo(d, s)) {
      return [NSString stringWithFormat:@"can't link %@", r];
    }
  }
  return nil;
}

// The game's copy brought up to date; nil with *copy set, else why not.
static NSString *mirrorApp(NSString *source, NSString **copy) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *key = [sha256Hex([source dataUsingEncoding:NSUTF8StringEncoding]) substringToIndex:16];
  NSString *home = [convertedGamesRoot() stringByAppendingPathComponent:key];
  NSString *dst = [home stringByAppendingPathComponent:source.lastPathComponent];
  NSString *manifestPath = [home stringByAppendingPathComponent:kManifest];

  // Which files are code (and so copied), found by a walk over the download.
  NSMutableSet *code = [NSMutableSet set], *codeDirs = [NSMutableSet set];
  NSDirectoryEnumerator *walk = [fm enumeratorAtPath:source];
  for (NSString *rel in walk) {
    if (![walk.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    if (!mayBeMachO([source stringByAppendingPathComponent:rel])) continue;
    [code addObject:rel];
    for (NSString *dir = rel.stringByDeletingLastPathComponent; dir.length; dir = dir.stringByDeletingLastPathComponent)
      [codeDirs addObject:dir];
  }
  NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfFile:manifestPath];
  ak_mirror m = { code, codeDirs, [manifest[@"files"] mutableCopy] ?: [NSMutableDictionary dictionary], [NSMutableDictionary dictionary], 0 };
  NSError *error;
  if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&error]) return error.localizedDescription;
  NSString *why = mirrorDir(source, dst, @"", &m);
  if (why) return why;
  [@{ @"source": source, @"files": m.newFiles } writeToFile:manifestPath atomically:YES];
  gameLog(@"its converted copy: %@ (%lu code files, %u copied fresh from the download)", dst, (unsigned long)code.count, m.copied);
  *copy = dst;
  return nil;
}

// Copies of games no longer installed (their download is gone) are removed.
static void removeOrphanCopies(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *root = convertedGamesRoot();
  for (NSString *key in [fm contentsOfDirectoryAtPath:root error:nil]) {
    NSString *home = [root stringByAppendingPathComponent:key];
    NSString *source = [NSDictionary dictionaryWithContentsOfFile:[home stringByAppendingPathComponent:kManifest]][@"source"];
    if ([source isKindOfClass:NSString.class] && ![fm fileExistsAtPath:source]) {
      gameLog(@"removing the converted copy of %@ (no longer installed)", source.lastPathComponent);
      [fm removeItemAtPath:home error:nil];
    }
  }
}

#pragma mark Signing

// LiveContainer runs this app, and since iOS 26 only in its JIT-less mode: every binary signed
// with the certificate imported into it (from SideStore/AltStore), which it does itself for
// the apps it installs and their tweaks. A game's binaries are converted here after install,
// so they are signed the same way: LiveContainer's signer (ZSign.dylib, class ZSigner) with its
// certificate, both found in this process. The certificate's hash is kept next to the game's
// copy, so a new certificate (they're renewed) means signing everything again.
static NSString *const kSignedStamp = @"signed-with";

static NSString *sha256Hex(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hex = [NSMutableString string];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  return hex;
}

// LiveContainer's shared settings (its +[NSUserDefaults lcSharedDefaults]), where it keeps the
// certificate and its password.
static NSUserDefaults *liveContainerDefaults(void) {
  SEL sel = NSSelectorFromString(@"lcSharedDefaults");
  if (![NSUserDefaults respondsToSelector:sel]) return nil;
  id defaults = ((id (*)(id, SEL))objc_msgSend)(NSUserDefaults.class, sel);
  return [defaults isKindOfClass:NSUserDefaults.class] ? defaults : nil;
}

// LiveContainer's own bundle: its signer is in Frameworks there.
static NSBundle *liveContainerBundle(void) {
  Class shared = NSClassFromString(@"LCSharedUtils");
  return shared ? [NSBundle bundleForClass:shared] : nil;
}

// ZSign.dylib links @rpath/OpenSSL.framework/OpenSSL, found through @executable_path/Frameworks,
// which in a guest of LiveContainer is this app's folder, not LiveContainer's. So
// LiveContainer's OpenSSL is loaded first, by its full path: dyld then matches the reference
// by install name. If that isn't enough, a link to it is put where ZSign looks, only while
// ZSign loads.
static NSString *gSignerApp;   // the LiveContainer .app whose Frameworks hold the signer

static Class zSigner(void) {
  Class signer = NSClassFromString(@"ZSigner");
  if (signer) return signer;
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *lc = liveContainerBundle().bundlePath;
  if (!lc) return Nil;
  for (NSString *rel in @[ @"Frameworks", @"../../Frameworks" ]) {
    NSString *dir = [lc stringByAppendingPathComponent:rel].stringByStandardizingPath;
    NSString *zsign = [dir stringByAppendingPathComponent:@"ZSign.dylib"];
    if (![fm fileExistsAtPath:zsign]) continue;
    gSignerApp = dir.stringByDeletingLastPathComponent;
    NSString *openssl = [dir stringByAppendingPathComponent:@"OpenSSL.framework"];
    NSString *opensslBinary = [openssl stringByAppendingPathComponent:@"OpenSSL"];
    if ([fm fileExistsAtPath:opensslBinary] && !dlopen(opensslBinary.fileSystemRepresentation, RTLD_GLOBAL))
      gameLog(@"LiveContainer's OpenSSL doesn't load: %s", dlerror());
    if (!dlopen(zsign.fileSystemRepresentation, RTLD_GLOBAL)) {
      gameLog(@"LiveContainer's signer doesn't load: %s", dlerror());
      NSString *link = [frameworksDir() stringByAppendingPathComponent:@"OpenSSL.framework"];
      if (![fm fileExistsAtPath:link] && [fm createSymbolicLinkAtPath:link withDestinationPath:openssl error:nil]) {
        if (dlopen(zsign.fileSystemRepresentation, RTLD_GLOBAL)) gameLog(@"LiveContainer's signer loaded through a link to its OpenSSL");
        else gameLog(@"LiveContainer's signer still doesn't load: %s", dlerror());
        [fm removeItemAtPath:link error:nil];
      }
    }
    if ((signer = NSClassFromString(@"ZSigner"))) return signer;
  }
  return Nil;
}

// Signs the files; nil when done (or when there's nothing to sign with), else why not.
static NSString *signFiles(NSArray<NSString *> *paths, NSData *certificate, NSString *password) {
  Class signer = zSigner();
  SEL sel = NSSelectorFromString(@"signMachOPathArr:bundleId:cert:pass:completionHandler:");
  if (!signer || ![signer respondsToSelector:sel]) return @"LiveContainer's signer couldn't be loaded (the lines above say why)";
  // The identifier LiveContainer signs its apps with: its own bundle ID, read from its
  // Info.plist (in a guest, NSBundle may answer with the guest's).
  NSString *bundleId = [NSDictionary dictionaryWithContentsOfFile:[gSignerApp stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
  if (![bundleId isKindOfClass:NSString.class]) bundleId = liveContainerBundle().bundleIdentifier ?: @"com.kdt.livecontainer";
  static dispatch_once_t once;
  dispatch_once(&once, ^{ gameLog(@"signing as %@", bundleId); });
  __block BOOL ok = NO;
  __block NSString *failure;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  void (^finished)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
    ok = success;
    failure = error.localizedDescription;
    dispatch_semaphore_signal(done);
  };
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  ((id (*)(id, SEL, NSArray *, NSString *, NSData *, NSString *, void (^)(BOOL, NSError *)))objc_msgSend)(
      signer, sel, paths, bundleId, certificate, password ?: @"", finished);
  // It reports on the main queue: the main thread keeps turning while it waits.
  if (NSThread.isMainThread) {
    while (dispatch_semaphore_wait(done, DISPATCH_TIME_NOW) != 0) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
  } else {
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  }
  gameLog(@"signed %lu binaries with LiveContainer's certificate in %.1fs: %@", (unsigned long)paths.count,
          CFAbsoluteTimeGetCurrent() - start, ok ? @"ok" : failure ?: @"failed");
  return ok ? nil : (failure ?: @"signing failed");
}

// The same settings read from their file in LiveContainer's app group, in case the defaults
// object can't be had (LiveContainer points a guest's own preferences at the guest's folder).
static NSDictionary *liveContainerSettingsFile(void) {
  Class shared = NSClassFromString(@"LCSharedUtils");
  SEL pathSel = NSSelectorFromString(@"appGroupPath"), idSel = NSSelectorFromString(@"appGroupID");
  if (![shared respondsToSelector:pathSel] || ![shared respondsToSelector:idSel]) return nil;
  NSURL *group = ((id (*)(id, SEL))objc_msgSend)(shared, pathSel);
  NSString *groupID = ((id (*)(id, SEL))objc_msgSend)(shared, idSel);
  if (![group isKindOfClass:NSURL.class] || ![groupID isKindOfClass:NSString.class]) return nil;
  NSString *plist = [NSString stringWithFormat:@"Library/Preferences/%@.plist", groupID];
  return [NSDictionary dictionaryWithContentsOfURL:[group URLByAppendingPathComponent:plist]];
}

// The certificate imported into LiveContainer (and its password), or nil: no JIT-less mode.
static NSData *liveContainerCertificate(NSString **password) {
  NSUserDefaults *lc = liveContainerDefaults();
  NSData *certificate = [lc objectForKey:@"LCCertificateData"];
  NSString *pass = [lc objectForKey:@"LCCertificatePassword"];
  if (![certificate isKindOfClass:NSData.class] || !certificate.length) {
    NSDictionary *file = liveContainerSettingsFile();
    certificate = file[@"LCCertificateData"];
    pass = file[@"LCCertificatePassword"];
  }
  if (password) *password = [pass isKindOfClass:NSString.class] ? pass : nil;
  return [certificate isKindOfClass:NSData.class] && certificate.length ? certificate : nil;
}

static NSString *signApp(NSBundle *app, NSArray<NSString *> *ready, NSArray<NSString *> *changed) {
  NSString *password;
  NSData *certificate = liveContainerCertificate(&password);
  if (!certificate) {
    // No JIT-less certificate: LiveContainer is running on JIT (before iOS 26), which lets
    // unsigned code load.
    gameLog(@"no certificate in LiveContainer%@: not signing, loading relies on JIT",
            liveContainerDefaults() ? @"" : @" (not running in LiveContainer?)");
    return nil;
  }
  NSString *stampPath = [app.bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:kSignedStamp];
  NSString *stamp = [NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil];
  NSString *hash = sha256Hex(certificate);
  NSArray<NSString *> *toSign = [stamp isEqualToString:hash] ? changed : ready;
  if (!toSign.count) return nil;
  NSString *why = signFiles(toSign, certificate, password);
  if (why) return why;
  [hash writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  return nil;
}

#pragma mark Checking a signature

static uint32_t be32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return OSSwapBigToHostInt32(v); }
static uint64_t be64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return OSSwapBigToHostInt64(v); }

// A thin Mach-O's LC_CODE_SIGNATURE (offset and size of its signature), or NO.
static BOOL signatureRange(const uint8_t *file, size_t length, uint32_t *offset, uint32_t *size) {
  const struct mach_header_64 *mh = (const void *)file;
  if (length < sizeof *mh || mh->magic != MH_MAGIC_64 || mh->sizeofcmds > length - sizeof *mh) return NO;
  const uint8_t *lc = file + sizeof *mh;
  for (uint32_t i = 0, off = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *c = (const void *)(lc + off);
    if (!c->cmdsize) break;
    if (c->cmd == LC_CODE_SIGNATURE) {
      const struct linkedit_data_command *cs = (const void *)c;
      *offset = cs->dataoff;
      *size = cs->datasize;
      return (uint64_t)cs->dataoff + cs->datasize <= length;
    }
    off += c->cmdsize;
  }
  return NO;
}

// What the kernel says of a binary's signature: the two checks dyld makes when it loads it
// (and LiveContainer makes after it signs), with iOS's own words when library validation
// refuses it. nil when it's accepted.
static NSString *kernelVerdict(NSString *path) {
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  uint32_t offset = 0, size = 0;
  if (!signatureRange(file.bytes, file.length, &offset, &size)) return @"no code signature found in it";
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) return [NSString stringWithFormat:@"can't open it (%s)", strerror(errno)];
  NSString *verdict = nil;
  fsignatures_t sig;
  memset(&sig, 0, sizeof sig);
  sig.fs_file_start = 0;
  sig.fs_blob_start = (void *)(uintptr_t)offset;
  sig.fs_blob_size = size;
  if (fcntl(fd, F_ADDFILESIGS_RETURN, &sig) == -1) {
    verdict = [NSString stringWithFormat:@"the kernel refuses its signature (%s)", strerror(errno)];
  } else {
    char message[512] = "";
    fchecklv_t lv;
    memset(&lv, 0, sizeof lv);
    lv.lv_file_start = 0;
    lv.lv_error_message_size = sizeof message;
    lv.lv_error_message = message;
    if (fcntl(fd, F_CHECK_LV, &lv) != 0)
      verdict = [NSString stringWithFormat:@"library validation refuses it: %s", message[0] ? message : strerror(errno)];
  }
  close(fd);
  return verdict;
}

// The signature's parts: each code directory's version, flags, hash type, identifier, team,
// code limit and executable segment, and the size of the CMS signature.
static NSString *describeSignature(NSString *path) {
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  uint32_t offset = 0, size = 0;
  if (!signatureRange(file.bytes, file.length, &offset, &size)) return @"none";
  const uint8_t *sb = (const uint8_t *)file.bytes + offset;
  if (size < 12 || be32(sb) != 0xfade0cc0) return @"not a signature superblob";
  uint32_t count = be32(sb + 8);
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (uint32_t i = 0; i < count && 12 + 8 * (i + 1) <= size; i++) {
    uint32_t type = be32(sb + 12 + 8 * i), at = be32(sb + 16 + 8 * i);
    if ((uint64_t)at + 8 > size) continue;
    const uint8_t *b = sb + at;
    uint32_t magic = be32(b), length = be32(b + 4);
    if ((uint64_t)at + length > size) continue;
    if (magic == 0xfade0c02 && length >= 44) {
      uint32_t version = be32(b + 8), flags = be32(b + 12), identAt = be32(b + 20), limit = be32(b + 32);
      NSString *ident = identAt < length ? [NSString stringWithUTF8String:(const char *)b + identAt] : nil;
      NSString *team = @"none";
      if (version >= 0x20200 && length >= 52) {
        uint32_t teamAt = be32(b + 48);
        if (teamAt && teamAt < length) team = [NSString stringWithUTF8String:(const char *)b + teamAt] ?: @"?";
      }
      uint64_t execLimit = 0, execFlags = 0;
      if (version >= 0x20400 && length >= 88) { execLimit = be64(b + 72); execFlags = be64(b + 80); }
      [parts addObject:[NSString stringWithFormat:@"code directory (slot %#x) v%#x flags %#x hash type %u id %@ team %@ "
                        @"limit %#x exec segment %#llx flags %#llx", type, version, flags, b[37], ident ?: @"?", team, limit,
                        execLimit, execFlags]];
    } else if (magic == 0xfade0b01) {
      [parts addObject:[NSString stringWithFormat:@"CMS %u bytes", length]];
    } else if (magic == 0xfade7171 || magic == 0xfade7172) {
      [parts addObject:[NSString stringWithFormat:@"entitlements %u bytes", length]];
    }
  }
  return [parts componentsJoinedByString:@"; "];
}

// When iOS refuses a signed game: one of Steam's own libraries, which LiveContainer signed and
// which loads, signed again here the way the game was. Whether iOS takes that tells this
// signing apart from what the conversion did to the game.
static void probeSigning(NSString *home) {
  NSString *reference = [frameworksDir().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"client/libogg.0.dylib"];
  gameLog(@"  for comparison, Steam's %@ as LiveContainer signed it: %@", reference.lastPathComponent, describeSignature(reference));
  NSString *password;
  NSData *certificate = liveContainerCertificate(&password);
  NSString *probe = [home stringByAppendingPathComponent:@"signing-probe.dylib"];
  NSFileManager *fm = NSFileManager.defaultManager;
  [fm removeItemAtPath:probe error:nil];
  if (!certificate || ![fm copyItemAtPath:reference toPath:probe error:nil]) return;
  NSString *why = signFiles(@[ probe ], certificate, password);
  gameLog(@"  the same library signed here: %@; %@", why ?: (kernelVerdict(probe) ?: @"iOS accepts it"), describeSignature(probe));
  [fm removeItemAtPath:probe error:nil];
}

// Every Mach-O in the app converted and signed; nil when the program can run, else why not.
static NSString *convertApp(NSBundle *app, NSString *program) {
  NSString *programDir = program.stringByDeletingLastPathComponent;
  linkTo([app.bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:kShimLink], frameworksDir());
  NSMutableArray<NSString *> *ready = [NSMutableArray array], *changedFiles = [NSMutableArray array];
  unsigned skipped = 0;
  BOOL changed;
  NSString *why = convertFile(program, programDir, app.bundlePath, YES, &changed);
  if (why) return [NSString stringWithFormat:@"its program can't run here: %@", why];
  [ready addObject:program];
  if (changed) [changedFiles addObject:program];
  NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtPath:app.bundlePath];
  for (NSString *rel in walk) {
    if (![walk.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
    NSString *path = [app.bundlePath stringByAppendingPathComponent:rel];
    if ([path isEqualToString:program] || !isMachO(path)) continue;
    why = convertFile(path, programDir, app.bundlePath, NO, &changed);
    if (why) {
      // A plug-in or helper that can't load (Intel only, say) only matters if the game loads it.
      if (++skipped <= 20) gameLog(@"  left out %@: %@", rel, why);
      continue;
    }
    [ready addObject:path];
    if (changed) [changedFiles addObject:path];
  }
  gameLog(@"%@: %lu binaries converted for iOS, %lu already were, %u left out", app.bundlePath.lastPathComponent,
          (unsigned long)changedFiles.count, (unsigned long)(ready.count - changedFiles.count), skipped);
  why = signApp(app, ready, changedFiles);
  return why ? [NSString stringWithFormat:@"couldn't sign it: %@", why] : nil;
}

#pragma mark Its own Steamworks client

// A Mac game's Steamworks (steam_api) loads steamclient.dylib from Steam's folder into the
// game's own process: a client of its own, which reads the game's app ID (SteamAppId) as it
// starts and talks to Steam's engine over Steam's IPC as the game's pid. Here the game runs in
// Steam's process, and that path gave it the steamclient Steam itself runs, whose client state
// is Steam's: its app ID read once at Steam's start, its pid Steam's. Steam refused the game's
// user ("CreateFn failed for SteamUser023 User"), so SteamAPI_Init failed, and a game that plays
// through Steam's networking (Cat Mail Co.'s New Game) waited forever. So a game that ships
// Steamworks gets a steamclient.dylib of its own next to its converted copy: a copy of Steam's,
// with links to the libraries it shares with Steam (their loaded images, as before), signed
// like the game. GameSteamworks.m hands it to the game's steam_api and makes it the game's pid.
static NSString *const kSteamclientStamp = @"copied-from";

static NSString *prepareSteamclient(NSBundle *app) {
  NSFileManager *fm = NSFileManager.defaultManager;
  BOOL shipsSteamworks = NO;
  NSDirectoryEnumerator *walk = [fm enumeratorAtPath:app.bundlePath];
  for (NSString *rel in walk) {
    NSString *name = rel.lastPathComponent;
    if ([name hasPrefix:@"libsteam_api"] || [name isEqualToString:@"steam_api"]) { shipsSteamworks = YES; break; }
  }
  if (!shipsSteamworks) return nil;
  NSString *client = [frameworksDir().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"client"];
  NSString *source = [client stringByAppendingPathComponent:@"steamclient.dylib"];
  NSString *dir = [app.bundlePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"steamclient"];
  NSString *copy = [dir stringByAppendingPathComponent:@"steamclient.dylib"];
  NSDictionary *attributes = [fm attributesOfItemAtPath:source error:nil];
  if (!attributes) return nil;
  // Copied again when Steam's changes (an update), not when signing changed the copy.
  NSString *stampPath = [dir stringByAppendingPathComponent:kSteamclientStamp];
  NSString *stamp = [NSString stringWithFormat:@"%@ %.0f", attributes[NSFileSize], [attributes[NSFileModificationDate] timeIntervalSince1970]];
  BOOL fresh = ![fm fileExistsAtPath:copy] ||
               ![[NSString stringWithContentsOfFile:stampPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:stamp];
  if (fresh) {
    NSError *error;
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:copy error:nil];
    if (![fm copyItemAtPath:source toPath:copy error:&error]) {
      gameLog(@"its Steamworks client couldn't be copied (%@): it shares Steam's", error.localizedDescription);
      return nil;
    }
  }
  for (NSString *lib in @[ @"libtier0_s.dylib", @"libvstdlib_s.dylib", @"libaudio.dylib" ])
    linkTo([dir stringByAppendingPathComponent:lib], [client stringByAppendingPathComponent:lib]);
  if (fresh) {
    NSString *password;
    NSData *certificate = liveContainerCertificate(&password);
    NSString *why = certificate ? signFiles(@[ copy ], certificate, password) : nil;
    if (why) { gameLog(@"its Steamworks client couldn't be signed (%@): it shares Steam's", why); return nil; }
    [stamp writeToFile:stampPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    gameLog(@"it ships Steamworks: it gets a steamclient of its own (a copy of Steam's), as a Mac game's process has");
  }
  return copy;
}

#pragma mark What it still needs

// The functions and classes a converted binary imports from system libraries (iOS's, or the
// shim) that aren't there: the work left before it can load, all of it in one log rather than
// dyld's first missing symbol. Returns how many.
static NSUInteger reportMissingImports(NSString *path, NSString *bundlePath) {
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (file.length < sizeof(struct mach_header_64)) return 0;
  const struct mach_header_64 *mh = file.bytes;
  if (mh->magic != MH_MAGIC_64 || !(mh->flags & MH_TWOLEVEL) || mh->sizeofcmds > file.length - sizeof *mh) return 0;
  if (mh->filetype != MH_DYLIB && mh->filetype != MH_BUNDLE) return 0;   // a helper program it ships isn't run
  NSMutableArray<NSString *> *libs = [NSMutableArray array];
  const struct symtab_command *symtab = NULL;
  const uint8_t *cmds = (const uint8_t *)(mh + 1);
  uint32_t off = 0;
  for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    if (!lc->cmdsize || off + lc->cmdsize > mh->sizeofcmds) break;
    switch (lc->cmd) {
      case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_LOAD_UPWARD_DYLIB:
        [libs addObject:@((const char *)lc + ((const struct dylib_command *)lc)->dylib.name.offset)];
        break;
      case LC_SYMTAB:
        symtab = (const void *)lc;
        break;
    }
    off += lc->cmdsize;
  }
  if (!symtab || symtab->symoff + (uint64_t)symtab->nsyms * sizeof(struct nlist_64) > file.length ||
      (uint64_t)symtab->stroff + symtab->strsize > file.length) return 0;
  const struct nlist_64 *syms = (const void *)((const uint8_t *)file.bytes + symtab->symoff);
  const char *strs = (const char *)file.bytes + symtab->stroff;

  NSMutableDictionary<NSString *, NSValue *> *handles = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *missing = [NSMutableDictionary dictionary];
  NSUInteger total = 0;
  for (uint32_t i = 0; i < symtab->nsyms; i++) {
    const struct nlist_64 *s = &syms[i];
    if ((s->n_type & N_TYPE) != N_UNDF || !(s->n_type & N_EXT) || s->n_value || (s->n_desc & N_WEAK_REF)) continue;
    uint32_t ordinal = GET_LIBRARY_ORDINAL(s->n_desc);
    if (ordinal == SELF_LIBRARY_ORDINAL || ordinal > libs.count || s->n_un.n_strx >= symtab->strsize) continue;
    NSString *lib = libs[ordinal - 1];
    if ([lib hasPrefix:@"@rpath/"]) {   // one of the app's (the shim, OpenGL); a game's own are checked themselves
      NSString *inApp = [frameworksDir() stringByAppendingPathComponent:[lib substringFromIndex:7]];
      if (![NSFileManager.defaultManager fileExistsAtPath:inApp]) continue;
      lib = inApp;
    }
    if (![lib hasPrefix:@"/"] || [lib hasPrefix:bundlePath]) continue;   // its own libraries are checked themselves
    const char *name = strs + s->n_un.n_strx;
    if (*name != '_') continue;
    NSValue *h = handles[lib];
    if (!h) {
      h = [NSValue valueWithPointer:dlopen(lib.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL)];
      handles[lib] = h;
    }
    if (h.pointerValue && dlsym(h.pointerValue, name + 1)) continue;
    NSString *shown = [NSString stringWithUTF8String:name + 1];
    if (!shown || [shown hasPrefix:@"OBJC_METACLASS_$_"]) continue;   // a metaclass goes with its class
    if ([shown hasPrefix:@"OBJC_CLASS_$_"]) shown = [@"class " stringByAppendingString:[shown substringFromIndex:13]];
    NSMutableArray *list = missing[lib] ?: (missing[lib] = [NSMutableArray array]);
    [list addObject:shown];
    total++;
  }
  for (NSString *lib in [missing.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSArray *list = missing[lib];
    NSString *where = handles[lib].pointerValue ? lib.lastPathComponent : [lib.lastPathComponent stringByAppendingString:@" (doesn't load)"];
    NSArray *shown = list.count > 60 ? [list subarrayWithRange:NSMakeRange(0, 60)] : list;
    gameLog(@"  %@ needs %lu from %@: %@%@", path.lastPathComponent, (unsigned long)list.count, where,
            [shown componentsJoinedByString:@" "], list.count > shown.count ? @" ..." : @"");
  }
  return total;
}

// The same question for one of a game's binaries as downloaded, before any launch (the
// installed-games check, GameLibrary.m). Each library is routed as convertFile would route it,
// and each strong import looked up where it would bind: iOS's library, or the shim and what its
// umbrella re-exports. AKOpenGL is only asked once it is loaded (loading it for a look would
// keep its memory). Returns nil when nothing is missing, else any of: cannot (why it can't load
// at all), helper (a program the game ships that isn't run here), missing ({library: [names]}),
// unchecked ([what wasn't asked]).
NSDictionary *AKGameBinaryGaps(NSString *path, NSString *programDir, BOOL isProgram) {
  NSData *file = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
  if (!file) return @{ @"cannot": @"can't read it" };
  NSString *why = nil;
  NSData *code = arm64Code(file, &why);
  if (!code) return @{ @"cannot": why };
  const struct mach_header_64 *mh = code.bytes;
  if (mh->sizeofcmds > code.length - sizeof *mh) return @{ @"cannot": @"bad load commands" };
  if (mh->filetype == MH_EXECUTE && !isProgram) return @{ @"helper": @YES };
  NSMutableArray<NSString *> *libs = [NSMutableArray array];
  const uint8_t *cmds = (const uint8_t *)(mh + 1);
  uint32_t off = 0;
  for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    if (!lc->cmdsize || off + lc->cmdsize > mh->sizeofcmds) return @{ @"cannot": @"bad load commands" };
    switch (lc->cmd) {
      case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_LOAD_UPWARD_DYLIB: {
        uint32_t at = ((const struct dylib_command *)lc)->dylib.name.offset;
        [libs addObject:at < lc->cmdsize ? @((const char *)lc + at) : @""];
        break;
      }
    }
    off += lc->cmdsize;
  }
  NSArray<NSArray<NSString *> *> *imports = importsByLibrary(code);
  NSString *fileDir = path.stringByDeletingLastPathComponent;
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *missing = [NSMutableDictionary dictionary];
  NSMutableSet<NSString *> *unchecked = [NSMutableSet set];
  for (NSUInteger i = 0; i < libs.count && i < imports.count; i++) {
    if (!imports[i].count) continue;
    NSString *to = throughShimIfLacking(routeLibrary(libs[i], programDir, fileDir), imports[i], nil);
    void *h = NULL;
    if ([to hasPrefix:@"@rpath/"]) {
      NSString *inApp = [frameworksDir() stringByAppendingPathComponent:[to substringFromIndex:7]];
      if (![NSFileManager.defaultManager fileExistsAtPath:inApp]) continue;   // the game's own, checked as a file of its own
      BOOL opengl = [to isEqualToString:kOpenGLName];
      h = dlopen(inApp.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL | (opengl ? RTLD_NOLOAD : 0));
      if (!h && opengl) { [unchecked addObject:@"OpenGL"]; continue; }
    } else if ([to hasPrefix:@"/"]) {
      h = dlopen(to.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    } else {
      continue;   // the game's own (@loader_path and the like)
    }
    NSString *lib = libs[i].lastPathComponent;
    if (!h) lib = [lib stringByAppendingString:@" (doesn't load here)"];
    for (NSString *name in imports[i]) {
      if ([name hasPrefix:@"OBJC_METACLASS_$_"] || (h && dlsym(h, name.UTF8String))) continue;
      NSString *shown = [name hasPrefix:@"OBJC_CLASS_$_"] ? [@"class " stringByAppendingString:[name substringFromIndex:13]] : name;
      NSMutableArray *list = missing[lib] ?: (missing[lib] = [NSMutableArray array]);
      [list addObject:shown];
    }
  }
  NSMutableDictionary *gaps = [NSMutableDictionary dictionary];
  if (missing.count) gaps[@"missing"] = missing;
  if (unchecked.count) gaps[@"unchecked"] = unchecked.allObjects;
  return gaps.count ? gaps : nil;
}

// What the program links, and where each library now goes.
static void logLibraries(NSString *program) {
  NSData *file = [NSData dataWithContentsOfFile:program options:NSDataReadingMappedIfSafe error:nil];
  const struct mach_header_64 *mh = file.bytes;
  if (file.length < sizeof *mh || mh->magic != MH_MAGIC_64) return;
  NSMutableArray<NSString *> *libs = [NSMutableArray array];
  const uint8_t *cmds = (const uint8_t *)(mh + 1);
  uint32_t off = 0;
  for (uint32_t i = 0; i < mh->ncmds && off + sizeof(struct load_command) <= mh->sizeofcmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    if (!lc->cmdsize) break;
    if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB || lc->cmd == LC_REEXPORT_DYLIB)
      [libs addObject:@((const char *)lc + ((const struct dylib_command *)lc)->dylib.name.offset)];
    off += lc->cmdsize;
  }
  gameLog(@"  it links: %@", [libs componentsJoinedByString:@", "]);
}

#pragma mark The running game

static pthread_mutex_t gGameLock = PTHREAD_MUTEX_INITIALIZER;
static NSBundle *gGameBundle;         // its converted copy, which the game itself sees
static NSBundle *gGameSourceBundle;   // the download, which Steam sees
static NSString *gGameProgram;
static NSString *gGameBundlePath;   // with a trailing slash
static NSString *gGameBundleReal;   // the same through realpath (/var is /private/var), as dyld may name it
static pid_t gGamePid;
static uint32_t gGameAppID;   // from Steam's launch environment (SteamAppId), 0 if it gave none
static CFRunLoopRef gGameRunLoop;

BOOL AKGameIsRunning(void) { return gGameProgram != nil; }
pid_t AKGamePid(void) { return gGamePid; }
uint32_t AKGameAppID(void) { return gGamePid ? gGameAppID : 0; }
NSBundle *AKGameBundleForPid(pid_t pid) { return pid && pid == gGamePid ? gGameSourceBundle : nil; }

// The game's main thread: the stand-in process thread running its program.
BOOL AKIsGameThread(void) {
  NSString *program = gGameProgram;
  const char *path = program ? AKInProcessCurrentPath() : NULL;
  return path && !strcmp(path, program.fileSystemRepresentation);
}

// The address ranges of the game's own images (its program, frameworks and plug-ins), kept as
// they load, to tell its calls from Steam's.
typedef struct { uintptr_t start, end; } ak_range;
static ak_range gGameImages[128];
static _Atomic int gGameImageCount;

static BOOL hasPrefix(const char *path, NSString *prefix) {
  return prefix && !strncmp(path, prefix.fileSystemRepresentation, strlen(prefix.fileSystemRepresentation));
}

// Every game image ever loaded (they stay loaded once their game ends), for telling an ended
// game's code from the running one's.
static ak_range gAllGameImages[256];
static _Atomic int gAllGameImageCount;

BOOL AKAddressIsDeadGameCode(const void *address) {
  uintptr_t a = (uintptr_t)address & 0x0000000fffffffffULL;
  int n = gAllGameImageCount;
  for (int i = 0; i < n; i++)
    if (a >= gAllGameImages[i].start && a < gAllGameImages[i].end) return !AKAddressIsInGame((const void *)a);
  return NO;
}

BOOL AKHeaderIsGameImage(const struct mach_header *header) {
  NSString *bundlePath = gGameBundlePath, *real = gGameBundleReal;
  Dl_info info;
  return bundlePath && dladdr(header, &info) && info.dli_fname && (hasPrefix(info.dli_fname, bundlePath) || hasPrefix(info.dli_fname, real));
}

static void bindOutput(const struct mach_header *header, intptr_t slide);   // its printing (below)
static void bindUnityQuit(const struct mach_header *header, intptr_t slide);   // Unity's quit (below)

#pragma mark Starting a game again

// A game's images stay loaded after it ends (dyld never unloads an image with Objective-C in
// it), and a second launch ran main() over the first run's globals: GameMaker printed "Failed
// to load the game" and stopped. So each game image's own data - its __data, __bss and
// __common sections, the C and C++ globals - is copied as dyld hands the image over, and its
// initializers noted; a later launch of the same game puts those bytes back and runs the
// initializers again (fresh C++ globals, static locals' guards cleared), as a new process
// would start. Objective-C sections, pointers bound to other libraries and constant data are
// left alone; what the first run allocated stays allocated.
typedef struct {
  const struct mach_header_64 *header;
  int spans, inits;
  struct { uint8_t *at; size_t size; uint8_t *copy; } span[8];
  uintptr_t init[64];
} ak_snapshot;
static ak_snapshot gSnapshots[32];
static int gSnapshotCount;

static void snapshotImage(const struct mach_header *header, intptr_t slide) {
  const struct mach_header_64 *mh = (const void *)header;
  for (int i = 0; i < gSnapshotCount; i++) if (gSnapshots[i].header == mh) return;
  if (gSnapshotCount >= 32 || mh->magic != MH_MAGIC_64) return;
  ak_snapshot *s = &gSnapshots[gSnapshotCount];
  memset(s, 0, sizeof *s);
  s->header = mh;
  const uint8_t *lc = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const struct load_command *)lc)->cmdsize) {
    const struct segment_command_64 *seg = (const void *)lc;
    if (seg->cmd != LC_SEGMENT_64) continue;
    BOOL data = !strncmp(seg->segname, "__DATA", 16) || !strncmp(seg->segname, "__DATA_DIRTY", 16);
    const struct section_64 *sect = (const void *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
      uint32_t type = sect->flags & SECTION_TYPE;
      if (type == S_MOD_INIT_FUNC_POINTERS) {
        const uintptr_t *fn = (const uintptr_t *)(sect->addr + slide);
        for (uint64_t k = 0; k < sect->size / sizeof(uintptr_t) && s->inits < 64; k++) s->init[s->inits++] = fn[k];
      } else if (type == S_INIT_FUNC_OFFSETS) {
        const uint32_t *off = (const uint32_t *)(sect->addr + slide);
        for (uint64_t k = 0; k < sect->size / sizeof(uint32_t) && s->inits < 64; k++) s->init[s->inits++] = (uintptr_t)mh + off[k];
      } else if (data && sect->size && s->spans < 8 &&
                 (!strncmp(sect->sectname, "__data", 16) || !strncmp(sect->sectname, "__bss", 16) || !strncmp(sect->sectname, "__common", 16))) {
        uint8_t *at = (uint8_t *)(sect->addr + slide), *copy = malloc(sect->size);
        if (!copy) continue;
        memcpy(copy, at, sect->size);
        s->span[s->spans].at = at;
        s->span[s->spans].size = sect->size;
        s->span[s->spans].copy = copy;
        s->spans++;
      }
    }
  }
  gSnapshotCount++;
}

// Every image of the game in `bundle` (a path with its trailing slash) back as it was loaded.
static int freshStart(NSString *bundle, NSString *bundleReal) {
  int images = 0;
  for (int i = 0; i < gSnapshotCount; i++) {
    ak_snapshot *s = &gSnapshots[i];
    Dl_info info;
    if (!dladdr(s->header, &info) || !info.dli_fname || !(hasPrefix(info.dli_fname, bundle) || hasPrefix(info.dli_fname, bundleReal)))
      continue;
    for (int k = 0; k < s->spans; k++) memcpy(s->span[k].at, s->span[k].copy, s->span[k].size);
    images++;
  }
  AKGameRestoreClasses();   // their methods, silenced when it ended (GameTeardown.m)
  // Then their initializers, in the order the images loaded.
  const char *argv[] = { gGameProgram.fileSystemRepresentation, NULL };
  char exec[PATH_MAX + 32];
  snprintf(exec, sizeof exec, "executable_path=%s", argv[0]);
  const char *apple[] = { exec, NULL };
  for (int i = 0; i < gSnapshotCount; i++) {
    ak_snapshot *s = &gSnapshots[i];
    Dl_info info;
    if (!dladdr(s->header, &info) || !info.dli_fname || !(hasPrefix(info.dli_fname, bundle) || hasPrefix(info.dli_fname, bundleReal)))
      continue;
    for (int k = 0; k < s->inits; k++)
      ((void (*)(int, const char **, char **, const char **, const void *))s->init[k])(1, argv, *_NSGetEnviron(), apple, NULL);
  }
  return images;
}

#pragma mark Bound as in its own process

// Every game runs in this one process, and dyld ties a newly loaded image's operator new and
// delete (and its other weak C++ definitions) to the first loaded image that exports one. That
// can be a game that has ended, its heap gone: Cat Mail Co.'s IL2CPP code allocated through
// DELTARUNE's GameMaker memory manager after DELTARUNE had ended, and crashed in it. It can be a
// running game's engine library whose allocator iOS's libc++ doesn't share (Unity's player: see
// hideOperatorNewDelete). And any C++ library Steam loads after a game would be tied the same
// way. On a Mac each game has its own process and none of this can happen. So each image loaded
// once a game has started is bound as its own process would bind it, except that operator new
// and delete are always the system's: on a Mac dyld also points the system's libc++ at a game's
// own allocator, but iOS's libc++ in the shared cache always allocates and frees with the
// system's, and a game's allocator mixed with it frees one's memory with the other ("pointer
// being freed was not allocated": Unity's IL2CPP start, whose program defines Unity's operator
// new, as Tunic's Mac build found too). Only a game program's own references to its own operator
// new and delete keep them (GameMaker's runner: its code calls them directly anyway). And any
// other import left pointing into an ended game's code goes to the image's own definition.
static const struct mach_header *gProgramHeader;   // the running game's program, once it loads
static NSString *gProgramInBundle;                  // its path inside its bundle ("Contents/MacOS/X")
static BOOL gGamesStarted;                          // a game has been launched in this run

static BOOL isAllocator(const char *symbol) {
  return !strncmp(symbol, "__Znw", 5) || !strncmp(symbol, "__Zna", 5) || !strncmp(symbol, "__Zdl", 5) || !strncmp(symbol, "__Zda", 5);
}

// The externals an image defines, by name (with the leading underscore), from its symbol table.
static NSDictionary<NSString *, NSValue *> *definitionsOf(const struct mach_header *header, intptr_t slide) {
  const struct mach_header_64 *mh = (const void *)header;
  const struct segment_command_64 *linkedit = NULL;
  const struct symtab_command *symtab = NULL;
  const uint8_t *lc = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const struct load_command *)lc)->cmdsize) {
    const struct load_command *l = (const void *)lc;
    if (l->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)l)->segname, SEG_LINKEDIT)) linkedit = (const void *)l;
    else if (l->cmd == LC_SYMTAB) symtab = (const void *)l;
  }
  NSMutableDictionary *defs = [NSMutableDictionary dictionary];
  if (!linkedit || !symtab) return defs;
  uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
  const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
  const char *strs = (const char *)(base + symtab->stroff);
  for (uint32_t i = 0; i < symtab->nsyms; i++) {
    if ((syms[i].n_type & (N_STAB | N_TYPE | N_EXT)) != (N_SECT | N_EXT)) continue;
    NSString *name = [NSString stringWithUTF8String:strs + syms[i].n_un.n_strx];
    if (name) defs[name] = [NSValue valueWithPointer:(void *)(syms[i].n_value + (uint64_t)slide)];
  }
  return defs;
}

static void bindAsItsOwnProcess(const struct mach_header *header, intptr_t slide, const char *name, BOOL game) {
  static void *libcxx;
  if (!libcxx) libcxx = dlopen("/usr/lib/libc++.1.dylib", RTLD_LAZY | RTLD_NOLOAD);
  BOOL program = game && header == gProgramHeader;
  __block NSDictionary *own = nil;
  __block int allocators = 0, fromEnded = 0;
  __block BOOL itsOwn = NO;
  AKRebindImportsFrom(header, slide, ^void *(const char *symbol, void *current) {
    if (isAllocator(symbol)) {
      void *to = NULL;
      if (program) {
        if (!own) own = definitionsOf(header, slide);
        to = [own[@(symbol)] pointerValue];
        itsOwn |= to != NULL;
      }
      if (!to && libcxx) to = dlsym(libcxx, symbol + 1);
      if (to && to != current) allocators++;
      return to;
    }
    if (!AKAddressIsDeadGameCode(current)) return NULL;
    if (!own) own = definitionsOf(header, slide);
    void *mine = [own[@(symbol)] pointerValue];
    if (mine) fromEnded++;
    return mine;
  });
  if (!allocators && !fromEnded) return;
  const char *base = name && strrchr(name, '/') ? strrchr(name, '/') + 1 : (name ?: "an image");
  gameLog(@"  %s, bound as in its own process: %d operator new/delete imports to %@, %d imports from an ended game to its own",
          base, allocators, itsOwn ? @"its own" : @"the system's", fromEnded);
}

static BOOL imageAdded(const struct mach_header *header, intptr_t slide);

// dyld's hook: a game's images as imageAdded says; any other image loaded once games have
// started (not iOS's own, in the shared cache) bound away from games.
static void imageLoaded(const struct mach_header *header, intptr_t slide) {
  if (imageAdded(header, slide) || !gGamesStarted || (header->flags & MH_DYLIB_IN_CACHE)) return;
  Dl_info info;
  bindAsItsOwnProcess(header, slide, dladdr(header, &info) ? info.dli_fname : NULL, NO);
}

// One of the running game's images (YES), set up as it loads.
static BOOL imageAdded(const struct mach_header *header, intptr_t slide) {
  NSString *bundlePath = gGameBundlePath, *real = gGameBundleReal;
  Dl_info info;
  if (!bundlePath || !dladdr(header, &info) || !info.dli_fname || !(hasPrefix(info.dli_fname, bundlePath) || hasPrefix(info.dli_fname, real)))
    return NO;
  // Its program loads first; then every image of its own is bound as in its own process.
  NSString *path = @(info.dli_fname);
  if (gProgramInBundle && [path hasSuffix:[@"/" stringByAppendingString:gProgramInBundle]]) {
    gProgramHeader = header;
  }
  bindAsItsOwnProcess(header, slide, info.dli_fname, YES);
  // Its IOKit HID calls (gamepads) are answered from GameController, its sound goes to iOS's
  // output unit, its busy waits on the clock rest the core, and what it prints is watched for
  // its quitting.
  AKGameBindControllers(header, slide, info.dli_fname);
  AKGameBindAudio(header, slide);
  AKGameBindClock(header, slide);
  AKGameBindLuaJIT(header, slide);   // LuaJIT's compiler off, its interpreter on (GameLuaJIT.m)
  AKGameBindMainThread(header, slide);   // its main queue and main thread are its own (GameMainThread.m)
  AKGameBindBundles(header, slide);      // its plug-in bundles' programs are found (GameBundles.m)
  AKGameBindMetal(header, slide);        // its Metal device marks it as drawn at the screen's scale (MetalCompat.m)
  AKGameBindSteamworks(header, slide, info.dli_fname);   // its Steamworks loads its own steamclient (GameSteamworks.m)
  bindOutput(header, slide);
  size_t nameLength = strlen(info.dli_fname);
  if (nameLength > 18 && !strcmp(info.dli_fname + nameLength - 18, "/UnityPlayer.dylib")) bindUnityQuit(header, slide);
  AKGameBindProcess(header, slide);   // its heap, exit handlers and dispatch sources (GameTeardown.m)
  snapshotImage(header, slide);
  const struct mach_header_64 *mh = (const void *)header;
  const uint8_t *lc = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const struct load_command *)lc)->cmdsize) {
    const struct segment_command_64 *seg = (const void *)lc;
    if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__TEXT", 16)) continue;
    ak_range range = { (uintptr_t)header, (uintptr_t)header + seg->vmsize };
    int all = gAllGameImageCount, known = 0;
    for (int k = 0; k < all; k++) known |= gAllGameImages[k].start == range.start;
    if (!known && all < 256) { gAllGameImages[all] = range; gAllGameImageCount = all + 1; }
    int n = gGameImageCount;
    if (n >= 128) return YES;
    gGameImages[n] = range;
    gGameImageCount = n + 1;
    return YES;
  }
  return YES;
}

BOOL AKAddressIsInGame(const void *address) {
  if (!gGameProgram) return NO;
  uintptr_t a = (uintptr_t)address;
  int n = gGameImageCount;
  for (int i = 0; i < n; i++) if (a >= gGameImages[i].start && a < gGameImages[i].end) return YES;
  return NO;
}

// +[NSBundle mainBundle] and CFBundleGetMainBundle(), asked by the game (from its main thread
// or its own code), answer with its bundle: that's where it finds its data. _NSGetExecutablePath
// names its program.
static IMP gMainBundle;

static NSBundle *mainBundleForCaller(id self, SEL _cmd) {
  NSBundle *game = gGameBundle;
  if (game && (AKAddressIsInGame(__builtin_return_address(0)) || AKIsGameThread())) return game;
  return ((NSBundle * (*)(id, SEL))gMainBundle)(self, _cmd);
}

static CFBundleRef gameCFMainBundle(void) {
  static CFBundleRef bundle;
  static NSString *bundlePath;
  NSBundle *game = gGameBundle;
  if (!game) return CFBundleGetMainBundle();
  @synchronized (NSBundle.class) {
    if (![bundlePath isEqualToString:game.bundlePath]) {
      if (bundle) CFRelease(bundle);
      bundle = CFBundleCreate(NULL, (__bridge CFURLRef)game.bundleURL);
      bundlePath = game.bundlePath;
    }
  }
  return bundle ?: CFBundleGetMainBundle();
}

static int gameExecutablePath(char *buf, uint32_t *bufsize) {
  NSString *program = gGameProgram;
  if (!program) return AKNSGetExecutablePath(buf, bufsize);
  const char *path = program.fileSystemRepresentation;
  uint32_t need = (uint32_t)strlen(path) + 1;
  if (!bufsize || *bufsize < need) {
    if (bufsize) *bufsize = need;
    return -1;
  }
  memcpy(buf, path, need);
  return 0;
}

// Its app delegate. A Mac app usually gets it from its main nib, and nibs aren't loaded here,
// so it is made directly: the class of the game's own that adopts NSApplicationDelegate
// (or is named like one).
static Class appDelegateClass(void) {
  unsigned count = 0;
  const char **names = objc_copyClassNamesForImage(gGameProgram.fileSystemRepresentation, &count);
  if (!names) {
    char real[PATH_MAX];
    if (realpath(gGameProgram.fileSystemRepresentation, real)) names = objc_copyClassNamesForImage(real, &count);
  }
  Protocol *delegateProtocol = objc_getProtocol("NSApplicationDelegate");
  Class best = Nil;
  BOOL bestNamed = NO;
  for (unsigned i = 0; i < count; i++) {
    Class c = objc_getClass(names[i]);
    if (!c) continue;
    BOOL conforms = NO;
    for (Class k = c; k && !conforms; k = class_getSuperclass(k)) conforms = delegateProtocol && class_conformsToProtocol(k, delegateProtocol);
    BOOL named = strstr(names[i], "AppDelegate") || strstr(names[i], "ApplicationDelegate");
    if (!conforms && !named) continue;
    if (conforms && named) { best = c; break; }
    if (!best || (named && !bestNamed)) { best = c; bestNamed = named; }
  }
  free(names);
  return best;
}

int AKGameApplicationMain(int argc, const char *argv[]) {
  AKGameMainThreadHere();
  NSApplication *app = NSApplication.sharedApplication;
  NSDictionary *info = gGameBundle.infoDictionary;
  gameLog(@"NSApplicationMain: principal class %@, main nib %@", info[@"NSPrincipalClass"] ?: @"-", info[@"NSMainNibFile"] ?: @"-");
  gameLog(@"its display: %ld Hz", (long)AKDisplayRefreshRate(UIScreen.mainScreen));
  // As AppKit does: the main nib makes its delegate, windows and views, NSApp its owner.
  NSString *mainNib = [info[@"NSMainNibFile"] isKindOfClass:NSString.class] ? info[@"NSMainNibFile"] : nil;
  if (mainNib) AKLoadNib(mainNib, gGameBundle, app, NULL);
  if (!app.delegate) {
    Class c = appDelegateClass();
    if (c) {
      id delegate = [c new];   // NSApplication keeps a game thread's delegate (a strong reference of its own)
      app.delegate = delegate;
      gameLog(@"its app delegate: %s, made directly (its nib didn't make one)", class_getName(c));
    } else {
      gameLog(@"no app delegate found in it");
    }
  }
  // The first pass of its loop, after launch, is where AppKit first displays its windows: an
  // OpenGL view gets its context there, current on this thread, before any timer fires.
  CFRunLoopPerformBlock(CFRunLoopGetCurrent(), kCFRunLoopCommonModes, ^{ AKPrepareGameOpenGLViews(); });
  [app run];
  return 0;
}

void AKGameNoteRunLoop(void) {
  AKGameMainThreadHere();
  if (gGameRunLoop || !AKIsGameThread()) return;
  pthread_mutex_lock(&gGameLock);
  if (!gGameRunLoop) gGameRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
  pthread_mutex_unlock(&gGameLock);
}

// Steam stopping the game (kill, or terminate on its NSRunningApplication): asked to quit as
// AppKit asks an app, -[NSApp terminate:] on its main thread, which ends it.
static void gameSignalled(pid_t pid, int sig) {
  if (pid != gGamePid || sig == 0) return;
  if (sig == SIGKILL) {
    gameLog(@"killed (signal 9): it ends now");
    AKInProcessForceExit(pid, 0);
    return;
  }
  pthread_mutex_lock(&gGameLock);
  CFRunLoopRef loop = gGameRunLoop ? (CFRunLoopRef)CFRetain(gGameRunLoop) : NULL;
  pthread_mutex_unlock(&gGameLock);
  if (loop) {
    gameLog(@"asking it to quit (signal %d)", sig);
    CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ [NSApp terminate:nil]; });
    CFRunLoopWakeUp(loop);
    CFRelease(loop);
  } else {
    gameLog(@"can't ask it to quit: it isn't running an event loop");
  }
  // Steam's Exit Game always ends it: one still running 5 s on (stuck in its own code, or with no
  // event loop to ask) ends for Steam and the screen, its thread left where it is.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (loop ? 5 : 0) * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (gGamePid != pid) return;
    gameLog(@"it didn't quit within 5 s: ended for Steam");
    AKInProcessForceExit(pid, 0);
  });
}

#pragma mark A game that left its main loop

// Ends the game as its own exit(0) would, on its thread when its event loop turns; one whose
// loop doesn't turn ends for Steam and the screen 5 s on.
static void endGame(pid_t pid) {
  pthread_mutex_lock(&gGameLock);
  CFRunLoopRef loop = gGameRunLoop ? (CFRunLoopRef)CFRetain(gGameRunLoop) : NULL;
  pthread_mutex_unlock(&gGameLock);
  if (loop) {
    CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ exit(0); });
    CFRunLoopWakeUp(loop);
    CFRelease(loop);
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (loop ? 5 : 0) * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (gGamePid != pid) return;
    gameLog(@"it didn't end within 5 s: ended for Steam");
    AKInProcessForceExit(pid, 0);
  });
}

// A game that steps from a frame timer (GameTimers.m) and invalidates its last one, making no
// other, has left its main loop: three seconds with no frame timer (the app in front) end it. A
// frame timer that stops firing for 10 s while still scheduled only has the game thread's stack
// logged, once per stall.
static void watchGameLoop(pid_t pid) {
  __block int quietFor = 0;
  __block BOOL hadFrameTimer = NO, reportedStall = NO;
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
  dispatch_source_set_event_handler(timer, ^{
    if (gGamePid != pid) { dispatch_source_cancel(timer); return; }
    int timers;
    CFAbsoluteTime began, ended, now = CFAbsoluteTimeGetCurrent();
    AKGameFrameTimerState(&timers, &began, &ended);
    if (timers > 0) {
      hadFrameTimer = YES;
      quietFor = 0;
      CFAbsoluteTime last = MAX(began, ended);
      if (now - last < 1) reportedStall = NO;
      if (!reportedStall && last > 0 && now - last > 10) {
        reportedStall = YES;
        AKInProcessLogStack(pid, began > ended ? "one step of its frame timer has taken over 10 s" : "its frame timer hasn't fired for 10 s");
      }
      return;
    }
    if (!hadFrameTimer || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (++quietFor < 3) return;
    dispatch_source_cancel(timer);
    gameLog(@"it stopped its frame timer and made no other: it has quit");
    AKInProcessLogStack(pid, "it left its main loop");
    endGame(pid);
  });
  dispatch_resume(timer);
}

// GameMaker prints "###game_end###<code>" when game_end() runs, frees its scripts, stops
// drawing and then calls nothing that ends the process here: its thread goes on in its event
// loop with its last frame on screen. What the game's own code prints is watched for that
// line. A game that then goes quiet - nothing printed and no frame shown for 2 s - has quit and
// is ended (its thread's stack logged first). game_change() (DELTARUNE's chapters) ends the
// game the same way but starts the next at once ("Processing command line" again): that one is
// left running, as is one still drawing two minutes on.
static double gLastOutput;      // CFAbsoluteTime of the game's last print
static BOOL gNextGameStarted;   // it printed a new game's start after ###game_end###
static BOOL gWatchingQuit;

static uint64_t framesShown(void) {
  static uint64_t (*shown)(void);
  if (!shown) shown = (uint64_t (*)(void))dlsym(RTLD_DEFAULT, "AKGLFramesShown");
  return shown ? shown() : 0;
}

static void gameSaidItQuit(void) {
  pid_t pid = gGamePid;
  if (!pid || gWatchingQuit) return;
  gWatchingQuit = YES;
  gNextGameStarted = NO;
  gameLog(@"it is shutting down (game_end): it is quitting");
  dispatch_async(dispatch_get_main_queue(), ^{
    __block uint64_t frames = framesShown();
    __block CFAbsoluteTime framesAt = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime started = framesAt;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      if (gGamePid != pid || gNextGameStarted || now - started > 120) {
        if (gGamePid == pid) gameLog(gNextGameStarted ? @"it started its next game (game_change)" : @"it is still drawing: left running");
        gWatchingQuit = NO;
        dispatch_source_cancel(timer);
        return;
      }
      uint64_t f = framesShown();
      if (f != frames) { frames = f; framesAt = now; }
      if (now - gLastOutput < 2 || now - framesAt < 2) return;
      gWatchingQuit = NO;
      dispatch_source_cancel(timer);
      gameLog(@"nothing printed or drawn for 2 s since: it has quit");
      AKInProcessLogStack(pid, "it quit but is still running");
      endGame(pid);
    });
    dispatch_resume(timer);
  });
}

static void noteOutput(const char *text, size_t n) {
  if (!text || !n) return;
  gLastOutput = CFAbsoluteTimeGetCurrent();
  // GameMaker frees its scripts as it shuts down: after game_end(), and after a game that failed
  // to load, which prints no game_end.
  if ((n >= 14 && memmem(text, n, "###game_end###", 14)) || (n >= 19 && memmem(text, n, "Script_Free called ", 19))) gameSaidItQuit();
  else if (n >= 23 && memmem(text, n, "Processing command line", 23)) gNextGameStarted = YES;
}

static void noteFormatted(const char *fmt, va_list ap) {
  char line[512];
  va_list copy;
  va_copy(copy, ap);
  int n = vsnprintf(line, sizeof line, fmt, copy);
  va_end(copy);
  if (n > 0) noteOutput(line, MIN((size_t)n, sizeof line - 1));
}

static int gamePrintf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  noteFormatted(fmt, ap);
  int r = vprintf(fmt, ap);
  va_end(ap);
  return r;
}

static int gameFprintf(FILE *f, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  noteFormatted(fmt, ap);
  int r = vfprintf(f, fmt, ap);
  va_end(ap);
  return r;
}

static int gameVprintf(const char *fmt, va_list ap) {
  noteFormatted(fmt, ap);
  return vprintf(fmt, ap);
}

static int gameVfprintf(FILE *f, const char *fmt, va_list ap) {
  noteFormatted(fmt, ap);
  return vfprintf(f, fmt, ap);
}

static int gamePuts(const char *s) {
  if (s) noteOutput(s, strlen(s));
  return puts(s);
}

static int gameFputs(const char *s, FILE *f) {
  if (s) noteOutput(s, strlen(s));
  return fputs(s, f);
}

static size_t gameFwrite(const void *p, size_t size, size_t count, FILE *f) {
  if (f == stdout || f == stderr) noteOutput(p, size * count);
  return fwrite(p, size, count, f);
}

static void bindOutput(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (!strcmp(symbol, "_printf")) return (void *)gamePrintf;
    if (!strcmp(symbol, "_fprintf")) return (void *)gameFprintf;
    if (!strcmp(symbol, "_vprintf")) return (void *)gameVprintf;
    if (!strcmp(symbol, "_vfprintf")) return (void *)gameVfprintf;
    if (!strcmp(symbol, "_puts")) return (void *)gamePuts;
    if (!strcmp(symbol, "_fputs")) return (void *)gameFputs;
    if (!strcmp(symbol, "_fwrite")) return (void *)gameFwrite;
    return NULL;
  });
}

// Unity's Mac player quits by tearing itself down and then stopping the run loop it saved, its
// only CFRunLoopStop (Tunic's Mac build showed it, debeanz/tunic-ios-port); on a Mac the process
// ends next. Here a game's player stopping the app's main run loop or the game's own ends the game
// a second later, unless it ended itself. The app's main run loop (UIKit's) isn't actually stopped.
static void unityRunLoopStop(CFRunLoopRef loop) {
  CFRunLoopRef main = CFRunLoopGetMain();
  if (loop != main) CFRunLoopStop(loop);
  pid_t pid = gGamePid;
  if (!pid || (loop != main && loop != gGameRunLoop)) return;
  gameLog(@"Unity's player stopped its run loop (how it quits): ending the game in 1 s unless it ends itself");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (gGamePid == pid) endGame(pid);
  });
}

static void bindUnityQuit(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    return strcmp(symbol, "_CFRunLoopStop") ? NULL : (void *)unityRunLoopStop;
  });
}

// Steam's console (stdout and stderr to steam-console.log) as a game starts. Unity's -logFile
// points the process's stdout and stderr at its own log, and nothing would point them back: they
// come back when the game ends.
static int gConsoleOut = -1, gConsoleErr = -1;

static void keepConsole(void) {
  if (gConsoleOut < 0) gConsoleOut = dup(STDOUT_FILENO);
  if (gConsoleErr < 0) gConsoleErr = dup(STDERR_FILENO);
}

static BOOL sameFile(int a, int b) {
  struct stat x, y;
  return fstat(a, &x) == 0 && fstat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}

static void restoreConsole(void) {
  fflush(stdout);
  fflush(stderr);
  BOOL moved = NO;
  // The descriptors and the ones stdio writes through (freopen may have given it others).
  int pairs[4][2] = { { gConsoleOut, STDOUT_FILENO }, { gConsoleOut, fileno(stdout) },
                      { gConsoleErr, STDERR_FILENO }, { gConsoleErr, fileno(stderr) } };
  for (int i = 0; i < 4; i++) {
    int saved = pairs[i][0], fd = pairs[i][1];
    if (saved >= 0 && fd >= 0 && !sameFile(saved, fd)) moved |= dup2(saved, fd) == fd;
  }
  if (gConsoleOut >= 0) close(gConsoleOut);
  if (gConsoleErr >= 0) close(gConsoleErr);
  gConsoleOut = gConsoleErr = -1;
  if (moved) gameLog(@"its output went to its own log while it ran; Steam's is back in steam-console.log");
}

static void gameEnded(pid_t pid, int status) {
  pthread_mutex_lock(&gGameLock);   // held by the launcher until gGamePid is set
  BOOL ours = pid == gGamePid;
  pthread_mutex_unlock(&gGameLock);
  if (!ours) return;
  restoreConsole();
  gameLog(@"%@ ended (%d)", gGameBundle.bundlePath.lastPathComponent, status);
  NSMutableArray<NSString *> *images = [NSMutableArray array];
  for (int i = 0; i < gGameImageCount; i++) {
    Dl_info info;
    if (dladdr((const void *)gGameImages[i].start, &info) && info.dli_fname) [images addObject:@(info.dli_fname)];
  }
  AKGameDidEnd(pid);
  AKGameAppEnded();
  AKGameProfileEnd();
  pthread_mutex_lock(&gGameLock);
  gGamePid = 0;
  gGameProgram = nil;
  gGameBundle = gGameSourceBundle = nil;
  gGameBundlePath = gGameBundleReal = nil;
  gGameImageCount = 0;
  if (gGameRunLoop) CFRelease(gGameRunLoop);
  gGameRunLoop = NULL;
  gGameAppID = 0;
  pthread_mutex_unlock(&gGameLock);
  dispatch_async(dispatch_get_main_queue(), ^{
    AKGameWindowsClose();
    AKWHGameChanged();
    AKGameTeardown(images);   // what its process would have taken with it (GameTeardown.m)
  });
}

// The program inside a Mac .app: Contents/MacOS/<CFBundleExecutable>, read directly if
// NSBundle (on iOS) doesn't find it.
static NSString *programOf(NSBundle *app, NSURL *appURL) {
  NSString *program = app.executablePath;
  if (program && [NSFileManager.defaultManager fileExistsAtPath:program]) return program;
  return AKMacBundleProgram(appURL.path);
}

// The app's own C++ libraries a game uses (the OpenGL stack: AKOpenGL, Mesa, and MoltenVK,
// which Zink opens later), loaded before the game is. A game may bring its own operator new and
// delete (GameMaker's MemoryManager); the loader then binds them into every library loaded
// after it, while libc++ itself keeps the system's — so MoltenVK's strings were made by the
// game's allocator and freed by the system's ("pointer being freed was not allocated"). On a
// Mac a game's allocator is everyone's; here it stays the game's and its plugins'.
static void preloadSharedLibraries(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (NSString *lib in @[ @"AKOpenGL.framework/AKOpenGL", @"libMoltenVK.dylib" ]) {
      NSString *path = [frameworksDir() stringByAppendingPathComponent:lib];
      if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
      // AKOpenGL as NSOpenGL.m opens it; MoltenVK as Zink and AKOpenGL do, privately.
      int mode = [lib hasPrefix:@"AKOpenGL"] ? RTLD_GLOBAL : RTLD_LOCAL;
      if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | mode)) gameLog(@"%@ doesn't load: %s", lib, dlerror());
    }
  });
}

// Whether the game defines operator new itself (then it shares it only with its own libraries).
static void noteOwnAllocator(void *image) {
  void *mine = dlsym(image, "_Znwm");
  if (mine && AKAddressIsInGame(mine)) gameLog(@"it defines its own operator new/delete: only its program's code uses them, its libraries and iOS's the system's");
}

// Why it couldn't start goes to *failure, a strong reference the failure block can set safely
// (AKLaunchMacApplication hands it on).
static pid_t launchMacApplication(NSURL *appURL, NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *environment,
                                  NSError *__strong *failure) {
  appURL = appURL.URLByStandardizingPath;
  NSBundle *source = [NSBundle bundleWithURL:appURL];
  NSString *sourceProgram = programOf(source, appURL);
  void (^fail)(NSString *) = ^(NSString *why) {
    gameLog(@"can't start %@: %@", appURL.lastPathComponent, why);
    *failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOEXEC userInfo:@{ NSLocalizedDescriptionKey: why }];
  };
  if (!source || !sourceProgram) { fail(@"no program in it"); return -1; }
  if (gGameProgram) { fail(@"a game is already running"); return -1; }
  gameLog(@"starting %@ (%@), program %@", appURL.lastPathComponent, source.bundleIdentifier ?: @"no bundle id", sourceProgram.lastPathComponent);
  if (labelledIOS(sourceProgram))
    gameLog(@"its download was changed by an earlier build of this app (which converted it in place); Steam's checks fail "
            @"on it until it's restored: in Steam, the game's Properties > Installed Files > Verify integrity");

  // It runs from its converted copy; the download stays as Steam installed it. A game started
  // before in this session runs again from the copy still loaded (its files aren't rewritten
  // under the loaded images), from a fresh start (see freshStart).
  static NSMutableDictionary<NSString *, NSArray<NSString *> *> *loadedCopies;   // download -> [copy, program]
  NSArray<NSString *> *loaded = loadedCopies[appURL.path];
  void *already = loaded ? dlopen(loaded[1].fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD) : NULL;
  if (already) dlclose(already);
  BOOL again = already != NULL;
  static dispatch_once_t tidy;
  dispatch_once(&tidy, ^{ removeOrphanCopies(); });
  NSString *copy = again ? loaded[0] : nil;
  NSString *why = again ? nil : mirrorApp(appURL.path, &copy);
  if (why) { fail([NSString stringWithFormat:@"couldn't make its converted copy: %@", why]); return -1; }
  NSString *rel = [sourceProgram hasPrefix:[appURL.path stringByAppendingString:@"/"]]
                      ? [sourceProgram substringFromIndex:appURL.path.length + 1]
                      : [@"Contents/MacOS" stringByAppendingPathComponent:sourceProgram.lastPathComponent];
  NSString *program = again ? loaded[1] : [copy stringByAppendingPathComponent:rel];
  NSBundle *app = [NSBundle bundleWithPath:copy];
  if (!app || ![NSFileManager.defaultManager fileExistsAtPath:program]) { fail(@"its converted copy has no program"); return -1; }
  why = again ? nil : convertApp(app, program);
  if (why) { fail(why); return -1; }
  if (again) gameLog(@"it ran before in this session: its loaded copy starts again");
  AKGameSetSteamclient(prepareSteamclient(app));   // its own Steamworks client (GameSteamworks.m)
  // Signed with LiveContainer's certificate: ask the kernel now, the way dyld will, and on a
  // refusal log enough to tell why.
  if (!again && liveContainerCertificate(NULL)) {
    NSString *refused = kernelVerdict(program);
    if (refused) {
      gameLog(@"iOS refuses %@: %@", program.lastPathComponent, refused);
      gameLog(@"  its signature: %@", describeSignature(program));
      probeSigning(copy.stringByDeletingLastPathComponent);
      fail([NSString stringWithFormat:@"iOS refuses its signature (%@)", refused]);
      return -1;
    }
    gameLog(@"iOS accepts its signature");
  }
  gameLog(@"resources: %@", app.resourcePath ?: @"not found");
  logLibraries(program);
  NSUInteger missing = reportMissingImports(program, app.bundlePath);
  NSDirectoryEnumerator *walk = [NSFileManager.defaultManager enumeratorAtPath:app.bundlePath];
  for (NSString *rel in walk) {
    NSString *path = [app.bundlePath stringByAppendingPathComponent:rel];
    if ([walk.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular] && ![path isEqualToString:program] && isMachO(path))
      missing += reportMissingImports(path, app.bundlePath);
  }
  if (missing) gameLog(@"%lu functions and classes it uses aren't here yet; it may not load", (unsigned long)missing);

  // The game's own bundle, program path and environment (Steam's SteamAppId and the like).
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Method m = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    gMainBundle = method_setImplementation(m, (IMP)mainBundleForCaller);
    AKInProcessSetExitObserver(gameEnded);
    AKInProcessSetSignalObserver(gameSignalled);
  });
  // Its performance profile (GameProfiles.m: Steam's Performance tab), before anything measures
  // the screen.
  NSString *profileID = [environment[@"SteamGameId"] isKindOfClass:NSString.class] ? environment[@"SteamGameId"]
                      : [environment[@"SteamAppId"] isKindOfClass:NSString.class] ? environment[@"SteamAppId"] : nil;
  AKGameProfileBegin(profileID);
  // A Unity player draws with Metal: its picture at the screen's scale from the start (NSScreen.m).
  if ([NSFileManager.defaultManager fileExistsAtPath:[app.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/UnityPlayer.dylib"]])
    AKGameNoteDrawsWithMetal();
  pthread_mutex_lock(&gGameLock);
  gGameBundle = app;
  gGameSourceBundle = source;
  gGameBundlePath = [app.bundlePath stringByAppendingString:@"/"];
  char real[PATH_MAX];
  gGameBundleReal = realpath(app.bundlePath.fileSystemRepresentation, real) ? [@(real) stringByAppendingString:@"/"] : nil;
  gGameProgram = program;
  gGameImageCount = 0;
  gProgramHeader = NULL;
  gProgramInBundle = [program hasPrefix:[app.bundlePath stringByAppendingString:@"/"]] ? [program substringFromIndex:app.bundlePath.length + 1]
                                                                                       : program.lastPathComponent;
  static dispatch_once_t watchImages;
  dispatch_once(&watchImages, ^{ _dyld_register_func_for_add_image(imageLoaded); });
  gGamesStarted = YES;   // after the hook's first pass over what was already loaded
  for (uint32_t i = 0; i < _dyld_image_count(); i++) imageAdded(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
  [environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
    if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class] && ![key hasPrefix:@"DYLD_"])
      setenv(key.UTF8String, value.UTF8String, 1);
  }];
  NSString *appID = [environment[@"SteamAppId"] isKindOfClass:NSString.class] ? environment[@"SteamAppId"] : nil;
  NSString *gameID = [environment[@"SteamGameId"] isKindOfClass:NSString.class] ? environment[@"SteamGameId"] : appID;
  gGameAppID = (uint32_t)appID.longLongValue;
  if (gameID.length) AKSteamNoteGameID(strtoull(gameID.UTF8String, NULL, 10));

  // Loaded here first, so its main-bundle calls are redirected before its main() runs.
  void (^undo)(void) = ^{
    gGameBundle = gGameSourceBundle = nil;
    gGameBundlePath = gGameBundleReal = nil;
    gGameProgram = nil;
    gGameImageCount = 0;
    pthread_mutex_unlock(&gGameLock);
    AKGameProfileEnd();
  };
  preloadSharedLibraries();
  AKGameInstallTimers();
  AKGameWatchProcess();
  AKGameWatchGameControllers();
  AKGameMetalPrepare();
  AKGameCrashGuardInstall();
  AKGameHeapBegin(appURL.lastPathComponent.stringByDeletingPathExtension);
  AKGameAudioBegin();
  // Global, as on macOS: its plugins (libYoYoGamepad) bind flat-namespace symbols to the program.
  void *image = dlopen(program.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (!image) {
    NSString *reason = [NSString stringWithFormat:@"it doesn't load: %s", dlerror()];
    undo();
    fail(reason);
    return -1;
  }
  int rebound = 0;
  for (NSString *prefix in gGameBundleReal && ![gGameBundleReal isEqualToString:gGameBundlePath] ? @[ gGameBundlePath, gGameBundleReal ] : @[ gGameBundlePath ]) {
    rebound += AKRebindSymbol(prefix.fileSystemRepresentation, "CFBundleGetMainBundle", (void *)gameCFMainBundle);
    rebound += AKRebindSymbol(prefix.fileSystemRepresentation, "_NSGetExecutablePath", (void *)gameExecutablePath);
  }
  gameLog(@"loaded (%d images of its own); %d main-bundle and program-path calls redirected", (int)gGameImageCount, rebound);
  AKGameTrackClasses();
  if (again) gameLog(@"%d of its images back as they were loaded, their initializers run again", freshStart(gGameBundlePath, gGameBundleReal));
  if (!loadedCopies) loadedCopies = [NSMutableDictionary dictionary];
  loadedCopies[appURL.path] = @[ copy, program ];
  noteOwnAllocator(image);

  NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:program];
  for (id a in arguments) if ([a isKindOfClass:NSString.class]) [args addObject:a];
  // Unity's own log (graphics setup, scripting errors) next to the app's logs: on a Mac it goes to
  // ~/Library/Logs, deep in this app's container.
  if ([NSFileManager.defaultManager fileExistsAtPath:[copy stringByAppendingPathComponent:@"Contents/Frameworks/UnityPlayer.dylib"]] &&
      ![args containsObject:@"-logFile"]) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    [args addObjectsFromArray:@[ @"-logFile", [docs stringByAppendingPathComponent:@"unity-player.log"] ]];
    gameLog(@"Unity's log: Documents/unity-player.log");
  }
  char **argv = calloc(args.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)args[i].UTF8String;
  keepConsole();
  pid_t pid = AKSpawnInProcess(program.fileSystemRepresentation, argv, NULL, "/");
  free(argv);
  if (pid < 0) {
    NSString *reason = [NSString stringWithFormat:@"it wouldn't start (%s)", strerror(errno)];
    restoreConsole();
    undo();
    fail(reason);
    return -1;
  }
  gGamePid = pid;
  AKInProcessDetach(pid);
  pthread_mutex_unlock(&gGameLock);
  gameLog(@"%@ running as pid %d%@", appURL.lastPathComponent, pid,
          gGameAppID ? [NSString stringWithFormat:@" (app %u)", gGameAppID] : @" (Steam gave no app id: no overlay)");
  dispatch_async(dispatch_get_main_queue(), ^{
    AKWHGameChanged();
    watchGameLoop(pid);
  });
  return pid;
}

pid_t AKLaunchMacApplication(NSURL *appURL, NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *environment,
                             NSError **error) {
  NSError *failure = nil;
  pid_t pid = launchMacApplication(appURL, arguments, environment, &failure);
  if (failure && error) *error = failure;
  return pid;
}
