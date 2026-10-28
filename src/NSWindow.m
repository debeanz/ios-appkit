#import "AKShimPrivate.h"
#import "AppKitShim/NSTrackingArea.h"

NSNotificationName const NSWindowDidBecomeKeyNotification = @"NSWindowDidBecomeKeyNotification";
NSNotificationName const NSWindowDidResignKeyNotification = @"NSWindowDidResignKeyNotification";
NSNotificationName const NSWindowDidChangeBackingPropertiesNotification = @"NSWindowDidChangeBackingPropertiesNotification";
NSNotificationName const NSWindowDidChangeScreenNotification = @"NSWindowDidChangeScreenNotification";
NSNotificationName const NSWindowDidChangeScreenProfileNotification = @"NSWindowDidChangeScreenProfileNotification";
NSNotificationName const NSWindowWillEnterFullScreenNotification = @"NSWindowWillEnterFullScreenNotification";
NSNotificationName const NSWindowDidEnterFullScreenNotification = @"NSWindowDidEnterFullScreenNotification";
NSNotificationName const NSWindowWillExitFullScreenNotification = @"NSWindowWillExitFullScreenNotification";
NSNotificationName const NSWindowDidExitFullScreenNotification = @"NSWindowDidExitFullScreenNotification";
NSString *const NSBackingPropertyOldScaleFactorKey = @"NSBackingPropertyOldScaleFactorKey";

// The single UIWindow every NSWindow mounts its content into. Created lazily so the
// shim works whether the host app sets up its own scene or lets us make one.
static UIWindow *AKSharedUIWindow(void) {
  static UIWindow *w;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:UIWindowScene.class]) {
        UIWindowScene *ws = (UIWindowScene *)scene;
        w = ws.windows.firstObject ?: [[UIWindow alloc] initWithWindowScene:ws];
        break;
      }
    }
    if (!w) w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (!w.rootViewController) w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = UIColor.blackColor;
    [w makeKeyAndVisible];
  });
  return w;
}

static BOOL AKViewTracks(NSView *view, NSTrackingAreaOptions option) {
  for (NSTrackingArea *a in view.trackingAreas) if (a.options & option) return YES;
  return NO;
}

@interface NSWindow ()
@property (nonatomic, assign, getter=isVisible, readwrite) BOOL visible;
@property (nonatomic, assign, getter=isKeyWindow, readwrite) BOOL keyWindow;
@property (nonatomic, weak, readwrite) NSResponder *firstResponder;
@property (nonatomic, weak) NSView *hoverView;
// Window chrome and stacking a client configures (VGUI sets all of these on its windows).
// Every window here is full screen in one UIWindow, so these are recorded, not applied.
@property (nonatomic, assign) NSInteger level;
@property (nonatomic, assign) NSUInteger collectionBehavior;
@property (nonatomic, assign) NSInteger animationBehavior;
@property (nonatomic, assign, getter=isOpaque) BOOL opaque;
@property (nonatomic, assign) BOOL hasShadow;
@property (nonatomic, assign, getter=isMovable) BOOL movable;
@property (nonatomic, assign, getter=isExcludedFromWindowsMenu) BOOL excludedFromWindowsMenu;
@property (nonatomic, assign, getter=isReleasedWhenClosed) BOOL releasedWhenClosed;
@property (nonatomic, assign, getter=isOneShot) BOOL oneShot;
@property (nonatomic, assign) BOOL cursorRectsDisabled;
@end

@implementation NSWindow {
  NSRect _frame;
  NSInteger _windowNumber;
}

- (instancetype)initWithContentRect:(NSRect)rect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)defer {
  if ((self = [super init])) {
    static NSInteger nextNumber = 1;
    _windowNumber = nextNumber++;
    _frame = rect;
    _alphaValue = 1.0;
    _styleMask = style | NSWindowStyleMaskFullScreen;
    _contentView = [[NSView alloc] initWithFrame:(NSRect){{0, 0}, rect.size}];
    [_contentView _setOwningWindow:self];
    // AppKit's defaults for a new window.
    _opaque = YES;
    _hasShadow = YES;
    _movable = YES;
    _releasedWhenClosed = YES;
    [NSApplication.sharedApplication _registerWindow:self];
  }
  return self;
}

- (NSInteger)windowNumber { return _windowNumber; }

- (void)setContentView:(NSView *)contentView {
  [_contentView removeFromSuperview];
  [_contentView _setOwningWindow:nil];
  _contentView = contentView;
  [contentView _setOwningWindow:self];
  contentView.frame = (NSRect){{0, 0}, _frame.size};
}

