// IOKit HID for the Mac games Steam starts, answered from GameController. A Mac game reads
// gamepads through IOHIDManager (GameMaker's libYoYoGamepad, SDL2); on iOS a Bluetooth
// controller reaches an app only through GameController, and IOKit's HID manager shows none. So
// the IOHID* imports of a game's own libraries are pointed here (Steam's aren't): each connected
// controller with a gamepad profile is a wired Xbox 360 controller — the layout Mac gamepad
// mapping databases know (SDL's "X360 Controller": 15 buttons, A B X Y LB RB LS RS Start Back
// Guide and the d-pad; sticks on X/Y and Rx/Ry, triggers on Z and Rz) — whose values are read
// from GameController when the game asks, and sent to its input callbacks as they change.
#import "AKShimPrivate.h"
#import <GameController/GameController.h>
#import <mach/mach_time.h>

typedef int32_t AKIOReturn;
enum { kAKIOReturnSuccess = 0, kAKIOReturnUnsupported = (int32_t)0xe00002c7 };
enum { kAKElementMisc = 1, kAKElementButton = 2, kAKElementAxis = 3 };
typedef void (*AKHIDDeviceCallback)(void *context, AKIOReturn result, void *sender, void *device);
typedef void (*AKHIDValueCallback)(void *context, AKIOReturn result, void *sender, void *value);
typedef void (*AKHIDCallback)(void *context, AKIOReturn result, void *sender);

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
  AKHIDCallback removed;
  void *removedContext;
  CFRunLoopTimerRef timer;                // when scheduled on its own
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
static int64_t readElement(AKHIDDevice *d, AKHIDElement *e) {
  GCExtendedGamepad *g = d->controller.extendedGamepad;
  // With Steam's overlay over the game, the controller drives Steam: the game sees it at rest.
  if (!g || AKGameOverlayShown()) return 0;
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
    for (AKHIDDevice *d in m->known) sendChanges(d, &m->input);
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

static void *hManagerCreate(CFAllocatorRef a, uint32_t options) {
  AKHIDManager *m = [AKHIDManager new];
  m->known = [NSMutableArray array];
  hidLog(@"the game opened a HID manager; %lu controller(s) connected", (unsigned long)connectedDevices().count);
  return (void *)CFBridgingRetain(m);
}
static void hManagerSetDeviceMatching(void *m, CFDictionaryRef d) { MGR(m)->matching = d ? @[ (__bridge NSDictionary *)d ] : nil; }
static void hManagerSetDeviceMatchingMultiple(void *m, CFArrayRef a) { MGR(m)->matching = a ? [(__bridge NSArray *)a copy] : nil; }
static void hManagerRegisterDeviceMatchingCallback(void *m, AKHIDDeviceCallback cb, void *ctx) { MGR(m)->matched = cb; MGR(m)->matchedContext = ctx; }
static void hManagerRegisterDeviceRemovalCallback(void *m, AKHIDDeviceCallback cb, void *ctx) { MGR(m)->removed = cb; MGR(m)->removedContext = ctx; }
static void hManagerRegisterInputValueCallback(void *m, AKHIDValueCallback cb, void *ctx) { MGR(m)->input = (AKValueCallback){ cb, ctx }; }
static void hIgnore2(void *a, void *b) {}
static void hIgnore3(void *a, void *b, void *c) {}
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
static void hDeviceRegisterRemovalCallback(void *d, AKHIDCallback cb, void *ctx) { DEV(d)->removed = cb; DEV(d)->removedContext = ctx; }
static void hDeviceSchedule(void *d, CFRunLoopRef loop, CFStringRef mode) {
  AKHIDDevice *dev = DEV(d);
  stopTimer(&dev->timer);
  dev->timer = pollTimer(loop, mode, ^{ @autoreleasepool { sendChanges(dev, NULL); } });
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
      F(IOHIDManagerRegisterInputReportCallback, hIgnore3), F(IOHIDManagerSetInputValueMatching, hIgnore2),
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
      F(IOHIDDeviceRegisterInputReportCallback, hIgnore3), F(IOHIDDeviceRegisterRemovalCallback, hDeviceRegisterRemovalCallback),
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
