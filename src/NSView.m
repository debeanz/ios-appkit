#import "AppKitShim/NSView.h"
#import "AppKitShim/NSWindow.h"
#import <UIKit/UIKit.h>

// A UIView subclass that calls back into its owning NSView for drawing, so an
// NSView subclass that overrides -drawRect: keeps working.
@interface _AKShimBackingView : UIView
@property (nonatomic, weak) NSView *owner;
@end

@implementation _AKShimBackingView
- (void)drawRect:(CGRect)rect { [self.owner drawRect:rect]; }
@end

@interface NSView ()
@property (nonatomic, strong) _AKShimBackingView *backing;
@property (nonatomic, weak, readwrite) NSView *superview;
@property (nonatomic, strong) NSMutableArray<NSView *> *mutableSubviews;
@property (nonatomic, weak) NSWindow *owningWindow; // set only on a window's content view
@end

@implementation NSView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super init])) {
    _backing = [[_AKShimBackingView alloc] initWithFrame:frame];
    _backing.owner = self;
    _backing.contentMode = UIViewContentModeRedraw;
    _mutableSubviews = [NSMutableArray array];
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

- (void)addSubview:(NSView *)view {
  if (!view) return;
  [view removeFromSuperview];
  view.superview = self;
  [_mutableSubviews addObject:view];
  [_backing addSubview:view.backing];
}

- (void)removeFromSuperview {
  [_backing removeFromSuperview];
  [self.superview.mutableSubviews removeObject:self];
  self.superview = nil;
}

// A content view knows its window directly; every other view asks its superview.
- (NSWindow *)window { return self.owningWindow ?: self.superview.window; }
- (void)_setOwningWindow:(NSWindow *)window { self.owningWindow = window; }

- (void)setNeedsDisplay:(BOOL)flag { if (flag) [_backing setNeedsDisplay]; }
- (void)setNeedsDisplayInRect:(NSRect)rect { [_backing setNeedsDisplayInRect:rect]; }
- (void)drawRect:(NSRect)dirtyRect { /* override point */ }

- (NSPoint)convertPoint:(NSPoint)point fromView:(NSView *)view {
  return [_backing convertPoint:point fromView:view.backing];
}
- (NSPoint)convertPoint:(NSPoint)point toView:(NSView *)view {
  return [_backing convertPoint:point toView:view.backing];
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

@end
