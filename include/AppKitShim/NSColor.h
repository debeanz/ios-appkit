// NSColor — thin wrapper over UIColor. Steam uses a handful of system colors plus
// RGBA construction; most AppKit color imports are the named-color globals below.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "NSGeometry.h"

// UIKitCore has a private NSColor; see AK_SHIM_RUNTIME_NAME.
AK_SHIM_RUNTIME_NAME(NSColor)
@interface NSColor : NSObject
+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)clearColor;
+ (NSColor *)blackColor;
+ (NSColor *)whiteColor;
+ (NSColor *)windowBackgroundColor;
+ (NSColor *)textColor;
+ (NSColor *)controlColor;
@property (nonatomic, readonly) CGColorRef CGColor;
@end
