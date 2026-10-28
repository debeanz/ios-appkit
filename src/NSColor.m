#import "AppKitShim/NSColor.h"
#import "AKShimPrivate.h"
#import "AppKitShim/NSGraphics.h"
#import <UIKit/UIKit.h>

@implementation NSColor {
  UIColor *_color;
}

- (instancetype)initWithUIColor:(UIColor *)c { if ((self = [super init])) _color = c; return self; }

+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [[NSColor alloc] initWithUIColor:[UIColor colorWithRed:r green:g blue:b alpha:a]];
}
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [self colorWithRed:r green:g blue:b alpha:a];
}

+ (NSColor *)clearColor { return [[NSColor alloc] initWithUIColor:UIColor.clearColor]; }
+ (NSColor *)blackColor { return [[NSColor alloc] initWithUIColor:UIColor.blackColor]; }
+ (NSColor *)whiteColor { return [[NSColor alloc] initWithUIColor:UIColor.whiteColor]; }
+ (NSColor *)windowBackgroundColor { return [[NSColor alloc] initWithUIColor:UIColor.systemBackgroundColor]; }
+ (NSColor *)textColor { return [[NSColor alloc] initWithUIColor:UIColor.labelColor]; }
+ (NSColor *)controlColor { return [[NSColor alloc] initWithUIColor:UIColor.secondarySystemBackgroundColor]; }

+ (NSColor *)redColor   { return [[NSColor alloc] initWithUIColor:UIColor.redColor]; }
+ (NSColor *)greenColor { return [[NSColor alloc] initWithUIColor:UIColor.greenColor]; }
+ (NSColor *)blueColor  { return [[NSColor alloc] initWithUIColor:UIColor.blueColor]; }
+ (NSColor *)grayColor  { return [[NSColor alloc] initWithUIColor:UIColor.grayColor]; }

- (CGColorRef)CGColor { return _color.CGColor; }

- (void)set { [self setFill]; [self setStroke]; }
- (void)setFill {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (ctx) CGContextSetFillColorWithColor(ctx, _color.CGColor);
}
- (void)setStroke {
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  if (ctx) CGContextSetStrokeColorWithColor(ctx, _color.CGColor);
}


AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER
@end
