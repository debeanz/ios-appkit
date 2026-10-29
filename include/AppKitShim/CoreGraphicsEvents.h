// The rest of macOS-only CoreGraphics: Quartz events, event sources, window lists and
// levels, display streams and fades, and the private window-server (CGS) calls Chromium makes.
//
// Scope on iOS: an app sees and drives only itself. CGEvents are real objects and
// CGEventPost delivers them into this app; window lists describe this app's own windows.
// Capturing the screen (display streams, window images) and system-wide event taps are not
// available to iOS apps, and report so through the API's own failure values.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <MacTypes.h>
#import "CoreGraphicsMac.h"

#pragma mark Quartz events

typedef struct __CGEvent *CGEventRef;
typedef struct __CGEventSource *CGEventSourceRef;
typedef struct __CGEventTapProxy *CGEventTapProxy;
typedef uint32_t CGEventType;
typedef uint64_t CGEventFlags;
typedef uint32_t CGEventField;
typedef uint64_t CGEventMask;
typedef uint16_t CGKeyCode;
typedef uint32_t CGMouseButton;
typedef uint32_t CGEventTapLocation;
typedef uint32_t CGEventTapPlacement;
typedef uint32_t CGEventTapOptions;
typedef int32_t CGEventSourceStateID;

// Event types share AppKit's NSEventType numbering.
enum {
  kCGEventNull = 0, kCGEventLeftMouseDown = 1, kCGEventLeftMouseUp = 2, kCGEventRightMouseDown = 3,
  kCGEventRightMouseUp = 4, kCGEventMouseMoved = 5, kCGEventLeftMouseDragged = 6, kCGEventRightMouseDragged = 7,
  kCGEventKeyDown = 10, kCGEventKeyUp = 11, kCGEventFlagsChanged = 12, kCGEventScrollWheel = 22,
  kCGEventOtherMouseDown = 25, kCGEventOtherMouseUp = 26, kCGEventOtherMouseDragged = 27,
};
#define kCGAnyInputEventType ((CGEventType)(~0))

enum { kCGMouseButtonLeft = 0, kCGMouseButtonRight = 1, kCGMouseButtonCenter = 2 };

enum {
  kCGEventSourceStatePrivate = -1, kCGEventSourceStateCombinedSessionState = 0, kCGEventSourceStateHIDSystemState = 1,
};

// Event fields (the subset the client reads).
enum {
  kCGMouseEventNumber = 0, kCGMouseEventClickState = 1, kCGMouseEventPressure = 2, kCGMouseEventButtonNumber = 3,
  kCGMouseEventDeltaX = 4, kCGMouseEventDeltaY = 5, kCGKeyboardEventAutorepeat = 8, kCGKeyboardEventKeycode = 9,
  kCGEventSourceUserData = 42,
};

enum { kCGHIDEventTap = 0, kCGSessionEventTap = 1, kCGAnnotatedSessionEventTap = 2 };

typedef CGEventRef (*CGEventTapCallBack)(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo);

CG_EXTERN CGEventRef CGEventCreate(CGEventSourceRef source) CF_RETURNS_RETAINED;
CG_EXTERN CGEventRef CGEventCreateKeyboardEvent(CGEventSourceRef source, CGKeyCode virtualKey, bool keyDown) CF_RETURNS_RETAINED;
CG_EXTERN CGEventRef CGEventCreateMouseEvent(CGEventSourceRef source, CGEventType mouseType, CGPoint location,
                                             CGMouseButton mouseButton) CF_RETURNS_RETAINED;
CG_EXTERN CFDataRef CGEventCreateData(CFAllocatorRef allocator, CGEventRef event) CF_RETURNS_RETAINED;
CG_EXTERN CGEventRef CGEventCreateFromData(CFAllocatorRef allocator, CFDataRef data) CF_RETURNS_RETAINED;
CG_EXTERN CGEventType CGEventGetType(CGEventRef event);
CG_EXTERN CGPoint CGEventGetLocation(CGEventRef event);
CG_EXTERN CGEventFlags CGEventGetFlags(CGEventRef event);
CG_EXTERN void CGEventSetFlags(CGEventRef event, CGEventFlags flags);
CG_EXTERN int64_t CGEventGetIntegerValueField(CGEventRef event, CGEventField field);
CG_EXTERN void CGEventKeyboardGetUnicodeString(CGEventRef event, UniCharCount maxLength, UniCharCount *actualLength, UniChar *unicodeString);
CG_EXTERN void CGEventKeyboardSetUnicodeString(CGEventRef event, UniCharCount length, const UniChar *unicodeString);

// Delivers the event to this app through [NSApp sendEvent:]; other apps can't receive it.
CG_EXTERN void CGEventPost(CGEventTapLocation tap, CGEventRef event);

// Event taps (watching all input system-wide) don't exist for iOS apps: creation returns NULL.
CG_EXTERN CFMachPortRef CGEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place, CGEventTapOptions options,
                                         CGEventMask eventsOfInterest, CGEventTapCallBack callback, void *userInfo);
