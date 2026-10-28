// https://steamloopback.host - where Steam's interface lives - and the other hosts Steam
// maps to local folders (CMsgSetLocalFileRequestMapping, CMsgSetBrowserViewDomainRequestMapping).
//
// The page must really be https://steamloopback.host: Steam's client only accepts the UI's
// WebSocket connections from that origin. The name resolves to 127.0.0.1 and nothing listens
// there; Steam Helper answers those requests itself, from files. WKWebView won't let an app
// handle https (+[WKWebView handlesURLScheme:] says WebKit does, and setURLSchemeHandler:
// refuses such schemes), so that check is told otherwise and the Steam pages' configuration
// gets this handler for https. Every https load of those pages then comes here: mapped hosts
// are served from their folders, and the rest is fetched with NSURLSession and streamed back
// (WebKit still applies CORS to it; cookies live in the shared NSHTTPCookieStorage, where
// Steam's CMsgSetCookie goes too). WebSockets don't pass through scheme handlers and connect
// directly.
//
// A mapping is a folder plus routes: a URL path under a route's prefix comes from the route's
// folder (only with an allowed extension, if it lists any), or - url_rewrite - is always the
// route's one file (the UI's client-side routes all load index.html).
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "WebHelper.h"

@interface AKWHHostMapping : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSArray<NSDictionary *> *routes;
@end
@implementation AKWHHostMapping
@end

@interface AKWHLoad : NSObject
@property(nonatomic, strong) id<WKURLSchemeTask> schemeTask;   // only touched on the main thread
@property(nonatomic, strong) NSURL *url;
@property(nonatomic, strong) NSURLSessionDataTask *dataTask;
@property(nonatomic) BOOL stopped;
@property(nonatomic) CFAbsoluteTime started;
@end
@implementation AKWHLoad
@end

@interface AKWHLoopback : NSObject <WKURLSchemeHandler, NSURLSessionDataDelegate>
@end

static NSMutableDictionary<NSString *, AKWHHostMapping *> *gHosts;   // by lower-case host
static NSMapTable<id, AKWHLoad *> *gLoadsByTask;                      // scheme task -> load
static NSMapTable<NSURLSessionTask *, AKWHLoad *> *gLoadsBySession;   // session task -> load
static NSURLSession *gSession;
static dispatch_queue_t gFileQueue;
static unsigned gServed, gProxied;

void AKWHLoopbackMapHost(NSString *host, NSString *root, NSArray<NSDictionary *> *routes) {
  if (!host.length || !root.length) return;
  AKWHHostMapping *m = [AKWHHostMapping new];
  m.root = root;
  m.routes = routes ?: @[];
  @synchronized(AKWHHostMapping.class) {
    if (!gHosts) gHosts = [NSMutableDictionary dictionary];
    gHosts[host.lowercaseString] = m;
  }
  AKWHLog(NO, @"serving https://%@ from %@ (%lu routes)", host, root, (unsigned long)m.routes.count);
}

static AKWHHostMapping *mappingFor(NSString *host) {
  @synchronized(AKWHHostMapping.class) { return host ? gHosts[host.lowercaseString] : nil; }
}

#pragma mark Cookies

// CMsgSetCookie: host is a URL ("https://store.steampowered.com"); samesite is CEF's enum
// (0 unspecified, 1 none, 2 lax, 3 strict); expires is a Unix time (0: a session cookie).
void AKWHLoopbackSetCookie(NSDictionary *c) {
  NSURL *url = [NSURL URLWithString:c[@"host"] ?: @""];
  NSString *domain = url.host ?: c[@"host"];
  if (!domain.length || ![c[@"key"] length]) return;
  NSMutableDictionary *props = [NSMutableDictionary dictionary];
  props[NSHTTPCookieName] = c[@"key"];
  props[NSHTTPCookieValue] = c[@"value"] ?: @"";
  props[NSHTTPCookiePath] = [c[@"path"] length] ? c[@"path"] : @"/";
  props[NSHTTPCookieDomain] = domain;
  if ([c[@"secure"] boolValue]) props[NSHTTPCookieSecure] = @"TRUE";
  if ([c[@"httponly"] boolValue]) props[@"HttpOnly"] = @"TRUE";
  uint32_t expires = [c[@"expires"] unsignedIntValue];
  if (expires) props[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:expires];
  if (@available(iOS 13.0, *)) {
    int samesite = [c[@"samesite"] intValue];
    if (samesite == 2) props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;
    else if (samesite == 3) props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteStrict;
  }
  NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:props];
  if (!cookie) return;
  [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];
  dispatch_async(dispatch_get_main_queue(), ^{
    [WKWebsiteDataStore.defaultDataStore.httpCookieStore setCookie:cookie completionHandler:nil];
  });
}

#pragma mark Local files

