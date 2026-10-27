// NSView — backed by a UIView. The one real subtlety is the coordinate system:
// AppKit views are bottom-left origin unless `flipped`, UIKit is top-left. This shim
// keeps a flag and converts in the geometry accessors so callers see AppKit semantics.
#import "NSResponder.h"
#import "NSGeometry.h"

@class NSWindow;
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

@property (nonatomic, assign) NSRect frame;
@property (nonatomic, assign) NSRect bounds;
@property (nonatomic, readonly, getter=isFlipped) BOOL flipped;
@property (nonatomic, assign) BOOL wantsLayer;
@property (nonatomic, assign) BOOL hidden;
@property (nonatomic, assign) NSAutoresizingMaskOptions autoresizingMask;

@property (nonatomic, readonly, weak) NSView *superview;
@property (nonatomic, readonly, copy) NSArray<NSView *> *subviews;
@property (nonatomic, readonly, weak) NSWindow *window;

- (void)addSubview:(NSView *)view;
- (void)removeFromSuperview;
- (void)setNeedsDisplay:(BOOL)flag;
- (void)setNeedsDisplayInRect:(NSRect)rect;
- (void)drawRect:(NSRect)dirtyRect;             // override point
- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view;
- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view;

// Escape hatch: the backing UIView, so Metal layers and CEF's compositor can attach.
#if __has_include(<UIKit/UIKit.h>)
@property (nonatomic, readonly) UIView *backingView;
#endif
@end
