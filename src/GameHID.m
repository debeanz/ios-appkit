// IOKit HID for the Mac games Steam starts, answered from GameController. A Mac game reads
// gamepads through IOHIDManager (GameMaker's libYoYoGamepad, SDL2); on iOS a Bluetooth
// controller reaches an app only through GameController, and IOKit's HID manager shows none. So
// the IOHID* imports of a game's own libraries are pointed here (Steam's aren't): each connected
// controller with a gamepad profile is a wired Xbox 360 controller — the layout Mac gamepad
// mapping databases know (SDL's "X360 Controller": 15 buttons, A B X Y LB RB LS RS Start Back
// Guide and the d-pad; sticks on X/Y and Rx/Ry, triggers on Z and Rz) — whose values are read
// from GameController when the game asks, and sent to its input callbacks as they change: as
// element values, as the input reports that controller sends (Unity's Input System reads those),
// and through queues of values (Unity's older input).
#import "AKShimPrivate.h"
#import <GameController/GameController.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>

typedef int32_t AKIOReturn;
enum { kAKIOReturnSuccess = 0, kAKIOReturnUnsupported = (int32_t)0xe00002c7 };
enum { kAKElementMisc = 1, kAKElementButton = 2, kAKElementAxis = 3 };
typedef void (*AKHIDDeviceCallback)(void *context, AKIOReturn result, void *sender, void *device);
typedef void (*AKHIDValueCallback)(void *context, AKIOReturn result, void *sender, void *value);
typedef void (*AKHIDCallback)(void *context, AKIOReturn result, void *sender);
typedef void (*AKHIDReportCallback)(void *context, AKIOReturn result, void *sender, uint32_t type, uint32_t reportID, uint8_t *report,
                                    long length);
typedef void (*AKHIDReportTimeCallback)(void *context, AKIOReturn result, void *sender, uint32_t type, uint32_t reportID,
                                        uint8_t *report, long length, uint64_t timeStamp);

// An input report callback (a device's, with the buffer its caller gave, or a manager's), and the
// report it was last sent.
enum { kAKReportSize = 20 };
typedef struct {
  AKHIDReportCallback fn;
  AKHIDReportTimeCallback timed;
  void *context;
  uint8_t *buffer;
  long length;
  uint8_t last[kAKReportSize];
  BOOL sent;
} AKReportCallback;

static void hidLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void hidLog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[AppKitShim] game controllers: %s\n", line.UTF8String);
}

@class AKHIDDevice;

@interface AKHIDElement : NSObject {
@public
  uint32_t page, usage, type, cookie;
  int64_t min, max;
  __weak AKHIDDevice *device;
  NSMutableDictionary *properties;   // set by the game (calibration)
}
@end
@implementation AKHIDElement
@end

@interface AKHIDValue : NSObject {
@public
  AKHIDElement *element;
  int64_t integer;
  uint64_t time;
}
@end
@implementation AKHIDValue
@end

typedef struct { AKHIDValueCallback fn; void *context; } AKValueCallback;

@interface AKHIDDevice : NSObject {
@public
  GCController *controller;
  NSArray<AKHIDElement *> *elements;
  NSMutableArray<AKHIDValue *> *values;   // one per element, what -GetValue hands out
  int64_t last[32];                       // per element, as last sent to callbacks
  uint32_t location;
  AKValueCallback input;
  AKReportCallback report;
  uint8_t scratch[kAKReportSize];         // the report last sent to managers' callbacks (they give no buffer)
  BOOL scratchSent;
  AKHIDCallback removed;
  void *removedContext;
  CFRunLoopTimerRef timer;                // when scheduled on its own
  uint32_t heldBack;                      // pressed for Steam's overlay: up for the game until let go
}
@end
@implementation AKHIDDevice
@end

@interface AKHIDManager : NSObject {
@public
  NSArray<NSDictionary *> *matching;      // nil: every device
  AKHIDDeviceCallback matched, removed;
  void *matchedContext, *removedContext;
  AKValueCallback input;
  AKReportCallback report;
  NSMutableArray<AKHIDDevice *> *known;
  CFRunLoopTimerRef timer;
  dispatch_queue_t queue;
  dispatch_source_t source;
}
@end
@implementation AKHIDManager
@end

#pragma mark Controllers as HID devices

static int64_t stick(float v) { return MAX(-32768, MIN(32767, lroundf(v * 32767.0f))); }
static int64_t trigger(float v) { return MAX(0, MIN(255, lroundf(v * 255.0f))); }

// What an element of the X360 layout reads on a GameController gamepad right now.
static int64_t readNow(AKHIDDevice *d, AKHIDElement *e);

// A button (bit = usage) or trigger (bits 20 and 21) held when Steam's overlay closed went to
// Steam (A on Resume, B out of its menu): the game sees it up until it is let go.
static uint32_t holdBackBit(AKHIDElement *e) {
  if (e->page == 9) return 1u << e->usage;
  return e->usage == 0x32 ? 1u << 20 : e->usage == 0x35 ? 1u << 21 : 0;
}

static int64_t readElement(AKHIDDevice *d, AKHIDElement *e) {
  // With Steam's overlay over the game, the controller drives Steam: the game sees it at rest.
  if (!d->controller.extendedGamepad || AKGameOverlayShown()) return 0;
  int64_t v = readNow(d, e);
  uint32_t bit = holdBackBit(e);
  if (bit && (__atomic_load_n(&d->heldBack, __ATOMIC_RELAXED) & bit)) {
    BOOL down = e->page == 9 ? v != 0 : v > 32;
    if (down) return 0;
    __atomic_and_fetch(&d->heldBack, ~bit, __ATOMIC_RELAXED);
  }
  return v;
}

static int64_t readNow(AKHIDDevice *d, AKHIDElement *e) {
  GCExtendedGamepad *g = d->controller.extendedGamepad;
  if (e->page == 9) {
    GCControllerButtonInput *b = nil;
    switch (e->usage) {
      // Start and Back as Steam lets them through: held back a moment, to tell them from the
      // View + Menu chord that opens Steam's overlay (WebHelperGamepad.m).
      case 9: return AKControllerMenuViewPressed(d->controller, YES);
      case 10: return AKControllerMenuViewPressed(d->controller, NO);
      case 11: return 0;   // Home is Steam's button
      case 1: b = g.buttonA; break;
      case 2: b = g.buttonB; break;
      case 3: b = g.buttonX; break;
      case 4: b = g.buttonY; break;
      case 5: b = g.leftShoulder; break;
      case 6: b = g.rightShoulder; break;
      case 7: b = g.leftThumbstickButton; break;
      case 8: b = g.rightThumbstickButton; break;
      case 12: b = g.dpad.up; break;
      case 13: b = g.dpad.down; break;
      case 14: b = g.dpad.left; break;
      case 15: b = g.dpad.right; break;
    }
    return b.isPressed ? 1 : 0;
  }
  switch (e->usage) {
    case 0x30: return stick(g.leftThumbstick.xAxis.value);
    case 0x31: return stick(-g.leftThumbstick.yAxis.value);    // HID's y grows downward
    case 0x32: return trigger(g.leftTrigger.value);
    case 0x33: return stick(g.rightThumbstick.xAxis.value);
    case 0x34: return stick(-g.rightThumbstick.yAxis.value);
    case 0x35: return trigger(g.rightTrigger.value);
  }
  return 0;
}

