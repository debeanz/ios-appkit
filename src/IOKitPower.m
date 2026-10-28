// System power notifications that an iOS app can't register for.
//
// Chromium's macOS power monitor (PowerMonitorDeviceSource, started from RunBrowser) calls
// IORegisterForSystemPower for sleep/wake events and then, unchecked, adds
// IONotificationPortGetRunLoopSource(port) to its run loop. iOS refuses the registration and
// leaves the port NULL, so the web helper crashed reading address 0x10. Sleep and wake don't
// reach an iOS app this way anyway (UIKit's lifecycle notifications cover them), so when the
// real call fails the shim hands back a working notification port that simply never fires,
// and likewise a do-nothing run loop source for the battery notifications. When the real
// calls succeed, their results pass straight through. IOKit is routed through the shim
// umbrella (which lists this code first), so the client binds here.
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdio.h>

// The iOS SDK ships no IOKit headers; these match IOKit's declarations.
typedef struct IONotificationPort *IONotificationPortRef;
typedef mach_port_t io_object_t;
typedef io_object_t io_connect_t;
typedef void (*IOServiceInterestCallback)(void *refcon, io_object_t service, uint32_t messageType, void *messageArgument);
typedef void (*IOPowerSourceCallbackType)(void *context);

io_connect_t IORegisterForSystemPower(void *refcon, IONotificationPortRef *thePortRef,
                                      IOServiceInterestCallback callback, io_object_t *notifier);
CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(IOPowerSourceCallbackType callback, void *context);

static void *realIOKit(const char *name) {
  static void *iokit;
  if (!iokit) iokit = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY);
  if (!iokit) iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
  return iokit ? dlsym(iokit, name) : NULL;
}

io_connect_t IORegisterForSystemPower(void *refcon, IONotificationPortRef *thePortRef,
                                      IOServiceInterestCallback callback, io_object_t *notifier) {
  io_connect_t (*real)(void *, IONotificationPortRef *, IOServiceInterestCallback, io_object_t *) =
      (io_connect_t (*)(void *, IONotificationPortRef *, IOServiceInterestCallback, io_object_t *))realIOKit("IORegisterForSystemPower");
  io_connect_t root = real ? real(refcon, thePortRef, callback, notifier) : MACH_PORT_NULL;
  if (root != MACH_PORT_NULL && thePortRef && *thePortRef) return root;

  // Refused: a real notification port with nothing registered on it, so the caller's
  // IONotificationPortGetRunLoopSource / IONotificationPortDestroy work as usual.
  IONotificationPortRef (*create)(mach_port_t) = (IONotificationPortRef (*)(mach_port_t))realIOKit("IONotificationPortCreate");
  if (thePortRef) *thePortRef = create ? create(MACH_PORT_NULL) : NULL;
  if (notifier) *notifier = MACH_PORT_NULL;
  static int told;
  if (!told++) fprintf(stderr, "[AppKitShim] IORegisterForSystemPower refused by iOS; gave the caller an idle notification port\n");
  return MACH_PORT_NULL;
}

static void noopPerform(void *info) {}

CFRunLoopSourceRef IOPSNotificationCreateRunLoopSource(IOPowerSourceCallbackType callback, void *context) {
  CFRunLoopSourceRef (*real)(IOPowerSourceCallbackType, void *) =
      (CFRunLoopSourceRef (*)(IOPowerSourceCallbackType, void *))realIOKit("IOPSNotificationCreateRunLoopSource");
  CFRunLoopSourceRef src = real ? real(callback, context) : NULL;
  if (src) return src;
  CFRunLoopSourceContext ctx = { .version = 0, .perform = noopPerform };
  return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
}
