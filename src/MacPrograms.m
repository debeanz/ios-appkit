// Mac programs Steam starts: its games.
//
// Steam downloads a game's Mac build and starts it with -[NSWorkspace launchApplicationAtURL:
// options:configuration:error:]. iOS starts no second process, so the game runs in this one,
// the way Steam Helper does (InProcessExec.m): its program is loaded as a library and its
// main() runs on a thread of its own, with a stand-in pid Steam can watch. Before that, every
// Mach-O in the game's .app gets the edits the IPA build gives Steam's own binaries
// (tools/package-ipa.sh, exec-to-dylib.js), here on the device because the game only arrives
// here:
//   - the arm64 code alone (an Intel-only game can't run: iOS has no x86 translation);
//   - platform macOS relabelled iOS (LC_BUILD_VERSION / LC_VERSION_MIN);
//   - each system library it links routed as the client's are (client/routes.json from the
//     build; a library Steam doesn't use goes to iOS's own copy if there is one, else to the
//     shim), @executable_path made absolute (in this process it would mean Steam's program);
//   - its code signature dropped (the edits void it; loading unsigned code takes JIT, which
//     LiveContainer uses to bypass the check);
//   - the program made a library (exec-to-dylib: MH_DYLIB, a one-page __PAGEZERO, the
//     dynamic-linker command become an rpath, an id), keeping LC_MAIN for its main().
// A file already done (thin, labelled iOS) is left alone, so a game is converted once per
// download. Before it loads, everything it imports that isn't here yet is logged at once.
// While the game runs, NSBundle's and CoreFoundation's main bundle and _NSGetExecutablePath
// are the game's when the game asks, its main thread gets an app delegate and event loop of
// its own (NSApplication.m), and its windows go above Steam's interface (NSWindow.m).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>
#import <pthread.h>
#import "AKShimPrivate.h"
#import "AppKitShim/LibSystemMac.h"

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

static NSString *shimPath(void) {
  return [frameworksDir() stringByAppendingPathComponent:@"AppKitShim.framework/AppKitShim"];
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

// The build's routes for the client's system libraries: {macOS path: {action, to}}.
static NSDictionary<NSString *, NSDictionary *> *clientRoutes(void) {
  static NSDictionary *routes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString *app = shimCorePath().stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    NSData *json = [NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"client/routes.json"]];
    NSDictionary *all = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    routes = [all[@"routes"] isKindOfClass:NSDictionary.class] ? all[@"routes"] : @{};
    if (!routes.count) gameLog(@"no client/routes.json in the app; system libraries are routed by rule only");
  });
  return routes;
}