static AKHIDDevice *deviceFor(GCController *controller) {
  static NSMapTable<GCController *, AKHIDDevice *> *devices;
  static uint32_t nextLocation = 0x14100000;
  @synchronized (AKHIDDevice.class) {
    if (!devices) devices = [NSMapTable weakToStrongObjectsMapTable];
    AKHIDDevice *d = [devices objectForKey:controller];
    if (d) return d;
    d = [AKHIDDevice new];
    d->controller = controller;
    d->location = nextLocation += 0x10000;
    NSMutableArray *elements = [NSMutableArray array];
    uint32_t cookie = 1;
    for (uint32_t usage = 1; usage <= 15; usage++) {
      AKHIDElement *e = [AKHIDElement new];
      e->page = 9; e->usage = usage; e->type = kAKElementButton; e->min = 0; e->max = 1; e->cookie = cookie++;
      e->device = d;
      [elements addObject:e];
    }
    for (uint32_t usage = 0x30; usage <= 0x35; usage++) {
      AKHIDElement *e = [AKHIDElement new];
      BOOL isTrigger = usage == 0x32 || usage == 0x35;
      e->page = 1; e->usage = usage; e->type = kAKElementMisc; e->cookie = cookie++;
      e->min = isTrigger ? 0 : -32768; e->max = isTrigger ? 255 : 32767;
      e->device = d;
      [elements addObject:e];
    }
    d->elements = elements;
    d->values = [NSMutableArray array];
    for (AKHIDElement *e in elements) {
      AKHIDValue *v = [AKHIDValue new];
      v->element = e;
      [d->values addObject:v];
    }
    [devices setObject:d forKey:controller];
    hidLog(@"\"%@\" shows to the game as an Xbox 360 controller", controller.vendorName ?: @"controller");
    return d;
  }
}

static void holdBackGameControllerElements(void);

void AKGameControllersHoldBack(void) {
  holdBackGameControllerElements();
  @synchronized (AKHIDDevice.class) {
    for (GCController *c in GCController.controllers) {
      if (!c.extendedGamepad) continue;
      AKHIDDevice *d = deviceFor(c);
      __atomic_store_n(&d->heldBack, ~0u, __ATOMIC_RELAXED);
    }
  }
}

static NSArray<AKHIDDevice *> *connectedDevices(void) {
  NSMutableArray *list = [NSMutableArray array];
  for (GCController *c in GCController.controllers) if (c.extendedGamepad) [list addObject:deviceFor(c)];
  return list;
}

static id property(AKHIDDevice *d, NSString *key) {
  static NSDictionary *fixed;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    fixed = @{
      @"VendorID": @0x045e, @"ProductID": @0x028e, @"VersionNumber": @0, @"VendorIDSource": @0,
      @"Product": @"Xbox 360 Wired Controller", @"Manufacturer": @"Microsoft", @"Transport": @"USB",
      @"PrimaryUsagePage": @1, @"PrimaryUsage": @5, @"DeviceUsagePage": @1, @"DeviceUsage": @5,
      @"DeviceUsagePairs": @[ @{ @"DeviceUsagePage": @1, @"DeviceUsage": @5 } ],
      @"CountryCode": @0, @"MaxInputReportSize": @20, @"ReportInterval": @8000,
    };
  });
  if ([key isEqualToString:@"LocationID"] || [key isEqualToString:@"UniqueID"]) return @(d->location);
  if ([key isEqualToString:@"SerialNumber"]) return [NSString stringWithFormat:@"%08x", d->location];
  return fixed[key];
}

static BOOL matchesOne(AKHIDDevice *d, NSDictionary *m) {
  for (NSString *key in m) {
    id want = m[key];
    if ([key isEqualToString:@"DeviceUsagePairs"]) {
      BOOL any = NO;
      for (NSDictionary *pair in [want isKindOfClass:NSArray.class] ? want : @[]) any = any || matchesOne(d, pair);
      if (!any) return NO;
      continue;
    }
    if ([key hasSuffix:@"UsagePage"]) { if ([want intValue] != 1) return NO; continue; }
    if ([key hasSuffix:@"Usage"]) { int u = [want intValue]; if (u != 4 && u != 5 && u != 8) return NO; continue; }
    id have = property(d, key);
    if (have && ![have isEqual:want]) return NO;
  }
  return YES;
}

static BOOL matches(AKHIDManager *m, AKHIDDevice *d) {
  if (!m->matching) return YES;
  for (NSDictionary *one in m->matching) if (matchesOne(d, one)) return YES;
  return NO;
}

#pragma mark Callbacks

static AKHIDValue *freshValue(AKHIDElement *e, int64_t integer) {
  AKHIDValue *v = [AKHIDValue new];
  v->element = e;
  v->integer = integer;
  v->time = mach_absolute_time();
  return v;
}

// Values that changed since the last poll, to the device's and the manager's callbacks.
static void sendChanges(AKHIDDevice *d, AKValueCallback *managerInput) {
  if (!d->input.fn && !(managerInput && managerInput->fn)) return;
  NSUInteger n = MIN(d->elements.count, 32u);
  for (NSUInteger i = 0; i < n; i++) {
    AKHIDElement *e = d->elements[i];
    int64_t now = readElement(d, e);
    if (now == d->last[i]) continue;
    d->last[i] = now;
    AKHIDValue *v = freshValue(e, now);
    if (d->input.fn) d->input.fn(d->input.context, kAKIOReturnSuccess, (__bridge void *)d, (__bridge void *)v);
    if (managerInput && managerInput->fn) managerInput->fn(managerInput->context, kAKIOReturnSuccess, (__bridge void *)d, (__bridge void *)v);
  }
}

