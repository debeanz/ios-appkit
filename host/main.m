// Steam-on-iOS app host.
//
// This is the app's main executable — the thing iOS launches. It does what the Mac
// launcher (steam_osx, which iOS can't run) does before handing over to the client: load
// the client's dylibs against the shim, set up the environment, chdir into the client,
// and call steamui.dylib's SteamDllMainEx(argc, argv, pump) — the call steam_osx makes,
// recovered from its arm64 code with Ghidra.
//
// On a device there is no console, so everything is written to Documents (visible in the
// Files app): launch.log (this host's steps, flushed line by line, plus the load address
// of every Steam image), steam-console.log (Steam's stdout/stderr), crash.log (signal or
// uncaught Objective-C exception with a backtrace) and steam-logs/ (Steam's own logs).
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <errno.h>
#import <execinfo.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <pthread.h>
#import <signal.h>
#import <sys/resource.h>
#import <sys/ucontext.h>
#import <unistd.h>

static UITextView *gLog;
static NSMutableString *gBuf;
static char gCrashPath[1024];
static char gBundlePath[1024];

static NSString *docsDir(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// Path to Documents/launch.log — the log survives a crash only if it's on disk, so every
// line is flushed there immediately (not just at the end).
static NSString *logPath(void) {
  return [docsDir() stringByAppendingPathComponent:@"launch.log"];
}

static void hostlog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSLog(@"[host] %@", line);
  NSString *snapshot;
  @synchronized([NSMutableString class]) { // threads log at once (Steam's, the web helper's)
    if (!gBuf) gBuf = [NSMutableString string];
    [gBuf appendFormat:@"%@\n", line];
    // Flush the whole buffer to disk each time: if the very next call kills the process,
    // the log up to here is already on disk for pulling off the device.
    [gBuf writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    snapshot = [gBuf copy];
  }
  // Mirror to screen. The on-disk log above is the reliable record across a crash; this
  // is the convenience view (Steam's windows cover it once they show).
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gLog) { gLog.text = snapshot; [gLog scrollRangeToVisible:NSMakeRange(snapshot.length, 0)]; }
  });
}

// Resolve a path inside the .app bundle.
static NSString *inApp(NSString *rel) {
  return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:rel];
}

// The client (steam_osx's own directory on a Mac), Steam's log folder (in Documents, so
// it can be pulled off the device) and Steam's data root (in this app's container).
static NSString *clientDir(void) { return inApp(@"client"); }
static NSString *logsDir(void) { return [docsDir() stringByAppendingPathComponent:@"steam-logs"]; }
static NSString *steamRoot(void) {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
}

#pragma mark Crash and console capture

static void writeStr(int fd, const char *s) { if (fd >= 0) write(fd, s, strlen(s)); }

// Fatal signal: record which, where, and the backtrace in Documents/crash.log (and the
// console log), then die the normal way. Runs on an alternate stack so a stack overflow
// can still report.
//
// SIGSYS is handled differently: the iOS sandbox raises it when the client makes a system
// call it isn't allowed to (the SysV-semaphore crash was one). Rather than die, log which
// call it was and resume with an error return (x0 = -ENOSYS), advancing past the trapping
// instruction — so one run surfaces every blocked call, not just the first, and the client
// takes its own "this failed" path. The right fix for each is to provide it in the shim, as
// the semaphores now are; this keeps the process alive to find the next one.
static void onFatalSignal(int sig, siginfo_t *info, void *uap) {
  int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
  char line[256];
  if (sig == SIGSYS) {
    ucontext_t *uc = (ucontext_t *)uap;
    unsigned long sysno = uc ? (unsigned long)uc->uc_mcontext->__ss.__x[16] : 0;  // arm64 syscall # in x16
    void *pc = uc ? (void *)uc->uc_mcontext->__ss.__pc : NULL;
    snprintf(line, sizeof line, "\n*** blocked system call %lu at pc %p — returning ENOSYS and continuing\n", sysno, pc);
    writeStr(fd, line); writeStr(2, line);
    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, fd);
    backtrace_symbols_fd(frames, n, 2);
    if (fd >= 0) close(fd);
    if (uc) {
      uc->uc_mcontext->__ss.__x[0] = (uint64_t)(-ENOSYS);  // the call "fails"
      uc->uc_mcontext->__ss.__pc += 4;                     // step over the trapping instruction
    }
    return;
  }
  char thread[64] = "";
  pthread_getname_np(pthread_self(), thread, sizeof thread);
  snprintf(line, sizeof line, "\n*** crashed: signal %d (SIG%s), fault address %p, thread \"%s\"%s\n",
           sig, sig < NSIG ? sys_signame[sig] : "?", info ? info->si_addr : NULL, thread,
           sig == SIGTRAP ? " (a trap: Chromium's CHECK/NOTREACHED, or a Swift/ObjC runtime trap)" : "");
  writeStr(fd, line); writeStr(2, line);
  void *frames[96];
  int n = backtrace(frames, 96);
  backtrace_symbols_fd(frames, n, fd);
  backtrace_symbols_fd(frames, n, 2);
  // Every image from the app, including ones loaded after startup (the web helper), so each
  // frame's address maps to image + offset.
  writeStr(fd, "images:\n");
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name || !strstr(name, gBundlePath)) continue;
    snprintf(line, sizeof line, "  %p  %s\n", (void *)_dyld_get_image_header(i), strrchr(name, '/') + 1);
    writeStr(fd, line);
  }
  if (fd >= 0) close(fd);
  signal(sig, SIG_DFL);
  raise(sig);
}