- (NSRect)frame { return _frame; }
- (void)setFrame:(NSRect)frame {
  _frame = frame;
  if (!self.visible) _contentView.backingView.frame = (NSRect){{0, 0}, frame.size};
}

- (NSScreen *)screen { return NSScreen.mainScreen; }
- (CGFloat)backingScaleFactor { return self.screen.backingScaleFactor; }

- (void)setStyleMask:(NSWindowStyleMask)styleMask { _styleMask = styleMask | NSWindowStyleMaskFullScreen; }
- (void)toggleFullScreen:(id)sender { /* already full screen, and can't leave it */ }

#pragma mark Ordering and key status

- (void)makeKeyAndOrderFront:(id)sender {
  [self orderFront:sender];
  [self makeKeyWindow];
}

// With one screen and no inspector panels, the key window is also the main window.
- (BOOL)isMainWindow { return self.isKeyWindow; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)makeMainWindow { [self makeKeyWindow]; }

- (void)makeKeyWindow {
  NSWindow *previous = NSApp.keyWindow;
  if (previous == self) return;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  // With one screen and no inspector panels, the key window is also the main window.
  if (previous) {
    previous.keyWindow = NO;
    [nc postNotificationName:NSWindowDidResignKeyNotification object:previous];
    [nc postNotificationName:NSWindowDidResignMainNotification object:previous];
  }
  self.keyWindow = YES;
  if (!self.firstResponder) [self makeFirstResponder:_contentView];
  else [self _syncUIKitFirstResponder];
  [nc postNotificationName:NSWindowDidBecomeKeyNotification object:self];
  [nc postNotificationName:NSWindowDidBecomeMainNotification object:self];
}

