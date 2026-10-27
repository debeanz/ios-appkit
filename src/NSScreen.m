#import "AKShimPrivate.h"

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

- (CGFloat)backingScaleFactor { return _screen.scale; }
- (NSInteger)maximumFramesPerSecond { return _screen.maximumFramesPerSecond; }

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