CG_EXTERN void CGEventTapEnable(CFMachPortRef tap, bool enable);

// Input state of this app, as its event source sees it.
CG_EXTERN bool CGEventSourceKeyState(CGEventSourceStateID stateID, CGKeyCode key);
CG_EXTERN bool CGEventSourceButtonState(CGEventSourceStateID stateID, CGMouseButton button);
CG_EXTERN CGEventFlags CGEventSourceFlagsState(CGEventSourceStateID stateID);
// An event source: the state it was made for, and how long events it posts quiet the local
// keyboard and mouse (nothing to quiet here; kept for the getter).
CG_EXTERN CGEventSourceRef CGEventSourceCreate(CGEventSourceStateID stateID) CF_RETURNS_RETAINED;
CG_EXTERN CGEventSourceStateID CGEventSourceGetSourceStateID(CGEventSourceRef source);
CG_EXTERN void CGEventSourceSetLocalEventsSuppressionInterval(CGEventSourceRef source, double seconds);
CG_EXTERN double CGEventSourceGetLocalEventsSuppressionInterval(CGEventSourceRef source);
CG_EXTERN double CGEventSourceSecondsSinceLastEventType(CGEventSourceStateID stateID, CGEventType eventType);
CG_EXTERN uint32_t CGEventSourceCounterForEventType(CGEventSourceStateID stateID, CGEventType eventType);
CG_EXTERN void CGGetLastMouseDelta(int32_t *deltaX, int32_t *deltaY);

#pragma mark Windows

typedef uint32_t CGWindowID;
typedef uint32_t CGWindowListOption;
typedef uint32_t CGWindowImageOption;
typedef int32_t CGWindowLevel;
typedef int32_t CGWindowLevelKey;

enum {
  kCGWindowListOptionAll = 0, kCGWindowListOptionOnScreenOnly = 1 << 0, kCGWindowListOptionOnScreenAboveWindow = 1 << 1,
  kCGWindowListOptionOnScreenBelowWindow = 1 << 2, kCGWindowListOptionIncludingWindow = 1 << 3,
  kCGWindowListExcludeDesktopElements = 1 << 4,
};
#define kCGNullWindowID ((CGWindowID)0)

enum {
  kCGBaseWindowLevelKey = 0, kCGMinimumWindowLevelKey, kCGDesktopWindowLevelKey, kCGBackstopMenuLevelKey,
  kCGNormalWindowLevelKey, kCGFloatingWindowLevelKey, kCGTornOffMenuWindowLevelKey, kCGDockWindowLevelKey,
  kCGMainMenuWindowLevelKey, kCGStatusWindowLevelKey, kCGModalPanelWindowLevelKey, kCGPopUpMenuWindowLevelKey,
  kCGDraggingWindowLevelKey, kCGScreenSaverWindowLevelKey, kCGMaximumWindowLevelKey, kCGOverlayWindowLevelKey,
  kCGHelpWindowLevelKey, kCGUtilityWindowLevelKey, kCGDesktopIconWindowLevelKey, kCGCursorWindowLevelKey,
  kCGAssistiveTechHighWindowLevelKey, kCGNumberOfWindowLevelKeys,
};

CG_EXTERN const CFStringRef kCGWindowNumber;
CG_EXTERN const CFStringRef kCGWindowOwnerPID;
CG_EXTERN const CFStringRef kCGWindowOwnerName;
CG_EXTERN const CFStringRef kCGWindowName;
CG_EXTERN const CFStringRef kCGWindowBounds;
CG_EXTERN const CFStringRef kCGWindowLayer;
CG_EXTERN const CFStringRef kCGWindowIsOnscreen;

CG_EXTERN CGWindowLevel CGWindowLevelForKey(CGWindowLevelKey key);
CG_EXTERN CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption option, CGWindowID relativeToWindow) CF_RETURNS_RETAINED;
// The same windows as bare CGWindowIDs (the array holds the numbers themselves, not CFNumbers).
CG_EXTERN CFArrayRef CGWindowListCreate(CGWindowListOption option, CGWindowID relativeToWindow) CF_RETURNS_RETAINED;
CG_EXTERN CFArrayRef CGWindowListCreateDescriptionFromArray(CFArrayRef windowArray) CF_RETURNS_RETAINED;
// Window images are screen capture: unavailable, NULL.
CG_EXTERN CGImageRef CGWindowListCreateImage(CGRect screenBounds, CGWindowListOption listOption, CGWindowID windowID,
                                             CGWindowImageOption imageOption) CF_RETURNS_RETAINED;
CG_EXTERN CGImageRef CGWindowListCreateImageFromArray(CGRect screenBounds, CFArrayRef windowArray,
                                                      CGWindowImageOption imageOption) CF_RETURNS_RETAINED;

#pragma mark Displays: capture, modes, fades