// An uncaught Objective-C exception — the likely shape of a gap between the shim and real
// AppKit ("unrecognized selector sent to instance") — logged with its call stack.
static void onUncaughtException(NSException *e) {
  NSString *text = [NSString stringWithFormat:@"\n*** uncaught exception %@: %@\n%@\n",
                    e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
  NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:@(gCrashPath)];
  if (!h) {
    [[NSFileManager defaultManager] createFileAtPath:@(gCrashPath) contents:nil attributes:nil];
    h = [NSFileHandle fileHandleForWritingAtPath:@(gCrashPath)];
  }
  [h seekToEndOfFile];
  [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
  [h closeFile];
  fputs(text.UTF8String, stderr);
}

static void installCrashReporting(void) {
  NSString *crash = [docsDir() stringByAppendingPathComponent:@"crash.log"];
  [[NSFileManager defaultManager] removeItemAtPath:crash error:nil];
  strlcpy(gCrashPath, crash.fileSystemRepresentation, sizeof gCrashPath);
  strlcpy(gBundlePath, [[NSBundle mainBundle] bundlePath].fileSystemRepresentation, sizeof gBundlePath);
  // Steam's Breakpad and Chromium would otherwise replace these handlers (and claim the Mach
  // exception ports), and a crash would leave no log; the shim keeps them (SignalGuard.m).
  setenv("AK_KEEP_FATAL_SIGNALS", "1", 1);

  static char altStack[64 * 1024];
  stack_t ss = { .ss_sp = altStack, .ss_size = sizeof altStack, .ss_flags = 0 };
  sigaltstack(&ss, NULL);
  struct sigaction sa = { 0 };
  sa.sa_sigaction = onFatalSignal;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&sa.sa_mask);
  const int fatal[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGSYS, SIGTRAP };
  for (size_t i = 0; i < sizeof fatal / sizeof fatal[0]; i++) sigaction(fatal[i], &sa, NULL);
  NSSetUncaughtExceptionHandler(onUncaughtException);
}

// Steam talks on stdout/stderr; send both to Documents/steam-console.log.
static void captureConsole(void) {
  NSString *path = [docsDir() stringByAppendingPathComponent:@"steam-console.log"];
  int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  dup2(fd, STDOUT_FILENO);
  dup2(fd, STDERR_FILENO);
  close(fd);
  setvbuf(stdout, NULL, _IOLBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);
}

#pragma mark Loading

// dlopen one image and log the outcome. Returns the handle (or NULL).
static void *probe(NSString *label, NSString *path) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    hostlog(@"  skip  %@  (not bundled: %@)", label, path.lastPathComponent);
    return NULL;
  }
  void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (h) hostlog(@"  OK    %@", label);
  else   hostlog(@"  FAIL  %@  -> %s", label, dlerror());
  return h;
}

// Where each image from this app landed, so a crash address maps to image + offset.
static void logImageBases(void) {
  NSString *bundle = [[NSBundle mainBundle] bundlePath];
  hostlog(@"image load addresses (for reading crash.log):");
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name || !strstr(name, bundle.fileSystemRepresentation)) continue;
    hostlog(@"  %p  %s", (void *)_dyld_get_image_header(i), strrchr(name, '/') + 1);
  }
}

#pragma mark Launch

