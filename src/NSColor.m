#import "AppKitShim/NSColor.h"
#import "AKShimPrivate.h"
#import "AppKitShim/NSGraphics.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// AppKit's named system colors, each mapped to the iOS semantic color that plays the same
// role (both adapt to light/dark appearance). Chromium reads these to build its native theme
// — by class method (+controlAccentColor) and through +colorWithCatalogName:@"System"
// colorName:. Names AppKit has but this table lacks come back nil, which callers handle.
static NSDictionary<NSString *, UIColor *> *AKSystemColors(void) {
  static NSDictionary *colors;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    colors = @{
      @"labelColor": UIColor.labelColor,
      @"secondaryLabelColor": UIColor.secondaryLabelColor,
      @"tertiaryLabelColor": UIColor.tertiaryLabelColor,
      @"quaternaryLabelColor": UIColor.quaternaryLabelColor,
      @"textColor": UIColor.labelColor,
      @"placeholderTextColor": UIColor.placeholderTextColor,
      @"selectedTextColor": UIColor.labelColor,
      @"textBackgroundColor": UIColor.systemBackgroundColor,
      @"selectedTextBackgroundColor": [UIColor.systemBlueColor colorWithAlphaComponent:0.3],
      @"keyboardFocusIndicatorColor": [UIColor.systemBlueColor colorWithAlphaComponent:0.5],
      @"unemphasizedSelectedTextColor": UIColor.labelColor,
      @"unemphasizedSelectedTextBackgroundColor": UIColor.systemGray5Color,
      @"linkColor": UIColor.linkColor,
      @"separatorColor": UIColor.separatorColor,
      @"selectedContentBackgroundColor": UIColor.systemBlueColor,
      @"unemphasizedSelectedContentBackgroundColor": UIColor.systemGray5Color,
      @"selectedMenuItemTextColor": UIColor.whiteColor,
      @"gridColor": UIColor.separatorColor,
      @"headerTextColor": UIColor.labelColor,
      @"alternatingContentBackgroundColor": UIColor.secondarySystemBackgroundColor,
      @"controlAccentColor": UIColor.tintColor,
      @"controlColor": UIColor.secondarySystemBackgroundColor,
      @"controlBackgroundColor": UIColor.systemBackgroundColor,
      @"controlTextColor": UIColor.labelColor,
      @"disabledControlTextColor": UIColor.tertiaryLabelColor,
      @"selectedControlColor": [UIColor.systemBlueColor colorWithAlphaComponent:0.3],
      @"selectedControlTextColor": UIColor.labelColor,
      @"alternateSelectedControlColor": UIColor.systemBlueColor,
      @"alternateSelectedControlTextColor": UIColor.whiteColor,
      @"scrubberTexturedBackgroundColor": UIColor.secondarySystemBackgroundColor,
      @"windowBackgroundColor": UIColor.systemBackgroundColor,
      @"windowFrameTextColor": UIColor.labelColor,
      @"windowFrameColor": UIColor.separatorColor,
      @"underPageBackgroundColor": UIColor.secondarySystemBackgroundColor,
      @"findHighlightColor": UIColor.systemYellowColor,
      @"highlightColor": UIColor.whiteColor,
      @"shadowColor": UIColor.blackColor,
      @"systemRedColor": UIColor.systemRedColor,
      @"systemGreenColor": UIColor.systemGreenColor,
      @"systemBlueColor": UIColor.systemBlueColor,
      @"systemOrangeColor": UIColor.systemOrangeColor,
      @"systemYellowColor": UIColor.systemYellowColor,
      @"systemBrownColor": UIColor.systemBrownColor,
      @"systemPinkColor": UIColor.systemPinkColor,
      @"systemPurpleColor": UIColor.systemPurpleColor,
      @"systemGrayColor": UIColor.systemGrayColor,
      @"systemTealColor": UIColor.systemTealColor,
      @"systemIndigoColor": UIColor.systemIndigoColor,
      @"systemMintColor": UIColor.systemMintColor,
      @"systemCyanColor": UIColor.systemCyanColor,
      @"systemFillColor": UIColor.systemFillColor,
      @"secondarySystemFillColor": UIColor.secondarySystemFillColor,
      @"tertiarySystemFillColor": UIColor.tertiarySystemFillColor,
      @"quaternarySystemFillColor": UIColor.quaternarySystemFillColor,
      @"cyanColor": UIColor.cyanColor,
      @"magentaColor": UIColor.magentaColor,
      @"yellowColor": UIColor.yellowColor,
      @"orangeColor": UIColor.orangeColor,
      @"purpleColor": UIColor.purpleColor,
      @"brownColor": UIColor.brownColor,
      @"darkGrayColor": UIColor.darkGrayColor,
      @"lightGrayColor": UIColor.lightGrayColor,
    };
  });
  return colors;
}