typedef struct CGDisplayStream *CGDisplayStreamRef;
typedef struct CGDisplayStreamUpdate *CGDisplayStreamUpdateRef;
typedef int32_t CGDisplayStreamFrameStatus;
typedef int32_t CGDisplayStreamUpdateRectType;
typedef void (^CGDisplayStreamFrameAvailableHandler)(CGDisplayStreamFrameStatus status, uint64_t displayTime,
                                                     IOSurfaceRef frameSurface, CGDisplayStreamUpdateRef updateRef);
typedef uint32_t CGDisplayFadeReservationToken;
typedef float CGDisplayFadeInterval;
typedef float CGDisplayReservationInterval;
typedef float CGDisplayBlendFraction;

CG_EXTERN const CFStringRef kCGDisplayStreamSourceRect;
CG_EXTERN const CFStringRef kCGDisplayStreamDestinationRect;
CG_EXTERN const CFStringRef kCGDisplayStreamPreserveAspectRatio;
CG_EXTERN const CFStringRef kCGDisplayStreamColorSpace;
CG_EXTERN const CFStringRef kCGDisplayStreamMinimumFrameTime;
CG_EXTERN const CFStringRef kCGDisplayStreamShowCursor;
CG_EXTERN const CFStringRef kCGDisplayStreamYCbCrMatrix;
CG_EXTERN const CFStringRef kCGDisplayStreamYCbCrMatrix_ITU_R_601_4;
CG_EXTERN const CFStringRef kCGDisplayShowDuplicateLowResolutionModes;

// Display streams are screen capture: unavailable, NULL / an error.
CG_EXTERN CGDisplayStreamRef CGDisplayStreamCreate(CGDirectDisplayID display, size_t outputWidth, size_t outputHeight,
                                                   int32_t pixelFormat, CFDictionaryRef properties,
                                                   CGDisplayStreamFrameAvailableHandler handler) CF_RETURNS_RETAINED;
CG_EXTERN CGDisplayStreamRef CGDisplayStreamCreateWithDispatchQueue(CGDirectDisplayID display, size_t outputWidth,
                                                                    size_t outputHeight, int32_t pixelFormat,
                                                                    CFDictionaryRef properties, dispatch_queue_t queue,
                                                                    CGDisplayStreamFrameAvailableHandler handler) CF_RETURNS_RETAINED;
CG_EXTERN CFRunLoopSourceRef CGDisplayStreamGetRunLoopSource(CGDisplayStreamRef displayStream);
CG_EXTERN CGError CGDisplayStreamStart(CGDisplayStreamRef displayStream);
CG_EXTERN CGError CGDisplayStreamStop(CGDisplayStreamRef displayStream);
CG_EXTERN const CGRect *CGDisplayStreamUpdateGetRects(CGDisplayStreamUpdateRef updateRef,
                                                     CGDisplayStreamUpdateRectType rectType, size_t *rectCount);
CG_EXTERN CGImageRef CGDisplayCreateImage(CGDirectDisplayID displayID) CF_RETURNS_RETAINED;

// iOS screens have one mode, which can't change; setting the current one succeeds.
CG_EXTERN CGError CGDisplaySetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode, CFDictionaryRef options);
CG_EXTERN uint32_t CGDisplayIDToOpenGLDisplayMask(CGDirectDisplayID display);
CG_EXTERN uint32_t CGDisplayIOServicePort(CGDirectDisplayID display);

// Screen fades (dimming every display) aren't available: no reservation is granted.
CG_EXTERN CGError CGAcquireDisplayFadeReservation(CGDisplayReservationInterval seconds, CGDisplayFadeReservationToken *token);
CG_EXTERN CGError CGReleaseDisplayFadeReservation(CGDisplayFadeReservationToken token);
CG_EXTERN CGError CGDisplayFade(CGDisplayFadeReservationToken token, CGDisplayFadeInterval duration,
                                CGDisplayBlendFraction startBlend, CGDisplayBlendFraction endBlend,
                                float redBlend, float greenBlend, float blueBlend, boolean_t synchronous);

// iOS renders text without macOS-style font smoothing.
CG_EXTERN bool CGFontRenderingGetFontSmoothingDisabled(void);

#pragma mark Private window server (CGS)

typedef int32_t CGSConnectionID;
typedef uint32_t CGSWindowID;

CG_EXTERN CGSConnectionID CGSMainConnectionID(void);
CG_EXTERN CGSConnectionID _CGSDefaultConnection(void);
CG_EXTERN CGError CGSSetDenyWindowServerConnections(bool deny);
CG_EXTERN CGError CGSGetWindowBounds(CGSConnectionID cid, CGSWindowID wid, CGRect *outBounds);
CG_EXTERN CGError CGSGetSurfaceBounds(CGSConnectionID cid, CGSWindowID wid, uint32_t surface, CGRect *outBounds);
CG_EXTERN CGError CGSSetWindowAlpha(CGSConnectionID cid, CGSWindowID wid, float alpha);
CG_EXTERN CGError CGSSetWindowTransform(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform transform);
CG_EXTERN CGError CGSSetWindowWarp(CGSConnectionID cid, CGSWindowID wid, int32_t width, int32_t height, const float *warp);
CG_EXTERN CGError CGSForceShowCursor(CGSConnectionID cid, bool show);
