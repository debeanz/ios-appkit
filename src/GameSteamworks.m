// A game's Steamworks talks to Steam through a steamclient of its own (MacPrograms.m makes it).
//
// The game's steam_api loads steamclient.dylib from Steam's folder; while a game runs, that load
// gets the game's copy instead: its own client state (the game's app ID, its own pipes), talking
// to Steam's engine over Steam's IPC as a Mac game's process does. Its pid is the one Steam knows
// the game by (the stand-in pid it was started as), so Steam tells the game's pipe from its own
// and from Steam's interface, which runs in the same process, and tracks it as that game's.
#import "AKShimPrivate.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

static NSString *gCopy;   // the running game's steamclient, or nil

void AKGameSetSteamclient(NSString *path) { @synchronized (NSBundle.class) { gCopy = path; } }

// The game's pid, as Steam started it, for the copy's own calls (its IPC sends its pid).
static pid_t gamePid(void) {
  pid_t pid = AKGamePid();
  return pid ? pid : getpid();
}

static uint64_t gameProcessId(void) { return (uint64_t)gamePid(); }

static void bindCopy(void *handle) {
  void *anything = dlsym(handle, "CreateInterface");
  Dl_info info;
  if (!anything || !dladdr(anything, &info)) return;
  const struct mach_header *header = info.dli_fbase;
  static NSMutableSet<NSValue *> *bound;
  @synchronized (NSBundle.class) {
    if (!bound) bound = [NSMutableSet set];
    NSValue *key = [NSValue valueWithPointer:header];
    if ([bound containsObject:key]) return;
    [bound addObject:key];
  }
  intptr_t slide = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++)
    if (_dyld_get_image_header(i) == header) slide = _dyld_get_image_vmaddr_slide(i);
  int changed = AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (!strcmp(symbol, "_getpid")) return (void *)gamePid;
    if (!strcmp(symbol, "_ThreadGetCurrentProcessId")) return (void *)gameProcessId;
    return NULL;
  });
  fprintf(stderr, "[AppKitShim] game: its Steamworks client is its own steamclient (as on a Mac), as pid %d to Steam (%d calls)\n",
          gamePid(), changed);
}

// Anything else steam_api loads, as if it had called dlopen itself (relative paths resolve from it).
static void *dlopenFrom(const char *path, int mode, void *caller) {
  static void *(*from)(const char *, int, void *);
  static dispatch_once_t once;
  dispatch_once(&once, ^{ from = (void *(*)(const char *, int, void *))dlsym(RTLD_DEFAULT, "dlopen_from"); });
  return from ? from(path, mode, caller) : dlopen(path, mode);
}

static void *gameDlopen(const char *path, int mode) {
  void *caller = __builtin_return_address(0);
  NSString *copy;
  @synchronized (NSBundle.class) { copy = gCopy; }
  size_t n = path ? strlen(path) : 0;
  if (copy && AKGameIsRunning() && n >= 18 && !strcmp(path + n - 18, "/steamclient.dylib")) {
    void *handle = dlopen(copy.fileSystemRepresentation, mode);
    if (handle) {
      if (!(mode & RTLD_NOLOAD)) bindCopy(handle);
      return handle;
    }
    if (!(mode & RTLD_NOLOAD)) fprintf(stderr, "[AppKitShim] game: its own steamclient didn't load (%s): it shares Steam's\n", dlerror());
  }
  return dlopenFrom(path, mode, caller);
}

// The game's Steamworks library (libsteam_api.dylib, or Unity's steam_api.bundle) is the one that
// loads steamclient.
void AKGameBindSteamworks(const struct mach_header *header, intptr_t slide, const char *path) {
  const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
  if (strncmp(name, "libsteam_api", 12) && strcmp(name, "steam_api")) return;
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    return strcmp(symbol, "_dlopen") ? NULL : (void *)gameDlopen;
  });
}
