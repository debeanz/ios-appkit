#import "AKShimPrivate.h"
#import "AppKitShim/NSTextInputContext.h"
#import "AppKitShim/NSTrackingArea.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Coordinates. AppKit measures from the bottom-left: window points go up from the bottom of
// the content area, and a view's own points do too unless it says -isFlipped (the default is
// not flipped). UIKit measures from the top-left. The shim keeps UIKit's geometry underneath
// and converts at the AppKit surface — frames, point/rect conversion, event locations and
// drawing — so Mac code that does its own flipping (Chromium flips every mouse point by its
// view's height) gets the numbers it would get on a Mac.

// A UIView subclass that calls back into its owning NSView for drawing and layout, so NSView
// subclasses that override -drawRect: or -setFrameSize: keep working. Input lives in InputBridge.m.
@implementation _AKShimBackingView
- (void)drawRect:(CGRect)rect {
  NSView *owner = self.owner;
  // An OpenGL view draws with a context current on the thread that made it (a game's main
  // thread, where AppKit would ask it), and its frames go to a layer of their own.
  if ([owner isKindOfClass:NSOpenGLView.class]) {
    [owner _ak_performOnOwnerThread:^{ [(NSOpenGLView *)owner _ak_display]; }];
    return;
  }
  if (owner.isFlipped) { [owner drawRect:rect]; return; }
  // An unflipped view draws with y going up, as on the Mac.
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  CGFloat h = self.bounds.size.height;
  CGContextSaveGState(ctx);
  CGContextTranslateCTM(ctx, 0, h);
  CGContextScaleCTM(ctx, 1, -1);
  [owner drawRect:CGRectMake(rect.origin.x, h - rect.origin.y - rect.size.height, rect.size.width, rect.size.height)];
  CGContextRestoreGState(ctx);
}
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

// Made by a nib (NibLoading.m). As in AppKit, no -initWithFrame: of the app's own runs: the
// nearest of the shim's classes sets the view up (an NSTextField its parts), then the
// archived flags and subviews apply.
- (instancetype)initWithCoder:(NSCoder *)coder {
  Class shim = self.class;
  const char *image = class_getImageName(NSView.class);
  while (shim && !(class_getImageName(shim) && strcmp(class_getImageName(shim), image) == 0)) shim = class_getSuperclass(shim);
  IMP setUp = class_getMethodImplementation(shim ?: NSView.class, @selector(initWithFrame:));
  // That initializer takes its receiver and returns its result owned, like any -init.
  void *made = ((void *(*)(void *, SEL, NSRect))setUp)((__bridge_retained void *)self, @selector(initWithFrame:), AKNibDecodeFrame(coder));
  self = (__bridge_transfer NSView *)made;
  if (self) [self _ak_applyNibCoder:coder];
  return self;
}

- (void)_ak_applyNibCoder:(NSCoder *)coder {
  uint32_t flags = (uint32_t)[coder decodeInt64ForKey:@"NSvFlags"];
  self.autoresizingMask = flags & 0x3F;
  if (flags & 0x80000000u) self.hidden = YES;
  if ([coder containsValueForKey:@"NSViewWantsBestResolutionOpenGLSurface"])
    self.wantsBestResolutionOpenGLSurface = [coder decodeBoolForKey:@"NSViewWantsBestResolutionOpenGLSurface"];
  id subviews = [coder decodeObjectForKey:@"NSSubviews"];
  if ([subviews isKindOfClass:NSArray.class])
    for (id view in subviews) if ([view isKindOfClass:NSView.class]) [self addSubview:view];
}

- (void)_ak_performOnOwnerThread:(dispatch_block_t)block {
  CFRunLoopRef loop = _ownerLoop;
  if (!loop || loop == CFRunLoopGetCurrent()) { block(); return; }
  CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, block);
  CFRunLoopWakeUp(loop);
}

- (UIView *)backingView { return _backing; }

#pragma mark Geometry

// A frame is in the superview's coordinates: measured from its bottom unless it is flipped.
static BOOL AKMeasuresFromBottom(NSView *superview) { return superview && !superview.isFlipped; }

- (NSRect)frame {
  CGRect f = _backing.frame;
  NSView *sup = self.superview;
  if (AKMeasuresFromBottom(sup)) f.origin.y = sup.backing.bounds.size.height - f.origin.y - f.size.height;
  return f;
}

- (void)setFrame:(NSRect)frame {
  [self setFrameOrigin:frame.origin];
  [self setFrameSize:frame.size];
}