@implementation NSColor {
  UIColor *_color;
}

- (instancetype)initWithUIColor:(UIColor *)c { if ((self = [super init])) _color = c; return self; }
+ (NSColor *)ak_with:(UIColor *)c { return c ? [[NSColor alloc] initWithUIColor:c] : nil; }

+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [self ak_with:[UIColor colorWithRed:r green:g blue:b alpha:a]];
}
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [self colorWithRed:r green:g blue:b alpha:a];
}
+ (NSColor *)colorWithSRGBRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [self colorWithRed:r green:g blue:b alpha:a];
}
+ (NSColor *)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [self colorWithRed:r green:g blue:b alpha:a];
}
+ (NSColor *)colorWithDisplayP3Red:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
  return [self ak_with:[UIColor colorWithDisplayP3Red:r green:g blue:b alpha:a]];
}
+ (NSColor *)colorWithWhite:(CGFloat)w alpha:(CGFloat)a { return [self ak_with:[UIColor colorWithWhite:w alpha:a]]; }
+ (NSColor *)colorWithCalibratedWhite:(CGFloat)w alpha:(CGFloat)a { return [self colorWithWhite:w alpha:a]; }
+ (NSColor *)colorWithDeviceWhite:(CGFloat)w alpha:(CGFloat)a { return [self colorWithWhite:w alpha:a]; }
+ (NSColor *)colorWithGenericGamma22White:(CGFloat)w alpha:(CGFloat)a { return [self colorWithWhite:w alpha:a]; }
+ (NSColor *)colorWithHue:(CGFloat)h saturation:(CGFloat)s brightness:(CGFloat)b alpha:(CGFloat)a {
  return [self ak_with:[UIColor colorWithHue:h saturation:s brightness:b alpha:a]];
}
+ (NSColor *)colorWithCGColor:(CGColorRef)cg { return cg ? [self ak_with:[UIColor colorWithCGColor:cg]] : nil; }
+ (NSColor *)colorWithCatalogName:(NSString *)catalog colorName:(NSString *)name {
  return [self ak_with:AKSystemColors()[name]];
}

+ (NSColor *)clearColor { return [self ak_with:UIColor.clearColor]; }
+ (NSColor *)blackColor { return [self ak_with:UIColor.blackColor]; }
+ (NSColor *)whiteColor { return [self ak_with:UIColor.whiteColor]; }
+ (NSColor *)grayColor  { return [self ak_with:UIColor.grayColor]; }
+ (NSColor *)redColor   { return [self ak_with:UIColor.redColor]; }
+ (NSColor *)greenColor { return [self ak_with:UIColor.greenColor]; }
+ (NSColor *)blueColor  { return [self ak_with:UIColor.blueColor]; }
+ (NSColor *)windowBackgroundColor { return [self ak_with:AKSystemColors()[@"windowBackgroundColor"]]; }
+ (NSColor *)textColor { return [self ak_with:AKSystemColors()[@"textColor"]]; }
+ (NSColor *)controlColor { return [self ak_with:AKSystemColors()[@"controlColor"]]; }

// Every other named system color (+controlAccentColor, +labelColor, ...) is added on first
// use from the table, so this class answers the same names AppKit does.
+ (BOOL)resolveClassMethod:(SEL)sel {
  NSString *name = NSStringFromSelector(sel);
  UIColor *ui = AKSystemColors()[name];
  if (ui) {
    IMP imp = imp_implementationWithBlock(^NSColor *(id cls) { return [NSColor ak_with:ui]; });
    class_addMethod(object_getClass(self), sel, imp, "@@:");
    return YES;
  }
  return [super resolveClassMethod:sel];
}

+ (NSInteger)currentControlTint { return 1; }  // NSBlueControlTint

- (CGColorRef)CGColor { return _color.CGColor; }

#pragma mark Components (float returns: implemented, not left to the fallback)

