// The Safari-engine web helper: a stand-in for Steam Helper (Steam's CEF program) that speaks
// the same protocol to the client, so Steam's interface is shown by WebKit (WKWebView, with
// Apple's JIT and GPU) instead of an in-process Chromium that iOS only lets interpret.
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
//   then the protobuf (HTMLMessages.h has the schema). The handle in that header is the one
//   that counts; the message's own browser_handle field is often left at -1.
//
// This file runs the connection on its own thread, logs every command to
// Documents/web-helper.log, and hands them to WebHelperWeb.m on the main thread, in order.
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unistd.h>
#import "HTMLMessages.h"
#import "SteamIPC.h"
#import "WebHelper.h"

int AKWebHelperMain(int argc, char **argv);

#pragma mark Logging

static FILE *gLogFile;
static uint64_t gStart;

static double elapsed(void) { return (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC) - gStart) / 1e9; }

void AKWHLog(BOOL console, NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  const char *text = line.UTF8String;
  if (gLogFile) fprintf(gLogFile, "%8.3f %s\n", elapsed(), text);
  if (console) fprintf(stderr, "[WebHelper] %s\n", text);
}

// Once per app run: a helper Steam restarts keeps writing after the first one's lines.
static void openLog(void) {
  if (gLogFile) return;
  NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  gLogFile = fopen([docs stringByAppendingPathComponent:@"web-helper.log"].fileSystemRepresentation, "w");
  if (gLogFile) setvbuf(gLogFile, NULL, _IOLBF, 0);
  gStart = clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

NSString *AKWHCommandName(uint32_t cmd) {
  const AKHTMLCommandInfo *info = AKHTMLCommand(cmd);
  if (!info) return [NSString stringWithFormat:@"Command%u", cmd];
  return info->guessed ? [NSString stringWithFormat:@"%s?", info->name] : @(info->name);
}

#pragma mark Clients

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

static AKSteamStream *gMaster;
static AKSteamEvent *gMasterEvent;
static NSMutableArray<AKWebHelperClient *> *gClients;
static AKWebHelperClient *gClient;   // Steam's client: the one connection commands go to
static atomic_bool gShutdown;
static unsigned gRegistered;

#pragma mark Sending

// Write one command to Steam. Safe from any thread: the stream serializes writers.
BOOL AKWHSend(uint32_t cmd, uint32_t browser, NSDictionary *fields) {
  AKWebHelperClient *client;
  @synchronized(AKWebHelperClient.class) { client = gClient; }
  const AKHTMLCommandInfo *info = AKHTMLCommand(cmd);
  if (!client || !info || info->message < 0) return NO;
  NSData *body = AKHTMLEncode(info->message, fields);
  uint32_t head[3] = { (uint32_t)body.length, cmd, browser };
  NSMutableData *buf = [NSMutableData dataWithBytes:head length:sizeof head];
  [buf appendData:body];
  uint32_t put = AKSteamStreamPut(client->toSteam, buf.bytes, (uint32_t)buf.length);
  AKWHLog(NO, @"-> %@ (browser %u) %@%@", AKWHCommandName(cmd), browser, AKHTMLDescribe(fields, 600),
          put == buf.length ? @"" : [NSString stringWithFormat:@"  FAILED (%u of %lu bytes)", put, (unsigned long)buf.length]);
  return put == buf.length;
}

#pragma mark Commands from the client

static void handleCommand(AKWebHelperClient *client, uint32_t cmd, uint32_t browser, NSData *body) {
  const AKHTMLCommandInfo *info = AKHTMLCommand(cmd);
  NSDictionary *msg = AKHTMLDecode(info ? info->message : -1, body.bytes, body.length);
  if (cmd == kAKWHJSRegisterMethod) {
    // Hundreds of these arrive at start-up (one per SteamClient API method): all in the file,
    // a count on the console.
    if (++gRegistered % 250 == 0) AKWHLog(YES, @"%u SteamClient methods registered so far", gRegistered);
    AKWHLog(NO, @"<- JSRegisterMethod (browser %u) %@ type %@", browser, msg[@"name"], msg[@"method_type"] ?: @"?");
  } else {
    AKWHLog(NO, @"<- %@ (browser %u, %lu bytes) %@", AKWHCommandName(cmd), browser, (unsigned long)body.length, AKHTMLDescribe(msg, 1500));
  }
  dispatch_async(dispatch_get_main_queue(), ^{ AKWHWebHandleCommand(cmd, browser, msg); });
}

// Read every complete command a client has written.
static void serviceClient(AKWebHelperClient *client) {
  while (AKSteamStreamAvailable(client->fromSteam) >= 12) {
    uint32_t head[3];
    if (AKSteamStreamGet(client->fromSteam, head, sizeof head) != sizeof head) return;
    if (head[0] > 32u << 20 || head[1] == 0 || head[1] >= 0xa0) {
      AKWHLog(YES, @"client %u's command stream is corrupt (length %u, command %u); dropping the client", client->pid, head[0], head[1]);
      [gClients removeObject:client];
      @synchronized(AKWebHelperClient.class) { if (gClient == client) gClient = nil; }
      return;
    }
    NSMutableData *body = [NSMutableData dataWithLength:head[0]];
    if (head[0] && AKSteamStreamGet(client->fromSteam, body.mutableBytes, head[0]) != head[0]) {
      AKWHLog(YES, @"client %u: command %@ cut short", client->pid, AKWHCommandName(head[1]));
      return;
    }
    @autoreleasepool { handleCommand(client, head[1], head[2], body); }
  }
}

#pragma mark The master stream

static void connectClient(uint32_t version, uint32_t pid, const char *replyName) {
  if (version != 1) AKWHLog(YES, @"client %u speaks protocol version %u (expected 1); trying anyway", pid, version);
  AKSteamStream *reply = AKSteamStreamOpen(replyName, 0x2000, 1000, AKSteamStreamOpenOrCreate);
  if (!reply) { AKWHLog(YES, @"client %u: can't open its reply stream %s", pid, replyName); return; }
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
    AKWHLog(YES, @"client %u: can't create its command streams %s_*", pid, base);
    AKSteamStreamClose(reply);
    return;
  }
  [gClients addObject:client];
  @synchronized(AKWebHelperClient.class) { gClient = client; }
  struct { uint32_t cmd, pid; char name[64]; } answer = { 2, (uint32_t)getpid(), { 0 } };
  strlcpy(answer.name, base, sizeof answer.name);
  uint32_t put = AKSteamStreamPut(reply, &answer, sizeof answer);
  AKSteamStreamClose(reply);
  AKWHLog(YES, @"client %u connected: streams %s_client/_server%@", pid, base, put == sizeof answer ? @"" : @" (reply FAILED)");
}

