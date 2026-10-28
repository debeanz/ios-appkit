// The Safari-mode web helper: a stand-in for Steam Helper (Steam's CEF program) that speaks
// the same protocol to the client, so Steam's interface can be shown by WebKit (WKWebView,
// with Apple's JIT and GPU) instead of an in-process Chromium that iOS only lets interpret.
//
// The client (chromehtml.dylib) starts "Steam Helper" with -steampid=<pid>; the host runs
// AKWebHelperMain in its place when the Safari engine is chosen. The protocol, recovered
// from both sides' arm64 code (Steam Helper's CChromeIPCServer, chromehtml's
// CChromeIPCClient):
//
//   Master stream "SteamChrome_MasterStream_uid<uid>_spid<pid>" (0x2000 bytes; the helper
//   creates it) and event "SteamChrome_MasterStream_Event_uid<uid>_spid<pid>", which the
//   client sets after everything it writes. On the master stream the client writes a u32:
//     1 connect     + {u32 version = 1, u32 client pid, char[64] reply stream name}. The
//                   helper creates the stream pair "<base>_client" (client -> helper) and
//                   "<base>_server" (helper -> client), 25 MB each, then writes
//                   {u32 2, u32 helper pid, char[64] base} to the reply stream.
//     3 disconnect  + {u32 client pid}
//     4 shut down
//   Commands each way: u32 protobuf length, u32 eHTMLCommands value, u32 browser handle,
//   then the protobuf (HTMLMessages.h has the schema).
//
// For now the helper accepts Steam's connection, logs every command it gets to
// Documents/web-helper.log (and a summary to the console), and answers browser creation so
// the client carries on; pages are not shown yet.
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unistd.h>
#import "HTMLMessages.h"
#import "SteamIPC.h"

int AKWebHelperMain(int argc, char **argv);

// eHTMLCommands values used here (data/htmlcommands.json has them all).
enum {
  kCmdBrowserCreate = 3,
  kCmdBrowserRemove = 6,
  kCmdJSRegisterMethod = 36,
  kCmdBrowserCreateResponse = 88,
  kCmdBrowserReady = 90,
};

#pragma mark Logging

static FILE *gLogFile;
static uint64_t gStart;

static double elapsed(void) { return (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC) - gStart) / 1e9; }

