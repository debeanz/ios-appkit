#import "AKShimPrivate.h"
#import "AppKitShim/AKShimInput.h"
#import <objc/runtime.h>
#import <os/lock.h>

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

#pragma mark A game's app (MacPrograms.m)

// A Mac game Steam starts runs in this process, its main() on a thread of its own, and uses
// this same NSApp. On that thread the app is the game's: its own delegate, its own launch
// (Steam already had its), and an event loop that runs until it quits.
static id gGameDelegate;
static BOOL gGameRunning, gGameStopped;
static NSEvent *gCurrentEvent[2];   // Steam's, a game's (-currentEvent)

@synthesize delegate = _delegate;

// The game's code asks for its delegate from its other threads too (Unity's view sends it
// -UpdatePlayer), so its calls count wherever they come from.
- (id<NSApplicationDelegate>)delegate {
  return AKIsGameThread() || AKAddressIsInGame(__builtin_return_address(0)) ? gGameDelegate : _delegate;
}

- (void)setDelegate:(id<NSApplicationDelegate>)delegate {
  if (AKIsGameThread() || AKAddressIsInGame(__builtin_return_address(0))) gGameDelegate = delegate;
  else _delegate = delegate;
}

- (BOOL)isRunning { return AKIsGameThread() ? gGameRunning : _running; }

void AKGameAppEnded(void) {
  AKGameBackingScaleReset();
  gGameDelegate = nil;
  gCurrentEvent[1] = nil;
  gGameRunning = gGameStopped = NO;
}

// The UIKit run loop is already spinning, so -run does not block: it marks the app
// running and lets control return to UIApplicationMain. Steam calls -run on a thread
// and pumps events with -nextEventMatchingMask:, which the shim serves from eventQueue.
// A game's main thread runs AppKit's loop instead: events in, sent on, until -stop:.
- (void)run {
  if (AKIsGameThread()) {
    AKGameNoteRunLoop();
    if (!gGameRunning) [self finishLaunching];
    gGameRunning = YES;
    gGameStopped = NO;
    while (!gGameStopped) @autoreleasepool {
      NSEvent *e = [self nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]
                                        inMode:NSDefaultRunLoopMode dequeue:YES];
      if (e) [self sendEvent:e];
    }
    gGameRunning = NO;
    return;
  }
  self.running = YES;
  [self finishLaunching];
}

- (void)finishLaunching {
  id<NSApplicationDelegate> delegate = self.delegate;
  if (AKIsGameThread()) {
    // The game's delegate only: Steam's observers already had this notification once.
    NSNotification *will = [NSNotification notificationWithName:@"NSApplicationWillFinishLaunchingNotification" object:self];
    if ([delegate respondsToSelector:@selector(applicationWillFinishLaunching:)]) [delegate applicationWillFinishLaunching:will];
    gGameRunning = YES;
    NSNotification *did = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self];
    if ([delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) [delegate applicationDidFinishLaunching:did];
    return;
  }
  NSNotification *n = [NSNotification notificationWithName:NSApplicationDidFinishLaunchingNotification object:self];
  if ([delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) [delegate applicationDidFinishLaunching:n];
  [NSNotificationCenter.defaultCenter postNotification:n];
}

- (void)stop:(id)sender {
  if (AKIsGameThread()) {
    fprintf(stderr, "[AppKitShim] game: -[NSApp stop:]: its event loop ends\n");
    gGameStopped = YES;
  } else {
    self.running = NO;
  }
}

// On a game's main thread, exit() ends the game only (InProcessExec.m).
- (void)terminate:(id)sender {
  if (AKIsGameThread()) fprintf(stderr, "[AppKitShim] game: -[NSApp terminate:]: it quits\n");
  id<NSApplicationDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(applicationWillTerminate:)]) {
    [delegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:self]];
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

// An event a game posted (from its main thread, or code of its own) is for the game's loop;
// any other is for Steam's. Neither takes the other's.
static char kGameEventKey;

static BOOL isGameEvent(NSEvent *e) { return objc_getAssociatedObject(e, &kGameEventKey) != nil; }

// An event for the running game's loop, from anywhere (Steam Input's keys and mouse, CGEvents.m).
- (void)_ak_postGameEvent:(NSEvent *)event {
  objc_setAssociatedObject(event, &kGameEventKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self postEvent:event atStart:NO];
}

- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart {
  if (AKGameIsRunning() && (AKIsGameThread() || AKAddressIsInGame(__builtin_return_address(0))))
    objc_setAssociatedObject(event, &kGameEventKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
  BOOL game = AKGameIsRunning(), gameThread = game && AKIsGameThread();
  @synchronized (_eventQueue) {
    for (NSUInteger i = 0; i < _eventQueue.count; i++) {
      NSEvent *e = _eventQueue[i];
      if (isGameEvent(e) != gameThread) {
        // Left by a game that has ended: nobody's.
        if (!game) [_eventQueue removeObjectAtIndex:i--];
        continue;
      }
      if (mask & (1UL << e.type)) {
        if (dequeue) {
          [_eventQueue removeObjectAtIndex:i];
          gCurrentEvent[gameThread] = e;
        }
        return e;
      }
    }
  }
  return nil;
}

// The event last dequeued or sent, as AppKit keeps it: the game's apart from Steam's.
- (NSEvent *)currentEvent {
  @synchronized (_eventQueue) { return gCurrentEvent[AKGameIsRunning() && AKIsGameThread()]; }
}

// The app is in front whenever any of it runs (it doesn't run hidden): visible. Engines stop
// drawing for an occluded app (Unity's applicationDidChangeOcclusionState:, SDL, Godot).
- (NSUInteger)occlusionState { return 1u << 1; }   // NSApplicationOcclusionStateVisible

// How long other threads spend waiting for these steps, logged every few seconds: Chromium's
// UI thread stalls for as long as the main thread takes to get to them, which shows as lag.
static void AKNoteMainWait(CFAbsoluteTime waited) {
  static CFAbsoluteTime windowStart, total, longest;
  static unsigned count;
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  os_unfair_lock_lock(&lock);
  if (!windowStart) windowStart = now;
  count++;
  total += waited;
  if (waited > longest) longest = waited;
  BOOL report = now - windowStart >= 5;
  unsigned n = count;
  CFAbsoluteTime span = now - windowStart, sum = total, max = longest;
  if (report) { windowStart = now; total = longest = 0; count = 0; }
  os_unfair_lock_unlock(&lock);
  if (report)
    fprintf(stderr, "[AppKitShim] UIKit steps from other threads: %u in %.1fs, %.0f ms spent waiting for the main thread (longest %.0f ms)\n",
            n, span, sum * 1000, max * 1000);
}

void AKOnMainSync(dispatch_block_t block) {
  if (NSThread.isMainThread) { block(); return; }
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_main_queue(), ^{
    block();
    dispatch_semaphore_signal(done);
  });
  // The main thread serves this between turns of Steam's loop; a long wait means it is stuck.
  if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
    fprintf(stderr, "[AppKitShim] %s waiting more than 5s for the main thread to run a UIKit step\n",
            NSThread.currentThread.name.UTF8String ?: "a thread");
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  }
  AKNoteMainWait(CFAbsoluteTimeGetCurrent() - start);
}

// As in AppKit, waiting for an event runs the calling thread's run loop in `mode` until an
// event arrives or `date` passes — one pass at least, even for a date already past. On the
// main thread that pass is what lets UIKit draw, take touches and run main-queue work, since
// Steam's own loop holds the main thread and never returns to UIApplicationMain's. On another
// thread (CEF's message loop, run by an in-process helper) it services the timers and sources
// Chromium schedules there.
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask
                         untilDate:(NSDate *)date
                            inMode:(NSString *)mode
                           dequeue:(BOOL)dequeue {
  NSEvent *e = [self _ak_dequeueMatching:mask dequeue:dequeue];
  if (e) return e;

  CFStringRef cfMode = (__bridge CFStringRef)(mode ?: NSDefaultRunLoopMode);
  if (NSThread.isMainThread) {
    CFRunLoopRunInMode(cfMode, 0, true);
    if ((e = [self _ak_dequeueMatching:mask dequeue:dequeue])) return e;
    NSTimeInterval left = date ? date.timeIntervalSinceNow : 0;
    while (left > 0 && !(e = [self _ak_dequeueMatching:mask dequeue:dequeue])) {
      CFRunLoopRunInMode(cfMode, MIN(left, 1.0 / 60), true);
      left = date.timeIntervalSinceNow;
    }
    return e;
  }

  AKInProcessExitIfEnded();   // a game Steam ended for good stops pumping here
  CFRunLoopRef loop = CFRunLoopGetCurrent();
  AKGameNoteRunLoop();   // a game pumping its events here can be asked to quit through this loop
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

  // A poll (a past or nil date) still turns the loop once, as AppKit's does: a game that polls
  // every frame only sees its timers, performed blocks and quit requests through this.
  CFRunLoopRunInMode(cfMode, 0, true);
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
  @synchronized (_eventQueue) { gCurrentEvent[AKGameIsRunning() && AKIsGameThread()] = event; }
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

// A game is in full screen (its windows cover the screen, NSWindow.m), with no Dock or menu
// bar: NSApplicationPresentationFullScreen | HideDock | HideMenuBar. Steam gets what it set.
- (NSUInteger)currentSystemPresentationOptions {
  return AKIsGameThread() ? (1u << 10) | (1u << 1) | (1u << 3) : self.presentationOptions;
}
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
  if (AKIsGameThread()) return AKGameApplicationMain(argc, argv);
  (void)NSApplication.sharedApplication;
  @autoreleasepool { return UIApplicationMain(argc, (char **)argv, nil, nil); }
}
