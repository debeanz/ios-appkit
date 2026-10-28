#import "AKShimPrivate.h"
#import "AppKitShim/NSRunningApplication.h"
#import <signal.h>

@implementation NSRunningApplication {
  pid_t _pid;
  NSString *_bundleID;
  NSDate *_launchDate;
  NSBundle *_game;   // a game Steam started, running in this process (MacPrograms.m); nil for this app
}

// The game started as stand-in `pid`, the same instance for as long as Steam asks about it.
+ (NSRunningApplication *)_ak_gameWithPid:(pid_t)pid {
  static NSRunningApplication *last;
  @synchronized (self) {
    if (last && last->_pid == pid) return last;
    NSBundle *game = AKGameBundleForPid(pid);
    if (!game) return nil;
    NSRunningApplication *app = [NSRunningApplication new];
    app->_pid = pid;
    app->_game = game;
    app->_bundleID = game.bundleIdentifier;
    app->_launchDate = [NSDate date];
    last = app;
    return app;
  }
}

+ (NSRunningApplication *)currentApplication {
  static NSRunningApplication *current;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    current = [NSRunningApplication new];
    current->_pid = NSProcessInfo.processInfo.processIdentifier;
    current->_bundleID = NSBundle.mainBundle.bundleIdentifier;
    current->_launchDate = [NSDate date];
  });
  return current;
}

// Only this app and the game Steam started exist here; match them, otherwise nothing.
+ (NSArray<NSRunningApplication *> *)runningApplicationsWithBundleIdentifier:(NSString *)bundleIdentifier {
  NSMutableArray *found = [NSMutableArray array];
  NSRunningApplication *me = self.currentApplication, *game = [self _ak_gameWithPid:AKGamePid()];
  if ([bundleIdentifier isEqualToString:me.bundleIdentifier]) [found addObject:me];
  if (game && [bundleIdentifier isEqualToString:game.bundleIdentifier]) [found addObject:game];
  return found;
}

+ (NSRunningApplication *)runningApplicationWithProcessIdentifier:(pid_t)pid {
  NSRunningApplication *me = self.currentApplication;
  return pid == me.processIdentifier ? me : [self _ak_gameWithPid:pid];
}

- (NSBundle *)_ak_bundle { return _game ?: NSBundle.mainBundle; }

- (pid_t)processIdentifier { return _pid; }
- (NSString *)bundleIdentifier { return _bundleID; }
- (NSString *)localizedName {
  NSDictionary *info = self._ak_bundle.infoDictionary;
  return info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: self._ak_bundle.bundlePath.lastPathComponent.stringByDeletingPathExtension;
}
- (NSURL *)bundleURL { return self._ak_bundle.bundleURL; }
- (NSURL *)executableURL { return self._ak_bundle.executableURL; }
- (NSDate *)launchDate { return _launchDate; }

// This app is active whenever it is in the foreground, and so is a game while it runs.
- (BOOL)isActive { return !self.isTerminated && UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }
- (BOOL)isHidden { return UIApplication.sharedApplication.applicationState == UIApplicationStateBackground; }
- (BOOL)isTerminated { return _game ? kill(_pid, 0) != 0 : NO; }   // kill knows stand-ins (InProcessExec.m)
- (BOOL)isFinishedLaunching { return YES; }

- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options { return self == NSRunningApplication.currentApplication || !self.isTerminated; }
- (BOOL)hide { return NO; }   // an app can't background itself on iOS
- (BOOL)unhide { return NO; }
// A game is asked to quit, as AppKit asks an app; this app can't end itself that way.
- (BOOL)terminate { return _game && !self.isTerminated && kill(_pid, SIGTERM) == 0; }
- (BOOL)forceTerminate { return self.terminate; }


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