// What steam_osx passes: -gamepadui is Big Picture, the Steam Deck interface; the rest
// keep Steam from verifying, repairing or updating the client (a download would replace
// the patched binaries with unpatched Mac ones). Documents/steam-args.txt, when present,
// replaces this list (whitespace separated, '#' starts a comment line), so flags such as
// -steamdeck can be tried without a rebuild; steam-args.example.txt shows the defaults.
// Arguments from Documents/<name>.txt when present (whitespace separated, '#' starts a
// comment line), else the defaults; <name>.example.txt always shows the defaults.
static NSArray<NSString *> *argumentsFromFile(NSString *name, NSArray<NSString *> *defaults, NSString *what) {
  NSString *example = [docsDir() stringByAppendingPathComponent:[name stringByAppendingString:@".example.txt"]];
  NSString *exampleText = [NSString stringWithFormat:
      @"# Copy to %@.txt to replace the %@ (one or more per line).\n%@\n",
      name, what, [defaults componentsJoinedByString:@"\n"]];
  [exampleText writeToFile:example atomically:YES encoding:NSUTF8StringEncoding error:nil];

  NSString *custom = [NSString stringWithContentsOfFile:[docsDir() stringByAppendingPathComponent:[name stringByAppendingString:@".txt"]]
                                               encoding:NSUTF8StringEncoding error:nil];
  if (!custom) return defaults;
  NSMutableArray *args = [NSMutableArray array];
  for (NSString *line in [custom componentsSeparatedByString:@"\n"]) {
    NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!t.length || [t hasPrefix:@"#"]) continue;
    // V8's flags travel as one Chromium switch whose value holds several space-separated flags.
    if ([t hasPrefix:@"--js-flags="]) { [args addObject:t]; continue; }
    for (NSString *word in [t componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
      if (word.length) [args addObject:word];
  }
  hostlog(@"using Documents/%@.txt", name);
  return args;
}

// The -cef-* switches are Steam's own: it turns them into the matching Chromium flags on the
// web helper's command line (no sandbox, no GPU, no crash reporter, no hang watchdog).
static NSArray<NSString *> *launchArguments(void) {
  return argumentsFromFile(@"steam-args", @[
    @"-gamepadui", @"-noverifyfiles", @"-norepairfiles", @"-nobootstrapperupdate",
    @"-skipinitialbootstrap", @"-inhibitbootstrap", @"-nocrashdialog",
    @"-cef-disable-sandbox", @"-cef-disable-gpu", @"-cef-disable-gpu-compositing",
    @"-cef-disable-breakpad", @"-cef-disable-hang-timeouts",
  ], @"launch arguments");
}

#pragma mark The web helper, in-process

// Steam draws its interface (Big Picture included) in steamwebhelper — Steam Helper.app, a
// CEF program — and starts it with tier0's CreateSimpleProcess, which forks and execs. iOS
// can do neither, so the host points the client's calls to CreateSimpleProcess here, and
// this runs the helper in-process through the shim (the packager made it a loadable
// library). Chromium normally splits itself into renderer/GPU/utility processes; here it
// has to stay in one, which these flags ask for.
//
// JavaScript runs in V8's interpreter (--jitless). This V8 writes generated code in place at
// the address it runs it from (MAP_JIT + pthread_jit_write_protect_np), and on A15+/M2+
// devices with iOS 26+ (TXM) MAP_JIT is refused without the dynamic-codesigning entitlement;
// the only JIT those devices allow is a debugger-authorized, execute-only region written
// through a separate alias, which V8 would have to be rebuilt to use. So the interpreter is
// tuned instead: bytecode is never flushed (re-compiling it is the expensive part without a
// JIT), feedback vectors are allocated up front (inline caches are the interpreter's main
// speed-up, and lazy allocation leaves them off until a function has run several times), and
// a larger young generation means fewer garbage collections.
//
// Pages render at 1.5x, not the screen's 3x: Chromium draws every pixel on the CPU here, so 3x
// is four times the pixels per frame; four raster threads use the efficiency cores for it.
// Reduced motion asks the UI to skip animations, which at software-rendered frame rates mostly
// show up as stutter.
static NSArray<NSString *> *webHelperArguments(void) {
  return argumentsFromFile(@"webhelper-args", @[
    @"--single-process", @"--no-sandbox", @"--no-zygote", @"--in-process-gpu",
    @"--disable-gpu", @"--disable-gpu-compositing",
    @"--js-flags=--jitless --no-flush-bytecode --no-lazy-feedback-allocation --max-semi-space-size=32",
    @"--force-device-scale-factor=1.5", @"--num-raster-threads=4", @"--force-prefers-reduced-motion",
    @"--use-mock-keychain", @"--enable-logging=stderr",
  ], @"extra web helper (CEF) arguments");
}

typedef pid_t (*AKSpawnInProcessFn)(const char *path, char *const argv[], char *const envp[], const char *cwd);
typedef int (*AKIsInProcessExecutableFn)(const char *path);
typedef pid_t (*AKSpawnInProcessFunctionFn)(const char *name, int (*function)(int, char **), char *const argv[]);
static AKSpawnInProcessFn gSpawnInProcess;
static AKIsInProcessExecutableFn gIsInProcess;
static AKSpawnInProcessFunctionFn gSpawnFunction;
static int (*gWebHelperMain)(int, char **);

#pragma mark Which web engine

// Steam's interface can be drawn by Chromium (Valve's Steam Helper, in-process: no JIT and no
// GPU on iOS, so slow) or by Safari's engine (the shim's WebHelper.m stands in for Steam
// Helper and shows pages in WKWebView). Chromium stays the default until the Safari engine
// can show the whole interface; a three-finger long press switches (see AppDelegate). The
// choice applies from the next launch.
static NSString *const kEngineKey = @"SteamWebEngine";

static BOOL safariEngine(void) {
  return [[[NSUserDefaults standardUserDefaults] stringForKey:kEngineKey] isEqualToString:@"safari"];
}

// Steam computes the helper's path as <executable dir>/../Frameworks/..., which on a Mac is
// Contents/Frameworks. The app keeps the client's Frameworks inside client/, so a path that
// doesn't exist is retried there.
static NSString *resolveProgram(const char *prog, const char *cwd) {
  NSString *p = @(prog);
  if (![p hasPrefix:@"/"]) {
    NSString *base = (cwd && *cwd) ? @(cwd) : [[NSFileManager defaultManager] currentDirectoryPath];
    p = [base stringByAppendingPathComponent:p];
  }
  p = p.stringByStandardizingPath;
  if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
  NSRange r = [p rangeOfString:@"/Frameworks/" options:NSBackwardsSearch];
  if (r.location != NSNotFound) {
    NSString *inClient = [[clientDir() stringByAppendingPathComponent:@"Frameworks"]
                           stringByAppendingPathComponent:[p substringFromIndex:NSMaxRange(r)]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:inClient]) return inClient;
  }
  return p;
}

// tier0's CreateSimpleProcess(argv-or-command, flags, envp, cwd) -> pid, 0 on failure. Flag
// 0x8 execs argv directly and 0x10 searches PATH for it; without either, the first argument
// is a shell command line. 0x20 means "don't start anything".
static pid_t hostCreateSimpleProcess(char **cmd, unsigned flags, char **envp, const char *cwd) {
  if (flags & 0x20) return 0;
  if (!(flags & 0x18)) {
    hostlog(@"process launch refused (a shell command; iOS can't run one): %s", (const char *)cmd);
    return 0;
  }
  NSMutableString *line = [NSMutableString string];
  for (int i = 0; cmd[i]; i++) [line appendFormat:@"%s%s", i ? " " : "", cmd[i]];
  NSString *path = resolveProgram(cmd[0], cwd);
  if (safariEngine() && [path.lastPathComponent isEqualToString:@"Steam Helper"]) {
    if (!gSpawnFunction || !gWebHelperMain) {
      hostlog(@"Safari engine: the shim has no web helper; nothing will draw Steam's interface");
      return 0;
    }
    pid_t pid = gSpawnFunction(path.fileSystemRepresentation, gWebHelperMain, cmd);
    hostlog(@"Safari engine: web helper standing in for Steam Helper as pid %d", pid);
    return pid > 0 ? pid : 0;
  }
  if (!gIsInProcess || !gIsInProcess(path.fileSystemRepresentation)) {
    hostlog(@"process launch refused (not a program the app can run in-process): %@\n    %@", path, line);
    return 0;
  }
  // The helper opens CEF by a path relative to its own directory (through the bundle's
  // symlinks), so that is its working directory.
  NSString *dir = path.stringByDeletingLastPathComponent;
  hostlog(@"starting in-process: %@ (asked for cwd %s)", path, cwd ? cwd : "(none)");
  pid_t pid = gSpawnInProcess(path.fileSystemRepresentation, cmd, envp, dir.fileSystemRepresentation);
  if (pid <= 0) hostlog(@"  in-process start failed: %s", strerror(errno));
  else hostlog(@"  running as pid %d", pid);
  return pid > 0 ? pid : 0;
}

