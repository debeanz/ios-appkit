// A Mac game's main thread is its own here, not UIKit's.
//
// On a Mac the main thread is the game's: work its code sends to the main queue, to the main
// run loop or with -performSelectorOnMainThread: runs there, between the frames of its loop, and
// "am I on the main thread?" is answered for that thread. Here the game's main() runs on a thread
// of its own (InProcessExec.m) and the app's main thread is UIKit's, so that work ran on UIKit's
// thread instead - at the same time as the game's, and where a crash in the game's code takes
// Steam down with it (the guard in GameCrash.m can only end a game's own threads).
//
// So for the game's code: the main queue is a queue its main thread's run loop drains
// (libdispatch's run-loop queue, as CoreFoundation makes for its run loops), the main run loop
// is its main thread's, pthread_main_np() and +[NSThread isMainThread] say whether this is its
// main thread, and -performSelectorOnMainThread: performs there. Its imports are bound to these
// (AKGameBindMainThread, as each of its images loads); the Objective-C ones look at their
// caller. Each launch gets a queue of its own, so nothing a previous run left behind reaches
// the next. Steam's code is untouched.
#import "AKShimPrivate.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>

// libdispatch's run-loop queues (exported for CoreFoundation; not in the SDK's headers).
static dispatch_queue_t (*createRunLoopQueue)(const char *label, unsigned long flags);
static mach_port_t (*runLoopQueuePort)(dispatch_queue_t queue);
static bool (*runLoopQueuePerform)(dispatch_queue_t queue);
static void (*runLoopQueueWakeUp)(dispatch_queue_t queue);

static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static pid_t gLoopPid, gQueuePid;      // the launch each belongs to
static CFRunLoopRef gLoop;             // its main thread's run loop (retained)
static NSThread *gThread;              // its main thread
static dispatch_queue_t gQueue;        // its main queue
static CFRunLoopSourceRef gSource;     // that queue's port, on gAttachedTo
static CFRunLoopRef gAttachedTo;       // (retained)

static BOOL haveRunLoopQueues(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    createRunLoopQueue = dlsym(RTLD_DEFAULT, "_dispatch_runloop_root_queue_create_4CF");
    runLoopQueuePort = dlsym(RTLD_DEFAULT, "_dispatch_runloop_root_queue_get_port_4CF");
    runLoopQueuePerform = dlsym(RTLD_DEFAULT, "_dispatch_runloop_root_queue_perform_4CF");
    runLoopQueueWakeUp = dlsym(RTLD_DEFAULT, "_dispatch_runloop_root_queue_wakeup_4CF");
  });
  return createRunLoopQueue && runLoopQueuePort && runLoopQueuePerform && runLoopQueueWakeUp;
}

// Its queue's port woke its run loop: one block, and another turn if there are more (as
// CoreFoundation drains its own).
static void drain(CFMachPortRef port, void *message, CFIndex size, void *info) {
  dispatch_queue_t queue = (__bridge dispatch_queue_t)info;
  if (runLoopQueuePerform(queue)) runLoopQueueWakeUp(queue);
}

// The queue's port onto its main thread's run loop, once both are this launch's. Under gLock.
static void attach(void) {
  if (!gQueue || !gLoop || gQueuePid != gLoopPid || gAttachedTo == gLoop) return;
  if (gAttachedTo) {
    CFRunLoopRemoveSource(gAttachedTo, gSource, kCFRunLoopCommonModes);
    CFRelease(gAttachedTo);
  }
  CFRunLoopAddSource(gLoop, gSource, kCFRunLoopCommonModes);
  gAttachedTo = (CFRunLoopRef)CFRetain(gLoop);
  CFRunLoopWakeUp(gLoop);
}

void AKGameMainThreadHere(void) {
  if (!AKIsGameThread()) return;
  pid_t pid = AKGamePid();
  CFRunLoopRef loop = CFRunLoopGetCurrent();
  pthread_mutex_lock(&gLock);
  if (gLoopPid != pid || gLoop != loop) {
    if (gLoop) CFRelease(gLoop);
    gLoop = (CFRunLoopRef)CFRetain(loop);
    gLoopPid = pid;
    gThread = NSThread.currentThread;
    attach();
  }
  pthread_mutex_unlock(&gLock);
}

// The running game's main queue: for this launch, made on first use. The previous launch's stays
// off every run loop with whatever it still held (its code is gone).
dispatch_queue_t AKGameMainQueue(void) {
  pid_t pid = AKGamePid();
  if (!pid || !haveRunLoopQueues()) return dispatch_get_main_queue();
  pthread_mutex_lock(&gLock);
  if (gQueuePid != pid) {
    if (gAttachedTo) {
      CFRunLoopRemoveSource(gAttachedTo, gSource, kCFRunLoopCommonModes);
      CFRelease(gAttachedTo);
      gAttachedTo = NULL;
    }
    gQueue = createRunLoopQueue("com.apple.main-thread (game)", 0);
    CFMachPortContext context = { 0, (__bridge void *)gQueue, NULL, NULL, NULL };
    CFMachPortRef port = gQueue ? CFMachPortCreateWithPort(NULL, runLoopQueuePort(gQueue), drain, &context, NULL) : NULL;
    gSource = port ? CFMachPortCreateRunLoopSource(NULL, port, 0) : NULL;
    if (port) CFRelease(port);
    if (!gSource) gQueue = nil;
    gQueuePid = pid;
    if (gQueue) attach();
  }
  dispatch_queue_t queue = gQueue ?: dispatch_get_main_queue();
  pthread_mutex_unlock(&gLock);
  return queue;
}

