#import "AppKitShim/NSScreen.h"
#import <UIKit/UIKit.h>

@implementation NSScreen {
  UIScreen *_screen;
}

- (instancetype)initWithUIScreen:(UIScreen *)s { if ((self = [super init])) _screen = s; return self; }

+ (NSArray<NSScreen *> *)screens {
  NSMutableArray *out = [NSMutableArray array];
  for (UIScreen *s in UIScreen.screens) [out addObject:[[NSScreen alloc] initWithUIScreen:s]];
  return out;
}

+ (NSScreen *)mainScreen {
  static NSScreen *main;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ main = [[NSScreen alloc] initWithUIScreen:UIScreen.mainScreen]; });
  return main;
}

- (NSRect)frame { return _screen.bounds; }

// No menu bar or Dock on iOS; the usable area is the screen minus the safe-area insets
// of the key window, if one exists yet.
- (NSRect)visibleFrame {
  CGRect b = _screen.bounds;
  UIWindow *w = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class]) { w = ((UIWindowScene *)scene).windows.firstObject; break; }
  }
  if (w) {
    UIEdgeInsets in = w.safeAreaInsets;
    b = UIEdgeInsetsInsetRect(b, in);
  }
  return b;
}

- (CGFloat)backingScaleFactor { return _screen.scale; }

@end
