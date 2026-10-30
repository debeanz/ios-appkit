// Quartz events, input state, window lists and levels, display capture/fade stubs and the
// private CGS calls. See CoreGraphicsEvents.h for what is in scope on iOS.
#import "AKShimPrivate.h"
#import "AppKitShim/CoreGraphicsEvents.h"
#import "AppKitShim/CoreServicesMac.h"

#pragma mark Input state, recorded from every event NSApp delivers

enum { AKTypeSlots = 32 }; // a constant, so the state arrays below aren't variable-length
static CFAbsoluteTime gLastTime[AKTypeSlots];
static uint32_t gCount[AKTypeSlots];
static NSMutableIndexSet *gKeysDown;
static uint32_t gButtonsDown;
static NSPoint gLastMouse;
static BOOL gHaveMouse;
static int32_t gMouseDX, gMouseDY;
static CFAbsoluteTime gStartTime;

void AKNoteInputEvent(NSEvent *e) {
  @synchronized (NSEvent.class) {
    if (!gKeysDown) { gKeysDown = [NSMutableIndexSet indexSet]; gStartTime = CFAbsoluteTimeGetCurrent(); }
    NSUInteger t = e.type;
    if (t < AKTypeSlots) { gLastTime[t] = CFAbsoluteTimeGetCurrent(); gCount[t]++; }
    switch (e.type) {
      case NSEventTypeKeyDown: [gKeysDown addIndex:e.keyCode]; break;
      case NSEventTypeKeyUp:   [gKeysDown removeIndex:e.keyCode]; break;
      case NSEventTypeLeftMouseDown:  gButtonsDown |= 1u << 0; break;
      case NSEventTypeLeftMouseUp:    gButtonsDown &= ~(1u << 0); break;
      case NSEventTypeRightMouseDown: gButtonsDown |= 1u << 1; break;
      case NSEventTypeRightMouseUp:   gButtonsDown &= ~(1u << 1); break;
      case NSEventTypeOtherMouseDown: gButtonsDown |= 1u << 2; break;
      case NSEventTypeOtherMouseUp:   gButtonsDown &= ~(1u << 2); break;
      default: break;
    }
    BOOL mouse = e.type == NSEventTypeMouseMoved || e.type == NSEventTypeLeftMouseDragged ||
                 e.type == NSEventTypeRightMouseDragged || e.type == NSEventTypeOtherMouseDragged ||
                 e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown;
    if (mouse) {
      NSPoint p = e.locationInWindow;
      // AppKit points go up; Quartz deltas count downward movement as positive.
      if (gHaveMouse) { gMouseDX = (int32_t)lround(p.x - gLastMouse.x); gMouseDY = (int32_t)lround(gLastMouse.y - p.y); }
      gLastMouse = p;
      gHaveMouse = YES;
    }
  }
}

bool CGEventSourceKeyState(CGEventSourceStateID stateID, CGKeyCode key) {
  @synchronized (NSEvent.class) { return [gKeysDown containsIndex:key]; }
}

bool CGEventSourceButtonState(CGEventSourceStateID stateID, CGMouseButton button) {
  if (button > 31) return false;
  @synchronized (NSEvent.class) { return (gButtonsDown >> button) & 1u; }
}

uint32_t AKMouseButtonsDown(void) {
  @synchronized (NSEvent.class) { return gButtonsDown; }
}

// Seconds since the last event of a type; with no such event yet, since the app started.
double CGEventSourceSecondsSinceLastEventType(CGEventSourceStateID stateID, CGEventType type) {
  @synchronized (NSEvent.class) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(), last = 0;
    if (type == kCGAnyInputEventType) {
      for (int i = 0; i < AKTypeSlots; i++) last = MAX(last, gLastTime[i]);
    } else if (type < (CGEventType)AKTypeSlots) {
      last = gLastTime[type];
    }
    if (last == 0) last = gStartTime > 0 ? gStartTime : now;
    return now - last;
  }
}

uint32_t CGEventSourceCounterForEventType(CGEventSourceStateID stateID, CGEventType type) {
  @synchronized (NSEvent.class) {
    if (type == kCGAnyInputEventType) {
      uint32_t total = 0;
      for (int i = 0; i < AKTypeSlots; i++) total += gCount[i];
      return total;
    }
    return type < (CGEventType)AKTypeSlots ? gCount[type] : 0;
  }
}

