// A game that crashes ends like a crashed process on a Mac: the game goes, Steam stays.
//
// Games run inside this app's one process, so a fatal signal in a game's code would take Steam
// down with it. From a game's first launch a handler sits in front of the host's
// (host/main.m, which writes Documents/crash.log and lets the app die). A fatal signal on a
// thread with the running game's code on its stack, other than the app's main thread, is the
// game's crash: the handler notes where (async-signal-safe: registers, frame pointers, write),
// parks that thread for good, and wakes a watcher thread, which logs the crash with its frames
// named, adds it to crash.log, and ends the game as Steam's Stop would (Steam sees its process
// gone and Big Picture comes back; the teardown then stops its other threads). That includes a
// game stopping on a gap in the shim ("unrecognized selector": the uncaught exception's abort).
// A thread of a game that has already ended, crashing in that game's code, just stops.
// Everything else - Steam's crashes, the web helper's, game code crashing on the main thread
// (which can't be parked without freezing the app) or on Core Audio's threads (see
// audioThread) - goes to the host's handler as before.
// Game threads get an alternate signal stack (InProcessExec.m), so a stack overflow is caught
// too. The game's own handlers stay recorded, not installed (SignalGuard.m).
#import "AKShimPrivate.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <pthread.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>

enum { kFrames = 48 };
static const int kFatal[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };

static struct sigaction gHostAction[NSIG];   // the handlers this sits in front of
// libSystem's own sigaction: inside the shim, sigaction and signal are SignalGuard.m's, which
// only record a fatal signal's handler.
static int (*gRealSigaction)(int, const struct sigaction *, struct sigaction *);
static semaphore_t gCrashed;                 // signalled by the handler, waited on by the watcher
static volatile int gHandling;               // a game crash being reported (one at a time)
static int gSignal;
static pid_t gPid;
static uintptr_t gAddress, gPC, gFrames[kFrames];
static int gFrameCount;

static void hostHandler(int sig, siginfo_t *info, void *uap) {
  struct sigaction *h = &gHostAction[sig];
  if ((h->sa_flags & SA_SIGINFO) && h->sa_sigaction) { h->sa_sigaction(sig, info, uap); return; }
  if (h->sa_handler != SIG_DFL && h->sa_handler != SIG_IGN && h->sa_handler) { h->sa_handler(sig); return; }
  struct sigaction dfl = { 0 };
  dfl.sa_handler = SIG_DFL;
  gRealSigaction(sig, &dfl, NULL);
  raise(sig);
}

// The faulting PC, the return address in LR, and the frame-pointer chain, within this thread's
// stack (a bad frame pointer is not followed out of it).
static int captureFrames(const ucontext_t *uc, uintptr_t *frames) {
  int n = 0;
#if defined(__arm64__)
  if (!uc) return 0;
  frames[n++] = (uintptr_t)uc->uc_mcontext->__ss.__pc;
  frames[n++] = (uintptr_t)uc->uc_mcontext->__ss.__lr;
  uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
  pthread_t self = pthread_self();
  uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(self), bottom = top - pthread_get_stacksize_np(self);
  while (n < kFrames && fp >= bottom && fp + 16 <= top && !(fp & 7)) {
    uintptr_t next = ((uintptr_t *)fp)[0], ret = ((uintptr_t *)fp)[1];
    if (!ret) break;
    frames[n++] = ret;
    if (next <= fp) break;
    fp = next;
  }
#endif
  return n;
}

// Core Audio's I/O and queue threads run a game's sound callbacks, but stopping the game's sound
// waits for the callback in hand to return: parked there, the teardown would never finish.
static BOOL audioThread(void) {
  char name[64] = "";
  pthread_getname_np(pthread_self(), name, sizeof name);
  return strstr(name, "IOThread") || strstr(name, "AURemoteIO") || strstr(name, "AQClient");
}