static int (*gRebind)(const char *, const char *, void *);
static int gRedirected;

// Steam loads some of its libraries later (chromehtml, which starts the helper, among them),
// so redirect each new image's imports as it arrives. dyld also calls this for every image
// already loaded when the callback is registered.
#pragma mark The web helper's windows

// The web helper draws Big Picture through SDL: it creates a window, takes its pixel surface
// and paints CEF's frames into it with SDL's software renderer — no OpenGL calls of its own.
// But it asks for the window with SDL's OpenGL flag set, and SDL's macOS backend then loads
// desktop OpenGL (OpenGL.framework/Libraries/libGL.dylib), which iOS doesn't have, so the
// window was never created ("CreateOutputWindow: failed to create window"). Dropping the
// flag isn't enough: a window created with no graphics flag gets SDL's default for macOS,
// which is OpenGL again. So the helper's window calls come here and ask for Metal instead,
// and SDL's window surface is told to present through its Metal renderer.
#define AK_SDL_WINDOW_OPENGL 0x2LL
#define AK_SDL_WINDOW_METAL 0x20000000LL

typedef uint32_t SDLProps;
static void *(*gSDLCreateWindowWithProperties)(SDLProps);
static void *(*gSDLCreatePopupWindow)(void *, int, int, int, int, uint64_t);
static void *(*gSDLGetWindowSurface)(void *);
static int64_t (*gSDLGetNumberProperty)(SDLProps, const char *, int64_t);
static bool (*gSDLSetNumberProperty)(SDLProps, const char *, int64_t);
static bool (*gSDLSetBooleanProperty)(SDLProps, const char *, bool);
static bool (*gSDLSetHint)(const char *, const char *);
static const char *(*gSDLGetError)(void);

static void *hostSDLCreateWindowWithProperties(SDLProps props) {
  int64_t flags = gSDLGetNumberProperty(props, "SDL.window.create.flags", 0);
  gSDLSetNumberProperty(props, "SDL.window.create.flags", (flags & ~AK_SDL_WINDOW_OPENGL) | AK_SDL_WINDOW_METAL);
  gSDLSetBooleanProperty(props, "SDL.window.create.opengl", false);
  gSDLSetBooleanProperty(props, "SDL.window.create.metal", true);
  void *window = gSDLCreateWindowWithProperties(props);
  hostlog(@"web helper window (flags 0x%llx, as Metal): %@", flags,
          window ? @"created" : [NSString stringWithFormat:@"failed: %s", gSDLGetError()]);
  return window;
}

static void *hostSDLCreatePopupWindow(void *parent, int x, int y, int w, int h, uint64_t flags) {
  void *window = gSDLCreatePopupWindow(parent, x, y, w, h, (flags & ~(uint64_t)AK_SDL_WINDOW_OPENGL) | AK_SDL_WINDOW_METAL);
  if (!window) hostlog(@"web helper popup window failed: %s", gSDLGetError());
  return window;
}

// The helper wraps the window's surface in a software renderer, and a renderer made from a
// surface has no window, so its frames never reach the screen — on the Mac either. What
// shows Big Picture is Chromium's own view, which the helper puts inside this window. A
// window surface would still make SDL stack an opaque, never-drawn Metal layer over that
// view, so the helper gets an ordinary surface of the window's size instead, one per window.
#define AK_SDL_PIXELFORMAT_ARGB8888 0x16362004u
typedef struct { uint32_t flags, format; int w, h; } AKSDLSurfaceHead; // SDL_Surface's first fields
static void *(*gSDLCreateSurface)(int, int, uint32_t);
static void (*gSDLDestroySurface)(void *);
static bool (*gSDLGetWindowSizeInPixels)(void *, int *, int *);

static void *hostSDLGetWindowSurface(void *window) {
  static NSMutableDictionary<NSValue *, NSValue *> *surfaces;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ surfaces = [NSMutableDictionary dictionary]; });
  int w = 0, h = 0;
  gSDLGetWindowSizeInPixels(window, &w, &h);
  if (w <= 0 || h <= 0) return gSDLGetWindowSurface(window);
  @synchronized(surfaces) {
    NSValue *key = [NSValue valueWithPointer:window];
    AKSDLSurfaceHead *surface = (AKSDLSurfaceHead *)surfaces[key].pointerValue;
    if (surface && (surface->w != w || surface->h != h)) { gSDLDestroySurface(surface); surface = NULL; }
    if (!surface) {
      surface = (AKSDLSurfaceHead *)gSDLCreateSurface(w, h, AK_SDL_PIXELFORMAT_ARGB8888);
      hostlog(@"web helper window surface %dx%d: %@", w, h,
              surface ? @"offscreen (Chromium's view shows the page)" : [NSString stringWithFormat:@"failed: %s", gSDLGetError()]);
      if (surface) surfaces[key] = [NSValue valueWithPointer:surface];
    }
    return surface;
  }
}

