#import "AKShimPrivate.h"
#import "AppKitShim/NSWorkspace.h"
#import "AppKitShim/NSRunningApplication.h"

NSNotificationName const NSWorkspaceDidActivateApplicationNotification = @"NSWorkspaceDidActivateApplicationNotification";
NSNotificationName const NSWorkspaceDidDeactivateApplicationNotification = @"NSWorkspaceDidDeactivateApplicationNotification";
NSNotificationName const NSWorkspaceActiveSpaceDidChangeNotification = @"NSWorkspaceActiveSpaceDidChangeNotification";
NSNotificationName const NSWorkspaceScreensDidSleepNotification = @"NSWorkspaceScreensDidSleepNotification";
NSNotificationName const NSWorkspaceScreensDidWakeNotification = @"NSWorkspaceScreensDidWakeNotification";
NSNotificationName const NSWorkspaceWillPowerOffNotification = @"NSWorkspaceWillPowerOffNotification";
NSNotificationName const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification = @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification";
NSString *const NSWorkspaceApplicationKey = @"NSWorkspaceApplicationKey";
NSString *const NSWorkspaceLaunchConfigurationArguments = @"NSWorkspaceLaunchConfigurationArguments";
NSString *const NSWorkspaceLaunchConfigurationEnvironment = @"NSWorkspaceLaunchConfigurationEnvironment";

@implementation NSWorkspaceOpenConfiguration
+ (instancetype)configuration { return [self new]; }
- (instancetype)init { if ((self = [super init])) _activates = YES; return self; }
- (id)copyWithZone:(NSZone *)zone {
  NSWorkspaceOpenConfiguration *c = [NSWorkspaceOpenConfiguration new];
  c.arguments = _arguments;
  c.environment = _environment;
  c.activates = _activates;
  c.hides = _hides;
  c.createsNewApplicationInstance = _createsNewApplicationInstance;
  c.promptsUserIfNeeded = _promptsUserIfNeeded;
  return c;
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end

@implementation NSWorkspace

+ (NSWorkspace *)sharedWorkspace {
  static NSWorkspace *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [NSWorkspace new]; });
  return shared;
}

// A private center, like AppKit's: workspace notifications are posted here, not on the
// default center. Nothing posts to it yet (iOS can't observe other apps), but observers
// register against it without crashing.
- (NSNotificationCenter *)notificationCenter {
  static NSNotificationCenter *center;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ center = [[NSNotificationCenter alloc] init]; });
  return center;
}

// Only this app is visible to itself on iOS.
- (NSArray<NSRunningApplication *> *)runningApplications { return @[ NSRunningApplication.currentApplication ]; }
- (NSRunningApplication *)frontmostApplication { return NSRunningApplication.currentApplication; }
- (NSRunningApplication *)menuBarOwningApplication { return NSRunningApplication.currentApplication; }

// -[UIApplication openURL:] is asynchronous and calls back on the main thread; AppKit's
// -openURL: returns a result. On the main thread waiting would deadlock, so the answer is
// whether some app handles the URL. Off the main thread, wait briefly for the real outcome.
- (BOOL)openURL:(NSURL *)url {
  if (!url) return NO;
  UIApplication *app = UIApplication.sharedApplication;
  if (NSThread.isMainThread) {
    BOOL handled = [app canOpenURL:url];
    [app openURL:url options:@{} completionHandler:nil];
    return handled;
  }
  __block BOOL ok = NO;
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    [app openURL:url options:@{} completionHandler:^(BOOL success) {
      ok = success;
      dispatch_semaphore_signal(done);
    }];
  });
  dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
  return ok;
}

- (void)openURL:(NSURL *)url
  configuration:(NSWorkspaceOpenConfiguration *)configuration
completionHandler:(void (^)(NSRunningApplication *, NSError *))completionHandler {
  [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
    if (!completionHandler) return;
    NSError *error = success ? nil : [NSError errorWithDomain:NSCocoaErrorDomain code:260 userInfo:nil];
    completionHandler(success ? NSRunningApplication.currentApplication : nil, error);
  }];
}

- (BOOL)openFile:(NSString *)fullPath { return [self openURL:[NSURL fileURLWithPath:fullPath]]; }
- (BOOL)openFile:(NSString *)fullPath withApplication:(NSString *)appName { return [self openFile:fullPath]; }
- (BOOL)selectFile:(NSString *)fullPath inFileViewerRootedAtPath:(NSString *)rootFullPath { return NO; }

- (NSURL *)URLForApplicationToOpenURL:(NSURL *)url {
  return [UIApplication.sharedApplication canOpenURL:url] ? url : nil;
}
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)bundleIdentifier { return nil; }
- (NSImage *)iconForFile:(NSString *)fullPath { return nil; }
- (NSImage *)iconForContentType:(id)contentType { return nil; }


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
