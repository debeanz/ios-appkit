// Fallback for a method a shim AppKit class doesn't implement yet: log it and return zero,
// rather than raise "unrecognized selector sent to instance" (which aborts). See the
// AK_UNIMPLEMENTED_FORWARDER macro in AKShimPrivate.h. This is a diagnostic aid while the
// shim grows — each logged line names a method some client (SDL3, steamui, CEF) actually
// calls at runtime, which no static symbol list captures. The honest fix for each is to
// implement it; until then a zero return is what most AppKit calls can tolerate.
#import "AKShimPrivate.h"
#import <dlfcn.h>
#import <execinfo.h>
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
  char kind = object_isClass(obj) ? '+' : '-';
  char key[512];
  snprintf(key, sizeof key, "%c%s %s", kind, cls, name);

  os_unfair_lock_lock(&lock);
  if (!seen) seen = CFSetCreateMutable(NULL, 0, &kCFTypeSetCallBacks);
  CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
  BOOL first = k && !CFSetContainsValue(seen, k);
  if (first) CFSetAddValue(seen, k);
  if (k) CFRelease(k);
  os_unfair_lock_unlock(&lock);

  if (first) fprintf(stderr, "[AppKitShim] unimplemented: %c[%s %s]\n", kind, cls, name);
}

// Every shim class answers a method it lacks this way, its class methods too: the macros cover
// the classes that opted in, and this the rest, as the shim loads. A game sends what its engine
// was built against, and the first message the shim had no method for ended the game (Unity's
// start-up sends +[NSWindow setAllowsAutomaticWindowTabbing:]). Only the shim's own lineages get
// it - classes whose superclass is NSObject, not its UIKit and Core Animation subclasses, nor its
// own helpers (AK..., but AKShim_ classes stand for Mac ones). class_addMethod leaves a class that
// defines the method itself (AK_UNIMPLEMENTED_FORWARDER) as it is.
static IMP gObjectSignature, gClassSignature;

static NSMethodSignature *shimSignature(id self, SEL _cmd, SEL sel) {
  NSMethodSignature *sig = ((NSMethodSignature * (*)(id, SEL, SEL))gObjectSignature)(self, _cmd, sel);
  return sig ?: AKFallbackSignature(self, sel, NO);
}

static NSMethodSignature *shimClassSignature(id self, SEL _cmd, SEL sel) {
  NSMethodSignature *sig = ((NSMethodSignature * (*)(id, SEL, SEL))gClassSignature)(self, _cmd, sel);
  return sig ?: AKFallbackSignature(self, sel, YES);
}

static void shimForward(id self, SEL _cmd, NSInvocation *invocation) {
  AKLogUnimplemented(self, invocation.selector);
  NSUInteger len = invocation.methodSignature.methodReturnLength;
  if (len) { void *zero = calloc(1, len); [invocation setReturnValue:zero]; free(zero); }
}

// A game's messages to iOS's own classes, too: one with no method there - a Mac-only method of a
// class iOS also has (AppKit's additions to NSString, NSBundle, NSValue...) - is logged and returns
// zero rather than ending the game. Only for the game: its main thread, or a message its code sent
// (the forwarding machinery's caller, a few frames up). Steam's messages raise as on iOS.
static IMP gObjectForward, gClassForward;

static BOOL sentByGame(void) {
  if (AKIsGameThread()) return YES;
  void *frames[8];
  int n = backtrace(frames, 8);
  for (int i = 1; i < n; i++) if (AKAddressIsInGame(frames[i])) return YES;
  return NO;
}

static NSMethodSignature *gameSignature(id self, SEL _cmd, SEL sel) {
  NSMethodSignature *sig = ((NSMethodSignature * (*)(id, SEL, SEL))gObjectSignature)(self, _cmd, sel);
  return sig || !AKGameIsRunning() || !sentByGame() ? sig : AKFallbackSignature(self, sel, NO);
}

static NSMethodSignature *gameClassSignature(id self, SEL _cmd, SEL sel) {
  NSMethodSignature *sig = ((NSMethodSignature * (*)(id, SEL, SEL))gClassSignature)(self, _cmd, sel);
  return sig || !AKGameIsRunning() || !sentByGame() ? sig : AKFallbackSignature(self, sel, YES);
}

static void gameForward(id self, SEL _cmd, NSInvocation *invocation) {
  if (AKGameIsRunning() && ![self respondsToSelector:invocation.selector] && sentByGame()) shimForward(self, _cmd, invocation);
  else ((void (*)(id, SEL, NSInvocation *))gObjectForward)(self, _cmd, invocation);
}

static void gameClassForward(id self, SEL _cmd, NSInvocation *invocation) {
  if (AKGameIsRunning() && ![self respondsToSelector:invocation.selector] && sentByGame()) shimForward(self, _cmd, invocation);
  else ((void (*)(id, SEL, NSInvocation *))gClassForward)(self, _cmd, invocation);
}

__attribute__((constructor)) static void forwardEveryShimClass(void) {
  Dl_info info;
  if (!dladdr((const void *)forwardEveryShimClass, &info) || !info.dli_fname) return;
  Class object = NSObject.class, objectMeta = object_getClass(object);
  SEL signature = @selector(methodSignatureForSelector:), forward = @selector(forwardInvocation:);
  gObjectSignature = method_setImplementation(class_getInstanceMethod(object, signature), (IMP)gameSignature);
  gClassSignature = method_setImplementation(class_getInstanceMethod(objectMeta, signature), (IMP)gameClassSignature);
  gObjectForward = method_setImplementation(class_getInstanceMethod(object, forward), (IMP)gameForward);
  gClassForward = method_setImplementation(class_getInstanceMethod(objectMeta, forward), (IMP)gameClassForward);
  unsigned count = 0;
  const char **names = objc_copyClassNamesForImage(info.dli_fname, &count);
  for (unsigned i = 0; i < count; i++) {
    if (!strncmp(names[i], "AK", 2) && strncmp(names[i], "AKShim", 6)) continue;
    Class cls = objc_getClass(names[i]);
    if (!cls || class_getSuperclass(cls) != object) continue;
    Class meta = object_getClass(cls);
    class_addMethod(cls, signature, (IMP)shimSignature, "@@::");
    class_addMethod(cls, forward, (IMP)shimForward, "v@:@");
    class_addMethod(meta, signature, (IMP)shimClassSignature, "@@::");
    class_addMethod(meta, forward, (IMP)shimForward, "v@:@");
  }
  free(names);
}
