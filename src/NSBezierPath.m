#import "AKShimPrivate.h"
#import "AppKitShim/NSGraphics.h"

// Backed by a mutable CGPath. Drawing uses the current graphics context.
@implementation NSBezierPath {
  CGMutablePathRef _path;
}

- (instancetype)init {
  if ((self = [super init])) {
    _path = CGPathCreateMutable();
    _lineWidth = 1.0;
    _windingRule = NSWindingRuleNonZero;
  }
  return self;
}

- (void)dealloc { CGPathRelease(_path); }

- (id)copyWithZone:(NSZone *)zone {
  NSBezierPath *copy = [[self.class allocWithZone:zone] init];
  CGPathRelease(copy->_path);
  copy->_path = CGPathCreateMutableCopy(_path);
  copy->_lineWidth = _lineWidth;
  copy->_lineCapStyle = _lineCapStyle;
  copy->_lineJoinStyle = _lineJoinStyle;
  copy->_windingRule = _windingRule;
  return copy;
}

+ (NSBezierPath *)bezierPath { return [NSBezierPath new]; }
+ (NSBezierPath *)bezierPathWithRect:(NSRect)rect { NSBezierPath *p = [NSBezierPath new]; [p appendBezierPathWithRect:rect]; return p; }
+ (NSBezierPath *)bezierPathWithOvalInRect:(NSRect)rect { NSBezierPath *p = [NSBezierPath new]; [p appendBezierPathWithOvalInRect:rect]; return p; }
+ (NSBezierPath *)bezierPathWithRoundedRect:(NSRect)rect xRadius:(CGFloat)xr yRadius:(CGFloat)yr {
  NSBezierPath *p = [NSBezierPath new];
  CGPathRef rounded = CGPathCreateWithRoundedRect(rect, xr, yr, NULL);
  CGPathAddPath(p->_path, NULL, rounded);
  CGPathRelease(rounded);
  return p;
}

+ (void)fillRect:(NSRect)rect {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (ctx) CGContextFillRect(ctx, rect);
}
+ (void)strokeRect:(NSRect)rect {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (ctx) CGContextStrokeRect(ctx, rect);
}

- (CGPathRef)CGPath { return _path; }
- (BOOL)isEmpty { return CGPathIsEmpty(_path); }
- (NSRect)bounds { return CGPathGetBoundingBox(_path); }
- (NSPoint)currentPoint { return CGPathGetCurrentPoint(_path); }

- (void)moveToPoint:(NSPoint)p { CGPathMoveToPoint(_path, NULL, p.x, p.y); }
- (void)lineToPoint:(NSPoint)p { CGPathAddLineToPoint(_path, NULL, p.x, p.y); }
- (void)curveToPoint:(NSPoint)end controlPoint1:(NSPoint)c1 controlPoint2:(NSPoint)c2 {
  CGPathAddCurveToPoint(_path, NULL, c1.x, c1.y, c2.x, c2.y, end.x, end.y);
}
- (void)closePath { CGPathCloseSubpath(_path); }
- (void)removeAllPoints { CGPathRelease(_path); _path = CGPathCreateMutable(); }
- (void)appendBezierPathWithRect:(NSRect)rect { CGPathAddRect(_path, NULL, rect); }
- (void)appendBezierPathWithOvalInRect:(NSRect)rect { CGPathAddEllipseInRect(_path, NULL, rect); }

- (void)_applyStroke:(CGContextRef)ctx {
  CGContextSetLineWidth(ctx, _lineWidth);
  CGContextSetLineCap(ctx, (CGLineCap)_lineCapStyle);
  CGContextSetLineJoin(ctx, (CGLineJoin)_lineJoinStyle);
}

- (void)fill {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (!ctx) return;
  CGContextAddPath(ctx, _path);
  if (_windingRule == NSWindingRuleEvenOdd) CGContextEOFillPath(ctx); else CGContextFillPath(ctx);
}

- (void)stroke {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (!ctx) return;
  [self _applyStroke:ctx];
  CGContextAddPath(ctx, _path);
  CGContextStrokePath(ctx);
}

- (void)addClip {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (!ctx) return;
  CGContextAddPath(ctx, _path);
  if (_windingRule == NSWindingRuleEvenOdd) CGContextEOClip(ctx); else CGContextClip(ctx);
}
- (void)setClip { [self addClip]; }

- (BOOL)containsPoint:(NSPoint)point {
  bool eo = _windingRule == NSWindingRuleEvenOdd;
  return CGPathContainsPoint(_path, NULL, point, eo);
}

@end
