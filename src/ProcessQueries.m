// Command-line queries a Mac program runs with popen, answered in process.
//
// iOS won't start another program, so popen always fails here. Most callers treat that as
// "no answer", but Steam's WebUI transport uses one to decide who may connect: before it
// completes a WebSocket upgrade it asks `/usr/sbin/lsof -F up -i TCP@<peer address>` which
// process owns the other end, and refuses anything it can't attribute to Steam — so on iOS
// its own interface got "403 Forbidden" on every connection and the screen stayed blank.
//
// That query has an exact in-process answer: look through this app's own sockets for one
// whose local or remote address is the one asked about. If one is found, the owner is this
// process, reported the way lsof's -F (field) output does it ("p<pid>" and "u<uid>" lines).
// If none is (a connection from some other app), the answer is empty and Steam still refuses
// it, as it would on a Mac. Any other command goes to the real popen; its refusal is logged.
// libSystem is routed through the shim umbrella, so the client's popen/pclose bind here.
#import <arpa/inet.h>
#import <dlfcn.h>
#import <errno.h>
#import <netinet/in.h>
#import <pthread.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

// AppKit-style names bound to the C symbols by asm label (the SDK marks popen off-limits on
// iOS, so it is not redeclared under its own name).
FILE *AKPopen(const char *command, const char *mode) __asm__("_popen");
int AKPclose(FILE *stream) __asm__("_pclose");

static void *realSym(const char *name) {
  static void *libSystem;
  if (!libSystem) libSystem = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
  return libSystem ? dlsym(libSystem, name) : NULL;
}

// Streams this file opened over an in-memory answer, with the buffer each one reads from.
#define AK_MAX_ANSWERS 32
static struct { FILE *stream; char *buffer; } gAnswers[AK_MAX_ANSWERS];
static pthread_mutex_t gAnswerLock = PTHREAD_MUTEX_INITIALIZER;

// Parse "127.0.0.1:54321", "[::1]:54321" or "::1:54321" into an address and port.
static int parseEndpoint(const char *text, struct sockaddr_storage *out) {
  char host[128];
  const char *colon = strrchr(text, ':');
  if (!colon) return 0;
  int port = atoi(colon + 1);
  size_t n = (size_t)(colon - text);
  if (n == 0 || n >= sizeof host || port <= 0 || port > 65535) return 0;
  memcpy(host, text, n);
  host[n] = 0;
  if (host[0] == '[' && host[n - 1] == ']') { memmove(host, host + 1, n - 2); host[n - 2] = 0; }
  memset(out, 0, sizeof *out);
  struct sockaddr_in *in4 = (struct sockaddr_in *)out;
  struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)out;
  if (inet_pton(AF_INET, host, &in4->sin_addr) == 1) {
    in4->sin_family = AF_INET; in4->sin_len = sizeof *in4; in4->sin_port = htons((uint16_t)port);
    return 1;
  }
  if (inet_pton(AF_INET6, host, &in6->sin6_addr) == 1) {
    in6->sin6_family = AF_INET6; in6->sin6_len = sizeof *in6; in6->sin6_port = htons((uint16_t)port);
    return 1;
  }
  return 0;
}

static int sameEndpoint(const struct sockaddr *a, const struct sockaddr_storage *want) {
  if (a->sa_family != want->ss_family) return 0;
  if (a->sa_family == AF_INET) {
    const struct sockaddr_in *x = (const struct sockaddr_in *)a, *y = (const struct sockaddr_in *)want;
    return x->sin_port == y->sin_port && x->sin_addr.s_addr == y->sin_addr.s_addr;
  }
  if (a->sa_family == AF_INET6) {
    const struct sockaddr_in6 *x = (const struct sockaddr_in6 *)a, *y = (const struct sockaddr_in6 *)want;
    return x->sin6_port == y->sin6_port && memcmp(&x->sin6_addr, &y->sin6_addr, sizeof x->sin6_addr) == 0;
  }
  return 0;
}

// Whether one of this process's sockets has `want` as its local or remote address.
static int ownSocketAt(const struct sockaddr_storage *want) {
  int max = getdtablesize();
  if (max > 65536) max = 65536;
  for (int fd = 0; fd < max; fd++) {
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    if (getsockname(fd, (struct sockaddr *)&ss, &sl) == 0 && sameEndpoint((struct sockaddr *)&ss, want)) return 1;
    sl = sizeof ss;
    if (getpeername(fd, (struct sockaddr *)&ss, &sl) == 0 && sameEndpoint((struct sockaddr *)&ss, want)) return 1;
  }
  return 0;
}

// `lsof ... -i TCP@<endpoint>`: this process's pid and uid if it owns the endpoint, else nothing.
static char *answerLsof(const char *command) {
  const char *at = strstr(command, "TCP@");
  if (!at) return NULL;
  char endpoint[160];
  size_t n = strcspn(at + 4, " \t\r\n'\"");
  if (n == 0 || n >= sizeof endpoint) return NULL;
  memcpy(endpoint, at + 4, n);
  endpoint[n] = 0;
  struct sockaddr_storage want;
  if (!parseEndpoint(endpoint, &want)) return strdup("");
  char *out = NULL;
  if (ownSocketAt(&want)) asprintf(&out, "p%d\nu%d\n", getpid(), getuid());
  else out = strdup("");
  fprintf(stderr, "[AppKitShim] lsof TCP@%s -> %s\n", endpoint, out[0] ? "this process" : "not ours");
  return out;
}

FILE *AKPopen(const char *command, const char *mode) {
  if (command && strncmp(command, "/usr/sbin/lsof ", 15) == 0 && strstr(command, "-F") && mode && mode[0] == 'r') {
    char *answer = answerLsof(command);
    if (answer) {
      FILE *f = fmemopen(answer, strlen(answer), "r");
      if (!f) { free(answer); return NULL; }
      pthread_mutex_lock(&gAnswerLock);
      int slot = -1;
      for (int i = 0; i < AK_MAX_ANSWERS; i++) if (!gAnswers[i].stream) { slot = i; break; }
      if (slot >= 0) { gAnswers[slot].stream = f; gAnswers[slot].buffer = answer; }
      pthread_mutex_unlock(&gAnswerLock);
      if (slot < 0) { fclose(f); free(answer); errno = EMFILE; return NULL; }
      return f;
    }
  }
  FILE *(*real)(const char *, const char *) = (FILE *(*)(const char *, const char *))realSym("popen");
  FILE *f = real ? real(command, mode) : NULL;
  if (!f) fprintf(stderr, "[AppKitShim] popen refused (iOS can't run programs): %s\n", command ? command : "(null)");
  return f;
}

int AKPclose(FILE *stream) {
  pthread_mutex_lock(&gAnswerLock);
  for (int i = 0; i < AK_MAX_ANSWERS; i++) {
    if (gAnswers[i].stream == stream) {
      char *buffer = gAnswers[i].buffer;
      gAnswers[i].stream = NULL;
      gAnswers[i].buffer = NULL;
      pthread_mutex_unlock(&gAnswerLock);
      fclose(stream);
      free(buffer);
      return 0;   // exit status 0, as the program would have returned
    }
  }
  pthread_mutex_unlock(&gAnswerLock);
  int (*real)(FILE *) = (int (*)(FILE *))realSym("pclose");
  return real ? real(stream) : -1;
}
