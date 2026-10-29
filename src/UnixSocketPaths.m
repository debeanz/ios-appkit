// Unix-domain socket paths in /tmp, moved into the app's own temporary directory.
//
// Mac programs put their rendezvous sockets in /tmp (Steam's web helper binds
// /tmp/steam_chrome_shmem_uid<uid>_spid<pid>, and the client connects to it to trade shared
// memory). An iOS app may only create files inside its container, so bind() there fails. The
// shim maps a socket path under /tmp, /private/tmp or /var/tmp to $TMPDIR/s<hash>, the same
// for bind and connect, so both ends still meet. The name is a short hash: a socket path must
// fit in sun_path (104 bytes), and the container's tmp directory alone is ~90 characters.
// libSystem is routed through the shim umbrella, so the client's socket calls bind here.
// The same wrappers also log loopback TCP bind/listen/connect results (see below).
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <errno.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stddef.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

int bind(int fd, const struct sockaddr *addr, socklen_t len);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
static void noteListening(int fd, int backlog);
static void noteBound(int fd);
static void noteConnected(int fd, const struct sockaddr *addr, socklen_t len);
static void forgetSocket(int fd);

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

#pragma mark Loopback diagnostics

// Steam's own components talk over TCP on 127.0.0.1 (its "process pipes": Steam3Master,
// SteamClientService) and its UI connects to them by WebSocket. Their failures are silent in
// a release build, so the loopback bind/listen/connect results are logged — once per port and
// outcome, to keep the log readable.
static int loopbackPort(const struct sockaddr *addr, char *text, size_t textLen) {
  if (!addr) return -1;
  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
    if ((ntohl(in->sin_addr.s_addr) >> 24) != 127) return -1;
    inet_ntop(AF_INET, &in->sin_addr, text, (socklen_t)textLen);
    return ntohs(in->sin_port);
  }
  if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
    if (!IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr)) return -1;
    strlcpy(text, "::1", textLen);
    return ntohs(in6->sin6_port);
  }
  return -1;
}

static void logOnce(const char *what, const char *host, int port, int rc, int err) {
  static char seen[256][48];
  static int nseen;
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  char key[48];
  snprintf(key, sizeof key, "%s:%d:%d", what, port, rc == 0 ? 0 : err);
  pthread_mutex_lock(&lock);
  for (int i = 0; i < nseen; i++) if (strcmp(seen[i], key) == 0) { pthread_mutex_unlock(&lock); return; }
  if (nseen < 256) strlcpy(seen[nseen++], key, sizeof seen[0]);
  pthread_mutex_unlock(&lock);
  fprintf(stderr, "[AppKitShim] %s %s:%d -> %s\n", what, host, port, rc == 0 ? "ok" : strerror(err));
}

int listen(int fd, int backlog);
int listen(int fd, int backlog) {
  int (*real)(int, int) = (int (*)(int, int))realSym("listen");
  int rc = real(fd, backlog);
  int e = errno;
  if (rc == 0) noteListening(fd, backlog);
  struct sockaddr_storage ss;
  socklen_t sl = sizeof ss;
  char host[64];
  int port;
  if (getsockname(fd, (struct sockaddr *)&ss, &sl) == 0 && (port = loopbackPort((struct sockaddr *)&ss, host, sizeof host)) >= 0)
    logOnce("listen", host, port, rc, e);
  errno = e;
  return rc;
}

#pragma mark Loopback traffic (first bytes each way)

// Steam's UI transport accepts the TCP connection but its WebSocket upgrade never
// completes. To see where the exchange stops, the first few transfers in each direction on a
// loopback connection are logged: whether the request reaches the server, and what (if
// anything) comes back. Only sockets marked at connect/accept are logged, at most a few
// times each, and the mark is cleared at close so a reused fd number isn't logged.
#define AK_TRACK_MAX 4096
static uint8_t gTracked[AK_TRACK_MAX];   // remaining transfers to log per fd (0 = not tracked)
static int gTrackPort[AK_TRACK_MAX];

static void trackFd(int fd, int port) {
  if (fd >= 0 && fd < AK_TRACK_MAX) { gTracked[fd] = 6; gTrackPort[fd] = port; }
}

// The real calls, looked up once: these wrappers sit on every read and write in the process.
#define REAL_ONCE(type, name) static __typeof__((type)0) real_; if (!real_) real_ = (type)realSym(#name)