static void redirectHelperWindows(const char *image) {
  gSDLCreateWindowWithProperties = (__typeof__(gSDLCreateWindowWithProperties))dlsym(RTLD_DEFAULT, "SDL_CreateWindowWithProperties");
  gSDLCreatePopupWindow = (__typeof__(gSDLCreatePopupWindow))dlsym(RTLD_DEFAULT, "SDL_CreatePopupWindow");
  gSDLGetNumberProperty = (__typeof__(gSDLGetNumberProperty))dlsym(RTLD_DEFAULT, "SDL_GetNumberProperty");
  gSDLSetNumberProperty = (__typeof__(gSDLSetNumberProperty))dlsym(RTLD_DEFAULT, "SDL_SetNumberProperty");
  gSDLSetBooleanProperty = (__typeof__(gSDLSetBooleanProperty))dlsym(RTLD_DEFAULT, "SDL_SetBooleanProperty");
  gSDLGetWindowSurface = (__typeof__(gSDLGetWindowSurface))dlsym(RTLD_DEFAULT, "SDL_GetWindowSurface");
  gSDLSetHint = (__typeof__(gSDLSetHint))dlsym(RTLD_DEFAULT, "SDL_SetHint");
  gSDLGetError = (__typeof__(gSDLGetError))dlsym(RTLD_DEFAULT, "SDL_GetError");
  gSDLCreateSurface = (__typeof__(gSDLCreateSurface))dlsym(RTLD_DEFAULT, "SDL_CreateSurface");
  gSDLDestroySurface = (__typeof__(gSDLDestroySurface))dlsym(RTLD_DEFAULT, "SDL_DestroySurface");
  gSDLGetWindowSizeInPixels = (__typeof__(gSDLGetWindowSizeInPixels))dlsym(RTLD_DEFAULT, "SDL_GetWindowSizeInPixels");
  if (!gSDLCreateWindowWithProperties || !gSDLCreatePopupWindow || !gSDLGetWindowSurface || !gSDLGetNumberProperty ||
      !gSDLSetNumberProperty || !gSDLSetBooleanProperty || !gSDLSetHint || !gSDLGetError ||
      !gSDLCreateSurface || !gSDLDestroySurface || !gSDLGetWindowSizeInPixels) {
    hostlog(@"  FAIL  SDL functions for the web helper's windows not found");
    return;
  }
  // If a real window surface is ever made, it presents through an SDL renderer, and only
  // Metal exists here. And skip SDL's hunt for a low-power GPU: it asks macOS-only device
  // questions iOS doesn't answer.
  gSDLSetHint("SDL_FRAMEBUFFER_ACCELERATION", "metal");
  gSDLSetHint("SDL_RENDER_METAL_PREFER_LOW_POWER_DEVICE", "0");
  int n = gRebind(image, "SDL_CreateWindowWithProperties", (void *)hostSDLCreateWindowWithProperties)
        + gRebind(image, "SDL_CreatePopupWindow", (void *)hostSDLCreatePopupWindow)
        + gRebind(image, "SDL_GetWindowSurface", (void *)hostSDLGetWindowSurface);
  hostlog(@"  web helper window creation redirected (%d)", n);
}

static void onImageAdded(const struct mach_header *mh, intptr_t slide) {
  Dl_info info;
  if (!dladdr(mh, &info) || !info.dli_fname) return;
  const char *bundle = [[NSBundle mainBundle] bundlePath].fileSystemRepresentation;
  if (strncmp(info.dli_fname, bundle, strlen(bundle)) != 0) return;
  int n = gRebind(info.dli_fname, "CreateSimpleProcess", (void *)hostCreateSimpleProcess);
  if (n > 0) {
    gRedirected += n;
    hostlog(@"  CreateSimpleProcess redirected in %s (%d)", strrchr(info.dli_fname, '/') + 1, n);
  }
  if (strstr(info.dli_fname, "Steam Helper.app/Contents/MacOS/Steam Helper")) redirectHelperWindows(info.dli_fname);
}

// Point every Steam image's CreateSimpleProcess at the host's, and register the helper's
// extra arguments with the shim.
static void installProcessLauncher(void) {
  gSpawnInProcess = (AKSpawnInProcessFn)dlsym(RTLD_DEFAULT, "AKSpawnInProcess");
  gIsInProcess = (AKIsInProcessExecutableFn)dlsym(RTLD_DEFAULT, "AKIsInProcessExecutable");
  gSpawnFunction = (AKSpawnInProcessFunctionFn)dlsym(RTLD_DEFAULT, "AKSpawnInProcessFunction");
  gWebHelperMain = (int (*)(int, char **))dlsym(RTLD_DEFAULT, "AKWebHelperMain");
  int (*rebind)(const char *, const char *, void *) = (int (*)(const char *, const char *, void *))dlsym(RTLD_DEFAULT, "AKRebindSymbol");
  void (*setExtra)(const char *, const char *const *) = (void (*)(const char *, const char *const *))dlsym(RTLD_DEFAULT, "AKInProcessSetExtraArgs");
  if (!gSpawnInProcess || !gIsInProcess || !rebind || !setExtra) {
    hostlog(@"  FAIL  the shim has no in-process launcher; the web helper can't start");
    return;
  }
  // Where CEF's framework and the main app bundle are. Unset, CEF derives both from the
  // executable as <first .app>/Contents/Frameworks/Chromium Embedded Framework.framework —
  // on a Mac that's inside Steam.app; here the first .app is this app, which has no
  // Contents/, so [NSBundle bundleWithURL:] came back nil and Chromium's CHECK fired inside
  // cef_initialize. On a Mac the helper's main bundle is the outer Steam.app: this app.
  NSString *cefFramework = [clientDir() stringByAppendingPathComponent:@"Frameworks/Chromium Embedded Framework.framework"];
  NSArray<NSString *> *extra = [webHelperArguments() arrayByAddingObjectsFromArray:@[
    [@"--framework-dir-path=" stringByAppendingString:cefFramework],
    [@"--main-bundle-path=" stringByAppendingString:[[NSBundle mainBundle] bundlePath]],
  ]];
  const char **argv = calloc(extra.count + 1, sizeof(char *));
  for (NSUInteger i = 0; i < extra.count; i++) argv[i] = strdup(extra[i].UTF8String);
  setExtra("Steam Helper", argv);
  gRebind = rebind;
  _dyld_register_func_for_add_image(onImageAdded);
  hostlog(@"in-process launcher ready: %d CreateSimpleProcess imports redirected so far; web helper gets: %@",
          gRedirected, [extra componentsJoinedByString:@" "]);
}