// Its input report as a wired Xbox 360 controller sends it on a Mac (the 360Controller driver's,
// which Unity's Input System reads as XboxGamepadMacOS): 0x00 0x14, then the buttons (d-pad up
// down left right, Start, Back, the stick presses, LB, RB, Guide, -, A, B, X, Y from bit 0),
// the triggers (0-255), and the sticks (16-bit, little-endian, y growing downward).
static void buildReport(AKHIDDevice *d, uint8_t r[kAKReportSize]) {
  static const uint8_t bitOf[16] = { [1] = 12, [2] = 13, [3] = 14, [4] = 15, [5] = 8, [6] = 9, [7] = 6, [8] = 7,
                                     [9] = 4, [10] = 5, [11] = 10, [12] = 0, [13] = 1, [14] = 2, [15] = 3 };
  memset(r, 0, kAKReportSize);
  r[1] = kAKReportSize;
  uint16_t buttons = 0;
  for (AKHIDElement *e in d->elements) {
    int64_t v = readElement(d, e);
    if (e->page == 9) {
      if (v && e->usage < 16) buttons |= (uint16_t)(1u << bitOf[e->usage]);
      continue;
    }
    int offset = e->usage == 0x30 ? 6 : e->usage == 0x31 ? 8 : e->usage == 0x33 ? 10 : e->usage == 0x34 ? 12 : 0;
    if (offset) { r[offset] = (uint8_t)(v & 0xff); r[offset + 1] = (uint8_t)((v >> 8) & 0xff); }
    else if (e->usage == 0x32) r[4] = (uint8_t)v;
    else if (e->usage == 0x35) r[5] = (uint8_t)v;
  }
  r[2] = (uint8_t)(buttons & 0xff);
  r[3] = (uint8_t)(buttons >> 8);
}

static void deliverReport(AKReportCallback *cb, AKHIDDevice *d, uint8_t *buffer, long length, const uint8_t r[kAKReportSize]) {
  long n = MIN(length, (long)kAKReportSize);
  if (n <= 0) return;
  memcpy(buffer, r, (size_t)n);
  if (cb->timed) cb->timed(cb->context, kAKIOReturnSuccess, (__bridge void *)d, 0, 0, buffer, n, mach_absolute_time());
  else cb->fn(cb->context, kAKIOReturnSuccess, (__bridge void *)d, 0, 0, buffer, n);   // type 0: an input report
}

// Its report, when it changed, to the device's report callback and the manager's.
static void sendReport(AKHIDDevice *d, AKReportCallback *managerReport) {
  BOOL toDevice = d->report.fn || d->report.timed, toManager = managerReport && (managerReport->fn || managerReport->timed);
  if (!toDevice && !toManager) return;
  uint8_t r[kAKReportSize];
  buildReport(d, r);
  if (toDevice && (!d->report.sent || memcmp(r, d->report.last, kAKReportSize))) {
    memcpy(d->report.last, r, kAKReportSize);
    d->report.sent = YES;
    deliverReport(&d->report, d, d->report.buffer, d->report.length, r);
  }
  if (toManager && (!d->scratchSent || memcmp(r, d->scratch, kAKReportSize))) {
    d->scratchSent = YES;
    deliverReport(managerReport, d, d->scratch, kAKReportSize, r);
  }
}

static void pollManager(AKHIDManager *m) {
  @autoreleasepool {
    NSArray<AKHIDDevice *> *now = connectedDevices();
    for (AKHIDDevice *d in now) {
      if (!matches(m, d) || [m->known containsObject:d]) continue;
      [m->known addObject:d];
      if (m->matched) m->matched(m->matchedContext, kAKIOReturnSuccess, (__bridge void *)m, (__bridge void *)d);
    }
    for (AKHIDDevice *d in [m->known copy]) {
      if ([now containsObject:d]) continue;
      [m->known removeObject:d];
      if (m->removed) m->removed(m->removedContext, kAKIOReturnSuccess, (__bridge void *)m, (__bridge void *)d);
      if (d->removed) d->removed(d->removedContext, kAKIOReturnSuccess, (__bridge void *)d);
    }
    for (AKHIDDevice *d in m->known) {
      sendChanges(d, &m->input);
      sendReport(d, &m->report);
    }
  }
}

static CFRunLoopTimerRef pollTimer(CFRunLoopRef loop, CFStringRef mode, dispatch_block_t poll) {
  CFRunLoopTimerRef t = CFRunLoopTimerCreateWithHandler(NULL, CFAbsoluteTimeGetCurrent(), 1.0 / 120, 0, 0,
                                                        ^(CFRunLoopTimerRef timer) { poll(); });
  CFRunLoopAddTimer(loop, t, mode ?: kCFRunLoopDefaultMode);
  return t;
}

static void stopTimer(CFRunLoopTimerRef *t) {
  if (!*t) return;
  CFRunLoopTimerInvalidate(*t);
  CFRelease(*t);
  *t = NULL;
}

#pragma mark The IOHID functions a game calls

#define MGR(ref) ((__bridge AKHIDManager *)(ref))
#define DEV(ref) ((__bridge AKHIDDevice *)(ref))
#define ELEM(ref) ((__bridge AKHIDElement *)(ref))
#define VAL(ref) ((__bridge AKHIDValue *)(ref))

static CFTypeID hidTypeID(void) { static CFTypeID t; if (!t) t = CFGetTypeID((__bridge CFTypeRef)[AKHIDValue new]); return t; }

static NSHashTable<AKHIDManager *> *gManagers;   // the game's, until it ends