static NSString *mimeType(NSString *path) {
  static NSDictionary *types;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    types = @{
      @"html": @"text/html; charset=utf-8", @"htm": @"text/html; charset=utf-8", @"js": @"text/javascript; charset=utf-8",
      @"mjs": @"text/javascript; charset=utf-8", @"css": @"text/css; charset=utf-8", @"json": @"application/json",
      @"map": @"application/json", @"txt": @"text/plain; charset=utf-8", @"xml": @"text/xml", @"svg": @"image/svg+xml",
      @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"gif": @"image/gif", @"webp": @"image/webp",
      @"avif": @"image/avif", @"ico": @"image/x-icon", @"woff": @"font/woff", @"woff2": @"font/woff2", @"ttf": @"font/ttf",
      @"otf": @"font/otf", @"webm": @"video/webm", @"mp4": @"video/mp4", @"m4v": @"video/mp4", @"mp3": @"audio/mpeg",
      @"wav": @"audio/wav", @"ogg": @"audio/ogg", @"m4a": @"audio/mp4", @"wasm": @"application/wasm",
    };
  });
  return types[path.pathExtension.lowercaseString] ?: @"application/octet-stream";
}

// The file a mapped URL path names, or nil.
static NSString *fileForPath(AKWHHostMapping *m, NSString *path) {
  while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
  for (NSString *part in [path componentsSeparatedByString:@"/"])
    if ([part isEqualToString:@".."]) return nil;
  for (NSDictionary *route in m.routes) {
    NSString *prefix = route[@"relative_url"];
    NSString *local = route[@"local_path"];
    if (!prefix.length || !local.length || ![path hasPrefix:prefix]) continue;
    if ([route[@"url_rewrite"] boolValue]) return local;
    NSString *rest = [path substringFromIndex:prefix.length];
    NSString *allowed = route[@"allowed_extensions"];
    if (allowed.length) {
      NSArray *exts = [allowed.lowercaseString componentsSeparatedByString:@";"];
      if (![exts containsObject:rest.pathExtension.lowercaseString]) return nil;
    }
    return [local stringByAppendingPathComponent:rest];
  }
  if (!path.length) path = @"index.html";
  return [m.root stringByAppendingPathComponent:path];
}

static void finishLoad(AKWHLoad *load, NSHTTPURLResponse *response, NSData *body, NSError *error) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (load.stopped) return;
    [gLoadsByTask removeObjectForKey:load.schemeTask];
    @try {
      if (error) {
        [load.schemeTask didFailWithError:error];
      } else {
        [load.schemeTask didReceiveResponse:response];
        if (body.length) [load.schemeTask didReceiveData:body];
        [load.schemeTask didFinish];
      }
    } @catch (NSException *e) {
      AKWHLog(NO, @"https load %@: %@", load.schemeTask.request.URL, e.reason);
    }
  });
}

static void serveFile(AKWHLoad *load, AKWHHostMapping *m) {
  NSURLRequest *request = load.schemeTask.request;
  NSURL *url = request.URL;
  NSString *range = [request valueForHTTPHeaderField:@"Range"];
  dispatch_async(gFileQueue, ^{
    NSString *file = fileForPath(m, url.path ?: @"");
    NSData *data = file ? [NSData dataWithContentsOfFile:file options:NSDataReadingMappedIfSafe error:nil] : nil;
    NSMutableDictionary *headers = [@{ @"Access-Control-Allow-Origin": @"*", @"Cache-Control": @"no-cache" } mutableCopy];
    NSInteger status = 200;
    NSData *body = data;
    if (!data) {
      status = 404;
      body = [NSData data];
      AKWHLog(NO, @"https %@: not found (%@)", url, file ?: @"outside the mapping");
    } else {
      headers[@"Content-Type"] = mimeType(file);
      headers[@"Accept-Ranges"] = @"bytes";
      // Media elements ask for byte ranges.
      unsigned long long start = 0, end = 0;
      if (range && sscanf(range.UTF8String, "bytes=%llu-%llu", &start, &end) >= 1 && start < data.length) {
        if (end == 0 || end >= data.length) end = data.length - 1;
        if (end >= start) {
          status = 206;
          body = [data subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1))];
          headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %llu-%llu/%lu", start, end, (unsigned long)data.length];
        }
      }
    }
    headers[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)body.length];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
    unsigned n = __atomic_add_fetch(&gServed, 1, __ATOMIC_RELAXED);
    if (n <= 40 || n % 200 == 0)
      AKWHLog(NO, @"https %@ -> %ld, %lu bytes, %.1f ms (%u local files so far)", url.path, (long)status,
              (unsigned long)body.length, (CFAbsoluteTimeGetCurrent() - load.started) * 1000, n);
    finishLoad(load, response, body, nil);
  });
}

#pragma mark The scheme handler

@implementation AKWHLoopback

