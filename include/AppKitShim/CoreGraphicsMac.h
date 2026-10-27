// The macOS-only part of CoreGraphics that the client uses: displays, display modes and the
// hardware cursor. iOS CoreGraphics has none of it (no CGDirectDisplay.h), so the shim
// defines it here, answering from UIScreen. Display IDs are 1 for the device's own screen
// and 2, 3... for external screens, in UIScreen order.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@protocol MTLDevice;

typedef uint32_t CGDirectDisplayID;
typedef uint32_t CGDisplayCount;
typedef uint32_t CGDisplayChangeSummaryFlags;
typedef struct CGDisplayMode *CGDisplayModeRef;

#define kCGNullDirectDisplay ((CGDirectDisplayID)0)

enum {
  kCGDisplayBeginConfigurationFlag = 1 << 0,
  kCGDisplayMovedFlag              = 1 << 1,
  kCGDisplaySetMainFlag            = 1 << 2,
  kCGDisplaySetModeFlag            = 1 << 3,
  kCGDisplayAddFlag                = 1 << 4,
  kCGDisplayRemoveFlag             = 1 << 5,
  kCGDisplayEnabledFlag            = 1 << 8,
  kCGDisplayDisabledFlag           = 1 << 9,
};

typedef void (*CGDisplayReconfigurationCallBack)(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo);

CG_EXTERN CGDirectDisplayID CGMainDisplayID(void);
CG_EXTERN CGError CGGetActiveDisplayList(uint32_t maxDisplays, CGDirectDisplayID *activeDisplays, uint32_t *displayCount);
CG_EXTERN CGError CGGetOnlineDisplayList(uint32_t maxDisplays, CGDirectDisplayID *onlineDisplays, uint32_t *displayCount);
CG_EXTERN CGError CGGetDisplaysWithPoint(CGPoint point, uint32_t maxDisplays, CGDirectDisplayID *displays, uint32_t *matchingDisplayCount);
CG_EXTERN CGError CGGetDisplaysWithRect(CGRect rect, uint32_t maxDisplays, CGDirectDisplayID *displays, uint32_t *matchingDisplayCount);

CG_EXTERN CGRect CGDisplayBounds(CGDirectDisplayID display);
CG_EXTERN size_t CGDisplayPixelsWide(CGDirectDisplayID display);
CG_EXTERN size_t CGDisplayPixelsHigh(CGDirectDisplayID display);
CG_EXTERN size_t CGDisplayBitsPerPixel(CGDirectDisplayID display);
CG_EXTERN CGSize CGDisplayScreenSize(CGDirectDisplayID display);
CG_EXTERN double CGDisplayRotation(CGDirectDisplayID display);
CG_EXTERN boolean_t CGDisplayIsMain(CGDirectDisplayID display);
CG_EXTERN boolean_t CGDisplayIsBuiltin(CGDirectDisplayID display);
CG_EXTERN boolean_t CGDisplayIsCaptured(CGDirectDisplayID display);
CG_EXTERN boolean_t CGDisplayUsesForceToGray(void);
CG_EXTERN CGDirectDisplayID CGDisplayMirrorsDisplay(CGDirectDisplayID display);
CG_EXTERN CGColorSpaceRef CGDisplayCopyColorSpace(CGDirectDisplayID display) CF_RETURNS_RETAINED;
CG_EXTERN id<MTLDevice> CGDirectDisplayCopyCurrentMetalDevice(CGDirectDisplayID display) NS_RETURNS_RETAINED;

CG_EXTERN CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID display) CF_RETURNS_RETAINED;
CG_EXTERN CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID display, CFDictionaryRef options) CF_RETURNS_RETAINED;
CG_EXTERN size_t CGDisplayModeGetWidth(CGDisplayModeRef mode);
CG_EXTERN size_t CGDisplayModeGetHeight(CGDisplayModeRef mode);
CG_EXTERN size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef mode);
CG_EXTERN size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef mode);
CG_EXTERN double CGDisplayModeGetRefreshRate(CGDisplayModeRef mode);
CG_EXTERN uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef mode);
CG_EXTERN bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef mode);
CG_EXTERN CFStringRef CGDisplayModeCopyPixelEncoding(CGDisplayModeRef mode) CF_RETURNS_RETAINED;
CG_EXTERN CGDisplayModeRef CGDisplayModeRetain(CGDisplayModeRef mode);
CG_EXTERN void CGDisplayModeRelease(CGDisplayModeRef mode);

CG_EXTERN CGError CGDisplayRegisterReconfigurationCallback(CGDisplayReconfigurationCallBack callback, void *userInfo);
CG_EXTERN CGError CGDisplayRemoveReconfigurationCallback(CGDisplayReconfigurationCallBack callback, void *userInfo);

// The hardware cursor: iOS has none, so these succeed without effect (warping updates the
// position the shim reports from +[NSEvent mouseLocation]).
CG_EXTERN CGError CGDisplayHideCursor(CGDirectDisplayID display);
CG_EXTERN CGError CGDisplayShowCursor(CGDirectDisplayID display);
CG_EXTERN boolean_t CGCursorIsVisible(void);
CG_EXTERN CGError CGWarpMouseCursorPosition(CGPoint newCursorPosition);
CG_EXTERN CGError CGDisplayMoveCursorToPoint(CGDirectDisplayID display, CGPoint point);
CG_EXTERN CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected);

// Screen recording permission. iOS apps can't capture the screen this way, so: denied.
CG_EXTERN bool CGPreflightScreenCaptureAccess(void);
CG_EXTERN bool CGRequestScreenCaptureAccess(void);
