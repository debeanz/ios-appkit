#import "AKShimPrivate.h"
#import "AppKitShim/AKShimInput.h"

NSApplication *NSApp = nil;
NSRunLoopMode const NSEventTrackingRunLoopMode = @"NSEventTrackingRunLoopMode";
NSNotificationName const NSApplicationDidChangeScreenParametersNotification = @"NSApplicationDidChangeScreenParametersNotification";

@interface NSApplication ()
@property (nonatomic, strong) NSMutableArray<NSWindow *> *mutableWindows;
@property (nonatomic, strong) NSMutableArray<NSEvent *> *eventQueue;
@property (nonatomic, assign, getter=isRunning, readwrite) BOOL running;
// Menus the client builds on the Mac. Tracked so getters round-trip; never shown (iOS has
// no menu bar — Big Picture draws its own UI).
@property (nonatomic, strong) NSMenu *servicesMenu;
@property (nonatomic, strong) NSMenu *windowsMenu;
@property (nonatomic, strong) NSMenu *helpMenu;
@property (nonatomic, strong) NSMenu *appleMenu;
@property (nonatomic, strong) NSImage *applicationIconImage;
@property (nonatomic, assign) NSUInteger presentationOptions;
@property (nonatomic, assign) NSInteger modalDepth;
@end

@implementation NSApplication

+ (NSApplication *)sharedApplication {
  static NSApplication *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // CEF installs an NSApplication subclass by calling +sharedApplication on it first,
    // so build an instance of whichever class got here.
    shared = [[self alloc] init];
    shared.mutableWindows = [NSMutableArray array];
    shared.eventQueue = [NSMutableArray array];
    NSApp = shared;
    [shared _ak_bridgeLifecycleNotifications];
  });
  return shared;
}

// UIKit's app lifecycle, re-posted under AppKit's names (Chromium pauses work and tracks
// activation through these).
- (void)_ak_bridgeLifecycleNotifications {
  NSDictionary<NSNotificationName, NSNotificationName> *map = @{
    UIApplicationDidBecomeActiveNotification: NSApplicationDidBecomeActiveNotification,
    UIApplicationWillResignActiveNotification: NSApplicationDidResignActiveNotification,
    UIApplicationWillEnterForegroundNotification: NSApplicationWillBecomeActiveNotification,
    UIApplicationDidEnterBackgroundNotification: NSApplicationDidHideNotification,
    UIApplicationWillTerminateNotification: NSApplicationWillTerminateNotification,
  };
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [map enumerateKeysAndObjectsUsingBlock:^(NSNotificationName ui, NSNotificationName appkit, BOOL *stop) {
    [nc addObserverForName:ui object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
      [NSNotificationCenter.defaultCenter postNotificationName:appkit object:NSApp];
    }];
  }];
}

- (NSArray<NSWindow *> *)windows { return [_mutableWindows copy]; }

- (NSWindow *)keyWindow {
  for (NSWindow *w in _mutableWindows) if (w.isKeyWindow) return w;
  return nil;
}

- (NSWindow *)windowWithWindowNumber:(NSInteger)windowNumber {
  for (NSWindow *w in _mutableWindows) if (w.windowNumber == windowNumber) return w;
  return nil;
}

- (void)_registerWindow:(NSWindow *)w { if (![_mutableWindows containsObject:w]) [_mutableWindows addObject:w]; }
- (void)_unregisterWindow:(NSWindow *)w { [_mutableWindows removeObject:w]; }

// The UIKit run loop is already spinning, so -run does not block: it marks the app
// running and lets control return to UIApplicationMain. Steam calls -run on a thread
// and pumps events with -nextEventMatchingMask:, which the shim serves from eventQueue.
- (void)run {
  self.running = YES;
  [self finishLaunching];
}

- (void)finishLaunching {
  NSNotification *n = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self];
  if ([_delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) [_delegate applicationDidFinishLaunching:n];
  [NSNotificationCenter.defaultCenter postNotification:n];
}

- (void)stop:(id)sender { self.running = NO; }

- (void)terminate:(id)sender {
  if ([_delegate respondsToSelector:@selector(applicationWillTerminate:)]) {
    [_delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:self]];
  }
  exit(0);
}