// steam_osx hands SteamDllMainEx a callback the client calls to tick the launcher's own
// update UI and job queues. This host has neither, so there is nothing to tick.
static void launcherPump(void) {}

typedef int (*SteamDllMainExFn)(int argc, char **argv, void (*pump)(void));

static void launchSteam(void *steamui, void *launcher) {
  NSString *client = clientDir();

  // As steam_osx's main does: SIGPIPE ignored, at least 9216 open files.
  signal(SIGPIPE, SIG_IGN);
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0) {
    if (rl.rlim_cur < 9216) rl.rlim_cur = 9216;
    if (rl.rlim_max != RLIM_INFINITY && rl.rlim_cur > rl.rlim_max) rl.rlim_cur = rl.rlim_max;
    setrlimit(RLIMIT_NOFILE, &rl);
  }

  // With STEAM_APP_BUNDLE_PATH set, the Mac launcher treats itself as already moved into
  // ~/Library/Application Support/Steam rather than copying itself there and exec'ing the
  // copy (impossible on iOS). The data root lives in this app's writable container.
  setenv("STEAM_APP_BUNDLE_PATH", [[NSBundle mainBundle] bundlePath].fileSystemRepresentation, 1);
  setenv("STEAM_CLIENT_CONFIG_FILE", "", 1);
  setenv("STEAM_CLIENT_LOG_FOLDER", logsDir().fileSystemRepresentation, 1);
  hostlog(@"steam root: %@", steamRoot());

  // steam_osx chdirs into its own directory (the client) and puts its own path in argv[0].
  if (chdir(client.fileSystemRepresentation) != 0) {
    hostlog(@"FAIL  chdir into %@: %s", client, strerror(errno));
    return;
  }
  NSArray<NSString *> *args = launchArguments();
  int argc = (int)args.count + 1;
  char **argv = calloc(argc + 1, sizeof(char *));
  argv[0] = strdup([client stringByAppendingPathComponent:@"steam_osx"].fileSystemRepresentation);
  for (int i = 1; i < argc; i++) argv[i] = strdup(args[i - 1].UTF8String);

  SteamDllMainExFn entry = (SteamDllMainExFn)dlsym(steamui, "SteamDllMainEx");
  if (!entry) {
    hostlog(@"FAIL  SteamDllMainEx not found: %s", dlerror());
    return;
  }
  // Steam's process pipes publish their real address in an environment variable named after
  // the pipe once the server is listening; its UI connects to them. Record what they hold
  // once Steam has had time to start, since a pipe that never comes up leaves the UI blank.
  for (int64_t delay = 15; delay <= 45; delay += 30) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      const char *master = getenv("Steam3Master"), *service = getenv("SteamClientService");
      hostlog(@"after %llds: Steam3Master=%s SteamClientService=%s", delay,
              master ? master : "(unset)", service ? service : "(unset)");
    });
  }
  hostlog(@"calling SteamDllMainEx (%p) with: %@", entry, [args componentsJoinedByString:@" "]);
  hostlog(@"(Steam's own output goes to steam-console.log; a crash goes to crash.log)");
  int rc = entry(argc, argv, launcherPump);
  hostlog(@"SteamDllMainEx returned %d", rc);
  const char *(*runOnExit)(void) = (const char *(*)(void))dlsym(launcher, "SteamLauncher_CommandLineToRunOnExit");
  if (runOnExit && *runOnExit()) hostlog(@"Steam asked to be relaunched with: %s", runOnExit());
}

// The commit and time CI built this from (ipa.yml passes it), so a log always says which
// build produced it.
#ifndef HOST_BUILD
#define HOST_BUILD "local"
#endif

#pragma mark Is the page reaching the screen?

// Chromium hands each finished page picture to its view as an IOSurface set as a CALayer's
// contents. Log the first few hand-overs (so a black window says whether frames are made at
// all), and later dump the whole layer tree (so it says where they went).
static IMP gSetContents;
static int gSurfaceFrames;

static void hostSetContents(CALayer *layer, SEL cmd, id contents) {
  if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
    int n = __atomic_add_fetch(&gSurfaceFrames, 1, __ATOMIC_RELAXED);
    if (n <= 3) {
      IOSurfaceRef s = (__bridge IOSurfaceRef)contents;
      hostlog(@"page frame %d: %zux%zu IOSurface into %@ (bounds %@, superlayer %@) on %@", n,
              IOSurfaceGetWidth(s), IOSurfaceGetHeight(s), NSStringFromClass(layer.class),
              NSStringFromCGRect(layer.bounds), layer.superlayer ? NSStringFromClass(layer.superlayer.class) : @"none",
              NSThread.isMainThread ? @"main" : (NSThread.currentThread.name.length ? NSThread.currentThread.name : @"a thread"));
    }
  }
  ((void (*)(id, SEL, id))gSetContents)(layer, cmd, contents);
}

