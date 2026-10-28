// NSView — backed by a UIView. The one real subtlety is the coordinate system:
// AppKit views are bottom-left origin unless `flipped`, UIKit is top-left. This shim
// keeps a flag and converts in the geometry accessors so callers see AppKit semantics.
#import "NSResponder.h"
#import "NSGeometry.h"

@class NSWindow, NSTextInputContext, NSTrackingArea, CALayer;

typedef NS_ENUM(NSInteger, NSViewLayerContentsRedrawPolicy) {
  NSViewLayerContentsRedrawNever = 0,
  NSViewLayerContentsRedrawOnSetNeedsDisplay = 1,
  NSViewLayerContentsRedrawDuringViewResize = 2,
  NSViewLayerContentsRedrawBeforeViewResize = 3,
  NSViewLayerContentsRedrawCrossfade = 4,
};
#if __has_include(<UIKit/UIKit.h>)
@class UIView;
#endif

typedef NS_OPTIONS(NSUInteger, NSAutoresizingMaskOptions) {
  NSViewNotSizable     = 0,
  NSViewMinXMargin     = 1 << 0,
  NSViewWidthSizable   = 1 << 1,
  NSViewMaxXMargin     = 1 << 2,
  NSViewMinYMargin     = 1 << 3,
  NSViewHeightSizable  = 1 << 4,
  NSViewMaxYMargin     = 1 << 5,
};

@interface NSView : NSResponder
- (instancetype)initWithFrame:(NSRect)frame;
- (instancetype)initWithCoder:(NSCoder *)coder;   // made by a nib

@property (nonatomic, assign) NSRect frame;
@property (nonatomic, assign) NSRect bounds;
@property (nonatomic, readonly, getter=isFlipped) BOOL flipped;
@property (nonatomic, assign) BOOL wantsLayer;
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) NSAutoresizingMaskOptions autoresizingMask;

@property (nonatomic, readonly, weak) NSView *superview;
@property (nonatomic, readonly, copy) NSArray<NSView *> *subviews;
@property (nonatomic, readonly, weak) NSWindow *window;

// AppKit's -setFrame: goes through these two, and Chromium overrides -setFrameSize: to
// resize its renderer, so the shim calls them too — including when UIKit layout (rotation,
// safe-area changes) resizes the backing view.
- (void)setFrameSize:(NSSize)size;
- (void)setFrameOrigin:(NSPoint)origin;

// Layer hosting. `layer` is a CALayer the client owns and fills (Chromium attaches its
// compositor output here); it is never the backing UIView's own layer, whose delegate UIKit
// needs. It sits in a container flipped to macOS's bottom-left layer geometry, so layer
// code written for the Mac renders the right way up.
@property (nonatomic, strong) CALayer *layer;
@property (nonatomic, assign) NSViewLayerContentsRedrawPolicy layerContentsRedrawPolicy;

// Override points, called as on the Mac when the view changes window or superview.
- (void)viewWillMoveToWindow:(NSWindow *)newWindow;
- (void)viewDidMoveToWindow;
- (void)viewWillMoveToSuperview:(NSView *)newSuperview;
- (void)viewDidMoveToSuperview;
- (void)viewDidChangeBackingProperties;

// Points <-> pixels, using the window's backing scale (2x or 3x on iPhone).
- (NSRect)convertRectToBacking:(NSRect)rect;
- (NSRect)convertRectFromBacking:(NSRect)rect;
- (NSSize)convertSizeToBacking:(NSSize)size;
- (NSSize)convertSizeFromBacking:(NSSize)size;
- (NSPoint)convertPointToBacking:(NSPoint)point;
- (NSPoint)convertPointFromBacking:(NSPoint)point;

- (void)addSubview:(NSView *)view;
- (void)removeFromSuperview;
- (void)setNeedsDisplay:(BOOL)flag;
- (void)setNeedsDisplayInRect:(NSRect)rect;
- (void)drawRect:(NSRect)dirtyRect;             // override point
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view;
- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view;

// Non-nil only for views that adopt NSTextInputClient (Chromium's view does).
@property (nonatomic, readonly, strong) NSTextInputContext *inputContext;

// Tracking areas decide which views get mouseEntered:/mouseExited:/mouseMoved:.
@property (nonatomic, readonly, copy) NSArray<NSTrackingArea *> *trackingAreas;
- (void)addTrackingArea:(NSTrackingArea *)area;
- (void)removeTrackingArea:(NSTrackingArea *)area;
- (void)updateTrackingAreas;

// Escape hatch: the backing UIView, so Metal layers and CEF's compositor can attach.
#if __has_include(<UIKit/UIKit.h>)
@property (nonatomic, readonly) UIView *backingView;
// Whether an OpenGL context draws this view at the screen's resolution or in points.
@property (nonatomic, assign) BOOL wantsBestResolutionOpenGLSurface;
#endif
@end