static void logTransfer(const char *dir, int fd, const void *buf, ssize_t n, int err) {
  if (fd < 0 || fd >= AK_TRACK_MAX || !gTracked[fd]) return;
  if (n < 0 && (err == EAGAIN || err == EINTR)) return;   // nothing happened yet
  gTracked[fd]--;
  // HTTP (the WebSocket upgrade request and the server's answer) is logged whole — its
  // headers are the point; anything else only as a short sample.
  char text[1600];
  size_t limit = 200;
  if (n >= 5 && (memcmp(buf, "GET ", 4) == 0 || memcmp(buf, "HTTP/", 5) == 0)) limit = sizeof text - 3;
  size_t k = 0;
  for (ssize_t i = 0; i < n && k < limit; i++) {
    unsigned char c = ((const unsigned char *)buf)[i];
    if (c == '\r') continue;
    text[k++] = c == '\n' ? '|' : (c >= 32 && c < 127) ? (char)c : '.';
  }
  text[k] = 0;
  if (n < 0) fprintf(stderr, "[AppKitShim] %s fd %d (port %d): %s\n", dir, fd, gTrackPort[fd], strerror(err));
  else fprintf(stderr, "[AppKitShim] %s fd %d (port %d): %zd bytes: %s\n", dir, fd, gTrackPort[fd], n, text);
}

ssize_t recv(int fd, void *buf, size_t len, int flags);
ssize_t recv(int fd, void *buf, size_t len, int flags) {
  REAL_ONCE(ssize_t (*)(int, void *, size_t, int), recv);
  ssize_t n = real_(fd, buf, len, flags);
  int e = errno;
  logTransfer("recv", fd, buf, n, e);
  errno = e;
  return n;
}

ssize_t send(int fd, const void *buf, size_t len, int flags);
ssize_t send(int fd, const void *buf, size_t len, int flags) {
  REAL_ONCE(ssize_t (*)(int, const void *, size_t, int), send);
  ssize_t n = real_(fd, buf, len, flags);
  int e = errno;
  logTransfer("send", fd, buf, n, e);
  errno = e;
  return n;
}

ssize_t read(int fd, void *buf, size_t len);
ssize_t read(int fd, void *buf, size_t len) {
  REAL_ONCE(ssize_t (*)(int, void *, size_t), read);
  ssize_t n = real_(fd, buf, len);
  if (fd >= 0 && fd < AK_TRACK_MAX && gTracked[fd]) { int e = errno; logTransfer("read", fd, buf, n, e); errno = e; }
  return n;
}

ssize_t write(int fd, const void *buf, size_t len);
ssize_t write(int fd, const void *buf, size_t len) {
  REAL_ONCE(ssize_t (*)(int, const void *, size_t), write);
  ssize_t n = real_(fd, buf, len);
  if (fd >= 0 && fd < AK_TRACK_MAX && gTracked[fd]) { int e = errno; logTransfer("write", fd, buf, n, e); errno = e; }
  return n;
}

int close(int fd);
int close(int fd) {
  REAL_ONCE(int (*)(int), close);
  forgetSocket(fd);
  if (fd >= 0 && fd < AK_TRACK_MAX && gTrackPort[fd]) {
    fprintf(stderr, "[AppKitShim] close fd %d (port %d)\n", fd, gTrackPort[fd]);
    gTracked[fd] = 0;
    gTrackPort[fd] = 0;
  }
  return real_(fd);
}

// Whether a loopback server ever takes a connection, and on which port.
int accept(int fd, struct sockaddr *addr, socklen_t *len);
int accept(int fd, struct sockaddr *addr, socklen_t *len) {
  int (*real)(int, struct sockaddr *, socklen_t *) = (int (*)(int, struct sockaddr *, socklen_t *))realSym("accept");
  int rc = real(fd, addr, len);
  int e = errno;
  if (!(rc < 0 && (e == EAGAIN || e == EINTR))) {
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    char host[64];
    int port;
    if (getsockname(fd, (struct sockaddr *)&ss, &sl) == 0 && (port = loopbackPort((struct sockaddr *)&ss, host, sizeof host)) >= 0) {
      logOnce("accept", host, port, rc < 0 ? rc : 0, e);
      if (rc >= 0) trackFd(rc, port);   // the server's end of this connection
    }
  }
  errno = e;
  return rc;
}