// Where this process's CPU time goes right now: the total (100% = one core) and the busiest
// threads by name. A phone that runs hot shows here which part is doing it. (WebKit's
// pages run in their own process and aren't counted.)
static NSString *cpuReport(void) {
  thread_act_array_t threads;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return @"(unavailable)";
  NSMutableArray<NSArray *> *busy = [NSMutableArray array];
  double total = 0;
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    thread_extended_info_data_t info;
    mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT;
    if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&info, &n) == KERN_SUCCESS) {
      double percent = info.pth_cpu_usage * 100.0 / TH_USAGE_SCALE;
      total += percent;
      if (percent >= 3) [busy addObject:@[ @(percent), info.pth_name[0] ? @(info.pth_name) : @"(unnamed)" ]];
    }
    mach_port_deallocate(mach_task_self(), threads[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
  [busy sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
  NSMutableString *out = [NSMutableString stringWithFormat:@"%.0f%% across %u threads", total, count];
  for (NSUInteger i = 0; i < busy.count && i < 6; i++) [out appendFormat:@"%@ %@ %.0f%%", i ? @"," : @";", busy[i][1], [busy[i][0] doubleValue]];
  return out;
}

static void watchPageFrames(void) {
  Method m = class_getInstanceMethod(CALayer.class, @selector(setContents:));
  gSetContents = method_setImplementation(m, (IMP)hostSetContents);
}

static void dumpLayer(CALayer *l, int depth, int *lines) {
  if (*lines >= 160 || depth > 16) return;
  (*lines)++;
  id c = l.contents;
  NSString *what = !c ? @"-" : CFGetTypeID((__bridge CFTypeRef)c) == IOSurfaceGetTypeID() ? @"IOSurface"
                                                                                            : NSStringFromClass([c class]);
  NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
  CGColorRef bg = l.backgroundColor;
  hostlog(@"%@%@ %@ frame=%@%@ opacity=%.2f bg=%@ contents=%@%@", pad, NSStringFromClass(l.class),
          l.delegate ? NSStringFromClass([(NSObject *)l.delegate class]) : @"",
          NSStringFromCGRect(l.frame), l.hidden ? @" HIDDEN" : @"", l.opacity,
          bg ? [NSString stringWithFormat:@"a%.2f", CGColorGetAlpha(bg)] : @"-", what,
          l.geometryFlipped ? @" flipped" : @"");
  for (CALayer *s in l.sublayers) dumpLayer(s, depth + 1, lines);
}

// Not called in normal runs (it found the 0x0 page container); call it from the heartbeat to
// see where layers end up.
__attribute__((unused)) static void dumpScreenLayers(void) {
  int lines = 0;
  hostlog(@"--- layer tree (%d page frames handed over so far) ---", gSurfaceFrames);
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class])
      for (UIWindow *w in ((UIWindowScene *)scene).windows) dumpLayer(w.layer, 0, &lines);
  hostlog(@"--- end of layer tree ---");
}

static void bringUpClient(void) {
  watchPageFrames();
  hostlog(@"Steam-on-iOS host starting — build %s", HOST_BUILD);
  hostlog(@"bundle: %@", [[NSBundle mainBundle] bundlePath]);
  hostlog(@"loaded images at start: %u", _dyld_image_count());

  // The shim's code first, then the umbrella in front of it that Steam's load commands
  // point at (it re-exports the code plus the real iOS libraries), so a failure names the
  // layer. Then the client, in rough dependency order (bundled under client/).
  // Steam's folders must exist before the launcher library hands them out.
  for (NSString *d in @[ logsDir(), steamRoot() ])
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];

  // On a Mac the process's executable is steam_osx, in the client directory, and Steam
  // loads its modules (filesystem_stdio, vgui2_s, ...) from next to it. Here it's this host
  // or LiveContainer, so tell the shim which executable to report to Steam
  // (_NSGetExecutablePath). Set before any Steam library loads: initializers may ask.
  setenv("AK_EXECUTABLE_PATH", [clientDir() stringByAppendingPathComponent:@"steam_osx"].fileSystemRepresentation, 1);

  // SteamLauncher.framework stands in for steam_osx's exported launcher functions. It goes
  // right after the shim and is configured at once: vgui2_s asks it for the universe while
  // it initializes, which happens as it loads.
  NSArray<NSArray<NSString *> *> *images = @[
    @[ @"AppKitShimCore.framework", @"Frameworks/AppKitShimCore.framework/AppKitShimCore" ],
    @[ @"AppKitShim.framework", @"Frameworks/AppKitShim.framework/AppKitShim" ],
    @[ @"SteamLauncher.framework", @"Frameworks/SteamLauncher.framework/SteamLauncher" ],
    @[ @"libtier0_s", @"client/libtier0_s.dylib" ],
    @[ @"libvstdlib_s", @"client/libvstdlib_s.dylib" ],
    @[ @"libSDL3", @"client/libSDL3.dylib" ],
    @[ @"CEF", @"client/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" ],
    @[ @"vgui2_s", @"client/vgui2_s.dylib" ],
    @[ @"steamclient", @"client/steamclient.dylib" ],
    @[ @"steamui", @"client/steamui.dylib" ],
  ];
  void *steamui = NULL, *launcher = NULL;
  BOOL allLoaded = YES;
  BOOL safari = safariEngine();
  hostlog(@"web engine: %@ (three-finger long press to change)", safari ? @"Safari (WebKit)" : @"Chromium (CEF)");
  for (NSArray<NSString *> *image in images) {
    // Only Steam Helper uses CEF; with the Safari engine it never loads (it is most of the
    // client's code, so that also saves memory).
    if (safari && [image[0] isEqualToString:@"CEF"]) continue;
    void *h = probe(image[0], inApp(image[1]));
    if (!h) allLoaded = NO;
    if ([image[0] isEqualToString:@"steamui"]) steamui = h;
    if ([image[0] isEqualToString:@"SteamLauncher.framework"] && h) {
      launcher = h;
      void (*configure)(const char *, const char *, const char *) =
          (void (*)(const char *, const char *, const char *))dlsym(h, "SteamLauncher_Configure");
      if (configure) {
        configure(clientDir().fileSystemRepresentation, logsDir().fileSystemRepresentation,
                  steamRoot().fileSystemRepresentation);
        hostlog(@"        launcher interface ready (install dir, logs, data root)");
      } else {
        hostlog(@"  FAIL  SteamLauncher_Configure missing");
        allLoaded = NO;
      }
    }
  }
  hostlog(@"loaded images now:     %u", _dyld_image_count());
  logImageBases();
  if (!allLoaded || !steamui || !launcher) {
    hostlog(@"--- not launching: a library failed to load ---");
    return;
  }
  installProcessLauncher();
  hostlog(@"--- all libraries loaded; starting Steam ---");
  launchSteam(steamui, launcher);
}