// Where a game binary's library reference should point here. A name already routed comes
// back unchanged, so converting again is harmless.
static NSString *routeLibrary(NSString *name, NSString *programDir, NSString *fileDir) {
  if ([name hasPrefix:@"@executable_path/"]) return fromExecutablePath(name, programDir, fileDir);
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
  if (exec && !isProgram) return nil;   // another program inside the app (a helper): not ours to run
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

  NSMutableData *out = [NSMutableData data];
  uint32_t ncmds = 0;
  struct rpath_command rpathHeader = { LC_RPATH, 0, { sizeof(struct rpath_command) } };
  NSData *rpathHeaderData = [NSData dataWithBytes:&rpathHeader length:sizeof rpathHeader];
  off = 0;
  for (uint32_t i = 0; i < mh->ncmds; i++) {
    const struct load_command *lc = (const void *)(cmds + off);
    NSData *original = [NSData dataWithBytes:lc length:lc->cmdsize];
    off += lc->cmdsize;
    switch (lc->cmd) {
      case LC_CODE_SIGNATURE:
        continue;   // voided by these edits
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
  [out appendData:stringCommand(LC_RPATH, sizeof rpathHeader, rpathHeaderData, frameworks)];
  ncmds++;
  if (exec && !hasId) {
    struct dylib_command header = { LC_ID_DYLIB, 0, { { sizeof(struct dylib_command) }, 0, 0x10000, 0x10000 } };
    [out appendData:stringCommand(LC_ID_DYLIB, sizeof header, [NSData dataWithBytes:&header length:sizeof header], path)];
    ncmds++;
  }
  if (sizeof *mh + out.length > firstSection)
    return [NSString stringWithFormat:@"no room in its header (%llu bytes free, %lu needed)",
            firstSection - sizeof *mh, (unsigned long)out.length];
  // Already as it should be: left alone.
  if (thin && !exec && mh->ncmds == ncmds && mh->sizeofcmds == out.length && !memcmp(cmds, out.bytes, out.length)) return nil;

  NSMutableData *m = [code mutableCopy];
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

// Every Mach-O in the app converted; nil when the program can run, else why not.
static NSString *convertApp(NSBundle *app, NSString *program) {
  NSString *programDir = program.stringByDeletingLastPathComponent;
  unsigned converted = 0, kept = 0, skipped = 0;
  BOOL changed;
  NSString *why = convertFile(program, programDir, app.bundlePath, YES, &changed);
  if (why) return [NSString stringWithFormat:@"its program can't run here: %@", why];
  converted += changed;
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
    if (changed) converted++; else kept++;
  }
  gameLog(@"%@: %u binaries converted for iOS, %u already were, %u left out", app.bundlePath.lastPathComponent, converted, kept, skipped);
  return nil;
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
    if ([lib isEqualToString:kShimName]) lib = shimPath();
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
static NSBundle *gGameBundle;
static NSString *gGameProgram;
static NSString *gGameBundlePath;   // with a trailing slash
static NSString *gGameBundleReal;   // the same through realpath (/var is /private/var), as dyld may name it
static pid_t gGamePid;
static CFRunLoopRef gGameRunLoop;

BOOL AKGameIsRunning(void) { return gGameProgram != nil; }
pid_t AKGamePid(void) { return gGamePid; }
NSBundle *AKGameBundleForPid(pid_t pid) { return pid && pid == gGamePid ? gGameBundle : nil; }

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

static void imageAdded(const struct mach_header *header, intptr_t slide) {
  NSString *bundlePath = gGameBundlePath, *real = gGameBundleReal;
  Dl_info info;
  if (!bundlePath || !dladdr(header, &info) || !info.dli_fname || !(hasPrefix(info.dli_fname, bundlePath) || hasPrefix(info.dli_fname, real)))
    return;
  const struct mach_header_64 *mh = (const void *)header;
  const uint8_t *lc = (const uint8_t *)(mh + 1);
  for (uint32_t i = 0; i < mh->ncmds; i++, lc += ((const struct load_command *)lc)->cmdsize) {
    const struct segment_command_64 *seg = (const void *)lc;
    if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__TEXT", 16)) continue;
    int n = gGameImageCount;
    if (n >= 128) return;
    gGameImages[n] = (ak_range){ (uintptr_t)header, (uintptr_t)header + seg->vmsize };
    gGameImageCount = n + 1;
    return;
  }
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
  NSApplication *app = NSApplication.sharedApplication;
  NSDictionary *info = gGameBundle.infoDictionary;
  gameLog(@"NSApplicationMain: principal class %@, main nib %@", info[@"NSPrincipalClass"] ?: @"-", info[@"NSMainNibFile"] ?: @"-");
  if (!app.delegate) {
    Class c = appDelegateClass();
    if (c) {
      app.delegate = [c new];
      gameLog(@"its app delegate: %s, made directly (nibs aren't loaded here)", class_getName(c));
    } else {
      gameLog(@"no app delegate found in it, and its nib can't be loaded here");
    }
  }
  [app run];
  return 0;
}

void AKGameNoteRunLoop(void) {
  if (gGameRunLoop || !AKIsGameThread()) return;
  pthread_mutex_lock(&gGameLock);
  if (!gGameRunLoop) gGameRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
  pthread_mutex_unlock(&gGameLock);
}

// Steam stopping the game (kill, or terminate on its NSRunningApplication): asked to quit as
// AppKit asks an app, -[NSApp terminate:] on its main thread, which ends it.
static void gameSignalled(pid_t pid, int sig) {
  if (pid != gGamePid || sig == 0) return;
  pthread_mutex_lock(&gGameLock);
  CFRunLoopRef loop = gGameRunLoop ? (CFRunLoopRef)CFRetain(gGameRunLoop) : NULL;
  pthread_mutex_unlock(&gGameLock);
  if (!loop) { gameLog(@"can't ask it to quit: it isn't running an event loop"); return; }
  gameLog(@"asking it to quit (signal %d)", sig);
  CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ [NSApp terminate:nil]; });
  CFRunLoopWakeUp(loop);
  CFRelease(loop);
}

static void gameEnded(pid_t pid, int status) {
  pthread_mutex_lock(&gGameLock);   // held by the launcher until gGamePid is set
  BOOL ours = pid == gGamePid;
  pthread_mutex_unlock(&gGameLock);
  if (!ours) return;
  gameLog(@"%@ ended (%d)", gGameBundle.bundlePath.lastPathComponent, status);
  AKGameDidEnd(pid);
  AKGameAppEnded();
  pthread_mutex_lock(&gGameLock);
  gGamePid = 0;
  gGameProgram = nil;
  gGameBundle = nil;
  gGameBundlePath = gGameBundleReal = nil;
  gGameImageCount = 0;
  if (gGameRunLoop) CFRelease(gGameRunLoop);
  gGameRunLoop = NULL;
  pthread_mutex_unlock(&gGameLock);
  dispatch_async(dispatch_get_main_queue(), ^{ AKGameWindowsClose(); });
}

// The program inside a Mac .app: Contents/MacOS/<CFBundleExecutable>, read directly if
// NSBundle (on iOS) doesn't find it.
static NSString *programOf(NSBundle *app, NSURL *appURL) {
  NSString *program = app.executablePath;
  if (program && [NSFileManager.defaultManager fileExistsAtPath:program]) return program;
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[appURL URLByAppendingPathComponent:@"Contents/Info.plist"]];
  NSString *name = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"]
                                                                             : appURL.lastPathComponent.stringByDeletingPathExtension;
  program = [[appURL.path stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:name];
  return [NSFileManager.defaultManager fileExistsAtPath:program] ? program : nil;
}

pid_t AKLaunchMacApplication(NSURL *appURL, NSArray<NSString *> *arguments, NSDictionary<NSString *, NSString *> *environment,
                             NSError **error) {
  appURL = appURL.URLByStandardizingPath;
  NSBundle *app = [NSBundle bundleWithURL:appURL];
  NSString *program = programOf(app, appURL);
  void (^fail)(NSString *) = ^(NSString *why) {
    gameLog(@"can't start %@: %@", appURL.lastPathComponent, why);
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOEXEC userInfo:@{ NSLocalizedDescriptionKey: why }];
  };
  if (!app || !program) { fail(@"no program in it"); return -1; }
  if (gGameProgram) { fail(@"a game is already running"); return -1; }
  gameLog(@"starting %@ (%@), program %@, resources %@", appURL.lastPathComponent, app.bundleIdentifier ?: @"no bundle id",
          program.lastPathComponent, app.resourcePath ?: @"not found");
  NSString *why = convertApp(app, program);
  if (why) { fail(why); return -1; }
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
  pthread_mutex_lock(&gGameLock);
  gGameBundle = app;
  gGameBundlePath = [app.bundlePath stringByAppendingString:@"/"];
  char real[PATH_MAX];
  gGameBundleReal = realpath(app.bundlePath.fileSystemRepresentation, real) ? [@(real) stringByAppendingString:@"/"] : nil;
  gGameProgram = program;
  gGameImageCount = 0;
  static dispatch_once_t watchImages;
  dispatch_once(&watchImages, ^{ _dyld_register_func_for_add_image(imageAdded); });
  for (uint32_t i = 0; i < _dyld_image_count(); i++) imageAdded(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
  [environment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
    if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSString.class] && ![key hasPrefix:@"DYLD_"])
      setenv(key.UTF8String, value.UTF8String, 1);
  }];

  // Loaded here first, so its main-bundle calls are redirected before its main() runs.
  void (^undo)(void) = ^{
    gGameBundle = nil;
    gGameBundlePath = gGameBundleReal = nil;
    gGameProgram = nil;
    gGameImageCount = 0;
    pthread_mutex_unlock(&gGameLock);
  };
  void *image = dlopen(program.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
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

  NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObject:program];
  for (id a in arguments) if ([a isKindOfClass:NSString.class]) [args addObject:a];
  char **argv = calloc(args.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < args.count; i++) argv[i] = (char *)args[i].UTF8String;
  pid_t pid = AKSpawnInProcess(program.fileSystemRepresentation, argv, NULL, "/");
  free(argv);
  if (pid < 0) {
    NSString *reason = [NSString stringWithFormat:@"it wouldn't start (%s)", strerror(errno)];
    undo();
    fail(reason);
    return -1;
  }
  gGamePid = pid;
  AKInProcessDetach(pid);
  pthread_mutex_unlock(&gGameLock);
  gameLog(@"%@ running as pid %d", appURL.lastPathComponent, pid);
  return pid;
}