static void serviceMaster(void) {
  while (AKSteamStreamAvailable(gMaster) >= 4) {
    uint32_t cmd = 0;
    if (AKSteamStreamGet(gMaster, &cmd, 4) != 4) return;
    if (cmd == 1) {
      struct { uint32_t version, pid; char name[64]; } req;
      if (AKSteamStreamGet(gMaster, &req, sizeof req) != sizeof req) { AKWHLog(YES, @"connect request cut short"); return; }
      req.name[63] = 0;
      connectClient(req.version, req.pid, req.name);
    } else if (cmd == 3) {
      uint32_t pid = 0;
      AKSteamStreamGet(gMaster, &pid, 4);
      AKWHLog(YES, @"client %u disconnected", pid);
      for (AKWebHelperClient *c in [gClients copy]) {
        if (c->pid != pid) continue;
        [gClients removeObject:c];
        @synchronized(AKWebHelperClient.class) { if (gClient == c) gClient = nil; }
      }
    } else if (cmd == 4) {
      AKWHLog(YES, @"asked to shut down");
      atomic_store(&gShutdown, true);
    } else {
      AKWHLog(YES, @"unknown master command %u", cmd);
    }
  }
}

#pragma mark Main

// Ending this helper as a crashed Steam Helper would: the connection loop stops and
// AKWebHelperMain returns 1, so the stand-in process exits and Steam's client starts a new
// helper ("Restart webhelper process") and builds its interface again. Any thread.
static atomic_int gExitStatus;

void AKWHExitForRestart(void) {
  atomic_store(&gExitStatus, 1);
  atomic_store(&gShutdown, true);
  if (gMasterEvent) AKSteamEventSet(gMasterEvent);
}

int AKWebHelperMain(int argc, char **argv) {
  openLog();
  atomic_store(&gShutdown, false);
  atomic_store(&gExitStatus, 0);
  uint32_t steamPid = (uint32_t)getpid();
  NSString *clientUI;
  NSMutableString *line = [NSMutableString string];
  for (int i = 0; i < argc; i++) {
    [line appendFormat:@"%s%s", i ? " " : "", argv[i]];
    if (strncmp(argv[i], "-steampid=", 10) == 0) steamPid = (uint32_t)strtoul(argv[i] + 10, NULL, 10);
    if (strncmp(argv[i], "-clientui=", 10) == 0) clientUI = @(argv[i] + 10);
  }
  AKWHLog(YES, @"Safari-engine web helper starting: %@", line);
  // Steam Helper sits beside clientui, as in Steam's own folder.
  if (clientUI)
    AKWHFontsSetPaths(clientUI, [clientUI.stringByDeletingLastPathComponent
                                    stringByAppendingPathComponent:@"Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper"]);

  gClients = [NSMutableArray array];
  char name[128];
  snprintf(name, sizeof name, "SteamChrome_MasterStream_uid%d_spid%u", (int)getuid(), steamPid);
  gMaster = AKSteamStreamOpen(name, 0x2000, 1000, AKSteamStreamForceCreate);
  char eventName[128];
  snprintf(eventName, sizeof eventName, "SteamChrome_MasterStream_Event_uid%d_spid%u", (int)getuid(), steamPid);
  gMasterEvent = AKSteamEventCreate(eventName, false, false, true);
  if (!gMaster || !gMasterEvent) {
    AKWHLog(YES, @"can't create the master stream %s or its event; giving up", name);
    return 1;
  }
  AKWHLog(YES, @"waiting for Steam on %s", name);

  // The client sets the master event after every command it writes, to any stream, so one
  // wait covers them all; after waking, everything pending is drained.
  while (!atomic_load(&gShutdown)) {
    AKSteamEventWait(gMasterEvent, -1);
    @autoreleasepool {
      serviceMaster();
      for (AKWebHelperClient *client in [gClients copy]) serviceClient(client);
    }
  }
  int status = atomic_load(&gExitStatus);
  AKWHLog(YES, @"stopped%@", status ? @" (exiting for Steam to start a new helper)" : @"");
  @synchronized(AKWebHelperClient.class) { gClient = nil; }
  [gClients removeAllObjects];
  AKSteamEventFree(gMasterEvent);
  gMasterEvent = NULL;
  AKSteamStreamClose(gMaster);
  gMaster = NULL;
  return status;
}
