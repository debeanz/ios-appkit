#import "AppKitShim/NSApplication.h"
#import "AppKitShim/NSWindow.h"
#import "AppKitShim/NSEvent.h"
#import <UIKit/UIKit.h>

NSApplication *NSApp = nil;

@interface NSApplication ()
@property (nonatomic, strong) NSMutableArray<NSWindow *> *mutableWindows;
@property (nonatomic, strong) NSMutableArray<NSEvent *> *eventQueue;
@property (nonatomic, assign, getter=isRunning, readwrite) BOOL running;
@property (nonatomic, weak) NSResponder *firstResponder;
@end

@implementation NSApplication

+ (NSApplication *)sharedApplication {
  static NSApplication *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[NSApplication alloc] init];
    shared.mutableWindows = [NSMutableArray array];
    shared.eventQueue = [NSMutableArray array];
    NSApp = shared;
  });
  return shared;
}

- (NSArray<NSWindow *> *)windows { return [_mutableWindows copy]; }

- (NSWindow *)keyWindow {
  for (NSWindow *w in _mutableWindows) if (w.isKeyWindow) return w;
  return nil;
}

// The UIKit run loop is already spinning, so -run does not block: it marks the app
// running and lets control return to UIApplicationMain. Steam calls -run on a thread
// and pumps events with -nextEventMatchingMask:, which the shim serves from eventQueue.
- (void)run {
  self.running = YES;
  [self finishLaunching];
}

- (void)finishLaunching {
  if ([_delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) {
    NSNotification *n = [NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification" object:self];
    [_delegate applicationDidFinishLaunching:n];
  }
}

- (void)stop:(id)sender { self.running = NO; }

- (void)terminate:(id)sender {
  if ([_delegate respondsToSelector:@selector(applicationWillTerminate:)]) {
    [_delegate applicationWillTerminate:[NSNotification notificationWithName:@"NSApplicationWillTerminateNotification" object:self]];
  }
  exit(0);
}

- (void)activateIgnoringOtherApps:(BOOL)flag { /* single foreground app on iOS */ }
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy { return YES; }

- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart {
  @synchronized (_eventQueue) {
    if (atStart) [_eventQueue insertObject:event atIndex:0];
    else [_eventQueue addObject:event];
  }
}

- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask
                         untilDate:(NSDate *)date
                            inMode:(NSString *)mode
                           dequeue:(BOOL)dequeue {
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

- (void)sendEvent:(NSEvent *)event {
  NSResponder *target = _firstResponder ?: self.keyWindow.contentView;
  switch (event.type) {
    case NSEventTypeLeftMouseDown:  [target mouseDown:event]; break;
    case NSEventTypeLeftMouseUp:    [target mouseUp:event]; break;
    case NSEventTypeKeyDown:        [target keyDown:event]; break;
    case NSEventTypeKeyUp:          [target keyUp:event]; break;
    case NSEventTypeScrollWheel:    [target scrollWheel:event]; break;
    default: break;
  }
}

- (void)makeFirstResponder:(NSResponder *)responder {
  [_firstResponder resignFirstResponder];
  _firstResponder = responder;
  [responder becomeFirstResponder];
}

// Register a window when it is created. Called from NSWindow via NSApp.
- (void)_registerWindow:(NSWindow *)w { if (![_mutableWindows containsObject:w]) [_mutableWindows addObject:w]; }

@end

int NSApplicationMain(int argc, const char *argv[]) {
  (void)NSApplication.sharedApplication;
  @autoreleasepool { return UIApplicationMain(argc, (char **)argv, nil, nil); }
}