static void *hManagerCreate(CFAllocatorRef a, uint32_t options) {
  AKHIDManager *m = [AKHIDManager new];
  m->known = [NSMutableArray array];
  @synchronized (AKHIDManager.class) {
    if (!gManagers) gManagers = [NSHashTable weakObjectsHashTable];
    [gManagers addObject:m];
  }
  hidLog(@"the game opened a HID manager; %lu controller(s) connected", (unsigned long)connectedDevices().count);
  return (void *)CFBridgingRetain(m);
}
static void hManagerSetDeviceMatching(void *m, CFDictionaryRef d) { MGR(m)->matching = d ? @[ (__bridge NSDictionary *)d ] : nil; }
static void hManagerSetDeviceMatchingMultiple(void *m, CFArrayRef a) { MGR(m)->matching = a ? [(__bridge NSArray *)a copy] : nil; }
static void hManagerRegisterDeviceMatchingCallback(void *m, AKHIDDeviceCallback cb, void *ctx) { MGR(m)->matched = cb; MGR(m)->matchedContext = ctx; }
static void hManagerRegisterDeviceRemovalCallback(void *m, AKHIDDeviceCallback cb, void *ctx) { MGR(m)->removed = cb; MGR(m)->removedContext = ctx; }
static void hManagerRegisterInputValueCallback(void *m, AKHIDValueCallback cb, void *ctx) { MGR(m)->input = (AKValueCallback){ cb, ctx }; }
static void hIgnore2(void *a, void *b) {}
static AKIOReturn hManagerOpen(void *m, uint32_t options) { return kAKIOReturnSuccess; }
static AKIOReturn hManagerClose(void *m, uint32_t options) {
  AKHIDManager *mgr = MGR(m);
  stopTimer(&mgr->timer);
  if (mgr->source) { dispatch_source_cancel(mgr->source); mgr->source = nil; }
  return kAKIOReturnSuccess;
}
static void hManagerSchedule(void *m, CFRunLoopRef loop, CFStringRef mode) {
  AKHIDManager *mgr = MGR(m);
  stopTimer(&mgr->timer);
  mgr->timer = pollTimer(loop, mode, ^{ pollManager(mgr); });
}
static void hManagerUnschedule(void *m, CFRunLoopRef loop, CFStringRef mode) { stopTimer(&MGR(m)->timer); }
static void hManagerSetDispatchQueue(void *m, dispatch_queue_t q) { MGR(m)->queue = q; }
static void hManagerActivate(void *m) {
  AKHIDManager *mgr = MGR(m);
  if (mgr->source || !mgr->queue) return;
  mgr->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, mgr->queue);
  dispatch_source_set_timer(mgr->source, DISPATCH_TIME_NOW, NSEC_PER_SEC / 120, NSEC_PER_MSEC);
  dispatch_source_set_event_handler(mgr->source, ^{ pollManager(mgr); });
  dispatch_resume(mgr->source);
}
static void hManagerCancel(void *m) { hManagerClose(m, 0); }
static CFSetRef hManagerCopyDevices(void *m) {
  NSMutableSet *set = [NSMutableSet set];
  for (AKHIDDevice *d in connectedDevices()) if (matches(MGR(m), d)) [set addObject:d];
  return set.count ? (CFSetRef)CFBridgingRetain(set) : NULL;
}
static CFTypeRef hManagerGetProperty(void *m, CFStringRef key) { return NULL; }
static Boolean hManagerSetProperty(void *m, CFStringRef key, CFTypeRef value) { return true; }

static AKIOReturn hDeviceOpen(void *d, uint32_t options) { return kAKIOReturnSuccess; }
static AKIOReturn hDeviceClose(void *d, uint32_t options) { stopTimer(&DEV(d)->timer); return kAKIOReturnSuccess; }
static CFTypeRef hDeviceGetProperty(void *d, CFStringRef key) { return (__bridge CFTypeRef)property(DEV(d), (__bridge NSString *)key); }
static Boolean hDeviceSetProperty(void *d, CFStringRef key, CFTypeRef value) { return true; }
static Boolean hDeviceConformsTo(void *d, uint32_t page, uint32_t usage) { return page == 1 && (usage == 4 || usage == 5); }
static uint32_t hDeviceGetService(void *d) { return 0; }

static CFArrayRef hDeviceCopyMatchingElements(void *d, CFDictionaryRef matching, uint32_t options) {
  NSDictionary *m = (__bridge NSDictionary *)matching;
  NSMutableArray *list = [NSMutableArray array];
  for (AKHIDElement *e in DEV(d)->elements) {
    if (m[@"UsagePage"] && [m[@"UsagePage"] unsignedIntValue] != e->page) continue;
    if (m[@"Usage"] && [m[@"Usage"] unsignedIntValue] != e->usage) continue;
    if (m[@"Type"] && [m[@"Type"] unsignedIntValue] != e->type) continue;
    if (m[@"ElementCookie"] && [m[@"ElementCookie"] unsignedIntValue] != e->cookie) continue;
    [list addObject:e];
  }
  return (CFArrayRef)CFBridgingRetain(list);
}

static AKIOReturn hDeviceGetValue(void *d, void *element, void **value) {
  AKHIDDevice *dev = DEV(d);
  NSUInteger i = [dev->elements indexOfObjectIdenticalTo:ELEM(element)];
  if (i == NSNotFound || !value) return kAKIOReturnUnsupported;
  AKHIDValue *v = dev->values[i];
  v->integer = readElement(dev, ELEM(element));
  v->time = mach_absolute_time();
  *value = (__bridge void *)v;
  return kAKIOReturnSuccess;
}
static AKIOReturn hDeviceGetValueWithOptions(void *d, void *element, void **value, uint32_t options) { return hDeviceGetValue(d, element, value); }
static AKIOReturn hDeviceSetValue(void *d, void *element, void *value) { return kAKIOReturnSuccess; }   // no outputs (rumble)
static AKIOReturn hDeviceReport(void *d, int type, long id, uint8_t *report, long length) { return kAKIOReturnUnsupported; }
static AKIOReturn hDeviceGetReport(void *d, int type, long id, uint8_t *report, long *length) { return kAKIOReturnUnsupported; }

static void hDeviceRegisterInputValueCallback(void *d, AKHIDValueCallback cb, void *ctx) { DEV(d)->input = (AKValueCallback){ cb, ctx }; }
// Input reports (Unity's Input System reads a gamepad as its reports).
static void hDeviceRegisterInputReportCallback(void *d, uint8_t *report, long length, AKHIDReportCallback cb, void *ctx) {
  DEV(d)->report = (AKReportCallback){ .fn = report ? cb : NULL, .context = ctx, .buffer = report, .length = length };
}
static void hDeviceRegisterInputReportTimeCallback(void *d, uint8_t *report, long length, AKHIDReportTimeCallback cb, void *ctx) {
  DEV(d)->report = (AKReportCallback){ .timed = report ? cb : NULL, .context = ctx, .buffer = report, .length = length };
}
static void hManagerRegisterInputReportCallback(void *m, AKHIDReportCallback cb, void *ctx) {
  MGR(m)->report = (AKReportCallback){ .fn = cb, .context = ctx };
}
static void hManagerRegisterInputReportTimeCallback(void *m, AKHIDReportTimeCallback cb, void *ctx) {
  MGR(m)->report = (AKReportCallback){ .timed = cb, .context = ctx };
}
static void hDeviceRegisterRemovalCallback(void *d, AKHIDCallback cb, void *ctx) { DEV(d)->removed = cb; DEV(d)->removedContext = ctx; }
static void hDeviceSchedule(void *d, CFRunLoopRef loop, CFStringRef mode) {
  AKHIDDevice *dev = DEV(d);
  stopTimer(&dev->timer);
  dev->timer = pollTimer(loop, mode, ^{ @autoreleasepool { sendChanges(dev, NULL); sendReport(dev, NULL); } });
}
static void hDeviceUnschedule(void *d, CFRunLoopRef loop, CFStringRef mode) { stopTimer(&DEV(d)->timer); }