static void onFatalSignal(int sig, siginfo_t *info, void *uap) {
  pid_t pid = AKGamePid();
  uintptr_t frames[kFrames];
  int n = !pthread_main_np() && !audioThread() ? captureFrames(uap, frames) : 0;
  BOOL game = NO, ended = NO;
  for (int i = 0; i < n && !game; i++) {
    game = pid && AKAddressIsInGame((const void *)frames[i]);
    ended = ended || AKAddressIsDeadGameCode((const void *)frames[i]);
  }
  // A thread of a game that has already ended (still finishing its last call): only it stops.
  if (!game && ended) {
    static const char line[] = "[AppKitShim] game: a thread of a game that had ended crashed; it stops there, Steam stays\n";
    write(2, line, sizeof line - 1);
    for (;;) sleep(3600);
  }
  if (!game) { hostHandler(sig, info, uap); return; }
  if (__sync_bool_compare_and_swap(&gHandling, 0, 1)) {
    gSignal = sig;
    gPid = pid;
    gAddress = info ? (uintptr_t)info->si_addr : 0;
    gPC = frames[0];
    memcpy(gFrames, frames, sizeof(uintptr_t) * (size_t)n);
    gFrameCount = n;
    static const char line[] = "[AppKitShim] game: it crashed; the game ends, Steam stays (details follow)\n";
    write(2, line, sizeof line - 1);
    semaphore_signal(gCrashed);
  }
  for (;;) sleep(3600);   // this thread is the game's, and the game is over: it never runs again
}

static NSString *nameFrame(uintptr_t address) {
  Dl_info info;
  if (!dladdr((const void *)address, &info) || !info.dli_fname) return [NSString stringWithFormat:@"0x%lx", (unsigned long)address];
  const char *image = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname;
  NSString *where = [NSString stringWithFormat:@"%s+0x%lx", image, (unsigned long)(address - (uintptr_t)info.dli_fbase)];
  return info.dli_sname ? [where stringByAppendingFormat:@" (%s)", info.dli_sname] : where;
}

static void *watchCrashes(void *unused) {
  pthread_setname_np("game crash watcher");
  for (;;) {
    if (semaphore_wait(gCrashed) != KERN_SUCCESS) continue;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; i < gFrameCount; i++) [names addObject:nameFrame(gFrames[i])];
    NSString *report = [NSString stringWithFormat:@"[AppKitShim] game: crashed with signal %d (SIG%s), fault address 0x%lx, at %@\n"
                                                  @"[AppKitShim] game: its stack: %@\n",
                        gSignal, gSignal < NSIG ? sys_signame[gSignal] : "?", (unsigned long)gAddress, nameFrame(gPC),
                        [names componentsJoinedByString:@" < "]];
    fputs(report.UTF8String, stderr);
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    FILE *crashLog = fopen([docs stringByAppendingPathComponent:@"crash.log"].fileSystemRepresentation, "a");
    if (crashLog) {
      fprintf(crashLog, "\n*** a game crashed (the app kept running)\n%s", report.UTF8String);
      fclose(crashLog);
    }
    AKInProcessForceExit(gPid, 128 + gSignal);   // as a shell reports a process a signal ended
    __sync_lock_release(&gHandling);
  }
  return NULL;
}

void AKGameCrashGuardInstall(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if (semaphore_create(mach_task_self(), &gCrashed, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) return;
    pthread_t watcher;
    if (pthread_create(&watcher, NULL, watchCrashes, NULL) != 0) return;
    pthread_detach(watcher);
    gRealSigaction = (int (*)(int, const struct sigaction *, struct sigaction *))dlsym(
        dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD), "sigaction");
    if (!gRealSigaction) return;
    struct sigaction sa = { 0 };
    sa.sa_sigaction = onFatalSignal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof kFatal / sizeof kFatal[0]; i++) gRealSigaction(kFatal[i], &sa, &gHostAction[kFatal[i]]);
    fprintf(stderr, "[AppKitShim] game crashes end the game, not the app (a handler in front of the host's)\n");
  });
}
