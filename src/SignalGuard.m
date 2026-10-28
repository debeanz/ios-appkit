// Keep the host's crash reporting in charge.
//
// The iOS host catches fatal signals and writes Documents/crash.log; on a device that log is
// the only reliable account of a crash. But the client brings its own crash machinery: Steam's
// crashhandler (Breakpad) claims the task's Mach exception ports, which see a bad access before
// any signal handler does, and Chromium installs signal handlers of its own. Either way the
// app can die with nothing written. With AK_KEEP_FATAL_SIGNALS set (the host sets it), the shim
// leaves the host's handlers for the fatal signals in place: sigaction/signal calls for them
// are recorded (and reported back to their caller) but not installed, and exception-port
// changes are acknowledged without being made. Other signals pass straight through. libSystem
// is routed through the shim umbrella, so the client's calls bind here; the host's don't.
#import <dlfcn.h>
#import <errno.h>
#import <mach/mach.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

int sigaction(int sig, const struct sigaction *act, struct sigaction *oact);
void (*signal(int sig, void (*handler)(int)))(int);

static void *realSym(const char *name) {
  static void *libSystem;
  if (!libSystem) libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
  return libSystem ? dlsym(libSystem, name) : NULL;
}

static int guarding(void) {
  const char *v = getenv("AK_KEEP_FATAL_SIGNALS");
  return v && *v && *v != '0';
}

static int isFatal(int sig) {
  return sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGFPE ||
         sig == SIGABRT || sig == SIGSYS || sig == SIGTRAP;
}

// What the client last asked for, per signal, so a later query reads back its own handler.
static struct sigaction gWanted[NSIG];
static int gHaveWanted[NSIG];

int sigaction(int sig, const struct sigaction *act, struct sigaction *oact) {
  int (*real)(int, const struct sigaction *, struct sigaction *) =
      (int (*)(int, const struct sigaction *, struct sigaction *))realSym("sigaction");
  if (sig <= 0 || sig >= NSIG || !isFatal(sig) || !guarding()) return real(sig, act, oact);
  if (oact) {
    if (gHaveWanted[sig]) *oact = gWanted[sig];
    else real(sig, NULL, oact);
  }
  if (act) {
    if (!gHaveWanted[sig]) fprintf(stderr, "[AppKitShim] kept the host's handler for signal %d (client's recorded, not installed)\n", sig);
    gWanted[sig] = *act;
    gHaveWanted[sig] = 1;
  }
  return 0;
}

void (*signal(int sig, void (*handler)(int)))(int) {
  void (*(*real)(int, void (*)(int)))(int) = (void (*(*)(int, void (*)(int)))(int))realSym("signal");
  if (sig <= 0 || sig >= NSIG || !isFatal(sig) || !guarding()) return real(sig, handler);
  struct sigaction act = { 0 }, old = { 0 };
  act.sa_handler = handler;
  sigemptyset(&act.sa_mask);
  sigaction(sig, &act, &old);
  return old.sa_handler;
}

#pragma mark Mach exception ports

kern_return_t task_set_exception_ports(task_t task, exception_mask_t mask, mach_port_t port,
                                       exception_behavior_t behavior, thread_state_flavor_t flavor) {
  if (guarding()) {
    static int told;
    if (!told++) fprintf(stderr, "[AppKitShim] kept the host's crash reporting (task exception ports left alone)\n");
    return KERN_SUCCESS;
  }
  kern_return_t (*real)(task_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t) =
      (kern_return_t (*)(task_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t))realSym("task_set_exception_ports");
  return real ? real(task, mask, port, behavior, flavor) : KERN_FAILURE;
}

kern_return_t thread_set_exception_ports(thread_act_t thread, exception_mask_t mask, mach_port_t port,
                                         exception_behavior_t behavior, thread_state_flavor_t flavor) {
  if (guarding()) return KERN_SUCCESS;
  kern_return_t (*real)(thread_act_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t) =
      (kern_return_t (*)(thread_act_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t))realSym("thread_set_exception_ports");
  return real ? real(thread, mask, port, behavior, flavor) : KERN_FAILURE;
}

// The swap form also reports the previous handlers; report none.
kern_return_t task_swap_exception_ports(task_t task, exception_mask_t mask, mach_port_t port,
                                        exception_behavior_t behavior, thread_state_flavor_t flavor,
                                        exception_mask_array_t masks, mach_msg_type_number_t *count,
                                        exception_handler_array_t handlers, exception_behavior_array_t behaviors,
                                        exception_flavor_array_t flavors) {
  if (guarding()) {
    if (count) *count = 0;
    return KERN_SUCCESS;
  }
  kern_return_t (*real)(task_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t,
                        exception_mask_array_t, mach_msg_type_number_t *, exception_handler_array_t,
                        exception_behavior_array_t, exception_flavor_array_t) =
      (kern_return_t (*)(task_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t,
                         exception_mask_array_t, mach_msg_type_number_t *, exception_handler_array_t,
                         exception_behavior_array_t, exception_flavor_array_t))realSym("task_swap_exception_ports");
  return real ? real(task, mask, port, behavior, flavor, masks, count, handlers, behaviors, flavors) : KERN_FAILURE;
}