- (void)orderFront:(id)sender {
  UIView *host = AKSharedUIWindow().rootViewController.view;
  UIView *bv = _contentView.backingView;
  [bv removeFromSuperview];
  [host addSubview:bv]; // last added is frontmost, i.e. ordered front
  // iOS has no menu bar or title bar: a window fills the screen inside the safe area,
  // which keeps content clear of the notch / Dynamic Island and the home indicator.
  bv.translatesAutoresizingMaskIntoConstraints = NO;
  UILayoutGuide *safe = host.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [bv.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [bv.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [bv.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [bv.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
  ]];
  bv.alpha = _alphaValue;
  self.visible = YES;
}

- (void)orderOut:(id)sender {
  [_contentView.backingView removeFromSuperview];
  _contentView.backingView.translatesAutoresizingMaskIntoConstraints = YES;
  self.visible = NO;
  if (self.keyWindow) {
    self.keyWindow = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:self];
  }
}

- (void)close {
  [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:self];
  [self orderOut:nil];
  [NSApp _unregisterWindow:self];
}

- (void)setAlphaValue:(CGFloat)a { _alphaValue = a; _contentView.backingView.alpha = a; }

#pragma mark First responder

- (BOOL)makeFirstResponder:(NSResponder *)responder {
  if (responder == _firstResponder) return YES;
  if (_firstResponder && ![_firstResponder resignFirstResponder]) return NO;
  if (responder && ![responder becomeFirstResponder]) {
    _firstResponder = nil;
    [self _syncUIKitFirstResponder];
    return NO;
  }
  _firstResponder = responder;
  [self _syncUIKitFirstResponder];
  return YES;
}

// Hardware keys only reach a UIKit first responder, so the backing view of the focused
// NSView (or the content view, if focus is on something that isn't a view) takes that role.
- (void)_syncUIKitFirstResponder {
  if (!self.keyWindow) return;
  NSView *v = [_firstResponder isKindOfClass:NSView.class] ? (NSView *)_firstResponder : _contentView;
  [v.backingView becomeFirstResponder];
}

#pragma mark Event dispatch

- (void)sendEvent:(NSEvent *)event {
  NSView *target = event._targetView ?: _contentView;
  switch (event.type) {
    case NSEventTypeLeftMouseDown:
      if (target.acceptsFirstResponder) [self makeFirstResponder:target];
      [target mouseDown:event]; break;
    case NSEventTypeLeftMouseUp:       [target mouseUp:event]; break;
    case NSEventTypeLeftMouseDragged:  [target mouseDragged:event]; break;
    case NSEventTypeRightMouseDown:
      if (target.acceptsFirstResponder) [self makeFirstResponder:target];
      [target rightMouseDown:event]; break;
    case NSEventTypeRightMouseUp:      [target rightMouseUp:event]; break;
    case NSEventTypeRightMouseDragged: [target rightMouseDragged:event]; break;
    case NSEventTypeOtherMouseDown:    [target otherMouseDown:event]; break;
    case NSEventTypeOtherMouseUp:      [target otherMouseUp:event]; break;
    case NSEventTypeOtherMouseDragged: [target otherMouseDragged:event]; break;
    case NSEventTypeScrollWheel:       [target scrollWheel:event]; break;
    case NSEventTypeMouseMoved:        [self _dispatchHover:event target:target]; break;
    case NSEventTypeKeyDown:
    case NSEventTypeKeyUp:
    case NSEventTypeFlagsChanged: {
      NSResponder *r = _firstResponder ?: _contentView;
      if (event.type == NSEventTypeKeyDown) {
        if ([r performKeyEquivalent:event]) break;
        // Command shortcuts (copy, paste, select all...) live in the main menu, as on the Mac.
        if ((event.modifierFlags & NSEventModifierFlagCommand) && [NSApp.mainMenu performKeyEquivalent:event]) break;
        [r keyDown:event];
      } else if (event.type == NSEventTypeKeyUp) [r keyUp:event];
      else [r flagsChanged:event];
      break;
    }
    default: break;
  }
}

// Pointer hover (iPad trackpad/mouse): enter/exit when the view under the pointer changes,
// then mouseMoved: for views that asked for it.
- (void)_dispatchHover:(NSEvent *)event target:(NSView *)target {
  NSView *previous = self.hoverView;
  if (previous != target) {
    if (previous && AKViewTracks(previous, NSTrackingMouseEnteredAndExited)) [previous mouseExited:event];
    if (AKViewTracks(target, NSTrackingMouseEnteredAndExited)) [target mouseEntered:event];
    self.hoverView = target;
  }
  if (_acceptsMouseMovedEvents || AKViewTracks(target, NSTrackingMouseMoved)) [target mouseMoved:event];
}

- (NSPoint)mouseLocationOutsideOfEventStream { return [NSEvent mouseLocation]; }

// Borderless on iOS: the content rect and frame rect are the same.
- (NSRect)contentRectForFrameRect:(NSRect)frameRect { return frameRect; }
- (NSRect)frameRectForContentRect:(NSRect)contentRect { return contentRect; }

#pragma mark Coordinates — window space is screen space offset by the frame origin

- (NSRect)convertRectToScreen:(NSRect)rect {
  return NSMakeRect(rect.origin.x + _frame.origin.x, rect.origin.y + _frame.origin.y, rect.size.width, rect.size.height);
}
- (NSRect)convertRectFromScreen:(NSRect)rect {
  return NSMakeRect(rect.origin.x - _frame.origin.x, rect.origin.y - _frame.origin.y, rect.size.width, rect.size.height);
}
- (NSPoint)convertPointToScreen:(NSPoint)point {
  return NSMakePoint(point.x + _frame.origin.x, point.y + _frame.origin.y);
}
- (NSPoint)convertPointFromScreen:(NSPoint)point {
  return NSMakePoint(point.x - _frame.origin.x, point.y - _frame.origin.y);
}

- (void)setFrame:(NSRect)frame display:(BOOL)display { [self setFrame:frame]; }
- (void)setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate { [self setFrame:frame]; }

#pragma mark State a client polls — answered so it keeps rendering

// Every window is full screen and frontmost: never minimized, always on the active space,
// and visible. A zero (the fallback's answer) would read as "occluded", and SDL stops
// presenting frames to an occluded window.
- (BOOL)isZoomed { return YES; }
- (BOOL)isMiniaturized { return NO; }
- (BOOL)isOnActiveSpace { return YES; }
- (BOOL)inLiveResize { return NO; }
- (NSUInteger)occlusionState { return 1u << 1; }  // NSWindowOcclusionStateVisible
- (void)center {}
- (NSWindow *)parentWindow { return nil; }
- (NSArray<NSWindow *> *)childWindows { return @[]; }

// Stacking within a level: every window is full screen, so "behind the others" still means
// shown — order it in without taking key status, as AppKit's -orderBack: does.
- (void)orderBack:(id)sender { if (!self.isVisible) [self orderFront:sender]; }

// Cursor rectangles (the pointer shape per region); recorded so the getter round-trips.
- (void)disableCursorRects { self.cursorRectsDisabled = YES; }
- (void)enableCursorRects { self.cursorRectsDisabled = NO; }
- (BOOL)areCursorRectsEnabled { return !self.cursorRectsDisabled; }

@end