void CGGetLastMouseDelta(int32_t *dx, int32_t *dy) {
  @synchronized (NSEvent.class) {
    if (dx) *dx = gMouseDX;
    if (dy) *dy = gMouseDY;
  }
}

#pragma mark CGEvent objects

@interface AKCGEvent : NSObject
@property (nonatomic) CGEventType type;
@property (nonatomic) CGPoint location;
@property (nonatomic) CGEventFlags flags;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *fields;
@property (nonatomic, copy) NSString *unicode; // set explicitly; otherwise derived from the key code
@end
@implementation AKCGEvent
@end

static AKCGEvent *AKEv(CGEventRef e) { return (__bridge AKCGEvent *)(void *)e; }

// NSEventModifierFlags and CGEventFlags use the same bits for Shift, Control, Option,
// Command and Caps Lock.
static const CGEventFlags AKFlagMask = 0x00FF0000;

CGPoint AKQuartzPointFromAppKit(NSPoint p) { return CGPointMake(p.x, UIScreen.mainScreen.bounds.size.height - p.y); }
NSPoint AKAppKitPointFromQuartz(CGPoint p) { return NSMakePoint(p.x, UIScreen.mainScreen.bounds.size.height - p.y); }

static CGEventRef AKNewEvent(CGEventType type, CGPoint location) {
  AKCGEvent *e = [AKCGEvent new];
  e.type = type;
  e.location = location;
  e.flags = (CGEventFlags)[NSEvent modifierFlags] & AKFlagMask;
  e.fields = [NSMutableDictionary dictionary];
  return (CGEventRef)CFBridgingRetain(e);
}

CGEventRef CGEventCreate(CGEventSourceRef source) { return AKNewEvent(kCGEventNull, AKQuartzPointFromAppKit([NSEvent mouseLocation])); }

CGEventRef CGEventCreateKeyboardEvent(CGEventSourceRef source, CGKeyCode key, bool keyDown) {
  CGEventRef ref = AKNewEvent(keyDown ? kCGEventKeyDown : kCGEventKeyUp, AKQuartzPointFromAppKit([NSEvent mouseLocation]));
  AKEv(ref).fields[@(kCGKeyboardEventKeycode)] = @(key);
  return ref;
}

CGEventRef CGEventCreateMouseEvent(CGEventSourceRef source, CGEventType type, CGPoint location, CGMouseButton button) {
  CGEventRef ref = AKNewEvent(type, location);
  AKEv(ref).fields[@(kCGMouseEventButtonNumber)] = @(button);
  AKEv(ref).fields[@(kCGMouseEventClickState)] = @1;
  return ref;
}

CGEventType CGEventGetType(CGEventRef e) { return e ? AKEv(e).type : kCGEventNull; }
CGPoint CGEventGetLocation(CGEventRef e) { return e ? AKEv(e).location : CGPointZero; }
CGEventFlags CGEventGetFlags(CGEventRef e) { return e ? AKEv(e).flags : 0; }
void CGEventSetFlags(CGEventRef e, CGEventFlags flags) { if (e) AKEv(e).flags = flags; }
CGEventFlags CGEventSourceFlagsState(CGEventSourceStateID stateID) { return (CGEventFlags)[NSEvent modifierFlags] & AKFlagMask; }

@interface AKCGEventSource : NSObject
@property (nonatomic) CGEventSourceStateID stateID;
@property (nonatomic) double suppressionInterval;
@end
@implementation AKCGEventSource
@end

CGEventSourceRef CGEventSourceCreate(CGEventSourceStateID stateID) {
  AKCGEventSource *s = [AKCGEventSource new];
  s.stateID = stateID;
  s.suppressionInterval = 0.25;   // macOS's default
  return (CGEventSourceRef)CFBridgingRetain(s);
}
CGEventSourceStateID CGEventSourceGetSourceStateID(CGEventSourceRef source) {
  return source ? ((__bridge AKCGEventSource *)(void *)source).stateID : kCGEventSourceStateHIDSystemState;
}
void CGEventSourceSetLocalEventsSuppressionInterval(CGEventSourceRef source, double seconds) {
  if (source) ((__bridge AKCGEventSource *)(void *)source).suppressionInterval = seconds;
}
double CGEventSourceGetLocalEventsSuppressionInterval(CGEventSourceRef source) {
  return source ? ((__bridge AKCGEventSource *)(void *)source).suppressionInterval : 0.25;
}
int64_t CGEventGetIntegerValueField(CGEventRef e, CGEventField field) { return e ? AKEv(e).fields[@(field)].longLongValue : 0; }

