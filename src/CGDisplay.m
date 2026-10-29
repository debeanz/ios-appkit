// macOS display APIs answered from UIScreen. See CoreGraphicsMac.h.
#import "AKShimPrivate.h"
#import <Metal/Metal.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // UIScreen.screens: still the only list of screens

#pragma mark Display IDs

static NSArray<UIScreen *> *AKScreens(void) {
  NSArray *screens = UIScreen.screens;
  return screens.count ? screens : @[ UIScreen.mainScreen ];
}

CGDirectDisplayID AKDisplayIDForScreen(UIScreen *screen) {
  NSUInteger i = [AKScreens() indexOfObjectIdenticalTo:screen];
  return i == NSNotFound ? kCGNullDirectDisplay : (CGDirectDisplayID)(i + 1);
}

UIScreen *AKScreenForDisplayID(CGDirectDisplayID display) {
  NSArray<UIScreen *> *screens = AKScreens();
  return (display >= 1 && display <= screens.count) ? screens[display - 1] : nil;
}

#pragma clang diagnostic pop

static CGError AKListDisplays(BOOL (^match)(CGDirectDisplayID, CGRect), uint32_t max,
                              CGDirectDisplayID *out, uint32_t *count) {
  uint32_t n = 0;
  NSArray<UIScreen *> *screens = AKScreens();
  for (NSUInteger i = 0; i < screens.count; i++) {
    CGDirectDisplayID d = (CGDirectDisplayID)(i + 1);
    if (match && !match(d, CGDisplayBounds(d))) continue;
    if (out && n < max) out[n] = d;
    n++;
  }
  if (count) *count = out ? MIN(n, max) : n;
  return kCGErrorSuccess;
}

CGDirectDisplayID CGMainDisplayID(void) { return 1; }

CGError CGGetActiveDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count) {
  return AKListDisplays(nil, max, displays, count);
}

CGError CGGetOnlineDisplayList(uint32_t max, CGDirectDisplayID *displays, uint32_t *count) {
  return AKListDisplays(nil, max, displays, count);
}

CGError CGGetDisplaysWithPoint(CGPoint point, uint32_t max, CGDirectDisplayID *displays, uint32_t *count) {
  return AKListDisplays(^BOOL(CGDirectDisplayID d, CGRect b) { return CGRectContainsPoint(b, point); },
                        max, displays, count);
}

CGError CGGetDisplaysWithRect(CGRect rect, uint32_t max, CGDirectDisplayID *displays, uint32_t *count) {
  return AKListDisplays(^BOOL(CGDirectDisplayID d, CGRect b) { return CGRectIntersectsRect(b, rect); },
                        max, displays, count);
}

#pragma mark Geometry

// Global display space, in points: the device screen at the origin, external screens laid
// out to its right, as macOS arranges a laptop with monitors.
CGRect CGDisplayBounds(CGDirectDisplayID display) {
  UIScreen *screen = AKScreenForDisplayID(display);
  if (!screen) return CGRectZero;
  CGFloat x = 0;
  for (CGDirectDisplayID d = 1; d < display; d++) x += AKScreenForDisplayID(d).bounds.size.width;
  return (CGRect){{x, 0}, screen.bounds.size};
}

size_t CGDisplayPixelsWide(CGDirectDisplayID display) { return (size_t)CGDisplayBounds(display).size.width; }
size_t CGDisplayPixelsHigh(CGDirectDisplayID display) { return (size_t)CGDisplayBounds(display).size.height; }
size_t CGDisplayBitsPerPixel(CGDirectDisplayID display) { return 32; }

// Physical size in millimetres. iOS doesn't report it; iPhone and iPad screens run close to
// 163 points per inch, which is accurate enough for the DPI estimates callers make with it.
CGSize CGDisplayScreenSize(CGDirectDisplayID display) {
  CGSize points = CGDisplayBounds(display).size;
  const CGFloat mmPerPoint = 25.4 / 163.0;
  return CGSizeMake(points.width * mmPerPoint, points.height * mmPerPoint);
}