+ (instancetype)shared {
  static AKWHLoopback *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [AKWHLoopback new];
    gFileQueue = dispatch_queue_create("AKWebHelper.files", DISPATCH_QUEUE_CONCURRENT);
    gLoadsByTask = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                         valueOptions:NSPointerFunctionsStrongMemory];
    gLoadsBySession = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                            valueOptions:NSPointerFunctionsStrongMemory];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    config.HTTPShouldSetCookies = YES;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    config.HTTPMaximumConnectionsPerHost = 8;
    config.timeoutIntervalForRequest = 60;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    gSession = [NSURLSession sessionWithConfiguration:config delegate:shared delegateQueue:queue];
  });
  return shared;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
  AKWHLoad *load = [AKWHLoad new];
  load.schemeTask = task;
  load.url = task.request.URL;
  load.started = CFAbsoluteTimeGetCurrent();
  [gLoadsByTask setObject:load forKey:task];
  NSURL *url = task.request.URL;
  AKWHHostMapping *m = mappingFor(url.host);
  if (m) { serveFile(load, m); return; }

  // Anything else: the real network.
  NSMutableURLRequest *request = [task.request mutableCopy];
  request.HTTPShouldHandleCookies = YES;
  NSURLSessionDataTask *data = [gSession dataTaskWithRequest:request];
  load.dataTask = data;
  @synchronized(gLoadsBySession) { [gLoadsBySession setObject:load forKey:data]; }
  unsigned n = __atomic_add_fetch(&gProxied, 1, __ATOMIC_RELAXED);
  if (n <= 40 || n % 200 == 0) AKWHLog(NO, @"https %@ %@ -> network (%u so far)", request.HTTPMethod, url, n);
  [data resume];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
  AKWHLoad *load = [gLoadsByTask objectForKey:task];
  if (!load) return;
  load.stopped = YES;
  [gLoadsByTask removeObjectForKey:task];
  [load.dataTask cancel];
}

static AKWHLoad *loadFor(NSURLSessionTask *task) {
  @synchronized(gLoadsBySession) { return [gLoadsBySession objectForKey:task]; }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  completionHandler(NSURLSessionResponseAllow);
  AKWHLoad *load = loadFor(dataTask);
  if (!load) return;
  // The body arrives decoded, so the encoding and length of the compressed body don't apply.
  NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
  NSMutableDictionary *headers = [http.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
  for (NSString *key in [headers allKeys]) {
    NSString *k = key.lowercaseString;
    if ([k isEqualToString:@"content-encoding"] || [k isEqualToString:@"content-length"] || [k isEqualToString:@"transfer-encoding"])
      [headers removeObjectForKey:key];
  }
  NSHTTPURLResponse *copy = [[NSHTTPURLResponse alloc] initWithURL:load.url statusCode:http ? http.statusCode : 200
                                                       HTTPVersion:@"HTTP/1.1" headerFields:headers];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (load.stopped) return;
    @try { [load.schemeTask didReceiveResponse:copy]; } @catch (NSException *e) { load.stopped = YES; }
  });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
  AKWHLoad *load = loadFor(dataTask);
  if (!load) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (load.stopped) return;
    @try { [load.schemeTask didReceiveData:data]; } @catch (NSException *e) { load.stopped = YES; }
  });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  AKWHLoad *load = loadFor(task);
  @synchronized(gLoadsBySession) { [gLoadsBySession removeObjectForKey:task]; }
  if (!load) return;
  if (error && error.code != NSURLErrorCancelled) AKWHLog(NO, @"https %@ failed: %@", task.originalRequest.URL, error.localizedDescription);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (load.stopped) return;
    [gLoadsByTask removeObjectForKey:load.schemeTask];
    @try {
      if (error) [load.schemeTask didFailWithError:error];
      else [load.schemeTask didFinish];
    } @catch (NSException *e) {
    }
  });
}

@end

#pragma mark Taking over https

static IMP gHandlesURLScheme;

static BOOL akHandlesURLScheme(id self, SEL _cmd, NSString *scheme) {
  if ([scheme caseInsensitiveCompare:@"https"] == NSOrderedSame) return NO;
  return ((BOOL (*)(id, SEL, NSString *))gHandlesURLScheme)(self, _cmd, scheme);
}

void AKWHLoopbackInstall(WKWebViewConfiguration *configuration) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Method m = class_getClassMethod(WKWebView.class, @selector(handlesURLScheme:));
    if (m) gHandlesURLScheme = method_setImplementation(m, (IMP)akHandlesURLScheme);
  });
  @try {
    [configuration setURLSchemeHandler:[AKWHLoopback shared] forURLScheme:@"https"];
    AKWHLog(YES, @"Steam's pages load https through the app (steamloopback.host from files, the rest from the network)");
  } @catch (NSException *e) {
    AKWHLog(YES, @"can't serve https://steamloopback.host: WebKit refused the https handler (%@)", e.reason);
  }
}
