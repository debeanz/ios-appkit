// Every Mac game installed, checked before it is played: Documents/games-report.txt says for
// each what it is made with and whether anything it uses is missing here, so the gaps across a
// whole library show up in one report rather than one failed launch at a time.
//
// Each binary in a game's .app is judged as a launch would judge it (AKGameBinaryGaps in
// MacPrograms.m: routed the same way, every strong import looked up where it would bind). Also
// told: code iOS can't run at all (Intel only), and engines that compile the game's code to
// machine code as it runs (Mono, .NET, Java, JavaScript), which iOS doesn't let this app do.
// "Ready to try" means nothing it links is missing; whether it then runs right is only known
// once it does.
//
// Quietly, in the background: the first look two minutes after the app starts, then one every
// five minutes that only goes further when Steam's install manifests changed, never while a game
// runs, and a game is looked at again only when it or this app changed.
#import "AKShimPrivate.h"
#import <dlfcn.h>

static NSString *const kCacheKey = @"AKInstalledGamesCheck";   // {appid: {stamp, text, verdict}}

static NSString *steamApps(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam/steamapps"];
}

// This app's build, so a newer one (which may lack less) looks again.
static NSString *appStamp(void) {
  Dl_info info;
  if (!dladdr((const void *)&appStamp, &info) || !info.dli_fname) return @"";
  NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:@(info.dli_fname) error:nil];
  return [NSString stringWithFormat:@"%llu-%.0f", [a[NSFileSize] unsignedLongLongValue], [a[NSFileModificationDate] timeIntervalSince1970]];
}

static NSString *acfValue(NSString *acf, NSString *key) {
  NSString *pattern = [NSString stringWithFormat:@"\"%@\"\\s+\"([^\"]*)\"", key];
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
  NSTextCheckingResult *m = [re firstMatchInString:acf options:0 range:NSMakeRange(0, acf.length)];
  return m ? [acf substringWithRange:[m rangeAtIndex:1]] : nil;
}

static BOOL isMachOFile(NSString *path) {
  FILE *f = fopen(path.fileSystemRepresentation, "rb");
  if (!f) return NO;
  uint32_t magic = 0;
  BOOL yes = fread(&magic, 4, 1, f) == 1 && (magic == 0xfeedfacf || magic == 0xbebafeca || magic == 0xbfbafeca);
  fclose(f);
  return yes;
}