static uint32_t hElementGetType(void *e) { return ELEM(e)->type; }
static uint32_t hElementGetUsagePage(void *e) { return ELEM(e)->page; }
static uint32_t hElementGetUsage(void *e) { return ELEM(e)->usage; }
static long hElementGetLogicalMin(void *e) { return (long)ELEM(e)->min; }
static long hElementGetLogicalMax(void *e) { return (long)ELEM(e)->max; }
static uint32_t hElementGetCookie(void *e) { return ELEM(e)->cookie; }
static void *hElementGetDevice(void *e) { return (__bridge void *)ELEM(e)->device; }
static void *hNull(void *e) { return NULL; }
static uint32_t hZero(void *e) { return 0; }
static uint32_t hOne(void *e) { return 1; }
static Boolean hFalse(void *e) { return false; }
static Boolean hTrue(void *e) { return true; }
static uint32_t hElementGetReportSize(void *e) { return ELEM(e)->type == kAKElementButton ? 1 : (ELEM(e)->max > 255 ? 16 : 8); }
static CFTypeRef hElementGetProperty(void *e, CFStringRef key) {
  AKHIDElement *el = ELEM(e);
  NSString *k = (__bridge NSString *)key;
  id v = el->properties[k];
  if (v) return (__bridge CFTypeRef)v;
  if ([k isEqualToString:@"UsagePage"]) return (__bridge CFTypeRef)@(el->page);
  if ([k isEqualToString:@"Usage"]) return (__bridge CFTypeRef)@(el->usage);
  if ([k isEqualToString:@"Min"]) return (__bridge CFTypeRef)@(el->min);
  if ([k isEqualToString:@"Max"]) return (__bridge CFTypeRef)@(el->max);
  if ([k isEqualToString:@"ElementCookie"]) return (__bridge CFTypeRef)@(el->cookie);
  return NULL;
}
static Boolean hElementSetProperty(void *e, CFStringRef key, CFTypeRef value) {
  AKHIDElement *el = ELEM(e);
  if (!el->properties) el->properties = [NSMutableDictionary dictionary];
  if (key && value) el->properties[(__bridge NSString *)key] = (__bridge id)value;
  return true;
}

static long hValueGetIntegerValue(void *v) { return (long)VAL(v)->integer; }
static void *hValueGetElement(void *v) { return (__bridge void *)VAL(v)->element; }
static uint64_t hValueGetTimeStamp(void *v) { return VAL(v)->time; }
static long hValueGetLength(void *v) { return sizeof(int64_t); }
static const uint8_t *hValueGetBytePtr(void *v) { return (const uint8_t *)&VAL(v)->integer; }
// Calibrated: into the element's calibration range when the game set one (else as physical),
// physical: the logical value (the element's physical range is its logical range).
static double hValueGetScaledValue(void *v, uint32_t type) {
  AKHIDValue *val = VAL(v);
  AKHIDElement *e = val->element;
  NSNumber *lo = e->properties[@"CalibrationMin"], *hi = e->properties[@"CalibrationMax"];
  if (type == 0 && lo && hi && e->max > e->min)
    return lo.doubleValue + (double)(val->integer - e->min) * (hi.doubleValue - lo.doubleValue) / (double)(e->max - e->min);
  return (double)val->integer;
}
static void *hValueCreateWithIntegerValue(CFAllocatorRef a, void *element, uint64_t time, long integer) {
  AKHIDValue *v = freshValue(ELEM(element), integer);
  v->time = time;
  return (void *)CFBridgingRetain(v);
}
static CFTypeID hTypeID(void) { return hidTypeID(); }

// Queues of element values (Unity's older input reads joysticks this way): each change of an
// element in the queue since it was added, oldest first; or, scheduled, a callback when there are.
@interface AKHIDQueue : NSObject {
@public
  __weak AKHIDDevice *device;
  NSMutableArray<AKHIDElement *> *elements;
  NSMutableArray<AKHIDValue *> *pending;
  int64_t last[64];
  long depth;
  BOOL started;
  AKHIDCallback available;
  void *availableContext;
  CFRunLoopTimerRef timer;
}
@end
@implementation AKHIDQueue
@end

#define QUEUE(ref) ((__bridge AKHIDQueue *)(ref))
static NSHashTable<AKHIDQueue *> *gQueues;   // the game's, until it ends

// The changes of its elements since it last looked, to the end of the queue (at most its depth).
static void fillQueue(AKHIDQueue *q) {
  AKHIDDevice *d = q->device;
  if (!d || !q->started) return;
  NSUInteger n = MIN(q->elements.count, 64u);
  for (NSUInteger i = 0; i < n; i++) {
    int64_t now = readElement(d, q->elements[i]);
    if (now == q->last[i]) continue;
    q->last[i] = now;
    if ((long)q->pending.count >= MAX(q->depth, 1)) [q->pending removeObjectAtIndex:0];
    [q->pending addObject:freshValue(q->elements[i], now)];
  }
}