dispatch_queue_t AKGameQueueFor(dispatch_queue_t queue) {
  return queue == dispatch_get_main_queue() ? AKGameMainQueue() : queue;
}

#pragma mark Its code's calls

static void gameAsync(dispatch_queue_t q, dispatch_block_t b) { dispatch_async(AKGameQueueFor(q), b); }
static void gameAsyncF(dispatch_queue_t q, void *c, dispatch_function_t f) { dispatch_async_f(AKGameQueueFor(q), c, f); }
static void gameBarrierAsync(dispatch_queue_t q, dispatch_block_t b) { dispatch_barrier_async(AKGameQueueFor(q), b); }
static void gameBarrierAsyncF(dispatch_queue_t q, void *c, dispatch_function_t f) { dispatch_barrier_async_f(AKGameQueueFor(q), c, f); }
static void gameAfter(dispatch_time_t t, dispatch_queue_t q, dispatch_block_t b) { dispatch_after(t, AKGameQueueFor(q), b); }
static void gameAfterF(dispatch_time_t t, dispatch_queue_t q, void *c, dispatch_function_t f) { dispatch_after_f(t, AKGameQueueFor(q), c, f); }
static void gameGroupAsync(dispatch_group_t g, dispatch_queue_t q, dispatch_block_t b) { dispatch_group_async(g, AKGameQueueFor(q), b); }
static void gameGroupAsyncF(dispatch_group_t g, dispatch_queue_t q, void *c, dispatch_function_t f) { dispatch_group_async_f(g, AKGameQueueFor(q), c, f); }
static void gameGroupNotify(dispatch_group_t g, dispatch_queue_t q, dispatch_block_t b) { dispatch_group_notify(g, AKGameQueueFor(q), b); }
static void gameGroupNotifyF(dispatch_group_t g, dispatch_queue_t q, void *c, dispatch_function_t f) { dispatch_group_notify_f(g, AKGameQueueFor(q), c, f); }
static void gameSetTarget(dispatch_object_t o, dispatch_queue_t q) { dispatch_set_target_queue(o, q ? AKGameQueueFor(q) : q); }

// Waiting on the main queue: on its main thread it runs now (the Mac would deadlock; nothing
// relies on that), from another thread it waits for its main thread's run loop.
static void gameSyncF(dispatch_queue_t q, void *c, dispatch_function_t f, BOOL barrier) {
  if (q != dispatch_get_main_queue()) {
    if (barrier) dispatch_barrier_sync_f(q, c, f); else dispatch_sync_f(q, c, f);
    return;
  }
  if (AKIsGameThread()) { f(c); return; }
  dispatch_queue_t main = AKGameMainQueue();
  if (main == dispatch_get_main_queue()) { dispatch_sync_f(main, c, f); return; }   // no queue of its own: as before
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  dispatch_async(main, ^{ f(c); dispatch_semaphore_signal(done); });
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}
static void callBlock(void *block) { ((__bridge dispatch_block_t)block)(); }
static void gameSync(dispatch_queue_t q, dispatch_block_t b) { gameSyncF(q, (__bridge void *)b, callBlock, NO); }
static void gameSyncFn(dispatch_queue_t q, void *c, dispatch_function_t f) { gameSyncF(q, c, f, NO); }
static void gameBarrierSync(dispatch_queue_t q, dispatch_block_t b) { gameSyncF(q, (__bridge void *)b, callBlock, YES); }
static void gameBarrierSyncFn(dispatch_queue_t q, void *c, dispatch_function_t f) { gameSyncF(q, c, f, YES); }

static int gamePthreadMainNp(void) { return AKIsGameThread(); }

static CFRunLoopRef gameRunLoopGetMain(void) {
  pthread_mutex_lock(&gLock);
  CFRunLoopRef loop = gLoop && gLoopPid == AKGamePid() ? gLoop : NULL;
  pthread_mutex_unlock(&gLock);
  return loop ?: CFRunLoopGetMain();
}