int bind(int fd, const struct sockaddr *addr, socklen_t len) {
  int (*real)(int, const struct sockaddr *, socklen_t) = (int (*)(int, const struct sockaddr *, socklen_t))realSym("bind");
  struct sockaddr_un local;
  if (!remap(addr, len, &local)) {
    int rc = real(fd, addr, len);
    int e = errno;
    if (rc == 0) noteBound(fd);
    char host[64];
    int port = loopbackPort(addr, host, sizeof host);
    if (port >= 0) logOnce("bind", host, port, rc, e);
    errno = e;
    return rc;
  }
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
  if (!remap(addr, len, &local)) {
    int rc = real(fd, addr, len);
    int e = errno;
    if (rc == 0) noteConnected(fd, addr, len);
    char host[64];
    int port;
    // Every loopback target is recorded (a non-blocking connect reports EINPROGRESS and only
    // fails later), so the log shows which port each client actually tries.
    if ((port = loopbackPort(addr, host, sizeof host)) >= 0) {
      logOnce("connect", host, port, rc, e);
      if (rc == 0 || e == EINPROGRESS) trackFd(fd, port);   // the client's end
    }
    errno = e;
    return rc;
  }
  return real(fd, (const struct sockaddr *)&local, (socklen_t)local.sun_len);
}

#pragma mark Sockets after the app was suspended

// iOS may take back a suspended app's sockets ("defunct" them; Apple's TN2277): a listening
// socket then never accepts again and a UDP socket fails every call. Steam never notices - its
// local servers (the UI's transport, its process pipes) stopped taking connections, so Big
// Picture lost the client for good (installs, game pages, search did nothing) and Steam's
// network thread spun on a dead socket at full speed. So listening TCP sockets and bound UDP
// sockets are noted (address, backlog, a UDP socket's peer), and when the app comes back to
// the foreground each whose address is free again - iOS took it - is made anew on that address
// and put in its place under the same descriptor (dup2): Steam goes on with it unaware.
typedef struct {
  int fd, type, backlog;
  struct sockaddr_storage addr, peer;
  socklen_t addrLen, peerLen;
} ak_sock;
static ak_sock gSocks[256];
static int gSockCount;
static pthread_mutex_t gSockLock = PTHREAD_MUTEX_INITIALIZER;

static void watchForeground(void);

static ak_sock *sockFor(int fd) {   // with gSockLock held
  for (int i = 0; i < gSockCount; i++) if (gSocks[i].fd == fd) return &gSocks[i];
  return NULL;
}

static void noteSocket(int fd, int type, int backlog) {
  struct sockaddr_storage ss;
  socklen_t sl = sizeof ss;
  if (getsockname(fd, (struct sockaddr *)&ss, &sl) != 0 || (ss.ss_family != AF_INET && ss.ss_family != AF_INET6)) return;
  pthread_mutex_lock(&gSockLock);
  ak_sock *k = sockFor(fd);
  if (!k && gSockCount < 256) { k = &gSocks[gSockCount++]; memset(k, 0, sizeof *k); }
  if (k) {
    k->fd = fd;
    k->type = type;
    k->backlog = backlog;
    k->addr = ss;
    k->addrLen = sl;
  }
  pthread_mutex_unlock(&gSockLock);
  watchForeground();
}

static void noteListening(int fd, int backlog) { noteSocket(fd, SOCK_STREAM, backlog); }

static void noteBound(int fd) {
  int type = 0;
  socklen_t l = sizeof type;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &l) == 0 && type == SOCK_DGRAM) noteSocket(fd, SOCK_DGRAM, 0);
}

static void noteConnected(int fd, const struct sockaddr *addr, socklen_t len) {
  pthread_mutex_lock(&gSockLock);
  ak_sock *k = sockFor(fd);
  if (k && k->type == SOCK_DGRAM && len <= sizeof k->peer) { memcpy(&k->peer, addr, len); k->peerLen = len; }
  pthread_mutex_unlock(&gSockLock);
}

static void forgetSocket(int fd) {
  pthread_mutex_lock(&gSockLock);
  for (int i = 0; i < gSockCount; i++)
    if (gSocks[i].fd == fd) { gSocks[i] = gSocks[--gSockCount]; break; }
  pthread_mutex_unlock(&gSockLock);
}

