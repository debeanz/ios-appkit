// Unix-domain socket paths in /tmp, moved into the app's own temporary directory.
//
// Mac programs put their rendezvous sockets in /tmp (Steam's web helper binds
// /tmp/steam_chrome_shmem_uid<uid>_spid<pid>, and the client connects to it to trade shared
// memory). An iOS app may only create files inside its container, so bind() there fails. The
// shim maps a socket path under /tmp, /private/tmp or /var/tmp to $TMPDIR/s<hash>, the same
// for bind and connect, so both ends still meet. The name is a short hash: a socket path must
// fit in sun_path (104 bytes), and the container's tmp directory alone is ~90 characters.
// libSystem is routed through the shim umbrella, so the client's socket calls bind here.
#import <dlfcn.h>
#import <errno.h>
#import <stddef.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

int bind(int fd, const struct sockaddr *addr, socklen_t len);
int connect(int fd, const struct sockaddr *addr, socklen_t len);

static void *realSym(const char *name) {
  static void *libSystem;
  if (!libSystem) libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
  return libSystem ? dlsym(libSystem, name) : NULL;
}

static int isSystemTmp(const char *p) {
  return strncmp(p, "/tmp/", 5) == 0 || strncmp(p, "/private/tmp/", 13) == 0 || strncmp(p, "/var/tmp/", 9) == 0;
}

// FNV-1a: stable, so bind and connect of the same path agree.
static uint32_t pathHash(const char *s) {
  uint32_t h = 2166136261u;
  for (; *s; s++) { h ^= (uint8_t)*s; h *= 16777619u; }
  return h;
}

// If addr is an AF_UNIX path in a system tmp directory, fill *out with the app-local
// equivalent and return 1.
static int remap(const struct sockaddr *addr, socklen_t len, struct sockaddr_un *out) {
  if (!addr || addr->sa_family != AF_UNIX || len <= offsetof(struct sockaddr_un, sun_path)) return 0;
  const struct sockaddr_un *un = (const struct sockaddr_un *)addr;
  char path[sizeof un->sun_path + 1];
  size_t n = len - offsetof(struct sockaddr_un, sun_path);
  if (n > sizeof un->sun_path) n = sizeof un->sun_path;
  memcpy(path, un->sun_path, n);
  path[n] = 0;
  if (!isSystemTmp(path)) return 0;

  const char *dir = getenv("TMPDIR");
  if (!dir || !*dir) return 0;
  memset(out, 0, sizeof *out);
  out->sun_family = AF_UNIX;
  int w = snprintf(out->sun_path, sizeof out->sun_path, "%s%ss%08x", dir,
                   dir[strlen(dir) - 1] == '/' ? "" : "/", pathHash(path));
  if (w < 0 || (size_t)w >= sizeof out->sun_path) {
    fprintf(stderr, "[AppKitShim] socket path %s: app tmp dir too long to move it there\n", path);
    return 0;
  }
  out->sun_len = (uint8_t)SUN_LEN(out);
  return 1;
}

int bind(int fd, const struct sockaddr *addr, socklen_t len) {
  int (*real)(int, const struct sockaddr *, socklen_t) = (int (*)(int, const struct sockaddr *, socklen_t))realSym("bind");
  struct sockaddr_un local;
  if (!remap(addr, len, &local)) return real(fd, addr, len);
  // The caller unlinked the /tmp path before binding (which iOS refused); clear any socket a
  // previous run left at the app-local path instead.
  unlink(local.sun_path);
  int rc = real(fd, (const struct sockaddr *)&local, (socklen_t)local.sun_len);
  int e = errno;
  fprintf(stderr, "[AppKitShim] bind %s -> %s: %s\n", ((const struct sockaddr_un *)addr)->sun_path,
          local.sun_path, rc == 0 ? "ok" : strerror(e));
  errno = e;
  return rc;
}

int connect(int fd, const struct sockaddr *addr, socklen_t len) {
  int (*real)(int, const struct sockaddr *, socklen_t) = (int (*)(int, const struct sockaddr *, socklen_t))realSym("connect");
  struct sockaddr_un local;
  if (!remap(addr, len, &local)) return real(fd, addr, len);
  return real(fd, (const struct sockaddr *)&local, (socklen_t)local.sun_len);
}
