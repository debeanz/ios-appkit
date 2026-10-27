// Fallback for a method a shim AppKit class doesn't implement yet: log it and return zero,
// rather than raise "unrecognized selector sent to instance" (which aborts). See the
// AK_UNIMPLEMENTED_FORWARDER macro in AKShimPrivate.h. This is a diagnostic aid while the
// shim grows — each logged line names a method some client (SDL3, steamui, CEF) actually
// calls at runtime, which no static symbol list captures. The honest fix for each is to
// implement it; until then a zero return is what most AppKit calls can tolerate.
#import "AKShimPrivate.h"
#import <objc/runtime.h>
#import <os/lock.h>

// A generic signature so forwardInvocation: is reached: return and every argument are
// pointer-sized (id). Correct for the void / object / BOOL / NSInteger returns that are the
// common case; a method with a struct or floating-point return should be implemented for
// real rather than left to the forwarder.
NSMethodSignature *AKGenericSignatureForSelector(SEL sel) {
  const char *name = sel_getName(sel);
  NSUInteger args = 0;
  for (const char *c = name; *c; c++) if (*c == ':') args++;
  NSMutableString *types = [NSMutableString stringWithString:@"@@:"];  // return, self, _cmd
  for (NSUInteger i = 0; i < args; i++) [types appendString:@"@"];
  return [NSMethodSignature signatureWithObjCTypes:types.UTF8String];
}

void AKLogUnimplemented(id obj, SEL sel) {
  // Log each class+selector once, so a method called every frame doesn't flood the log.
  static CFMutableSetRef seen;
  static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
  const char *cls = object_getClassName(obj);
  const char *name = sel_getName(sel);
  char key[512];
  snprintf(key, sizeof key, "%s %s", cls, name);

  os_unfair_lock_lock(&lock);
  if (!seen) seen = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
  CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  BOOL first = k && !CFSetContainsValue(seen, k);
  if (first) CFSetAddValue(seen, k);
  if (k) CFRelease(k);
  os_unfair_lock_unlock(&lock);

  if (first) fprintf(stderr, "[AppKitShim] unimplemented: -[%s %s]\n", cls, name);
}