static void *hQueueCreate(CFAllocatorRef a, void *device, long depth, uint32_t options) {
  AKHIDQueue *q = [AKHIDQueue new];
  q->device = DEV(device);
  q->elements = [NSMutableArray array];
  q->pending = [NSMutableArray array];
  q->depth = depth;
  @synchronized (AKHIDQueue.class) {
    if (!gQueues) gQueues = [NSHashTable weakObjectsHashTable];
    [gQueues addObject:q];
  }
  return (void *)CFBridgingRetain(q);
}
static void hQueueAddElement(void *q, void *e) {
  AKHIDQueue *queue = QUEUE(q);
  if ([queue->elements indexOfObjectIdenticalTo:ELEM(e)] != NSNotFound || queue->elements.count >= 64 || !queue->device) return;
  queue->last[queue->elements.count] = readElement(queue->device, ELEM(e));   // changes from now on
  [queue->elements addObject:ELEM(e)];
}
static void hQueueRemoveElement(void *q, void *e) {
  AKHIDQueue *queue = QUEUE(q);
  NSUInteger i = [queue->elements indexOfObjectIdenticalTo:ELEM(e)];
  if (i == NSNotFound) return;
  memmove(&queue->last[i], &queue->last[i + 1], sizeof(int64_t) * (queue->elements.count - i - 1));
  [queue->elements removeObjectAtIndex:i];
}
static Boolean hQueueContainsElement(void *q, void *e) { return [QUEUE(q)->elements indexOfObjectIdenticalTo:ELEM(e)] != NSNotFound; }
static void hQueueStart(void *q) { QUEUE(q)->started = YES; }
static void hQueueStop(void *q) { QUEUE(q)->started = NO; }
static void *hQueueCopyNextValue(void *q) {
  AKHIDQueue *queue = QUEUE(q);
  @autoreleasepool {
    if (!queue->pending.count) fillQueue(queue);
    if (!queue->pending.count) return NULL;
    AKHIDValue *v = queue->pending.firstObject;
    [queue->pending removeObjectAtIndex:0];
    return (void *)CFBridgingRetain(v);
  }
}
static void *hQueueCopyNextValueWithTimeout(void *q, double timeout) { return hQueueCopyNextValue(q); }
static void *hQueueGetDevice(void *q) { return (__bridge void *)QUEUE(q)->device; }
static long hQueueGetDepth(void *q) { return QUEUE(q)->depth; }
static void hQueueSetDepth(void *q, long depth) { QUEUE(q)->depth = depth; }
static void hQueueRegisterValueAvailableCallback(void *q, AKHIDCallback cb, void *ctx) {
  QUEUE(q)->available = cb;
  QUEUE(q)->availableContext = ctx;
}
static void hQueueSchedule(void *q, CFRunLoopRef loop, CFStringRef mode) {
  AKHIDQueue *queue = QUEUE(q);
  stopTimer(&queue->timer);
  __weak AKHIDQueue *weakQueue = queue;
  queue->timer = pollTimer(loop, mode, ^{
    AKHIDQueue *strong = weakQueue;
    if (!strong) return;
    @autoreleasepool { fillQueue(strong); }
    if (strong->pending.count && strong->available) strong->available(strong->availableContext, kAKIOReturnSuccess, (__bridge void *)strong);
  });
}
static void hQueueUnschedule(void *q, CFRunLoopRef loop, CFStringRef mode) { stopTimer(&QUEUE(q)->timer); }

#pragma mark Binding a game library's imports

static NSDictionary<NSString *, NSValue *> *bridge(void) {
  static NSDictionary *table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
#define F(name, fn) @"_" #name: [NSValue valueWithPointer:(const void *)fn]
    table = @{
      F(IOHIDManagerCreate, hManagerCreate), F(IOHIDManagerSetDeviceMatching, hManagerSetDeviceMatching),
      F(IOHIDManagerSetDeviceMatchingMultiple, hManagerSetDeviceMatchingMultiple),
      F(IOHIDManagerRegisterDeviceMatchingCallback, hManagerRegisterDeviceMatchingCallback),
      F(IOHIDManagerRegisterDeviceRemovalCallback, hManagerRegisterDeviceRemovalCallback),
      F(IOHIDManagerRegisterInputValueCallback, hManagerRegisterInputValueCallback),
      F(IOHIDManagerRegisterInputReportCallback, hManagerRegisterInputReportCallback),
      F(IOHIDManagerRegisterInputReportWithTimeStampCallback, hManagerRegisterInputReportTimeCallback),
      F(IOHIDManagerSetInputValueMatching, hIgnore2),
      F(IOHIDManagerSetInputValueMatchingMultiple, hIgnore2), F(IOHIDManagerOpen, hManagerOpen),
      F(IOHIDManagerClose, hManagerClose), F(IOHIDManagerScheduleWithRunLoop, hManagerSchedule),
      F(IOHIDManagerUnscheduleFromRunLoop, hManagerUnschedule), F(IOHIDManagerSetDispatchQueue, hManagerSetDispatchQueue),
      F(IOHIDManagerActivate, hManagerActivate), F(IOHIDManagerCancel, hManagerCancel),
      F(IOHIDManagerSetCancelHandler, hIgnore2), F(IOHIDManagerCopyDevices, hManagerCopyDevices),
      F(IOHIDManagerGetProperty, hManagerGetProperty), F(IOHIDManagerSetProperty, hManagerSetProperty),
      F(IOHIDManagerGetTypeID, hTypeID),
      F(IOHIDDeviceOpen, hDeviceOpen), F(IOHIDDeviceClose, hDeviceClose), F(IOHIDDeviceGetProperty, hDeviceGetProperty),
      F(IOHIDDeviceSetProperty, hDeviceSetProperty), F(IOHIDDeviceConformsTo, hDeviceConformsTo),
      F(IOHIDDeviceGetService, hDeviceGetService), F(IOHIDDeviceCopyMatchingElements, hDeviceCopyMatchingElements),
      F(IOHIDDeviceGetValue, hDeviceGetValue), F(IOHIDDeviceGetValueWithOptions, hDeviceGetValueWithOptions),
      F(IOHIDDeviceSetValue, hDeviceSetValue), F(IOHIDDeviceSetReport, hDeviceReport), F(IOHIDDeviceGetReport, hDeviceGetReport),
      F(IOHIDDeviceRegisterInputValueCallback, hDeviceRegisterInputValueCallback),
      F(IOHIDDeviceRegisterInputReportCallback, hDeviceRegisterInputReportCallback),
      F(IOHIDDeviceRegisterInputReportWithTimeStampCallback, hDeviceRegisterInputReportTimeCallback),
      F(IOHIDDeviceRegisterRemovalCallback, hDeviceRegisterRemovalCallback),
      F(IOHIDDeviceSetInputValueMatching, hIgnore2), F(IOHIDDeviceSetInputValueMatchingMultiple, hIgnore2),
      F(IOHIDDeviceScheduleWithRunLoop, hDeviceSchedule), F(IOHIDDeviceUnscheduleFromRunLoop, hDeviceUnschedule),
      F(IOHIDDeviceGetTypeID, hTypeID),
      F(IOHIDElementGetType, hElementGetType), F(IOHIDElementGetUsagePage, hElementGetUsagePage),
      F(IOHIDElementGetUsage, hElementGetUsage), F(IOHIDElementGetLogicalMin, hElementGetLogicalMin),
      F(IOHIDElementGetLogicalMax, hElementGetLogicalMax), F(IOHIDElementGetPhysicalMin, hElementGetLogicalMin),
      F(IOHIDElementGetPhysicalMax, hElementGetLogicalMax), F(IOHIDElementGetCookie, hElementGetCookie),
      F(IOHIDElementGetDevice, hElementGetDevice), F(IOHIDElementGetName, hNull), F(IOHIDElementGetParent, hNull),
      F(IOHIDElementGetChildren, hNull), F(IOHIDElementGetCollectionType, hZero), F(IOHIDElementGetReportID, hZero),
      F(IOHIDElementGetReportSize, hElementGetReportSize), F(IOHIDElementGetReportCount, hOne),
      F(IOHIDElementGetUnit, hZero), F(IOHIDElementGetUnitExponent, hZero), F(IOHIDElementIsArray, hFalse),
      F(IOHIDElementIsRelative, hFalse), F(IOHIDElementIsWrapping, hFalse), F(IOHIDElementIsNonLinear, hFalse),
      F(IOHIDElementIsVirtual, hFalse), F(IOHIDElementHasNullState, hFalse), F(IOHIDElementHasPreferredState, hTrue),
      F(IOHIDElementGetProperty, hElementGetProperty), F(IOHIDElementSetProperty, hElementSetProperty),
      F(IOHIDElementGetTypeID, hTypeID),
      F(IOHIDValueGetIntegerValue, hValueGetIntegerValue), F(IOHIDValueGetElement, hValueGetElement),
      F(IOHIDValueGetTimeStamp, hValueGetTimeStamp), F(IOHIDValueGetLength, hValueGetLength),
      F(IOHIDValueGetBytePtr, hValueGetBytePtr), F(IOHIDValueGetScaledValue, hValueGetScaledValue),
      F(IOHIDValueCreateWithIntegerValue, hValueCreateWithIntegerValue), F(IOHIDValueGetTypeID, hTypeID),
      F(IOHIDQueueCreate, hQueueCreate), F(IOHIDQueueAddElement, hQueueAddElement), F(IOHIDQueueRemoveElement, hQueueRemoveElement),
      F(IOHIDQueueContainsElement, hQueueContainsElement), F(IOHIDQueueStart, hQueueStart), F(IOHIDQueueStop, hQueueStop),
      F(IOHIDQueueCopyNextValue, hQueueCopyNextValue), F(IOHIDQueueCopyNextValueWithTimeout, hQueueCopyNextValueWithTimeout),
      F(IOHIDQueueGetDevice, hQueueGetDevice), F(IOHIDQueueGetDepth, hQueueGetDepth), F(IOHIDQueueSetDepth, hQueueSetDepth),
      F(IOHIDQueueRegisterValueAvailableCallback, hQueueRegisterValueAvailableCallback),
      F(IOHIDQueueScheduleWithRunLoop, hQueueSchedule), F(IOHIDQueueUnscheduleFromRunLoop, hQueueUnschedule),
      F(IOHIDQueueGetTypeID, hTypeID),
    };
#undef F
  });
  return table;
}