- (void)activateIgnoringOtherApps:(BOOL)flag { /* single foreground app on iOS */ }
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy { return YES; }

// Run loops of threads waiting in -nextEventMatchingMask:, each with the source that wakes
// it, so a posted event ends the wait at once.
static NSMutableArray<NSValue *> *gWaiters;   // CFRunLoopSourceRef, paired with its run loop
static NSMutableArray<NSValue *> *gWaiterLoops;

static void noopPerform(void *info) {}

- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart {
  @synchronized (_eventQueue) {
    if (atStart) [_eventQueue insertObject:event atIndex:0];
    else [_eventQueue addObject:event];
    for (NSUInteger i = 0; i < gWaiters.count; i++) {
      CFRunLoopSourceSignal((CFRunLoopSourceRef)gWaiters[i].pointerValue);
      CFRunLoopWakeUp((CFRunLoopRef)gWaiterLoops[i].pointerValue);
    }
  }
}

- (NSEvent *)_ak_dequeueMatching:(NSUInteger)mask dequeue:(BOOL)dequeue {
  @synchronized (_eventQueue) {
    for (NSUInteger i = 0; i < _eventQueue.count; i++) {
      NSEvent *e = _eventQueue[i];
      if (mask & (1UL << e.type)) {
        if (dequeue) [_eventQueue removeObjectAtIndex:i];
        return e;
      }
    }
  }
  return nil;
}

// On the main thread the UIKit run loop is already spinning around the caller, so this only
// takes what is queued. Another thread pumping its own loop (CEF's message loop, run by an
// in-process helper) gets AppKit's real behaviour: that thread's run loop runs in `mode`
// until an event arrives or `date` passes, which is what services the work Chromium
// schedules on it. Without that it would spin without ever running its timers and sources.
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask
                         untilDate:(NSDate *)date
                            inMode:(NSString *)mode
                           dequeue:(BOOL)dequeue {
  NSEvent *e = [self _ak_dequeueMatching:mask dequeue:dequeue];
  if (e || NSThread.isMainThread) return e;

  CFStringRef cfMode = (__bridge CFStringRef)(mode ?: NSDefaultRunLoopMode);
  CFRunLoopRef loop = CFRunLoopGetCurrent();
  // A source of its own keeps the mode from being empty (an empty mode returns at once).
  static NSMutableDictionary<NSValue *, NSValue *> *sources;
  CFRunLoopSourceRef src;
  @synchronized (_eventQueue) {
    if (!sources) { sources = [NSMutableDictionary dictionary]; gWaiters = [NSMutableArray array]; gWaiterLoops = [NSMutableArray array]; }
    NSValue *key = [NSValue valueWithPointer:loop];
    src = (CFRunLoopSourceRef)sources[key].pointerValue;
    if (!src) {
      CFRunLoopSourceContext ctx = { .version = 0, .perform = noopPerform };
      src = CFRunLoopSourceCreate(NULL, 0, &ctx);
      sources[key] = [NSValue valueWithPointer:src];
    }
    [gWaiters addObject:[NSValue valueWithPointer:src]];
    [gWaiterLoops addObject:key];
  }
  CFRunLoopAddSource(loop, src, cfMode);

  NSTimeInterval left = date ? date.timeIntervalSinceNow : 0;
  while (!(e = [self _ak_dequeueMatching:mask dequeue:dequeue]) && left > 0) {
    CFRunLoopRunInMode(cfMode, MIN(left, 1.0), true);
    left = date.timeIntervalSinceNow;
  }

  @synchronized (_eventQueue) {
    NSUInteger i = [gWaiters indexOfObject:[NSValue valueWithPointer:src]];
    if (i != NSNotFound) { [gWaiters removeObjectAtIndex:i]; [gWaiterLoops removeObjectAtIndex:i]; }
  }
  return e;
}

- (void)sendEvent:(NSEvent *)event {
  event = AKRunLocalEventMonitors(event);  // a local monitor may replace or swallow it
  if (!event) return;
  AKNoteInputEvent(event);
  NSWindow *window = event.window ?: self.keyWindow;
  [window sendEvent:event];
  // A click or key press may have moved focus into or out of a text field.
  AKShimUpdateSoftwareKeyboard();
}

