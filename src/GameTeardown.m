// What ends with a Mac game Steam started, as it would with its process on a Mac.
//
// iOS starts no processes for an app, so a game runs in this one (MacPrograms.m), and when it
// ends nothing takes back what it had: its heap, its threads, its graphics memory, its sound, and
// the callbacks the app and the system hold into its code. So, for any game:
//  - its own libraries allocate from a malloc zone of their own (their malloc family is pointed
//    there as each loads, AKGameBindProcess); exit handlers they register, which the app would
//    only run at its own exit over a heap long gone, stay unregistered;
//  - the Objective-C objects of its classes are noted as they are made, and the Metal buffers,
//    textures, heaps and command queues its code makes (its own Metal, or MoltenVK's for Vulkan);
//  - at its end (AKGameTeardown, main thread): whatever would call into it lets go (sound of any
//    kind - the audio session stops all of it -, controllers through IOKit or GameController,
//    display links, dispatch sources, notification observers); every thread with its code on
//    the stack is stopped; its objects let go of what they hold; its OpenGL contexts and the
//    Metal objects it made and left are freed; its classes' methods are made to do nothing (an
//    object of its left somewhere can't run its code over freed memory); and then its zone is
//    destroyed: everything it allocated, at once. A thread that can't be stopped safely keeps
//    the heap (logged).
// A later launch of the same game gets a new zone and its classes' methods back.
#import "AKShimPrivate.h"
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

typedef struct { uintptr_t start, end; } ak_text;

static void teardownLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void teardownLog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[AppKitShim] game: %s\n", line.UTF8String);
}

#pragma mark Its heap

static malloc_zone_t *gZone;   // the running game's

void AKGameHeapBegin(NSString *name) {
  gZone = malloc_create_zone(0, 0);
  malloc_set_zone_name(gZone, [name stringByAppendingString:@" (Mac game)"].UTF8String);
}

static void *gameMalloc(size_t n) { return gZone ? malloc_zone_malloc(gZone, n) : malloc(n); }
static void *gameCalloc(size_t count, size_t n) { return gZone ? malloc_zone_calloc(gZone, count, n) : calloc(count, n); }
static void *gameValloc(size_t n) { return gZone ? malloc_zone_valloc(gZone, n) : valloc(n); }

// A block from elsewhere (strdup inside libc, a system API's buffer) is resized where it lives.
static void *gameRealloc(void *p, size_t n) {
  if (!p) return gameMalloc(n);
  if (gZone && malloc_zone_from_ptr(p) == gZone) return malloc_zone_realloc(gZone, p, n);
  return realloc(p, n);
}

static void *gameReallocf(void *p, size_t n) {
  void *q = gameRealloc(p, n);
  if (!q && n) free(p);
  return q;
}

static int gamePosixMemalign(void **out, size_t align, size_t n) {
  if (!gZone) return posix_memalign(out, align, n);
  if (align < sizeof(void *) || (align & (align - 1))) return EINVAL;
  void *p = malloc_zone_memalign(gZone, align, n);
  if (!p) return ENOMEM;
  *out = p;
  return 0;
}

static void *gameAlignedAlloc(size_t align, size_t n) {
  return gZone ? malloc_zone_memalign(gZone, MAX(align, sizeof(void *)), n) : aligned_alloc(align, n);
}

static char *gameStrdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *d = gameMalloc(n);
  if (d) memcpy(d, s, n);
  return d;
}

static char *gameStrndup(const char *s, size_t max) {
  size_t n = strnlen(s, max);
  char *d = gameMalloc(n + 1);
  if (d) { memcpy(d, s, n); d[n] = 0; }
  return d;
}

static int gExitHandlers;
static int gameCxaAtexit(void (*fn)(void *), void *arg, void *dso) { gExitHandlers++; return 0; }
static int gameAtexit(void (*fn)(void)) { gExitHandlers++; return 0; }

// Its dispatch sources (timers and the like, on queues of its own or the system's).
static NSHashTable *gSources;

