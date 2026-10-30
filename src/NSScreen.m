#import "AKShimPrivate.h"
#import <QuartzCore/QuartzCore.h>

NSNotificationName const NSScreenColorSpaceDidChangeNotification = @"NSScreenColorSpaceDidChangeNotification";

@implementation NSScreen {
  UIScreen *_screen;
}

- (instancetype)initWithUIScreen:(UIScreen *)s { if ((self = [super init])) _screen = s; return self; }

// Same order as CoreGraphics display IDs (1 = this device's screen), so NSScreen.screens[i]
// has NSScreenNumber i + 1.
+ (NSArray<NSScreen *> *)screens {
  NSMutableArray *out = [NSMutableArray array];
  for (CGDirectDisplayID d = 1; AKScreenForDisplayID(d); d++) {
    UIScreen *s = AKScreenForDisplayID(d);
    [out addObject:(s == UIScreen.mainScreen) ? self.mainScreen : [[NSScreen alloc] initWithUIScreen:s]];
  }
  return out;
}

+ (NSScreen *)mainScreen {
  static NSScreen *main;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ main = [[NSScreen alloc] initWithUIScreen:UIScreen.mainScreen]; });
  return main;
}

- (NSRect)frame { return CGDisplayBounds(AKDisplayIDForScreen(_screen)); }

// No menu bar or Dock on iOS; the usable area is the screen minus the safe-area insets
// of the key window, if one exists yet.
- (NSRect)visibleFrame {
  CGRect b = self.frame;
  UIWindow *w = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class]) { w = ((UIWindowScene *)scene).windows.firstObject; break; }
  }
  if (w) b = UIEdgeInsetsInsetRect(b, w.safeAreaInsets);
  return b;
}

// The screen with the most color depth: there's one kind here.
+ (NSScreen *)deepestScreen { return self.mainScreen; }

// Its CoreGraphics display (deviceDescription's NSScreenNumber), and a display link it drives.
- (CGDirectDisplayID)CGDirectDisplayID { return AKDisplayIDForScreen(_screen); }
- (CADisplayLink *)displayLinkWithTarget:(id)target selector:(SEL)selector {
  CADisplayLink *link = [_screen displayLinkWithTarget:target selector:selector];
  return link ?: [CADisplayLink displayLinkWithTarget:target selector:selector];
}

// 1 to a game, as its windows are (NSWindow.m).
- (CGFloat)backingScaleFactor { return AKIsGameThread() ? 1 : _screen.scale; }
- (NSInteger)maximumFramesPerSecond { return AKDisplayRefreshRate(_screen); }   // CVDisplayLink.m
- (NSTimeInterval)minimumRefreshInterval { return 1.0 / MAX(1, self.maximumFramesPerSecond); }
- (NSTimeInterval)maximumRefreshInterval { return self.minimumRefreshInterval; }
- (NSTimeInterval)displayUpdateGranularity { return 0; }   // any interval in that range
- (NSTimeInterval)lastDisplayUpdateTimestamp { return CACurrentMediaTime(); }

// Points <-> pixels at the scale the caller sees (Unity sizes its screen from the frame
// converted, so these must hold: a struct return can't come from the unimplemented fallback).
- (NSRect)convertRectToBacking:(NSRect)r {
  CGFloat s = self.backingScaleFactor;
  return NSMakeRect(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s);
}
- (NSRect)convertRectFromBacking:(NSRect)r {
  CGFloat s = self.backingScaleFactor;
  return NSMakeRect(r.origin.x / s, r.origin.y / s, r.size.width / s, r.size.height / s);
}
- (NSRect)backingAlignedRect:(NSRect)r options:(unsigned long long)options {
  return [self convertRectFromBacking:AKNearestPixelRect([self convertRectToBacking:r])];
}

// A Mac screen without a camera housing: nothing kept clear at the top, no areas beside it. A
// Mac game takes these for a notch and would letterbox the picture below it; here its window
// covers the whole screen (NSWindow.m), as on a Mac without one.
- (NSEdgeInsets)safeAreaInsets { return NSEdgeInsetsMake(0, 0, 0, 0); }
- (NSRect)auxiliaryTopLeftArea { return NSZeroRect; }
- (NSRect)auxiliaryTopRightArea { return NSZeroRect; }

// 8 bits a channel, RGB (NSWindowDepthTwentyfourBitRGB), the only depth listed.
- (int)depth { return 0x208; }
- (const int *)supportedWindowDepths {
  static const int depths[] = { 0x208, 0 };
  return depths;
}

// EDR (HDR) headroom. These return a CGFloat, which the unimplemented-method fallback
// can't fake (it would set the integer, not the floating-point, return register and SDL
// would read garbage), so answer them: 1.0 means standard dynamic range, no extra headroom
// — true for a client treating the display as SDR. iOS exposes the real value as
// UIScreen.currentEDRHeadroom (iOS 16+); use it when present, clamped to at least 1.0.
- (CGFloat)maximumExtendedDynamicRangeColorComponentValue {
  if (@available(iOS 16.0, *)) return MAX(1.0, _screen.currentEDRHeadroom);
  return 1.0;
}
- (CGFloat)maximumPotentialExtendedDynamicRangeColorComponentValue {
  if (@available(iOS 16.0, *)) return MAX(1.0, _screen.potentialEDRHeadroom);
  return 1.0;
}
- (CGFloat)maximumReferenceExtendedDynamicRangeColorComponentValue { return 1.0; }

// The screen's color space: Display P3 on wide-gamut panels (every recent iPhone and iPad),
// sRGB otherwise. Chromium builds its display color profile from this.
- (NSColorSpace *)colorSpace {
  return _screen.traitCollection.displayGamut == UIDisplayGamutP3 ? NSColorSpace.displayP3ColorSpace
                                                                  : NSColorSpace.sRGBColorSpace;
}

- (BOOL)canRepresentDisplayGamut:(NSInteger)displayGamut {
  // NSDisplayGamutSRGB = 1, NSDisplayGamutP3 = 2
  return displayGamut == 1 || (displayGamut == 2 && _screen.traitCollection.displayGamut == UIDisplayGamutP3);
}

- (NSString *)localizedName {
  return _screen == UIScreen.mainScreen ? UIDevice.currentDevice.model : @"External Display";
}

- (NSDictionary<NSString *, id> *)deviceDescription {
  CGFloat dpi = 72.0 * _screen.scale; // AppKit reports 72 dpi per backing-scale step
  return @{
    @"NSScreenNumber": @(AKDisplayIDForScreen(_screen)),
    @"NSDeviceSize": [NSValue valueWithCGSize:self.frame.size],
    @"NSDeviceResolution": [NSValue valueWithCGSize:CGSizeMake(dpi, dpi)],
    @"NSDeviceIsScreen": @"YES",
    @"NSDeviceBitsPerSample": @8,
  };
}

AK_UNIMPLEMENTED_FORWARDER
AK_UNIMPLEMENTED_CLASS_FORWARDER

@end