static void reviveSockets(void) {
  int (*realBind)(int, const struct sockaddr *, socklen_t) = (int (*)(int, const struct sockaddr *, socklen_t))realSym("bind");
  int (*realListen)(int, int) = (int (*)(int, int))realSym("listen");
  int (*realConnect)(int, const struct sockaddr *, socklen_t) = (int (*)(int, const struct sockaddr *, socklen_t))realSym("connect");
  int (*realClose)(int) = (int (*)(int))realSym("close");
  static ak_sock socks[256];
  pthread_mutex_lock(&gSockLock);
  int n = gSockCount;
  memcpy(socks, gSocks, sizeof(ak_sock) * (size_t)n);
  pthread_mutex_unlock(&gSockLock);
  int revived = 0;
  for (int i = 0; i < n; i++) {
    ak_sock *k = &socks[i];
    int s = socket(k->addr.ss_family, k->type, 0);
    if (s < 0) continue;
    int one = 1;
    if (k->type == SOCK_STREAM) setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (realBind(s, (struct sockaddr *)&k->addr, k->addrLen) != 0) { realClose(s); continue; }   // still its own: alive
    int v;
    socklen_t l = sizeof v;
    int flags = fcntl(k->fd, F_GETFL);
    if (flags >= 0) fcntl(s, F_SETFL, flags);
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    if (getsockopt(k->fd, SOL_SOCKET, SO_RCVBUF, &v, &l) == 0) setsockopt(s, SOL_SOCKET, SO_RCVBUF, &v, sizeof v);
    l = sizeof v;
    if (getsockopt(k->fd, SOL_SOCKET, SO_SNDBUF, &v, &l) == 0) setsockopt(s, SOL_SOCKET, SO_SNDBUF, &v, sizeof v);
    if (k->type == SOCK_STREAM && realListen(s, k->backlog) != 0) { realClose(s); continue; }
    if (k->type == SOCK_DGRAM && k->peerLen) realConnect(s, (struct sockaddr *)&k->peer, k->peerLen);
    if (dup2(s, k->fd) < 0) { realClose(s); continue; }
    realClose(s);
    char host[64] = "?";
    int port = 0;
    if (k->addr.ss_family == AF_INET) {
      inet_ntop(AF_INET, &((struct sockaddr_in *)&k->addr)->sin_addr, host, sizeof host);
      port = ntohs(((struct sockaddr_in *)&k->addr)->sin_port);
    } else {
      inet_ntop(AF_INET6, &((struct sockaddr_in6 *)&k->addr)->sin6_addr, host, sizeof host);
      port = ntohs(((struct sockaddr_in6 *)&k->addr)->sin6_port);
    }
    fprintf(stderr, "[AppKitShim] %s socket %s:%d (fd %d) was taken back while the app was suspended: made anew\n",
            k->type == SOCK_STREAM ? "listening" : "UDP", host, port, k->fd);
    revived++;
  }
  if (n) fprintf(stderr, "[AppKitShim] back in the foreground: %d of %d listening/UDP sockets made anew\n", revived, n);
}

static void watchForeground(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                                                       queue:nil usingBlock:^(NSNotification *n) { reviveSockets(); }];
    });
  });
}

// What Steam's network thread keeps getting from a socket (an error other than "nothing yet"),
// once per error: a dead socket it spins on shows here.
ssize_t recvfrom(int fd, void *buf, size_t len, int flags, struct sockaddr *from, socklen_t *fromLen);
ssize_t recvfrom(int fd, void *buf, size_t len, int flags, struct sockaddr *from, socklen_t *fromLen) {
  REAL_ONCE(ssize_t (*)(int, void *, size_t, int, struct sockaddr *, socklen_t *), recvfrom);
  ssize_t n = real_(fd, buf, len, flags, from, fromLen);
  if (n < 0) {
    int e = errno;
    if (e != EAGAIN && e != EINTR) {
      static int seen[8], nseen;
      int logged = 0;
      for (int i = 0; i < nseen; i++) logged |= seen[i] == e;
      if (!logged && nseen < 8) {
        seen[nseen++] = e;
        fprintf(stderr, "[AppKitShim] recvfrom fd %d: %s\n", fd, strerror(e));
      }
    }
    errno = e;
  }
  return n;
}