static dispatch_source_t gameSourceCreate(dispatch_source_type_t type, uintptr_t handle, uintptr_t mask, dispatch_queue_t queue) {
  dispatch_source_t s = dispatch_source_create(type, handle, mask, queue);
  if (s) @synchronized (NSHashTable.class) {
    if (!gSources) gSources = [NSHashTable weakObjectsHashTable];
    [gSources addObject:s];
  }
  return s;
}

void AKGameBindProcess(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    static const struct { const char *name; void *fn; } table[] = {
      { "_malloc", (void *)gameMalloc }, { "_calloc", (void *)gameCalloc }, { "_valloc", (void *)gameValloc },
      { "_realloc", (void *)gameRealloc }, { "_reallocf", (void *)gameReallocf },
      { "_posix_memalign", (void *)gamePosixMemalign }, { "_aligned_alloc", (void *)gameAlignedAlloc },
      { "_strdup", (void *)gameStrdup }, { "_strndup", (void *)gameStrndup },
      { "___cxa_atexit", (void *)gameCxaAtexit }, { "_atexit", (void *)gameAtexit },
      { "_dispatch_source_create", (void *)gameSourceCreate },
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
      if (!strcmp(symbol, table[i].name)) return table[i].fn;
    return NULL;
  });
}

#pragma mark Its objects

static NSHashTable *gInstances;   // objects of its classes, as they are made

static void noteInstance(id o) {
  if (!o) return;
  @synchronized (NSHashTable.class) {
    if (!gInstances) gInstances = [NSHashTable weakObjectsHashTable];
    [gInstances addObject:o];
  }
}

// +alloc and +allocWithZone: of each of its classes note what they make.
static void trackClass(Class cls) {
  Class meta = object_getClass(cls);
  Method alloc = class_getClassMethod(cls, @selector(alloc));
  Method allocZone = class_getClassMethod(cls, @selector(allocWithZone:));
  if (alloc) {
    IMP orig = method_getImplementation(alloc);
    IMP mine = imp_implementationWithBlock(^id(Class c) {
      id o = ((id (*)(Class, SEL))orig)(c, @selector(alloc));
      noteInstance(o);
      return o;
    });
    if (!class_addMethod(meta, @selector(alloc), mine, method_getTypeEncoding(alloc))) method_setImplementation(alloc, mine);
  }
  if (allocZone) {
    IMP orig = method_getImplementation(allocZone);
    IMP mine = imp_implementationWithBlock(^id(Class c, void *zone) {
      id o = ((id (*)(Class, SEL, void *))orig)(c, @selector(allocWithZone:), zone);
      noteInstance(o);
      return o;
    });
    if (!class_addMethod(meta, @selector(allocWithZone:), mine, method_getTypeEncoding(allocZone))) method_setImplementation(allocZone, mine);
  }
}

static void imageLoaded(const struct mach_header *header) {
  static NSMutableSet<NSValue *> *tracked;
  @synchronized (NSHashTable.class) {
    if (!tracked) tracked = [NSMutableSet set];
    NSValue *key = [NSValue valueWithPointer:header];
    if ([tracked containsObject:key] || !AKHeaderIsGameImage(header)) return;
    [tracked addObject:key];
  }
  Dl_info info;
  if (!dladdr(header, &info) || !info.dli_fname) return;
  unsigned count = 0;
  const char **names = objc_copyClassNamesForImage(info.dli_fname, &count);
  for (unsigned i = 0; i < count; i++) {
    Class c = objc_getClass(names[i]);
    if (c) trackClass(c);
  }
  free(names);
}

static BOOL isGameClass(Class c, NSArray<NSString *> *images) {
  const char *image = class_getImageName(c);
  return image && [images containsObject:@(image)];
}

