#import "AKShimPrivate.h"
#import "AppKitShim/NSTextInputContext.h"
#import "AppKitShim/NSTrackingArea.h"

// A UIView subclass that calls back into its owning NSView for drawing, so an
// NSView subclass that overrides -drawRect: keeps working. Input lives in InputBridge.m.
@implementation _AKShimBackingView
- (void)drawRect:(CGRect)rect { [self.owner drawRect:rect]; }
@end

@interface NSView ()
@property (nonatomic, strong) _AKShimBackingView *backing;
@property (nonatomic, weak, readwrite) NSView *superview;
@property (nonatomic, strong) NSMutableArray<NSView *> *mutableSubviews;
@property (nonatomic, strong) NSMutableArray<NSTrackingArea *> *mutableTrackingAreas;
@property (nonatomic, weak) NSWindow *owningWindow; // set only on a window's content view
@end

@implementation NSView {
  NSTextInputContext *_inputContext;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super init])) {
    _backing = [[_AKShimBackingView alloc] initWithFrame:frame];
    _backing.owner = self;
    _backing.contentMode = UIViewContentModeRedraw;
    [_backing _ak_installInputSupport];
    _mutableSubviews = [NSMutableArray array];
    _mutableTrackingAreas = [NSMutableArray array];
  }
  return self;
}

- (UIView *)backingView { return _backing; }

- (NSRect)frame { return _backing.frame; }
- (void)setFrame:(NSRect)frame { _backing.frame = frame; }

- (NSRect)bounds { return _backing.bounds; }
- (void)setBounds:(NSRect)bounds { _backing.bounds = bounds; }

// UIKit is top-left origin, which is AppKit's "flipped". Report that honestly so
// callers that special-case flipped coordinates compute the right thing.
- (BOOL)isFlipped { return YES; }

- (BOOL)hidden { return _backing.hidden; }
- (void)setHidden:(BOOL)h { _backing.hidden = h; }

- (void)setWantsLayer:(BOOL)flag { _wantsLayer = flag; } // UIViews are always layer-backed
- (NSArray<NSView *> *)subviews { return [_mutableSubviews copy]; }

// As in AppKit, a view's next responder is its superview, so unhandled events climb the tree.
- (void)addSubview:(NSView *)view {
  if (!view) return;
  [view removeFromSuperview];
  view.superview = self;
  view.nextResponder = self;
  [_mutableSubviews addObject:view];
  [_backing addSubview:view.backing];
}

- (void)removeFromSuperview {
  [_backing removeFromSuperview];
  [self.superview.mutableSubviews removeObject:self];
  if (self.nextResponder == self.superview) self.nextResponder = nil;
  self.superview = nil;
}

// A content view knows its window directly; every other view asks its superview.
- (NSWindow *)window { return self.owningWindow ?: self.superview.window; }
- (void)_setOwningWindow:(NSWindow *)window {
  self.owningWindow = window;
  self.nextResponder = window;
}

- (void)setNeedsDisplay:(BOOL)flag { if (flag) [_backing setNeedsDisplay]; }
- (void)setNeedsDisplayInRect:(NSRect)rect { [_backing setNeedsDisplayInRect:rect]; }
- (void)drawRect:(NSRect)dirtyRect { /* override point */ }

// A nil view means window coordinates, which in the shim are the content view's coordinates
// (the window's content sits inside the safe area, so it is not the UIWindow's space).
- (UIView *)_ak_spaceForView:(NSView *)view {
  return view ? view.backing : (self.window.contentView.backingView ?: _backing);
}
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view {
  return [_backing convertPoint:point fromView:[self _ak_spaceForView:view]];
}
- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view {
  return [_backing convertPoint:point toView:[self _ak_spaceForView:view]];
}

// Route backing-view autoresizing onto the AppKit mask values that overlap UIKit's.
- (void)setAutoresizingMask:(NSAutoresizingMaskOptions)mask {
  _autoresizingMask = mask;
  UIViewAutoresizing u = UIViewAutoresizingNone;
  if (mask & NSViewWidthSizable)  u |= UIViewAutoresizingFlexibleWidth;
  if (mask & NSViewHeightSizable) u |= UIViewAutoresizingFlexibleHeight;
  if (mask & NSViewMinXMargin)    u |= UIViewAutoresizingFlexibleLeftMargin;
  if (mask & NSViewMaxXMargin)    u |= UIViewAutoresizingFlexibleRightMargin;
  if (mask & NSViewMinYMargin)    u |= UIViewAutoresizingFlexibleTopMargin;
  if (mask & NSViewMaxYMargin)    u |= UIViewAutoresizingFlexibleBottomMargin;
  _backing.autoresizingMask = u;
}

#pragma mark Text input

- (NSTextInputContext *)inputContext {
  if (!_inputContext && [self conformsToProtocol:@protocol(NSTextInputClient)]) {
    _inputContext = [[NSTextInputContext alloc] initWithClient:(id<NSTextInputClient>)self];
  }
  return _inputContext;
}

// AppKit sends key events through the view's input context when it has one; that is
// where Chromium expects -insertText:replacementRange: and -doCommandBySelector: from.
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events {
  NSTextInputContext *ctx = self.inputContext;
  if (!ctx) { [super interpretKeyEvents:events]; return; }
  for (NSEvent *e in events) [ctx handleEvent:e];
}

#pragma mark Tracking areas

- (NSArray<NSTrackingArea *> *)trackingAreas { return [_mutableTrackingAreas copy]; }
- (void)addTrackingArea:(NSTrackingArea *)area { if (area) [_mutableTrackingAreas addObject:area]; }
- (void)removeTrackingArea:(NSTrackingArea *)area { [_mutableTrackingAreas removeObject:area]; }
- (void)updateTrackingAreas { /* override point; areas with NSTrackingInVisibleRect need no update */ }

@end