double CGDisplayRotation(CGDirectDisplayID display) { return 0; }
boolean_t CGDisplayIsMain(CGDirectDisplayID display) { return display == CGMainDisplayID(); }
boolean_t CGDisplayIsBuiltin(CGDirectDisplayID display) { return display == CGMainDisplayID(); }
boolean_t CGDisplayIsCaptured(CGDirectDisplayID display) { return false; }
boolean_t CGDisplayUsesForceToGray(void) { return false; }
CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID display) { return kCGNullDirectDisplay; }

CGColorSpaceRef CGDisplayCopyColorSpace(CGDirectDisplayID display) {
  UIScreen *screen = AKScreenForDisplayID(display);
  BOOL p3 = screen.traitCollection.displayGamut == UIDisplayGamutP3;
  return CGColorSpaceCreateWithName(p3 ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB);
}

id<MTLDevice> CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID display) {
  return MTLCreateSystemDefaultDevice(); // one GPU on iOS
}

#pragma mark Display modes

// A display mode is an Objective-C object, which makes it a valid CFType: CFRetain,
// CFRelease and CFArray all work on it, as callers expect.
@interface AKDisplayMode : NSObject
@property (nonatomic) size_t width, height, pixelWidth, pixelHeight;
@property (nonatomic) double refreshRate;
@end
@implementation AKDisplayMode
@end

static AKDisplayMode *AKModeForDisplay(CGDirectDisplayID display) {
  UIScreen *screen = AKScreenForDisplayID(display);
  if (!screen) return nil;
  AKDisplayMode *m = [AKDisplayMode new];
  CGSize pts = screen.bounds.size;
  m.width = (size_t)pts.width;
  m.height = (size_t)pts.height;
  m.pixelWidth = (size_t)(pts.width * screen.scale);
  m.pixelHeight = (size_t)(pts.height * screen.scale);
  m.refreshRate = (double)AKDisplayRefreshRate(screen);   // CVDisplayLink.m: as frames go out
  return m;
}

static AKDisplayMode *AKMode(CGDisplayModeRef mode) { return (__bridge AKDisplayMode *)(void *)mode; }

CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID display) {
  AKDisplayMode *m = AKModeForDisplay(display);
  return m ? (CGDisplayModeRef)CFBridgingRetain(m) : NULL;
}

CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID display, CFDictionaryRef options) {
  AKDisplayMode *m = AKModeForDisplay(display); // iOS screens have exactly one mode
  return (CFArrayRef)CFBridgingRetain(m ? @[ m ] : @[]);
}

size_t CGDisplayModeGetWidth(CGDisplayModeRef mode)       { return AKMode(mode).width; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef mode)      { return AKMode(mode).height; }
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef mode)  { return AKMode(mode).pixelWidth; }
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef mode) { return AKMode(mode).pixelHeight; }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef mode) { return AKMode(mode).refreshRate; }
uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef mode)   { return 0; }
bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef mode) { return mode != NULL; }

CFStringRef CGDisplayModeCopyPixelEncoding(CGDisplayModeRef mode) {
  return CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB"); // IO32BitDirectPixels; CFSTR constants are immortal
}

CGDisplayModeRef CGDisplayModeRetain(CGDisplayModeRef mode) { if (mode) CFRetain(mode); return mode; }
void CGDisplayModeRelease(CGDisplayModeRef mode) { if (mode) CFRelease(mode); }

#pragma mark Reconfiguration callbacks

@interface AKReconfigurationCallback : NSObject
@property (nonatomic) CGDisplayReconfigurationCallBack fn;
@property (nonatomic) void *userInfo;
@end
@implementation AKReconfigurationCallback
@end

static NSMutableArray<AKReconfigurationCallback *> *gReconfigCallbacks;

static void AKNotifyReconfiguration(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags) {
  NSArray *callbacks;
  @synchronized (NSApplication.class) { callbacks = [gReconfigCallbacks copy]; }
  // macOS sends a "begin" pass, then the change itself.
  for (AKReconfigurationCallback *cb in callbacks) cb.fn(display, kCGDisplayBeginConfigurationFlag, cb.userInfo);
  for (AKReconfigurationCallback *cb in callbacks) cb.fn(display, flags, cb.userInfo);
  [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
}

// Screens connecting, disconnecting or changing mode are the iOS reconfiguration events.
static void AKObserveScreens(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIScreenDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { AKNotifyReconfiguration(AKDisplayIDForScreen(n.object), kCGDisplayAddFlag | kCGDisplayEnabledFlag); }];
    [nc addObserverForName:UIScreenDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { AKNotifyReconfiguration(kCGNullDirectDisplay, kCGDisplayRemoveFlag | kCGDisplayDisabledFlag); }];
    [nc addObserverForName:UIScreenModeDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *n) { AKNotifyReconfiguration(AKDisplayIDForScreen(n.object), kCGDisplaySetModeFlag); }];
  });
}