// Its objects let go of the objects they hold (strong instance variables of its own classes; one
// whose memory management isn't known is left as it is).
static NSUInteger releaseInstanceVariables(NSArray<NSString *> *images) {
  NSArray *objects;
  @synchronized (NSHashTable.class) { objects = gInstances.allObjects; [gInstances removeAllObjects]; }
  for (id o in objects) {
    for (Class c = object_getClass(o); c; c = class_getSuperclass(c)) {
      if (!isGameClass(c, images)) continue;
      unsigned n = 0;
      Ivar *ivars = class_copyIvarList(c, &n);
      for (unsigned i = 0; i < n; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == '@') object_setIvar(o, ivars[i], nil);
      }
      free(ivars);
    }
  }
  return objects.count;
}

#pragma mark Its Metal objects

// Metal buffers, textures, heaps and command queues made by its code (Metal directly, or
// MoltenVK for Vulkan), in the order made. Nothing of the game is left to hold them at its end.
static NSPointerArray *gMetal;
static NSMutableSet<NSString *> *gHooked;

static void hookMaker(Class cls, SEL sel);

static void noteMetal(id made) {
  @synchronized (NSHashTable.class) {
    if (!gMetal) gMetal = [NSPointerArray weakObjectsPointerArray];
    [gMetal addPointer:(__bridge void *)made];
  }
  // What those make in turn: buffers and textures from a heap, textures from a buffer, views.
  Class c = object_getClass(made);
  hookMaker(c, @selector(newBufferWithLength:options:));
  hookMaker(c, @selector(newTextureWithDescriptor:));
  hookMaker(c, @selector(newTextureWithDescriptor:offset:bytesPerRow:));
  hookMaker(c, @selector(newTextureViewWithPixelFormat:));
}

// A method that returns a new object (+1): every argument these take is an integer or a
// pointer, so one shape forwards them all.
static void hookMaker(Class cls, SEL sel) {
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) return;
  NSString *key = [NSString stringWithFormat:@"%p %s", (void *)m, sel_getName(sel)];
  @synchronized (NSHashTable.class) {
    if (!gHooked) gHooked = [NSMutableSet set];
    if ([gHooked containsObject:key]) return;
    [gHooked addObject:key];
  }
  __block IMP orig = NULL;
  IMP mine = imp_implementationWithBlock(^id(id self, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t d) {
    id made = ((id (*)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t))orig)(self, sel, a, b, c, d);
    if (made && AKAddressIsInGame(__builtin_return_address(0))) noteMetal(made);
    return made;
  });
  orig = method_setImplementation(m, mine);
}

static void hookMetal(void) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (!device) return;
  Class c = object_getClass(device);
  for (NSString *name in @[ @"newBufferWithLength:options:", @"newBufferWithBytes:length:options:",
                            @"newBufferWithBytesNoCopy:length:options:deallocator:", @"newTextureWithDescriptor:",
                            @"newTextureWithDescriptor:iosurface:plane:", @"newHeapWithDescriptor:", @"newCommandQueue",
                            @"newCommandQueueWithMaxCommandBufferCount:" ])
    hookMaker(c, NSSelectorFromString(name));
}

// The ones still alive, newest first (a texture before the heap it came from), each let go of
// by every reference left: those were the game's.
static NSUInteger freeMetal(void) {
  NSPointerArray *made;
  @synchronized (NSHashTable.class) { made = gMetal; gMetal = nil; }
  NSUInteger freed = 0;
  for (NSInteger i = (NSInteger)made.count - 1; i >= 0; i--) {
    @autoreleasepool {
      id o = (__bridge id)[made pointerAtIndex:(NSUInteger)i];
      if (!o) continue;
      CFTypeRef ref = (__bridge CFTypeRef)o;
      CFIndex left = CFGetRetainCount(ref) - 1;   // less this reference
      for (CFIndex k = 0; k < left; k++) CFRelease(ref);
      freed++;
    }
  }
  return freed;
}

#pragma mark What calls into it

// Its notification observers (the caller is its code), removed at its end.
static NSHashTable *gObservers;
static IMP gAddObserver, gAddObserverBlock;

static void noteObserver(id observer) {
  if (!observer) return;
  @synchronized (NSHashTable.class) {
    if (!gObservers) gObservers = [NSHashTable weakObjectsHashTable];
    [gObservers addObject:observer];
  }
}

