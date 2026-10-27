#import "AppKitShim/NSColor.h"
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

- (CGColorRef)CGColor { return _color.CGColor; }

@end
