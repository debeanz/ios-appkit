#import "AKShimPrivate.h"
#import "AppKitShim/NSTextInputContext.h"
#import "AppKitShim/NSTrackingArea.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

// A UIView subclass that calls back into its owning NSView for drawing and layout, so NSView
// subclasses that override -drawRect: or -setFrameSize: keep working. Input lives in InputBridge.m.
@implementation _AKShimBackingView
- (void)drawRect:(CGRect)rect { [self.owner drawRect:rect]; }
- (void)layoutSubviews {
  [super layoutSubviews];
  [self.owner _ak_backingDidLayout];
}
@end

@interface NSView ()
@property (nonatomic, strong) _AKShimBackingView *backing;
@property (nonatomic, weak, readwrite) NSView *superview;
@property (nonatomic, strong) NSMutableArray<NSView *> *mutableSubviews;
@property (nonatomic, strong) NSMutableArray<NSTrackingArea *> *mutableTrackingAreas;
@property (nonatomic, weak) NSWindow *owningWindow; // set only on a window's content view
@end

// Window-change notifications go to a view and its whole subtree, as in AppKit.
static void AKViewWillMoveToWindow(NSView *view, NSWindow *window) {
  [view viewWillMoveToWindow:window];
  for (NSView *sub in view.subviews) AKViewWillMoveToWindow(sub, window);
}

static void AKViewDidMoveToWindow(NSView *view) {
  [view viewDidMoveToWindow];
  for (NSView *sub in view.subviews) AKViewDidMoveToWindow(sub);
}

@implementation NSView {
  NSTextInputContext *_inputContext;
  CALayer *_flipLayer;   // container with macOS (bottom-left) geometry; holds _hostedLayer
  CALayer *_hostedLayer; // the client's layer
  CGSize _lastSize;
  BOOL _applyingLayout;
  CFRunLoopRef _ownerLoop; // run loop of the thread that made this view (Chromium's UI thread for its views)
}

- (instancetype)init { return [self initWithFrame:NSZeroRect]; }

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super init])) {
    _backing = [[_AKShimBackingView alloc] initWithFrame:frame];
    _backing.owner = self;
    _backing.contentMode = UIViewContentModeRedraw;
    [_backing _ak_installInputSupport];
    _mutableSubviews = [NSMutableArray array];
    _mutableTrackingAreas = [NSMutableArray array];
    _lastSize = frame.size;
    _layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    _ownerLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
  }
  return self;
}

- (void)dealloc {
  if (_ownerLoop) CFRelease(_ownerLoop);
}

- (UIView *)backingView { return _backing; }

#pragma mark Geometry

- (NSRect)frame { return _backing.frame; }

- (void)setFrame:(NSRect)frame {
  [self setFrameOrigin:frame.origin];
  [self setFrameSize:frame.size];
}

- (void)setFrameOrigin:(NSPoint)origin {
  AKOnMainSync(^{
    CGRect f = self->_backing.frame;
    f.origin = origin;
    self->_backing.frame = f;
  });
}

- (void)setFrameSize:(NSSize)size {
  if (!_applyingLayout) {
    AKOnMainSync(^{
      CGRect f = self->_backing.frame;
      f.size = size;
      self->_backing.frame = f;
    });
  }
  _lastSize = size;
  [self _ak_layoutLayers];
}

// UIKit resized the backing view (rotation, safe-area or constraint changes): tell the NSView
// through -setFrameSize: so overrides see it, without writing the size back to UIKit.
// UIKit lays out on the main thread, but a view made on another thread (Chromium's, on its
// UI thread) must hear about it there: Chromium stops the app when called off that thread.
- (void)_ak_backingDidLayout {
  [self _ak_layoutLayers];
  CGSize size = _backing.bounds.size;
  if (CGSizeEqualToSize(size, _lastSize)) return;
  if (!_ownerLoop || _ownerLoop == CFRunLoopGetCurrent()) {
    [self _ak_applyBackingSize:size];
    return;
  }
  __weak NSView *weakSelf = self;
  CFRunLoopPerformBlock(_ownerLoop, kCFRunLoopCommonModes, ^{ [weakSelf _ak_applyBackingSize:size]; });
  CFRunLoopWakeUp(_ownerLoop);
}

- (void)_ak_applyBackingSize:(CGSize)size {
  if (CGSizeEqualToSize(size, _lastSize)) return;
  _applyingLayout = YES;
  [self setFrameSize:size];
  _applyingLayout = NO;
}