static void addObserver(id self, SEL _cmd, id observer, SEL sel, NSNotificationName name, id object) {
  if (AKAddressIsInGame(__builtin_return_address(0))) noteObserver(observer);
  ((void (*)(id, SEL, id, SEL, NSNotificationName, id))gAddObserver)(self, _cmd, observer, sel, name, object);
}

static id addObserverBlock(id self, SEL _cmd, NSNotificationName name, id object, NSOperationQueue *queue, void (^block)(NSNotification *)) {
  id token = ((id (*)(id, SEL, NSNotificationName, id, NSOperationQueue *, id))gAddObserverBlock)(self, _cmd, name, object, queue, block);
  if (AKAddressIsInGame(__builtin_return_address(0))) noteObserver(token);
  return token;
}

void AKGameWatchProcess(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Class c = NSNotificationCenter.class;
    gAddObserver = method_setImplementation(class_getInstanceMethod(c, @selector(addObserver:selector:name:object:)), (IMP)addObserver);
    gAddObserverBlock = method_setImplementation(class_getInstanceMethod(c, @selector(addObserverForName:object:queue:usingBlock:)),
                                                 (IMP)addObserverBlock);
    // The runtime calls this as each image's classes are ready (not in the SDK's headers; the
    // launch also calls AKGameTrackClasses once its program is loaded).
    void (*addLoadImageCallback)(void (*)(const struct mach_header *)) =
        (void (*)(void (*)(const struct mach_header *)))dlsym(RTLD_DEFAULT, "objc_addLoadImageCallback");
    if (addLoadImageCallback) addLoadImageCallback(imageLoaded);
    hookMetal();
  });
}

// The game's images loaded so far, their classes noted (again harmless: each image once).
void AKGameTrackClasses(void) {
  for (uint32_t i = 0; i < _dyld_image_count(); i++) imageLoaded(_dyld_get_image_header(i));
}

BOOL AKBlockIsDeadGameCode(id block) {
  if (!block) return NO;
  void *invoke = ((void **)(__bridge void *)block)[2];   // Block_layout: isa, flags+reserved, invoke
  return AKAddressIsDeadGameCode(invoke);
}

// Handlers its code set on controllers, keyboards and mice (GameController), taken off.
static NSUInteger clearControllerHandlers(void) {
  static NSArray<NSString *> *keys;
  if (!keys) keys = @[ @"valueChangedHandler", @"pressedChangedHandler", @"touchedChangedHandler", @"valueDidChangeHandler",
                       @"keyChangedHandler", @"mouseMovedHandler", @"controllerPausedHandler" ];
  NSMutableArray *objects = [NSMutableArray array];
  for (GCController *c in GCController.controllers) {
    [objects addObject:c];
    if (c.extendedGamepad) [objects addObject:c.extendedGamepad];
    if (c.microGamepad) [objects addObject:c.microGamepad];
    if (c.motion) [objects addObject:c.motion];
    if (@available(iOS 14.0, *)) {
      [objects addObject:c.physicalInputProfile];
      [objects addObjectsFromArray:c.physicalInputProfile.allElements.allObjects];
    }
  }
  if (@available(iOS 14.0, *)) {
    GCKeyboardInput *k = GCKeyboard.coalescedKeyboard.keyboardInput;
    if (k) { [objects addObject:k]; [objects addObjectsFromArray:k.allElements.allObjects]; }
    for (GCMouse *m in GCMouse.mice) {
      if (!m.mouseInput) continue;
      [objects addObject:m.mouseInput];
      [objects addObjectsFromArray:m.mouseInput.allElements.allObjects];
    }
  }
  NSUInteger cleared = 0;
  for (id o in objects) {
    for (NSString *key in keys) {
      if (![o respondsToSelector:NSSelectorFromString(key)]) continue;
      @try {
        id handler = [o valueForKey:key];
        if (AKBlockIsDeadGameCode(handler)) { [o setValue:nil forKey:key]; cleared++; }
      } @catch (NSException *e) {
      }
    }
  }
  return cleared;
}

