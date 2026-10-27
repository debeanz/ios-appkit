// NSRunningApplication — describes a running app. On iOS only this app is visible to itself,
// so there is one: the current application. The client reads processIdentifier, bundle id and
// activation state, mostly for its own process.
#import <Foundation/Foundation.h>

typedef NS_OPTIONS(NSUInteger, NSApplicationActivationOptions) {
  NSApplicationActivateAllWindows = 1 << 0,
  NSApplicationActivateIgnoringOtherApps = 1 << 1,
};

typedef NS_ENUM(NSInteger, NSApplicationActivationPolicyValue) {
  NSApplicationActivationPolicyRegularValue = 0,
};

@interface NSRunningApplication : NSObject
@property (class, readonly, strong) NSRunningApplication *currentApplication;
+ (NSArray<NSRunningApplication *> *)runningApplicationsWithBundleIdentifier:(NSString *)bundleIdentifier;
+ (NSRunningApplication *)runningApplicationWithProcessIdentifier:(pid_t)pid;

@property (nonatomic, readonly) pid_t processIdentifier;
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy) NSString *localizedName;
@property (nonatomic, readonly, copy) NSURL *bundleURL;
@property (nonatomic, readonly, copy) NSURL *executableURL;
@property (nonatomic, readonly, copy) NSDate *launchDate;
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly, getter=isTerminated) BOOL terminated;
@property (nonatomic, readonly, getter=isFinishedLaunching) BOOL finishedLaunching;

- (BOOL)activateWithOptions:(NSApplicationActivationOptions)options;
- (BOOL)hide;
- (BOOL)unhide;
- (BOOL)terminate;
- (BOOL)forceTerminate;
@end