// Everything to Documents/web-helper.log; console lines (Steam's console log) only when asked.
static void helperLog(BOOL console, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void helperLog(BOOL console, NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  const char *text = line.UTF8String;
  if (gLogFile) fprintf(gLogFile, "%8.3f %s\n", elapsed(), text);
  if (console) fprintf(stderr, "[WebHelper] %s\n", text);
}

static void openLog(void) {
  NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  gLogFile = fopen([docs stringByAppendingPathComponent:@"web-helper.log"].fileSystemRepresentation, "w");
  if (gLogFile) setvbuf(gLogFile, NULL, _IOLBF, 0);
  gStart = clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

#pragma mark Clients and browsers

@interface AKWebHelperClient : NSObject {
 @public
  uint32_t pid;
  AKSteamStream *fromSteam, *toSteam;
}
@end
@implementation AKWebHelperClient
- (void)dealloc {
  AKSteamStreamClose(fromSteam);
  AKSteamStreamClose(toSteam);
}
@end

@interface AKWebHelperBrowser : NSObject
@property(nonatomic) uint32_t handle;
@property(nonatomic, weak) AKWebHelperClient *client;
@property(nonatomic, copy) NSDictionary *creation;
@property(nonatomic) NSUInteger registeredMethods;
@end
@implementation AKWebHelperBrowser
@end

static AKSteamStream *gMaster;
static AKSteamEvent *gMasterEvent;
static NSMutableArray<AKWebHelperClient *> *gClients;
static NSMutableDictionary<NSNumber *, AKWebHelperBrowser *> *gBrowsers;
static uint32_t gNextBrowserIndex = 1;
static atomic_bool gShutdown;

static NSString *commandName(uint32_t cmd) {
  const AKHTMLCommandInfo *info = AKHTMLCommand(cmd);
  if (!info) return [NSString stringWithFormat:@"Command%u", cmd];
  return info->guessed ? [NSString stringWithFormat:@"%s?", info->name] : @(info->name);
}

#pragma mark Sending

// Write one command to a client. Safe from any thread: the stream serializes writers.
static BOOL sendCommand(AKWebHelperClient *client, uint32_t cmd, uint32_t browser, NSDictionary *fields) {
  const AKHTMLCommandInfo *info = AKHTMLCommand(cmd);
  if (!client || !info || info->message < 0) return NO;
  NSData *body = AKHTMLEncode(info->message, fields);
  uint32_t head[3] = { (uint32_t)body.length, cmd, browser };
  NSMutableData *buf = [NSMutableData dataWithBytes:head length:sizeof head];
  [buf appendData:body];
  uint32_t put = AKSteamStreamPut(client->toSteam, buf.bytes, (uint32_t)buf.length);
  helperLog(NO, @"-> %@ (browser %u) %@%@", commandName(cmd), browser, AKHTMLDescribe(fields, 400),
            put == buf.length ? @"" : [NSString stringWithFormat:@"  FAILED (%u of %lu bytes)", put, (unsigned long)buf.length]);
  return put == buf.length;
}

#pragma mark Commands from the client

static void createBrowser(AKWebHelperClient *client, NSDictionary *msg) {
  // Handles are an index in the low 16 bits and a serial in the high 16, as the helper's are.
  uint32_t handle = (1u << 16) | (gNextBrowserIndex++ & 0xffff);
  AKWebHelperBrowser *b = [AKWebHelperBrowser new];
  b.handle = handle;
  b.client = client;
  b.creation = msg;
  gBrowsers[@(handle)] = b;
  helperLog(YES, @"browser %u created: type %@, %@x%@, %@", handle, msg[@"browser_type"] ?: @0,
            msg[@"initial_width"] ?: @"?", msg[@"initial_height"] ?: @"?", msg[@"initial_url"] ?: @"(no URL)");
  sendCommand(client, kCmdBrowserCreateResponse, handle, @{ @"browser_handle": @(handle), @"request_id": msg[@"request_id"] ?: @0 });
  sendCommand(client, kCmdBrowserReady, handle, @{ @"browser_handle": @(handle) });
}

static void handleCommand(AKWebHelperClient *client, uint32_t cmd, uint32_t browser, NSData *body) {
  const AKHTMLCommandInfo *info = AKHTMLCommand(cmd);
  NSDictionary *msg = AKHTMLDecode(info ? info->message : -1, body.bytes, body.length);
  AKWebHelperBrowser *b = gBrowsers[@(browser)];
  if (cmd == kCmdJSRegisterMethod) {
    // Hundreds of these arrive at start-up (one per SteamClient API method): name them all in
    // the file, count them on the console.
    b.registeredMethods++;
    helperLog(NO, @"<- JSRegisterMethod (browser %u) %@ type %@", browser, msg[@"name"], msg[@"method_type"] ?: @"?");
    return;
  }
  helperLog(NO, @"<- %@ (browser %u, %lu bytes) %@", commandName(cmd), browser, (unsigned long)body.length, AKHTMLDescribe(msg, 1500));
  switch (cmd) {
    case kCmdBrowserCreate:
      createBrowser(client, msg);
      break;
    case kCmdBrowserRemove:
      if (b) helperLog(YES, @"browser %u removed (%lu JS methods had been registered)", browser, (unsigned long)b.registeredMethods);
      [gBrowsers removeObjectForKey:@(browser)];
      break;
    default:
      break;
  }
}

// Read every complete command a client has written.
static void serviceClient(AKWebHelperClient *client) {
  while (AKSteamStreamAvailable(client->fromSteam) >= 12) {
    uint32_t head[3];
    if (AKSteamStreamGet(client->fromSteam, head, sizeof head) != sizeof head) return;
    if (head[0] > 32u << 20 || head[1] == 0 || head[1] >= 0xa0) {
      helperLog(YES, @"client %u's command stream is corrupt (length %u, command %u); dropping the client", client->pid, head[0], head[1]);
      [gClients removeObject:client];
      return;
    }
    NSMutableData *body = [NSMutableData dataWithLength:head[0]];
    if (head[0] && AKSteamStreamGet(client->fromSteam, body.mutableBytes, head[0]) != head[0]) {
      helperLog(YES, @"client %u: command %@ cut short", client->pid, commandName(head[1]));
      return;
    }
    @autoreleasepool { handleCommand(client, head[1], head[2], body); }
  }
}

#pragma mark The master stream

static void connectClient(uint32_t version, uint32_t pid, const char *replyName) {
  if (version != 1) helperLog(YES, @"client %u speaks protocol version %u (expected 1); trying anyway", pid, version);
  AKSteamStream *reply = AKSteamStreamOpen(replyName, 0x2000, 1000, AKSteamStreamOpenOrCreate);
  if (!reply) { helperLog(YES, @"client %u: can't open its reply stream %s", pid, replyName); return; }
  char base[64];
  snprintf(base, sizeof base, "SteamChrome_ClientStream_%u_%u", arc4random_uniform(0x10000), pid);
  char name[96];
  AKWebHelperClient *client = [AKWebHelperClient new];
  client->pid = pid;
  snprintf(name, sizeof name, "%s_client", base);
  client->fromSteam = AKSteamStreamOpen(name, 0x1900000, 1000, AKSteamStreamOpenOrCreate);
  snprintf(name, sizeof name, "%s_server", base);
  client->toSteam = AKSteamStreamOpen(name, 0x1900000, 1000, AKSteamStreamOpenOrCreate);
  if (!client->fromSteam || !client->toSteam) {
    helperLog(YES, @"client %u: can't create its command streams %s_*", pid, base);
    AKSteamStreamClose(reply);
    return;
  }
  [gClients addObject:client];
  struct { uint32_t cmd, pid; char name[64]; } answer = { 2, (uint32_t)getpid(), { 0 } };
  strlcpy(answer.name, base, sizeof answer.name);
  uint32_t put = AKSteamStreamPut(reply, &answer, sizeof answer);
  AKSteamStreamClose(reply);
  helperLog(YES, @"client %u connected: streams %s_client/_server%@", pid, base, put == sizeof answer ? @"" : @" (reply FAILED)");
}

static void serviceMaster(void) {
  while (AKSteamStreamAvailable(gMaster) >= 4) {
    uint32_t cmd = 0;
    if (AKSteamStreamGet(gMaster, &cmd, 4) != 4) return;
    if (cmd == 1) {
      struct { uint32_t version, pid; char name[64]; } req;
      if (AKSteamStreamGet(gMaster, &req, sizeof req) != sizeof req) { helperLog(YES, @"connect request cut short"); return; }
      req.name[63] = 0;
      connectClient(req.version, req.pid, req.name);
    } else if (cmd == 3) {
      uint32_t pid = 0;
      AKSteamStreamGet(gMaster, &pid, 4);
      helperLog(YES, @"client %u disconnected", pid);
      for (AKWebHelperClient *c in [gClients copy]) if (c->pid == pid) [gClients removeObject:c];
    } else if (cmd == 4) {
      helperLog(YES, @"asked to shut down");
      atomic_store(&gShutdown, true);
    } else {
      helperLog(YES, @"unknown master command %u", cmd);
    }
  }
}

#pragma mark Main

int AKWebHelperMain(int argc, char **argv) {
  openLog();
  uint32_t steamPid = (uint32_t)getpid();
  NSMutableString *line = [NSMutableString string];
  for (int i = 0; i < argc; i++) {
    [line appendFormat:@"%s%s", i ? " " : "", argv[i]];
    if (strncmp(argv[i], "-steampid=", 10) == 0) steamPid = (uint32_t)strtoul(argv[i] + 10, NULL, 10);
  }
  helperLog(YES, @"Safari-engine web helper starting: %@", line);

  gClients = [NSMutableArray array];
  gBrowsers = [NSMutableDictionary dictionary];
  char name[128];
  snprintf(name, sizeof name, "SteamChrome_MasterStream_uid%d_spid%u", (int)getuid(), steamPid);
  gMaster = AKSteamStreamOpen(name, 0x2000, 1000, AKSteamStreamForceCreate);
  char eventName[128];
  snprintf(eventName, sizeof eventName, "SteamChrome_MasterStream_Event_uid%d_spid%u", (int)getuid(), steamPid);
  gMasterEvent = AKSteamEventCreate(eventName, false, false, true);
  if (!gMaster || !gMasterEvent) {
    helperLog(YES, @"can't create the master stream %s or its event; giving up", name);
    return 1;
  }
  helperLog(YES, @"waiting for Steam on %s", name);

  // The client sets the master event after every command it writes, to any stream, so one
  // wait covers them all; after waking, everything pending is drained.
  while (!atomic_load(&gShutdown)) {
    AKSteamEventWait(gMasterEvent, -1);
    @autoreleasepool {
      serviceMaster();
      for (AKWebHelperClient *client in [gClients copy]) serviceClient(client);
    }
  }
  helperLog(YES, @"stopped");
  [gClients removeAllObjects];
  AKSteamEventFree(gMasterEvent);
  AKSteamStreamClose(gMaster);
  return 0;
}