#pragma mark Its end

// A thread is stopped only outside the allocator, the Objective-C runtime, dyld, GCD, Foundation,
// the threads library, sound and the graphics stack: a lock held there would be held for good.
// Those libraries' code ranges are found before any thread is paused (dladdr and friends take
// locks a paused thread may hold); while one is, only its registers and stack are read.
// Two kinds: code that holds a lock shared with the app for as long as it is anywhere on the
// stack (the allocator, the Objective-C runtime, dyld, the app's OpenGL stack), and code that
// only does while it runs (a thread asleep under CoreFoundation's run loop, GCD, the threads
// library's waits or the shim's event pump holds none of their locks). libc is the first kind
// (its streams' locks) except for its sleeps, which hold nothing: a game thread that polls with
// usleep is stopped there.
static ak_text gLockAny[64], gLockRunning[64], gLibc;
static int gLockAnyCount, gLockRunningCount;

static void findLockingCode(void) {
  static const char *any[] = { "libsystem_malloc", "libobjc", "/dyld", "AKOpenGL", "OSMesa", "MoltenVK" };
  static const char *running[] = { "CoreFoundation", "Foundation", "libdispatch", "libsystem_pthread", "AppKitShimCore",
                                   "AudioToolbox", "CoreAudio", "AVFAudio" };
  gLockAnyCount = gLockRunningCount = 0;
  gLibc = (ak_text){ 0, 0 };
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const char *name = _dyld_get_image_name(i);
    if (!name) continue;
    BOOL libc = strstr(name, "/libsystem_c.dylib") != NULL;
    BOOL inAny = libc, inRunning = NO;
    for (size_t k = 0; k < sizeof any / sizeof any[0] && !inAny; k++) inAny = strstr(name, any[k]) != NULL;
    for (size_t k = 0; k < sizeof running / sizeof running[0] && !inRunning; k++) inRunning = strstr(name, running[k]) != NULL;
    const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(i);
    if ((!inAny && !inRunning) || AKAddressIsDeadGameCode(mh)) continue;   // a game's own copy (MoltenVK) only held its locks
    const uint8_t *lc = (const uint8_t *)(mh + 1);
    for (uint32_t j = 0; j < mh->ncmds; j++, lc += ((const struct load_command *)lc)->cmdsize) {
      const struct segment_command_64 *seg = (const void *)lc;
      if (seg->cmd != LC_SEGMENT_64 || strncmp(seg->segname, "__TEXT", 16)) continue;
      ak_text t = { (uintptr_t)mh, (uintptr_t)mh + seg->vmsize };
      if (libc) gLibc = t;
      else if (inAny && gLockAnyCount < 64) gLockAny[gLockAnyCount++] = t;
      else if (inRunning && gLockRunningCount < 64) gLockRunning[gLockRunningCount++] = t;
      break;
    }
  }
}

static int captureFrames(thread_act_t thread, uintptr_t top, uintptr_t bottom, uintptr_t *frames, int max) {
  int n = 0;
#if defined(__arm64__)
  arm_thread_state64_t state;
  mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
  if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return 0;
  frames[n++] = (uintptr_t)arm_thread_state64_get_pc(state) & 0x0000000fffffffffULL;
  frames[n++] = (uintptr_t)arm_thread_state64_get_lr(state) & 0x0000000fffffffffULL;
  uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
  while (n < max && top && fp >= bottom && fp + 16 <= top && !(fp & 7)) {
    uintptr_t next = ((uintptr_t *)fp)[0], ret = ((uintptr_t *)fp)[1];
    if (!ret) break;
    frames[n++] = ret & 0x0000000fffffffffULL;
    if (next <= fp) break;
    fp = next;
  }
#endif
  return n;
}

static BOOL runsGameCode(const uintptr_t *frames, int n) {
  for (int i = 0; i < n; i++) if (AKAddressIsDeadGameCode((void *)frames[i])) return YES;
  return NO;
}

