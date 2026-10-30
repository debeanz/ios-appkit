// Fallback for a method a shim AppKit class doesn't implement yet: log it and return zero,
// rather than raise "unrecognized selector sent to instance" (which aborts). See the
// AK_UNIMPLEMENTED_FORWARDER macro in AKShimPrivate.h. This is a diagnostic aid while the
// shim grows — each logged line names a method some client (SDL3, steamui, CEF) actually
// calls at runtime, which no static symbol list captures. The honest fix for each is to
// implement it; until then a zero return is what most AppKit calls can tolerate.
#import "AKShimPrivate.h"
#import <dlfcn.h>
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

// macOS's own type encodings for the methods of the shim's classes that return a struct or a
// floating-point value (tools/mac-methods.m writes them next to the shim at build time): with
// the real signature the zero returned lands where the caller reads it (d0-d3 for an NSRect, d0
// for a CGFloat), not in x0 with garbage left where it looks.
//   "<Class> -<selector> <types>" and "^ <Class> <its superclass>", as on macOS.
static NSDictionary<NSString *, NSString *> *gMacTypes, *gMacSupers;

static void loadMacTypes(void) {
  Dl_info info;
  if (!dladdr((const void *)loadMacTypes, &info) || !info.dli_fname) return;
  NSString *path = [@(info.dli_fname).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"mac-method-types.txt"];
  NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  NSMutableDictionary *types = [NSMutableDictionary dictionary], *supers = [NSMutableDictionary dictionary];
  for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
    NSArray<NSString *> *f = [line componentsSeparatedByString:@" "];
    if (f.count == 3 && [f[0] isEqualToString:@"^"]) supers[f[1]] = f[2];
    else if (f.count == 3) types[[NSString stringWithFormat:@"%@ %@", f[0], f[1]]] = f[2];
  }
  gMacTypes = types;
  gMacSupers = supers;
}

// The shim class a receiver's class is (a game's NSWindow subclass is an NSWindow), under its
// AppKit name, then up macOS's lineage.
static const char *macTypes(Class cls, SEL sel, BOOL classMethod) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{ loadMacTypes(); });
  if (!gMacTypes.count) return NULL;
  for (Class c = cls; c; c = class_getSuperclass(c)) {
    NSString *name = @(class_getName(c));
    if ([name isEqualToString:@"AKShimFont"]) name = @"NSFont";
    else if ([name hasPrefix:@"AKShim_"]) name = [name substringFromIndex:7];
    for (NSString *n = name; n; n = gMacSupers[n]) {
      NSString *types = gMacTypes[[NSString stringWithFormat:@"%@ %c%s", n, classMethod ? '+' : '-', sel_getName(sel)]];
      if (types) return types.UTF8String;
    }
  }
  return NULL;
}

NSMethodSignature *AKFallbackSignature(id receiver, SEL sel, BOOL classMethod) {
  const char *types = macTypes(classMethod ? (Class)receiver : object_getClass(receiver), sel, classMethod);
  if (types) {
    @try {
      NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:types];
      if (sig) return sig;
    } @catch (NSException *e) {
    }
  }
  return AKGenericSignatureForSelector(sel);
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