// Steam's windows fill the whole screen, like a game: no status bar, the home indicator fades
// out, and edge swipes need a second swipe so a stray one doesn't leave the app.
@interface HostViewController : UIViewController
@end

@implementation HostViewController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate, UIGestureRecognizerDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

// Three fingers held on the screen anywhere: choose the web engine for the next launch. The
// recognizer only watches - Steam's views still get the touches.
- (void)watchForEngineGesture {
  UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(engineGesture:)];
  g.numberOfTouchesRequired = 3;
  g.minimumPressDuration = 0.8;
  g.cancelsTouchesInView = NO;
  g.delaysTouchesBegan = NO;
  g.delaysTouchesEnded = NO;
  g.delegate = self;
  [self.window addGestureRecognizer:g];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  return YES;
}

- (void)engineGesture:(UILongPressGestureRecognizer *)g {
  if (g.state != UIGestureRecognizerStateBegan) return;
  UIViewController *top = self.window.rootViewController;
  while (top.presentedViewController) top = top.presentedViewController;
  if ([top isKindOfClass:UIAlertController.class]) return;
  BOOL safari = safariEngine();
  UIAlertController *menu = [UIAlertController
      alertControllerWithTitle:@"Web engine"
                       message:[NSString stringWithFormat:@"Steam's interface is drawn by %@. A change applies the next time Steam starts.",
                                                          safari ? @"Safari's engine (WebKit)" : @"Chromium"]
                preferredStyle:UIAlertControllerStyleAlert];
  void (^choose)(NSString *, NSString *) = ^(NSString *engine, NSString *label) {
    [[NSUserDefaults standardUserDefaults] setObject:engine forKey:kEngineKey];
    hostlog(@"web engine set to %@ for the next launch", label);
    UIAlertController *restart = [UIAlertController
        alertControllerWithTitle:@"Restart Steam"
                         message:[NSString stringWithFormat:@"Quit now and open Steam again to use %@.", label]
                  preferredStyle:UIAlertControllerStyleAlert];
    [restart addAction:[UIAlertAction actionWithTitle:@"Quit Now" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { exit(0); }]];
    [restart addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:restart animated:YES completion:nil];
  };
  [menu addAction:[UIAlertAction actionWithTitle:safari ? @"Safari (WebKit) - current" : @"Safari (WebKit) - experimental"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { if (!safari) choose(@"safari", @"Safari's engine"); }]];
  [menu addAction:[UIAlertAction actionWithTitle:safari ? @"Chromium" : @"Chromium - current"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) { if (safari) choose(@"chromium", @"Chromium"); }]];
  [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  [top presentViewController:menu animated:YES completion:nil];
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController *vc = [HostViewController new];
  vc.view.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
  gLog = [[UITextView alloc] initWithFrame:vc.view.bounds];
  gLog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  gLog.backgroundColor = UIColor.clearColor;
  gLog.textColor = [UIColor colorWithRed:0.60 green:0.85 blue:1.0 alpha:1.0];
  gLog.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
  gLog.editable = NO;
  gLog.text = @"";
  [vc.view addSubview:gLog];
  self.window.rootViewController = vc;
  [self.window makeKeyAndVisible];
  [self watchForEngineGesture];

  // Run the client bring-up off the first runloop tick so the window is up to show logs.
  // From a timer, not a main-queue block: Steam's loop never returns, and while a main-queue
  // block is running the main queue can't run another one, so every later main-queue job
  // (UIKit work the shim sends over from other threads, this log view) would wait forever.
  // Called from a timer, the run loop turns Steam's loop makes still drain the queue.
  [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *t) { bringUpClient(); }];
  // A heartbeat in the log shows whether the main thread still gets a turn once Steam runs,
  // how many page frames Chromium handed over since the last one (its frame rate), and where
  // the CPU goes: every 10 s for the first minute, then every 30 s.
  __block int beats = 0, framesBefore = 0;
  NSTimer *heartbeat = [NSTimer timerWithTimeInterval:10 repeats:YES block:^(NSTimer *t) {
    int frames = gSurfaceFrames;
    ++beats;
    if (beats <= 6 || beats % 3 == 0)
      hostlog(@"main thread turning (%ds); page frames %.1f/s; CPU %@", beats * 10, (frames - framesBefore) / 10.0, cpuReport());
    framesBefore = frames;
  }];
  [NSRunLoop.mainRunLoop addTimer:heartbeat forMode:NSRunLoopCommonModes];
  return YES;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    captureConsole();
    installCrashReporting();
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
