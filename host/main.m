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
#import <dlfcn.h>
#import <execinfo.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <sys/resource.h>
#import <unistd.h>

static UITextView *gLog;
static NSMutableString *gBuf;
static char gCrashPath[1024];

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
  if (!gBuf) gBuf = [NSMutableString string];
  [gBuf appendFormat:@"%@\n", line];
  // Flush the whole buffer to disk each time: if the very next call kills the process,
  // the log up to here is already on disk for pulling off the device.
  [gBuf writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
  // Mirror to screen. The on-disk log above is the reliable record across a crash; this
  // is the convenience view (it stops updating while Steam holds the main thread).
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gLog) { gLog.text = gBuf; [gLog scrollRangeToVisible:NSMakeRange(gBuf.length, 0)]; }
  });
}

// Resolve a path inside the .app bundle.
static NSString *inApp(NSString *rel) {
  return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:rel];
}

#pragma mark Crash and console capture

static void writeStr(int fd, const char *s) { if (fd >= 0) write(fd, s, strlen(s)); }

// Fatal signal: record which, where, and the backtrace in Documents/crash.log (and the
// console log), then die the normal way. Runs on an alternate stack so a stack overflow
// can still report.
static void onFatalSignal(int sig, siginfo_t *info, void *uap) {
  int fd = open(gCrashPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
  char line[200];
  snprintf(line, sizeof line, "\n*** crashed: signal %d (SIG%s), fault address %p\n",
           sig, sig < NSIG ? sys_signame[sig] : "?", info ? info->si_addr : NULL);
  writeStr(fd, line); writeStr(2, line);
  void *frames[96];
  int n = backtrace(frames, 96);
  backtrace_symbols_fd(frames, n, fd);
  backtrace_symbols_fd(frames, n, 2);
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

  static char altStack[64 * 1024];
  stack_t ss = { .ss_sp = altStack, .ss_size = sizeof altStack, .ss_flags = 0 };
  sigaltstack(&ss, NULL);
  struct sigaction sa = { 0 };
  sa.sa_sigaction = onFatalSignal;
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigemptyset(&sa.sa_mask);
  const int fatal[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT };
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
static NSArray<NSString *> *launchArguments(void) {
  NSArray *defaults = @[ @"-gamepadui", @"-noverifyfiles", @"-norepairfiles", @"-nobootstrapperupdate",
                         @"-skipinitialbootstrap", @"-inhibitbootstrap", @"-nocrashdialog" ];
  NSString *example = [docsDir() stringByAppendingPathComponent:@"steam-args.example.txt"];
  NSString *exampleText = [NSString stringWithFormat:
      @"# Copy to steam-args.txt to replace the launch arguments (one or more per line).\n%@\n",
      [defaults componentsJoinedByString:@"\n"]];
  [exampleText writeToFile:example atomically:YES encoding:NSUTF8StringEncoding error:nil];

  NSString *custom = [NSString stringWithContentsOfFile:[docsDir() stringByAppendingPathComponent:@"steam-args.txt"]
                                               encoding:NSUTF8StringEncoding error:nil];
  if (!custom) return defaults;
  NSMutableArray *args = [NSMutableArray array];
  for (NSString *line in [custom componentsSeparatedByString:@"\n"]) {
    NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!t.length || [t hasPrefix:@"#"]) continue;
    for (NSString *word in [t componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
      if (word.length) [args addObject:word];
  }
  hostlog(@"using Documents/steam-args.txt");
  return args;
}

// steam_osx hands SteamDllMainEx a callback the client calls to tick the launcher's own
// update UI and job queues. This host has neither, so there is nothing to tick.
static void launcherPump(void) {}

typedef int (*SteamDllMainExFn)(int argc, char **argv, void (*pump)(void));

static void launchSteam(void *steamui) {
  NSString *client = inApp(@"client");

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
  NSString *logs = [docsDir() stringByAppendingPathComponent:@"steam-logs"];
  NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Steam"];
  for (NSString *d in @[ logs, root ])
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
  setenv("STEAM_CLIENT_LOG_FOLDER", logs.fileSystemRepresentation, 1);
  hostlog(@"steam root: %@", root);

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
  hostlog(@"calling SteamDllMainEx (%p) with: %@", entry, [args componentsJoinedByString:@" "]);
  hostlog(@"(Steam's own output goes to steam-console.log; a crash goes to crash.log)");
  int rc = entry(argc, argv, launcherPump);
  hostlog(@"SteamDllMainEx returned %d", rc);
}

static void bringUpClient(void) {
  hostlog(@"Steam-on-iOS host starting");
  hostlog(@"bundle: %@", [[NSBundle mainBundle] bundlePath]);
  hostlog(@"loaded images at start: %u", _dyld_image_count());

  // The shim's code first, then the umbrella in front of it that Steam's load commands
  // point at (it re-exports the code plus the real iOS libraries), so a failure names the
  // layer. Then the client, in rough dependency order (bundled under client/).
  NSArray<NSArray<NSString *> *> *images = @[
    @[ @"AppKitShimCore.framework", @"Frameworks/AppKitShimCore.framework/AppKitShimCore" ],
    @[ @"AppKitShim.framework", @"Frameworks/AppKitShim.framework/AppKitShim" ],
    @[ @"libtier0_s", @"client/libtier0_s.dylib" ],
    @[ @"libvstdlib_s", @"client/libvstdlib_s.dylib" ],
    @[ @"libSDL3", @"client/libSDL3.dylib" ],
    @[ @"CEF", @"client/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework" ],
    @[ @"vgui2_s", @"client/vgui2_s.dylib" ],
    @[ @"steamclient", @"client/steamclient.dylib" ],
    @[ @"steamui", @"client/steamui.dylib" ],
  ];
  void *steamui = NULL;
  BOOL allLoaded = YES;
  for (NSArray<NSString *> *image in images) {
    void *h = probe(image[0], inApp(image[1]));
    if (!h) allLoaded = NO;
    if ([image[0] isEqualToString:@"steamui"]) steamui = h;
  }
  hostlog(@"loaded images now:     %u", _dyld_image_count());
  logImageBases();
  if (!allLoaded || !steamui) {
    hostlog(@"--- not launching: a library failed to load ---");
    return;
  }
  hostlog(@"--- all libraries loaded; starting Steam ---");
  launchSteam(steamui);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController *vc = [UIViewController new];
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

  // Run the client bring-up off the first runloop tick so the window is up to show logs.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{ bringUpClient(); });
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