// The NSEvent a CGEvent stands for (Unity makes one from CGEventCreate(NULL) to read where the
// pointer is and which modifier keys are down). The two number their event types alike, and
// their modifier flags too.
@implementation NSEvent (AKCGEvent)
+ (NSEvent *)eventWithCGEvent:(CGEventRef)cgEvent {
  if (!cgEvent) return nil;
  CGEventType type = CGEventGetType(cgEvent);
  NSPoint location = AKAppKitPointFromQuartz(CGEventGetLocation(cgEvent));
  NSEventModifierFlags flags = (NSEventModifierFlags)(CGEventGetFlags(cgEvent) & 0xffff0000);
  NSTimeInterval time = NSProcessInfo.processInfo.systemUptime;
  if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
    NSString *text = AKEv(cgEvent).unicode ?: @"";
    return [NSEvent keyEventWithType:(NSEventType)type location:location modifierFlags:flags timestamp:time windowNumber:0 context:nil
                          characters:text charactersIgnoringModifiers:text isARepeat:NO
                             keyCode:(unsigned short)CGEventGetIntegerValueField(cgEvent, kCGKeyboardEventKeycode)];
  }
  BOOL mouse = (type >= kCGEventLeftMouseDown && type <= kCGEventRightMouseDragged) ||
               (type >= kCGEventOtherMouseDown && type <= kCGEventOtherMouseDragged);
  return [NSEvent mouseEventWithType:mouse ? (NSEventType)type : NSEventTypeMouseMoved location:location modifierFlags:flags
                           timestamp:time windowNumber:0 context:nil eventNumber:0
                          clickCount:(NSInteger)CGEventGetIntegerValueField(cgEvent, kCGMouseEventClickState) pressure:0];
}
@end

// The text a key event types: the explicit string, else the key translated through the US
// layout with the event's modifiers, as macOS derives it from the current layout.
static NSString *AKEventText(AKCGEvent *e) {
  if (e.unicode) return e.unicode;
  if (e.type != kCGEventKeyDown && e.type != kCGEventKeyUp) return @"";
  UInt32 carbon = 0;
  if (e.flags & NSEventModifierFlagCommand)  carbon |= 1 << 0;
  if (e.flags & NSEventModifierFlagShift)    carbon |= 1 << 1;
  if (e.flags & NSEventModifierFlagCapsLock) carbon |= 1 << 2;
  if (e.flags & NSEventModifierFlagOption)   carbon |= 1 << 3;
  if (e.flags & NSEventModifierFlagControl)  carbon |= 1 << 4;
  NSData *layout = AKUSKeyboardLayoutData();
  UniChar buf[4];
  UniCharCount n = 0;
  UInt32 dead = 0;
  UCKeyTranslate((const UCKeyboardLayout *)layout.bytes, (UInt16)e.fields[@(kCGKeyboardEventKeycode)].unsignedShortValue,
                 kUCKeyActionDown, carbon, LMGetKbdType(), 0, &dead, 4, &n, buf);
  return [NSString stringWithCharacters:buf length:n];
}

void CGEventKeyboardGetUnicodeString(CGEventRef e, UniCharCount max, UniCharCount *actual, UniChar *out) {
  NSString *s = e ? AKEventText(AKEv(e)) : @"";
  UniCharCount n = MIN((UniCharCount)s.length, max);
  if (out && n) [s getCharacters:out range:NSMakeRange(0, n)];
  if (actual) *actual = n;
}

void CGEventKeyboardSetUnicodeString(CGEventRef e, UniCharCount length, const UniChar *chars) {
  if (e) AKEv(e).unicode = chars ? [NSString stringWithCharacters:chars length:length] : @"";
}

CFDataRef CGEventCreateData(CFAllocatorRef allocator, CGEventRef e) {
  if (!e) return NULL;
  AKCGEvent *ev = AKEv(e);
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  [ev.fields enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, NSNumber *v, BOOL *stop) { fields[k.stringValue] = v; }];
  NSDictionary *plist = @{ @"type": @(ev.type), @"x": @(ev.location.x), @"y": @(ev.location.y),
                           @"flags": @(ev.flags), @"fields": fields, @"unicode": ev.unicode ?: [NSNull null] };
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:plist requiringSecureCoding:YES error:nil];
  return data ? (CFDataRef)CFBridgingRetain(data) : NULL;
}