- (void)makeFirstResponder:(NSResponder *)responder { [self.keyWindow makeFirstResponder:responder]; }

#pragma mark Menus (tracked; not shown on iOS)

// servicesMenu/windowsMenu/helpMenu/appleMenu are properties above (auto getters/setters).
// SDL's Mac app setup assigns all of these while building the menu bar; keeping them avoids
// log noise. mainMenu is a property in the header.

// The Window menu's list of open windows (SDL keeps it current); there's no menu to update.
- (void)addWindowsItem:(NSWindow *)win title:(NSString *)title filename:(BOOL)isFilename {}
- (void)changeWindowsItem:(NSWindow *)win title:(NSString *)title filename:(BOOL)isFilename {}
- (void)removeWindowsItem:(NSWindow *)win {}

// No Dock: nil, so badge labels and display requests sent to the tile do nothing.
- (id)dockTile { return nil; }

#pragma mark Activation / visibility (single foreground app on iOS)

- (void)hide:(id)sender {}
- (void)unhide:(id)sender {}
- (void)unhideWithoutActivation {}
- (void)hideOtherApplications:(id)sender {}
- (void)unhideAllApplications:(id)sender {}
- (BOOL)isHidden { return NO; }
- (BOOL)isActive { return YES; }
- (void)activate {}
- (void)updateWindows {}
- (void)setWindowsNeedUpdate:(BOOL)needUpdate {}
- (NSInteger)activationPolicy { return NSApplicationActivationPolicyRegular; }
- (NSWindow *)mainWindow { return self.keyWindow; }
- (NSInteger)requestUserAttention:(NSInteger)requestType { return 0; }
- (void)cancelUserAttentionRequest:(NSInteger)request {}

- (NSArray<NSWindow *> *)orderedWindows { return [self.mutableWindows copy]; }
- (void)enumerateWindowsWithOptions:(NSUInteger)options
                         usingBlock:(void (^)(NSWindow *window, BOOL *stop))block {
  if (!block) return;
  BOOL stop = NO;
  for (NSWindow *w in [self.mutableWindows copy]) { block(w, &stop); if (stop) break; }
}

#pragma mark Appearance — the client only reads it; nil means "no override"

- (id)effectiveAppearance { return nil; }
- (id)appearance { return nil; }
- (void)setAppearance:(id)appearance {}

#pragma mark Modal sessions — no nested UI; report "keep running" so loops exit cleanly

// Steam/SDL rarely run a real modal loop here. Returning a session that immediately reports
// "stopped" means a -runModalSession: loop finishes at once instead of spinning forever.
- (void *)beginModalSessionForWindow:(NSWindow *)window { self.modalDepth++; return (void *)(intptr_t)self.modalDepth; }
- (NSInteger)runModalSession:(void *)session { return -1001; /* NSModalResponseStop */ }
- (void)endModalSession:(void *)session { if (self.modalDepth > 0) self.modalDepth--; }
- (NSInteger)runModalForWindow:(NSWindow *)window { return -1000; /* NSModalResponseOK */ }
- (void)stopModalWithCode:(NSInteger)returnCode {}
- (void)stopModal {}
- (void)abortModal {}
- (NSWindow *)modalWindow { return nil; }

#pragma mark Action dispatch down the responder chain

- (id)targetForAction:(SEL)action {
  for (NSResponder *r = self.keyWindow.firstResponder; r; r = r.nextResponder)
    if ([r respondsToSelector:action]) return r;
  return [self respondsToSelector:action] ? self : nil;
}

- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender {
  id dest = target ?: [self targetForAction:action];
  if (!dest || ![dest respondsToSelector:action]) return NO;
  IMP imp = [dest methodForSelector:action];
  ((void (*)(id, SEL, id))imp)(dest, action, sender);
  return YES;
}

AK_UNIMPLEMENTED_FORWARDER

@end

int NSApplicationMain(int argc, const char *argv[]) {
  (void)NSApplication.sharedApplication;
  @autoreleasepool { return UIApplicationMain(argc, (char **)argv, nil, nil); }
}