// sRGB components, as AppKit gives after converting to an RGB space. A color with no RGB
// form (a pattern) reports black, so callers never read garbage.
- (void)getRed:(CGFloat *)r green:(CGFloat *)g blue:(CGFloat *)b alpha:(CGFloat *)a {
  CGFloat rr = 0, gg = 0, bb = 0, aa = 1;
  if (![_color getRed:&rr green:&gg blue:&bb alpha:&aa]) {
    CGFloat w = 0;
    if ([_color getWhite:&w alpha:&aa]) rr = gg = bb = w;
  }
  if (r) *r = rr;
  if (g) *g = gg;
  if (b) *b = bb;
  if (a) *a = aa;
}
- (CGFloat)redComponent   { CGFloat v; [self getRed:&v green:NULL blue:NULL alpha:NULL]; return v; }
- (CGFloat)greenComponent { CGFloat v; [self getRed:NULL green:&v blue:NULL alpha:NULL]; return v; }
- (CGFloat)blueComponent  { CGFloat v; [self getRed:NULL green:NULL blue:&v alpha:NULL]; return v; }
- (CGFloat)alphaComponent { CGFloat v; [self getRed:NULL green:NULL blue:NULL alpha:&v]; return v; }
- (void)getWhite:(CGFloat *)w alpha:(CGFloat *)a {
  CGFloat r, g, b, aa;
  [self getRed:&r green:&g blue:&b alpha:&aa];
  if (w) *w = 0.299 * r + 0.587 * g + 0.114 * b;
  if (a) *a = aa;
}
- (CGFloat)whiteComponent { CGFloat w; [self getWhite:&w alpha:NULL]; return w; }
- (void)getHue:(CGFloat *)h saturation:(CGFloat *)s brightness:(CGFloat *)b alpha:(CGFloat *)a {
  CGFloat hh = 0, ss = 0, bb = 0, aa = 1;
  [_color getHue:&hh saturation:&ss brightness:&bb alpha:&aa];
  if (h) *h = hh;
  if (s) *s = ss;
  if (b) *b = bb;
  if (a) *a = aa;
}
- (CGFloat)hueComponent        { CGFloat v; [self getHue:&v saturation:NULL brightness:NULL alpha:NULL]; return v; }
- (CGFloat)saturationComponent { CGFloat v; [self getHue:NULL saturation:&v brightness:NULL alpha:NULL]; return v; }
- (CGFloat)brightnessComponent { CGFloat v; [self getHue:NULL saturation:NULL brightness:&v alpha:NULL]; return v; }
- (NSInteger)numberOfComponents { return 4; }
- (void)getComponents:(CGFloat *)components {
  if (components) [self getRed:&components[0] green:&components[1] blue:&components[2] alpha:&components[3]];
}

#pragma mark Color spaces

// Every shim color is already a concrete RGB color (dynamic system colors resolve against
// the current appearance), so converting returns an RGB copy rather than nil.
- (NSColor *)ak_resolvedRGB {
  CGFloat r, g, b, a;
  [self getRed:&r green:&g blue:&b alpha:&a];
  return [NSColor colorWithRed:r green:g blue:b alpha:a];
}
- (NSColor *)colorUsingColorSpace:(NSColorSpace *)space { return [self ak_resolvedRGB]; }
- (NSColor *)colorUsingColorSpaceName:(NSString *)name { return [self ak_resolvedRGB]; }
- (NSColor *)colorUsingType:(NSInteger)type { return [self ak_resolvedRGB]; }
- (NSColorSpace *)colorSpace { return NSColorSpace.sRGBColorSpace; }
- (NSString *)colorSpaceName { return @"NSCalibratedRGBColorSpace"; }
- (NSInteger)type { return 0; }  // NSColorTypeComponentBased

#pragma mark Derived colors

- (NSColor *)colorWithAlphaComponent:(CGFloat)alpha { return [NSColor ak_with:[_color colorWithAlphaComponent:alpha]]; }
- (NSColor *)blendedColorWithFraction:(CGFloat)fraction ofColor:(NSColor *)other {
  CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
  [self getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
  [other getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
  CGFloat f = MAX(0, MIN(1, fraction));
  return [NSColor colorWithRed:r1 + (r2 - r1) * f green:g1 + (g2 - g1) * f blue:b1 + (b2 - b1) * f alpha:a1 + (a2 - a1) * f];
}
- (NSColor *)highlightWithLevel:(CGFloat)level { return [self blendedColorWithFraction:level ofColor:NSColor.whiteColor]; }
- (NSColor *)shadowWithLevel:(CGFloat)level { return [self blendedColorWithFraction:level ofColor:NSColor.blackColor]; }

- (BOOL)isEqual:(id)other {
  return [other isKindOfClass:NSColor.class] && [_color isEqual:((NSColor *)other)->_color];
}
- (NSUInteger)hash { return _color.hash; }
- (NSString *)description { return [NSString stringWithFormat:@"NSColor(%@)", _color]; }

#pragma mark Drawing

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