CGEventRef CGEventCreateFromData(CFAllocatorRef allocator, CFDataRef data) {
  if (!data) return NULL;
  NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSNumber.class, NSString.class, NSNull.class, nil];
  NSDictionary *plist = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:(__bridge NSData *)data error:nil];
  if (![plist isKindOfClass:NSDictionary.class]) return NULL;
  CGEventRef ref = AKNewEvent((CGEventType)[plist[@"type"] unsignedIntValue],
                              CGPointMake([plist[@"x"] doubleValue], [plist[@"y"] doubleValue]));
  AKCGEvent *ev = AKEv(ref);
  ev.flags = (CGEventFlags)[plist[@"flags"] unsignedLongLongValue];
  [plist[@"fields"] enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSNumber *v, BOOL *stop) { ev.fields[@(k.intValue)] = v; }];
  if ([plist[@"unicode"] isKindOfClass:NSString.class]) ev.unicode = plist[@"unicode"];
  return ref;
}

#pragma mark Posting into this app

static NSView *AKViewUnder(NSWindow *w, NSPoint windowPoint) {
  UIView *hit = [w.contentView.backingView hitTest:windowPoint withEvent:nil];
  while (hit && ![hit isKindOfClass:_AKShimBackingView.class]) hit = hit.superview;
  return ((_AKShimBackingView *)hit).owner ?: w.contentView;
}

// The running game's window in front of everything (no Steam overlay over it), or nil.
static NSWindow *AKGameWindowInFront(void) {
  if (!AKGameIsRunning() || AKGameOverlayShown()) return nil;
  NSWindow *found = nil;
  for (NSWindow *w in NSApp.windows) {
    if (!w._ak_gameWindow || !w.visible) continue;
    if (w.isKeyWindow) return w;
    if (!found) found = w;
  }
  return found;
}

static void AKPostOnMain(AKCGEvent *ev) {
  NSEventModifierFlags flags = (NSEventModifierFlags)(ev.flags & AKFlagMask);
  // Keys and the mouse Steam posts while a game is in front are Steam Input's (a controller
  // played as keyboard and mouse for a game without controller support): they go to the game's
  // own event loop, as macOS puts them in its event queue.
  NSWindow *game = AKGameWindowInFront();
  // With the Safari engine Steam's interface is web pages, so the keys Steam types (its
  // on-screen keyboard, played with a controller) go to the focused page, not a window here.
  if (!game && AKWHStageView() && (ev.type == kCGEventKeyDown || ev.type == kCGEventKeyUp)) {
    AKWHTypeKey(ev.type == kCGEventKeyDown, ev.fields[@(kCGKeyboardEventKeycode)].unsignedShortValue, AKEventText(ev),
                (flags & NSEventModifierFlagCommand) != 0);
    return;
  }
  NSWindow *w = game ?: NSApp.keyWindow;
  if (!w) return;
  NSEvent *e = nil;
  switch (ev.type) {
    case kCGEventKeyDown: case kCGEventKeyUp: case kCGEventFlagsChanged: {
      unsigned short code = ev.fields[@(kCGKeyboardEventKeycode)].unsignedShortValue;
      NSString *chars = AKCharactersForMacKeyCode(code) ?: AKEventText(ev);
      e = [NSEvent keyEventWithType:(NSEventType)ev.type location:[NSEvent mouseLocation] modifierFlags:flags
                          timestamp:0 windowNumber:w.windowNumber context:nil characters:chars
        charactersIgnoringModifiers:chars.lowercaseString isARepeat:ev.fields[@(kCGKeyboardEventAutorepeat)].boolValue
                            keyCode:code];
      break;
    }
    case kCGEventLeftMouseDown: case kCGEventLeftMouseUp: case kCGEventRightMouseDown: case kCGEventRightMouseUp:
    case kCGEventMouseMoved: case kCGEventLeftMouseDragged: case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDown: case kCGEventOtherMouseUp: case kCGEventOtherMouseDragged: {
      // Quartz locations are global display points (top-left origin); find the view under
      // the point in UIKit terms, and give the event AppKit window coordinates (bottom-left).
      UIView *content = w.contentView.backingView;
      CGPoint u = content.window ? [content convertPoint:ev.location fromView:nil] : ev.location;
      NSPoint p = NSMakePoint(u.x, content.bounds.size.height - u.y);
      e = [NSEvent mouseEventWithType:(NSEventType)ev.type location:p modifierFlags:flags timestamp:0
                         windowNumber:w.windowNumber context:nil eventNumber:0
                           clickCount:MAX(1, (NSInteger)ev.fields[@(kCGMouseEventClickState)].integerValue) pressure:1];
      [e _setWindow:w targetView:AKViewUnder(w, u)];
      [NSEvent _setMouseLocation:p];
      break;
    }
    default: return;
  }
  if (game) {
    static unsigned logged;
    if (++logged <= 5) fprintf(stderr, "[AppKitShim] game: Steam Input sends it an event (CGEvent type %d)\n", (int)ev.type);
    [NSApp _ak_postGameEvent:e];
    return;
  }
  [NSApp sendEvent:e];
}

