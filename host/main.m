// Steam-on-iOS app host.
//
// This is the app's main executable — the thing iOS launches. Its job is to stand up the
// environment the native Steam client expects, load the shim, then bring the client's
// dylibs into the process and report exactly how far that gets. On a device there is no
// console, so every step is mirrored to an on-screen log and to Documents/launch.log.
//
// This is deliberately a diagnostic launcher first: it turns "does the retagged client
// load against the shim on iOS?" into a concrete, readable answer instead of a silent
// crash. Actually driving Big Picture (gamepadui, single-process CEF) is layered on once
// the dylibs load clean.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

static UITextView *gLog;
static NSMutableString *gBuf;

static void logf(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSLog(@"[host] %@", line);
  if (!gBuf) gBuf = [NSMutableString string];
  [gBuf appendFormat:@"%@\n", line];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gLog) { gLog.text = gBuf; }
  });
}

// Resolve a path inside the .app bundle.
static NSString *inApp(NSString *rel) {
  return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:rel];
}

// dlopen one image and log the outcome. Returns the handle (or NULL).
static void *probe(NSString *label, NSString *path) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    logf(@"  skip  %@  (not bundled: %@)", label, path.lastPathComponent);
    return NULL;
  }
  void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
  if (h) logf(@"  OK    %@", label);
  else   logf(@"  FAIL  %@  -> %s", label, dlerror());
  return h;
}

static void bringUpClient(void) {
  logf(@"Steam-on-iOS host starting");
  logf(@"bundle: %@", [[NSBundle mainBundle] bundlePath]);

  // Environment the client reads. Keep JIT on (StikDebug enables it); force the single
  // CEF process since iOS forbids spawning the helper processes Steam normally forks;
  // keep the self-updater from fetching unsigned binaries over ours.
  setenv("STEAM_RUNTIME", "0", 1);
  setenv("STEAMOS", "1", 1);
  setenv("STEAM_DISABLE_UPDATE", "1", 1);
  setenv("STEAM_GAMEPADUI", "1", 1);
  setenv("CEF_SINGLE_PROCESS", "1", 1);
  // Steam resources live next to the dylibs inside the bundle (under client/, since the
  // app's own executable is named Steam).
  setenv("STEAM_CLIENT_DIR", inApp(@"client").fileSystemRepresentation, 1);

  logf(@"loaded images at start: %u", _dyld_image_count());

  // The shim first, so its macOS symbols are in the global pool (RTLD_GLOBAL) before any
  // Steam dylib that was repointed to it resolves.
  probe(@"AppKitShim.framework", inApp(@"Frameworks/AppKitShim.framework/AppKitShim"));

  // Core Valve runtime, then the client, in rough dependency order. The Steam payload is
  // bundled under client/ in the .app.
  NSString *c = @"client";
  probe(@"libtier0_s",    inApp([c stringByAppendingPathComponent:@"libtier0_s.dylib"]));
  probe(@"libvstdlib_s",  inApp([c stringByAppendingPathComponent:@"libvstdlib_s.dylib"]));
  probe(@"libSDL3",       inApp([c stringByAppendingPathComponent:@"libSDL3.dylib"]));
  probe(@"CEF",           inApp(@"client/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework"));
  probe(@"vgui2_s",       inApp([c stringByAppendingPathComponent:@"vgui2_s.dylib"]));
  probe(@"steamclient",   inApp([c stringByAppendingPathComponent:@"steamclient.dylib"]));
  probe(@"steamui",       inApp([c stringByAppendingPathComponent:@"steamui.dylib"]));

  logf(@"loaded images now:     %u", _dyld_image_count());
  logf(@"--- probe complete ---");

  // Persist for pulling off the device.
  NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  [gBuf writeToFile:[docs stringByAppendingPathComponent:@"launch.log"]
         atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
  }
}