void AKGameBindControllers(const struct mach_header *header, intptr_t slide, const char *name) {
  NSDictionary<NSString *, NSValue *> *table = bridge();
  NSMutableSet<NSString *> *bridged = [NSMutableSet set], *other = [NSMutableSet set], *gc = [NSMutableSet set];
  int changed = AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (strncmp(symbol, "_IOHID", 6) == 0) {
      NSString *s = @(symbol);
      NSValue *to = table[s];
      [(to ? bridged : other) addObject:[s substringFromIndex:1]];
      return to.pointerValue;
    }
    if (strstr(symbol, "GCController")) [gc addObject:@(symbol + 1)];
    return NULL;
  });
  const char *base = strrchr(name, '/') ? strrchr(name, '/') + 1 : name;
  if (bridged.count || other.count)
    hidLog(@"%s reads controllers through IOKit HID: %d calls of %lu functions now answered from GameController%@", base,
           changed, (unsigned long)bridged.count,
           other.count ? [NSString stringWithFormat:@"; not answered: %@", [other.allObjects componentsJoinedByString:@", "]] : @"");
  if (gc.count) hidLog(@"%s uses GameController directly (%@)", base, [gc.allObjects componentsJoinedByString:@", "]);
}

// The game ended: its managers and devices stop polling and calling it back.
void AKGameControllersShutdown(void) {
  NSArray<AKHIDManager *> *managers;
  @synchronized (AKHIDManager.class) {
    managers = gManagers.allObjects;
    [gManagers removeAllObjects];
  }
  for (AKHIDManager *m in managers) {
    hManagerClose((__bridge void *)m, 0);
    m->matched = m->removed = NULL;
    m->input = (AKValueCallback){ NULL, NULL };
    m->report = (AKReportCallback){ 0 };
  }
  for (AKHIDDevice *d in connectedDevices()) {
    stopTimer(&d->timer);
    d->input = (AKValueCallback){ NULL, NULL };
    d->report = (AKReportCallback){ 0 };
    d->scratchSent = NO;
    d->removed = NULL;
  }
  NSArray<AKHIDQueue *> *queues;
  @synchronized (AKHIDQueue.class) {
    queues = gQueues.allObjects;
    [gQueues removeAllObjects];
  }
  for (AKHIDQueue *q in queues) {
    stopTimer(&q->timer);
    q->started = NO;
    q->available = NULL;
  }
}

#pragma mark Games that read GameController themselves

// A game that reads controllers through GameController (rather than IOKit HID above) holds the
// same GCController objects Steam's interface does. Its reads and handlers get the treatment the
// HID path gives: while Steam's overlay is over it the controller is at rest for it (reads are
// zero, its handlers aren't called), a button held as the overlay closes is up for it until let
// go (the A that chose Resume), Menu and View come as Steam lets them through (held back a
// moment, for the View + Menu chord) and Home is Steam's. Only calls from the game's own code are
// touched: Steam's interface reads the same objects.
static char kHeldKey;

static GCController *controllerOf(id element, int *which) {   // which: 1 Menu, 2 View, 3 Home, 0 other
  *which = 0;
  for (GCController *c in GCController.controllers) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (!g) continue;
    if (element == g.buttonMenu) { *which = 1; return c; }
    if (element == g.buttonOptions) { *which = 2; return c; }
    if (element == g.buttonHome) { *which = 3; return c; }
  }
  return nil;
}