void CGEventPost(CGEventTapLocation tap, CGEventRef event) {
  if (!event) return;
  AKCGEvent *ev = AKEv(event);
  if (NSThread.isMainThread) AKPostOnMain(ev);
  else dispatch_async(dispatch_get_main_queue(), ^{ AKPostOnMain(ev); });
}

CFMachPortRef CGEventTapCreate(CGEventTapLocation tap, CGEventTapPlacement place, CGEventTapOptions options,
                               CGEventMask mask, CGEventTapCallBack callback, void *userInfo) {
  return NULL;
}

void CGEventTapEnable(CFMachPortRef tap, bool enable) {}

#pragma mark Windows

const CFStringRef kCGWindowNumber = CFSTR("kCGWindowNumber");
const CFStringRef kCGWindowOwnerPID = CFSTR("kCGWindowOwnerPID");
const CFStringRef kCGWindowOwnerName = CFSTR("kCGWindowOwnerName");
const CFStringRef kCGWindowName = CFSTR("kCGWindowName");
const CFStringRef kCGWindowBounds = CFSTR("kCGWindowBounds");
const CFStringRef kCGWindowLayer = CFSTR("kCGWindowLayer");
const CFStringRef kCGWindowIsOnscreen = CFSTR("kCGWindowIsOnscreen");

CGWindowLevel CGWindowLevelForKey(CGWindowLevelKey key) {
  static const int32_t minimum = INT32_MIN + 1, maximum = INT32_MAX - 16;
  switch (key) {
    case kCGBaseWindowLevelKey:              return INT32_MIN;
    case kCGMinimumWindowLevelKey:           return minimum;
    case kCGDesktopWindowLevelKey:           return minimum + 20;
    case kCGDesktopIconWindowLevelKey:       return minimum + 40;
    case kCGBackstopMenuLevelKey:            return -20;
    case kCGNormalWindowLevelKey:            return 0;
    case kCGFloatingWindowLevelKey:          return 3;
    case kCGTornOffMenuWindowLevelKey:       return 3;
    case kCGModalPanelWindowLevelKey:        return 8;
    case kCGUtilityWindowLevelKey:           return 19;
    case kCGDockWindowLevelKey:              return 20;
    case kCGMainMenuWindowLevelKey:          return 24;
    case kCGStatusWindowLevelKey:            return 25;
    case kCGPopUpMenuWindowLevelKey:         return 101;
    case kCGOverlayWindowLevelKey:           return 102;
    case kCGHelpWindowLevelKey:              return 200;
    case kCGDraggingWindowLevelKey:          return 500;
    case kCGScreenSaverWindowLevelKey:       return 1000;
    case kCGAssistiveTechHighWindowLevelKey: return 1500;
    case kCGCursorWindowLevelKey:            return maximum - 1;
    case kCGMaximumWindowLevelKey:           return maximum;
    default:                                 return 0;
  }
}

// A window's bounds in global display points (top-left origin, as Quartz reports them).
static CGRect AKWindowScreenBounds(NSWindow *w) {
  UIView *content = w.contentView.backingView;
  return content.window ? [content convertRect:content.bounds toView:nil] : w.frame;
}

