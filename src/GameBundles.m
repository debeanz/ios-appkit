// The program inside a Mac bundle: Contents/MacOS/<CFBundleExecutable>.
//
// iOS's bundle code doesn't look there, so a Mac bundle has no executable to iOS: a game's
// plug-in bundles had no program and their code never loaded. Unity looks for a native plug-in
// as Contents/PlugIns/<name>.bundle and asks CFBundleCopyExecutableURL for its program;
// with none it fell back to dlopen("steam_api"), which failed, and the game's Steamworks code
// quit the game ("Unable to load DLL 'steam_api'"). So where iOS finds no program, a Mac
// bundle's is found the Mac's way: for NSBundle's executablePath/URL and loading (everyone's;
// a bundle iOS understands keeps its answer), and for the game's CFBundle calls (its images'
// imports): the executable URL, loading, and the function and data pointers of a bundle loaded
// that way.
#import "AKShimPrivate.h"
#import <dlfcn.h>
#import <objc/runtime.h>

NSString *AKMacBundleProgram(NSString *bundlePath) {
  if (!bundlePath.length) return nil;
  NSString *contents = [bundlePath stringByAppendingPathComponent:@"Contents"];
  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[contents stringByAppendingPathComponent:@"Info.plist"]];
  NSString *name = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"]
                                                                             : bundlePath.lastPathComponent.stringByDeletingPathExtension;
  NSString *program = [[contents stringByAppendingPathComponent:@"MacOS"] stringByAppendingPathComponent:name];
  return [NSFileManager.defaultManager fileExistsAtPath:program] ? program : nil;
}

static BOOL exists(NSString *path) { return path && [NSFileManager.defaultManager fileExistsAtPath:path]; }

#pragma mark NSBundle

static IMP gExecutablePath, gExecutableURL, gLoadAndReturnError;

static NSString *executablePath(NSBundle *self, SEL _cmd) {
  NSString *path = ((NSString * (*)(id, SEL))gExecutablePath)(self, _cmd);
  return exists(path) ? path : AKMacBundleProgram(self.bundlePath) ?: path;
}

static NSURL *executableURL(NSBundle *self, SEL _cmd) {
  NSURL *url = ((NSURL * (*)(id, SEL))gExecutableURL)(self, _cmd);
  if (exists(url.path)) return url;
  NSString *program = AKMacBundleProgram(self.bundlePath);
  return program ? [NSURL fileURLWithPath:program] : url;
}

static BOOL loadAndReturnError(NSBundle *self, SEL _cmd, NSError **error) {
  if (((BOOL (*)(id, SEL, NSError **))gLoadAndReturnError)(self, _cmd, error)) return YES;
  NSString *program = AKMacBundleProgram(self.bundlePath);
  if (!program || !dlopen(program.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) return NO;
  if (error) *error = nil;
  return YES;
}

__attribute__((constructor)) static void hookBundles(void) {
  Class bundle = NSBundle.class;
  gExecutablePath = method_setImplementation(class_getInstanceMethod(bundle, @selector(executablePath)), (IMP)executablePath);
  gExecutableURL = method_setImplementation(class_getInstanceMethod(bundle, @selector(executableURL)), (IMP)executableURL);
  gLoadAndReturnError = method_setImplementation(class_getInstanceMethod(bundle, @selector(loadAndReturnError:)), (IMP)loadAndReturnError);
}

#pragma mark A game's CFBundle calls

// Bundles loaded here (their path -> dlopen handle), for their function and data pointers.
static NSMutableDictionary<NSString *, NSValue *> *gLoaded;

static NSString *pathOf(CFBundleRef bundle) {
  CFURLRef url = bundle ? CFBundleCopyBundleURL(bundle) : NULL;
  NSString *path = url ? ((__bridge NSURL *)url).path : nil;
  if (url) CFRelease(url);
  return path;
}

static CFURLRef gameCopyExecutableURL(CFBundleRef bundle) {
  CFURLRef url = CFBundleCopyExecutableURL(bundle);
  if (url && exists(((__bridge NSURL *)url).path)) return url;
  NSString *program = AKMacBundleProgram(pathOf(bundle));
  if (!program) return url;
  if (url) CFRelease(url);
  return (__bridge_retained CFURLRef)[NSURL fileURLWithPath:program];
}

static void *loadedHandle(CFBundleRef bundle) {
  NSString *path = pathOf(bundle);
  @synchronized (NSBundle.class) { return path ? gLoaded[path].pointerValue : NULL; }
}

static Boolean loadMacBundle(CFBundleRef bundle) {
  NSString *path = pathOf(bundle), *program = AKMacBundleProgram(path);
  void *handle = program ? dlopen(program.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) : NULL;
  if (!handle) return false;
  @synchronized (NSBundle.class) {
    if (!gLoaded) gLoaded = [NSMutableDictionary dictionary];
    gLoaded[path] = [NSValue valueWithPointer:handle];
  }
  return true;
}

static Boolean gameLoadExecutable(CFBundleRef bundle) {
  return CFBundleLoadExecutable(bundle) || loadMacBundle(bundle);
}

static Boolean gameLoadExecutableAndReturnError(CFBundleRef bundle, CFErrorRef *error) {
  if (CFBundleLoadExecutableAndReturnError(bundle, error)) return true;
  if (!loadMacBundle(bundle)) return false;
  if (error && *error) { CFRelease(*error); *error = NULL; }
  return true;
}

static Boolean gameIsExecutableLoaded(CFBundleRef bundle) {
  return CFBundleIsExecutableLoaded(bundle) || loadedHandle(bundle);
}

static void *symbolOf(CFBundleRef bundle, CFStringRef name) {
  void *handle = loadedHandle(bundle);
  return handle && name ? dlsym(handle, ((__bridge NSString *)name).UTF8String) : NULL;
}

static void *gameFunctionPointer(CFBundleRef bundle, CFStringRef name) {
  return CFBundleGetFunctionPointerForName(bundle, name) ?: symbolOf(bundle, name);
}

static void *gameDataPointer(CFBundleRef bundle, CFStringRef name) {
  return CFBundleGetDataPointerForName(bundle, name) ?: symbolOf(bundle, name);
}

void AKGameBindBundles(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    static const struct { const char *name; void *fn; } table[] = {
      { "_CFBundleCopyExecutableURL", (void *)gameCopyExecutableURL },
      { "_CFBundleLoadExecutable", (void *)gameLoadExecutable },
      { "_CFBundleLoadExecutableAndReturnError", (void *)gameLoadExecutableAndReturnError },
      { "_CFBundleIsExecutableLoaded", (void *)gameIsExecutableLoaded },
      { "_CFBundleGetFunctionPointerForName", (void *)gameFunctionPointer },
      { "_CFBundleGetDataPointerForName", (void *)gameDataPointer },
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
      if (!strcmp(symbol, table[i].name)) return table[i].fn;
    return NULL;
  });
}