void AKGameBindMainThread(const struct mach_header *header, intptr_t slide) {
  AKGameMainThreadHere();   // its program loads on its main thread
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    static const struct { const char *name; void *fn; } table[] = {
      { "_dispatch_async", (void *)gameAsync }, { "_dispatch_async_f", (void *)gameAsyncF },
      { "_dispatch_barrier_async", (void *)gameBarrierAsync }, { "_dispatch_barrier_async_f", (void *)gameBarrierAsyncF },
      { "_dispatch_after", (void *)gameAfter }, { "_dispatch_after_f", (void *)gameAfterF },
      { "_dispatch_group_async", (void *)gameGroupAsync }, { "_dispatch_group_async_f", (void *)gameGroupAsyncF },
      { "_dispatch_group_notify", (void *)gameGroupNotify }, { "_dispatch_group_notify_f", (void *)gameGroupNotifyF },
      { "_dispatch_set_target_queue", (void *)gameSetTarget },
      { "_dispatch_sync", (void *)gameSync }, { "_dispatch_sync_f", (void *)gameSyncFn },
      { "_dispatch_barrier_sync", (void *)gameBarrierSync }, { "_dispatch_barrier_sync_f", (void *)gameBarrierSyncFn },
      { "_pthread_main_np", (void *)gamePthreadMainNp }, { "_CFRunLoopGetMain", (void *)gameRunLoopGetMain },
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++)
      if (!strcmp(symbol, table[i].name)) return table[i].fn;
    return NULL;
  });
}

#pragma mark Objective-C

static BOOL gameCaller(const void *returnAddress) { return AKGameIsRunning() && AKAddressIsInGame(returnAddress); }

static IMP gIsMainThreadClass, gIsMainThread, gMainThread, gPerformOnMain, gPerformOnMainModes;

static BOOL isMainThreadClass(id self, SEL _cmd) {
  if (gameCaller(__builtin_return_address(0))) return AKIsGameThread();
  return ((BOOL (*)(id, SEL))gIsMainThreadClass)(self, _cmd);
}

static BOOL isMainThread(NSThread *self, SEL _cmd) {
  if (gameCaller(__builtin_return_address(0))) {
    pthread_mutex_lock(&gLock);
    BOOL main = gThread && self == gThread && gLoopPid == AKGamePid();
    pthread_mutex_unlock(&gLock);
    return main;
  }
  return ((BOOL (*)(id, SEL))gIsMainThread)(self, _cmd);
}

static NSThread *mainThread(id self, SEL _cmd) {
  if (gameCaller(__builtin_return_address(0))) {
    pthread_mutex_lock(&gLock);
    NSThread *thread = gLoopPid == AKGamePid() ? gThread : nil;
    pthread_mutex_unlock(&gLock);
    if (thread) return thread;
  }
  return ((NSThread * (*)(id, SEL))gMainThread)(self, _cmd);
}

// On its main thread's run loop (in the modes given, or the common ones); waiting if asked.
static BOOL performOnGameMain(id target, SEL sel, id arg, BOOL wait, NSArray<NSString *> *modes) {
  CFRunLoopRef loop = gameRunLoopGetMain();
  if (loop == CFRunLoopGetMain()) return NO;   // its main thread isn't known yet: as before
  if (wait && AKIsGameThread()) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
    return YES;
  }
  dispatch_semaphore_t done = wait ? dispatch_semaphore_create(0) : nil;
  dispatch_block_t block = ^{
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, arg);
    if (done) dispatch_semaphore_signal(done);
  };
  if (modes.count) for (NSString *mode in modes) CFRunLoopPerformBlock(loop, (__bridge CFStringRef)mode, block);
  else CFRunLoopPerformBlock(loop, kCFRunLoopCommonModes, block);
  CFRunLoopWakeUp(loop);
  if (done) dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
  return YES;
}

static void performOnMain(id self, SEL _cmd, SEL sel, id arg, BOOL wait) {
  if (gameCaller(__builtin_return_address(0)) && performOnGameMain(self, sel, arg, wait, nil)) return;
  ((void (*)(id, SEL, SEL, id, BOOL))gPerformOnMain)(self, _cmd, sel, arg, wait);
}

static void performOnMainModes(id self, SEL _cmd, SEL sel, id arg, BOOL wait, NSArray *modes) {
  if (gameCaller(__builtin_return_address(0)) && performOnGameMain(self, sel, arg, wait, modes)) return;
  ((void (*)(id, SEL, SEL, id, BOOL, NSArray *))gPerformOnMainModes)(self, _cmd, sel, arg, wait, modes);
}

__attribute__((constructor)) static void hookMainThreadQuestions(void) {
  Class thread = NSThread.class, object = NSObject.class;
  gIsMainThreadClass = method_setImplementation(class_getClassMethod(thread, @selector(isMainThread)), (IMP)isMainThreadClass);
  gIsMainThread = method_setImplementation(class_getInstanceMethod(thread, @selector(isMainThread)), (IMP)isMainThread);
  gMainThread = method_setImplementation(class_getClassMethod(thread, @selector(mainThread)), (IMP)mainThread);
  gPerformOnMain = method_setImplementation(
      class_getInstanceMethod(object, @selector(performSelectorOnMainThread:withObject:waitUntilDone:)), (IMP)performOnMain);
  gPerformOnMainModes = method_setImplementation(
      class_getInstanceMethod(object, @selector(performSelectorOnMainThread:withObject:waitUntilDone:modes:)), (IMP)performOnMainModes);
}