static NSDictionary *AKWindowInfo(NSWindow *w) {
  NSString *app = NSBundle.mainBundle.infoDictionary[@"CFBundleName"] ?: NSProcessInfo.processInfo.processName;
  NSDictionary *bounds = CFBridgingRelease(CGRectCreateDictionaryRepresentation(AKWindowScreenBounds(w)));
  return @{
    (__bridge NSString *)kCGWindowNumber: @(w.windowNumber),
    (__bridge NSString *)kCGWindowOwnerPID: @(getpid()),
    (__bridge NSString *)kCGWindowOwnerName: app,
    (__bridge NSString *)kCGWindowName: w.title ?: @"",
    (__bridge NSString *)kCGWindowBounds: bounds,
    (__bridge NSString *)kCGWindowLayer: @0,
    (__bridge NSString *)kCGWindowIsOnscreen: @(w.isVisible),
  };
}

// Only this app's windows are visible to it; listed front to back.
static NSArray<NSWindow *> *AKListedWindows(CGWindowListOption option, CGWindowID relativeTo) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSWindow *w in NSApp.windows.reverseObjectEnumerator) {
    if ((option & kCGWindowListOptionIncludingWindow) && (CGWindowID)w.windowNumber != relativeTo) continue;
    if ((option & kCGWindowListOptionOnScreenOnly) && !w.isVisible) continue;
    [out addObject:w];
  }
  return out;
}

CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption option, CGWindowID relativeTo) {
  NSMutableArray *out = [NSMutableArray array];
  for (NSWindow *w in AKListedWindows(option, relativeTo)) [out addObject:AKWindowInfo(w)];
  return (CFArrayRef)CFBridgingRetain(out);
}

CFArrayRef CGWindowListCreate(CGWindowListOption option, CGWindowID relativeTo) {
  CFMutableArrayRef out = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
  for (NSWindow *w in AKListedWindows(option, relativeTo)) CFArrayAppendValue(out, (const void *)(uintptr_t)(CGWindowID)w.windowNumber);
  return out;
}

// The array holds bare CGWindowIDs (CGWindowListCreate's); one built of CFNumbers is read too.
static CGWindowID AKWindowIDAt(CFArrayRef windows, CFIndex i) {
  uintptr_t v = (uintptr_t)CFArrayGetValueAtIndex(windows, i);
  return v <= UINT32_MAX ? (CGWindowID)v : (CGWindowID)[(__bridge NSNumber *)(const void *)v unsignedIntValue];
}

CFArrayRef CGWindowListCreateDescriptionFromArray(CFArrayRef windowArray) {
  NSMutableArray *out = [NSMutableArray array];
  for (CFIndex i = 0; windowArray && i < CFArrayGetCount(windowArray); i++) {
    NSWindow *w = [NSApp windowWithWindowNumber:AKWindowIDAt(windowArray, i)];
    if (w) [out addObject:AKWindowInfo(w)];
  }
  return (CFArrayRef)CFBridgingRetain(out);
}

CGImageRef CGWindowListCreateImage(CGRect bounds, CGWindowListOption option, CGWindowID windowID, CGWindowImageOption imageOption) {
  return NULL;
}

CGImageRef CGWindowListCreateImageFromArray(CGRect bounds, CFArrayRef windowArray, CGWindowImageOption imageOption) {
  return NULL;
}

#pragma mark Displays: capture, modes, fades

const CFStringRef kCGDisplayStreamSourceRect = CFSTR("kCGDisplayStreamSourceRect");
const CFStringRef kCGDisplayStreamDestinationRect = CFSTR("kCGDisplayStreamDestinationRect");
const CFStringRef kCGDisplayStreamPreserveAspectRatio = CFSTR("kCGDisplayStreamPreserveAspectRatio");
const CFStringRef kCGDisplayStreamColorSpace = CFSTR("kCGDisplayStreamColorSpace");
const CFStringRef kCGDisplayStreamMinimumFrameTime = CFSTR("kCGDisplayStreamMinimumFrameTime");
const CFStringRef kCGDisplayStreamShowCursor = CFSTR("kCGDisplayStreamShowCursor");
const CFStringRef kCGDisplayStreamYCbCrMatrix = CFSTR("kCGDisplayStreamYCbCrMatrix");
const CFStringRef kCGDisplayStreamYCbCrMatrix_ITU_R_601_4 = CFSTR("ITU_R_601_4");
const CFStringRef kCGDisplayShowDuplicateLowResolutionModes = CFSTR("kCGDisplayShowDuplicateLowResolutionModes");

CGDisplayStreamRef CGDisplayStreamCreate(CGDirectDisplayID display, size_t w, size_t h, int32_t fmt,
                                         CFDictionaryRef props, CGDisplayStreamFrameAvailableHandler handler) {
  return NULL;
}

