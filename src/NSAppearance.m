#import "AKShimPrivate.h"
#import "AppKitShim/NSGraphics.h"
#import "AppKitShim/AppKitConstants.h"

static NSAppearance *gCurrentAppearance;

@implementation NSAppearance

- (instancetype)initWithAppearanceNamed:(NSAppearanceName)name bundle:(NSBundle *)bundle {
  if ((self = [super init])) _name = [name copy];
  return self;
}

+ (NSAppearance *)appearanceNamed:(NSAppearanceName)name {
  return [[NSAppearance alloc] initWithAppearanceNamed:name bundle:nil];
}

// Follows the key window's trait collection (the device's Light/Dark setting) unless the
// client has set one explicitly.
+ (NSAppearance *)currentAppearance {
  if (gCurrentAppearance) return gCurrentAppearance;
  BOOL dark = UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
  return [self appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
}

+ (void)setCurrentAppearance:(NSAppearance *)appearance { gCurrentAppearance = appearance; }

- (BOOL)_isDark { return [_name containsString:@"Dark"]; }

- (NSAppearanceName)bestMatchFromAppearancesWithNames:(NSArray<NSAppearanceName> *)names {
  NSAppearanceName dark = nil, light = nil;
  for (NSAppearanceName n in names) {
    if ([n containsString:@"Dark"]) dark = dark ?: n;
    else light = light ?: n;
  }
  NSAppearanceName preferred = self._isDark ? (dark ?: light) : (light ?: dark);
  return preferred ?: names.firstObject;
}

- (void)performAsCurrentDrawingAppearance:(void (^)(void))block {
  NSAppearance *previous = gCurrentAppearance;
  gCurrentAppearance = self;
  if (block) block();
  gCurrentAppearance = previous;
}

@end
