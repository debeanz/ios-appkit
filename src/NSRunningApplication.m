#import "AKShimPrivate.h"
#import "AppKitShim/NSRunningApplication.h"

@implementation NSRunningApplication {
  pid_t _pid;
  NSString *_bundleID;
  NSDate *_launchDate;
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

// Only this app exists here; match it, otherwise nothing.
+ (NSArray<NSRunningApplication *> *)runningApplicationsWithBundleIdentifier:(NSString *)bundleIdentifier {
  NSRunningApplication *me = self.currentApplication;
  return [bundleIdentifier isEqualToString:me.bundleIdentifier] ? @[ me ] : @[];
}

+ (NSRunningApplication *)runningApplicationWithProcessIdentifier:(pid_t)pid {
  NSRunningApplication *me = self.currentApplication;
  return pid == me.processIdentifier ? me : nil;
}

- (pid_t)processIdentifier { return _pid; }
- (NSString *)bundleIdentifier { return _bundleID; }
- (NSString *)localizedName {
  return NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: NSBundle.mainBundle.infoDictionary[@"CFBundleName"];
}
- (NSURL *)bundleURL { return NSBundle.mainBundle.bundleURL; }
- (NSURL *)executableURL { return NSBundle.mainBundle.executableURL; }
- (NSDate *)launchDate { return _launchDate; }

// This app is active whenever it is in the foreground.
- (BOOL)isActive { return UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }
- (BOOL)isHidden { return UIApplication.sharedApplication.applicationState == UIApplicationStateBackground; }
- (BOOL)isTerminated { return NO; }
- (BOOL)isFinishedLaunching { return YES; }

- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options { return self == NSRunningApplication.currentApplication; }
- (BOOL)hide { return NO; }   // an app can't background itself on iOS
- (BOOL)unhide { return NO; }
- (BOOL)terminate { return NO; }
- (BOOL)forceTerminate { return NO; }

@end