CGDisplayStreamRef CGDisplayStreamCreateWithDispatchQueue(CGDirectDisplayID display, size_t w, size_t h, int32_t fmt,
                                                          CFDictionaryRef props, dispatch_queue_t queue,
                                                          CGDisplayStreamFrameAvailableHandler handler) {
  return NULL;
}

CFRunLoopSourceRef CGDisplayStreamGetRunLoopSource(CGDisplayStreamRef stream) { return NULL; }
CGError CGDisplayStreamStart(CGDisplayStreamRef stream) { return kCGErrorIllegalArgument; }
CGError CGDisplayStreamStop(CGDisplayStreamRef stream) { return kCGErrorIllegalArgument; }

const CGRect *CGDisplayStreamUpdateGetRects(CGDisplayStreamUpdateRef update, CGDisplayStreamUpdateRectType type, size_t *count) {
  if (count) *count = 0;
  return NULL;
}

CGImageRef CGDisplayCreateImage(CGDirectDisplayID display) { return NULL; }

CGError CGDisplaySetDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode, CFDictionaryRef options) {
  CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
  if (!current) return kCGErrorIllegalArgument;
  BOOL same = mode && CGDisplayModeGetWidth(mode) == CGDisplayModeGetWidth(current) &&
              CGDisplayModeGetHeight(mode) == CGDisplayModeGetHeight(current);
  CGDisplayModeRelease(current);
  return same ? kCGErrorSuccess : kCGErrorIllegalArgument;
}

uint32_t CGDisplayIDToOpenGLDisplayMask(CGDirectDisplayID display) {
  return (display >= 1 && display <= 32 && AKScreenForDisplayID(display)) ? 1u << (display - 1) : 0;
}

uint32_t CGDisplayIOServicePort(CGDirectDisplayID display) { return 0; }

CGError CGAcquireDisplayFadeReservation(CGDisplayReservationInterval seconds, CGDisplayFadeReservationToken *token) {
  if (token) *token = 0;
  return kCGErrorNoneAvailable;
}

CGError CGReleaseDisplayFadeReservation(CGDisplayFadeReservationToken token) { return kCGErrorIllegalArgument; }

CGError CGDisplayFade(CGDisplayFadeReservationToken token, CGDisplayFadeInterval duration, CGDisplayBlendFraction start,
                      CGDisplayBlendFraction end, float r, float g, float b, boolean_t synchronous) {
  return kCGErrorIllegalArgument;
}

bool CGFontRenderingGetFontSmoothingDisabled(void) { return true; }

#pragma mark Private window server (CGS)

CGSConnectionID CGSMainConnectionID(void) { return 1; }
CGSConnectionID _CGSDefaultConnection(void) { return 1; }
CGError CGSSetDenyWindowServerConnections(bool deny) { return kCGErrorSuccess; }

CGError CGSGetWindowBounds(CGSConnectionID cid, CGSWindowID wid, CGRect *outBounds) {
  NSWindow *w = [NSApp windowWithWindowNumber:wid];
  if (!w || !outBounds) return kCGErrorIllegalArgument;
  *outBounds = AKWindowScreenBounds(w);
  return kCGErrorSuccess;
}

CGError CGSGetSurfaceBounds(CGSConnectionID cid, CGSWindowID wid, uint32_t surface, CGRect *outBounds) {
  return kCGErrorIllegalArgument;
}

CGError CGSSetWindowAlpha(CGSConnectionID cid, CGSWindowID wid, float alpha) {
  NSWindow *w = [NSApp windowWithWindowNumber:wid];
  if (!w) return kCGErrorIllegalArgument;
  w.alphaValue = alpha;
  return kCGErrorSuccess;
}

// Window transforms and warps are window-server compositing effects; accepted for this app's
// own windows without visible effect.
CGError CGSSetWindowTransform(CGSConnectionID cid, CGSWindowID wid, CGAffineTransform transform) {
  return [NSApp windowWithWindowNumber:wid] ? kCGErrorSuccess : kCGErrorIllegalArgument;
}

CGError CGSSetWindowWarp(CGSConnectionID cid, CGSWindowID wid, int32_t width, int32_t height, const float *warp) {
  return [NSApp windowWithWindowNumber:wid] ? kCGErrorSuccess : kCGErrorIllegalArgument;
}

CGError CGSForceShowCursor(CGSConnectionID cid, bool show) { return kCGErrorSuccess; }