// Each setter works out the UIKit frame first and skips the trip to the main thread when it
// is already there: Chromium re-sends unchanged frames, and every trip waits for Steam's loop.
- (void)setFrameOrigin:(NSPoint)origin {
  CGRect f = _backing.frame;
  NSView *sup = self.superview;
  f.origin.x = origin.x;
  f.origin.y = AKMeasuresFromBottom(sup) ? sup.backing.bounds.size.height - origin.y - f.size.height : origin.y;
  if (CGRectEqualToRect(f, _backing.frame)) return;
  AKOnMainSync(^{ self->_backing.frame = f; });
}

- (void)setFrameSize:(NSSize)size {
  if (!_applyingLayout) {
    CGRect f = _backing.frame;
    // Measured from the bottom, a size change keeps the bottom edge where it is.
    if (AKMeasuresFromBottom(self.superview)) f.origin.y += f.size.height - size.height;
    f.size = size;
    if (!CGRectEqualToRect(f, _backing.frame)) AKOnMainSync(^{ self->_backing.frame = f; });
  }
  _lastSize = size;
  [self _ak_layoutLayers];
}

// Place the backing view for `frame` given in the current superview's coordinates, without
// going through the overridable setters (AppKit doesn't call them when a view is moved).
- (void)_ak_placeFrame:(NSRect)frame {
  CGRect f = frame;
  NSView *sup = self.superview;
  if (AKMeasuresFromBottom(sup)) f.origin.y = sup.backing.bounds.size.height - frame.origin.y - frame.size.height;
  if (CGRectEqualToRect(f, _backing.frame)) return;
  AKOnMainSync(^{ self->_backing.frame = f; });
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

// AppKit's default: y goes up. Views that want top-down coordinates override this.
- (BOOL)isFlipped { return NO; }

- (BOOL)hidden { return _backing.hidden; }
- (void)setHidden:(BOOL)h {
  if (_backing.hidden == h) return;
  AKOnMainSync(^{ self->_backing.hidden = h; });
}

- (NSArray<NSView *> *)subviews { return [_mutableSubviews copy]; }

#pragma mark Layers

- (void)setWantsLayer:(BOOL)flag { _wantsLayer = flag; }

// Whether an OpenGL context draws this view at the screen's resolution (NSOpenGL.m) or in
// points. Touches always come through UIKit.
static char kBestResolutionKey;
- (void)setWantsBestResolutionOpenGLSurface:(BOOL)flag {
  objc_setAssociatedObject(self, &kBestResolutionKey, @(flag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (BOOL)wantsBestResolutionOpenGLSurface { return [objc_getAssociatedObject(self, &kBestResolutionKey) boolValue]; }
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

  // As in AppKit, the frame keeps its numbers across the move; they are read in the new
  // superview's coordinates (which may measure from the bottom where the old one didn't).
  NSRect frame = view.frame;
  [view _ak_detachFromSuperview];
  view.superview = self;
  view.nextResponder = self;
  [_mutableSubviews addObject:view];
  AKOnMainSync(^{ [self->_backing addSubview:view.backing]; });
  [view _ak_placeFrame:frame];
  [view _ak_applyAutoresizing];

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

// AppKit's "is this point in this rect" (point and rect in this view's coordinates).
- (BOOL)mouse:(NSPoint)point inRect:(NSRect)rect { return CGRectContainsPoint(rect, point); }

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

// The superview's list may hold the last reference to this view, and AppKit doesn't let go of
// it there: the removed view is autoreleased, so it lives until the current event is done.
// Mac code relies on that — Steam brings a popup to the front with
//   [view removeFromSuperview]; [superview addSubview:view positioned:... relativeTo:nil];
// holding no reference of its own in between. Releasing on the spot freed the view first
// (Steam's menu crashed opening, on -dealloc and then on the re-add).
- (void)removeFromSuperview {
  if (!self.superview) return;
  CFAutorelease(CFBridgingRetain(self));
  NSWindow *oldWindow = self.window;
  [self viewWillMoveToSuperview:nil];
  if (oldWindow) AKViewWillMoveToWindow(self, nil);
  [self _ak_detachFromSuperview];
  [self viewDidMoveToSuperview];
  if (oldWindow) AKViewDidMoveToWindow(self);
}

- (void)_ak_detachFromSuperview {
  NSView *sup = self.superview;
  if (!sup) return;
  __attribute__((objc_precise_lifetime)) NSView *keepAlive = self;
  self.superview = nil;
  if (self.nextResponder == sup) self.nextResponder = nil;
  AKOnMainSync(^{ [self->_backing removeFromSuperview]; });
  [sup.mutableSubviews removeObjectIdenticalTo:self];
  (void)keepAlive;
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

// A redraw request has no result to wait for: from another thread it is queued, not awaited.
static void AKOnMainLater(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}
- (void)setNeedsDisplay:(BOOL)flag { if (flag) AKOnMainLater(^{ [self->_backing setNeedsDisplay]; }); }
- (void)setNeedsDisplayInRect:(NSRect)rect {
  CGRect r = [self _ak_uikitRect:rect];
  AKOnMainLater(^{ [self->_backing setNeedsDisplayInRect:r]; });
}
- (void)drawRect:(NSRect)dirtyRect { /* override point */ }

// This view's AppKit coordinates <-> its backing view's UIKit coordinates (the same flip
// both ways).
- (CGPoint)_ak_uikitPoint:(NSPoint)p {
  return self.isFlipped ? p : CGPointMake(p.x, _backing.bounds.size.height - p.y);
}
- (CGRect)_ak_uikitRect:(NSRect)r {
  if (self.isFlipped) return r;
  r.origin.y = _backing.bounds.size.height - r.origin.y - r.size.height;
  return r;
}

// A nil view means the window: points measured up from the bottom-left of its content area
// (windows here fill the screen, so these are screen points too).
- (UIView *)_ak_windowSpace {
  return self.window.contentView.backingView ?: _backing;
}

- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view {
  UIView *space = view ? view.backing : [self _ak_windowSpace];
  CGPoint p = view ? [view _ak_uikitPoint:point] : CGPointMake(point.x, space.bounds.size.height - point.y);
  if (space != _backing) p = [_backing convertPoint:p fromView:space];
  return [self _ak_uikitPoint:p]; // the flip is its own inverse
}
- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view {
  UIView *space = view ? view.backing : [self _ak_windowSpace];
  CGPoint p = [self _ak_uikitPoint:point];
  if (space != _backing) p = [_backing convertPoint:p toView:space];
  return view ? [view _ak_uikitPoint:p] : NSMakePoint(p.x, space.bounds.size.height - p.y);
}
- (NSRect)convertRect:(NSRect)rect fromView:(NSView *)view {
  UIView *space = view ? view.backing : [self _ak_windowSpace];
  CGRect r = rect;
  if (view) r = [view _ak_uikitRect:rect];
  else r.origin.y = space.bounds.size.height - rect.origin.y - rect.size.height;
  if (space != _backing) r = [_backing convertRect:r fromView:space];
  return [self _ak_uikitRect:r];
}
- (NSRect)convertRect:(NSRect)rect toView:(NSView *)view {
  UIView *space = view ? view.backing : [self _ak_windowSpace];
  CGRect r = [self _ak_uikitRect:rect];
  if (space != _backing) r = [_backing convertRect:r toView:space];
  if (view) return [view _ak_uikitRect:r];
  r.origin.y = space.bounds.size.height - r.origin.y - r.size.height;
  return r;
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

// Route backing-view autoresizing onto UIKit's equivalent. AppKit's MinY margin is the one
// at the low-y edge: the bottom in a superview that measures from the bottom, the top in a
// flipped one. And with no flexible y part, a frame measured from the bottom keeps its
// bottom margin when the superview grows — UIKit's flexible top margin.
- (void)setAutoresizingMask:(NSAutoresizingMaskOptions)mask {
  _autoresizingMask = mask;
  [self _ak_applyAutoresizing];
}

- (void)_ak_applyAutoresizing {
  NSAutoresizingMaskOptions mask = _autoresizingMask;
  UIViewAutoresizing u = UIViewAutoresizingNone;
  if (mask & NSViewWidthSizable)  u |= UIViewAutoresizingFlexibleWidth;
  if (mask & NSViewHeightSizable) u |= UIViewAutoresizingFlexibleHeight;
  if (mask & NSViewMinXMargin)    u |= UIViewAutoresizingFlexibleLeftMargin;
  if (mask & NSViewMaxXMargin)    u |= UIViewAutoresizingFlexibleRightMargin;
  if (AKMeasuresFromBottom(self.superview)) {
    if (mask & NSViewMinYMargin) u |= UIViewAutoresizingFlexibleBottomMargin;
    if (mask & NSViewMaxYMargin) u |= UIViewAutoresizingFlexibleTopMargin;
    if (!(mask & (NSViewMinYMargin | NSViewMaxYMargin | NSViewHeightSizable))) u |= UIViewAutoresizingFlexibleTopMargin;
  } else {
    if (mask & NSViewMinYMargin) u |= UIViewAutoresizingFlexibleTopMargin;
    if (mask & NSViewMaxYMargin) u |= UIViewAutoresizingFlexibleBottomMargin;
  }
  if (_backing.autoresizingMask == u) return;
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