// Whether the game sees this element at rest now; `down` is its real state.
static BOOL atRestForGame(id element, BOOL down) {
  if (AKGameOverlayShown()) return YES;
  if (objc_getAssociatedObject(element, &kHeldKey)) {
    if (down) return YES;
    objc_setAssociatedObject(element, &kHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return NO;
}

static void holdBackGameControllerElements(void) {
  for (GCController *c in GCController.controllers) {
    for (GCControllerElement *e in c.physicalInputProfile.allElements) {
      if ([e isKindOfClass:GCControllerButtonInput.class] && ((GCControllerButtonInput *)e).isPressed)
        objc_setAssociatedObject(e, &kHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
}

static NSMutableSet<NSValue *> *gHookedMethods;

static BOOL claimMethod(Method m) {
  if (!m) return NO;
  @synchronized (GCController.class) {
    if (!gHookedMethods) gHookedMethods = [NSMutableSet set];
    NSValue *key = [NSValue valueWithPointer:m];
    if ([gHookedMethods containsObject:key]) return NO;
    [gHookedMethods addObject:key];
  }
  return YES;
}

static void hookButtonClass(Class cls) {
  SEL valueSel = @selector(value), pressedSel = @selector(isPressed);
  Method value = class_getInstanceMethod(cls, valueSel), pressed = class_getInstanceMethod(cls, pressedSel);
  if (claimMethod(value)) {
    __block IMP orig = NULL;
    orig = method_setImplementation(value, imp_implementationWithBlock(^float(GCControllerButtonInput *self) {
      float v = ((float (*)(id, SEL))orig)(self, valueSel);
      if (!AKAddressIsInGame(__builtin_return_address(0))) return v;
      int which;
      GCController *c = controllerOf(self, &which);
      if (which == 3) return 0;
      if (which) return !AKGameOverlayShown() && AKControllerMenuViewPressed(c, which == 1) ? 1 : 0;
      return atRestForGame(self, v > 0.5f) ? 0 : v;
    }));
  }
  if (claimMethod(pressed)) {
    __block IMP orig = NULL;
    orig = method_setImplementation(pressed, imp_implementationWithBlock(^BOOL(GCControllerButtonInput *self) {
      BOOL p = ((BOOL (*)(id, SEL))orig)(self, pressedSel);
      if (!AKAddressIsInGame(__builtin_return_address(0))) return p;
      int which;
      GCController *c = controllerOf(self, &which);
      if (which == 3) return NO;
      if (which) return !AKGameOverlayShown() && AKControllerMenuViewPressed(c, which == 1);
      return atRestForGame(self, p) ? NO : p;
    }));
  }
}

static void hookAxisClass(Class cls) {
  SEL valueSel = @selector(value);
  Method value = class_getInstanceMethod(cls, valueSel);
  if (!claimMethod(value)) return;
  __block IMP orig = NULL;
  orig = method_setImplementation(value, imp_implementationWithBlock(^float(GCControllerAxisInput *self) {
    float v = ((float (*)(id, SEL))orig)(self, valueSel);
    return AKAddressIsInGame(__builtin_return_address(0)) && AKGameOverlayShown() ? 0 : v;
  }));
}

// Handlers the game sets are wrapped: not called while it should see the controller at rest (a
// button's release after the overlay closed included, as it never saw that press).
static void hookHandlerSetter(Class cls, SEL sel, id (^wrap)(id element, id handler)) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!claimMethod(m)) return;
  __block IMP orig = NULL;
  orig = method_setImplementation(m, imp_implementationWithBlock(^(id self, id handler) {
    if (handler && AKAddressIsInGame(__builtin_return_address(0))) handler = wrap(self, handler);
    ((void (*)(id, SEL, id))orig)(self, sel, handler);
  }));
}

static void hookElementClasses(Class button, Class axis, Class dpad) {
  if (button) {
    hookButtonClass(button);
    hookHandlerSetter(button, @selector(setValueChangedHandler:), ^id(id element, id handler) {
      GCControllerButtonValueChangedHandler h = handler;
      return ^(GCControllerButtonInput *b, float value, BOOL pressed) { if (!atRestForGame(b, pressed)) h(b, value, pressed); };
    });
    hookHandlerSetter(button, @selector(setPressedChangedHandler:), ^id(id element, id handler) {
      GCControllerButtonValueChangedHandler h = handler;
      return ^(GCControllerButtonInput *b, float value, BOOL pressed) { if (!atRestForGame(b, pressed)) h(b, value, pressed); };
    });
  }
  if (axis) {
    hookAxisClass(axis);
    hookHandlerSetter(axis, @selector(setValueChangedHandler:), ^id(id element, id handler) {
      GCControllerAxisValueChangedHandler h = handler;
      return ^(GCControllerAxisInput *a, float value) { if (!AKGameOverlayShown()) h(a, value); };
    });
  }
  if (dpad) {
    hookHandlerSetter(dpad, @selector(setValueChangedHandler:), ^id(id element, id handler) {
      GCControllerDirectionPadValueChangedHandler h = handler;
      return ^(GCControllerDirectionPad *d, float x, float y) { if (!AKGameOverlayShown()) h(d, x, y); };
    });
  }
}

static id wrapGamepadHandler(id element, GCExtendedGamepadValueChangedHandler h) {
  return ^(GCExtendedGamepad *g, GCControllerElement *e) {
    BOOL down = [e isKindOfClass:GCControllerButtonInput.class] && ((GCControllerButtonInput *)e).isPressed;
    if (!atRestForGame(e, down)) h(g, e);
  };
}

void AKGameWatchGameControllers(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    hookElementClasses(GCControllerButtonInput.class, GCControllerAxisInput.class, GCControllerDirectionPad.class);
    hookHandlerSetter(GCExtendedGamepad.class, @selector(setValueChangedHandler:), ^id(id element, id h) { return wrapGamepadHandler(element, h); });
    // A controller connected later may bring classes of its own.
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { AKGameWatchGameControllers(); }];
    hookHandlerSetter(GCPhysicalInputProfile.class, @selector(setValueDidChangeHandler:), ^id(id element, id handler) {
      void (^h)(GCPhysicalInputProfile *, GCControllerElement *) = handler;
      return ^(GCPhysicalInputProfile *p, GCControllerElement *e) {
        BOOL down = [e isKindOfClass:GCControllerButtonInput.class] && ((GCControllerButtonInput *)e).isPressed;
        if (!atRestForGame(e, down)) h(p, e);
      };
    });
  });
  // The concrete classes of the controllers connected now (GameController may use subclasses).
  for (GCController *c in GCController.controllers) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (!g) continue;
    hookElementClasses(object_getClass(g.buttonA), object_getClass(g.leftThumbstick.xAxis), object_getClass(g.dpad));
    hookHandlerSetter(object_getClass(g), @selector(setValueChangedHandler:), ^id(id element, id h) { return wrapGamepadHandler(element, h); });
  }
}