// The .app bundles in a game's folder (some sit a folder or two down).
static NSArray<NSString *> *appsIn(NSString *dir) {
  NSMutableArray *apps = [NSMutableArray array];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSDirectoryEnumerator *walk = [fm enumeratorAtURL:[NSURL fileURLWithPath:dir] includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                                            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
  for (NSURL *url in walk) {
    if (walk.level > 3) { [walk skipDescendants]; continue; }
    if (![url.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
    [apps addObject:url.path];
    [walk skipDescendants];
  }
  return apps;
}

// What a game is made with, by the files its engine ships; and whether that engine compiles
// the game's code as it runs.
static NSString *engineOf(NSSet<NSString *> *names, NSString *program, NSString **codegen) {
  BOOL (^has)(NSString *) = ^BOOL(NSString *n) { return [names containsObject:n]; };
  BOOL (^hasSuffix)(NSString *) = ^BOOL(NSString *s) {
    for (NSString *n in names) if ([n hasSuffix:s]) return YES;
    return NO;
  };
  BOOL mono = has(@"libmonobdwgc-2.0.dylib") || has(@"libmonosgen-2.0.dylib") || has(@"libmono-2.0.dylib") || has(@"MonoBleedingEdge");
  *codegen = nil;
  if (mono) *codegen = @"Mono";
  else if (has(@"libcoreclr.dylib")) *codegen = @".NET (CoreCLR)";
  else if (has(@"libjvm.dylib")) *codegen = @"Java";
  else if (has(@"Electron Framework.framework") || has(@"nwjs Framework.framework") || has(@"libnode.dylib")) *codegen = @"JavaScript (V8)";
  if (has(@"UnityPlayer.dylib")) return has(@"GameAssembly.dylib") ? @"Unity (IL2CPP)" : mono ? @"Unity (Mono)" : @"Unity";
  if (has(@"game.ios") || [program isEqualToString:@"Mac_Runner"]) return @"GameMaker";
  if (hasSuffix(@".pck") || [program.lowercaseString hasPrefix:@"godot"]) return @"Godot";
  if (has(@"love.framework") || [program isEqualToString:@"love"]) return @"LÖVE";
  if (has(@"UE4") || has(@"UE")) return @"Unreal Engine";
  if (has(@"renpy") || hasSuffix(@".rpa")) return @"Ren'Py";
  if (has(@"FNA.dll")) return @"FNA";
  if (has(@"MonoGame.Framework.dll")) return @"MonoGame";
  if (has(@"nwjs Framework.framework")) return @"NW.js";
  if (has(@"Electron Framework.framework")) return @"Electron";
  if (has(@"libjvm.dylib")) return @"Java";
  if (has(@"SDL3.framework") || hasSuffix(@"libSDL3.dylib") || hasSuffix(@"libSDL3.0.dylib")) return @"SDL3";
  if (has(@"SDL2.framework") || hasSuffix(@"libSDL2.dylib") || hasSuffix(@"libSDL2-2.0.0.dylib")) return @"SDL2";
  return nil;
}

// One game's lines in the report, and its verdict: ready, gaps, notyet or cannot.
static NSString *checkGame(NSString *name, NSString *appid, NSString *dir, NSString **verdict) {
  NSMutableString *text = [NSMutableString string];
  NSArray<NSString *> *apps = appsIn(dir);
  if (!apps.count) {
    *verdict = @"cannot";
    return [NSString stringWithFormat:@"%@ (app %@)\n  can't run here: no Mac app in its folder\n", name, appid];
  }
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *missing = [NSMutableDictionary dictionary];
  NSMutableSet<NSString *> *unchecked = [NSMutableSet set];
  NSMutableArray<NSString *> *leftOut = [NSMutableArray array];
  NSMutableSet<NSString *> *names = [NSMutableSet set];
  NSString *cannot = nil, *programName = nil;
  BOOL luajit = NO;
  NSData *luajitMark = [@"luaJIT_setmode" dataUsingEncoding:NSUTF8StringEncoding];
  for (NSString *app in apps) {
    NSString *program = [NSBundle bundleWithPath:app].executablePath;
    if (!programName) programName = program.lastPathComponent;
    NSDirectoryEnumerator *walk = [fm enumeratorAtPath:app];
    for (NSString *rel in walk) {
      [names addObject:rel.lastPathComponent];
      if (![walk.fileAttributes[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
      NSString *path = [app stringByAppendingPathComponent:rel];
      NSString *ext = rel.pathExtension.lowercaseString;
      if (ext.length && ![@[ @"dylib", @"so", @"bundle", @"plugin" ] containsObject:ext]) continue;
      if (!isMachOFile(path)) continue;
      BOOL isProgram = [path isEqualToString:program];
      NSDictionary *gaps = AKGameBinaryGaps(path, program.stringByDeletingLastPathComponent, isProgram);
      // LuaJIT: a library named for Lua, or built into a program of ordinary size (a 100 MB
      // engine isn't read through for it).
      unsigned long long size = [walk.fileAttributes[NSFileSize] unsignedLongLongValue];
      if (!luajit && ([rel.lastPathComponent.lowercaseString containsString:@"lua"] || (isProgram && size < (64ull << 20)))) {
        NSData *bytes = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        luajit = bytes && [bytes rangeOfData:luajitMark options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
      }
      if (gaps[@"helper"]) continue;
      if (gaps[@"cannot"]) {
        if (isProgram) cannot = gaps[@"cannot"];
        else [leftOut addObject:[NSString stringWithFormat:@"%@ (%@)", rel.lastPathComponent, gaps[@"cannot"]]];
        continue;
      }
      [unchecked addObjectsFromArray:gaps[@"unchecked"] ?: @[]];
      NSDictionary<NSString *, NSArray *> *m = gaps[@"missing"];
      for (NSString *lib in m) {
        NSMutableOrderedSet *set = missing[lib] ?: (missing[lib] = [NSMutableOrderedSet orderedSet]);
        [set addObjectsFromArray:m[lib]];
      }
    }
  }
  NSString *codegen = nil;
  NSString *engine = engineOf(names, programName, &codegen);
  [text appendFormat:@"%@ (app %@)%@\n", name, appid, engine ? [@" - " stringByAppendingString:engine] : @""];
  NSUInteger count = 0;
  for (NSOrderedSet *set in missing.allValues) count += set.count;
  if (cannot) {
    *verdict = @"cannot";
    [text appendFormat:@"  can't run here: its program is %@%@\n", cannot,
                       [cannot isEqualToString:@"Intel only"] ? @" (no Apple Silicon build to run)" : @""];
    return text;
  }
  if (codegen) {
    *verdict = @"notyet";
    [text appendFormat:@"  not yet: %@ compiles the game's code to machine code as it runs, which iOS doesn't let this app do\n", codegen];
  } else {
    *verdict = count ? @"gaps" : @"ready";
    if (!count) [text appendString:@"  ready to try: nothing it uses is missing here\n"];
  }
  if (luajit) [text appendString:@"  LuaJIT: runs on its interpreter here (its compiler is kept off)\n"];
  if (count) {
    [text appendFormat:@"  %lu names it uses are missing here:\n", (unsigned long)count];
    for (NSString *lib in [missing.allKeys sortedArrayUsingSelector:@selector(compare:)])
      [text appendFormat:@"    from %@: %@\n", lib, [missing[lib].array componentsJoinedByString:@" "]];
  }
  if (unchecked.count) [text appendFormat:@"  not checked yet: %@ (once an OpenGL game has run)\n", [unchecked.allObjects componentsJoinedByString:@", "]];
  if (leftOut.count) [text appendFormat:@"  left out, matters only if the game loads it: %@\n", [leftOut componentsJoinedByString:@", "]];
  return text;
}

static NSString *manifestsSignature(void) {
  NSMutableString *sig = [NSMutableString string];
  NSFileManager *fm = NSFileManager.defaultManager;
  for (NSString *n in [[fm contentsOfDirectoryAtPath:steamApps() error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
    if (![n hasPrefix:@"appmanifest_"]) continue;
    NSDictionary *a = [fm attributesOfItemAtPath:[steamApps() stringByAppendingPathComponent:n] error:nil];
    [sig appendFormat:@"%@:%.0f;", n, [a[NSFileModificationDate] timeIntervalSince1970]];
  }
  return sig;
}

static void checkLibrary(void) {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSDictionary *cache = [defaults dictionaryForKey:kCacheKey] ?: @{};
  NSMutableDictionary *next = [NSMutableDictionary dictionary];
  NSString *build = appStamp();
  NSMutableArray<NSString *> *entries = [NSMutableArray array];
  NSCountedSet<NSString *> *verdicts = [NSCountedSet set];
  unsigned looked = 0;
  for (NSString *n in [[fm contentsOfDirectoryAtPath:steamApps() error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
    if (![n hasPrefix:@"appmanifest_"] || ![n hasSuffix:@".acf"]) continue;
    NSString *acf = [NSString stringWithContentsOfFile:[steamApps() stringByAppendingPathComponent:n] encoding:NSUTF8StringEncoding error:nil];
    NSString *appid = acfValue(acf, @"appid"), *name = acfValue(acf, @"name"), *dir = acfValue(acf, @"installdir");
    if (!acf || !appid || !dir || !([acfValue(acf, @"StateFlags") intValue] & 4)) continue;   // 4: fully installed
    if ([appid isEqualToString:@"228980"]) continue;   // Steamworks Common Redistributables
    NSString *stamp = [NSString stringWithFormat:@"%@ %@ %@", acfValue(acf, @"buildid") ?: @"", acfValue(acf, @"LastUpdated") ?: @"", build];
    NSDictionary *had = cache[appid];
    NSString *text, *verdict;
    if ([had[@"stamp"] isEqualToString:stamp] && had[@"text"] && had[@"verdict"]) {
      text = had[@"text"];
      verdict = had[@"verdict"];
    } else {
      @autoreleasepool {
        text = checkGame(name ?: dir, appid, [steamApps() stringByAppendingPathComponent:[@"common" stringByAppendingPathComponent:dir]], &verdict);
      }
      looked++;
    }
    next[appid] = @{ @"stamp": stamp, @"text": text, @"verdict": verdict };
    [entries addObject:text];
    [verdicts addObject:verdict];
  }
  [defaults setObject:next forKey:kCacheKey];
  NSString *summary = [NSString stringWithFormat:@"%lu Mac games installed: %lu ready to try, %lu with names missing here, %lu not yet (code compiled as they run), %lu can't run here",
                       (unsigned long)entries.count, (unsigned long)[verdicts countForObject:@"ready"], (unsigned long)[verdicts countForObject:@"gaps"],
                       (unsigned long)[verdicts countForObject:@"notyet"], (unsigned long)[verdicts countForObject:@"cannot"]];
  NSDateFormatter *when = [NSDateFormatter new];
  when.dateFormat = @"yyyy-MM-dd HH:mm";
  NSString *report = [NSString stringWithFormat:@"Mac games installed here, checked %@\n%@\n\n%@", [when stringFromDate:NSDate.date], summary,
                      [entries componentsJoinedByString:@"\n"]];
  NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  [report writeToFile:[docs stringByAppendingPathComponent:@"games-report.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  fprintf(stderr, "[AppKitShim] games: %s (%u looked at afresh; Documents/games-report.txt)\n", summary.UTF8String, looked);
}

static void scheduleCheck(int64_t seconds) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
    static NSString *lastSignature;
    if (AKGameIsRunning()) { scheduleCheck(60); return; }
    NSString *signature = manifestsSignature();
    if (![signature isEqualToString:lastSignature]) {
      lastSignature = signature;
      @autoreleasepool { checkLibrary(); }
    }
    scheduleCheck(300);
  });
}

__attribute__((constructor)) static void startChecking(void) {
  scheduleCheck(120);
}
