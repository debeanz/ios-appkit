// Mach bootstrap services, in process.
//
// A Mac program publishes a Mach service with bootstrap_check_in so its other processes can
// find it with bootstrap_look_up. Chromium's browser process does this first thing on macOS
// (its MachPortRendezvousServer, "<bundle id>.MachPortRendezvousServer.<pid>") and CHECKs the
// result. iOS doesn't let an app register services, so CEF crashed inside cef_initialize.
// Here every "process" lives in this one task, so a service only has to be found by this task:
// the shim keeps a registry of names. bootstrap_check_in makes a receive right and records it
// under the name; bootstrap_look_up of a recorded name hands back a send right to it. Names
// it hasn't recorded go to the real calls (Steam's own ipctool lookup still fails the way it
// did, and falls back). libSystem is routed through the shim umbrella, so the client binds here.
#import <dlfcn.h>
#import <mach/mach.h>
#import <pthread.h>
#import <stdio.h>
#import <string.h>

kern_return_t bootstrap_check_in(mach_port_t bp, const char *service_name, mach_port_t *sp);
kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

#define AK_MAX_SERVICES 64
#define AK_SERVICE_NAMELEN 128          // name_t

static struct { char name[AK_SERVICE_NAMELEN]; mach_port_t port; } gServices[AK_MAX_SERVICES];
static int gServiceCount;
static pthread_mutex_t gServiceLock = PTHREAD_MUTEX_INITIALIZER;

static void *realSym(const char *name) {
  static void *libSystem;
  if (!libSystem) libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
  return libSystem ? dlsym(libSystem, name) : NULL;
}

static int findService(const char *name) {
  for (int i = 0; i < gServiceCount; i++) if (strcmp(gServices[i].name, name) == 0) return i;
  return -1;
}

kern_return_t bootstrap_check_in(mach_port_t bp, const char *service_name, mach_port_t *sp) {
  if (!service_name || !sp) return KERN_INVALID_ARGUMENT;
  pthread_mutex_lock(&gServiceLock);
  int i = findService(service_name);
  if (i >= 0) {
    // Checked in twice: the service is already active, as launchd would say.
    pthread_mutex_unlock(&gServiceLock);
    return 1103;                          // BOOTSTRAP_SERVICE_ACTIVE
  }
  if (gServiceCount >= AK_MAX_SERVICES) { pthread_mutex_unlock(&gServiceLock); return KERN_RESOURCE_SHORTAGE; }
  mach_port_t port = MACH_PORT_NULL;
  kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
  if (kr != KERN_SUCCESS) { pthread_mutex_unlock(&gServiceLock); return kr; }
  strlcpy(gServices[gServiceCount].name, service_name, AK_SERVICE_NAMELEN);
  gServices[gServiceCount].port = port;
  gServiceCount++;
  pthread_mutex_unlock(&gServiceLock);
  fprintf(stderr, "[AppKitShim] Mach service %s registered in-process (port 0x%x)\n", service_name, port);
  *sp = port;
  return KERN_SUCCESS;
}

kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp) {
  if (!service_name || !sp) return KERN_INVALID_ARGUMENT;
  pthread_mutex_lock(&gServiceLock);
  int i = findService(service_name);
  mach_port_t port = i >= 0 ? gServices[i].port : MACH_PORT_NULL;
  pthread_mutex_unlock(&gServiceLock);
  if (port != MACH_PORT_NULL) {
    // A send right for the caller, as a lookup returns one.
    kern_return_t kr = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) return kr;
    *sp = port;
    return KERN_SUCCESS;
  }
  kern_return_t (*real)(mach_port_t, const char *, mach_port_t *) =
      (kern_return_t (*)(mach_port_t, const char *, mach_port_t *))realSym("bootstrap_look_up");
  return real ? real(bp, service_name, sp) : 1102;   // BOOTSTRAP_UNKNOWN_SERVICE
}
