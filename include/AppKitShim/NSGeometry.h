// NSGeometry — AppKit's geometry types. On 64-bit macOS these are literally the
// CoreGraphics types, so the shim does the same and iOS code and Mac code agree.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#ifndef APPKITSHIM_NSGEOMETRY_H
#define APPKITSHIM_NSGEOMETRY_H

// UIKit ships private classes with some AppKit names (NSColor, for one). Objective-C class
// names are process-global, so a shim class with the same name would collide with it.
// This registers the class with the runtime under a distinct name. It renames the class
// symbol too (_OBJC_CLASS_$_AKShim_NSColor), so the Makefile's CLASS_ALIASES also exports it
// as _OBJC_CLASS_$_NSColor, the name the client's binaries bind to; without that they bind to
// UIKit's private class. The smoke test fails on any remaining collision, so it tells us
// which classes need this.
#define AK_SHIM_RUNTIME_NAME(name) __attribute__((objc_runtime_name("AKShim_" #name)))

typedef CGPoint NSPoint;
typedef CGSize  NSSize;
typedef CGRect  NSRect;
typedef NSInteger NSRectEdge;

typedef struct NSEdgeInsets { CGFloat top, left, bottom, right; } NSEdgeInsets;

#define NSZeroPoint ((NSPoint){0, 0})
#define NSZeroSize  ((NSSize){0, 0})
#define NSZeroRect  ((NSRect){{0, 0}, {0, 0}})

NS_INLINE NSPoint NSMakePoint(CGFloat x, CGFloat y) { return (NSPoint){x, y}; }
NS_INLINE NSSize  NSMakeSize(CGFloat w, CGFloat h)  { return (NSSize){w, h}; }
NS_INLINE NSRect  NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return (NSRect){{x, y}, {w, h}}; }

NS_INLINE CGFloat NSMinX(NSRect r) { return CGRectGetMinX(r); }
NS_INLINE CGFloat NSMinY(NSRect r) { return CGRectGetMinY(r); }
NS_INLINE CGFloat NSMaxX(NSRect r) { return CGRectGetMaxX(r); }
NS_INLINE CGFloat NSMaxY(NSRect r) { return CGRectGetMaxY(r); }
NS_INLINE CGFloat NSMidX(NSRect r) { return CGRectGetMidX(r); }
NS_INLINE CGFloat NSMidY(NSRect r) { return CGRectGetMidY(r); }
NS_INLINE CGFloat NSWidth(NSRect r)  { return r.size.width; }
NS_INLINE CGFloat NSHeight(NSRect r) { return r.size.height; }

NS_INLINE BOOL NSEqualPoints(NSPoint a, NSPoint b) { return CGPointEqualToPoint(a, b); }
NS_INLINE BOOL NSEqualSizes(NSSize a, NSSize b)     { return CGSizeEqualToSize(a, b); }
NS_INLINE BOOL NSEqualRects(NSRect a, NSRect b)     { return CGRectEqualToRect(a, b); }
NS_INLINE BOOL NSPointInRect(NSPoint p, NSRect r)   { return CGRectContainsPoint(r, p); }
NS_INLINE BOOL NSIsEmptyRect(NSRect r)              { return CGRectIsEmpty(r); }
NS_INLINE NSRect NSInsetRect(NSRect r, CGFloat dx, CGFloat dy) { return CGRectInset(r, dx, dy); }
NS_INLINE NSRect NSIntersectionRect(NSRect a, NSRect b)        { return CGRectIntersection(a, b); }
NS_INLINE NSRect NSUnionRect(NSRect a, NSRect b)               { return CGRectUnion(a, b); }
NS_INLINE BOOL NSContainsRect(NSRect a, NSRect b)             { return CGRectContainsRect(a, b); }
NS_INLINE BOOL NSIntersectsRect(NSRect a, NSRect b)          { return CGRectIntersectsRect(a, b); }

NS_INLINE NSEdgeInsets NSEdgeInsetsMake(CGFloat t, CGFloat l, CGFloat b, CGFloat r) {
  return (NSEdgeInsets){t, l, b, r};
}

#endif
