// NSWorkspace — on the Mac this launches apps, opens files and URLs, and reports on running
// apps. The client uses it mainly to open URLs (a steam:// link, a help page in the browser)
// and to ask about the frontmost app. On iOS, opening a URL goes through UIApplication, which
// hands http/https and custom schemes to whichever app claims them.
#import <Foundation/Foundation.h>
#import "NSGeometry.h"

@class NSRunningApplication, NSWorkspaceOpenConfiguration, NSImage;

extern NSNotificationName const NSWorkspaceDidActivateApplicationNotification;
extern NSNotificationName const NSWorkspaceDidDeactivateApplicationNotification;
extern NSNotificationName const NSWorkspaceActiveSpaceDidChangeNotification;
extern NSNotificationName const NSWorkspaceScreensDidSleepNotification;
extern NSNotificationName const NSWorkspaceScreensDidWakeNotification;
extern NSNotificationName const NSWorkspaceWillPowerOffNotification;
extern NSNotificationName const NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification;
extern NSString *const NSWorkspaceApplicationKey;
extern NSString *const NSWorkspaceLaunchConfigurationArguments;
extern NSString *const NSWorkspaceLaunchConfigurationEnvironment;

@interface NSWorkspace : NSObject
@property (class, readonly, strong) NSWorkspace *sharedWorkspace;
@property (nonatomic, readonly, strong) NSNotificationCenter *notificationCenter;
@property (nonatomic, readonly, copy) NSArray<NSRunningApplication *> *runningApplications;
@property (nonatomic, readonly, strong) NSRunningApplication *frontmostApplication;
@property (nonatomic, readonly, strong) NSRunningApplication *menuBarOwningApplication;

// The real work: open a URL. Hands off to UIApplication, so http/https open in the browser
// and a custom scheme opens its handler app.
- (BOOL)openURL:(NSURL *)url;
- (void)openURL:(NSURL *)url
  configuration:(NSWorkspaceOpenConfiguration *)configuration
completionHandler:(void (^)(NSRunningApplication *app, NSError *error))completionHandler;

// No separate file browser on iOS; opening a file URL goes through the same path.
- (BOOL)openFile:(NSString *)fullPath;
- (BOOL)openFile:(NSString *)fullPath withApplication:(NSString *)appName;
- (BOOL)selectFile:(NSString *)fullPath inFileViewerRootedAtPath:(NSString *)rootFullPath;

- (NSURL *)URLForApplicationToOpenURL:(NSURL *)url;
- (NSURL *)URLForApplicationWithBundleIdentifier:(NSString *)bundleIdentifier;
- (NSImage *)iconForFile:(NSString *)fullPath;
- (NSImage *)iconForContentType:(id)contentType;
@end

@interface NSWorkspaceOpenConfiguration : NSObject <NSCopying>
+ (instancetype)configuration;
@property (nonatomic, copy) NSArray<NSString *> *arguments;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic) BOOL activates;
@property (nonatomic) BOOL hides;
@property (nonatomic) BOOL createsNewApplicationInstance;
@property (nonatomic) BOOL promptsUserIfNeeded;
@end