static BOOL holdsLocks(const uintptr_t *frames, int n) {
  for (int i = 0; i < n; i++)
    for (int k = 0; k < gLockAnyCount; k++)
      if (frames[i] >= gLockAny[k].start && frames[i] < gLockAny[k].end) return YES;
  for (int k = 0; n > 0 && k < gLockRunningCount; k++)   // where it is running now
    if (frames[0] >= gLockRunning[k].start && frames[0] < gLockRunning[k].end) return YES;
  return NO;
}

// libc on the stack only in calls that wait and hold none of its locks (nanosleep$NOCANCEL and
// the like count). Looked up with dladdr while the thread is paused, which is safe because it has
// already been found clear of dyld (whose lock dladdr takes).
static BOOL libcOnlyWaits(const uintptr_t *frames, int n) {
  static const char *waits[] = { "nanosleep", "usleep", "sleep", "pause" };
  for (int i = 0; i < n; i++) {
    if (frames[i] < gLibc.start || frames[i] >= gLibc.end) continue;
    Dl_info info;
    if (!dladdr((void *)frames[i], &info) || !info.dli_sname) return NO;
    size_t len = strcspn(info.dli_sname, "$");
    BOOL wait = NO;
    for (size_t k = 0; k < sizeof waits / sizeof waits[0] && !wait; k++)
      wait = strlen(waits[k]) == len && !strncmp(info.dli_sname, waits[k], len);
    if (!wait) return NO;
  }
  return YES;
}

// A thread that never could be stopped, where it was (looked up once it runs again).
static void logStuckThread(const uintptr_t *frames, int n) {
  NSMutableArray *where = [NSMutableArray array];
  for (int i = 0; i < n && where.count < 8; i++) {
    Dl_info info;
    if (!dladdr((void *)frames[i], &info) || !info.dli_fname) continue;
    const char *image = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname;
    [where addObject:[NSString stringWithFormat:@"%s+0x%lx", image, (unsigned long)(frames[i] - (uintptr_t)info.dli_fbase)]];
  }
  teardownLog(@"a thread of its couldn't be stopped safely; it is at %@", [where componentsJoinedByString:@" < "]);
}

// Every thread with its code on the stack, stopped for good once it is somewhere safe. Returns
// how many were stopped; *stuck counts those that never were.
static int stopThreads(int *stuck) {
  int stopped = 0;
  *stuck = 0;
  findLockingCode();
  thread_act_array_t threads;
  mach_msg_type_number_t count = 0;
  if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return 0;
  thread_act_t me = mach_thread_self();
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    thread_act_t t = threads[i];
    pthread_t pt = t != me ? pthread_from_mach_thread_np(t) : NULL;   // its stack, asked while it runs
    uintptr_t top = pt ? (uintptr_t)pthread_get_stackaddr_np(pt) : 0, bottom = pt ? top - pthread_get_stacksize_np(pt) : 0;
    if (t != me) {
      uintptr_t frames[64];
      for (int tries = 0; tries < 100; tries++) {
        if (thread_suspend(t) != KERN_SUCCESS) break;   // ended
        int n = captureFrames(t, top, bottom, frames, 64);
        if (!runsGameCode(frames, n)) { thread_resume(t); break; }   // not the game's
        if (!holdsLocks(frames, n) && libcOnlyWaits(frames, n)) { stopped++; break; }   // stays stopped
        thread_resume(t);
        if (tries == 99) { (*stuck)++; logStuckThread(frames, n); }
        usleep(10000);
      }
    }
    mach_port_deallocate(mach_task_self(), t);
  }
  mach_port_deallocate(mach_task_self(), me);
  vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
  return stopped;
}

// Its classes' methods, and what they were, while it is gone.
typedef struct { Method method; IMP imp; } ak_saved;
static ak_saved *gSaved;
static size_t gSavedCount, gSavedCap;

static id methodGone(id self, SEL _cmd) { return nil; }