// Hand an input event to the app on the thread that owns this view. UIKit calls the input
// methods on the main thread, but Chromium's views (made on its UI thread) trap when touched
// from any other thread, so the actual -[NSApp sendEvent:] runs on the owner's run loop.
// Delivery stays in order per loop (CFRunLoopPerformBlock queues), and the event already
// carries its window and target view, so it routes the same whichever thread sends it.
- (void)_ak_deliverEvent:(NSEvent *)event {
  CFRunLoopRef loop = _ownerLoop;
  if (!loop || loop == CFRunLoopGetCurrent()) {
    [NSApp sendEvent:event];
    return;
  }
  CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, ^{ [NSApp sendEvent:event]; });
  CFRunLoopWakeUp(loop);
}

- (NSRect)bounds { return _backing.bounds; }
- (void)setBounds:(NSRect)bounds { AKOnMainSync(^{ self->_backing.bounds = bounds; }); }

// UIKit is top-left origin, which is AppKit's "flipped". Report that honestly so
// callers that special-case flipped coordinates compute the right thing.
- (BOOL)isFlipped { return YES; }

- (BOOL)hidden { return _backing.hidden; }
- (void)setHidden:(BOOL)h { AKOnMainSync(^{ self->_backing.hidden = h; }); }

- (NSArray<NSView *> *)subviews { return [_mutableSubviews copy]; }

#pragma mark Layers

- (void)setWantsLayer:(BOOL)flag { _wantsLayer = flag; }

// Desktop-OpenGL and trackpad-touch switches; iOS views are always full resolution and get
// touches through UIKit.
- (void)setWantsBestResolutionOpenGLSurface:(BOOL)flag {}
- (void)setAcceptsTouchEvents:(BOOL)flag {}

// As in AppKit, a layer-backed view's layer comes from -makeBackingLayer when the view
// overrides it — SDL's Metal view returns a CAMetalLayer there, and the window surface it
// renders through needs that layer, not a plain one.
- (CALayer *)layer {
  if (!_hostedLayer && _wantsLayer) {
    SEL make = NSSelectorFromString(@"makeBackingLayer");
    CALayer *layer = nil;
    if ([self respondsToSelector:make]) layer = ((CALayer *(*)(id, SEL))objc_msgSend)(self, make);
    self.layer = layer ?: [CALayer layer];
  }
  return _hostedLayer;
}

- (void)setLayer:(CALayer *)layer {
  if (layer == _hostedLayer) return;
  [_hostedLayer removeFromSuperlayer];
  _hostedLayer = layer;
  if (!layer) return;
  _wantsLayer = YES;
  AKOnMainSync(^{
    if (!self->_flipLayer) {
      // macOS layers measure from the bottom-left, iOS layers from the top-left. Hosting the
      // client's layer inside one flipped container makes every layer below it map to the
      // screen exactly as it would on the Mac, so Mac code's own flips come out right.
      self->_flipLayer = [CALayer layer];
      self->_flipLayer.geometryFlipped = YES;
      [self->_backing.layer insertSublayer:self->_flipLayer atIndex:0]; // below subviews, as in AppKit
    }
    [self->_flipLayer addSublayer:layer];
    [self _ak_layoutLayers];
  });
}

- (void)_ak_layoutLayers {
  if (!_flipLayer) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES]; // resize in step with the view, no implicit animation
  _flipLayer.frame = _backing.bounds;
  _hostedLayer.frame = _flipLayer.bounds;
  [CATransaction commit];
}

#pragma mark View tree

// As in AppKit, a view's next responder is its superview, so unhandled events climb the tree.
- (void)addSubview:(NSView *)view {
  if (!view) return;
  NSWindow *oldWindow = view.window, *newWindow = self.window;
  [view viewWillMoveToSuperview:self];
  if (oldWindow != newWindow) AKViewWillMoveToWindow(view, newWindow);

  [view _ak_detachFromSuperview];
  view.superview = self;
  view.nextResponder = self;
  [_mutableSubviews addObject:view];
  AKOnMainSync(^{ [self->_backing addSubview:view.backing]; });

  [view viewDidMoveToSuperview];
  if (oldWindow != newWindow) AKViewDidMoveToWindow(view);
}

// NSWindowAbove = 1, NSWindowBelow = -1; with no other view, the top or bottom of the stack.
// Chromium puts its page view into a window's view tree this way.
- (void)addSubview:(NSView *)view positioned:(NSInteger)place relativeTo:(NSView *)other {
  if (!view) return;
  [self addSubview:view]; // now frontmost
  if (other && ![_mutableSubviews containsObject:other]) other = nil;
  if (place > 0 && !other) return;
  [_mutableSubviews removeObject:view];
  NSUInteger i = other ? [_mutableSubviews indexOfObject:other] + (place > 0 ? 1 : 0) : 0;
  [_mutableSubviews insertObject:view atIndex:i];
  AKOnMainSync(^{
    if (other && place > 0) [self->_backing insertSubview:view.backing aboveSubview:other.backing];
    else if (other) [self->_backing insertSubview:view.backing belowSubview:other.backing];
    else [self->_backing sendSubviewToBack:view.backing];
  });
}

