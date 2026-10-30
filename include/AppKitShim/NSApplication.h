// NSApplication — the process-wide singleton. On the Mac it owns the run loop and the
// menu bar; here it wraps the shared UIApplication and the active scene. CEF and Steam
// call [NSApp run], post custom events, and expect a delegate, so the shim provides a
// real run loop (the UIKit one is already running) and an event queue for -postEvent:.
#import "NSResponder.h"

@class NSWindow, NSEvent, NSMenu;

typedef NS_ENUM(NSInteger, NSApplicationActivationPolicy) {
  NSApplicationActivationPolicyRegular = 0,
  NSApplicationActivationPolicyAccessory = 1,
  NSApplicationActivationPolicyProhibited = 2,
};

@protocol NSApplicationDelegate <NSObject>
@optional
- (void)applicationWillFinishLaunching:(NSNotification *)note;
- (void)applicationDidFinishLaunching:(NSNotification *)note;
- (void)applicationWillTerminate:(NSNotification *)note;
@end

@interface NSApplication : NSResponder
@property (class, readonly, strong) NSApplication *sharedApplication;
@property (nonatomic, weak) id<NSApplicationDelegate> delegate;
@property (nonatomic, strong) NSMenu *mainMenu;             // tracked, not shown on iOS
@property (nonatomic, readonly, copy) NSArray<NSWindow *> *windows;
@property (nonatomic, readonly, weak) NSWindow *keyWindow;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (readonly, strong) NSEvent *currentEvent;          // the last event dequeued or sent
@property (nonatomic, readonly) NSUInteger occlusionState;   // visible: the app is in front

- (void)run;
- (void)stop:(id)sender;
- (void)terminate:(id)sender;
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy;

- (NSWindow *)windowWithWindowNumber:(NSInteger)windowNumber;

// Steam/CEF drive input by posting synthetic events and pulling them back out.
// -sendEvent: is the single entry point for real input too: the UIKit bridge calls it,
// and it routes to the event's window (or the key window). CEF subclasses NSApplication
// and overrides it, so input must always come through here.
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart;
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask
                         untilDate:(NSDate *)date
                            inMode:(NSString *)mode
                           dequeue:(BOOL)dequeue;
- (void)sendEvent:(NSEvent *)event;
- (void)finishLaunching;

// Not AppKit API: convenience that sets the key window's first responder.
- (void)makeFirstResponder:(NSResponder *)responder;
@end

extern NSRunLoopMode const NSEventTrackingRunLoopMode;
// Posted when a screen connects, disconnects or changes mode.
extern NSNotificationName const NSApplicationDidChangeScreenParametersNotification;

// The AppKit global. Set when +sharedApplication first runs.
extern NSApplication *NSApp;

int NSApplicationMain(int argc, const char *argv[]);