static void silenceClass(Class c) {
  unsigned count = 0;
  Method *methods = class_copyMethodList(c, &count);
  for (unsigned i = 0; i < count; i++) {
    if (gSavedCount == gSavedCap) {
      gSavedCap = gSavedCap ? gSavedCap * 2 : 256;
      gSaved = realloc(gSaved, gSavedCap * sizeof *gSaved);
    }
    gSaved[gSavedCount++] = (ak_saved){ methods[i], method_setImplementation(methods[i], (IMP)methodGone) };
  }
  free(methods);
}

void AKGameRestoreClasses(void) {
  for (size_t i = 0; i < gSavedCount; i++) method_setImplementation(gSaved[i].method, gSaved[i].imp);
  if (gSavedCount) teardownLog(@"its classes' %zu methods back", gSavedCount);
  gSavedCount = 0;
}

void AKGameTeardown(NSArray<NSString *> *images) {
  // What would call into it, first: sound of any kind (the session stops every audio object it
  // runs), controllers, display links, dispatch sources, notifications.
  AKGameAudioStop();
  AKGameControllersShutdown();
  NSUInteger handlers = clearControllerHandlers();
  AKGameDisplayLinksStop();
  NSArray *observers, *sources;
  @synchronized (NSHashTable.class) {
    observers = gObservers.allObjects;
    sources = gSources.allObjects;
    [gObservers removeAllObjects];
    [gSources removeAllObjects];
  }
  for (id o in observers) [NSNotificationCenter.defaultCenter removeObserver:o];
  for (dispatch_source_t s in sources) dispatch_source_cancel(s);

  // Then every thread still running its code.
  int stuck = 0, stopped = stopThreads(&stuck);
  if (!stuck) AKGameAudioRelease();

  // What it held: its objects let go, its OpenGL contexts and leftover Metal objects freed.
  NSUInteger objects = stuck ? 0 : releaseInstanceVariables(images);
  int contexts = 0;
  int (*contextCount)(void) = (int (*)(void))dlsym(RTLD_DEFAULT, "AKGLContextCount");
  void (*destroyContexts)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "AKGLDestroyAllContexts");
  if (contextCount && destroyContexts && !stuck) {
    contexts = contextCount();
    destroyContexts();
  }
  NSUInteger metal = stuck ? 0 : freeMetal();

  // Its code: every method of its classes does nothing now.
  int classes = 0;
  for (NSString *image in images) {
    unsigned count = 0;
    const char **names = objc_copyClassNamesForImage(image.fileSystemRepresentation, &count);
    for (unsigned i = 0; i < count; i++) {
      Class c = objc_getClass(names[i]);
      if (!c) continue;
      silenceClass(c);
      silenceClass(object_getClass(c));
      classes++;
    }
    free(names);
  }
  teardownLog(@"ended like its process: %d threads stopped%@, %lu controller handlers, %lu observers and %lu dispatch "
              @"sources removed, %lu of its objects let go, %d OpenGL contexts and %lu Metal objects freed, %d classes "
              @"silenced, %d exit handlers left unrun",
              stopped, stuck ? [NSString stringWithFormat:@" (%d couldn't be)", stuck] : @"", (unsigned long)handlers,
              (unsigned long)observers.count, (unsigned long)sources.count, (unsigned long)objects, contexts,
              (unsigned long)metal, classes, gExitHandlers);
  gExitHandlers = 0;

  // Its heap, a moment on (blocks already queued that release its objects run first).
  malloc_zone_t *zone = gZone;
  gZone = NULL;
  if (!zone) return;
  if (stuck) {
    teardownLog(@"its heap stays: a thread of its couldn't be stopped safely");
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    malloc_statistics_t stats = { 0 };
    malloc_zone_statistics(zone, &stats);
    malloc_destroy_zone(zone);
    teardownLog(@"its heap freed: %.1f MB in use, %.1f MB held", stats.size_in_use / 1048576.0, stats.size_allocated / 1048576.0);
  });
}