CGError CGDisplayRegisterReconfigurationCallback(CGDisplayReconfigurationCallBack callback, void *userInfo) {
  if (!callback) return kCGErrorIllegalArgument;
  AKObserveScreens();
  AKReconfigurationCallback *cb = [AKReconfigurationCallback new];
  cb.fn = callback;
  cb.userInfo = userInfo;
  @synchronized (NSApplication.class) {
    if (!gReconfigCallbacks) gReconfigCallbacks = [NSMutableArray array];
    [gReconfigCallbacks addObject:cb];
  }
  return kCGErrorSuccess;
}

CGError CGDisplayRemoveReconfigurationCallback(CGDisplayReconfigurationCallBack callback, void *userInfo) {
  @synchronized (NSApplication.class) {
    NSIndexSet *gone = [gReconfigCallbacks indexesOfObjectsPassingTest:^BOOL(AKReconfigurationCallback *cb, NSUInteger i, BOOL *stop) {
      return cb.fn == callback && cb.userInfo == userInfo;
    }];
    [gReconfigCallbacks removeObjectsAtIndexes:gone];
  }
  return kCGErrorSuccess;
}

#pragma mark Capture

CGError CGCaptureAllDisplays(void) { return kCGErrorSuccess; }
CGError CGReleaseAllDisplays(void) { return kCGErrorSuccess; }
CGError CGDisplayCapture(CGDirectDisplayID display) { return kCGErrorSuccess; }
CGError CGDisplayRelease(CGDirectDisplayID display) { return kCGErrorSuccess; }
int32_t CGShieldingWindowLevel(void) { return 2147483628; }   // kCGShieldingWindowLevelKey's level on macOS

#pragma mark Gamma

// Identity, at up to 256 entries per channel (a Mac display's table size); *sampleCount says how
// many were filled.
CGError CGGetDisplayTransferByTable(CGDirectDisplayID display, uint32_t capacity, CGGammaValue *red, CGGammaValue *green,
                                    CGGammaValue *blue, uint32_t *sampleCount) {
  uint32_t n = capacity < 256 ? capacity : 256;
  for (uint32_t i = 0; i < n; i++) {
    CGGammaValue v = n > 1 ? (CGGammaValue)i / (CGGammaValue)(n - 1) : 0;
    if (red) red[i] = v;
    if (green) green[i] = v;
    if (blue) blue[i] = v;
  }
  if (sampleCount) *sampleCount = n;
  return kCGErrorSuccess;
}

CGError CGSetDisplayTransferByTable(CGDirectDisplayID display, uint32_t size, const CGGammaValue *red, const CGGammaValue *green,
                                    const CGGammaValue *blue) {
  return kCGErrorSuccess;
}

#pragma mark Cursor

CGError CGDisplayHideCursor(CGDirectDisplayID display) { return kCGErrorSuccess; }
CGError CGDisplayShowCursor(CGDirectDisplayID display) { return kCGErrorSuccess; }
boolean_t CGCursorIsVisible(void) { return false; }

CGError CGWarpMouseCursorPosition(CGPoint p) {
  [NSEvent _setMouseLocation:AKAppKitPointFromQuartz(p)];
  return kCGErrorSuccess;
}

CGError CGDisplayMoveCursorToPoint(CGDirectDisplayID display, CGPoint p) {
  CGRect b = CGDisplayBounds(display);
  return CGWarpMouseCursorPosition(CGPointMake(b.origin.x + p.x, b.origin.y + p.y));
}

CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected) { return kCGErrorSuccess; }

bool CGPreflightScreenCaptureAccess(void) { return false; }
bool CGRequestScreenCaptureAccess(void) { return false; }