// AppKit's getter for `hidden` (the shim's property getter is -hidden).
- (BOOL)isHidden { return _backing.hidden; }

// AppKit hit testing: `point` is in the superview's coordinates; the answer is the deepest
// visible view under it, frontmost first, or nil.
- (NSView *)hitTest:(NSPoint)point {
  if (_backing.hidden) return nil;
  NSPoint local = self.superview ? [self convertPoint:point fromView:self.superview] : point;
  if (!CGRectContainsPoint(self.bounds, local)) return nil;
  for (NSView *sub in [self.subviews reverseObjectEnumerator]) {
    NSView *hit = [sub hitTest:local];
    if (hit) return hit;
  }
  return self;
}

- (BOOL)isHiddenOrHasHiddenAncestor {
  for (NSView *v = self; v; v = v.superview) if (v.hidden) return YES;
  return NO;
}

// Keyboard loop, drag and drop, and trackpad touch kinds: nothing on iOS uses them.
- (void)setNextKeyView:(NSView *)next {}
- (NSView *)nextKeyView { return nil; }
- (void)registerForDraggedTypes:(NSArray *)types {}
- (void)unregisterDraggedTypes {}
- (NSUInteger)allowedTouchTypes { return 0; }
- (void)setAllowedTouchTypes:(NSUInteger)types {}

- (void)removeFromSuperview {
  if (!self.superview) return;
  NSWindow *oldWindow = self.window;
  [self viewWillMoveToSuperview:nil];
  if (oldWindow) AKViewWillMoveToWindow(self, nil);
  [self _ak_detachFromSuperview];
  [self viewDidMoveToSuperview];
  if (oldWindow) AKViewDidMoveToWindow(self);
}

- (void)_ak_detachFromSuperview {
  if (!self.superview) return;
  AKOnMainSync(^{ [self->_backing removeFromSuperview]; });
  [self.superview.mutableSubviews removeObject:self];
  if (self.nextResponder == self.superview) self.nextResponder = nil;
  self.superview = nil;
}

// A content view knows its window directly; every other view asks its superview.
- (NSWindow *)window { return self.owningWindow ?: self.superview.window; }

- (void)_setOwningWindow:(NSWindow *)window {
  NSWindow *old = self.window;
  if (old != window) AKViewWillMoveToWindow(self, window);
  self.owningWindow = window;
  self.nextResponder = window;
  if (old != window) AKViewDidMoveToWindow(self);
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {}
- (void)viewDidMoveToWindow {}
- (void)viewWillMoveToSuperview:(NSView *)newSuperview {}
- (void)viewDidMoveToSuperview {}
- (void)viewDidChangeBackingProperties {}

#pragma mark Drawing and coordinates

- (void)setNeedsDisplay:(BOOL)flag { if (flag) AKOnMainSync(^{ [self->_backing setNeedsDisplay]; }); }
- (void)setNeedsDisplayInRect:(NSRect)rect { AKOnMainSync(^{ [self->_backing setNeedsDisplayInRect:rect]; }); }
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
- (NSRect)convertRect:(NSRect)rect fromView:(NSView *)view {
  return [_backing convertRect:rect fromView:[self _ak_spaceForView:view]];
}
- (NSRect)convertRect:(NSRect)rect toView:(NSView *)view {
  return [_backing convertRect:rect toView:[self _ak_spaceForView:view]];
}

- (CGFloat)_ak_backingScale {
  CGFloat s = self.window.backingScaleFactor;
  return s > 0 ? s : UIScreen.mainScreen.scale;
}

- (NSRect)convertRectToBacking:(NSRect)r {
  CGFloat s = [self _ak_backingScale];
  return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s);
}
- (NSRect)convertRectFromBacking:(NSRect)r {
  CGFloat s = [self _ak_backingScale];
  return NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s);
}
- (NSSize)convertSizeToBacking:(NSSize)size {
  CGFloat s = [self _ak_backingScale];
  return NSMakeSize(size.width * s, size.height * s);
}
- (NSSize)convertSizeFromBacking:(NSSize)size {
  CGFloat s = [self _ak_backingScale];
  return NSMakeSize(size.width / s, size.height / s);
}
- (NSPoint)convertPointToBacking:(NSPoint)p {
  CGFloat s = [self _ak_backingScale];
  return NSMakePoint(p.x * s, p.y * s);
}
- (NSPoint)convertPointFromBacking:(NSPoint)p {
  CGFloat s = [self _ak_backingScale];
  return NSMakePoint(p.x / s, p.y / s);
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
  AKOnMainSync(^{ self->_backing.autoresizingMask = u; });
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
